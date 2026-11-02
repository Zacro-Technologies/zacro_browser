import Foundation

extension BrowserTab {
  /// An actual live document whose persistence belongs to its source tab.
  /// This projection is never inserted into the persistent tabs collection.
  public var peekDocument: BrowserTab? {
    guard !isClosed, let peek else { return nil }
    var value = BrowserTab(id: "peek:" + id, spaceID: spaceID, url: peek.url, title: peek.title)
    value.windowID = windowID; value.openerTabID = id
    value.nativeNavigation = peek.nativeNavigation; value.muted = peek.muted
    value.autoDiscardable = peek.autoDiscardable
    value.createdAt = peek.createdAt ?? createdAt; value.lastAccessedAt = peek.lastAccessedAt ?? lastAccessedAt
    value.navigation = peek.navigation ?? [NavigationEntry(url: peek.url, title: peek.title, nativeNavigation: peek.nativeNavigation)]
    value.navigationIndex = peek.navigationIndex ?? (value.navigation.count - 1)
    return value
  }
}

extension BrowserStore {
  public func document(id: String) -> BrowserTab? {
    if id.hasPrefix("peek:") { return tab(String(id.dropFirst(5)))?.peekDocument }
    return tab(id)
  }
  public func updatePeekDurably(tabID: String, _ mutate: (inout SavedPeek) -> Void) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.updatePeekDurably(tabID: tabID, mutate) } }
    guard let source = tab(tabID), !source.isClosed, var peek = source.peek else { throw ShortcutError("This Peek is no longer available.") }
    let prior = peek
    mutate(&peek)
    guard let url = BrowserAddress.documentURL(peek.url, provenance: peek.nativeNavigation) else {
      throw ShortcutError("The Peek destination requires a matching native navigation approval.")
    }
    peek.url = url.absoluteString
    if peek.nativeNavigation?.matches(peek.url) != true { peek.nativeNavigation = nil }
    if prior.url != peek.url {
      var entries = peek.navigation ?? source.peekDocument?.navigation ?? []
      let index = peek.navigationIndex ?? (entries.count - 1)
      if !entries.indices.contains(index) || entries[index].url != peek.url {
        entries = Array((Array(entries.prefix(max(0, index + 1))) + [NavigationEntry(url: peek.url, title: peek.title, nativeNavigation: peek.nativeNavigation)]).suffix(100))
        peek.navigation = entries; peek.navigationIndex = entries.count - 1
      }
    }
    if var entries = peek.navigation, let index = peek.navigationIndex,
      entries.indices.contains(index), entries[index].url == peek.url {
      entries[index] = NavigationEntry(url: peek.url, title: peek.title, nativeNavigation: peek.nativeNavigation)
      peek.navigation = entries
    }
    try commit { state in
      if let index = state.tabs.firstIndex(where: { $0.id == tabID }) { state.tabs[index].peek = peek }
    }
  }
  public func closePeekDurably(tabID: String) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.closePeekDurably(tabID: tabID) } }
    guard tab(tabID) != nil else { throw ShortcutError("This tab is no longer available.") }
    try commit { state in
      if let index = state.tabs.firstIndex(where: { $0.id == tabID }) { state.tabs[index].peek = nil }
    }
  }
  /// Extension activation targets a particular document; normal sidebar tab
  /// activation continues to reveal its retained Peek.
  public func selectDocumentDurably(id: String) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.selectDocumentDurably(id: id) } }
    let preview = id.hasPrefix("peek:"), sourceID = preview ? String(id.dropFirst(5)) : id
    guard let source = tab(sourceID), !preview || source.peekDocument != nil else { throw ShortcutError("This document is no longer available.") }
    let spaceID = source.isFavorite && profileID(for: source) == activeProfileID ? state.activeSpaceID : source.spaceID
    try commit { state in
      guard let index = state.tabs.firstIndex(where: { $0.id == sourceID }) else { return }
      state.tabs[index].spaceID = spaceID; state.tabs[index].isClosed = false; state.tabs[index].closedAt = nil
      state.tabs[index].lastAccessedAt = Date()
      state.tabs[index].peek?.isPresented = preview
      if preview { state.tabs[index].peek?.lastAccessedAt = Date() }
      state.activeSpaceID = spaceID; state.activeTabID = sourceID
      if let space = state.spaces.firstIndex(where: { $0.id == spaceID }) { state.spaces[space].lastActiveTabID = sourceID }
    }
    requestedHighlightReset = true
  }
  @discardableResult public func promotePeekDurably(tabID: String, activate: Bool = true) throws -> BrowserTab {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.promotePeekDurably(tabID: tabID, activate: activate) } }
    guard state.tabs.count < 1_000, let source = tab(tabID), var promoted = source.peekDocument,
      BrowserAddress.documentURL(promoted.url, provenance: promoted.nativeNavigation) != nil else {
      throw ShortcutError("This Peek is no longer available, or the tab limit has been reached.")
    }
    promoted.id = UUID().uuidString; promoted.lastAccessedAt = Date()
    try commit { state in
      guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
      state.tabs[index].peek = nil
      state.tabs.insert(promoted, at: index + 1)
      for i in state.tabs.indices where state.tabs[i].openerTabID == "peek:" + tabID {
        state.tabs[i].openerTabID = promoted.id
      }
      if activate {
        state.activeSpaceID = promoted.spaceID; state.activeTabID = promoted.id
        if let space = state.spaces.firstIndex(where: { $0.id == promoted.spaceID }) { state.spaces[space].lastActiveTabID = promoted.id }
      }
    }
    if activate { requestedHighlightReset = true }
    return tab(promoted.id)!
  }
}
