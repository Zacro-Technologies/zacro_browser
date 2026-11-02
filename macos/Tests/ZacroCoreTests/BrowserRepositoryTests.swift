import XCTest
@testable import ZacroCore

@MainActor final class BrowserRepositoryTests: XCTestCase {
  private func directory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroWindows-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: path) }
    return path
  }
  private func blockWrites(_ path: URL) throws {
    let file = path.appendingPathComponent("native-state.json")
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
  }

  func testLegacyMigrationAssignsRetainedTabsAndPreservesSelection() throws {
    var legacy = BrowserState()
    let normal = BrowserTab(spaceID: "home", url: "https://example.com")
    var favorite = BrowserTab(spaceID: "home", url: "https://favorite.example", isFavorite: true, isPinned: true)
    favorite.isClosed = true
    legacy.tabs = [normal, favorite]; legacy.activeTabID = normal.id
    let repository = BrowserRepository(directory: try directory(), initialState: legacy)
    XCTAssertEqual(repository.windows.count, 1)
    XCTAssertEqual(repository.focusedStore.state.activeTabID, normal.id)
    XCTAssertEqual(Set(repository.canonicalStore.state.tabs.compactMap(\.windowID)), [repository.defaultWindowID])
    XCTAssertTrue(repository.focusedStore.tab(favorite.id)!.isClosed)
    try repository.canonicalStore.flush()
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(reopened.focusedStore.state.activeTabID, normal.id)
    XCTAssertEqual(reopened.windows[0].id, repository.windows[0].id)
  }

  func testWindowFacadesShareCollectionsButKeepSelectionAndLayoutIndependent() throws {
    let repository = BrowserRepository(directory: try directory())
    let first = repository.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://one.example"))
    let second = try repository.makeWindow(addresses: ["https://two.example"])
    let b = try XCTUnwrap(second.state.activeTab)
    first.updateSettings { $0.sidebarWidth = 310; $0.pageGutter = 10 }
    second.updateProfile("default") { $0.name = "Shared" }
    let c = try XCTUnwrap(first.createTab(address: "https://three.example"))
    XCTAssertEqual(Set(repository.canonicalStore.state.tabs.map(\.id)), [a.id, b.id, c.id])
    XCTAssertEqual(second.state.activeTabID, b.id)
    XCTAssertEqual(first.state.activeTabID, c.id)
    XCTAssertEqual(first.state.settings.sidebarWidth, 310)
    XCTAssertEqual(second.state.settings.sidebarWidth, 224)
    XCTAssertEqual(second.state.settings.pageGutter, 10)
    XCTAssertEqual(first.state.profiles[0].name, "Shared")
    first.selectTab(id: b.id); first.updateTab(b.id) { $0.title = "Incorrect" }
    XCTAssertEqual(first.state.activeTabID, c.id)
    XCTAssertNotEqual(second.tab(b.id)?.title, "Incorrect")
    XCTAssertEqual(repository.canonicalStore.state.activeTabID, b.id)
  }

  func testSpaceMemoryIsWindowLocalAndDeletingSharedSpaceMovesBothOwners() throws {
    let repository = BrowserRepository(directory: try directory())
    let first = repository.focusedStore, a = try XCTUnwrap(first.createTab(address: "https://first.example"))
    let space = first.createSpace(name: "Second")
    let firstSecond = try XCTUnwrap(first.createTab(address: "https://first-second.example"))
    let second = try repository.makeWindow(addresses: ["https://other.example"])
    second.selectSpace(id: space.id)
    let otherSecond = try XCTUnwrap(second.createTab(address: "https://other-second.example"))
    first.selectSpace(id: "home"); XCTAssertEqual(first.state.activeTabID, a.id)
    first.selectSpace(id: space.id); XCTAssertEqual(first.state.activeTabID, firstSecond.id)
    XCTAssertEqual(second.state.activeTabID, otherSecond.id)
    first.deleteSpace(id: space.id)
    XCTAssertEqual(second.tab(otherSecond.id)?.spaceID, "home")
    XCTAssertEqual(second.state.activeSpaceID, "home")
    XCTAssertNotNil(first.tab(firstSecond.id))
  }

  func testSplitTransferMovesBothMembersWithoutReplacingTheirState() throws {
    let repository = BrowserRepository(directory: try directory())
    let first = repository.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://a.example")), b = try XCTUnwrap(first.createTab(address: "https://b.example"))
    first.setSplit(left: a.id, right: b.id)
    first.setPeek(tabID: a.id, address: "https://peek.example")
    first.updateTab(a.id) { $0.autoDiscardable = false }
    let split = try XCTUnwrap(first.split(for: a.id))
    let second = try repository.makeWindow(addresses: ["https://destination.example"])
    try repository.moveTabs([a.id], toWindowID: second.owningWindowID!, index: 0)
    XCTAssertNil(first.tab(a.id)); XCTAssertNil(first.tab(b.id))
    XCTAssertEqual(second.split(for: a.id)?.id, split.id)
    XCTAssertEqual(second.tab(a.id)?.peek?.url, "https://peek.example/")
    XCTAssertEqual(second.tab(a.id)?.autoDiscardable, false)
    XCTAssertEqual(second.tab(a.id)?.navigation, a.navigation)
  }

  func testHighlightIsAtomicAndCannotSelectAnotherWindowOrProfile() throws {
    let repository = BrowserRepository(directory: try directory())
    let first = repository.focusedStore
    let a = try XCTUnwrap(first.createTab()), b = try XCTUnwrap(first.createTab())
    let second = try repository.makeWindow()
    let secondActive = second.state.activeTabID!
    try repository.selectTabs([a.id, b.id], activeID: a.id, inWindowID: first.owningWindowID!)
    XCTAssertEqual(repository.windows.first { $0.id == first.owningWindowID }?.highlightedTabIDs, [a.id, b.id])
    XCTAssertEqual(second.state.activeTabID, secondActive)
    XCTAssertThrowsError(try repository.selectTabs([a.id, secondActive], activeID: a.id, inWindowID: first.owningWindowID!))
    first.closeTab(id: a.id)
    XCTAssertEqual(first.state.activeTabID, b.id)
  }

  func testWindowCreationAndTransferRollbackCompletelyOnFailedWrite() throws {
    let path = try directory(), repository = BrowserRepository(directory: path)
    let source = repository.focusedStore, tab = try XCTUnwrap(source.createTab(address: "https://kept.example"))
    let destination = try repository.makeWindow()
    let before = repository.canonicalStore.state
    try blockWrites(path)
    var bounds = BrowserWindowBounds(); bounds.width = 900
    XCTAssertThrowsError(try repository.makeWindow(addresses: ["https://new.example", "https://other.example"], bounds: bounds))
    XCTAssertEqual(repository.canonicalStore.state, before)
    XCTAssertThrowsError(try repository.moveTabs([tab.id], toWindowID: destination.owningWindowID!))
    XCTAssertEqual(repository.canonicalStore.state, before)
    XCTAssertEqual(source.tab(tab.id)?.windowID, source.owningWindowID)
  }

  func testClosedPublicWindowRestoresWithoutArchivingOrDuplicatingTabs() throws {
    let repository = BrowserRepository(directory: try directory())
    let source = repository.focusedStore, tab = try XCTUnwrap(source.createTab(address: "https://kept.example"))
    XCTAssertTrue(repository.closeWindow(source.owningWindowID!).isEmpty)
    XCTAssertTrue(repository.canonicalStore.state.archive.isEmpty)
    let reopened = try repository.makeWindow()
    XCTAssertEqual(reopened.owningWindowID, source.owningWindowID)
    XCTAssertEqual(reopened.state.tabs.map(\.id), [tab.id])
    XCTAssertEqual(reopened.state.activeTabID, tab.id)
  }

  func testParkedWindowCountDoesNotBlockNewOpenWindows() throws {
    var state = BrowserState()
    var sessions = [BrowserWindowSession(id: "open", activeSpaceID: "home")]
    for index in 0..<100 {
      var window = BrowserWindowSession(id: "parked-\(index)", activeSpaceID: "home"); window.isOpen = false
      var tab = BrowserTab(spaceID: "home", url: "https://example.com/\(index)"); tab.windowID = window.id
      sessions.append(window); state.tabs.append(tab)
    }
    state.windowSessions = sessions; state.focusedWindowID = "open"
    let repository = BrowserRepository(directory: try directory(), initialState: state)
    let created = try repository.makeWindow()
    XCTAssertNotEqual(created.owningWindowID, "open")
    XCTAssertEqual(repository.windows.filter(\.isOpen).count, 2)
    XCTAssertEqual(repository.windows.filter { !$0.isOpen }.count, 100)
  }

  func testPrivateCloseDiscardsOnlyAfterLastOwnerAndDoesNotNeedDisk() throws {
    let path = try directory(), repository = BrowserRepository(directory: path)
    let publicWindow = repository.focusedStore
    let profile = try publicWindow.createProfileDurably(name: "Private", isPrivate: true)
    let privateSpace = publicWindow.state.activeSpaceID
    publicWindow.selectSpace(id: "home")
    let privateWindow = try repository.makeWindow(profileID: profile.id)
    let privateID = privateWindow.owningWindowID!
    let tab = try XCTUnwrap(privateWindow.createTab(address: "https://secret.example"))
    try repository.canonicalStore.flush()
    let persisted = try String(contentsOf: path.appendingPathComponent("native-state.json"), encoding: .utf8)
    XCTAssertFalse(persisted.contains("secret.example")); XCTAssertFalse(persisted.contains(profile.id)); XCTAssertFalse(persisted.contains(privateSpace)); XCTAssertFalse(persisted.contains(privateID))
    try blockWrites(path)
    XCTAssertEqual(repository.closeWindow(privateID), [profile.id])
    XCTAssertFalse(repository.windows.contains { $0.id == privateID })
    XCTAssertFalse(repository.canonicalStore.state.profiles.contains { $0.id == profile.id })
    XCTAssertNil(repository.canonicalStore.tab(tab.id))
    XCTAssertTrue(repository.windows.contains { $0.id == publicWindow.owningWindowID && $0.isOpen })
  }

  func testStaleDirectFacadeSnapshotCannotReplaceAuthoritativeTabs() throws {
    let repository = BrowserRepository(directory: try directory())
    let first = repository.focusedStore
    let second = try repository.makeWindow()
    let id = try XCTUnwrap(second.state.activeTabID)
    first.state.tabs.removeAll(); first.state.profiles[0].name = "Stale"
    XCTAssertThrowsError(try first.flush())
    XCTAssertNotNil(repository.canonicalStore.tab(id))
    XCTAssertNotEqual(repository.canonicalStore.state.profiles[0].name, "Stale")
    XCTAssertNotNil(first.lastError)
  }
}
