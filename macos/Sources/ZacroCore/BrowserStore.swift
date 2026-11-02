import Combine
import Foundation

@MainActor
public final class BrowserStore: ObservableObject {
  @Published public var state: BrowserState
  @Published public private(set) var lastError: String?
  public let directory: URL
  private let file: URL
  private let persistence: SessionPersistence
  private var loadingFailed = false
  private var autosaveDelay: TimeInterval?
  private var pendingSave: DispatchWorkItem?
  private var pendingSince: TimeInterval?
  private var saveRevision: UInt64 = 0
  private let memoryOnly: Bool
  var repository: BrowserRepository?
  public private(set) var owningWindowID: String?
  var creationWindowID: String?
  var requestedRecoveryPurge = false
  var requestedHighlightReset = false
  var visibleWindowTabIDs: Set<String> = []
  public init(directory: URL, initialState: BrowserState? = nil, memoryOnly: Bool = false) {
    self.memoryOnly = memoryOnly
    self.directory = directory
    file = directory.appendingPathComponent("native-state.json")
    persistence = SessionPersistence(file: file)
    state = initialState ?? BrowserState()
    let primaryExists = FileManager.default.fileExists(atPath: file.path)
    if initialState == nil, primaryExists || FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path) {
      do {
        state = try readState(file)
        repair()
      } catch {
        lastError = primaryExists
          ? "Could not load the saved browser session. The original file has been preserved: \(error.localizedDescription)"
          : "Could not load the saved browser session: \(error.localizedDescription)"
        loadingFailed = true
        if primaryExists { persistence.preserveUnreadablePrimary() }
        if let data = try? SessionPersistence.recoveryData(for: file), let recovered = try? readState(data) {
          state = recovered
          repair()
          lastError = "Recovered your session from its last backup."
        }
      }
    }
    if initialState == nil, !state.settings.restoreSession {
      let kept = Set(state.splits.flatMap(\.tabIDs))
      let removed = state.tabs.filter { !$0.isPinned && !$0.isFavorite && $0.peek == nil && !kept.contains($0.id) }
      state.archive.insert(contentsOf: removed.filter { tab in
        tab.url != "about:blank" && !state.profiles.contains { $0.id == profileID(for: tab) && $0.isPrivate }
      }.map { ArchivedTab(tab: $0) }, at: 0)
      state.tabs.removeAll { tab in removed.contains { $0.id == tab.id } }
      state.activeTabID = nil
      if var windows = state.windowSessions {
        for i in windows.indices {
          windows[i].activeTabID = nil
          windows[i].highlightedTabIDs.removeAll()
        }
        state.windowSessions = windows
      }
      repair()
    }
    if initialState == nil {
      func dormantAtStartup(_ id: String?) -> Bool {
        guard let selected = state.tabs.first(where: { $0.id == id }) else { return false }
        return selected.isPinned && selected.peek == nil && split(for: selected.id) == nil
      }
      if var windows = state.windowSessions {
        for i in windows.indices where dormantAtStartup(windows[i].activeTabID) {
          let window = windows[i]
          windows[i].activeTabID = state.tabs.first {
            $0.windowID == window.id && $0.spaceID == window.activeSpaceID && !$0.isPinned && !$0.isClosed
          }?.id
          windows[i].highlightedTabIDs = Set(windows[i].activeTabID.map { [$0] } ?? [])
        }
        state.windowSessions = windows
        BrowserWindowState.applyFocusedSelection(&state)
      } else if dormantAtStartup(state.activeTabID) {
        state.activeTabID = state.tabs.first { $0.spaceID == state.activeSpaceID && !$0.isPinned && !$0.isClosed }?.id
      }
    }
    if initialState == nil {
      for i in state.downloads.indices {
        state.downloads[i].canResume = nil // A live native snapshot must confirm resumability after a restart.
        if state.downloads[i].status == "completed" { state.downloads[i].status = "complete" }
        else if !["complete", "cancelled", "interrupted"].contains(state.downloads[i].status) {
          state.downloads[i].status = "interrupted"
        }
      }
    }
  }
  func attachRepository(_ repository: BrowserRepository, windowID: String?) {
    self.repository = repository; owningWindowID = windowID
  }
  func configureReduction(windowID: String?, creationWindowID: String? = nil) { owningWindowID = windowID; self.creationWindowID = creationWindowID ?? windowID }
  func acceptRepositoryState(_ value: BrowserState, error: String?) { state = value; lastError = error }
  private func owns(_ tab: BrowserTab) -> Bool { owningWindowID == nil || tab.windowID == owningWindowID }
  private var ownedTabs: [BrowserTab] { state.tabs.filter(owns) }
  public var activeProfileID: String { state.activeSpace?.profileID ?? "default" }
  public var savedWindows: [BrowserSavedWindow] { repository?.savedWindows ?? [] }
  public var visibleTabs: [BrowserTab] {
    state.tabs.filter { tab in
      owns(tab) && (tab.spaceID == state.activeSpaceID
        || (tab.isFavorite && profileID(for: tab) == activeProfileID))
    }
  }
  public func profileID(for tab: BrowserTab) -> String? {
    state.spaces.first { $0.id == tab.spaceID }?.profileID
  }
  public func tab(_ id: String) -> BrowserTab? { state.tabs.first { $0.id == id && owns($0) } }
  /// Keyboard navigation follows the same organization and split placement as the sidebar.
  public func sidebarTabs(spaceID: String? = nil) -> [BrowserTab] {
    let spaceID = spaceID ?? state.activeSpaceID
    guard let space = state.spaces.first(where: { $0.id == spaceID }) else { return [] }
    let groups = state.splits.filter { $0.spaceID == spaceID && $0.tabIDs.allSatisfy { tab($0) != nil } }
    let grouped = Set(groups.flatMap(\.tabIDs))
    let favorites = ownedTabs.filter { !grouped.contains($0.id) && $0.isFavorite && profileID(for: $0) == space.profileID }
    let tabs = ownedTabs.filter { !grouped.contains($0.id) && !$0.isFavorite && $0.spaceID == spaceID
      && ($0.isPinned || $0.folderID != nil || $0.url != "about:blank" || $0.homePage == true) }
    return favorites
      + state.folders.filter { $0.spaceID == spaceID }.flatMap { folder in tabs.filter { $0.folderID == folder.id } }
      + tabs.filter { $0.isPinned && $0.folderID == nil }
      + groups.flatMap { $0.tabIDs.compactMap(tab) }
      + tabs.filter { !$0.isPinned && $0.folderID == nil }
  }
  public func split(for tabID: String) -> SplitGroup? {
    state.splits.first { $0.tabIDs.contains(tabID) && $0.tabIDs.allSatisfy { tab($0) != nil } }
  }
  private func readState(_ url: URL) throws -> BrowserState {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 32 * 1024 * 1024 else { throw ShortcutError("Browser data exceeds its safety limit.") }
    return try readState(Data(contentsOf: url))
  }
  private func readState(_ data: Data) throws -> BrowserState {
    guard data.count <= 32 * 1024 * 1024 else { throw ShortcutError("Browser data exceeds its safety limit.") }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["version"] as? Int == 1, root["profiles"] is [[String: Any]], root["spaces"] is [[String: Any]]
    else { throw LegacyImportError.invalidState }
    var decoded = try JSONDecoder().decode(BrowserState.self, from: data)
    decoded.profiles.removeAll(where: \.isPrivate)
    guard !decoded.profiles.isEmpty else { throw LegacyImportError.invalidState }
    return decoded
  }
  public func save() {
    if let repository { repository.save(from: self); return }
    if memoryOnly { return }
    if autosaveDelay == nil {
      do { try flush() } catch { lastError = "Could not save the browser session: \(error.localizedDescription)" }
      return
    }
    pendingSave?.cancel()
    let now = ProcessInfo.processInfo.systemUptime
    pendingSince = pendingSince ?? now
    let delay = min(autosaveDelay ?? 0, max(0, 1 - (now - (pendingSince ?? now))))
    let work = DispatchWorkItem { [weak self] in self?.performAutosave() }
    pendingSave = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
  /// Opt in after loading. Defaults remain synchronous for command-line tools and migrations.
  public func enableDebouncedPersistence(delay: TimeInterval = 0.25) {
    if let repository { repository.enableDebouncedPersistence(delay: delay); return }
    if memoryOnly { return }
    autosaveDelay = min(1, max(0.01, delay.isFinite ? delay : 0.25))
  }
  private func performAutosave() {
    pendingSave = nil; pendingSince = nil; saveRevision &+= 1
    let revision = saveRevision
    persistence.write(persistableState(), purgeRecovery: false) { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, self.saveRevision == revision else { return }
        if let error { self.lastError = "Could not save the browser session: \(error)" }
      }
    }
  }
  /// Flushes the latest state after all older queued writes. Call before application termination.
  public func flush() throws {
    if let repository { try repository.flush(from: self); return }
    if memoryOnly { return }
    pendingSave?.cancel(); pendingSave = nil; pendingSince = nil; saveRevision &+= 1
    do {
      try persistence.writeSynchronously(persistableState(), purgeRecovery: false)
      loadingFailed = false
    } catch {
      lastError = "Could not save the browser session: \(error.localizedDescription)"
      throw error
    }
  }
  /// Publishes the candidate only after its complete, normalized state is durably saved.
  /// Suitable for editors that must remain open when storage is unavailable.
  public func commit(purgeRecovery: Bool = false, _ mutate: (inout BrowserState) -> Void) throws {
    if let repository { try repository.mutateDurably(windowID: owningWindowID) { try $0.commit(purgeRecovery: purgeRecovery, mutate) }; return }
    var candidate = state
    mutate(&candidate)
    let normalized = BrowserStore(directory: directory, initialState: candidate, memoryOnly: true)
    normalized.configureReduction(windowID: owningWindowID)
    normalized.repair()
    if memoryOnly { requestedRecoveryPurge = requestedRecoveryPurge || purgeRecovery; state = normalized.state; return }
    pendingSave?.cancel(); pendingSave = nil; pendingSince = nil; saveRevision &+= 1
    do {
      try persistence.writeSynchronously(normalized.persistableState(), purgeRecovery: purgeRecovery)
      loadingFailed = false; lastError = nil
      state = normalized.state
    } catch {
      lastError = "Could not save the browser session: \(error.localizedDescription)"
      if autosaveDelay != nil && !purgeRecovery { save() }
      throw error
    }
  }
  public func updateSettings(_ mutate: (inout BrowserSettings) -> Void) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.updateSettings(mutate) } }

    mutate(&state.settings)
    repair()
    save()
  }
  public func updateProfile(_ id: String, _ mutate: (inout BrowserProfile) -> Void) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.updateProfile(id, mutate) } }
    guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
    mutate(&state.profiles[index]); repair(); save()
  }
  public func updateWindowBounds(_ bounds: BrowserWindowBounds) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.updateWindowBounds(bounds) } }
    state.windowBounds = bounds; save()
  }
  public func selectTabs(_ ids: [String], activeID: String) throws {
    guard let repository else { selectTab(id: activeID); return }
    try repository.selectTabs(ids, activeID: activeID, inWindowID: owningWindowID ?? repository.focusedWindowID)
  }
  public func updateTab(_ id: String, _ mutate: (inout BrowserTab) -> Void) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.updateTab(id, mutate) } }

    guard let index = state.tabs.firstIndex(where: { $0.id == id && owns($0) }) else { return }
    mutate(&state.tabs[index])
    normalizeTabText(index)
    save()
  }
  public func updateSpace(_ id: String, _ mutate: (inout BrowserSpace) -> Void) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.updateSpace(id, mutate) } }

    guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
    mutate(&state.spaces[index])
    repair()
    save()
  }
  public func selectSpace(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.selectSpace(id: id) } }

    guard let space = state.spaces.first(where: { $0.id == id }) else { return }
    requestedHighlightReset = true
    markCurrentTabActive()
    state.activeSpaceID = id
    let remembered = ownedTabs.first { $0.id == space.lastActiveTabID && !$0.isClosed
      && ($0.spaceID == id || ($0.isFavorite && profileID(for: $0) == space.profileID)) }
    if let remembered, remembered.isFavorite, let index = state.tabs.firstIndex(where: { $0.id == remembered.id }) {
      state.tabs[index].spaceID = id
    }
    state.activeTabID = remembered?.id
      ?? ownedTabs.first(where: { $0.spaceID == id && !$0.isFavorite && !$0.isClosed })?.id
    markCurrentTabActive()
    save()
  }
  public func selectTab(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.selectTab(id: id) } }

    guard let index = state.tabs.firstIndex(where: { $0.id == id && owns($0) }) else { return }
    requestedHighlightReset = true
    let tab = state.tabs[index]
    markCurrentTabActive()
    if !tab.isFavorite || profileID(for: tab) != activeProfileID {
      state.activeSpaceID = tab.spaceID
    } else {
      state.tabs[index].spaceID = state.activeSpaceID
    }
    state.activeTabID = id
    state.tabs[index].isClosed = false
    state.tabs[index].closedAt = nil
    state.tabs[index].peek?.isPresented = true
    state.tabs[index].lastAccessedAt = Date()
    if let space = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }) {
      state.spaces[space].lastActiveTabID = id
    }
    save()
  }
  @discardableResult public func createTab(
    address: String = "about:blank", spaceID: String? = nil, activate: Bool = true
  ) -> BrowserTab? {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.createTab(address: address, spaceID: spaceID, activate: activate) } }

    guard state.tabs.count < 1_000 else { lastError = "Close some tabs before opening more."; return nil }
    let destination = spaceID ?? state.activeSpaceID
    guard state.spaces.contains(where: { $0.id == destination }),
      let url = BrowserAddress.resolve(address, engine: state.settings.searchEngine)
    else {
      lastError = "Enter a valid web address or search."
      return nil
    }
    var tab = BrowserTab(
      spaceID: destination, url: url.absoluteString, title: url.host ?? "New tab")
    tab.windowID = creationWindowID
    tab.navigation = [NavigationEntry(url: url.absoluteString)]
    tab.navigationIndex = 0
    state.tabs.append(tab)
    if activate { selectTab(id: tab.id) } else { save() }
    return tab
  }
  public func closeTab(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.closeTab(id: id) } }

    guard let index = state.tabs.firstIndex(where: { $0.id == id && owns($0) }) else { return }
    if state.activeTabID == id || state.activeTabID.flatMap({ split(for: $0) })?.tabIDs.contains(id) == true { markCurrentTabActive() }
    var tab = state.tabs[index]
    tab.peek = nil
    tab.openerTabID = nil
    state.splits.removeAll { $0.tabIDs.contains(id) }
    for i in state.tabs.indices where state.tabs[i].openerTabID == id { state.tabs[i].openerTabID = nil }
    if tab.isFavorite || tab.isPinned {
      state.tabs[index].isClosed = true
      state.tabs[index].closedAt = Date()
      state.tabs[index].peek = nil
      state.tabs[index].openerTabID = nil
      state.tabs[index].url = tab.savedURL ?? tab.url
      state.tabs[index].nativeNavigation = tab.savedURL == nil ? tab.nativeNavigation : tab.savedNativeNavigation
      state.tabs[index].navigation = [NavigationEntry(url: state.tabs[index].url, nativeNavigation: state.tabs[index].nativeNavigation)]
      state.tabs[index].navigationIndex = 0
    } else {
      if tab.url != "about:blank", !state.profiles.contains(where: { $0.id == profileID(for: tab) && $0.isPrivate }) {
        state.archive.removeAll { $0.id == tab.id }
        state.archive.insert(ArchivedTab(tab: tab), at: 0)
      }
      state.tabs.remove(at: index)
    }
    if state.activeTabID == id {
      let offset = tab.isPinned ? index + 1 : index
      state.activeTabID = state.tabs.dropFirst(offset).first { owns($0) && $0.spaceID == tab.spaceID && !$0.isPinned && !$0.isClosed }?.id
        ?? state.tabs.last { owns($0) && $0.spaceID == tab.spaceID && !$0.isPinned && !$0.isClosed }?.id
      if let space = state.spaces.firstIndex(where: { $0.id == tab.spaceID }) { state.spaces[space].lastActiveTabID = state.activeTabID }
    }
    state.archive = Array(state.archive.prefix(1_000))
    save()
  }
  @discardableResult public func createExtensionTab(url: String, title: String = "", spaceID: String? = nil, activate: Bool = true) -> BrowserTab? {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.createExtensionTab(url: url, title: title, spaceID: spaceID, activate: activate) } }

    guard let address = BrowserAddress.extensionURL(url),
      let tab = createTab(spaceID: spaceID, activate: false) else { return nil }
    updateTab(tab.id) { $0.url = address.absoluteString; $0.title = title.isEmpty ? "Extension" : String(title.prefix(500)); $0.navigation = []; $0.navigationIndex = -1 }
    if activate { selectTab(id: tab.id) }
    return self.tab(tab.id)
  }
  public func setExtensionPage(tabID: String, url: String, title: String = "") {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.setExtensionPage(tabID: tabID, url: url, title: title) } }

    guard let address = BrowserAddress.extensionURL(url) else { return }
    updateTab(tabID) { tab in
      tab.url = address.absoluteString; tab.homePage = nil
      if !title.isEmpty { tab.title = String(title.prefix(500)) }
    }
  }
  @discardableResult public func restoreTab(id: String? = nil) -> BrowserTab? {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.restoreTab(id: id) } }

    guard state.tabs.count < 1_000 else { lastError = "Close some tabs before restoring more."; return nil }
    guard
      let index = state.archive.firstIndex(where: { entry in
        (id != nil ? entry.id == id : entry.tab.spaceID == state.activeSpaceID)
          && state.spaces.first(where: { space in space.id == entry.tab.spaceID })?.profileID
            == activeProfileID
      })
    else { return nil }
    var tab = state.archive.remove(at: index).tab
    tab.windowID = creationWindowID
    if state.tabs.contains(where: { $0.id == tab.id }) { tab.id = UUID().uuidString }
    tab.isClosed = false
    tab.closedAt = nil
    tab.openerTabID = nil
    state.tabs.append(tab)
    selectTab(id: tab.id)
    return tab
  }
  public func toggleFavorite(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.toggleFavorite(id: id) } }

    guard let index = state.tabs.firstIndex(where: { $0.id == id && owns($0) }) else { return }
    let wasPinned = state.tabs[index].isPinned
    if profileID(for: state.tabs[index]) == activeProfileID { state.tabs[index].spaceID = state.activeSpaceID }
    state.tabs[index].isFavorite.toggle()
    state.tabs[index].isPinned = true
    if !wasPinned || state.tabs[index].savedURL == nil {
      state.tabs[index].savedURL = state.tabs[index].url
      state.tabs[index].savedNativeNavigation = state.tabs[index].nativeNavigation
      state.tabs[index].savedTitle = state.tabs[index].title
    }
    state.tabs[index].folderID = nil
    save()
  }
  public func togglePin(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.togglePin(id: id) } }

    guard let index = state.tabs.firstIndex(where: { $0.id == id && owns($0) }) else { return }
    if state.tabs[index].isFavorite, profileID(for: state.tabs[index]) == activeProfileID { state.tabs[index].spaceID = state.activeSpaceID }
    state.tabs[index].isPinned.toggle()
    state.tabs[index].isFavorite = false
    state.tabs[index].savedURL = state.tabs[index].isPinned ? state.tabs[index].url : nil
    state.tabs[index].savedNativeNavigation = state.tabs[index].isPinned ? state.tabs[index].nativeNavigation : nil
    state.tabs[index].savedTitle = state.tabs[index].isPinned ? state.tabs[index].title : nil
    state.tabs[index].folderID = nil
    if state.tabs[index].isClosed && !state.tabs[index].isPinned { state.tabs.remove(at: index) }
    save()
  }
  public func moveTab(
    id: String, spaceID: String? = nil, folderID: String? = nil, index: Int? = nil,
    pinned: Bool? = nil, favorite: Bool? = nil, clearFolder: Bool = false, clearGroup: Bool = false
  ) {
    if let repository {
      return repository.mutate(windowID: owningWindowID) { reducer in
        var insertion = index
        if let owner = owningWindowID, let index {
          // Drag previews index this window's projection. Resolve its remaining
          // neighbor against the fresh shared collection before reducing.
          let remaining = reducer.state.tabs.filter { $0.id != id }
          let local = remaining.filter { $0.windowID == owner }
          let position = max(0, min(index, local.count))
          if position < local.count {
            insertion = remaining.firstIndex { $0.id == local[position].id }
          } else if let last = local.last, let anchor = remaining.firstIndex(where: { $0.id == last.id }) {
            insertion = anchor + 1
          } else {
            insertion = min(reducer.state.tabs.firstIndex(where: { $0.id == id }) ?? remaining.count, remaining.count)
          }
        }
        reducer.moveTab(id: id, spaceID: spaceID, folderID: folderID, index: insertion, pinned: pinned,
          favorite: favorite, clearFolder: clearFolder, clearGroup: clearGroup)
      }
    }

    guard let source = tab(id) else { return }
    let target = spaceID ?? source.spaceID
    guard state.spaces.first(where: { $0.id == target })?.profileID == profileID(for: source) else {
      lastError = "Tabs cannot move between browsing profiles."; return
    }
    if let folderID, !state.folders.contains(where: { $0.id == folderID && $0.spaceID == target }) { return }
    if clearGroup {
      let ungrouped = BrowserTabGroupState.expanded([id], in: state)
      for i in state.tabs.indices where ungrouped.contains(state.tabs[i].id) { state.tabs[i].groupID = nil }
    }
    let group = split(for: id)
    let movingGroup = group != nil && spaceID != nil && group?.spaceID != target
    if movingGroup, let group {
      for i in state.tabs.indices where group.tabIDs.contains(state.tabs[i].id) {
        state.tabs[i].spaceID = target; state.tabs[i].folderID = nil
      }
      if let i = state.splits.firstIndex(where: { $0.id == group.id }) { state.splits[i].spaceID = target }
    }
    guard let i = state.tabs.firstIndex(where: { $0.id == id && owns($0) }) else { return }
    state.tabs[i].spaceID = target
    if clearFolder || folderID != nil || source.spaceID != target { state.tabs[i].folderID = folderID }
    let makeFavorite = favorite ?? ((folderID != nil || pinned == false || source.spaceID != target) ? false : source.isFavorite)
    let makePinned = makeFavorite || (pinned ?? (folderID != nil ? true : source.isPinned))
    if makePinned {
      if !source.isPinned || state.tabs[i].savedURL == nil { state.tabs[i].savedURL = source.url; state.tabs[i].savedNativeNavigation = source.nativeNavigation }
      if state.tabs[i].savedTitle == nil { state.tabs[i].savedTitle = source.title }
      state.tabs[i].isPinned = true; state.tabs[i].isFavorite = makeFavorite
      if makeFavorite { state.tabs[i].folderID = nil }
    } else {
      state.tabs[i].isPinned = false; state.tabs[i].isFavorite = false; state.tabs[i].folderID = nil
      state.tabs[i].savedURL = nil; state.tabs[i].savedNativeNavigation = nil; state.tabs[i].savedTitle = nil; state.tabs[i].isClosed = false
    }
    if let index {
      let moved = state.tabs.remove(at: i)
      state.tabs.insert(moved, at: max(0, min(index, state.tabs.count)))
    }
    if let active = state.activeTabID, active == id || (movingGroup && group?.tabIDs.contains(active) == true) {
      state.activeSpaceID = target
      if let i = state.spaces.firstIndex(where: { $0.id == target }) { state.spaces[i].lastActiveTabID = active }
    }
    repair(); save()
  }
  public func navigate(
    tabID: String, address: String, title: String = "", recordHistory: Bool = true
  ) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.navigate(tabID: tabID, address: address, title: title, recordHistory: recordHistory) } }

    guard let url = BrowserAddress.resolve(address, engine: state.settings.searchEngine),
      let i = state.tabs.firstIndex(where: { $0.id == tabID && owns($0) })
    else { return }
    let title = boundedText(title, limit: 500)
    let value = url.absoluteString
    state.tabs[i].url = value
    state.tabs[i].nativeNavigation = nil
    if value != "about:blank" { state.tabs[i].homePage = nil }
    if !title.isEmpty { state.tabs[i].title = title }
    let old = state.tabs[i]
    if old.navigation.indices.contains(old.navigationIndex),
      old.navigation[old.navigationIndex].url == value
    {
      if !title.isEmpty { state.tabs[i].navigation[old.navigationIndex].title = title }
    } else {
      state.tabs[i].navigation =
        Array(old.navigation.prefix(max(0, old.navigationIndex + 1))) + [
          NavigationEntry(url: value, title: title)
        ]
      state.tabs[i].navigation = Array(state.tabs[i].navigation.suffix(100))
      state.tabs[i].navigationIndex = state.tabs[i].navigation.count - 1
    }
    if recordHistory, BrowserAddress.webURL(value) != nil,
      let profile = profileID(for: state.tabs[i]),
      !state.profiles.contains(where: { $0.id == profile && $0.isPrivate })
    {
      if let recent = state.history.firstIndex(where: { $0.profileID == profile }),
        state.history[recent].url == value, Date().timeIntervalSince(state.history[recent].visitedAt) < 60 {
        if !title.isEmpty { state.history[recent].title = title }
        state.history[recent].visitedAt = Date()
      } else {
        state.history.insert(HistoryEntry(profileID: profile, url: value, title: title), at: 0)
      }
      state.history = Array(state.history.prefix(20_000))
    }
    save()
  }
  public func back(tabID: String) -> String? {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.back(tabID: tabID) } }
    return step(tabID, offset: -1)
  }
  public func forward(tabID: String) -> String? {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.forward(tabID: tabID) } }
    return step(tabID, offset: 1)
  }
  private func step(_ tabID: String, offset: Int) -> String? {
    guard let i = state.tabs.firstIndex(where: { $0.id == tabID && owns($0) }) else { return nil }
    let destination = state.tabs[i].navigationIndex + offset
    guard state.tabs[i].navigation.indices.contains(destination) else { return nil }
    state.tabs[i].navigationIndex = destination
    state.tabs[i].url = state.tabs[i].navigation[destination].url
    state.tabs[i].nativeNavigation = state.tabs[i].navigation[destination].nativeNavigation
    state.tabs[i].title = state.tabs[i].navigation[destination].title
    save()
    return state.tabs[i].url
  }
  public func setSplit(left: String, right: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.setSplit(left: left, right: right) } }

    guard left != right, let lhs = tab(left), let rhs = tab(right),
      profileID(for: lhs) == activeProfileID, profileID(for: rhs) == activeProfileID,
      (lhs.spaceID == state.activeSpaceID || lhs.isFavorite),
      (rhs.spaceID == state.activeSpaceID || rhs.isFavorite),
      !lhs.isClosed, (!rhs.isClosed || rhs.isPinned || rhs.isFavorite), lhs.url != "about:blank", rhs.url != "about:blank"
    else { return }
    if let group = state.splits.first(where: { $0.tabIDs.contains(left) || $0.tabIDs.contains(right) }) {
      if Set(group.tabIDs) != Set([left, right]) { lastError = "Unsplit these tabs before adding them to another split view." }
      return
    }
    for i in state.tabs.indices where [left, right].contains(state.tabs[i].id) {
      state.tabs[i].spaceID = state.activeSpaceID
      state.tabs[i].isClosed = false
    }
    state.splits.append(SplitGroup(spaceID: state.activeSpaceID, leftTabID: left, rightTabID: right))
    selectTab(id: left)
  }
  public func unsplit(tabID: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.unsplit(tabID: tabID) } }

    guard tab(tabID) != nil else { return }
    if state.activeTabID.flatMap({ split(for: $0) })?.tabIDs.contains(tabID) == true { markCurrentTabActive() }
    state.splits.removeAll { $0.tabIDs.contains(tabID) }
    save()
  }
  public func setSplitRatio(id: String, ratio: Double) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.setSplitRatio(id: id, ratio: ratio) } }

    guard ratio.isFinite, let i = state.splits.firstIndex(where: { $0.id == id && $0.tabIDs.allSatisfy { tab($0) != nil } }) else { return }
    state.splits[i].ratio = min(0.9, max(0.1, ratio))
    save()
  }
  public func setPeek(tabID: String, address: String, title: String = "") {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.setPeek(tabID: tabID, address: address, title: title) } }

    guard let url = BrowserAddress.webURL(address), let tab = tab(tabID), !tab.isClosed else { return }
    updateTab(tabID) { $0.peek = SavedPeek(url: url.absoluteString, title: String(title.prefix(500))) }
  }
  public func closePeek(tabID: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.closePeek(tabID: tabID) } }
 updateTab(tabID) { $0.peek = nil } }
  @discardableResult public func promotePeek(tabID: String) -> BrowserTab? {
    do { return try promotePeekDurably(tabID: tabID) }
    catch { lastError = error.localizedDescription; return nil }
  }
  @discardableResult public func createSpace(name: String, profileID: String? = nil) -> BrowserSpace
  {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.createSpace(name: name, profileID: profileID) } }

    guard state.spaces.count < 500 else { lastError = "Space limit reached."; return state.activeSpace ?? state.spaces[0] }
    let space = BrowserSpace(
      profileID: profileID ?? activeProfileID,
      name: boundedText(name, limit: 200, fallback: "New Space"))
    guard state.profiles.contains(where: { $0.id == space.profileID }) else {
      return state.spaces[0]
    }
    state.spaces.append(space)
    selectSpace(id: space.id)
    return space
  }
  public func deleteSpace(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.deleteSpace(id: id) } }

    guard state.spaces.count > 1, let space = state.spaces.first(where: { $0.id == id }),
      state.spaces.filter({ $0.profileID == space.profileID }).count > 1
    else { return }
    guard let destination = state.spaces.first(where: { $0.id != id && $0.profileID == space.profileID }) else { return }
    for i in state.tabs.indices where state.tabs[i].spaceID == id {
      state.tabs[i].spaceID = destination.id; state.tabs[i].folderID = nil
    }
    for i in state.archive.indices where state.archive[i].tab.spaceID == id {
      state.archive[i].tab.spaceID = destination.id; state.archive[i].tab.folderID = nil
    }
    for i in state.splits.indices where state.splits[i].spaceID == id { state.splits[i].spaceID = destination.id }
    state.folders.removeAll { $0.spaceID == id }
    state.spaces.removeAll { $0.id == id }
    if state.activeSpaceID == id { selectSpace(id: destination.id) }
    repair()
    save()
  }
  @discardableResult public func createProfile(name: String, isPrivate: Bool = false)
    -> BrowserProfile
  {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.createProfile(name: name, isPrivate: isPrivate) } }

    guard state.profiles.count < 100, state.spaces.count < 500 else {
      lastError = "Profile or Space limit reached."; return state.activeProfile ?? state.profiles[0]
    }
    let profile = BrowserProfile(name: boundedText(name, limit: 200, fallback: "Profile"), isPrivate: isPrivate)
    state.profiles.append(profile)
    _ = createSpace(name: name, profileID: profile.id)
    if isPrivate, let i = state.spaces.firstIndex(where: { $0.profileID == profile.id }) {
      state.spaces[i].name = "Private"; state.spaces[i].icon = "moon"; state.spaces[i].theme.primaryColor = "#69519c"; save()
    }
    return profile
  }
  @discardableResult public func createProfileDurably(name: String, isPrivate: Bool = false) throws -> BrowserProfile {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.createProfileDurably(name: name, isPrivate: isPrivate) } }

    guard state.profiles.count < 100, state.spaces.count < 500 else { throw ShortcutError("Profile or Space limit reached.") }
    let profile = BrowserProfile(name: boundedText(name, limit: 200, fallback: "Profile"), isPrivate: isPrivate)
    var space = BrowserSpace(profileID: profile.id, name: boundedText(name, limit: 200, fallback: "New Space"))
    if isPrivate { space.name = "Private"; space.icon = "moon"; space.theme.primaryColor = "#69519c" }
    let visible = visibleActivityIDs(), now = Date()
    try commit { state in
      for index in state.tabs.indices where visible.contains(state.tabs[index].id) { state.tabs[index].lastAccessedAt = now }
      state.profiles.append(profile); state.spaces.append(space)
      state.activeSpaceID = space.id; state.activeTabID = nil
    }
    return profile
  }
  public func deleteProfile(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.deleteProfile(id: id) } }

    do { try deleteProfileDurably(id: id) } catch { lastError = "Could not delete this profile: \(error.localizedDescription)" }
  }
  /// Private data is memory-only; closing its window must never depend on a
  /// successful write to the persistent profiles' directory.
  public func discardPrivateProfile(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.discardPrivateProfile(id: id) } }

    guard state.profiles.contains(where: { $0.id == id && $0.isPrivate }) else { return }
    var candidate = state
    let spaces = Set(candidate.spaces.filter { $0.profileID == id }.map(\.id))
    candidate.profiles.removeAll { $0.id == id }
    candidate.spaces.removeAll { spaces.contains($0.id) }
    candidate.tabs.removeAll { spaces.contains($0.spaceID) }
    candidate.folders.removeAll { spaces.contains($0.spaceID) }
    candidate.splits.removeAll { spaces.contains($0.spaceID) }
    candidate.archive.removeAll { spaces.contains($0.tab.spaceID) }
    candidate.history.removeAll { $0.profileID == id }
    candidate.bookmarks.removeAll { $0.profileID == id }
    candidate.downloads.removeAll { $0.profileID == id }
    candidate.permissions.removeAll { $0.profileID == id }
    let normalized = BrowserStore(directory: directory, initialState: candidate)
    normalized.repair()
    state = normalized.state
  }
  public func deleteProfileDurably(id: String) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.deleteProfileDurably(id: id) } }

    guard let profile = state.profiles.first(where: { $0.id == id }) else { return }
    guard state.profiles.contains(where: { !$0.isPrivate && $0.id != id }) else {
      throw ShortcutError("Keep at least one non-private browsing profile.")
    }
    if !profile.isPrivate {
      guard NativeProfileRetirement.validID(id) else { throw ShortcutError("This profile has an invalid native storage identifier.") }
      guard state.pendingNativeProfileRetirements.count < 1_000
        || state.pendingNativeProfileRetirements.contains(id) else {
        throw ShortcutError("Finish pending profile cleanup before deleting another profile.")
      }
    }
    try commit(purgeRecovery: true) { state in
      if !profile.isPrivate, !state.pendingNativeProfileRetirements.contains(id) {
        state.pendingNativeProfileRetirements.append(id)
      }
      state.profiles.removeAll { $0.id == id }
      state.spaces.removeAll { $0.profileID == id }
      state.history.removeAll { $0.profileID == id }
      state.bookmarks.removeAll { $0.profileID == id }
      state.downloads.removeAll { $0.profileID == id }
      state.permissions.removeAll { $0.profileID == id }
    }
  }
  @discardableResult public func createFolder(
    name: String, spaceID: String? = nil, parentID: String? = nil
  ) -> BrowserFolder {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.createFolder(name: name, spaceID: spaceID, parentID: parentID) } }

    let folder = BrowserFolder(
      spaceID: spaceID ?? state.activeSpaceID, name: boundedText(name, limit: 200, fallback: "Folder"), parentID: parentID)
    guard state.folders.count < 1_000 else { lastError = "Folder limit reached."; return folder }
    state.folders.append(folder)
    repair()
    save()
    return folder
  }
  @discardableResult public func createFolderDurably(name: String, spaceID: String? = nil, parentID: String? = nil) throws -> BrowserFolder {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.createFolderDurably(name: name, spaceID: spaceID, parentID: parentID) } }

    let spaceID = spaceID ?? state.activeSpaceID
    guard state.spaces.contains(where: { $0.id == spaceID }) else { throw ShortcutError("This Space is no longer available.") }
    guard parentID == nil || state.folders.contains(where: { $0.id == parentID && $0.spaceID == spaceID }) else {
      throw ShortcutError("The destination folder is no longer available in this Space.")
    }
    guard state.folders.count < 1_000 else { throw ShortcutError("Folder limit reached.") }
    let folder = BrowserFolder(spaceID: spaceID, name: boundedText(name, limit: 200, fallback: "Folder"), parentID: parentID)
    try commit { $0.folders.append(folder) }
    return folder
  }
  public func updateFolder(id: String, name: String? = nil, isExpanded: Bool? = nil) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.updateFolder(id: id, name: name, isExpanded: isExpanded) } }

    guard let i = state.folders.firstIndex(where: { $0.id == id }) else { return }
    if let name { state.folders[i].name = boundedText(name, limit: 200, fallback: "Folder") }
    if let isExpanded { state.folders[i].isExpanded = isExpanded }
    save()
  }
  public func deleteFolder(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.deleteFolder(id: id) } }

    state.folders.removeAll { $0.id == id }
    for i in state.tabs.indices where state.tabs[i].folderID == id { state.tabs[i].folderID = nil }
    for i in state.archive.indices where state.archive[i].tab.folderID == id { state.archive[i].tab.folderID = nil }
    for i in state.folders.indices where state.folders[i].parentID == id {
      state.folders[i].parentID = nil
    }
    save()
  }
  public func toggleBookmark(url: String, title: String, profileID: String? = nil) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.toggleBookmark(url: url, title: title, profileID: profileID) } }

    let profile = profileID ?? activeProfileID
    guard state.profiles.contains(where: { $0.id == profile }), let address = BrowserAddress.webURL(url) else { return }
    let url = address.absoluteString
    if let i = state.bookmarks.firstIndex(where: { $0.url == url && $0.profileID == profile }) {
      state.bookmarks.remove(at: i)
    } else {
      state.bookmarks.insert(Bookmark(profileID: profile, url: url, title: boundedText(title, limit: 500, fallback: url)), at: 0)
    }
    save()
  }
  public func removeBookmark(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.removeBookmark(id: id) } }

    state.bookmarks.removeAll { $0.id == id }
    save()
  }
  public func clearHistory(profileID: String? = nil) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.clearHistory(profileID: profileID) } }

    do { try clearHistoryDurably(profileID: profileID) } catch { lastError = "Could not clear history: \(error.localizedDescription)" }
  }
  public func clearHistoryDurably(profileID: String? = nil) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.clearHistoryDurably(profileID: profileID) } }

    let profile = profileID ?? activeProfileID
    let spaces = Set(state.spaces.filter { $0.profileID == profile }.map(\.id))
    try commit(purgeRecovery: true) { state in
      state.history.removeAll { $0.profileID == profile }
      for i in state.tabs.indices where spaces.contains(state.tabs[i].spaceID) {
        state.tabs[i].navigation = [NavigationEntry(url: state.tabs[i].url, title: state.tabs[i].title, nativeNavigation: state.tabs[i].nativeNavigation)]
        state.tabs[i].navigationIndex = 0
        if let peek = state.tabs[i].peek {
          state.tabs[i].peek?.navigation = [NavigationEntry(url: peek.url, title: peek.title, nativeNavigation: peek.nativeNavigation)]
          state.tabs[i].peek?.navigationIndex = 0
        }
      }
      for i in state.archive.indices where spaces.contains(state.archive[i].tab.spaceID) {
        state.archive[i].tab.navigation = [NavigationEntry(url: state.archive[i].tab.url, title: state.archive[i].tab.title, nativeNavigation: state.archive[i].tab.nativeNavigation)]
        state.archive[i].tab.navigationIndex = 0
      }
    }
  }
  public func clearArchive(profileID: String? = nil) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.clearArchive(profileID: profileID) } }

    do { try clearArchiveDurably(profileID: profileID) } catch { lastError = "Could not clear archived tabs: \(error.localizedDescription)" }
  }
  public func clearArchiveDurably(profileID: String? = nil) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.clearArchiveDurably(profileID: profileID) } }

    let profile = profileID ?? activeProfileID
    let spaces = Set(state.spaces.filter { $0.profileID == profile }.map(\.id))
    try commit(purgeRecovery: true) { $0.archive.removeAll { spaces.contains($0.tab.spaceID) } }
  }
  /// The runtime excludes pages with active media, downloads, pending beforeunload,
  /// form edits, capture, opener relationships, or other engine-owned activity.
  public func archiveCandidates(now: Date = Date(), excludeIDs: Set<String> = []) -> [BrowserTab] {
    let splitIDs = Set(state.splits.flatMap(\.tabIDs))
    let selected = Set((state.windowSessions ?? []).filter(\.isOpen).compactMap(\.activeTabID))
    return ownedTabs.filter {
      !$0.isFavorite && !$0.isPinned && $0.folderID == nil && $0.peek == nil && !splitIDs.contains($0.id)
        && $0.id != state.activeTabID && !selected.contains($0.id) && !visibleWindowTabIDs.contains($0.id) && !excludeIDs.contains($0.id)
        && archiveHours(profileID: profileID(for: $0) ?? "") > 0
        && now.timeIntervalSince($0.lastAccessedAt) >= archiveHours(profileID: profileID(for: $0) ?? "") * 3600
    }
  }
  public func archiveStale(now: Date = Date(), excludeIDs: Set<String> = []) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.archiveStale(now: now, excludeIDs: excludeIDs) } }

    for tab in archiveCandidates(now: now, excludeIDs: excludeIDs) { closeTab(id: tab.id) }
  }
  public func recordDownload(_ record: DownloadRecord) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.recordDownload(record) } }

    if let i = state.downloads.firstIndex(where: { $0.id == record.id }) {
      state.downloads[i] = record
    } else {
      state.downloads.insert(record, at: 0)
    }
    state.downloads = DownloadCollection.ordered(state.downloads)
    save()
  }
  public func clearError() { if let repository { repository.clearError(); return }; lastError = nil }
  public static let archiveCadences: [Double] = [0, 1, 6, 12, 24, 48, 72, 168, 720]
  private func markCurrentTabActive() {
    markVisibleTabActivity(now: Date())
  }
  private func markVisibleTabActivity(now: Date) {
    let ids = visibleActivityIDs()
    for i in state.tabs.indices where ids.contains(state.tabs[i].id) { state.tabs[i].lastAccessedAt = now }
  }
  private func visibleActivityIDs() -> Set<String> {
    guard let active = state.activeTabID else { return [] }
    let group = state.splits.first { $0.spaceID == state.activeSpaceID && $0.tabIDs.contains(active) }
    return Set(group?.tabIDs ?? [active])
  }
  public func recordVisibleTabActivity(now: Date = Date()) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.recordVisibleTabActivity(now: now) } }

    markVisibleTabActivity(now: now); save()
  }
  public func archiveHours(profileID: String) -> Double {
    state.profiles.first(where: { $0.id == profileID })?.archiveAfterHours ?? state.settings.archiveAfterHours
  }
  public func setArchiveHours(profileID: String, hours: Double?) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.setArchiveHours(profileID: profileID, hours: hours) } }

    guard let i = state.profiles.firstIndex(where: { $0.id == profileID }),
      hours.map(Self.archiveCadences.contains) ?? true else { return }
    let defaultProfile = state.profiles.first(where: { $0.id == "default" && !$0.isPrivate })
      ?? state.profiles.first(where: { !$0.isPrivate })
    if defaultProfile?.id == profileID {
      if let hours { state.settings.archiveAfterHours = hours }
      state.profiles[i].archiveAfterHours = nil
    } else { state.profiles[i].archiveAfterHours = hours }
    save()
  }
  public func updateShortcut(id: String, accelerator: String) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.updateShortcut(id: id, accelerator: accelerator) } }

    let overrides = try BrowserShortcut.updating(state.settings.shortcutOverrides, id: id, accelerator: accelerator)
    try commit { $0.settings.shortcutOverrides = overrides }
  }
  public func resetShortcut(id: String? = nil) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.resetShortcut(id: id) } }

    if let id, let entry = BrowserShortcut.defaults.first(where: { $0.id == id }) {
      try updateShortcut(id: id, accelerator: entry.accelerator)
    } else if id == nil { try commit { $0.settings.shortcutOverrides = [:] } }
  }
  public func setSiteSearches(_ engines: [SiteSearchEngine]) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.setSiteSearches(engines) } }

    for engine in engines { if let error = engine.validationError { throw ShortcutError(error) } }
    let normalized = SiteSearchEngine.normalized(engines)
    guard normalized.count == engines.count else { throw ShortcutError("Choose unique keywords for up to 20 site searches.") }
    try commit { $0.settings.siteSearches = normalized }
  }
  public func replacePinnedDestination(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.replacePinnedDestination(id: id) } }

    guard let tab = tab(id), tab.isPinned || tab.isFavorite else { return }
    updateTab(id) { $0.savedURL = $0.url; $0.savedTitle = $0.title; $0.savedNativeNavigation = $0.nativeNavigation }
  }
  public func resetPinnedDestination(id: String) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.resetPinnedDestination(id: id) } }

    guard let tab = tab(id), tab.isPinned || tab.isFavorite else { return }
    updateTab(id) {
      if let saved = $0.savedURL { $0.url = saved; $0.nativeNavigation = $0.savedNativeNavigation }
    }
  }
  @discardableResult public func duplicateTab(id: String) -> BrowserTab? {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.duplicateTab(id: id) } }

    guard let tab = tab(id) else { return nil }
    if let proof = tab.nativeNavigation, proof.matches(tab.url) {
      guard let created = createTab(spaceID: tab.spaceID) else { return nil }
      updateTab(created.id) {
        $0.url = tab.url; $0.title = tab.title; $0.nativeNavigation = proof
        $0.navigation = [NavigationEntry(url: tab.url, title: tab.title, nativeNavigation: proof)]; $0.navigationIndex = 0
      }
      return self.tab(created.id)
    }
    let duplicate = BrowserAddress.extensionURL(tab.url) == nil
      ? createTab(address: tab.url, spaceID: tab.spaceID)
      : createExtensionTab(url: tab.url, title: tab.title, spaceID: tab.spaceID)
    guard let created = duplicate else { return nil }
    if tab.homePage == true { updateTab(created.id) { $0.homePage = true } }
    return self.tab(created.id)
  }
  public func setPermission(profileID: String, origin: String, permission: String, allowed: Bool) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.setPermission(profileID: profileID, origin: origin, permission: permission, allowed: allowed) } }

    guard state.profiles.contains(where: { $0.id == profileID }), let origin = BrowserAddress.webOrigin(origin),
      !permission.isEmpty, permission.count <= 80
    else { return }
    state.permissions.removeAll { $0.profileID == profileID && $0.origin == origin && $0.permission == permission }
    state.permissions.append(.init(profileID: profileID, origin: origin, permission: permission, allowed: allowed))
    save()
  }
  public func clearPermissions(profileID: String? = nil) {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.clearPermissions(profileID: profileID) } }

    do { try clearPermissionsDurably(profileID: profileID) } catch { lastError = "Could not reset site permissions: \(error.localizedDescription)" }
  }
  public func clearPermissionsDurably(profileID: String? = nil) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.clearPermissionsDurably(profileID: profileID) } }

    let profile = profileID ?? activeProfileID
    try commit(purgeRecovery: true) { $0.permissions.removeAll { $0.profileID == profile } }
  }
  public func removePermissionDurably(id: String) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.removePermissionDurably(id: id) } }

    try commit(purgeRecovery: true) { $0.permissions.removeAll { $0.id == id } }
  }
  public func savedPermission(profileID: String, origin: String, permission: String) -> Bool? {
    guard let origin = BrowserAddress.webOrigin(origin) else { return nil }
    return state.permissions.first { $0.profileID == profileID && $0.origin == origin && $0.permission == permission }?.allowed
  }
  private func persistableState() -> BrowserState {
    var clean = state
    clean.profiles.removeAll(where: \.isPrivate)
    let profiles = Set(clean.profiles.map(\.id))
    clean.spaces.removeAll { !profiles.contains($0.profileID) }
    let spaces = Set(clean.spaces.map(\.id))
    clean.tabs.removeAll { !spaces.contains($0.spaceID) }
    clean.folders.removeAll { !spaces.contains($0.spaceID) }
    clean.splits.removeAll { !spaces.contains($0.spaceID) }
    clean.tabGroups.removeAll { !profiles.contains($0.profileID) }
    clean.archive.removeAll { !spaces.contains($0.tab.spaceID) }
    clean.history.removeAll { !profiles.contains($0.profileID) }
    clean.bookmarks.removeAll { !profiles.contains($0.profileID) }
    clean.bookmarkImportAcknowledgements.removeAll { !profiles.contains($0.profileID) }
    clean.downloads.removeAll { !profiles.contains($0.profileID) }
    clean.permissions.removeAll { !profiles.contains($0.profileID) }
    if !spaces.contains(clean.activeSpaceID) {
      clean.activeSpaceID = clean.spaces.first?.id ?? "home"
      clean.activeTabID = nil
    }
    if clean.windowSessions != nil {
      let publicTabs = Set(clean.tabs.map(\.id))
      let privateSpaces = Set(state.spaces.filter { !profiles.contains($0.profileID) }.map(\.id))
      clean.windowSessions?.removeAll { window in
        privateSpaces.contains(window.activeSpaceID) && !clean.tabs.contains { $0.windowID == window.id }
      }
      for i in clean.windowSessions!.indices {
        clean.windowSessions![i].highlightedTabIDs = clean.windowSessions![i].highlightedTabIDs.intersection(publicTabs)
        clean.windowSessions![i].lastActiveTabBySpace = clean.windowSessions![i].lastActiveTabBySpace.filter { spaces.contains($0.key) && publicTabs.contains($0.value) }
      }
      BrowserWindowState.normalize(&clean, migrate: true)
    }
    return clean
  }
  public func repair() {
    if let repository { return repository.mutate(windowID: owningWindowID) { $0.repair() } }

    state.profiles = Array(unique(state.profiles).prefix(100))
    state.spaces = Array(unique(state.spaces).prefix(500))
    state.tabs = Array(unique(state.tabs).prefix(1_000))
    state.folders = Array(unique(state.folders).prefix(1_000))
    state.bookmarks = Array(unique(state.bookmarks).prefix(20_000))
    state.history = Array(unique(state.history).prefix(20_000))
    state.downloads = unique(state.downloads)
    state.archive = Array(unique(state.archive).prefix(1_000))
    state.splits = unique(state.splits)
    if state.profiles.isEmpty { state.profiles = BrowserState().profiles }
    let profiles = Set(state.profiles.map(\.id))
    state.spaces.removeAll { !profiles.contains($0.profileID) }
    for profile in state.profiles where !state.spaces.contains(where: { $0.profileID == profile.id }) {
      state.spaces.append(BrowserSpace(profileID: profile.id, name: profile.name))
    }
    let spaces = Set(state.spaces.map(\.id))
    state.tabs.removeAll {
      !spaces.contains($0.spaceID)
        || BrowserAddress.documentURL($0.url, provenance: $0.nativeNavigation) == nil
    }
    let spaceProfiles = Dictionary(uniqueKeysWithValues: state.spaces.map { ($0.id,$0.profileID) })
    var openTabs = Dictionary(uniqueKeysWithValues: state.tabs.filter { !$0.isClosed }.map { ($0.id,$0) })
    for tab in state.tabs {
      if let preview = tab.peekDocument, BrowserAddress.documentURL(preview.url, provenance: preview.nativeNavigation) != nil {
        openTabs[preview.id] = preview
      }
    }
    for i in state.tabs.indices {
      guard let openerID = state.tabs[i].openerTabID else { continue }
      if state.tabs[i].isClosed || openerID == state.tabs[i].id || openTabs[openerID] == nil ||
          openTabs[openerID].flatMap({ spaceProfiles[$0.spaceID] }) != spaceProfiles[state.tabs[i].spaceID] {
        state.tabs[i].openerTabID = nil
      }
    }
    state.folders.removeAll { !spaces.contains($0.spaceID) }
    state.archive.removeAll {
      !spaces.contains($0.tab.spaceID)
        || BrowserAddress.documentURL($0.tab.url, provenance: $0.tab.nativeNavigation) == nil
    }
    state.splits.removeAll { group in
      !spaces.contains(group.spaceID) || group.leftTabID == group.rightTabID
        || group.tabIDs.contains { id in
          !state.tabs.contains { tab in tab.id == id && !tab.isClosed
            && profileID(for: tab) == state.spaces.first(where: { $0.id == group.spaceID })?.profileID
            && (tab.spaceID == group.spaceID || tab.isFavorite) }
        }
    }
    var splitMembers = Set<String>()
    state.splits = state.splits.filter { group in
      guard group.tabIDs.allSatisfy({ !splitMembers.contains($0) }) else { return false }
      splitMembers.formUnion(group.tabIDs)
      return true
    }
    for i in state.splits.indices {
      state.splits[i].ratio = finiteClamp(state.splits[i].ratio, 0.1, 0.9, 0.5)
    }
    state.history.removeAll {
      !profiles.contains($0.profileID) || BrowserAddress.webURL($0.url) == nil
    }
    state.bookmarks.removeAll {
      !profiles.contains($0.profileID) || BrowserAddress.webURL($0.url) == nil
    }
    let publicProfiles = Set(state.profiles.filter { !$0.isPrivate }.map(\.id))
    state.bookmarkImportAcknowledgements = Array(state.bookmarkImportAcknowledgements.filter {
      publicProfiles.contains($0.profileID) && !$0.logicalID.isEmpty && $0.logicalID.count <= 128 && UUID(uuidString: $0.uuid) != nil
    }.prefix(20_000))
    for i in state.history.indices {
      state.history[i].url = BrowserAddress.webURL(state.history[i].url)!.absoluteString
      state.history[i].title = boundedText(state.history[i].title, limit: 500, fallback: state.history[i].url)
    }
    for i in state.bookmarks.indices {
      state.bookmarks[i].url = BrowserAddress.webURL(state.bookmarks[i].url)!.absoluteString
      state.bookmarks[i].title = boundedText(state.bookmarks[i].title, limit: 500, fallback: state.bookmarks[i].url)
    }
    state.downloads.removeAll { !profiles.contains($0.profileID) }
    for i in state.downloads.indices {
      if let guid = state.downloads[i].nativeGUID, UUID(uuidString: guid) == nil { state.downloads[i].nativeGUID = nil }
    }
    state.downloads = DownloadCollection.ordered(state.downloads)
    var permissionIDs = Set<String>()
    state.permissions = Array(state.permissions.compactMap { permission in
      guard profiles.contains(permission.profileID), let origin = BrowserAddress.webOrigin(permission.origin),
        !permission.permission.isEmpty, permission.permission.count <= 80 else { return nil }
      var permission = permission; permission.origin = origin
      return permissionIDs.insert(permission.id).inserted ? permission : nil
    }.prefix(2_000))
    for i in state.folders.indices {
      var visited: Set<String> = [state.folders[i].id]
      var ancestor = state.folders[i].parentID
      while let id = ancestor {
        if !visited.insert(id).inserted { state.folders[i].parentID = nil; break }
        ancestor = state.folders.first(where: { $0.id == id })?.parentID
      }
      if let parent = state.folders[i].parentID,
        parent == state.folders[i].id
          || !state.folders.contains(where: {
            $0.id == parent && $0.spaceID == state.folders[i].spaceID
          })
      {
        state.folders[i].parentID = nil
      }
    }
    for i in state.tabs.indices { var tab = state.tabs[i]; repairTab(&tab); state.tabs[i] = tab }
    for i in state.archive.indices { var tab = state.archive[i].tab; repairTab(&tab); tab.peek = nil; tab.openerTabID = nil; state.archive[i].tab = tab }
    if !spaces.contains(state.activeSpaceID) {
      state.activeSpaceID = state.spaces[0].id
      state.activeTabID = nil
    }
    if let id = state.activeTabID,
      !state.tabs.contains(where: {
        $0.id == id && !$0.isClosed
          && ($0.spaceID == state.activeSpaceID
            || ($0.isFavorite && profileID(for: $0) == activeProfileID))
      })
    {
      state.activeTabID = nil
    }
    state.settings.pageGutter = finiteClamp(state.settings.pageGutter, 4, 20, 4).rounded()
    state.settings.pageRadius = finiteClamp(state.settings.pageRadius, 0, 20, 12).rounded()
    state.settings.sidebarWidth = finiteClamp(state.settings.sidebarWidth, 200, 380, 224).rounded()
    state.settings.panelWidth = finiteClamp(state.settings.panelWidth, 260, 560, 336).rounded()
    state.settings.motionScale = (finiteClamp(state.settings.motionScale, 0.7, 1.4, 1) * 100).rounded() / 100
    if !Self.archiveCadences.contains(state.settings.archiveAfterHours) { state.settings.archiveAfterHours = 12 }
    state.settings.siteSearches = SiteSearchEngine.normalized(state.settings.siteSearches)
    state.settings.shortcutOverrides = BrowserShortcut.sanitized(state.settings.shortcutOverrides)
    state.settings.openSourcesLimit = min(10, max(1, state.settings.openSourcesLimit))
    if ![0, 5, 10, 20, 30, 60, 120].contains(state.settings.pinnedSleepMinutes) { state.settings.pinnedSleepMinutes = 20 }
    if !["comfortable", "compact"].contains(state.settings.tabDensity) { state.settings.tabDensity = "comfortable" }
    if !["system", "light", "dark"].contains(state.settings.appearance) { state.settings.appearance = "system" }
    if !["codex", "claude-code", "openai", "anthropic", "compatible", "openrouter"].contains(state.settings.aiProvider) { state.settings.aiProvider = "codex" }
    if !state.settings.aiModel.isEmpty && state.settings.aiModel.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,159}$", options: .regularExpression) == nil { state.settings.aiModel = "" }
    state.windowBounds.width = finiteClamp(state.windowBounds.width, 560, 7680, 1440)
    state.windowBounds.height = finiteClamp(state.windowBounds.height, 420, 4320, 940)
    if state.windowBounds.x?.isFinite != true { state.windowBounds.x = nil }
    if state.windowBounds.y?.isFinite != true { state.windowBounds.y = nil }
    if state.windowBounds.sizeKind != "window" { state.windowBounds.sizeKind = "content" }
    for i in state.profiles.indices {
      state.profiles[i].name = boundedText(state.profiles[i].name, limit: 200, fallback: "Profile")
      if let cadence = state.profiles[i].archiveAfterHours, !Self.archiveCadences.contains(cadence) { state.profiles[i].archiveAfterHours = nil }
      var seen = Set<String>()
      state.profiles[i].pinnedExtensionIDs = Array(state.profiles[i].pinnedExtensionIDs.filter {
        $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil && seen.insert($0).inserted
      }.prefix(256))
    }
    if let i = state.profiles.firstIndex(where: { $0.id == "default" && !$0.isPrivate }) ?? state.profiles.firstIndex(where: { !$0.isPrivate }),
      let cadence = state.profiles[i].archiveAfterHours {
      state.settings.archiveAfterHours = cadence
      state.profiles[i].archiveAfterHours = nil
    }
    for i in state.folders.indices { state.folders[i].name = boundedText(state.folders[i].name, limit: 200, fallback: "Folder") }
    for i in state.spaces.indices {
      state.spaces[i].name = boundedText(state.spaces[i].name, limit: 200, fallback: "Space")
      if let last = state.spaces[i].lastActiveTabID,
        !state.tabs.contains(where: { $0.id == last && ($0.spaceID == state.spaces[i].id || ($0.isFavorite && profileID(for: $0) == state.spaces[i].profileID)) }) {
        state.spaces[i].lastActiveTabID = nil
      }
      if state.spaces[i].theme.primaryColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { state.spaces[i].theme.primaryColor = SpaceTheme().primaryColor }
      if state.spaces[i].theme.secondaryColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { state.spaces[i].theme.secondaryColor = SpaceTheme().secondaryColor }
      if !["system", "light", "dark"].contains(state.spaces[i].theme.appearance) { state.spaces[i].theme.appearance = "system" }
      state.spaces[i].theme.intensity = finiteClamp(state.spaces[i].theme.intensity, 0, 1, 0)
      state.spaces[i].theme.blend = finiteClamp(state.spaces[i].theme.blend, 0, 1, 0.5)
      state.spaces[i].theme.opacity = finiteClamp(state.spaces[i].theme.opacity, 0, 1, 1)
      state.spaces[i].theme.blur = finiteClamp(state.spaces[i].theme.blur, 0, 1, 0)
      state.spaces[i].theme.grain = finiteClamp(state.spaces[i].theme.grain, 0, 1, 0)
    }
    BrowserWindowState.normalize(&state)
    BrowserTabGroupState.normalize(&state)
  }
  private func boundedText(_ value: String, limit: Int, fallback: String = "") -> String {
    let clean = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    return clean.isEmpty ? fallback : clean
  }
  private func normalizeTabText(_ index: Int) {
    state.tabs[index].title = boundedText(state.tabs[index].title, limit: 500, fallback: "New tab")
    state.tabs[index].customTitle = state.tabs[index].customTitle.flatMap { let value = boundedText($0, limit: 500); return value.isEmpty ? nil : value }
    state.tabs[index].savedTitle = state.tabs[index].savedTitle.map { boundedText($0, limit: 500) }
    if let peek = state.tabs[index].peek { state.tabs[index].peek?.title = boundedText(peek.title, limit: 500) }
  }
  func repairTab(_ tab: inout BrowserTab) {
    if !tab.isClosed || tab.closedAt?.timeIntervalSince1970.isFinite == false { tab.closedAt = nil }
    if let url = BrowserAddress.documentURL(tab.url, provenance: tab.nativeNavigation) { tab.url = url.absoluteString }
    if tab.nativeNavigation?.matches(tab.url) != true { tab.nativeNavigation = nil }
    tab.savedURL = tab.savedURL.flatMap { BrowserAddress.documentURL($0, provenance: tab.savedNativeNavigation)?.absoluteString }
    if tab.savedURL.map({ tab.savedNativeNavigation?.matches($0) == true }) != true { tab.savedNativeNavigation = nil }
    if let folder = tab.folderID, !state.folders.contains(where: { $0.id == folder && $0.spaceID == tab.spaceID }) { tab.folderID = nil }
    if tab.isFavorite { tab.folderID = nil; tab.isPinned = true }
    if tab.folderID != nil { tab.isPinned = true }
    tab.title = boundedText(tab.title, limit: 500, fallback: "New tab")
    tab.customTitle = tab.customTitle.flatMap { let value = boundedText($0, limit: 500); return value.isEmpty ? nil : value }
    if tab.isPinned {
      if tab.savedURL.flatMap({ BrowserAddress.documentURL($0, provenance: tab.savedNativeNavigation) }) == nil { tab.savedURL = tab.url; tab.savedNativeNavigation = tab.nativeNavigation }
      tab.savedTitle = boundedText(tab.savedTitle ?? tab.title, limit: 500, fallback: tab.title)
    } else { tab.savedURL = nil; tab.savedNativeNavigation = nil; tab.savedTitle = nil; tab.isClosed = false }
    if tab.isClosed || tab.peek.map({ BrowserAddress.documentURL($0.url, provenance: $0.nativeNavigation) == nil }) == true { tab.peek = nil }
    else if var peek = tab.peek, var preview = tab.peekDocument {
      repairTab(&preview)
      peek.url = preview.url; peek.title = preview.title; peek.nativeNavigation = preview.nativeNavigation
      peek.navigation = preview.navigation; peek.navigationIndex = preview.navigationIndex
      if peek.createdAt?.timeIntervalSince1970.isFinite == false { peek.createdAt = nil }
      if peek.lastAccessedAt?.timeIntervalSince1970.isFinite == false { peek.lastAccessedAt = nil }
      tab.peek = peek
    }
    let originalIndex = tab.navigationIndex
    var entries: [NavigationEntry] = []
    var currentIndex: Int?
    if !tab.isClosed, tab.navigation.indices.contains(originalIndex) {
      let start = max(0, originalIndex - 49), end = min(tab.navigation.count, max(0, originalIndex - 49) + 100)
      for index in start..<end {
        let entry = tab.navigation[index]
        guard let url = BrowserAddress.documentURL(entry.url, provenance: entry.nativeNavigation)?.absoluteString else { continue }
        if index == originalIndex, url == tab.url { currentIndex = entries.count }
        entries.append(.init(url: url, title: boundedText(entry.title, limit: 500), nativeNavigation: entry.nativeNavigation?.matches(url) == true ? entry.nativeNavigation : nil))
      }
    }
    if let currentIndex { tab.navigation = entries; tab.navigationIndex = currentIndex }
    else { tab.navigation = [.init(url: tab.url, title: tab.title, nativeNavigation: tab.nativeNavigation)]; tab.navigationIndex = 0 }
  }
  private func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
    var seen = Set<String>()
    return values.filter {
      !$0.id.isEmpty && $0.id.count <= 128
        && $0.id.unicodeScalars.allSatisfy {
          CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
          ).contains($0)
        } && seen.insert($0.id).inserted
    }
  }
  private func finiteClamp(_ value: Double, _ lower: Double, _ upper: Double, _ fallback: Double)
    -> Double
  { value.isFinite ? min(upper, max(lower, value)) : fallback }
}
