import AppKit
@_exported import CefKit
import CryptoKit
import Foundation

/// Owns the Chromium runtime and native Chrome-style window. Never uses Alloy.
@MainActor
public final class ChromiumEngine: NSObject {
  public let dataDirectory: URL
  public private(set) var pages: [String: ChromiumPage] = [:]
  private var profiles: [String: CefProfile] = [:]
  private var openedPersistentProfiles: Set<String> = []
  private var extensionAccess: [String: Set<String>] = [:]
  private var privateExtensionAccess: [String: Set<String>] = [:]
  private var downloadControls: [String: CefDownloadControl] = [:]
  private var retiredProfiles: Set<String> = []
  private var profilesUnderMaintenance: Set<String> = []
  private var profileMaintenanceEpochs: [String: UInt64] = [:]
  private var profileDownloadRetirements: [String: Task<Void, Error>] = [:]
  private var retirementPhase = ChromiumRetirementPhase()
  private var shuttingDown = false
  private var host: CefChromeBrowser?
  private var capabilities: CefNativeCapabilities?
  private var unsupportedNativeCapabilities = false
  private var capabilityProbe: Task<CefNativeCapabilities, Error>?
  private var capabilityProbeID: UUID?
  public private(set) var contexts: [String: ChromiumWindowContext] = [:]
  public private(set) var primaryWindow: ChromiumWindowContext?
  public private(set) var focusedWindowID: String?
  private var nextWindowID = 1
  private let extensionPopupOwnership = ChromiumExtensionPopupOwnership()
  public var window: NSWindow? { primaryWindow?.window }
  public var onLayout: (() -> Void)? {
    get { primaryWindow?.onLayout }
    set { primaryWindow?.onLayout = newValue }
  }
  public private(set) var isTerminating = false
  public var onTerminationChanged: ((Bool) -> Void)?
  public var beforeTermination: (() async -> Void)?
  public var beforeClosingDocuments: (() async -> Bool)?
  private var closingPreparation: Task<Bool, Never>?
  private var closingPreparationID: UUID?
  private var terminationAttemptID: UUID?
  private var terminationDrainStarted = false
  private var terminationCleanup: Task<Void, Never>?
  private var terminationCompletionAttemptID: UUID?
  public var onDownload: ((String, Bool, CefDownload) -> Void)?
  public var onPageClosed: ((String) -> Void)?
  public var onPageCloseCancelled: ((String) -> Void)?
  /// Fallback for engine-owned management documents with no window coordinator.
  /// The host chooses a matching profile/window and adopts the live popup.
  public var onUnownedPopupCreated: ((ChromiumPage, ChromiumPage, Bool) -> Void)?
  public var onUnownedOpenURL: ((ChromiumPage, URL, Bool) -> Void)?
  public var isWindowClosing: Bool { primaryWindow?.isClosing ?? false }
  public var isWindowOpen: Bool { primaryWindow?.isOpen ?? false }
  public var onWindowClosed: (() -> Void)? {
    get { primaryWindow?.onClosed }
    set { primaryWindow?.onClosed = newValue }
  }
  public var onWindowCloseCancelled: (() -> Void)? {
    get { primaryWindow?.onCloseCancelled }
    set { primaryWindow?.onCloseCancelled = newValue }
  }

  public init(dataDirectory: URL) {
    self.dataDirectory = dataDirectory
    super.init()
  }

  /// Exact native action-popup ownership; authentication, permission and
  /// JavaScript dialog windows are never accepted through this lookup.
  public func extensionPopupOwner(_ popup: NSWindow) -> ChromiumWindowContext? {
    guard let owner = extensionPopupOwnership.owner(of: popup) else { return nil }
    return contexts.values.first { $0.window === owner && $0.isOpen && !$0.isClosing }
  }

  /// Runtime capabilities do not vary by profile. Probe through the broker's
  /// initialized blank document so a fresh tab can retain its initial entry
  /// without waiting for a renderer to handle an unknown protocol method.
  public func nativeCapabilities() async throws -> CefNativeCapabilities {
    try Task.checkCancellation()
    guard !shuttingDown, let browser = host?.browser else { throw CefDevToolsError.browserClosed }
    if let capabilities { return capabilities }
    if unsupportedNativeCapabilities {
      throw CefDevToolsError.protocolError(code: -32601, message: "The loaded Chromium runtime does not provide native browser capabilities.")
    }
    let token: UUID
    let probe: Task<CefNativeCapabilities, Error>
    if let existing = capabilityProbe, let existingID = capabilityProbeID {
      probe = existing; token = existingID
    } else {
      token = UUID()
      probe = Task { @MainActor in
        try await browser.waitUntilReady()
        return try await browser.nativeCapabilities()
      }
      capabilityProbe = probe; capabilityProbeID = token
    }
    defer {
      if capabilityProbeID == token { capabilityProbe = nil; capabilityProbeID = nil }
    }
    do {
      let result = try await probe.value
      capabilities = result
      try Task.checkCancellation()
      return result
    } catch {
      if let failure = error as? CefDevToolsError, failure.isUnsupportedMethod {
        unsupportedNativeCapabilities = true
      }
      throw error
    }
  }

