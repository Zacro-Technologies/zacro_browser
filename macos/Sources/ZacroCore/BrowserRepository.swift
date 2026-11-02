import Combine
import Foundation

/// One authoritative state and one persistence writer, with independent window projections.
@MainActor public final class BrowserRepository: ObservableObject {
  public let directory: URL
  private weak var canonicalFacade: BrowserStore?
  public var canonicalStore: BrowserStore {
    if let canonicalFacade { return canonicalFacade }
    let value = BrowserStore(directory: directory, initialState: writer.state, memoryOnly: true)
    value.attachRepository(self, windowID: nil)
    value.acceptRepositoryState(writer.state, error: writer.lastError)
    canonicalFacade = value
    return value
  }
  private let writer: BrowserStore
  private final class WeakStore { weak var value: BrowserStore?; init(_ value: BrowserStore) { self.value = value } }
  private var facades: [String: WeakStore] = [:]
  public var windows: [BrowserWindowSession] { writer.state.windowSessions ?? [] }
  public var focusedWindowID: String { writer.state.focusedWindowID ?? windows[0].id }
  public var defaultWindowID: String { windows.first?.id ?? "main" }
  public var focusedStore: BrowserStore { store(for: focusedWindowID)! }
  /// Preserve the live session on restart; if every window was closed, reopen
  /// the most recently parked public window instead of the oldest created one.
  public var startupWindowID: String? {
    if windows.contains(where: { $0.id == focusedWindowID && $0.isOpen }) { return focusedWindowID }
    if let open = windows.first(where: \.isOpen) { return open.id }
    return savedWindows.first?.id
      ?? windows.first(where: { $0.id == focusedWindowID })?.id
      ?? windows.first?.id
  }
  public var savedWindows: [BrowserSavedWindow] {
    windows.compactMap { window -> BrowserSavedWindow? in
      guard !window.isOpen else { return nil }
      let tabs = writer.state.tabs.filter { $0.windowID == window.id }
      guard !tabs.isEmpty, let space = writer.state.spaces.first(where: { $0.id == window.activeSpaceID }),
        let profile = writer.state.profiles.first(where: { $0.id == space.profileID && !$0.isPrivate }) else { return nil }
      let active = tabs.first { $0.id == window.activeTabID } ?? tabs.first { !$0.isClosed }
      return BrowserSavedWindow(id: window.id, title: active?.displayTitle ?? space.name,
        tabCount: tabs.filter { !$0.isClosed }.count, profileID: profile.id, profileName: profile.name, closedAt: window.closedAt)
    }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
  }

  @discardableResult public func reopenWindow(id: String, focus: Bool = true) throws -> BrowserStore {
    guard savedWindows.contains(where: { $0.id == id }), windows.filter(\.isOpen).count < 100 else {
      throw ShortcutError("Choose a saved public window and close an open window if the limit is reached.")
    }
    try commitState { state in
      guard let index = state.windowSessions?.firstIndex(where: { $0.id == id }) else { return }
      state.windowSessions![index].isOpen = true; state.windowSessions![index].closedAt = nil
      if focus { state.focusedWindowID = id }
    }
    return store(for: id)!
  }

  public init(directory: URL, initialState: BrowserState? = nil) {
    self.directory = directory
    writer = BrowserStore(directory: directory, initialState: initialState)
    writer.repair()
    var state = writer.state
    BrowserWindowState.normalize(&state, migrate: true)
    writer.state = state
    publish()
  }

  public func store(for windowID: String) -> BrowserStore? {
    guard windows.contains(where: { $0.id == windowID }) else { return nil }
    if let value = facades[windowID]?.value { return value }
    let value = BrowserStore(directory: directory, initialState: snapshot(for: windowID), memoryOnly: true)
    value.attachRepository(self, windowID: windowID)
    value.acceptRepositoryState(value.state, error: writer.lastError)
    facades[windowID] = WeakStore(value)
    return value
  }

  func snapshot(for windowID: String?) -> BrowserState { BrowserWindowState.projection(writer.state, windowID: windowID) }

