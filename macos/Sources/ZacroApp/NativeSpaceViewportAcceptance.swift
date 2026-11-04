import AppKit

/// Deterministic presentation and native scroll-lifetime checks. These do not
/// synthesize a trackpad gesture or certify physical pointer routing.
@MainActor
enum NativeSpaceViewportAcceptance {
  static func check() -> [String: Bool] {
    var result: [String: Bool] = [:]
    let ids = (0..<1_000).map { "space-\($0)" }
    let viewport = NativeSpaceViewport(automaticallyAdvance: false)
    viewport.synchronize(ids: ids, selectedID: ids[400], motionScale: 1, at: 0)
    result["space_viewport_bounds_thousand_spaces"] = viewport.frames.count == 3
      && Set(viewport.frames.map(\.id)) == Set([ids[399], ids[400], ids[401]])
    viewport.track(progress: 4.25)
    result["space_viewport_continuous_long_drag"] = viewport.frames.count == 4
      && near(viewport.frames.first(where: { $0.id == ids[404] })?.offset, -0.25)
      && near(viewport.frames.first(where: { $0.id == ids[405] })?.offset, 0.75)
    viewport.settle(selectedID: ids[404], duration: 0.14, motionScale: 1, at: 1)
    viewport.synchronize(ids: ids, selectedID: ids[404], motionScale: 1, at: 1)
    viewport.advance(at: 1.07)
    let moving = viewport.frames.first(where: { $0.id == ids[404] })?.offset ?? 99
    viewport.advance(at: 1 + 0.14)
    result["space_viewport_snap_preserves_destination"] = moving > -0.25 && moving < 0
      && near(viewport.frames.first(where: { $0.id == ids[404] })?.offset, 0) && !viewport.isAnimating
    viewport.synchronize(ids: ids, selectedID: ids[900], motionScale: 1, at: 2)
    result["space_distant_dot_one_viewport"] = near(viewport.frames.first(where: { $0.id == ids[900] })?.offset, 1)
      && viewport.frames.count <= 4 && !viewport.frames.contains(where: { $0.id == ids[650] })
    viewport.advance(at: 2.1)
    let midDotFrames = viewport.frames
    viewport.track(progress: 0)
    let idleDidNotCancel = viewport.frames == midDotFrames && viewport.isAnimating
    viewport.settle(selectedID: ids[900], duration: 0.1, motionScale: 1, at: 2.1)
    viewport.advance(at: 2.15)
    let retainedTarget = abs(viewport.frames.first(where: { $0.id == ids[900] })?.offset ?? 99) < 1
    viewport.synchronize(ids: ids, selectedID: ids[20], motionScale: 1, at: 2.1)
    viewport.advance(at: 2.4)
    result["space_dot_interruption_cannot_revert_selection"] = viewport.selectedID == ids[20]
      && near(viewport.frames.first(where: { $0.id == ids[20] })?.offset, 0) && viewport.frames.count == 3
      && idleDidNotCancel && retainedTarget
    viewport.synchronize(ids: ids, selectedID: ids[800], motionScale: 0, at: 3)
    result["space_reduced_motion_snaps_exactly"] = !viewport.isAnimating
      && near(viewport.frames.first(where: { $0.id == ids[800] })?.offset, 0)
    viewport.synchronize(ids: ["private-a", "private-b"], selectedID: "private-b", motionScale: 1, at: 4)
    result["space_profile_change_removes_old_previews"] = Set(viewport.frames.map(\.id)) == Set(["private-a", "private-b"])
      && !viewport.isAnimating

    let interrupted = NativeSpaceViewport(automaticallyAdvance: false)
    interrupted.synchronize(ids: ids, selectedID: ids[400], motionScale: 0, at: 0)
    var boundedInterruptions = true
    for turn in 0..<50 {
      let incoming = ids[turn.isMultiple(of: 2) ? 900 - turn : 20 + turn]
      interrupted.synchronize(ids: ids, selectedID: incoming, motionScale: 1, at: Double(turn) * 0.000_1)
      boundedInterruptions = boundedInterruptions && interrupted.frames.count <= 4
        && interrupted.frames.contains { $0.id == incoming }
    }
    result["space_rapid_dot_interruptions_keep_the_incoming_page_within_bounded_hosts"] = boundedInterruptions

    let continuity = NativeSpaceViewport(automaticallyAdvance: false)
    continuity.synchronize(ids: ids, selectedID: ids[200], motionScale: 0, at: 10)
    continuity.synchronize(ids: ids, selectedID: ids[201], motionScale: 1, at: 11)
    continuity.advance(at: 11.06)
    let beforeDotInterruption = continuity.frames.first(where: { $0.id == ids[201] })?.offset ?? 99
    continuity.track(progress: 0.12)
    let dotWasContinuous = near(continuity.frames.first(where: { $0.id == ids[201] })?.offset,
      beforeDotInterruption - 0.12) && continuity.isTracking && !continuity.isAnimating
    continuity.track(progress: 0)
    let reversalKeptOrigin = near(continuity.frames.first(where: { $0.id == ids[201] })?.offset,
      beforeDotInterruption) && continuity.isTracking
    continuity.track(progress: -0.2)
    result["space_finger_interrupts_dot_at_its_visual_position_and_preserves_zero_reversal"] = dotWasContinuous
      && reversalKeptOrigin && near(continuity.frames.first(where: { $0.id == ids[201] })?.offset,
        beforeDotInterruption + 0.2)

    continuity.synchronize(ids: ids, selectedID: ids[700], motionScale: 1, at: 12)
    let newerDot = continuity.frames
    continuity.cancelTracking()
    let newerDotSurvived = continuity.isAnimating && continuity.frames == newerDot
    continuity.advance(at: 12.3)
    result["space_old_contact_cancellation_cannot_finish_a_newer_dot_transition"] = newerDotSurvived
      && near(continuity.frames.first(where: { $0.id == ids[700] })?.offset, 0)

    continuity.track(progress: 0.6)
    continuity.settle(selectedID: ids[701], duration: 0.2, motionScale: 1, at: 13)
    continuity.advance(at: 13.05)
    let beforeSnapInterruption = continuity.frames.first(where: { $0.id == ids[701] })?.offset ?? 99
    continuity.track(progress: -0.1)
    let snapWasContinuous = near(continuity.frames.first(where: { $0.id == ids[701] })?.offset,
      beforeSnapInterruption + 0.1)
    continuity.cancelTracking()
    let activeCancelClearedOrigin = !continuity.isTracking && !continuity.isAnimating
      && !continuity.hasPendingTrackingPresentation
      && near(continuity.frames.first(where: { $0.id == ids[701] })?.offset, 0)
    continuity.track(progress: 0.15)
    result["space_finger_interrupts_snap_continuously_and_active_cancel_discards_its_origin"] = snapWasContinuous
      && activeCancelClearedOrigin
      && near(continuity.frames.first(where: { $0.id == ids[701] })?.offset, -0.15)
    continuity.stop()

    let cache = NativeSpaceScrollCache()
    let key = NativeSpaceScrollCache.Key(spaceID: "one", favorites: false)
    let favoriteKey = NativeSpaceScrollCache.Key(spaceID: "one", favorites: true)
    cache.store(346, for: key); cache.store(88, for: favoriteKey)
    let first = scroll(cache: cache, key: key, flipped: true)
    result["space_scroll_restores_exact_pixel_offset"] = near(Double(first.scroll.contentView.bounds.minY), 346)
    first.scroll.contentView.scroll(to: NSPoint(x: 0, y: 427))
    first.scroll.reflectScrolledClipView(first.scroll.contentView)
    first.observer.configure(cache: cache, key: key, active: false)
    first.scroll.contentView.scroll(to: .zero)
    first.observer.detach(); first.observer.removeFromSuperview()
    let second = scroll(cache: cache, key: key, flipped: true)
    result["space_scroll_survives_preview_and_rehosting"] = near(Double(cache.offset(for: key)), 427)
      && near(Double(second.scroll.contentView.bounds.minY), 427) && near(Double(cache.offset(for: favoriteKey)), 88)
    let unflipped = scroll(cache: cache, key: favoriteKey, flipped: false)
    result["space_scroll_supports_unflipped_documents"] = near(Double(unflipped.document.bounds.maxY - unflipped.scroll.contentView.bounds.maxY), 88)
    let small = scroll(cache: cache, key: key, flipped: true, documentHeight: 180)
    result["space_scroll_clamps_shortened_content"] = near(Double(small.scroll.contentView.bounds.minY),
      Double(max(0, small.document.bounds.height - small.scroll.contentView.bounds.height)))
    small.document.setFrameSize(NSSize(width: 200, height: 1_000))
    small.scroll.layoutSubtreeIfNeeded(); small.observer.layout()
    result["space_scroll_waits_for_complete_initial_layout"] = near(Double(small.scroll.contentView.bounds.minY), 427)
      && near(Double(cache.offset(for: key)), 427)
    cache.prune(spaceIDs: ["two"])
    result["space_scroll_forgets_deleted_spaces"] = cache.offset(for: key) == 0 && cache.offset(for: favoriteKey) == 0
    for item in [first, second, unflipped, small] { item.observer.detach() }
    return result
  }
  private static func near(_ value: Double?, _ target: Double) -> Bool { value.map { abs($0 - target) < 0.001 } ?? false }
  private struct ScrollFixture {
    let scroll: NSScrollView
    let document: NSView
    let observer: NativeSpaceScrollObserver
  }
  private static func scroll(cache: NativeSpaceScrollCache, key: NativeSpaceScrollCache.Key,
    flipped: Bool, documentHeight: CGFloat = 1_000) -> ScrollFixture {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false
    let document: NSView = flipped ? FlippedDocument() : NSView()
    document.frame = NSRect(x: 0, y: 0, width: 200, height: documentHeight)
    scroll.documentView = document
    let observer = NativeSpaceScrollObserver(frame: document.bounds)
    observer.configure(cache: cache, key: key, active: true)
    document.addSubview(observer)
    scroll.layoutSubtreeIfNeeded(); observer.layout()
    return .init(scroll: scroll, document: document, observer: observer)
  }
  private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
}
