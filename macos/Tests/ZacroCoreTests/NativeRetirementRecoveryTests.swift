import XCTest
@testable import ZacroCore

@MainActor final class NativeRetirementRecoveryTests: XCTestCase {
  private func repository() throws -> BrowserRepository {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroRetirement-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return BrowserRepository(directory: directory)
  }
  private func snapshot(_ store: BrowserStore, _ id: String, peek: Bool = false) throws -> NativeRetirementSnapshot {
    let source = try XCTUnwrap(store.tab(id))
    let profileID = try XCTUnwrap(store.profileID(for: source))
    let profile = try XCTUnwrap(store.state.profiles.first { $0.id == profileID })
    return NativeRetirementSnapshot(pageID: peek ? "peek:" + id : id, profileID: profileID,
      isPrivate: profile.isPrivate, ownerWindowID: try XCTUnwrap(source.windowID),
      source: source, preview: peek ? source.peek : nil,
      splits: store.state.splits.filter { $0.tabIDs.contains(id) })
  }
  func testClosedNormalTabRecoveryPreservesOtherWindowAndHistoryWithoutDuplicateArchive() throws {
    let repo = try repository(), first = repo.focusedStore
    let a = try XCTUnwrap(first.createTab(address: "https://example.com/a"))
    first.navigate(tabID: a.id, address: "https://example.com/b")
    first.setPeek(tabID: a.id, address: "https://example.com/preview", title: "Preview")
    try first.updatePeekDurably(tabID: a.id) {
      $0.navigation = [NavigationEntry(url: $0.url, title: $0.title)]
      $0.navigationIndex = 0
    }
    let saved = try snapshot(first, a.id)
    let second = try repo.makeWindow(addresses: ["https://other.example/"])
    first.closeTab(id: a.id)
    let other = second.state.tabs, selection = second.state.activeTabID
    let windows = repo.windows, focusedWindow = repo.focusedWindowID
    let history = repo.canonicalStore.state.history
    let result = try repo.canonicalStore.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(result, saved.source)
    XCTAssertEqual(result.windowID, first.owningWindowID)
    XCTAssertEqual(repo.windows, windows); XCTAssertEqual(repo.focusedWindowID, focusedWindow)
    XCTAssertEqual(second.state.tabs, other); XCTAssertEqual(second.state.activeTabID, selection)
    XCTAssertEqual(repo.canonicalStore.state.history, history)
    XCTAssertFalse(repo.canonicalStore.state.archive.contains { $0.id == a.id })
    XCTAssertEqual(BrowserRepository(directory: repo.directory).canonicalStore.tab(a.id), result)
  }
  func testPinRecoveryKeepsNewHomeAndNameButRestoresLiveHistory() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/home"))
    scope.togglePin(id: tab.id)
    scope.navigate(tabID: tab.id, address: "https://example.com/live")
    let saved = try snapshot(scope, tab.id)
    scope.closeTab(id: tab.id)
    scope.updateTab(tab.id) { $0.customTitle = "New name"; $0.savedURL = "https://example.com/new-home" }
    let result = try scope.recoverRetiringDocumentDurably(saved)
    XCTAssertTrue(result.isPinned); XCTAssertFalse(result.isClosed); XCTAssertNil(result.closedAt)
    XCTAssertEqual(result.customTitle, "New name"); XCTAssertEqual(result.savedURL, "https://example.com/new-home")
    XCTAssertEqual(result.url, saved.source.url); XCTAssertEqual(result.navigation, saved.source.navigation)
  }
  func testPeekRecoveryPreservesCompleteMetadataAndRejectsNewPreview() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/source"))
    scope.setPeek(tabID: tab.id, address: "https://example.com/peek", title: "Peek")
    try scope.updatePeekDurably(tabID: tab.id) {
      $0.isMuted = true; $0.autoDiscardable = false; $0.isPresented = false
      $0.navigation = [NavigationEntry(url: "https://example.com/previous"), NavigationEntry(url: $0.url)]
      $0.navigationIndex = 1
    }
    let saved = try snapshot(scope, tab.id, peek: true)
    scope.closePeek(tabID: tab.id)
    try scope.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(scope.tab(tab.id)?.peek, saved.preview)
    scope.closePeek(tabID: tab.id)
    scope.setPeek(tabID: tab.id, address: "https://example.com/new")
    let before = repo.canonicalStore.state
    XCTAssertThrowsError(try scope.recoverRetiringDocumentDurably(saved))
    XCTAssertEqual(repo.canonicalStore.state, before)
  }
  func testDeletedProfileOrRetirementAuthorityCannotBeRecreated() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/"))
    let saved = try snapshot(scope, tab.id)
    var missing = repo.canonicalStore.state; missing.profiles.removeAll { $0.id == saved.profileID }
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(missing, snapshot: saved))
    var retired = repo.canonicalStore.state; retired.pendingNativeProfileRetirements = [saved.profileID]
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(retired, snapshot: saved))
    var privacyChanged = repo.canonicalStore.state; privacyChanged.profiles[0].isPrivate = true
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(privacyChanged, snapshot: saved))
  }
  func testLivePeekCanRecoverItsRemovedUnmaterializedSourceAtomically() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/source"))
    scope.setPeek(tabID: tab.id, address: "https://example.com/preview", title: "Retained")
    try scope.updatePeekDurably(tabID: tab.id) {
      $0.navigation = [NavigationEntry(url: $0.url, title: $0.title)]
      $0.navigationIndex = 0
    }
    let saved = try snapshot(scope, tab.id, peek: true)
    scope.closeTab(id: tab.id)
    let recovered = try scope.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(recovered.id, saved.pageID)
    XCTAssertEqual(scope.tab(tab.id)?.peek, saved.preview)
    XCTAssertEqual(scope.tab(tab.id)?.url, saved.source.url)
    XCTAssertFalse(scope.state.archive.contains { $0.id == tab.id })
  }
  func testRecoveryRestoresCompatibleSplitAndRespectsTabBound() throws {
    let repo = try repository(), scope = repo.focusedStore
    let a = try XCTUnwrap(scope.createTab(address: "https://example.com/a"))
    let b = try XCTUnwrap(scope.createTab(address: "https://example.com/b"))
    scope.setSplit(left: a.id, right: b.id)
    let saved = try snapshot(scope, a.id)
    scope.closeTab(id: a.id)
    try scope.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(scope.state.splits, saved.splits)
    var full = repo.canonicalStore.state
    full.tabs = (0..<1_000).map { index in
      var tab = BrowserTab(spaceID: a.spaceID, url: "https://example.com/\(index)")
      tab.windowID = saved.ownerWindowID; return tab
    }
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(full, snapshot: saved))
  }
  func testForeignOwnerReplacementAndParkedWindowRejectWithoutMutation() throws {
    let repo = try repository(), first = repo.focusedStore
    let tab = try XCTUnwrap(first.createTab(address: "https://example.com/"))
    let saved = try snapshot(first, tab.id)
    let second = try repo.makeWindow(addresses: ["https://other.example/"])
    first.closeTab(id: tab.id)
    let removed = repo.canonicalStore.state
    XCTAssertThrowsError(try second.recoverRetiringDocumentDurably(saved)) { error in
      guard let rejection = error as? NativeRetirementRecoveryError,
        case .windowUnavailable = rejection else {
        return XCTFail("Foreign façade rejected for the wrong reason: \(error)")
      }
    }
    XCTAssertEqual(repo.canonicalStore.state, removed)
    let restored = try first.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(restored.windowID, first.owningWindowID)
    XCTAssertEqual(repo.focusedWindowID, second.owningWindowID)
    try repo.moveTabs([tab.id], toWindowID: second.owningWindowID!, index: -1)
    let foreign = repo.canonicalStore.state
    XCTAssertThrowsError(try repo.canonicalStore.recoverRetiringDocumentDurably(saved))
    XCTAssertEqual(repo.canonicalStore.state, foreign)
    var parked = foreign
    parked.tabs.removeAll { $0.id == tab.id }
    let index = try XCTUnwrap(parked.windowSessions?.firstIndex { $0.id == saved.ownerWindowID })
    parked.windowSessions![index].isOpen = false
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(parked, snapshot: saved))
    var replacement = foreign
    let tabIndex = try XCTUnwrap(replacement.tabs.firstIndex { $0.id == tab.id })
    replacement.tabs[tabIndex] = saved.source
    replacement.tabs[tabIndex].isClosed = true
    replacement.tabs[tabIndex].createdAt = saved.source.createdAt.addingTimeInterval(1)
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(replacement, snapshot: saved))
  }
  func testRecoveryCanUseExistingSameProfileSpaceButNeverCreatesOne() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/"))
    let saved = try snapshot(scope, tab.id)
    var state = repo.canonicalStore.state
    state.tabs.removeAll { $0.id == tab.id }; state.spaces.removeAll()
    XCTAssertThrowsError(try NativeRetirementRecovery.candidate(state, snapshot: saved))
    let destination = BrowserSpace(profileID: saved.profileID, name: "Existing")
    state.spaces = [destination]
    let recovered = try NativeRetirementRecovery.candidate(state, snapshot: saved)
    XCTAssertEqual(recovered.tabs.first { $0.id == tab.id }?.spaceID, destination.id)
    XCTAssertEqual(recovered.spaces, state.spaces)
  }
  func testSplitRecoveryCannotTakeMemberFromReplacementSplit() throws {
    let repo = try repository(), scope = repo.focusedStore
    let a = try XCTUnwrap(scope.createTab(address: "https://example.com/a"))
    let b = try XCTUnwrap(scope.createTab(address: "https://example.com/b"))
    let c = try XCTUnwrap(scope.createTab(address: "https://example.com/c"))
    scope.setSplit(left: a.id, right: b.id)
    let saved = try snapshot(scope, a.id)
    scope.closeTab(id: a.id); scope.setSplit(left: b.id, right: c.id)
    let replacement = scope.state.splits
    try scope.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(scope.state.splits, replacement)
  }
  func testPrivateRecoveryNeverPersistsPrivateProfileOrDocument() throws {
    let repo = try repository(), scope = repo.focusedStore
    let profile = try scope.createProfileDurably(name: "Private", isPrivate: true)
    let privateStore = try repo.makeWindow(profileID: profile.id)
    let tab = try XCTUnwrap(privateStore.createTab(address: "https://private.example/secret"))
    let saved = try snapshot(privateStore, tab.id)
    privateStore.closeTab(id: tab.id)
    try privateStore.recoverRetiringDocumentDurably(saved)
    XCTAssertEqual(privateStore.tab(tab.id)?.url, saved.source.url)
    let restarted = BrowserRepository(directory: repo.directory)
    XCTAssertFalse(restarted.canonicalStore.state.profiles.contains { $0.id == profile.id })
    XCTAssertNil(restarted.canonicalStore.tab(tab.id))
  }
  func testMalformedSnapshotRejectsBeforeWritingAndDiskFailureRollsBack() throws {
    let repo = try repository(), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com/"))
    let saved = try snapshot(scope, tab.id)
    scope.closeTab(id: tab.id)
    var invalid = saved.source; invalid.url = "javascript:alert(1)"; invalid.nativeNavigation = nil
    let bad = NativeRetirementSnapshot(pageID: tab.id, profileID: saved.profileID, isPrivate: false,
      ownerWindowID: saved.ownerWindowID, source: invalid, preview: nil, splits: [])
    let before = repo.canonicalStore.state
    XCTAssertThrowsError(try scope.recoverRetiringDocumentDurably(bad))
    XCTAssertEqual(repo.canonicalStore.state, before)
    let file = repo.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try scope.recoverRetiringDocumentDurably(saved)) { error in
      XCTAssertFalse(error is NativeRetirementRecoveryError,
        "The valid recovery must reach persistence and report its actual I/O failure.")
    }
    XCTAssertEqual(repo.canonicalStore.state, before)
  }
}
