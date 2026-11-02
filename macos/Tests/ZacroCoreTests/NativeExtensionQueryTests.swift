import XCTest
@testable import ZacroCore

final class NativeExtensionQueryTests: XCTestCase {
  private func matches(_ query: [String:Any], _ tab: [String:Any], current: Int = 1, focused: Int? = 1,
                       type: String = "normal") throws -> Bool {
    try NativeExtensionQuery.matches(query:query,tab:tab,currentWindowID:current,lastFocusedWindowID:focused,windowType:type)
  }
  func testFalseIsAFilterAndMissingIsNotFalse() throws {
    for field in ["active","audible","autoDiscardable","discarded","frozen","highlighted","pinned"] {
      XCTAssertTrue(try matches([field:false],[field:false]),field)
      XCTAssertFalse(try matches([field:false],[field:true]),field)
      XCTAssertFalse(try matches([field:false],[:]),field)
      XCTAssertTrue(try matches([field:true],[field:true]),field)
      XCTAssertFalse(try matches([field:true],[field:false]),field)
    }
    XCTAssertTrue(try matches([:],[:]))
  }
  func testJSONBooleansDoNotAcceptNumericOrStringLookalikes() throws {
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with:Data("{\"active\":false,\"pinned\":true,\"index\":0}".utf8)) as? [String:Any])
    XCTAssertTrue(try matches(decoded,["active":false,"pinned":true,"index":0]))
    for invalid in [0,1,0.0,"false",NSNull()] as [Any] {
      XCTAssertThrowsError(try matches(["active":invalid],["active":false]))
    }
    XCTAssertFalse(try matches(["active":false],["active":0]))
  }
  func testIntegersRejectBooleansFractionalNumbersAndOverflow() throws {
    for key in ["index","windowId","groupId","splitViewId"] {
      for invalid in [true,false,1.0,1.25,"1",Int64(Int32.max)+1,NSNull()] as [Any] {
        XCTAssertThrowsError(try matches([key:invalid],[key:1]),key)
      }
    }
    XCTAssertTrue(try matches(["index":2,"groupId":-1],["index":2,"groupId":-1]))
    XCTAssertFalse(try matches(["index":2],["index":3]))
    XCTAssertFalse(try matches(["groupId":-1],[:]))
  }
  func testSplitViewIdentityMatchesOnlyItsExactGroupOrExplicitNone() throws {
    XCTAssertTrue(try matches(["splitViewId":7],["splitViewId":7]))
    XCTAssertFalse(try matches(["splitViewId":7],["splitViewId":8]))
    XCTAssertTrue(try matches(["splitViewId":-1],["splitViewId":-1]))
    XCTAssertFalse(try matches(["splitViewId":-1],[:]))
    XCTAssertFalse(try matches(["splitViewId":-1],["splitViewId":0]))
  }
  func testCurrentAndLastFocusedWindowIncludeFalseAndAbsentFocus() throws {
    XCTAssertTrue(try matches(["currentWindow":true],["windowId":8],current:8))
    XCTAssertFalse(try matches(["currentWindow":false],["windowId":8],current:8))
    XCTAssertTrue(try matches(["currentWindow":false],["windowId":9],current:8))
    XCTAssertFalse(try matches(["currentWindow":false],[:],current:8))
    XCTAssertTrue(try matches(["lastFocusedWindow":true],["windowId":9],current:8,focused:9))
    XCTAssertTrue(try matches(["lastFocusedWindow":false],["windowId":8],current:8,focused:9))
    XCTAssertFalse(try matches(["lastFocusedWindow":true],["windowId":8],focused:nil))
    XCTAssertTrue(try matches(["lastFocusedWindow":false],["windowId":8],focused:nil))
  }
  func testWindowAliasesAndWindowTypeRemainDistinct() throws {
    XCTAssertTrue(try matches(["windowId":-2],["windowId":8],current:8))
    XCTAssertFalse(try matches(["windowId":-2],["windowId":9],current:8))
    XCTAssertFalse(try matches(["windowId":-1],["windowId":-1]))
    XCTAssertTrue(try matches(["windowId":9],["windowId":9]))
    XCTAssertFalse(try matches(["windowType":"popup"],["windowId":1],type:"normal"))
    XCTAssertTrue(try matches(["windowType":"popup"],["windowId":1],type:"popup"))
  }
  func testMutedInfoTakesPrecedenceAndStatusIsExact() throws {
    XCTAssertTrue(try matches(["muted":false],["mutedInfo":["muted":false],"muted":true]))
    XCTAssertTrue(try matches(["muted":true],["muted":true]))
    XCTAssertFalse(try matches(["muted":false],[:]))
    XCTAssertTrue(try matches(["status":"loading"],["status":"loading"]))
    XCTAssertFalse(try matches(["status":"complete"],["status":"loading"]))
    XCTAssertThrowsError(try matches(["status":false],["status":"complete"]))
  }
  func testSensitiveFiltersAreValidatedButDelegatedToChromium() throws {
    XCTAssertTrue(try matches(["url":"https://allowed.example/*","title":"Secret*"],[:]))
    XCTAssertTrue(try matches(["url":["https://allowed.example/*"]],["url":"https://different.example/"]))
    XCTAssertTrue(try matches(["url":[]],[:]))
    XCTAssertThrowsError(try matches(["url":["https://example/*",7]],[:]))
    XCTAssertThrowsError(try matches(["title":7],[:]))
  }
  func testAllFieldsValidateBeforeAnEarlierMismatchCanHideBadInput() throws {
    XCTAssertThrowsError(try matches(["active":true,"unknown":false],["active":false]))
    XCTAssertThrowsError(try matches(["active":true,"index":false],["active":false]))
  }
}
