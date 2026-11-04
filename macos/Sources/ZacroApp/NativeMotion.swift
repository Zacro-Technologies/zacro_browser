import AppKit
import QuartzCore
import SwiftUI

/// One quick response and smooth, monotonic settling curve across the shell.
/// Matches the renderer's cubic-bezier(.16, 1, .3, 1), without spring overshoot.
enum NativeMotion {
  static let fast = 0.10
  static let entrance = 0.16
  static let chrome = 0.20
  static let peekOpening = 0.20
  static let peekExpansion = 0.22
  static let peekClosing = 0.12

  static func animation(_ duration: Double, scale: Double = 1) -> Animation? {
    guard scale.isFinite, duration.isFinite, scale > 0, duration > 0 else { return nil }
    return .timingCurve(0.16, 1, 0.3, 1, duration: duration * scale)
  }

  static var timingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
  }

  /// Solve x(t) before reading y(t); using the Bezier parameter directly as
  /// elapsed time produces a different speed curve from SwiftUI/Core Animation.
  static func progress(_ fraction: Double) -> Double {
    guard fraction > 0 else { return 0 }
    guard fraction < 1 else { return 1 }
    var low = 0.0, high = 1.0
    for _ in 0..<18 {
      let t = (low + high) / 2, inverse = 1 - t
      let x = 3 * inverse * inverse * t * 0.16 + 3 * inverse * t * t * 0.3 + t * t * t
      if x < fraction { low = t } else { high = t }
    }
    let inverse = 1 - (low + high) / 2
    return 1 - inverse * inverse * inverse
  }
}

/// A short-lived, view/display-matched clock. It runs only during a transition,
/// follows the owning window between screens, and keeps pacing in tracking mode.
@MainActor
final class NativeMotionClock {
  private var link: CADisplayLink?
  private var frame: ((TimeInterval) -> Void)?
  private var deadline: Task<Void, Never>?
  private var generation = UUID()
  var isRunning: Bool { link != nil }

  func start(in view: NSView, until end: TimeInterval, frame: @escaping (TimeInterval) -> Void) {
    stop()
    self.frame = frame
    let token = generation
    let target = Target(owner: self)
    let link = view.displayLink(target: target, selector: #selector(Target.advance(_:)))
    self.link = link
    link.add(to: .main, forMode: .common)
    // AppKit pauses a view's display link while hidden/off-display. A single
    // cancellable deadline still completes an accepted close or Space snap;
    // hidden windows must not retain an unfinished lifecycle transaction.
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, end - ProcessInfo.processInfo.systemUptime))) }
      catch { return }
      guard let self, self.generation == token else { return }
      self.frame?(max(end, ProcessInfo.processInfo.systemUptime))
    }
  }

  func stop() {
    generation = UUID()
    deadline?.cancel(); deadline = nil
    link?.invalidate(); link = nil; frame = nil
  }

  @MainActor
  private final class Target: NSObject {
    weak var owner: NativeMotionClock?
    init(owner: NativeMotionClock) { self.owner = owner }
    @objc func advance(_ link: CADisplayLink) {
      guard let owner, owner.link === link else { link.invalidate(); return }
      owner.frame?(ProcessInfo.processInfo.systemUptime)
    }
  }

  deinit { deadline?.cancel(); link?.invalidate() }
}
