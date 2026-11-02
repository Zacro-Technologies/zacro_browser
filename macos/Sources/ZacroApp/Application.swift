import AppKit
import Combine
import SwiftUI
import ZacroChromium
import ZacroCore
import ZacroServices

@main
enum ZacroApplication {
  @MainActor static func main() {
    let integrationRequested = CommandLine.arguments.contains("--native-integration-acceptance")
    guard !integrationRequested || CommandLine.arguments.contains("--engine-acceptance") else {
      fputs("Application integration requires the disposable engine acceptance mode.\n", stderr)
      exit(1)
    }
    let base =
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_DATA"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Zacro Native")
    let engine = ChromiumEngine(dataDirectory: base)
    do {
      try engine.start()
      defer { engine.shutdown() }
      if CommandLine.arguments.contains("--engine-acceptance"),
        !CommandLine.arguments.contains("--native-ui-review"),
        !integrationRequested,
        ProcessInfo.processInfo.environment["ZACRO_NATIVE_DATA"] != nil,
        let raw = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"],
        let url = URL(string: raw), url.host == "127.0.0.1"
      {
        let acceptance = EngineAcceptance(engine: engine)
        NSApp.setActivationPolicy(.regular)
        acceptance.run(url: url)
        withExtendedLifetime(acceptance) { NSApp.run() }
        return
      }
      let coordinator = ApplicationCoordinator(engine: engine, repository: BrowserRepository(directory: base))
      if integrationRequested { coordinator.store.updateSettings { $0.onboardingCompleted = true } }
      NSApplication.shared.delegate = coordinator
      NSApplication.shared.setActivationPolicy(.regular)
      coordinator.install()
      let integration = integrationRequested ? BrowserIntegrationAcceptance(application: coordinator) : nil
      if let integration, let raw = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"], let url = URL(string: raw) {
        integration.run(url: url)
      }
      withExtendedLifetime((coordinator, integration)) { NSApplication.shared.run() }
      coordinator.store.save()
      try coordinator.store.flush()
    } catch {
      // Initialization failures must never silently switch engine or remove sandboxing.
      fputs("Zacro Chromium initialization failed: \(error)\n", stderr)
      exit(1)
    }
  }
}

