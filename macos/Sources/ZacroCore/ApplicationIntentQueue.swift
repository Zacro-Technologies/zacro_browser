import Foundation

/// Launch Services and macOS menus can arrive while the last window is
/// unloading. Keep their order until a live destination can safely accept them.
public struct ApplicationIntentQueue {
  public enum Action: Equatable {
    case openURL(String)
    case command(String)
    case showWindow
  }
  public struct Window: Equatable {
    public let id: String
    public let isClosing: Bool
    public init(id: String, isClosing: Bool = false) { self.id = id; self.isClosing = isClosing }
  }
  public struct Intent: Equatable {
    public let action: Action
    public let preferredWindowID: String?
  }
  public enum Delivery: Equatable {
    /// A nil target asks the application to reopen a saved window or make one.
    case perform(Intent, windowID: String?)
    case discard(Intent)
  }
  private var pending: [Intent] = []
  public var count: Int { pending.count }
  public init() {}

  @discardableResult public mutating func append(_ action: Action, preferredWindowID: String? = nil) -> Bool {
    guard pending.count < 32 else { return false }
    pending.append(Intent(action: action, preferredWindowID: preferredWindowID))
    return true
  }
  public mutating func removeAll() { pending.removeAll() }

  /// Only open windows are supplied. A closing target is not interchangeable
  /// with a background window: wait for its unload decision before rebinding.
  public mutating func next(ready: Bool, terminating: Bool, windows: [Window], focusedWindowID: String?) -> Delivery? {
    guard ready, !terminating, let intent = pending.first else { return nil }
    let preferred = windows.first { $0.id == intent.preferredWindowID }
    let focused = windows.first { $0.id == focusedWindowID }
    if preferred?.isClosing == true || (preferred == nil && focused?.isClosing == true) { return nil }
    let target = preferred ?? focused ?? windows.first(where: { !$0.isClosing })
    if target == nil && windows.contains(where: \.isClosing) { return nil }
    pending.removeFirst()
    if case .command(let command) = intent.action {
      // Commands that create/reopen a window do that themselves. Ensuring a
      // destination first would create two windows after closing the last one.
      if ["open-browser", "new-window", "reopen-window"].contains(command) {
        return .perform(intent, windowID: nil)
      }
      if ["close-tab", "close-window", "window-minimize", "window-zoom"].contains(command),
        target == nil || (intent.preferredWindowID != nil && preferred == nil) {
        return .discard(intent)
      }
    }
    return .perform(intent, windowID: target?.id)
  }
}
