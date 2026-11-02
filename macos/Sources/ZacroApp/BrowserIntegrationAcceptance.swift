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
      do { try await Task.sleep(for: .seconds(420)) } catch { return }
      self?.finish("The application integration check timed out.")
    }
    task = Task { [weak self] in
      guard let self else { return }
      do { try await self.checkApplication(url: url); self.finish(nil) }
      catch { self.finish(error.localizedDescription) }
    }
  }

  private func checkApplication(url: URL) async throws {
    try checkAIResetOrdering()
    let engine = application.engine
    guard let first = application.focusedCoordinator else { throw Failure("No application window") }
    try await wait("initialShellLayout") { first.actions.contentFrame.width > 400 }
    first.actions.palette = false
    guard let tab = first.store.createTab(address: url.appendingPathComponent("first").absoluteString) else { throw Failure("First tab creation") }
    let page = try await first.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    try await loaded(page)
    let browser = try await page.ready(), nativeID = browser.id
    var permissionOrigin = URLComponents()
    permissionOrigin.scheme = url.scheme; permissionOrigin.host = url.host; permissionOrigin.port = url.port
    guard let origin = permissionOrigin.url?.absoluteString else { throw Failure("Fixture origin") }
    first.store.setPermission(profileID: page.profileID, origin: origin, permission: "camera", allowed: true)
    try require(page.onPermission?(.init(kinds: .camera, origin: origin)) == .allow,
      "visiblePageUsesExplicitSavedPermission")
    try require(page.onPermission?(.init(kinds: .screenCapture, origin: origin)) == .useDefault,
      "screenCaptureRequiresNativeChooser")
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
    try first.activateExtensionTab(tab.id)
    first.layoutPages()
    try await wait("sourceActivationHidesRetainedPeek") {
      first.activePage === page && first.store.tab(tab.id)?.peek?.isPresented == false && preview.nativeWindow?.isVisible == false
    }
    try first.activateExtensionTab(preview.id)
    first.layoutPages()
    let resumedPreviewDraft = try await previewBrowser.devTools.evaluate("document.querySelector('#previewDraft').value") as? String
    try require(first.activePage === preview && resumedPreviewDraft == "peek draft", "peekActivationRetainsDocumentAndDraft")
    first.runCommand("mute-tab")
    try require(previewBrowser.isAudioMuted && !browser.isAudioMuted && first.store.tab(tab.id)?.isMuted == false,
      "peekMuteDoesNotMuteSource")
    first.promotePeek()
    try await wait("peekPromotion") { first.store.state.activeTabID != tab.id && first.store.tab(tab.id)?.peek == nil }
    guard let promotedID = first.store.state.activeTabID else { throw Failure("Promoted Peek missing") }
    let promotedDraft = try await previewBrowser.devTools.evaluate("document.querySelector('#previewDraft').value") as? String
    try require(engine.pages[promotedID] === preview && promotedDraft == "peek draft"
      && first.store.tab(promotedID)?.isMuted == true, "peekPromotionKeepsRendererAndForm")

    first.store.setSplit(left: tab.id, right: promotedID)
    guard let split = first.store.split(for: tab.id) else { throw Failure("Split creation") }
    first.layoutPages()
    first.previewSplitRatio(id: split.id, ratio: 0.63)
    first.finishSplitResize(id: split.id, ratio: 0.63)
    try require(abs((first.store.split(for: tab.id)?.ratio ?? 0) - 0.63) < 0.001, "splitRatioCommitted")
    guard let unrelated = first.store.createTab(address: url.appendingPathComponent("unrelated").absoluteString) else { throw Failure("Unrelated tab") }
    _ = try await first.ensurePageReady(unrelated)
    first.layoutPages()
    try require(page.onPermission?(.init(kinds: .camera, origin: origin)) == .deny,
      "hiddenPageCannotReuseSavedPermission")
    try first.store.clearPermissionsDurably(profileID: page.profileID)
    first.store.selectTab(id: tab.id)
    try require(first.store.split(for: tab.id)?.id == split.id, "splitSurvivesTabSwitch")

    // Keep a real target-blank popup and a live split open while importing the
    // Electron collection format through the production import pipeline.
    let beforePopup = Set(application.store.state.tabs.map(\.id))
    _ = try await browser.devTools.evaluate("window.retainedPopup=window.open('/popup','zacro-app-acceptance'); !!window.retainedPopup", userGesture: true)
    try await wait("popupAdoptedByApplication") {
      application.store.state.tabs.contains { !beforePopup.contains($0.id) && engine.pages[$0.id]?.openerID == tab.id }
    }
    guard let popup = application.store.state.tabs.first(where: { !beforePopup.contains($0.id) && engine.pages[$0.id]?.openerID == tab.id }),
      let popupPage = engine.pages[popup.id] else { throw Failure("Popup adoption") }
    try await loaded(popupPage)
    try require(popup.openerTabID == tab.id, "popupOpenerIsPersistedInSession")
    let originalSpace = tab.spaceID
    let previousProfiles = Set(first.store.state.profiles.map(\.id))
    let collection: [String: Any] = [
      "format": "zacro-export", "version": 1,
      "profiles": [["id": "imported-profile", "name": "Acceptance second profile", "private": false]],
      "spaces": [["id": "imported-space", "profileId": "imported-profile", "name": "Imported space", "color": "#7556D9"]],
      "tabs": [["id": "imported-tab", "spaceId": "imported-space", "profileId": "imported-profile",
        "url": url.appendingPathComponent("other-profile").absoluteString, "title": "Imported page", "pinned": true]],
      "bookmarks": [["id": "imported-bookmark", "profileId": "imported-profile",
        "url": url.appendingPathComponent("saved").absoluteString, "title": "Imported bookmark"]]
    ]
    let export = engine.dataDirectory.appendingPathComponent("acceptance-electron-export.json")
    try JSONSerialization.data(withJSONObject: collection).write(to: export, options: .atomic)
    try first.store.importData(from: export)
    guard let imported = first.store.state.profiles.first(where: { !previousProfiles.contains($0.id) }),
      let importedSpace = first.store.state.spaces.first(where: { $0.profileID == imported.id }),
      let other = first.store.state.tabs.first(where: { $0.spaceID == importedSpace.id }) else { throw Failure("Imported profile tab") }
    first.store.selectSpace(id: importedSpace.id)
    first.store.selectTab(id: other.id)
    try require(other.isPinned && other.windowID == first.windowContext.id
      && first.store.state.bookmarks.contains(where: { $0.profileID == imported.id && $0.title == "Imported bookmark" }),
      "electronImportRetainsCollectionsAndWindowOwnership")
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
    _ = try await browser.devTools.evaluate("document.body.insertAdjacentHTML('beforeend','<p>Approved context from its owning window.</p>'); null")
    first.windowContext.show()
    try await wait("focusReturnsToFirstWindow", record: false) { application.focusedCoordinator === first }
    let context = try await application.readContext([
      AIContextGrant(id: tab.id, url: URL(string: tab.url)!, profileID: page.profileID)
    ])
    try require(context.count == 1 && context[0].text.contains("Approved context from its owning window."),
      "approvedContextUsesTabOwnerAcrossSameProfileWindows")
    application.newWindow()
    guard let third = application.windows.values.first(where: { $0 !== first && $0 !== second }),
      let savedLeft = third.store.createTab(address: url.appendingPathComponent("saved-left").absoluteString),
      let savedRight = third.store.createTab(address: url.appendingPathComponent("saved-right").absoluteString) else {
      throw Failure("Saved window setup")
    }
    third.actions.palette = false
    third.store.setSplit(left: savedLeft.id, right: savedRight.id)
    let savedIDs = Set(third.store.state.tabs.map(\.id)), closedNativeID = third.windowContext.nativeID
    guard let savedSplit = third.store.split(for: savedLeft.id) else { throw Failure("Saved window split") }
    _ = try await third.ensurePageReady(savedLeft)
    let didClose = await third.requestCloseWindow()
    try require(didClose && application.repository.savedWindows.contains(where: { $0.id == third.windowContext.id }),
      "closedWindowAppearsInSavedWindows")
    let reopened = try application.reopenWindow(id: third.windowContext.id)
    try require(reopened === third && reopened.windowContext.nativeID != closedNativeID
      && Set(reopened.store.state.tabs.map(\.id)) == savedIDs
      && reopened.store.split(for: savedLeft.id)?.id == savedSplit.id, "reopenedWindowRetainsExactTabsAndSplit")
    let reopenedPage = try await reopened.ensurePageReady(savedLeft)
    try await loaded(reopenedPage)
    try require(await reopened.requestCloseWindow(), "restoredWindowClosesCleanly")
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
    first.windowContext.show()
    try await wait("differentProfileWindowGainsFocus", record: false) { application.focusedCoordinator === first }
    let backgroundContext = try await application.readContext([
      AIContextGrant(id: tab.id, url: URL(string: tab.url)!, profileID: page.profileID,
        conversationID: second.windowContext.id)
    ])
    try require(backgroundContext.count == 1 && backgroundContext[0].text.contains("Approved context from its owning window."),
      "approvedContextSurvivesAnotherProfileWindowFocus")
    var rejectedUnknownOwner = false
    do {
      _ = try await application.readContext([
        AIContextGrant(id: tab.id, url: URL(string: tab.url)!, profileID: page.profileID, conversationID: "missing-window")
      ])
    } catch let error as ServiceError { rejectedUnknownOwner = error.code == "CONTEXT_CHANGED" }
    try require(rejectedUnknownOwner, "contextCannotInventWindowAuthority")
    await first.closeServicesPresentation()
    first.services.start()
    let siblingStatus = await second.services.aiService.status(for: AIProfileScope(id: second.store.activeProfileID))
    try require(siblingStatus["profileId"].string == second.store.activeProfileID
      && first.services.aiService === application.services.aiService, "closingWindowPresentationKeepsSharedServices")
    do { nativeExtensions = try await engine.nativeCapabilities().extensionBrowser == true }
    catch let error as CefDevToolsError where error.isUnsupportedMethod { nativeExtensions = false }
    if nativeExtensions {
      try await checkExtensionFixture(url: url, owner: second, page: page)
      try await checkNativeMedia(url: url, owner: second)
    }
    else if ProcessInfo.processInfo.environment["ZACRO_REQUIRE_NATIVE_EXTENSIONS"] == "1" {
      throw Failure("The packaged runtime does not implement the native extension protocol")
    }
    try await checkNativePDF(url: url, owner: second)
    second.store.selectTab(id: page.id)
    second.openExtensions(store: false)
    try require(second.actions.library == "Extensions" && second.activePage === page,
      "extensionManagementUsesNativeLibraryWithoutReplacingPage")
    second.openExtensions(store: true)
    guard let webStoreTab = second.store.state.activeTab,
      URL(string: webStoreTab.url)?.host == "chromewebstore.google.com" else { throw Failure("Owned Web Store tab") }
    let webStorePage = try await second.ensurePageReady(webStoreTab)
    let count = second.store.state.tabs.count
    second.openExtensions(store: true)
    try require(second.store.state.activeTabID == webStoreTab.id && second.store.state.tabs.count == count
      && webStoreTab.windowID == second.windowContext.id && webStorePage.ownerWindowID == second.windowContext.id,
      "webStoreUsesOneOrdinaryOwnedTab")
    second.store.selectTab(id: page.id)
    if nativeExtensions { try await checkProfileClear(url: url, survivor: page, owner: second) }
  }

  private func checkProfileClear(url: URL, survivor: ChromiumPage, owner: BrowserWindowCoordinator) async throws {
    let originalSpace = owner.store.state.activeSpaceID
    let profile = try owner.store.createProfileDurably(name: "Disposable data-clear profile")
    guard let tab = owner.store.createTab(address: url.appendingPathComponent("clear-one").absoluteString) else {
      throw Failure("Profile clear first tab")
    }
    let page = try await owner.ensurePageReady(tab)
    try await loaded(page)
    _ = try await page.ready().devTools.evaluate("localStorage.setItem('clear-fixture','before'); true")
    owner.store.setPeek(tabID: tab.id, address: url.appendingPathComponent("clear-peek-one").absoluteString)
    owner.windowContext.show(); application.repository.focusWindow(owner.windowContext.id)
    application.newWindow()
    guard let sibling = application.focusedCoordinator, sibling !== owner,
      sibling.store.activeProfileID == profile.id,
      let other = sibling.store.createTab(address: url.appendingPathComponent("clear-two").absoluteString) else {
      throw Failure("Profile clear second window")
    }
    sibling.actions.palette = false
    let otherPage = try await sibling.ensurePageReady(other)
    try await loaded(otherPage)
    sibling.store.setPeek(tabID: other.id, address: url.appendingPathComponent("clear-peek-two").absoluteString)
    guard let firstAction = owner.actions.performLibraryAction, let secondAction = sibling.actions.performLibraryAction else {
      throw Failure("Profile clear Library actions")
    }
    let operation = Task { try await firstAction("data:clear", ["profileId":profile.id]) }
    try await wait("profileClearAcquiresSharedLock", record: false) { self.application.deletingProfileID == profile.id }
    var rejectedConcurrentClear = false
    do { try await secondAction("data:clear", ["profileId":profile.id]) }
    catch { rejectedConcurrentClear = true }
    try await operation.value
    try require(rejectedConcurrentClear && application.deletingProfileID == nil,
      "profileClearCannotOverwriteAnotherWindowOperation")
    try require(application.store.tab(tab.id)?.peek == nil && application.store.tab(other.id)?.peek == nil
      && !application.store.state.history.contains(where: { $0.profileID == profile.id }),
      "profileClearRemovesPeekAndHistoryAcrossAllWindows")
    guard let retained = owner.store.tab(tab.id) else { throw Failure("Profile clear removed saved tab") }
    let restored = try await owner.ensurePageReady(retained)
    try await loaded(restored)
    let cleared = try await restored.ready().devTools.evaluate("localStorage.getItem('clear-fixture')===null") as? Bool
    try require(cleared == true && application.engine.pages[survivor.id] === survivor,
      "profileClearErasesActualSiteStorageAndPreservesOtherProfiles")
    try require(await sibling.requestCloseWindow(), "clearedProfileWindowCloses")
    owner.store.selectSpace(id: originalSpace)
  }

  private func checkAIResetOrdering() throws {
    let conversation = NativeAIConversationState()
    conversation.activate(profileID: "acceptance-reset")
    func reset(_ revision: Int, cancelled: ServiceJSON = .null) -> ServiceJSON {
      ["type":"ai:reset", "profileId":"acceptance-reset", "resetRevision":.number(Double(revision)),
       "cancelledRequestId":cancelled]
    }
    conversation.receive(reset(1))
    conversation.begin(question: "Retry", request: ["requestId":"retry"])
    conversation.receive(reset(1))
    try require(conversation.busy && conversation.messages.count == 2, "duplicateAIResetPreservesNewRequest")
    conversation.receive(reset(2))
    conversation.receive(["type":"ai:answer", "profileId":"acceptance-reset", "requestId":"retry",
      "resetRevision":1, "answer":"Stale answer"])
    try require(conversation.busy && conversation.messages.count == 2
      && conversation.messages.last?.text == "", "staleAIAnswerCannotCrossReset")
    conversation.receive(reset(3, cancelled: "retry"))
    try require(!conversation.busy && conversation.messages.isEmpty, "AIResetCancelsItsActualRequest")
  }

  private func checkNativeMedia(url: URL, owner: BrowserWindowCoordinator) async throws {
    guard let tab = owner.store.createTab(address: url.appendingPathComponent("media-host").absoluteString) else {
      throw Failure("Media acceptance tab")
    }
    let page = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    try await loaded(page)
    owner.layoutPages()
    let browser = try await page.ready()
    let script = url.appendingPathComponent("media/acceptance.js").absoluteString
    _ = try await browser.devTools.evaluate("new Promise((resolve,reject)=>{const s=document.createElement('script');s.src=\(try literal(script));s.onload=()=>resolve(true);s.onerror=()=>reject(new Error('Media fixture failed to load'));document.head.append(s)})")
    do {
      guard let result = try await browser.devTools.evaluate("zacroMediaAcceptance.run(\(try literal(url.absoluteString)))", timeout: 90) as? [String: Any],
        let mediaChecks = result["checks"] as? [String: Bool] else { throw Failure("Invalid media acceptance result") }
      for (name, passed) in mediaChecks { checks["media:" + name] = passed }
      guard result["passed"] as? Bool == true else { throw Failure("Native media: \(result["errors"] ?? "failed")") }
      let pictureInPicture = try await browser.devTools.evaluate("zacroMediaAcceptance.pictureInPicture()", userGesture: true) as? Bool
      try require(pictureInPicture == true, "nativePictureInPicturePresentsDecodedVideo")
      _ = try await browser.devTools.evaluate("zacroMediaAcceptance.cleanup(); true")
    } catch {
      _ = try? await browser.devTools.evaluate("zacroMediaAcceptance.cleanup(); true")
      throw error
    }
    try require(await owner.requestCloseTab(tab.id), "mediaFixtureClosesCleanly")
  }

  private func checkNativePDF(url: URL, owner: BrowserWindowCoordinator) async throws {
    guard let pdfTab = owner.store.createTab(address: url.appendingPathComponent("media/synthetic.pdf").absoluteString) else {
      throw Failure("PDF acceptance tab")
    }
    let pdfPage = try await owner.ensurePageReady(pdfTab)
    try await application.navigation.waitForRestore(pdfPage)
    try await loaded(pdfPage)
    try require(try await NativePDFAcceptance.check(pdfPage), "nativePDFViewerLoadsActualDocument")
    try require(await owner.requestCloseTab(pdfTab.id), "pdfFixtureClosesCleanly")
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
      guard let network = try await worker.evaluate("zacroNetworkAcceptance.run(\(encoded))", timeout: 90) as? [String: Any],
        let networkChecks = network["checks"] as? [String: Bool] else { throw Failure("Invalid extension network fixture result") }
      for (name, passed) in networkChecks { checks["extension-network:" + name] = passed }
      guard network["passed"] as? Bool == true else { throw Failure("Native extension network fixture: \(network["errors"] ?? "failed")") }
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
      try await checkNativeShortcut(manager: manager, identifier: identifier, worker: worker, page: page)
      try await checkNativeOptions(worker: worker, identifier: identifier, owner: owner)
      try await checkNativeHistory(manager: manager, worker: worker, owner: owner, url: url)
      try await checkNativeBookmarkMigration(manager: manager, profileID: page.profileID, url: url)
      try await checkNativeDownload(worker: worker, profileID: page.profileID, url: url)
      try await checkNativePeek(manager: manager, identifier: identifier, worker: worker, owner: owner, source: page, url: url)
      guard let blank = owner.store.createTab(address: "about:blank") else { throw Failure("Blank action tab") }
      let blankPage = try await owner.extensionActionPage(profileID: page.profileID)
      try await manager.performAction(identifier, on: blankPage)
      try await wait("nativeExtensionActionOnBlankTab") {
        guard let action = try await worker.evaluate("zacroAcceptance.actionResult()") as? [String: Any] else { return false }
        return action["id"] as? Int == blankPage.reservedNativeTabID
          && action["url"] as? String == "about:blank" && owner.store.state.activeTabID == blank.id
      }
      try require(blankPage.id == blank.id && blankPage.ownerWindowID == owner.windowContext.id,
        "blankExtensionActionUsesRealOwnedDocument")
      _ = try await worker.evaluate("zacroAcceptance.configureAction('popup')")
      guard let ownerWindow = owner.window else { throw Failure("Blank action window") }
      let anchor = ownerWindow.convertToScreen(NSRect(x: 180, y: max(0, ownerWindow.frame.height - 80), width: 20, height: 20))
      try await manager.performAction(identifier, on: blankPage, anchorWindow: ownerWindow, anchorRect: anchor)
      guard let popup = try await worker.evaluate("zacroAcceptance.popupResult()") as? [String: Any] else {
        throw Failure("Native action popup result")
      }
      try require(popup["windowID"] as? Int == owner.windowContext.nativeID
        && (popup["tabIDs"] as? [Int]) == [blankPage.reservedNativeTabID].compactMap { $0 },
        "extensionPopupOnBlankUsesLogicalOwnerAndActiveTab")
      _ = try await worker.evaluate("zacroAcceptance.configureAction('record')")
      owner.store.selectTab(id: page.id)
      try await checkNativeSidePanel(manager: manager, identifier: identifier, worker: worker,
                                     owner: owner, source: page, url: url)
      try await checkParkedSidePanel(manager: manager, identifier: identifier, worker: worker,
                                    owner: owner, url: url)
      extensionFixturePassed = true
      await worker.close()
    } catch {
      await worker.close()
      throw error
    }
  }

  private func checkNativeShortcut(manager: ChromeExtensionManager, identifier: String,
                                   worker: ChromeExtensionWorkerSession, page: ChromiumPage) async throws {
    await application.extensionBrowser.waitForTopologyPublication()
    guard let shortcut = try await manager.shortcuts().first(where: {
      $0.extensionID == identifier && $0.name == "record-native-shortcut"
    }) else { throw Failure("Native extension command registration") }
    let previous = try await worker.evaluate("zacroAcceptance.commandResult()") as? [String: Any]
    let count = previous?["nativeCommandCount"] as? Int ?? 0
    try require(try await manager.performShortcut(shortcut, on: page), "nativeShortcutUsesChromiumRegistry")
    try await wait("nativeShortcutDispatchesActualCommandEvent") {
      let value = try await worker.evaluate("zacroAcceptance.commandResult()") as? [String: Any]
      let command = value?["lastNativeCommand"] as? [String: Any]
      let tab = command?["tab"] as? [String: Any]
      return value?["nativeCommandCount"] as? Int == count + 1
        && command?["name"] as? String == shortcut.name && tab?["id"] as? Int == page.reservedNativeTabID
    }
    try await manager.setShortcutHandlingSuspended(true)
    do {
      try require(try await manager.performShortcut(shortcut, on: page) == false, "shortcutRecordingSuspendsNativeExecution")
      try await manager.setShortcutHandlingSuspended(false)
    } catch {
      try? await manager.setShortcutHandlingSuspended(false)
      throw error
    }
    let after = try await worker.evaluate("zacroAcceptance.commandResult()") as? [String: Any]
    try require(after?["nativeCommandCount"] as? Int == count + 1, "suspendedShortcutDoesNotDeliverDuplicateCommand")
  }

  private func checkParkedSidePanel(manager: ChromeExtensionManager, identifier: String,
                                    worker: ChromeExtensionWorkerSession,
                                    owner: BrowserWindowCoordinator, url: URL) async throws {
    owner.windowContext.show()
    application.repository.focusWindow(owner.windowContext.id)
    application.newWindow()
    guard let empty = application.focusedCoordinator, empty !== owner,
      empty.store.activeProfileID == owner.store.activeProfileID else { throw Failure("Panel parking window") }
    empty.actions.palette = false
    let host = try await empty.extensionActionPage(profileID: empty.store.activeProfileID)
    _ = try await worker.evaluate("zacroAcceptance.configureAction('panel')")
    try await manager.performAction(identifier, on: host)
    try await wait("parkingFixtureOpensPanel", record: false) { host.isSidePanelVisible }
    guard let initial = try await worker.evaluate("zacroAcceptance.panelState('last-tab panel draft')") as? [String: Any],
      let instance = initial["instance"] as? String else { throw Failure("Panel parking instance") }
    try require(await empty.requestCloseTab(host.id), "lastTabWithPanelCloses")
    try await wait("globalPanelSurvivesAnEmptyWindow") {
      empty.store.state.activeTab == nil
        && self.application.engine.parkedExtensionPanel(ownerWindowID: empty.windowContext.id,
          profileID: empty.store.activeProfileID)?.nativeWindow?.isVisible == true
    }
    let logicalTabs = try await worker.evaluate("chrome.tabs.query({windowId:\(empty.windowContext.nativeID)}).then(t=>t.length)") as? Int
    let parked = try await worker.evaluate("zacroAcceptance.panelState()") as? [String: Any]
    try require(logicalTabs == 0 && parked?["instance"] as? String == instance
      && parked?["draft"] as? String == "last-tab panel draft", "parkedPanelHasNoInventedTabAndRetainsDraft")
    guard let next = empty.store.createTab(address: url.appendingPathComponent("panel-after-empty").absoluteString) else {
      throw Failure("Panel return tab")
    }
    let nextPage = try await empty.ensurePageReady(next)
    try await loaded(nextPage)
    try await wait("panelReturnsFromEmptyWindow") { nextPage.isSidePanelVisible }
    let returned = try await worker.evaluate("zacroAcceptance.panelState()") as? [String: Any]
    try require(returned?["instance"] as? String == instance
      && returned?["draft"] as? String == "last-tab panel draft", "panelReturnKeepsActualDocument")
    _ = try await worker.evaluate("zacroAcceptance.closePanel(\(empty.windowContext.nativeID))")
    try require(await empty.requestCloseWindow(), "panelParkingWindowClosesCleanly")
    _ = try await worker.evaluate("zacroAcceptance.configureAction('record')")
    owner.windowContext.show()
  }

  private func checkNativeOptions(worker: ChromeExtensionWorkerSession, identifier: String,
                                  owner: BrowserWindowCoordinator) async throws {
    owner.windowContext.show()
    _ = try await worker.evaluate("chrome.runtime.openOptionsPage().then(()=>true)")
    guard let first = try await worker.evaluate("zacroAcceptance.optionsResult()") as? [String: Any],
      let nativeWindow = first["window"] as? [String: Any], let nativeWindowID = nativeWindow["id"] as? Int,
      let nativeTab = first["tab"] as? [String: Any], let nativeTabID = nativeTab["id"] as? Int,
      let instance = first["instance"] as? String,
      let popup = application.windows.values.first(where: { $0.windowContext.nativeID == nativeWindowID }),
      let page = popup.windowPages.values.first(where: { $0.reservedNativeTabID == nativeTabID }),
      let popupWindow = popup.window else { throw Failure("Managed extension options popup") }
    try require(popup.isPopup && nativeWindow["type"] as? String == "popup"
      && page.url?.scheme == "chrome-extension" && page.url?.host == identifier
      && page.ownerWindowID == popup.windowContext.id, "extensionOptionsUsesOwnedPopupAndActualDocument")
    try await wait("optionsPopupHasContentOnlyLayout") {
      !popupWindow.styleMask.contains(.fullSizeContentView)
        && abs(popup.actions.contentFrame.minX) < 1 && abs(popup.actions.contentFrame.minY) < 1
        && popup.actions.contentFrame.width > 600 && abs(popupWindow.frame.width - 850) < 2
        && abs(popupWindow.frame.height - 650) < 2
    }
    let browser = try await page.ready()
    _ = try await browser.devTools.evaluate("document.querySelector('#options-draft').value='retained options draft'; true")
    _ = try await worker.evaluate("chrome.runtime.openOptionsPage().then(()=>true)")
    let again = try await worker.evaluate("zacroAcceptance.optionsResult()") as? [String: Any]
    let repeatedWindow = again?["window"] as? [String: Any], repeatedTab = again?["tab"] as? [String: Any]
    try require(again?["instance"] as? String == instance && again?["draft"] as? String == "retained options draft"
      && repeatedWindow?["id"] as? Int == nativeWindowID && repeatedTab?["id"] as? Int == nativeTabID,
      "extensionOptionsReusePreservesWindowTabAndForm")
    try require(await popup.requestCloseWindow(), "extensionOptionsPopupClosesCleanly")
    owner.windowContext.show()
  }

  private func checkNativeSidePanel(manager: ChromeExtensionManager, identifier: String,
                                    worker: ChromeExtensionWorkerSession, owner: BrowserWindowCoordinator,
                                    source: ChromiumPage, url: URL) async throws {
    _ = try await worker.evaluate("zacroAcceptance.configureAction('panel')")
    guard let host = owner.store.createTab(address: url.appendingPathComponent("panel-host").absoluteString) else {
      throw Failure("Native side panel host")
    }
    let hostPage = try await owner.ensurePageReady(host)
    try await application.navigation.waitForRestore(hostPage)
    try await loaded(hostPage)
    owner.layoutPages()
    try await application.extensionBrowser.prepareInitialNavigation(hostPage)
    await application.extensionBrowser.waitForTopologyPublication()
    try await manager.performAction(identifier, on: hostPage)
    guard let initial = try await worker.evaluate("zacroAcceptance.panelState('unsaved panel draft')") as? [String: Any],
      let instance = initial["instance"] as? String else { throw Failure("Native side panel document") }
    try require(initial["windowID"] as? Int == owner.windowContext.nativeID,
      "sidePanelUsesLogicalBrowserWindow")
    try owner.activateExtensionTab(source.id)
    owner.layoutPages()
    await application.extensionBrowser.waitForTopologyPublication()
    guard let switched = try await worker.evaluate("zacroAcceptance.panelState()") as? [String: Any] else {
      throw Failure("Switched side panel document")
    }
    try require(switched["instance"] as? String == instance && switched["draft"] as? String == "unsaved panel draft",
      "sidePanelRetainsLiveDocumentAcrossTabSwitch")
    guard let hostID = hostPage.reservedNativeTabID else { throw Failure("Side panel host identity") }
    _ = try await worker.evaluate("chrome.tabs.remove(\(hostID)).then(()=>true)")
    guard let retained = try await worker.evaluate("zacroAcceptance.panelState()") as? [String: Any] else {
      throw Failure("Retained side panel after host close")
    }
    try require(retained["instance"] as? String == instance && retained["draft"] as? String == "unsaved panel draft"
      && application.engine.pages[source.id] === source, "sidePanelSurvivesOriginalHostClosure")
    _ = try await worker.evaluate("zacroAcceptance.closePanel(\(owner.windowContext.nativeID))")
    guard let blank = owner.store.createTab(address: "about:blank") else { throw Failure("Blank side panel host") }
    let blankPage = try await owner.extensionActionPage(profileID: source.profileID)
    try await manager.performAction(identifier, on: blankPage)
    _ = try await worker.evaluate("zacroAcceptance.panelState('blank canvas panel')")
    try await wait("nativeSidePanelVisibleOverBlankCanvas") {
      blankPage.isSidePanelVisible && blankPage.nativeWindow?.isVisible == true
    }
    try require(owner.store.state.activeTabID == blank.id && !owner.actions.nativePageVisible
      && blankPage.url?.absoluteString == "about:blank", "blankSidePanelPreservesThemedEmptyCanvas")
    _ = try await worker.evaluate("zacroAcceptance.closePanel(\(owner.windowContext.nativeID))")
    try await wait("blankSidePanelCloseHidesOnlyNativeDocument") {
      !blankPage.isSidePanelVisible && blankPage.nativeWindow?.isVisible == false
    }
    _ = try await worker.evaluate("zacroAcceptance.configureAction('record')")
  }

  private func checkNativePeek(manager: ChromeExtensionManager, identifier: String,
                               worker: ChromeExtensionWorkerSession, owner: BrowserWindowCoordinator,
                               source: ChromiumPage, url: URL) async throws {
    let destination = url.appendingPathComponent("extension-peek").absoluteString
    owner.store.selectTab(id: source.id)
    owner.store.setPeek(tabID: source.id, address: destination)
    guard let document = owner.store.tab(source.id)?.peekDocument else { throw Failure("Extension Peek model") }
    let preview = try await owner.ensurePageReady(document)
    try await application.navigation.waitForRestore(preview)
    try await loaded(preview)
    owner.layoutPages()
    try await application.extensionBrowser.prepareInitialNavigation(preview)
    await application.extensionBrowser.waitForTopologyPublication()
    guard let sourceID = source.reservedNativeTabID, let peekID = preview.reservedNativeTabID else {
      throw Failure("Extension Peek native identities")
    }
    _ = try await worker.evaluate("zacroPeekFixture.activateSourceThenPeek(\(sourceID),\(peekID))")
    try require(owner.activePage === preview && owner.store.tab(source.id)?.peek?.isPresented != false,
      "extensionSelectsRetainedPeekAndSource")
    let browser = try await preview.ready()
    _ = try await browser.devTools.evaluate("document.body.innerHTML='<input id=extensionPeekDraft>'; document.querySelector('#extensionPeekDraft').value='retained extension preview'; null")
    try await manager.performAction(identifier, on: preview)
    try await wait("extensionActionTargetsPeek") {
      let action = try await worker.evaluate("zacroAcceptance.actionResult()") as? [String: Any]
      return action?["id"] as? Int == peekID && action?["active"] as? Bool == true
    }
    // The worker validates real scripting, per-tab zoom, and PNG capture. Keep
    // image bytes inside the worker instead of serializing them into the log.
    let accessed = try await worker.evaluate("(async()=>{const r=await zacroPeekFixture.documentAccess(\(sourceID),\(peekID),\(try literal(destination)));return r.peekID===\(peekID)&&r.capture.length>100})()") as? Bool
    try require(accessed == true, "extensionsAccessActualPeekDocument")
    await application.extensionBrowser.waitForTopologyPublication()
    _ = try await worker.evaluate("zacroPeekFixture.promoteByPinning(\(sourceID),\(peekID))")
    guard let promoted = owner.store.state.tabs.first(where: { application.engine.pages[$0.id] === preview }) else {
      throw Failure("Extension-promoted Peek model")
    }
    let draft = try await browser.devTools.evaluate("document.querySelector('#extensionPeekDraft').value") as? String
    try require(promoted.isPinned && preview.reservedNativeTabID == peekID && preview.browser === browser
      && owner.store.tab(source.id)?.peek == nil && draft == "retained extension preview",
      "extensionPeekPromotionRetainsNativeIdentityAndDraft")

    owner.store.selectTab(id: source.id)
    owner.store.setPeek(tabID: source.id, address: url.appendingPathComponent("extension-peek-close").absoluteString)
    guard let closingDocument = owner.store.tab(source.id)?.peekDocument else { throw Failure("Closable Peek model") }
    let closing = try await owner.ensurePageReady(closingDocument)
    try await application.navigation.waitForRestore(closing)
    try await loaded(closing)
    owner.layoutPages()
    try await application.extensionBrowser.prepareInitialNavigation(closing)
    await application.extensionBrowser.waitForTopologyPublication()
    guard let closingID = closing.reservedNativeTabID else { throw Failure("Closable Peek native identity") }
    _ = try await worker.evaluate("zacroPeekFixture.closePreview(\(sourceID),\(closingID))")
    try require(owner.store.tab(source.id)?.peek == nil && application.engine.pages[source.id] === source
      && owner.activePage === source, "extensionClosesPeekWithoutClosingSource")
  }

  private func checkNativeHistory(manager: ChromeExtensionManager, worker: ChromeExtensionWorkerSession,
                                  owner: BrowserWindowCoordinator, url: URL) async throws {
    guard let marker = try await worker.evaluate("zacroAcceptance.seedHistory(\(try literal(url.absoluteString)))") as? String,
      let action = owner.actions.performLibraryAction else { throw Failure("Native history setup") }
    try await action("history:clear", ["profileId": owner.store.activeProfileID])
    let cleared = try await worker.evaluate("zacroAcceptance.verifyHistoryCleared(\(try literal(marker)))") as? Bool
    try require(cleared == true, "browserHistoryClearRemovesExtensionVisibleVisits")
  }

  private func checkNativeBookmarkMigration(manager: ChromeExtensionManager, profileID: String, url: URL) async throws {
    let entry = ChromeBookmarkImport(logicalID: UUID().uuidString,
      url: url.appendingPathComponent("bookmark-import").absoluteString,
      title: "Native migration fixture", dateAdded: Date().timeIntervalSince1970 * 1000)
    let first = try await manager.importBookmarks([entry])
    guard let node = first.first?.node, first.count == 1 else { throw Failure("Native bookmark import") }
    try await manager.removeBookmark(nodeID: node.nodeID, uuid: node.uuid, storage: node.storage)
    let replay = try await manager.importBookmarks([entry])
    try require(replay.count == 1 && replay[0].removed && replay[0].node == nil && replay[0].uuid == node.uuid,
      "nativeBookmarkImportDoesNotResurrectDeletedEntry")
    try await application.bookmarks.refresh(profileID: profileID)
    try application.store.flush()
    try await manager.acknowledgeBookmarkImports(replay)
  }

  private func checkNativeDownload(worker: ChromeExtensionWorkerSession, profileID: String, url: URL) async throws {
    guard let seed = try await worker.evaluate("zacroAcceptance.seedDownload(\(try literal(url.absoluteString)))") as? [String: Any],
      let nativeID = seed["id"] as? Int, let filename = seed["filename"] as? String else { throw Failure("Worker download setup") }
    do {
      try await wait("workerDownloadAppearsInSwiftLibrary") {
        application.store.state.downloads.contains { $0.profileID == profileID && $0.filename == filename && $0.nativeGUID != nil }
      }
      guard let record = application.store.state.downloads.first(where: { $0.profileID == profileID && $0.filename == filename }),
        let guid = record.nativeGUID else { throw Failure("Worker download identity") }
      try await application.downloads.perform("download:pause", id: record.id, profileID: profileID)
      try await wait("swiftLibraryPausesWorkerDownload") {
        let state = try await worker.evaluate("zacroAcceptance.downloadState(\(nativeID))") as? [String: Any]
        return state?["paused"] as? Bool == true
      }
      try await application.downloads.perform("download:resume", id: record.id, profileID: profileID)
      try await wait("swiftLibraryResumesWorkerDownload", timeout: 30) {
        application.store.state.downloads.contains { $0.id == record.id && $0.nativeGUID == guid && $0.status == "complete" }
      }
      let renamed = "zacro-native-acceptance-" + UUID().uuidString.lowercased() + ".bin"
      try await application.downloads.perform("download:rename", id: record.id, name: renamed, profileID: profileID)
      guard let native = try await worker.evaluate("zacroAcceptance.downloadState(\(nativeID))") as? [String: Any],
        let path = native["filename"] as? String else { throw Failure("Renamed native download") }
      try require(URL(fileURLWithPath: path).lastPathComponent == renamed
        && application.store.state.downloads.first(where: { $0.id == record.id })?.path == path,
        "downloadRenameUpdatesChromiumAndSwift")
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      try require(try handle.read(upToCount: 64) == Data(repeating: 90, count: 64), "resumedDownloadHasExpectedPayload")
      try await application.downloads.perform("download:undo", id: record.id, profileID: profileID)
      try require(application.store.state.downloads.first(where: { $0.id == record.id })?.filename == filename,
        "nativeDownloadRenameUndo")
      _ = try await worker.evaluate("zacroAcceptance.cleanupDownload(\(nativeID))")
      try await wait("nativeDownloadRemovalUpdatesSwiftLibrary") {
        !application.store.state.downloads.contains { $0.id == record.id }
      }
    } catch {
      _ = try? await worker.evaluate("zacroAcceptance.cleanupDownload(\(nativeID))")
      throw error
    }
  }

  private func literal(_ value: String) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
  }

  private func loaded(_ page: ChromiumPage) async throws {
    try await wait("loaded:" + page.id, record: false) {
      page.browser != nil && !page.isLoading && page.url?.host == "127.0.0.1" && !page.title.isEmpty
    }
  }
  private func wait(_ name: String, record: Bool = true, timeout: TimeInterval = 12, condition: () async throws -> Bool) async throws {
    let limit = Date().addingTimeInterval(timeout)
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
