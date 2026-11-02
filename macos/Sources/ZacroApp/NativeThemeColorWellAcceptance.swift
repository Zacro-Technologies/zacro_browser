import AppKit

/// Exercises only an owned, non-presented AppKit control. Physical color-panel
/// interaction remains separate from these native-contract/render checks.
@MainActor
enum NativeThemeColorWellAcceptance {
  /// Run against the real editor's hosting window after its layout settles.
  /// A raw NSColorWell frame alone does not test SwiftUI's fitting proposals.
  static func checkHosted(in window: NSWindow) -> [String: Bool] {
    guard let root = window.contentView else { return ["theme_well_hosted_layout_is_27_points": false] }
    root.layoutSubtreeIfNeeded()
    var wells: [NativeThemeColorWellControl] = []
    func collect(_ view: NSView) {
      if let well = view as? NativeThemeColorWellControl { wells.append(well) }
      view.subviews.forEach(collect)
    }
    collect(root)
    func exact(_ size: NSSize) -> Bool { abs(size.width - 27) < 0.01 && abs(size.height - 27) < 0.01 }
    let geometry = wells.map { "frame=\($0.frame) bounds=\($0.bounds) fitting=\($0.fittingSize) insets=\($0.alignmentRectInsets) root=\($0.convert($0.bounds, to: root))" }.joined(separator: "; ")
    fputs("[Theme well acceptance] visible=\(window.isVisible) key=\(window.isKeyWindow) wells=\(wells.count) \(geometry)\n", stderr)
    return [
      "theme_well_hosted_layout_is_27_points": !wells.isEmpty && wells.allSatisfy {
        exact($0.frame.size) && exact($0.bounds.size) && exact($0.convert($0.bounds, to: root).size)
      },
      "theme_well_hosted_fitting_preserves_native_control": !wells.isEmpty && wells.allSatisfy {
        exact($0.fittingSize) && $0.isBordered && $0.accessibilityRole() == .colorWell
      },
    ]
  }

  static func check() -> [String: Bool] {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 72, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let container = SwatchSurface(frame: NSRect(x: 0, y: 0, width: 72, height: 60))
    window.contentView = container
    let well = NativeThemeColorWellControl(frame: NSRect(x: 16, y: 16, width: 27, height: 27))
    well.setAccessibilityLabel("Primary color")
    container.addSubview(well)

    let source = NSColorWell(frame: .zero)
    let nativeContract = well.intrinsicContentSize == NSSize(width: 27, height: 27)
      && well.accessibilityRole() == .colorWell
      && well.accessibilityLabel() == "Primary color"
      && !well.registeredDraggedTypes.isEmpty
      && well.registeredDraggedTypes == source.registeredDraggedTypes
      && well.isBordered
      && !well.supportsAlpha
    let focus = window.makeFirstResponder(well) && window.firstResponder === well

    var changes: [NSColor] = []
    var selections = 0
    well.onChange = { changes.append($0) }
    well.onSelect = { selections += 1 }
    source.color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 0.3)
    well.takeColorFrom(source)
    let programmaticUpdateIsQuiet = changes.isEmpty && selections == 0
    let delivered = well.sendAction(well.action, to: well.target)
    let action = delivered && changes.count == 1 && selections == 1
      && changes[0].alphaComponent == 1 && well.color.alphaComponent == 1

    _ = window.makeFirstResponder(nil)
    let foreground = NSColor(srgbRed: 0.61, green: 0.27, blue: 0.38, alpha: 1)
    well.color = foreground
    container.swatch = foreground
    func renderMatches(background: NSColor) -> Bool {
      container.background = background
      container.needsDisplay = true
      container.layoutSubtreeIfNeeded()
      guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return false }
      container.cacheDisplay(in: container.bounds, to: bitmap)
      let scaleX = CGFloat(bitmap.pixelsWide) / container.bounds.width
      let scaleY = CGFloat(bitmap.pixelsHigh) / container.bounds.height
      func pixel(_ x: CGFloat, _ y: CGFloat, matches referenceX: CGFloat, _ referenceY: CGFloat) -> Bool {
        guard let actual = bitmap.colorAt(x: Int(x * scaleX),
          y: Int((container.bounds.height - y) * scaleY))?.usingColorSpace(.sRGB),
          let reference = bitmap.colorAt(x: Int(referenceX * scaleX),
            y: Int((container.bounds.height - referenceY) * scaleY))?.usingColorSpace(.sRGB)
        else { return false }
        return actual.alphaComponent > 0.99
          && abs(actual.redComponent - reference.redComponent) < 0.025
          && abs(actual.greenComponent - reference.greenComponent) < 0.025
          && abs(actual.blueComponent - reference.blueComponent) < 0.025
      }
      // Center and near-edge share the exact selected color; the rounded
      // corner retains the card behind it instead of a native bezel.
      return pixel(29.5, 29.5, matches: 58, 24)
        && pixel(17, 29.5, matches: 58, 24)
        && pixel(16.5, 16.5, matches: 5, 5)
    }
    let dark = renderMatches(background: NSColor(srgbRed: 0.2, green: 0.17, blue: 0.2, alpha: 1))
    let light = renderMatches(background: NSColor(srgbRed: 0.93, green: 0.9, blue: 0.92, alpha: 1))
    return [
      "theme_well_native_accessibility_and_color_drop_contract": nativeContract,
      "theme_well_native_keyboard_focus": focus,
      "theme_well_refresh_does_not_publish_user_change": programmaticUpdateIsQuiet,
      "theme_well_native_action_publishes_opaque_color": action,
      "theme_well_borderless_rounded_color_light_and_dark": dark && light,
    ]
  }

  private final class SwatchSurface: NSView {
    var background = NSColor.clear
    var swatch = NSColor.clear
    override func draw(_ dirtyRect: NSRect) {
      background.setFill(); bounds.fill()
      swatch.setFill(); NSRect(x: 54, y: 20, width: 10, height: 10).fill()
    }
  }
}