  /// Call before NSApplication.shared or SwiftUI's App.main().
  public func start() throws {
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    try removeRetiredProfileData()
    var configuration = CefConfiguration()
    configuration.rootCachePath = dataDirectory.appendingPathComponent(
      "Chromium", isDirectory: true)
    configuration.noSandbox = false
    configuration.safeStorage = .keychain
    if CommandLine.arguments.contains("--engine-acceptance") {
      let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
      let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        .resolvingSymlinksInPath()
      guard
        let fixtureURL = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"].flatMap(
          URL.init(string:)),
        fixtureURL.scheme == "http", fixtureURL.host == "127.0.0.1",
        fixtureURL.user == nil, fixtureURL.password == nil,
        directory.deletingLastPathComponent() == temporary,
        directory.lastPathComponent.hasPrefix("zacro-native-acceptance-"),
        try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
      else {
        throw NSError(
          domain: "ZacroEngine", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Engine acceptance requires a fresh empty zacro-native-acceptance-* directory inside the system temporary directory."
          ])
      }
      configuration.safeStorage = .mockKeychain
    }
    configuration.persistSessionCookies = true
    // Match official CEF release behavior. Unbranded Chromium otherwise applies
    // its developer field-trial test matrix, including helper architectures
    // that CEF does not package. This leaves production defaults and sandbox
    // enforcement intact, including in a diagnostic non-official build.
    configuration.extraCommandLineSwitches.updateValue(nil, forKey: "disable-field-trial-config")
    // The native scoped lease follows actual document visibility. Its fresh
    // process acceptance proves retained trees without enabling hidden brokers
    // or never-shown documents through a process-wide renderer switch.
    let scopedAccessibilityAcceptance = CommandLine.arguments.contains("--native-accessibility-acceptance")
    if scopedAccessibilityAcceptance {
      guard CommandLine.arguments.contains("--engine-acceptance"),
        !CommandLine.arguments.contains("--native-integration-acceptance"),
        !CommandLine.arguments.contains("--native-ui-review") else {
        throw NSError(domain: "ZacroEngine", code: 1, userInfo: [NSLocalizedDescriptionKey:
          "Scoped accessibility acceptance requires its own fresh disposable engine launch."])
      }
    }
    configuration.defaultRuntimeStyle = .chrome
    configuration.logFile = dataDirectory.appendingPathComponent("chromium.log")
    try CefRuntime.shared.initialize(configuration: configuration)
    CefRuntime.shared.onTerminationChanged = { [weak self] terminating in
      guard let self else { return }
      self.isTerminating = terminating
      if terminating {
        let attempt = UUID(); self.terminationAttemptID = attempt
        self.retirementPhase.prepare(attempt)
      } else {
        if let attempt = self.terminationAttemptID { self.retirementPhase.cancel(attempt) }
        self.terminationAttemptID = nil
        self.closingPreparationID = nil
        let preparation = self.closingPreparation; self.closingPreparation = nil
        preparation?.cancel()
        for context in self.contexts.values {
          if let attempt = context.closingAttemptID {
            self.cancelWindowClose(context, vetoedBy: nil, attemptID: attempt)
          } else { self.cancelWindowPreparation(context) }
        }
      }
      self.onTerminationChanged?(terminating)
    }
    CefRuntime.shared.beforeClosingDocuments = { [weak self] in
      await self?.prepareToCloseDocuments() ?? true
    }
    CefRuntime.shared.onReadyToTerminate = { [weak self] in
      self?.finishTerminationAfterCleanup {
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(
          with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
          NSApp.postEvent(wake, atStart: true)
        }
      }
    }
    CefRuntime.shared.bridge.autoInjectsShim = false
    // Chromium's Views content view owns event routing and accessibility. A
    // SwiftUI subview placed over it can draw while its controls receive no
    // clicks. Keep the application chrome in a real AppKit window and attach
    // the independent Chrome document windows beneath that native parent.
    primaryWindow = createWindow(id: "primary")
    var options = CefChromeBrowserOptions()
    options.initialBounds = CGRect(x: -16000, y: -16000, width: 800, height: 600)
    options.profile = .incognito()
    options.showsWindowOnCreation = false
    host = CefChromeBrowser.create(url: URL(string: "about:blank")!, options: options)
    host?.setPageVisible(false)
  }

  /// A nil URL creates a fresh initial document without navigation, suitable
  /// for authenticated native session restoration before its first load.
  public func page(id: String, profileID: String, isPrivate: Bool, url: URL?,
                   nativeReservation: ChromeTabMaterialization? = nil) -> ChromiumPage {
    page(id: id, profileID: profileID, isPrivate: isPrivate, url: url,
      nativeReservation: nativeReservation, ownerWindowID: primaryWindow?.id)
  }

  public func page(id: String, profileID: String, isPrivate: Bool, url: URL?,
                   nativeReservation: ChromeTabMaterialization? = nil,
                   ownerWindowID: String?) -> ChromiumPage {
    if !isPrivate && retiredProfiles.contains(profileID) {
      let rejected = ChromiumPage(id: id, profileID: profileID, isPrivate: false)
      rejected.ownerWindowID = ownerWindowID
      rejected.rejectCreation("This profile is still being removed. Import it as a new profile or restart after removal completes.")
      return rejected
    }
    if let page = pages[id] {
      precondition(
        page.profileID == profileID && page.isPrivate == isPrivate,
        "Cannot move a live page across profiles")
      return page
    }
    precondition(host != nil, "Start Chromium before creating pages")
    precondition(ownerWindowID == nil || contexts[ownerWindowID!]?.isOpen == true,
      "A document requires an open owning window")
    precondition(nativeReservation == nil || (nativeReservation?.profileID == profileID && nativeReservation?.logicalID == id),
      "A native tab reservation belongs to its original profile and logical tab")
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    let profile: CefProfile
    if let existing = profiles[key] {
      profile = existing
    } else {
      let safeID = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }
        .joined()
      profile = isPrivate ? .incognito() : .persistent(name: safeID)
      profiles[key] = profile
    }
    let page = ChromiumPage(id: id, profileID: profileID, isPrivate: isPrivate)
    if !isPrivate { openedPersistentProfiles.insert(profileID) }
    page.ownerWindowID = ownerWindowID
    page.reservedNativeTabID = nativeReservation?.nativeID
    let chrome = host!.createPage(
      url: url, profile: profile, delegate: page, hostingWindow: ownerWindowID.flatMap { contexts[$0]?.window },
      nativeTabReservation: nativeReservation?.token)
    attach(page, chrome: chrome)
    return page
  }

  private func attach(_ page: ChromiumPage, chrome: CefChromeBrowser) {
    // A synchronous reservation/creation rejection can close before the
    // factory returns. Never cache that document or retain it as a child.
    guard !chrome.browser.isClosed else { return }
    let profileID = page.profileID, isPrivate = page.isPrivate
    chrome.browser.downloadObserver = { [weak self] download, control in
      guard let self, !self.shuttingDown else { control?.invalidate(); return }
      let key = "\(profileID):\(download.id)"
      if download.isComplete || download.isCanceled {
        self.downloadControls.removeValue(forKey: key)?.invalidate()
        control?.invalidate()
      } else if let control {
        self.downloadControls.updateValue(control, forKey: key)?.invalidate()
      }
      self.onDownload?(profileID, isPrivate, download)
    }
    page.chrome = chrome
    page.authorizeExtensionURL = { [weak self, weak page] url in
      guard let self, let page, let identifier = url.host else { return false }
      let allowed = page.isPrivate ? self.privateExtensionAccess[page.profileID] : self.extensionAccess[page.profileID]
      return allowed?.contains(identifier) == true
    }
    page.adoptCurrentDocumentState()
    page.onSidePanelChangedInternal = { [weak self, weak page] visible in
      guard visible, let self, let page, !page.id.hasPrefix("panel-parking:") else { return }
      Task { [weak self, weak page] in
        guard let self, let page else { return }
        _ = await self.prepareRetainedPanelBeforeClosing(page)
      }
    }
    page.observeDocumentState()
    chrome.beforeClose = { [weak self, weak page] in
      guard let self, let page else { return true }
      if self.isTerminating || page.ownerWindowID.flatMap({ self.contexts[$0]?.isClosing }) == true { return true }
      guard await page.beforeClose?() ?? true else {
        page.preparationVetoPending = true; return false
      }
      let accepted = await self.prepareRetainedPanelBeforeClosing(page)
      if !accepted { page.preparationVetoPending = true }
      return accepted
    }
    chrome.browser.onCloseCancelled = { [weak self, weak page] in
      page?.chrome?.cancelPreparedClose()
      // An older tab preparation can be cancelled by a newer window-close
      // attempt. Its callback is not a beforeunload veto for that new attempt.
      let preparationVeto = page?.preparationVetoPending == true
      page?.preparationVetoPending = false
      if !preparationVeto, let self, let page, let attempt = page.windowCloseAttemptID,
        let owner = page.ownerWindowID, let context = self.contexts[owner] {
        self.cancelWindowClose(context, vetoedBy: page, attemptID: attempt)
      }
      page?.onCloseCancelled?()
      if let page { self?.onPageCloseCancelled?(page.id) }
      if preparationVeto, let self, let page {
        // CEF keeps one closePreparation task. A newer close() may have met
        // that old task instead of starting native beforeunload; retry only
        // once its rejection has drained, under the newer accepted scope.
        let windowAttempt = page.windowCloseAttemptID
        let terminationAttempt = self.terminationAttemptID
        DispatchQueue.main.async { [weak self, weak page] in
          guard let self, let page, self.pages[page.id] === page else { return }
          if let terminationAttempt, self.isTerminating,
            self.terminationAttemptID == terminationAttempt, page.browser?.closingForTermination == true {
            page.close()
          } else if !self.isTerminating, let windowAttempt,
            let owner = page.ownerWindowID, let context = self.contexts[owner],
            context.isOpen, context.isClosing, context.closingAttemptID == windowAttempt,
            context.closingPreparation == nil, page.windowCloseAttemptID == windowAttempt {
            page.close()
          }
        }
      }
    }
    page.onClosedInternal = { [weak self, weak page] in
      guard let self, let page else { return }
      if self.pages[page.id] === page { self.pages.removeValue(forKey: page.id) }
      self.onPageClosed?(page.id)
      if let owner = page.ownerWindowID, let context = self.contexts[owner] {
        self.finishWindowCloseIfReady(context)
      }
    }
    page.onFocusedInternal = { [weak self, weak page] in
      guard let self, let owner = page?.ownerWindowID else { return }
      self.windowDidFocus(id: owner)
    }
    page.canAdoptPopupInternally = { [weak self] in self?.onUnownedPopupCreated != nil }
    page.openURLInternally = { [weak self, weak page] url, foreground in
      guard let self, let page, let callback = self.onUnownedOpenURL else { return false }
      callback(page, url, foreground); return true
    }
    pages[page.id] = page
    chrome.onPopupCreated = { [weak self, weak page] child, request in
      guard let self, let page, self.pages[page.id] === page, !self.isTerminating,
        page.ownerWindowID.flatMap({ self.contexts[$0]?.isClosing }) != true else {
        child.close(); return
      }
      let popup = ChromiumPage(id: "popup-" + UUID().uuidString, profileID: page.profileID, isPrivate: page.isPrivate)
      popup.openerID = page.id
      popup.ownerWindowID = page.ownerWindowID
      child.browser.delegate = popup
      self.attach(popup, chrome: child)
      if let callback = page.onPopupCreated { callback(popup, request.disposition.prefersForeground) }
      else if let callback = self.onUnownedPopupCreated { callback(page, popup, request.disposition.prefersForeground) }
      else { popup.close() }
    }
  }

  /// A real Chromium owner for global extension UI when its logical window
  /// temporarily has no live document. It is never a user tab or action target.
  /// The shell may present this transparent blank BrowserView over its empty
  /// canvas; selecting a live tab transfers the existing panel back to it.
  public func parkedExtensionPanel(ownerWindowID: String, profileID: String) -> ChromiumPage? {
    let id = panelParkingID(ownerWindowID: ownerWindowID, profileID: profileID)
    guard let page = pages[id], page.isSidePanelVisible else { return nil }
    return page
  }

  /// Prevents panel retention from creating documents while a profile-wide
  /// clear/delete transaction is closing its complete document snapshot.
  public func setProfileMaintenance(_ profileID: String, active: Bool) {
    let changed = active ? profilesUnderMaintenance.insert(profileID).inserted
      : profilesUnderMaintenance.remove(profileID) != nil
    if changed { profileMaintenanceEpochs[profileID, default: 0] &+= 1 }
  }

  private func panelParkingID(ownerWindowID: String, profileID: String) -> String {
    "panel-parking:\(ownerWindowID):\(profileID)"
  }

  private func prepareRetainedPanelBeforeClosing(_ page: ChromiumPage) async -> Bool {
    guard !page.isPrivate, !profilesUnderMaintenance.contains(page.profileID),
      !page.id.hasPrefix("panel-parking:"),
      capabilities?.extensionBrowser == true, let ownerID = page.ownerWindowID,
      let context = contexts[ownerID], context.isOpen, !context.isClosing,
      let browser = page.browser else { return true }
    let originalID = page.id
    let maintenanceEpoch = profileMaintenanceEpochs[page.profileID, default: 0]
    func retentionNoLongerNeeded() -> Bool {
      isTerminating || context.isClosing || profilesUnderMaintenance.contains(page.profileID)
        || profileMaintenanceEpochs[page.profileID, default: 0] != maintenanceEpoch
    }
    do {
      let result = try await browser.devTools.call("Zacro.hasOwnedGlobalPanel", parameters: ["windowID": context.nativeID])
      if retentionNoLongerNeeded() { return true }
      guard pages[originalID] === page, page.browser === browser, page.ownerWindowID == ownerID,
        context.isOpen, let owned = result["owned"] as? Bool else { return false }
      guard owned else { return true }
      let parkingID = panelParkingID(ownerWindowID: ownerID, profileID: page.profileID)
      let parking = self.page(id: parkingID, profileID: page.profileID, isPrivate: false,
        url: URL(string: "about:blank"), ownerWindowID: ownerID)
      parking.onChange = { [weak context] in context?.onLayout?() }
      let parkingBrowser = try await parking.ready()
      let deadline = Date().addingTimeInterval(5)
      while parking.url?.absoluteString != "about:blank" || parking.isLoading {
        if retentionNoLongerNeeded() { return true }
        guard context.isOpen, pages[parkingID] === parking, Date() < deadline else {
          throw CefDevToolsError.unavailable
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      if retentionNoLongerNeeded() { return true }
      guard context.isOpen, pages[originalID] === page, page.ownerWindowID == ownerID,
        pages[parkingID] === parking, parking.browser === parkingBrowser else { return false }
      let registered = try await parkingBrowser.devTools.call("Zacro.registerPanelParking",
        parameters: ["windowID": context.nativeID])
      if retentionNoLongerNeeded() { return true }
      guard pages[originalID] === page, page.browser === browser, page.ownerWindowID == ownerID,
        registered["registered"] as? Bool == true else { return false }
      // The real view moves only in Chromium's accepted WillDetach callback.
      // A beforeunload cancellation leaves the source panel untouched.
      return true
    } catch {
      if retentionNoLongerNeeded() { return true }
      page.reportClosePreparationError("The extension panel could not be retained: " + error.localizedDescription)
      return false
    }
  }

  public func hideAll(windowID: String? = nil) {
    for page in pages.values where windowID == nil || page.ownerWindowID == windowID { page.hide() }
  }
  func updateExtensionAccess(_ snapshot: ChromeExtensionSnapshot, profileID: String) {
    extensionAccess[profileID] = Set(snapshot.extensions.filter(\.isEnabled).map(\.id))
    privateExtensionAccess[profileID] = Set(snapshot.extensions.filter { $0.isEnabled && $0.incognitoAccess.isActive }.map(\.id))
  }
  public func clearNetworkData(profileID: String, isPrivate: Bool, selected: CefNetworkData = .all) async throws {
    guard isPrivate || !retiredProfiles.contains(profileID) else {
      throw CefDevToolsError.rejected("This profile is still being removed.")
    }
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    let profile: CefProfile
    if let existing = profiles[key] { profile = existing }
    else {
      let safeID = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
      profile = isPrivate ? .incognito() : .persistent(name: safeID)
      profiles[key] = profile
    }
    if !isPrivate { openedPersistentProfiles.insert(profileID) }
    try await profile.clearNetworkData(selected)
  }
  /// Reparents the same retained Chromium document when promoting a Peek.
  /// Callers reconnect their model callbacks to the new tab identifier.
  @discardableResult public func adoptPage(fromID: String, toID: String) -> ChromiumPage? {
    guard fromID != toID, !toID.isEmpty, pages[toID] == nil,
      let page = pages.removeValue(forKey: fromID) else { return nil }
    page.id = toID
    pages[toID] = page
    for child in pages.values where child.openerID == fromID { child.openerID = toID }
    return page
  }
  public func close(id: String) { pages[id]?.close() }
  /// Chrome-owned auth/developer windows retain the actual request context but
  /// are deliberately absent from the application tab catalog.
  public func auxiliaryBrowsers(profileID: String, isPrivate: Bool) -> [CefBrowser] {
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    guard let profile = profiles[key] else { return [] }
    return CefRuntime.shared.auxiliaryBrowsers.filter { $0.belongs(to: profile) }
  }
  public func closeAuxiliaryBrowsers(profileID: String, isPrivate: Bool) async throws {
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    guard let profile = profiles[key] else { return }
    try await CefRuntime.shared.closeAuxiliaryBrowsers(in: profile)
  }
  private func hasAuxiliaryWindows(profileID: String, isPrivate: Bool) -> Bool {
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    guard let profile = profiles[key] else { return false }
    return CefRuntime.shared.hasAuxiliaryWindows(in: profile)
  }
  /// Core must already have committed profile deletion or last-private-owner
  /// retirement. Keep the existing context alive until Chromium has cancelled
  /// every transfer, including worker downloads with no browser callback.
  public func retireProfileDownloads(profileID: String, isPrivate: Bool) async throws {
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    if let pending = profileDownloadRetirements[key] { try await pending.value; return }
    guard retirementPhase.canBeginTask, !shuttingDown, !terminationDrainStarted else {
      throw CefDevToolsError.rejected("Profile retirement is deferred to runtime shutdown or a cancelled-Quit retry.")
    }
    // Startup replay and profiles never opened in this process have no native
    // transfers. Do not create a request context merely to remove one.
    guard profiles[key] != nil else { return }
    let task = Task { @MainActor in
      try await self.closeAuxiliaryBrowsers(profileID: profileID, isPrivate: isPrivate)
      guard self.retirementPhase.canCreateForExistingTask, !self.shuttingDown,
        !self.terminationDrainStarted, self.host?.browser.isClosed == false else { throw CefDevToolsError.browserClosed }
      do {
        guard try await self.nativeCapabilities().downloads == true else { return }
      } catch let error as CefDevToolsError where error.isUnsupportedMethod {
        // Explicit stock-runtime diagnostics have no native extension download
        // manager. Their CEF callback controls are cancelled during release.
        return
      }
      guard self.retirementPhase.canCreateForExistingTask, !self.shuttingDown,
        !self.terminationDrainStarted, self.host?.browser.isClosed == false else { throw CefDevToolsError.browserClosed }
      let transport = self.page(id: "maintenance:retire:" + key, profileID: profileID,
        isPrivate: isPrivate, url: URL(string: "about:blank")!, ownerWindowID: nil)
      transport.hide()
      try await transport.ready().retireProfileDownloads()
      // A failed fence retains this exact transport and context for retry. The
      // durable Core receipt must not be acknowledged until this succeeds.
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let previous = transport.onClosed
        transport.onClosed = { previous?(); continuation.resume() }
        transport.close()
      }
    }
    profileDownloadRetirements[key] = task
    defer { profileDownloadRetirements.removeValue(forKey: key) }
    try await task.value
  }
  public func releasePrivateProfile(_ profileID: String) throws {
    guard !pages.values.contains(where: { $0.profileID == profileID && $0.isPrivate }),
      !hasAuxiliaryWindows(profileID: profileID, isPrivate: true) else {
      throw CefDevToolsError.rejected("Close the private profile's documents before releasing it.")
    }
    profiles.removeValue(forKey: "private:" + profileID)
    privateExtensionAccess.removeValue(forKey: profileID)
    for key in downloadControls.keys.filter({ Self.downloadProfileID($0) == profileID }) {
      if let control = downloadControls.removeValue(forKey: key) { _ = control.cancel(); control.invalidate() }
    }
  }
  /// Removes runtime ownership only after all documents have accepted close.
  /// Chromium owns profile databases until shutdown; deletion is journaled and
  /// completed with no live Chromium context, including after an interrupted quit.
  public func retireProfile(_ profileID: String) throws {
    guard ChromiumProfileRetirementJournal.validID(profileID) else { throw POSIXError(.EINVAL) }
    guard !pages.values.contains(where: { $0.profileID == profileID }),
      !hasAuxiliaryWindows(profileID: profileID, isPrivate: false),
      !hasAuxiliaryWindows(profileID: profileID, isPrivate: true) else {
      throw NSError(domain: "ZacroEngine", code: 2, userInfo: [NSLocalizedDescriptionKey:
        "Close this profile's documents before deleting it."])
    }
    retiredProfiles.insert(profileID)
    try profileRetirementJournal.write(retiredProfiles)
    profiles.removeValue(forKey: "persistent:" + profileID)
    profiles.removeValue(forKey: "private:" + profileID)
    extensionAccess.removeValue(forKey: profileID)
    privateExtensionAccess.removeValue(forKey: profileID)
    for key in downloadControls.keys.filter({ Self.downloadProfileID($0) == profileID }) {
      if let control = downloadControls.removeValue(forKey: key) { _ = control.cancel(); control.invalidate() }
    }
  }

  private var retirementJournal: URL { dataDirectory.appendingPathComponent("retired-chromium-profiles.json") }
  private static func downloadProfileID(_ key: String) -> String? {
    key.lastIndex(of: ":").map { String(key[..<$0]) }
  }
  private var profileRetirementJournal: ChromiumProfileRetirementJournal {
    ChromiumProfileRetirementJournal(file: retirementJournal)
  }

  /// Replays an authoritative Core deletion receipt before this runtime has
  /// opened the profile. A live or previously opened context stays deferred.
  public func replayProfileRetirement(_ profileID: String) throws {
    guard !openedPersistentProfiles.contains(profileID),
      !pages.values.contains(where: { $0.profileID == profileID }) else {
      throw CefDevToolsError.rejected("Replay profile retirement before opening its native documents.")
    }
    try retireProfile(profileID)
    try removeProfileDirectory(profileID)
    var remaining = retiredProfiles
    remaining.remove(profileID)
    try profileRetirementJournal.write(remaining)
    retiredProfiles = remaining
  }

  private func removeProfileDirectory(_ identifier: String) throws {
    let root = dataDirectory.appendingPathComponent("Chromium", isDirectory: true)
    let safeID = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    try ChromiumProfileRetirementJournal.removeProfileDirectory(root: root, hash: safeID)
  }
  private func removeRetiredProfileData() throws {
    let existing = FileManager.default.fileExists(atPath: retirementJournal.path)
    retiredProfiles.formUnion(try profileRetirementJournal.read())
    guard existing || !retiredProfiles.isEmpty else { return }
    for identifier in retiredProfiles {
      try removeProfileDirectory(identifier)
    }
    try profileRetirementJournal.write([])
    retiredProfiles.removeAll()
  }
  public func context(id: String) -> ChromiumWindowContext? { contexts[id] }

  /// Bind the startup shell to the durable model before creating documents.
  @discardableResult public func bindPrimaryWindow(id: String) -> ChromiumWindowContext? {
    guard !id.isEmpty, let primaryWindow, pages.isEmpty,
      contexts[id] == nil || contexts[id] === primaryWindow else { return nil }
    contexts.removeValue(forKey: primaryWindow.id)
    if focusedWindowID == primaryWindow.id { focusedWindowID = id }
    primaryWindow.id = id
    contexts[id] = primaryWindow
    return primaryWindow
  }

  @discardableResult public func createWindow(id: String = UUID().uuidString) -> ChromiumWindowContext {
    precondition(!id.isEmpty && !shuttingDown, "A window requires a valid live engine")
    if let existing = contexts[id] {
      if !existing.isOpen {
        existing.nativeID = nextWindowID; nextWindowID += 1
        existing.isOpen = true; existing.isClosing = false
      }
      return existing
    }
    let context = ChromiumWindowContext(id: id, nativeID: nextWindowID, engine: self)
    nextWindowID += 1
    contexts[id] = context
    if primaryWindow == nil { primaryWindow = context }
    return context
  }

  /// Move only the presentation owner; the Chromium document is never recreated.
  @discardableResult public func movePage(id: String, toWindowID: String) -> Bool {
    guard let page = pages[id], let target = contexts[toWindowID], target.isOpen,
      !target.isClosing, !isTerminating,
      page.ownerWindowID.flatMap({ contexts[$0]?.isClosing }) != true else { return false }
    if page.ownerWindowID == toWindowID { return true }
    page.hide()
    page.ownerWindowID = toWindowID
    page.chrome?.setHostingWindow(target.window)
    return true
  }

  func windowDidFocus(id: String) {
    guard let context = contexts[id], context.isOpen else { return }
    focusedWindowID = id
    context.onFocused?()
  }

  public func showWindow() { if let primaryWindow { showWindow(id: primaryWindow.id) } }
  public func showWindow(id: String) {
    guard let context = contexts[id], !context.isClosing, !isTerminating else { return }
    if !context.isOpen { _ = createWindow(id: id) }
    context.window.makeKeyAndOrderFront(nil)
  }

  /// Chromium asks only this shell's documents about unsaved changes.
  public func closeWindow() { if let primaryWindow { closeWindow(id: primaryWindow.id) } }
  public func closeWindow(id: String) {
    guard let context = contexts[id], context.isOpen, !context.isClosing, !isTerminating else { return }
    let attempt = UUID()
    context.closingAttemptID = attempt
    context.isClosing = true
    Task { @MainActor [weak self, weak context] in
      guard let self, let context else { return }
      let accepted = await self.prepareToCloseDocuments(in: context)
      guard context.isClosing, context.closingAttemptID == attempt, !self.isTerminating else { return }
      guard accepted else { self.cancelWindowClose(context, vetoedBy: nil, attemptID: attempt); return }
      for page in Array(self.pages.values) where page.ownerWindowID == context.id {
        page.closedForWindow = true
        page.windowCloseAttemptID = attempt
        page.close()
      }
      self.finishWindowCloseIfReady(context)
    }
  }

  private func prepareToCloseDocuments(in context: ChromiumWindowContext) async -> Bool {
    if let existing = context.closingPreparation, let token = context.closingPreparationID {
      let accepted = await existing.value
      return accepted && !Task.isCancelled && context.closingPreparationID == token
    }
    let token = UUID()
    context.closingPreparationID = token
    let task = Task { @MainActor [weak self, weak context] in
      guard let self, let context, !Task.isCancelled,
        context.closingPreparationID == token else { return false }
      if let prepare = context.beforeClosingDocuments { return await prepare() }
      if context === self.primaryWindow { return await self.beforeClosingDocuments?() ?? true }
      return true
    }
    context.closingPreparation = task
    let accepted = await task.value
    guard context.closingPreparationID == token else { return false }
    context.closingPreparation = nil
    return accepted && !Task.isCancelled && !task.isCancelled
  }

  private func prepareToCloseDocuments() async -> Bool {
    guard isTerminating, let attempt = terminationAttemptID else { return false }
    // A late Chrome-created document can veto after application cleanup began.
    // A later Quit must still negotiate that document without rerunning closed
    // services or reopening retirement admission. Owned documents were already
    // drained; an unexpected new one keeps the retry safely blocked.
    if terminationDrainStarted { return pages.isEmpty }
    if let closingPreparation, let token = closingPreparationID {
      let accepted = await closingPreparation.value
      return accepted && !Task.isCancelled && terminationAttemptID == attempt && closingPreparationID == token
    }
    let token = UUID()
    closingPreparationID = token
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      // Prepare every live shell before CEF asks any document to unload. A veto
      // leaves all native windows intact and permits another attempt later.
      for context in self.contexts.values.sorted(by: { $0.nativeID < $1.nativeID }) where context.isOpen {
        guard !Task.isCancelled, self.terminationAttemptID == attempt,
          self.closingPreparationID == token else { return false }
        if !(await self.prepareToCloseDocuments(in: context)) { return false }
      }
      // New per-profile tasks have been blocked since Quit began. Existing
      // authorized retirements keep their broker until they settle; failures
      // retain cleanup authority for shutdown/startup or a cancelled-Quit retry.
      for retirement in Array(self.profileDownloadRetirements.values) {
        _ = await retirement.result
        guard !Task.isCancelled, self.terminationAttemptID == attempt,
          self.closingPreparationID == token else { return false }
      }
      guard !Task.isCancelled, self.terminationAttemptID == attempt,
        self.closingPreparationID == token else { return false }
      return self.retirementPhase.beginNativeClose(attempt)
    }
    closingPreparation = task
    let accepted = await task.value
    guard closingPreparationID == token else { return false }
    closingPreparation = nil
    return accepted && !Task.isCancelled && !task.isCancelled && terminationAttemptID == attempt
  }

  private func finishTerminationAfterCleanup(_ completion: @escaping () -> Void) {
    guard let attempt = terminationAttemptID,
      terminationCompletionAttemptID != attempt,
      let finish = CefRuntime.shared.deferredTerminationCompletion(completion) else { return }
    terminationCompletionAttemptID = attempt
    if terminationCleanup == nil {
      terminationDrainStarted = true
      retirementPhase.beginDrain()
      // Keep one cleanup task across late native vetoes. A replacement Quit
      // waits for this same task and binds its own exact runtime completion.
      terminationCleanup = Task { @MainActor in await self.beforeTermination?() }
    }
    guard let cleanup = terminationCleanup else { return }
    Task { @MainActor in
      await cleanup.value
      finish()
    }
  }

  private func cancelWindowPreparation(_ context: ChromiumWindowContext) {
    context.closingPreparationID = nil
    let preparation = context.closingPreparation; context.closingPreparation = nil
    preparation?.cancel()
  }

  private func cancelWindowClose(_ context: ChromiumWindowContext, vetoedBy page: ChromiumPage?, attemptID: UUID) {
    if page?.windowCloseAttemptID == attemptID {
      page?.closedForWindow = false; page?.windowCloseAttemptID = nil
    }
    guard context.isClosing, context.closingAttemptID == attemptID else { return }
    context.closingAttemptID = nil
    context.isClosing = false
    cancelWindowPreparation(context)
    // Accepted siblings retain their origin flag until native didClose so the
    // model can restore them when another document vetoes the close.
    context.onCloseCancelled?()
  }

  private func finishWindowCloseIfReady(_ context: ChromiumWindowContext) {
    guard context.isClosing, let attempt = context.closingAttemptID, context.closingPreparation == nil,
      !pages.values.contains(where: { $0.ownerWindowID == context.id }) else { return }
    DispatchQueue.main.async { [weak self, weak context] in
      guard let self, let context, context.isClosing, context.closingAttemptID == attempt,
        !self.pages.values.contains(where: { $0.ownerWindowID == context.id }) else { return }
      context.closingAttemptID = nil
      context.closingPreparationID = nil
      context.isClosing = false; context.isOpen = false
      context.window.orderOut(nil)
      if self.focusedWindowID == context.id { self.focusedWindowID = nil }
      // Core owns private-session lifetime, including empty windows and
      // dormant tabs. Only its authoritative retired IDs may release a profile.
      context.onClosed?()
    }
  }

  @discardableResult public func pauseDownload(profileID: String, id: UInt32) -> Bool {
    downloadControls["\(profileID):\(id)"]?.pause() ?? false
  }
  @discardableResult public func resumeDownload(profileID: String, id: UInt32) -> Bool {
    downloadControls["\(profileID):\(id)"]?.resume() ?? false
  }
  @discardableResult public func cancelDownload(profileID: String, id: UInt32) -> Bool {
    downloadControls["\(profileID):\(id)"]?.cancel() ?? false
  }

  /// Call after NSApplication.run() returns and all native pages have closed.
  public func shutdown() {
    shuttingDown = true
    capabilityProbe?.cancel(); capabilityProbe = nil; capabilityProbeID = nil
    capabilities = nil; unsupportedNativeCapabilities = false
    onLayout = nil
    onTerminationChanged = nil
    onDownload = nil
    onPageClosed = nil
    onPageCloseCancelled = nil
    onUnownedPopupCreated = nil
    onUnownedOpenURL = nil
    for control in downloadControls.values { control.invalidate() }
    downloadControls.removeAll()
    terminationAttemptID = nil; closingPreparationID = nil
    closingPreparation?.cancel(); closingPreparation = nil
    for context in contexts.values {
      cancelWindowPreparation(context)
      context.closingAttemptID = nil
      context.window.delegate = nil
      context.window.orderOut(nil)
      context.window.contentView = nil
      context.engine = nil
    }
    contexts.removeAll(); primaryWindow = nil; focusedWindowID = nil
    pages.removeAll()
    host = nil
    profiles.removeAll()
    CefRuntime.shared.shutdown()
    do { try removeRetiredProfileData() }
    catch { NSLog("Chromium profile retirement remains queued: %@", error.localizedDescription) }
  }
}