@MainActor
final class BrowserWindowCoordinator: NSObject {
  unowned let application: ApplicationCoordinator
  let windowContext: ChromiumWindowContext
  var window: NSWindow? { windowContext.window }
  var isPopup: Bool { application.repository.windows.first(where: { $0.id == windowContext.id })?.kind == .popup }
  var engine: ChromiumEngine { application.engine }
  let store: BrowserStore
  let actions = BrowserActions()
  private var observations: Set<AnyCancellable> = []
  private var host: PassthroughHostingView<AnyView>?
  private var contentFrame = CGRect.zero
  private var layoutQueued = false
  private var splitResizeDraft: (id: String, ratio: Double)?
  private var keyMonitor: Any?
  private var replayingExtensionKey = false
  private let peekPanel = PeekPanelController()
  private var pendingDeletion: (Set<String>, () -> Void)? { get { application.pendingDeletion } set { application.pendingDeletion = newValue } }
  private var profileDeletionPageIDs: Set<String> { get { application.profileDeletionPageIDs } set { application.profileDeletionPageIDs = newValue } }
  private var deletingProfileID: String? { get { application.deletingProfileID } set { application.deletingProfileID = newValue } }
  private var scopeCloseCancelled: (() -> Void)? { get { application.scopeCloseCancelled } set { application.scopeCloseCancelled = newValue } }
  private var favicons: FaviconCache { application.favicons }
  private var peekFrames: [String: CGRect] = [:]
  private var peekOrigins: [String: CGRect] = [:]
  private var peekClosingSnapshots: [String: NSImage] = [:]
  private var retiringPageIDs = Set<String>()
  private var visiblePageFrames: [String: CGRect] = [:]
  private var sidePanelPageIDs = Set<String>()
  private var modelURLs: [String: String] = [:]
  private var iconDestinations: [String: String] = [:]
  private var pendingHistory: [String: (source: String?, destination: String)] = [:]
  private var restoredHistoryPages = Set<String>()
  private var downloads: NativeDownloads { application.downloads }
  private var navigation: NativeNavigationCoordinator { application.navigation }
  private var extensionSync: NativeExtensionSync { application.extensionSync }
  private var extensionBrowser: NativeExtensionBrowser { application.extensionBrowser }
  private var runtimeCapabilityTask: Task<Void, Never>? { application.runtimeCapabilityTask }
  private var runtimeCapabilitiesChecked: Bool { application.runtimeCapabilitiesChecked }
  private var dormantPages = Set<String>()
  private struct PagePreparation { let reservation: ChromeTabMaterialization? }
  private var pagePreparations: [String: PagePreparation] = [:]
  private var pageCreations: [String: Task<ChromiumPage?, Error>] = [:]
  private var pageCreationFailures: [String: String] = [:]
  private var reservedPages = Set<String>()
  private var dormantNavigations: [String: Task<Void, Error>] = [:]
  private var discardOperations: [String: Task<Void, Error>] = [:]
  private var closeWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
  private var windowCloseWaiters: [CheckedContinuation<Bool, Never>] = []
  private var discardingPages = Set<String>()
  private var mediaPermissionPages = Set<String>()
  private var idleSweep: Task<Void, Never>?
  private lazy var extensions = NativeExtensionsModel(store: store, engine: engine, actions: actions)
  private var siteControlsInitialized = false
  private var siteControlProfileID: String?
  private var commandFingerprint = ""
  private var recentTabCycle: [String]?
  private var recentTabIndex = 0
  private var recentModifiers: NSEvent.ModifierFlags = []
  private var scopedServices: NativeServicesModel?
  var services: NativeServicesModel {
    if let scopedServices { return scopedServices }
    let model = NativeServicesModel(store: store, sharing: application.services)
    model.sourceAction = { [weak self] action, payload in
      guard let self else { throw CancellationError() }
      return try await self.openAISources(action: action, payload: payload)
    }
    scopedServices = model
    return model
  }
  init(application: ApplicationCoordinator, store: BrowserStore, context: ChromiumWindowContext) {
    self.application = application
    self.store = store
    self.windowContext = context
  }
  var windowPages: [String: ChromiumPage] { engine.pages.filter { $0.value.ownerWindowID == windowContext.id } }
  struct TabPresentationState {
    var urls: [String: String] = [:]
    var pending: [String: (source: String?, destination: String)] = [:]
    var dormant: Set<String> = []
    var restored: Set<String> = []
  }
  func isDiscarded(_ id: String) -> Bool { dormantPages.contains(id) || engine.pages[id] == nil }
  func activateExtensionTab(_ id: String) throws {
    guard store.document(id: id) != nil else { throw CancellationError() }
    pageCreationFailures.removeValue(forKey: id)
    try store.selectDocumentDurably(id: id)
    actions.nativePageVisible = false
    scheduleLayout()
  }
  func extensionEvent(profileID: String, event: ChromeExtensionEvent) {
    extensions.nativeEvent(profileID: profileID, event: event)
  }
  func didRestorePage(_ id: String, restored: Bool) {
    if restored { restoredHistoryPages.remove(id) }
    updateNavigationState(activePage)
    scheduleLayout()
  }
  func prepareTermination() {
    extensions.close()
    idleSweep?.cancel()
    for task in pageCreations.values { task.cancel() }
    for task in dormantNavigations.values { task.cancel() }
    pagePreparations.removeAll()
  }
  func closeServicesPresentation() async {
    let model = scopedServices; scopedServices = nil
    await model?.close()
  }
  func reopen() {
    actions.nativePageVisible = false
    pageCreationFailures.removeAll()
    extensions.refresh()
    services.start()
    scheduleLayout()
  }
  func prepareTabTransfer(_ id: String) async throws {
    guard store.tab(id)?.isClosed == false, closeWaiters[id] == nil,
      !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    for key in [id, "peek:" + id] {
      if let task = pageCreations[key] { task.cancel(); _ = try? await task.value }
    }
    try await discardOperations[id]?.value
    try await dormantNavigations[id]?.value
    for key in [id, "peek:" + id] {
      if let page = engine.pages[key] { try await navigation.waitForRestore(page) }
    }
  }
  func detachTab(_ id: String) -> TabPresentationState {
    var saved = TabPresentationState()
    if store.state.activeTabID == id || peekFrames[id] != nil { hidePeekPresentation(immediately: true) }
    for key in [id, "peek:" + id] {
      engine.pages[key]?.hide()
      engine.pages[key]?.setPresentationParent(nil)
      saved.urls[key] = modelURLs.removeValue(forKey: key)
      saved.pending[key] = pendingHistory.removeValue(forKey: key)
      if dormantPages.remove(key) != nil { saved.dormant.insert(key) }
      if restoredHistoryPages.remove(key) != nil { saved.restored.insert(key) }
      visiblePageFrames.removeValue(forKey: key)
      pageCreationFailures.removeValue(forKey: key)
    }
    peekFrames.removeValue(forKey: id); peekOrigins.removeValue(forKey: id)
    peekClosingSnapshots.removeValue(forKey: id)
    actions.audibleTabIDs.remove(id)
    return saved
  }
  func attachTab(_ id: String, state: TabPresentationState?) {
    guard let tab = store.tab(id) else { return }
    if let state {
      modelURLs.merge(state.urls) { _, new in new }
      pendingHistory.merge(state.pending) { _, new in new }
      dormantPages.formUnion(state.dormant)
      restoredHistoryPages.formUnion(state.restored)
    }
    for key in [id, "peek:" + id] {
      guard let page = engine.pages[key] else { continue }
      modelURLs[key] = modelURLs[key] ?? (key == id ? tab.url : tab.peek?.url)
      wire(page, tabID: id, peek: key != id)
    }
    if let page = engine.pages[id] { updateIcon(page, tab: tab) }
    scheduleLayout()
  }
  func adoptPopup(_ popup: ChromiumPage, spaceID: String? = nil, foreground: Bool) -> Bool {
    let profileID = spaceID.flatMap { id in store.state.spaces.first { $0.id == id }?.profileID } ?? store.activeProfileID
    guard engine.pages[popup.id] === popup, !popup.creationFailed,
      popup.profileID == profileID, !windowContext.isClosing else { return false }
    let address = popup.browser?.url?.absoluteString ?? "about:blank"
    let destination = BrowserAddress.extensionURL(address) != nil
      ? store.createExtensionTab(url: address, spaceID: spaceID, activate: false)
      : store.createTab(address: address, spaceID: spaceID, activate: false)
    guard let tab = destination else { return false }
    guard engine.movePage(id: popup.id, toWindowID: windowContext.id),
      engine.adoptPage(fromID: popup.id, toID: tab.id) != nil else {
      store.closeTab(id: tab.id); return false
    }
    if let openerID = popup.openerID, let opener = application.store.document(id: openerID),
      !opener.isClosed, application.store.profileID(for: opener) == profileID {
      store.updateTab(tab.id) { $0.openerTabID = openerID }
    }
    modelURLs[tab.id] = popup.browser?.url?.absoluteString ?? tab.url
    wire(popup, tabID: tab.id, peek: false)
    if foreground { store.selectTab(id: tab.id); popup.focus() }
    scheduleLayout()
    return true
  }
  var activePage: ChromiumPage? {
    guard let tab = store.state.activeTab else { return nil }
    if tab.peek?.isPresented != false, tab.peek != nil, let preview = engine.pages["peek:" + tab.id] { return preview }
    return engine.pages[tab.id]
  }
  var selectedDocumentID: String? {
    guard let tab = store.state.activeTab else { return nil }
    return tab.peek != nil && tab.peek?.isPresented != false ? "peek:" + tab.id : tab.id
  }
  var visibleSplit: SplitGroup? {
    guard let id = store.state.activeTabID, var split = store.split(for: id),
      split.spaceID == store.state.activeSpaceID else { return nil }
    let range = splitResizeRange(width: contentFrame.width)
    let ratio = splitResizeDraft?.id == split.id ? splitResizeDraft!.ratio : split.ratio
    split.ratio = min(range.upperBound, max(range.lowerBound, ratio))
    return split
  }
  func splitResizeRange(width: Double) -> ClosedRange<Double> {
    let available = max(2, width - 6)
    let minimum = min(160, floor(available / 2)) / available
    return max(0.1, minimum)...min(0.9, 1 - minimum)
  }
  func previewSplitRatio(id: String, ratio: Double) {
    guard visibleSplit?.id == id, ratio.isFinite else { return }
    splitResizeDraft = (id, ratio)
    scheduleLayout()
  }
  func finishSplitResize(id: String, ratio: Double?) {
    if splitResizeDraft?.id == id { splitResizeDraft = nil }
    if let ratio, visibleSplit?.id == id { store.setSplitRatio(id: id, ratio: ratio) }
    scheduleLayout()
  }
  private func hidePeekPresentation(immediately: Bool = false) {
    for page in windowPages.values where page.id.hasPrefix("peek:") {
      page.setPresentationParent(nil)
    }
    peekPanel.hide(immediately: immediately)
  }
  func install(show: Bool = true) {
    guard let window = window else { return }
    store.enableDebouncedPersistence()
    window.titleVisibility = isPopup ? .visible : .hidden
    window.titlebarAppearsTransparent = !isPopup
    if isPopup { window.styleMask.remove(.fullSizeContentView) }
    else { window.styleMask.insert(.fullSizeContentView) }
    window.isOpaque = false
    window.backgroundColor = .clear
    restoreWindowBounds(window)
    guard let parent = window.contentView else { return }
    let root = BrowserShell(store: store, actions: actions) { [weak self] in
      NativeContentOverlay(store: self!.store, coordinator: self!)
    }
    let host = PassthroughHostingView(rootView: AnyView(root))
    host.frame = parent.bounds
    host.autoresizingMask = [.width, .height]
    host.shouldPassThrough = { [weak self] point in self?.passesThrough(point) ?? false }
    parent.addSubview(host, positioned: .above, relativeTo: nil)
    self.host = host
    for notification in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
      NotificationCenter.default.publisher(for: notification, object: window)
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self, weak window] _ in
          guard let self, let window else { return }
          self.rememberWindowBounds(window)
        }.store(in: &observations)
    }
    actions.navigate = { [weak self] address in self?.navigate(address) }
    actions.newTab = { [weak self] address in
      guard let self, let tab = self.store.createTab(address: address) else { return }
      self.actions.nativePageVisible = false
      _ = self.page(for: tab)
      self.scheduleLayout()
    }
    actions.activate = { [weak self] id in
      self?.pageCreationFailures.removeValue(forKey: id)
      self?.actions.nativePageVisible = false
      self?.scheduleLayout()
    }
    actions.back = { [weak self] in self?.goBack() }
    actions.forward = { [weak self] in self?.goForward() }
    actions.reload = { [weak self] in
      guard let self else { return }
      if let page = self.activePage {
        if page.isLoading { page.stop() } else { page.reload() }
      } else { self.retryActivePage() }
    }
    actions.zoom = { [weak self] in self?.activePage?.zoom(by: $0) }
    actions.printPage = { [weak self] in self?.activePage?.printPage() }
    actions.find = { [weak self] in self?.find() }
    actions.findNext = { [weak self] in guard let self else { return }; self.activePage?.find(self.actions.findQuery) }
    actions.findPrevious = { [weak self] in guard let self else { return }; self.activePage?.find(self.actions.findQuery, forward: false) }
    actions.updateFind = { [weak self] value in self?.activePage?.find(String(value.prefix(1000))) }
    actions.closeFind = { [weak self] in self?.actions.findVisible = false; self?.activePage?.browser?.stopFinding(clearSelection: true); self?.activePage?.focus() }
    actions.closeTab = { [weak self] id in
      Task { [weak self] in _ = await self?.requestCloseTab(id) }
    }
    actions.deleteSpace = { [weak self] id in self?.deleteScope(space: id, profile: nil) }
    actions.deleteProfile = { [weak self] id in self?.deleteScope(space: nil, profile: id) }
    actions.openExtensions = { [weak self] in self?.openExtensions(store: false) }
    actions.openExtensionStore = { [weak self] in self?.openExtensions(store: true) }
    actions.iconForURL = { [weak self] address in
      guard let self, let url = URL(string: address) else { return nil }
      return self.favicons.cached(profile: self.store.activeProfileID, url: url,
        isPrivate: self.store.state.activeProfile?.isPrivate ?? true)
    }
    actions.onLayout = { [weak self] frame, _ in
      guard let self, self.contentFrame != frame else { return }
      if ProcessInfo.processInfo.environment["ZACRO_NATIVE_LAYOUT_TRACE"] == "1" { fputs("Zacro page frame: \(frame) Library: \(self.actions.library ?? "closed")\n", stderr) }
      self.contentFrame = frame
      self.scheduleLayout()
    }
    contentFrame = actions.contentFrame
    windowContext.onLayout = { [weak self] in self?.scheduleLayout() }
    windowContext.onClosed = { [weak self] in
      guard let self else { return }
      self.hidePeekPresentation(immediately: true)
      self.actions.nativePageVisible = false
      self.visiblePageFrames.removeAll()
      self.sidePanelPageIDs.removeAll()
      self.peekFrames.removeAll()
      self.peekClosingSnapshots.removeAll()
      self.extensions.close()
      self.actions.palette = false; self.actions.library = nil; self.actions.themeEditor = false
      let presentationServices = self.scopedServices; self.scopedServices = nil
      Task { await presentationServices?.close() }
      self.finishWindowCloseWaiters(accepted: true)
      self.application.didCloseWindow(self)
    }
    windowContext.onCloseCancelled = { [weak self] in
      self?.finishWindowCloseWaiters(accepted: false)
      self?.scheduleLayout()
    }
    windowContext.beforeClosingDocuments = { [weak self] in
      guard let self else { return true }
      guard self.deletingProfileID == nil else {
        self.showError("Wait for the current profile operation to finish before closing the browser.")
        return false
      }
      for task in self.pageCreations.values { task.cancel() }
      for task in self.dormantNavigations.values { task.cancel() }
      for task in Array(self.discardOperations.values) { _ = try? await task.value }
      for task in Array(self.dormantNavigations.values) { _ = try? await task.value }
      await self.navigation.captureAll(windowID: self.windowContext.id)
      self.store.save()
      do { try self.store.flush(); return true }
      catch { self.showError("Your session could not be saved: \(error.localizedDescription)"); return false }
    }
    store.$state.dropFirst().sink { [weak self] _ in self?.scheduleLayout() }.store(
      in: &observations)
    actions.$palette.dropFirst().sink { [weak self] _ in self?.scheduleLayout() }.store(
      in: &observations)
    actions.$library.dropFirst().sink { [weak self] section in
      guard let self else { return }
      if section != nil { self.window?.makeKeyAndOrderFront(nil) }
      self.scheduleLayout()
    }.store(in: &observations)
    installServices()
    services.start()
    refreshDefaultBrowser()
    refreshCommands()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      self?.handleKey(event) == true ? nil : event
    }
    scheduleLayout()
    if show { windowContext.show() } else { window.orderFront(nil) }
    Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
      guard let self, self.idleSweep == nil else { return }
      self.idleSweep = Task { [weak self] in
        guard let self else { return }
        defer { self.idleSweep = nil }
        await self.maintainInactiveTabs()
      }
    }.store(in: &observations)
  }
  private func passesThrough(_ point: NSPoint) -> Bool {
    guard let host, store.state.activeTab != nil, !actions.palette,
      actions.library == nil, !actions.themeEditor
    else { return false }
    let top = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
    if !isPopup && !store.state.settings.sidebarVisible
      && CGRect(x: contentFrame.minX, y: contentFrame.minY, width: 56, height: 56).contains(top)
    {
      return false
    }
    if let id = store.state.activeTabID, store.state.activeTab?.peek != nil, store.state.activeTab?.peek?.isPresented != false,
      let frame = peekFrames[id]
    {
      return frame.contains(top)
    }
    if let split = visibleSplit {
      let x = contentFrame.minX + (contentFrame.width - 6) * split.ratio
      if CGRect(x: x - 4, y: contentFrame.minY, width: 14, height: contentFrame.height).contains(
        top)
      {
        return false
      }
    }
    return contentFrame.contains(top)
  }
  func scheduleLayout() {
    guard !engine.isTerminating, !layoutQueued else { return }
    layoutQueued = true
    DispatchQueue.main.async { [weak self] in
      self?.layoutQueued = false
      self?.layoutPages()
    }
  }
  private func page(for tab: BrowserTab) -> ChromiumPage? {
    let isPeek = tab.id.hasPrefix("peek:")
    let sourceID = isPeek ? String(tab.id.dropFirst(5)) : tab.id
    guard !tab.isClosed, let profileID = store.profileID(for: tab),
      deletingProfileID != profileID,
      let profile = store.state.profiles.first(where: { $0.id == profileID })
    else { return nil }
    if let existing = engine.pages[tab.id],
      existing.profileID != profileID || existing.isPrivate != profile.isPrivate
    {
      retirePage(id: tab.id)
      return nil
    }
    guard !retiringPageIDs.contains(tab.id), !discardingPages.contains(tab.id) else { return nil }
    if dormantNavigations[tab.id] != nil { return engine.pages[tab.id] }
    if dormantPages.contains(tab.id), modelURLs[tab.id] != tab.url {
      navigateExtensionTab(tab, address: tab.url)
      return nil
    }
    let existed = engine.pages[tab.id] != nil
    if !existed && !profile.isPrivate && pagePreparations[tab.id] == nil {
      if pageCreationFailures[tab.id] != tab.url { beginPageCreation(tab) }
      return nil
    }
    let reservation = !existed ? pagePreparations.removeValue(forKey: tab.id)?.reservation : nil
    let wasReserved = reservedPages.remove(tab.id) != nil
    let page = engine.page(
      id: tab.id, profileID: profileID, isPrivate: profile.isPrivate,
      url: existed || profile.isPrivate ? (URL(string: tab.url) ?? URL(string: "about:blank")!) : nil,
      nativeReservation: reservation, ownerWindowID: windowContext.id)
    if !existed || wasReserved {
      page.hide()
      if tab.navigation.count > 1 { restoredHistoryPages.insert(tab.id) }
      modelURLs[tab.id] = tab.url
    } else if modelURLs[tab.id] != tab.url, pendingHistory[tab.id] == nil,
      let url = URL(string: tab.url)
    {
      // Collection imports and explicit state navigation load the new destination,
      // without reusing a document from a different profile.
      if tab.nativeNavigation != nil { navigateExtensionTab(tab, address: tab.url) }
      else {
        pendingHistory[tab.id] = (page.url?.absoluteString ?? modelURLs[tab.id], tab.url)
        modelURLs[tab.id] = tab.url
        navigation.cancelRestore(page)
        page.load(url)
      }
    }
    wire(page, tabID: sourceID, peek: isPeek)
    let wasDormant = dormantPages.remove(tab.id) != nil
    if ((!existed || wasReserved) && !profile.isPrivate) || wasDormant {
      navigation.restore(page, tabID: sourceID, peek: isPeek, address: tab.url, dormant: wasDormant)
    } else if wasReserved, let url = URL(string: tab.url) {
      page.load(url)
    }
    if !existed { inspectRuntimeCapabilities(page) }
    if !isPeek { updateIcon(page, tab: tab) }
    return page
  }
  /// A public tab reserves its Chrome identity before creating a WebContents.
  /// Querying unloaded tabs never invokes this path or opens a hidden window.
  private func beginPageCreation(_ tab: BrowserTab) {
    guard pageCreations[tab.id] == nil, let profileID = store.profileID(for: tab) else { return }
    pageCreationFailures.removeValue(forKey: tab.id)
    pageCreations[tab.id] = Task { [weak self] in
      guard let self else { throw CancellationError() }
      defer {
        self.pageCreations.removeValue(forKey: tab.id)
        self.pagePreparations.removeValue(forKey: tab.id)
        self.scheduleLayout()
      }
      do {
        self.inspectRuntimeCapabilities()
        await self.runtimeCapabilityTask?.value
        try Task.checkCancellation()
        guard self.runtimeCapabilitiesChecked else { throw CefDevToolsError.unavailable }
        let reservation = self.extensionBrowser.enabled
          ? try await self.extensionBrowser.preparePageCreation(tabID: tab.id) : nil
        guard let requested = self.store.document(id: tab.id) else { throw CancellationError() }
        _ = try await self.navigation.validateDestination(of: requested)
        try Task.checkCancellation()
        guard self.windowContext.isOpen, !self.windowContext.isClosing, !self.engine.isTerminating,
          self.deletingProfileID != profileID,
          let current = self.store.document(id: tab.id), !current.isClosed,
          self.store.profileID(for: current) == profileID, current.url == requested.url,
          current.nativeNavigation == requested.nativeNavigation else { throw CancellationError() }
        self.pagePreparations[tab.id] = PagePreparation(reservation: reservation)
        guard let page = self.page(for: current) else { throw CefDevToolsError.unavailable }
        _ = try await page.ready()
        guard self.engine.pages[tab.id] === page else { throw CancellationError() }
        return page
      } catch {
        if !(error is CancellationError), let current = self.store.document(id: tab.id), !current.isClosed {
          self.pageCreationFailures[tab.id] = current.url
          if self.selectedDocumentID == tab.id, self.windowContext.isOpen,
            !self.windowContext.isClosing, !self.engine.isTerminating, self.deletingProfileID == nil {
            self.showError("This tab could not be opened: " + error.localizedDescription)
          }
        }
        throw error
      }
    }
  }
  func ensurePageReady(_ tab: BrowserTab) async throws -> ChromiumPage {
    pageCreationFailures.removeValue(forKey: tab.id)
    try await discardOperations[tab.id]?.value
    try await dormantNavigations[tab.id]?.value
    guard let current = store.document(id: tab.id), !current.isClosed,
      store.profileID(for: current) == store.profileID(for: tab) else { throw CancellationError() }
    let page: ChromiumPage
    if let existing = self.page(for: current) { page = existing }
    else if let pending = pageCreations[tab.id], let created = try await pending.value { page = created }
    else if let pending = dormantNavigations[tab.id] {
      try await pending.value
      guard let restored = self.page(for: store.document(id: tab.id) ?? tab) else { throw CefDevToolsError.unavailable }
      page = restored
    } else { throw CefDevToolsError.unavailable }
    _ = try await page.ready()
    guard owns(page, tabID: tab.id) else { throw CancellationError() }
    return page
  }
  private func retryActivePage() {
    guard let id = selectedDocumentID, let tab = store.document(id: id) else { return }
    pageCreationFailures.removeValue(forKey: tab.id)
    _ = page(for: tab)
    scheduleLayout()
  }
  func requestCloseTab(_ id: String) async -> Bool {
    guard store.document(id: id) != nil else { return false }
    pageCreations[id]?.cancel()
    dormantNavigations[id]?.cancel()
    pagePreparations.removeValue(forKey: id)
    pageCreationFailures.removeValue(forKey: id)
    if id.hasPrefix("peek:") {
      if let page = engine.pages[id] { return await requestClosePage(page) }
      do { try store.closePeekDurably(tabID: String(id.dropFirst(5))); return true }
      catch { showError(error.localizedDescription); return false }
    }
    pageCreations["peek:" + id]?.cancel()
    if let preview = engine.pages["peek:" + id], !(await requestClosePage(preview)) { return false }
    if let page = engine.pages[id] { return await requestClosePage(page) }
    store.closeTab(id: id)
    return true
  }
  func navigateExtensionTab(_ tab: BrowserTab, address: String) {
    guard let url = URL(string: address) else { return }
    guard let page = engine.pages[tab.id] else {
      pageCreationFailures.removeValue(forKey: tab.id)
      _ = self.page(for: tab)
      scheduleLayout()
      return
    }
    navigation.cancelRestore(page)
    reservedPages.remove(tab.id)
    pendingHistory[tab.id] = (page.url?.absoluteString, address)
    modelURLs[tab.id] = address
    // Multiple URL updates during one restore share the native operation. Its
    // final load uses the latest committed model destination.
    if dormantNavigations[tab.id] != nil { return }
    let wasDormant = dormantPages.remove(tab.id) != nil
    if wasDormant || discardOperations[tab.id] != nil || tab.nativeNavigation != nil {
      let discarding = discardOperations[tab.id]
      let mustWake = wasDormant || discarding != nil
      if mustWake { discardingPages.insert(tab.id) }
      dormantNavigations[tab.id] = Task { [weak self, weak page] in
        guard let self, let page else { throw CancellationError() }
        defer {
          self.dormantNavigations.removeValue(forKey: tab.id)
          self.discardingPages.remove(tab.id)
          self.scheduleLayout()
        }
        do {
          try await discarding?.value
          try Task.checkCancellation()
          if mustWake {
            let browser = try await page.ready()
            try await browser.restoreDiscardedDocument()
          }
          self.dormantPages.remove(tab.id)
          while true {
            try Task.checkCancellation()
            guard self.owns(page, tabID: tab.id), !self.windowContext.isClosing, !self.engine.isTerminating,
              let destination = self.store.document(id: tab.id) else { throw CancellationError() }
            self.modelURLs[tab.id] = destination.url
            do { try await self.navigation.loadDestination(page, tab: destination) }
            catch {
              if !Task.isCancelled, self.owns(page, tabID: tab.id), self.store.document(id: tab.id)?.url != destination.url { continue }
              throw error
            }
            if self.store.document(id: tab.id)?.url == destination.url { break }
          }
        } catch {
          if self.engine.pages[tab.id] === page, page.url?.absoluteString == "about:blank" { self.dormantPages.insert(tab.id) }
          if !(error is CancellationError), self.store.state.activeTabID == tab.id { self.showError(error.localizedDescription) }
          throw error
        }
      }
    } else { page.load(url) }
    scheduleLayout()
  }
  private func requestClosePage(_ page: ChromiumPage) async -> Bool {
    guard engine.pages[page.id] === page else { return true }
    return await withCheckedContinuation { continuation in
      let pending = closeWaiters[page.id] != nil
      closeWaiters[page.id, default: []].append(continuation)
      if !pending { page.close() }
    }
  }
  private func finishCloseWaiters(_ id: String, accepted: Bool) {
    for continuation in closeWaiters.removeValue(forKey: id) ?? [] { continuation.resume(returning: accepted) }
  }
  func requestCloseWindow() async -> Bool {
    guard windowContext.isOpen, let window = window else { return true }
    return await withCheckedContinuation { continuation in
      let pending = !windowCloseWaiters.isEmpty
      windowCloseWaiters.append(continuation)
      if !pending { window.performClose(nil) }
    }
  }
  private func finishWindowCloseWaiters(accepted: Bool) {
    let waiters = windowCloseWaiters; windowCloseWaiters.removeAll()
    for continuation in waiters { continuation.resume(returning: accepted) }
  }
  private func owns(_ page: ChromiumPage, tabID: String) -> Bool {
    guard engine.pages[page.id] === page, !retiringPageIDs.contains(page.id),
      let tab = store.document(id: tabID), !tab.isClosed,
      let profileID = store.profileID(for: tab), profileID == page.profileID,
      let profile = store.state.profiles.first(where: { $0.id == profileID }),
      profile.isPrivate == page.isPrivate
    else { return false }
    return true
  }
  private func wire(_ page: ChromiumPage, tabID: String, peek: Bool) {
    page.beforeClose = { [weak self, weak page] in
      guard let self, let page else { return true }
      if !peek, !self.windowContext.isClosing, !self.engine.isTerminating,
        let preview = self.engine.pages["peek:" + tabID], !(await self.requestClosePage(preview)) { return false }
      self.peekClosingSnapshots.removeValue(forKey: tabID)
      if peek, self.selectedDocumentID == page.id, !self.windowContext.isClosing,
        !self.engine.isTerminating, self.deletingProfileID == nil, let browser = page.browser {
        if let result = try? await browser.devTools.call("Page.captureScreenshot",
          parameters: ["format": "png", "captureBeyondViewport": false], timeout: 1),
          let encoded = result["data"] as? String, encoded.utf8.count <= 11 * 1024 * 1024,
          let bytes = Data(base64Encoded: encoded), let image = NSImage(data: bytes),
          self.selectedDocumentID == page.id, self.owns(page, tabID: tabID) {
          self.peekClosingSnapshots[tabID] = image
        }
      }
      await self.navigation.capture(page, tabID: tabID, peek: peek)
      return true
    }
    page.onChange = { [weak self, weak page] in
      guard let self, let page, self.owns(page, tabID: tabID), !self.navigation.isRestoring(page),
        !self.reservedPages.contains(page.id), !self.discardingPages.contains(page.id), !self.dormantPages.contains(page.id) else { return }
      defer { self.extensionBrowser.reconcile() }
      if page.isSidePanelVisible != self.sidePanelPageIDs.contains(page.id) {
        if page.isSidePanelVisible { self.sidePanelPageIDs.insert(page.id) }
        else { self.sidePanelPageIDs.remove(page.id) }
        self.scheduleLayout()
      }
      let audible = page.isAudible || self.engine.pages[peek ? tabID : "peek:" + tabID]?.isAudible == true
      if audible != self.actions.audibleTabIDs.contains(tabID) {
        if audible { self.actions.audibleTabIDs.insert(tabID) } else { self.actions.audibleTabIDs.remove(tabID) }
      }
      if peek {
        guard self.store.tab(tabID)?.peek != nil else { return }
        if let url = page.faviconDocumentURL, url == page.url, let icon = page.faviconURL {
          self.favicons.load(profile: page.profileID, pageURL: url, iconURL: icon, isPrivate: page.isPrivate,
            persist: true,
            nativeImage: { [weak page] in await page?.browser?.downloadFavicon(icon) }) { [weak self, weak page] image in
              guard let self, let page, self.owns(page, tabID: tabID), self.store.tab(tabID)?.peek?.url == url.absoluteString,
                self.actions.peekIcons[tabID] !== image else { return }
              self.actions.peekIcons[tabID] = image
            }
        }
        if let url = page.url, let saved = self.store.tab(tabID)?.peek,
          saved.url != url.absoluteString || saved.title != page.title
        {
          let value = url.absoluteString
          if let request = self.pendingHistory[page.id],
            value == request.source && value != request.destination
          {
            return
          }
          self.pendingHistory.removeValue(forKey: page.id)
          self.modelURLs[page.id] = value
          let proof = saved.nativeNavigation.flatMap { $0.matches(value) ? $0 : nil }
            ?? saved.navigation?.last(where: { $0.url == value && $0.nativeNavigation?.matches(value) == true })?.nativeNavigation
          guard BrowserAddress.documentURL(value, provenance: proof) != nil else { return }
          do {
            try self.store.updatePeekDurably(tabID: tabID) {
              $0.url = value; $0.title = page.title; $0.nativeNavigation = proof
            }
          } catch { self.showError(error.localizedDescription) }
        }
      } else if let tab = self.store.tab(tabID), let url = page.url {
        let value = url.absoluteString
        let provenance = tab.nativeNavigation.flatMap { $0.matches(value) ? $0 : nil }
          ?? tab.navigation.last(where: { $0.url == value && $0.nativeNavigation?.matches(value) == true })?.nativeNavigation
        guard BrowserAddress.documentURL(value, provenance: provenance) != nil else { return }
        if let provenance, BrowserAddress.documentURL(value) == nil {
          self.modelURLs[tabID] = value
          self.pendingHistory.removeValue(forKey: tabID)
          if tab.url != value || tab.nativeNavigation != provenance || (!page.title.isEmpty && tab.title != page.title) {
            self.store.updateTab(tabID) { entry in
              entry.url = value; entry.nativeNavigation = provenance
              if !page.title.isEmpty { entry.title = page.title }
              if entry.navigation.indices.contains(entry.navigationIndex), entry.navigation[entry.navigationIndex].url == value {
                entry.navigation[entry.navigationIndex].title = page.title
              } else if let index = entry.navigation.lastIndex(where: { $0.url == value && $0.nativeNavigation == provenance }) {
                entry.navigationIndex = index
              }
            }
          }
          self.navigation.observe(page, tabID: tabID, peek: false)
          if self.store.state.activeTabID == tabID { self.updateNavigationState(self.activePage) }
          return
        }
        if BrowserAddress.extensionURL(value) != nil {
          self.modelURLs[tabID] = value
          self.pendingHistory.removeValue(forKey: tabID)
          if tab.url != value || tab.title != page.title { self.store.setExtensionPage(tabID: tabID, url: value, title: page.title) }
          self.navigation.observe(page, tabID: tabID, peek: false)
          if self.store.state.activeTabID == tabID { self.updateNavigationState(self.activePage) }
          return
        }
        if let request = self.pendingHistory[tabID] {
          // Loading/title events can arrive with the old URL before Chromium
          // commits the requested history entry. They must not append that old
          // document to the persisted stack or destroy its forward entries.
          if value != request.source || value == request.destination {
            self.pendingHistory.removeValue(forKey: tabID)
            self.modelURLs[tabID] = value
            self.store.updateTab(tabID) { entry in
              entry.url = value
              if !page.title.isEmpty { entry.title = page.title }
              if entry.navigation.indices.contains(entry.navigationIndex) {
                entry.navigation[entry.navigationIndex] = NavigationEntry(
                  url: value, title: page.title)
              }
            }
            self.store.navigate(tabID: tabID, address: value, title: page.title)
          }
        } else if tab.url != value {
          self.modelURLs[tabID] = value
          self.store.navigate(tabID: tabID, address: value, title: page.title)
        } else if !page.title.isEmpty && tab.title != page.title {
          self.store.updateTab(tabID) { entry in
            entry.title = page.title
            if entry.navigation.indices.contains(entry.navigationIndex) {
              entry.navigation[entry.navigationIndex].title = page.title
            }
          }
        }
        if let latest = self.store.tab(tabID) { self.updateIcon(page, tab: latest) }
      }
      self.navigation.observe(page, tabID: tabID, peek: peek)
      if self.store.state.activeTabID == tabID { self.updateNavigationState(self.activePage) }
    }
    page.onOpenURL = { [weak self, weak page] url, foreground in
      guard let self, let page, self.owns(page, tabID: tabID), let source = self.store.tab(tabID)
      else { return }
      // A background document cannot open a popup in the currently selected
      // profile. Preserve the originating document's exact Space ownership.
      let destination = BrowserAddress.extensionURL(url.absoluteString) != nil
        ? self.store.createExtensionTab(url: url.absoluteString, spaceID: source.spaceID, activate: foreground)
        : self.store.createTab(address: url.absoluteString, spaceID: source.spaceID, activate: foreground)
      if let tab = destination
      {
        _ = self.page(for: tab)
      }
    }
    page.onPopupCreated = { [weak self, weak page] popup, foreground in
      guard let self, let page, self.owns(page, tabID: tabID), let source = self.store.tab(tabID) else { popup.close(); return }
      if !self.adoptPopup(popup, spaceID: source.spaceID, foreground: foreground) { popup.close() }
    }
    page.onPeek = { [weak self, weak page] url in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      if let window = self.window, let content = window.contentView {
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = content.convert(inWindow, from: nil)
        let y = content.isFlipped ? point.y : content.bounds.height - point.y
        self.peekOrigins[tabID] = CGRect(
          x: min(max(self.contentFrame.minX, point.x - 20), self.contentFrame.maxX - 40),
          y: min(max(self.contentFrame.minY, y - 15), self.contentFrame.maxY - 30), width: 40, height: 30)
      }
      self.store.setPeek(tabID: tabID, address: url.absoluteString)
    }
    page.onDownloadDecision = { [weak self, weak page] download, suggested in
      guard let self, let page, self.owns(page, tabID: tabID), let tab = self.store.document(id: page.id) else { return .deny }
      return self.downloads.decide(download, suggested: suggested, source: tab, profile: page.profileID)
    }
    page.onPermission = { [weak self, weak page] request in
      guard let self, let page, self.owns(page, tabID: tabID) else { return .deny }
      return self.requestPermission(request, page: page)
    }
    page.onFindResult = { [weak self, weak page] count, ordinal, _ in
      guard let self, let page, self.owns(page, tabID: tabID), self.activePage === page else { return }
      if self.actions.findMatchCount != count { self.actions.findMatchCount = count }
      if self.actions.findActiveMatch != ordinal { self.actions.findActiveMatch = ordinal }
    }
    page.onFocused = { [weak self, weak page] in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      if !peek, self.store.state.activeTabID != tabID,
        self.visibleSplit?.tabIDs.contains(tabID) == true {
        self.store.selectTab(id: tabID)
      }
      self.updateNavigationState(self.activePage)
    }
    page.onSearchSelection = { [weak self, weak page] selection in
      guard let self, let page, self.owns(page, tabID: tabID), let source = self.store.tab(tabID),
        let newTab = self.store.createTab(address: selection, spaceID: source.spaceID, activate: true) else { return }
      _ = self.page(for: newTab)
    }
    page.onMutedChanged = { [weak self, weak page] muted in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      self.store.updateTab(tabID) {
        if peek { $0.peek?.isMuted = muted } else { $0.isMuted = muted }
      }
    }
    page.onCloseCancelled = { [weak self, weak page] in
      guard let self, let page else { return }
      self.finishCloseWaiters(page.id, accepted: false)
      self.peekClosingSnapshots.removeValue(forKey: tabID)
      if self.profileDeletionPageIDs.remove(page.id) != nil {
        self.pendingDeletion = nil; self.deletingProfileID = nil
        let cancel = self.scopeCloseCancelled; self.scopeCloseCancelled = nil; cancel?()
      }
      self.scheduleLayout()
    }
    let muted = store.document(id: page.id)?.isMuted ?? false
    if page.browser?.isAudioMuted != muted { page.browser?.isAudioMuted = muted }
    page.onClosed = { [weak self, weak page] in
      guard let self, let page else { return }
      defer { self.finishCloseWaiters(page.id, accepted: true) }
      self.navigation.forget(page.id)
      if !peek || self.engine.pages[tabID]?.isAudible != true { self.actions.audibleTabIDs.remove(tabID) }
      self.reservedPages.remove(page.id)
      self.dormantPages.remove(page.id); self.discardingPages.remove(page.id); self.mediaPermissionPages.remove(page.id)
      self.visiblePageFrames.removeValue(forKey: page.id)
      self.sidePanelPageIDs.remove(page.id)
      self.modelURLs.removeValue(forKey: page.id)
      self.pendingHistory.removeValue(forKey: page.id)
      self.restoredHistoryPages.remove(page.id)
      if self.profileDeletionPageIDs.remove(page.id) != nil {
        self.scheduleLayout()
        return
      }
      if page.closedForTermination || page.closedForWindow || page.creationFailed {
        self.scheduleLayout()
        return
      }
      if peek {
        if let snapshot = self.peekClosingSnapshots.removeValue(forKey: tabID),
          self.store.state.activeTabID == tabID { self.peekPanel.animateClosedSnapshot(snapshot) }
        if self.store.tab(tabID)?.peek != nil { self.store.closePeek(tabID: tabID) }
      } else if let tab = self.store.tab(tabID), !tab.isClosed {
        let wasActive = self.store.state.activeTabID == tabID
        let opener = page.openerID.flatMap { self.store.document(id: $0) }
        self.store.closeTab(id: tabID)
        if wasActive, let opener, !opener.isClosed, self.store.profileID(for: opener) == page.profileID {
          do { try self.store.selectDocumentDurably(id: opener.id) }
          catch { self.showError(error.localizedDescription) }
        }
        if wasActive {
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let active = self.activePage { active.focus() } else { self.window?.makeKey() }
          }
        }
      }
      self.scheduleLayout()
    }
  }
  private func retirePage(id: String) {
    guard let page = engine.pages[id], retiringPageIDs.insert(id).inserted else { return }
    navigation.forget(id)
    page.onChange = nil
    page.onOpenURL = nil
    page.onPeek = nil
    // Cleanup is already reflected in the model; the native completion must
    // not archive a newly imported tab or close an already-closed saved pin.
    page.onClosed = { [weak self] in
      guard let self else { return }
      self.finishCloseWaiters(id, accepted: true)
      self.reservedPages.remove(id)
      self.retiringPageIDs.remove(id)
      self.visiblePageFrames.removeValue(forKey: id)
      self.sidePanelPageIDs.remove(id)
      self.modelURLs.removeValue(forKey: id)
      self.pendingHistory.removeValue(forKey: id)
      self.restoredHistoryPages.remove(id)
      self.scheduleLayout()
    }
    page.onCloseCancelled = { [weak self, weak page] in
      guard let self, let page else { return }
      self.finishCloseWaiters(id, accepted: false)
      self.retiringPageIDs.remove(id)
      if id.hasPrefix("peek:"), let url = page.url,
        let source = self.store.tab(String(id.dropFirst(5))), self.store.profileID(for: source) == page.profileID,
        source.peek == nil {
        self.store.setPeek(tabID: source.id, address: url.absoluteString, title: page.title)
      }
      self.scheduleLayout()
    }
    engine.close(id: id)
  }
  func updateNavigationState(_ page: ChromiumPage?) {
    refreshSiteControls()
    let tab = selectedDocumentID.flatMap { store.document(id: $0) }
    if isPopup, let window {
      let title = String((page?.title.isEmpty == false ? page!.title : tab?.title ?? "Zacro").prefix(200))
      if window.title != title { window.title = title }
    }
    let nativeHistory = page != nil && !restoredHistoryPages.contains(page!.id)
    let back = nativeHistory ? page?.canGoBack ?? false : tab.map { $0.navigationIndex > 0 } ?? false
    let forward = nativeHistory ? page?.canGoForward ?? false : tab.map { $0.navigationIndex >= 0 && $0.navigationIndex < $0.navigation.count - 1 } ?? false
    let loading = page?.isLoading ?? false
    if actions.canGoBack != back { actions.canGoBack = back }
    if actions.canGoForward != forward { actions.canGoForward = forward }
    if actions.loading != loading { actions.loading = loading }
    refreshCommands()
  }
  func layoutPages() {
    guard !engine.isTerminating, !windowContext.isClosing, windowContext.isOpen else { return }
    defer { if deletingProfileID == nil { extensionBrowser.reconcile() } }
    refreshCommands()
    services.refreshContext()
    if deletingProfileID == nil { extensionSync.refreshProfiles() }
    application.bookmarks.refreshProfiles()
    let messages = application.libraryMessages(profileID: store.activeProfileID)
    if actions.libraryMessages != messages { actions.libraryMessages = messages }
    refreshSiteControls()
    extensions.profileChanged()
    extensions.activePageChanged(activePage)
    let persistentIcons: [(profile: String, url: URL)] = application.store.state.tabs.flatMap { tab -> [(profile: String, url: URL)] in
      guard let profile = store.profileID(for: tab),
        store.state.profiles.first(where: { $0.id == profile })?.isPrivate == false else { return [] }
      var addresses = [tab.peek?.url]
      if tab.isPinned || tab.isFavorite { addresses += [tab.savedURL, tab.url] }
      return addresses.compactMap { $0.flatMap(BrowserAddress.webURL).map { (profile, $0) } }
    }
    favicons.retain(persistentIcons)
    for tab in store.state.tabs where tab.isPinned || tab.isFavorite || tab.peek != nil {
      if let address = tab.peek?.url, let url = URL(string: address),
        let profile = store.profileID(for: tab), profile == store.activeProfileID,
        let icon = favicons.cached(profile: profile, url: url, isPrivate: store.state.activeProfile?.isPrivate ?? true, persist: true),
        actions.peekIcons[tab.id] !== icon { actions.peekIcons[tab.id] = icon }
      guard tab.isPinned || tab.isFavorite else { continue }
      if let url = URL(string: tab.savedURL ?? tab.url), let profile = store.profileID(for: tab),
        profile == store.activeProfileID,
        let icon = favicons.cached(profile: profile, url: url, isPrivate: store.state.activeProfile?.isPrivate ?? true, persist: true) {
        applyIcon(icon, tabID: tab.id, address: url.absoluteString)
      }
    }
    let loaded = Set(store.state.tabs.compactMap { engine.pages[$0.id] == nil || dormantPages.contains($0.id) || reservedPages.contains($0.id) ? nil : $0.id })
    if actions.loadedTabIDs != loaded { actions.loadedTabIDs = loaded }
    if let pending = pendingDeletion, pending.0.allSatisfy({ engine.pages[$0] == nil }) {
      pendingDeletion = nil
      profileDeletionPageIDs.subtract(pending.0)
      pending.1()
    }
    if store.state.activeTab?.peek == nil || store.state.activeTab?.peek?.isPresented == false { hidePeekPresentation() }
    if contentFrame.width <= 0, let bounds = window?.contentView?.bounds {
      let gutter = isPopup ? 0 : store.state.settings.pageGutter
      let sidebar = !isPopup && store.state.settings.sidebarVisible ? store.state.settings.sidebarWidth : 0
      contentFrame = CGRect(
        x: sidebar + gutter, y: gutter, width: max(1, bounds.width - sidebar - 2 * gutter),
        height: max(1, bounds.height - 2 * gutter))
    }
    guard contentFrame.width > 0 else { return }
    var desired: [String: (ChromiumPage, CGRect)] = [:]
    if let current = store.state.activeTab, !current.isClosed,
      current.url != "about:blank" || engine.pages[current.id]?.isSidePanelVisible == true
        || visibleSplit != nil || (current.peek != nil && current.peek?.isPresented != false) {
      if let group = visibleSplit, let left = store.tab(group.leftTabID),
        let right = store.tab(group.rightTabID)
      {
        let firstWidth = (contentFrame.width - 6) * group.ratio
        if let page = page(for: left) {
          desired[page.id] = (
            page,
            CGRect(
              x: contentFrame.minX, y: contentFrame.minY, width: firstWidth,
              height: contentFrame.height)
          )
        }
        if let page = page(for: right) {
          desired[page.id] = (
            page,
            CGRect(
              x: contentFrame.minX + firstWidth + 6, y: contentFrame.minY,
              width: contentFrame.width - firstWidth - 6, height: contentFrame.height)
          )
        }
      } else if current.url != "about:blank" || engine.pages[current.id]?.isSidePanelVisible == true,
        let page = page(for: current) {
        desired[page.id] = (page, contentFrame)
      }
      if current.peek?.isPresented != false, let document = current.peekDocument, let preview = page(for: document) {
        let frame = PeekPanelController.targetFrame(in: contentFrame)
        peekFrames[current.id] = frame
        desired[preview.id] = (preview, frame)
      }
      updateNavigationState(activePage)
    } else {
      updateNavigationState(nil)
    }
    // Persistent tabs keep their native document and layer attached. Only
    // actual visibility/frame changes reach Chromium, avoiding hide/show flash.
    for entry in desired.values { entry.0.setCornerRadius(isPopup ? 0 : store.state.settings.pageRadius) }
    for (id, _) in visiblePageFrames where desired[id] == nil {
      engine.pages[id]?.hide()
      if id.hasPrefix("peek:") { engine.pages[id]?.setPresentationParent(nil) }
    }
    for (id, entry) in desired where visiblePageFrames[id] != entry.1 {
      if id.hasPrefix("peek:"), peekPanel.isAnimating { continue }
      entry.0.show(frame: entry.1)
    }
    visiblePageFrames = desired.mapValues { $0.1 }
    if let id = store.state.activeTabID, let preview = desired["peek:" + id]?.0,
      let parent = window
    {
      peekPanel.show(
        parent: parent, contentFrame: contentFrame, preview: preview.browser?.nativeView?.window,
        close: { [weak self] in self?.closePeek() }, expand: { [weak self] in self?.promotePeek() },
        theme: presentationTheme, radius: store.state.settings.pageRadius,
        motionScale: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : store.state.settings.motionScale,
        previewFrame: desired[preview.id]?.1, originFrame: peekOrigins[id],
        updatePreviewFrame: { [weak self, weak preview] frame in
          guard let self, let preview, self.engine.pages[preview.id] === preview,
            self.store.state.activeTabID == id else { return }
          preview.show(frame: frame)
          self.peekFrames[id] = frame
          self.visiblePageFrames[preview.id] = frame
        })
      preview.setPresentationParent(peekPanel.presentationWindow)
    }
    let ids = Set(store.state.tabs.filter { !$0.isClosed }.map(\.id))
    for id in Array(windowPages.keys) {
      if id.hasPrefix("extensions:") || id.hasPrefix("extension-store:") || id.hasPrefix("maintenance:") { continue }
      if id.hasPrefix("peek:") {
        let source = String(id.dropFirst(5))
        if !ids.contains(source) || store.tab(source)?.peek == nil { retirePage(id: id) }
      } else if !ids.contains(id) {
        retirePage(id: id)
      }
    }
  }
  func navigate(_ address: String) {
    actions.nativePageVisible = false
    guard let url = BrowserAddress.resolve(address, engine: store.state.settings.searchEngine)
    else { return }
    if let tab = store.state.activeTab, tab.peek != nil, tab.peek?.isPresented != false, let preview = engine.pages["peek:" + tab.id] {
      if url.absoluteString == "about:blank" { closePeek(); return }
      navigation.cancelRestore(preview)
      pendingHistory[preview.id] = (preview.url?.absoluteString, url.absoluteString)
      preview.load(url)
      preview.focus()
      return
    }
    if let tab = store.state.activeTab {
      if dormantPages.contains(tab.id) {
        store.navigate(tabID: tab.id, address: address)
        if let updated = store.tab(tab.id) { navigateExtensionTab(updated, address: url.absoluteString) }
        return
      }
      let page = page(for: tab)
      pendingHistory[tab.id] = (page?.url?.absoluteString ?? tab.url, url.absoluteString)
      modelURLs[tab.id] = url.absoluteString
      if let page { navigation.cancelRestore(page) }
      store.navigate(tabID: tab.id, address: address)
      page?.load(url)
    } else if let tab = store.createTab(address: address) {
      _ = page(for: tab)
    }
    scheduleLayout()
  }
  func goBack() { stepHistory(forward: false) }
  func goForward() { stepHistory(forward: true) }
  private func stepHistory(forward: Bool) {
    guard let id = selectedDocumentID, let tab = store.document(id: id), let page = page(for: tab) else { return }
    if !restoredHistoryPages.contains(page.id) {
      if forward { page.goForward() } else { page.goBack() }
      return
    }
    let address: String?
    if id.hasPrefix("peek:") {
      let index = tab.navigationIndex + (forward ? 1 : -1)
      guard tab.navigation.indices.contains(index) else { return }
      let entry = tab.navigation[index]
      do {
        try store.updatePeekDurably(tabID: String(id.dropFirst(5))) {
          $0.navigationIndex = index; $0.url = entry.url; $0.title = entry.title; $0.nativeNavigation = entry.nativeNavigation
        }
        address = entry.url
      } catch { showError(error.localizedDescription); return }
    } else { address = forward ? store.forward(tabID: tab.id) : store.back(tabID: tab.id) }
    guard let address, let url = URL(string: address) else { return }
    pendingHistory[tab.id] = (page.url?.absoluteString ?? tab.url, address)
    modelURLs[tab.id] = address
    // Restored histories contain destinations, not Chromium page-state. Until
    // a live native stack is available, load the chosen entry without appending
    // it to the model or losing the saved forward path.
    if !restoredHistoryPages.contains(tab.id), forward ? page.canGoForward : page.canGoBack {
      if forward { page.goForward() } else { page.goBack() }
    } else {
      if let current = store.document(id: tab.id), current.nativeNavigation != nil { navigateExtensionTab(current, address: address) }
      else { page.load(url) }
    }
  }
  func promotePeek() {
    guard let source = store.state.activeTab, source.peek != nil, source.peek?.isPresented != false else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.preparePeekPromotion(sourceID: source.id)
        guard self.selectedDocumentID == "peek:" + source.id else { throw CancellationError() }
        let complete = { [weak self] in
          guard let self, self.selectedDocumentID == "peek:" + source.id else { return }
          do { _ = try self.commitPeekPromotion(sourceID: source.id, activate: true) }
          catch { self.showError(error.localizedDescription) }
        }
        if !self.peekPanel.animateExpand(completion: complete) { complete() }
      } catch is CancellationError { }
      catch { self.showError(error.localizedDescription) }
    }
  }
  private func preparePeekPromotion(sourceID: String) async throws -> ChromiumPage {
    guard let document = store.document(id: "peek:" + sourceID) else { throw CancellationError() }
    let page = try await ensurePageReady(document)
    try await navigation.waitForRestore(page)
    try await extensionBrowser.prepareInitialNavigation(page)
    guard owns(page, tabID: sourceID), store.tab(sourceID)?.peek != nil,
      !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    return page
  }
  func promotePeekDocument(sourceID: String, activate: Bool, authorize: @MainActor () async throws -> Void) async throws -> BrowserTab {
    let page = try await preparePeekPromotion(sourceID: sourceID)
    try await authorize()
    guard owns(page, tabID: sourceID), store.tab(sourceID)?.peek != nil,
      !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    return try commitPeekPromotion(sourceID: sourceID, activate: activate)
  }
  private func commitPeekPromotion(sourceID id: String, activate: Bool) throws -> BrowserTab {
    let previewID = "peek:" + id
    guard let preview = engine.pages[previewID], owns(preview, tabID: id), preview.browser != nil,
      !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    let promoted = try store.promotePeekDurably(tabID: id, activate: activate)
    if let page = engine.adoptPage(fromID: previewID, toID: promoted.id) {
      extensionBrowser.didPromotePeek(sourceID: id, targetID: promoted.id)
      navigation.forget(previewID)
      page.setPresentationParent(nil)
      modelURLs.removeValue(forKey: previewID)
      pendingHistory[promoted.id] = pendingHistory.removeValue(forKey: previewID)
      visiblePageFrames[promoted.id] = visiblePageFrames.removeValue(forKey: previewID)
      modelURLs[promoted.id] = promoted.url
      wire(page, tabID: promoted.id, peek: false)
      updateIcon(page, tab: promoted)
      Task { [weak self, weak page] in
        guard let self, let page else { return }
        await self.navigation.promotePeek(profileID: page.profileID, sourceID: id, targetID: promoted.id, address: promoted.url)
        await self.navigation.capture(page, tabID: promoted.id, peek: false)
      }
    }
    peekFrames.removeValue(forKey: id); peekOrigins.removeValue(forKey: id); actions.peekIcons.removeValue(forKey: id)
    scheduleLayout()
    return promoted
  }
  func closePeek() {
    guard let id = store.state.activeTabID else { return }
    if let page = engine.pages["peek:" + id] { page.close() }
    else { store.closePeek(tabID: id) }
  }
  func find() {
    actions.findVisible = true
  }
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    for (id,title) in [("open-browser","New Window"),("command-palette","Command Palette"),("new-private-space","New Private Space")] {
      let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = id; menu.addItem(item)
    }
    return menu
  }
  private func handleKey(_ event: NSEvent) -> Bool {
    if replayingExtensionKey { return false }
    guard application.focusedCoordinator === self else { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.type == .flagsChanged {
      if !flags.isSuperset(of: recentModifiers) { recentTabCycle = nil; recentModifiers = [] }
      return false
    }
    if let resize = NSApp.keyWindow?.firstResponder as? NativeResizeHandleView,
      resize.handleKey(event) { return true }
    guard !actions.recordingShortcut else { return false }
    if let text = NSApp.keyWindow?.firstResponder as? NSTextInputClient, text.hasMarkedText() { return false }
    if NSApp.modalWindow != nil || NSApp.keyWindow?.sheetParent != nil || window?.attachedSheet != nil { return false }
    if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "q" {
      NSApp.terminate(nil); return true
    }
    if let focusedWindow = NSApp.keyWindow, focusedWindow !== window {
      let browserControls = focusedWindow.identifier == NSUserInterfaceItemIdentifier("ZacroBrowserControls")
        && focusedWindow.parent === window
      guard browserControls || windowPages.values.contains(where: { $0.nativeWindow === focusedWindow }) else { return false }
    }
    if event.keyCode == 53 && flags.isEmpty {
      if actions.handleInterfaceEscape() { return true }
      if actions.palette { return actions.handlePaletteEscape() }
      if actions.findVisible { actions.closeFind(); return true }
      if store.state.activeTab?.peek != nil, store.state.activeTab?.peek?.isPresented != false { closePeek(); return true }
      if actions.library != nil { actions.library = nil; return true }
      return false
    }
    let keys = NativeKeyBinding.candidates(event)
    guard let command = BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides).first(where: {
      !keys.isDisjoint(with: [$0.accelerator] + $0.aliases)
    }) else { return dispatchExtensionShortcut(event) }
    let repeatable = ["zoom-in", "zoom-out", "next-tab", "previous-tab", "recent-tab", "previous-recent-tab", "find-next", "find-previous"]
    if event.isARepeat && !repeatable.contains(command.id) { return true }
    if command.id.contains("recent-tab") { recentModifiers = flags.subtracting(.shift) }
    else { recentTabCycle = nil; recentModifiers = [] }
    runCommand(command.id)
    return true
  }
  private func dispatchExtensionShortcut(_ event: NSEvent) -> Bool {
    // Chromium handles keys focused in its own document windows. This path
    // covers the Swift shell, where its native keybinding registry has no view.
    guard event.type == .keyDown, let shell = window, NSApp.keyWindow === shell,
      !actions.palette, !actions.themeEditor, !actions.recordingShortcut,
      let shortcut = extensions.matchingShortcut(for: event) else { return false }
    if event.isARepeat { return true }
    let profile = store.activeProfileID, selected = selectedDocumentID
    let responder = shell.firstResponder
    Task { [weak self, weak shell, weak responder] in
      guard let self, let shell, self.window === shell, NSApp.keyWindow === shell,
        shell.firstResponder === responder, self.store.activeProfileID == profile,
        self.selectedDocumentID == selected, !self.actions.recordingShortcut else { return }
      do {
        let page = try await self.extensionActionPage(profileID: profile)
        guard NSApp.keyWindow === shell, shell.firstResponder === responder, !self.actions.recordingShortcut else { return }
        let address = page.url
        let anchor = shell.convertToScreen(NSRect(x: max(8, self.store.state.settings.sidebarWidth - 34),
          y: max(0, (shell.contentView?.bounds.height ?? shell.frame.height) - 68), width: 26, height: 26))
        let performed = try await ChromeExtensionManager(engine: self.engine, profileID: profile)
          .performShortcut(shortcut, on: page, anchorWindow: shell, anchorRect: anchor)
        guard !performed, self.windowContext.isOpen, !self.windowContext.isClosing,
          !self.engine.isTerminating, NSApp.keyWindow === shell, shell.firstResponder === responder,
          self.store.activeProfileID == profile, self.activePage === page, page.url == address,
          !self.actions.recordingShortcut, NSApp.modalWindow == nil, shell.attachedSheet == nil else { return }
        // Replay only Chromium's explicit, nonexecuted rejection. A timeout or
        // lost acknowledgement must never execute an original key twice.
        self.replayingExtensionKey = true
        defer { self.replayingExtensionKey = false }
        NSApp.sendEvent(event)
      } catch is CancellationError {
        return
      } catch {
        self.extensions.error = error.localizedDescription
      }
    }
    return true
  }
  func installMenus() {
    let catalog = BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides)
    func command(_ id: String, _ title: String) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = id; item.isEnabled = commandAvailable(id)
      let parts = (catalog.first { $0.id == id }?.accelerator ?? "").components(separatedBy: "+")
      let special: [String:String] = ["Left":String(UnicodeScalar(NSLeftArrowFunctionKey)!), "Right":String(UnicodeScalar(NSRightArrowFunctionKey)!), "Up":String(UnicodeScalar(NSUpArrowFunctionKey)!), "Down":String(UnicodeScalar(NSDownArrowFunctionKey)!), "Tab":"\t", "Enter":"\r", "Escape":"\u{1b}"]
      if let key = parts.last, key.count == 1 || special[key] != nil {
        item.keyEquivalent = special[key] ?? key.lowercased(); item.keyEquivalentModifierMask = []
        for (name, flag): (String,NSEvent.ModifierFlags) in [("Mod",.command),("Ctrl",.control),("Alt",.option),("Shift",.shift)] where parts.dropLast().contains(name) { item.keyEquivalentModifierMask.insert(flag) }
      }
      return item
    }
    let bar = NSMenu()
    func append(_ title: String, _ items: [(String,String)]) -> NSMenu {
      let menu = NSMenu(title: title); menu.autoenablesItems = false
      for (id,label) in items { menu.addItem(id.isEmpty ? .separator() : command(id,label)) }
      let item = NSMenuItem(); item.submenu = menu; bar.addItem(item); return menu
    }
    let app = append("Zacro", [])
    app.addItem(withTitle: "About Zacro", action: #selector(about), keyEquivalent: "").target = self
    app.addItem(.separator()); app.addItem(command("preferences", "Settings…")); app.addItem(command("shortcuts", "Keyboard Shortcuts…")); app.addItem(.separator())
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services"); servicesItem.submenu = servicesMenu; app.addItem(servicesItem); NSApp.servicesMenu = servicesMenu
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Zacro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); hideOthers.keyEquivalentModifierMask = [.command,.option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator()); app.addItem(withTitle: "Quit Zacro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    _ = append("File", [("command-palette","Command Palette…"),("new-tab","New Tab Page"),("open-browser","New Window"),("new-private-space","New Private Space"),("open-location","Open Location…"),("reopen-tab","Reopen Closed Tab"),("reopen-window","Reopen Closed Window"),("",""),("close-tab","Close Tab"),("close-window","Close Window"),("",""),("import","Import Browser Data…"),("export","Export Browser Data…"),("",""),("save-page","Save Page As…"),("print","Print…")])
    let edit = append("Edit", [])
    for (id,title,key,flags): (String,String,String,NSEvent.ModifierFlags) in [
      ("undo","Undo","z",.command),("redo","Redo","z",[.command,.shift]),
      ("cut","Cut","x",.command),("copy","Copy","c",.command),("paste","Paste","v",.command),
      ("paste-match-style","Paste and Match Style","v",[.command,.option,.shift]),("select-all","Select All","a",.command)] {
      if id == "cut" { edit.addItem(.separator()) }
      let item = command("edit:" + id,title); item.keyEquivalent = key; item.keyEquivalentModifierMask = flags; edit.addItem(item)
    }
    edit.addItem(.separator()); edit.addItem(command("find","Find…"))
    let speech = NSMenuItem(title: "Speech", action: nil, keyEquivalent: ""), speechMenu = NSMenu(title: "Speech")
    speechMenu.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
    speechMenu.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
    speech.submenu = speechMenu; edit.addItem(speech)
    _ = append("View", [("reload","Reload Page"),("force-reload","Reload Without Cache"),("",""),("sidebar-toggle","Toggle Sidebar"),("focus-sidebar","Focus Sidebar"),("reveal-tab","Reveal Tab in Sidebar"),("zoom-in","Zoom In"),("zoom-out","Zoom Out"),("zoom-reset","Actual Size"),("",""),("fullscreen", window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"),("developer-tools","Developer Tools")])
    _ = append("History", [("history-back","Back"),("history-forward","Forward"),("",""),("history","Show History"),("downloads","Downloads")])
    _ = append("Tabs", [("previous-tab","Previous Tab"),("next-tab","Next Tab"),("",""),("pin-tab","Pin / Unpin Tab"),("duplicate-tab","Duplicate Tab"),("rename-tab","Rename Tab…"),("move-tab","Move Tab…"),("mute-tab","Mute / Unmute Tab"),("split","Split View…"),("unsplit","Unsplit Tabs"),("",""),("previous-space","Previous Space"),("next-space","Next Space"),("new-space","New Space…"),("new-folder","New Folder…"),("",""),("bookmark","Bookmark This Page")])
    let window = append("Window", [("windows", "Saved Windows"),("", "")])
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(.separator()); window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    NSApp.windowsMenu = window
    NSApp.helpMenu = append("Help", [("onboarding","Welcome Tour"),("",""),("releases","Zacro Releases"),("issues","Report an Issue")])
    NSApp.mainMenu = bar
  }
  private func deleteScope(space: String?, profile: String?) {
    guard pendingDeletion == nil, deletingProfileID == nil else { return }
    if let profile, application.clearingHistoryProfiles.contains(profile) {
      showError("Finish clearing this profile’s history first.")
      return
    }
    if let space { store.deleteSpace(id: space); return }
    guard let profile, store.state.profiles.contains(where: { $0.id == profile }) else { return }
    let ids = Set(engine.pages.values.filter { $0.profileID == profile }.map(\.id))
    deletingProfileID = profile
    let completion = { [weak self] in
      guard let self else { return }
      Task { [weak self] in
        guard let self else { return }
        defer { self.deletingProfileID = nil; self.scheduleLayout() }
        var committed = false
        do {
          try await self.services.prepareProfileDeletion(profile)
          let ids = self.application.store.state.tabs.filter { self.store.profileID(for: $0) == profile }.map(\.id)
          try self.store.deleteProfileDurably(id: profile)
          committed = true
          self.application.bookmarks.removeProfile(profile)
          self.downloads.removeProfile(profile)
          try self.engine.retireProfile(profile)
          self.favicons.clear(profile: profile)
          try await self.navigation.removeProfile(profile)
          await self.extensionSync.removeProfile(profile)
          for owner in self.application.windows.values {
            for id in ids {
              owner.actions.icons.removeValue(forKey: id); owner.actions.iconColors.removeValue(forKey: id)
              owner.actions.peekIcons.removeValue(forKey: id)
            }
          }
          try await self.services.didDeleteProfile(profile)
        } catch {
          if !committed { try? await self.services.cancelProfileDeletion(profile) }
          self.showError(error.localizedDescription)
        }
      }
    }
    if ids.isEmpty {
      completion()
      return
    }
    pendingDeletion = (ids, completion)
    profileDeletionPageIDs.formUnion(ids)
    for id in ids { engine.close(id: id) }
  }
  private func refreshSiteControls() {
    let profileChanged = siteControlProfileID != store.activeProfileID
    var controls = profileChanged ? SiteControlActions() : actions.siteControls
    controls.url = activePage?.url ?? store.state.activeTab.flatMap { URL(string: $0.url) }
    controls.title = activePage?.title ?? store.state.activeTab?.displayTitle ?? ""
    controls.profileName = store.state.activeProfile?.name ?? "Personal"
    controls.spaceName = store.state.activeSpace?.name ?? "Personal"
    controls.isSplit = visibleSplit != nil
    controls.pageError = activePage?.error != nil
    controls.isPrivate = store.state.activeProfile?.isPrivate ?? false
    controls.isBookmarked = store.state.bookmarks.contains {
      $0.url == controls.url?.absoluteString && $0.profileID == store.activeProfileID
    }
    controls.zoomPercent = Int(pow(1.2, activePage?.browser?.zoomLevel ?? 0) * 100)
    let previous = actions.siteControls
    guard controls.url != previous.url || controls.title != previous.title
      || controls.profileName != previous.profileName || controls.isPrivate != previous.isPrivate
      || controls.isBookmarked != previous.isBookmarked || controls.zoomPercent != previous.zoomPercent
      || controls.spaceName != previous.spaceName || controls.isSplit != previous.isSplit
      || controls.pageError != previous.pageError || profileChanged || !siteControlsInitialized
    else { return }
    siteControlsInitialized = true
    siteControlProfileID = store.activeProfileID
    controls.bookmark = { [weak self] in
      self?.toggleBookmark()
    }
    controls.printPage = { [weak self] in self?.activePage?.printPage() }
    controls.find = { [weak self] in self?.find() }
    controls.split = { [weak self] in
      guard let self else { return }
      self.runCommand(self.visibleSplit != nil ? "unsplit" : "split")
    }
    controls.customizeSpace = { [weak self] in self?.actions.themeEditor = true }
    controls.permissions = { [weak self] in _ = self?.actions.performInterfaceCommand("permissions") }
    controls.browserMenu = { [weak self] in _ = self?.actions.performInterfaceCommand("browser-menu") }
    controls.pageActions = { [weak self] in _ = self?.actions.performInterfaceCommand("page-actions") }
    controls.openDefaultBrowser = { [weak self] in
      guard let value = self?.activePage?.url?.absoluteString, let url = BrowserAddress.webURL(value) else { return }
      NSWorkspace.shared.open(url)
    }
    controls.zoomIn = { [weak self] in
      self?.activePage?.zoom(by: 1)
      self?.refreshSiteControls()
    }
    controls.zoomOut = { [weak self] in
      self?.activePage?.zoom(by: -1)
      self?.refreshSiteControls()
    }
    controls.resetZoom = { [weak self] in
      self?.activePage?.resetZoom()
      self?.refreshSiteControls()
    }
    controls.developerTools = { [weak self] in self?.activePage?.showDevTools() }
    controls.showExtensions = { [weak self] in
      guard let self else { return }
      if self.activePage?.showExtensionsMenu() != true { self.openExtensions(store: false) }
    }
    controls.manageExtensions = { [weak self] in self?.openExtensions(store: false) }
    controls.extensionStore = { [weak self] in self?.openExtensions(store: true) }
    actions.siteControls = controls
  }
  func openExtensions(store showStore: Bool) {
    guard store.state.activeProfile?.isPrivate != true else { return }
    actions.palette = false
    if !showStore {
      actions.library = "Extensions"
      return
    }
    actions.library = nil
    let existing = store.state.tabs.first {
      !$0.isClosed && store.profileID(for: $0) == store.activeProfileID
        && URL(string: $0.url)?.scheme == "https"
        && URL(string: $0.url)?.host == "chromewebstore.google.com"
    }
    guard let tab = existing ?? store.createTab(address: "https://chromewebstore.google.com/") else { return }
    do { try store.selectDocumentDurably(id: tab.id) }
    catch { showError(error.localizedDescription); return }
    _ = page(for: tab)
    scheduleLayout()
  }
  func updateIcon(_ page: ChromiumPage, tab: BrowserTab) {
    guard let displayURL = URL(string: tab.savedURL ?? tab.url) else { return }
    if let cached = favicons.cached(profile: page.profileID, url: displayURL, isPrivate: page.isPrivate) {
      applyIcon(cached, tabID: tab.id, address: displayURL.absoluteString)
    } else if iconDestinations[tab.id] != displayURL.absoluteString {
      actions.icons.removeValue(forKey: tab.id)
      actions.iconColors.removeValue(forKey: tab.id)
    }
    guard let documentURL = page.faviconDocumentURL, documentURL == page.url,
      let iconURL = page.faviconURL else { return }
    favicons.load(
      profile: page.profileID, pageURL: documentURL, iconURL: iconURL, isPrivate: page.isPrivate,
      persist: tab.isPinned || tab.isFavorite,
      nativeImage: { [weak page] in await page?.browser?.downloadFavicon(iconURL) }
    ) { [weak self, weak page] image in
      guard let self, let page, self.owns(page, tabID: tab.id),
        self.store.tab(tab.id).map({ $0.savedURL ?? $0.url }) == documentURL.absoluteString else { return }
      self.applyIcon(image, tabID: tab.id, address: documentURL.absoluteString)
    }
  }
  private func applyIcon(_ image: NSImage, tabID: String, address: String) {
    iconDestinations[tabID] = address
    guard actions.icons[tabID] !== image else { return }
    actions.icons[tabID] = image
    if let color = favicons.accent(image) { actions.iconColors[tabID] = Color(nsColor: color) }
    else { actions.iconColors.removeValue(forKey: tabID) }
  }
  @objc private func about() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Zacro", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
    ])
  }
}