  private func reducer(for windowID: String?) -> BrowserStore {
    var state = writer.state
    let context = windowID ?? focusedWindowID
    if let window = windows.first(where: { $0.id == context }) {
      state.activeSpaceID = window.activeSpaceID; state.activeTabID = window.activeTabID
      state.windowBounds = window.bounds
      state.settings.sidebarWidth = window.sidebarWidth
      state.settings.sidebarVisible = window.sidebarVisible
      state.settings.panelWidth = window.panelWidth
      for index in state.spaces.indices { state.spaces[index].lastActiveTabID = window.lastActiveTabBySpace[state.spaces[index].id] }
    }
    // The reducer uses the original single-window algorithms on fresh shared
    // collections. Window metadata is reconciled once after the operation.
    state.windowSessions = nil; state.focusedWindowID = nil
    let result = BrowserStore(directory: directory, initialState: state, memoryOnly: true)
    result.configureReduction(windowID: windowID, creationWindowID: context)
    result.visibleWindowTabIDs = Set(windows.filter(\.isOpen).compactMap(\.activeTabID))
    return result
  }

  private func result(from reducer: BrowserStore, windowID: String?) -> BrowserState {
    let previous = writer.state
    var state = reducer.state
    let context = windowID ?? focusedWindowID
    var sessions = previous.windowSessions ?? []
    if let index = sessions.firstIndex(where: { $0.id == context }) {
      if let oldActive = sessions[index].activeTabID,
        !state.tabs.contains(where: { $0.id == oldActive && !$0.isClosed }),
        let highlighted = state.tabs.first(where: { $0.windowID == context && !$0.isClosed && sessions[index].highlightedTabIDs.contains($0.id) }) {
        state.activeTabID = highlighted.id; state.activeSpaceID = highlighted.spaceID
      }
      if reducer.requestedHighlightReset { sessions[index].highlightedTabIDs.removeAll() }
      sessions[index].activeSpaceID = state.activeSpaceID
      sessions[index].activeTabID = state.activeTabID
      sessions[index].bounds = state.windowBounds
      sessions[index].sidebarVisible = state.settings.sidebarVisible
      sessions[index].sidebarWidth = state.settings.sidebarWidth
      sessions[index].panelWidth = state.settings.panelWidth
      sessions[index].lastActiveTabBySpace = Dictionary(uniqueKeysWithValues: state.spaces.compactMap { space in
        space.lastActiveTabID.map { (space.id, $0) }
      })
    }
    let previousIDs = Set(previous.tabs.map(\.id))
    for index in state.tabs.indices where !previousIDs.contains(state.tabs[index].id) {
      state.tabs[index].windowID = context
    }
    state.settings.sidebarVisible = previous.settings.sidebarVisible
    state.settings.sidebarWidth = previous.settings.sidebarWidth
    state.settings.panelWidth = previous.settings.panelWidth
    // Shared Space deletion must move every affected window to a remaining
    // Space in its own profile, not the first profile in the collection.
    for index in sessions.indices where !state.spaces.contains(where: { $0.id == sessions[index].activeSpaceID }) {
      let oldProfile = previous.spaces.first { $0.id == sessions[index].activeSpaceID }?.profileID
      if let destination = state.spaces.first(where: { $0.profileID == oldProfile }) {
        sessions[index].activeSpaceID = destination.id
      }
    }
    state.windowSessions = sessions; state.focusedWindowID = previous.focusedWindowID
    BrowserWindowState.normalize(&state, migrate: true)
    return state
  }

  func mutate<Result>(windowID: String?, _ operation: (BrowserStore) -> Result) -> Result {
    let reducer = reducer(for: windowID)
    let value = operation(reducer)
    guard windowID == nil || windows.contains(where: { $0.id == windowID }) else {
      publish(error: "This browser window is no longer available."); return value
    }
    writer.state = result(from: reducer, windowID: windowID)
    writer.save()
    publish(error: reducer.lastError ?? writer.lastError)
    return value
  }

  func mutateDurably<Result>(windowID: String?, _ operation: (BrowserStore) throws -> Result) throws -> Result {
    guard windowID == nil || windows.contains(where: { $0.id == windowID }) else { throw ShortcutError("This browser window is no longer available.") }
    let reducer = reducer(for: windowID)
    let value = try operation(reducer)
    let candidate = result(from: reducer, windowID: windowID)
    do { try writer.commit(purgeRecovery: reducer.requestedRecoveryPurge) { $0 = candidate } }
    catch { publish(); throw error }
    publish(error: reducer.lastError)
    return value
  }

