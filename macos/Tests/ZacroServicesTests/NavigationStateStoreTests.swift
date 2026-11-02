import Foundation
import CryptoKit
import XCTest
@testable import ZacroServices

final class NavigationStateStoreTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zacro-navigation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func store(_ directory: URL) -> NativeNavigationStateStore {
    NativeNavigationStateStore(directory: directory) { id in
      guard ["personal", "work", "private"].contains(id) else { return nil }
      return AIProfileScope(id: id, isPrivate: id == "private")
    }
  }
  private func file(_ root: URL, profile: String = "personal", tab: String = "tab", peek: Bool = false) -> URL {
    root.appendingPathComponent("Navigation").appendingPathComponent(ServiceFiles.hash(profile))
      .appendingPathComponent(ServiceFiles.hash(tab) + (peek ? "-peek.bin" : "-main.bin"))
  }
  func testApprovedNativeAddressBindingsRoundTripWithoutPlaintextDocumentMetadata() async throws {
    let root = try directory(), vault = store(root), payload = Data([0, 255, 9, 17])
    let addresses = ["chrome://settings/", "file:///tmp/private-document.html", "blob:https://example.com/12345678",
      "https://fixture-user:fixture-password@example.com/approved",
      "data:text/html," + String(repeating: "%3Cprivate-content%3E", count: 5_000)]
    for (index, address) in addresses.enumerated() {
      let id = "native-\(index)"
      try await vault.write(profileID: "personal", tabID: id, address: address, encryptedData: payload)
      let persisted = try Data(contentsOf: file(root, tab: id))
      XCTAssertLessThan(persisted.count, 1_024)
      XCTAssertNil(persisted.range(of: Data(address.utf8)))
      let restarted = store(root)
      expectEqual(try await restarted.read(profileID: "personal", tabID: id, address: address), payload)
      expectEqual(try await restarted.read(profileID: "personal", tabID: id, address: address + "#other"), nil)
      XCTAssertFalse(FileManager.default.fileExists(atPath: file(root, tab: id).path))
    }
  }
  func testLegacyAddressMetadataRemainsReadableAndCopyUpgradesToDigest() async throws {
    let root = try directory(), vault = store(root), payload = Data([19, 23]), address = "https://legacy.test/"
    let legacy: [String: Any] = ["profile": ServiceFiles.hash("personal"), "tab": ServiceFiles.hash("tab"),
      "peek": false, "address": address, "length": payload.count,
      "digest": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
    let header = try JSONSerialization.data(withJSONObject: legacy), length = UInt32(header.count)
    var bytes = Data([0x5a, 0x41, 0x43, 0x4e, 0x41, 0x56, 1, 0])
    bytes.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
    bytes.append(header); bytes.append(payload)
    try FileManager.default.createDirectory(at: file(root).deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file(root))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: address), payload)
    expectTrue(try await vault.copy(profileID: "personal", fromTabID: "tab", toTabID: "copy", address: address))
    let copied = try Data(contentsOf: file(root, tab: "copy"))
    let copiedLength = copied[8..<12].reduce(0) { ($0 << 8) | Int($1) }
    var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: copied[12..<(12 + copiedLength)]) as? [String: Any])
    XCTAssertEqual(metadata["version"] as? Int, 2)
    XCTAssertNil(metadata["address"]); XCTAssertEqual((metadata["addressDigest"] as? String)?.count, 64)
    // Unknown metadata versions cannot accidentally be treated as legacy.
    metadata["version"] = 999
    let changed = try JSONSerialization.data(withJSONObject: metadata), size = UInt32(changed.count)
    var corrupt = Data(bytes.prefix(8))
    corrupt.append(contentsOf: [UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
    corrupt.append(changed); corrupt.append(payload); try corrupt.write(to: file(root, tab: "copy"))
    expectEqual(try await store(root).read(profileID: "personal", tabID: "copy", address: address), nil)
  }
  func testInvalidOrOversizedNativeAddressCannotReplaceAValidArtifact() async throws {
    let root = try directory(), vault = store(root), address = "file:///tmp/kept.html", payload = Data([1, 2])
    try await vault.write(profileID: "personal", tabID: "tab", address: address, encryptedData: payload)
    for invalid in ["relative", "javascript:alert(1)", "chrome-untrusted://test/", "file:///tmp/line\nfeed",
      "data:text/plain," + String(repeating: "x", count: NativeNavigationStateStore.maximumAddressBytes)] {
      do {
        try await vault.write(profileID: "personal", tabID: "tab", address: invalid, encryptedData: Data([9]))
        XCTFail("Invalid structural binding must fail")
      } catch let error as ServiceError { XCTAssertEqual(error.code, "INPUT") }
      expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: address), payload)
    }
  }
  func testRestartRestoresExactBytesWithProfileTabAndPeekIsolation() async throws {
    let root = try directory(), first = store(root), bytes = Data([0, 255, 1, 2, 0, 34])
    try await first.write(profileID: "personal", tabID: "tab", address: "HTTPS://Example.COM:443", encryptedData: bytes)
    try await first.write(profileID: "personal", tabID: "tab", peek: true, address: "https://peek.test/", encryptedData: Data([7]))
    let second = store(root)
    expectEqual(try await second.read(profileID: "personal", tabID: "tab", address: "https://example.com/"), bytes)
    expectEqual(try await second.read(profileID: "personal", tabID: "tab", peek: true, address: "https://peek.test/"), Data([7]))
    expectEqual(try await second.read(profileID: "work", tabID: "tab", address: "https://example.com/"), nil)
    expectEqual(try await second.read(profileID: "personal", tabID: "other", address: "https://example.com/"), nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: file(root).path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: file(root).deletingLastPathComponent().path)
    XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertFalse(file(root).path.contains("example.com"))
  }
  func testExplicitNavigationAndInvalidAddressRemoveStaleArtifact() async throws {
    let root = try directory(), vault = store(root)
    try await vault.write(profileID: "personal", tabID: "tab", address: "https://a.test/", encryptedData: Data([1]))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: "https://b.test/"), nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file(root).path))
    try await vault.write(profileID: "personal", tabID: "tab", address: "https://a.test/", encryptedData: Data([2]))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: "file:///private/data"), nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file(root).path))
  }
  func testPrivateAndMissingProfilesCannotReadOrWrite() async throws {
    let root = try directory(), vault = store(root)
    for profile in ["private", "missing"] {
      do {
        try await vault.write(profileID: profile, tabID: "tab", address: "https://a.test/", encryptedData: Data([1]))
        XCTFail("A private or missing profile must not write")
      } catch let error as ServiceError { XCTAssertEqual(error.code, profile == "private" ? "PRIVATE" : "PROFILE") }
      do {
        _ = try await vault.read(profileID: profile, tabID: "tab", address: "https://a.test/")
        XCTFail("A private or missing profile must not restore")
      } catch let error as ServiceError { XCTAssertEqual(error.code, profile == "private" ? "PRIVATE" : "PROFILE") }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Navigation").path))
  }
  func testPromotionAndCopyPreserveIndependentArtifactsAndRemoveOnlySourcePeek() async throws {
    let root = try directory(), vault = store(root), address = "https://peek.test/", bytes = Data([5, 6])
    try await vault.write(profileID: "personal", tabID: "tab", address: "https://parent.test/", encryptedData: Data([1]))
    try await vault.write(profileID: "personal", tabID: "tab", peek: true, address: address, encryptedData: bytes)
    expectTrue(try await vault.promotePeek(profileID: "personal", fromTabID: "tab", toTabID: "promoted", address: address))
    expectEqual(try await vault.read(profileID: "personal", tabID: "promoted", address: address), bytes)
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", peek: true, address: address), nil)
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: "https://parent.test/"), Data([1]))
    expectTrue(try await vault.copy(profileID: "personal", fromTabID: "promoted", toTabID: "copy", address: address))
    try await vault.remove(profileID: "personal", tabID: "promoted")
    expectEqual(try await vault.read(profileID: "personal", tabID: "copy", address: address), bytes)
    try await vault.removeProfile(profileID: "personal")
    expectEqual(try await vault.read(profileID: "personal", tabID: "copy", address: address), nil)
  }
  func testFailedPromotionPreservesPeekAndOversizedWritePreservesPriorArtifact() async throws {
    let root = try directory(), vault = store(root), address = "https://a.test/"
    try await vault.write(profileID: "personal", tabID: "tab", peek: true, address: address, encryptedData: Data([1]))
    try FileManager.default.createDirectory(at: file(root, tab: "destination"), withIntermediateDirectories: true)
    do { _ = try await vault.promotePeek(profileID: "personal", fromTabID: "tab", toTabID: "destination", address: address); XCTFail("Blocked destination must fail") }
    catch {}
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", peek: true, address: address), Data([1]))
    do {
      try await vault.write(profileID: "personal", tabID: "tab", peek: true, address: address,
                            encryptedData: Data(repeating: 4, count: NativeNavigationStateStore.maximumEncryptedBytes + 1))
      XCTFail("Oversized payload must fail")
    } catch let error as ServiceError { XCTAssertEqual(error.code, "STORAGE_SIZE") }
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", peek: true, address: address), Data([1]))
  }
  func testCorruptionAndTransplantedMetadataAreRejectedAndRemoved() async throws {
    let root = try directory(), vault = store(root), address = "https://a.test/"
    try await vault.write(profileID: "personal", tabID: "tab", address: address, encryptedData: Data([1, 2, 3]))
    var bytes = try Data(contentsOf: file(root)); bytes[bytes.count - 1] ^= 1
    try bytes.write(to: file(root))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: address), nil)
    try await vault.write(profileID: "personal", tabID: "tab", address: address, encryptedData: Data([1, 2, 3]))
    let foreign = file(root, profile: "work")
    try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: file(root), to: foreign)
    expectEqual(try await vault.read(profileID: "work", tabID: "tab", address: address), nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: address), Data([1, 2, 3]))
  }
  func testMalformedLengthAndSymlinkNeverReadOutsideVault() async throws {
    let root = try directory(), vault = store(root), address = "https://a.test/"
    try await vault.write(profileID: "personal", tabID: "tab", address: address, encryptedData: Data([1]))
    try Data([0x5a, 0x41, 0x43, 0x4e, 0x41, 0x56, 1, 0, 255, 255, 255, 255]).write(to: file(root))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: address), nil)
    let outside = root.appendingPathComponent("unrelated")
    try Data([9]).write(to: outside)
    try FileManager.default.createSymbolicLink(at: file(root), withDestinationURL: outside)
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: address), nil)
    XCTAssertEqual(try Data(contentsOf: outside), Data([9]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: file(root).path))
  }
  func testSymlinkedProfileDirectoryCannotReadOrRemoveExternalArtifacts() async throws {
    let root = try directory(), vault = store(root), address = "https://a.test/"
    try await vault.write(profileID: "personal", tabID: "tab", address: address, encryptedData: Data([1]))
    let profile = file(root).deletingLastPathComponent(), external = root.appendingPathComponent("moved-profile")
    try FileManager.default.moveItem(at: profile, to: external)
    try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: external)
    do { _ = try await vault.read(profileID: "personal", tabID: "tab", address: address); XCTFail("Directory symlink must be rejected") }
    catch let error as ServiceError { XCTAssertEqual(error.code, "STORAGE") }
    do { try await vault.remove(profileID: "personal", tabID: "tab"); XCTFail("Directory symlink must not be followed for deletion") }
    catch let error as ServiceError { XCTAssertEqual(error.code, "STORAGE") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent(file(root).lastPathComponent).path))
  }
  func testProfileCleanupCancelsPendingCaptureButAllowsFutureCapture() async throws {
    let root = try directory(), gate = NavigationProfileGate()
    let vault = NativeNavigationStateStore(directory: root) { await gate.profile($0) }
    await gate.pauseNext()
    let pending = Task { try await vault.write(profileID: "personal", tabID: "tab", address: "https://a.test/", encryptedData: Data([1])) }
    while await !gate.isWaiting { await Task.yield() }
    try await vault.removeProfile(profileID: "personal")
    await gate.resume()
    do { try await pending.value; XCTFail("Pending capture must not resurrect cleared data") }
    catch let error as ServiceError { XCTAssertEqual(error.code, "CANCELLED") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: file(root).path))
    try await vault.write(profileID: "personal", tabID: "tab", address: "https://b.test/", encryptedData: Data([2]))
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: "https://b.test/"), Data([2]))
  }
  func testStaleReadCannotRemoveNewerCaptureAfterAwaitingProfile() async throws {
    let root = try directory(), gate = NavigationProfileGate()
    let vault = NativeNavigationStateStore(directory: root) { await gate.profile($0) }
    try await vault.write(profileID: "personal", tabID: "tab", address: "https://old.test/", encryptedData: Data([1]))
    await gate.pauseNext()
    let pending = Task { try await vault.read(profileID: "personal", tabID: "tab", address: "https://old.test/") }
    while await !gate.isWaiting { await Task.yield() }
    try await vault.write(profileID: "personal", tabID: "tab", address: "https://new.test/", encryptedData: Data([2]))
    await gate.resume()
    do { _ = try await pending.value; XCTFail("Stale read must not invalidate new capture") }
    catch let error as ServiceError { XCTAssertEqual(error.code, "CANCELLED") }
    expectEqual(try await vault.read(profileID: "personal", tabID: "tab", address: "https://new.test/"), Data([2]))
  }
}

private actor NavigationProfileGate {
  private var pause = false
  private var continuation: CheckedContinuation<Void, Never>?
  var isWaiting: Bool { continuation != nil }
  func pauseNext() { pause = true }
  func profile(_ id: String) async -> AIProfileScope {
    if pause { pause = false; await withCheckedContinuation { continuation = $0 } }
    return AIProfileScope(id: id)
  }
  func resume() { continuation?.resume(); continuation = nil }
}
