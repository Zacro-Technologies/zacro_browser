import Foundation

public enum BrowserWindowKind: String, Codable, Sendable { case normal, popup }

/// Persistent logical ownership. Native window and Chromium IDs never enter the session file.
public struct BrowserWindowSession: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: BrowserWindowKind = .normal
  public var isOpen = true
  public var activeSpaceID: String
  public var activeTabID: String?
  public var highlightedTabIDs: Set<String> = []
  public var lastActiveTabBySpace: [String: String] = [:]
  public var bounds = BrowserWindowBounds()
  public var sidebarVisible = true
  public var sidebarWidth: Double = 224
  public var panelWidth: Double = 336

  public init(id: String = UUID().uuidString, activeSpaceID: String, kind: BrowserWindowKind = .normal) {
    self.id = id; self.activeSpaceID = activeSpaceID; self.kind = kind
  }
}

enum BrowserWindowState {
  static func normalize(_ state: inout BrowserState, migrate: Bool = false) {
    guard state.windowSessions != nil || migrate else { return }
    var windows = state.windowSessions ?? []
    var seen = Set<String>()
    // At most 1,000 retained tabs can own closed sessions, in addition to the
    // bounded live shells. Empty closed records are pruned by the repository.
    windows = Array(windows.filter { !$0.id.isEmpty && $0.id.count <= 128 && seen.insert($0.id).inserted }.prefix(1_100))
    if windows.isEmpty {
      var primary = BrowserWindowSession(id: "main", activeSpaceID: state.activeSpaceID)
      primary.activeTabID = state.activeTabID
      primary.bounds = state.windowBounds
      primary.sidebarVisible = state.settings.sidebarVisible
      primary.sidebarWidth = state.settings.sidebarWidth
      primary.panelWidth = state.settings.panelWidth
      primary.lastActiveTabBySpace = Dictionary(uniqueKeysWithValues: state.spaces.compactMap { space in
        space.lastActiveTabID.map { (space.id, $0) }
      })
      windows = [primary]
    }
    let ids = Set(windows.map(\.id))
    let fallback = state.focusedWindowID.flatMap { ids.contains($0) ? $0 : nil } ?? windows[0].id
    for index in state.tabs.indices where state.tabs[index].windowID.map(ids.contains) != true {
      state.tabs[index].windowID = fallback
    }
    let tabMap = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.id, $0) })
    let spaces = Dictionary(uniqueKeysWithValues: state.spaces.map { ($0.id, $0) })
    for index in windows.indices {
      var window = windows[index]
      if spaces[window.activeSpaceID] == nil { window.activeSpaceID = state.spaces.first?.id ?? "home" }
      let own = state.tabs.filter { $0.windowID == window.id && !$0.isClosed }
      let profile = spaces[window.activeSpaceID]?.profileID
      func canSelect(_ tab: BrowserTab) -> Bool {
        tab.windowID == window.id && !tab.isClosed &&
          (tab.spaceID == window.activeSpaceID || (tab.isFavorite && spaces[tab.spaceID]?.profileID == profile))
      }
      if window.activeTabID.flatMap({ tabMap[$0] }).map(canSelect) != true {
        window.activeTabID = window.lastActiveTabBySpace[window.activeSpaceID]
          .flatMap { tabMap[$0] }.flatMap { canSelect($0) ? $0.id : nil }
          ?? own.first(where: { $0.spaceID == window.activeSpaceID && !$0.isPinned })?.id
      }
      window.highlightedTabIDs = window.highlightedTabIDs.filter { id in
        guard let tab = tabMap[id] else { return false }
        return tab.windowID == window.id && !tab.isClosed && spaces[tab.spaceID]?.profileID == profile
      }
      if let active = window.activeTabID { window.highlightedTabIDs.insert(active) }
      else { window.highlightedTabIDs.removeAll() }
      window.lastActiveTabBySpace = window.lastActiveTabBySpace.filter { space, id in
        guard let target = spaces[space], let tab = tabMap[id] else { return false }
        return tab.windowID == window.id && !tab.isClosed &&
          (tab.spaceID == space || (tab.isFavorite && spaces[tab.spaceID]?.profileID == target.profileID))
      }
      if let active = window.activeTabID { window.lastActiveTabBySpace[window.activeSpaceID] = active }
      window.sidebarWidth = finite(window.sidebarWidth, 200, 380, 224)
      window.panelWidth = finite(window.panelWidth, 260, 560, 336)
      window.bounds.width = finite(window.bounds.width, 560, 7680, 1440)
      window.bounds.height = finite(window.bounds.height, 420, 4320, 940)
      if window.bounds.x?.isFinite == false { window.bounds.x = nil }
      if window.bounds.y?.isFinite == false { window.bounds.y = nil }
      windows[index] = window
    }
    // A persisted split can never join documents owned by different windows.
    state.splits.removeAll { group in
      let owners = group.tabIDs.compactMap { tabMap[$0]?.windowID }
      return owners.count != group.tabIDs.count || Set(owners).count != 1
    }
    BrowserTabGroupState.normalize(&state)
    state.windowSessions = windows
    state.focusedWindowID = fallback
    applyFocusedSelection(&state)
  }

  static func applyFocusedSelection(_ state: inout BrowserState) {
    guard let window = state.windowSessions?.first(where: { $0.id == state.focusedWindowID }) else { return }
    state.activeSpaceID = window.activeSpaceID; state.activeTabID = window.activeTabID
    state.windowBounds = window.bounds
  }

  static func projection(_ state: BrowserState, windowID: String?) -> BrowserState {
    var result = state
    guard let windowID, let window = state.windowSessions?.first(where: { $0.id == windowID }) else { return result }
    result.tabs = state.tabs.filter { $0.windowID == windowID }
    result.tabGroups = state.tabGroups.filter { $0.windowID == windowID }
    let ids = Set(result.tabs.map(\.id))
    result.splits = state.splits.filter { $0.tabIDs.allSatisfy(ids.contains) }
    result.activeSpaceID = window.activeSpaceID; result.activeTabID = window.activeTabID
    result.windowBounds = window.bounds
    result.settings.sidebarVisible = window.sidebarVisible
    result.settings.sidebarWidth = window.sidebarWidth; result.settings.panelWidth = window.panelWidth
    for index in result.spaces.indices { result.spaces[index].lastActiveTabID = window.lastActiveTabBySpace[result.spaces[index].id] }
    return result
  }

  private static func finite(_ value: Double, _ minimum: Double, _ maximum: Double, _ fallback: Double) -> Double {
    value.isFinite ? min(maximum, max(minimum, value)) : fallback
  }
}
