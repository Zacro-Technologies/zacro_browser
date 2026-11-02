import XCTest
@testable import ZacroCore

@MainActor final class BrowserHistoryTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroHistory-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
  func testRequestedNavigationDoesNotReplaceCommittedVisitOrBackStack() throws {
    let store = BrowserStore(directory: try directory())
    let tab = try XCTUnwrap(store.createTab(address: "https://first.example/"))
    XCTAssertTrue(store.state.history.isEmpty)
    let first = try XCTUnwrap(store.recordHistoryVisit(profileID: "default", address: tab.url, title: "First"))
    store.navigate(tabID: tab.id, address: "https://failed.example/", recordHistory: false)
    let navigation = try XCTUnwrap(store.tab(tab.id)).navigation
    XCTAssertEqual(store.state.history.map(\.id), [first])
    store.recordHistoryVisit(profileID: "default", address: "https://redirect.example/", title: "Redirect")
    XCTAssertEqual(store.state.history.map(\.url), ["https://redirect.example/", tab.url])
    XCTAssertEqual(store.tab(tab.id)?.navigation, navigation)
  }
  func testProfileLocalReloadDedupeAndDelayedTitleDoNotCreateVisits() throws {
    let store = BrowserStore(directory: try directory(), memoryOnly: true)
    store.state.profiles.append(.init(id: "other", name: "Other"))
    let firstDate = Date(timeIntervalSince1970: 1000), url = "https://example.com/"
    let first = try XCTUnwrap(store.recordHistoryVisit(profileID: "default", address: url, title: "First", visitedAt: firstDate))
    let other = try XCTUnwrap(store.recordHistoryVisit(profileID: "other", address: url, title: "Other", visitedAt: firstDate))
    let reloadDate = firstDate.addingTimeInterval(59)
    XCTAssertEqual(store.recordHistoryVisit(profileID: "default", address: url, visitedAt: reloadDate), first)
    XCTAssertEqual(store.state.history.count, 2)
    store.updateHistoryVisitTitle(id: first, profileID: "other", address: url, title: "Wrong profile")
    store.updateHistoryVisitTitle(id: first, profileID: "default", address: "https://other.example/", title: "Wrong document")
    store.updateHistoryVisitTitle(id: first, profileID: "default", address: url, title: "  " + String(repeating: "T", count: 550))
    XCTAssertEqual(store.state.history.first { $0.id == first }?.title, String(repeating: "T", count: 500))
    XCTAssertEqual(store.state.history.first { $0.id == first }?.visitedAt, reloadDate)
    XCTAssertEqual(store.state.history.first { $0.id == other }?.title, "Other")
    let later = store.recordHistoryVisit(profileID: "default", address: url, title: "Later", visitedAt: reloadDate.addingTimeInterval(60))
    XCTAssertNotEqual(later, first)
    XCTAssertEqual(store.state.history.count, 3)
  }
  func testRejectedVisitsNeverEnterHistoryAndClearInvalidatesTitleUpdates() throws {
    let store = BrowserStore(directory: try directory())
    store.state.profiles.append(.init(id: "private", name: "Private", isPrivate: true))
    for profile in ["private", "missing"] {
      XCTAssertNil(store.recordHistoryVisit(profileID: profile, address: "https://secret.example/"))
    }
    for address in ["about:blank", "chrome://settings", "chrome-extension://" + String(repeating: "a", count: 32) + "/options.html", "file:///tmp/private", "https://user:password@example.com/"] {
      XCTAssertNil(store.recordHistoryVisit(profileID: "default", address: address))
    }
    XCTAssertNil(store.recordHistoryVisit(profileID: "default", address: "https://example.com/", visitedAt: Date(timeIntervalSince1970: .infinity)))
    XCTAssertTrue(store.state.history.isEmpty)
    let id = try XCTUnwrap(store.recordHistoryVisit(profileID: "default", address: "https://example.com/"))
    try store.clearHistoryDurably(profileID: "default")
    store.updateHistoryVisitTitle(id: id, profileID: "default", address: "https://example.com/", title: "Late title")
    XCTAssertTrue(store.state.history.isEmpty)
    XCTAssertTrue(BrowserStore(directory: store.directory).state.history.isEmpty)
  }
  func testVisitThroughWindowFacadePreservesOtherWindowStateAndPersists() throws {
    let repository = BrowserRepository(directory: try directory())
    let first = repository.focusedStore
    let original = try XCTUnwrap(first.createTab(address: "https://first.example/"))
    let secondStore = try repository.makeWindow(profileID: "default", addresses: ["https://second.example/"])
    secondStore.recordHistoryVisit(profileID: "default", address: "https://second.example/", title: "Second")
    first.recordHistoryVisit(profileID: "default", address: original.url, title: "First")
    XCTAssertEqual(first.state.activeTabID, original.id)
    XCTAssertEqual(secondStore.state.tabs.map(\.url), ["https://second.example/"])
    XCTAssertEqual(repository.canonicalStore.state.history.count, 2)
    XCTAssertEqual(BrowserRepository(directory: repository.directory).canonicalStore.state.history.count, 2)
  }
  func testPeekPromotionRecordsOnlyItsCurrentDestinationAtomically() throws {
    let store = BrowserStore(directory: try directory())
    let source = try XCTUnwrap(store.createTab(address: "https://source.example/"))
    store.setPeek(tabID: source.id, address: "https://peek.example/", title: "Peek")
    try store.updatePeekDurably(tabID: source.id) { $0.url = "https://final.example/"; $0.title = "Final" }
    XCTAssertTrue(store.state.history.isEmpty)
    _ = try store.promotePeekDurably(tabID: source.id)
    XCTAssertEqual(store.state.history.map(\.url), ["https://final.example/"])
    XCTAssertEqual(BrowserStore(directory: store.directory).state.history.map(\.url), ["https://final.example/"])
    store.setPeek(tabID: source.id, address: "https://failed-promotion.example/")
    let before = store.state
    let file = store.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.promotePeekDurably(tabID: source.id))
    XCTAssertEqual(store.state, before)
  }
  func testHistoryCapacityDropsOldestVisit() throws {
    var state = BrowserState()
    state.history = (0..<20_000).map {
      HistoryEntry(profileID: "default", url: "https://example.com/\($0)", title: "Visit", visitedAt: Date(timeIntervalSince1970: Double(30_000 - $0)))
    }
    let removed = try XCTUnwrap(state.history.last).id
    let store = BrowserStore(directory: try directory(), initialState: state, memoryOnly: true)
    let added = store.recordHistoryVisit(profileID: "default", address: "https://new.example/", visitedAt: Date(timeIntervalSince1970: 40_000))
    XCTAssertEqual(store.state.history.count, 20_000)
    XCTAssertEqual(store.state.history.first?.id, added)
    XCTAssertFalse(store.state.history.contains { $0.id == removed })
  }
}
