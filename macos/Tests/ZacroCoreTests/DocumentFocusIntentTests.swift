import XCTest
@testable import ZacroCore

final class DocumentFocusIntentTests: XCTestCase {
  private let first = DocumentFocusIntent.Selection(documentID: "a", profileID: "personal")
  func testTransientWaitDoesNotCompleteOrStartDuplicateMaterialization() throws {
    var intent = DocumentFocusIntent()
    let token = try XCTUnwrap(intent.begin(first))
    XCTAssertTrue(intent.isPending(token))
    XCTAssertNil(intent.begin(first))
    XCTAssertTrue(intent.complete(token))
    XCTAssertFalse(intent.isPending(token))
    XCTAssertNil(intent.begin(first))
  }
  func testNewInteractionAbandonsEvenBeforeLayoutStartsAndCannotRevive() throws {
    var intent = DocumentFocusIntent()
    intent.abandon(first)
    XCTAssertNil(intent.begin(first))
    let explicit = try XCTUnwrap(intent.begin(first, explicit: true))
    intent.abandon(first)
    XCTAssertFalse(intent.complete(explicit))
    XCTAssertNil(intent.begin(first))
    XCTAssertEqual(intent.phase, .abandoned)
  }
  func testOldAsyncCompletionCannotConsumeNewSelectionOrExplicitRetry() throws {
    var intent = DocumentFocusIntent()
    let old = try XCTUnwrap(intent.begin(first))
    let retry = try XCTUnwrap(intent.begin(first, explicit: true))
    XCTAssertFalse(intent.complete(old))
    let other = try XCTUnwrap(intent.begin(.init(documentID: "b", profileID: "personal")))
    XCTAssertFalse(intent.complete(retry))
    XCTAssertTrue(intent.isPending(other))
    XCTAssertTrue(intent.complete(other))
  }
  func testProfileIdentityAndWindowReopenCreateFreshIntent() throws {
    var intent = DocumentFocusIntent()
    let old = try XCTUnwrap(intent.begin(first))
    let otherProfile = try XCTUnwrap(intent.begin(.init(documentID: "a", profileID: "work")))
    XCTAssertFalse(intent.complete(old))
    intent.clear()
    XCTAssertFalse(intent.complete(otherProfile))
    XCTAssertNotNil(intent.begin(first))
  }
}
