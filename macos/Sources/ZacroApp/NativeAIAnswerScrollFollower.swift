import AppKit
import SwiftUI

/// Put this anchor inside the transcript document, not outside its ScrollView.
/// Match renderer shouldFollowAI(): only a reader less than 80pts from the end
/// before content growth follows the next streamed/final/error layout.
struct NativeAIAnswerScrollFollower: NSViewRepresentable {
  var followsGrowth = true
  func makeNSView(context: Context) -> NativeAIAnswerScrollObserver { NativeAIAnswerScrollObserver() }
  func updateNSView(_ view: NativeAIAnswerScrollObserver, context: Context) { view.configure(enabled: followsGrowth) }
  static func dismantleNSView(_ view: NativeAIAnswerScrollObserver, coordinator: ()) { view.detach() }
}

@MainActor final class NativeAIAnswerScrollObserver: NSView {
  private struct Geometry {
    let document: CGRect
    let visible: CGRect
    let flipped: Bool
    var distanceFromBottom: CGFloat {
      max(0, flipped ? document.maxY - visible.maxY : visible.minY - document.minY)
    }
  }
  private weak var scroll: NSScrollView?
  private weak var document: NSView?
  private var observations: [NSObjectProtocol] = []
  private var notificationLeases: [NativeAIViewNotificationLease] = []
  private var geometry: Geometry?
  private var enabled = true
  private var follows = false
  private var applying = false
  private var generation: UInt64 = 0
  private var pending: DispatchWorkItem?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func isAccessibilityElement() -> Bool { false }
  override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { detach() } else { connect() }
  }
  override func layout() { super.layout(); connect(); changed() }

  func configure(enabled: Bool) {
    if self.enabled != enabled {
      cancelPending(); self.enabled = enabled
      geometry = snapshot(); follows = geometry.map { $0.distanceFromBottom < 80 } ?? false
    }
    connect()
  }
  private func connect() {
    guard let found = enclosingScrollView, let nextDocument = found.documentView else { detach(); return }
    guard scroll !== found || document !== nextDocument else { return }
    detach(); scroll = found; document = nextDocument
    geometry = snapshot(); follows = geometry.map { $0.distanceFromBottom < 80 } ?? false
    let clip = found.contentView
    notificationLeases = [.acquire(clip, kind: .bounds), .acquire(clip, kind: .frame),
      .acquire(nextDocument, kind: .bounds), .acquire(nextDocument, kind: .frame)]
    for (view, name) in [(clip, NSView.boundsDidChangeNotification), (clip, NSView.frameDidChangeNotification),
      (nextDocument, NSView.boundsDidChangeNotification), (nextDocument, NSView.frameDidChangeNotification)] {
      observations.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.changed() }
      })
    }
  }
  private func snapshot() -> Geometry? {
    guard let scroll, let document, scroll.documentView === document,
      scroll.contentView.bounds.height > 0, document.bounds.height.isFinite else { return nil }
    return Geometry(document: document.bounds, visible: scroll.documentVisibleRect, flipped: document.isFlipped)
  }
  private func changed() {
    guard !applying, let next = snapshot() else { return }
    guard let before = geometry else {
      geometry = next; follows = next.distanceFromBottom < 80; return
    }
    geometry = next
    if next.document.height > before.document.height {
      let previousOffset = before.visible.minY - before.document.minY
      let currentOffset = next.visible.minY - next.document.minY
      let movedAway = next.flipped ? currentOffset < previousOffset : currentOffset > previousOffset
      if next.visible.size == before.visible.size && movedAway {
        // The first observation can combine growth with a real scroll-up.
        // Its unchanged viewport size distinguishes it from composer resizing.
        cancelPending(); follows = next.distanceFromBottom < 80; return
      }
      // A clip bounds notification may arrive before the document frame one.
      // Consult the cached pre-growth intent, never the enlarged tail gap.
      if enabled && follows { scheduleFollow() }
    } else if next.document != before.document {
      cancelPending(); follows = next.distanceFromBottom < 80
    } else if next.visible.size != before.visible.size {
      // Composer/status layout can resize the viewport after the transcript
      // grows. That is not a reader scroll; keep the queued pre-growth intent
      // and compute its destination from the final viewport dimensions.
      if pending != nil && enabled && follows { scheduleFollow() }
      else { follows = next.distanceFromBottom < 80 }
    } else if next.visible.origin != before.visible.origin {
      // Manual wheel/keyboard/programmatic scrolling has the same ownership:
      // a changed viewport invalidates any older queued follow before writing.
      cancelPending(); follows = next.distanceFromBottom < 80
    }
  }
  private func scheduleFollow() {
    cancelPending()
    let expected = generation
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == expected, self.enabled, self.follows,
        let scroll = self.scroll, let document = self.document,
        self.enclosingScrollView === scroll, scroll.documentView === document,
        let current = self.snapshot() else { return }
      self.pending = nil
      // Scroll in clip coordinates. The document can be flipped or unflipped;
      // its converted bottom-edge displacement is added to the current origin.
      let bottom = current.flipped
        ? CGPoint(x: current.visible.minX, y: current.document.maxY)
        : CGPoint(x: current.visible.minX, y: current.document.minY)
      let bottomInClip = scroll.contentView.convert(bottom, from: document)
      let clip = scroll.contentView
      let targetY = clip.isFlipped ? bottomInClip.y - clip.bounds.height : bottomInClip.y
      let proposed = CGRect(x: clip.bounds.minX, y: targetY, width: clip.bounds.width, height: clip.bounds.height)
      let target = clip.constrainBoundsRect(proposed).origin
      guard abs(target.y - clip.bounds.minY) > 0.01 else { self.geometry = current; return }
      self.applying = true
      clip.scroll(to: target); scroll.reflectScrolledClipView(clip)
      self.applying = false
      self.geometry = self.snapshot(); self.follows = self.geometry.map { $0.distanceFromBottom < 80 } ?? false
    }
    pending = work; DispatchQueue.main.async(execute: work)
  }
  private func cancelPending() { generation &+= 1; pending?.cancel(); pending = nil }
  func detach() {
    cancelPending()
    observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
    notificationLeases.forEach { $0.release() }; notificationLeases.removeAll()
    scroll = nil; document = nil; geometry = nil; follows = false
  }
  deinit {
    pending?.cancel()
    observations.forEach(NotificationCenter.default.removeObserver)
    // Representable dismantling and view detachment normally release these.
    // SwiftUI can also destroy the hierarchy without either callback.
    let leases = notificationLeases
    Task { @MainActor in leases.forEach { $0.release() } }
  }
}

