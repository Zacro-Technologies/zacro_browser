import AppKit
import SwiftUI
import ZacroCore

enum SidebarSection: Equatable {
  case favorite, pinned, regular
  case folder(String)
  var folderID: String? {
    if case .folder(let id) = self { return id }
    return nil
  }
  var pinned: Bool { self != .regular }
  func regionID(space: String) -> String {
    let section: String
    switch self {
    case .favorite: section = "favorites"
    case .pinned: section = "pins"
    case .regular: section = "today"
    case .folder(let id): section = "folder:" + id
    }
    return space + ":" + section
  }
}
@MainActor final class SidebarDragSession: ObservableObject {
  let native = NativeSidebarDragController()
  @Published var id: String?
  @Published var preview: [BrowserTab]?
  private let hover: NativeSidebarDwell
  private var authority: NativeSidebarDragAuthority?
  private var projectedGroupID: String?
  private var projection: Projection?
  var projectionRegionID: String? { projection.map { $0.section.regionID(space: $0.space) } }
  private struct Projection {
    let space: String
    let section: SidebarSection
    let before: String?
    let after: Bool
  }
  init(schedule: NativeSidebarDwell.Schedule? = nil) {
    hover = NativeSidebarDwell(schedule: schedule)
  }
  func start(_ id: String, store: BrowserStore) {
    cancel()
    guard let authority = NativeSidebarDragAuthority.capture(id: id, store: store) else { return }
    self.authority = authority
    self.id = id
    preview = store.state.tabs
    projectedGroupID = store.tab(id)?.groupID
  }
  func cancel() {
    hover.cancel()
    authority = nil
    id = nil
    preview = nil
    projectedGroupID = nil
    projection = nil
  }
  func resetReflow(store: BrowserStore) {
    guard id != nil else { return }
    projection = nil
    reconcile(store: store)
  }
  func reconcile(store: BrowserStore) {
    guard let id else { return }
    guard authority?.isCurrent(in: store) == true, let source = store.tab(id) else {
      cancel(); return
    }
    if let projection {
      project(store: store, space: projection.space, section: projection.section,
        before: projection.before, after: projection.after)
    } else {
      projectedGroupID = source.groupID
      preview = store.state.tabs
    }
  }
  func stopHover() {
    hover.cancel()
  }
  func scheduleHover(store: BrowserStore, target: @escaping () -> String?, repeatNavigation: Bool) {
    guard let authority, authority.isCurrent(in: store) else { stopHover(); return }
    hover.schedule(authority: authority, store: store, target: target) { [weak self, weak store] in
      guard let self, let store, self.authority == authority else { return }
      self.resetReflow(store: store)
      if repeatNavigation { self.scheduleHover(store: store, target: target, repeatNavigation: true) }
    }
  }
  func isProjectedSplitPlaceholder(_ tabID: String, in spaceID: String, section: SidebarSection, store: BrowserStore) -> Bool {
    guard id == tabID, let projection, projection.space == spaceID, projection.section == section,
      let split = store.split(for: tabID) else { return false }
    // The retained split capsule already displays its members in its own
    // Space. Only an otherwise absent destination row needs a placeholder.
    return split.spaceID != spaceID
  }
  func project(store: BrowserStore, space: String, section: SidebarSection, before: String?, after: Bool = false) {
    guard authority?.isCurrent(in: store) == true, let id, let source = store.tab(id), before != id,
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else { return }
    // Reflow is only a presentation of the latest model. A page can finish
    // loading, open another tab, or close while a native drag is in progress.
    // Reusing the previous projection would hide those changes until drop.
    projection = Projection(space: space, section: section, before: before, after: after)
    var projected = store.state.tabs
    guard let index = projected.firstIndex(where: { $0.id == id }) else { return }
    var moved = projected.remove(at: index)
    projectedGroupID = before.flatMap { store.tab($0)?.groupID }
    if section != .regular || projectedGroupID != source.groupID { moved.groupID = nil }
    moved.spaceID = space; moved.folderID = section.folderID
    moved.isFavorite = section == .favorite; moved.isPinned = section.pinned
    moved.savedURL = section.pinned ? (moved.savedURL ?? moved.url) : nil
    if !section.pinned { moved.isClosed = false }
    let destination: Int
    if let before, let target = projected.firstIndex(where: { $0.id == before }) {
      destination = target + (after ? 1 : 0)
    } else {
      let last = projected.lastIndex { tab in
        if section == .favorite { return tab.isFavorite && store.profileID(for: tab) == store.activeProfileID }
        guard tab.spaceID == space, !tab.isFavorite else { return false }
        if let folder = section.folderID { return tab.folderID == folder }
        return tab.folderID == nil && tab.isPinned == section.pinned
      }
      destination = last.map { $0 + 1 } ?? projected.count
    }
    projected.insert(moved, at: min(projected.count, destination))
    guard projected != preview else { return }
    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil
      : NativeMotion.animation(0.14, scale: store.state.settings.motionScale)) {
      preview = projected
    }
  }
  func commit(store: BrowserStore, space: String, section: SidebarSection? = nil) -> Bool {
    guard authority?.isCurrent(in: store) == true, let id, let source = store.tab(id),
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else { cancel(); return false }
    let index = section == nil ? nil : preview?.firstIndex(where: { $0.id == id })
    store.moveTab(id: id, spaceID: space, folderID: section?.folderID, index: index,
      pinned: section?.pinned, favorite: section.map { $0 == .favorite }, clearFolder: section != nil,
      clearGroup: section == .regular && source.groupID != nil && projectedGroupID != source.groupID)
    cancel(); return true
  }

}
