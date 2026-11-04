import AppKit
import Combine
import SwiftUI

/// Validate the native presentation boundary without synthesizing a trackpad
/// gesture or treating these geometry/cancellation checks as an FPS result.
@MainActor
enum NativeSpacePageStripAcceptance {
  static func run(in window: NSWindow) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      window.identifier?.rawValue.hasPrefix("ZacroBrowserWindow:") == true,
      window.isVisible, let root = window.contentView, root.window === window else {
      throw Failure("The native strip fixture requires its exact visible browser window")
    }
    let ids = (0..<10).map { "strip-space-\($0)" }
    let viewport = NativeSpaceViewport(automaticallyAdvance: false)
    viewport.synchronize(ids: ids, selectedID: ids[4], motionScale: 0)
    let view = NativeSpacePageStripView(frame: CGRect(x: -2_000, y: -2_000, width: 224, height: 420))
    root.addSubview(view, positioned: .below, relativeTo: nil)
    var environment = EnvironmentValues()
    environment[ProbeKey.self] = "owned-strip-environment"
    environment.layoutDirection = .rightToLeft
    let automatic = NativeSpaceViewport()
    defer { automatic.stop(); automatic.attachMotionView(nil); view.detach(); view.removeFromSuperview() }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw Failure(name) }
      checks.append(name)
    }
    func wait(_ name: String, condition: () -> Bool) async throws {
      let end = ProcessInfo.processInfo.systemUptime + 1
      while ProcessInfo.processInfo.systemUptime < end {
        try Task.checkCancellation()
        guard window.contentView === root, root.window === window else { throw Failure("The strip owner changed") }
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw Failure(name)
    }
    let content: @MainActor (String, Bool) -> AnyView = { id, selected in
      AnyView(Probe().overlay(Text(id + (selected ? " selected" : " preview"))))
    }
    view.configure(viewport: viewport, selectedID: ids[4], environment: environment, content: content)
    view.layoutSubtreeIfNeeded()
    let initial = view.hosts
    let initialReplacements = initial.mapValues(\.rootReplacementCount)
    for progress in [0.2, 0.4, 0.6, 0.8, 0.3] { viewport.track(progress: progress) }
    try require(initial.allSatisfy { id, host in view.hosts[id] === host
        && host.rootReplacementCount == initialReplacements[id] }
      && view.hosts.count == 4 && view.hosts.values.allSatisfy { $0.frame.size == view.bounds.size }
      && view.displayedFrames.allSatisfy { frame in
        view.hosts[frame.id]?.frame.origin == CGPoint(x: frame.offset * view.bounds.width, y: 0)
      }, "spaceNativeStripMovesRetainedConstantSizeHostsWithoutReplacingFractionalRoots")

    view.setFrameSize(NSSize(width: 286, height: 470)); view.layoutSubtreeIfNeeded()
    try require(view.hosts.values.allSatisfy { $0.frame.size == view.bounds.size && $0.safeAreaRegions.isEmpty }
      && initial.allSatisfy { id, host in host.rootReplacementCount == initialReplacements[id] },
      "spaceNativeStripResizesOnlyForItsActualBoundsWithoutTitlebarInsets")

    let retainedBeforeModel = view.hosts
    let modelReplacements = retainedBeforeModel.mapValues(\.rootReplacementCount)
    view.configure(viewport: viewport, selectedID: ids[5], environment: environment, content: content)
    view.layoutSubtreeIfNeeded()
    try await wait("The native strip did not forward its complete SwiftUI environment") {
      view.hosts.values.allSatisfy { host in
        probes(in: host).contains { $0.value == "owned-strip-environment" && $0.direction == .rightToLeft }
      }
    }
    try require(retainedBeforeModel.allSatisfy { id, host in view.hosts[id] === host
        && host.rootReplacementCount == (modelReplacements[id] ?? 0) + 1 }
      && view.hosts[ids[5]]?.isAccessibilityHidden() == false
      && view.hosts.filter { $0.key != ids[5] }.allSatisfy { _, host in
        host.isAccessibilityHidden() && host.hitTest(CGPoint(x: host.frame.midX, y: host.frame.midY)) == nil
      }, "spaceNativeStripRefreshesModelsAndExposesOnlyTheSelectedPage")

    viewport.track(progress: 4.25)
    try require(view.hosts.count <= 4 && initial.values.allSatisfy { $0.superview == nil },
      "spaceNativeStripRetiresOffscreenHostsAtTheBoundedCacheEdge")
    view.detach()
    viewport.track(progress: 0.4)
    try require(view.hosts.isEmpty && view.subviews.isEmpty,
      "spaceNativeStripDetachStopsOldViewportSubscriptions")

    automatic.attachMotionView(root)
    automatic.synchronize(ids: ids, selectedID: ids[4], motionScale: 0)
    var publications = 0
    let observer = automatic.$frames.dropFirst().sink { _ in publications += 1 }
    defer { observer.cancel() }
    let baseline = automatic.frames
    automatic.track(progress: 0.1); automatic.track(progress: 0.4); automatic.track(progress: 0.9)
    let queuedBeforeYield = automatic.frames == baseline && automatic.hasPendingTrackingPresentation && publications == 0
    try await wait("The display-paced strip did not publish its latest raw sample") { !automatic.hasPendingTrackingPresentation }
    let presented = automatic.frames
    try await Task.sleep(for: .milliseconds(80))
    try require(queuedBeforeYield && publications == 1 && automatic.frames == presented
      && near(automatic.frames.first(where: { $0.id == ids[4] })?.offset, -0.9),
      "spaceTrackingCoalescesRawSamplesIntoOnePresentationWithoutIdlePublications")

    automatic.track(progress: 0.2); automatic.track(progress: 0.6)
    automatic.settle(selectedID: ids[5], duration: 0.2, motionScale: 1)
    let flushedAtRelease = !automatic.hasPendingTrackingPresentation && automatic.selectedID == ids[5]
      && near(automatic.frames.first(where: { $0.id == ids[4] })?.offset, -0.6)
    automatic.stop()
    let stopped = automatic.frames, stoppedPublications = publications
    try await Task.sleep(for: .milliseconds(80))
    try require(flushedAtRelease && automatic.frames == stopped && publications == stoppedPublications
      && !automatic.isTracking && !automatic.isAnimating,
      "spaceTrackingFlushesTheLatestFingerPositionBeforeReleaseAndCancelsItsTail")

    automatic.track(progress: 0.5)
    automatic.synchronize(ids: ["private-strip-a", "private-strip-b"], selectedID: "private-strip-b", motionScale: 0)
    let resetFrames = automatic.frames
    try await Task.sleep(for: .milliseconds(80))
    let resetWasStable = automatic.frames == resetFrames && !automatic.hasPendingTrackingPresentation
      && automatic.frames.allSatisfy { $0.id.hasPrefix("private-strip-") }
    automatic.track(progress: -0.4)
    automatic.attachMotionView(nil)
    let detachedFrames = automatic.frames, detachedPublications = publications
    try await Task.sleep(for: .milliseconds(80))
    try require(resetWasStable && !automatic.hasPendingTrackingPresentation && !automatic.isTracking
      && automatic.frames == detachedFrames && publications == detachedPublications,
      "spaceTrackingContextResetAndDetachDiscardQueuedOldProgress")

    automatic.attachMotionView(root)
    automatic.track(progress: -0.35)
    automatic.cancelTracking()
    let cancelled = automatic.frames, cancelledPublications = publications
    try await Task.sleep(for: .milliseconds(80))
    let queuedCancelWasStable = automatic.frames == cancelled && publications == cancelledPublications
      && !automatic.hasPendingTrackingPresentation && !automatic.isTracking
    automatic.track(progress: -0.15)
    automatic.flushPendingTrackingPresentation()
    try require(queuedCancelWasStable
      && near(automatic.frames.first(where: { $0.id == "private-strip-b" })?.offset, 0.15),
      "spaceTrackingExplicitCancellationDiscardsQueuedProgressAndItsCapturedOrigin")
    automatic.cancelTracking()
    return checks
  }

  private static func near(_ value: Double?, _ target: Double) -> Bool {
    value.map { abs($0 - target) < 0.000_001 } ?? false
  }
  private struct ProbeKey: EnvironmentKey { static let defaultValue = "missing" }
  private struct Probe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { let view = ProbeView(); configure(view, context); return view }
    func updateNSView(_ view: ProbeView, context: Context) { configure(view, context) }
    private func configure(_ view: ProbeView, _ context: Context) {
      view.value = context.environment[ProbeKey.self]; view.direction = context.environment.layoutDirection
    }
  }
  private final class ProbeView: NSView {
    var value = ""
    var direction = LayoutDirection.leftToRight
  }
  private static func probes(in root: NSView) -> [ProbeView] {
    (root as? ProbeView).map { [$0] } ?? root.subviews.flatMap { probes(in: $0) }
  }
  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Native space strip acceptance failed: " + message }
  }
}
