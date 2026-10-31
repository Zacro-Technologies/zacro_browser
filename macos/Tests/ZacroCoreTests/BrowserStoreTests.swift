import XCTest

@testable import ZacroCore

@MainActor
final class BrowserStoreTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "zacro-native-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func testAddressPolicyAndSearchDefaults() {
    XCTAssertEqual(
      BrowserAddress.resolve("hello & world")?.absoluteString,
      "https://www.google.com/search?q=hello%20%26%20world")
    XCTAssertEqual(
      BrowserAddress.resolve("localhost:8080/path")?.absoluteString, "http://localhost:8080/path")
    XCTAssertEqual(BrowserAddress.resolve("example.com")?.absoluteString, "https://example.com")
    for address in [
      "javascript:alert(1)", "file:///tmp/secret", "data:text/html,test",
      "https://user:password@example.com", "https://", "mailto:someone@example.com", "custom:thing",
      "",
    ] {
      XCTAssertNil(BrowserAddress.resolve(address), address)
    }
    XCTAssertEqual(BrowserState().settings.pageGutter, 4)
    XCTAssertEqual(BrowserState().settings.searchEngine, .google)
  }
  func testPersistentSplitsPeeksAndNavigationAcrossRestart() throws {
    let dir = try directory()
    let store = BrowserStore(directory: dir)
    let first = try XCTUnwrap(store.createTab(address: "https://example.com/start"))
    let second = try XCTUnwrap(store.createTab(address: "https://example.org"))
    store.navigate(tabID: first.id, address: "https://example.com/next", title: "Next")
    store.setPeek(tabID: first.id, address: "https://example.net/preview", title: "Preview")
    store.setSplit(left: first.id, right: second.id)
    store.setSplitRatio(id: try XCTUnwrap(store.split(for: first.id)).id, ratio: 0.7)
    _ = store.createTab(address: "https://example.com/unrelated")
    let reopened = BrowserStore(directory: dir)
    XCTAssertEqual(reopened.split(for: first.id)?.ratio, 0.7)
    XCTAssertEqual(reopened.tab(first.id)?.peek?.title, "Preview")
    XCTAssertEqual(reopened.back(tabID: first.id), "https://example.com/start")
    XCTAssertEqual(reopened.forward(tabID: first.id), "https://example.com/next")
    reopened.unsplit(tabID: first.id)
    XCTAssertTrue(reopened.state.splits.isEmpty)
    XCTAssertEqual(reopened.state.tabs.count, 3)
  }
  func testPrivateProfileNeverPersists() throws {
    let dir = try directory()
    let store = BrowserStore(directory: dir)
    let profile = store.createProfile(name: "Secret profile", isPrivate: true)
    let tab = try XCTUnwrap(store.createTab(address: "https://secret.example.com"))
    store.setPeek(tabID: tab.id, address: "https://secret.example.com/peek")
    store.toggleBookmark(url: tab.url, title: "Secret bookmark")
    store.recordDownload(
      DownloadRecord(profileID: profile.id, url: tab.url, filename: "secret.txt"))
    store.navigate(tabID: tab.id, address: "https://secret.example.com/next")
    store.save()
    let raw = try String(
      contentsOf: dir.appendingPathComponent("native-state.json"), encoding: .utf8)
    XCTAssertFalse(raw.contains("secret"))
    XCTAssertFalse(raw.contains(profile.id))
    let reopened = BrowserStore(directory: dir)
    XCTAssertEqual(reopened.state.profiles.count, 1)
    XCTAssertNil(reopened.state.activeTabID)
    XCTAssertEqual(reopened.state.activeSpaceID, "home")
  }
  func testMovingSplitMovesBothMembersAndRejectsProfileCrossing() throws {
    let store = BrowserStore(directory: try directory())
    let left = try XCTUnwrap(store.createTab(address: "https://left.example"))
    let right = try XCTUnwrap(store.createTab(address: "https://right.example"))
    store.setSplit(left: left.id, right: right.id)
    let destination = store.createSpace(name: "Work")
    store.moveTab(id: left.id, spaceID: destination.id)
    XCTAssertEqual(store.tab(right.id)?.spaceID, destination.id)
    XCTAssertEqual(store.split(for: left.id)?.spaceID, destination.id)
    _ = store.createProfile(name: "Other")
    let foreignSpace = store.state.activeSpaceID
    store.moveTab(id: left.id, spaceID: foreignSpace)
    XCTAssertEqual(store.tab(left.id)?.spaceID, destination.id)
    XCTAssertNotNil(store.lastError)
  }
  func testClosingPinsKeepsDestinationAndArchiveRestoresHistory() throws {
    let store = BrowserStore(directory: try directory())
    let pinned = try XCTUnwrap(store.createTab(address: "https://example.com"))
    store.togglePin(id: pinned.id)
    store.navigate(tabID: pinned.id, address: "https://example.com/away")
    store.closeTab(id: pinned.id)
    XCTAssertEqual(store.tab(pinned.id)?.url, "https://example.com")
    XCTAssertEqual(store.tab(pinned.id)?.isClosed, true)
    XCTAssertTrue(store.state.archive.isEmpty)
    let normal = try XCTUnwrap(store.createTab(address: "https://example.net/a"))
    store.navigate(tabID: normal.id, address: "https://example.net/b")
    store.closeTab(id: normal.id)
    XCTAssertNil(store.tab(normal.id))
    XCTAssertEqual(store.restoreTab(id: normal.id)?.id, normal.id)
    XCTAssertEqual(store.back(tabID: normal.id), "https://example.net/a")
  }
  func testMalformedSavedStateIsPreservedOnFirstMutation() throws {
    let dir = try directory()
    let file = dir.appendingPathComponent("native-state.json")
    try Data("broken".utf8).write(to: file)
    let store = BrowserStore(directory: dir)
    XCTAssertNotNil(store.lastError)
    _ = store.createTab(address: "example.com")
    let preserved = try FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("native-state-unreadable-") }
    XCTAssertEqual(preserved.count, 1)
    XCTAssertEqual(try String(contentsOf: preserved[0], encoding: .utf8), "broken")
    XCTAssertEqual(BrowserStore(directory: dir).state.tabs.count, 1)
  }
  func testLegacyImportDoesNotModifySourceAndDropsUnsafeURLs() throws {
    let dir = try directory()
    let source = dir.appendingPathComponent("old-state.json")
    let original = Data(
      #"{"profiles":[{"id":"default","name":"Personal"}],"spaces":[{"id":"home","profileId":"default","name":"Home"}],"tabs":[{"id":"one","spaceId":"home","url":"https://example.com","title":"Example","pinned":true,"pinnedUrl":"https://example.com/home","navigationHistory":{"entries":[{"url":"https://example.com/before"},{"url":"https://example.com"},{"url":"https://example.com/after"}],"index":1}},{"id":"bad","spaceId":"home","url":"javascript:alert(1)"}],"settings":{"pageGutter":4,"searchEngine":"google"},"activeSpaceId":"home","activeTabId":"one"}"#
        .utf8)
    try original.write(to: source)
    let store = BrowserStore(directory: dir)
    try store.importLegacy(from: source)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(store.state.tabs.count, 1)
    XCTAssertEqual(store.state.tabs[0].isPinned, true)
    XCTAssertEqual(store.state.activeTabID, "one")
    XCTAssertEqual(store.tab("one")?.savedURL, "https://example.com/home")
    XCTAssertEqual(store.forward(tabID: "one"), "https://example.com/after")
  }
  func testPartialSettingsAndDisabledRestoreKeepSavedDestinations() throws {
    let partial = try JSONDecoder().decode(
      BrowserSettings.self, from: Data(#"{"searchEngine":"unknown"}"#.utf8))
    XCTAssertEqual(partial.pageGutter, 4)
    XCTAssertEqual(partial.searchEngine, .google)
    let dir = try directory()
    let store = BrowserStore(directory: dir)
    let pin = try XCTUnwrap(store.createTab(address: "pin.example"))
    store.togglePin(id: pin.id)
    _ = store.createTab(address: "temporary.example")
    store.updateSettings { $0.restoreSession = false }
    let reopened = BrowserStore(directory: dir)
    XCTAssertEqual(reopened.state.tabs.map(\.id), [pin.id])
    XCTAssertNil(reopened.state.activeTabID)
  }
  func testActiveSelectionCannotCrossProfileAfterRepair() throws {
    let store = BrowserStore(directory: try directory())
    let publicTab = try XCTUnwrap(store.createTab(address: "public.example"))
    _ = store.createProfile(name: "Other")
    store.state.activeTabID = publicTab.id
    store.repair()
    XCTAssertNil(store.state.activeTabID)
  }
  func testRepairRejectsUnsafeIdentifiersAndURLControls() throws {
    let store = BrowserStore(directory: try directory())
    store.state.profiles.append(BrowserProfile(id: "../other-profile", name: "Unsafe"))
    store.state.spaces.append(
      BrowserSpace(id: "evil", profileID: "../other-profile", name: "Unsafe"))
    store.state.tabs.append(BrowserTab(id: "evil-tab", spaceID: "evil", url: "https://example.com"))
    store.repair()
    XCTAssertEqual(store.state.profiles.count, 1)
    XCTAssertEqual(store.state.spaces.count, 1)
    XCTAssertTrue(store.state.tabs.isEmpty)
    XCTAssertNil(BrowserAddress.webURL("https://example.com/\nsecret"))
  }
  func testArchiveExcludesPersistentSplitsAndPeeks() throws {
    let store = BrowserStore(directory: try directory())
    let a = try XCTUnwrap(store.createTab(address: "a.example"))
    let b = try XCTUnwrap(store.createTab(address: "b.example"))
    let c = try XCTUnwrap(store.createTab(address: "c.example"))
    let d = try XCTUnwrap(store.createTab(address: "d.example"))
    store.setSplit(left: a.id, right: b.id)
    store.setPeek(tabID: c.id, address: "https://peek.example")
    store.selectTab(id: d.id)
    store.archiveStale(now: Date().addingTimeInterval(86400))
    XCTAssertEqual(store.state.tabs.count, 4)
  }
}
