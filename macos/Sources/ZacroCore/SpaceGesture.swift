import Foundation

/// Clock-injected Space strip recognizer. Only finger travel changes the strip;
/// a release snaps once, and the remaining momentum belongs to that release.
/// Native callers negate NSEvent's deltas and pass its monotonic timestamp.
public struct SpaceGesture: Sendable {
  public enum ContactPhase: Sendable { case none, began, changed, ended, cancelled }
  public enum DeltaMode: Sendable { case pixels, lines, pages }
  public enum Phase: Sendable { case idle, pending, tracking, edge, committed, settling, vertical, locked, blocked }
  public enum ReleaseReason: Sendable { case quiet, phaseEnd, cancelled, momentum, deceleration }

  public struct Input: Sendable {
    public var time: TimeInterval
    public var deltaX: Double
    public var deltaY: Double
    public var width: Double
    public var index: Int
    public var count: Int
    public var contextKey: String
    public var phase: ContactPhase
    /// `nil` for a device with no native momentum information.
    public var momentum: Bool?
    public var deltaMode: DeltaMode
    public var shiftKey: Bool
    /// Covers modifiers, an active drag, editable controls, or an invalid context.
    public var blocked: Bool
    public init(time: TimeInterval, deltaX: Double = 0, deltaY: Double = 0,
                width: Double = 224, index: Int, count: Int, contextKey: String,
                phase: ContactPhase = .none, momentum: Bool? = nil,
                deltaMode: DeltaMode = .pixels, shiftKey: Bool = false, blocked: Bool = false) {
      self.time = time; self.deltaX = deltaX; self.deltaY = deltaY; self.width = width
      self.index = index; self.count = count; self.contextKey = contextKey
      self.phase = phase; self.momentum = momentum; self.deltaMode = deltaMode
      self.shiftKey = shiftKey; self.blocked = blocked
    }
  }
  public struct Output: Sendable {
    public var consumed = false
    public var offset = 0.0
    public var fromOffset = 0.0
    /// Signed, rubber-banded page displacement suitable for the native strip.
    public var progress: Double { -offset / travel }
    public var position: Double?
    public var direction = 0
    public var targetIndex: Int?
    public var originIndex = -1
    public var contextKey: String?
    public var commit = 0
    public var atEdge = false
    public var phase = Phase.idle
    public var travel = 224.0
    public var duration: TimeInterval = 0
    public var idleDelay: TimeInterval = 0
    public var reason: ReleaseReason?
    public var didRelease: Bool { reason != nil }
    public var selectedIndex: Int? { didRelease ? originIndex + commit : nil }
  }

  public static let idleInterval: TimeInterval = 0.320
  public static let releaseInterval: TimeInterval = 0.180
  public var isTracking: Bool { phase == .tracking }
  public var isPending: Bool { phase == .pending }
  public var hasKnownContactPhase: Bool { phaseKnown }

  // Internal milliseconds preserve the original browser recognizer's thresholds.
  private var lastTime = -Double.infinity, startedAt = 0.0
  private var context: String?
  private var origin = -1, count = 0
  private var travel = 224.0
  private var phase = Phase.idle
  private var distance = 0.0, horizontal = 0.0, vertical = 0.0
  private var samples: [(time: Double, position: Double)] = []
  private var lastDX = 0.0, reverseDistance = 0.0
  private var momentumSeen = false, contactKnown = false, phaseKnown = false
  private var peak = 0.0, peakTime = 0.0
  private var declining = 0
  public init() {}

