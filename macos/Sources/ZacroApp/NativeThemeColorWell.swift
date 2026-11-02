import AppKit
import SwiftUI

/// A genuine AppKit color well with the renderer's compact, borderless swatch.
/// AppKit continues to own color-panel activation, color dragging and keyboard
/// accessibility; only its drawing is replaced.
struct NativeThemeColorWell: NSViewRepresentable {
  let title: String
  let color: NSColor
  var onSelect: () -> Void
  var onChange: (NSColor) -> Void

  func makeNSView(context: Context) -> NativeThemeColorWellControl {
    let well = NativeThemeColorWellControl(frame: .zero)
    updateNSView(well, context: context)
    return well
  }

  func updateNSView(_ well: NativeThemeColorWellControl, context: Context) {
    well.setAccessibilityLabel(title)
    let opaque = color.withAlphaComponent(1)
    if well.color != opaque { well.color = opaque; well.needsDisplay = true }
    well.onSelect = onSelect
    well.onChange = onChange
  }

  static func dismantleNSView(_ well: NativeThemeColorWellControl, coordinator: ()) {
    well.deactivate()
    well.onSelect = {}
    well.onChange = { _ in }
  }
}

@MainActor
final class NativeThemeColorWellControl: NSColorWell {
  var onSelect: () -> Void = {}
  var onChange: (NSColor) -> Void = { _ in }

  override init(frame: NSRect) {
    super.init(frame: frame)
    colorWellStyle = .default
    // Keep AppKit's activation behavior. Setting isBordered=false also
    // disables click-to-open; our drawing alone removes the visible bezel.
    isBordered = true
    supportsAlpha = false
    isContinuous = true
    target = self
    action = #selector(colorChanged)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: NSSize { NSSize(width: 27, height: 27) }
  override var isOpaque: Bool { false }
  override var focusRingMaskBounds: NSRect { bounds }

  override func draw(_ dirtyRect: NSRect) { drawSwatch() }
  override func drawWell(inside insideRect: NSRect) { drawSwatch() }

  override func drawFocusRingMask() { swatchPath.fill() }

  override func activate(_ exclusive: Bool) {
    onSelect()
    super.activate(exclusive)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil && isActive { deactivate() }
  }

  private var swatchPath: NSBezierPath {
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
  }

  private func drawSwatch() {
    color.withAlphaComponent(1).setFill()
    swatchPath.fill()
  }

  @objc private func colorChanged() {
    let opaque = color.withAlphaComponent(1)
    if color != opaque { color = opaque }
    needsDisplay = true
    onSelect()
    onChange(opaque)
  }
}
