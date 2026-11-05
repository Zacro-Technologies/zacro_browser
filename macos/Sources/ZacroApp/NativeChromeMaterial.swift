import AppKit
import SwiftUI

struct NativeChromeMaterialOcclusion: Equatable {
  var contentFrame: CGRect
  var radius: CGFloat
  var splitRatio: Double? = nil
}

/// Mask only the behind-window material. The continuous window tint remains
/// untouched, including every pane contour, its antialiasing and its shadow.
struct NativeChromeMaterial: NSViewRepresentable {
  var amount: Double
  var occlusion: NativeChromeMaterialOcclusion? = nil
  func makeNSView(context: Context) -> NativeChromeMaterialView {
    let view = NativeChromeMaterialView()
    view.configure(amount: amount, occlusion: occlusion)
    return view
  }
  func updateNSView(_ view: NativeChromeMaterialView, context: Context) {
    view.configure(amount: amount, occlusion: occlusion)
  }
}

final class NativeChromeMaterialView: NSVisualEffectView {
  private struct MaskGeometry: Equatable {
    var size: CGSize
    var holes: [CGRect]
    var scale: CGFloat
  }
  private var occlusion: NativeChromeMaterialOcclusion?
  private var appliedGeometry: MaskGeometry?
  private var appliedImage: NSImage?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .underWindowBackground
    blendingMode = .behindWindow
    state = .active
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
  func configure(amount: Double, occlusion: NativeChromeMaterialOcclusion?) {
    let alpha = amount.isFinite ? min(1, max(0, amount)) : 0
    if alphaValue != alpha { alphaValue = alpha }
    self.occlusion = occlusion
    updateMask()
  }
  override func layout() { super.layout(); updateMask() }
  override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); updateMask() }
  override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateMask() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMask() }
  override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateMask() }

  private func geometry() -> MaskGeometry? {
    guard let occlusion, let root = window?.contentView,
      bounds.width > 0, bounds.height > 0, occlusion.radius.isFinite,
      occlusion.contentFrame.width > 0, occlusion.contentFrame.height > 0,
      [occlusion.contentFrame.minX, occlusion.contentFrame.minY,
        occlusion.contentFrame.maxX, occlusion.contentFrame.maxY].allSatisfy(\.isFinite) else { return nil }
    let input = occlusion.contentFrame
    let rootRect = root.isFlipped ? input : CGRect(x: input.minX,
      y: root.bounds.maxY - input.maxY, width: input.width, height: input.height)
    let local = convert(rootRect, from: root)
    let topLeft = CGRect(x: local.minX - bounds.minX,
      y: isFlipped ? local.minY - bounds.minY : bounds.maxY - local.maxY,
      width: local.width, height: local.height)
    let inset = max(0, occlusion.radius) + 4
    let area = CGRect(origin: .zero, size: bounds.size)
    let holes = NativePaneGeometry.frames(in: topLeft, splitRatio: occlusion.splitRatio).compactMap { pane -> CGRect? in
      guard pane.width > inset * 2, pane.height > inset * 2 else { return nil }
      let clipped = pane.insetBy(dx: inset, dy: inset).intersection(area)
      // Round inward: excluded pixels must remain deep inside opaque content.
      let left = ceil(clipped.minX), top = ceil(clipped.minY)
      let right = floor(clipped.maxX), bottom = floor(clipped.maxY)
      guard !clipped.isNull, right > left, bottom > top else { return nil }
      return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    guard !holes.isEmpty else { return nil }
    return MaskGeometry(size: bounds.size, holes: holes, scale: window?.backingScaleFactor ?? 1)
  }

  private func updateMask() {
    let next = geometry()
    guard next != appliedGeometry || maskImage !== appliedImage else { return }
    appliedGeometry = next
    guard let next, let first = next.holes.first else {
      appliedImage = nil
      if maskImage != nil { maskImage = nil }
      return
    }
    // All split panes share vertical bounds. Keep just their fixed top/bottom
    // bands and a one-point middle strip; public capInsets stretch that strip.
    // A resize therefore avoids generating an entire window-sized mask bitmap.
    let top = first.minY, bottom = max(0, next.size.height - first.maxY)
    let imageSize = CGSize(width: next.size.width, height: top + 1 + bottom)
    let strips = next.holes.map { CGRect(x: $0.minX, y: bottom, width: $0.width, height: 1) }
    let image = NSImage(size: imageSize, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.setFillColor(NSColor.white.cgColor)
      context.fill(rect)
      for strip in strips { context.clear(strip) }
      return true
    }
    image.capInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    image.resizingMode = .stretch
    appliedImage = image
    maskImage = image
  }
}