  private func finite(_ value: Double, _ fallback: Double = 0) -> Double { value.isFinite ? value : fallback }
  private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
  private func sign(_ value: Double) -> Int { value == 0 ? 0 : value < 0 ? -1 : 1 }
  private func neutral(consumed: Bool = false) -> Output {
    var output = Output()
    output.consumed = consumed; output.originIndex = origin; output.contextKey = context
    output.phase = phase; output.travel = travel; output.idleDelay = phase == .idle ? 0 : Self.idleInterval
    return output
  }
  private mutating func clear() {
    phase = .idle; distance = 0; horizontal = 0; vertical = 0; lastDX = 0; reverseDistance = 0
    samples.removeAll(keepingCapacity: true)
    momentumSeen = false; contactKnown = false; phaseKnown = false; peak = 0; declining = 0
  }
  private func feedback(consumed: Bool = false) -> Output {
    guard phase == .tracking else { return neutral(consumed: consumed) }
    var output = neutral(consumed: consumed)
    let position = Double(origin) + distance / travel
    let bounded = clamp(position, 0, Double(count - 1))
    let over = (position - bounded) * travel
    output.offset = over == 0 ? -distance : -(bounded - Double(origin)) * travel - Double(sign(over)) * 24 * abs(over) / (40 + abs(over))
    output.position = bounded; output.direction = sign(distance); output.atEdge = over != 0
    if output.direction != 0 && !output.atEdge {
      output.targetIndex = Int(clamp(Double(origin) + ceil(abs(distance) / travel) * Double(output.direction), 0, Double(count - 1)))
    }
    output.phase = output.atEdge ? .edge : .tracking; output.idleDelay = Self.releaseInterval
    return output
  }
  private func velocity() -> Double {
    guard samples.count >= 2, let first = samples.first, let last = samples.last, last.time - first.time >= 8 else { return 0 }
    return clamp((last.position - first.position) / (last.time - first.time), -2.5, 2.5)
  }
  private mutating func release(_ reason: ReleaseReason, consumed: Bool = false, cancelled: Bool = false) -> Output {
    var output = feedback(consumed: consumed)
    let speed = velocity(), amount = abs(distance)
    let reversing = reverseDistance >= travel * 0.08 && sign(lastDX) != output.direction
    let flick = amount >= travel * 0.12 && sign(speed) == output.direction && abs(speed) >= 0.55 && amount + abs(speed) * 110 >= travel * 0.5
    let quick = lastTime - startedAt <= 220 && !reversing && (flick || amount >= travel * 0.42)
    let projected = distance / travel
    var target = clamp(Double(origin) + projected.rounded(.toNearestOrAwayFromZero), 0, Double(count - 1))
    if reversing { target = clamp(Double(origin) + (lastDX < 0 ? floor(projected) : ceil(projected)), 0, Double(count - 1)) }
    if !flick && amount >= travel * 0.42 && amount < travel * 0.5 && !reversing {
      target = clamp(Double(origin + sign(distance)), 0, Double(count - 1))
    }
    if quick { target = clamp(Double(origin + sign(distance)), 0, Double(count - 1)) }
    output.commit = cancelled ? 0 : Int(target) - origin
    let destination = -Double(output.commit) * travel
    let remaining = abs(destination - output.offset) / travel
    let duration = output.commit != 0 ? clamp(140 + remaining * 100, 140, 240) : clamp(100 + remaining * 100, 100, 200)
    output.phase = output.commit != 0 ? .committed : .settling
    output.targetIndex = output.commit != 0 ? origin + output.commit : nil
    output.fromOffset = output.offset; output.offset = destination
    output.duration = duration.rounded() / 1000; output.reason = reason; output.idleDelay = Self.idleInterval
    phase = .locked; samples.removeAll(keepingCapacity: true)
    return output
  }
  @discardableResult public mutating func interrupt(at time: TimeInterval) -> Output {
    interruptMilliseconds(time * 1000)
  }
  private mutating func interruptMilliseconds(_ time: Double) -> Output {
    let wasMomentum = momentumSeen
    lastTime = max(finite(time, finite(lastTime)), finite(lastTime))
    clear(); momentumSeen = wasMomentum; phase = .blocked
    return neutral()
  }
  public mutating func update(_ input: Input) -> Output {
    let time = max(finite(input.time * 1000, finite(lastTime)), finite(lastTime))
    let width = max(1, finite(input.width, 224))
    let scale = input.deltaMode == .lines ? 16 : input.deltaMode == .pages ? width : 1
    let shifted = input.shiftKey && finite(input.deltaX) == 0
    let dx = finite(shifted ? input.deltaY : input.deltaX) * scale
    let dy = shifted ? 0 : finite(input.deltaY) * scale
    let nextCount = max(0, input.count), nextIndex = input.index
    if input.blocked || nextCount < 2 || nextIndex < 0 || nextIndex >= nextCount { return interruptMilliseconds(time) }
    let elapsed = time - lastTime
    // A completed trackpad stream must not lock out a subsequently used mouse.
    // This never rearms a held contact or a reported native momentum tail.
    let changedDevice = phaseKnown && phase != .tracking && phase != .pending &&
      elapsed >= 320 && input.phase == .none && input.momentum == nil
    if (!phaseKnown && elapsed >= 320) || changedDevice || input.phase == .began || (momentumSeen && input.momentum == false) {
      clear()
    } else if context != input.contextKey || ((phase == .tracking || phase == .pending) && (origin != nextIndex || count != nextCount)) {
      return interruptMilliseconds(time)
    }
    context = input.contextKey
    if input.phase == .cancelled || input.phase == .ended {
      lastTime = time
      if phase == .tracking { return release(input.phase == .cancelled ? .cancelled : .phaseEnd, cancelled: input.phase == .cancelled) }
      if phase == .pending { phase = .locked }
      return neutral()
    }
    if input.momentum == true {
      lastTime = time; momentumSeen = true
      if phase == .tracking { return release(.momentum, consumed: true) }
      phase = .locked
      return neutral(consumed: abs(dx) > abs(dy) * 1.5)
    }
    if dx == 0 && dy == 0 {
      if input.phase == .changed && (phase == .tracking || phase == .pending) { contactKnown = true; phaseKnown = true }
      return feedback()
    }
    lastTime = time
    if phase == .blocked || phase == .vertical { return neutral() }
    if phase == .locked { return neutral(consumed: dx != 0 && abs(dx) >= abs(dy) * 1.5) }
    if phase == .idle { startedAt = time; origin = nextIndex; count = nextCount; travel = width; phase = .pending }
    contactKnown = contactKnown || input.phase == .began || input.phase == .changed || input.momentum == false
    phaseKnown = phaseKnown || input.phase == .began || input.phase == .changed
    horizontal += abs(dx); vertical += abs(dy); distance += dx
    if time - startedAt <= 220 { distance = clamp(distance, -travel * 1.05, travel * 1.05) }
    if phase == .pending {
      if vertical >= 8 && horizontal < vertical * 1.5 { phase = .vertical; distance = 0; return neutral() }
      if horizontal < 8 || horizontal < vertical * 1.5 { var output = neutral(); output.idleDelay = Self.releaseInterval; return output }
      phase = .tracking
    }
    if dx != 0 && lastDX != 0 && sign(dx) != sign(lastDX) {
      samples.removeAll(keepingCapacity: true); reverseDistance = 0; peak = 0; declining = 0
    }
    reverseDistance += abs(dx)
    if dx != 0 { samples.append((time, distance)) }
    samples.removeAll { time - $0.time > 80 }
    let magnitude = abs(dx), previous = abs(lastDX)
    if magnitude >= peak { peak = magnitude; peakTime = time; declining = 0 }
    else if magnitude >= 1 && magnitude < previous * 0.95 && elapsed >= 8 && elapsed <= 45 { declining += 1 }
    else { declining = 0 }
    if dx != 0 { lastDX = dx }
    distance = clamp(distance, -travel * (Double(origin) + 0.35), travel * (Double(count - 1 - origin) + 0.35))
    if !contactKnown && declining >= 3 && peak >= 12 && magnitude <= peak * 0.6 && time - peakTime >= 40 && abs(distance) >= travel * 0.18 {
      return release(.deceleration, consumed: true)
    }
    return feedback(consumed: true)
  }
  public mutating func settle(at time: TimeInterval) -> Output {
    let elapsed = finite(time * 1000, finite(lastTime)) - lastTime
    if phase == .tracking && phaseKnown { var output = feedback(); output.idleDelay = Self.idleInterval; return output }
    if phase == .tracking && elapsed >= 180 {
      var output = release(.quiet); output.idleDelay = max(1, ceil(320 - elapsed)) / 1000; return output
    }
    if elapsed >= 320 { clear(); return neutral() }
    let deadline = phase == .tracking || phase == .pending ? 180.0 : 320.0
    if phase == .pending && elapsed >= 180 { phase = .locked }
    var output = feedback(); output.idleDelay = max(1, ceil((phase == .locked ? 320 : deadline) - elapsed)) / 1000
    return output
  }
}
