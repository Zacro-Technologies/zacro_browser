import AppKit

/// Real owned NSScrollView/document geometry and notifications; no provider,
/// displayed window or desktop input. Queued writes use the normal main queue.
@MainActor enum NativeAIAnswerScrollAcceptance {
  static func check() async -> [String: Bool] {
    var result: [String: Bool] = [:]
    let fixture = Fixture(), other = Fixture(), unflipped = Fixture(flipped: false), short = Fixture(height: 40)
    defer { for item in [fixture, other, unflipped, short] { item.close() } }

    fixture.position(distance: 79)
    fixture.grow(by: 500)
    await settle()
    result["AIAnswerGrowthUsesNearBottomPositionBeforeLargeLayoutChange"] = fixture.distance < 0.1

    fixture.grow(by: 300)
    fixture.scroll.setFrameSize(NSSize(width: 260, height: 120))
    fixture.scroll.layoutSubtreeIfNeeded(); fixture.observer.layout()
    await settle()
    result["AIAnswerPendingFollowSurvivesPostGrowthComposerViewportResize"] = fixture.distance < 0.1

    fixture.position(distance: 80)
    let boundary = fixture.origin
    fixture.grow(by: 200)
    await settle()
    result["AIAnswerFollowUsesReferenceStrict80PointThreshold"] = near(fixture.origin, boundary)

    fixture.position(distance: 300)
    let reading = fixture.origin
    fixture.grow(by: 240)
    await settle()
    result["AIAnswerGrowthPreservesReaderScrolledUp"] = near(fixture.origin, reading)

    fixture.position(distance: 0)
    fixture.grow(by: 300)
    fixture.position(distance: 440)
    let manual = fixture.origin
    await settle()
    result["AIAnswerQueuedFollowYieldsToLaterManualViewportChange"] = near(fixture.origin, manual)

    fixture.position(distance: 0)
    let beforeBatch = fixture.origin
    let postedFrame = fixture.document.postsFrameChangedNotifications
    let postedBounds = fixture.document.postsBoundsChangedNotifications
    // Deliver the first observation through the real clip scroll, after both
    // changes exist. No private scroll helper method or input is injected.
    fixture.document.postsFrameChangedNotifications = false
    fixture.document.postsBoundsChangedNotifications = false
    fixture.document.setFrameSize(NSSize(width: 260, height: fixture.document.frame.height + 300))
    fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: beforeBatch - 100))
    fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
    fixture.document.postsFrameChangedNotifications = postedFrame
    fixture.document.postsBoundsChangedNotifications = postedBounds
    fixture.observer.layout()
    await settle()
    result["AIAnswerBatchedGrowthAndReaderScrollUpPreservesReaderIntent"] = near(fixture.origin, beforeBatch - 100)

    fixture.position(distance: 0)
    fixture.grow(by: 120)
    fixture.grow(by: 260)
    await settle()
    result["AIAnswerFollowResumesAtBottomAndCoalescesFinalOrErrorGrowth"] = fixture.distance < 0.1

    fixture.grow(by: 220)
    fixture.observer.configure(enabled: false)
    let disabled = fixture.origin
    await settle()
    fixture.grow(by: 160)
    await settle()
    result["AIAnswerDisabledFollowingCancelsPendingAndFutureWrites"] = near(fixture.origin, disabled)
    fixture.position(distance: 0)
    fixture.observer.configure(enabled: true)
    fixture.grow(by: 150)
    await settle()
    result["AIAnswerReenabledFollowingUsesCurrentReaderPosition"] = fixture.distance < 0.1

    fixture.grow(by: 200)
    let oldOrigin = fixture.origin
    fixture.observer.removeFromSuperview()
    other.position(distance: 250)
    let otherOrigin = other.origin
    other.observer.detach(); other.observer.removeFromSuperview()
    other.document.addSubview(fixture.observer)
    fixture.observer.layout()
    other.grow(by: 180)
    await settle()
    result["AIAnswerReparentingRevokesOldPendingFollowAndKeepsNewOwnerPosition"] =
      near(fixture.origin, oldOrigin) && near(other.origin, otherOrigin)
    fixture.observer.removeFromSuperview()

    unflipped.position(distance: 0)
    unflipped.grow(by: 300)
    await settle()
    let bottom = unflipped.distance < 0.1
    unflipped.position(distance: 200)
    let reverseOrigin = unflipped.origin
    unflipped.grow(by: 300)
    await settle()
    result["AIAnswerFollowingSupportsUnflippedDocumentCoordinates"] = bottom && near(unflipped.origin, reverseOrigin)

    short.grow(by: 800)
    await settle()
    result["AIAnswerInitiallyShortTranscriptFollowsFirstOverflow"] = short.distance < 0.1
    short.document.setFrameSize(NSSize(width: 260, height: 400))
    short.scroll.layoutSubtreeIfNeeded(); short.observer.layout()
    let afterShrink = short.origin
    await settle()
    result["AIAnswerDocumentShrinkDoesNotScheduleAnotherScroll"] = near(short.origin, afterShrink)

    // Two simultaneous anchors share only their own flag leases. Removing one
    // must not disable the other; the last release restores original values.
    let flags = Fixture(notificationFlags: false)
    defer { flags.close() }
    let secondObserver = NativeAIAnswerScrollObserver(frame: .zero)
    flags.document.addSubview(secondObserver); secondObserver.layout()
    flags.observer.detach()
    let retained = flags.scroll.contentView.postsBoundsChangedNotifications && flags.document.postsFrameChangedNotifications
    secondObserver.detach(); secondObserver.removeFromSuperview()
    result["AIAnswerNotificationLeasesRestoreOnlyAfterLastOwnedObserver"] = retained
      && !flags.scroll.contentView.postsBoundsChangedNotifications && !flags.document.postsFrameChangedNotifications
    return result
  }

  private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.1 }
  private static func settle() async {
    // Drain already-enqueued AppKit notification/follow work without a timer.
    for _ in 0..<2 { await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
    } }
  }
  @MainActor private final class Fixture {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    let document: NSView
    let observer = NativeAIAnswerScrollObserver(frame: .zero)
    var origin: CGFloat { scroll.contentView.bounds.minY }
    var distance: CGFloat {
      let visible = scroll.documentVisibleRect
      return max(0, document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY)
    }
    init(flipped: Bool = true, height: CGFloat = 1_000, notificationFlags: Bool? = nil) {
      document = flipped ? FlippedDocument() : NSView()
      scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false
      document.frame = NSRect(x: 0, y: 0, width: 260, height: height)
      scroll.documentView = document
      if let notificationFlags {
        scroll.contentView.postsBoundsChangedNotifications = notificationFlags
        scroll.contentView.postsFrameChangedNotifications = notificationFlags
        document.postsBoundsChangedNotifications = notificationFlags
        document.postsFrameChangedNotifications = notificationFlags
      }
      document.addSubview(observer); scroll.layoutSubtreeIfNeeded(); observer.layout()
    }
    func position(distance: CGFloat) {
      let clip = scroll.contentView
      let y = document.isFlipped ? max(0, document.bounds.maxY - clip.bounds.height - distance) : distance
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
    }
    func grow(by amount: CGFloat) {
      document.setFrameSize(NSSize(width: document.frame.width, height: document.frame.height + amount))
      scroll.layoutSubtreeIfNeeded(); observer.layout()
    }
    func close() { observer.detach(); observer.removeFromSuperview(); scroll.documentView = nil }
  }
  private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
}
