import AppKit
import SwiftUI

/// Native split divider retains the actual page views while resizing.
struct NativeSplitView: NSViewRepresentable {
  let first: NSView
  let second: NSView?
  var ratio: Double
  var onResize: (Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSSplitView {
    let view = NSSplitView()
    view.isVertical = true
    view.dividerStyle = .thin
    view.delegate = context.coordinator
    view.addArrangedSubview(first)
    if let second { view.addArrangedSubview(second) }
    return view
  }
  func updateNSView(_ view: NSSplitView, context: Context) {
    context.coordinator.parent = self
    let desired = [first] + (second.map { [$0] } ?? [])
    if view.arrangedSubviews != desired {
      for child in view.arrangedSubviews {
        view.removeArrangedSubview(child)
        child.removeFromSuperview()
      }
      for child in desired {
        child.removeFromSuperview()
        view.addArrangedSubview(child)
      }
      view.adjustSubviews()
    }
    if second != nil && view.bounds.width > 0 && !context.coordinator.resizing {
      let position = (view.bounds.width - view.dividerThickness) * min(0.85, max(0.15, ratio))
      if abs(first.frame.width - position) > 1 { view.setPosition(position, ofDividerAt: 0) }
    }
  }
  final class Coordinator: NSObject, NSSplitViewDelegate {
    var parent: NativeSplitView
    var resizing = false
    init(_ parent: NativeSplitView) { self.parent = parent }
    func splitView(
      _ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int
    ) -> CGFloat { min(180, splitView.bounds.width * 0.3) }
    func splitView(
      _ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int
    ) -> CGFloat { max(0, splitView.bounds.width - min(180, splitView.bounds.width * 0.3)) }
    func splitViewDidResizeSubviews(_ notification: Notification) {
      guard let view = notification.object as? NSSplitView, view.arrangedSubviews.count == 2,
        view.bounds.width > view.dividerThickness
      else { return }
      let ratio = view.arrangedSubviews[0].frame.width / (view.bounds.width - view.dividerThickness)
      guard abs(ratio - parent.ratio) > 0.005 else { return }
      resizing = true
      DispatchQueue.main.async { [weak self] in
        self?.parent.onResize(ratio)
        self?.resizing = false
      }
    }
  }
}
