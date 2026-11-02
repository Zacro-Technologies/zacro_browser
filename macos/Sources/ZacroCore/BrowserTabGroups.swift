import Foundation

/// Chrome tab groups are window/profile-owned collections, separate from Space folders.
public struct BrowserTabGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var windowID: String
  public var profileID: String
  public var title: String
  public var color: String
  public var collapsed: Bool
  public static let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
  public init(id: String = UUID().uuidString, windowID: String, profileID: String,
              title: String = "", color: String = "grey", collapsed: Bool = false) {
    self.id = id; self.windowID = windowID; self.profileID = profileID
    self.title = title; self.color = color; self.collapsed = collapsed
  }
}

enum BrowserTabGroupState {
  private struct OrderScope: Hashable { var window: String; var profile: String }
  static func expanded(_ ids: Set<String>, in state: BrowserState) -> Set<String> {
    var result = ids
    for split in state.splits where !ids.isDisjoint(with: split.tabIDs) { result.formUnion(split.tabIDs) }
    return result
  }
  static func normalize(_ state: inout BrowserState) {
    let profiles = Set(state.profiles.map(\.id))
    let spaceProfiles = Dictionary(uniqueKeysWithValues: state.spaces.map { ($0.id, $0.profileID) })
    var seen = Set<String>()
    state.tabGroups = Array(state.tabGroups.filter { !$0.id.isEmpty && $0.id.count <= 128 &&
      !$0.windowID.isEmpty && $0.windowID.count <= 128 && profiles.contains($0.profileID) && seen.insert($0.id).inserted }.prefix(1_000))
    for index in state.tabGroups.indices {
      state.tabGroups[index].title = String(state.tabGroups[index].title.prefix(500))
      if !BrowserTabGroup.colors.contains(state.tabGroups[index].color) { state.tabGroups[index].color = "grey" }
    }
    let groups = Dictionary(uniqueKeysWithValues: state.tabGroups.map { ($0.id, $0) })
    for index in state.tabs.indices {
      let tab = state.tabs[index]
      guard let id = tab.groupID else { continue }
      guard let group = groups[id], !tab.isClosed, !tab.isPinned, !tab.isFavorite, tab.folderID == nil,
        tab.windowID == group.windowID, spaceProfiles[tab.spaceID] == group.profileID else {
        state.tabs[index].groupID = nil; continue
      }
    }
    for split in state.splits {
      let indices = state.tabs.indices.filter { split.tabIDs.contains(state.tabs[$0].id) }
      if Set(indices.map { state.tabs[$0].groupID }).count > 1 {
        for index in indices { state.tabs[index].groupID = nil }
      }
    }
    let used = Set(state.tabs.compactMap(\.groupID))
    state.tabGroups.removeAll { !used.contains($0.id) }
    // Each collection is one contiguous block in the profile's logical order.
    // Unrelated profiles and closed destinations keep their relative positions.
    let keys = Set(state.tabs.compactMap { tab -> OrderScope? in
      guard !tab.isClosed, let window = tab.windowID, let profile = spaceProfiles[tab.spaceID] else { return nil }
      return OrderScope(window: window, profile: profile)
    })
    for key in keys {
      let indices = state.tabs.indices.filter { state.tabs[$0].windowID == key.window && !state.tabs[$0].isClosed && spaceProfiles[state.tabs[$0].spaceID] == key.profile }
      let tabs = indices.map { state.tabs[$0] }
      var ordered = tabs.filter(\.isPinned), emitted = Set<String>()
      for tab in tabs where !tab.isPinned {
        if let group = tab.groupID {
          if emitted.insert(group).inserted { ordered.append(contentsOf: tabs.filter { $0.groupID == group }) }
        } else { ordered.append(tab) }
      }
      for (index, tab) in zip(indices, ordered) { state.tabs[index] = tab }
    }
  }
}

