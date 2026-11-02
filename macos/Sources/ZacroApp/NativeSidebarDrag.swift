import AppKit
import SwiftUI

/// The native source lives under the window, independently of the SwiftUI row
/// being reordered. A Space/category change can replace every row presentation
/// without detaching the source of an in-progress AppKit drag.
@MainActor
final class NativeSidebarDragController {
  var canStart: (String) -> Bool = { _ in false }
  var began: (String) -> Void = { _ in }
  var ended: () -> Void = {}
  var projectedRegion: () -> String? = { nil }
  var exitedRegion: () -> Void = {}
  var motionScale = 1.0
  var isDragging: Bool { lease != nil && lease?.isInvalidated == false }
  private var isEnabled = true
  private weak var host: NSView?
  private var anchors: [ObjectIdentifier: WeakAnchor] = [:]
  private var regions: [ObjectIdentifier: WeakAnchor] = [:]
  private var monitor: Any?
  private var windowClose: NSObjectProtocol?
  private var pressed: Press?
  private var lease: NativeSidebarDragLease?
  private var session: NSDraggingSession?

  private struct WeakAnchor {
    weak var view: NSView?
    let id: String
  }
  private struct Press {
    weak var view: NSView?
    let id: String
    let point: NSPoint
  }

  func attach(_ view: NSView) {
    guard let window = view.window else { detach(view); return }
    guard isEnabled else { host = view; return }
    if host === view, monitor != nil { return }
    host = view
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
      var result: NSEvent? = event
      MainActor.assumeIsolated { if let self { result = self.receive(event) } }
      return result
    }
    if let windowClose { NotificationCenter.default.removeObserver(windowClose) }
    windowClose = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
  }
  func detach(_ view: NSView) {
    guard host === view else { return }
    host = nil; pressed = nil
    // The source and close observer must survive sidebar/Space presentation
    // teardown until AppKit reports completion or the owning window closes.
    if lease == nil { removeObservers() }
  }
  func register(_ view: NSView, id: String) {
    anchors[ObjectIdentifier(view)] = WeakAnchor(view: view, id: id)
  }
  func unregister(_ view: NSView) { anchors.removeValue(forKey: ObjectIdentifier(view)) }
  func registerRegion(_ view: NSView, id: String) { regions[ObjectIdentifier(view)] = WeakAnchor(view: view, id: id) }
  func unregisterRegion(_ view: NSView) { regions.removeValue(forKey: ObjectIdentifier(view)) }

  /// Region geometry belongs to the whole section, not a row that moves under
  /// the pointer during reflow. Multiple Today anchors include its New Tab row.
  func regionContains(_ id: String, screenPoint: NSPoint) -> Bool? {
    guard let window = host?.window else { return nil }
    regions = regions.filter { $0.value.view != nil }
    let bounds = regions.values.compactMap { anchor -> NSRect? in
      guard anchor.id == id, let view = anchor.view, view.window === window,
        !view.isHiddenOrHasHiddenAncestor else { return nil }
      let visible = view.visibleRect.intersection(view.bounds)
      guard !visible.isEmpty else { return nil }
      return view.convert(visible, to: nil)
    }
    guard let first = bounds.first else { return nil }
    let union = bounds.dropFirst().reduce(first) { $0.union($1) }
    return union.contains(window.convertPoint(fromScreen: screenPoint))
  }
  private func moved() {
    // AppKit reports the drag image origin here; use the pointer's synchronous
    // position so a click offset inside the image cannot change the destination.
    guard isDragging, let id = projectedRegion(), regionContains(id, screenPoint: NSEvent.mouseLocation) == false else { return }
    exitedRegion()
  }

  func setEnabled(_ value: Bool) {
    if value { isEnabled = true }
    else { suspend() }
  }
  func cancel() {
    pressed = nil
    guard let lease, !lease.isInvalidated else { return }
    lease.invalidate()
    session?.animatesToStartingPositionsOnCancelOrFail = false
    session?.enumerateDraggingItems(options: [], for: nil, classes: [NSString.self], searchOptions: [:]) { item, _, _ in
      item.setDraggingFrame(item.draggingFrame, contents: nil)
    }
    // AppKit has no public NSDraggingSession.cancel(). Stop model work now,
    // but retain the inert source until AppKit delivers its terminal callback.
    ended()
  }
  func suspend() {
    isEnabled = false
    cancel()
    removeObservers()
  }

  private func receive(_ event: NSEvent) -> NSEvent? {
    if event.type == .leftMouseUp { pressed = nil; return event }
    guard lease == nil else { return event }
    guard isEnabled, let window = host?.window, window.isVisible, event.window === window, window.attachedSheet == nil,
      NSApp.modalWindow == nil else { pressed = nil; return event }
    if event.type == .leftMouseDown {
      pressed = nil
      guard !event.modifierFlags.contains(.control), event.clickCount == 1 else { return event }
      anchors = anchors.filter { $0.value.view != nil }
      for anchor in anchors.values {
        guard let view = anchor.view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
          canStart(anchor.id) else { continue }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point), view.visibleRect.contains(point) else { continue }
        pressed = Press(view: view, id: anchor.id, point: event.locationInWindow)
        break
      }
      return event
    }
    guard event.type == .leftMouseDragged, let press = pressed, let view = press.view,
      view.window === window, canStart(press.id) else { return event }
    let distance = hypot(event.locationInWindow.x - press.point.x, event.locationInWindow.y - press.point.y)
    guard distance >= 4, let parent = window.contentView else { return event }
    let frame = parent.convert(view.bounds, from: view).intersection(parent.bounds)
    guard frame.width > 1, frame.height > 1, let image = snapshot(view: parent, frame: frame) else { return event }
    pressed = nil
    let next = NativeSidebarDragLease(parent: parent) { [self] _ in finish() }
    next.source.didMove = { [weak self] _ in self?.moved() }
    lease = next
    let item = NSDraggingItem(pasteboardWriter: press.id as NSString)
    item.setDraggingFrame(next.source.convert(frame, from: parent), contents: image)
    began(press.id)
    // Starting a drag consumes the threshold-crossing event. The original
    // mouse-down is untouched, so clicks, modifier selection and focus keep
    // their normal SwiftUI behavior whenever no drag starts.
    session = next.source.beginDraggingSession(with: [item], event: event, source: next.source)
    session?.animatesToStartingPositionsOnCancelOrFail = motionScale > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    session?.draggingFormation = .none
    return nil
  }
  private func snapshot(view: NSView, frame: NSRect) -> NSImage? {
    // Capture only the controlled sidebar row, never a native page window.
    // AppKit chooses the backing-pixel dimensions for the current display.
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
    view.cacheDisplay(in: frame, to: bitmap)
    let image = NSImage(size: frame.size); image.addRepresentation(bitmap)
    return image
  }
  private func finish() {
    guard let previous = lease else { return }
    lease = nil; session = nil; pressed = nil
    if !previous.isInvalidated { ended() }
    if !isEnabled || host?.window == nil { removeObservers() }
  }
  private func close() {
    host = nil; pressed = nil; anchors.removeAll(); regions.removeAll()
    lease?.finish(operation: [])
    removeObservers()
  }
  private func removeObservers() {
    if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    if let windowClose { NotificationCenter.default.removeObserver(windowClose) }; windowClose = nil
  }
}

