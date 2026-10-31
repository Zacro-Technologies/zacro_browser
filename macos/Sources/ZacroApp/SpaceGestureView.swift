import AppKit
import SwiftUI

/// Receives only sidebar scroll events. Native momentum never changes Spaces.
struct SpaceGestureSurface<Content: View>: NSViewRepresentable {
  var index: Int
  var count: Int
  var onProgress: (Double) -> Void
  var onSelect: (Int) -> Void
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> SpaceScrollHost<Content> {
    let view = SpaceScrollHost(rootView: content())
    configure(view)
    return view
  }
  func updateNSView(_ view: SpaceScrollHost<Content>, context: Context) {
    view.rootView = content()
    configure(view)
  }
  private func configure(_ view: SpaceScrollHost<Content>) {
    view.index = index
    view.count = count
    view.onProgress = onProgress
    view.onSelect = onSelect
  }
}

final class SpaceScrollHost<Content: View>: NSHostingView<Content> {
  var index = 0
  var count = 1
  var onProgress: (Double) -> Void = { _ in }
  var onSelect: (Int) -> Void = { _ in }
  private var started: TimeInterval = 0
  private var displacement: Double = 0
  private var origin = 0
  private var claimed = false

  override func scrollWheel(with event: NSEvent) {
    if !event.momentumPhase.isEmpty { return }
    if event.phase.contains(.began) {
      origin = index
      started = event.timestamp
      displacement = 0
      claimed = false
    }
    if event.phase.contains(.cancelled) {
      claimed = false
      onProgress(0)
      return
    }
    if event.phase.contains(.ended) {
      guard claimed else {
        super.scrollWheel(with: event)
        return
      }
      let duration = event.timestamp - started
      let pageWidth = max(180, bounds.width)
      let distance = displacement / pageWidth
      let offset: Int
      if duration < 0.28 {
        offset = abs(displacement) > 18 ? (displacement > 0 ? 1 : -1) : 0
      } else {
        offset = Int(distance.rounded(.toNearestOrAwayFromZero))
      }
      claimed = false
      onSelect(min(max(0, origin + offset), max(0, count - 1)))
      onProgress(0)
      return
    }
    // A horizontal contact can continue over several pages until fingers lift.
    guard event.hasPreciseScrollingDeltas,
      claimed || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2
    else {
      super.scrollWheel(with: event)
      return
    }
    if !claimed {
      claimed = true
      origin = index
      if started == 0 { started = event.timestamp }
    }
    displacement -= event.scrollingDeltaX
    let width = max(180, bounds.width)
    let bounded = min(
      Double(max(0, count - 1 - origin)), max(Double(-origin), displacement / width))
    onProgress(bounded)
  }
}
