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
    let performanceRequested = CommandLine.arguments.contains("--native-performance-acceptance")
    guard !(integrationRequested || performanceRequested) || CommandLine.arguments.contains("--engine-acceptance") else {
      fputs("Application integration requires the disposable engine acceptance mode.\n", stderr)
      exit(1)
    }
    guard !performanceRequested || (!integrationRequested &&
      ProcessInfo.processInfo.environment["ZACRO_PERFORMANCE_OUTPUT"]?.isEmpty == false) else {
      fputs("Performance diagnostics require their own disposable run and an output path.\n", stderr)
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
        !integrationRequested, !performanceRequested,
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
      if integrationRequested || performanceRequested { coordinator.store.updateSettings { $0.onboardingCompleted = true } }
      NSApplication.shared.delegate = coordinator
      NSApplication.shared.setActivationPolicy(.regular)
      coordinator.install()
      let integration = integrationRequested ? BrowserIntegrationAcceptance(application: coordinator) : nil
      if let integration, let raw = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"], let url = URL(string: raw) {
        integration.run(url: url)
      }
      let performance = performanceRequested ? NativePerformanceAcceptance(application: coordinator) : nil
      performance?.run()
      withExtendedLifetime((coordinator, integration, performance)) { NSApplication.shared.run() }
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
final class BrowserWindowCoordinator: NSObject, NSMenuItemValidation {
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
  lazy var peekOpening = NativePeekOpeningCoordinator(owner: self)
  func pendingPeekReplacementCount(_ sourceID: String) -> Int {
    peekOpening.pendingRequestCount(sourceTabID: sourceID)
  }
  var hasPresentedPeek: Bool { peekPanel.presentationWindow?.isVisible == true }
  private let loadingStrips = NativeLoadingStripController()
  private let documentErrorPanels = NativeDocumentErrorPanelController()
  func hasPresentedDocumentError(_ id: String) -> Bool { documentErrorPanels.isPresented(documentID: id) }
  func presentedDocumentErrorBounds(_ id: String) -> CGRect? { documentErrorPanels.presentedBounds(documentID: id) }
  private var loadingDocumentIDs = Set<String>()
  private var observedDocumentBounds: [String: CGRect] = [:]
  private var selectionFocusIntent = DocumentFocusIntent()
  private var selectionFocusTask: Task<Void, Never>?
  private var reservedSelectionFocusToken: DocumentFocusIntent.Token?
  private struct SelectionFocusDiagnostic {
    let time: TimeInterval
    let event: String
    let phase: DocumentFocusIntent.Phase
    let requestedID: String?
    let intentID: String?
    let intentProfileID: String?
    let selectedID: String?
    let activeTabID: String?
    let profileID: String
    let ownerNativeID: Int
    let ownerOpen: Bool
    let ownerClosing: Bool
    let terminating: Bool
    let deletingProfileID: String?
    let appActive: Bool
    let mouseButtons: Int
    let environmentAllowed: Bool
    let transitionAllowed: Bool
    let focusAllowed: Bool
    let keyWindow: Int
    let keyOwned: Bool
    let responderType: Any.Type?
    let ownerWindow: Int
    let ownerSheet: Int
    let modalWindow: Int
    let nativeID: Int32
    let pageWindow: Int
    let pageVisible: Bool
    let requestedNativeID: Int32
    let requestedWindow: Int
    let requestedKey: Bool
  }
  private let selectionFocusDiagnosticsAvailable = CommandLine.arguments.contains("--engine-acceptance")
    && CommandLine.arguments.contains("--native-integration-acceptance")
  private var selectionFocusDiagnosticIDs = Set<String>()
  private var selectionFocusDiagnostics: [SelectionFocusDiagnostic] = []
  private var selectionFocusDiagnosticNext = 0
  private var collectionPanelTask: Task<Void, Never>?
  private var deferredWindowError: String?
  private weak var retiringPaletteEditor: NSTextView?
  private weak var retiringPaletteWindow: NSWindow?
  private var retiringPaletteDeadline: TimeInterval = 0
  private var pendingDeletion: (Set<String>, () -> Void)? { get { application.pendingDeletion } set { application.pendingDeletion = newValue } }
  private var profileDeletionPageIDs: Set<String> { get { application.profileDeletionPageIDs } set { application.profileDeletionPageIDs = newValue } }
  private var deletingProfileID: String? { get { application.deletingProfileID } set { application.deletingProfileID = newValue } }
  private var scopeCloseCancelled: (() -> Void)? { get { application.scopeCloseCancelled } set { application.scopeCloseCancelled = newValue } }
  private var favicons: FaviconCache { application.favicons }
  private var peekFrames: [String: CGRect] = [:]
  private var peekOrigins: [String: CGRect] = [:]
  private var peekClosingSnapshots: [String: NSImage] = [:]
  private var retiringPageIDs = Set<String>()
  private var retirementTasks: [ObjectIdentifier: (id: UUID, task: Task<Void, Never>)] = [:]
  private var retirementReviews: [ObjectIdentifier: (id: UUID, task: Task<Void, Never>)] = [:]
  private var visiblePageFrames: [String: CGRect] = [:]
  private var sidePanelPageIDs = Set<String>()
  private var modelURLs: [String: String] = [:]
  private var iconDestinations: [String: String] = [:]
  struct PendingHistory {
    let source: String?
    let destination: String
    let liveRequestID: UUID?
    init(source: String?, destination: String, liveRequestID: UUID? = nil) {
      self.source = source; self.destination = destination; self.liveRequestID = liveRequestID
    }
  }
  private var pendingHistory: [String: PendingHistory] = [:]
  private var liveNavigations: [String: (id: UUID, task: Task<Void, Never>)] = [:]
  func hasPendingLiveNavigation(_ id: String) -> Bool { liveNavigations[id] != nil }
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
  private struct PendingSitePermission {
    let pageID: String
    let profileID: String
    let address: URL?
    let key: String
    let request: CefPermissionRequest
    let originKey: String
    let permissionKeys: [String]
    let alert: NSAlert
    let callback: CefPermissionCallback
    var presented = false
  }
  private var permissionPrompts: [UUID: PendingSitePermission] = [:]
  private var permissionQueue: [UUID] = []
  var pendingPermissionRequestCount: Int { permissionPrompts.count }
  private var idleSweep: Task<Void, Never>?
  private lazy var extensions = NativeExtensionsModel(store: store, engine: engine, actions: actions)
  private var siteControlsInitialized = false
  private var siteControlProfileID: String?
  private var commandFingerprint = ""
  private var nativeMenus: (fingerprint: String, bar: NSMenu, services: NSMenu, windows: NSMenu, help: NSMenu)?
  private var recentTabCycle: [String]?
  private var recentTabIndex = 0
  private var recentModifiers: NSEvent.ModifierFlags = []
  private var scopedServices: NativeServicesModel?
  private var servicesRetirement: Task<Void, Never>?
  private var serviceObservations = Set<AnyCancellable>()
  private var aiCommandRefreshQueued = false
  var services: NativeServicesModel {
    if let scopedServices { return scopedServices }
    let model = NativeServicesModel(store: store, sharing: application.services, predecessor: servicesRetirement)
    model.sourceAction = { [weak self] action, payload in
      guard let self else { throw CancellationError() }
      return try await self.openAISources(action: action, payload: payload)
    }
    model.dialogWindow = { [weak self] in
      guard let self, self.windowContext.isOpen, !self.windowContext.isClosing,
        !self.engine.isTerminating else { return nil }
      return self.window
    }
    scopedServices = model
    serviceObservations.removeAll()
    model.objectWillChange.sink { [weak self] _ in self?.scheduleAICommandRefresh() }
      .store(in: &serviceObservations)
    model.aiConversation.objectWillChange.sink { [weak self] _ in self?.scheduleAICommandRefresh() }
      .store(in: &serviceObservations)
    scheduleAICommandRefresh()
    return model
  }
  private func scheduleAICommandRefresh() {
    guard !aiCommandRefreshQueued else { return }
    aiCommandRefreshQueued = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.aiCommandRefreshQueued = false
      self.refreshAICommands()
    }
  }
  private func refreshAICommands() {
    let model = scopedServices
    let configured = windowContext.isOpen && !windowContext.isClosing && !engine.isTerminating
      && model?.ai["profileId"].string == store.activeProfileID
      && model?.ai["configured"].bool == true && store.state.activeProfile?.isPrivate == false
    let busy = model?.canSubmitAIQuestion != true
    if actions.aiConfigured != configured { actions.aiConfigured = configured }
    if actions.aiBusy != busy { actions.aiBusy = busy }
  }
  private func presentAIQuestion(_ value: String) {
    guard windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating else { return }
    let model = services, profile = store.activeProfileID
    let question = value.trimmingCharacters(in: .whitespacesAndNewlines)
    actions.library = "AI"
    window?.makeKeyAndOrderFront(nil)
    guard !question.isEmpty else { return }
    guard question.utf16.count <= 8000 else {
      model.aiConversation.notice = "Keep your question under 8,000 characters."
      return
    }
    guard model.canSubmitAIQuestion else { model.aiConversation.prepare(question); return }
    Task { [weak self, weak model] in
      guard let self, let model, self.scopedServices === model,
        self.windowContext.isOpen, !self.windowContext.isClosing, !self.engine.isTerminating,
        self.store.activeProfileID == profile else { return }
      do { _ = try await model.submitAIQuestion(question, expectedProfileID: profile) }
      catch {
        guard self.scopedServices === model, self.windowContext.isOpen,
          !self.windowContext.isClosing, self.store.activeProfileID == profile else { return }
        model.aiConversation.notice = error.localizedDescription
      }
    }
  }
  init(application: ApplicationCoordinator, store: BrowserStore, context: ChromiumWindowContext) {
    self.application = application
    self.store = store
    self.windowContext = context
  }
  var windowPages: [String: ChromiumPage] { engine.pages.filter { $0.value.ownerWindowID == windowContext.id } }
  struct TabPresentationState {
    var urls: [String: String] = [:]
    var pending: [String: PendingHistory] = [:]
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
    // Title/redirect/load events may all finish while document adapters are
    // preparing. Reconcile the retained document once restoration releases
    // its metadata guard instead of waiting for another unrelated event.
    windowPages[id]?.onChange?()
    updateNavigationState(activePage)
    scheduleLayout()
  }
  func prepareTermination() {
    peekOpening.cancel()
    collectionPanelTask?.cancel(); collectionPanelTask = nil
    actions.cancelWindowInteractions()
    actions.resetWindowPresentation()
    if let window {
      NativeWindowSheet.cancel(for: window)
      NativeResizeHandle.cancel(in: window)
    }
    cancelPermissionPrompts()
    loadingStrips.hide()
    documentErrorPanels.hide()
    cancelSelectionFocus()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    extensions.close()
    idleSweep?.cancel()
    for task in pageCreations.values { task.cancel() }
    for task in dormantNavigations.values { task.cancel() }
    pagePreparations.removeAll()
  }
  @discardableResult
  private func retireServicesPresentation() -> Task<Void, Never>? {
    if let model = scopedServices { servicesRetirement = model.beginShutdown() }
    scopedServices = nil
    serviceObservations.removeAll()
    refreshAICommands()
    return servicesRetirement
  }
  func closeServicesPresentation() async {
    await retireServicesPresentation()?.value
  }
  func reopen() {
    actions.nativePageVisible = false
    pageCreationFailures.removeAll()
    extensions.refresh()
    services.start()
    scheduleLayout()
  }
  func prepareTabTransfer(_ id: String) async throws {
    guard let original = store.tab(id), let profileID = store.profileID(for: original) else { throw CancellationError() }
    let ownerID = windowContext.id
    func requireOwner() throws {
      try Task.checkCancellation()
      guard let tab = store.tab(id), !tab.isClosed, tab.windowID == ownerID,
        tab.createdAt == original.createdAt, store.profileID(for: tab) == profileID,
        closeWaiters[id] == nil, windowContext.isOpen, !windowContext.isClosing,
        !engine.isTerminating, deletingProfileID != profileID else { throw CancellationError() }
    }
    try requireOwner()
    for key in [id, "peek:" + id] {
      if let task = pageCreations[key] { task.cancel(); _ = try? await task.value }
      try requireOwner()
    }
    try await discardOperations[id]?.value
    try requireOwner()
    try await dormantNavigations[id]?.value
    try requireOwner()
    for key in [id, "peek:" + id] {
      if let page = engine.pages[key] {
        try await settleLiveNavigation(page)
        try await navigation.waitForRestore(page)
        try requireOwner()
        guard engine.pages[key] === page, page.id == key, page.ownerWindowID == ownerID,
          page.profileID == profileID, liveNavigations[key] == nil else { throw CancellationError() }
      }
    }
    try requireOwner()
    guard liveNavigations[id] == nil, liveNavigations["peek:" + id] == nil else { throw CancellationError() }
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
  func adoptPopup(_ popup: ChromiumPage, spaceID: String? = nil, foreground: Bool,
    validateAdoption: (() throws -> Void)? = nil) async -> Bool {
    let profileID = spaceID.flatMap { id in store.state.spaces.first { $0.id == id }?.profileID } ?? store.activeProfileID
    guard engine.pages[popup.id] === popup, !popup.creationFailed,
      popup.profileID == profileID, !windowContext.isClosing else { return false }
    var preparation: NativeHistoryPublicationPreparation?
    var committed = false
    do {
      try validateAdoption?()
      if !popup.isPrivate {
        application.inspectRuntimeCapabilities()
        await application.runtimeCapabilityTask?.value
        try validateAdoption?()
        guard application.runtimeCapabilitiesChecked else {
          throw ShortcutError("Chromium’s browser capabilities could not be verified. Try again.")
        }
      }
      if !popup.isPrivate && application.supportsHistoryMirror {
        preparation = try await application.historyMirror.preparePublication(popup)
        try validateAdoption?()
      }
      guard engine.pages[popup.id] === popup, !popup.creationFailed, !engine.isTerminating,
        popup.profileID == profileID, !windowContext.isClosing,
        store.state.profiles.contains(where: { $0.id == profileID }),
        store.state.spaces.contains(where: { $0.id == (spaceID ?? store.state.activeSpaceID) && $0.profileID == profileID }) else {
        throw CancellationError()
      }
      let address = popup.browser?.url?.absoluteString ?? "about:blank"
      try validateAdoption?()
      let tab: BrowserTab
      if let preparation {
        try preparation.validate()
        var candidate = BrowserTab(spaceID: spaceID ?? store.state.activeSpaceID,
          url: address, title: popup.title.isEmpty ? (URL(string: address)?.host ?? "New tab") : popup.title)
        candidate.windowID = windowContext.id
        candidate.navigation = [NavigationEntry(url: address)]; candidate.navigationIndex = 0
        if let openerID = popup.openerID, let opener = application.store.document(id: openerID),
          !opener.isClosed, application.store.profileID(for: opener) == profileID { candidate.openerTabID = openerID }
        tab = try store.adoptNativeHistoryPopupDurably(candidate, publication: preparation.publication, activate: false)
        committed = true
      } else {
        let destination = BrowserAddress.extensionURL(address) != nil
          ? store.createExtensionTab(url: address, spaceID: spaceID, activate: false)
          : store.createTab(address: address, spaceID: spaceID, activate: false)
        guard let destination else { throw CancellationError() }; tab = destination
      }
      application.popupAdoptions.didCommitCore(popup, tabID: tab.id)
      guard engine.movePage(id: popup.id, toWindowID: windowContext.id),
        engine.adoptPage(fromID: popup.id, toID: tab.id) != nil else {
        if !committed { store.closeTab(id: tab.id) }
        throw CancellationError()
      }
      if preparation == nil, let openerID = popup.openerID, let opener = application.store.document(id: openerID),
        !opener.isClosed, application.store.profileID(for: opener) == profileID {
        store.updateTab(tab.id) { $0.openerTabID = openerID }
      }
      modelURLs[tab.id] = popup.browser?.url?.absoluteString ?? tab.url
      wire(popup, tabID: tab.id, peek: false)
      application.popupAdoptions.didAdopt(popup)
      if foreground { store.selectTab(id: tab.id); focusSelectedDocument(force: true) }
      extensionBrowser.reconcile()
      scheduleLayout()
      await preparation?.finish(committed: committed)
      return true
    } catch {
      await preparation?.finish(committed: committed)
      if !(error is CancellationError) { showError(error.localizedDescription) }
      return false
    }
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
  private func performToolbarNavigation(_ action: () -> Void) {
    let event = NSApp.currentEvent
    let mouseOrigin = event?.window === window
      // The delivered release event is authoritative. AppKit's global button
      // snapshot can still report the button during this mouse-up action.
      && event?.type == .leftMouseUp
      && event.map { abs(ProcessInfo.processInfo.systemUptime - $0.timestamp) <= 0.5 } == true
    let restorePage = mouseOrigin ? actions.capturePageFocusRestoration() : nil
    action()
    _ = restorePage?()
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
      NativeContentOverlay(store: self!.store, actions: self!.actions, coordinator: self!)
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
      self?.focusSelectedDocument(force: true)
    }
    actions.back = { [weak self] in
      guard let self else { return }
      self.performToolbarNavigation { self.goBack() }
    }
    actions.forward = { [weak self] in
      guard let self else { return }
      self.performToolbarNavigation { self.goForward() }
    }
    actions.reload = { [weak self] in
      guard let self else { return }
      self.performToolbarNavigation {
        if let page = self.activePage {
          if page.isLoading { page.stop() } else { page.reload() }
        } else { self.retryActivePage() }
      }
    }
    actions.zoom = { [weak self] in self?.activePage?.zoom(by: $0) }
    actions.printPage = { [weak self] in self?.activePage?.printPage() }
    actions.find = { [weak self] in self?.find() }
    actions.focusPage = { [weak self] in
      guard let self, self.windowContext.isOpen, !self.windowContext.isClosing,
        !self.engine.isTerminating, !self.actions.palette, !self.actions.themeEditor,
        self.actions.library == nil, self.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
      self.activePage?.focus()
    }
    actions.capturePageFocusRestoration = { [weak self] in
      guard let self, NSApp.isActive, self.windowContext.isOpen, !self.windowContext.isClosing,
        !self.engine.isTerminating, self.deletingProfileID == nil,
        let root = self.window, let page = self.activePage, let native = page.nativeWindow,
        native.isVisible,
        self.selectedDocumentID == page.id, page.ownerWindowID == self.windowContext.id,
        page.profileID == self.store.activeProfileID, self.engine.pages[page.id] === page else { return nil }
      let documentOrigin = NSApp.keyWindow === native && native.isKeyWindow
      let event = NSApp.currentEvent
      let rootMouseOrigin = NSApp.keyWindow === root && root.isKeyWindow
        && event?.window === root && (event?.type == .leftMouseDown || event?.type == .leftMouseUp)
        && event.map { abs(ProcessInfo.processInfo.systemUptime - $0.timestamp) <= 0.5 } == true
        && !((root.firstResponder as? NSText)?.isEditable == true)
      guard documentOrigin || rootMouseOrigin else { return nil }
      let ownerID = self.windowContext.id, selectedID = page.id, profileID = page.profileID
      let rootEditor = root.firstResponder as? NSTextView
      let rootEditorDelegate = rootEditor?.delegate as AnyObject?
      return { [weak self, weak page, weak native, weak root, weak rootEditor,
        weak rootEditorDelegate] in
        guard let self, let page, let native, let root else { return false }
        @MainActor func admitted() -> Bool {
          guard NSApp.isActive, self.application.focusedCoordinator === self,
            self.windowContext.id == ownerID, self.window === root,
            self.windowContext.isOpen, !self.windowContext.isClosing, !self.engine.isTerminating,
            self.deletingProfileID == nil, root.isVisible, !root.isMiniaturized,
            self.store.activeProfileID == profileID, self.selectedDocumentID == selectedID,
            self.activePage === page, self.engine.pages[selectedID] === page,
            page.ownerWindowID == ownerID, page.profileID == profileID, page.documentError == nil,
            page.nativeWindow === native, native.isVisible,
            !self.actions.palette, !self.actions.themeEditor, self.actions.library == nil,
            !self.actions.findVisible, !self.actions.recordingShortcut,
            root.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
          let key = NSApp.keyWindow
          let retiringPalette = self.retiringPaletteWindow
          let retiringOwnPanel = key === retiringPalette && retiringPalette?.isVisible == false
            && retiringPalette?.parent == nil && ProcessInfo.processInfo.systemUptime < self.retiringPaletteDeadline
          guard key == nil || key === native || key === root || retiringOwnPanel else { return false }
          if key === root, let editor = root.firstResponder as? NSTextView {
            guard editor === rootEditor, (editor.delegate as AnyObject?) === rootEditorDelegate else { return false }
          }
          return true
        }
        guard admitted() else { return false }
        self.cancelSelectionFocus()
        self.layoutPages()
        guard admitted() else { return false }
        // Clear an old rail keyboard target only for this admitted explicit
        // document return. A generic native-key notification can also occur
        // during an unrelated root-editor/sidebar handoff.
        self.actions.prepareDocumentFocusRestoration()
        guard admitted() else { return false }
        page.focus()
        return NSApp.keyWindow === native && native.isKeyWindow
      }
    }
    actions.sidebarToggleOwnsFocus = { [weak self] candidate in
      self?.ownsSidebarToggleFocus(candidate) == true
    }
    actions.focusPageAfterSidebarToggle = { [weak self] in
      // The handoff has synchronously checked exact key-window ownership,
      // including a just-detached owned palette. Do not infer it a second time.
      guard let self, NSApp.isActive, self.application.focusedCoordinator === self,
        self.windowContext.isOpen, !self.windowContext.isClosing, !self.engine.isTerminating,
        self.deletingProfileID == nil, self.window?.isVisible == true,
        !self.actions.palette, !self.actions.themeEditor, !self.actions.recordingShortcut,
        self.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
      // Library can remain open while its rail hides. The toggle explicitly
      // returns focus to the selected document, not to a different control.
      let selected = self.selectedDocumentID, profile = self.store.activeProfileID
      self.cancelSelectionFocus()
      self.layoutPages()
      guard self.selectedDocumentID == selected, self.store.activeProfileID == profile else { return }
      if let page = self.activePage, page.documentError == nil,
        page.ownerWindowID == self.windowContext.id, page.profileID == self.store.activeProfileID,
        page.id == self.selectedDocumentID, page.nativeWindow?.isVisible == true {
        page.focus()
      } else { self.window?.makeKeyAndOrderFront(nil) }
    }
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
      self.peekOpening.cancel()
      self.collectionPanelTask?.cancel()
      if let window = self.window { NativeWindowSheet.cancel(for: window) }
      self.deferredWindowError = nil
      self.actions.resetWindowPresentation()
      self.cancelPermissionPrompts()
      self.hidePeekPresentation(immediately: true)
      self.loadingStrips.hide()
      self.documentErrorPanels.hide()
      self.loadingDocumentIDs.removeAll()
      self.observedDocumentBounds.removeAll()
      self.cancelSelectionFocus()
      self.actions.documentErrors.removeAll()
      self.actions.nativePageVisible = false
      self.visiblePageFrames.removeAll()
      self.sidePanelPageIDs.removeAll()
      self.peekFrames.removeAll()
      self.peekClosingSnapshots.removeAll()
      self.extensions.close()
      self.actions.palette = false; self.actions.library = nil; self.actions.themeEditor = false
      self.retireServicesPresentation()
      self.finishWindowCloseWaiters(accepted: true)
      self.application.didCloseWindow(self)
    }
    windowContext.onCloseCancelled = { [weak self] in
      self?.application.popupAdoptions.resumeAvailable()
      self?.finishWindowCloseWaiters(accepted: false)
      self?.scheduleLayout()
      self?.application.resumeApplicationIntents()
      if let self, let page = self.application.pageRetirements.blockedPage(ownerID: self.windowContext.id) {
        // Let the engine finish cancelling this exact window/Quit attempt.
        DispatchQueue.main.async { [weak self, weak page] in
          guard let self, let page else { return }
          self.presentRetirementRecovery(page)
        }
      }
      if let self, let message = self.deferredWindowError {
        self.deferredWindowError = nil; self.showError(message)
      }
    }
    windowContext.beforeClosingDocuments = { [weak self] in
      guard let self else { return true }
      self.peekOpening.cancel()
      self.application.peekLinks.refresh()
      guard self.deletingProfileID == nil else {
        self.showError("Wait for the current profile operation to finish before closing the browser.")
        return false
      }
      self.collectionPanelTask?.cancel()
      if let window = self.window { NativeWindowSheet.cancel(for: window) }
      self.actions.cancelWindowInteractions()
      if let window = self.window { NativeResizeHandle.cancel(in: window) }
      for task in self.pageCreations.values { task.cancel() }
      self.cancelPermissionPrompts()
      await self.application.popupAdoptions.prepareForNativeClose(ownerID: self.windowContext.id)
      for task in self.dormantNavigations.values { task.cancel() }
      for task in Array(self.discardOperations.values) { _ = try? await task.value }
      for task in Array(self.dormantNavigations.values) { _ = try? await task.value }
      guard self.retirementAllowsWindowClose() else { return false }
      guard await self.prepareNavigationForClose() else { return false }
      self.store.save()
      do { try self.store.flush(); return true }
      catch { self.showError("Your session could not be saved: \(error.localizedDescription)"); return false }
    }
    store.$state.dropFirst().sink { [weak self] next in
      guard let self else { return }
      let previous = self.store.state
      if self.focusSelection(in: next) != self.focusSelection(in: previous) {
        // Reserve before presentation can restore a different native key pane.
        // Layout may coalesce transitions, but cannot replace this selection.
        self.reserveSelectionFocus(self.focusSelection(in: next))
      }
      if next.activeTabID != previous.activeTabID || next.activeSpaceID != previous.activeSpaceID
        || next.activeTab?.peek?.isPresented != previous.activeTab?.peek?.isPresented {
        self.peekOpening.cancel()
      }
      self.scheduleLayout()
    }.store(in: &observations)
    actions.$palette.dropFirst().sink { [weak self] presented in
      guard let self else { return }
      if presented {
        self.abandonSelectionFocus(reason: "palette.presented")
        self.retiringPaletteEditor = nil
        self.retiringPaletteWindow = nil
      } else if self.actions.palette, let key = NSApp.keyWindow,
        let editor = key.firstResponder as? NSTextView,
        self.ownsDocumentFocusWindow(key)
          || (key.identifier == NSUserInterfaceItemIdentifier("ZacroBrowserControls") && key.parent === self.window) {
        // @Published delivers before the closing palette removes its field
        // editor. Only this exact editor gets a short retirement grace period.
        self.retiringPaletteEditor = editor
        self.retiringPaletteWindow = key
        self.retiringPaletteDeadline = ProcessInfo.processInfo.systemUptime + 0.25
      }
      self.scheduleLayout()
    }.store(
      in: &observations)
    actions.$library.dropFirst().sink { [weak self] section in
      guard let self else { return }
      if section != nil { self.abandonSelectionFocus(reason: "library.presented"); self.window?.makeKeyAndOrderFront(nil) }
      self.scheduleLayout()
    }.store(in: &observations)
    for publisher in [actions.$themeEditor.eraseToAnyPublisher(), actions.$findVisible.eraseToAnyPublisher(),
      actions.$recordingShortcut.eraseToAnyPublisher()] {
      publisher.dropFirst().sink { [weak self] shown in
        if shown { self?.abandonSelectionFocus(reason: "interface.presented") }
      }.store(in: &observations)
    }
    for name in [NSApplication.didResignActiveNotification, NSWindow.willBeginSheetNotification,
      NSText.didBeginEditingNotification, NSControl.textDidBeginEditingNotification] {
      NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
        guard let self, self.selectionFocusIntent.phase == .pending else { return }
        self.abandonSelectionFocus(reason: "notification." + name.rawValue)
      }.store(in: &observations)
    }
    NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] event in
      self?.schedulePermissionPresentation()
      guard let self, self.selectionFocusIntent.phase == .pending,
        !self.ownsDocumentFocusWindow(event.object as? NSWindow) else { return }
      self.abandonSelectionFocus(reason: "foreign-key.\((event.object as? NSWindow)?.windowNumber ?? -1)")
    }.store(in: &observations)
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didEndSheetNotification,
      NSWindow.didDeminiaturizeNotification] {
      NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
        self?.schedulePermissionPresentation()
      }.store(in: &observations)
    }
    installServices()
    services.start()
    refreshDefaultBrowser()
    refreshCommands()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged,
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
      .otherMouseDragged, .scrollWheel]) { [weak self] event in
      guard let self else { return event }
      // This runs before the event's selection/navigation action. That action
      // may create a new intent; an older asynchronous completion may not.
      if event.type != .flagsChanged {
        self.abandonSelectionFocus(reason: "input.\(event.type.rawValue)")
        self.selectSplitPaneForInteraction(event)
      }
      guard event.type == .keyDown || event.type == .flagsChanged else { return event }
      return self.handleKey(event) ? nil : event
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
    guard let host,
      store.state.activeTab != nil || engine.parkedExtensionPanel(ownerWindowID: windowContext.id, profileID: store.activeProfileID) != nil,
      !actions.palette,
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
      return actions.documentErrors["peek:" + id] == nil && frame.contains(top)
    }
    if let split = visibleSplit {
      let x = contentFrame.minX + (contentFrame.width - 6) * split.ratio
      if CGRect(x: x - 4, y: contentFrame.minY, width: 14, height: contentFrame.height).contains(
        top)
      {
        return false
      }
    }
    for (id, frame) in documentFrames() where actions.documentErrors[id] != nil && frame.contains(top) { return false }
    return contentFrame.contains(top)
  }
  private func documentFrames() -> [String: CGRect] {
    if let split = visibleSplit {
      let width = (contentFrame.width - 6) * split.ratio
      return [split.leftTabID: CGRect(x: contentFrame.minX, y: contentFrame.minY, width: width, height: contentFrame.height),
        split.rightTabID: CGRect(x: contentFrame.minX + width + 6, y: contentFrame.minY,
          width: contentFrame.width - width - 6, height: contentFrame.height)]
    }
    return store.state.activeTabID.map { [$0: contentFrame] } ?? [:]
  }
  private func refreshDocumentPresentation(_ page: ChromiumPage) {
    let message = page.documentError?.message
    var changed = actions.documentErrors[page.id] != message
    if changed { actions.documentErrors[page.id] = message }
    if page.isLoading != loadingDocumentIDs.contains(page.id) {
      if page.isLoading { loadingDocumentIDs.insert(page.id) } else { loadingDocumentIDs.remove(page.id) }
      changed = true
    }
    if observedDocumentBounds[page.id] != page.documentBounds {
      observedDocumentBounds[page.id] = page.documentBounds
      changed = true
    }
    if changed { scheduleLayout() }
  }
  private func showsNativeDocument(_ page: ChromiumPage) -> Bool {
    if page.documentError == nil { return true }
    return page.isSidePanelVisible && page.documentBounds.map { $0.width > 0 && $0.height > 0 } == true
  }
  func peekLinkSnapshot(_ page: ChromiumPage) -> NativePeekLinkSnapshot? {
    guard windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      engine.pages[page.id] === page, page.ownerWindowID == windowContext.id,
      deletingProfileID != page.profileID,
      let tab = store.document(id: page.id), !tab.isClosed,
      store.profileID(for: tab) == page.profileID,
      let source = page.url, source.absoluteString == tab.url,
      BrowserAddress.webURL(source.absoluteString) != nil else { return nil }
    let underneathPeek = hasPresentedPeek && selectedDocumentID != page.id
    let visible = store.activeProfileID == page.profileID && page.documentError == nil
      && visiblePageFrames[page.id] != nil && page.nativeWindow?.isVisible == true
      && !underneathPeek && !actions.palette
    let pinned = !page.id.hasPrefix("peek:") && tab.isPinned ? (tab.savedURL ?? tab.url) : nil
    return NativePeekLinkSnapshot(pageID: page.id, profileID: page.profileID,
      ownerWindowID: windowContext.id, sourceURL: source.absoluteString,
      pinnedURL: pinned, visible: visible)
  }
  private func cancelSelectionFocus() {
    traceSelectionFocus("cancel.before-clear")
    selectionFocusTask?.cancel(); selectionFocusTask = nil
    reservedSelectionFocusToken = nil
    selectionFocusIntent.clear()
  }
  private func reserveSelectionFocus(_ selection: DocumentFocusIntent.Selection?) {
    cancelSelectionFocus()
    guard let selection else { return }
    reservedSelectionFocusToken = selectionFocusIntent.begin(selection)
    traceSelectionFocus("selection.reserved", requestedID: selection.documentID)
  }
  private var hasPendingSelectionFocus: Bool {
    selectionFocusIntent.phase == .pending && selectionFocusIntent.selection == focusSelection
  }
  private var focusSelection: DocumentFocusIntent.Selection? {
    focusSelection(in: store.state)
  }
  private func focusSelection(in state: BrowserState) -> DocumentFocusIntent.Selection? {
    guard let tab = state.activeTab else { return nil }
    let documentID = tab.peek != nil && tab.peek?.isPresented != false ? "peek:" + tab.id : tab.id
    return .init(documentID: documentID, profileID: state.activeSpace?.profileID ?? "default")
  }
  private func abandonSelectionFocus(reason: String = "interaction") {
    traceSelectionFocus("abandon.before." + reason)
    selectionFocusTask?.cancel(); selectionFocusTask = nil
    reservedSelectionFocusToken = nil
    selectionFocusIntent.abandon(focusSelection)
    traceSelectionFocus("abandon.after." + reason)
  }
  private func selectSplitPaneForInteraction(_ event: NSEvent) {
    guard [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(event.type),
      permitsSplitPaneInteraction,
      event.type != .keyDown || !(NSApp.keyWindow?.firstResponder is NSTextView),
      store.state.activeTab?.peek == nil || store.state.activeTab?.peek?.isPresented == false,
      let split = visibleSplit, let targetWindow = event.window else { return }
    let targets = split.tabIDs.compactMap { engine.pages[$0] }.filter { page in
      owns(page, tabID: page.id) && page.documentError == nil
        && page.ownerWindowID == windowContext.id && store.tab(page.id)?.windowID == windowContext.id
        && page.profileID == store.activeProfileID
        && visiblePageFrames[page.id] != nil && page.nativeWindow === targetWindow
        && targetWindow.isVisible
    }
    guard targets.count == 1, let target = targets.first,
      store.state.activeTabID != target.id else { return }
    // An automatic restoration may already have made this pane key. A real
    // input event still selects its exact document without another focus edge.
    store.selectTab(id: target.id)
  }
  private var permitsSplitPaneInteraction: Bool {
    // Find stays open while the user interacts with a document. Automatic
    // focus uses the stricter environment below and never leaves its editor.
    NSApp.isActive && windowContext.isOpen && !windowContext.isClosing && !engine.isTerminating
      && deletingProfileID == nil && !actions.palette && !actions.themeEditor && actions.library == nil
      && !actions.recordingShortcut && window?.attachedSheet == nil && NSApp.modalWindow == nil
  }
  func beginSelectionFocusDiagnostics(tabIDs: Set<String>) {
    guard selectionFocusDiagnosticsAvailable, tabIDs.allSatisfy({ id in
      guard let tab = store.document(id: id), tab.windowID == windowContext.id,
        let url = URL(string: tab.url), url.host == "127.0.0.1" else { return false }
      return url.path == "/focus-left" || url.path == "/focus-right"
    }) else { return }
    selectionFocusDiagnosticIDs = tabIDs
    selectionFocusDiagnostics.removeAll(keepingCapacity: true)
    selectionFocusDiagnostics.reserveCapacity(64)
    selectionFocusDiagnosticNext = 0
  }

  /// Flush only after the unchanged acceptance predicate has succeeded/failed.
  /// During focus transitions the ring stores values without JSON or stderr.
  func flushSelectionFocusDiagnostics(outcome: String) {
    guard selectionFocusDiagnosticsAvailable, !selectionFocusDiagnosticIDs.isEmpty else { return }
    let ordered = Array(selectionFocusDiagnostics[selectionFocusDiagnosticNext...])
      + Array(selectionFocusDiagnostics[..<selectionFocusDiagnosticNext])
    let rows: [[String: Any]] = ordered.map { value in
      ["time": value.time, "event": value.event, "phase": String(describing: value.phase),
        "requestedID": value.requestedID ?? "nil", "intentID": value.intentID ?? "nil",
        "intentProfileID": value.intentProfileID ?? "nil", "selectedID": value.selectedID ?? "nil",
        "activeTabID": value.activeTabID ?? "nil", "profileID": value.profileID,
        "ownerNativeID": value.ownerNativeID, "ownerOpen": value.ownerOpen,
        "ownerClosing": value.ownerClosing, "terminating": value.terminating,
        "deletingProfileID": value.deletingProfileID ?? "nil", "appActive": value.appActive,
        "mouseButtons": value.mouseButtons, "environmentAllowed": value.environmentAllowed,
        "transitionAllowed": value.transitionAllowed, "focusAllowed": value.focusAllowed,
        "keyWindow": value.keyWindow, "keyOwned": value.keyOwned,
        "keyResponder": value.responderType.map { String(reflecting: $0) } ?? "nil",
        "ownerWindow": value.ownerWindow, "ownerSheet": value.ownerSheet,
        "modalWindow": value.modalWindow, "pageNativeID": value.nativeID,
        "pageWindow": value.pageWindow, "pageVisible": value.pageVisible,
        "requestedNativeID": value.requestedNativeID, "requestedWindow": value.requestedWindow,
        "requestedKey": value.requestedKey]
    }
    if let data = try? JSONSerialization.data(withJSONObject: [
      "ownerID": windowContext.id, "outcome": outcome, "events": rows,
    ], options: [.sortedKeys]) {
      fputs("Native hosted focus snapshot ring: \(String(decoding: data, as: UTF8.self))\n", stderr)
    }
    selectionFocusDiagnosticIDs.removeAll()
    selectionFocusDiagnostics.removeAll(keepingCapacity: true)
    selectionFocusDiagnosticNext = 0
  }

  /// A bounded read-only ring for explicitly registered loopback fixture IDs.
  private func traceSelectionFocus(_ event: String, requestedID: String? = nil) {
    guard selectionFocusDiagnosticsAvailable, !selectionFocusDiagnosticIDs.isEmpty else { return }
    let selectedID = selectedDocumentID
    guard selectedID.map(selectionFocusDiagnosticIDs.contains) == true
      || selectionFocusIntent.selection.map({ selectionFocusDiagnosticIDs.contains($0.documentID) }) == true
      || requestedID.map(selectionFocusDiagnosticIDs.contains) == true else { return }
    let key = NSApp.keyWindow
    let page = selectedID.flatMap { engine.pages[$0] }
    let requestedPage = requestedID.flatMap { engine.pages[$0] }
    let value = SelectionFocusDiagnostic(time: ProcessInfo.processInfo.systemUptime,
      event: event, phase: selectionFocusIntent.phase, requestedID: requestedID,
      intentID: selectionFocusIntent.selection?.documentID, intentProfileID: selectionFocusIntent.selection?.profileID,
      selectedID: selectedID, activeTabID: store.state.activeTabID, profileID: store.activeProfileID,
      ownerNativeID: windowContext.nativeID, ownerOpen: windowContext.isOpen,
      ownerClosing: windowContext.isClosing, terminating: engine.isTerminating,
      deletingProfileID: deletingProfileID, appActive: NSApp.isActive,
      mouseButtons: Int(NSEvent.pressedMouseButtons), environmentAllowed: permitsDocumentFocusEnvironment,
      transitionAllowed: permitsSelectionFocusTransition, focusAllowed: permitsDocumentFocus,
      keyWindow: key?.windowNumber ?? -1, keyOwned: ownsDocumentFocusWindow(key),
      responderType: (key?.firstResponder).map { type(of: $0) },
      ownerWindow: window?.windowNumber ?? -1, ownerSheet: window?.attachedSheet?.windowNumber ?? -1,
      modalWindow: NSApp.modalWindow?.windowNumber ?? -1, nativeID: page?.browser?.id ?? -1,
      pageWindow: page?.nativeWindow?.windowNumber ?? -1, pageVisible: page?.nativeWindow?.isVisible == true,
      requestedNativeID: requestedPage?.browser?.id ?? -1,
      requestedWindow: requestedPage?.nativeWindow?.windowNumber ?? -1,
      requestedKey: requestedPage?.nativeWindow?.isKeyWindow == true)
    if event == "begin.same-selection-skipped", !selectionFocusDiagnostics.isEmpty {
      let last = selectionFocusDiagnostics[selectionFocusDiagnostics.count < 64
        ? selectionFocusDiagnostics.count - 1 : (selectionFocusDiagnosticNext + 63) % 64]
      if last.event == value.event, last.phase == value.phase,
        last.intentID == value.intentID, last.selectedID == value.selectedID,
        last.keyWindow == value.keyWindow, last.mouseButtons == value.mouseButtons,
        last.deletingProfileID == value.deletingProfileID, last.focusAllowed == value.focusAllowed,
        last.transitionAllowed == value.transitionAllowed, last.nativeID == value.nativeID,
        last.pageWindow == value.pageWindow, last.pageVisible == value.pageVisible { return }
    }
    if selectionFocusDiagnostics.count < 64 { selectionFocusDiagnostics.append(value) }
    else {
      selectionFocusDiagnostics[selectionFocusDiagnosticNext] = value
      selectionFocusDiagnosticNext = (selectionFocusDiagnosticNext + 1) % 64
    }
  }
  private func ownsDocumentFocusWindow(_ candidate: NSWindow?) -> Bool {
    guard let candidate else { return false }
    return candidate === window || windowPages.values.contains { $0.nativeWindow === candidate }
  }
  private func ownsSidebarToggleFocus(_ candidate: NSWindow?) -> Bool {
    guard NSApp.isActive, application.focusedCoordinator === self,
      windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      deletingProfileID == nil, let window, window.isVisible, !window.isMiniaturized else { return false }
    guard let candidate else { return window.isMainWindow }
    if ownsDocumentFocusWindow(candidate) || documentErrorPanels.owns(candidate)
      || engine.extensionPopupOwner(candidate) === windowContext { return true }
    var owner: NSWindow? = candidate
    while let current = owner {
      if current === window { return true }
      owner = current.sheetParent ?? current.parent
    }
    return false
  }
  private var permitsDocumentFocusEnvironment: Bool {
    guard NSApp.isActive, windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      deletingProfileID == nil, !actions.palette, !actions.themeEditor, actions.library == nil,
      !actions.findVisible, !actions.recordingShortcut, window?.attachedSheet == nil,
      NSApp.modalWindow == nil else { return false }
    return true
  }
  private var permitsDocumentFocusContext: Bool {
    permitsDocumentFocusEnvironment && ownsDocumentFocusWindow(NSApp.keyWindow)
  }
  private var permitsSelectionFocusTransition: Bool {
    guard permitsDocumentFocusEnvironment else { return false }
    if ownsDocumentFocusWindow(NSApp.keyWindow) || NSApp.keyWindow == nil { return true }
    return NSApp.keyWindow === retiringPaletteWindow
      && ProcessInfo.processInfo.systemUptime < retiringPaletteDeadline
  }
  private var permitsDocumentFocus: Bool {
    permitsDocumentFocusContext && NSEvent.pressedMouseButtons == 0
      && !(NSApp.keyWindow?.firstResponder is NSTextView)
  }
  /// Visibility is independent of activation. Only the still-selected document
  /// of the focused browser may take focus after asynchronous materialization.
  private func focusSelectedDocument(force: Bool = false) {
    guard let selection = focusSelection else { cancelSelectionFocus(); return }
    let token: DocumentFocusIntent.Token
    if !force, let reserved = reservedSelectionFocusToken,
      reserved.selection == selection, selectionFocusIntent.isPending(reserved) {
      reservedSelectionFocusToken = nil
      token = reserved
      traceSelectionFocus("begin.reserved")
    } else {
      reservedSelectionFocusToken = nil
      guard let next = selectionFocusIntent.begin(selection, explicit: force) else {
        traceSelectionFocus("begin.same-selection-skipped"); return
      }
      token = next
      traceSelectionFocus(force ? "begin.explicit" : "begin.selection")
    }
    selectionFocusTask?.cancel()
    let id = selection.documentID, profileID = selection.profileID
    guard let tab = store.document(id: id), !tab.isClosed, tab.url != "about:blank",
      permitsSelectionFocusTransition else { abandonSelectionFocus(reason: "admission.denied"); return }
    let transitionDeadline = ProcessInfo.processInfo.systemUptime + 0.25
    selectionFocusTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.selectionFocusIntent.isPending(token) { self.abandonSelectionFocus(reason: "task.finished-pending") }
      }
      do {
        self.traceSelectionFocus("task.entered", requestedID: id)
        while !self.permitsDocumentFocus {
          try Task.checkCancellation()
          let now = ProcessInfo.processInfo.systemUptime
          guard self.selectionFocusIntent.isPending(token), self.focusSelection == selection,
            self.permitsSelectionFocusTransition,
            now < transitionDeadline else { self.traceSelectionFocus("task.transition-rejected", requestedID: id); return }
          if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            guard editor === self.retiringPaletteEditor, now < self.retiringPaletteDeadline else {
              self.traceSelectionFocus("task.editor-rejected", requestedID: id); return
            }
          }
          try await Task.sleep(for: .milliseconds(16))
        }
        try Task.checkCancellation()
        guard self.selectionFocusIntent.isPending(token), self.focusSelection == selection else {
          self.traceSelectionFocus("task.selection-changed", requestedID: id); return
        }
        self.traceSelectionFocus("task.materializing", requestedID: id)
        let page = try await self.ensurePageReady(tab)
        self.traceSelectionFocus("task.materialized", requestedID: id)
        try await self.navigation.waitForRestore(page)
        self.traceSelectionFocus("task.restored", requestedID: id)
        try Task.checkCancellation()
        guard self.selectionFocusIntent.isPending(token), self.selectedDocumentID == id,
          self.store.activeProfileID == profileID, self.permitsDocumentFocus,
          self.engine.pages[id] === page, page.documentError == nil else {
          self.traceSelectionFocus("task.after-restore-rejected", requestedID: id); return
        }
        self.layoutPages()
        guard self.selectionFocusIntent.isPending(token), self.selectedDocumentID == id,
          page.nativeWindow?.isVisible == true,
          self.permitsDocumentFocus else { self.traceSelectionFocus("task.after-layout-rejected", requestedID: id); return }
        self.traceSelectionFocus("task.focusing", requestedID: id)
        page.focus()
        if self.selectionFocusIntent.complete(token) { self.selectionFocusTask = nil }
        self.traceSelectionFocus("task.completed", requestedID: id)
      } catch {
        self.traceSelectionFocus("task.error." + error.localizedDescription, requestedID: id)
        /* The page's own error/retry presentation owns failure reporting. */
      }
    }
  }
  func retryDocument(_ id: String) {
    guard let tab = store.document(id: id), !tab.isClosed, let page = engine.pages[id],
      page.ownerWindowID == windowContext.id else { return }
    navigation.cancelRestore(page)
    page.reload()
  }
  func editDocumentAddress(_ id: String) {
    guard let tab = store.document(id: id), !tab.isClosed else { return }
    do { try store.selectDocumentDurably(id: id); actions.openPalette(address: tab.url) }
    catch { showError(error.localizedDescription) }
  }
  func scheduleLayout() {
    guard !engine.isTerminating, !layoutQueued else { return }
    layoutQueued = true
    // Native window border drags run a nested event-tracking loop. Keep the
    // coalesced pass available there so child document windows resize live.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        self?.layoutQueued = false
        self?.layoutPages()
      }
    }
  }
  private func page(for tab: BrowserTab) -> ChromiumPage? {
    let isPeek = tab.id.hasPrefix("peek:")
    let sourceID = isPeek ? String(tab.id.dropFirst(5)) : tab.id
    if isPeek, engine.pages[tab.id] == nil, peekOpening.isReplacing(sourceTabID: sourceID) { return nil }
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
    if !existed && pagePreparations[tab.id] == nil {
      if pageCreationFailures[tab.id] != tab.url { beginPageCreation(tab) }
      return nil
    }
    let reservation = !existed ? pagePreparations.removeValue(forKey: tab.id)?.reservation : nil
    let wasReserved = reservedPages.remove(tab.id) != nil
    let page = engine.page(
      id: tab.id, profileID: profileID, isPrivate: profile.isPrivate,
      url: existed ? (URL(string: tab.url) ?? URL(string: "about:blank")!) : nil,
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
        pendingHistory[tab.id] = PendingHistory(source: page.url?.absoluteString ?? modelURLs[tab.id], destination: tab.url)
        modelURLs[tab.id] = tab.url
        navigation.cancelRestore(page)
        page.load(url)
      }
    }
    wire(page, tabID: sourceID, peek: isPeek)
    let wasDormant = dormantPages.remove(tab.id) != nil
    if !existed || wasReserved || wasDormant {
      navigation.restore(page, tabID: sourceID, peek: isPeek, address: tab.url, dormant: wasDormant)
    }
    if !existed { inspectRuntimeCapabilities(page) }
    if !isPeek { updateIcon(page, tab: tab) }
    return page
  }
  /// A tab reserves its Chrome identity before creating a WebContents. Private
  /// identities serve only Chromium's bundled component, never extension sync.
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
  func requestCloseTab(_ id: String, forPeekReplacement: Bool = false) async -> Bool {
    guard store.document(id: id) != nil else { return false }
    let sourceID = id.hasPrefix("peek:") ? String(id.dropFirst(5)) : id
    if !forPeekReplacement, id.hasPrefix("peek:") || peekOpening.isReplacing(sourceTabID: sourceID) {
      peekOpening.cancel(discardDestination: true)
    }
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
    pendingHistory[tab.id] = PendingHistory(source: page.url?.absoluteString, destination: address)
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
    guard windowContext.isOpen else { return true }
    guard !engine.isTerminating else { return false }
    return await withCheckedContinuation { continuation in
      let pending = !windowCloseWaiters.isEmpty
      windowCloseWaiters.append(continuation)
      // AppKit can refuse performClose while a sheet disables the titlebar's
      // close button. The context owns cancellation and Chromium beforeunload.
      if !pending { windowContext.close() }
    }
  }
  private func finishWindowCloseWaiters(accepted: Bool) {
    let waiters = windowCloseWaiters; windowCloseWaiters.removeAll()
    for continuation in waiters { continuation.resume(returning: accepted) }
  }
  private func prepareNavigationForClose(page: ChromiumPage? = nil,
    tabID: String? = nil, peek: Bool = false) async -> Bool {
    guard let owner = window else { return false }
    while !Task.isCancelled, windowContext.isOpen, window === owner {
      let issues: [NativeNavigationCoordinator.CaptureIssue]
      if let page, let tabID {
        guard engine.pages[page.id] === page, page.ownerWindowID == windowContext.id else { return false }
        issues = await navigation.captureIssueForClose(page, tabID: tabID, peek: peek).map { [$0] } ?? []
      } else {
        issues = await navigation.captureIssuesForClose(windowID: windowContext.id)
      }
      guard !Task.isCancelled, windowContext.isOpen, window === owner else { return false }
      if issues.isEmpty { return true }
      guard issues.allSatisfy({ engine.pages[$0.pageID]?.ownerWindowID == windowContext.id }),
        await NativeNavigationCloseReview.present(pageCount: issues.count, owner: owner),
        !Task.isCancelled, windowContext.isOpen, window === owner,
        issues.allSatisfy({ engine.pages[$0.pageID]?.ownerWindowID == windowContext.id }) else { return false }
      do {
        // If a page changed while its sheet was open, capture that document
        // again instead of applying consent to a different saved snapshot.
        if try await navigation.continueWithoutPageState(issues) { return true }
      } catch {
        showError("Your session could not be saved: \(error.localizedDescription)")
        return false
      }
    }
    return false
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
      return await self.prepareNavigationForClose(page: page, tabID: tabID, peek: peek)
    }
    page.onChange = { [weak self, weak page] in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      defer {
        self.application.peekLinks.refresh()
        self.application.pageRetirements.remember(page)
      }
      self.refreshDocumentPresentation(page)
      guard !self.navigation.isRestoring(page),
        !self.reservedPages.contains(page.id), !self.discardingPages.contains(page.id), !self.dormantPages.contains(page.id) else { return }
      defer { self.extensionBrowser.reconcile() }
      if !peek, page.isLoading != self.actions.loadingTabIDs.contains(tabID) {
        if page.isLoading { self.actions.loadingTabIDs.insert(tabID) }
        else { self.actions.loadingTabIDs.remove(tabID) }
      }
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
            self.store.navigate(tabID: tabID, address: value, title: page.title, recordHistory: false)
          }
        } else if tab.url != value {
          self.modelURLs[tabID] = value
          self.store.navigate(tabID: tabID, address: value, title: page.title, recordHistory: false)
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
      self.application.popupAdoptions.begin(popup: popup, source: page, owner: self,
        spaceID: source.spaceID, foreground: foreground)
    }
    page.onPeek = { [weak self, weak page] url, invocationPoint in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      // A link in either visible split member belongs to that member even if
      // native focus has not yet emitted its asynchronous selection callback.
      if !peek, self.store.state.activeTabID != tabID,
        self.visibleSplit?.tabIDs.contains(tabID) == true {
        self.store.selectTab(id: tabID)
      }
      var origin: CGRect?
      if let window = self.window, let content = window.contentView {
        var screenPoint = NSEvent.mouseLocation
        if let invocationPoint, let view = page.browser?.nativeView, let sourceWindow = view.window,
          let point = ChromiumPageContextMenuPolicy.viewportPoint(invocationPoint, documentBounds: page.documentBounds) {
          let local = NSPoint(x: view.bounds.minX + point.x,
            y: view.isFlipped ? view.bounds.minY + point.y : view.bounds.maxY - point.y)
          screenPoint = sourceWindow.convertPoint(toScreen: view.convert(local, to: nil))
        }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let point = content.convert(inWindow, from: nil)
        let y = content.isFlipped ? point.y : content.bounds.height - point.y
        origin = CGRect(
          x: min(max(self.contentFrame.minX, point.x - 20), self.contentFrame.maxX - 40),
          y: min(max(self.contentFrame.minY, y - 15), self.contentFrame.maxY - 30), width: 40, height: 30)
      }
      Task { [weak self, weak page] in
        guard let self, let page else { return }
        do { _ = try await self.requestOpenPeek(sourceTabID: tabID, sourcePage: page, url: url, origin: origin) }
        catch is CancellationError { }
        catch { self.showError(error.localizedDescription) }
      }
    }
    page.onDownloadDecision = { [weak self, weak page] download, suggested in
      guard let self, let page, self.owns(page, tabID: tabID), let tab = self.store.document(id: page.id) else { return .deny }
      return self.downloads.decide(download, suggested: suggested, source: tab, profile: page.profileID)
    }
    page.onPermissionRequest = { [weak self, weak page] request, callback in
      guard let self, let page, self.owns(page, tabID: tabID) else { callback.resolve(.deny); return true }
      return self.requestPermission(request, page: page, callback: callback)
    }
    page.onPermission = { [weak self, weak page] request in
      guard let self, let page, self.owns(page, tabID: tabID) else { return .deny }
      return self.immediatePermissionDecision(request, page: page) ?? .dismiss
    }
    page.onPermissionDismissed = { [weak self] id in self?.cancelPermissionPrompt(id) }
    page.onFindResult = { [weak self, weak page] count, ordinal, _ in
      guard let self, let page, self.owns(page, tabID: tabID), self.activePage === page else { return }
      if self.actions.findMatchCount != count { self.actions.findMatchCount = count }
      if self.actions.findActiveMatch != ordinal { self.actions.findActiveMatch = ordinal }
    }
    page.onFocused = { [weak self, weak page] in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      self.traceSelectionFocus("native-focus-callback", requestedID: tabID)
      // Showing/reparenting native split windows can emit focus callbacks. A
      // document beneath the modal Peek cannot take logical selection from it.
      if !peek, let preview = self.store.state.activeTab?.peek, preview.isPresented != false { return }
      if !peek, self.store.state.activeTabID != tabID,
        self.visibleSplit?.tabIDs.contains(tabID) == true,
        !self.hasPendingSelectionFocus,
        let nativeWindow = page.nativeWindow, nativeWindow.isKeyWindow,
        NSApp.keyWindow === nativeWindow {
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
      self.application.cancelProfileOperation(forPage: page.id)
      self.scheduleLayout()
    }
    let muted = store.document(id: page.id)?.isMuted ?? false
    if page.browser?.isAudioMuted != muted { page.browser?.isAudioMuted = muted }
    page.onClosed = { [weak self, weak page] in
      guard let self, let page else { return }
      self.application.peekLinks.forget(page)
      self.application.webDialogs.forget(page)
      self.application.historyVisits.forget(page)
      self.application.pageRetirements.forget(page)
      defer { self.finishCloseWaiters(page.id, accepted: true) }
      self.navigation.forget(page.id)
      self.actions.documentErrors.removeValue(forKey: page.id)
      self.loadingDocumentIDs.remove(page.id)
      self.observedDocumentBounds.removeValue(forKey: page.id)
      if !peek || self.engine.pages[tabID]?.isAudible != true { self.actions.audibleTabIDs.remove(tabID) }
      self.reservedPages.remove(page.id)
      self.dormantPages.remove(page.id); self.discardingPages.remove(page.id); self.mediaPermissionPages.remove(page.id)
      self.visiblePageFrames.removeValue(forKey: page.id)
      self.sidePanelPageIDs.remove(page.id)
      self.modelURLs.removeValue(forKey: page.id)
      self.pendingHistory.removeValue(forKey: page.id)
      self.liveNavigations.removeValue(forKey: page.id)?.task.cancel()
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
        if self.store.tab(tabID)?.peek != nil,
          !self.peekOpening.retainsDestination(sourceTabID: tabID, page: page) {
          self.store.closePeek(tabID: tabID)
        }
      } else if let tab = self.store.tab(tabID), !tab.isClosed {
        let wasActive = self.store.state.activeTabID == tabID
        let opener = page.openerID.flatMap { self.store.document(id: $0) }
        self.store.closeTab(id: tabID)
        if wasActive, let opener, !opener.isClosed, self.store.profileID(for: opener) == page.profileID {
          do { try self.store.selectDocumentDurably(id: opener.id) }
          catch { self.showError(error.localizedDescription) }
        }
        if wasActive {
          self.focusSelectedDocument(force: true)
        }
      }
      self.scheduleLayout()
    }
    application.peekLinks.connect(page)
    application.webDialogs.connect(page)
    application.historyVisits.connect(page)
    application.pageRetirements.remember(page)
  }
  private func retirePage(id: String) {
    if id.hasPrefix("peek:") {
      let sourceID = String(id.dropFirst(5))
      if store.tab(sourceID)?.isClosed != false, engine.pages[sourceID] != nil {
        // A queued source transaction restores both records before negotiating
        // the Peek. Never start two overlapping recoveries from one layout.
        retirePage(id: sourceID)
        return
      }
    }
    guard let page = engine.pages[id], page.ownerWindowID == windowContext.id,
      !application.popupAdoptions.isPending(page),
      !application.pageRetirements.isBlocked(page), retiringPageIDs.insert(id).inserted else { return }
    if isInertRetirement(page) {
      closeInertRetirement(page)
      return
    }
    beginRetirementRecovery(page, retry: false)
  }

  /// An already discarded document has a successful capture plus a native
  /// blank commit. Retiring it must not reopen the archive or replace its vault.
  private func isInertRetirement(_ page: ChromiumPage) -> Bool {
    guard engine.pages[page.id] === page, page.ownerWindowID == windowContext.id,
      !page.isLoading, !hasPendingLiveNavigation(page.id),
      discardOperations[page.id] == nil, dormantNavigations[page.id] == nil,
      store.document(id: page.id)?.isClosed != false else { return false }
    if page.creationFailed { return true }
    return (reservedPages.contains(page.id) || dormantPages.contains(page.id))
      && (page.url == nil || page.url?.absoluteString == "about:blank")
  }

  private func beginRetirementRecovery(_ page: ChromiumPage, retry: Bool) {
    let id = page.id, key = ObjectIdentifier(page), token = UUID()
    guard retirementTasks[key] == nil, page.ownerWindowID == windowContext.id else { return }
    retirementTasks[key] = (token, Task { @MainActor [weak self, weak page] in
      guard let self, let page else { return }
      defer {
        if self.retirementTasks[key]?.id == token { self.retirementTasks.removeValue(forKey: key) }
        self.retiringPageIDs.remove(id)
        self.scheduleLayout()
      }
      var recoveryLease: NativePageRetirementCoordinator.Lease?
      do {
        // No async navigation can publish into a recovered identity later.
        // A pending request remains a blocked retained document, never stopped
        // or discarded simply to satisfy a model-first deletion.
        let lease: NativePageRetirementCoordinator.Lease
        if retry { lease = try self.application.pageRetirements.retry(page) }
        else { lease = try self.application.pageRetirements.recover(page) }
        recoveryLease = lease
        guard self.application.pageRetirements.validates(lease, page: page) else { throw CancellationError() }
        self.retiringPageIDs.remove(id)
        let sourceID = id.hasPrefix("peek:") ? String(id.dropFirst(5)) : id
        self.wire(page, tabID: sourceID, peek: id.hasPrefix("peek:"))
        self.modelURLs[id] = self.store.document(id: id)?.url
        // A restored source can include its still-live Peek. Both must use
        // ordinary close hooks before requestCloseTab negotiates them in order.
        if !id.hasPrefix("peek:"), let preview = self.engine.pages["peek:" + id],
          preview.ownerWindowID == self.windowContext.id, self.store.tab(id)?.peek != nil {
          self.wire(preview, tabID: id, peek: true)
          self.modelURLs[preview.id] = self.store.document(id: preview.id)?.url
        }
        let closed = await self.requestCloseTab(lease.closeTargetID)
        self.application.pageRetirements.finished(lease, page: page, closed: closed)
      } catch {
        // Recovery itself retains a typed blocked record. A lifecycle change
        // after recovery is also blocked until an explicit retry validates it.
        if let recoveryLease {
          self.application.pageRetirements.finished(recoveryLease, page: page, closed: false)
        }
        self.application.pageRetirements.block(page, reason: error.localizedDescription)
        self.presentRetirementRecovery(page)
      }
    })
  }

  private func closeInertRetirement(_ page: ChromiumPage) {
    let id = page.id
    page.beforeClose = { [weak self, weak page] in
      guard let self, let page else { return false }
      return self.isInertRetirement(page)
    }
    // Keep normal JS-dialog authority connected until native completion. An
    // unexpected new handler vetoes, and is surfaced rather than force closed.
    page.onClosed = { [weak self, weak page] in
      guard let self, let page else { return }
      self.application.peekLinks.forget(page)
      self.application.webDialogs.forget(page)
      self.application.historyVisits.forget(page)
      self.application.pageRetirements.forget(page)
      self.finishCloseWaiters(id, accepted: true)
      self.navigation.forget(id)
      self.reservedPages.remove(id); self.dormantPages.remove(id); self.discardingPages.remove(id)
      self.retiringPageIDs.remove(id); self.mediaPermissionPages.remove(id)
      self.visiblePageFrames.removeValue(forKey: id)
      self.actions.documentErrors.removeValue(forKey: id)
      self.loadingDocumentIDs.remove(id); self.observedDocumentBounds.removeValue(forKey: id)
      self.sidePanelPageIDs.remove(id); self.modelURLs.removeValue(forKey: id)
      self.pendingHistory.removeValue(forKey: id)
      self.liveNavigations.removeValue(forKey: id)?.task.cancel()
      self.restoredHistoryPages.remove(id)
      self.scheduleLayout()
    }
    page.onCloseCancelled = { [weak self, weak page] in
      guard let self, let page else { return }
      self.finishCloseWaiters(id, accepted: false)
      self.retiringPageIDs.remove(id)
      self.application.pageRetirements.block(page,
        reason: "This previously sleeping document kept its native contents. Keep the window open and retry recovery.")
      self.presentRetirementRecovery(page)
    }
    engine.close(id: id)
  }

  /// Also guards a close that races the layout which would discover an orphan.
  /// Existing Core documents continue through normal native beforeunload.
  private func retirementAllowsWindowClose() -> Bool {
    for page in windowPages.values where !page.id.hasPrefix("extensions:")
      && !page.id.hasPrefix("extension-store:") && !page.id.hasPrefix("maintenance:")
      && !page.id.hasPrefix("panel-parking:") {
      if application.popupAdoptions.isPending(page) { continue }
      if store.document(id: page.id)?.isClosed != false, !isInertRetirement(page) {
        application.pageRetirements.block(page,
          reason: "A live page must be recovered before this window can close. Its unsaved contents remain in memory.")
      }
    }
    return application.pageRetirements.blockedPage(ownerID: windowContext.id) == nil
  }

  /// An exact owned Retry / Keep Window Open sheet. Keep Open suppresses layout
  /// retries; attempting to close this owner offers this recovery action again.
  private func presentRetirementRecovery(_ page: ChromiumPage) {
    let key = ObjectIdentifier(page), id = page.id
    guard retirementReviews[key] == nil, let window,
      windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      page.ownerWindowID == windowContext.id, engine.pages[id] === page else { return }
    let token = UUID()
    retirementReviews[key] = (token, Task { @MainActor [weak self, weak page, weak window] in
      guard let self, let page, let window else { return }
      defer { if self.retirementReviews[key]?.id == token { self.retirementReviews.removeValue(forKey: key) } }
      let alert = NSAlert()
      alert.messageText = "This live page needs recovery"
      alert.informativeText = self.application.pageRetirements.reason(for: page) ?? "The page remains open in memory."
      alert.addButton(withTitle: "Keep Window Open")
      alert.addButton(withTitle: "Retry Recovery")
      alert.window.identifier = NSUserInterfaceItemIdentifier("ZacroRetirementRecovery:" + token.uuidString)
      let response = await NativeWindowSheet.present(alert, for: window)
      guard !Task.isCancelled, response == .alertSecondButtonReturn,
        self.window === window, self.windowContext.isOpen, !self.windowContext.isClosing,
        !self.engine.isTerminating, self.engine.pages[id] === page,
        page.ownerWindowID == self.windowContext.id else { return }
      self.retirementReviews.removeValue(forKey: key)
      self.retiringPageIDs.insert(id)
      self.beginRetirementRecovery(page, retry: true)
    })
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
    let liveRetirementObjects = Set(windowPages.values.map(ObjectIdentifier.init))
    for (key, review) in Array(retirementReviews) where !liveRetirementObjects.contains(key) {
      review.task.cancel()
      if retirementReviews[key]?.id == review.id { retirementReviews.removeValue(forKey: key) }
    }
    application.popupAdoptions.refresh()
    application.pageRetirements.refresh()
    application.webDialogs.refresh()
    for (id, prompt) in permissionPrompts {
      guard let page = engine.pages[prompt.pageID], page.url == prompt.address,
        page.profileID == prompt.profileID, mayRequestPermission(page) else {
        cancelPermissionPrompt(id); continue
      }
    }
    guard !engine.isTerminating, !windowContext.isClosing, windowContext.isOpen else { return }
    defer {
      application.peekLinks.refresh()
      if deletingProfileID == nil { extensionBrowser.reconcile() }
    }
    refreshCommands()
    services.refreshContext()
    refreshAICommands()
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
    let loading = Set(store.state.tabs.compactMap { tab -> String? in
      guard let page = engine.pages[tab.id], page.ownerWindowID == windowContext.id,
        page.isLoading, !dormantPages.contains(tab.id), !reservedPages.contains(tab.id) else { return nil }
      return tab.id
    })
    if actions.loadingTabIDs != loading { actions.loadingTabIDs = loading }
    let errors = Dictionary(uniqueKeysWithValues: windowPages.values.compactMap { page -> (String, String)? in
      guard store.document(id: page.id) != nil, let error = page.documentError else { return nil }
      return (page.id, error.message)
    })
    if actions.documentErrors != errors { actions.documentErrors = errors }
    if let pending = pendingDeletion, pending.0.allSatisfy({ engine.pages[$0] == nil }) {
      pendingDeletion = nil
      profileDeletionPageIDs.subtract(pending.0)
      pending.1()
    }
    if store.state.activeTab?.peek == nil || store.state.activeTab?.peek?.isPresented == false { hidePeekPresentation() }
    if contentFrame.width <= 0, let bounds = window?.contentView?.bounds {
      let gutter = isPopup ? 0 : store.state.settings.pageGutter
      let top = actions.findVisible ? 40 : gutter
      let sidebar = !isPopup && store.state.settings.sidebarVisible ? store.state.settings.sidebarWidth : 0
      contentFrame = CGRect(
        x: sidebar + gutter, y: top, width: max(1, bounds.width - sidebar - 2 * gutter),
        height: max(1, bounds.height - top - gutter))
    }
    guard contentFrame.width > 0 else { return }
    if actions.contentSplitRatio != visibleSplit?.ratio { actions.contentSplitRatio = visibleSplit?.ratio }
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
    if desired.isEmpty, deletingProfileID != store.activeProfileID,
      let parking = engine.parkedExtensionPanel(ownerWindowID: windowContext.id, profileID: store.activeProfileID) {
      desired[parking.id] = (parking, contentFrame)
    }
    // Persistent tabs keep their native document and layer attached. Only
    // actual visibility/frame changes reach Chromium, avoiding hide/show flash.
    for entry in desired.values { entry.0.setCornerRadius(isPopup ? 0 : store.state.settings.pageRadius) }
    let visible = desired.filter { showsNativeDocument($0.value.0) }
    for (id, _) in visiblePageFrames where visible[id] == nil {
      engine.pages[id]?.hide()
      if id.hasPrefix("peek:"), desired[id] == nil { engine.pages[id]?.setPresentationParent(nil) }
    }
    var presentedFrames: [String: CGRect] = [:]
    for (id, entry) in visible {
      if id.hasPrefix("peek:"), peekPanel.isAnimating {
        // Animation owns this frame. A desired target is not evidence that
        // an error-hidden native page has actually been presented there.
        if entry.0.nativeWindow?.isVisible == true, let frame = visiblePageFrames[id] {
          presentedFrames[id] = frame
        }
        continue
      }
      if visiblePageFrames[id] != entry.1 || entry.0.nativeWindow?.isVisible != true {
        entry.0.show(frame: entry.1)
      }
      if entry.0.nativeWindow?.isVisible == true { presentedFrames[id] = entry.1 }
    }
    visiblePageFrames = presentedFrames
    if let id = store.state.activeTabID, let preview = desired["peek:" + id]?.0,
      let parent = window
    {
      peekPanel.show(
        parent: parent, contentFrame: contentFrame,
        preview: showsNativeDocument(preview) ? preview.browser?.nativeView?.window : nil,
        close: { [weak self] in self?.closePeek() }, expand: { [weak self] in self?.promotePeek() },
        theme: presentationTheme, radius: store.state.settings.pageRadius,
        motionScale: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : store.state.settings.motionScale,
        previewFrame: desired[preview.id]?.1, originFrame: peekOrigins[id],
        updatePreviewFrame: { [weak self, weak preview] frame in
          guard let self, let preview, self.engine.pages[preview.id] === preview,
            self.store.state.activeTabID == id else { return }
          self.peekFrames[id] = frame
          if self.showsNativeDocument(preview) {
            preview.show(frame: frame)
            self.visiblePageFrames[preview.id] = frame
          }
        }, error: showsNativeDocument(preview) ? nil : preview.documentError?.message,
        url: store.document(id: preview.id)?.url ?? "",
        retry: { [weak self, weak preview] in if let preview { self?.retryDocument(preview.id) } })
      preview.setPresentationParent(peekPanel.presentationWindow)
    }
    var errorPresentations: [String: NativeDocumentErrorPresentation] = [:]
    for (id, entry) in visible {
      guard let error = entry.0.documentError, let bounds = entry.0.documentBounds,
        let window = entry.0.nativeWindow else { continue }
      errorPresentations[id] = NativeDocumentErrorPresentation(window: window, bounds: bounds,
        message: error.message, url: store.document(id: id)?.url ?? "", isPeek: id.hasPrefix("peek:"),
        retry: { [weak self] in self?.retryDocument(id) },
        editAddress: { [weak self] in self?.editDocumentAddress(id) })
    }
    documentErrorPanels.update(errorPresentations, theme: presentationTheme)
    let loadingWindows = Dictionary(uniqueKeysWithValues: visible.compactMap { id, entry -> (String, NSWindow)? in
      guard entry.0.isLoading, entry.0.documentError == nil, let window = entry.0.nativeWindow else { return nil }
      return (id, window)
    })
    loadingStrips.update(windows: loadingWindows, theme: presentationTheme,
      motionScale: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : store.state.settings.motionScale)
    // Recover sources before their live previews. Recovery changes Core, so
    // each later iteration must inspect the current authoritative collection.
    let retiringCandidates = Array(windowPages.keys).sorted {
      if $0.hasPrefix("peek:") != $1.hasPrefix("peek:") { return !$0.hasPrefix("peek:") }
      return $0 < $1
    }
    for id in retiringCandidates {
      if id.hasPrefix("extensions:") || id.hasPrefix("extension-store:") || id.hasPrefix("maintenance:")
        || id.hasPrefix("panel-parking:") { continue }
      if id.hasPrefix("peek:") {
        let source = String(id.dropFirst(5))
        if store.tab(source)?.isClosed != false || store.tab(source)?.peek == nil { retirePage(id: id) }
      } else if store.tab(id)?.isClosed != false {
        retirePage(id: id)
      }
    }
    focusSelectedDocument()
  }
  func navigate(_ address: String) {
    actions.nativePageVisible = false
    guard let url = BrowserAddress.resolve(address, engine: store.state.settings.searchEngine)
    else { return }
    if let tab = store.state.activeTab, tab.peek != nil, tab.peek?.isPresented != false, let preview = engine.pages["peek:" + tab.id] {
      if url.absoluteString == "about:blank" { closePeek(); return }
      navigation.cancelRestore(preview)
      loadLivePage(preview, destination: url)
      focusSelectedDocument(force: true)
      return
    }
    if let tab = store.state.activeTab {
      if dormantPages.contains(tab.id) {
        store.navigate(tabID: tab.id, address: address, recordHistory: false)
        if let updated = store.tab(tab.id) { navigateExtensionTab(updated, address: url.absoluteString) }
        return
      }
      if let page = engine.pages[tab.id] {
        navigation.cancelRestore(page)
        loadLivePage(page, destination: url)
      } else {
        store.navigate(tabID: tab.id, address: address, recordHistory: false)
        if let updated = store.tab(tab.id) { _ = page(for: updated) }
      }
    } else if let tab = store.createTab(address: address) {
      _ = page(for: tab)
    }
    scheduleLayout()
    focusSelectedDocument(force: true)
  }
  /// Keep the committed model intact until this exact native navigation commits.
  /// Page.navigate's browser-generated navigation token returns the decision
  /// for this request, including beforeunload veto and superseding navigation.
  private func loadLivePage(_ page: ChromiumPage, destination: URL) {
    let id = page.id, request = UUID(), ownerID = windowContext.id, profileID = page.profileID
    let sourceID = id.hasPrefix("peek:") ? String(id.dropFirst(5)) : id
    liveNavigations.removeValue(forKey: id)?.task.cancel()
    pendingHistory[id] = PendingHistory(source: page.url?.absoluteString,
      destination: destination.absoluteString, liveRequestID: request)
    let task = Task { @MainActor [weak self, weak page] in
      guard let self, let page else { return }
      var submittedBrowser: CefBrowser?
      @MainActor func isCurrentOwner() -> Bool {
        page.id == id && page.profileID == profileID && page.ownerWindowID == ownerID
          && self.engine.pages[id] === page && self.owns(page, tabID: sourceID)
          && self.windowContext.id == ownerID && self.windowContext.isOpen
          && !self.windowContext.isClosing && !self.engine.isTerminating
          && self.deletingProfileID != profileID
          && submittedBrowser.map { page.browser === $0 && !$0.isClosed } == true
      }
      defer {
        if self.liveNavigations[id]?.id == request {
          self.liveNavigations.removeValue(forKey: id)
          // Other native routes can request the same URL. Only this request's
          // exact pending lease may be settled by its reply or cancellation.
          if self.pendingHistory[id]?.liveRequestID == request {
            self.pendingHistory.removeValue(forKey: id)
            if isCurrentOwner() {
              self.modelURLs[id] = self.store.document(id: id)?.url
              page.onChange?()
            }
          }
          if isCurrentOwner() { self.scheduleLayout() }
        }
      }
      do {
        let browser = try await page.ready()
        submittedBrowser = browser
        try Task.checkCancellation()
        guard self.liveNavigations[id]?.id == request, isCurrentOwner() else { return }
        _ = try await browser.devTools.call("Page.navigate",
          parameters: ["url": destination.absoluteString], timeout: 120)
        try Task.checkCancellation()
        guard self.liveNavigations[id]?.id == request, isCurrentOwner() else { return }
        // Network failures reach CEF's main-frame load-error callback and the
        // inline document error surface. Page.navigate can reply before that
        // callback; interpreting its errorText as a separate UI failure creates
        // a duplicate modal sheet over the page. Protocol/transport failures
        // still throw and follow the exact-owner error path below.
      } catch {
        if !(error is CancellationError), self.liveNavigations[id]?.id == request,
          isCurrentOwner() { self.showError(error.localizedDescription) }
      }
    }
    liveNavigations[id] = (request, task)
  }
  /// Identity-changing operations must wait for Chromium's actual response,
  /// then reject a replacement request rather than promote or move mid-flight.
  private func settleLiveNavigation(_ page: ChromiumPage) async throws {
    let id = page.id, profileID = page.profileID, ownerID = windowContext.id
    let browser = page.browser
    let sourceID = id.hasPrefix("peek:") ? String(id.dropFirst(5)) : id
    if let pending = liveNavigations[id] { await pending.task.value }
    try Task.checkCancellation()
    guard page.id == id, page.profileID == profileID, page.ownerWindowID == ownerID,
      engine.pages[id] === page, page.browser === browser, owns(page, tabID: sourceID),
      windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      deletingProfileID != profileID, liveNavigations[id] == nil,
      application.webDialogs.pendingRequestCount(for: page) == 0 else { throw CancellationError() }
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
    pendingHistory[tab.id] = PendingHistory(source: page.url?.absoluteString ?? tab.url, destination: address)
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
  @discardableResult func requestOpenPeek(sourceTabID: String, sourcePage: ChromiumPage? = nil,
    url: URL, origin: CGRect? = nil) async throws -> Bool {
    try await peekOpening.open(sourceTabID: sourceTabID, sourcePage: sourcePage, url: url) { destination in
      let ownerID = self.windowContext.id
      guard let source = self.store.tab(sourceTabID), !source.isClosed, source.windowID == ownerID else {
        throw CancellationError()
      }
      try self.store.commit { state in
        // A façade projects one window; its commit receives the shared
        // canonical collection. Resolve identity inside that collection.
        guard let index = state.tabs.firstIndex(where: {
          $0.id == sourceTabID && $0.windowID == ownerID && !$0.isClosed
        }) else { return }
        state.tabs[index].peek = SavedPeek(url: destination.absoluteString, title: destination.host ?? "")
      }
      self.peekOrigins[sourceTabID] = origin
    }
  }
  func promotePeek() {
    guard let source = store.state.activeTab, source.peek != nil, source.peek?.isPresented != false,
      !peekOpening.isReplacing(sourceTabID: source.id) else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.preparePeekPromotion(sourceID: source.id)
        guard self.selectedDocumentID == "peek:" + source.id else { throw CancellationError() }
        let complete = { [weak self] in
          guard let self, self.selectedDocumentID == "peek:" + source.id else { return }
          Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.promotePeekDocument(sourceID: source.id, activate: true, authorize: {}) }
            catch is CancellationError { }
            catch { self.showError(error.localizedDescription) }
          }
        }
        if !self.peekPanel.animateExpand(completion: complete) { complete() }
      } catch is CancellationError { }
      catch { self.showError(error.localizedDescription) }
    }
  }
  private func preparePeekPromotion(sourceID: String) async throws -> ChromiumPage {
    guard !peekOpening.isReplacing(sourceTabID: sourceID) else { throw CancellationError() }
    guard let document = store.document(id: "peek:" + sourceID) else { throw CancellationError() }
    let page = try await ensurePageReady(document)
    try await settleLiveNavigation(page)
    try await navigation.waitForRestore(page)
    if !page.isPrivate {
      application.inspectRuntimeCapabilities()
      await application.runtimeCapabilityTask?.value
      guard application.runtimeCapabilitiesChecked else {
        throw ShortcutError("Chromium’s browser capabilities could not be verified. Try again.")
      }
    }
    try await extensionBrowser.prepareInitialNavigation(page)
    guard page.id == "peek:" + sourceID, engine.pages[page.id] === page,
      page.ownerWindowID == windowContext.id, owns(page, tabID: sourceID),
      liveNavigations[page.id] == nil, store.tab(sourceID)?.peek != nil,
      !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    return page
  }
  func promotePeekDocument(sourceID: String, activate: Bool, authorize: @MainActor () async throws -> Void) async throws -> BrowserTab {
    let page = try await preparePeekPromotion(sourceID: sourceID)
    let preparation = !page.isPrivate && application.supportsHistoryMirror
      ? try await application.historyMirror.preparePublication(page) : nil
    do {
      try await authorize()
      guard page.id == "peek:" + sourceID, engine.pages[page.id] === page,
        page.ownerWindowID == windowContext.id, owns(page, tabID: sourceID),
        liveNavigations[page.id] == nil, store.tab(sourceID)?.peek != nil,
        !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
      try preparation?.validate()
      let promoted = try commitPeekPromotion(sourceID: sourceID, activate: activate, publication: preparation?.publication)
      await preparation?.finish(committed: true)
      return promoted
    } catch {
      await preparation?.finish(committed: false)
      throw error
    }
  }
  private func commitPeekPromotion(sourceID id: String, activate: Bool, publication: NativeHistoryPublication? = nil) throws -> BrowserTab {
    guard !peekOpening.isReplacing(sourceTabID: id) else { throw CancellationError() }
    let previewID = "peek:" + id
    guard let preview = engine.pages[previewID], owns(preview, tabID: id), preview.browser != nil,
      preview.ownerWindowID == windowContext.id, liveNavigations[previewID] == nil,
      !windowContext.isClosing, !engine.isTerminating else { throw CancellationError() }
    let promoted = try publication.map { try store.promoteNativeHistoryPeekDurably(tabID: id, publication: $0, activate: activate) }
      ?? store.promotePeekDurably(tabID: id, activate: activate)
    if let page = engine.adoptPage(fromID: previewID, toID: promoted.id) {
      extensionBrowser.didPromotePeek(sourceID: id, targetID: promoted.id)
      navigation.forget(previewID)
      page.setPresentationParent(nil)
      modelURLs.removeValue(forKey: previewID)
      pendingHistory[promoted.id] = pendingHistory.removeValue(forKey: previewID)
      visiblePageFrames[promoted.id] = visiblePageFrames.removeValue(forKey: previewID)
      modelURLs[promoted.id] = promoted.url
      wire(page, tabID: promoted.id, peek: false)
      application.historyVisits.didPromote(page)
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
    peekOpening.cancel(discardDestination: true)
    if let page = engine.pages["peek:" + id] { page.close() }
    else { store.closePeek(tabID: id) }
  }
  func find() {
    actions.openFind()
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
      let extensionPopup = engine.extensionPopupOwner(focusedWindow) === windowContext
      guard browserControls || documentErrorPanels.owns(focusedWindow)
        || extensionPopup || windowPages.values.contains(where: { $0.nativeWindow === focusedWindow }) else { return false }
      // Escape belongs to the actual Chrome bubble. Shell navigation shortcuts
      // below still target its exact owning logical browser window.
      if extensionPopup && event.keyCode == 53 && flags.isEmpty { return false }
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
    // Only this accepted key event carries document origin. Native menu and
    // palette commands use the default shell origin even when a page is key.
    let fromPage = event.window.map { source in
      windowPages.values.contains { $0.nativeWindow === source }
    } ?? false
    runCommand(command.id, fromPage: fromPage)
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
    let menuFingerprint = catalog.map { "\($0.id):\($0.accelerator):\(commandAvailable($0.id))" }.joined(separator: "|")
      + ":\(window?.styleMask.contains(.fullScreen) == true):"
      + ["unsplit", "reopen-window", "window-minimize", "window-zoom"].map { "\($0):\(commandAvailable($0))" }.joined(separator: "|")
    if let cached = nativeMenus, cached.fingerprint == menuFingerprint {
      // Chrome can replace the application's menu when its native document
      // becomes key. Restore our exact owner's bar without rebuilding every
      // menu for a page/editor focus change inside the same browser.
      if NSApp.servicesMenu !== cached.services { NSApp.servicesMenu = cached.services }
      if NSApp.windowsMenu !== cached.windows { NSApp.windowsMenu = cached.windows }
      if NSApp.helpMenu !== cached.help { NSApp.helpMenu = cached.help }
      if NSApp.mainMenu !== cached.bar { NSApp.mainMenu = cached.bar }
      return
    }
    func command(_ id: String, _ title: String) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = id; item.isEnabled = commandAvailable(id)
      let parts = (catalog.first { $0.id == id }?.accelerator ?? "").components(separatedBy: "+")
      if let key = parts.last, let equivalent = NativeShortcutEvent.menuKeyEquivalent(key) {
        item.keyEquivalent = equivalent; item.keyEquivalentModifierMask = []
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
    edit.autoenablesItems = true
    for (id,title,key,flags): (String,String,String,NSEvent.ModifierFlags) in [
      ("undo","Undo","z",.command),("redo","Redo","z",[.command,.shift]),
      ("cut","Cut","x",.command),("copy","Copy","c",.command),("paste","Paste","v",.command),
      ("paste-match-style","Paste and Match Style","v",[.command,.option,.shift]),("select-all","Select All","a",.command)] {
      if id == "cut" { edit.addItem(.separator()) }
      let item = command("edit:" + id,title)
      NativeEditingMenu.configure(item, id: id)
      item.keyEquivalent = key; item.keyEquivalentModifierMask = flags; edit.addItem(item)
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
    let minimize = command("window-minimize", "Minimize")
    minimize.keyEquivalent = "m"; minimize.keyEquivalentModifierMask = .command; window.addItem(minimize)
    window.addItem(command("window-zoom", "Zoom"))
    window.addItem(.separator()); window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    NSApp.windowsMenu = window
    let help = append("Help", [("onboarding","Welcome Tour"),("",""),("releases","Zacro Releases"),("issues","Report an Issue")])
    NSApp.helpMenu = help
    NSApp.mainMenu = bar
    nativeMenus = (menuFingerprint, bar, servicesMenu, window, help)
  }
  private func deleteScope(space: String?, profile: String?) {
    guard pendingDeletion == nil, deletingProfileID == nil else { return }
    if let profile, application.clearingHistoryProfiles.contains(profile) {
      showError("Finish clearing this profile’s history first.")
      return
    }
    if let space { store.deleteSpace(id: space); return }
    guard let profile, let profileRecord = store.state.profiles.first(where: { $0.id == profile }) else { return }
    deletingProfileID = profile
    Task { @MainActor [self] in
      do {
        if !profileRecord.isPrivate {
          try await application.historyMirror.suspend(profileID: profile)
          // Retire the observer before its hidden transport can close. A veto
          // reconnects through a fresh manager, rather than keeping a dead
          // DevTools registration that can no longer publish native changes.
          await extensionSync.pauseProfile(profile)
        }
      } catch {
        if deletingProfileID == profile { deletingProfileID = nil }
        if !profileRecord.isPrivate { extensionSync.resumeProfile(profile) }
        application.historyMirror.resume(profileID: profile)
        showError(error.localizedDescription)
        return
      }
      guard deletingProfileID == profile, !engine.isTerminating,
        store.state.profiles.contains(where: { $0.id == profile && $0.isPrivate == profileRecord.isPrivate }) else {
        if deletingProfileID == profile { deletingProfileID = nil }
        if !profileRecord.isPrivate { extensionSync.resumeProfile(profile) }
        application.historyMirror.resume(profileID: profile)
        return
      }
      // The mirror's actual DB barrier must complete while its transport is
      // alive, before any page/profile broker can enter the close sequence.
      await application.popupAdoptions.prepareForNativeClose(profileID: profile)
      let ids = Set(engine.pages.values.filter { $0.profileID == profile }.map(\.id))
      let completion = { [weak self] in
        guard let self else { return }
        Task { [weak self] in
          guard let self else { return }
          defer {
            self.deletingProfileID = nil; self.application.scheduleAllWindows()
            if !profileRecord.isPrivate { self.extensionSync.resumeProfile(profile) }
            self.application.historyMirror.resume(profileID: profile)
          }
          var committed = false
          do {
            try await self.engine.closeAuxiliaryBrowsers(profileID: profile, isPrivate: profileRecord.isPrivate)
            guard self.deletingProfileID == profile,
              self.store.state.profiles.contains(where: { $0.id == profile && $0.isPrivate == profileRecord.isPrivate }) else {
              throw CancellationError()
            }
            try await self.services.prepareProfileDeletion(profile)
            // Provider cleanup can suspend while an extension opens another
            // native auth window. Drain that exact context again before commit.
            try await self.engine.closeAuxiliaryBrowsers(profileID: profile, isPrivate: profileRecord.isPrivate)
            guard self.deletingProfileID == profile, !self.engine.isTerminating,
              self.store.state.profiles.contains(where: { $0.id == profile && $0.isPrivate == profileRecord.isPrivate }) else {
              throw CancellationError()
            }
            let ids = self.application.store.state.tabs.filter { self.store.profileID(for: $0) == profile }.map(\.id)
            try self.store.deleteProfileDurably(id: profile)
            committed = true
            self.application.bookmarks.removeProfile(profile)
            self.application.historyMirror.removeProfile(profile)
            self.downloads.removeProfile(profile)
            if profileRecord.isPrivate {
              try await self.application.retirePrivateProfileAfterModelRemoval(profile)
            }
            else {
              try await self.engine.retireProfileDownloads(profileID: profile, isPrivate: false)
              try self.engine.retireProfile(profile)
            }
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
            if !profileRecord.isPrivate {
              try NativeProfileArtifacts.remove(directory: self.engine.dataDirectory, profileID: profile)
              try self.store.acknowledgeNativeProfileRetirement(profile)
            }
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
      application.popupAdoptions.willCloseProfileDocuments(profileID: profile, ids: ids)
      for id in ids { engine.close(id: id) }
    }
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
    let needsWindow = pageCommands.contains(id) || id.hasPrefix("peek-") || [
      "close-tab", "close-window", "sidebar-toggle", "fullscreen", "previous-tab", "next-tab",
      "history-back", "history-forward", "unsplit", "window-minimize", "window-zoom",
    ].contains(id)
    if needsWindow && (!windowContext.isOpen || windowContext.isClosing || engine.isTerminating) { return false }
    if id == "window-minimize" { return window?.isMiniaturized == false }
    if id == "reopen-window" { return !application.repository.savedWindows.isEmpty }
    if id == "reopen-tab" { return recentlyClosedTabID != nil }
    if id == "history-back" { return actions.canGoBack }
    if id == "history-forward" { return actions.canGoForward }
    if id.hasPrefix("peek-") { return store.state.activeTab?.peek != nil && store.state.activeTab?.peek?.isPresented != false }
    if id == "unsplit" { return visibleSplit != nil }
    if id == "stop" { return activePage?.isLoading == true }
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
    } + [BrowserRuntimeCommand(id: "unsplit", title: "Unsplit tabs", icon: commandIcon("unsplit"), keywords: "split separate", available: commandAvailable("unsplit")) { [weak self] in self?.runCommand("unsplit") },
      BrowserRuntimeCommand(id: "reopen-window", title: "Reopen closed window", icon: commandIcon("reopen-window"), keywords: "restore session tabs", available: commandAvailable("reopen-window")) { [weak self] in self?.runCommand("reopen-window") },
      BrowserRuntimeCommand(id: "windows", title: "Saved windows", icon: commandIcon("windows"), keywords: "restore session tabs", available: true) { [weak self] in self?.runCommand("windows") },
      BrowserRuntimeCommand(id: "about", title: "About Zacro", icon: "info", keywords: "version browser", available: true) { [weak self] in self?.runCommand("about") }]
    if application.focusedCoordinator === self { installMenus() }
  }
  private func commandIcon(_ id: String) -> String {
    NativeGlyph.commandName(id)
  }
  @objc private func menuCommand(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String else { return }
    if id.hasPrefix("edit:") { editCommand(String(id.dropFirst(5))) }
    else {
      application.performApplicationCommand(id,
        preferredWindowID: application.focusedCoordinator?.windowContext.id ?? windowContext.id)
    }
  }
  private func editCommand(_ id: String) {
    NativeEditingMenu.perform(id, sender: self)
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard let id = item.representedObject as? String else { return true }
    return commandAvailable(id)
  }
  private var orderedTabs: [BrowserTab] {
    store.sidebarTabs()
  }
  func runCommand(_ id: String, fromPage: Bool = false) {
    let tracingSidebarFocus = ["focus-sidebar", "reveal-tab"].contains(id)
      && CommandLine.arguments.contains("--native-integration-acceptance")
    guard application.permitWindowCommand(id, from: self) else {
      if tracingSidebarFocus { fputs("Native sidebar command rejected: window=\(windowContext.id) command=\(id) stage=application-admission\n", stderr) }
      return
    }
    if tracingSidebarFocus { fputs("Native sidebar command admitted: window=\(windowContext.id) command=\(id) popup=\(isPopup)\n", stderr) }
    if isPopup {
      if id == "close-tab" || id == "close-window" {
        if id == "close-tab", store.state.activeTab?.peek != nil, store.state.activeTab?.peek?.isPresented != false { closePeek() }
        else { Task { [weak self] in _ = await self?.requestCloseWindow() } }
        return
      }
      if id == "focus-chrome" { activePage?.focus(); return }
      let documentCommands: Set<String> = ["history-back", "history-forward", "copy-url", "mute-tab", "reload", "force-reload",
        "stop", "find", "find-next", "find-previous", "bookmark", "save-page", "print", "zoom-in", "zoom-out", "zoom-reset",
        "developer-tools", "fullscreen", "window-minimize", "window-zoom", "about", "new-window", "open-browser", "peek-close", "peek-promote"]
      if !documentCommands.contains(id) {
        do { try application.browsingWindow(profileID: store.activeProfileID).runCommand(id) }
        catch { showError(error.localizedDescription) }
        return
      }
    }
    guard commandAvailable(id) else {
      if tracingSidebarFocus { fputs("Native sidebar command rejected: window=\(windowContext.id) command=\(id) stage=availability\n", stderr) }
      return
    }
    if id == "sidebar-toggle" {
      actions.toggleSidebar(fromPage)
      // The UI dismissal handoff owns focus. Generic shell activation here
      // would immediately steal focus back from the selected native document.
      return
    }
    if ["focus-sidebar", "reveal-tab"].contains(id), !actions.palette, !actions.themeEditor {
      // The selected Chromium document can own a separate key window. Make
      // the intended shell key before setting its custom keyboard-focus target.
      window?.makeKeyAndOrderFront(nil)
    }
    let interfaceHandled = actions.performInterfaceCommand(id)
    if tracingSidebarFocus { fputs("Native sidebar interface dispatch: window=\(windowContext.id) command=\(id) handled=\(interfaceHandled) key=\(window?.isKeyWindow == true)\n", stderr) }
    if interfaceHandled {
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
    case "find-next":
      if !actions.findVisible { find() }
      actions.findNext()
    case "find-previous":
      if !actions.findVisible { find() }
      actions.findPrevious()
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
      var question = ""
      if actions.palette {
        question = actions.query
        actions.palette = false
      } else if store.state.activeTab?.homePage == true, !actions.homeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        question = actions.homeQuery
        actions.homeQuery = ""
      }
      presentAIQuestion(question)
    case "preferences": actions.library = "Settings"
    case "new-window": application.newWindow()
    case "open-browser": application.newWindow()
    case "close-window": windowContext.close()
    case "window-minimize": window?.performMiniaturize(nil)
    case "window-zoom": window?.performZoom(nil)
    case "fullscreen": window?.toggleFullScreen(nil)
    case "developer-tools": activePage?.showDevTools()
    case "import": presentCollectionPanel(exporting: false)
    case "export": presentCollectionPanel(exporting: true)
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
    NativeSidePanelPresentationDiagnostics.showError(message, owner: self)
    guard let window, windowContext.isOpen else {
      fputs("Zacro: \(message)\n", stderr); return
    }
    if windowContext.isClosing { deferredWindowError = message; return }
    let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "OK")
    Task { [weak self, weak window] in
      guard let self, let window, self.windowContext.isOpen,
        !self.windowContext.isClosing, self.window === window else { return }
      _ = await NativeWindowSheet.present(alert, for: window)
    }
  }
  private func presentCollectionPanel(exporting: Bool) {
    guard collectionPanelTask == nil, let window, windowContext.isOpen, !windowContext.isClosing,
      !engine.isTerminating else { return }
    let profileID = store.activeProfileID
    collectionPanelTask = Task { [weak self, weak window] in
      guard let self, let window else { return }
      defer { self.collectionPanelTask = nil }
      let panel: NSSavePanel
      if exporting {
        panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Zacro Collection.json"
      } else {
        let open = NSOpenPanel(); open.allowedContentTypes = [.json, .html]
        open.allowsMultipleSelection = false; panel = open
      }
      guard await NativeWindowSheet.present(panel, for: window) == .OK, !Task.isCancelled,
        self.window === window, self.windowContext.isOpen, !self.windowContext.isClosing,
        !self.engine.isTerminating, let url = panel.url else { return }
      do {
        if exporting { try self.store.exportData(to: url) }
        else {
          guard url.pathExtension.lowercased() != "html" || self.store.activeProfileID == profileID else { return }
          try self.store.importData(from: url)
        }
      } catch { self.showError(error.localizedDescription) }
    }
  }
  private var servicePalette: NativeSpacePalette {
    let theme = presentationTheme
    let dark = theme.appearance == "dark" || (theme.appearance == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    return NativeSpacePalette(theme: theme, dark: dark)
  }
  fileprivate var presentationTheme: SpaceTheme {
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
  func extensionActionPage(profileID: String, requireFocused: Bool = false,
    authorize: @MainActor () async throws -> Void = {}) async throws -> ChromiumPage {
    func available() -> Bool {
      guard store.activeProfileID == profileID, store.state.activeProfile?.isPrivate == false,
        deletingProfileID != profileID, windowContext.isOpen, !windowContext.isClosing,
        !engine.isTerminating else { return false }
      guard requireFocused else { return true }
      let keyWindow = NSApp.keyWindow
      let ownsControls = keyWindow.map {
        ($0.identifier == NSUserInterfaceItemIdentifier("ZacroBrowserControls") && $0.parent === window)
          || documentErrorPanels.owns($0) || $0 === peekPanel.presentationWindow
          || engine.extensionPopupOwner($0) === windowContext
      } ?? false
      return NSApp.isActive && application.focusedCoordinator === self
        && window?.isVisible == true && window?.isMiniaturized == false
        && (ownsDocumentFocusWindow(keyWindow) || ownsControls) && NSApp.modalWindow == nil
        && window?.attachedSheet == nil && keyWindow?.sheetParent == nil
    }
    guard available() else { throw CancellationError() }
    let originalSelection = selectedDocumentID
    try await authorize()
    try Task.checkCancellation()
    guard available(), selectedDocumentID == originalSelection else { throw CancellationError() }
    let tab: BrowserTab
    if let id = originalSelection {
      guard let selected = store.document(id: id), !selected.isClosed else { throw CancellationError() }
      tab = selected
    } else {
      // The native request has been authorized immediately before this model
      // mutation. An empty window gains a real tab, never a hidden catalog entry.
      guard let created = store.createTab(address: "about:blank") else {
        throw ChromeExtensionError.managementUnavailable
      }
      tab = created
    }
    guard store.profileID(for: tab) == profileID else { throw CancellationError() }
    let page = try await ensurePageReady(tab)
    try await navigation.waitForRestore(page)
    guard page.profileID == profileID, page.ownerWindowID == windowContext.id,
      available(), selectedDocumentID == tab.id, activePage === page else { throw CancellationError() }
    try await extensionBrowser.prepareInitialNavigation(page)
    try Task.checkCancellation()
    guard available(), selectedDocumentID == tab.id, activePage === page,
      engine.pages[tab.id] === page else { throw CancellationError() }
    return page
  }
  private func installServices() {
    actions.askAI = { [weak self] question in self?.presentAIQuestion(question) }
    extensions.invokeSidePanel = { [weak self] profile, identifier in
      guard let self else { throw CancellationError() }
      let page = try await self.extensionActionPage(profileID: profile)
      try await ChromeExtensionManager(engine: self.engine, profileID: profile)
        .openSidePanel(identifier, on: page)
    }
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
    actions.libraryHeaderContent = { [weak self] section in
      guard let self, section == "AI" else { return nil }
      return AnyView(NativeAINewConversationButton(model:self.services))
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
    if action == "ai:open-search" {
      try Task.checkCancellation()
      guard windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
        payload["profileId"].string == store.activeProfileID,
        payload["conversationId"].string == services.conversationID,
        services.ordinaryAISearchQuery(requestID:payload["requestId"].string) == payload["query"].string,
        let url = BrowserAddress.searchURL(payload["query"].string, engine:store.state.settings.searchEngine) else {
        throw ServiceError("CONTEXT_CHANGED", "This answer or its browser window changed.")
      }
      // Search is an explicit action, not a claim that the provider verified
      // this destination. Resolve the current search setting at the click.
      actions.newTab(url.absoluteString)
      return .null
    }
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
  private func cancelPermissionPrompt(_ id: UUID) {
    guard let pending = permissionPrompts.removeValue(forKey: id) else { return }
    permissionQueue.removeAll { $0 == id }
    pending.callback.cancel()
    pending.alert.window.sheetParent?.endSheet(pending.alert.window, returnCode: .cancel)
    schedulePermissionPresentation()
  }
  private func cancelPermissionPrompts() {
    for id in Array(permissionPrompts.keys) { cancelPermissionPrompt(id) }
  }
  private static let permissionKinds: [(CefPermissionKind, String, String)] = [
    (.camera,"camera","camera"),(.microphone,"microphone","microphone"),(.geolocation,"geolocation","location"),
    (.notifications,"notifications","notifications"),(.clipboard,"clipboard","clipboard"),(.midi,"midi","MIDI devices"),
    (.pointerLock,"pointer-lock","pointer lock"),(.storageAccess,"storage-access","site storage"),(.sensors,"sensors","sensors"),
    (.windowManagement,"window-management","window management"),(.downloads,"downloads","multiple downloads")]
  private func permissionDetails(_ request: CefPermissionRequest) -> (URL, String, [(CefPermissionKind, String, String)])? {
    guard let url = BrowserAddress.webURL(request.origin), !request.kinds.contains(.other), !request.kinds.isEmpty else { return nil }
    var origin = URLComponents(); origin.scheme = url.scheme; origin.host = url.host; origin.port = url.port
    guard let key = origin.url?.absoluteString else { return nil }
    let requested = Self.permissionKinds.filter { request.kinds.contains($0.0) }
    return requested.isEmpty ? nil : (url, key, requested)
  }
  /// A noninteractive policy result; nil means a new request requires user UI.
  private func immediatePermissionDecision(_ request: CefPermissionRequest, page: ChromiumPage) -> CefPermissionDecision? {
    guard mayRequestPermission(page) else { return .deny }
    if URL(string: request.origin)?.scheme?.lowercased() == "chrome-extension"
      || !request.kinds.intersection([.screenCapture, .systemAudioCapture]).isEmpty { return .useDefault }
    guard let (_, key, requested) = permissionDetails(request) else { return .deny }
    if requested.contains(where: { store.savedPermission(profileID: page.profileID, origin: key, permission: $0.1) == false }) { return .deny }
    if requested.allSatisfy({ store.savedPermission(profileID: page.profileID, origin: key, permission: $0.1) == true }) {
      if !request.kinds.intersection([.camera, .microphone]).isEmpty { mediaPermissionPages.insert(page.id) }
      return .allow
    }
    return nil
  }
  private func requestPermission(_ request: CefPermissionRequest, page: ChromiumPage,
                                 callback: CefPermissionCallback) -> Bool {
    func finish(_ choice: CefPermissionDecision) -> Bool { callback.resolve(choice); return true }
    guard callback.isPending else { return true }
    // Extension permission policy and screen/source selection belong to Chromium.
    // A saved camera or microphone choice must never authorize screen sharing.
    if let choice = immediatePermissionDecision(request, page: page) {
      return choice == .useDefault ? false : finish(choice)
    }
    guard let (url, key, requested) = permissionDetails(request) else { return finish(.deny) }
    let promptID = "\(page.profileID):\(key):\(request.kinds.rawValue)"
    guard !permissionPrompts.values.contains(where: { $0.key == promptID }), permissionPrompts.count < 16
      else { return finish(.dismiss) }
    let originalURL = page.url
    let alert = NSAlert(); alert.messageText = "Allow \(url.host ?? request.origin) to use \(requested.map { $0.2 }.joined(separator: ", "))?"
    alert.informativeText = "Profile: \(store.state.profiles.first(where: { $0.id == page.profileID })?.name ?? "Personal")"
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Remember for this site"
    alert.suppressionButton?.state = .off
    alert.addButton(withTitle: "Don’t Allow"); alert.addButton(withTitle: "Allow")
    permissionPrompts[request.id] = .init(pageID: page.id, profileID: page.profileID,
      address: originalURL, key: promptID, request: request, originKey: key,
      permissionKeys: requested.map { $0.1 }, alert: alert, callback: callback)
    permissionQueue.append(request.id)
    presentQueuedPermission()
    return true
  }
  private func schedulePermissionPresentation() {
    guard !permissionPrompts.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in self?.presentQueuedPermission() }
  }
  private func presentQueuedPermission() {
    guard let window, windowContext.isOpen, !windowContext.isClosing, !engine.isTerminating,
      window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
      NSApp.modalWindow == nil, NSApp.isActive, ownsDocumentFocusWindow(NSApp.keyWindow),
      !permissionPrompts.values.contains(where: \.presented),
      let id = permissionQueue.first, var pending = permissionPrompts[id] else { return }
    guard let page = engine.pages[pending.pageID], page.profileID == pending.profileID,
      page.url == pending.address, pending.callback.isPending, mayRequestPermission(page) else {
      cancelPermissionPrompt(id); return
    }
    pending.presented = true; permissionPrompts[id] = pending
    let alert = pending.alert, callback = pending.callback, request = pending.request
    let originalURL = pending.address
    alert.beginSheetModal(for: window) { [weak self, weak page] response in
      guard let self, let pending = self.permissionPrompts.removeValue(forKey: request.id),
        pending.callback === callback, callback.isPending else { callback.cancel(); return }
      self.permissionQueue.removeAll { $0 == request.id }
      defer { self.schedulePermissionPresentation() }
      guard let page, self.mayRequestPermission(page), page.url == originalURL,
        self.engine.pages[page.id] === page,
        self.store.state.profiles.contains(where: { $0.id == page.profileID }) else { callback.cancel(); return }
      guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
        callback.cancel(); return
      }
      let allowed = response == .alertSecondButtonReturn
      if alert.suppressionButton?.state == .on {
        for permission in pending.permissionKeys {
          self.store.setPermission(profileID: page.profileID, origin: pending.originKey, permission: permission, allowed: allowed)
        }
      }
      if allowed && !request.kinds.intersection([.camera, .microphone]).isEmpty { self.mediaPermissionPages.insert(page.id) }
      callback.resolve(allowed ? .allow : .deny)
    }
  }
  private func mayRequestPermission(_ page: ChromiumPage) -> Bool {
    windowContext.isOpen && !windowContext.isClosing && !engine.isTerminating
      && deletingProfileID != page.profileID
      && engine.pages[page.id] === page && page.ownerWindowID == windowContext.id
      && store.activeProfileID == page.profileID
      && (activePage === page || visiblePageFrames[page.id] != nil)
  }
  private func libraryAction(_ action: String, payload: [String:String]) async throws {
    try Task.checkCancellation()
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
      let profileID = store.activeProfileID
      guard let window else { throw CancellationError() }
      let record = try downloads.record(id, profileID: profileID)
      let suggestion = try await services.aiAction("ai:suggest-name", payload: ["name":.string(record.filename), "url":.string(record.sourceURL ?? record.url), "title":.string(record.sourceTitle ?? "")])
      guard self.window === window, windowContext.isOpen, !windowContext.isClosing,
        !engine.isTerminating, store.activeProfileID == profileID else { throw CancellationError() }
      _ = try downloads.record(id, profileID: profileID)
      let alert = NSAlert(); alert.messageText = "Rename download"
      let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = suggestion["name"].string
      alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
      guard await NativeWindowSheet.present(alert, for: window) == .alertFirstButtonReturn,
        !Task.isCancelled, self.window === window, windowContext.isOpen, !windowContext.isClosing,
        !engine.isTerminating, store.activeProfileID == profileID else { return }
      try await downloads.perform("download:rename", id: id, name: field.stringValue, profileID: profileID)
    } else if action == "tab:mute", let tab = store.tab(id), store.profileID(for: tab) == store.activeProfileID {
      store.updateTab(id) { $0.isMuted.toggle() }; engine.pages[id]?.browser?.isAudioMuted = !tab.isMuted
    } else if action == "tab:sleep" { try await sleepTab(id) }
    else if action == "peek:open", let address = payload["url"] {
      if let tab = store.state.activeTab {
        guard let url = BrowserAddress.webURL(address) else { throw ShortcutError("Choose a web link to preview.") }
        _ = try await requestOpenPeek(sourceTabID: tab.id, url: url)
      }
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
    defer {
      application.clearingHistoryProfiles.remove(profileID)
      application.historyMirror.resume(profileID: profileID)
    }
    if !profile.isPrivate {
      application.inspectRuntimeCapabilities()
      await application.runtimeCapabilityTask?.value
      guard application.runtimeCapabilitiesChecked else {
        throw ShortcutError("Chromium’s browser capabilities could not be verified. Try again.")
      }
      try await application.historyMirror.suspend(profileID: profileID)
    }
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
      let manager = ChromeExtensionManager(engine: engine, profileID: profileID)
      try await manager.clearBrowsingHistory()
      if application.supportsHistoryMirror {
        let barrier = try await manager.historyMirrorSession()
        await barrier.close()
      }
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
    // Reserve the shared profile operation before creating or awaiting a native
    // maintenance page. A second window must not replace its close continuation.
    deletingProfileID = profileID
    defer {
      deletingProfileID = nil; application.scheduleAllWindows()
      application.historyMirror.resume(profileID: profileID)
    }
    if !profile.isPrivate {
      application.inspectRuntimeCapabilities()
      await application.runtimeCapabilityTask?.value
      guard application.runtimeCapabilitiesChecked else {
        throw ShortcutError("Chromium’s browser capabilities could not be verified. Try again.")
      }
      try await application.historyMirror.suspend(profileID: profileID)
    }
    let maintenance = engine.page(id: "maintenance:" + profileID, profileID: profileID,
      isPrivate: profile.isPrivate, url: URL(string: "about:blank")!, ownerWindowID: nil)
    defer { maintenance.close() }
    maintenance.hide()
    let browser = try await maintenance.ready()
    guard try await browser.nativeCapabilities().browsingData else {
      throw ShortcutError("The Chromium runtime cannot clear all site data.")
    }
    try await engine.closeAuxiliaryBrowsers(profileID: profileID, isPrivate: profile.isPrivate)
    guard deletingProfileID == profileID,
      store.state.profiles.contains(where: { $0.id == profileID && $0.isPrivate == profile.isPrivate }) else {
      throw CancellationError()
    }
    if !profile.isPrivate {
      await services.resetAIConversations(profileID: profileID)
    }
    navigation.beginProfileReset(profileID)
    application.bookmarks.removeProfile(profileID)
    downloads.removeProfile(profileID)
    await extensionSync.pauseProfile(profileID)
    defer {
      navigation.endProfileReset(profileID)
      extensionSync.resumeProfile(profileID)
    }
    await application.popupAdoptions.prepareForNativeClose(profileID: profileID)
    let documents = engine.pages.values.filter { $0.profileID == profileID && $0 !== maintenance }
    let ids = Set(documents.map(\.id))
    if !ids.isEmpty {
      let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        profileDeletionPageIDs.formUnion(ids)
        application.popupAdoptions.willCloseProfileDocuments(profileID: profileID, ids: ids)
        scopeCloseCancelled = { continuation.resume(returning: false) }
        pendingDeletion = (ids, { [weak self] in
          self?.scopeCloseCancelled = nil
          continuation.resume(returning: true)
        })
        for page in documents { page.close() }
      }
      guard closed else { throw CancellationError() }
    }
    try await engine.closeAuxiliaryBrowsers(profileID: profileID, isPrivate: profile.isPrivate)
    guard deletingProfileID == profileID, !engine.isTerminating,
      store.state.profiles.contains(where: { $0.id == profileID && $0.isPrivate == profile.isPrivate }) else {
      throw CancellationError()
    }
    try await browser.clearProfileBrowsingData(siteData: true, cache: true, history: true)
    if !profile.isPrivate && application.supportsHistoryMirror {
      // BrowsingDataRemover completion alone does not report a failed History
      // SQL commit. Check the existing live maintenance page before Core clears.
      let barrier = try await maintenance.historyMirrorSession()
      await barrier.close()
    }
    try await engine.clearNetworkData(profileID: profileID, isPrivate: profile.isPrivate,
      selected: [.cookies, .cache, .httpAuthentication])
    try store.clearHistoryDurably(profileID: profileID)
    try store.clearPermissionsDurably(profileID: profileID)
    try await navigation.clearSavedHistory(profileID: profileID)
    let tabs = application.store.state.tabs.filter { application.store.profileID(for: $0) == profileID }
    let tabIDs = Set(tabs.map(\.id))
    try application.store.commit(purgeRecovery: true) { state in
      for index in state.tabs.indices where tabIDs.contains(state.tabs[index].id) {
        state.tabs[index].peek = nil
      }
    }
    for owner in application.windows.values {
      for id in tabIDs {
        owner.actions.icons.removeValue(forKey: id); owner.actions.iconColors.removeValue(forKey: id)
        owner.actions.peekIcons.removeValue(forKey: id)
      }
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
      let page = engine.pages[id], canUnload(page, tab: tab, automatically: automatically) else {
      traceDiscardRefusal(id, reason: "initial host ownership/visibility/state")
      return false
    }
    let originalURL = page.url
    let originalActivity = tab.lastAccessedAt
    let lease = try await application.peekLinks.suspendForDiscard(page)
    do {
      guard engine.pages[id] === page, page.url == originalURL,
        store.tab(id)?.lastAccessedAt == originalActivity else {
        await application.peekLinks.resumeAfterDiscard(lease)
        traceDiscardRefusal(id, reason: "document/activity changed during adapter retirement")
        return false
      }
      let discarded = try await unloadWithSuspendedLinks(id, automatically: automatically)
      await application.peekLinks.resumeAfterDiscard(lease)
      return discarded
    } catch {
      await application.peekLinks.resumeAfterDiscard(lease)
      throw error
    }
  }

  private func traceDiscardRefusal(_ id: String, reason: String) {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance") else { return }
    let tab = store.tab(id), page = engine.pages[id]
    var state: [String: Any] = [
      "id": id, "reason": reason, "ownerID": windowContext.id,
      "windowOpen": windowContext.isOpen, "windowClosing": windowContext.isClosing,
      "engineTerminating": engine.isTerminating, "taskCancelled": Task.isCancelled,
      "activeID": store.state.activeTabID ?? "nil", "activeProfile": store.activeProfileID,
      "sleepAvailable": actions.libraryCapabilities.contains("tab:sleep"),
      "modelExists": tab != nil, "pageExists": page != nil,
      "visibleFrame": visiblePageFrames.keys.contains(id),
      "visibleSplitMember": visibleSplit?.tabIDs.contains(id) == true,
      "reserved": reservedPages.contains(id), "dormant": dormantPages.contains(id),
      "discarding": discardingPages.contains(id), "mediaPermission": mediaPermissionPages.contains(id),
      "creating": pageCreations[id] != nil, "waking": dormantNavigations[id] != nil,
      "liveNavigation": liveNavigations[id] != nil,
    ]
    if let tab {
      state["closed"] = tab.isClosed; state["modelWindow"] = tab.windowID ?? "nil"
      state["profile"] = store.profileID(for: tab) ?? "nil"
      state["peek"] = tab.peek != nil; state["autoDiscardable"] = tab.autoDiscardable != false
      state["modelURLLength"] = tab.url.utf8.count
      if let page {
        state["ownsPage"] = owns(page, tabID: tab.id)
        state["downloadProtected"] = downloads.protects(tab, profileID: page.profileID)
        state["nativeURLMatchesModel"] = page.url?.absoluteString == tab.url
      }
    }
    if let page {
      state["browserID"] = page.browser?.id ?? -1
      state["nativeClosed"] = page.browser?.isClosed ?? true
      state["nativeLoading"] = page.isLoading
      state["nativeVisible"] = page.nativeWindow?.isVisible ?? false
      state["nativeOwner"] = page.ownerWindowID ?? "nil"
      state["restoring"] = navigation.isRestoring(page)
      state["pendingAuthentication"] = page.hasPendingAuthentication
      state["liveOpener"] = page.openerID.flatMap({ engine.pages[$0] }) != nil
      state["liveChildren"] = engine.pages.values.filter { $0.openerID == page.id }.count
    }
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
      fputs("Native discard refused state: \(String(decoding: data, as: UTF8.self))\n", stderr)
    } else { fputs("Native discard refused \(id): \(reason)\n", stderr) }
  }

  private func unloadWithSuspendedLinks(_ id: String, automatically: Bool) async throws -> Bool {
    guard actions.libraryCapabilities.contains("tab:sleep"), let tab = store.tab(id),
      let page = engine.pages[id], let browser = page.browser, canUnload(page, tab: tab, automatically: automatically) else {
      traceDiscardRefusal(id, reason: "host state changed while removing owned adapter")
      return false
    }
    let url = page.url
    let activity = tab.lastAccessedAt
    let safety = try await browser.documentSafetyState()
    guard safety.permitsAutomaticUnload else {
      traceDiscardRefusal(id, reason: "native safety \(safety)")
      return false
    }
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
      canUnload(page, tab: current, automatically: automatically), page.url == url else {
      traceDiscardRefusal(id, reason: "DOM safety or changed activity/owner")
      return false
    }
    let captured = page.isPrivate ? true : await navigation.captureBeforeDiscard(page, tabID: id, peek: false)
    guard captured,
      let latest = store.tab(id), latest.lastAccessedAt == activity,
      canUnload(page, tab: latest, automatically: automatically), page.url == url,
      try await browser.documentSafetyState().permitsAutomaticUnload else {
      traceDiscardRefusal(id, reason: "capture failed or final native/owner safety changed (captured=\(captured))")
      return false
    }
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
  // The document can be key while this shell remains the browser's main
  // window. A click on browser chrome must perform its action immediately.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return shouldPassThrough(local) ? nil : super.hitTest(point)
  }
}

private struct NativeContentOverlay: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  let coordinator: BrowserWindowCoordinator
  @State private var resizeRatio: Double?
  @Environment(\.presentedSpaceTheme) private var presentedTheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  private var needsTransparentResizeHitArea: Bool {
    let theme = presentedTheme ?? store.state.activeSpace?.theme ?? SpaceTheme()
    return !reduceTransparency && contrast != .increased && theme.opacity <= 0 && theme.blur <= 0
  }
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
            needsTransparentHitArea: needsTransparentResizeHitArea,
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
        ForEach(panes(width: geometry.size.width, height: geometry.size.height), id: \.id) { pane in
          if let message = actions.documentErrors[pane.id] {
            NativePageErrorView(message: message, url: store.document(id: pane.id)?.url ?? "",
              theme: coordinator.presentationTheme,
              retry: { coordinator.retryDocument(pane.id) }, editAddress: { coordinator.editDocumentAddress(pane.id) })
              .clipShape(NativePaneShape(radius: coordinator.isPopup ? 0 : store.state.settings.pageRadius))
              .frame(width: pane.frame.width, height: pane.frame.height)
              .position(x: pane.frame.midX, y: pane.frame.midY)
          }
        }
      }.coordinateSpace(name: "content")
    }
  }
  private struct Pane { let id: String; let frame: CGRect }
  private func panes(width: CGFloat, height: CGFloat) -> [Pane] {
    if let split = coordinator.visibleSplit {
      let first = max(0, width - 6) * (resizeRatio ?? split.ratio)
      return [Pane(id: split.leftTabID, frame: CGRect(x: 0, y: 0, width: first, height: height)),
        Pane(id: split.rightTabID, frame: CGRect(x: first + 6, y: 0, width: max(0, width - first - 6), height: height))]
    }
    return store.state.activeTabID.map { [Pane(id: $0, frame: CGRect(x: 0, y: 0, width: width, height: height))] } ?? []
  }
}
