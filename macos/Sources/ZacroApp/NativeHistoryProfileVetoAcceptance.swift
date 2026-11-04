import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// A real Delete Profile / Stay cycle must reconnect history observation after
/// the original hidden broker closes. No manual mirror refresh can satisfy the
/// post-veto deletion proof; only the new observer's ordinary event path can.
@MainActor enum NativeHistoryProfileVetoAcceptance {
  @MainActor private final class ObservationReceipt {
    var count = 0
    var completedDrains = 0
    weak var page: ChromiumPage?
    weak var browser: CefBrowser?
  }

  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, application.supportsHistoryMirror,
      application.deletingProfileID == nil, application.pendingDeletion == nil,
      originalOwner.windowContext.isOpen, !originalOwner.windowContext.isClosing,
      originalOwner.store.state.activeProfile?.isPrivate == false,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil else {
      throw ShortcutError("History profile-veto acceptance requires the disposable custom-runtime public loopback owner.")
    }
    let engine = application.engine
    let originalWindows = Set(application.windows.keys)
    let originalSurvivors = engine.pages.values.filter {
      $0.ownerWindowID == originalOwner.windowContext.id && !$0.isPrivate && $0.browser?.isClosed == false
    }.map { (page: $0, browser: $0.browser!, address: $0.url, nativeID: $0.reservedNativeTabID) }
    guard !originalSurvivors.isEmpty else { throw ShortcutError("Keep an actual original native document for the profile-veto isolation proof.") }
    let directory = engine.dataDirectory.appendingPathComponent("AcceptanceHistoryProfileVeto-" + UUID().uuidString)
    var owner: BrowserWindowCoordinator?
    var profileID: String?
    var source: ChromiumPage?
    var sourceBrowser: CefBrowser?
    var manager: ChromeExtensionManager?
    var oldWorker: ChromeExtensionWorkerSession?
    var freshWorker: ChromeExtensionWorkerSession?
    let observed = ObservationReceipt()
    let priorObservation = application.extensionSync.nativeObservationReady
    let priorHistoryStatus = application.historyMirror.onStatus
    var interceptingObservation = false
    var checks: [String] = []

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native history profile-veto check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("History profile-veto acceptance failed: " + name) }
      checks.append(name)
    }
    func ownedSheet() -> NSWindow? {
      guard let owner, let source, let sheet = owner.windowContext.window.attachedSheet,
        sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:beforeunload:") == true,
        application.webDialogs.owns(sheet, page: source) else { return nil }
      return sheet
    }
    func restoreObservation() {
      guard interceptingObservation else { return }
      application.extensionSync.nativeObservationReady = priorObservation
      application.historyMirror.onStatus = priorHistoryStatus
      interceptingObservation = false
    }
    func cleanup() async throws {
      restoreObservation()
      var failure: Error?
      // Never dismiss a different security sheet or interpret owner loss as
      // approval. A failed fixture first settles its exact pending attempt.
      if let sheet = ownedSheet(), let owner {
        owner.windowContext.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      }
      if let profileID, application.deletingProfileID == profileID {
        do { try await wait("owned veto operation settles before cleanup") {
          application.deletingProfileID != profileID
        } } catch { failure = error }
      }
      if let source, let sourceBrowser, source.browser === sourceBrowser, !sourceBrowser.isClosed,
        source.url?.scheme == "http", source.url?.host == "127.0.0.1", source.url?.port == url.port {
        do { _ = try await sourceBrowser.devTools.evaluate("window.onbeforeunload=null;true") }
        catch { failure = failure ?? error }
      }
      await oldWorker?.close(); oldWorker = nil
      await freshWorker?.close(); freshWorker = nil
      if let profileID, let owner, application.store.state.profiles.contains(where: { $0.id == profileID }),
        application.deletingProfileID == nil {
        owner.actions.deleteProfile(profileID)
        do { try await wait("actual cleanup deletes only the owned public profile") {
          application.deletingProfileID == nil
            && !application.store.state.profiles.contains { $0.id == profileID }
            && !application.store.pendingNativeProfileRetirements.contains(profileID)
            && !engine.pages.values.contains { $0.profileID == profileID }
        } } catch { failure = failure ?? error }
      }
      await manager?.close()
      if let owner, owner.windowContext.isOpen, !(await owner.requestCloseWindow()) {
        failure = failure ?? ShortcutError("The owned profile-veto window did not accept normal cleanup.")
      }
      if let profileID, !application.store.state.profiles.contains(where: { $0.id == profileID }),
        !application.store.pendingNativeProfileRetirements.contains(profileID),
        !engine.pages.values.contains(where: { $0.profileID == profileID }) {
        try? FileManager.default.removeItem(at: directory)
      }
      if originalOwner.windowContext.isOpen {
        originalOwner.windowContext.show()
        application.repository.focusWindow(originalOwner.windowContext.id)
        application.extensionBrowser.windowFocusChanged()
      }
      if let failure { throw failure }
    }

    do {
      originalOwner.windowContext.show()
      application.repository.focusWindow(originalOwner.windowContext.id)
      application.newWindow()
      let added = application.windows.values.filter {
        !originalWindows.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
      }
      guard added.count == 1, let windowOwner = added.first else { throw ShortcutError("No exact new profile-veto fixture window.") }
      owner = windowOwner; windowOwner.actions.palette = false
      let profile = try windowOwner.store.createProfileDurably(name: "History observation veto fixture")
      profileID = profile.id
      guard !profile.isPrivate, profile.id != originalOwner.store.activeProfileID,
        windowOwner.store.activeProfileID == profile.id else { throw ShortcutError("The history-veto fixture did not get an isolated public profile.") }
      var address = URLComponents(url: url.appendingPathComponent("native-history-form"), resolvingAgainstBaseURL: false)!
      address.queryItems = [URLQueryItem(name: "history-veto", value: UUID().uuidString)]
      guard let boundURL = address.url,
        let tab = windowOwner.store.createTab(address: boundURL.absoluteString) else { throw ShortcutError("No exact history-veto loopback form.") }
      let page = try await windowOwner.ensurePageReady(tab)
      source = page
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready(); sourceBrowser = browser
      try await wait("actual owned form document") {
        guard !page.isLoading, page.url == boundURL, page.documentError == nil else { return false }
        return try await browser.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      // Setup only. No refresh/ensure is allowed after Delete Profile is invoked.
      try await application.extensionSync.ensureNativeObservation(profileID: profile.id)
      try await application.historyMirror.refresh(profileID: profile.id)
      let nativeHistory = try await page.historyMirrorSession()
      let descriptor: ChromeHistoryDocument
      do { descriptor = try await nativeHistory.document(page); await nativeHistory.close() }
      catch { await nativeHistory.close(); throw error }
      guard let eventID = descriptor.currentEventID else { throw ShortcutError("The actual form has no native history event identity.") }
      var binding: NativeHistoryBinding?
      try await wait("initial actual native/Core history binding") {
        binding = application.store.nativeHistoryBindings(profileID: profile.id).first {
          $0.eventID == eventID && $0.coreAddress == boundURL.absoluteString
        }
        return binding != nil
      }
      guard let binding else { throw ShortcutError("No initial bound Core Library visit.") }
      try require(descriptor.logicalID == tab.id && descriptor.ownerWindowID == windowOwner.windowContext.nativeID,
        "historyVetoStartsWithExactActualNativeDocumentAndLibraryBinding")

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let manifest: [String: Any] = ["manifest_version": 3, "name": "Owned history profile veto worker",
        "version": "1.0", "permissions": ["history"], "background": ["service_worker": "worker.js"]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
      try Data("chrome.runtime.onInstalled.addListener(()=>{});".utf8).write(to: directory.appendingPathComponent("worker.js"), options: .atomic)
      let extensionManager = ChromeExtensionManager(engine: engine, profileID: profile.id); manager = extensionManager
      try await extensionManager.setDeveloperMode(true)
      let identifier = try await extensionManager.loadUnpackedExtension(at: directory)
      let inspector = try await extensionManager.workerSession(identifier); oldWorker = inspector
      let beforeNativeVisits = try await inspector.evaluate("chrome.history.getVisits({url:\(try literal(boundURL.absoluteString))})") as? [[String: Any]] ?? []
      try require(beforeNativeVisits.contains { $0["visitId"] as? String == binding.identity.visitID },
        "historyVetoWorkerSeesTheExactBoundNativeVisit")
      let transportID = "extensions:" + profile.id
      guard let oldTransport = engine.pages[transportID], let oldBroker = oldTransport.browser,
        !oldBroker.isClosed, oldTransport.profileID == profile.id else {
        throw ShortcutError("No exact old native observation/worker transport.")
      }
      windowOwner.actions.palette = false
      windowOwner.windowContext.show()
      application.repository.focusWindow(windowOwner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
      let draft = "history observer survives actual profile veto " + UUID().uuidString
      _ = try await browser.devTools.evaluate("""
        (()=>{const field=document.getElementById('retained');field.value=\(try literal(draft));
          field.dispatchEvent(new Event('input',{bubbles:true}));field.dispatchEvent(new Event('change',{bubbles:true}));
          const button=document.createElement('button');button.id='historyVetoActivate';button.textContent='Edit';
          button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
          document.body.appendChild(button);window.onbeforeunload=event=>{event.preventDefault();event.returnValue='Owned unsaved draft';};return true;})()
        """)
      page.focus()
      try await wait("actual focused and hit-testable veto source") {
        guard windowOwner.activePage === page, page.browser === browser,
          page.nativeWindow?.isVisible == true else { return false }
        return try await browser.devTools.evaluate("document.hasFocus()&&document.elementFromPoint(60,36)?.id==='historyVetoActivate'") as? Bool == true
      }
      let activation = try await NativeDocumentActivationAcceptance.click(application: application,
        owner: windowOwner, page: page, buttonID: "historyVetoActivate", label: "history-profile-veto")
      try require(["trusted", "primary", "sticky", "focused", "guarded"].allSatisfy { activation[$0] as? Bool == true },
        "historyVetoUsesActuallyActivatedGuardedNativeForm")
      let navigationURLs = windowOwner.store.tab(tab.id)?.navigation.map(\.url)
      application.historyMirror.onStatus = { id, message in
        priorHistoryStatus?(id, message)
        if id == profile.id, observed.count > 0, message == nil { observed.completedDrains += 1 }
      }
      application.extensionSync.nativeObservationReady = { [weak application] id in
        priorObservation?(id)
        guard let application, id == profile.id else { return }
        observed.count += 1
        observed.page = application.engine.pages[transportID]
        observed.browser = observed.page?.browser
      }
      interceptingObservation = true
      windowOwner.actions.deleteProfile(profile.id)
      try await wait("old hidden broker closes while exact owned beforeunload sheet waits") {
        ownedSheet() != nil && oldBroker.isClosed && engine.pages[transportID] !== oldTransport
          && application.deletingProfileID == profile.id
      }
      try require(page.browser === browser && !browser.isClosed && application.store.state.profiles.contains { $0.id == profile.id }
        && application.store.state.history.contains { $0.id == binding.coreID }
        && observed.count == 0,
        "historyVetoClosesOldBrokerBeforeDecisionWithoutLosingHeldProfileOrVisit")
      guard let sheet = ownedSheet() else { throw ShortcutError("No exact owned profile-veto Stay sheet.") }
      windowOwner.windowContext.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      try await wait("Stay releases deletion lock and reconnects actual observation on a new transport") {
        guard application.deletingProfileID == nil, application.pendingDeletion == nil,
          application.webDialogs.pendingRequestCount(for: page) == 0,
          windowOwner.windowContext.window.attachedSheet == nil,
          observed.count > 0, observed.completedDrains > 0,
          let replacement = observed.page, let native = observed.browser else { return false }
        return replacement !== oldTransport && native !== oldBroker && !native.isClosed
          && engine.pages[transportID] === replacement && replacement.browser === native
          && replacement.profileID == profile.id && !replacement.isPrivate
      }
      let keptDraft = try await browser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(keptDraft == draft && page.browser === browser && !browser.isClosed
        && windowOwner.store.tab(tab.id)?.url == boundURL.absoluteString
        && windowOwner.store.tab(tab.id)?.navigation.map(\.url) == navigationURLs,
        "historyVetoStayPreservesExactDocumentDraftAndNavigation")
      try require(application.store.state.history.contains { $0.id == binding.coreID }
        && application.store.nativeHistoryBindings(profileID: profile.id).contains { $0 == binding },
        "historyVetoReconnectCompletesInitialAutomaticVerificationBeforeNativeDelete")
      await inspector.close(); oldWorker = nil
      let replacementManager = ChromeExtensionManager(engine: engine, profileID: profile.id)
      let replacementWorker = try await replacementManager.workerSession(identifier); freshWorker = replacementWorker
      try require(engine.pages[transportID] === observed.page && observed.browser?.isClosed == false,
        "historyVetoReattachesSameInstalledWorkerThroughObservedReplacementBroker")
      let deleted = try await replacementWorker.evaluate("""
        (async()=>{await chrome.history.deleteUrl({url:\(try literal(boundURL.absoluteString))});return true;})()
        """, timeout: 15)
      guard deleted as? Bool == true else { throw ShortcutError("The actual post-veto Chrome history deletion did not finish.") }
      // No mirror refresh, observation-ensure or navigation follows the API.
      // An ordinary native history notification must drive this Core removal.
      try await wait("new observer automatically removes the exact deleted Core Library row") {
        !application.store.state.history.contains { $0.id == binding.coreID }
          && !application.store.nativeHistoryBindings(profileID: profile.id).contains { $0.coreID == binding.coreID }
      }
      try require(application.store.state.profiles.contains { $0.id == profile.id }
        && windowOwner.store.tab(tab.id)?.isClosed == false && page.browser === browser && !browser.isClosed,
        "historyVetoFreshNativeNotificationRemovesLibraryVisitWithoutManualRefresh")
      let afterDeleteDraft = try await browser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(afterDeleteDraft == draft && originalSurvivors.allSatisfy {
        engine.pages[$0.page.id] === $0.page && $0.page.browser === $0.browser && !$0.browser.isClosed
          && $0.page.url == $0.address && $0.page.reservedNativeTabID == $0.nativeID
      }, "historyVetoObservedDeletionPreservesLiveFormAndUnrelatedProfileDocuments")
      try await cleanup()
      try require(application.deletingProfileID == nil && !application.store.state.profiles.contains { $0.id == profile.id }
        && !application.store.pendingNativeProfileRetirements.contains(profile.id)
        && !engine.pages.values.contains { $0.profileID == profile.id },
        "historyVetoFixtureCleansOnlyItsOwnedPublicProfileAndWindow")
      return checks
    } catch {
      let failure = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native history-veto fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw failure
    }
  }

  private static func literal(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
  }
  private static func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      try Task.checkCancellation()
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(40))
    }
    throw ShortcutError("Native history profile-veto acceptance timed out: " + phase)
  }
}
