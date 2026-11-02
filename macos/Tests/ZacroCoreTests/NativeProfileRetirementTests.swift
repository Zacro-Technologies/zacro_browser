import XCTest
@testable import ZacroCore

@MainActor final class NativeProfileRetirementTests: XCTestCase {
  private func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroRetirement-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: value) }
    return value
  }
  private func disk(_ directory: URL, backup: Bool = false) throws -> BrowserState {
    try JSONDecoder().decode(BrowserState.self, from: Data(contentsOf:
      directory.appendingPathComponent(backup ? "native-state.json.bak" : "native-state.json")))
  }
  private func blockBackup(_ directory: URL) throws {
    let backup = directory.appendingPathComponent("native-state.json.bak")
    if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
  }

  func testDeletionAndReceiptPersistTogetherAndRecoverFromBackupBeforeAcknowledgement() throws {
    let path = try directory(), repository = BrowserRepository(directory: path)
    let store = repository.focusedStore
    let profile = try store.createProfileDurably(name: "Work")
    _ = store.createTab(address: "https://retired.example")
    try store.deleteProfileDurably(id: profile.id)
    for backup in [false, true] {
      let saved = try disk(path, backup: backup)
      XCTAssertFalse(saved.profiles.contains { $0.id == profile.id })
      XCTAssertFalse(saved.tabs.contains { $0.url.contains("retired.example") })
      XCTAssertEqual(saved.pendingNativeProfileRetirements, [profile.id])
    }
    try Data("corrupt primary".utf8).write(to: path.appendingPathComponent("native-state.json"))
    let recovered = BrowserRepository(directory: path)
    XCTAssertEqual(recovered.canonicalStore.pendingNativeProfileRetirements, [profile.id])
    try recovered.canonicalStore.acknowledgeNativeProfileRetirement(profile.id)
    for backup in [false, true] { XCTAssertTrue(try disk(path, backup: backup).pendingNativeProfileRetirements.isEmpty) }
    XCTAssertTrue(BrowserRepository(directory: path).canonicalStore.pendingNativeProfileRetirements.isEmpty)
    try recovered.canonicalStore.acknowledgeNativeProfileRetirement(profile.id) // Idempotent replay.
  }

  func testFailedDeletionRetainsProfileWithoutAuthorizingNativeCleanup() throws {
    let path = try directory(), store = BrowserStore(directory: path)
    let profile = try store.createProfileDurably(name: "Retained")
    let original = store.state
    try blockBackup(path)
    XCTAssertThrowsError(try store.deleteProfileDurably(id: profile.id))
    XCTAssertEqual(store.state, original)
    XCTAssertTrue(store.pendingNativeProfileRetirements.isEmpty)
    let restarted = BrowserStore(directory: path)
    XCTAssertTrue(restarted.state.profiles.contains { $0.id == profile.id })
    XCTAssertTrue(restarted.pendingNativeProfileRetirements.isEmpty)
  }

  func testFailedAcknowledgementLeavesDurableReplayReceipt() throws {
    let path = try directory(), store = BrowserStore(directory: path)
    let profile = try store.createProfileDurably(name: "Retire")
    try store.deleteProfileDurably(id: profile.id)
    try blockBackup(path)
    XCTAssertThrowsError(try store.acknowledgeNativeProfileRetirement(profile.id))
    XCTAssertEqual(store.pendingNativeProfileRetirements, [profile.id])
    XCTAssertEqual(BrowserStore(directory: path).pendingNativeProfileRetirements, [profile.id])
    try FileManager.default.removeItem(at: path.appendingPathComponent("native-state.json.bak"))
    try store.acknowledgeNativeProfileRetirement(profile.id)
    XCTAssertTrue(store.pendingNativeProfileRetirements.isEmpty)
  }

  func testImportCannotAuthorRetirementsOrExportExistingInternalReceipts() throws {
    let path = try directory(), store = BrowserStore(directory: path)
    let deleted = try store.createProfileDurably(name: "Deleted")
    try store.deleteProfileDurably(id: deleted.id)
    var imported = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserState())) as! [String: Any]
    imported["pendingNativeProfileRetirements"] = ["default", "external-profile"]
    let input = path.appendingPathComponent("input.json")
    try JSONSerialization.data(withJSONObject: imported).write(to: input)
    try store.importData(from: input)
    XCTAssertEqual(store.pendingNativeProfileRetirements, [deleted.id])
    XCTAssertTrue(store.state.profiles.contains { $0.id == "default" })
    XCTAssertFalse(store.state.profiles.contains { $0.id == deleted.id })
    // Even malformed internal metadata is discarded from an untrusted import.
    imported["pendingNativeProfileRetirements"] = ["invalid": true]
    try JSONSerialization.data(withJSONObject: imported).write(to: input)
    try store.importData(from: input)
    XCTAssertEqual(store.pendingNativeProfileRetirements, [deleted.id])
    let exported = path.appendingPathComponent("export.json")
    try store.exportData(to: exported)
    let output = try JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as! [String: Any]
    XCTAssertNil(output["pendingNativeProfileRetirements"])
    let destination = BrowserStore(directory: try directory())
    try destination.importData(from: exported)
    XCTAssertTrue(destination.pendingNativeProfileRetirements.isEmpty)
  }

  func testPrivateDeletionAndExistingProfilesNeverAuthorizeNativeDiskRetirement() throws {
    let store = BrowserStore(directory: try directory())
    let privateProfile = try store.createProfileDurably(name: "Private", isPrivate: true)
    try store.deleteProfileDurably(id: privateProfile.id)
    XCTAssertTrue(store.pendingNativeProfileRetirements.isEmpty)
    store.state.pendingNativeProfileRetirements = ["default"]
    XCTAssertTrue(store.pendingNativeProfileRetirements.isEmpty)
    XCTAssertThrowsError(try store.acknowledgeNativeProfileRetirement("default"))
    XCTAssertTrue(store.state.profiles.contains { $0.id == "default" })
  }

  func testReceiptBoundRefusesDeletionWithoutDroppingPriorCleanup() throws {
    let store = BrowserStore(directory: try directory())
    let profile = try store.createProfileDurably(name: "Keep")
    store.state.pendingNativeProfileRetirements = (0..<1_000).map { "retired-\($0)" }
    XCTAssertThrowsError(try store.deleteProfileDurably(id: profile.id))
    XCTAssertTrue(store.state.profiles.contains { $0.id == profile.id })
    XCTAssertEqual(store.pendingNativeProfileRetirements.count, 1_000)
    var oversized = store.state
    oversized.pendingNativeProfileRetirements.append("overflow")
    XCTAssertThrowsError(try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(oversized)))
  }
}
