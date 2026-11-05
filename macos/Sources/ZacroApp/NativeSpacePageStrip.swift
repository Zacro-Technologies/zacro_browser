import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Keep page contents and native scroll views retained while the strip moves.
/// Fractional positions cross this boundary as native geometry, never as a new
/// sidebar root view or another SwiftUI animation transaction.
struct NativeSpacePageStrip: NSViewRepresentable {
  let viewport: NativeSpaceViewport
  let selectedID: String
  let content: @MainActor (String, Bool) -> AnyView

  func makeNSView(context: Context) -> NativeSpacePageStripView {
    let view = NativeSpacePageStripView()
    view.configure(viewport: viewport, selectedID: selectedID, environment: context.environment, content: content)
    return view
  }
  func updateNSView(_ view: NativeSpacePageStripView, context: Context) {
    view.configure(viewport: viewport, selectedID: selectedID, environment: context.environment, content: content)
  }
  static func dismantleNSView(_ view: NativeSpacePageStripView, coordinator: ()) { view.detach() }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeSpacePageStripView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
}

@MainActor
final class NativeSpacePageStripView: NSView {
  private weak var viewport: NativeSpaceViewport?
  private var framesObservation: AnyCancellable?
  private var content: (@MainActor (String, Bool) -> AnyView)?
  private var environment = EnvironmentValues()
  private var selectedID = ""
  private var contentRevision: UInt64 = 0
  private(set) var hosts: [String: NativeSpacePageHost] = [:]
  private(set) var displayedFrames: [NativeSpaceViewport.Frame] = []
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }

  func configure(viewport: NativeSpaceViewport, selectedID: String, environment: EnvironmentValues,
    content: @escaping @MainActor (String, Bool) -> AnyView) {
    let changedViewport = self.viewport !== viewport
    if changedViewport { detach() }
    self.viewport = viewport; self.selectedID = selectedID
    self.environment = environment; self.content = content
    contentRevision &+= 1
    if changedViewport {
      framesObservation = viewport.$frames.sink { [weak self] frames in self?.present(frames) }
    } else { present(viewport.frames) }
  }

  override func layout() { super.layout(); layoutHosts() }
  override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutHosts() }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(convert(point, from: superview)) else { return nil }
    return super.hitTest(point)
  }

  private func present(_ frames: [NativeSpaceViewport.Frame]) {
    // The viewport hosts at most the intersecting pages and one neighbor on
    // either side. Keep that bound even if an invalid presentation is supplied.
    assert(frames.count <= 4)
    displayedFrames = Array(frames.prefix(4))
    let retained = Set(displayedFrames.map(\.id))
    for id in Array(hosts.keys) where !retained.contains(id) {
      hosts.removeValue(forKey: id)?.removeFromSuperview()
    }
    for frame in displayedFrames {
      let selected = frame.id == selectedID
      if let host = hosts[frame.id] {
        if host.contentRevision != contentRevision { updateRoot(host, id: frame.id, selected: selected) }
      } else if let root = rootView(id: frame.id, selected: selected) {
        let host = NativeSpacePageHost(rootView: root)
        host.identifier = NSUserInterfaceItemIdentifier("NativeSpacePage:" + frame.id)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        host.autoresizingMask = []
        host.contentRevision = contentRevision; host.rootReplacementCount = 1
        host.isSelected = selected; host.setAccessibilityHidden(!selected)
        hosts[frame.id] = host; addSubview(host)
      }
    }
    layoutHosts()
  }

  private func rootView(id: String, selected: Bool) -> AnyView? {
    guard let content else { return nil }
    return AnyView(content(id, selected)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .environment(\.self, environment)
      .ignoresSafeArea()
      .allowsHitTesting(selected).accessibilityHidden(!selected))
  }
  private func updateRoot(_ host: NativeSpacePageHost, id: String, selected: Bool) {
    guard let root = rootView(id: id, selected: selected) else { return }
    host.rootView = root; host.contentRevision = contentRevision; host.rootReplacementCount &+= 1
    host.isSelected = selected; host.setAccessibilityHidden(!selected)
  }
  private func layoutHosts() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for frame in displayedFrames {
      guard let host = hosts[frame.id] else { continue }
      // A position sample never changes a page's proposed content dimensions.
      // Only an actual sidebar/window resize is allowed to reflow its contents.
      if host.frame.size != bounds.size { host.setFrameSize(bounds.size) }
      let origin = NSPoint(x: bounds.minX + frame.offset * bounds.width, y: bounds.minY)
      if host.frame.origin != origin { host.setFrameOrigin(origin) }
    }
    CATransaction.commit()
  }

  func detach() {
    framesObservation?.cancel(); framesObservation = nil
    viewport = nil; content = nil
    for host in hosts.values { host.removeFromSuperview() }
    hosts.removeAll(); displayedFrames = []
  }
  deinit { framesObservation?.cancel() }
}

/// Native hit testing and accessibility agree on the single authoritative page.
final class NativeSpacePageHost: NSHostingView<AnyView> {
  var isSelected = false
  var contentRevision: UInt64 = 0
  var rootReplacementCount: UInt64 = 0
  override var isOpaque: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSelected }
  override func hitTest(_ point: NSPoint) -> NSView? { isSelected ? super.hitTest(point) : nil }
}
