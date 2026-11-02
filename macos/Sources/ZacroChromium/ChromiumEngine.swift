import AppKit
@_exported import CefKit
import CryptoKit
import Foundation

/// Owns the Chromium runtime and native Chrome-style window. Never uses Alloy.
@MainActor
public final class ChromiumEngine: NSObject, NSWindowDelegate {
  public let dataDirectory: URL
  public private(set) var pages: [String: ChromiumPage] = [:]
  private var profiles: [String: CefProfile] = [:]
  private var extensionAccess: [String: Set<String>] = [:]
  private var privateExtensionAccess: [String: Set<String>] = [:]
  private var downloadControls: [String: CefDownloadControl] = [:]
  private var retiredProfiles: Set<String> = []
  private var shuttingDown = false
  private var host: CefChromeBrowser?
  private var capabilities: CefNativeCapabilities?
  private var unsupportedNativeCapabilities = false
  private var capabilityProbe: Task<CefNativeCapabilities, Error>?
  private var capabilityProbeID: UUID?
  private var nativeWindow: NSWindow?
  public var window: NSWindow? { nativeWindow }
  public var onLayout: (() -> Void)?
  public private(set) var isTerminating = false
  public var onTerminationChanged: ((Bool) -> Void)?
  public var beforeTermination: (() async -> Void)?
  public var beforeClosingDocuments: (() async -> Bool)?
  private var closingPreparation: Task<Bool, Never>?
  private var terminationDrainStarted = false
  public var onDownload: ((String, Bool, CefDownload) -> Void)?
  public private(set) var isWindowClosing = false
  public private(set) var isWindowOpen = true
  public var onWindowClosed: (() -> Void)?
  public var onWindowCloseCancelled: (() -> Void)?