  func commitState<Result>(_ operation: (inout BrowserState) throws -> Result) throws -> Result {
    var candidate = writer.state
    let result = try operation(&candidate)
    BrowserWindowState.normalize(&candidate)
    do { try writer.commit { $0 = candidate } } catch { publish(); throw error }
    publish(); return result
  }

  func save(from store: BrowserStore) {
    guard store.state == snapshot(for: store.owningWindowID) else {
      store.acceptRepositoryState(snapshot(for: store.owningWindowID), error: "The window changed outside a browser transaction. Retry the action.")
      return
    }
    writer.save(); publish()
  }
  func flush(from store: BrowserStore) throws {
    guard store.state == snapshot(for: store.owningWindowID) else {
      store.acceptRepositoryState(snapshot(for: store.owningWindowID), error: "The window changed outside a browser transaction. Retry the action.")
      throw ShortcutError("A stale window snapshot cannot replace the shared browser session.")
    }
    do { try writer.flush() } catch { publish(); throw error }
    publish()
  }
  func enableDebouncedPersistence(delay: TimeInterval) { writer.enableDebouncedPersistence(delay: delay) }
  func clearError() { writer.clearError(); publish() }
  func exportData(to url: URL) throws { try writer.exportData(to: url) }

  private func publish(error: String? = nil) {
    objectWillChange.send()
    canonicalFacade?.acceptRepositoryState(writer.state, error: error ?? writer.lastError)
    for (id, weak) in facades {
      guard let facade = weak.value else { facades.removeValue(forKey: id); continue }
      facade.acceptRepositoryState(snapshot(for: id), error: error ?? writer.lastError)
    }
  }

  @discardableResult public func makeWindow(profileID: String? = nil, movingTabIDs: [String] = [],
      addresses: [String] = [], bounds: BrowserWindowBounds? = nil,
      nativeAuthorizations: [String: NativeNavigationProvenance] = [:],
      kind: BrowserWindowKind = .normal, focus: Bool = true) throws -> BrowserStore {
    guard windows.filter(\.isOpen).count < 100 else { throw ShortcutError("Close an open window before opening more.") }
    let profile = profileID ?? writer.state.activeProfile?.id ?? writer.state.profiles[0].id
    guard let space = writer.state.spaces.first(where: { $0.profileID == profile }) else { throw ShortcutError("This profile has no Space.") }
    if movingTabIDs.isEmpty, addresses.isEmpty, !windows.contains(where: \.isOpen), kind == .normal,
       let existing = windows.first(where: { window in window.kind == .normal &&
         writer.state.spaces.contains(where: { $0.id == window.activeSpaceID && $0.profileID == profile }) }) {
      try updateWindow(existing.id) { $0.isOpen = true; $0.closedAt = nil }
      if focus { focusWindow(existing.id) }
      return store(for: existing.id)!
    }
    var session = BrowserWindowSession(activeSpaceID: space.id, kind: kind)
    if let bounds { session.bounds = bounds }
    session.sidebarVisible = writer.state.settings.sidebarVisible
    session.sidebarWidth = writer.state.settings.sidebarWidth; session.panelWidth = writer.state.settings.panelWidth
    var candidate = writer.state
    let retainedOwners = Set(candidate.tabs.compactMap(\.windowID))
    candidate.windowSessions?.removeAll { !$0.isOpen && !retainedOwners.contains($0.id) }
    let requested = addresses.isEmpty && movingTabIDs.isEmpty ? ["about:blank"] : addresses
    guard candidate.tabs.count + requested.count <= 1_000 else { throw ShortcutError("Close some tabs before opening more.") }
    let urls = try requested.map { address -> URL in
      guard let url = BrowserAddress.documentURL(address, provenance: nativeAuthorizations[address]) else { throw ShortcutError("Choose a valid web or extension address.") }
      return url
    }
    if let first = urls.first {
      for (address, url) in zip(requested, urls) {
        var tab = BrowserTab(spaceID: space.id, url: url.absoluteString, title: url.host ?? "New tab")
        tab.windowID = session.id; tab.nativeNavigation = nativeAuthorizations[address]; tab.navigation = [NavigationEntry(url: url.absoluteString, nativeNavigation: nativeAuthorizations[address])]; tab.navigationIndex = 0
        candidate.tabs.append(tab)
        if session.activeTabID == nil && url == first { session.activeTabID = tab.id }
      }
    }
    candidate.windowSessions?.append(session)
    if focus { candidate.focusedWindowID = session.id }
    if !movingTabIDs.isEmpty { try Self.move(&candidate, ids: movingTabIDs, destination: session.id, index: -1) }
    BrowserWindowState.normalize(&candidate)
    try writer.commit { $0 = candidate }; publish()
    return store(for: session.id)!
  }

