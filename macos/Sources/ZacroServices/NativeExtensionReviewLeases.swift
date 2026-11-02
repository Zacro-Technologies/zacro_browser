import Foundation

/// Lifetime of an in-flight native consent operation. This contains no saved
/// choices: its cancellation never removes the durable intent behind a review.
@MainActor
public final class NativeExtensionReviewLeases {
  private struct Lease {
    let review: NativeExtensionReview
    let owner: String
    let cancel: () -> Void
  }
  private var leases: [UUID: Lease] = [:]
  public init() {}
  public var count: Int { leases.count }
  public func begin(_ review: NativeExtensionReview, owner: String, cancel: @escaping () -> Void) -> UUID {
    let token = UUID(); leases[token] = Lease(review:review,owner:owner,cancel:cancel); return token
  }
  public func finish(_ token: UUID) { leases.removeValue(forKey:token) }
  private func cancel(_ token: UUID) {
    // Remove before calling native cancellation, which can synchronously reenter.
    leases.removeValue(forKey:token)?.cancel()
  }
  public func cancel(profileID: String) {
    for (token,lease) in leases where lease.review.profileID == profileID { cancel(token) }
  }
  public func cancelAll() { for token in Array(leases.keys) { cancel(token) } }
  public func invalidateOwners(_ current: (_ windowID: String, _ profileID: String) -> Bool) {
    for (token,lease) in leases where !current(lease.owner,lease.review.profileID) { cancel(token) }
  }
  public func invalidateIntents(_ current: (ServiceJSON) async -> Bool) async {
    // Snapshot tokens. A late response may cancel only its original operation,
    // never a new review of the same extension opened in the meantime.
    for (token,lease) in leases {
      if !(await current(lease.review.intent)) { cancel(token) }
    }
  }
}
