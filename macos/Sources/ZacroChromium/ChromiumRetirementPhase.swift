import Foundation

/// Only already-authorized retirement tasks may create a transport during Quit
/// preparation. Once native close starts, cleanup belongs to runtime shutdown.
struct ChromiumRetirementPhase {
  private enum State { case accepting, preparing(UUID), closing(UUID), draining }
  private var state: State = .accepting
  var canBeginTask: Bool { if case .accepting = state { return true }; return false }
  var canCreateForExistingTask: Bool {
    switch state { case .accepting, .preparing: return true; case .closing, .draining: return false }
  }
  mutating func prepare(_ attempt: UUID) {
    if case .draining = state { return }
    state = .preparing(attempt)
  }
  mutating func cancel(_ attempt: UUID) {
    switch state {
    case .preparing(let current), .closing(let current):
      if current == attempt { state = .accepting }
    default: break
    }
  }
  mutating func beginNativeClose(_ attempt: UUID) -> Bool {
    guard case .preparing(let current) = state, current == attempt else { return false }
    state = .closing(attempt); return true
  }
  mutating func beginDrain() { state = .draining }
}
