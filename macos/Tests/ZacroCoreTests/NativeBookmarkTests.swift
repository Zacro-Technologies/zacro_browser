import XCTest
@testable import ZacroCore

@MainActor final class NativeBookmarkTests: XCTestCase {
  private func store() throws -> BrowserStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroBookmarkMirror-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return BrowserStore(directory: dir)
  }
  private func record(_ id: Int, uuid: String = UUID().uuidString, url: String = "https://example.com", logicalID: String? = nil) -> NativeBookmarkRecord {
    .init(identity: .init(nodeID: String(id), uuid: uuid), url: url, title: "Native \(id)", logicalID: logicalID)
  }
  func testNativeProjectionRetainsMigratedIDAndRemovesOnlyAcknowledgedLegacyRecords() throws {
    let store = try store()
    store.toggleBookmark(url: "https://legacy.example", title: "Legacy")
    store.toggleBookmark(url: "https://pending.example", title: "Pending")
    let legacy = try XCTUnwrap(store.state.bookmarks.first { $0.title == "Legacy" })
    let native = record(1, url: legacy.url, logicalID: legacy.id)
    try store.reconcileNativeBookmarks(profileID: "default", records: [native], resolvedLegacyIDs: [legacy.id])
    XCTAssertEqual(store.state.bookmarks.count, 2)
    XCTAssertEqual(store.state.bookmarks.first { $0.nativeIdentity != nil }?.id, legacy.id)
    XCTAssertEqual(store.state.bookmarks.first { $0.nativeIdentity == nil }?.title, "Pending")
    try store.reconcileNativeBookmarks(profileID: "default", records: [])
    XCTAssertEqual(store.state.bookmarks.map(\.title), ["Pending"])
  }
  func testNativeUUIDIdentitySurvivesRestartRenameAndDuplicateURLs() throws {
    let store = try store(), a = record(1), b = record(2)
    try store.reconcileNativeBookmarks(profileID: "default", records: [a, b])
    let first = store.state.bookmarks
    var changed = a; changed.title = "Renamed"; changed.identity.nodeID = "10"; changed.identity.editable = false
    let restored = BrowserStore(directory: store.directory)
    try restored.reconcileNativeBookmarks(profileID: "default", records: [changed, b])
    XCTAssertEqual(restored.state.bookmarks.map(\.id), first.map(\.id))
    XCTAssertEqual(restored.state.bookmarks.first?.title, "Renamed")
    XCTAssertEqual(restored.state.bookmarks.first?.nativeIdentity?.nodeID, "10")
    XCTAssertEqual(restored.state.bookmarks.first?.nativeIdentity?.editable, false)
  }
  func testNativeMirrorIsProfileScopedRejectsPrivateAndMalformedSnapshots() throws {
    let store = try store(); store.toggleBookmark(url: "https://keep.example", title: "Keep")
    let publicProfile = store.createProfile(name: "Other")
    try store.reconcileNativeBookmarks(profileID: publicProfile.id, records: [record(1)])
    XCTAssertTrue(store.state.bookmarks.contains { $0.title == "Keep" })
    let privateProfile = store.createProfile(name: "Secret", isPrivate: true)
    XCTAssertThrowsError(try store.reconcileNativeBookmarks(profileID: privateProfile.id, records: []))
    var bad = record(2); bad.identity.uuid = "not-a-native-uuid"
    let before = store.state
    XCTAssertThrowsError(try store.reconcileNativeBookmarks(profileID: publicProfile.id, records: [bad]))
    let duplicate = record(3)
    XCTAssertThrowsError(try store.reconcileNativeBookmarks(profileID: publicProfile.id, records: [duplicate, duplicate]))
    XCTAssertEqual(store.state, before)
  }
  func testFailedNativeCacheWriteKeepsPreviousMirrorAndPortableImportStripsBindings() throws {
    let store = try store(), native = record(1)
    try store.reconcileNativeBookmarks(profileID: "default", records: [native])
    let export = store.directory.appendingPathComponent("export.json")
    try store.exportData(to: export)
    XCTAssertFalse(String(decoding: try Data(contentsOf: export), as: UTF8.self).contains("nativeIdentity"))
    let target = try self.store(); try target.importData(from: export)
    XCTAssertEqual(target.state.bookmarks.count, 1); XCTAssertNil(target.state.bookmarks[0].nativeIdentity)
    let nativeExport = store.directory.appendingPathComponent("snapshot.json")
    try JSONEncoder().encode(store.state).write(to: nativeExport)
    let other = try self.store(); try other.importData(from: nativeExport)
    XCTAssertNil(other.state.bookmarks[0].nativeIdentity)
    let before = store.state, file = store.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.reconcileNativeBookmarks(profileID: "default", records: []))
    XCTAssertEqual(store.state, before)
  }
  func testMigrationAcknowledgementSurvivesRestartAndRecoveryWithoutResurrectingDeletedImport() throws {
    let store = try store()
    store.toggleBookmark(url: "https://deleted.example", title: "Deleted during native migration")
    let legacy = try XCTUnwrap(store.state.bookmarks.first), uuid = UUID().uuidString
    let ack = NativeBookmarkImportAcknowledgement(profileID: "default", logicalID: legacy.id, uuid: uuid)
    try store.reconcileNativeBookmarks(profileID: "default", records: [], resolvedLegacyIDs: [legacy.id], acknowledgements: [ack])
    XCTAssertTrue(store.state.bookmarks.isEmpty)
    let restarted = BrowserStore(directory: store.directory)
    XCTAssertEqual(restarted.state.bookmarkImportAcknowledgements, [ack])
    let backup = store.directory.appendingPathComponent("native-state.json.bak")
    let recovered = try JSONDecoder().decode(BrowserState.self, from: Data(contentsOf: backup))
    XCTAssertTrue(recovered.bookmarks.isEmpty)
    XCTAssertEqual(recovered.bookmarkImportAcknowledgements, [ack])
    try restarted.acknowledgeNativeBookmarkImports([ack])
    XCTAssertTrue(BrowserStore(directory: store.directory).state.bookmarkImportAcknowledgements.isEmpty)
    try restarted.acknowledgeNativeBookmarkImports([ack])
    XCTAssertTrue(restarted.state.bookmarks.isEmpty)
  }
  func testMigrationAndAcknowledgementRollBackOnDiskFailure() throws {
    let store = try store(); store.toggleBookmark(url: "https://legacy.example", title: "Legacy")
    let legacy = try XCTUnwrap(store.state.bookmarks.first), native = record(1, logicalID: legacy.id)
    let ack = NativeBookmarkImportAcknowledgement(profileID: "default", logicalID: legacy.id, uuid: native.identity.uuid)
    let file = store.directory.appendingPathComponent("native-state.json"), before = store.state
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.reconcileNativeBookmarks(profileID: "default", records: [native], resolvedLegacyIDs: [legacy.id], acknowledgements: [ack]))
    XCTAssertEqual(store.state, before)
    try FileManager.default.removeItem(at: file)
    try store.reconcileNativeBookmarks(profileID: "default", records: [native], resolvedLegacyIDs: [legacy.id], acknowledgements: [ack])
    let migrated = store.state
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.acknowledgeNativeBookmarkImports([ack]))
    XCTAssertEqual(store.state, migrated)
  }
  func testLocalAndAccountBookmarksWithSameUUIDKeepDistinctStableIdentities() throws {
    let store = try store(), first = record(1)
    var second = first; second.identity.storage = "account"; second.identity.nodeID = "2"
    try store.reconcileNativeBookmarks(profileID: "default", records: [first, second])
    let ids = store.state.bookmarks.map(\.id)
    XCTAssertEqual(Set(ids).count, 2)
    try store.reconcileNativeBookmarks(profileID: "default", records: [second, first])
    XCTAssertEqual(store.state.bookmarks.map(\.id), ids.reversed())
  }
}
