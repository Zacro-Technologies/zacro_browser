import Foundation

@main enum RetirementJournalCheck {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "RetirementJournalCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  }
  static func rejects(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zacro-retirement-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = ChromiumProfileRetirementJournal(file: root.appendingPathComponent("journal.json"))
    try require(try journal.read().isEmpty, "Missing journal must be empty")
    try journal.write(["first", "legacy profile: 日本語"])
    try require(try journal.read() == ["first", "legacy profile: 日本語"], "Durable round trip")
    let mode = try FileManager.default.attributesOfItem(atPath: journal.file.path)[.posixPermissions] as? NSNumber
    try require(mode?.intValue == 0o600, "Journal permissions must be private")
    try journal.write(["replacement"])
    try require(try journal.read() == ["replacement"], "Atomic replacement")
    try require(rejects { try journal.write([""]) }, "Invalid receipt must fail")
    try require(rejects { try journal.write(Set((0...1_000).map(String.init))) }, "Unbounded receipt list must fail")
    try require(try journal.read() == ["replacement"], "Rejected writes must preserve the committed receipt")
    try journal.write([])
    try require(try journal.read().isEmpty, "Acknowledged journal must commit empty")
    try Data("not json".utf8).write(to: journal.file)
    try require(rejects { _ = try journal.read() }, "Corrupt receipt must fail closed")
    try FileManager.default.removeItem(at: journal.file)
    let target = root.appendingPathComponent("outside.json")
    try Data("[]".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: journal.file, withDestinationURL: target)
    try require(rejects { _ = try journal.read() }, "A symlink must not become deletion authority")
    try FileManager.default.removeItem(at: target)
    try require(rejects { _ = try journal.read() }, "A dangling symlink must not count as an absent journal")
    try FileManager.default.removeItem(at: journal.file)
    try FileManager.default.createDirectory(at: journal.file, withIntermediateDirectories: false)
    let marker = journal.file.appendingPathComponent("keep")
    try Data("keep".utf8).write(to: marker)
    try require(rejects { try journal.write(["failed-rename"]) }, "Failed atomic replacement must report failure")
    try require(FileManager.default.fileExists(atPath: marker.path), "Failed replacement must preserve existing data")
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    try require(!files.contains { $0.hasPrefix(".retirement-") }, "Failed write must clean its temporary file")

    let chromium = root.appendingPathComponent("Chromium")
    let outside = root.appendingPathComponent("outside")
    let hash = String(repeating: "a", count: 64)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: chromium, withDestinationURL: outside)
    try require(rejects { try ChromiumProfileRetirementJournal.removeProfileDirectory(root: chromium, hash: hash) }, "Linked native root must fail closed")
    try require(rejects { try ChromiumProfileRetirementJournal.synchronizeDirectory(chromium) }, "Directory sync must reject links")
    try FileManager.default.removeItem(at: chromium)
    try FileManager.default.createDirectory(at: chromium, withIntermediateDirectories: false)
    let profile = chromium.appendingPathComponent(hash)
    try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: outside)
    try require(rejects { try ChromiumProfileRetirementJournal.removeProfileDirectory(root: chromium, hash: hash) }, "Linked profile directory must fail closed")
    try require(FileManager.default.fileExists(atPath: outside.path), "Linked target must remain untouched")
    try FileManager.default.removeItem(at: profile)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
    try Data("native profile".utf8).write(to: profile.appendingPathComponent("owned"))
    try ChromiumProfileRetirementJournal.removeProfileDirectory(root: chromium, hash: hash)
    try require(!FileManager.default.fileExists(atPath: profile.path), "Owned profile directory must be removed")
    try ChromiumProfileRetirementJournal.removeProfileDirectory(root: chromium, hash: hash)
    try require(FileManager.default.fileExists(atPath: chromium.path), "Absent-leaf retry must retain and synchronize its root")
    try require(rejects { try ChromiumProfileRetirementJournal.removeProfileDirectory(root: chromium, hash: "../outside") }, "Removal must be limited to hashed profile names")
    print("Profile retirement journal: 21 filesystem checks passed")
  }
}
