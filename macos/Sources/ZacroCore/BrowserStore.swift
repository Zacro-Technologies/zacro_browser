import Combine
import Foundation

@MainActor
public final class BrowserStore: ObservableObject {
  @Published public var state: BrowserState
  @Published public private(set) var lastError: String?
  public let directory: URL
  private let file: URL
  private var loadingFailed = false
  public init(directory: URL, initialState: BrowserState? = nil) {
    self.directory = directory
    file = directory.appendingPathComponent("native-state.json")
    state = initialState ?? BrowserState()
    if initialState == nil, FileManager.default.fileExists(atPath: file.path) {
      do {
        state = try JSONDecoder().decode(BrowserState.self, from: Data(contentsOf: file))
        repair()
      } catch {
        lastError =
          "Could not load the saved browser session. The original file has been preserved: \(error.localizedDescription)"
        loadingFailed = true
      }
    }
    if !state.settings.restoreSession {
      let kept = Set(state.splits.flatMap(\.tabIDs))
      state.tabs.removeAll {
        !$0.isPinned && !$0.isFavorite && $0.peek == nil && !kept.contains($0.id)
      }
      repair()
    }
  }
  public var activeProfileID: String { state.activeSpace?.profileID ?? "default" }
  public var visibleTabs: [BrowserTab] {
    state.tabs.filter { tab in
      tab.spaceID == state.activeSpaceID
        || (tab.isFavorite && profileID(for: tab) == activeProfileID)
    }
  }
  public func profileID(for tab: BrowserTab) -> String? {
    state.spaces.first { $0.id == tab.spaceID }?.profileID
  }
  public func tab(_ id: String) -> BrowserTab? { state.tabs.first { $0.id == id } }
  public func split(for tabID: String) -> SplitGroup? {
    state.splits.first { $0.tabIDs.contains(tabID) }
  }
  public func save() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if loadingFailed, FileManager.default.fileExists(atPath: file.path) {
        let preserved = directory.appendingPathComponent(
          "native-state-unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: file, to: preserved)
        loadingFailed = false
      }
      let data = try JSONEncoder().encode(persistableState())
      try data.write(to: file, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch { lastError = "Could not save the browser session: \(error.localizedDescription)" }
  }
  public func updateSettings(_ mutate: (inout BrowserSettings) -> Void) {
    mutate(&state.settings)
    repair()
    save()
  }
  public func updateTab(_ id: String, _ mutate: (inout BrowserTab) -> Void) {
    guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
    mutate(&state.tabs[index])
    save()
  }
  public func updateSpace(_ id: String, _ mutate: (inout BrowserSpace) -> Void) {
    guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
    mutate(&state.spaces[index])
    repair()
    save()
  }
  public func selectSpace(id: String) {
    guard let space = state.spaces.first(where: { $0.id == id }) else { return }
    state.activeSpaceID = id
    state.activeTabID =
      state.tabs.first(where: { $0.id == space.lastActiveTabID && !$0.isClosed })?.id
      ?? state.tabs.first(where: { $0.spaceID == id && !$0.isClosed })?.id
    save()
  }
  public func selectTab(id: String) {
    guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = state.tabs[index]
    if !tab.isFavorite || profileID(for: tab) != activeProfileID {
      state.activeSpaceID = tab.spaceID
    }
    state.activeTabID = id
    state.tabs[index].isClosed = false
    state.tabs[index].lastAccessedAt = Date()
    if let space = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }) {
      state.spaces[space].lastActiveTabID = id
    }
    save()
  }
  @discardableResult public func createTab(
    address: String = "about:blank", spaceID: String? = nil, activate: Bool = true
  ) -> BrowserTab? {
    let destination = spaceID ?? state.activeSpaceID
    guard state.spaces.contains(where: { $0.id == destination }),
      let url = BrowserAddress.resolve(address, engine: state.settings.searchEngine)
    else {
      lastError = "Enter a valid web address or search."
      return nil
    }
    var tab = BrowserTab(
      spaceID: destination, url: url.absoluteString, title: url.host ?? "New tab")
    tab.navigation = [NavigationEntry(url: url.absoluteString)]
    tab.navigationIndex = 0
    state.tabs.append(tab)
    if activate { selectTab(id: tab.id) } else { save() }
    return tab
  }
  public func closeTab(id: String) {
    guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = state.tabs[index]
    state.splits.removeAll { $0.tabIDs.contains(id) }
    if tab.isFavorite || tab.isPinned {
      state.tabs[index].isClosed = true
      state.tabs[index].peek = nil
      state.tabs[index].url = tab.savedURL ?? tab.url
      state.tabs[index].navigation = [NavigationEntry(url: state.tabs[index].url)]
      state.tabs[index].navigationIndex = 0
    } else {
      state.archive.insert(ArchivedTab(tab: tab), at: 0)
      state.tabs.remove(at: index)
    }
    if state.activeTabID == id {
      state.activeTabID =
        state.tabs.first(where: { $0.spaceID == state.activeSpaceID && !$0.isClosed })?.id
    }
    state.archive = Array(state.archive.prefix(500))
    save()
  }
  @discardableResult public func restoreTab(id: String? = nil) -> BrowserTab? {
    guard
      let index = state.archive.firstIndex(where: { entry in
        (id == nil || entry.id == id)
          && state.spaces.first(where: { space in space.id == entry.tab.spaceID })?.profileID
            == activeProfileID
      })
    else { return nil }
    var tab = state.archive.remove(at: index).tab
    if state.tabs.contains(where: { $0.id == tab.id }) { tab.id = UUID().uuidString }
    tab.isClosed = false
    state.tabs.append(tab)
    selectTab(id: tab.id)
    return tab
  }
  public func toggleFavorite(id: String) {
    guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
    state.tabs[index].isFavorite.toggle()
    state.tabs[index].isPinned = state.tabs[index].isFavorite
    state.tabs[index].savedURL = state.tabs[index].isFavorite ? state.tabs[index].url : nil
    if state.tabs[index].isClosed && !state.tabs[index].isFavorite { state.tabs.remove(at: index) }
    save()
  }
  public func togglePin(id: String) {
    guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
    state.tabs[index].isPinned.toggle()
    state.tabs[index].isFavorite = false
    state.tabs[index].savedURL = state.tabs[index].isPinned ? state.tabs[index].url : nil
    if state.tabs[index].isClosed && !state.tabs[index].isPinned { state.tabs.remove(at: index) }
    save()
  }
  public func moveTab(
    id: String, spaceID: String? = nil, folderID: String? = nil, index: Int? = nil
  ) {
    guard let tab = tab(id) else { return }
    let target = spaceID ?? tab.spaceID
    guard state.spaces.first(where: { $0.id == target })?.profileID == profileID(for: tab) else {
      lastError = "Tabs cannot move between browsing profiles."
      return
    }
    if let folderID, !state.folders.contains(where: { $0.id == folderID && $0.spaceID == target }) {
      return
    }
    let partners = split(for: id)?.tabIDs ?? [id]
    for tabID in partners {
      guard let i = state.tabs.firstIndex(where: { $0.id == tabID }) else { continue }
      state.tabs[i].spaceID = target
      state.tabs[i].folderID = folderID
      if folderID != nil {
        state.tabs[i].isPinned = true
        state.tabs[i].isFavorite = false
      }
    }
    if let splitIndex = state.splits.firstIndex(where: { $0.tabIDs.contains(id) }) {
      state.splits[splitIndex].spaceID = target
    }
    if let i = state.tabs.firstIndex(where: { $0.id == id }), let index {
      let moved = state.tabs.remove(at: i)
      state.tabs.insert(moved, at: max(0, min(index, state.tabs.count)))
    }
    if state.activeTabID == id { state.activeSpaceID = target }
    save()
  }
  public func navigate(
    tabID: String, address: String, title: String = "", recordHistory: Bool = true
  ) {
    guard let url = BrowserAddress.resolve(address, engine: state.settings.searchEngine),
      let i = state.tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let value = url.absoluteString
    state.tabs[i].url = value
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
      state.history.removeAll { $0.profileID == profile && $0.url == value }
      state.history.insert(HistoryEntry(profileID: profile, url: value, title: title), at: 0)
      state.history = Array(state.history.prefix(10_000))
    }
    save()
  }
  public func back(tabID: String) -> String? { step(tabID, offset: -1) }
  public func forward(tabID: String) -> String? { step(tabID, offset: 1) }
  private func step(_ tabID: String, offset: Int) -> String? {
    guard let i = state.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
    let destination = state.tabs[i].navigationIndex + offset
    guard state.tabs[i].navigation.indices.contains(destination) else { return nil }
    state.tabs[i].navigationIndex = destination
    state.tabs[i].url = state.tabs[i].navigation[destination].url
    state.tabs[i].title = state.tabs[i].navigation[destination].title
    save()
    return state.tabs[i].url
  }
  public func setSplit(left: String, right: String) {
    guard left != right, let lhs = tab(left), let rhs = tab(right), lhs.spaceID == rhs.spaceID,
      !lhs.isClosed, !rhs.isClosed
    else { return }
    state.splits.removeAll { $0.tabIDs.contains(left) || $0.tabIDs.contains(right) }
    state.splits.append(SplitGroup(spaceID: lhs.spaceID, leftTabID: left, rightTabID: right))
    selectTab(id: left)
  }
  public func unsplit(tabID: String) {
    state.splits.removeAll { $0.tabIDs.contains(tabID) }
    save()
  }
  public func setSplitRatio(id: String, ratio: Double) {
    guard ratio.isFinite, let i = state.splits.firstIndex(where: { $0.id == id }) else { return }
    state.splits[i].ratio = min(0.85, max(0.15, ratio))
    save()
  }
  public func setPeek(tabID: String, address: String, title: String = "") {
    guard let url = BrowserAddress.webURL(address) else { return }
    updateTab(tabID) { $0.peek = SavedPeek(url: url.absoluteString, title: title) }
  }
  public func closePeek(tabID: String) { updateTab(tabID) { $0.peek = nil } }
  @discardableResult public func promotePeek(tabID: String) -> BrowserTab? {
    guard let tab = tab(tabID), let peek = tab.peek else { return nil }
    closePeek(tabID: tabID)
    return createTab(address: peek.url, spaceID: tab.spaceID)
  }
  @discardableResult public func createSpace(name: String, profileID: String? = nil) -> BrowserSpace
  {
    let space = BrowserSpace(
      profileID: profileID ?? activeProfileID,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Space" : name)
    guard state.profiles.contains(where: { $0.id == space.profileID }) else {
      return state.spaces[0]
    }
    state.spaces.append(space)
    selectSpace(id: space.id)
    return space
  }
  public func deleteSpace(id: String) {
    guard state.spaces.count > 1, let space = state.spaces.first(where: { $0.id == id }),
      state.spaces.filter({ $0.profileID == space.profileID }).count > 1
    else { return }
    state.tabs.removeAll { $0.spaceID == id }
    state.archive.removeAll { $0.tab.spaceID == id }
    state.folders.removeAll { $0.spaceID == id }
    state.splits.removeAll { $0.spaceID == id }
    state.spaces.removeAll { $0.id == id }
    repair()
    save()
  }
  @discardableResult public func createProfile(name: String, isPrivate: Bool = false)
    -> BrowserProfile
  {
    let profile = BrowserProfile(name: name, isPrivate: isPrivate)
    state.profiles.append(profile)
    _ = createSpace(name: name, profileID: profile.id)
    return profile
  }
  public func deleteProfile(id: String) {
    guard state.profiles.contains(where: { $0.id == id }),
      state.profiles.filter({ !$0.isPrivate && $0.id != id }).count > 0
    else { return }
    state.profiles.removeAll { $0.id == id }
    state.spaces.removeAll { $0.profileID == id }
    state.history.removeAll { $0.profileID == id }
    state.bookmarks.removeAll { $0.profileID == id }
    state.downloads.removeAll { $0.profileID == id }
    repair()
    save()
  }
  @discardableResult public func createFolder(
    name: String, spaceID: String? = nil, parentID: String? = nil
  ) -> BrowserFolder {
    let folder = BrowserFolder(
      spaceID: spaceID ?? state.activeSpaceID, name: name, parentID: parentID)
    state.folders.append(folder)
    repair()
    save()
    return folder
  }
  public func updateFolder(id: String, name: String? = nil, isExpanded: Bool? = nil) {
    guard let i = state.folders.firstIndex(where: { $0.id == id }) else { return }
    if let name { state.folders[i].name = name }
    if let isExpanded { state.folders[i].isExpanded = isExpanded }
    save()
  }
  public func deleteFolder(id: String) {
    state.folders.removeAll { $0.id == id }
    for i in state.tabs.indices where state.tabs[i].folderID == id { state.tabs[i].folderID = nil }
    for i in state.folders.indices where state.folders[i].parentID == id {
      state.folders[i].parentID = nil
    }
    save()
  }
  public func toggleBookmark(url: String, title: String, profileID: String? = nil) {
    let profile = profileID ?? activeProfileID
    guard BrowserAddress.webURL(url) != nil else { return }
    if let i = state.bookmarks.firstIndex(where: { $0.url == url && $0.profileID == profile }) {
      state.bookmarks.remove(at: i)
    } else {
      state.bookmarks.append(Bookmark(profileID: profile, url: url, title: title))
    }
    save()
  }
  public func removeBookmark(id: String) {
    state.bookmarks.removeAll { $0.id == id }
    save()
  }
  public func clearHistory(profileID: String? = nil) {
    let profile = profileID ?? activeProfileID
    state.history.removeAll { $0.profileID == profile }
    for i in state.tabs.indices where self.profileID(for: state.tabs[i]) == profile {
      state.tabs[i].navigation = [
        NavigationEntry(url: state.tabs[i].url, title: state.tabs[i].title)
      ]
      state.tabs[i].navigationIndex = 0
    }
    state.archive.removeAll { self.profileID(for: $0.tab) == profile }
    save()
  }
  public func clearArchive(profileID: String? = nil) {
    let profile = profileID ?? activeProfileID
    state.archive.removeAll { self.profileID(for: $0.tab) == profile }
    save()
  }
  public func archiveStale(now: Date = Date()) {
    let splitIDs = Set(state.splits.flatMap(\.tabIDs))
    let stale = state.tabs.filter {
      !$0.isFavorite && !$0.isPinned && $0.peek == nil && !splitIDs.contains($0.id)
        && $0.id != state.activeTabID
        && now.timeIntervalSince($0.lastAccessedAt) > state.settings.archiveAfterHours * 3600
    }
    for tab in stale { closeTab(id: tab.id) }
  }
  public func recordDownload(_ record: DownloadRecord) {
    if let i = state.downloads.firstIndex(where: { $0.id == record.id }) {
      state.downloads[i] = record
    } else {
      state.downloads.insert(record, at: 0)
    }
    save()
  }
  public func exportData(to url: URL) throws {
    try JSONEncoder().encode(persistableState()).write(to: url, options: [.atomic])
  }
  public func importData(from url: URL) throws {
    let imported = try JSONDecoder().decode(BrowserState.self, from: Data(contentsOf: url))
    state = imported
    repair()
    save()
  }
  public func clearError() { lastError = nil }
  private func persistableState() -> BrowserState {
    var clean = state
    clean.profiles.removeAll(where: \.isPrivate)
    let profiles = Set(clean.profiles.map(\.id))
    clean.spaces.removeAll { !profiles.contains($0.profileID) }
    let spaces = Set(clean.spaces.map(\.id))
    clean.tabs.removeAll { !spaces.contains($0.spaceID) }
    clean.folders.removeAll { !spaces.contains($0.spaceID) }
    clean.splits.removeAll { !spaces.contains($0.spaceID) }
    clean.archive.removeAll { !spaces.contains($0.tab.spaceID) }
    clean.history.removeAll { !profiles.contains($0.profileID) }
    clean.bookmarks.removeAll { !profiles.contains($0.profileID) }
    clean.downloads.removeAll { !profiles.contains($0.profileID) }
    if !spaces.contains(clean.activeSpaceID) {
      clean.activeSpaceID = clean.spaces.first?.id ?? "home"
      clean.activeTabID = nil
    }
    return clean
  }
  public func repair() {
    state.profiles = unique(state.profiles)
    state.spaces = unique(state.spaces)
    state.tabs = unique(state.tabs)
    state.folders = unique(state.folders)
    state.bookmarks = unique(state.bookmarks)
    state.history = unique(state.history)
    state.downloads = unique(state.downloads)
    state.archive = unique(state.archive)
    state.splits = unique(state.splits)
    if state.profiles.isEmpty { state.profiles = BrowserState().profiles }
    let profiles = Set(state.profiles.map(\.id))
    state.spaces.removeAll { !profiles.contains($0.profileID) }
    if state.spaces.isEmpty {
      state.spaces = [BrowserSpace(id: "home", profileID: state.profiles[0].id, name: "Personal")]
    }
    let spaces = Set(state.spaces.map(\.id))
    state.tabs.removeAll {
      !spaces.contains($0.spaceID)
        || (BrowserAddress.webURL($0.url) == nil && $0.url != "about:blank")
    }
    state.folders.removeAll { !spaces.contains($0.spaceID) }
    state.archive.removeAll {
      !spaces.contains($0.tab.spaceID)
        || (BrowserAddress.webURL($0.tab.url) == nil && $0.tab.url != "about:blank")
    }
    state.splits.removeAll { group in
      !spaces.contains(group.spaceID) || group.leftTabID == group.rightTabID
        || group.tabIDs.contains { id in
          !state.tabs.contains { $0.id == id && $0.spaceID == group.spaceID && !$0.isClosed }
        }
    }
    var splitMembers = Set<String>()
    state.splits = state.splits.filter { group in
      guard group.tabIDs.allSatisfy({ !splitMembers.contains($0) }) else { return false }
      splitMembers.formUnion(group.tabIDs)
      return true
    }
    for i in state.splits.indices {
      state.splits[i].ratio = finiteClamp(state.splits[i].ratio, 0.15, 0.85, 0.5)
    }
    state.history.removeAll {
      !profiles.contains($0.profileID) || BrowserAddress.webURL($0.url) == nil
    }
    state.bookmarks.removeAll {
      !profiles.contains($0.profileID) || BrowserAddress.webURL($0.url) == nil
    }
    state.downloads.removeAll { !profiles.contains($0.profileID) }
    for i in state.folders.indices {
      if let parent = state.folders[i].parentID,
        parent == state.folders[i].id
          || !state.folders.contains(where: {
            $0.id == parent && $0.spaceID == state.folders[i].spaceID
          })
      {
        state.folders[i].parentID = nil
      }
    }
    for i in state.tabs.indices {
      state.tabs[i].navigation = state.tabs[i].navigation.filter {
        BrowserAddress.webURL($0.url) != nil || $0.url == "about:blank"
      }
      state.tabs[i].navigationIndex = min(
        max(-1, state.tabs[i].navigationIndex), state.tabs[i].navigation.count - 1)
      if let folderID = state.tabs[i].folderID,
        !state.folders.contains(where: { $0.id == folderID && $0.spaceID == state.tabs[i].spaceID })
      {
        state.tabs[i].folderID = nil
      }
      if let peek = state.tabs[i].peek, BrowserAddress.webURL(peek.url) == nil {
        state.tabs[i].peek = nil
      }
    }
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
    state.settings.pageGutter = finiteClamp(state.settings.pageGutter, 4, 20, 4)
    state.settings.pageRadius = finiteClamp(state.settings.pageRadius, 0, 24, 12)
    state.settings.sidebarWidth = finiteClamp(state.settings.sidebarWidth, 180, 380, 224)
    state.settings.motionScale = finiteClamp(state.settings.motionScale, 0, 2, 1)
    state.settings.archiveAfterHours = finiteClamp(state.settings.archiveAfterHours, 1, 8760, 12)
    for i in state.spaces.indices {
      state.spaces[i].theme.intensity = finiteClamp(state.spaces[i].theme.intensity, 0, 1, 0.45)
      state.spaces[i].theme.blend = finiteClamp(state.spaces[i].theme.blend, 0, 1, 0.5)
      state.spaces[i].theme.opacity = finiteClamp(state.spaces[i].theme.opacity, 0, 1, 0.85)
      state.spaces[i].theme.blur = finiteClamp(state.spaces[i].theme.blur, 0, 1, 0.5)
      state.spaces[i].theme.grain = finiteClamp(state.spaces[i].theme.grain, 0, 1, 0.08)
    }
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
