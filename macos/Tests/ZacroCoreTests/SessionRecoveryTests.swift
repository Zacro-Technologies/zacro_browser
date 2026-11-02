import Foundation
import XCTest
@testable import ZacroCore

@MainActor final class SessionRecoveryTests: XCTestCase {
  private func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroRecovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: value) }
    return value
  }
  private func decode(_ data: Data) throws -> BrowserState { try JSONDecoder().decode(BrowserState.self, from: data) }

  func testLatePrimaryFailureCannotRecoverUncommittedDeletionOrCertifyItOnAutosave() throws {
    let path = try directory(), file = path.appendingPathComponent("native-state.json")
    let store = BrowserStore(directory: path)
    let profile = try store.createProfileDurably(name: "Not deleted")
    let original = store.state
    // The candidate backup can be written, but replacing the primary must fail.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.deleteProfileDurably(id: profile.id))
    XCTAssertEqual(store.state, original)
    let candidate = try decode(Data(contentsOf: file.appendingPathExtension("bak")))
    XCTAssertEqual(candidate.pendingNativeProfileRetirements, [profile.id])
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    try FileManager.default.removeItem(at: file)
    let restarted = BrowserStore(directory: path)
    XCTAssertTrue(restarted.pendingNativeProfileRetirements.isEmpty)
    XCTAssertNotNil(restarted.lastError)
    try restarted.flush() // No valid old primary exists to certify the candidate.
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    try restarted.flush() // This rotation can only certify the new committed primary.
    XCTAssertTrue(try decode(SessionPersistence.recoveryData(for: file)).pendingNativeProfileRetirements.isEmpty)
  }

  func testNormalRotationAfterFailedPrivacyWriteCertifiesOnlyPriorPrimaryEvenIfNextWriteFails() throws {
    let path = try directory(), file = path.appendingPathComponent("native-state.json")
    let store = BrowserStore(directory: path)
    let profile = try store.createProfileDurably(name: "Retained")
    let original = try Data(contentsOf: file)
    var candidate = store.state
    candidate.profiles.removeAll { $0.id == profile.id }
    candidate.pendingNativeProfileRetirements = [profile.id]
    let persistence = SessionPersistence(file: file) { data, destination in
      if destination == file { throw CocoaError(.fileWriteNoPermission) }
      try AtomicStoreFile.write(data, to: destination)
    }
    XCTAssertThrowsError(try persistence.writeSynchronously(candidate, purgeRecovery: true))
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    XCTAssertThrowsError(try persistence.writeSynchronously(store.state, purgeRecovery: false))
    XCTAssertEqual(try SessionPersistence.recoveryData(for: file), original)
    XCTAssertTrue(try decode(SessionPersistence.recoveryData(for: file)).pendingNativeProfileRetirements.isEmpty)
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testProofPublicationFailureDoesNotRollBackCommittedPrimary() throws {
    let path = try directory(), file = path.appendingPathComponent("native-state.json")
    var candidate = BrowserState()
    candidate.pendingNativeProfileRetirements = ["retired-profile"]
    let persistence = SessionPersistence(file: file) { data, destination in
      if destination.pathExtension == "commit",
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["digest"] != nil {
        throw CocoaError(.fileWriteOutOfSpace)
      }
      try AtomicStoreFile.write(data, to: destination)
    }
    XCTAssertNoThrow(try persistence.writeSynchronously(candidate, purgeRecovery: true))
    XCTAssertEqual(BrowserStore(directory: path).pendingNativeProfileRetirements, ["retired-profile"])
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    try SessionPersistence(file: file).writeSynchronously(candidate, purgeRecovery: false)
    XCTAssertEqual(try decode(SessionPersistence.recoveryData(for: file)).pendingNativeProfileRetirements, ["retired-profile"])
  }

  func testLegacyMarkerlessBackupCanRestoreBrowsingButCannotAuthorizeRetirement() throws {
    let path = try directory(), file = path.appendingPathComponent("native-state.json")
    var legacy = BrowserState()
    legacy.profiles[0].name = "Legacy recovered"
    try JSONEncoder().encode(legacy).write(to: file.appendingPathExtension("bak"))
    XCTAssertEqual(BrowserStore(directory: path).state.profiles[0].name, "Legacy recovered")
    legacy.pendingNativeProfileRetirements = ["unproven-deletion"]
    try JSONEncoder().encode(legacy).write(to: file.appendingPathExtension("bak"))
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    XCTAssertTrue(BrowserStore(directory: path).pendingNativeProfileRetirements.isEmpty)
  }

  func testChangedBackupOrMalformedProofCannotAuthorizeRecovery() throws {
    let path = try directory(), file = path.appendingPathComponent("native-state.json")
    let backup = file.appendingPathExtension("bak"), proof = backup.appendingPathExtension("commit")
    var saved = BrowserState()
    saved.pendingNativeProfileRetirements = ["committed-deletion"]
    try SessionPersistence(file: file).writeSynchronously(saved, purgeRecovery: true)
    let original = try Data(contentsOf: backup), validProof = try Data(contentsOf: proof)
    saved.pendingNativeProfileRetirements = ["different-deletion"]
    try JSONEncoder().encode(saved).write(to: backup)
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    try original.write(to: backup)
    for invalid in [Data(), Data("{\"version\":1}".utf8), Data(repeating: 65, count: 1_025)] {
      try invalid.write(to: proof)
      XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
    }
    try FileManager.default.removeItem(at: proof)
    let external = path.appendingPathComponent("external-proof")
    try validProof.write(to: external)
    try FileManager.default.createSymbolicLink(at: proof, withDestinationURL: external)
    XCTAssertThrowsError(try SessionPersistence.recoveryData(for: file))
  }

  func testMissingPrimaryRecoversCommittedBackupAndPreservesReceiptUntilAcknowledged() throws {
    let path = try directory(), file = path.appendingPathComponent("native-state.json")
    let store = BrowserStore(directory: path)
    let profile = try store.createProfileDurably(name: "Deleted")
    try store.deleteProfileDurably(id: profile.id)
    try FileManager.default.removeItem(at: file)
    let recovered = BrowserStore(directory: path)
    XCTAssertEqual(recovered.pendingNativeProfileRetirements, [profile.id])
    XCTAssertEqual(recovered.lastError, "Recovered your session from its last backup.")
    try recovered.acknowledgeNativeProfileRetirement(profile.id)
    XCTAssertTrue(try decode(SessionPersistence.recoveryData(for: file)).pendingNativeProfileRetirements.isEmpty)
    XCTAssertTrue(BrowserStore(directory: path).pendingNativeProfileRetirements.isEmpty)
  }

  func testAtomicWriterRejectsLinkedOrUnavailableParentBeforeReplacingAnyFile() throws {
    let path = try directory(), real = path.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let original = Data("original".utf8), file = real.appendingPathComponent("state.json")
    try original.write(to: file)
    let linked = path.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    XCTAssertThrowsError(try AtomicStoreFile.write(Data("replacement".utf8), to: linked.appendingPathComponent("state.json")))
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path), ["state.json"])
    let unavailable = path.appendingPathComponent("missing/state.json")
    XCTAssertThrowsError(try AtomicStoreFile.write(Data(), to: unavailable))
    XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
    try AtomicStoreFile.write(Data("committed".utf8), to: file)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "committed")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path), ["state.json"])
  }
}
