import AppKit
import Foundation
import ZacroChromium
import ZacroCore
import ZacroServices

/// Exercises the real application owners in a gated, disposable profile. This
/// supplements desktop acceptance; it does not synthesize mouse/keyboard input.
@MainActor
final class BrowserIntegrationAcceptance {
  private let application: ApplicationCoordinator
  private var checks: [String: Bool] = [:]
  private var task: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var finished = false
  private var nativeExtensions = false
  private var extensionFixturePassed = false
  init(application: ApplicationCoordinator) { self.application = application }

  func run(url: URL) {
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(240)) } catch { return }
      self?.finish("The application integration check timed out.")
    }
    task = Task { [weak self] in
      guard let self else { return }
      do { try await self.checkApplication(url: url); self.finish(nil) }
      catch { self.finish(error.localizedDescription) }
    }
  }

  private func checkApplication(url: URL) async throws {
    let engine = application.engine
    guard let first = application.focusedCoordinator else { throw Failure("No application window") }
    try await wait("initialShellLayout") { first.actions.contentFrame.width > 400 }
    first.actions.palette = false
    guard let tab = first.store.createTab(address: url.appendingPathComponent("first").absoluteString) else { throw Failure("First tab creation") }
    let page = try await first.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    try await loaded(page)
    let browser = try await page.ready(), nativeID = browser.id
    _ = try await browser.devTools.evaluate("document.body.innerHTML='<input id=draft value=initial><a target=_blank href=\"/popup\">Popup</a>'; document.querySelector('#draft').value='keep this draft'; null")
    first.actions.openPalette()
    try await Task.sleep(for: .milliseconds(120))
    first.actions.palette = false
    let paletteDraft = try await browser.devTools.evaluate("document.querySelector('#draft').value") as? String
    try require(engine.pages[tab.id] === page && paletteDraft == "keep this draft", "paletteRetainsLiveDocument")

    first.store.setPeek(tabID: tab.id, address: url.appendingPathComponent("peek").absoluteString)
    first.layoutPages()
    try await wait("peekCreatesRetainedDocument") { engine.pages["peek:" + tab.id]?.browser != nil }
    guard let preview = engine.pages["peek:" + tab.id] else { throw Failure("Peek page missing") }
    try await loaded(preview)
    let previewBrowser = try await preview.ready()
    _ = try await previewBrowser.devTools.evaluate("document.body.innerHTML='<input id=previewDraft>'; document.querySelector('#previewDraft').value='peek draft'; null")
    let sourceDraft = try await browser.devTools.evaluate("document.querySelector('#draft').value") as? String
    try require(sourceDraft == "keep this draft" && page.nativeWindow?.isVisible == true, "peekKeepsSourceRendered")
    first.promotePeek()
    try await wait("peekPromotion") { first.store.state.activeTabID != tab.id && first.store.tab(tab.id)?.peek == nil }
    guard let promotedID = first.store.state.activeTabID else { throw Failure("Promoted Peek missing") }
    let promotedDraft = try await previewBrowser.devTools.evaluate("document.querySelector('#previewDraft').value") as? String
    try require(engine.pages[promotedID] === preview && promotedDraft == "peek draft", "peekPromotionKeepsRendererAndForm")

    first.store.setSplit(left: tab.id, right: promotedID)
    guard let split = first.store.split(for: tab.id) else { throw Failure("Split creation") }
    first.layoutPages()
    first.previewSplitRatio(id: split.id, ratio: 0.63)
    first.finishSplitResize(id: split.id, ratio: 0.63)
    try require(abs((first.store.split(for: tab.id)?.ratio ?? 0) - 0.63) < 0.001, "splitRatioCommitted")
    guard let unrelated = first.store.createTab(address: url.appendingPathComponent("unrelated").absoluteString) else { throw Failure("Unrelated tab") }
    _ = try await first.ensurePageReady(unrelated)
    first.store.selectTab(id: tab.id)
    try require(first.store.split(for: tab.id)?.id == split.id, "splitSurvivesTabSwitch")

    // This is the historical watchdog sequence: an actual native target-blank
    // popup remains open across a second profile and a live split.
    let beforePopup = Set(application.store.state.tabs.map(\.id))
    _ = try await browser.devTools.evaluate("window.retainedPopup=window.open('/popup','zacro-app-acceptance'); !!window.retainedPopup", userGesture: true)
    try await wait("popupAdoptedByApplication") {
      application.store.state.tabs.contains { !beforePopup.contains($0.id) && engine.pages[$0.id]?.openerID == tab.id }
    }
    guard let popup = application.store.state.tabs.first(where: { !beforePopup.contains($0.id) && engine.pages[$0.id]?.openerID == tab.id }),
      let popupPage = engine.pages[popup.id] else { throw Failure("Popup adoption") }
    try await loaded(popupPage)
    let originalSpace = tab.spaceID
    _ = first.store.createProfile(name: "Acceptance second profile")
    guard let other = first.store.createTab(address: url.appendingPathComponent("other-profile").absoluteString) else { throw Failure("Other profile tab") }
    let otherPage = try await first.ensurePageReady(other)
    try await loaded(otherPage)
    try require(otherPage.browser?.profileCachePath != browser.profileCachePath, "applicationProfilesAreIsolated")
    first.store.selectSpace(id: originalSpace)
    first.store.selectTab(id: tab.id)

    application.newWindow()
    try await wait("secondApplicationShell") { application.windows.values.filter { $0.windowContext.isOpen }.count == 2 }
    guard let second = application.windows.values.first(where: { $0 !== first }) else { throw Failure("Second window") }
    try await application.moveTabs([tab.id], toWindowID: second.windowContext.id, index: 0, authorize: {})
    second.store.selectTab(id: tab.id)
    second.layoutPages()
    try require(second.store.split(for: tab.id)?.id == split.id && second.store.tab(promotedID) != nil, "splitMovesAsAUnit")
    let movedDraft = try await browser.devTools.evaluate("document.querySelector('#draft').value") as? String
    try require(engine.pages[tab.id] === page && browser.id == nativeID && movedDraft == "keep this draft"
      && page.ownerWindowID == second.windowContext.id, "applicationWindowTransferRetainsDocument")
    try require(first.store.tab(tab.id) == nil && application.store.tab(tab.id)?.windowID == second.windowContext.id,
      "exactlyOneWindowOwnsTab")
    first.actions.openPalette()
    try require(!second.actions.palette, "windowPaletteStateIsIndependent")
    first.actions.palette = false
    first.store.updateSettings { $0.sidebarWidth = 256 }
    second.store.updateSettings { $0.sidebarWidth = 288 }
    try require(first.store.state.settings.sidebarWidth == 256 && second.store.state.settings.sidebarWidth == 288,
      "windowSidebarWidthsAreIndependent")
    application.store.save(); try application.store.flush()
    let decoded = try JSONDecoder().decode(BrowserState.self,
      from: Data(contentsOf: engine.dataDirectory.appendingPathComponent("native-state.json")))
    try require(decoded.windowSessions?.filter(\.isOpen).count == 2
      && decoded.tabs.first(where: { $0.id == tab.id })?.windowID == second.windowContext.id,
      "windowOwnershipPersisted")
    try require(engine.pages[popup.id] === popupPage && popupPage.browser != nil, "popupRetainedForApplicationShutdown")
    try require(first.services.aiService === second.services.aiService
      && first.services.aiService === application.services.aiService
      && first.services.syncService === second.services.syncService, "windowServicesShareOneBackend")
    let otherProfile = first.store.profileID(for: other)!
    first.store.selectSpace(id: other.spaceID)
    first.services.refreshContext(); second.services.refreshContext()
    try await wait("windowServicesKeepOwnProfile") {
      first.services.ai["profileId"].string == otherProfile
        && second.services.ai["profileId"].string == second.store.activeProfileID
    }
    await first.closeServicesPresentation()
    first.services.start()
    let siblingStatus = await second.services.aiService.status(for: AIProfileScope(id: second.store.activeProfileID))
    try require(siblingStatus["profileId"].string == second.store.activeProfileID
      && first.services.aiService === application.services.aiService, "closingWindowPresentationKeepsSharedServices")
    do { nativeExtensions = try await engine.nativeCapabilities().extensionBrowser == true }
    catch let error as CefDevToolsError where error.isUnsupportedMethod { nativeExtensions = false }
    if nativeExtensions { try await checkExtensionFixture(url: url, owner: second, page: page) }
    else if ProcessInfo.processInfo.environment["ZACRO_REQUIRE_NATIVE_EXTENSIONS"] == "1" {
      throw Failure("The packaged runtime does not implement the native extension protocol")
    }
  }

  private func checkExtensionFixture(url: URL, owner: BrowserWindowCoordinator, page: ChromiumPage) async throws {
    guard let fixture = ProcessInfo.processInfo.environment["ZACRO_NATIVE_EXTENSION_FIXTURE"] else {
      throw Failure("Missing real-extension acceptance fixture")
    }
    let copy = application.engine.dataDirectory.appendingPathComponent("AcceptanceExtension", isDirectory: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: copy)
    let manager = ChromeExtensionManager(engine: application.engine, profileID: page.profileID)
    let identifier = try await manager.loadUnpackedExtension(at: copy)
    let worker = try await manager.workerSession(identifier)
    do {
      let config: [String: Any] = ["baseURL": url.absoluteString,
        "sourceWindowID": owner.windowContext.nativeID, "groups": true]
      let encoded = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
      guard let result = try await worker.evaluate("zacroAcceptance.run(\(encoded))", timeout: 120) as? [String: Any],
        let fixtureChecks = result["checks"] as? [String: Bool] else { throw Failure("Invalid extension fixture result") }
      for (name, passed) in fixtureChecks { checks["extension:" + name] = passed }
      guard result["passed"] as? Bool == true else { throw Failure("Native extension fixture: \(result["errors"] ?? "failed")") }
      owner.store.selectTab(id: page.id)
      owner.windowContext.show()
      try await application.extensionBrowser.prepareInitialNavigation(page)
      try await manager.performAction(identifier, on: page)
      try await wait("nativeExtensionActionDispatch") {
        guard let action = try await worker.evaluate("zacroAcceptance.actionResult()") as? [String: Any] else { return false }
        return action["id"] as? Int == page.reservedNativeTabID
          && action["windowId"] as? Int == owner.windowContext.nativeID
          && action["active"] as? Bool == true
      }
      extensionFixturePassed = true
      await worker.close()
    } catch {
      await worker.close()
      throw error
    }
  }

  private func loaded(_ page: ChromiumPage) async throws {
    try await wait("loaded:" + page.id, record: false) {
      page.browser != nil && !page.isLoading && page.url?.host == "127.0.0.1" && !page.title.isEmpty
    }
  }
  private func wait(_ name: String, record: Bool = true, condition: () async throws -> Bool) async throws {
    let limit = Date().addingTimeInterval(12)
    while Date() < limit {
      try Task.checkCancellation()
      if try await condition() { if record { checks[name] = true }; return }
      try await Task.sleep(for: .milliseconds(80))
    }
    checks[name] = false; throw Failure(name)
  }
  private func require(_ value: Bool, _ name: String) throws {
    checks[name] = value
    if !value { throw Failure(name) }
  }
  private func finish(_ error: String?) {
    guard !finished else { return }; finished = true; deadline?.cancel()
    let report: [String: Any] = ["passed": error == nil, "error": error ?? "", "checks": checks,
      "nativeExtensionProtocol": nativeExtensions, "extensionCompatibilityVerified": false,
      "extensionFixturePassed": extensionFixturePassed,
      "desktopInputVerified": false, "windows": application.windows.count]
    if let output = ProcessInfo.processInfo.environment["ZACRO_ACCEPTANCE_OUTPUT"],
      let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    fputs("Native application integration: \(error ?? "passed")\n", stderr)
    NSApp.terminate(nil)
  }
  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Application integration failed: " + message }
  }
}
