import XCTest
@testable import ZacroCore

/// Release and contact scenarios from the shipping Electron recognizer, driven
/// by an injected clock so neither test timing nor trackpad inertia affects them.
final class SpaceGestureTests: XCTestCase {
  private func event(_ milliseconds: Double, _ dx: Double = 0, dy: Double = 0,
                     width: Double = 224, index: Int = 1, count: Int = 3,
                     context: String = "regular", phase: SpaceGesture.ContactPhase = .none,
                     momentum: Bool? = nil, mode: SpaceGesture.DeltaMode = .pixels,
                     shift: Bool = false, blocked: Bool = false) -> SpaceGesture.Input {
    .init(time: milliseconds / 1000, deltaX: dx, deltaY: dy, width: width,
          index: index, count: count, contextKey: context, phase: phase,
          momentum: momentum, deltaMode: mode, shiftKey: shift, blocked: blocked)
  }
  func testLiveDragFollowsDistanceAndOnlyCommitsOnceAfterRelease() {
    var gesture = SpaceGesture()
    for (time, distance) in [(0.0, 40.0), (35, 80), (70, 120), (105, 160)] {
      let result = gesture.update(event(time, 40))
      XCTAssertEqual(result.phase, .tracking); XCTAssertEqual(result.commit, 0)
      XCTAssertEqual(result.offset, -distance); XCTAssertEqual(result.progress, distance / 224)
      XCTAssertTrue(result.consumed)
    }
    XCTAssertFalse(gesture.settle(at: 0.284).didRelease)
    let release = gesture.settle(at: 0.285)
    XCTAssertEqual(release.commit, 1); XCTAssertEqual(release.targetIndex, 2)
    XCTAssertEqual(release.fromOffset, -160); XCTAssertEqual(release.offset, -224)
    XCTAssertEqual(release.reason, .quiet); XCTAssertEqual(release.duration, 0.169)
    XCTAssertEqual(gesture.settle(at: 0.425).commit, 0)
  }
  func testSnapDistanceScalesWithActualSidebarWidth() {
    var narrow = SpaceGesture(), wide = SpaceGesture()
    _ = narrow.update(event(0, 100, width: 200)); _ = wide.update(event(0, 100, width: 380))
    XCTAssertEqual(narrow.settle(at: 0.180).commit, 1)
    let back = wide.settle(at: 0.180)
    XCTAssertEqual(back.phase, .settling); XCTAssertEqual(back.commit, 0)
    XCTAssertEqual(back.selectedIndex, 1); XCTAssertEqual(back.fromOffset, -100); XCTAssertEqual(back.offset, 0)
  }
  func testShortFlickRequiresRealRecentVelocity() {
    var flick = SpaceGesture()
    _ = flick.update(event(0, -20)); _ = flick.update(event(20, -26))
    XCTAssertEqual(flick.settle(at: 0.200).commit, -1)
    var slow = SpaceGesture(), single = SpaceGesture()
    _ = slow.update(event(0, -20)); _ = slow.update(event(90, -26))
    _ = single.update(event(90, -46))
    XCTAssertEqual(slow.settle(at: 0.270).commit, 0)
    XCTAssertEqual(single.settle(at: 0.270).commit, 0)
  }
  func testReversingCancelsOldVelocityAndCanUnwindToOrigin() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 140))
    XCTAssertEqual(gesture.update(event(40, -40)).offset, -100)
    XCTAssertEqual(gesture.settle(at: 0.220).commit, 0)
    var unwind = SpaceGesture()
    _ = unwind.update(event(0, 40))
    XCTAssertEqual(unwind.update(event(40, -30)).offset, -10)
    XCTAssertEqual(unwind.update(event(80, -10)).offset, 0)
    XCTAssertEqual(unwind.settle(at: 0.260).commit, 0)
  }
  func testKnownContactCanPauseAndReleaseWithoutFinalDelta() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 120, phase: .began))
    XCTAssertFalse(gesture.settle(at: 2).didRelease)
    XCTAssertEqual(gesture.update(event(2_100, 10, phase: .changed)).offset, -130)
    let release = gesture.update(event(2_130, phase: .ended))
    XCTAssertEqual(release.commit, 1); XCTAssertEqual(release.reason, .phaseEnd)
    XCTAssertEqual(release.fromOffset, -130)
    var cancelled = SpaceGesture()
    _ = cancelled.update(event(0, 160, phase: .began))
    let result = cancelled.update(event(30, phase: .cancelled))
    XCTAssertEqual(result.commit, 0); XCTAssertEqual(result.selectedIndex, 1)
    XCTAssertEqual(result.reason, .cancelled)
  }
  func testMomentumNeverContributesTravelOrCommitsAgain() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 100, momentum: false))
    let release = gesture.update(event(20, 500, momentum: true))
    XCTAssertEqual(release.commit, 1); XCTAssertEqual(release.fromOffset, -100)
    XCTAssertEqual(release.reason, .momentum)
    for time in [40.0, 500, 2_000] {
      XCTAssertEqual(gesture.update(event(time, 900, index: 2, momentum: true)).commit, 0)
    }
    XCTAssertEqual(gesture.update(event(2_010, -120, index: 2, momentum: false)).phase, .tracking)
    XCTAssertEqual(gesture.settle(at: 2.190).commit, -1)
    var short = SpaceGesture()
    _ = short.update(event(0, 20, momentum: false))
    XCTAssertEqual(short.update(event(20, 500, momentum: true)).commit, 0)
  }
  func testConservativeTailDetectionOnlyAppliesWithoutNativeContact() {
    for known in [false, true] {
      var gesture = SpaceGesture(), result: SpaceGesture.Output?
      for (time, dx) in [(0.0, 40.0), (16, 32), (32, 24), (48, 16)] {
        result = gesture.update(event(time, dx, momentum: known ? false : nil))
      }
      XCTAssertEqual(result?.commit, known ? 0 : 1)
      XCTAssertEqual(result?.reason, known ? nil : .deceleration)
    }
    var stable = SpaceGesture()
    for index in 0..<8 { XCTAssertFalse(stable.update(event(Double(index * 65), 20)).didRelease) }
    XCTAssertEqual(stable.settle(at: 0.635).commit, 1)
  }
  func testContactlessReleaseStaysLockedUntilQuiet() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 120, index: 0))
    XCTAssertEqual(gesture.settle(at: 0.180).commit, 1)
    for index in 0..<8 {
      let result = gesture.update(event(Double(160 + index * 70), index.isMultiple(of: 2) ? 100 : -100))
      XCTAssertEqual(result.commit, 0); XCTAssertEqual(result.offset, 0)
    }
    _ = gesture.update(event(970, 120))
    XCTAssertEqual(gesture.settle(at: 1.150).commit, 1)
  }
  func testVerticalAndDiagonalScrollingKeepTheirOriginalAxis() {
    for dx in [0.0, 20] {
      var gesture = SpaceGesture()
      XCTAssertFalse(gesture.update(event(0, dx, dy: 20)).consumed)
      XCTAssertFalse(gesture.update(event(30, 100)).consumed)
      XCTAssertEqual(gesture.settle(at: 0.210).commit, 0)
    }
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, dy: 2))
    XCTAssertEqual(gesture.update(event(10, 20, dy: 1)).phase, .tracking)
    XCTAssertEqual(gesture.update(event(30, 20, dy: 12)).offset, -40)
  }
  func testEdgesRubberBandWithoutWrappingAndPermitDeliberateReversal() {
    var gesture = SpaceGesture()
    let edge = gesture.update(event(0, -1_000, index: 0))
    XCTAssertEqual(edge.phase, .edge); XCTAssertGreaterThan(edge.offset, 0); XCTAssertLessThan(edge.offset, 24)
    XCTAssertNil(edge.targetIndex); XCTAssertEqual(gesture.settle(at: 0.180).commit, 0)
    var reverse = SpaceGesture()
    _ = reverse.update(event(0, -1_000, index: 0))
    _ = reverse.update(event(60, 220, index: 0))
    XCTAssertEqual(reverse.settle(at: 0.240).commit, 1)
  }
  func testBlockedInputsProfileChangesAndSelectionChangesCancelOldStream() {
    for input in [event(20, 120, blocked: true), event(20, 120, context: "private"),
                  event(20, 120, index: 0), event(20, 120, count: 4), event(20, 120, index: -1)] {
      var gesture = SpaceGesture()
      _ = gesture.update(event(0, 120))
      let blocked = gesture.update(input)
      XCTAssertEqual(blocked.commit, 0); XCTAssertFalse(blocked.consumed)
      XCTAssertEqual(gesture.settle(at: 0.200).commit, 0)
    }
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 120)); gesture.interrupt(at: 0.020)
    XCTAssertEqual(gesture.update(event(40, 100)).commit, 0)
    _ = gesture.update(event(360, 120))
    XCTAssertEqual(gesture.settle(at: 0.540).commit, 1)
  }
  func testLinePageAndShiftWheelNormalizeBeforeRecognition() {
    for (input, expected) in [(event(0, -7, mode: .lines), -1),
                              (event(0, 1, mode: .pages), 1),
                              (event(0, dy: -100, shift: true), -1)] {
      var gesture = SpaceGesture()
      _ = gesture.update(input)
      XCTAssertEqual(gesture.settle(at: 0.180).commit, expected)
    }
  }
  func testMalformedAndZeroDeltasCannotPoisonOrExtendGesture() {
    var gesture = SpaceGesture()
    for dx in [Double.nan, .infinity, -.infinity, 0] { XCTAssertTrue(gesture.update(event(0, dx)).offset.isFinite) }
    _ = gesture.update(event(10, 120)); _ = gesture.update(event(189))
    XCTAssertEqual(gesture.settle(at: 0.190).commit, 1)
    XCTAssertFalse(gesture.update(event(500, 100, index: -1)).consumed)
  }
  func testContinuousLongContactCanReachEverySpaceAndSnapsExactlyOnce() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 100, index: 0, count: 6, phase: .began))
    XCTAssertEqual(gesture.settle(at: 2).phase, .tracking)
    XCTAssertEqual(gesture.update(event(2_100, 300, index: 0, count: 6, phase: .changed)).offset, -400)
    XCTAssertEqual(gesture.update(event(2_200, 240, index: 0, count: 6, phase: .changed)).position, 640 / 224)
    let release = gesture.update(event(2_300, index: 0, count: 6, phase: .ended))
    XCTAssertEqual(release.commit, 3); XCTAssertEqual(release.targetIndex, 3); XCTAssertEqual(release.offset, -672)
    XCTAssertFalse(gesture.update(event(2_310, 1_000, index: 3, count: 6, momentum: true)).didRelease)
  }
  func testMultiPageReversalSettlesAtPageUnderFingers() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 100, index: 0, count: 6, phase: .began))
    _ = gesture.update(event(300, 560, index: 0, count: 6, phase: .changed))
    _ = gesture.update(event(380, -100, index: 0, count: 6, phase: .changed))
    let release = gesture.update(event(420, index: 0, count: 6, phase: .ended))
    XCTAssertEqual(release.commit, 2); XCTAssertEqual(release.targetIndex, 2)
  }
  func testDelayedNativePhaseRetainsDistanceAndOwnsReleaseDeadline() {
    var gesture = SpaceGesture()
    XCTAssertEqual(gesture.update(event(0, 120)).offset, -120)
    XCTAssertEqual(gesture.update(event(20, phase: .changed)).offset, -120)
    XCTAssertTrue(gesture.hasKnownContactPhase)
    XCTAssertEqual(gesture.settle(at: 2).phase, .tracking)
    XCTAssertEqual(gesture.update(event(2_100, phase: .ended)).commit, 1)
  }
  func testQuickLargeFlickAlwaysSelectsOneNeighborInBothDirections() {
    for direction in [-1.0, 1] {
      var gesture = SpaceGesture()
      _ = gesture.update(event(0, direction * 150, index: 3, count: 7, phase: .began))
      let drag = gesture.update(event(35, direction * 600, index: 3, count: 7, phase: .changed))
      XCTAssertLessThanOrEqual(abs(drag.offset), 224 * 1.05)
      let release = gesture.update(event(55, index: 3, count: 7, phase: .ended))
      XCTAssertEqual(release.commit, Int(direction)); XCTAssertEqual(release.targetIndex, 3 + Int(direction))
      XCTAssertEqual(gesture.update(event(65, direction * 900, index: 3 + Int(direction), count: 7, momentum: true)).commit, 0)
    }
  }
  func testSustainedFastReleaseUsesDistanceWithoutVelocityProjection() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 30, index: 0, count: 7, phase: .began))
    _ = gesture.update(event(500, 300, index: 0, count: 7, phase: .changed))
    _ = gesture.update(event(520, 190, index: 0, count: 7, phase: .changed))
    let release = gesture.update(event(525, index: 0, count: 7, phase: .ended))
    XCTAssertEqual(release.commit, 2); XCTAssertEqual(release.offset, -448)
  }
  func testPhaseLessMouseRearmsAfterCompletedNativeStreamButNotDuringHeldContact() {
    var gesture = SpaceGesture()
    _ = gesture.update(event(0, 120, phase: .began))
    XCTAssertEqual(gesture.update(event(50, phase: .ended)).commit, 1)
    XCTAssertEqual(gesture.update(event(400, -120, index: 2)).phase, .tracking)
    XCTAssertEqual(gesture.settle(at: 0.580).commit, -1)
    var held = SpaceGesture()
    _ = held.update(event(0, 100, index: 0, count: 6, phase: .began))
    XCTAssertEqual(held.update(event(2_000, 300, index: 0, count: 6)).offset, -400)
    XCTAssertFalse(held.settle(at: 4).didRelease)
    XCTAssertEqual(held.update(event(4_100, index: 0, count: 6, phase: .ended)).commit, 2)
  }
}
