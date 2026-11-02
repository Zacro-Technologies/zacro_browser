import XCTest
@testable import ZacroServices

final class NativeProfileArtifactsTests: XCTestCase {
  private func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroArtifacts-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: value) }
    return value
  }
  @discardableResult private func file(_ path: URL) throws -> URL {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("owned fixture".utf8).write(to: path)
    return path
  }
  private func icon(_ root: URL, profile: String, url: String = "https://example.com") -> URL {
    root.appendingPathComponent("Icons/" + ServiceFiles.hash(profile) + "-" + ServiceFiles.hash(url) + ".png")
  }

  func testRemovesOnlyExactProfileArtifactsAndReplayIsIdempotent() throws {
    let root = try directory(), target = "removed", other = "retained"
    let removedHistory = try file(root.appendingPathComponent("Navigation/" + ServiceFiles.hash(target) + "/tab-main.bin"))
    let keptHistory = try file(root.appendingPathComponent("Navigation/" + ServiceFiles.hash(other) + "/tab-main.bin"))
    let removedIcon = try file(icon(root, profile: target)), keptIcon = try file(icon(root, profile: other))
    let malformed = try file(root.appendingPathComponent("Icons/" + ServiceFiles.hash(target) + "-unrelated.png"))
    let native = try file(root.appendingPathComponent("Chromium/" + ServiceFiles.hash(target) + "/Cookies"))
    try NativeProfileArtifacts.remove(directory: root, profileID: target)
    XCTAssertFalse(FileManager.default.fileExists(atPath: removedHistory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: removedIcon.path))
    for value in [keptHistory, keptIcon, malformed, native] { XCTAssertTrue(FileManager.default.fileExists(atPath: value.path)) }
    try NativeProfileArtifacts.remove(directory: root, profileID: target)
  }

  func testRootAndNamespaceSymlinksNeverReachExternalData() throws {
    let root = try directory(), outside = try directory()
    let sentinel = try file(icon(outside, profile: "profile"))
    let linkedRoot = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
    XCTAssertThrowsError(try NativeProfileArtifacts.remove(directory: linkedRoot, profileID: "profile"))
    let linkedIcons = root.appendingPathComponent("Icons")
    try FileManager.default.createSymbolicLink(at: linkedIcons, withDestinationURL: outside.appendingPathComponent("Icons"))
    XCTAssertThrowsError(try NativeProfileArtifacts.remove(directory: root, profileID: "profile"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    try FileManager.default.removeItem(at: linkedIcons)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Navigation"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Navigation/" + ServiceFiles.hash("profile")), withDestinationURL: outside)
    XCTAssertThrowsError(try NativeProfileArtifacts.remove(directory: root, profileID: "profile"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
  }

  func testOwnedIconLinkIsRemovedWithoutDeletingItsTargetAndUnsafeEntryCanRetry() throws {
    let root = try directory(), outside = try directory(), sentinel = try file(outside.appendingPathComponent("keep"))
    let link = icon(root, profile: "profile")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
    try NativeProfileArtifacts.remove(directory: root, profileID: "profile")
    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
    XCTAssertThrowsError(try NativeProfileArtifacts.remove(directory: root, profileID: "profile"))
    try FileManager.default.removeItem(at: link)
    try NativeProfileArtifacts.remove(directory: root, profileID: "profile")
  }

  func testLegacyLongIDCanBeCleanedWithoutRelaxingNavigationWrites() async throws {
    let root = try directory(), profile = String(repeating: "p", count: 700)
    let history = try file(root.appendingPathComponent("Navigation/" + ServiceFiles.hash(profile) + "/tab-main.bin"))
    let cache = try file(icon(root, profile: profile))
    let vault = NativeNavigationStateStore(directory: root) { id in AIProfileScope(id: id, isPrivate: false) }
    do {
      try await vault.write(profileID: profile, tabID: "tab", address: "https://example.com", encryptedData: Data([1]))
      XCTFail("The write identity bound must stay unchanged")
    } catch { }
    try await vault.removeProfile(profileID: profile)
    XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
    try NativeProfileArtifacts.remove(directory: root, profileID: profile)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    XCTAssertThrowsError(try NativeProfileArtifacts.remove(directory: root, profileID: "bad\nprofile"))
    XCTAssertThrowsError(try NativeProfileArtifacts.remove(directory: root, profileID: String(repeating: "x", count: 1_025)))
  }
}