extension BrowserWindowCoordinator {
  private func refreshDefaultBrowser() {
    actions.defaultBrowser = ["https", "http"].allSatisfy { scheme in
      guard let url = URL(string: "\(scheme)://example.com"),
        let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
      return Bundle(url: application)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
  }
  private func restoreWindowBounds(_ window: NSWindow) {
    let saved = store.state.windowBounds
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    let requested = CGRect(x: saved.x ?? window.frame.minX, y: saved.y.map { primaryTop - $0 - saved.height } ?? window.frame.minY,
      width: saved.width, height: saved.height)
    let screen = NSScreen.screens.max { left,right in
      let l = left.visibleFrame.intersection(requested), r = right.visibleFrame.intersection(requested)
      return (l.isNull ? 0 : l.width*l.height) < (r.isNull ? 0 : r.width*r.height)
    } ?? NSScreen.main
    guard let screen else { return }
    let available = screen.visibleFrame
    let width = min(available.width, max(560, requested.width)), height = min(available.height, max(420, requested.height))
    let origin = CGPoint(x: min(max(requested.minX,available.minX),available.maxX-width), y: min(max(requested.minY,available.minY),available.maxY-height))
    window.minSize = CGSize(width: min(560, available.width), height: min(420,available.height))
    window.setFrame(CGRect(origin: origin, size: CGSize(width:width,height:height)), display:false)
    if saved.maximized { window.zoom(nil) }
  }
  private func rememberWindowBounds(_ window: NSWindow) {
    guard windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      !window.styleMask.contains(.fullScreen), !window.isMiniaturized, !window.inLiveResize else { return }
    var bounds = store.state.windowBounds
    bounds.maximized = window.isZoomed
    if !window.isZoomed {
      let frame = window.frame
      bounds.width = frame.width; bounds.height = frame.height; bounds.x = frame.minX
      bounds.y = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY; bounds.sizeKind = "window"
    }
    if bounds != store.state.windowBounds { store.updateWindowBounds(bounds) }
  }
  private var pageCommands: Set<String> {
    ["copy-url", "pin-tab", "duplicate-tab", "rename-tab", "move-tab", "mute-tab", "split", "reload", "force-reload", "stop", "find", "find-next", "find-previous", "bookmark", "save-page", "print", "zoom-in", "zoom-out", "zoom-reset", "developer-tools"]
  }
  private func commandAvailable(_ id: String) -> Bool {
    if id == "reopen-window" { return !application.repository.savedWindows.isEmpty }
    if id == "reopen-tab" { return recentlyClosedTabID != nil }
    if id == "history-back" { return actions.canGoBack }
    if id == "history-forward" { return actions.canGoForward }
    if id.hasPrefix("peek-") { return store.state.activeTab?.peek != nil && store.state.activeTab?.peek?.isPresented != false }
    if id == "unsplit" { return visibleSplit != nil }
    if ["pin-tab", "duplicate-tab", "rename-tab", "move-tab", "split"].contains(id) {
      return store.state.activeTab.map { !$0.isClosed && $0.url != "about:blank" } ?? false
    }
    if pageCommands.contains(id) {
      return selectedDocumentID.flatMap { store.document(id: $0) }.map { !$0.isClosed && $0.url != "about:blank" } ?? false
    }
    return true
  }
  private func refreshCommands() {
    let catalog = BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides)
    let fingerprint = catalog.map { "\($0.id):\($0.accelerator):\(commandAvailable($0.id))" }.joined(separator: "|") + ":\(commandAvailable("unsplit")):\(commandAvailable("reopen-window"))"
    guard fingerprint != commandFingerprint else { return }
    commandFingerprint = fingerprint
    actions.runtimeCommands = catalog.map { entry in
      BrowserRuntimeCommand(id: entry.id, title: entry.title, icon: commandIcon(entry.id),
        shortcut: entry.accelerator.isEmpty ? nil : entry.accelerator, keywords: entry.category,
        available: commandAvailable(entry.id)) { [weak self] in self?.runCommand(entry.id) }
    } + [BrowserRuntimeCommand(id: "unsplit", title: "Unsplit tabs", icon: "rectangle", keywords: "split separate", available: commandAvailable("unsplit")) { [weak self] in self?.runCommand("unsplit") },
      BrowserRuntimeCommand(id: "reopen-window", title: "Reopen closed window", icon: "rectangle", keywords: "restore session tabs", available: commandAvailable("reopen-window")) { [weak self] in self?.runCommand("reopen-window") },
      BrowserRuntimeCommand(id: "windows", title: "Saved windows", icon: "rectangle", keywords: "restore session tabs", available: true) { [weak self] in self?.runCommand("windows") },
      BrowserRuntimeCommand(id: "about", title: "About Zacro", icon: "info", keywords: "version browser", available: true) { [weak self] in self?.runCommand("about") }]
    if application.focusedCoordinator === self { installMenus() }
  }
  private func commandIcon(_ id: String) -> String {
    NativeGlyph.commandName(id)
  }
  @objc private func menuCommand(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String else { return }
    if id.hasPrefix("edit:") { editCommand(String(id.dropFirst(5))) }
    else { runCommand(id) }
  }
  private func editCommand(_ id: String) {
    let selector = ["undo":"undo:","redo":"redo:","cut":"cut:","copy":"copy:","paste":"paste:","paste-match-style":"pasteAsPlainText:","select-all":"selectAll:"][id] ?? ""
    guard !selector.isEmpty else { return }
    if let page = engine.pages.values.first(where: { $0.nativeWindow === NSApp.keyWindow }), let browser = page.browser {
      switch id {
      case "undo": browser.undo()
      case "redo": browser.redo()
      case "cut": browser.cutSelection()
      case "copy": browser.copySelection()
      case "paste": browser.paste()
      case "paste-match-style": browser.pasteAndMatchStyle()
      case "select-all": browser.selectAll()
      default: break
      }
    } else { NSApp.sendAction(Selector(selector), to: nil, from: self) }
  }
  private var orderedTabs: [BrowserTab] {
    store.sidebarTabs()
  }
  func runCommand(_ id: String) {
    if isPopup {
      if id == "close-tab" || id == "close-window" {
        if id == "close-tab", store.state.activeTab?.peek != nil, store.state.activeTab?.peek?.isPresented != false { closePeek() }
        else { Task { [weak self] in _ = await self?.requestCloseWindow() } }
        return
      }
      if id == "focus-chrome" { activePage?.focus(); return }
      let documentCommands: Set<String> = ["history-back", "history-forward", "copy-url", "mute-tab", "reload", "force-reload",
        "stop", "find", "find-next", "find-previous", "bookmark", "save-page", "print", "zoom-in", "zoom-out", "zoom-reset",
        "developer-tools", "fullscreen", "about", "new-window", "open-browser", "peek-close", "peek-promote"]
      if !documentCommands.contains(id) {
        do { try application.browsingWindow(profileID: store.activeProfileID).runCommand(id) }
        catch { showError(error.localizedDescription) }
        return
      }
    }
    guard commandAvailable(id) else { return }
    if actions.performInterfaceCommand(id) {
      if !actions.palette && !actions.themeEditor { window?.makeKeyAndOrderFront(nil) }
      return
    }
    switch id {
    case "command-palette": actions.openPalette()
    case "open-location": actions.openPalette(address: activePage?.url?.absoluteString ?? selectedDocumentID.flatMap { store.document(id: $0)?.url } ?? "")
    case "about": about()
    case "new-tab":
      actions.newTab("about:blank")
      if let id = store.state.activeTabID { store.updateTab(id) { $0.homePage = true } }
    case "paste-search":
      if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        if text.count <= 8_000 { actions.newTab(text) } else { showError("Paste up to 8,000 characters.") }
      }
    case "sidebar-toggle": store.updateSettings { $0.sidebarVisible.toggle() }
    case "history-back": goBack()
    case "history-forward": goForward()
    case "copy-url":
      if let url = activePage?.url?.absoluteString ?? store.state.activeTab?.url, url != "about:blank",
        BrowserAddress.documentURL(url, provenance: selectedDocumentID.flatMap { store.document(id: $0)?.nativeNavigation }) != nil {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
      }
    case "next-space", "previous-space":
      let spaces = store.state.spaces.filter { $0.profileID == store.activeProfileID }
      if let current = spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }) {
        let index = current + (id == "next-space" ? 1 : -1)
        if spaces.indices.contains(index) { store.selectSpace(id: spaces[index].id) }
      }
    case "new-private-space":
      do { _ = try store.createProfileDurably(name: "Private", isPrivate: true) }
      catch { showError(error.localizedDescription) }
    case "close-tab":
      if store.state.activeTab?.peek != nil, store.state.activeTab?.peek?.isPresented != false { closePeek() }
      else if let id = store.state.activeTabID { actions.closeTab(id) }
    case "reopen-tab":
      if let id = recentlyClosedTabID {
        do { _ = page(for: try store.restoreSessionTabDurably(id: id)) }
        catch { showError(error.localizedDescription) }
      }
    case "reopen-window":
      if let session = application.repository.savedWindows.first {
        do { try application.reopenWindow(id: session.id) } catch { showError(error.localizedDescription) }
      }
    case "next-tab", "previous-tab":
      let tabs = orderedTabs
      if !tabs.isEmpty {
        let current = tabs.firstIndex { $0.id == store.state.activeTabID } ?? 0
        store.selectTab(id: tabs[(current + (id == "next-tab" ? 1 : -1) + tabs.count) % tabs.count].id)
      }
    case "recent-tab", "previous-recent-tab":
      if recentTabCycle == nil {
        recentTabCycle = store.visibleTabs.filter { !$0.isClosed }.sorted { $0.lastAccessedAt > $1.lastAccessedAt }.map(\.id)
        recentTabIndex = recentTabCycle?.firstIndex(of: store.state.activeTabID ?? "") ?? 0
      }
      if let tabs = recentTabCycle, !tabs.isEmpty {
        recentTabIndex = (recentTabIndex + (id == "recent-tab" ? 1 : -1) + tabs.count) % tabs.count
        store.selectTab(id: tabs[recentTabIndex])
      }
    case "pin-tab": if let id = store.state.activeTabID { store.togglePin(id: id) }
    case "duplicate-tab": if let id = store.state.activeTabID, let tab = store.duplicateTab(id: id) { _ = page(for: tab) }
    case "mute-tab":
      if let id = selectedDocumentID, let tab = store.document(id: id) {
        do {
          if id.hasPrefix("peek:") { try store.updatePeekDurably(tabID: String(id.dropFirst(5))) { $0.isMuted.toggle() } }
          else { store.updateTab(id) { $0.isMuted.toggle() } }
          activePage?.browser?.isAudioMuted = !tab.isMuted
        } catch { showError(error.localizedDescription) }
      }
    case "unsplit": if let id = store.state.activeTabID { store.unsplit(tabID: id) }
    case "peek-close": closePeek()
    case "peek-promote": promotePeek()
    case "reload": if let page = activePage { page.reload() } else { retryActivePage() }
    case "force-reload": activePage?.browser?.reload(ignoreCache: true)
    case "stop": activePage?.stop()
    case "find": find()
    case "find-next": actions.findNext()
    case "find-previous": actions.findPrevious()
    case "bookmark":
      toggleBookmark()
    case "save-page": _ = activePage?.browser?.executeChromeCommand(named: "IDC_SAVE_PAGE")
    case "print": activePage?.printPage()
    case "zoom-in": activePage?.zoom(by: 1); refreshSiteControls()
    case "zoom-out": activePage?.zoom(by: -1); refreshSiteControls()
    case "zoom-reset": activePage?.resetZoom(); refreshSiteControls()
    case "history", "downloads", "bookmarks", "archive", "extensions", "windows":
      actions.library = id.capitalized
      if id == "downloads", downloads.enabled {
        let profileID = store.activeProfileID
        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.extensionSync.ensureNativeObservation(profileID: profileID)
            try await self.downloads.refresh(profileID: profileID)
          } catch { /* The profile-specific Library status reports refresh errors. */ }
        }
      }
    case "ai":
      if actions.palette {
        let question = actions.query
        actions.palette = false
        services.aiConversation.prepare(question)
      } else if store.state.activeTab?.homePage == true, !actions.homeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        services.aiConversation.prepare(actions.homeQuery)
        actions.homeQuery = ""
      }
      actions.library = "AI"
      window?.makeKeyAndOrderFront(nil)
    case "preferences": actions.library = "Settings"
    case "new-window": application.newWindow()
    case "open-browser": application.newWindow()
    case "close-window": window?.performClose(nil)
    case "fullscreen": window?.toggleFullScreen(nil)
    case "developer-tools": activePage?.showDevTools()
    case "import":
      let panel = NSOpenPanel(); panel.allowedContentTypes = [.json,.html]; panel.allowsMultipleSelection = false
      if panel.runModal() == .OK, let url = panel.url { do { try store.importData(from: url) } catch { showError(error.localizedDescription) } }
    case "export":
      let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Zacro Collection.json"
      if panel.runModal() == .OK, let url = panel.url { do { try store.exportData(to: url) } catch { showError(error.localizedDescription) } }
    case "releases", "issues":
      if let url = URL(string: "https://github.com/Zacro-Technologies/zacro_browser/" + id) { NSWorkspace.shared.open(url) }
    case "focus-chrome":
      if NSApp.keyWindow === window { activePage?.focus() }
      else { window?.makeKeyAndOrderFront(nil); _ = actions.performInterfaceCommand("focus-sidebar") }
    default:
      if id.hasPrefix("tab-"), let number = Int(id.dropFirst(4)) {
        let tabs = orderedTabs; let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { store.selectTab(id: tabs[index].id) }
      } else if id.hasPrefix("space-"), let number = Int(id.dropFirst(6)) {
        let spaces = store.state.spaces.filter { $0.profileID == store.activeProfileID }
        if spaces.indices.contains(number - 1) { store.selectSpace(id: spaces[number - 1].id) }
      }
    }
  }
  func showError(_ message: String) {
    let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "OK")
    if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
  }
  private var servicePalette: NativeSpacePalette {
    let theme = presentationTheme
    let dark = theme.appearance == "dark" || (theme.appearance == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    return NativeSpacePalette(theme: theme, dark: dark)
  }
  private var presentationTheme: SpaceTheme {
    var theme = store.state.activeSpace?.theme ?? SpaceTheme()
    theme.appearance = store.state.settings.appearance
    return theme
  }
  private var recentlyClosedTabID: String? {
    guard store.state.activeProfile?.isPrivate == false else { return nil }
    let archived = store.state.archive.filter { store.profileID(for: $0.tab) == store.activeProfileID }
      .map { (id: $0.id, date: $0.archivedAt) }
    let pinned = store.state.tabs.filter { $0.isClosed && store.profileID(for: $0) == store.activeProfileID }
      .map { (id: $0.id, date: $0.closedAt ?? .distantPast) }
    return (archived + pinned).max(by: { $0.date < $1.date })?.id
  }
  func extensionActionPage(profileID: String) async throws -> ChromiumPage {
    guard store.activeProfileID == profileID, store.state.activeProfile?.isPrivate == false,
      windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    let page: ChromiumPage
    if let active = activePage { page = active }
    else {
      guard let tab = store.state.activeTab ?? store.createTab(address: "about:blank"),
        store.profileID(for: tab) == profileID else { throw ChromeExtensionError.managementUnavailable }
      page = try await ensurePageReady(tab)
      try await navigation.waitForRestore(page)
    }
    guard page.profileID == profileID, page.ownerWindowID == windowContext.id,
      store.activeProfileID == profileID, activePage === page,
      windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    try await extensionBrowser.prepareInitialNavigation(page)
    return page
  }
  private func installServices() {
    extensions.invokeOptions = { [weak self] profile, identifier in
      guard let self, self.store.activeProfileID == profile, self.store.state.activeProfile?.isPrivate == false,
        self.windowContext.isOpen, !self.windowContext.isClosing, !self.engine.isTerminating else { throw CancellationError() }
      try await self.application.extensionBrowser.openOptions(profileID: profile, extensionID: identifier,
        sourceWindowID: self.windowContext.nativeID)
    }
    extensions.invokeAction = { [weak self] profile, identifier, anchor in
      guard let self else { throw CancellationError() }
      let anchorRect = anchor ?? self.window.map { window in
        window.convertToScreen(NSRect(x: max(8, self.store.state.settings.sidebarWidth - 34),
          y: max(0, (window.contentView?.bounds.height ?? window.frame.height) - 68), width: 26, height: 26))
      }
      let page = try await self.extensionActionPage(profileID: profile)
      try await ChromeExtensionManager(engine: self.engine, profileID: profile)
        .performAction(identifier, on: page, anchorWindow: self.window, anchorRect: anchorRect)
    }
    actions.libraryContent = { [weak self] section in
      guard let self else { return nil }
      if section == "AI" { return AnyView(NativeAIView(model: self.services, palette: self.servicePalette)) }
      if section == "Extensions" {
        return AnyView(NativeExtensionsView(model: self.extensions, palette: self.servicePalette,
          openStore: { [weak self] in self?.openExtensions(store: true) }))
      }
      return nil
    }
    actions.settingsContent = { [weak self] in
      guard let self else { return nil }
      return AnyView(VStack(alignment: .leading, spacing: 18) {
        NativeAIConnectionView(model: self.services, palette: self.servicePalette)
        NativeSyncSettingsView(model: self.services, palette: self.servicePalette)
      })
    }
    actions.libraryCapabilities = ["download:pause", "download:resume", "download:cancel", "download:rename", "download:undo", "download:suggest", "peek:open", "tab:mute", "data:import-html", "archive:clear", "permission:list", "app:set-default-browser", "window:restore", "bookmark:remove", "bookmark:toggle"]
    actions.performLibraryAction = { [weak self] action, payload in
      guard let self else { return }
      try await self.libraryAction(action, payload: payload)
    }
  }
  func openAISources(action: String, payload: ServiceJSON) async throws -> ServiceJSON {
    guard store.state.activeProfile?.isPrivate == false else { throw ServiceError("PRIVATE", "AI is unavailable in private profiles.") }
    let profileID = store.activeProfileID
    let status = await services.aiService.status(for: AIProfileScope(id: profileID), conversationID: services.conversationID)
    guard status["profileId"].string == profileID, store.activeProfileID == profileID else { throw ServiceError("CONTEXT_CHANGED", "The active profile changed.") }
    let latest = status["latest"]
    let sources = try await services.aiService.verifiedSources(expectedProfileID: profileID, conversationID: services.conversationID)
    guard store.activeProfileID == profileID, !windowContext.isClosing, !engine.isTerminating else {
      throw ServiceError("CONTEXT_CHANGED", "The window or active profile changed.")
    }
    let requested = action == "ai:open-sources" ? latest["sources"].array : [payload]
    var seen = Set<String>()
    for source in requested.prefix(action == "ai:open-sources" ? store.state.settings.openSourcesLimit : 1) {
      let value = source["url"].string
      guard let url = BrowserAddress.webURL(value), seen.insert(value).inserted,
        sources.contains(where: { $0["url"].string == value }) else { continue }
      let baseURL: (String) -> String = { value in
        guard var parts = URLComponents(string: value) else { return value }
        parts.fragment = nil; return parts.string ?? value
      }
      if let tab = store.state.tabs.first(where: {
        store.profileID(for: $0) == store.activeProfileID
          && ($0.id == source["tabId"].string || baseURL($0.url) == baseURL(value))
          && baseURL($0.url) == baseURL(value)
      }) {
        store.selectTab(id: tab.id)
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment != nil, tab.url != value { navigate(value) }
      } else { actions.newTab(url.absoluteString) }
      let quote = String(source["quote"].string.prefix(1000))
      if !quote.isEmpty { activePage?.find(quote) }
    }
    return .null
  }
  func readContext(_ grants: [AIContextGrant]) async throws -> [AIPageExtract] {
    guard grants.count <= 6, Set(grants.map(\.id)).count == grants.count,
      let profile = store.state.activeProfile, !profile.isPrivate else { throw ServiceError("PRIVATE", "Review pages in a regular profile before sharing.") }
    var results: [AIPageExtract] = []
    for grant in grants {
      try Task.checkCancellation()
      guard grant.profileID == profile.id, store.activeProfileID == profile.id,
        let tab = store.tab(grant.id), store.profileID(for: tab) == profile.id,
        tab.url == grant.url.absoluteString else { throw ServiceError("CONTEXT_CHANGED", "A selected page changed. Review it again before sharing.") }
      guard !tab.isClosed, let page = engine.pages[tab.id], owns(page, tabID: tab.id),
        page.url == grant.url, let browser = page.browser else {
        results.append(AIPageExtract(id: tab.id, url: grant.url, title: tab.displayTitle, text: "", error: "Open this page before sharing its text.")); continue
      }
      do {
        let expression = #"""
        (() => {
          const root = document.body?.cloneNode(true);
          if (!root) return {text:'', type:document.contentType};
          const original = document.body.querySelectorAll('*'), copies = root.querySelectorAll('*');
          for (let i=0; i<original.length; i++) {
            const style=getComputedStyle(original[i]);
            if(style.display==='none'||style.visibility==='hidden') copies[i]?.remove();
          }
          root.querySelectorAll('script,style,noscript,input,textarea,select,option,[contenteditable],[hidden],[aria-hidden="true"],iframe,object,embed').forEach(n=>n.remove());
          root.querySelectorAll('p,div,section,article,li,h1,h2,h3,h4,h5,h6,pre,blockquote,br,tr').forEach(n=>n.appendChild(document.createTextNode('\n\n')));
          return {type:document.contentType,text:(root.textContent||'').replace(/[^\S\n]+/g,' ').replace(/\n{3,}/g,'\n\n').trim().slice(0,60000)};
        })()
        """#
        let value = try await browser.devTools.evaluateIsolated(expression) as? [String: Any]
        guard store.activeProfileID == profile.id, owns(page, tabID: tab.id), page.url == grant.url,
          store.tab(tab.id)?.url == grant.url.absoluteString else { throw ServiceError("CONTEXT_CHANGED", "A page or profile changed while it was being read.") }
        if value?["type"] as? String == "application/pdf" || grant.url.pathExtension.lowercased() == "pdf" {
          let response = try await browser.fetchResource(grant.url, maximumBytes: NativePDFExtractor.maximumBytes, maximumRedirects: 3, timeout: 25)
          guard store.activeProfileID == profile.id, owns(page, tabID: tab.id), page.url == grant.url,
            store.tab(tab.id)?.url == grant.url.absoluteString else { throw ServiceError("CONTEXT_CHANGED", "The PDF or profile changed while it was being read.") }
          let extracted = try await NativePDFExtractor(directory: engine.dataDirectory).extract(response.data)
          guard store.activeProfileID == profile.id, owns(page, tabID: tab.id), page.url == grant.url else { throw ServiceError("CONTEXT_CHANGED", "The PDF or profile changed while it was being read.") }
          results.append(AIPageExtract(id: tab.id, url: grant.url, title: page.title, text: extracted.text, pdfPages: extracted.pages, truncated: extracted.truncated))
          continue
        }
        let text = value?["text"] as? String ?? ""
        results.append(AIPageExtract(id: tab.id, url: grant.url, title: page.title, text: text,
          truncated: text.count >= 60_000, error: text.isEmpty ? "This page has no readable text." : nil))
      } catch {
        guard store.activeProfileID == profile.id, page.url == grant.url else { throw ServiceError("CONTEXT_CHANGED", "A page or profile changed while it was being read.") }
        results.append(AIPageExtract(id: tab.id, url: grant.url, title: tab.displayTitle, text: "", error: error.localizedDescription))
      }
    }
    return results
  }
  private func requestPermission(_ request: CefPermissionRequest, page: ChromiumPage) -> CefPermissionDecision {
    guard let url = BrowserAddress.webURL(request.origin), !request.kinds.contains(.other), !request.kinds.isEmpty else { return .deny }
    var origin = URLComponents(); origin.scheme = url.scheme; origin.host = url.host; origin.port = url.port
    guard let key = origin.url?.absoluteString else { return .deny }
    let kinds: [(CefPermissionKind,String,String)] = [(.camera,"camera","camera"),(.microphone,"microphone","microphone"),(.geolocation,"geolocation","location"),(.notifications,"notifications","notifications"),(.clipboard,"clipboard","clipboard"),(.midi,"midi","MIDI devices"),(.pointerLock,"pointer-lock","pointer lock"),(.storageAccess,"storage-access","site storage"),(.sensors,"sensors","sensors"),(.windowManagement,"window-management","window management"),(.downloads,"downloads","multiple downloads")]
    let requested = kinds.filter { request.kinds.contains($0.0) }
    if requested.contains(where: { store.savedPermission(profileID: page.profileID, origin: key, permission: $0.1) == false }) { return .deny }
    if requested.allSatisfy({ store.savedPermission(profileID: page.profileID, origin: key, permission: $0.1) == true }) {
      if !request.kinds.intersection([.camera, .microphone]).isEmpty { mediaPermissionPages.insert(page.id) }
      return .allow
    }
    let originalURL = page.url
    let alert = NSAlert(); alert.messageText = "Allow \(url.host ?? request.origin) to use \(requested.map { $0.2 }.joined(separator: ", "))?"
    alert.addButton(withTitle: "Don’t Allow"); alert.addButton(withTitle: "Allow")
    let allowed = alert.runModal() == .alertSecondButtonReturn
    guard page.url == originalURL, engine.pages[page.id] === page,
      store.state.profiles.contains(where: { $0.id == page.profileID }) else { return .deny }
    for kind in requested { store.setPermission(profileID: page.profileID, origin: key, permission: kind.1, allowed: allowed) }
    if allowed && !request.kinds.intersection([.camera, .microphone]).isEmpty { mediaPermissionPages.insert(page.id) }
    return allowed ? .allow : .deny
  }
  private func libraryAction(_ action: String, payload: [String:String]) async throws {
    guard !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    if let profile = payload["profileId"], profile != store.activeProfileID { throw ShortcutError("The active profile changed. Try again.") }
    let id = payload["id"] ?? payload["tabID"] ?? store.state.activeTabID ?? ""
    if action == "bookmark:toggle" {
      guard let tab = store.tab(id), let profileID = store.profileID(for: tab), profileID == store.activeProfileID else { throw CancellationError() }
      try await application.bookmarks.toggle(profileID: profileID, url: tab.url, title: tab.displayTitle)
    } else if action == "bookmark:remove" {
      try await application.bookmarks.remove(profileID: store.activeProfileID, bookmarkID: id)
    } else if action == "window:restore", let id = payload["windowID"] {
      try application.reopenWindow(id: id)
    } else if action == "history:clear" {
      try await clearHistory(profileID: store.activeProfileID)
    } else if action == "archive:clear" {
      let profile = store.activeProfileID
      let ids = store.state.archive.filter { store.profileID(for: $0.tab) == profile }.map { $0.tab.id }
      try store.clearArchiveDurably(profileID: profile)
      for id in ids where store.tab(id) == nil { try await navigation.removeSavedTab(profileID: profile, tabID: id) }
    } else if action == "data:clear" {
      try await clearProfileData(profileID: store.activeProfileID)
    } else if action.hasPrefix("download:"), action != "download:suggest" {
      try await downloads.perform(action, id: id, name: payload["name"] ?? "", profileID: store.activeProfileID)
    } else if action == "download:suggest" {
      let record = try downloads.record(id, profileID: store.activeProfileID)
      let suggestion = try await services.aiAction("ai:suggest-name", payload: ["name":.string(record.filename), "url":.string(record.sourceURL ?? record.url), "title":.string(record.sourceTitle ?? "")])
      _ = try downloads.record(id, profileID: store.activeProfileID)
      let alert = NSAlert(); alert.messageText = "Rename download"
      let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = suggestion["name"].string
      alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn { try await downloads.perform("download:rename", id: id, name: field.stringValue, profileID: store.activeProfileID) }
    } else if action == "tab:mute", let tab = store.tab(id), store.profileID(for: tab) == store.activeProfileID {
      store.updateTab(id) { $0.isMuted.toggle() }; engine.pages[id]?.browser?.isAudioMuted = !tab.isMuted
    } else if action == "tab:sleep" { try await sleepTab(id) }
    else if action == "peek:open", let address = payload["url"] {
      if let tab = store.state.activeTab { store.setPeek(tabID: tab.id, address: address) }
      else { actions.newTab(address) }
    } else if action == "data:import-bookmarks", let path = payload["path"] {
      let profileID = store.activeProfileID
      try store.importData(from: URL(fileURLWithPath: path))
      if application.bookmarks.enabled, store.state.activeProfile?.isPrivate == false {
        try await application.bookmarks.refresh(profileID: profileID)
      }
    }
    else if action == "permission:list" { _ = actions.performInterfaceCommand("permissions") }
    else if action == "app:set-default-browser" {
      for scheme in ["http", "https"] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          }
        }
      }
      refreshDefaultBrowser()
    } else { throw ShortcutError("This action is unavailable for the selected item.") }
  }
  private func toggleBookmark() {
    guard let page = activePage, let url = page.url, BrowserAddress.webURL(url.absoluteString) != nil else { return }
    let profileID = page.profileID, title = page.title
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.application.bookmarks.toggle(profileID: profileID, url: url.absoluteString, title: title)
        self.refreshSiteControls()
      } catch { self.showError(error.localizedDescription) }
    }
  }
  private func clearHistory(profileID: String) async throws {
    guard deletingProfileID == nil, pendingDeletion == nil,
      let profile = store.state.profiles.first(where: { $0.id == profileID }),
      application.clearingHistoryProfiles.insert(profileID).inserted else {
      throw ShortcutError("Finish the current profile operation first.")
    }
    defer { application.clearingHistoryProfiles.remove(profileID) }
    navigation.beginProfileReset(profileID)
    defer {
      navigation.endProfileReset(profileID)
      for owner in application.windows.values { owner.updateNavigationState(owner.activePage) }
    }
    // Clear the same HistoryService queried by extensions and Chrome pages
    // before committing the corresponding Swift collection/vault deletion.
    if profile.isPrivate {
      let maintenance = engine.page(id: "history-maintenance:" + profileID, profileID: profileID,
        isPrivate: true, url: URL(string: "about:blank")!, ownerWindowID: nil)
      defer { maintenance.close() }
      maintenance.hide()
      try await maintenance.ready().clearProfileBrowsingData(siteData: false, cache: false, history: true)
    } else {
      try await ChromeExtensionManager(engine: engine, profileID: profileID).clearBrowsingHistory()
    }
    for page in engine.pages.values where page.profileID == profileID
      && (application.store.tab(page.id) != nil || page.id.hasPrefix("peek:")) {
      if let browser = page.browser {
        _ = try await browser.devTools.call("Page.resetNavigationHistory")
        for owner in application.windows.values { owner.restoredHistoryPages.remove(page.id) }
      }
    }
    try store.clearHistoryDurably(profileID: profileID)
    try await navigation.clearSavedHistory(profileID: profileID)
  }

  private func clearProfileData(profileID: String) async throws {
    guard deletingProfileID == nil, pendingDeletion == nil,
      !application.clearingHistoryProfiles.contains(profileID),
      let profile = store.state.profiles.first(where: { $0.id == profileID }) else {
      throw ShortcutError("Finish the current profile operation first.")
    }
    let maintenance = engine.page(id: "maintenance:" + profileID, profileID: profileID,
      isPrivate: profile.isPrivate, url: URL(string: "about:blank")!, ownerWindowID: nil)
    defer { maintenance.close() }
    maintenance.hide()
    let browser = try await maintenance.ready()
    guard try await browser.nativeCapabilities().browsingData else {
      throw ShortcutError("The Chromium runtime cannot clear all site data.")
    }
    if !profile.isPrivate && store.activeProfileID == profileID {
      _ = try await services.aiAction("ai:reset", payload: [:])
    }
    deletingProfileID = profileID
    navigation.beginProfileReset(profileID)
    application.bookmarks.removeProfile(profileID)
    downloads.removeProfile(profileID)
    await extensionSync.pauseProfile(profileID)
    defer {
      deletingProfileID = nil
      navigation.endProfileReset(profileID)
      extensionSync.resumeProfile(profileID)
      scheduleLayout()
    }
    let documents = engine.pages.values.filter { $0.profileID == profileID && $0 !== maintenance }
    let ids = Set(documents.map(\.id))
    if !ids.isEmpty {
      let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        profileDeletionPageIDs.formUnion(ids)
        scopeCloseCancelled = { continuation.resume(returning: false) }
        pendingDeletion = (ids, { [weak self] in
          self?.scopeCloseCancelled = nil
          continuation.resume(returning: true)
        })
        for page in documents { page.close() }
      }
      guard closed else { throw CancellationError() }
    }
    try await browser.clearProfileBrowsingData(siteData: true, cache: true, history: true)
    try await engine.clearNetworkData(profileID: profileID, isPrivate: profile.isPrivate,
      selected: [.cookies, .cache, .httpAuthentication])
    try store.clearHistoryDurably(profileID: profileID)
    try store.clearPermissionsDurably(profileID: profileID)
    try await navigation.clearSavedHistory(profileID: profileID)
    let tabs = store.state.tabs.filter { store.profileID(for: $0) == profileID }
    for tab in tabs {
      if tab.peek != nil { store.closePeek(tabID: tab.id) }
      actions.icons.removeValue(forKey: tab.id); actions.iconColors.removeValue(forKey: tab.id)
      actions.peekIcons.removeValue(forKey: tab.id)
    }
    favicons.clear(profile: profileID)
  }
  private func sleepTab(_ id: String) async throws {
    guard let tab = store.tab(id), store.profileID(for: tab) == store.activeProfileID, tab.isPinned else { return }
    _ = try await unloadInactiveTab(id)
  }

  private func canUnload(_ page: ChromiumPage, tab: BrowserTab, automatically: Bool = false) -> Bool {
    guard !automatically || tab.autoDiscardable != false else { return false }
    guard !Task.isCancelled, windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      owns(page, tabID: tab.id), !page.isLoading,
      store.state.activeTabID != tab.id, visibleSplit?.tabIDs.contains(tab.id) != true, tab.peek == nil,
      !visiblePageFrames.keys.contains(page.id), !navigation.isRestoring(page),
      !reservedPages.contains(page.id), !dormantPages.contains(page.id), !discardingPages.contains(page.id), !mediaPermissionPages.contains(page.id),
      !page.hasPendingAuthentication, !downloads.protects(tab, profileID: page.profileID),
      page.openerID.flatMap({ engine.pages[$0] }) == nil,
      !engine.pages.values.contains(where: { $0.openerID == page.id }) else { return false }
    return true
  }

  func unloadInactiveTab(_ id: String, automatically: Bool = false) async throws -> Bool {
    guard actions.libraryCapabilities.contains("tab:sleep"), let tab = store.tab(id),
      let page = engine.pages[id], let browser = page.browser, canUnload(page, tab: tab, automatically: automatically) else { return false }
    let url = page.url
    let activity = tab.lastAccessedAt
    guard try await browser.documentSafetyState().permitsAutomaticUnload else { return false }
    let safe = try await browser.devTools.evaluateIsolated(#"""
      (() => {
        const inspect=(doc,depth=0)=>{
          if(!doc||depth>8||doc.designMode==='on'||doc.querySelector('[contenteditable]:not([contenteditable="false"])'))return false;
          for(const input of doc.querySelectorAll('input')){
            if(input.type==='checkbox'||input.type==='radio'){if(input.checked!==input.defaultChecked)return false;}
            else if(input.type==='file'){if(input.files.length)return false;}
            else if(input.value!==input.defaultValue)return false;
          }
          for(const input of doc.querySelectorAll('textarea'))if(input.value!==input.defaultValue)return false;
          for(const select of doc.querySelectorAll('select')){
            const options=[...select.options],defaults=options.map((o,i)=>o.defaultSelected?i:-1).filter(i=>i>=0);
            if(!select.multiple&&!defaults.length&&options.length)defaults.push(0);
            if(options.some((o,i)=>o.selected!==defaults.includes(i)))return false;
          }
          for(const media of doc.querySelectorAll('audio,video'))if(!media.paused||media.srcObject)return false;
          for(const frame of doc.querySelectorAll('iframe,frame')){try{if(!inspect(frame.contentDocument,depth+1))return false;}catch{return false;}}
          return true;
        };return inspect(document);
      })()
      """#, timeout: 1) as? Bool
    guard safe == true, let current = store.tab(id), current.lastAccessedAt == activity,
      canUnload(page, tab: current, automatically: automatically), page.url == url else { return false }
    let captured = page.isPrivate ? true : await navigation.capture(page, tabID: id, peek: false)
    guard captured,
      let latest = store.tab(id), latest.lastAccessedAt == activity,
      canUnload(page, tab: latest, automatically: automatically), page.url == url,
      try await browser.documentSafetyState().permitsAutomaticUnload else { return false }
    guard let current = store.tab(id), current.lastAccessedAt == activity,
      canUnload(page, tab: current, automatically: automatically), page.url == url else { return false }
    discardingPages.insert(id)
    let operation = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      defer { self.discardOperations.removeValue(forKey: id); self.discardingPages.remove(id); self.scheduleLayout() }
      do {
        try await browser.discardDocument()
        guard self.engine.pages[id] === page else { throw CancellationError() }
        self.dormantPages.insert(id)
        self.navigation.forget(id)
      } catch {
        if page.url?.absoluteString == "about:blank", self.engine.pages[id] === page { self.dormantPages.insert(id) }
        throw error
      }
    }
    discardOperations[id] = operation
    try await operation.value
    return engine.pages[id] === page && dormantPages.contains(id)
  }

  private func maintainInactiveTabs() async {
    guard windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating, deletingProfileID == nil else { return }
    store.recordVisibleTabActivity()
    let liveIDs = Set(engine.pages.keys).subtracting(dormantPages).subtracting(reservedPages)
    store.archiveStale(excludeIDs: liveIDs)
    for tab in store.archiveCandidates() {
      guard !Task.isCancelled else { return }
      if (try? await unloadInactiveTab(tab.id)) == true,
        store.archiveCandidates().contains(where: { $0.id == tab.id }) { store.closeTab(id: tab.id) }
    }
    let minutes = store.state.settings.pinnedSleepMinutes
    guard minutes > 0 else { return }
    for tab in store.state.tabs where tab.isPinned && Date().timeIntervalSince(tab.lastAccessedAt) >= Double(minutes) * 60 {
      guard !Task.isCancelled else { return }
      _ = try? await unloadInactiveTab(tab.id, automatically: true)
    }
  }

  private func inspectRuntimeCapabilities(_ page: ChromiumPage? = nil) {
    application.inspectRuntimeCapabilities()
  }

}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
  var shouldPassThrough: (NSPoint) -> Bool = { _ in false }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return shouldPassThrough(local) ? nil : super.hitTest(point)
  }
}

private struct NativeContentOverlay: View {
  @ObservedObject var store: BrowserStore
  let coordinator: BrowserWindowCoordinator
  @State private var resizeRatio: Double?
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if coordinator.visibleSplit == nil && (store.state.activeTab == nil || store.state.activeTab?.url == "about:blank"
          || store.state.activeTab?.isClosed == true) && !coordinator.actions.nativePageVisible {
          NativeEmptyPageBackground(theme: store.state.activeSpace?.theme ?? SpaceTheme())
        } else if let split = coordinator.visibleSplit {
          NativeResizeHandle(
            value: resizeRatio ?? split.ratio,
            range: coordinator.splitResizeRange(width: geometry.size.width),
            step: 0.02, fineStep: 0.02, largeStep: 0.1, reset: 0.5,
            pixelsPerUnit: max(2, geometry.size.width - 6), label: "Resize split view",
            valueDescription: { "\(Int(($0 * 100).rounded()))% left, \(Int(((1 - $0) * 100).rounded()))% right" },
            preview: { value in
              resizeRatio = value
              coordinator.previewSplitRatio(id: split.id, ratio: value)
            }, commit: { value in
              resizeRatio = nil
              coordinator.finishSplitResize(id: split.id, ratio: value)
            }, cancel: {
              resizeRatio = nil
              coordinator.finishSplitResize(id: split.id, ratio: nil)
            }
          )
          .frame(width: 6, height: geometry.size.height)
          .position(x: (geometry.size.width - 6) * (resizeRatio ?? split.ratio) + 3,
                    y: geometry.size.height / 2)
          .id(split.id)
          .onChange(of: split.id) { _, _ in resizeRatio = nil }
          .onDisappear { resizeRatio = nil; coordinator.finishSplitResize(id: split.id, ratio: nil) }

        } else {
          Color.clear
        }
      }.coordinateSpace(name: "content")
    }
  }
}