extension BrowserRepository {
  @discardableResult public func groupTabs(_ ids: [String], groupID: String? = nil,
                                          inWindowID windowID: String) throws -> BrowserTabGroup {
    try commitState { state in
      guard !ids.isEmpty, Set(ids).count == ids.count,
        state.windowSessions?.contains(where: { $0.id == windowID && $0.isOpen }) == true else {
        throw ShortcutError("Choose open tabs in one browser window.")
      }
      let selected = BrowserTabGroupState.expanded(Set(ids), in: state)
      let tabs = state.tabs.filter { selected.contains($0.id) }
      let profiles = Set(tabs.compactMap { tab in state.spaces.first { $0.id == tab.spaceID }?.profileID })
      guard tabs.count == selected.count, tabs.allSatisfy({ !$0.isClosed && $0.windowID == windowID }),
        profiles.count == 1, let profile = profiles.first else { throw ShortcutError("Group open tabs from one profile in this window.") }
      let group: BrowserTabGroup
      if let groupID {
        guard let existing = state.tabGroups.first(where: { $0.id == groupID && $0.windowID == windowID && $0.profileID == profile }) else {
          throw ShortcutError("Unknown tab group in this window.")
        }
        group = existing
      } else { group = BrowserTabGroup(windowID: windowID, profileID: profile); state.tabGroups.append(group) }
      for index in state.tabs.indices where selected.contains(state.tabs[index].id) {
        state.tabs[index].groupID = group.id; state.tabs[index].isPinned = false; state.tabs[index].isFavorite = false
        state.tabs[index].folderID = nil; state.tabs[index].savedURL = nil; state.tabs[index].savedTitle = nil
      }
      if let index = state.windowSessions?.firstIndex(where: { $0.id == windowID }) {
        state.windowSessions![index].highlightedTabIDs.subtract(selected)
        if let active = state.windowSessions![index].activeTabID { state.windowSessions![index].highlightedTabIDs.insert(active) }
      }
      BrowserTabGroupState.normalize(&state)
      return group
    }
  }
  public func ungroupTabs(_ ids: [String]) throws {
    try commitState { state in
      guard !ids.isEmpty, Set(ids).count == ids.count,
        ids.allSatisfy({ id in state.tabs.contains { $0.id == id && !$0.isClosed } }) else { throw ShortcutError("Choose open tabs to ungroup.") }
      let selected = BrowserTabGroupState.expanded(Set(ids), in: state)
      for index in state.tabs.indices where selected.contains(state.tabs[index].id) { state.tabs[index].groupID = nil }
      BrowserTabGroupState.normalize(&state)
    }
  }
  public func updateTabGroup(_ id: String, title: String? = nil, color: String? = nil, collapsed: Bool? = nil) throws {
    guard color.map(BrowserTabGroup.colors.contains) ?? true else { throw ShortcutError("Choose a supported tab group color.") }
    guard title.map({ $0.count <= 500 }) ?? true else { throw ShortcutError("Use a tab group title of up to 500 characters.") }
    try commitState { state in
      guard let index = state.tabGroups.firstIndex(where: { $0.id == id }) else { throw ShortcutError("This tab group is no longer available.") }
      if let title { state.tabGroups[index].title = title }
      if let color { state.tabGroups[index].color = color }
      if let collapsed { state.tabGroups[index].collapsed = collapsed }
    }
  }
}

extension BrowserStore {
  @discardableResult public func groupTabs(_ ids: [String], groupID: String? = nil) throws -> BrowserTabGroup {
    guard let repository else { throw ShortcutError("Tab groups require a browser window.") }
    let window = owningWindowID ?? repository.focusedWindowID
    return try repository.groupTabs(ids, groupID: groupID, inWindowID: window)
  }
  public func ungroupTabs(_ ids: [String]) throws {
    guard let repository, ids.allSatisfy({ tab($0) != nil }) else { throw ShortcutError("Choose tabs in this browser window.") }
    try repository.ungroupTabs(ids)
  }
  public func updateTabGroup(_ id: String, title: String? = nil, color: String? = nil, collapsed: Bool? = nil) throws {
    guard let repository, state.tabGroups.contains(where: { $0.id == id && (owningWindowID == nil || $0.windowID == owningWindowID) }) else {
      throw ShortcutError("This tab group is not in this window.")
    }
    try repository.updateTabGroup(id, title: title, color: color, collapsed: collapsed)
  }
}
