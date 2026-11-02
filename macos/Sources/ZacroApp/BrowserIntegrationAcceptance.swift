import AppKit
import Darwin
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
    guard let firstWindow = first.window else { throw Failure("No application window presentation") }
    for (name, passed) in NativeSidebarDragAcceptance.check(in: firstWindow) { try require(passed, name) }
    for (name, passed) in NativeSpaceViewportAcceptance.check() { try require(passed, name) }
    for (name, passed) in NativeThemeColorWellAcceptance.check() { try require(passed, name) }
    for (name, passed) in await NativeWindowDialogOwnerAcceptance.check() { try require(passed, name) }
    try await checkNativeWindowSheets(owner: firstWindow)
    first.windowContext.show()
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
    try NativeViewRenderEvidence.capture("sidebar", window: firstWindow)
    first.actions.openPalette()
    try await Task.sleep(for: .milliseconds(220))
    try NativeViewRenderEvidence.capture("palette", window: firstWindow)
    first.actions.palette = false
    let paletteDraft = try await browser.devTools.evaluate("document.querySelector('#draft').value") as? String
    try require(engine.pages[tab.id] === page && paletteDraft == "keep this draft", "paletteRetainsLiveDocument")
    let savedTheme = first.store.state.activeSpace?.theme
    try require(first.actions.performInterfaceCommand("space-theme"), "themeEditorCommandOpensOwnedPresentation")
    try await wait("themeEditorHasOwnedVisibleView", record: false) {
      first.actions.themeEditorWindow?.isVisible == true
        && (first.actions.themeEditorWindow?.contentView?.bounds.width ?? 0) > 100
    }
    guard let themeWindow = first.actions.themeEditorWindow else { throw Failure("Theme editor presentation") }
    try await Task.sleep(for: .milliseconds(220))
    try NativeViewRenderEvidence.capture("theme-editor", window: themeWindow)
    first.actions.themeEditor = false
    try await wait("themeEditorDismissesItsOwnedView", record: false) {
      first.actions.themeEditorWindow == nil && !themeWindow.isVisible
    }
    let themeDraft = try await browser.devTools.evaluate("document.querySelector('#draft').value") as? String
    try require(first.store.state.activeSpace?.theme == savedTheme && themeDraft == "keep this draft"
      && engine.pages[tab.id] === page, "themeEditorDismissalRetainsThemeAndLiveDocument")
    let normalTop = first.actions.contentFrame.minY
    first.find()
    try await wait("findReservesSpaceAboveLivePage") { abs(first.actions.contentFrame.minY - 40) < 0.5 }
    let findSession = first.actions.findSession
    first.find()
    try require(first.actions.findVisible && first.actions.findSession != findSession, "repeatedFindRequestsFocusAgain")
    first.actions.closeFind()
    try await wait("closingFindRestoresPageGutter") { abs(first.actions.contentFrame.minY - normalTop) < 0.5 }
    first.runCommand("find-next")
    try require(first.actions.findVisible, "findNextOpensHiddenFindBar")
    first.actions.closeFind()
    let findDraft = try await browser.devTools.evaluate("document.querySelector('#draft').value") as? String
    try require(engine.pages[tab.id] === page && findDraft == "keep this draft", "findLayoutRetainsLiveDocument")

    first.store.setPeek(tabID: tab.id, address: url.appendingPathComponent("peek").absoluteString)
    let selectedPreview = try await first.extensionActionPage(profileID: page.profileID)
    try require(selectedPreview.id == "peek:" + tab.id && selectedPreview !== page,
      "extensionActionMaterializesTheSelectedPeek")
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
    try await checkPermissionSheets(owner: second, other: first, url: url)
    _ = try await browser.devTools.evaluate("document.body.insertAdjacentHTML('beforeend','<p>Approved context from its owning window.</p>'); null")
    first.windowContext.show()
    try await wait("focusReturnsToFirstWindow", record: false) { application.focusedCoordinator === first }
    let context = try await application.readContext([
      AIContextGrant(id: tab.id, url: URL(string: tab.url)!, profileID: page.profileID)
    ])
    try require(context.count == 1 && context[0].text.contains("Approved context from its owning window."),
      "approvedContextUsesTabOwnerAcrossSameProfileWindows")
    application.newWindow()
    guard let third = application.windows.values.first(where: { $0 !== first && $0 !== second }) else {
      throw Failure("Saved window setup")
    }
    try await checkActionPreparationContext(owner: third, other: first)
    guard let savedLeft = third.store.createTab(address: url.appendingPathComponent("saved-left").absoluteString),
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
    try await checkFailedDocuments(url: url, owner: second, survivor: page)
    do { nativeExtensions = try await engine.nativeCapabilities().extensionBrowser == true }
    catch let error as CefDevToolsError where error.isUnsupportedMethod { nativeExtensions = false }
    if nativeExtensions {
      try await checkHostedSelection(url: url, owner: second, survivor: page)
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
    try await checkApplicationReopening(url: url, owner: second, page: page)
  }

  private func checkApplicationReopening(url: URL, owner: BrowserWindowCoordinator,
    page: ChromiumPage) async throws {
    owner.store.selectTab(id: page.id)
    owner.actions.palette = false; owner.actions.library = nil
    owner.windowContext.show(); owner.layoutPages(); page.focus()
    try await wait("menuFixtureFocusesActualPage", record: false) { NSApp.keyWindow === page.nativeWindow }
    application.performApplicationCommand("zoom-in", preferredWindowID: owner.windowContext.id)
    try require(NSApp.keyWindow === page.nativeWindow && application.pendingApplicationIntentCount == 0,
      "applicationMenuPreservesActualDocumentFocus")
    page.resetZoom()
    guard let windowMenu = NSApp.windowsMenu,
      let minimize = windowMenu.items.first(where: { $0.representedObject as? String == "window-minimize" }),
      let action = minimize.action, let shell = owner.window else { throw Failure("Logical-window menu fixture") }
    try require(NSApp.sendAction(action, to: minimize.target, from: minimize),
      "windowMenuDispatchesToLogicalBrowserOwner")
    try await wait("documentFocusedMinimizeTargetsOwningShell") { shell.isMiniaturized }
    application.performApplicationCommand("zoom-in", preferredWindowID: owner.windowContext.id)
    try await wait("ownedCommandRestoresSameMiniaturizedBrowser") {
      !shell.isMiniaturized && shell.isVisible && owner.windowContext.isOpen
        && self.application.focusedCoordinator === owner
    }
    page.resetZoom()
    let open = application.windows.values.filter { $0.windowContext.isOpen }
      .sorted { $0.windowContext.nativeID < $1.windowContext.nativeID }
    guard let closingOwner = open.first?.window else { throw Failure("Logical-close sheet owner") }
    let closingAlert = NSAlert(); closingAlert.messageText = "Disposable logical-window closure fixture"
    var closingResponse: NSApplication.ModalResponse?
    let closingDialog = Task { closingResponse = await NativeWindowSheet.present(closingAlert, for: closingOwner) }
    defer { closingDialog.cancel() }
    try await wait("applicationCloseFixtureHasOwnedSheet", record: false) {
      closingOwner.attachedSheet === closingAlert.window
    }
    for window in open {
      window.actions.palette = false; window.actions.library = nil; window.actions.themeEditor = false
      try require(await window.requestCloseWindow(), "appRoutingClosesWindow:\(window.windowContext.id)")
    }
    try await wait("applicationRemainsAliveWithNoBrowserWindows") {
      !self.application.windows.values.contains { $0.windowContext.isOpen }
    }
    try await wait("logicalBrowserClosureCancelsItsNativeDialog") {
      closingResponse == .cancel && closingOwner.attachedSheet == nil
    }
    guard let expected = application.repository.savedWindows.first?.id,
      let dock = application.applicationDockMenu(NSApp) else { throw Failure("Closed-window Dock menu") }
    try require(dock.items.compactMap { $0.representedObject as? String }
      == ["open-browser", "command-palette", "new-private-space"], "dockActionsSurviveClosingLastWindow")
    application.performApplicationCommand("command-palette")
    try await wait("menuCommandReopensMostRecentSavedWindow") {
      let windows = self.application.windows.values.filter { $0.windowContext.isOpen }
      return windows.count == 1 && windows[0].windowContext.id == expected && windows[0].actions.palette
    }
    guard let reopened = application.focusedCoordinator else { throw Failure("Reopened command window") }
    let destination = url.appendingPathComponent("external-application-link")
    application.application(NSApp, open: [destination])
    try await wait("externalLinkUsesOneLiveOwnedWindow") {
      self.application.windows.values.filter { $0.windowContext.isOpen }.count == 1
        && reopened.store.state.activeTab?.url == destination.absoluteString
        && self.application.pendingApplicationIntentCount == 0
    }
    try require(await reopened.requestCloseWindow(), "applicationRouteWindowClosesCleanly")
    application.performApplicationCommand("open-browser")
    try await wait("newWindowCommandCreatesExactlyOneWindowAfterClosure") {
      self.application.windows.values.filter { $0.windowContext.isOpen }.count == 1
        && self.application.pendingApplicationIntentCount == 0
    }
  }

  private func checkActionPreparationContext(owner: BrowserWindowCoordinator,
    other: BrowserWindowCoordinator) async throws {
    let originalSpace = owner.store.state.activeSpaceID, profile = owner.store.activeProfileID
    let before = Set(owner.store.state.tabs.map(\.id))
    guard let different = owner.store.state.spaces.first(where: { $0.profileID != profile }) else {
      throw Failure("Action preparation profile fixture")
    }
    do {
      _ = try await owner.extensionActionPage(profileID: profile, authorize: {
        owner.store.selectSpace(id: different.id)
      })
      throw Failure("Stale action authorization unexpectedly succeeded")
    } catch is CancellationError { }
    try require(Set(owner.store.state.tabs.map(\.id)) == before,
      "extensionActionRechecksContextBeforeCreatingBlankTab")
    owner.store.selectSpace(id: originalSpace)
    other.windowContext.show()
    try await wait("actionFixtureFocusesOtherWindow", record: false) {
      self.application.focusedCoordinator === other && NSApp.keyWindow !== owner.window
    }
    var authorized = false
    do {
      _ = try await owner.extensionActionPage(profileID: profile, requireFocused: true,
        authorize: { authorized = true })
      throw Failure("Inactive popup target unexpectedly succeeded")
    } catch is CancellationError { }
    try require(!authorized && Set(owner.store.state.tabs.map(\.id)) == before,
      "programmaticActionCannotActivateAnInactiveWindow")
    owner.windowContext.show()
  }

  private func checkNativeWindowSheets(owner: NSWindow) async throws {
    let alert = NSAlert(); alert.messageText = "Disposable dialog cancellation fixture"
    var response: NSApplication.ModalResponse?
    let task = Task { response = await NativeWindowSheet.present(alert, for: owner) }
    defer { task.cancel() }
    try await wait("nativeDialogIsOwnedAndAsynchronous", record: false) {
      owner.attachedSheet === alert.window && NSApp.modalWindow == nil
    }
    let duplicate = NSAlert(); duplicate.messageText = "Must not replace the existing sheet"
    let duplicateResponse = await NativeWindowSheet.present(duplicate, for: owner)
    try require(duplicateResponse == .cancel && owner.attachedSheet === alert.window && response == nil,
      "nativeDialogCannotReplaceAnotherOwnedSheet")
    task.cancel()
    try await wait("nativeDialogTaskCancellationClosesItsSheet") {
      response == .cancel && owner.attachedSheet == nil
    }
    let temporary = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 180),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    temporary.isReleasedWhenClosed = false; temporary.orderFront(nil)
    let closeAlert = NSAlert(); closeAlert.messageText = "Disposable owner-closure fixture"
    var closeResponse: NSApplication.ModalResponse?
    let closing = Task { closeResponse = await NativeWindowSheet.present(closeAlert, for: temporary) }
    defer { closing.cancel(); temporary.close() }
    try await wait("nativeDialogFixtureOwnsItsTemporarySheet", record: false) {
      temporary.attachedSheet === closeAlert.window
    }
    temporary.close()
    try await wait("nativeDialogOwnerClosureResolvesCancellation") {
      closeResponse == .cancel && !temporary.isVisible
    }
    let child = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 180),
      styleMask: [.titled], backing: .buffered, defer: false)
    child.isReleasedWhenClosed = false
    owner.addChildWindow(child, ordered: .above); child.orderFront(nil)
    defer { owner.removeChildWindow(child); child.close() }
    let nestedAlert = NSAlert(); nestedAlert.messageText = "Disposable descendant-sheet fixture"
    var nestedResponse: NSApplication.ModalResponse?
    let nested = Task { nestedResponse = await NativeWindowSheet.present(nestedAlert, for: child) }
    defer { nested.cancel() }
    try await wait("nativeDialogFixtureOwnsDescendantSheet", record: false) {
      child.attachedSheet === nestedAlert.window
    }
    NativeWindowSheet.cancel(for: owner)
    try await wait("nativeDialogLogicalOwnerCancellationIncludesDescendants") {
      nestedResponse == .cancel && child.attachedSheet == nil && owner.isVisible
    }
  }

  private func checkPermissionSheets(owner: BrowserWindowCoordinator,
    other: BrowserWindowCoordinator, url: URL) async throws {
    let previous = owner.store.state.activeTabID
    owner.windowContext.show()
    owner.actions.palette = false
    guard let tab = owner.store.createTab(address: url.appendingPathComponent("permission-sheet").absoluteString),
      let origin = BrowserAddress.webOrigin(url.absoluteString), let ownerWindow = owner.window else {
      throw Failure("Permission sheet fixture")
    }
    let page = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    try await loaded(page)
    try await wait("permissionFixtureHasOwnFocus", record: false) {
      self.application.focusedCoordinator === owner
        && (NSApp.keyWindow === ownerWindow || NSApp.keyWindow === page.nativeWindow)
    }
    let browser = try await page.ready()
    _ = try await browser.devTools.evaluate("window.permissionResult='pending'; Notification.requestPermission().then(result=>window.permissionResult=result); true", userGesture: true)
    try await wait("sitePermissionUsesAnOwnedNonblockingSheet") {
      ownerWindow.attachedSheet != nil && NSApp.modalWindow == nil
    }
    other.windowContext.show()
    try await wait("permissionSheetLeavesAnotherWindowUsable") {
      self.application.focusedCoordinator === other
        && (NSApp.keyWindow === other.window || other.windowPages.values.contains { $0.nativeWindow === NSApp.keyWindow })
        && ownerWindow.attachedSheet != nil && NSApp.modalWindow == nil
    }
    page.load(url.appendingPathComponent("permission-cancelled-by-navigation"))
    try await loaded(page)
    try await wait("navigationDismissesItsPendingPermission") { ownerWindow.attachedSheet == nil }
    try require(owner.store.savedPermission(profileID: page.profileID, origin: origin, permission: "notifications") == nil,
      "cancelledPermissionCannotPersistAChoice")
    _ = try await browser.devTools.evaluate("window.permissionResult='pending'; Notification.requestPermission().then(result=>window.permissionResult=result); true", userGesture: true)
    try await wait("backgroundPermissionWaitsWithoutTakingFocus") {
      owner.pendingPermissionRequestCount == 1 && ownerWindow.attachedSheet == nil
        && self.application.focusedCoordinator === other && NSApp.modalWindow == nil
    }
    owner.windowContext.show()
    try await wait("queuedPermissionAppearsOnlyInItsOwnWindow") {
      ownerWindow.attachedSheet != nil && owner.pendingPermissionRequestCount == 1 && NSApp.modalWindow == nil
    }
    try require(await owner.requestCloseTab(tab.id), "permissionFixtureClosesCleanly")
    try await wait("closingSourceCancelsQueuedOrPresentedPermission") {
      owner.pendingPermissionRequestCount == 0 && ownerWindow.attachedSheet == nil
    }
    if let previous { owner.store.selectTab(id: previous) }
    owner.layoutPages()
  }

  private func checkHostedSelection(url: URL, owner: BrowserWindowCoordinator, survivor: ChromiumPage) async throws {
    owner.actions.palette = false; owner.actions.library = nil; owner.windowContext.show()
    guard let left = owner.store.createTab(address: url.appendingPathComponent("focus-left").absoluteString),
      let right = owner.store.createTab(address: url.appendingPathComponent("focus-right").absoluteString) else {
      throw Failure("Hosted focus fixture tabs")
    }
    owner.store.setSplit(left: left.id, right: right.id)
    owner.store.selectTab(id: left.id)
    let leftPage = try await owner.ensurePageReady(left), rightPage = try await owner.ensurePageReady(right)
    try await loaded(leftPage); try await loaded(rightPage)
    try await wait("hostedSplitShowPreservesSelectedPane") {
      owner.store.state.activeTabID == left.id && leftPage.nativeWindow?.isVisible == true
        && rightPage.nativeWindow?.isVisible == true && NSApp.keyWindow === leftPage.nativeWindow
    }
    owner.store.selectTab(id: right.id)
    try await wait("logicalSplitSelectionFocusesItsActualDocument") {
      owner.activePage === rightPage && NSApp.keyWindow === rightPage.nativeWindow
    }
    try require(await owner.requestCloseTab(left.id), "inactiveSplitFocusFixtureCloses")
    try require(await owner.requestCloseTab(right.id), "activeSplitFocusFixtureCloses")
    owner.store.selectTab(id: survivor.id)
  }

  private func checkFailedDocuments(url: URL, owner: BrowserWindowCoordinator, survivor: ChromiumPage) async throws {
    // Port1 is Chromium's deliberately blocked loopback port: deterministic
    // failure without contacting an external server or a user service.
    guard let tab = owner.store.createTab(address: "http://127.0.0.1:1/native-error") else { throw Failure("Error fixture tab") }
    owner.actions.palette = false; owner.actions.library = nil
    let failed = try await owner.ensurePageReady(tab)
    let browser = try await failed.ready(), nativeID = browser.id
    try await wait("failedPageUsesRetainedNativeErrorCard") {
      failed.documentError != nil && owner.actions.documentErrors[tab.id] != nil
        && failed.nativeWindow?.isVisible == false
    }
    if let window = owner.window { try NativeViewRenderEvidence.capture("page-error", window: window) }
    owner.editDocumentAddress(tab.id)
    try require(owner.actions.palette && owner.actions.paletteEditsAddress
      && owner.actions.query == tab.url, "failedPageCanEditItsOwnAddress")
    owner.actions.palette = false
    owner.navigate(url.appendingPathComponent("recovered-error").absoluteString)
    try await loaded(failed)
    try await wait("failedPageRecoversWithoutReplacingNativeIdentity") {
      failed.documentError == nil && owner.actions.documentErrors[tab.id] == nil
        && failed.nativeWindow?.isVisible == true && failed.browser?.id == nativeID
    }
    try require(await owner.requestCloseTab(tab.id), "recoveredErrorTabClosesCleanly")
    owner.store.selectTab(id: survivor.id)
    owner.store.setPeek(tabID: survivor.id, address: "http://127.0.0.1:1/peek-error")
    owner.layoutPages()
    try await wait("failedPeekKeepsSourceVisible") {
      guard let preview = self.application.engine.pages["peek:" + survivor.id] else { return false }
      return preview.documentError != nil && owner.actions.documentErrors[preview.id] != nil
        && preview.nativeWindow?.isVisible == false && survivor.nativeWindow?.isVisible == true
        && owner.store.state.activeTabID == survivor.id && owner.hasPresentedPeek
    }
    if let window = owner.window { try NativeViewRenderEvidence.capture("peek-error", window: window) }
    guard let preview = application.engine.pages["peek:" + survivor.id], let previewID = preview.browser?.id else {
      throw Failure("Failed Peek retains its browser")
    }
    owner.navigate(url.appendingPathComponent("recovered-peek").absoluteString)
    try await loaded(preview)
    try await wait("failedPeekRecoversWithoutReplacingNativeIdentity") {
      preview.documentError == nil && owner.actions.documentErrors[preview.id] == nil
        && preview.nativeWindow?.isVisible == true && preview.browser?.id == previewID
    }
    try require(await owner.requestCloseTab(preview.id), "recoveredPeekClosesCleanly")
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
      try await checkNativeIdentity(worker: worker, baseURL: url)
      try await checkNativeMessaging(worker: worker, identifier: identifier)
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
      try await checkProgrammaticActionPopup(worker: worker, owner: owner, source: page, url: url)
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
      _ = try await worker.evaluate("zacroAcceptance.setPanelEventObservation(false)")
      try await checkNativeSidePanel(manager: manager, identifier: identifier, worker: worker,
                                     owner: owner, source: page, url: url)
      try await checkParkedSidePanel(manager: manager, identifier: identifier, worker: worker,
                                    owner: owner, url: url)
      _ = try await worker.evaluate("zacroAcceptance.setPanelEventObservation(true)")
      extensionFixturePassed = true
      await worker.close()
    } catch {
      await worker.close()
      throw error
    }
  }

  private func checkProgrammaticActionPopup(worker: ChromeExtensionWorkerSession,
    owner: BrowserWindowCoordinator, source: ChromiumPage, url: URL) async throws {
    var address = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    address.host = "localhost"; address.path = "/native-network/denied"
    owner.actions.palette = false; owner.actions.library = nil
    owner.windowContext.show()
    guard let destination = address.url,
      let tab = owner.store.createTab(address: destination.absoluteString) else {
      throw Failure("Programmatic popup origin fixture")
    }
    let page = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    try await loaded(page)
    try await application.extensionBrowser.prepareInitialNavigation(page)
    await application.extensionBrowser.waitForTopologyPublication()
    guard let nativeID = page.reservedNativeTabID else { throw Failure("Popup fixture document identity") }
    owner.actions.openPalette()
    try await wait("programmaticPopupFixtureShowsOwnedPalette", record: false) {
      NSApp.keyWindow?.identifier == NSUserInterfaceItemIdentifier("ZacroBrowserControls")
        && NSApp.keyWindow?.parent === owner.window
    }
    guard let controls = NSApp.keyWindow else { throw Failure("Popup fixture controls") }
    guard let result = try await worker.evaluate("zacroAcceptance.openPopup(\(owner.windowContext.nativeID),\(nativeID))") as? [String: Any] else {
      throw Failure("Programmatic popup result")
    }
    try require(result["windowID"] as? Int == owner.windowContext.nativeID
      && (result["tabIDs"] as? [Int]) == [nativeID],
      "programmaticPopupUsesSelectedLogicalDocumentWithoutActiveTabGrant")
    try await wait("programmaticPopupHasExactOwnerAboveOwnedControls") {
      guard let popup = NSApp.keyWindow else { return false }
      return self.application.engine.extensionPopupOwner(popup) === owner.windowContext
        && popup.level.rawValue >= controls.level.rawValue && popup.isVisible
    }
    _ = try await worker.evaluate("zacroAcceptance.closePopup()")
    try await wait("programmaticPopupReleasesNativeOwnership") {
      !NSApp.windows.contains { self.application.engine.extensionPopupOwner($0) === owner.windowContext }
    }
    owner.actions.palette = false
    _ = try await worker.evaluate("zacroAcceptance.configureAction('record')")
    try require(await owner.requestCloseTab(tab.id), "programmaticPopupFixtureClosesCleanly")
    owner.store.selectTab(id: source.id)
    owner.windowContext.show()
  }

  private func checkNativeMessaging(worker: ChromeExtensionWorkerSession, identifier: String) async throws {
    let files = FileManager.default
    guard identifier.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
      let executablePath = ProcessInfo.processInfo.environment["ZACRO_NATIVE_MESSAGING_FIXTURE"],
      files.isExecutableFile(atPath: executablePath) else { throw Failure("Missing disposable native messaging host") }
    let data = application.engine.dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard data.lastPathComponent.hasPrefix("zacro-native-acceptance-"),
      data.deletingLastPathComponent() == files.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
      throw Failure("Native messaging fixtures require the disposable acceptance profile")
    }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let chromium = data.appendingPathComponent("Chromium", isDirectory: true)
    let directory = chromium.appendingPathComponent("ZacroNativeMessagingFixture-" + token, isDirectory: true)
    let registrations = chromium.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try files.createDirectory(at: registrations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var manifests: [URL] = []
    defer {
      for manifest in manifests { try? files.removeItem(at: manifest) }
      try? files.removeItem(at: directory)
    }
    var hosts: [String: String] = [:]
    for kind in ["echo", "fragments", "batch", "oversized", "truncated", "invalidjson", "hold", "denied"] {
      let host = directory.appendingPathComponent(kind)
      try files.copyItem(at: URL(fileURLWithPath: executablePath), to: host)
      try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
      let name = "com.zacro.native_fixture_" + token + "." + kind
      let denied = String(repeating: identifier == String(repeating: "a", count: 32) ? "b" : "a", count: 32)
      let manifest: [String: Any] = ["name": name, "description": "Disposable Zacro acceptance host",
        "path": host.path, "type": "stdio", "allowed_origins": ["chrome-extension://" + (kind == "denied" ? denied : identifier) + "/"]]
      let location = registrations.appendingPathComponent(name + ".json")
      try JSONSerialization.data(withJSONObject: manifest).write(to: location, options: .withoutOverwriting)
      manifests.append(location)
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
      hosts[kind] = name
    }
    hosts["missing"] = "com.zacro.native_fixture_" + token + ".missing"
    let config = String(decoding: try JSONSerialization.data(withJSONObject: ["hosts": hosts]), as: UTF8.self)
    guard let result = try await worker.evaluate("zacroNativeMessagingAcceptance.run(\(config))", timeout: 90) as? [String: Any],
      let results = result["checks"] as? [String: Bool], results.count == 9 else { throw Failure("Invalid native messaging fixture result") }
    for (name, passed) in results { checks["extension-messaging:" + name] = passed }
    guard result["passed"] as? Bool == true else { throw Failure("Native messaging: \(result["errors"] ?? "failed")") }
    try require(!files.fileExists(atPath: directory.appendingPathComponent("denied.pid").path), "nativeDeniedHostNeverLaunched")
    let pidText = try String(contentsOf: directory.appendingPathComponent("hold.pid"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(pidText), pid > 1 else { throw Failure("Native host process identity") }
    try await wait("nativeDisconnectedHostExited", timeout: 8) {
      // An exited child awaiting Chromium's background reap is already dead.
      // A failed process query is not evidence of exit; never signal a PID.
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
      let status = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
      return status == 0 && (size == 0 || info.kp_proc.p_stat == Int8(SZOMB))
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

  private func checkNativeIdentity(worker: ChromeExtensionWorkerSession, baseURL: URL) async throws {
    guard let result = try await worker.evaluate("zacroIdentityAcceptance.run({baseURL:\(try literal(baseURL.absoluteString))})", timeout: 90) as? [String: Any],
      let identityChecks = result["checks"] as? [String: Bool], identityChecks.count == 6 else {
      throw Failure("Invalid native identity fixture result")
    }
    for (name, passed) in identityChecks { checks["extension-identity:" + name] = passed }
    guard identityChecks.values.allSatisfy({ $0 }) else { throw Failure("Native identity: \(result["errors"] ?? "failed")") }
    for cancel in [false, true] {
      let token = "zacro-native-" + UUID().uuidString
      let encoded = try literal(token)
      let before = Set(NSApp.windows.map(ObjectIdentifier.init))
      guard let flow = try await worker.evaluate("zacroIdentityAcceptance.startInteractive({baseURL:\(try literal(baseURL.absoluteString)),token:\(encoded)})") as? [String: Any],
        let title = flow["title"] as? String else { throw Failure("Interactive native auth start") }
      var window: NSWindow?
      try await wait("nativeAuthPresentsOwnedWindow", record: false) {
        window = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.title == title && $0.isVisible }
        return window != nil
      }
      guard let window else { throw Failure("Native auth window") }
      let pending = try await worker.evaluate("zacroIdentityAcceptance.status(\(encoded))") as? [String: Any]
      try require(pending?["state"] as? String == "pending"
        && (pending?["logicalAuthTabIDs"] as? [Int])?.isEmpty == true
        && (pending?["logicalAuthWindowIDs"] as? [Int])?.isEmpty == true,
        cancel ? "cancelAuthFlowKeepsCredentialsOutsideTabCatalog" : "nativeAuthFlowKeepsCredentialsOutsideTabCatalog")
      if cancel {
        // Owned fixture window lifecycle only; this does not simulate a click
        // or establish desktop keyboard/pointer acceptance.
        window.performClose(nil)
      } else {
        _ = try await worker.evaluate("zacroIdentityAcceptance.release(\(encoded))")
      }
      try await wait(cancel ? "nativeAuthCancellationRejectsAndCloses" : "nativeAuthCallbackResolvesAndCloses") {
        let status = try await worker.evaluate("zacroIdentityAcceptance.status(\(encoded))") as? [String: Any]
        return !window.isVisible && status?["state"] as? String == (cancel ? "rejected" : "resolved")
          && (cancel || status?["exactCallback"] as? Bool == true)
      }
      _ = try await worker.evaluate("zacroIdentityAcceptance.finish(\(encoded))")
    }
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
    owner.navigate("http://127.0.0.1:1/panel-error")
    try await wait("failedDocumentKeepsNativeSidePanelVisible") {
      guard let bounds = hostPage.documentBounds, let window = hostPage.nativeWindow else { return false }
      return hostPage.documentError != nil && hostPage.isSidePanelVisible && window.isVisible
        && bounds.width > 0 && bounds.width < window.frame.width - 20
        && owner.hasPresentedDocumentError(host.id)
    }
    guard let documentBounds = hostPage.documentBounds,
      let errorBounds = owner.presentedDocumentErrorBounds(host.id) else {
      throw Failure("Side panel error presentation bounds")
    }
    try require(abs(errorBounds.minX - documentBounds.minX) < 1
      && abs(errorBounds.minY - documentBounds.minY) < 1
      && abs(errorBounds.width - documentBounds.width) < 1
      && abs(errorBounds.height - documentBounds.height) < 1,
      "pageErrorCoversOnlyTheFailedDocument")
    let failedPanel = try await worker.evaluate("zacroAcceptance.panelState()") as? [String: Any]
    try require(failedPanel?["instance"] as? String == instance
      && failedPanel?["draft"] as? String == "unsaved panel draft", "pageErrorPreservesExtensionPanelDocument")
    let hostBrowserID = hostPage.browser?.id
    owner.navigate(url.appendingPathComponent("panel-recovered").absoluteString)
    try await loaded(hostPage)
    try await wait("sidePanelDocumentRecoversWithoutReplacingEitherView") {
      hostPage.documentError == nil && hostPage.browser?.id == hostBrowserID
        && hostPage.isSidePanelVisible && !owner.hasPresentedDocumentError(host.id)
    }
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
      if try await condition() { if record { try require(true, name) }; return }
      try await Task.sleep(for: .milliseconds(80))
    }
    checks[name] = false; throw Failure(name)
  }
  private func require(_ value: Bool, _ name: String) throws {
    checks[name] = value
    fputs("Native application check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
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
