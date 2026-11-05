import Darwin
import Foundation

@main enum AcceptanceProfileLeaseCheck {
  static func main() throws {
    var directories: [URL] = []
    defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    var passed = 0
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw NSError(domain: "AcceptanceProfileLeaseCheck", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
      passed += 1
    }
    func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    func fresh() throws -> URL {
      let url = try ChromiumAcceptanceProfileLease.systemTemporaryDirectory()
        .appendingPathComponent("zacro-native-acceptance-lease-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      directories.append(url); return url
    }
    let nonce = String(repeating: "0123456789abcdef", count: 4)
    let directory = try fresh()
    var first = try ChromiumAcceptanceProfileLease.admit(directory: directory, persisted: true, resume: false, nonce: nonce)
    try require(first != nil, "Fresh test mode must acquire its app-created lease")
    let marker = directory.appendingPathComponent(ChromiumAcceptanceProfileLease.markerName)
    let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
    try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "App marker must be private")
    try withExtendedLifetime(first) {
      try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: directory,
        persisted: true, resume: true, nonce: nonce) }, "A still-running first owner must reject resume")
    }
    first = nil
    try Data("fixture, not user profile data".utf8).write(to: directory.appendingPathComponent("saved-fixture"))
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: directory,
      persisted: false, resume: false, nonce: nil) }, "Ordinary acceptance must still require an empty directory")
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: directory,
      persisted: true, resume: false, nonce: nonce) }, "Fresh mode must not recreate an existing app marker")
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: directory,
      persisted: true, resume: true, nonce: String(repeating: "a", count: 64)) }, "Wrong nonce must reject resume")
    try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(ChromiumAcceptanceProfileLease.resumeName).path),
      "Rejected resume must not consume the valid lease")
    var second = try ChromiumAcceptanceProfileLease.admit(directory: directory, persisted: true, resume: true, nonce: nonce)
    try require(second != nil, "Cold second process may reuse exactly its owned profile")
    try withExtendedLifetime(second) {
      try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: directory,
        persisted: true, resume: true, nonce: nonce) }, "A concurrent second owner must fail closed")
    }
    second = nil
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: directory,
      persisted: true, resume: true, nonce: nonce) }, "A completed second launch must not authorize a third")

    let invalidNonce = try fresh()
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: invalidNonce,
      persisted: true, resume: false, nonce: "short") }, "A short nonce must not authorize persistence")
    try require(try FileManager.default.contentsOfDirectory(atPath: invalidNonce.path).isEmpty, "Invalid nonce must not create an owner marker")
    let broadMode = try fresh()
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broadMode.path)
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: broadMode,
      persisted: true, resume: false, nonce: nonce) }, "A shared profile directory must not authorize restart")
    let noMarker = try fresh()
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: noMarker,
      persisted: true, resume: true, nonce: nonce) }, "Resume must never create a missing first-launch marker")
    let nested = noMarker.appendingPathComponent("zacro-native-acceptance-nested")
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: nested,
      persisted: true, resume: false, nonce: nonce) }, "Only a direct system-temp child may be admitted")
    let linked = try fresh()
    try FileManager.default.removeItem(at: linked)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: invalidNonce)
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: linked,
      persisted: true, resume: false, nonce: nonce) }, "A linked profile leaf must fail closed")
    let expired = try fresh()
    var old = try ChromiumAcceptanceProfileLease.admit(directory: expired, persisted: true, resume: false,
      nonce: nonce, now: Date(timeIntervalSinceNow: -7 * 60 * 60))
    withExtendedLifetime(old) {}; old = nil
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: expired,
      persisted: true, resume: true, nonce: nonce) }, "Expired ownership cannot authorize reuse")
    let insecureMarker = try fresh()
    var owner = try ChromiumAcceptanceProfileLease.admit(directory: insecureMarker, persisted: true, resume: false, nonce: nonce)
    withExtendedLifetime(owner) {}; owner = nil
    let insecureFile = insecureMarker.appendingPathComponent(ChromiumAcceptanceProfileLease.markerName)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: insecureFile.path)
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: insecureMarker,
      persisted: true, resume: true, nonce: nonce) }, "An exposed marker cannot authorize resume")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: insecureFile.path)
    let duplicate = insecureMarker.appendingPathComponent("duplicate-marker")
    try FileManager.default.linkItem(at: insecureFile, to: duplicate)
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: insecureMarker,
      persisted: true, resume: true, nonce: nonce) }, "Hard-linked marker cannot authorize resume")
    try FileManager.default.removeItem(at: duplicate)
    try FileManager.default.removeItem(at: insecureFile)
    try FileManager.default.createSymbolicLink(at: insecureFile, withDestinationURL: marker)
    try require(rejects { _ = try ChromiumAcceptanceProfileLease.admit(directory: insecureMarker,
      persisted: true, resume: true, nonce: nonce) }, "Linked marker cannot authorize resume")
    print("Acceptance profile lease: \(passed) real filesystem checks passed (no browser or CEF runtime)")
  }
}
