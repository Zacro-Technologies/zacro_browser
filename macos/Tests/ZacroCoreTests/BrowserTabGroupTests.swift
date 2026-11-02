import XCTest
@testable import ZacroCore

@MainActor final class BrowserTabGroupTests: XCTestCase {
  private func repository() throws -> BrowserRepository {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroGroups-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return BrowserRepository(directory: dir)
  }
  private func tab(_ store: BrowserStore, _ name: String) throws -> BrowserTab {
    try XCTUnwrap(store.createTab(address: "https://" + name + ".example"))
  }
  func testGroupsRemainSeparateFromFoldersAndPreserveSpacesWhileUnpinning() throws {
    let repo = try repository(), store = repo.focusedStore
    let a = try tab(store, "a"), middle = try tab(store, "middle")
    store.togglePin(id: a.id)
    let space = store.createSpace(name: "Other"), b = try tab(store, "b")
    let folder = store.createFolder(name: "Folder")
    store.moveTab(id: b.id, folderID: folder.id)
    let group = try store.groupTabs([a.id, b.id])
    XCTAssertEqual(store.tab(a.id)?.spaceID, "home"); XCTAssertEqual(store.tab(b.id)?.spaceID, space.id)
    XCTAssertEqual(store.tab(a.id)?.isPinned, false); XCTAssertEqual(store.tab(b.id)?.folderID, nil)
    XCTAssertEqual(store.state.folders.map(\.id), [folder.id])
    XCTAssertEqual(store.state.tabs.map(\.id), [a.id, b.id, middle.id])
    XCTAssertEqual(store.state.tabGroups, [group])
    try store.updateTabGroup(group.id, title: "Research", color: "cyan", collapsed: true)
    _ = repo.closeWindow(store.owningWindowID!)
    let reopened = BrowserRepository(directory: repo.directory)
    XCTAssertEqual(reopened.canonicalStore.state.tabGroups.first?.title, "Research")
    XCTAssertEqual(reopened.canonicalStore.state.tabGroups.first?.color, "cyan")
    XCTAssertEqual(reopened.canonicalStore.state.tabGroups.first?.collapsed, true)
  }
  func testPinnedPrefixAndGroupContiguityUseSameCanonicalIndices() throws {
    let repo = try repository(), store = repo.focusedStore
    let a = try tab(store, "a"), b = try tab(store, "b"), c = try tab(store, "c"), d = try tab(store, "d")
    store.togglePin(id: c.id); store.togglePin(id: d.id)
    XCTAssertEqual(store.state.tabs.map(\.id), [c.id, d.id, a.id, b.id])
    let group = try store.groupTabs([c.id, b.id])
    XCTAssertEqual(store.state.tabs.map(\.id), [d.id, c.id, b.id, a.id])
    try repo.moveTabs([a.id], toWindowID: store.owningWindowID!, index: 0)
    XCTAssertEqual(store.state.tabs.map(\.id), [d.id, a.id, c.id, b.id])
    XCTAssertEqual(store.state.tabs.filter { $0.groupID == group.id }.map(\.id), [c.id, b.id])
    store.togglePin(id: d.id)
    XCTAssertEqual(store.state.tabs.map(\.id), [d.id, a.id, c.id, b.id])
  }
  func testGroupingAndUngroupingExpandSplitsWithoutDestroyingThem() throws {
    let repo = try repository(), store = repo.focusedStore
    let a = try tab(store, "a"), b = try tab(store, "b"), c = try tab(store, "c")
    store.setSplit(left: a.id, right: b.id)
    let split = try XCTUnwrap(store.split(for: a.id))
    let group = try store.groupTabs([a.id, c.id])
    XCTAssertTrue(store.state.tabs.allSatisfy { $0.groupID == group.id })
    try store.ungroupTabs([a.id])
    XCTAssertNil(store.tab(a.id)?.groupID); XCTAssertNil(store.tab(b.id)?.groupID)
    XCTAssertEqual(store.tab(c.id)?.groupID, group.id)
    XCTAssertEqual(store.split(for: a.id)?.id, split.id)
    try store.ungroupTabs([c.id]); XCTAssertTrue(store.state.tabGroups.isEmpty)
  }
  func testWholeGroupTransferKeepsIdentityAndPartialTransferDetaches() throws {
    let repo = try repository(), first = repo.focusedStore
    let a = try tab(first, "a"), b = try tab(first, "b"), c = try tab(first, "c")
    let group = try first.groupTabs([a.id, b.id, c.id])
    let other = try repo.makeWindow()
    try repo.moveTabs([a.id, b.id, c.id], toWindowID: other.owningWindowID!, index: 0)
    XCTAssertTrue(first.state.tabGroups.isEmpty)
    XCTAssertEqual(other.state.tabGroups.first?.id, group.id)
    XCTAssertEqual(other.state.tabGroups.first?.windowID, other.owningWindowID)
    try repo.moveTabs([a.id], toWindowID: first.owningWindowID!, index: 0)
    XCTAssertNil(first.tab(a.id)?.groupID)
    XCTAssertEqual(other.tab(b.id)?.groupID, group.id)
    XCTAssertEqual(other.tab(c.id)?.groupID, group.id)
  }
  func testMoveOutsideGroupUngroupsMovedTabsAndPinningCleansEmptyGroup() throws {
    let repo = try repository(), store = repo.focusedStore
    let a = try tab(store, "a"), b = try tab(store, "b"), c = try tab(store, "c"), d = try tab(store, "d")
    let group = try store.groupTabs([a.id, b.id, c.id])
    try repo.moveTabs([a.id], toWindowID: store.owningWindowID!, index: -1)
    XCTAssertNil(store.tab(a.id)?.groupID)
    XCTAssertEqual(store.state.tabs.map(\.id), [b.id, c.id, d.id, a.id])
    store.togglePin(id: b.id); store.togglePin(id: c.id)
    XCTAssertFalse(store.state.tabGroups.contains { $0.id == group.id })
  }
  func testForeignWindowProfileAndInvalidMetadataCannotMutateGroups() throws {
    let repo = try repository(), first = repo.focusedStore, a = try tab(first, "a")
    let second = try repo.makeWindow(), b = try XCTUnwrap(second.state.activeTab)
    XCTAssertThrowsError(try first.groupTabs([a.id, b.id]))
    let group = try first.groupTabs([a.id])
    XCTAssertThrowsError(try second.updateTabGroup(group.id, title: "Foreign"))
    XCTAssertThrowsError(try first.updateTabGroup(group.id, color: "invalid"))
    let otherProfile = first.createProfile(name: "Other"), other = try tab(first, "other")
    XCTAssertNotEqual(otherProfile.id, "default")
    XCTAssertThrowsError(try first.groupTabs([a.id, other.id]))
    XCTAssertEqual(first.state.tabGroups.first?.title, "")
  }
  func testFailedGroupCommitPreservesTabsAndMetadata() throws {
    let repo = try repository(), store = repo.focusedStore, a = try tab(store, "a"), b = try tab(store, "b")
    store.toggleFavorite(id: a.id)
    let before = repo.canonicalStore.state
    let file = repo.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.groupTabs([a.id, b.id]))
    XCTAssertEqual(repo.canonicalStore.state, before)
  }
  func testPortableGroupsRemapIDsAndNeverExportPrivateGroups() throws {
    let repo = try repository(), store = repo.focusedStore
    let a = try tab(store, "a"), b = try tab(store, "b"), group = try store.groupTabs([a.id, b.id])
    try store.updateTabGroup(group.id, title: "Shared", color: "orange", collapsed: true)
    _ = store.createProfile(name: "Secret", isPrivate: true)
    let secret = try tab(store, "secret"), privateGroup = try store.groupTabs([secret.id])
    let file = repo.directory.appendingPathComponent("export.json")
    try store.exportData(to: file)
    let bytes = try Data(contentsOf: file)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(privateGroup.id))
    let target = try repository(); try target.focusedStore.importData(from: file)
    let imported = try XCTUnwrap(target.canonicalStore.state.tabGroups.first)
    XCTAssertNotEqual(imported.id, group.id); XCTAssertEqual(imported.title, "Shared")
    XCTAssertEqual(imported.color, "orange"); XCTAssertTrue(imported.collapsed)
    XCTAssertEqual(target.canonicalStore.state.tabs.filter { $0.groupID == imported.id }.count, 2)
    XCTAssertTrue(target.canonicalStore.state.tabs.allSatisfy { $0.windowID == target.focusedWindowID })
  }
}
