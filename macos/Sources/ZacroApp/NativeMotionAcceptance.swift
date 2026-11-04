import AppKit

/// Exercise actual AppKit frame delivery and cancellation in the disposable
/// browser window. No desktop events or unrelated windows are inspected.
@MainActor
enum NativeMotionAcceptance {
  static func run(in window: NSWindow) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      window.identifier?.rawValue.hasPrefix("ZacroBrowserWindow:") == true,
      window.isVisible, !window.isMiniaturized, let root = window.contentView,
      root.window === window else { throw Failure("Motion acceptance requires its visible owned browser window") }
    let clock = NativeMotionClock()
    let hidden = NSView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
    hidden.isHidden = true
    root.addSubview(hidden, positioned: .below, relativeTo: nil)
    defer { clock.stop(); hidden.removeFromSuperview() }

    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw Failure(name) }
      checks.append(name)
    }
    func wait(_ name: String, condition: () -> Bool) async throws {
      let end = ProcessInfo.processInfo.systemUptime + 1
      while ProcessInfo.processInfo.systemUptime < end {
        try Task.checkCancellation()
        guard window.contentView === root, root.window === window else {
          throw Failure("Motion acceptance lost its exact owned root")
        }
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw Failure(name)
    }

    let samples = (0...1000).map { NativeMotion.progress(Double($0) / 1000) }
    try require(samples.first == 0 && samples.last == 1
      && samples.allSatisfy { $0.isFinite && (0.0...1.0).contains($0) }
      && zip(samples, samples.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 }
      && samples[250] > 0.8
      && samples[1000] - samples[990] < samples[500] - samples[490],
      "motionCurveRespondsQuicklyAndSettlesWithoutOvershoot")

    var visibleFrames = 0
    var receivedDisplayFrame = false
    let visibleEnd = ProcessInfo.processInfo.systemUptime + 0.5
    clock.start(in: root, until: visibleEnd) { [weak clock] time in
      visibleFrames += 1
      // The terminal deadline cannot masquerade as a real display callback.
      if time < visibleEnd - 0.01 { receivedDisplayFrame = true; clock?.stop() }
    }
    try await wait("The owned view did not deliver an actual display-linked frame") { receivedDisplayFrame }
    let stoppedAt = visibleFrames
    try await Task.sleep(for: .milliseconds(80))
    try require(stoppedAt > 0 && visibleFrames == stoppedAt && !clock.isRunning,
      "motionDisplayLinkFollowsItsOwnedViewAndStopsWithoutIdleCallbacks")

    var hiddenFrames = 0
    var hiddenCompletedAt = 0.0
    let hiddenEnd = ProcessInfo.processInfo.systemUptime + 0.07
    clock.start(in: hidden, until: hiddenEnd) { [weak clock] time in
      hiddenFrames += 1; hiddenCompletedAt = time; clock?.stop()
    }
    try await wait("The hidden owned view did not complete at its terminal deadline") { hiddenFrames > 0 }
    try await Task.sleep(for: .milliseconds(40))
    try require(hidden.window === window && hidden.isHidden && hiddenFrames == 1
      && hiddenCompletedAt >= hiddenEnd && !clock.isRunning,
      "motionHiddenViewCompletesOnceWithoutRequiringDisplayFrames")

    var oldDelivered = false
    var replacementDelivered = false
    var replacementAt = 0.0
    clock.start(in: hidden, until: ProcessInfo.processInfo.systemUptime + 0.06) { _ in oldDelivered = true }
    let replacementEnd = ProcessInfo.processInfo.systemUptime + 0.14
    clock.start(in: hidden, until: replacementEnd) { [weak clock] time in
      replacementDelivered = true; replacementAt = time; clock?.stop()
    }
    try await wait("The replacement motion did not reach its own terminal deadline") { replacementDelivered }
    try require(!oldDelivered && replacementAt >= replacementEnd && !clock.isRunning,
      "motionInterruptionCancelsTheOldDisplayLinkAndTerminalDeadline")
    return checks
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Native motion acceptance failed: " + message }
  }
}