  public func focusWindow(_ id: String) {
    guard windows.contains(where: { $0.id == id }) else { return }
    writer.state.focusedWindowID = id
    BrowserWindowState.applyFocusedSelection(&writer.state)
    writer.save(); publish()
  }

  public func updateWindow(_ id: String, _ edit: (inout BrowserWindowSession) -> Void) throws {
    var candidate = writer.state
    guard let index = candidate.windowSessions?.firstIndex(where: { $0.id == id }) else { throw ShortcutError("Unknown browser window.") }
    edit(&candidate.windowSessions![index])
    guard candidate.windowSessions![index].id == id else { throw ShortcutError("A browser window identity cannot change.") }
    BrowserWindowState.normalize(&candidate)
    try writer.commit { $0 = candidate }; publish()
  }

  public func selectTabs(_ ids: [String], activeID: String, inWindowID id: String, presentPeek: Bool? = nil) throws {
    guard !ids.isEmpty, Set(ids).count == ids.count, ids.contains(activeID),
      ids.allSatisfy({ value in writer.state.tabs.contains { $0.id == value && $0.windowID == id && !$0.isClosed } }),
      let active = writer.state.tabs.first(where: { $0.id == activeID }),
      let profile = writer.state.spaces.first(where: { $0.id == active.spaceID })?.profileID,
      ids.allSatisfy({ value in writer.state.tabs.first(where: { $0.id == value }).flatMap { tab in writer.state.spaces.first { $0.id == tab.spaceID } }?.profileID == profile })
    else { throw ShortcutError("Select open tabs from one profile in this window.") }
    try commitState { state in
      guard let index = state.windowSessions?.firstIndex(where: { $0.id == id }) else { throw ShortcutError("Unknown browser window.") }
      state.windowSessions![index].activeSpaceID = active.spaceID; state.windowSessions![index].activeTabID = activeID
      state.windowSessions![index].highlightedTabIDs = Set(ids); state.windowSessions![index].lastActiveTabBySpace[active.spaceID] = activeID
      if let presentPeek, let tabIndex = state.tabs.firstIndex(where: { $0.id == activeID }) {
        state.tabs[tabIndex].peek?.isPresented = presentPeek
      }
    }
  }

  public func moveTabs(_ ids: [String], toWindowID destination: String, index: Int = -1) throws {
    var candidate = writer.state
    try Self.move(&candidate, ids: ids, destination: destination, index: index)
    BrowserWindowState.normalize(&candidate)
    try writer.commit { $0 = candidate }; publish()
  }

