import AppKit

/// Validate the real material view and its assigned alpha mask offscreen.
/// This does not measure desktop blur composition or GPU performance.
@MainActor enum NativeChromeMaterialAcceptance {
  static func check() throws -> [String: Bool] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance") else { throw Failure() }
    let originalKey = NSApp.keyWindow
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
    window.contentView = root
    let view = NativeChromeMaterialView(frame: .zero)
    root.addSubview(view)
    var input = NativeChromeMaterialOcclusion(contentFrame: CGRect(x: 224, y: 4, width: 412, height: 472), radius: 12)
    view.configure(amount: 0.6, occlusion: input)
    var results = ["chrome_material_zero_initial_geometry_keeps_full_material": view.maskImage == nil]
    view.setFrameSize(root.bounds.size)
    guard let first = view.maskImage else { throw Failure() }
    func alpha(_ image: NSImage, x: CGFloat, edge: Bool = false) throws -> CGFloat {
      guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
        bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
        let color = bitmap.colorAt(x: min(bitmap.pixelsWide - 1,
          max(0, Int(x / image.size.width * CGFloat(bitmap.pixelsWide)))),
          y: edge ? 0 : bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { throw Failure() }
      return color.alphaComponent
    }
    results["chrome_material_excludes_opaque_center_preserving_rail_corners_and_caps"] =
      try alpha(first, x: 430) < 0.01 && alpha(first, x: 100) > 0.99
      && alpha(first, x: 226) > 0.99 && alpha(first, x: 430, edge: true) > 0.99
      && first.capInsets.top == 20 && first.capInsets.bottom == 20 && first.size.height == 41
    view.configure(amount: 0.7, occlusion: input)
    results["chrome_material_alpha_change_retains_one_effect_and_unchanged_mask"] =
      view.maskImage === first && view.alphaValue == 0.7 && root.subviews.count == 1
      && view.material == .underWindowBackground && view.blendingMode == .behindWindow && view.state == .active
    input.splitRatio = 0.5
    view.configure(amount: 0.7, occlusion: input)
    guard let split = view.maskImage else { throw Failure() }
    results["chrome_material_split_excludes_both_interiors_and_preserves_six_point_gap"] =
      try alpha(split, x: 325) < 0.01 && alpha(split, x: 533) < 0.01 && alpha(split, x: 430) > 0.99
    view.configure(amount: 0.7, occlusion: input)
    results["chrome_material_identical_geometry_reuses_actual_mask"] = view.maskImage === split
    input.radius = 20
    view.configure(amount: 0.7, occlusion: input)
    results["chrome_material_radius_change_replaces_actual_mask"] = view.maskImage != nil && view.maskImage !== split
    view.configure(amount: 0.7, occlusion: nil)
    results["chrome_material_optional_occlusion_defaults_to_full_material"] = view.maskImage == nil
    results["chrome_material_offscreen_checks_preserve_focus"] = !window.isVisible && NSApp.keyWindow === originalKey
    return results
  }
  private struct Failure: LocalizedError {
    var errorDescription: String? { "Native chrome material mask could not be verified." }
  }
}
