import AppKit
import SwiftUI

/// Cast the pane's shadow without placing a colored surface below a live page.
/// The cutout also removes the shadow's interior silhouette, leaving only its
/// exterior falloff. Empty tabs supply their own intentional opaque canvas.
struct NativePaneShadow: NSViewRepresentable {
  var radius: CGFloat
  func makeNSView(context: Context) -> NativePaneShadowView {
    let view = NativePaneShadowView(); view.radius = radius; return view
  }
  func updateNSView(_ view: NativePaneShadowView, context: Context) { view.radius = radius }
}

final class NativePaneShadowView: NSView {
  static let inset: CGFloat = 24
  let shadowLayer = CAShapeLayer()
  let cutout = CAShapeLayer()
  var radius: CGFloat = 12 { didSet { if radius != oldValue { needsLayout = true } } }
  private var geometry: CGRect?
  private var appliedRadius: CGFloat?
  private var appliedScale: CGFloat?
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    shadowLayer.backgroundColor = NSColor.clear.cgColor
    // The opaque caster is completely removed by the exterior-only mask.
    // A clear CALayer with just shadowPath does not consistently cast a
    // shadow through AppKit's layer rendering path.
    shadowLayer.fillColor = NSColor.black.cgColor
    shadowLayer.shadowColor = NSColor(srgbRed: 32 / 255, green: 19 / 255, blue: 36 / 255, alpha: 1).cgColor
    shadowLayer.shadowOpacity = 0.11
    shadowLayer.shadowRadius = 9
    shadowLayer.shadowOffset = CGSize(width: 0, height: 4)
    cutout.fillRule = .evenOdd
    cutout.fillColor = NSColor.black.cgColor
    shadowLayer.mask = cutout
    layer?.addSublayer(shadowLayer)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
  override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

  override func layout() {
    super.layout()
    let scale = window?.backingScaleFactor ?? 2
    guard geometry != bounds || appliedRadius != radius || appliedScale != scale else { return }
    let local = CGRect(origin: .zero, size: bounds.size)
    let pane = local.insetBy(dx: Self.inset, dy: Self.inset)
    guard pane.width > 0, pane.height > 0 else { return }
    let path = NativePaneShape(radius: radius).path(in: pane).cgPath
    let outside = CGMutablePath()
    outside.addRect(local)
    // An inverse mask of the identical antialiased path leaves A*(1-A)
    // caster pixels at the edge: an unwanted dark outline. Exclude one
    // physical pixel beyond the caster while retaining its soft shadow.
    let outset = 1 / max(1, scale)
    outside.addPath(NativePaneShape(radius: radius + outset)
      .path(in: pane.insetBy(dx: -outset, dy: -outset)).cgPath)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shadowLayer.frame = bounds
    shadowLayer.path = path
    shadowLayer.shadowPath = path
    cutout.frame = local
    cutout.path = outside
    shadowLayer.contentsScale = scale
    cutout.contentsScale = shadowLayer.contentsScale
    CATransaction.commit()
    geometry = bounds; appliedRadius = radius; appliedScale = scale
  }
}

/// Uses the exact split ratio currently displayed, including an unfinished drag.
struct NativePaneShadows: View {
  let radius: CGFloat
  let splitRatio: Double?
  var body: some View {
    GeometryReader { geometry in
      let panes = NativePaneGeometry.frames(in: CGRect(origin: .zero, size: geometry.size), splitRatio: splitRatio)
      ForEach(Array(panes.enumerated()), id: \.offset) { _, pane in
        shadow.frame(width: pane.width, height: pane.height)
          .position(x: pane.midX, y: pane.midY)
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
  private var shadow: some View {
    NativePaneShadow(radius: radius).padding(-NativePaneShadowView.inset)
  }
}
