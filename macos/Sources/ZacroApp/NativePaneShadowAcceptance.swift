import AppKit
import QuartzCore
import SwiftUI

/// Renders the actual shadow component's layer into a transparent bitmap. This
/// checks its alpha and geometry, independently of NSView cacheDisplay or the
/// separately composited Chromium windows; desktop composition is a later gate.
@MainActor enum NativePaneShadowAcceptance {
  static func check() -> [String: Bool] {
    let view = NativePaneShadowView(frame: .zero)
    var noBacking = true, exactPath = true, cutout = true
    var centerClear = true, visibleShadow = true, farCornersClear = true
    var rendered = true, noninteractive = true, shadowAlphaOnly = true
    for (size, radius) in [(CGSize(width: 320, height: 180), CGFloat(12)),
      (CGSize(width: 160, height: 120), CGFloat(20)),
      (CGSize(width: 420, height: 210), CGFloat(0)),
      (CGSize(width: 420, height: 210), CGFloat(12))] {
      view.radius = radius
      view.frame.size = CGSize(width: size.width + 2 * NativePaneShadowView.inset,
        height: size.height + 2 * NativePaneShadowView.inset)
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      let bounds = CGRect(origin: .zero, size: view.bounds.size)
      let pane = bounds.insetBy(dx: NativePaneShadowView.inset, dy: NativePaneShadowView.inset)
      let expected = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: pane).cgPath
      let layer = view.layer
      noBacking = noBacking && !view.isOpaque && (layer?.backgroundColor?.alpha ?? 0) == 0
        && layer?.contents == nil && view.shadowLayer.backgroundColor?.alpha == 0
        && view.shadowLayer.contents == nil
      exactPath = exactPath && view.shadowLayer.frame == view.bounds
        && view.shadowLayer.shadowPath.map { CFEqual($0, expected) } == true
        && view.shadowLayer.path.map { CFEqual($0, expected) } == true
        && view.shadowLayer.shadowOpacity > 0
      cutout = cutout && view.shadowLayer.mask === view.cutout && view.cutout.fillRule == .evenOdd
        && view.cutout.path?.contains(CGPoint(x: pane.midX, y: pane.midY), using: .evenOdd) == false
        && view.cutout.path?.contains(CGPoint(x: 1, y: 1), using: .evenOdd) == true
      noninteractive = noninteractive && view.hitTest(CGPoint(x: pane.midX, y: pane.midY)) == nil
        && !view.isAccessibilityElement()
      let bitmap = render(view)
      rendered = rendered && bitmap != nil
      guard let bitmap else { continue }
      let maximumShadowAlpha = UInt8(min(255, ceil(Double(view.shadowLayer.shadowOpacity) * 255) + 1))
      shadowAlphaOnly = shadowAlphaOnly && stride(from: 3, to: bitmap.bytes.count, by: 4).allSatisfy {
        bitmap.bytes[$0] <= maximumShadowAlpha
      }
      func alpha(_ x: Int, _ y: Int) -> UInt8 { bitmap.bytes[(y * bitmap.width + x) * 4 + 3] }
      let scale = bitmap.scale
      let centerX = Int((pane.midX * scale).rounded()), centerY = Int((pane.midY * scale).rounded())
      centerClear = centerClear && (centerY - 4...centerY + 4).allSatisfy { y in
        (centerX - 4...centerX + 4).allSatisfy { alpha($0, y) == 0 }
      }
      var exteriorShadow = false
      for y in 0..<bitmap.height {
        for x in 0..<bitmap.width where alpha(x, y) > 0 {
          let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
          if point.x < pane.minX - 1 || point.x > pane.maxX + 1
            || point.y < pane.minY - 1 || point.y > pane.maxY + 1 { exteriorShadow = true }
        }
      }
      visibleShadow = visibleShadow && exteriorShadow
      let corners = [CGPoint(x: 2, y: 2), CGPoint(x: bounds.maxX - 2, y: 2),
        CGPoint(x: 2, y: bounds.maxY - 2), CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2)]
      farCornersClear = farCornersClear && corners.allSatisfy {
        alpha(Int($0.x * scale), Int($0.y * scale)) == 0
      }
    }
    return [
      "paneShadowActualLayerHasNoBackgroundOrContentBacking": noBacking,
      "paneShadowActualPathTracksIndependentContinuousContourAndResize": exactPath,
      "paneShadowEvenOddMaskCutsOutPaneInterior": cutout,
      "paneShadowActualLayerBitmapRendersSuccessfully": rendered,
      "paneShadowActualBitmapHasZeroAlphaAtPaneCenter": rendered && centerClear,
      "paneShadowActualBitmapContainsExteriorFalloff": rendered && visibleShadow,
      "paneShadowActualBitmapFarCornersRemainTransparent": rendered && farCornersClear,
      "paneShadowActualBitmapHasNoOpaqueCasterFringeOrOutline": rendered && shadowAlphaOnly,
      "paneShadowDoesNotInterceptInputOrExposeAccessibilityContent": noninteractive,
    ]
  }

  private struct Bitmap {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat
  }
  private static func render(_ view: NativePaneShadowView) -> Bitmap? {
    guard let layer = view.layer else { return nil }
    let scale: CGFloat = 2
    let width = Int((view.bounds.width * scale).rounded(.up))
    let height = Int((view.bounds.height * scale).rounded(.up))
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let success = bytes.withUnsafeMutableBytes { storage -> Bool in
      guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.scaleBy(x: scale, y: scale)
      layer.render(in: context)
      return true
    }
    return success ? Bitmap(bytes: bytes, width: width, height: height, scale: scale) : nil
  }
}