/// Owns precisely one terminal callback and one retained native source view.
/// It is also independently exercisable without synthesizing pointer input.
@MainActor
final class NativeSidebarDragLease {
  let source = NativeSidebarDragSource()
  private(set) var isInvalidated = false
  private var completion: ((NSDragOperation) -> Void)?
  init(parent: NSView, completion: @escaping (NSDragOperation) -> Void) {
    self.completion = completion
    source.frame = parent.bounds
    source.autoresizingMask = [.width, .height]
    source.setAccessibilityElement(false)
    parent.addSubview(source, positioned: .below, relativeTo: nil)
    source.didEnd = { [weak self] operation in self?.finish(operation: operation) }
  }
  func finish(operation: NSDragOperation) {
    guard let completion else { return }
    self.completion = nil
    source.didEnd = nil
    source.didMove = nil
    source.removeFromSuperview()
    completion(isInvalidated ? [] : operation)
  }
  func invalidate() { isInvalidated = true; source.permittedOperation = [] }
}

final class NativeSidebarDragSource: NSView, NSDraggingSource {
  var didEnd: ((NSDragOperation) -> Void)?
  var didMove: ((NSPoint) -> Void)?
  var permittedOperation: NSDragOperation = .move
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { permittedOperation }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { didMove?(screenPoint) }
  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { didEnd?(operation) }
}

struct NativeSidebarDragHost: NSViewRepresentable {
  let controller: NativeSidebarDragController
  let isEnabled: Bool
  let motionScale: Double
  let canStart: (String) -> Bool
  let began: (String) -> Void
  let ended: () -> Void
  let projectedRegion: () -> String?
  let exitedRegion: () -> Void
  func makeNSView(context: Context) -> HostView {
    let view = HostView(); view.controller = controller; return view
  }
  func updateNSView(_ view: HostView, context: Context) {
    controller.setEnabled(isEnabled)
    controller.motionScale = motionScale
    controller.canStart = canStart; controller.began = began; controller.ended = ended
    controller.projectedRegion = projectedRegion; controller.exitedRegion = exitedRegion
    controller.attach(view)
  }
  static func dismantleNSView(_ view: HostView, coordinator: ()) { view.controller?.detach(view) }
  final class HostView: NSView {
    weak var controller: NativeSidebarDragController?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller?.attach(self) }
  }
}

struct NativeSidebarDropRegion: NSViewRepresentable {
  let controller: NativeSidebarDragController
  let id: String
  func makeNSView(context: Context) -> RegionView {
    let view = RegionView(); view.controller = controller; controller.registerRegion(view, id: id); return view
  }
  func updateNSView(_ view: RegionView, context: Context) { controller.registerRegion(view, id: id) }
  static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.controller?.unregisterRegion(view) }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: RegionView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
  final class RegionView: NSView {
    weak var controller: NativeSidebarDragController?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

struct NativeSidebarDragAnchor: NSViewRepresentable {
  let controller: NativeSidebarDragController
  let id: String
  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView(); view.controller = controller; controller.register(view, id: id); return view
  }
  func updateNSView(_ view: AnchorView, context: Context) { controller.register(view, id: id) }
  static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.controller?.unregister(view) }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnchorView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
  final class AnchorView: NSView {
    weak var controller: NativeSidebarDragController?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
