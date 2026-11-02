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

  func testColdLaunchChoosesMostRecentlyClosedWindowAndPreservesLiveFocus() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    _ = first.createTab(address: "https://first.example")
    let second = try repository.makeWindow(addresses: ["https://last.example"])
    let firstID = try XCTUnwrap(first.owningWindowID), secondID = try XCTUnwrap(second.owningWindowID)
    repository.focusWindow(secondID)
    XCTAssertEqual(repository.startupWindowID, secondID)
    _ = repository.closeWindow(firstID)
    XCTAssertEqual(repository.startupWindowID, secondID)
    _ = repository.closeWindow(secondID)
    try repository.updateWindow(firstID) { $0.closedAt = Date(timeIntervalSince1970: 100) }
    try repository.updateWindow(secondID) { $0.closedAt = Date(timeIntervalSince1970: 200) }
    repository.focusWindow(firstID) // A stale menu target must not override close order.
    let restarted = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(restarted.startupWindowID, secondID)
    XCTAssertFalse(restarted.windows.contains(where: \.isOpen))
    XCTAssertEqual(restarted.store(for: secondID)?.state.activeTab?.url, "https://last.example/")
    _ = try restarted.reopenWindow(id: firstID)
    XCTAssertEqual(restarted.startupWindowID, firstID)
    XCTAssertEqual(restarted.savedWindows.map(\.id), [secondID])
  }

  func testDisabledSessionRestoreKeepsSavedDocumentsDormantInEveryWindow() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://split.example/a"))
    let b = try XCTUnwrap(first.createTab(address: "https://split.example/b"))
    first.setSplit(left: a.id, right: b.id)
    let discarded = try XCTUnwrap(first.createTab(address: "https://ordinary.example"))
    first.selectTab(id: a.id)
    let second = try repository.makeWindow(addresses: ["https://preview.example"])
    let source = try XCTUnwrap(second.state.activeTabID)
    second.setPeek(tabID: source, address: "https://peek.example")
    second.updateSettings { $0.restoreSession = false }
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(Set(reopened.canonicalStore.state.tabs.map(\.id)), [a.id, b.id, source])
    XCTAssertEqual(reopened.canonicalStore.state.archive.first?.id, discarded.id)
    XCTAssertEqual(reopened.canonicalStore.state.splits.count, 1)
    XCTAssertEqual(reopened.canonicalStore.tab(source)?.peek?.url, "https://peek.example/")
    XCTAssertTrue(reopened.windows.allSatisfy { $0.activeTabID == nil && $0.highlightedTabIDs.isEmpty })
    // An unrelated transaction and another disk round trip must not resurrect
    // the remembered split/Peek selection through window normalization.
    reopened.canonicalStore.updateSettings { $0.pageGutter = 8 }
    let twice = BrowserRepository(directory: repository.directory)
    XCTAssertTrue(twice.windows.allSatisfy { $0.activeTabID == nil })
    let firstAgain = try XCTUnwrap(twice.store(for: first.owningWindowID!))
    firstAgain.selectTab(id: a.id)
    XCTAssertEqual(firstAgain.state.activeTabID, a.id)
    XCTAssertNil(twice.store(for: second.owningWindowID!)?.state.activeTabID)
  }

  func testPinnedStartupSelectionIsWindowLocalAndKeepsPeekOrSplitActive() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    let ordinary = try XCTUnwrap(first.createTab(address: "https://ordinary.example"))
    let pinned = try XCTUnwrap(first.createTab(address: "https://pinned.example"))
    first.togglePin(id: pinned.id)
    let second = try repository.makeWindow(addresses: ["https://favorite.example"])
    let favorite = try XCTUnwrap(second.state.activeTabID)
    second.toggleFavorite(id: favorite)
    let third = try repository.makeWindow(addresses: ["https://preview.example"])
    let preview = try XCTUnwrap(third.state.activeTabID)
    third.togglePin(id: preview); third.setPeek(tabID: preview, address: "https://peek.example")
    let fourth = try repository.makeWindow(addresses: ["https://left.example", "https://right.example"])
    let members = fourth.state.tabs.map(\.id)
    fourth.togglePin(id: members[0]); fourth.setSplit(left: members[0], right: members[1])
    fourth.selectTab(id: members[0])
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(reopened.store(for: first.owningWindowID!)?.state.activeTabID, ordinary.id)
    XCTAssertNil(reopened.store(for: second.owningWindowID!)?.state.activeTabID)
    XCTAssertEqual(reopened.store(for: third.owningWindowID!)?.state.activeTabID, preview)
    XCTAssertEqual(reopened.store(for: fourth.owningWindowID!)?.state.activeTabID, members[0])
    let secondAgain = try XCTUnwrap(reopened.store(for: second.owningWindowID!))
    secondAgain.updateProfile("default") { $0.name = "Still dormant" }
    XCTAssertNil(secondAgain.state.activeTabID)
    secondAgain.selectTab(id: favorite)
    XCTAssertEqual(secondAgain.state.activeTabID, favorite)
  }

  func testIntentionalEmptySelectionSurvivesNormalizationButInvalidSelectionRepairs() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    let tab = try XCTUnwrap(first.createTab(address: "https://remembered.example"))
    let windowID = first.owningWindowID!
    try repository.updateWindow(windowID) { $0.activeTabID = nil }
    XCTAssertNil(first.state.activeTabID)
    XCTAssertEqual(repository.windows[0].lastActiveTabBySpace["home"], tab.id)
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertNil(reopened.focusedStore.state.activeTabID)
    try reopened.updateWindow(windowID) { $0.activeTabID = "missing" }
    XCTAssertEqual(reopened.focusedStore.state.activeTabID, tab.id)
  }

  func testSecondWindowSidebarReordersUseItsProjectionAcrossCategoryChanges() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    _ = first.createTab(address:"https://first.example/a")
    _ = first.createTab(address:"https://first.example/b")
    _ = first.createTab(address:"https://first.example/c")
    let firstOrder = first.state.tabs.map(\.id)
    let second = try repository.makeWindow(addresses:["https://second.example/a", "https://second.example/b", "https://second.example/c"])
    let original = second.state.tabs.map(\.id)
    XCTAssertEqual(original.count, 3)
    second.moveTab(id: original[2], index: 1)
    XCTAssertEqual(second.state.tabs.map(\.id), [original[0], original[2], original[1]])
    second.moveTab(id: original[1], index: 0, pinned: true, favorite: true)
    XCTAssertEqual(second.state.tabs.map(\.id), [original[1], original[0], original[2]])
    XCTAssertTrue(second.tab(original[1])!.isFavorite)
    second.moveTab(id: original[1], index: 2, pinned: false, favorite: false, clearFolder: true)
    XCTAssertEqual(second.state.tabs.map(\.id), [original[0], original[2], original[1]])
    XCTAssertFalse(second.tab(original[1])!.isPinned)
    XCTAssertEqual(first.state.tabs.map(\.id), firstOrder)
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(reopened.store(for: second.owningWindowID!)?.state.tabs.map(\.id), second.state.tabs.map(\.id))
    XCTAssertEqual(reopened.store(for: first.owningWindowID!)?.state.tabs.map(\.id), firstOrder)
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

  func testDeletingWorkSpaceKeepsOtherWindowsInTheirOwnProfile() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    let personal = try XCTUnwrap(first.createTab(address: "https://personal.example"))
    let work = try first.createProfileDurably(name: "Work"), retainedSpace = first.state.activeSpaceID
    let removed = first.createSpace(name: "Temporary", profileID: work.id)
    let a = try XCTUnwrap(first.createTab(address: "https://work.example/a"))
    let second = try repository.makeWindow(profileID: work.id, addresses: ["https://work.example/b"])
    second.selectSpace(id: removed.id)
    let b = try XCTUnwrap(second.createTab(address: "https://work.example/selected"))
    let publicWindow = try repository.makeWindow(profileID: "default", addresses: ["https://unrelated.example"])
    publicWindow.selectSpace(id: "home")
    let publicSelection = publicWindow.state.activeTabID
    first.deleteSpace(id: removed.id)
    for scope in [first, second] {
      XCTAssertEqual(scope.activeProfileID, work.id)
      XCTAssertEqual(scope.state.activeSpaceID, retainedSpace)
    }
    XCTAssertEqual(second.state.activeTabID, b.id)
    XCTAssertEqual(first.tab(a.id)?.spaceID, retainedSpace)
    XCTAssertEqual(publicWindow.state.activeSpaceID, "home")
    XCTAssertEqual(publicWindow.state.activeTabID, publicSelection)
    XCTAssertNotNil(first.tab(personal.id))
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(reopened.store(for: second.owningWindowID!)?.activeProfileID, work.id)
    XCTAssertEqual(reopened.store(for: second.owningWindowID!)?.state.activeTabID, b.id)
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
  func testRecentlyClosedWindowsReopenWithoutReplacingSplitHighlightsOrCreatingBlankTabs() throws {
    let repo = BrowserRepository(directory: try directory()), first = repo.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://a.example")), b = try XCTUnwrap(first.createTab(address: "https://b.example"))
    first.setSplit(left: a.id, right: b.id)
    try first.selectTabs([a.id, b.id], activeID: a.id)
    let splitID = first.state.splits[0].id, firstID = first.owningWindowID!
    let second = try repo.makeWindow(addresses: ["https://second.example"]), secondID = second.owningWindowID!
    _ = repo.closeWindow(firstID); _ = repo.closeWindow(secondID)
    try repo.updateWindow(firstID) { $0.closedAt = Date(timeIntervalSince1970: 10) }
    try repo.updateWindow(secondID) { $0.closedAt = Date(timeIntervalSince1970: 20) }
    XCTAssertEqual(first.savedWindows.map(\.id), [secondID, firstID])
    XCTAssertEqual(first.savedWindows.first { $0.id == firstID }?.tabCount, 2)
    let reopened = try repo.reopenWindow(id: firstID)
    XCTAssertEqual(reopened.state.tabs.map(\.id), [a.id, b.id])
    XCTAssertEqual(reopened.state.splits.first?.id, splitID)
    let window = try XCTUnwrap(repo.windows.first { $0.id == firstID })
    XCTAssertEqual(window.highlightedTabIDs, [a.id, b.id]); XCTAssertEqual(window.activeTabID, a.id)
    XCTAssertNil(window.closedAt); XCTAssertEqual(repo.focusedWindowID, firstID)
    let restored = BrowserRepository(directory: repo.directory)
    XCTAssertEqual(restored.savedWindows.map(\.id), [secondID])
    XCTAssertEqual(restored.windows.first { $0.id == firstID }?.isOpen, true)
  }
  func testReopeningSavedWindowIsDurableAndPrivateWindowsAreNeverListed() throws {
    let repo = BrowserRepository(directory: try directory()), first = repo.focusedStore
    _ = first.createTab(address: "https://public.example")
    let id = first.owningWindowID!
    _ = repo.closeWindow(id)
    let secret = repo.canonicalStore.createProfile(name: "Secret", isPrivate: true)
    let privateWindow = try repo.makeWindow(profileID: secret.id)
    _ = repo.closeWindow(privateWindow.owningWindowID!)
    XCTAssertTrue(repo.savedWindows.allSatisfy { $0.profileID != secret.id })
    let before = repo.canonicalStore.state
    try blockWrites(repo.directory)
    XCTAssertThrowsError(try repo.reopenWindow(id: id))
    XCTAssertEqual(repo.canonicalStore.state, before)
  }

}
