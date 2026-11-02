import Foundation
import ZacroCore

/// Explicitly fires even cancelled callbacks. These checks exercise the actual
/// model/reflow authority, without synthesizing a physical drag or waiting on time.
@MainActor
enum NativeSidebarReorderAcceptance {
  @MainActor private final class Scheduler {
    var actions: [@MainActor () -> Void] = []
    var delays: [TimeInterval] = []
    var schedule: NativeSidebarDwell.Schedule {
      { [self] delay, action in
        delays.append(delay); actions.append(action)
        return {} // A callback may already be queued when cancellation occurs.
      }
    }
    func fire(_ index: Int) { if actions.indices.contains(index) { actions[index]() } }
  }

  private static func fixture() -> BrowserStore {
    var state = BrowserState()
    state.profiles = [.init(id: "profile", name: "Personal"), .init(id: "other", name: "Work")]
    state.spaces = ["a", "b", "c", "d"].map { BrowserSpace(id: $0, profileID: "profile", name: $0) }
      + [.init(id: "work", profileID: "other", name: "Work")]
    state.activeSpaceID = "b"; state.activeTabID = nil
    var favorite = BrowserTab(id: "favorite", spaceID: "a", url: "https://favorite.example/", isFavorite: true, isPinned: true)
    favorite.windowID = "window"
    var partner = BrowserTab(id: "partner", spaceID: "a", url: "https://partner.example/", isPinned: true)
    partner.windowID = "window"
    state.tabs = [favorite, partner]
    var split = SplitGroup(spaceID: "a", leftTabID: favorite.id, rightTabID: partner.id)
    split.ratio = 0.63; state.splits = [split]
    state.windowSessions = [.init(id: "window", activeSpaceID: "b"), .init(id: "other-window", activeSpaceID: "b")]
    state.focusedWindowID = "window"
    return BrowserStore(directory: URL(fileURLWithPath: "/unused-native-sidebar-acceptance"), initialState: state, memoryOnly: true)
  }

