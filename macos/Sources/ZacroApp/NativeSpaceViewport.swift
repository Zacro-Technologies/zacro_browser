import AppKit
import SwiftUI

/// Only the pages intersecting the sidebar and one neighboring page on either
/// side are hosted. Dot navigation slides one viewport, even across 100 Spaces;
/// a held trackpad gesture keeps its continuous physical position.
@MainActor
final class NativeSpaceViewport: ObservableObject {
  struct Frame: Identifiable, Equatable {
    let id: String
    let offset: Double
  }
  struct Blend: Equatable {
    let from: String
    let to: String
    let progress: Double
  }
  @Published private(set) var frames: [Frame] = []
  @Published private(set) var blend: Blend?
  @Published private(set) var isAnimating = false
  @Published private(set) var isTracking = false
  private(set) var selectedID: String?
  private var ids: [String] = []
  private var position = 0.0
  private var animation: Motion?
  private let clock = NativeMotionClock()
  private weak var motionView: NSView?
  private let automaticallyAdvance: Bool
  private struct Motion {
    let id = UUID()
    let started: TimeInterval
    let duration: Double
    let fromPosition: Double?
    let targetPosition: Double
    let starts: [Frame]
    let ends: [Frame]
    let appearance: Blend
  }

  init(automaticallyAdvance: Bool = true) { self.automaticallyAdvance = automaticallyAdvance }

  /// The anchor supplies this viewport's exact window content view. A zero-size
  /// SwiftUI attachment is only a locator, never the display-link source.
  func attachMotionView(_ view: NSView?) {
    guard motionView !== view else { return }
    clock.stop(); motionView = view
    guard automaticallyAdvance, let motion = animation else { return }
    guard let view, view.window != nil else { finish(); return }
    startClock(for: motion, in: view)
  }

  func synchronize(ids next: [String], selectedID selected: String, motionScale: Double,
    at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard let nextIndex = next.firstIndex(of: selected) else { reset(ids: next, selectedID: nil); return }
    guard ids == next, let previous = selectedID, next.contains(previous) else {
      reset(ids: next, selectedID: selected); return
    }
    guard previous != selected else {
      if motionScale <= 0, isAnimating { finish() }
      return
    }
    let previousIndex = next.firstIndex(of: previous) ?? nextIndex
    let direction = nextIndex > previousIndex ? 1.0 : -1.0
    // Preserve currently visible presentation offsets when a second selection
    // interrupts a transition. Offscreen pages never accumulate across clicks.
    var starts = frames.filter { abs($0.offset) < 1.000_001 }
    if !starts.contains(where: { $0.id == selected }) { starts.append(.init(id: selected, offset: direction)) }
    let ends = starts.map { frame in
      Frame(id: frame.id, offset: frame.id == selected ? 0
        : direction > 0 ? min(-1, frame.offset - 1) : max(1, frame.offset + 1))
    }
    self.selectedID = selected
    begin(Motion(started: time, duration: NativeMotion.chrome * max(0, motionScale), fromPosition: nil,
      targetPosition: Double(nextIndex), starts: starts, ends: ends,
      appearance: .init(from: previous, to: selected, progress: 0)))
  }

  func track(progress: Double) {
    guard let selectedID, let current = ids.firstIndex(of: selectedID), progress.isFinite else { return }
    // Idle/contact-began events do not own an in-flight dot animation. An
    // actual horizontal gesture takes over when it supplies feedback.
    if progress == 0 && !isTracking { return }
    cancelAnimation()
    isTracking = progress != 0
    position = Double(current) + progress
    presentPosition(position)
  }

  /// Called before the authoritative model changes selection, so its subsequent
  /// notification cannot turn a gesture snap into a second dot transition.
  func settle(selectedID selected: String, duration: Double, motionScale: Double,
    at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard let target = ids.firstIndex(of: selected), let previous = selectedID else { return }
    self.selectedID = selected
    begin(Motion(started: time, duration: max(0, duration * motionScale), fromPosition: position,
      targetPosition: Double(target), starts: [], ends: [],
      appearance: .init(from: previous, to: selected, progress: 0)))
  }

