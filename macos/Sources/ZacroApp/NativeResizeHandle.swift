import AppKit
import SwiftUI

/// A native separator keeps an in-progress resize separate from durable settings.
/// Keyboard handling precedes browser shortcuts while this view owns focus.
struct NativeResizeHandle: NSViewRepresentable {
  @MainActor static func cancel(in window: NSWindow) {
    guard let root = window.contentView else { return }
    var handles: [NativeResizeHandleView] = []
    func collect(_ view: NSView) {
      if let handle = view as? NativeResizeHandleView { handles.append(handle) }
      view.subviews.forEach(collect)
    }
    collect(root)
    handles.forEach { $0.finish(commit: false) }
  }
  var value: Double
  var range: ClosedRange<Double>
  var direction: Double = 1
  var step: Double = 16
  var fineStep: Double = 1
  var largeStep: Double = 32
  var reset: Double
  var pixelsPerUnit: Double = 1
  var label: String
  var needsTransparentHitArea = false
  var valueDescription: (Double) -> String = { "\(Int($0.rounded())) pixels" }
  var preview: (Double) -> Void
  var commit: (Double) -> Void
  var cancel: () -> Void

  func makeNSView(context: Context) -> NativeResizeHandleView {
    let view = NativeResizeHandleView(); view.configuration = self; return view
  }
  func updateNSView(_ view: NativeResizeHandleView, context: Context) { view.configuration = self }
  static func dismantleNSView(_ view: NativeResizeHandleView, coordinator: ()) { view.detach() }
}

final class NativeResizeHandleView: NSView {
  var configuration: NativeResizeHandle? {
    didSet {
      guard let configuration else { return }
      setAccessibilityElement(true); setAccessibilityRole(.splitter)
      setAccessibilityOrientation(.vertical); setAccessibilityLabel(configuration.label)
      setAccessibilityValue(configuration.valueDescription(configuration.value))
      needsDisplay = true
    }
  }
  private var startValue: Double?
  private var startX: CGFloat = 0
  private var previewValue: Double?
  private var hovered = false
  private var tracking: NSTrackingArea?
  private var notifications: [NSObjectProtocol] = []
  private weak var observedWindow: NSWindow?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    tracking = next; addTrackingArea(next)
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    // Only fully clear chrome needs a painted WindowServer hit target. An
    // always-painted idle handle makes a visible stripe through the gradient.
    let highlighted = hovered || window?.firstResponder === self
    let opacity = startValue != nil ? 0.14 : highlighted ? 0.08
      : configuration?.needsTransparentHitArea == true ? 0.01 : 0
    guard opacity > 0 else { return }
    NSColor.labelColor.withAlphaComponent(opacity).setFill()
    bounds.fill()
  }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { finish(commit: false); needsDisplay = true; return true }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if observedWindow !== window { finish(commit: false, deferCallback: true) }
    observedWindow = window
    notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
    guard let window else { return }
    for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.finish(commit: false) }
      })
    }
    notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.finish(commit: false) }
    })
  }
  deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
  override func mouseDown(with event: NSEvent) {
    guard let configuration else { return }
    window?.makeFirstResponder(self)
    if event.clickCount == 2 { apply(configuration.reset); return }
    startValue = configuration.value; previewValue = configuration.value; startX = event.locationInWindow.x
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard let configuration, let startValue else { return }
    let delta = Double(event.locationInWindow.x - startX) / max(0.0001, configuration.pixelsPerUnit)
    let value = clamped(startValue + configuration.direction * delta)
    previewValue = value; configuration.preview(value); needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) { finish(commit: true) }
  func detach() {
    finish(commit: false, deferCallback: true)
    notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
  }
  func finish(commit: Bool, deferCallback: Bool = false) {
    guard startValue != nil, let configuration else { return }
    let value = previewValue ?? configuration.value
    startValue = nil; previewValue = nil; needsDisplay = true
    if commit { configuration.commit(clamped(value)) }
    else if deferCallback { DispatchQueue.main.async(execute: configuration.cancel) }
    else { configuration.cancel() }
  }
  /// Called by the application's local monitor before matching navigation keys.
  @discardableResult func handleKey(_ event: NSEvent) -> Bool {
    guard let configuration, event.type == .keyDown else { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.keyCode == 53, flags.isEmpty, startValue != nil { finish(commit: false); return true }
    guard flags.isDisjoint(with: [.command, .control]) else { return false }
    let step = flags.contains(.shift) ? configuration.largeStep : flags.contains(.option) ? configuration.fineStep : configuration.step
    switch event.keyCode {
    case 123: apply(configuration.value - step * configuration.direction)
    case 124: apply(configuration.value + step * configuration.direction)
    case 115: apply(configuration.range.lowerBound)
    case 119: apply(configuration.range.upperBound)
    default: return false
    }
    return true
  }
  override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }
  override func accessibilityPerformIncrement() -> Bool {
    guard let configuration else { return false }; apply(configuration.value + configuration.step); return true
  }
  override func accessibilityPerformDecrement() -> Bool {
    guard let configuration else { return false }; apply(configuration.value - configuration.step); return true
  }
  private func apply(_ value: Double) {
    guard let configuration else { return }
    finish(commit: false); configuration.commit(clamped(value))
  }
  private func clamped(_ value: Double) -> Double {
    guard let configuration else { return value }
    return min(configuration.range.upperBound, max(configuration.range.lowerBound, value))
  }
}