  static func move(_ state: inout BrowserState, ids: [String], destination: String, index: Int) throws {
    guard !ids.isEmpty, Set(ids).count == ids.count, index >= -1,
      state.windowSessions?.contains(where: { $0.id == destination && $0.isOpen }) == true else { throw ShortcutError("Choose an open destination window and distinct tabs.") }
    var moving = Set(ids)
    for group in state.splits where !moving.isDisjoint(with: group.tabIDs) &&
      state.tabs.contains(where: { group.tabIDs.contains($0.id) && $0.windowID != destination }) { moving.formUnion(group.tabIDs) }
    let completeIDs = ids + state.tabs.filter { moving.contains($0.id) && !ids.contains($0.id) }.map(\.id)
    let tabs = completeIDs.compactMap { id in state.tabs.first { $0.id == id && !$0.isClosed } }
    guard tabs.count == completeIDs.count else { throw ShortcutError("A tab is no longer open.") }
    let profiles = Set(tabs.compactMap { tab in state.spaces.first { $0.id == tab.spaceID }?.profileID })
    guard profiles.count == 1 else { throw ShortcutError("Move tabs from one profile at a time.") }
    let profileID = profiles.first!
    let spaceIDs = Set(state.spaces.filter { $0.profileID == profileID }.map(\.id))
    func inDestination(_ tab: BrowserTab) -> Bool { tab.windowID == destination && !tab.isClosed && spaceIDs.contains(tab.spaceID) }
    let remaining = state.tabs.filter { !moving.contains($0.id) }
    var ordered = remaining.filter(inDestination)
    let position = index == -1 ? ordered.count : min(index, ordered.count)
    var moved = tabs
    for i in moved.indices { moved[i].windowID = destination }
    ordered.insert(contentsOf: moved, at: position)
    var output: [BrowserTab] = [], cursor = 0
    let last = remaining.lastIndex(where: inDestination)
    for (i, tab) in remaining.enumerated() {
      if inDestination(tab) { output.append(ordered[cursor]); cursor += 1 } else { output.append(tab) }
      if i == last { output.append(contentsOf: ordered.dropFirst(cursor)); cursor = ordered.count }
    }
    if last == nil { output.append(contentsOf: ordered) }
    state.tabs = output
    for groupIndex in state.tabGroups.indices {
      let group = state.tabGroups[groupIndex]
      let members = state.tabs.filter { $0.groupID == group.id }
      let movedMembers = members.filter { moving.contains($0.id) }
      guard !movedMembers.isEmpty else { continue }
      if movedMembers.count == members.count {
        state.tabGroups[groupIndex].windowID = destination
      } else if group.windowID != destination {
        for i in state.tabs.indices where moving.contains(state.tabs[i].id) && state.tabs[i].groupID == group.id { state.tabs[i].groupID = nil }
      } else {
        let order = state.tabs.filter(inDestination)
        let positions = order.indices.filter { order[$0].groupID == group.id }
        if let first = positions.first, let last = positions.last, last - first + 1 != positions.count {
          let detach = BrowserTabGroupState.expanded(Set(movedMembers.map(\.id)), in: state)
          for i in state.tabs.indices where detach.contains(state.tabs[i].id) { state.tabs[i].groupID = nil }
        }
      }
    }
    if let i = state.windowSessions?.firstIndex(where: { $0.id == destination }), state.windowSessions![i].activeTabID == nil {
      state.windowSessions![i].activeSpaceID = moved[0].spaceID
      state.windowSessions![i].activeTabID = moved[0].id
    }
  }

  /// Public sessions are parked. Private data destruction never waits for disk.
  @discardableResult public func closeWindow(_ id: String) -> [String] {
    guard let index = writer.state.windowSessions?.firstIndex(where: { $0.id == id }) else { return [] }
    writer.state.windowSessions![index].isOpen = false
    writer.state.windowSessions![index].closedAt = Date()
    if writer.state.focusedWindowID == id, let other = windows.first(where: \.isOpen) { writer.state.focusedWindowID = other.id }
    let open = Set(windows.filter(\.isOpen).map(\.id))
    let retired = writer.state.profiles.filter { profile in
      guard profile.isPrivate else { return false }
      let spaces = Set(writer.state.spaces.filter { $0.profileID == profile.id }.map(\.id))
      return !windows.contains { $0.isOpen && spaces.contains($0.activeSpaceID) } &&
        !writer.state.tabs.contains { spaces.contains($0.spaceID) && $0.windowID.map(open.contains) == true }
    }.map(\.id)
    let retiredSpaces = Set(writer.state.spaces.filter { retired.contains($0.profileID) }.map(\.id))
    writer.state.windowSessions?.removeAll { window in
      retiredSpaces.contains(window.activeSpaceID) &&
        !writer.state.tabs.contains { $0.windowID == window.id && !retiredSpaces.contains($0.spaceID) }
    }
    for profile in retired { writer.discardPrivateProfile(id: profile) }
    BrowserWindowState.normalize(&writer.state)
    writer.save(); publish()
    return retired
  }
}
