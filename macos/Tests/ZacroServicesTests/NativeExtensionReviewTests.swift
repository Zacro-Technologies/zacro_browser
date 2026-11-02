import XCTest
@testable import ZacroServices

final class NativeExtensionReviewTests: XCTestCase {
  private let ext = String(repeating:"a", count:32)
  private var intent: ServiceJSON {
    ["profileId":"personal", "linkId":"link-1", "accountId":"account-1", "endpoint":"https://sync.example",
      "extension":["extensionId":.string(ext), "source":["kind":"web-store", "id":.string(ext)],
        "generation":"generation-1", "state":"enabled", "revision":1]]
  }
  func testReviewBindsTheEntireConsentContextButNotPresentationOrRevision() throws {
    let original = try NativeExtensionReview(intent:intent,action:.install,name:"Original")
    var newer = intent; newer["extension"]["revision"] = 2
    XCTAssertTrue(original.matches(try NativeExtensionReview(intent:newer,action:.install,name:"Renamed")))
    for field in ["profileId", "linkId", "accountId", "endpoint"] {
      var changed = intent; changed[field] = .string("different")
      XCTAssertFalse(original.matches(try NativeExtensionReview(intent:changed,action:.install)),field)
    }
    for field in ["generation", "state"] {
      var changed = intent; changed["extension"][field] = field == "state" ? "disabled" : "generation-2"
      XCTAssertFalse(original.matches(try NativeExtensionReview(intent:changed,action:.install)),field)
    }
    XCTAssertFalse(original.matches(try NativeExtensionReview(intent:intent,action:.enable)))
  }
  func testPendingRowsRoundTripWithoutCreatingAdditionalAuthority() throws {
    for (state,action) in [("enabled",NativeExtensionReview.Action.install),("disabled",.install),("enabled",.enable),("disabled",.disable),("removed",.remove)] {
      var value = intent; value["extension"]["state"] = .string(state)
      let review = try NativeExtensionReview(intent:value,action:action,name:"A website tool")
      let decoded = try NativeExtensionReview(value:ServiceJSON.decode(review.value.encoded()))
      XCTAssertEqual(decoded,review)
      for field in ["profileId", "linkId", "accountId", "extensionId", "generation", "state", "action"] {
        var forged = review.value; forged[field] = "other"
        XCTAssertThrowsError(try NativeExtensionReview(value:forged),field)
      }
    }
  }
  func testRemovedAndInstalledIntentsCannotBeReinterpretedAsAnotherAction() throws {
    XCTAssertThrowsError(try NativeExtensionReview(intent:intent,action:.remove))
    XCTAssertThrowsError(try NativeExtensionReview(intent:intent,action:.disable))
    var removed = intent; removed["extension"]["state"] = "removed"
    for action in [NativeExtensionReview.Action.install,.enable,.disable] {
      XCTAssertThrowsError(try NativeExtensionReview(intent:removed,action:action))
    }
    var unpacked = intent; unpacked["extension"]["source"]["kind"] = "unpacked"
    XCTAssertThrowsError(try NativeExtensionReview(intent:unpacked,action:.install))
    var other = intent; other["extension"]["source"]["id"] = .string(String(repeating:"b",count:32))
    XCTAssertThrowsError(try NativeExtensionReview(intent:other,action:.install))
  }
  @MainActor func testOwnerAndProfileRevocationCancelsOnlyMatchingOperationsOnce() throws {
    let leases = NativeExtensionReviewLeases(), review = try NativeExtensionReview(intent:intent,action:.install)
    var otherIntent = intent; otherIntent["profileId"] = "other"
    let other = try NativeExtensionReview(intent:otherIntent,action:.install)
    var first = 0, second = 0, third = 0
    _ = leases.begin(review,owner:"window-a") { first += 1; leases.cancel(profileID:"personal") }
    _ = leases.begin(review,owner:"window-b") { second += 1 }
    _ = leases.begin(other,owner:"window-c") { third += 1 }
    leases.invalidateOwners { window, _ in window != "window-a" }
    XCTAssertEqual(first,1); XCTAssertEqual(second,1); XCTAssertEqual(third,0)
    XCTAssertEqual(leases.count,1)
    leases.cancel(profileID:"personal"); leases.cancelAll(); leases.cancelAll()
    XCTAssertEqual(first,1); XCTAssertEqual(second,1); XCTAssertEqual(third,1)
  }
  @MainActor func testLateIntentValidationCannotCancelReplacementReview() async throws {
    let leases = NativeExtensionReviewLeases(), review = try NativeExtensionReview(intent:intent,action:.install)
    let gate = ReviewValidationGate()
    var oldCancelled = 0, replacementCancelled = 0
    let old = leases.begin(review,owner:"window") { oldCancelled += 1 }
    let validation = Task { await leases.invalidateIntents { _ in await gate.wait() } }
    await gate.waitUntilRequested()
    leases.finish(old)
    let replacement = leases.begin(review,owner:"window") { replacementCancelled += 1 }
    await gate.resolve(false); await validation.value
    XCTAssertEqual(oldCancelled,0); XCTAssertEqual(replacementCancelled,0); XCTAssertEqual(leases.count,1)
    await leases.invalidateIntents { _ in false }
    XCTAssertEqual(replacementCancelled,1); XCTAssertEqual(leases.count,0)
    leases.finish(replacement)
  }
  @MainActor func testCloudRevocationCancelsBlockedNativeTaskWithoutWaitingForProfileQueue() async throws {
    let leases = NativeExtensionReviewLeases(), review = try NativeExtensionReview(intent:intent,action:.install)
    let gate = ReviewValidationGate()
    let native = Task { try await withTaskCancellationHandler {
      _ = await gate.wait(); try Task.checkCancellation()
    } onCancel: { Task { await gate.resolve(false) } } }
    await gate.waitUntilRequested()
    _ = leases.begin(review,owner:"window") { native.cancel() }
    await leases.invalidateIntents { _ in false }
    do { try await native.value; XCTFail("The blocked native request must be cancelled") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(leases.count,0)
  }
}

private actor ReviewValidationGate {
  private var pending: CheckedContinuation<Bool,Never>?
  private var started: [CheckedContinuation<Void,Never>] = []
  func wait() async -> Bool {
    await withCheckedContinuation { continuation in
      pending = continuation
      let listeners = started; started.removeAll(); listeners.forEach { $0.resume() }
    }
  }
  func waitUntilRequested() async {
    if pending != nil { return }
    await withCheckedContinuation { started.append($0) }
  }
  func resolve(_ result: Bool) { let response = pending; pending = nil; response?.resume(returning:result) }
}
