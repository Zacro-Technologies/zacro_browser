import AppKit
import SwiftUI

/// Binds asynchronous dialogs to the view that initiated them, including views
/// inside an existing sheet. A different key browser window is never inferred.
@MainActor
final class NativeWindowDialogOwner: ObservableObject {
  private weak var anchor: NSView?
  private weak var attachedWindow: NSWindow?
  private var generation = UUID()
  private var task: Task<Void, Never>?

  @MainActor struct Context {
    let window: NSWindow
    fileprivate weak var owner: NativeWindowDialogOwner?
    fileprivate let generation: UUID
    var isCurrent: Bool {
      !Task.isCancelled && owner?.generation == generation
        && owner?.anchor?.window === window && window.isVisible
    }
  }

  func perform(_ operation: @escaping @MainActor (Context) async -> Void) {
    guard let window = anchor?.window, window.isVisible, window.attachedSheet == nil else { return }
    cancel()
    let context = Context(window: window, owner: self, generation: generation)
    task = Task { @MainActor [weak self] in
      guard context.isCurrent else { return }
      await operation(context)
      if self?.generation == context.generation { self?.task = nil }
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
  }

  fileprivate func attach(_ view: NSView) {
    if anchor !== view || attachedWindow !== view.window { cancel() }
    anchor = view
    attachedWindow = view.window
  }

  fileprivate func detach(_ view: NSView) {
    guard anchor === view else { return }
    cancel(); anchor = nil; attachedWindow = nil
  }
}

struct NativeWindowDialogAnchor: NSViewRepresentable {
  let owner: NativeWindowDialogOwner
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor(frame: .zero); view.owner = owner
    return view
  }
  func updateNSView(_ view: Anchor, context: Context) {
    if view.owner !== owner { view.owner?.detach(view); view.owner = owner }
    owner.attach(view)
  }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.owner?.detach(view) }

  final class Anchor: NSView {
    weak var owner: NativeWindowDialogOwner?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.attach(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
  }
}
