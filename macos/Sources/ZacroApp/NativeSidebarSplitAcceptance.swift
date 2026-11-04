import Foundation
import ZacroCore

/// Runs the context action against the real memory-only reducer. These cases
/// cover resulting selection, retained pins and persistent groups, not pixels.
@MainActor enum NativeSidebarSplitAcceptance {
  static func check() -> [String: Bool] {
    func fixture() -> BrowserStore {
      var state = BrowserState()
      state.profiles = [.init(id: "profile", name: "Fixture")]
      state.spaces = [.init(id: "space", profileID: "profile", name: "Focus"),
        .init(id: "other", profileID: "profile", name: "Other")]
      state.activeSpaceID = "space"; state.activeTabID = "active"
      state.tabs = [BrowserTab(id: "active", spaceID: "space", url: "https://active.example/"),
        BrowserTab(id: "first", spaceID: "space", url: "https://first.example/"),
        BrowserTab(id: "clicked", spaceID: "space", url: "https://clicked.example/")]
      return BrowserStore(directory: URL(fileURLWithPath: "/unused-native-sidebar-split"), initialState: state, memoryOnly: true)
    }
    func pair(_ store: BrowserStore) -> Set<String> { Set(store.split(for: "active")?.tabIDs ?? []) }
    func succeeds(_ store: BrowserStore, target: String) -> Bool {
      do { try NativeSidebarSplit.open(tabID: target, store: store); return true }
      catch { return false }
    }
    var checks: [String: Bool] = [:]
    do {
      let store = fixture()
      checks["sidebarContextSplitUsesClickedRowAndKeepsCurrentPage"] = succeeds(store, target: "clicked")
        && pair(store) == ["active", "clicked"] && store.state.activeTabID == "active"
    }
    do {
      let store = fixture()
      checks["sidebarContextSplitCurrentRowFallsBackToFirstEligiblePage"] = succeeds(store, target: "active")
        && pair(store) == ["active", "first"] && store.state.activeTabID == "active"
    }
    do {
      let store = fixture()
      store.togglePin(id: "clicked"); store.closeTab(id: "clicked")
      let wasClosed = store.tab("clicked")?.isClosed == true
      checks["sidebarContextSplitWakesRetainedPinInSameGroupMutation"] = wasClosed && succeeds(store, target: "clicked")
        && pair(store) == ["active", "clicked"] && store.tab("clicked")?.isClosed == false
        && store.tab("clicked")?.isPinned == true && store.state.activeTabID == "active"
    }
    do {
      let store = fixture()
      store.updateTab("active") { $0.url = "about:blank" }
      let before = store.state
      checks["sidebarContextSplitRejectsBlankCurrentPageWithoutSelectingClickedRow"] = !succeeds(store, target: "clicked")
        && store.state == before
    }
    do {
      let store = fixture()
      store.updateTab("first") { $0.url = "about:blank" }
      store.updateTab("clicked") { $0.spaceID = "other"; $0.isFavorite = true; $0.isPinned = true }
      let before = store.state
      checks["sidebarContextSplitRequiresSecondPageInCurrentSpace"] = !succeeds(store, target: "clicked")
        && store.state == before
    }
    do {
      let store = fixture()
      store.setSplit(left: "active", right: "first")
      if let group = store.split(for: "active") { store.setSplitRatio(id: group.id, ratio: 0.63) }
      let groups = store.state.splits
      checks["sidebarContextSplitKeepsExistingPairAndRatioUntilExplicitUnsplit"] = !succeeds(store, target: "clicked")
        && store.state.splits == groups && store.state.activeTabID == "active"
    }
    return checks
  }
}