  func stop() { finish() }

  /// Explicit time makes interruption, snapping and bounded-host behavior
  /// reproducible without claiming physical trackpad input acceptance.
  func advance(at time: TimeInterval) {
    guard let motion = animation else { return }
    guard time < motion.started + motion.duration else { finish(); return }
    let fraction = motion.duration > 0 ? min(1, max(0, (time - motion.started) / motion.duration)) : 1
    guard fraction < 1 else { finish(); return }
    let progress = NativeMotion.progress(fraction)
    if let start = motion.fromPosition {
      position = start + (motion.targetPosition - start) * progress
      presentPosition(position)
    } else {
      frames = zip(motion.starts, motion.ends).map { start, end in
        .init(id: start.id, offset: start.offset + (end.offset - start.offset) * progress)
      }
      position = motion.targetPosition - (frames.first(where: { $0.id == selectedID })?.offset ?? 0)
      blend = .init(from: motion.appearance.from, to: motion.appearance.to, progress: progress)
    }
  }

  private func begin(_ motion: Motion) {
    cancelAnimation(); isTracking = false
    animation = motion
    guard motion.duration > 0 else { finish(); return }
    isAnimating = true
    advance(at: motion.started)
    guard automaticallyAdvance else { return }
    guard let motionView, motionView.window != nil else { finish(); return }
    startClock(for: motion, in: motionView)
  }
  private func startClock(for motion: Motion, in view: NSView) {
    let generation = motion.id
    clock.start(in: view, until: motion.started + motion.duration) { [weak self] time in
      guard let self, self.animation?.id == generation else { return }
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.finish() }
      else { self.advance(at: time) }
    }
  }
  private func cancelAnimation() {
    clock.stop(); animation = nil; isAnimating = false
  }
  private func finish() {
    cancelAnimation(); isTracking = false
    guard let selectedID, let index = ids.firstIndex(of: selectedID) else { frames = []; blend = nil; return }
    position = Double(index); presentPosition(position)
  }
  private func reset(ids: [String], selectedID: String?) {
    cancelAnimation(); isTracking = false; self.ids = ids; self.selectedID = selectedID
    finish()
  }
  private func presentPosition(_ value: Double) {
    guard !ids.isEmpty else { frames = []; blend = nil; return }
    let clamped = min(Double(ids.count - 1), max(0, value))
    let lower = Int(floor(clamped)), upper = Int(ceil(clamped))
    frames = (max(0, lower - 1)...min(ids.count - 1, upper + 1)).map {
      Frame(id: ids[$0], offset: Double($0) - value)
    }
    blend = .init(from: ids[lower], to: ids[upper], progress: clamped - Double(lower))
  }
}

/// Resolve the exact owning window without a global key-window/display guess.
struct NativeSpaceMotionAnchor: NSViewRepresentable {
  let viewport: NativeSpaceViewport
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor(); view.viewport = viewport; return view
  }
  func updateNSView(_ view: Anchor, context: Context) {
    if view.viewport !== viewport { view.viewport?.attachMotionView(nil); view.viewport = viewport }
    view.connect()
  }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.viewport?.attachMotionView(nil) }
  final class Anchor: NSView {
    weak var viewport: NativeSpaceViewport?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
    func connect() { viewport?.attachMotionView(window?.contentView) }
  }
}

/// Scroll offsets outlive a hosted preview page. Only the active Space writes;
/// offscreen preview layout cannot replace a user's saved position with zero.
@MainActor
final class NativeSpaceScrollCache {
  struct Key: Hashable { let spaceID: String; let favorites: Bool }
  private var offsets: [Key: CGFloat] = [:]
  func offset(for key: Key) -> CGFloat { offsets[key] ?? 0 }
  func store(_ offset: CGFloat, for key: Key) { if offset.isFinite { offsets[key] = max(0, offset) } }
  func prune(spaceIDs: Set<String>) { offsets = offsets.filter { spaceIDs.contains($0.key.spaceID) } }
}