/// Share only this helper's notification flag changes; the last lease restores
/// the prior value, and never overrides a flag its owner has since disabled.
@MainActor private final class NativeAIViewNotificationLease {
  enum Kind: Hashable { case bounds, frame }
  private struct Key: Hashable { let view: ObjectIdentifier; let kind: Kind }
  private final class Entry {
    weak var view: NSView?
    let original: Bool
    var count = 1
    init(view: NSView, original: Bool) { self.view = view; self.original = original }
  }
  private static var entries: [Key: Entry] = [:]
  private let key: Key
  private let entry: Entry
  private var released = false
  private init(key: Key, entry: Entry) { self.key = key; self.entry = entry }
  static func acquire(_ view: NSView, kind: Kind) -> NativeAIViewNotificationLease {
    let key = Key(view: ObjectIdentifier(view), kind: kind)
    if let entry = entries[key], entry.view === view { entry.count += 1 }
    else {
      let original = kind == .bounds ? view.postsBoundsChangedNotifications : view.postsFrameChangedNotifications
      entries[key] = Entry(view: view, original: original)
      if kind == .bounds { view.postsBoundsChangedNotifications = true } else { view.postsFrameChangedNotifications = true }
    }
    return NativeAIViewNotificationLease(key: key, entry: entries[key]!)
  }
  func release() {
    guard !released else { return }; released = true
    guard Self.entries[key] === entry else { return }
    entry.count -= 1
    guard entry.count == 0 else { return }
    Self.entries.removeValue(forKey: key)
    guard let view = entry.view, !entry.original else { return }
    if key.kind == .bounds, view.postsBoundsChangedNotifications { view.postsBoundsChangedNotifications = false }
    if key.kind == .frame, view.postsFrameChangedNotifications { view.postsFrameChangedNotifications = false }
  }
}
