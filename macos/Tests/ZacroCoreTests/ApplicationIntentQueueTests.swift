import XCTest
@testable import ZacroCore

final class ApplicationIntentQueueTests: XCTestCase {
  func testLaunchAndCloseVetoRetainArrivalOrderAndOriginalWindow() throws {
    var queue = ApplicationIntentQueue()
    queue.append(.openURL("https://first.example"), preferredWindowID: "a")
    queue.append(.command("command-palette"), preferredWindowID: "a")
    XCTAssertNil(queue.next(ready: false, terminating: false, windows: [], focusedWindowID: nil))
    XCTAssertNil(queue.next(ready: true, terminating: false, windows: [.init(id: "a", isClosing: true), .init(id: "b")], focusedWindowID: "b"))
    guard case .perform(let first, let firstOwner)? = queue.next(ready: true, terminating: false, windows: [.init(id: "a"), .init(id: "b")], focusedWindowID: "b") else { return XCTFail("Veto must release the first intent") }
    XCTAssertEqual(first.action, .openURL("https://first.example")); XCTAssertEqual(firstOwner, "a")
    guard case .perform(let second, let secondOwner)? = queue.next(ready: true, terminating: false, windows: [.init(id: "a"), .init(id: "b")], focusedWindowID: "b") else { return XCTFail("Second intent missing") }
    XCTAssertEqual(second.action, .command("command-palette")); XCTAssertEqual(secondOwner, "a")
    XCTAssertEqual(queue.count, 0)
  }
  func testSuccessfulCloseRebindsLinksButDoesNotCloseAnotherWindow() {
    var queue = ApplicationIntentQueue()
    queue.append(.openURL("https://example.com"), preferredWindowID: "a")
    queue.append(.command("close-window"), preferredWindowID: "a")
    queue.append(.command("window-minimize"), preferredWindowID: "a")
    guard case .perform(_, let target)? = queue.next(ready: true, terminating: false, windows: [.init(id: "b")], focusedWindowID: "b") else { return XCTFail("Link not delivered") }
    XCTAssertEqual(target, "b")
    guard case .discard? = queue.next(ready: true, terminating: false, windows: [.init(id: "b")], focusedWindowID: "b") else { return XCTFail("A stale close must not close B") }
    guard case .discard? = queue.next(ready: true, terminating: false, windows: [.init(id: "b")], focusedWindowID: "b") else { return XCTFail("A stale minimize must not minimize B") }
  }
  func testNoWindowReopensOnlyForDocumentCommandsAndCreatesExactlyOnce() {
    var queue = ApplicationIntentQueue()
    for action in [ApplicationIntentQueue.Action.command("open-browser"), .command("reopen-window"), .command("new-tab"), .showWindow] {
      queue.append(action)
      guard case .perform(let intent, let target)? = queue.next(ready: true, terminating: false, windows: [], focusedWindowID: nil) else { return XCTFail("Missing action") }
      XCTAssertEqual(intent.action, action); XCTAssertNil(target); XCTAssertEqual(queue.count, 0)
    }
    queue.append(.command("close-tab"))
    guard case .discard? = queue.next(ready: true, terminating: false, windows: [], focusedWindowID: nil) else { return XCTFail("Close must not create a window") }
  }
  func testTerminationDefersUntilVetoAndFinalTerminationClearsBoundedQueue() {
    var queue = ApplicationIntentQueue()
    for index in 0..<32 { XCTAssertTrue(queue.append(.openURL("https://example.com/\(index)"))) }
    XCTAssertFalse(queue.append(.command("new-tab")))
    XCTAssertNil(queue.next(ready: true, terminating: true, windows: [.init(id: "a")], focusedWindowID: "a"))
    XCTAssertEqual(queue.count, 32)
    guard case .perform(_, let target)? = queue.next(ready: true, terminating: false, windows: [.init(id: "a")], focusedWindowID: "a") else { return XCTFail("Quit veto must resume delivery") }
    XCTAssertEqual(target, "a")
    queue.removeAll(); XCTAssertEqual(queue.count, 0)
  }
}
