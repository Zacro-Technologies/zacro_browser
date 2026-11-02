import AppKit

/// AppKit normally retains a window's first responder while a child panel is
/// key. Restore a captured responder only when that retained target vanished;
/// a newer valid target belongs to the action that dismissed the panel.
@MainActor
final class NativeFocusRestoration {
  private weak var window: NSWindow?
  private weak var responder: NSResponder?
  func capture(in window: NSWindow) { self.window = window; responder = window.firstResponder }
  func restore(in window: NSWindow) -> Bool {
    guard self.window === window else { return false }
    if available(window.firstResponder, in: window) { return true }
    guard available(responder, in: window), let responder else { return false }
    return window.makeFirstResponder(responder)
  }
  func clear() { window = nil; responder = nil }
  private func available(_ responder: NSResponder?, in window: NSWindow) -> Bool {
    guard let view = responder as? NSView, view !== window.contentView,
      view.window === window, !view.isHiddenOrHasHiddenAncestor,
      view.bounds.width > 0, view.bounds.height > 0, view.acceptsFirstResponder else { return false }
    if let control = view as? NSControl, !control.isEnabled { return false }
    if let editor = view as? NSTextView, editor.isFieldEditor,
      let control = editor.delegate as? NSControl, !control.isEnabled { return false }
    return true
  }
}
