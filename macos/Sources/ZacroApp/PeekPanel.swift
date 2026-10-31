import AppKit
import SwiftUI

@MainActor
final class PeekPanelController {
  private var panel: NSPanel?
  func show(
    parent: NSWindow, contentFrame: CGRect, preview: NSWindow?, close: @escaping () -> Void,
    expand: @escaping () -> Void
  ) {
    guard let content = parent.contentView else { return }
    let panel: NSPanel
    if let existing = self.panel {
      panel = existing
    } else {
      panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.isMovable = false
      panel.collectionBehavior = [.fullScreenAuxiliary]
      parent.addChildWindow(panel, ordered: .above)
      self.panel = panel
    }
    let rect = CGRect(
      x: contentFrame.minX, y: content.bounds.height - contentFrame.maxY, width: contentFrame.width,
      height: contentFrame.height)
    panel.setFrame(parent.convertToScreen(content.convert(rect, to: nil)), display: true)
    panel.contentView = NSHostingView(rootView: PeekBackdrop(close: close, expand: expand))
    panel.orderFront(nil)
    if let preview { preview.order(.above, relativeTo: panel.windowNumber) }
  }
  func hide() {
    guard let panel else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    self.panel = nil
  }
}

private struct PeekBackdrop: View {
  var close: () -> Void
  var expand: () -> Void
  var body: some View {
    GeometryReader { geometry in
      let inset = max(55, geometry.size.width * 0.12)
      ZStack(alignment: .topTrailing) {
        Color.black.opacity(0.18).onTapGesture(perform: close)
        VStack(spacing: 8) {
          Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32) }.help(
            "Close Peek")
          Button(action: expand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 32, height: 32)
          }.help("Expand Peek")
        }.buttonStyle(.plain).background(.regularMaterial, in: Capsule()).padding(.top, 36).padding(
          .trailing, inset - 44)
      }
    }
  }
}
