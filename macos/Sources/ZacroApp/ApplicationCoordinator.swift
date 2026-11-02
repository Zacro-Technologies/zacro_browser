import AppKit
import Combine
import SwiftUI
import ZacroChromium
import ZacroCore
import ZacroServices

/// One runtime, repository, and service backend; every shell owns its own UI.
@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate {
  let engine: ChromiumEngine
  let repository: BrowserRepository
  var store: BrowserStore { repository.canonicalStore }
  private(set) var windows: [String: BrowserWindowCoordinator] = [:]
  private var observations: Set<AnyCancellable> = []
  var pendingDeletion: (Set<String>, () -> Void)?
  var profileDeletionPageIDs = Set<String>()
  var deletingProfileID: String? {
    didSet {
      guard oldValue != deletingProfileID else { return }
      if let oldValue { engine.setProfileMaintenance(oldValue, active: false) }
      if let deletingProfileID { engine.setProfileMaintenance(deletingProfileID, active: true) }
    }
  }
  var clearingHistoryProfiles: Set<String> = []
  var scopeCloseCancelled: (() -> Void)?
  lazy var favicons = FaviconCache(directory: engine.dataDirectory.appendingPathComponent("Icons"))
  lazy var downloads = NativeDownloads(store: store, engine: engine)
  lazy var bookmarks = NativeBookmarkSync(engine: engine, store: store)
  lazy var navigation = NativeNavigationCoordinator(engine: engine, store: store)
  lazy var services = NativeServicesModel(store: store, directory: engine.dataDirectory,
    conversationProfile: { [weak self] identifier in
      guard let coordinator = self else { return nil }
      return await MainActor.run {
        guard let owner = coordinator.windows[identifier], owner.windowContext.isOpen,
          !owner.windowContext.isClosing, !coordinator.engine.isTerminating,
          let profile = owner.store.state.activeProfile,
          coordinator.deletingProfileID != profile.id else { return nil }
        return AIProfileScope(id: profile.id, isPrivate: profile.isPrivate)
      }
    }) { [weak self] grants in
    guard let self else { throw CancellationError() }
    return try await self.readContext(grants)
  }
  lazy var extensionSync = NativeExtensionSync(engine: engine, store: store, services: services)
  lazy var extensionBrowser = NativeExtensionBrowser(repository: repository, engine: engine)
  private(set) var runtimeCapabilityTask: Task<Void, Never>?
  private(set) var runtimeCapabilitiesChecked = false
  private var runtimeCapabilities: CefNativeCapabilities?
  private var observedNativeProfiles: Set<String> = []
  private var libraryStatus: [String: [String: String]] = [:]

  init(engine: ChromiumEngine, repository: BrowserRepository) {
    self.engine = engine; self.repository = repository
    super.init()
  }

  var focusedCoordinator: BrowserWindowCoordinator? {
    if let keyWindow = NSApp.keyWindow, let context = engine.extensionPopupOwner(keyWindow),
      let owner = windows[context.id], owner.windowContext.isOpen { return owner }
    if let focused = repository.canonicalStore.state.focusedWindowID,
      let owner = windows[focused], owner.windowContext.isOpen { return owner }
    return windows.values.first { $0.windowContext.isOpen }
  }
  func owner(tabID: String) -> BrowserWindowCoordinator? {
    let source = tabID.hasPrefix("peek:") ? String(tabID.dropFirst(5)) : tabID
    guard let id = store.tab(source)?.windowID else { return nil }
    return windows[id]
  }
  private func owner(page: ChromiumPage) -> BrowserWindowCoordinator? {
    page.ownerWindowID.flatMap { windows[$0] } ?? owner(tabID: page.id)
  }

  /// The approved tab identity, rather than whichever same-profile shell most
  /// recently gained focus, determines where page context is read.
  func readContext(_ grants: [AIContextGrant]) async throws -> [AIPageExtract] {
    let conversationID = grants.first?.conversationID
    let requester = conversationID.flatMap { windows[$0] }
    let scope = requester?.store ?? store
    guard grants.count <= 6, Set(grants.map(\.id)).count == grants.count,
      grants.allSatisfy({ $0.conversationID == conversationID }),
      conversationID == nil || (requester?.windowContext.isOpen == true && requester?.windowContext.isClosing == false),
      let profile = scope.state.activeProfile, !profile.isPrivate,
      deletingProfileID != profile.id,
      grants.allSatisfy({ $0.profileID == profile.id }) else {
      throw ServiceError("CONTEXT_CHANGED", "Review the selected pages in their regular profile before sharing.")
    }
    var result: [AIPageExtract] = []
    for grant in grants {
      try Task.checkCancellation()
      guard scope.activeProfileID == profile.id, deletingProfileID != profile.id, !engine.isTerminating,
        conversationID == nil || (requester?.windowContext.isOpen == true && requester?.windowContext.isClosing == false),
        let owner = owner(tabID: grant.id),
        owner.windowContext.isOpen, !owner.windowContext.isClosing else {
        throw ServiceError("CONTEXT_CHANGED", "A selected page or its window changed. Review it again before sharing.")
      }
      let page = try await owner.readContext([grant])
      guard scope.activeProfileID == profile.id, deletingProfileID != profile.id, !engine.isTerminating,
        conversationID == nil || (requester?.windowContext.isOpen == true && requester?.windowContext.isClosing == false),
        self.owner(tabID: grant.id) === owner,
        owner.windowContext.isOpen, !owner.windowContext.isClosing,
        store.tab(grant.id)?.url == grant.url.absoluteString else {
        throw ServiceError("CONTEXT_CHANGED", "A selected page or its window changed while it was being read.")
      }
      result.append(contentsOf: page)
    }
    return result
  }

  func install() {
    store.enableDebouncedPersistence()
    let first = repository.windows.first { $0.id == repository.startupWindowID }
    if let first {
      engine.bindPrimaryWindow(id: first.id)
      if !first.isOpen { try? repository.updateWindow(first.id) { $0.isOpen = true; $0.closedAt = nil } }
      repository.focusWindow(first.id)
    }
    installRuntimeCallbacks()
    for session in repository.windows where session.isOpen {
      guard let scope = repository.store(for: session.id) else { continue }
      let context = engine.context(id: session.id) ?? engine.createWindow(id: session.id)
      let coordinator = BrowserWindowCoordinator(application: self, store: scope, context: context)
      windows[session.id] = coordinator
      coordinator.install(show: false)
    }
    if windows.isEmpty { newWindow() }
    focusedCoordinator?.windowContext.show()
    focusedCoordinator?.installMenus()
    downloads.onStarted = { [weak self] id in self?.owner(tabID: id)?.actions.library = "Downloads" }
    downloads.install()
    bookmarks.start()
    extensionSync.start()
    services.start()
    inspectRuntimeCapabilities()
    NSApp.activate(ignoringOtherApps: true)
    if !CommandLine.arguments.contains("--native-integration-acceptance"),
      let address = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"] {
      focusedCoordinator?.navigate(address)
    }
  }

  private func installRuntimeCallbacks() {
    engine.onUnownedPopupCreated = { [weak self] source, popup, foreground in
      guard let self else { popup.close(); return }
      do {
        let owner = try self.windowForManagedPage(source, foreground: foreground)
        if !owner.adoptPopup(popup, foreground: foreground) { popup.close() }
      } catch { popup.close(); self.focusedCoordinator?.showError(error.localizedDescription) }
    }
    engine.onUnownedOpenURL = { [weak self] source, url, foreground in
      guard let self else { return }
      do {
        let owner = try self.windowForManagedPage(source, foreground: foreground)
        let tab = BrowserAddress.extensionURL(url.absoluteString) != nil
          ? owner.store.createExtensionTab(url: url.absoluteString, activate: foreground)
          : owner.store.createTab(address: url.absoluteString, activate: foreground)
        if let tab { Task { _ = try? await owner.ensurePageReady(tab) } }
        owner.scheduleLayout()
      } catch { self.focusedCoordinator?.showError(error.localizedDescription) }
    }
    engine.onPageClosed = { [weak self] _ in self?.scheduleAllWindows() }
    engine.onPageCloseCancelled = { [weak self] id in
      self?.cancelProfileOperation(forPage: id)
    }
    navigation.beforeRestore = { [weak self] page in
      guard let self, !page.isPrivate, self.store.document(id: page.id) != nil else { return }
      self.inspectRuntimeCapabilities()
      await self.runtimeCapabilityTask?.value
      if self.extensionBrowser.enabled { try await self.extensionBrowser.prepareInitialNavigation(page) }
    }
    navigation.didFailPreparation = { [weak self] id, message in
      guard let self, let owner = self.owner(tabID: id), owner.selectedDocumentID == id,
        self.deletingProfileID == nil, owner.windowContext.isOpen,
        !owner.windowContext.isClosing, !self.engine.isTerminating else { return }
      if self.engine.pages[id]?.documentError != nil { owner.scheduleLayout(); return }
      owner.showError("This tab could not be opened: " + message)
    }
    navigation.didRestore = { [weak self] id, restored in
      self?.owner(tabID: id)?.didRestorePage(id, restored: restored)
    }
    engine.onTerminationChanged = { [weak self] terminating in
      guard let self else { return }
      if terminating {
        self.store.save()
        do { try self.store.flush() } catch { self.focusedCoordinator?.showError(error.localizedDescription) }
      } else { self.scheduleAllWindows() }
    }
    engine.beforeTermination = { [weak self] in
      guard let self else { return }
      for owner in self.windows.values { owner.prepareTermination() }
      for owner in self.windows.values { await owner.closeServicesPresentation() }
      await self.downloads.close()
      await self.bookmarks.close()
      await self.extensionBrowser.close()
      await self.extensionSync.close()
      await self.services.close()
      self.store.save()
      do { try self.store.flush() } catch { fputs("Zacro could not save its final session: \(error)\n", stderr) }
    }
    extensionBrowser.profileAvailable = { [weak self] id in self?.deletingProfileID != id }
    extensionBrowser.materializePage = { [weak self] tab in
      guard let self, let owner = self.owner(tabID: tab.id) else { throw CancellationError() }
      let page = try await owner.ensurePageReady(tab)
      try await self.navigation.waitForRestore(page)
      guard self.engine.pages[tab.id] === page else { throw CancellationError() }
      return page
    }
    extensionBrowser.prepareActionPopupDocument = { [weak self] windowID, profileID, authorize in
      guard let self, let owner = self.windows[windowID], self.focusedCoordinator === owner else {
        throw CancellationError()
      }
      return try await owner.extensionActionPage(profileID: profileID, requireFocused: true, authorize: authorize)
    }
    extensionBrowser.closeTab = { [weak self] id in await self?.owner(tabID: id)?.requestCloseTab(id) ?? false }
    extensionBrowser.navigateTab = { [weak self] tab, address in self?.owner(tabID: tab.id)?.navigateExtensionTab(tab, address: address) }
    extensionBrowser.activateTab = { [weak self] id in
      guard let owner = self?.owner(tabID: id) else { throw CancellationError() }
      try owner.activateExtensionTab(id)
    }
    extensionBrowser.discardTab = { [weak self] id in try await self?.owner(tabID: id)?.unloadInactiveTab(id) ?? false }
    extensionBrowser.closeWindow = { [weak self] id in await self?.windows[id]?.requestCloseWindow() ?? false }
    extensionBrowser.createWindow = { [weak self] request in
      guard let self else { throw CancellationError() }
      return try await self.createExtensionWindow(request)
    }
    extensionBrowser.moveTabs = { [weak self] ids, destination, index, authorize in
      guard let self else { throw CancellationError() }
      try await self.moveTabs(ids, toWindowID: destination, index: index, authorize: authorize)
    }
    extensionBrowser.promotePeek = { [weak self] sourceID, activate, authorize in
      guard let self, let owner = self.owner(tabID: sourceID) else { throw CancellationError() }
      return try await owner.promotePeekDocument(sourceID: sourceID, activate: activate, authorize: authorize)
    }
    extensionBrowser.restoreWindow = { [weak self] id, authorize in
      guard let self, !self.engine.isTerminating else { throw CancellationError() }
      try await authorize()
      return try self.reopenWindow(id: id).windowContext.id
    }
    extensionBrowser.isDiscarded = { [weak self] id in self?.owner(tabID: id)?.isDiscarded(id) ?? true }
    extensionBrowser.isAudible = { [weak self] id in self?.engine.pages[id]?.isAudible ?? false }
    extensionBrowser.didChange = { [weak self] in self?.scheduleAllWindows() }
    extensionSync.nativeEvent = { [weak self] profile, event in
      guard let self else { return }
      self.bookmarks.nativeEvent(profileID: profile, event: event)
      self.downloads.nativeEvent(profileID: profile, event: event)
      for owner in self.windows.values { owner.extensionEvent(profileID: profile, event: event) }
      if case let .hostRequest(request) = event {
        Task { [weak self] in await self?.extensionBrowser.handle(profileID: profile, request: request) }
      }
    }
    bookmarks.ensureObservation = { [weak self] id in
      guard let self else { throw CancellationError() }
      try await self.extensionSync.ensureNativeObservation(profileID: id)
    }
    extensionSync.nativeObservationReady = { [weak self] id in
      guard let self else { return }
      self.observedNativeProfiles.insert(id)
      self.bookmarks.observationReady(profileID: id)
      Task { [weak self] in try? await self?.downloads.refresh(profileID: id) }
    }
    bookmarks.onStatus = { [weak self] id, message in self?.publishLibraryStatus(profileID: id, section: "Bookmarks", message: message) }
    downloads.onStatus = { [weak self] id, message in self?.publishLibraryStatus(profileID: id, section: "Downloads", message: message) }
    services.sourceAction = { [weak self] action, payload in
      guard let owner = self?.focusedCoordinator else { throw CancellationError() }
      return try await owner.openAISources(action: action, payload: payload)
    }
    NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] event in
      guard let self, let window = event.object as? NSWindow else { return }
      self.focusChanged(window)
    }.store(in: &observations)
    for notification in [NSWindow.didResignKeyNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.publisher(for: notification).sink { [weak self] _ in
        self?.extensionBrowser.windowFocusChanged()
      }.store(in: &observations)
    }
  }

  private func focusChanged(_ window: NSWindow) {
    var parent = window
    while let next = parent.parent { parent = next }
    let context = engine.contexts.values.first { $0.window === parent }
      ?? engine.pages.values.first { $0.nativeWindow === window }.flatMap { $0.ownerWindowID.flatMap(engine.context(id:)) }
    guard let context, context.isOpen, let owner = windows[context.id] else { return }
    repository.focusWindow(context.id)
    owner.installMenus()
    services.refreshContext()
    extensionBrowser.windowFocusChanged()
  }

  func scheduleAllWindows() { for owner in windows.values { owner.scheduleLayout() } }
  func cancelProfileOperation(forPage id: String) {
    guard profileDeletionPageIDs.remove(id) != nil, pendingDeletion?.0.contains(id) == true else { return }
    pendingDeletion = nil
    let cancel = scopeCloseCancelled; scopeCloseCancelled = nil
    // The async clear operation owns its lock until its defer runs. Releasing
    // it here would let another window start before the old operation unwinds.
    if let cancel { cancel() } else { deletingProfileID = nil }
    scheduleAllWindows()
  }
  func libraryMessages(profileID: String) -> [String: String] { libraryStatus[profileID, default: [:]] }
  private func publishLibraryStatus(profileID: String, section: String, message: String?) {
    libraryStatus[profileID, default: [:]][section] = message
    for owner in windows.values where owner.store.activeProfileID == profileID {
      owner.actions.libraryMessages = libraryMessages(profileID: profileID)
    }
  }
  private func windowForManagedPage(_ page: ChromiumPage, foreground: Bool) throws -> BrowserWindowCoordinator {
    guard !page.isPrivate, deletingProfileID != page.profileID, !engine.isTerminating,
      store.state.profiles.contains(where: { $0.id == page.profileID && !$0.isPrivate }) else { throw CancellationError() }
    let matching = windows.values.filter { $0.windowContext.isOpen && !$0.windowContext.isClosing && $0.store.activeProfileID == page.profileID }
    if let owner = matching.first(where: { $0 === focusedCoordinator }) ?? matching.first {
      if foreground { repository.focusWindow(owner.windowContext.id); owner.windowContext.show() }
      return owner
    }
    let scope = try repository.makeWindow(profileID: page.profileID, focus: foreground)
    let owner = try present(scope, focused: foreground)
    if scope.state.tabs.count == 1, let placeholder = scope.state.tabs.first, placeholder.url == "about:blank" { scope.closeTab(id: placeholder.id) }
    return owner
  }
  func didCloseWindow(_ owner: BrowserWindowCoordinator) {
    let privateProfiles = repository.closeWindow(owner.windowContext.id)
    for id in privateProfiles {
      favicons.clear(profile: id)
      do { try engine.releasePrivateProfile(id) }
      catch { fputs("Zacro could not release a private context: \(error.localizedDescription)\n", stderr) }
    }
    Task { [weak self] in await self?.extensionBrowser.didCloseWindow(owner.windowContext.id) }
    scheduleAllWindows()
  }

  func newWindow() {
    do {
      let scope = try repository.makeWindow(profileID: focusedCoordinator?.store.activeProfileID)
      try present(scope, focused: true)
    } catch { focusedCoordinator?.showError(error.localizedDescription) }
  }
  func browsingWindow(profileID: String) throws -> BrowserWindowCoordinator {
    guard !engine.isTerminating else { throw CancellationError() }
    if let owner = windows.values.first(where: {
      !$0.isPopup && $0.windowContext.isOpen && !$0.windowContext.isClosing && $0.store.activeProfileID == profileID
    }) {
      owner.windowContext.show()
      return owner
    }
    return try present(repository.makeWindow(profileID: profileID), focused: true)
  }
  @discardableResult func reopenWindow(id: String) throws -> BrowserWindowCoordinator {
    guard !engine.isTerminating else { throw CancellationError() }
    return try present(repository.reopenWindow(id: id), focused: true)
  }
  @discardableResult private func present(_ scope: BrowserStore, focused: Bool) throws -> BrowserWindowCoordinator {
    guard let id = scope.owningWindowID else { throw CancellationError() }
    let context = engine.createWindow(id: id)
    let coordinator: BrowserWindowCoordinator
    if let existing = windows[id], existing.windowContext === context {
      coordinator = existing
      coordinator.reopen()
    } else {
      coordinator = BrowserWindowCoordinator(application: self, store: scope, context: context)
      windows[id] = coordinator
      coordinator.install(show: false)
    }
    applyRuntimeCapabilities(to: coordinator)
    if focused { repository.focusWindow(id); context.show() }
    else { context.window.orderFront(nil) }
    return coordinator
  }

  private func createExtensionWindow(_ request: NativeExtensionWindowRequest) async throws -> String {
    guard !engine.isTerminating, deletingProfileID != request.profileID else { throw CancellationError() }
    let moving = expandedTabIDs(request.movingTabID.map { [$0] } ?? [])
    let oldOwners = Dictionary(uniqueKeysWithValues: moving.compactMap { id in owner(tabID: id).map { (id, $0) } })
    for id in moving { try await oldOwners[id]?.prepareTabTransfer(id) }
    try await request.authorize()
    guard !engine.isTerminating, deletingProfileID != request.profileID,
      oldOwners.values.allSatisfy({ $0.windowContext.isOpen && !$0.windowContext.isClosing }) else { throw CancellationError() }
    var bounds = BrowserWindowBounds()
    bounds.sizeKind = "window"
    if let value = request.left { bounds.x = Double(value) }
    if let value = request.top { bounds.y = Double(value) }
    if let value = request.width { bounds.width = Double(value) }
    if let value = request.height { bounds.height = Double(value) }
    if request.state == "maximized" { bounds.maximized = true }
    let scope = try repository.makeWindow(profileID: request.profileID, movingTabIDs: moving,
      addresses: request.urls, bounds: bounds, nativeAuthorizations: request.nativeAuthorizations,
      kind: request.kind == .popup ? .popup : .normal, focus: request.focused)
    guard let id = scope.owningWindowID else { throw CancellationError() }
    let created = scope.state.tabs.filter { !moving.contains($0.id) }
    if let openerRequestID = request.openerRequestID {
      extensionBrowser.setCreationOpener(tabIDs: created.map(\.id), requestID: openerRequestID)
    }
    let coordinator = try present(scope, focused: request.focused)
    for tabID in moving { transferPresentation(tabID, from: oldOwners[tabID], to: coordinator) }
    switch request.state {
    case "minimized": coordinator.window?.miniaturize(nil)
    case "maximized": if coordinator.window?.isZoomed == false { coordinator.window?.zoom(nil) }
    case "fullscreen": if coordinator.window?.styleMask.contains(.fullScreen) == false { coordinator.window?.toggleFullScreen(nil) }
    default: break
    }
    coordinator.scheduleLayout()
    if request.openerRequestID != nil {
      for tab in created { _ = try await coordinator.ensurePageReady(tab) }
    }
    return id
  }

  func transferPresentation(_ tabID: String, from source: BrowserWindowCoordinator?, to destination: BrowserWindowCoordinator) {
    let state = source?.detachTab(tabID)
    for id in [tabID, "peek:" + tabID] {
      if engine.pages[id] != nil { engine.movePage(id: id, toWindowID: destination.windowContext.id) }
    }
    destination.attachTab(tabID, state: state)
    source?.scheduleLayout(); destination.scheduleLayout()
  }

  private func expandedTabIDs(_ ids: [String]) -> [String] {
    var result = ids
    for id in ids {
      if let split = store.split(for: id) {
        for member in split.tabIDs where !result.contains(member) { result.append(member) }
      }
    }
    return result
  }

  func moveTabs(_ requested: [String], toWindowID id: String, index: Int, authorize: () async throws -> Void) async throws {
    var ids = requested
    for tabID in requested where store.tab(tabID)?.windowID != id {
      for member in expandedTabIDs([tabID]) where !ids.contains(member) { ids.append(member) }
    }
    guard let destination = windows[id], destination.windowContext.isOpen,
      !destination.windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    let sources = Dictionary(uniqueKeysWithValues: ids.compactMap { id in owner(tabID: id).map { (id, $0) } })
    guard sources.count == ids.count else { throw CancellationError() }
    for id in ids { try await sources[id]?.prepareTabTransfer(id) }
    try await authorize()
    guard destination.windowContext.isOpen, !destination.windowContext.isClosing,
      !engine.isTerminating, sources.values.allSatisfy({ $0.windowContext.isOpen && !$0.windowContext.isClosing }) else { throw CancellationError() }
    try repository.moveTabs(ids, toWindowID: id, index: index)
    for id in ids where sources[id] !== destination { transferPresentation(id, from: sources[id], to: destination) }
    scheduleAllWindows()
  }

  func inspectRuntimeCapabilities() {
    guard !runtimeCapabilitiesChecked, runtimeCapabilityTask == nil else { return }
    runtimeCapabilityTask = Task { [weak self] in
      guard let self else { return }
      defer { self.runtimeCapabilityTask = nil }
      do {
        let capabilities = try await self.engine.nativeCapabilities()
        self.runtimeCapabilities = capabilities
        self.runtimeCapabilitiesChecked = true
        self.extensionBrowser.enabled = capabilities.extensionBrowser == true
        self.bookmarks.enabled = capabilities.bookmarks == true
        self.downloads.enabled = capabilities.downloads == true
        for id in self.observedNativeProfiles { Task { [weak self] in try? await self?.downloads.refresh(profileID: id) } }
        for owner in self.windows.values { self.applyRuntimeCapabilities(to: owner) }
        self.extensionBrowser.reconcile()
      } catch {
        if let failure = error as? CefDevToolsError, failure.isUnsupportedMethod { self.runtimeCapabilitiesChecked = true }
      }
    }
  }
  private func applyRuntimeCapabilities(to owner: BrowserWindowCoordinator) {
    guard let capabilities = runtimeCapabilities else { return }
    if capabilities.browsingData { owner.actions.libraryCapabilities.formUnion(["data:clear", "history:clear"]) }
    if capabilities.documentState && capabilities.retainedDiscard == true && capabilities.volatileDiscard == true && capabilities.encryptedNavigation == true {
      owner.actions.libraryCapabilities.insert("tab:sleep")
    }
  }

  func applicationWillTerminate(_ notification: Notification) { store.save(); try? store.flush() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let owner = focusedCoordinator { owner.windowContext.show() }
    else if let session = repository.savedWindows.first {
      do { try reopenWindow(id: session.id) }
      catch { newWindow() }
    } else { newWindow() }
    return true
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    _ = applicationShouldHandleReopen(application, hasVisibleWindows: focusedCoordinator != nil)
    for url in urls.prefix(32) where BrowserAddress.webURL(url.absoluteString) != nil {
      focusedCoordinator?.actions.newTab(url.absoluteString)
    }
  }
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { focusedCoordinator?.applicationDockMenu(sender) }
}
