import Foundation
import ZacroCore

/// The sidebar context action corresponds to split:toggle({ id }) in main.cjs.
/// It pairs the supplied row with the current page without first selecting it.
@MainActor enum NativeSidebarSplit {
  static func open(tabID: String, store: BrowserStore) throws {
    guard let active = store.state.activeTab, active.url != "about:blank", !active.isClosed else {
      throw ShortcutError("Open a web page in the current tab before starting split view.")
    }
    let candidates = store.state.tabs.filter {
      $0.spaceID == store.state.activeSpaceID && $0.id != active.id && $0.url != "about:blank"
    }
    guard let target = candidates.first(where: { $0.id == tabID })
      ?? candidates.first(where: { store.split(for: $0.id) == nil }) else {
      throw ShortcutError("Open a second web page in this Space to use split view.")
    }
    store.setSplit(left: active.id, right: target.id)
    guard let group = store.split(for: active.id), Set(group.tabIDs) == Set([active.id, target.id]) else {
      throw ShortcutError(store.lastError ?? "Choose two open web pages in the same Space.")
    }
  }
}