/// One retained Chromium document, including its own back/forward and form state.
@MainActor
public final class ChromiumPage: CefBrowserDelegate {
  public fileprivate(set) var id: String
  public let profileID: String
  public let isPrivate: Bool
  public fileprivate(set) var ownerWindowID: String?
  fileprivate var onFocusedInternal: (() -> Void)?
  fileprivate var canAdoptPopupInternally: (() -> Bool)?
  fileprivate var openURLInternally: ((URL, Bool) -> Bool)?
  fileprivate var chrome: CefChromeBrowser?
  fileprivate var onClosedInternal: (() -> Void)?
  fileprivate var authorizeExtensionURL: ((URL) -> Bool)?
  public var browser: CefBrowser? { chrome?.browser }
  public var nativeWindow: NSWindow? { chrome?.nsWindow }
  public private(set) var title = ""
  public private(set) var url: URL?
  public private(set) var isLoading = false
  public private(set) var isAudible = false
  public private(set) var isSidePanelVisible = false
  /// Actual document slot within the hosted page viewport, using top-left
  /// coordinates. A native side panel occupies the remaining area.
  public private(set) var documentBounds: CGRect?
  private var documentEventToken: UUID?
  private var documentObservation: Task<Void, Never>?
  fileprivate var onSidePanelChangedInternal: ((Bool) -> Void)?
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var progress = 0.0
  public private(set) var error: String?
  public private(set) var documentError: ChromiumDocumentError?
  public private(set) var creationFailed = false
  private var creationFailure: String?
  public private(set) var faviconURL: URL?
  /// The committed document that supplied `faviconURL`; never the pinned home URL.
  public private(set) var faviconDocumentURL: URL?
  public fileprivate(set) var reservedNativeTabID: Int?
  public var onChange: (() -> Void)?
  /// Actual cross-document commit, including a reload or restored history entry.
  public var onCommittedNavigation: ((URL) -> Void)?
  /// Emitted only by Chromium's title callback, never a general state refresh.
  public var onTitleChanged: ((String) -> Void)?
  public var onOpenURL: ((URL, Bool) -> Void)?
  /// A context-menu invocation includes its original root-document point.
  /// Other native navigation gestures may omit a point.
  public var onPeek: ((URL, CGPoint?) -> Void)?
  public var onSearchSelection: ((String) -> Void)?
  public var onMutedChanged: ((Bool) -> Void)?
  public var onFocused: (() -> Void)?
  public var onStatusText: ((String) -> Void)?
  public var onPopupCreated: ((ChromiumPage, Bool) -> Void)?
  public var onCloseCancelled: (() -> Void)?
  public var beforeClose: (() async -> Bool)?
  public fileprivate(set) var openerID: String?
  private var popupTimes: [Date] = []
  private var authentication: (UUID, URL?, CefAuthCallback, NSAlert)?
  public var hasPendingAuthentication: Bool { authentication != nil }
  public var onDownload: ((CefDownload) -> Void)?
  public var onDownloadDecision: ((CefDownload, String) -> CefDownloadDecision)?
  public var onPermission: ((CefPermissionRequest) -> CefPermissionDecision)?
  public var onPermissionRequest: ((CefPermissionRequest, CefPermissionCallback) -> Bool)?
  public var onPermissionDismissed: ((UUID) -> Void)?
  public var onJavaScriptDialog: ((CefJSDialog, CefJSDialogCallback) -> Void)?
  public var onBeforeUnloadDialog: ((String, Bool, CefJSDialogCallback) -> Void)?
  public var onJavaScriptDialogReset: (() -> Void)?
  public var onClosed: (() -> Void)?
  public private(set) var closedForTermination = false
  public fileprivate(set) var closedForWindow = false
  fileprivate var windowCloseAttemptID: UUID?
  fileprivate var preparationVetoPending = false
  public var onFindResult: ((Int, Int, Bool) -> Void)? {
    get { browser?.onFindResult }
    set { browser?.onFindResult = newValue }
  }
  private var lastFindQuery = ""
  private var approvedNavigationURLs: Set<Data> = []
  private static func navigationKey(_ url: URL) -> Data {
    Data(SHA256.hash(data: Data(url.absoluteString.utf8)))
  }

