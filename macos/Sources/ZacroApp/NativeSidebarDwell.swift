import Foundation
import ZacroCore

/// Captured at the actual drag start, independent of re-rendered row values.
/// Ordinary metadata changes remain valid; a different profile or owner does not.
@MainActor
struct NativeSidebarDragAuthority: Equatable {
  let tabID: String
  let profileID: String
  let windowID: String?

  static func capture(id: String, store: BrowserStore) -> Self? {
    guard let tab = store.tab(id), store.profileID(for: tab) == store.activeProfileID else { return nil }
    let value = Self(tabID: id, profileID: store.activeProfileID, windowID: store.owningWindowID ?? tab.windowID)
    return value.isCurrent(in: store) ? value : nil
  }

  func isCurrent(in store: BrowserStore) -> Bool {
    guard store.activeProfileID == profileID, let tab = store.tab(tabID),
      store.profileID(for: tab) == profileID, tab.windowID == windowID,
      store.owningWindowID == nil || store.owningWindowID == windowID else { return false }
    if let windowID {
      return store.state.windowSessions?.contains { $0.id == windowID && $0.isOpen } == true
    }
    return true
  }
}

/// A cancelled DispatchWorkItem may already be queued. Generation and model
/// validation therefore authorize the navigation, rather than timer cancellation.
@MainActor
final class NativeSidebarDwell {
  typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
  private let scheduler: Schedule
  private var cancellation: (() -> Void)?
  private var generation: UInt64 = 0

  init(schedule: Schedule? = nil) {
    scheduler = schedule ?? { delay, action in
      let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
      return { item.cancel() }
    }
  }

  func cancel() {
    generation &+= 1
    cancellation?(); cancellation = nil
  }

  func schedule(authority: NativeSidebarDragAuthority, store: BrowserStore,
    target: @escaping () -> String?, didNavigate: @escaping () -> Void) {
    cancel()
    guard authority.isCurrent(in: store), let candidate = target(), candidate != store.state.activeSpaceID,
      store.state.spaces.contains(where: { $0.id == candidate && $0.profileID == authority.profileID }) else { return }
    let token = generation, startingSpace = store.state.activeSpaceID
    cancellation = scheduler(0.55) { [weak self, weak store] in
      guard let self, self.generation == token else { return }
      self.cancel()
      guard let store, authority.isCurrent(in: store), store.state.activeSpaceID == startingSpace,
        let destination = target(), destination != startingSpace,
        store.state.spaces.contains(where: { $0.id == destination && $0.profileID == authority.profileID }) else { return }
      store.selectSpace(id: destination)
      guard authority.isCurrent(in: store), store.state.activeSpaceID == destination else { return }
      didNavigate()
    }
  }

  static func neighbor(in store: BrowserStore, offset: Int) -> String? {
    let spaces = store.state.spaces.filter { $0.profileID == store.activeProfileID }
    guard let current = spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }),
      spaces.indices.contains(current + offset) else { return nil }
    return spaces[current + offset].id
  }
}