  static func check() -> [String: Bool] {
    var result: [String: Bool] = [:]
    do {
      let store = fixture(), drag = SidebarDragSession()
      drag.start("favorite", store: store)
      result["nativeDragSplitFavoriteStartsFromAnotherSpace"] = drag.id == "favorite"
        && store.split(for: "favorite")?.spaceID == "a" && store.state.activeSpaceID == "b"
      drag.project(store: store, space: "c", section: .regular, before: nil)
      result["nativeDragSplitPlaceholderIsOnlyTheAbsentDestinationRow"] =
        drag.isProjectedSplitPlaceholder("favorite", in: "c", section: .regular, store: store)
        && !drag.isProjectedSplitPlaceholder("partner", in: "c", section: .regular, store: store)
        && !drag.isProjectedSplitPlaceholder("favorite", in: "c", section: .pinned, store: store)
        && !drag.isProjectedSplitPlaceholder("favorite", in: "a", section: .regular, store: store)
        && drag.preview?.first(where: { $0.id == "favorite" })?.isPinned == false
        && store.tab("favorite")?.isPinned == true
      let committed = drag.commit(store: store, space: "c", section: .regular)
      result["nativeDragSplitFavoriteMovePreservesPairAndRatio"] = committed
        && store.split(for: "favorite")?.spaceID == "c" && store.split(for: "favorite")?.ratio == 0.63
        && store.tab("favorite")?.spaceID == "c" && store.tab("partner")?.spaceID == "c"
        && store.tab("favorite")?.isPinned == false && store.tab("favorite")?.isFavorite == false
        && store.tab("partner")?.isPinned == true && store.tab("partner")?.isFavorite == false
    }
    do {
      let store = fixture(), scheduler = Scheduler(), drag = SidebarDragSession(schedule: scheduler.schedule)
      drag.start("favorite", store: store)
      drag.scheduleHover(store: store, target: { "c" }, repeatNavigation: false)
      drag.cancel(); drag.start("favorite", store: store)
      drag.scheduleHover(store: store, target: { "d" }, repeatNavigation: false)
      scheduler.fire(0)
      let oldRejected = store.state.activeSpaceID == "b"
      scheduler.fire(1)
      result["nativeDragDwellRejectsCancelledSameTabGeneration"] = oldRejected && store.state.activeSpaceID == "d"
        && scheduler.delays == [0.55, 0.55]
    }
    let invalidations: [(String, (BrowserStore) -> Void)] = [
      ("ProfileSwitch", { $0.state.activeSpaceID = "work" }),
      ("TransferredSource", { $0.state.tabs[0].windowID = "other-window" }),
      ("DeletedTarget", { $0.state.spaces.removeAll { $0.id == "c" } }),
      ("ForeignTarget", { $0.state.spaces[$0.state.spaces.firstIndex(where: { $0.id == "c" })!].profileID = "other" }),
      ("ClosedOwner", { $0.state.windowSessions![0].isOpen = false }),
      ("RemovedSource", { $0.state.tabs.removeAll { $0.id == "favorite" } }),
      ("ChangedStartingSpace", { $0.state.activeSpaceID = "a" }),
    ]
    for (name, invalidate) in invalidations {
      let store = fixture(), scheduler = Scheduler(), drag = SidebarDragSession(schedule: scheduler.schedule)
      drag.start("favorite", store: store)
      drag.scheduleHover(store: store, target: { "c" }, repeatNavigation: false)
      invalidate(store)
      let before = store.state.activeSpaceID
      scheduler.fire(0)
      result["nativeDragDwellRejects" + name] = store.state.activeSpaceID == before
    }
    do {
      let store = fixture(), scheduler = Scheduler(), drag = SidebarDragSession(schedule: scheduler.schedule)
      drag.start("favorite", store: store)
      drag.scheduleHover(store: store, target: { "c" }, repeatNavigation: false)
      store.state.tabs[0].title = "Finished loading"; store.state.spaces[2].name = "Renamed"
      scheduler.fire(0)
      result["nativeDragDwellAllowsUnrelatedMetadataUpdates"] = store.state.activeSpaceID == "c"
    }
    do {
      let store = fixture(), scheduler = Scheduler(), drag = SidebarDragSession(schedule: scheduler.schedule)
      drag.start("favorite", store: store)
      drag.scheduleHover(store: store, target: { NativeSidebarDwell.neighbor(in: store, offset: 1) }, repeatNavigation: true)
      store.state.spaces.swapAt(2, 3)
      scheduler.fire(0)
      let freshNeighbor = store.state.activeSpaceID == "d" && scheduler.actions.count == 2
      scheduler.fire(1)
      result["nativeDragEdgeDwellUsesFreshOrderAndStopsAtBoundary"] = freshNeighbor
        && store.state.activeSpaceID == "c" && scheduler.actions.count == 2
    }
    do {
      let store = fixture(), scheduler = Scheduler(), drag = SidebarDragSession(schedule: scheduler.schedule)
      drag.start("favorite", store: store)
      drag.scheduleHover(store: store, target: { "c" }, repeatNavigation: false)
      drag.stopHover(); scheduler.fire(0)
      result["nativeDragLeavingHoverRejectsQueuedTimer"] = store.state.activeSpaceID == "b"
      drag.project(store: store, space: "b", section: .pinned, before: nil)
      drag.scheduleHover(store: store, target: { "c" }, repeatNavigation: false)
      scheduler.fire(1)
      result["nativeDragDwellClearsOldReflowAndRetainsSource"] = store.state.activeSpaceID == "c"
        && drag.id == "favorite" && drag.projectionRegionID == nil && drag.preview == store.state.tabs
    }
    do {
      let store = fixture(), drag = SidebarDragSession()
      drag.start("favorite", store: store)
      drag.project(store: store, space: "c", section: .regular, before: nil)
      store.state.tabs[0].windowID = "other-window"
      let before = store.state.tabs
      result["nativeDragDropRevalidatesSourceOwner"] = !drag.commit(store: store, space: "c", section: .regular)
        && store.state.tabs == before && drag.id == nil
    }
    return result
  }
}