  fileprivate func adoptCurrentDocumentState() {
    guard let browser else { return }
    title = browser.title
    url = browser.url
    isLoading = browser.isLoading
    canGoBack = browser.canGoBack
    canGoForward = browser.canGoForward
  }

  fileprivate func reportClosePreparationError(_ message: String) {
    error = message; onChange?()
  }

  fileprivate func observeDocumentState() {
    documentObservation?.cancel()
    documentObservation = Task { [weak self] in
      guard let self else { return }
      do {
        let browser = try await ready()
        try Task.checkCancellation()
        let token = try browser.devTools.observeEvents { [weak self] method, params in
          guard let self else { return }
          if method == "Zacro.documentAudioChanged", let audible = params["audible"] as? Bool {
            self.isAudible = audible; self.onChange?()
          } else if method == "Zacro.documentSidePanelChanged", let visible = params["visible"] as? Bool {
            self.updateSidePanelVisible(visible)
          } else if method == "Zacro.documentBoundsChanged" {
            self.updateDocumentBounds(params["bounds"])
          }
        }
        documentEventToken = token
        do {
          let state = try await browser.devTools.call("Zacro.observeDocument", parameters: ["enabled": true])
          guard !Task.isCancelled, self.browser === browser else { return }
          if let audible = state["audible"] as? Bool { isAudible = audible; onChange?() }
          if let visible = state["sidePanelVisible"] as? Bool { updateSidePanelVisible(visible) }
          updateDocumentBounds(state["bounds"])
        } catch {
          browser.devTools.removeEventObserver(token); documentEventToken = nil
        }
      } catch { /* Native creation or shutdown ended observation. */ }
    }
  }