struct NativeSpaceScrollAnchor: NSViewRepresentable {
  let cache: NativeSpaceScrollCache
  let spaceID: String
  let favorites: Bool
  let active: Bool
  func makeNSView(context: Context) -> NativeSpaceScrollObserver { NativeSpaceScrollObserver() }
  func updateNSView(_ view: NativeSpaceScrollObserver, context: Context) {
    view.configure(cache: cache, key: .init(spaceID: spaceID, favorites: favorites), active: active)
  }
  static func dismantleNSView(_ view: NativeSpaceScrollObserver, coordinator: ()) { view.detach() }
}

@MainActor
final class NativeSpaceScrollObserver: NSView {
  private weak var scroll: NSScrollView?
  private weak var document: NSView?
  private weak var cache: NativeSpaceScrollCache?
  private var key: NativeSpaceScrollCache.Key?
  private var active = false
  private var restored = false
  private var applying = false
  private var observations: [NSObjectProtocol] = []
  private var settleLayout: DispatchWorkItem?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { connect() } }
  override func layout() { super.layout(); connect(); restoreIfReady() }
  func configure(cache: NativeSpaceScrollCache, key: NativeSpaceScrollCache.Key, active: Bool) {
    if self.cache !== cache || self.key != key {
      settleLayout?.cancel(); settleLayout = nil
      restored = false; self.cache = cache; self.key = key
    } else if !self.active && active { restored = false }
    self.active = active
    connect(); restoreIfReady()
  }
  private func connect() {
    guard let found = enclosingScrollView else { return }
    guard scroll !== found || document !== found.documentView else { return }
    removeObservations(); scroll = found; document = found.documentView; restored = false
    let clip = found.contentView
    clip.postsBoundsChangedNotifications = true
    observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.applying else { return }
        if !self.restored, self.active,
          NSApp.currentEvent.map({ [.scrollWheel, .keyDown].contains($0.type) }) == true {
          self.settleLayout?.cancel(); self.settleLayout = nil; self.restored = true
        }
        if self.restored { self.save() } else { self.restoreIfReady() }
      }
    })
    for view in [clip, found.documentView].compactMap({ $0 }) {
      view.postsFrameChangedNotifications = true
      observations.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.restoreIfReady() }
      })
    }
    restoreIfReady()
  }
  private func restoreIfReady(allowClamping: Bool = false) {
    guard !restored, let scroll, let document = scroll.documentView, let key, let cache,
      scroll.contentView.bounds.height > 0, document.bounds.height > 0 else { return }
    let clip = scroll.contentView
    let maximum = max(0, document.bounds.height - clip.bounds.height)
    let requested = cache.offset(for: key), offset = min(requested, maximum)
    applying = true
    let y = document.isFlipped ? document.bounds.minY + offset : document.bounds.maxY - clip.bounds.height - offset
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(document.bounds.minY, y)))
    scroll.reflectScrolledClipView(clip)
    applying = false
    settleLayout?.cancel(); settleLayout = nil
    if requested <= maximum || allowClamping {
      restored = true
      if allowClamping { save() }
    } else if active {
      // SwiftUI may first publish a positive but incomplete document height.
      // Keep the requested offset through that layout, then clamp only after
      // the document frame settles; a real scroll/key input takes ownership.
      let work = DispatchWorkItem { [weak self] in self?.restoreIfReady(allowClamping: true) }
      settleLayout = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: work)
    }
  }
  private func save() {
    guard active, restored, !applying, let scroll, let document = scroll.documentView, let key, let cache else { return }
    let clip = scroll.contentView
    let offset = document.isFlipped ? clip.bounds.minY - document.bounds.minY : document.bounds.maxY - clip.bounds.maxY
    cache.store(min(max(0, document.bounds.height - clip.bounds.height), max(0, offset)), for: key)
  }
  func detach() { settleLayout?.cancel(); settleLayout = nil; removeObservations(); scroll = nil; document = nil; restored = false }
  private func removeObservations() {
    for observation in observations { NotificationCenter.default.removeObserver(observation) }
    observations = []
  }
  deinit { settleLayout?.cancel(); for observation in observations { NotificationCenter.default.removeObserver(observation) } }
}
