import AppKit
import Combine
import SwiftUI
import ZacroChromium
import ZacroCore

@main
enum ZacroApplication {
  @MainActor static func main() {
    let base =
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_DATA"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Zacro Native")
    let engine = ChromiumEngine(dataDirectory: base)
    do {
      try engine.start()
      if CommandLine.arguments.contains("--engine-acceptance"),
        !CommandLine.arguments.contains("--native-ui-review"),
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
      let coordinator = ApplicationCoordinator(engine: engine, store: BrowserStore(directory: base))
      NSApplication.shared.delegate = coordinator
      NSApplication.shared.setActivationPolicy(.regular)
      coordinator.install()
      withExtendedLifetime(coordinator) { NSApplication.shared.run() }
    } catch {
      // Initialization failures must never silently switch engine or remove sandboxing.
      fputs("Zacro Chromium initialization failed: \(error)\n", stderr)
      exit(1)
    }
  }
}

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate {
  let engine: ChromiumEngine
  let store: BrowserStore
  let actions = BrowserActions()
  private var observations: Set<AnyCancellable> = []
  private var host: PassthroughHostingView<AnyView>?
  private var contentFrame = CGRect.zero
  private var layoutQueued = false
  private var keyMonitor: Any?
  private let peekPanel = PeekPanelController()
  private var pendingDeletion: (Set<String>, () -> Void)?
  private var internalPage: ChromiumPage?
  private lazy var favicons = FaviconCache(
    directory: engine.dataDirectory.appendingPathComponent("Icons"))
  private var peekFrames: [String: CGRect] = [:]
  private var retiringPageIDs = Set<String>()
  private var visiblePageFrames: [String: CGRect] = [:]
  private var modelURLs: [String: String] = [:]
  private var pendingHistory: [String: (source: String?, destination: String)] = [:]
  private var restoredHistoryPages = Set<String>()
  private var downloadPublication: [String: Date] = [:]
  private var downloadRecordIDs: [String: String] = [:]
  init(engine: ChromiumEngine, store: BrowserStore) {
    self.engine = engine
    self.store = store
  }
  var activePage: ChromiumPage? { store.state.activeTabID.flatMap { engine.pages[$0] } }
  func install() {
    guard let window = engine.window, let parent = window.contentView else { return }
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = .clear
    let root = BrowserShell(store: store, actions: actions) { [weak self] in
      NativeContentOverlay(store: self!.store, coordinator: self!)
    }
    let host = PassthroughHostingView(rootView: AnyView(root))
    host.frame = parent.bounds
    host.autoresizingMask = [.width, .height]
    host.shouldPassThrough = { [weak self] point in self?.passesThrough(point) ?? false }
    parent.addSubview(host, positioned: .above, relativeTo: nil)
    self.host = host
    actions.navigate = { [weak self] address in self?.navigate(address) }
    actions.newTab = { [weak self] address in
      guard let self, let tab = self.store.createTab(address: address) else { return }
      self.internalPage = nil
      self.actions.nativePageVisible = false
      _ = self.page(for: tab)
      self.scheduleLayout()
    }
    actions.activate = { [weak self] _ in
      self?.internalPage = nil
      self?.actions.nativePageVisible = false
      self?.scheduleLayout()
    }
    actions.back = { [weak self] in self?.goBack() }
    actions.forward = { [weak self] in self?.goForward() }
    actions.reload = { [weak self] in
      guard let page = self?.activePage else { return }
      if page.isLoading { page.stop() } else { page.reload() }
    }
    actions.zoom = { [weak self] in self?.activePage?.zoom(by: $0) }
    actions.printPage = { [weak self] in self?.activePage?.printPage() }
    actions.find = { [weak self] in self?.find() }
    actions.closeTab = { [weak self] id in
      guard let self else { return }
      if let page = self.engine.pages[id] { page.close() } else { self.store.closeTab(id: id) }
    }
    actions.deleteSpace = { [weak self] id in self?.deleteScope(space: id, profile: nil) }
    actions.deleteProfile = { [weak self] id in self?.deleteScope(space: nil, profile: id) }
    actions.openExtensions = { [weak self] in self?.openExtensions(store: false) }
    actions.openExtensionStore = { [weak self] in self?.openExtensions(store: true) }
    actions.onLayout = { [weak self] frame, _ in
      self?.contentFrame = frame
      self?.scheduleLayout()
    }
    contentFrame = actions.contentFrame
    engine.onLayout = { [weak self] in self?.scheduleLayout() }
    store.$state.dropFirst().sink { [weak self] _ in self?.scheduleLayout() }.store(
      in: &observations)
    actions.$palette.dropFirst().sink { [weak self] _ in self?.scheduleLayout() }.store(
      in: &observations)
    installMenus()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKey(event) == true ? nil : event
    }
    scheduleLayout()
    engine.showWindow()
    NSApp.activate(ignoringOtherApps: true)
    if ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"] != nil {
      navigate(ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"]!)
    }
  }
  private func passesThrough(_ point: NSPoint) -> Bool {
    guard let host, store.state.activeTab != nil || internalPage != nil, !actions.palette,
      actions.library == nil, !actions.themeEditor
    else { return false }
    let top = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
    if !store.state.settings.sidebarVisible
      && CGRect(x: contentFrame.minX, y: contentFrame.minY, width: 56, height: 56).contains(top)
    {
      return false
    }
    if let id = store.state.activeTabID, store.state.activeTab?.peek != nil,
      let frame = peekFrames[id]
    {
      return frame.contains(top)
    }
    if let id = store.state.activeTabID, let split = store.split(for: id) {
      let x = contentFrame.minX + (contentFrame.width - 6) * split.ratio
      if CGRect(x: x - 4, y: contentFrame.minY, width: 14, height: contentFrame.height).contains(
        top)
      {
        return false
      }
    }
    return contentFrame.contains(top)
  }
  private func scheduleLayout() {
    guard !layoutQueued else { return }
    layoutQueued = true
    DispatchQueue.main.async { [weak self] in
      self?.layoutQueued = false
      self?.layoutPages()
    }
  }
  private func page(for tab: BrowserTab) -> ChromiumPage? {
    guard !tab.isClosed, let profileID = store.profileID(for: tab),
      let profile = store.state.profiles.first(where: { $0.id == profileID })
    else { return nil }
    if let existing = engine.pages[tab.id],
      existing.profileID != profileID || existing.isPrivate != profile.isPrivate
    {
      retirePage(id: tab.id)
      return nil
    }
    guard !retiringPageIDs.contains(tab.id) else { return nil }
    let existed = engine.pages[tab.id] != nil
    let page = engine.page(
      id: tab.id, profileID: profileID, isPrivate: profile.isPrivate,
      url: URL(string: tab.url) ?? URL(string: "about:blank")!)
    if !existed {
      page.hide()
      if tab.navigation.count > 1 { restoredHistoryPages.insert(tab.id) }
      modelURLs[tab.id] = tab.url
    } else if modelURLs[tab.id] != tab.url, pendingHistory[tab.id] == nil,
      let url = URL(string: tab.url)
    {
      // Collection imports and explicit state navigation load the new destination,
      // without reusing a document from a different profile.
      pendingHistory[tab.id] = (page.url?.absoluteString ?? modelURLs[tab.id], tab.url)
      modelURLs[tab.id] = tab.url
      page.load(url)
    }
    wire(page, tabID: tab.id, peek: false)
    updateIcon(page, tab: tab)
    return page
  }
  private func owns(_ page: ChromiumPage, tabID: String) -> Bool {
    guard engine.pages[page.id] === page, !retiringPageIDs.contains(page.id),
      let tab = store.tab(tabID), !tab.isClosed,
      let profileID = store.profileID(for: tab), profileID == page.profileID,
      let profile = store.state.profiles.first(where: { $0.id == profileID }),
      profile.isPrivate == page.isPrivate
    else { return false }
    return true
  }
  private func wire(_ page: ChromiumPage, tabID: String, peek: Bool) {
    page.onChange = { [weak self, weak page] in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      if peek {
        guard self.store.tab(tabID)?.peek != nil else { return }
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
          self.store.setPeek(tabID: tabID, address: value, title: page.title)
        }
      } else if let tab = self.store.tab(tabID), let url = page.url {
        let value = url.absoluteString
        guard BrowserAddress.webURL(value) != nil || value == "about:blank" else { return }
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
      if self.store.state.activeTabID == tabID && !peek { self.updateNavigationState(page) }
    }
    page.onOpenURL = { [weak self, weak page] url, foreground in
      guard let self, let page, self.owns(page, tabID: tabID), let source = self.store.tab(tabID)
      else { return }
      // A background document cannot open a popup in the currently selected
      // profile. Preserve the originating document's exact Space ownership.
      if let tab = self.store.createTab(
        address: url.absoluteString, spaceID: source.spaceID, activate: foreground)
      {
        _ = self.page(for: tab)
      }
    }
    page.onPeek = { [weak self, weak page] url in
      guard let self, let page, self.owns(page, tabID: tabID) else { return }
      self.store.setPeek(tabID: tabID, address: url.absoluteString)
    }
    page.onDownload = { [weak self, weak page] download in
      guard let self, let page,
        self.store.state.profiles.contains(where: {
          $0.id == page.profileID && $0.isPrivate == page.isPrivate
        })
      else { return }
      let key = "\(page.profileID):\(download.id)"
      let id = self.downloadRecordIDs[key] ?? UUID().uuidString
      self.downloadRecordIDs[key] = id
      let now = Date()
      if !download.isComplete && !download.isCanceled, let previous = self.downloadPublication[id],
        now.timeIntervalSince(previous) < 0.4
      {
        return
      }
      self.downloadPublication[id] = now
      var record =
        self.store.state.downloads.first { $0.id == id }
        ?? DownloadRecord(
          id: id, profileID: page.profileID, url: download.url?.absoluteString ?? "",
          filename: download.fullPath?.lastPathComponent ?? "Download")
      record.path = download.fullPath?.path
      record.receivedBytes = download.receivedBytes
      record.totalBytes = download.totalBytes
      record.status =
        download.isComplete ? "complete" : download.isCanceled ? "cancelled" : "downloading"
      self.store.recordDownload(record)
    }
    page.onClosed = { [weak self, weak page] in
      guard let self, let page else { return }
      self.visiblePageFrames.removeValue(forKey: page.id)
      self.modelURLs.removeValue(forKey: page.id)
      self.pendingHistory.removeValue(forKey: page.id)
      self.restoredHistoryPages.remove(page.id)
      if peek {
        if self.store.tab(tabID)?.peek != nil { self.store.closePeek(tabID: tabID) }
      } else if let tab = self.store.tab(tabID), !tab.isClosed {
        self.store.closeTab(id: tabID)
      }
      self.scheduleLayout()
    }
  }
  private func retirePage(id: String) {
    guard let page = engine.pages[id], retiringPageIDs.insert(id).inserted else { return }
    page.onChange = nil
    page.onOpenURL = nil
    page.onPeek = nil
    // Cleanup is already reflected in the model; the native completion must
    // not archive a newly imported tab or close an already-closed saved pin.
    page.onClosed = { [weak self] in
      guard let self else { return }
      self.retiringPageIDs.remove(id)
      self.visiblePageFrames.removeValue(forKey: id)
      self.modelURLs.removeValue(forKey: id)
      self.pendingHistory.removeValue(forKey: id)
      self.restoredHistoryPages.remove(id)
      self.scheduleLayout()
    }
    engine.close(id: id)
  }
  private func updateNavigationState(_ page: ChromiumPage?) {
    refreshSiteControls()
    guard let tab = store.state.activeTab else {
      actions.canGoBack = false
      actions.canGoForward = false
      actions.loading = false
      return
    }
    actions.canGoBack = tab.navigationIndex > 0
    actions.canGoForward =
      tab.navigationIndex >= 0 && tab.navigationIndex < tab.navigation.count - 1
    actions.loading = page?.isLoading ?? false
  }
  func layoutPages() {
    if let pending = pendingDeletion, pending.0.allSatisfy({ engine.pages[$0] == nil }) {
      pendingDeletion = nil
      pending.1()
    }
    if store.state.activeTab?.peek == nil || internalPage != nil { peekPanel.hide() }
    if contentFrame.width <= 0, let bounds = engine.window?.contentView?.bounds {
      let gutter = store.state.settings.pageGutter
      let sidebar = store.state.settings.sidebarVisible ? store.state.settings.sidebarWidth : 0
      contentFrame = CGRect(
        x: sidebar + gutter, y: gutter, width: max(1, bounds.width - sidebar - 2 * gutter),
        height: max(1, bounds.height - 2 * gutter))
    }
    guard contentFrame.width > 0 else { return }
    var desired: [String: (ChromiumPage, CGRect)] = [:]
    if let internalPage, internalPage.profileID == store.activeProfileID,
      store.state.activeProfile?.isPrivate != true
    {
      desired[internalPage.id] = (internalPage, contentFrame)
    } else if let current = store.state.activeTab, !current.isClosed {
      if let group = store.split(for: current.id), let left = store.tab(group.leftTabID),
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
      } else if let page = page(for: current) {
        desired[page.id] = (page, contentFrame)
      }
      if let peek = current.peek, let url = URL(string: peek.url), let source = page(for: current) {
        let previewID = "peek:\(current.id)"
        if let existing = engine.pages[previewID],
          existing.profileID != source.profileID || existing.isPrivate != source.isPrivate
        {
          retirePage(id: previewID)
        } else if !retiringPageIDs.contains(previewID) {
          let wasLoaded = engine.pages[previewID] != nil
          let preview = engine.page(
            id: previewID, profileID: source.profileID, isPrivate: source.isPrivate, url: url)
          if !wasLoaded { preview.hide() }
          wire(preview, tabID: current.id, peek: true)
          if let previous = modelURLs[previewID], previous != peek.url {
            pendingHistory[previewID] = (preview.url?.absoluteString ?? previous, peek.url)
            preview.load(url)
          }
          modelURLs[previewID] = peek.url
          let frame = contentFrame.insetBy(dx: max(55, contentFrame.width * 0.12), dy: 36)
          peekFrames[current.id] = frame
          desired[preview.id] = (preview, frame)
        }
      }
      updateNavigationState(engine.pages[current.id])
    } else {
      updateNavigationState(nil)
    }
    // Persistent tabs keep their native document and layer attached. Only
    // actual visibility/frame changes reach Chromium, avoiding hide/show flash.
    for (id, _) in visiblePageFrames where desired[id] == nil { engine.pages[id]?.hide() }
    for (id, entry) in desired where visiblePageFrames[id] != entry.1 {
      entry.0.show(frame: entry.1)
    }
    visiblePageFrames = desired.mapValues { $0.1 }
    if let id = store.state.activeTabID, let preview = desired["peek:" + id]?.0,
      let parent = engine.window
    {
      peekPanel.show(
        parent: parent, contentFrame: contentFrame, preview: preview.browser?.nativeView?.window,
        close: { [weak self] in self?.closePeek() }, expand: { [weak self] in self?.promotePeek() })
    }
    let ids = Set(store.state.tabs.filter { !$0.isClosed }.map(\.id))
    for id in Array(engine.pages.keys) {
      if id.hasPrefix("extensions:") || id.hasPrefix("extension-store:") { continue }
      if id.hasPrefix("peek:") {
        let source = String(id.dropFirst(5))
        if !ids.contains(source) || store.tab(source)?.peek == nil { retirePage(id: id) }
      } else if !ids.contains(id) {
        retirePage(id: id)
      }
    }
  }
  func navigate(_ address: String) {
    internalPage = nil
    actions.nativePageVisible = false
    guard let url = BrowserAddress.resolve(address, engine: store.state.settings.searchEngine)
    else { return }
    if let tab = store.state.activeTab {
      let page = page(for: tab)
      pendingHistory[tab.id] = (page?.url?.absoluteString ?? tab.url, url.absoluteString)
      modelURLs[tab.id] = url.absoluteString
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
    guard let tab = store.state.activeTab, let page = page(for: tab) else { return }
    let address = forward ? store.forward(tabID: tab.id) : store.back(tabID: tab.id)
    guard let address, let url = URL(string: address) else { return }
    pendingHistory[tab.id] = (page.url?.absoluteString ?? tab.url, address)
    modelURLs[tab.id] = address
    // Restored histories contain destinations, not Chromium page-state. Until
    // a live native stack is available, load the chosen entry without appending
    // it to the model or losing the saved forward path.
    if !restoredHistoryPages.contains(tab.id), forward ? page.canGoForward : page.canGoBack {
      if forward { page.goForward() } else { page.goBack() }
    } else {
      page.load(url)
    }
  }
  func promotePeek() { if let id = store.state.activeTabID { _ = store.promotePeek(tabID: id) } }
  func closePeek() { if let id = store.state.activeTabID { store.closePeek(tabID: id) } }
  func find() {
    let alert = NSAlert()
    alert.messageText = "Find in page"
    let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: "Find")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { activePage?.find(field.stringValue) }
  }
  func applicationWillTerminate(_ notification: Notification) { store.save() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  private func handleKey(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.contains(.command) else { return false }
    let shift = event.modifierFlags.contains(.shift)
    let control = event.modifierFlags.contains(.control)
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "t":
      if shift {
        if let tab = store.restoreTab() { _ = page(for: tab) }
      } else {
        actions.openPalette()
      }
    case "l": actions.openPalette(address: store.state.activeTab?.url ?? "")
    case "s": store.updateSettings { $0.sidebarVisible.toggle() }
    case "w": activePage?.close()
    case "r": activePage?.reload()
    case "f": find()
    case "p": activePage?.printPage()
    case "d":
      if let tab = store.state.activeTab {
        store.toggleBookmark(url: tab.url, title: tab.displayTitle)
      }
    case "v" where control:
      if let text = NSPasteboard.general.string(forType: .string) { navigate(text) }
    case ",": actions.library = "Settings"
    case "=", "+": activePage?.zoom(by: 1)
    case "-": activePage?.zoom(by: -1)
    case "0": activePage?.resetZoom()
    default:
      if event.keyCode == 123 {
        goBack()
      } else if event.keyCode == 124 {
        goForward()
      } else {
        return false
      }
    }
    return true
  }
  private func installMenus() {
    let bar = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "About Zacro", action: #selector(about), keyEquivalent: "").target = self
    app.addItem(.separator())
    app.addItem(
      withTitle: "Quit Zacro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let top = NSMenuItem()
    top.submenu = app
    bar.addItem(top)
    let edit = NSMenu(title: "Edit")
    for (title, selector, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
    let editItem = NSMenuItem()
    editItem.submenu = edit
    bar.addItem(editItem)
    NSApp.mainMenu = bar
  }
  private func deleteScope(space: String?, profile: String?) {
    guard pendingDeletion == nil else { return }
    let ids = Set(
      engine.pages.values.filter { page in
        if let profile { return page.profileID == profile }
        let tabID = page.id.hasPrefix("peek:") ? String(page.id.dropFirst(5)) : page.id
        return store.tab(tabID)?.spaceID == space
      }.map(\.id))
    let completion = { [weak self] in
      if let space { self?.store.deleteSpace(id: space) }
      if let profile { self?.store.deleteProfile(id: profile) }
    }
    if ids.isEmpty {
      completion()
      return
    }
    pendingDeletion = (ids, completion)
    for id in ids { engine.close(id: id) }
  }
  private func refreshSiteControls() {
    var controls = SiteControlActions()
    controls.url = store.state.activeTab.flatMap { URL(string: $0.url) }
    controls.title = store.state.activeTab?.displayTitle ?? ""
    controls.profileName = store.state.activeProfile?.name ?? "Personal"
    controls.isPrivate = store.state.activeProfile?.isPrivate ?? false
    controls.isBookmarked = store.state.bookmarks.contains {
      $0.url == controls.url?.absoluteString && $0.profileID == store.activeProfileID
    }
    controls.zoomPercent = Int(pow(1.2, activePage?.browser?.zoomLevel ?? 0) * 100)
    controls.bookmark = { [weak self] in
      guard let self, let tab = self.store.state.activeTab else { return }
      self.store.toggleBookmark(url: tab.url, title: tab.displayTitle)
    }
    controls.printPage = { [weak self] in self?.activePage?.printPage() }
    controls.find = { [weak self] in self?.find() }
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
    internalPage =
      showStore
      ? engine.extensionStorePage(profileID: store.activeProfileID)
      : engine.extensionsPage(profileID: store.activeProfileID)
    actions.nativePageVisible = true
    scheduleLayout()
  }
  func updateIcon(_ page: ChromiumPage, tab: BrowserTab) {
    guard let pageURL = URL(string: tab.savedURL ?? tab.url) else { return }
    if let cached = favicons.cached(
      profile: page.profileID, url: pageURL, isPrivate: page.isPrivate)
    {
      actions.icons[tab.id] = cached
    }
    guard let iconURL = page.faviconURL else { return }
    favicons.load(
      profile: page.profileID, pageURL: pageURL, iconURL: iconURL, isPrivate: page.isPrivate,
      persist: tab.isPinned || tab.isFavorite
    ) { [weak self] image in self?.actions.icons[tab.id] = image }
  }
  @objc private func about() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Zacro Native", .applicationVersion: "0.11.0-dev",
    ])
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
  let coordinator: ApplicationCoordinator
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if store.state.activeTab == nil && !coordinator.actions.nativePageVisible {
          NativeThemeBackground(theme: store.state.activeSpace?.theme ?? SpaceTheme())
        } else if let id = store.state.activeTabID, store.state.activeTab?.peek != nil {
          let insetX = max(55, geometry.size.width * 0.12)
          Path { path in
            path.addRect(CGRect(origin: .zero, size: geometry.size))
            path.addRoundedRect(
              in: CGRect(
                x: insetX, y: 36, width: geometry.size.width - 2 * insetX,
                height: geometry.size.height - 72), cornerSize: CGSize(width: 12, height: 12))
          }.fill(Color.black.opacity(0.22), style: FillStyle(eoFill: true))
            .onTapGesture { store.closePeek(tabID: id) }
          VStack(spacing: 10) {
            Button {
              coordinator.closePeek()
            } label: {
              Image(systemName: "xmark")
            }
            Button {
              coordinator.promotePeek()
            } label: {
              Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
          }.buttonStyle(.plain).padding(10).background(.regularMaterial, in: Capsule())
            .position(x: geometry.size.width - insetX + 26, y: 78)
        } else if let id = store.state.activeTabID, let split = store.split(for: id) {
          Rectangle().fill(Color.clear).frame(width: 6).contentShape(Rectangle())
            .position(x: (geometry.size.width - 6) * split.ratio + 3, y: geometry.size.height / 2)
            .gesture(
              DragGesture(coordinateSpace: .named("content")).onChanged { value in
                store.setSplitRatio(
                  id: split.id, ratio: value.location.x / max(1, geometry.size.width - 6))
              }
            ).onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        } else {
          Color.clear
        }
      }.coordinateSpace(name: "content")
    }
  }
}