  public init(dataDirectory: URL) {
    self.dataDirectory = dataDirectory
    super.init()
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
    // Stock CEF's per-document AX state can be lost when retained native
    // windows change visibility. Keep real renderer accessibility enabled
    // until the custom scoped accessibility lease is packaged and verified.
    configuration.extraCommandLineSwitches.updateValue(nil, forKey: "force-renderer-accessibility")
    configuration.defaultRuntimeStyle = .chrome
    configuration.logFile = dataDirectory.appendingPathComponent("chromium.log")
    try CefRuntime.shared.initialize(configuration: configuration)
    CefRuntime.shared.onTerminationChanged = { [weak self] terminating in
      self?.isTerminating = terminating
      if !terminating, self?.isWindowClosing == true { self?.cancelWindowClose(vetoedBy: nil) }
      self?.onTerminationChanged?(terminating)
    }
    CefRuntime.shared.beforeClosingDocuments = { [weak self] in
      await self?.prepareToCloseDocuments() ?? true
    }
    CefRuntime.shared.onReadyToTerminate = { [weak self] in
      guard let self, !self.terminationDrainStarted else { return }
      self.terminationDrainStarted = true
      Task { @MainActor in
        // Documents have accepted unload. Finish provider/credential/storage
        // work while AppKit's run loop can still deliver its completions.
        await self.beforeTermination?()
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
    let nativeWindow = NSWindow(
      contentRect: CGRect(x: 80, y: 80, width: 1280, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    nativeWindow.title = "Zacro"
    nativeWindow.titleVisibility = .hidden
    nativeWindow.titlebarAppearsTransparent = true
    nativeWindow.isReleasedWhenClosed = false
    nativeWindow.minSize = NSSize(width: 680, height: 480)
    nativeWindow.collectionBehavior.insert(.fullScreenPrimary)
    nativeWindow.delegate = self
    self.nativeWindow = nativeWindow
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
    if let page = pages[id] {
      precondition(
        page.profileID == profileID && page.isPrivate == isPrivate,
        "Cannot move a live page across profiles")
      return page
    }
    precondition(host != nil, "Start Chromium before creating pages")
    precondition(nativeReservation == nil || (!isPrivate && nativeReservation?.profileID == profileID && nativeReservation?.logicalID == id),
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
    page.reservedNativeTabID = nativeReservation?.nativeID
    let chrome = host!.createPage(
      url: url, profile: profile, delegate: page, hostingWindow: nativeWindow,
      nativeTabReservation: nativeReservation?.token)
    attach(page, chrome: chrome)
    return page
  }

  private func attach(_ page: ChromiumPage, chrome: CefChromeBrowser) {
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
    page.observeDocumentState()
    chrome.beforeClose = { [weak self, weak page] in
      guard let self, let page else { return true }
      if self.isTerminating || self.isWindowClosing { return true }
      return await page.beforeClose?() ?? true
    }
    chrome.browser.onCloseCancelled = { [weak self, weak page] in
      page?.chrome?.cancelPreparedClose()
      self?.cancelWindowClose(vetoedBy: page)
      page?.onCloseCancelled?()
    }
    page.onClosedInternal = { [weak self, weak page] in
      guard let self, let page else { return }
      if self.pages[page.id] === page { self.pages.removeValue(forKey: page.id) }
      self.finishWindowCloseIfReady()
    }
    pages[page.id] = page
    chrome.onPopupCreated = { [weak self, weak page] child, request in
      guard let self, let page, self.pages[page.id] === page, !self.isTerminating, !self.isWindowClosing else {
        child.close(); return
      }
      let popup = ChromiumPage(id: "popup-" + UUID().uuidString, profileID: page.profileID, isPrivate: page.isPrivate)
      popup.openerID = page.id
      child.browser.delegate = popup
      self.attach(popup, chrome: child)
      if let callback = page.onPopupCreated { callback(popup, request.disposition.prefersForeground) }
      else { popup.close() }
    }
  }

  public func hideAll() { for page in pages.values { page.hide() } }
  func updateExtensionAccess(_ snapshot: ChromeExtensionSnapshot, profileID: String) {
    extensionAccess[profileID] = Set(snapshot.extensions.filter(\.isEnabled).map(\.id))
    privateExtensionAccess[profileID] = Set(snapshot.extensions.filter { $0.isEnabled && $0.incognitoAccess.isActive }.map(\.id))
  }
  public func clearNetworkData(profileID: String, isPrivate: Bool, selected: CefNetworkData = .all) async throws {
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    let profile: CefProfile
    if let existing = profiles[key] { profile = existing }
    else {
      let safeID = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
      profile = isPrivate ? .incognito() : .persistent(name: safeID)
      profiles[key] = profile
    }
    try await profile.clearNetworkData(selected)
  }
  /// Reparents the same retained Chromium document when promoting a Peek.
  /// Callers reconnect their model callbacks to the new tab identifier.
  @discardableResult public func adoptPage(fromID: String, toID: String) -> ChromiumPage? {
    guard fromID != toID, !toID.isEmpty, pages[toID] == nil,
      let page = pages.removeValue(forKey: fromID) else { return nil }
    page.id = toID
    pages[toID] = page
    return page
  }
  public func close(id: String) { pages[id]?.close() }
  public func releasePrivateProfile(_ profileID: String) throws {
    guard !pages.values.contains(where: { $0.profileID == profileID && $0.isPrivate }) else {
      throw CefDevToolsError.rejected("Close the private profile's documents before releasing it.")
    }
    profiles.removeValue(forKey: "private:" + profileID)
    privateExtensionAccess.removeValue(forKey: profileID)
    for key in downloadControls.keys.filter({ $0.hasPrefix(profileID + ":") }) {
      if let control = downloadControls.removeValue(forKey: key) { _ = control.cancel(); control.invalidate() }
    }
  }
  /// Removes runtime ownership only after all documents have accepted close.
  /// Chromium owns profile databases until shutdown; deletion is journaled and
  /// completed with no live Chromium context, including after an interrupted quit.
  public func retireProfile(_ profileID: String) throws {
    guard !pages.values.contains(where: { $0.profileID == profileID }) else {
      throw NSError(domain: "ZacroEngine", code: 2, userInfo: [NSLocalizedDescriptionKey:
        "Close this profile's documents before deleting it."])
    }
    retiredProfiles.insert(profileID)
    try JSONEncoder().encode(Array(retiredProfiles)).write(to: retirementJournal, options: .atomic)
    profiles.removeValue(forKey: "persistent:" + profileID)
    profiles.removeValue(forKey: "private:" + profileID)
    extensionAccess.removeValue(forKey: profileID)
    privateExtensionAccess.removeValue(forKey: profileID)
    for key in downloadControls.keys.filter({ $0.hasPrefix(profileID + ":") }) {
      if let control = downloadControls.removeValue(forKey: key) { _ = control.cancel(); control.invalidate() }
    }
  }

  private var retirementJournal: URL { dataDirectory.appendingPathComponent("retired-chromium-profiles.json") }
  private func removeRetiredProfileData() throws {
    if FileManager.default.fileExists(atPath: retirementJournal.path) {
      retiredProfiles.formUnion(try JSONDecoder().decode([String].self, from: Data(contentsOf: retirementJournal)))
    }
    let root = dataDirectory.appendingPathComponent("Chromium", isDirectory: true)
    for identifier in retiredProfiles {
      let safeID = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
      let directory = root.appendingPathComponent(safeID, isDirectory: true)
      if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    if FileManager.default.fileExists(atPath: retirementJournal.path) { try FileManager.default.removeItem(at: retirementJournal) }
    retiredProfiles.removeAll()
  }
  public func showWindow() {
    guard !isWindowClosing else { return }
    isWindowOpen = true
    nativeWindow?.makeKeyAndOrderFront(nil)
  }
  /// Chromium asks every document about unsaved changes before closing.
  public func closeWindow() {
    guard isWindowOpen, !isWindowClosing, !isTerminating else { return }
    isWindowClosing = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let accepted = await self.prepareToCloseDocuments()
      guard self.isWindowClosing, !self.isTerminating else { return }
      guard accepted else { self.cancelWindowClose(vetoedBy: nil); return }
      self.closeWindowDocuments()
    }
  }

  private func prepareToCloseDocuments() async -> Bool {
    if let closingPreparation { return await closingPreparation.value }
    let task = Task { @MainActor [weak self] in await self?.beforeClosingDocuments?() ?? true }
    closingPreparation = task
    let accepted = await task.value
    closingPreparation = nil
    return accepted
  }

  private func closeWindowDocuments() {
    for page in Array(pages.values) {
      if page.id.hasPrefix("extensions:") && !page.isPrivate { page.hide(); continue }
      page.closedForWindow = true
      page.close()
    }
    finishWindowCloseIfReady()
  }

  private func cancelWindowClose(vetoedBy page: ChromiumPage?) {
    page?.closedForWindow = false
    guard isWindowClosing else { return }
    isWindowClosing = false
    // Other documents may already have accepted close. Keep their origin flag
    // until didClose so the host retains their model for window restoration.
    onWindowCloseCancelled?()
  }

  private func finishWindowCloseIfReady() {
    guard isWindowClosing, closingPreparation == nil, hasNoWindowDocuments else { return }
    // Let CEF finish native child-window destruction before hiding the shell.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isWindowClosing, self.hasNoWindowDocuments else { return }
      self.isWindowClosing = false
      self.isWindowOpen = false
      self.nativeWindow?.orderOut(nil)
      let privateKeys = self.profiles.keys.filter { $0.hasPrefix("private:") }
      for key in privateKeys { self.profiles.removeValue(forKey: key) }
      self.onWindowClosed?()
    }
  }

  private var hasNoWindowDocuments: Bool {
    !pages.values.contains { !$0.id.hasPrefix("extensions:") || $0.isPrivate }
  }

  public func windowShouldClose(_ sender: NSWindow) -> Bool {
    closeWindow()
    return false
  }
  public func windowDidResize(_ notification: Notification) { onLayout?() }

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
    for control in downloadControls.values { control.invalidate() }
    downloadControls.removeAll()
    nativeWindow?.delegate = nil
    nativeWindow?.orderOut(nil)
    nativeWindow?.contentView = nil
    nativeWindow = nil
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
  fileprivate var chrome: CefChromeBrowser?
  fileprivate var onClosedInternal: (() -> Void)?
  fileprivate var authorizeExtensionURL: ((URL) -> Bool)?
  public var browser: CefBrowser? { chrome?.browser }
  public var nativeWindow: NSWindow? { chrome?.nsWindow }
  public private(set) var title = ""
  public private(set) var url: URL?
  public private(set) var isLoading = false
  public private(set) var isAudible = false
  private var documentEventToken: UUID?
  private var documentObservation: Task<Void, Never>?
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var progress = 0.0
  public private(set) var error: String?
  public private(set) var faviconURL: URL?
  /// The committed document that supplied `faviconURL`; never the pinned home URL.
  public private(set) var faviconDocumentURL: URL?
  public fileprivate(set) var reservedNativeTabID: Int?
  public var onChange: (() -> Void)?
  public var onOpenURL: ((URL, Bool) -> Void)?
  public var onPeek: ((URL) -> Void)?
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
  public var onClosed: (() -> Void)?
  public private(set) var closedForTermination = false
  public fileprivate(set) var closedForWindow = false
  public var onFindResult: ((Int, Int, Bool) -> Void)? {
    get { browser?.onFindResult }
    set { browser?.onFindResult = newValue }
  }
  private var lastFindQuery = ""

  fileprivate func adoptCurrentDocumentState() {
    guard let browser else { return }
    title = browser.title
    url = browser.url
    isLoading = browser.isLoading
    canGoBack = browser.canGoBack
    canGoForward = browser.canGoForward
  }

  fileprivate func observeDocumentState() {
    documentObservation?.cancel()
    documentObservation = Task { [weak self] in
      guard let self else { return }
      do {
        let browser = try await ready()
        try Task.checkCancellation()
        let token = try browser.devTools.observeEvents { [weak self] method, params in
          guard let self, method == "Zacro.documentAudioChanged", let audible = params["audible"] as? Bool else { return }
          self.isAudible = audible; self.onChange?()
        }
        documentEventToken = token
        do {
          let state = try await browser.devTools.call("Zacro.observeDocument", parameters: ["enabled": true])
          guard !Task.isCancelled, self.browser === browser else { return }
          if let audible = state["audible"] as? Bool { isAudible = audible; onChange?() }
        } catch {
          browser.devTools.removeEventObserver(token); documentEventToken = nil
        }
      } catch { /* Native creation or shutdown ended observation. */ }
    }
  }

  fileprivate init(id: String, profileID: String, isPrivate: Bool) {
    self.id = id
    self.profileID = profileID
    self.isPrivate = isPrivate
  }
  public func load(_ url: URL) { browser?.load(url) }
  public func ready() async throws -> CefBrowser {
    guard let browser else { throw CefDevToolsError.browserClosed }
    try await browser.waitUntilReady()
    guard self.browser === browser else { throw CefDevToolsError.browserClosed }
    return browser
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
    view.window?.makeKey()
    view.window?.makeFirstResponder(view)
    browser.setFocus(true)
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
    onChange?()
  }
  public func browser(_ b: CefBrowser, didChangeURL url: URL?) {
    if self.url != url {
      cancelAuthentication()
      faviconURL = nil
      faviconDocumentURL = nil
    }
    self.url = url
    error = nil
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
      error = errorText
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
      NSEvent.modifierFlags.contains(.shift), let onPeek { onPeek(url); return .handled }
    // Never replace a Chromium-created popup with a GET of its URL: the live
    // document carries POST bodies, named-window identity and its opener.
    return onPopupCreated == nil ? .deny : .allowNativePopup
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
      || authorizeExtensionURL?(target) == true
  }
  public func browser(_ b: CefBrowser, didRequestNewTab url: URL?) -> Bool {
    browser(b, didRequestNewTab: url, disposition: .newForegroundTab, userGesture: true)
  }
  public func browser(_ b: CefBrowser, didRequestNewTab url: URL?, disposition: CefWindowOpenDisposition, userGesture: Bool) -> Bool {
    guard let url, allowedNewDocumentURL(url) else { return true }
    if disposition == .newWindow, userGesture, NSEvent.modifierFlags.contains(.shift), let onPeek { onPeek(url); return true }
    guard let onOpenURL else { return false }
    onOpenURL(url, disposition.prefersForeground)
    return true
  }
  public func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?, isMainFrame: Bool, isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision {
    guard isMainFrame else { return .allow }
    guard let url else { return .cancel }
    if Self.webURL(url) || url.absoluteString == "about:blank" { return .allow }
    if url.scheme == "chrome", id.hasPrefix("extensions:"), url.host == "extensions" { return .allow }
    // Chromium still validates extension resource ownership and web-accessible
    // resources. No privileged native bridge exists in this document.
    if url.scheme == "chrome-extension", let host = url.host,
      host.count == 32, host.utf8.allSatisfy({ (97...112).contains($0) }) { return .allow }
    return .cancel
  }
  public func browserDidClose(_ b: CefBrowser) {
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
    if params.linkURL != nil {
      menu.insertItem(at: 0, commandID: CefMenuModel.userCommandIDFirst, title: "Peek at link")
      menu.insertItem(at: 1, commandID: CefMenuModel.userCommandIDFirst + 1, title: "Open link in new tab")
      menu.insertItem(at: 2, commandID: CefMenuModel.userCommandIDFirst + 2, title: "Open link in background")
      menu.insertItem(at: 3, commandID: CefMenuModel.userCommandIDFirst + 3, title: "Copy link address")
      menu.insertSeparator(at: 4)
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
      guard let url = params.linkURL, Self.webURL(url) else { return true }
      switch commandID - CefMenuModel.userCommandIDFirst {
      case 0: onPeek?(url)
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
  public func browserDidGainFocus(_ b: CefBrowser) { onFocused?() }
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
    if let onPermission { return onPermission(request) }
    guard let origin = URL(string: request.origin),
      ["https", "http"].contains(origin.scheme?.lowercased() ?? ""),
      !request.kinds.contains(.other)
    else { return .deny }
    let names: [(CefPermissionKind, String)] = [
      (.camera, "camera"), (.microphone, "microphone"), (.geolocation, "location"),
      (.notifications, "notifications"), (.clipboard, "clipboard"), (.midi, "MIDI devices"),
      (.pointerLock, "pointer lock"), (.storageAccess, "site storage"), (.sensors, "sensors"),
      (.windowManagement, "window management"), (.downloads, "multiple downloads"),
    ]
    let requested = names.filter { request.kinds.contains($0.0) }.map { $0.1 }.joined(
      separator: ", ")
    let alert = NSAlert()
    alert.messageText = "Allow \(origin.host ?? request.origin) to use \(requested)?"
    alert.informativeText = "This decision applies to this request in the current browser profile."
    alert.addButton(withTitle: "Don’t Allow")
    alert.addButton(withTitle: "Allow")
    return alert.runModal() == .alertSecondButtonReturn ? .allow : .deny
  }
  public func browser(
    _ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int
  ) {
    error = "This page stopped responding. Reload to continue."
    onChange?()
  }
}

extension ChromiumEngine {
  /// Chromium's real extension manager, including unpacked install, enable,
  /// disable and removal. It runs inside the selected profile's Chrome runtime.
  public func extensionsPage(profileID: String) -> ChromiumPage {
    if let existing = pages["extensions:\(profileID)"] { return existing }
    let page = page(
      id: "extensions:\(profileID)", profileID: profileID, isPrivate: false,
      url: URL(string: "chrome://extensions/")!)
    return page
  }

  public func extensionStorePage(profileID: String) -> ChromiumPage {
    page(
      id: "extension-store:\(profileID)", profileID: profileID, isPrivate: false,
      url: URL(string: "https://chromewebstore.google.com/")!)
  }
}
