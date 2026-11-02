import XCTest
@testable import ZacroCore

@MainActor final class PeekDocumentTests: XCTestCase {
  private func repository() throws -> BrowserRepository {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroPeekDocuments-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return BrowserRepository(directory: dir)
  }
  private func proof(_ url: String) throws -> NativeNavigationProvenance {
    let id = String(repeating: "a", count: 32)
    return try XCTUnwrap(NativeNavigationProvenance(extensionID: id, incarnationID: id + ":123", approvedURL: url))
  }
  func testLegacyPeekProjectsStableDocumentWithoutAddingPersistentTab() throws {
    let peek = try JSONDecoder().decode(SavedPeek.self, from: Data(#"{"url":"https://peek.example/","title":"Peek"}"#.utf8))
    var source = BrowserTab(spaceID: "home", url: "https://source.example/"); source.windowID = "window"; source.peek = peek
    let first = try XCTUnwrap(source.peekDocument), second = try XCTUnwrap(source.peekDocument)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.id, "peek:" + source.id); XCTAssertEqual(first.openerTabID, source.id)
    XCTAssertEqual(first.windowID, "window"); XCTAssertNil(first.peek)
    XCTAssertNotEqual(peek.isPresented, false); XCTAssertFalse(peek.isMuted)
  }
  func testDocumentSelectionHidesRetainedPeekAndSidebarRevealsIt() throws {
    let repo = try repository(), scope = repo.focusedStore
    let source = try XCTUnwrap(scope.createTab(address: "https://source.example/"))
    scope.setPeek(tabID: source.id, address: "https://peek.example/", title: "Peek")
    try scope.selectDocumentDurably(id: source.id)
    XCTAssertEqual(scope.tab(source.id)?.peek?.isPresented, false)
    XCTAssertNotNil(scope.document(id: "peek:" + source.id))
    let restarted = BrowserRepository(directory: repo.directory), restored = restarted.focusedStore
    XCTAssertEqual(restored.tab(source.id)?.peek?.isPresented, false)
    try restored.selectDocumentDurably(id: "peek:" + source.id)
    XCTAssertEqual(restored.state.activeTabID, source.id); XCTAssertEqual(restored.tab(source.id)?.peek?.isPresented, true)
    try restored.selectDocumentDurably(id: source.id)
    restored.selectTab(id: source.id)
    XCTAssertEqual(restored.tab(source.id)?.peek?.isPresented, true)
    try restarted.selectTabs([source.id], activeID: source.id, inWindowID: restored.owningWindowID!, presentPeek: false)
    XCTAssertEqual(restored.tab(source.id)?.peek?.isPresented, false)
    XCTAssertEqual(restored.state.tabs.count, 1)
  }
  func testNativePeekPromotionPreservesHistoryMetadataAndSourceOpener() throws {
    let repo = try repository(), scope = repo.focusedStore
    let source = try XCTUnwrap(scope.createTab(address: "https://source.example/"))
    scope.setPeek(tabID: source.id, address: "https://peek.example/", title: "First")
    let url = "file:///tmp/approved.html", approval = try proof("file:///tmp/approved.html")
    try scope.updatePeekDurably(tabID: source.id) {
      $0.url = url; $0.title = "Local file"; $0.nativeNavigation = approval
      $0.isMuted = true; $0.autoDiscardable = false; $0.isPresented = false
    }
    let preview = try XCTUnwrap(scope.document(id: "peek:" + source.id))
    XCTAssertEqual(preview.navigation.map(\.url), ["https://peek.example/", url])
    let promoted = try scope.promotePeekDurably(tabID: source.id, activate: false)
    XCTAssertEqual(promoted.nativeNavigation, approval); XCTAssertTrue(promoted.isMuted)
    XCTAssertEqual(promoted.autoDiscardable, false); XCTAssertEqual(promoted.openerTabID, source.id)
    XCTAssertEqual(promoted.navigation, preview.navigation)
    XCTAssertEqual(scope.state.activeTabID, source.id); XCTAssertNil(scope.tab(source.id)?.peek)
    XCTAssertEqual(scope.back(tabID: promoted.id), "https://peek.example/")
    XCTAssertEqual(scope.forward(tabID: promoted.id), url)
    XCTAssertEqual(scope.tab(promoted.id)?.nativeNavigation, approval)
  }
  func testPeekMutationsRollbackAndImportedSnapshotsCannotCarryNativeAuthority() throws {
    let repo = try repository(), scope = repo.focusedStore
    let source = try XCTUnwrap(scope.createTab(address: "https://source.example/"))
    scope.setPeek(tabID: source.id, address: "https://peek.example/", title: "Peek")
    let before = repo.canonicalStore.state
    XCTAssertThrowsError(try scope.updatePeekDurably(tabID: source.id) { $0.url = "file:///tmp/no-approval" })
    XCTAssertEqual(repo.canonicalStore.state, before)
    let approvedURL = "file:///tmp/private-peek.html", approval = try proof("file:///tmp/private-peek.html")
    try scope.updatePeekDurably(tabID: source.id) { $0.url = approvedURL; $0.nativeNavigation = approval }
    let snapshot = repo.directory.appendingPathComponent("export.json")
    try JSONEncoder().encode(repo.canonicalStore.state).write(to: snapshot)
    let destination = try repository(); try destination.focusedStore.importData(from: snapshot)
    XCTAssertTrue(destination.canonicalStore.state.tabs.allSatisfy { $0.peek == nil })
    try scope.exportData(to: snapshot)
    XCTAssertFalse(String(decoding: try Data(contentsOf: snapshot), as: UTF8.self).contains("private-peek"))
    let file = repo.directory.appendingPathComponent("native-state.json"), expected = repo.canonicalStore.state
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try scope.promotePeekDurably(tabID: source.id))
    XCTAssertThrowsError(try scope.selectDocumentDurably(id: source.id))
    XCTAssertThrowsError(try scope.closePeekDurably(tabID: source.id))
    XCTAssertEqual(repo.canonicalStore.state, expected)
  }
  func testVirtualOpenerSurvivesRestartImportAndPromotionButClearsWhenPeekCloses() throws {
    let repo = try repository(), scope = repo.focusedStore
    let source = try XCTUnwrap(scope.createTab(address: "https://source.example/"))
    let child = try XCTUnwrap(scope.createTab(address: "https://child.example/"))
    scope.setPeek(tabID: source.id, address: "https://peek.example/", title: "Peek")
    scope.updateTab(child.id) { $0.openerTabID = "peek:" + source.id }
    XCTAssertEqual(scope.tab(child.id)?.openerTabID, "peek:" + source.id)
    XCTAssertEqual(BrowserRepository(directory: repo.directory).canonicalStore.tab(child.id)?.openerTabID, "peek:" + source.id)
    let file = repo.directory.appendingPathComponent("portable.json"); try scope.exportData(to: file)
    let imported = try repository(); try imported.focusedStore.importData(from: file)
    let importedSource = try XCTUnwrap(imported.canonicalStore.state.tabs.first { $0.url == source.url })
    XCTAssertEqual(imported.canonicalStore.state.tabs.first { $0.url == child.url }?.openerTabID, "peek:" + importedSource.id)
    let promoted = try scope.promotePeekDurably(tabID: source.id)
    XCTAssertEqual(scope.tab(child.id)?.openerTabID, promoted.id)
    scope.setPeek(tabID: source.id, address: "https://again.example/")
    scope.updateTab(child.id) { $0.openerTabID = "peek:" + source.id }
    try scope.closePeekDurably(tabID: source.id)
    XCTAssertNil(scope.tab(child.id)?.openerTabID)
    let other = try scope.createProfileDurably(name: "Other")
    let foreign = try repo.makeWindow(profileID: other.id).createTab(address: "https://foreign.example/")
    scope.setPeek(tabID: source.id, address: "https://peek.example/")
    let foreignID = try XCTUnwrap(foreign?.id)
    try repo.canonicalStore.commit { state in
      if let index = state.tabs.firstIndex(where: { $0.id == foreignID }) { state.tabs[index].openerTabID = "peek:" + source.id }
    }
    XCTAssertNil(repo.canonicalStore.tab(try XCTUnwrap(foreign?.id))?.openerTabID)
  }
}
