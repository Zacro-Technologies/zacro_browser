import XCTest
@testable import ZacroCore

@MainActor final class BrowserSessionTests: XCTestCase {
  private func repository() throws -> BrowserRepository {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroSessions-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return BrowserRepository(directory: dir)
  }
  func testArchivedHistoryAndClosedPinnedIdentityRestoreWithoutDuplication() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/a"))
    scope.navigate(tabID: tab.id, address: "https://example.com/b")
    let history = try XCTUnwrap(scope.tab(tab.id)).navigation
    scope.closeTab(id: tab.id)
    let restored = try scope.restoreSessionTabDurably(id: tab.id)
    XCTAssertEqual(restored.navigation, history); XCTAssertEqual(scope.state.activeTabID, tab.id)
    XCTAssertTrue(scope.state.archive.isEmpty)
    scope.togglePin(id: tab.id); scope.closeTab(id: tab.id)
    XCTAssertNotNil(scope.tab(tab.id)?.closedAt)
    let restarted = BrowserRepository(directory: repo.directory), target = restarted.focusedStore
    XCTAssertNotNil(target.tab(tab.id)?.closedAt)
    try target.restoreSessionTabDurably(id: tab.id)
    XCTAssertNil(target.tab(tab.id)?.closedAt)
    XCTAssertEqual(target.state.tabs.filter { $0.id == tab.id }.count, 1)
    XCTAssertFalse(target.tab(tab.id)!.isClosed)
  }
  func testRestoringNestedWindowTabMovesPersistentSplitAndRejectsLiveForeignTabs() throws {
    let repo = try repository(), first = repo.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://example.com/a"))
    let b = try XCTUnwrap(first.createTab(address: "https://example.com/b"))
    first.setSplit(left: a.id, right: b.id)
    let split = try XCTUnwrap(first.state.splits.first)
    let second = try repo.makeWindow(addresses: ["https://example.com/c"])
    XCTAssertThrowsError(try second.restoreSessionTabDurably(id: a.id))
    repo.closeWindow(first.owningWindowID!)
    try second.restoreSessionTabDurably(id: a.id)
    XCTAssertEqual(second.tab(a.id)?.windowID, second.owningWindowID)
    XCTAssertEqual(second.tab(b.id)?.windowID, second.owningWindowID)
    XCTAssertEqual(second.state.splits.first { $0.id == split.id }, split)
    XCTAssertEqual(second.state.activeTabID, a.id)
    XCTAssertFalse(repo.savedWindows.contains { $0.id == first.owningWindowID })
  }
  func testRestoreFailureIsAtomicAndCannotCrossProfiles() throws {
    let repo = try repository(), scope = repo.focusedStore
    let a = try XCTUnwrap(scope.createTab(address: "https://example.com/a")); scope.closeTab(id: a.id)
    let other = try scope.createProfileDurably(name: "Other")
    let second = try repo.makeWindow(profileID: other.id)
    XCTAssertThrowsError(try second.restoreSessionTabDurably(id: a.id))
    let file = repo.directory.appendingPathComponent("native-state.json"), before = repo.canonicalStore.state
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let originalSpace = before.spaces.first { $0.profileID == "default" }!
    scope.selectSpace(id: originalSpace.id)
    let activeBefore = repo.canonicalStore.state
    XCTAssertThrowsError(try scope.restoreSessionTabDurably(id: a.id))
    XCTAssertEqual(repo.canonicalStore.state, activeBefore)
    XCTAssertTrue(repo.canonicalStore.state.archive.contains { $0.id == a.id })
  }
  func testParkedPeekRestoreTransfersSourceAndSplitWithoutPromotion() throws {
    let repo = try repository(), first = repo.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://example.com/a"))
    let b = try XCTUnwrap(first.createTab(address: "https://example.com/b"))
    first.setSplit(left: a.id, right: b.id)
    first.setPeek(tabID: a.id, address: "https://example.com/preview", title: "Preview")
    try first.updatePeekDurably(tabID: a.id) { $0.isPresented = false; $0.muted = true }
    let preview = try XCTUnwrap(first.tab(a.id)?.peek)
    let split = try XCTUnwrap(first.state.splits.first)
    let second = try repo.makeWindow(addresses: ["https://example.com/c"])
    XCTAssertThrowsError(try second.restoreSessionTabDurably(id: "peek:" + a.id))
    repo.closeWindow(first.owningWindowID!)
    let count = repo.canonicalStore.state.tabs.count
    let restored = try second.restoreSessionTabDurably(id: "peek:" + a.id)
    XCTAssertEqual(restored.id, "peek:" + a.id)
    XCTAssertEqual(restored.url, preview.url); XCTAssertTrue(restored.isMuted)
    XCTAssertEqual(restored.openerTabID, a.id)
    XCTAssertEqual(second.state.activeTabID, a.id)
    XCTAssertEqual(second.tab(a.id)?.peek?.isPresented, true)
    XCTAssertEqual(second.tab(b.id)?.windowID, second.owningWindowID)
    XCTAssertEqual(second.state.splits.first { $0.id == split.id }, split)
    XCTAssertEqual(repo.canonicalStore.state.tabs.count, count)
    XCTAssertFalse(repo.canonicalStore.state.tabs.contains { $0.id == restored.id })
    let restarted = BrowserRepository(directory: repo.directory)
    XCTAssertEqual(restarted.store(for: second.owningWindowID!)?.document(id: restored.id)?.url, preview.url)
  }
  func testParkedPeekRestoreRejectsMissingCrossProfileAndRollsBackWriteFailure() throws {
    let repo = try repository(), first = repo.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://example.com/a"))
    first.setPeek(tabID: a.id, address: "https://example.com/preview", title: "Preview")
    let second = try repo.makeWindow(addresses: ["https://example.com/b"])
    repo.closeWindow(first.owningWindowID!)
    XCTAssertThrowsError(try second.restoreSessionTabDurably(id: "peek:missing"))
    let other = try second.createProfileDurably(name: "Other")
    let third = try repo.makeWindow(profileID: other.id)
    XCTAssertThrowsError(try third.restoreSessionTabDurably(id: "peek:" + a.id))
    let file = repo.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let before = repo.canonicalStore.state
    XCTAssertThrowsError(try second.restoreSessionTabDurably(id: "peek:" + a.id))
    XCTAssertEqual(repo.canonicalStore.state, before)
    XCTAssertEqual(repo.canonicalStore.tab(a.id)?.windowID, first.owningWindowID)
  }
}
