import Foundation

extension BrowserStore {
  /// Restores an archived tab, retained closed pin, or a tab from a parked
  /// window. Native identifiers and navigation grants are revalidated by the host.
  @discardableResult public func restoreSessionTabDurably(id: String) throws -> BrowserTab {
    if let repository {
      return try repository.restoreSessionTabDurably(id: id, inWindowID: owningWindowID ?? repository.focusedWindowID)
    }
    var candidate = state
    let profile = activeProfileID
    if let index = candidate.archive.firstIndex(where: { $0.id == id }) {
      guard candidate.tabs.count < 1_000, !candidate.tabs.contains(where: { $0.id == id }) else {
        throw ShortcutError("Close a tab before restoring this session.")
      }
      var tab = candidate.archive[index].tab
      guard candidate.spaces.first(where: { $0.id == tab.spaceID })?.profileID == profile else { throw ShortcutError("Restore a tab from this profile.") }
      candidate.archive.remove(at: index)
      tab.windowID = creationWindowID; tab.isClosed = false; tab.closedAt = nil; tab.openerTabID = nil
      candidate.tabs.append(tab)
    } else {
      guard let index = candidate.tabs.firstIndex(where: { $0.id == id && $0.isClosed && ($0.windowID == owningWindowID || owningWindowID == nil) }),
        candidate.spaces.first(where: { $0.id == candidate.tabs[index].spaceID })?.profileID == profile else {
        throw ShortcutError("This closed tab is no longer available.")
      }
      candidate.tabs[index].isClosed = false; candidate.tabs[index].closedAt = nil
    }
    guard let tab = candidate.tabs.first(where: { $0.id == id }) else { throw CancellationError() }
    candidate.activeSpaceID = tab.spaceID; candidate.activeTabID = id
    if let index = candidate.spaces.firstIndex(where: { $0.id == tab.spaceID }) { candidate.spaces[index].lastActiveTabID = id }
    try commit { $0 = candidate }
    return self.tab(id)!
  }
}

extension BrowserRepository {
  @discardableResult public func restoreSessionTabDurably(id: String, inWindowID destination: String) throws -> BrowserTab {
    let isPeek = id.hasPrefix("peek:")
    let sourceID = isPeek ? String(id.dropFirst(5)) : id
    return try commitState { state in
      guard let targetIndex = state.windowSessions?.firstIndex(where: { $0.id == destination && $0.isOpen }),
        let targetProfile = state.spaces.first(where: { $0.id == state.windowSessions![targetIndex].activeSpaceID })?.profileID,
        state.profiles.contains(where: { $0.id == targetProfile && !$0.isPrivate }) else {
        throw ShortcutError("Choose an open public window for this session.")
      }
      if !isPeek, let archiveIndex = state.archive.firstIndex(where: { $0.id == sourceID }) {
        guard state.tabs.count < 1_000, !state.tabs.contains(where: { $0.id == id }) else {
          throw ShortcutError("Close a tab before restoring this session.")
        }
        var tab = state.archive[archiveIndex].tab
        guard state.spaces.first(where: { $0.id == tab.spaceID })?.profileID == targetProfile else { throw ShortcutError("Restore a tab from this profile.") }
        state.archive.remove(at: archiveIndex)
        tab.windowID = destination; tab.isClosed = false; tab.closedAt = nil; tab.openerTabID = nil
        state.tabs.append(tab)
      } else {
        guard let index = state.tabs.firstIndex(where: { $0.id == sourceID }),
          state.spaces.first(where: { $0.id == state.tabs[index].spaceID })?.profileID == targetProfile else {
          throw ShortcutError("This closed tab is no longer available in this profile.")
        }
        let tab = state.tabs[index]
        let parked = state.windowSessions?.contains(where: { $0.id == tab.windowID && !$0.isOpen }) == true
        guard !isPeek || (parked && tab.peekDocument != nil) else {
          throw ShortcutError("This saved Peek is no longer available.")
        }
        guard (tab.isClosed && tab.windowID == destination) || parked else {
          throw ShortcutError("This tab already belongs to an open window.")
        }
        state.tabs[index].isClosed = false; state.tabs[index].closedAt = nil
        if tab.windowID != destination { try Self.move(&state, ids: [sourceID], destination: destination, index: -1) }
      }
      guard let tabIndex = state.tabs.firstIndex(where: { $0.id == sourceID }) else { throw CancellationError() }
      state.tabs[tabIndex].lastAccessedAt = Date()
      if isPeek { state.tabs[tabIndex].peek?.isPresented = true }
      let tab = state.tabs[tabIndex]
      state.windowSessions![targetIndex].activeSpaceID = tab.spaceID
      state.windowSessions![targetIndex].activeTabID = sourceID
      state.windowSessions![targetIndex].highlightedTabIDs = [sourceID]
      state.windowSessions![targetIndex].lastActiveTabBySpace[tab.spaceID] = sourceID
      return isPeek ? tab.peekDocument! : tab
    }
  }
}