  private func updateSidePanelVisible(_ visible: Bool) {
    let changed = isSidePanelVisible != visible
    isSidePanelVisible = visible
    onChange?()
    if changed { onSidePanelChangedInternal?(visible) }
  }

  private func updateDocumentBounds(_ value: Any?) {
    var bounds: CGRect?
    if let value = value as? [String: Any],
       let x = value["x"] as? NSNumber, let y = value["y"] as? NSNumber,
       let width = value["width"] as? NSNumber, let height = value["height"] as? NSNumber {
      let values = [x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue]
      if values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }), width.doubleValue > 0, height.doubleValue > 0 {
        bounds = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
      }
    }
    guard bounds != documentBounds else { return }
    documentBounds = bounds
    onChange?()
  }

  fileprivate init(id: String, profileID: String, isPrivate: Bool) {
    self.id = id
    self.profileID = profileID
    self.isPrivate = isPrivate
  }
  public func load(_ url: URL) { browser?.load(url) }
  /// Authorize each validated entry before restoring native history. The
  /// encrypted native history independently revalidates every privileged entry.
  public func authorizeNavigation(_ approval: ChromeNavigationApproval) throws {
    guard approval.profileID == profileID else { throw ChromeExtensionError.invalidResponse }
    guard approval.url.absoluteString.utf8.count <= 1024 * 1024 else {
      throw ChromeExtensionError.loadFailed("The native navigation address exceeds the supported size.")
    }
    let key = Self.navigationKey(approval.url)
    guard approvedNavigationURLs.contains(key) || approvedNavigationURLs.count < 8192 else {
      throw ChromeExtensionError.loadFailed("Too many retained native navigation authorizations.")
    }
    approvedNavigationURLs.insert(key)
  }
  public func loadApprovedNavigation(_ approval: ChromeNavigationApproval) async throws {
    try authorizeNavigation(approval)
    // A network error does not revoke an otherwise valid history entry. The
    // native throttle rechecks the extension incarnation on every traversal.
    _ = try await ready().devTools.call("Zacro.navigateApproved", parameters: approval.parameters, timeout: 50)
  }
  public func ready() async throws -> CefBrowser {
    if let creationFailure { throw CefDevToolsError.rejected(creationFailure) }
    guard let browser else { throw CefDevToolsError.browserClosed }
    try await browser.waitUntilReady()
    guard self.browser === browser else { throw CefDevToolsError.browserClosed }
    return browser
  }
  fileprivate func rejectCreation(_ message: String) {
    creationFailed = true; creationFailure = message; error = message
  }
  public func goBack() { browser?.goBack() }
  public func goForward() { browser?.goForward() }
  public func reload() { browser?.reload() }
  public func stop() { browser?.stopLoading() }
  public func close() { chrome?.close() }
  public func show(frame: CGRect) {
    browser?.setAccessibilityEnabled(true)
    chrome?.setPageFrame(frame)
    chrome?.setPageVisible(true)
  }
  public func hide() { chrome?.setPageVisible(false) }
  public func setCornerRadius(_ radius: CGFloat) { chrome?.setPageCornerRadius(radius) }
  public func setPresentationParent(_ window: NSWindow?) { chrome?.setPresentationParent(window) }
  public func focus() {
    guard let browser, let view = browser.nativeView else { return }
    let tracing = CommandLine.arguments.contains("--native-integration-acceptance")
    @MainActor func trace(_ phase: String) {
      guard tracing else { return }
      let window = view.window
      let responder = (window?.firstResponder).map { String(reflecting: type(of: $0)) } ?? "nil"
      fputs("Native document focus \(phase) id=\(id) appActive=\(NSApp.isActive) window=\(window?.windowNumber ?? -1) key=\(window?.isKeyWindow == true) canKey=\(window?.canBecomeKey == true) appKey=\(NSApp.keyWindow?.windowNumber ?? -1) view=\(String(reflecting: type(of: view))) responder=\(responder) parent=\(window?.parent?.windowNumber ?? -1)\n", stderr)
    }
    trace("before")
    view.window?.makeKey()
    // Chrome Views returns its Widget root as the CEF window handle, not the
    // document's RenderWidgetHostViewCocoa. Making that generic root the Cocoa
    // responder can undo the WebView focus restored when the window became
    // key. Views still remembers the same WebView, so its later RequestFocus
    // then exits without restoring actual document focus. Let CEF's genuine
    // WebView/FocusManager path select the native document responder instead.
    browser.setFocus(true)
    trace("after")
  }
  public func find(_ text: String, forward: Bool = true, findNext: Bool = true) {
    browser?.find(text, forward: forward, matchCase: false,
      findNext: findNext && text == lastFindQuery)
    lastFindQuery = text
  }
  public func zoom(by amount: Double) { if let browser { browser.zoomLevel += amount } }
  public func resetZoom() { browser?.zoomLevel = 0 }
  public func printPage() { browser?.printPage() }
  public func showDevTools() { browser?.showDevTools() }
  @discardableResult public func showExtensionsMenu() -> Bool {
    browser?.executeChromeCommand(named: "IDC_EXTENSIONS_SUBMENU") ?? false
  }
  @discardableResult public func manageExtensions() -> Bool {
    browser?.executeChromeCommand(named: "IDC_MANAGE_EXTENSIONS") ?? false
  }

  public func browser(_ b: CefBrowser, didChangeTitle title: String) {
    self.title = title
    onTitleChanged?(title)
    onChange?()
  }
  public func browser(_ b: CefBrowser, didCommitNavigation url: URL) {
    guard browser === b else { return }
    onCommittedNavigation?(url)
  }
  public func browser(_ b: CefBrowser, didChangeURL url: URL?) {
    if self.url != url {
      cancelAuthentication()
      faviconURL = nil
      faviconDocumentURL = nil
    }
    self.url = url
    // Error pages may commit their URL after on_load_error. Keep the failure
    // until a genuine subsequent main-frame navigation begins.
    onChange?()
  }
  public func browser(
    _ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool
  ) {
    if isLoading && !self.isLoading {
      faviconURL = nil
      faviconDocumentURL = nil
    }
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    onChange?()
  }
  public func browser(_ b: CefBrowser, didChangeProgress progress: Double) {
    self.progress = progress
    onChange?()
  }
  public func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {
    faviconURL = urls.first
    faviconDocumentURL = urls.isEmpty ? nil : b.url
    onChange?()
  }
  public func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String)
  {
    if code != -3 {
      let message = errorText.isEmpty ? "This page could not be loaded." : String(errorText.prefix(2000))
      error = message
      documentError = ChromiumDocumentError(url: URL(string: failedURL) ?? url, code: code, message: message)
      onChange?()
    }
  }
  public func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest)
    -> CefWindowOpenAction
  {
    let blank = request.targetURL == nil || request.targetURL?.absoluteString == "about:blank"
    guard blank || request.targetURL.map(allowedNewDocumentURL) == true else { return .deny }
    let now = Date()
    popupTimes.removeAll { now.timeIntervalSince($0) >= 1 }
    guard popupTimes.count < 4 else { return .deny }
    popupTimes.append(now)
    if request.disposition == .newWindow, request.userGesture, let url = request.targetURL,
      NSEvent.modifierFlags.contains(.shift), let onPeek { onPeek(url, nil); return .handled }
    // Never replace a Chromium-created popup with a GET of its URL: the live
    // document carries POST bodies, named-window identity and its opener.
    return onPopupCreated != nil || canAdoptPopupInternally?() == true ? .allowNativePopup : .deny
  }
  private static func webURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false && url.user == nil && url.password == nil
  }
  private func allowedNewDocumentURL(_ target: URL) -> Bool {
    if Self.webURL(target) { return true }
    guard target.scheme == "chrome-extension", target.user == nil, target.password == nil,
      let identifier = target.host, identifier.count == 32,
      identifier.utf8.allSatisfy({ (97...112).contains($0) }) else { return false }
    // A committed extension document is already authorized by Chromium for
    // this request context. Other extensions require a native registry snapshot.
    return (url?.scheme == "chrome-extension" && url?.host == identifier)
      || (url?.scheme == "chrome" && url?.host == "extensions")
      || authorizeExtensionURL?(target) == true
  }
  public func browser(_ b: CefBrowser, didRequestNewTab url: URL?) -> Bool {
    browser(b, didRequestNewTab: url, disposition: .newForegroundTab, userGesture: true)
  }
  public func browser(_ b: CefBrowser, didRequestNewTab url: URL?, disposition: CefWindowOpenDisposition, userGesture: Bool) -> Bool {
    guard let url, allowedNewDocumentURL(url) else { return true }
    if disposition == .newWindow, userGesture, NSEvent.modifierFlags.contains(.shift), let onPeek { onPeek(url, nil); return true }
    if let onOpenURL { onOpenURL(url, disposition.prefersForeground); return true }
    return openURLInternally?(url, disposition.prefersForeground) ?? false
  }
  public func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?, isMainFrame: Bool, isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision {
    guard isMainFrame else { return .allow }
    guard let url else { return .cancel }
    func allowMainFrameNavigation() -> CefNavigationDecision {
      if documentError != nil || error != nil {
        documentError = nil; error = nil; onChange?()
      }
      return .allow
    }
    if Self.webURL(url) || url.absoluteString == "about:blank" || approvedNavigationURLs.contains(Self.navigationKey(url)) { return allowMainFrameNavigation() }
    if url.scheme == "chrome", (id.hasPrefix("extensions:") || id.hasPrefix("extension-settings:")),
      url.host == "extensions" { return allowMainFrameNavigation() }
    // Chromium still validates extension resource ownership and web-accessible
    // resources. No privileged native bridge exists in this document.
    if url.scheme == "chrome-extension", let host = url.host,
      host.count == 32, host.utf8.allSatisfy({ (97...112).contains($0) }) { return allowMainFrameNavigation() }
    return .cancel
  }
  public func browserDidClose(_ b: CefBrowser) {
    onJavaScriptDialogReset?()
    creationFailed = b.creationFailed
    documentObservation?.cancel(); documentObservation = nil
    if let documentEventToken { b.devTools.removeEventObserver(documentEventToken) }
    documentEventToken = nil
    cancelAuthentication()
    closedForTermination = b.closingForTermination
    chrome?.detachClosedPage()
    chrome = nil
    onClosedInternal?()
    onClosed?()
  }
  public func browser(
    _ b: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams
  ) {
    // Chrome's window/profile/tab commands bypass Zacro's logical models.
    // Replace only the known commands, preserving spellcheck and extensions.
    for name in ["IDC_CONTENT_CONTEXT_OPENLINKNEWTAB", "IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW",
      "IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD", "IDC_CONTENT_CONTEXT_OPENLINKINPROFILE",
      "IDC_CONTENT_CONTEXT_OPENLINKBOOKMARKAPP", "IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW",
      "IDC_CONTENT_CONTEXT_OPENLINK_ISOLATED", "IDC_CONTENT_CONTEXT_COPYLINKLOCATION",
      "IDC_CONTENT_CONTEXT_SEARCHWEBFOR", "IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB",
      "IDC_CONTENT_CONTEXT_GOTOURL", "IDC_CONTENT_CONTEXT_INSPECTELEMENT",
      "IDC_CONTENT_CONTEXT_INSPECTELEMENT_WITH_DEVTOOLS"] {
      menu.removeChromeCommand(named: name)
    }
    let links = ChromiumPageContextMenuPolicy.linkCommands(params)
    if !links.isEmpty {
      for (index, command) in links.enumerated() {
        menu.insertItem(at: index, commandID: command.commandID, title: command.title)
      }
      menu.insertSeparator(at: links.count)
    }
    if !params.selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !params.isEditable {
      menu.addItem(commandID: CefMenuModel.userCommandIDFirst + 4, title: "Search selection")
    }
    if params.mediaType == .image, params.hasImageContents {
      // Chrome's native context command copies the decoded image (including
      // cross-origin images); preserving it avoids a page script clipboard shim.
      for index in 0..<menu.count where menu.label(at: index).lowercased() == "copy image" {
        menu.setTitle(at: index, title: "Copy image")
      }
    }
    menu.addSeparator()
    menu.addItem(commandID: CefMenuModel.userCommandIDFirst + 5, title: b.isAudioMuted ? "Unmute tab" : "Mute tab")
    menu.addItem(commandID: CefMenuModel.userCommandIDFirst + 6, title: "Inspect element")
    menu.compactSeparators()
  }
  public func browser(
    _ b: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams
  ) -> Bool {
    switch commandID - CefMenuModel.userCommandIDFirst {
    case 0, 1, 2, 3:
      guard let url = ChromiumPageContextMenuPolicy.webLink(params) else { return true }
      switch commandID - CefMenuModel.userCommandIDFirst {
      case 0: onPeek?(url, ChromiumPageContextMenuPolicy.invocationPoint(params))
      case 1: onOpenURL?(url, true)
      case 2: onOpenURL?(url, false)
      default: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
      }
    case 4: onSearchSelection?(String(params.selectionText.prefix(2_000)))
    case 5: b.isAudioMuted.toggle(); onMutedChanged?(b.isAudioMuted)
    case 6: b.showDevTools(inspecting: CGPoint(x: params.x, y: params.y))
    default: return false
    }
    return true
  }
  public func browserDidGainFocus(_ b: CefBrowser) { onFocusedInternal?(); onFocused?() }
  public func browser(_ b: CefBrowser, didChangeStatusMessage message: String) { onStatusText?(message) }
  public func browser(_ b: CefBrowser, didReceiveAuthChallenge challenge: CefAuthChallenge, callback: CefAuthCallback) -> Bool {
    guard authentication == nil, let origin = URL(string: challenge.origin), Self.webURL(origin),
      let window = chrome?.nsWindow?.parent ?? chrome?.nsWindow else { callback.cancel(); return true }
    let id = UUID(), alert = NSAlert()
    alert.messageText = "Sign in to \(challenge.isProxy ? "proxy " : "")\(challenge.host)"
    alert.informativeText = challenge.realm.isEmpty ? challenge.origin : "\(challenge.origin)\n\(String(challenge.realm.prefix(300)))"
    let username = NSTextField(), password = NSSecureTextField()
    username.placeholderString = "Username"; password.placeholderString = "Password"
    let fields = NSStackView(views: [username, password]); fields.orientation = .vertical; fields.spacing = 10
    fields.frame = CGRect(x: 0, y: 0, width: 300, height: 58)
    fields.alignment = .leading
    username.widthAnchor.constraint(equalToConstant: 300).isActive = true
    password.widthAnchor.constraint(equalToConstant: 300).isActive = true
    alert.accessoryView = fields; alert.addButton(withTitle: "Sign in"); alert.addButton(withTitle: "Cancel")
    authentication = (id, url, callback, alert)
    alert.beginSheetModal(for: window) { [weak self, weak b] response in
      guard let self, let pending = self.authentication, pending.0 == id else { callback.cancel(); return }
      self.authentication = nil
      guard response == .alertFirstButtonReturn, b === self.browser, self.url == pending.1 else { callback.cancel(); return }
      callback.continue(username: username.stringValue, password: password.stringValue)
      password.stringValue = ""
    }
    return true
  }
  private func cancelAuthentication() {
    guard let pending = authentication else { return }
    authentication = nil; pending.2.cancel()
    pending.3.window.sheetParent?.endSheet(pending.3.window, returnCode: .cancel)
  }
  public func browser(
    _ b: CefBrowser, decidePolicyForDownload download: CefDownload, suggestedName: String
  ) -> CefDownloadDecision {
    if let onDownloadDecision { return onDownloadDecision(download, suggestedName) }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = URL(fileURLWithPath: suggestedName).lastPathComponent
    guard panel.runModal() == .OK, let destination = panel.url else { return .deny }
    return .allow(destination: destination)
  }
  public func browser(_ b: CefBrowser, downloadDidProgress download: CefDownload) {
    onDownload?(download)
  }
  public func browser(_ b: CefBrowser, requestsPermission request: CefPermissionRequest)
    -> CefPermissionDecision
  {
    if request.kinds.contains(.screenCapture) || request.kinds.contains(.systemAudioCapture) ||
      URL(string: request.origin)?.scheme?.lowercased() == "chrome-extension" {
      return .useDefault
    }
    if let onPermission { return onPermission(request) }
    return .deny
  }
  public func browser(_ b: CefBrowser, runJSDialog dialog: CefJSDialog,
                      callback: CefJSDialogCallback) -> Bool {
    guard browser === b else { callback.cancel(); return true }
    if let onJavaScriptDialog { onJavaScriptDialog(dialog, callback) }
    else { callback.cancel() }
    return true
  }
  public func browser(_ b: CefBrowser, runBeforeUnloadDialog message: String,
                      isReload: Bool, callback: CefJSDialogCallback) -> Bool {
    guard browser === b else { callback.cancel(); return true }
    if let onBeforeUnloadDialog { onBeforeUnloadDialog(message, isReload, callback) }
    else { callback.cancel() }
    return true
  }
  public func browserResetJavaScriptDialog(_ b: CefBrowser) {
    guard browser === b else { return }
    onJavaScriptDialogReset?()
  }
  public func browser(_ b: CefBrowser, requestsPermission request: CefPermissionRequest,
                      callback: CefPermissionCallback) -> Bool {
    if request.kinds.contains(.screenCapture) || request.kinds.contains(.systemAudioCapture)
      || URL(string: request.origin)?.scheme?.lowercased() == "chrome-extension" { return false }
    if let onPermissionRequest { return onPermissionRequest(request, callback) }
    let choice = browser(b, requestsPermission: request)
    guard choice != .useDefault else { return false }
    callback.resolve(choice); return true
  }
  public func browser(_ b: CefBrowser, dismissedPermission requestID: UUID) {
    onPermissionDismissed?(requestID)
  }
  public func browser(
    _ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int
  ) {
    let message = "This page stopped responding. Reload to continue."
    error = message
    documentError = ChromiumDocumentError(url: url, code: errorCode, message: message, isRendererTermination: true)
    onChange?()
  }
}

extension ChromiumEngine {
  /// Hidden native transport for bundled component APIs in an ephemeral
  /// profile. It never loads the extension manager or a persistent profile.
  func privateComponentsPage(profileID: String) -> ChromiumPage {
    let identifier = "private-components:\(profileID)"
    if let existing = pages[identifier] { return existing }
    return page(id: identifier, profileID: profileID, isPrivate: true,
      url: URL(string: "about:blank")!, ownerWindowID: nil)
  }

  /// Chromium's real extension manager, including unpacked install, enable,
  /// disable and removal. It runs inside the selected profile's Chrome runtime.
  public func extensionsPage(profileID: String) -> ChromiumPage {
    if let existing = pages["extensions:\(profileID)"] { return existing }
    let page = page(
      id: "extensions:\(profileID)", profileID: profileID, isPrivate: false,
      url: URL(string: "chrome://extensions/")!, ownerWindowID: nil)
    return page
  }

}
