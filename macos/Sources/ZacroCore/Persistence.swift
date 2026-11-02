import Foundation
import Darwin
import CryptoKit

/// All session writes share one serial queue. Encoding and fsync never run on the UI thread
/// for ordinary autosaves; a durable commit/quit waits behind any in-flight write.
final class SessionPersistence: @unchecked Sendable {
  private let queue = DispatchQueue(label: "tech.zacro.session-persistence", qos: .utility)
  private let file: URL
  private let writeFile: @Sendable (Data, URL) throws -> Void
  private var preserveUnreadable = false
  init(file: URL, writeFile: @escaping @Sendable (Data, URL) throws -> Void = {
    try AtomicStoreFile.write($0, to: $1)
  }) { self.file = file; self.writeFile = writeFile }

  private struct BackupCommitProof: Codable {
    let version: Int
    let digest: String?
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  /// A privacy transaction writes its sanitized recovery candidate before its primary.
  /// Only a proof published after that commit permits the candidate to be recovered.
  static func recoveryData(for file: URL) throws -> Data {
    let backup = file.appendingPathExtension("bak")
    let size = try backup.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 32 * 1024 * 1024 else { throw ShortcutError("Browser backup exceeds its safety limit.") }
    let data = try Data(contentsOf: backup)
    guard data.count <= 32 * 1024 * 1024 else { throw ShortcutError("Browser backup exceeds its safety limit.") }
    let proof = backup.appendingPathExtension("commit")
    var status = stat()
    if lstat(proof.path, &status) == 0 {
      guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size <= 1_024,
        let decoded = try? JSONDecoder().decode(BackupCommitProof.self, from: Data(contentsOf: proof)),
        decoded.version == 1, decoded.digest == digest(data)
      else { throw ShortcutError("The browser backup was not committed successfully.") }
    } else {
      guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      // Older releases had no proof. Such a backup may restore browsing data, but
      // must never authorize a new native-profile deletion.
      let legacy = try JSONDecoder().decode(BrowserState.self, from: data)
      guard legacy.pendingNativeProfileRetirements.isEmpty else {
        throw ShortcutError("The browser backup has no committed profile-deletion proof.")
      }
    }
    return data
  }
  private func setBackupProof(_ data: Data?) throws {
    let proof = BackupCommitProof(version: 1, digest: data.map(Self.digest))
    try writeFile(JSONEncoder().encode(proof), file.appendingPathExtension("bak").appendingPathExtension("commit"))
  }
  func preserveUnreadablePrimary() { queue.sync { preserveUnreadable = true } }
  func write(_ state: BrowserState, purgeRecovery: Bool, completion: @escaping @Sendable (String?) -> Void) {
    queue.async { [self] in
      do { try persist(state, purgeRecovery: purgeRecovery); completion(nil) }
      catch { completion(error.localizedDescription) }
    }
  }
  func writeSynchronously(_ state: BrowserState, purgeRecovery: Bool) throws {
    try queue.sync { try persist(state, purgeRecovery: purgeRecovery) }
  }
  private func persist(_ state: BrowserState, purgeRecovery: Bool) throws {
    let directory = file.deletingLastPathComponent()
    let manager = FileManager.default
    let data = try JSONEncoder().encode(state)
    guard data.count <= 32 * 1024 * 1024 else { throw ShortcutError("Browser data exceeds its safety limit.") }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if preserveUnreadable, manager.fileExists(atPath: file.path) {
      try manager.moveItem(at: file, to: directory.appendingPathComponent("native-state-unreadable-\(UUID().uuidString).json"))
      preserveUnreadable = false
    }
    let backup = file.appendingPathExtension("bak")
    if !purgeRecovery, manager.fileExists(atPath: file.path),
      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
      let previous = try? Data(contentsOf: file),
      let root = try? JSONSerialization.jsonObject(with: previous) as? [String: Any],
      root["version"] as? Int == 1, root["profiles"] is [[String: Any]], root["spaces"] is [[String: Any]],
      (try? JSONDecoder().decode(BrowserState.self, from: previous)) != nil {
      // These bytes came from the committed primary, never from an uncertified
      // recovery candidate left behind by an earlier failed privacy transaction.
      try setBackupProof(nil)
      try writeFile(previous, backup)
      try setBackupProof(previous)
    }
    if purgeRecovery {
      try setBackupProof(nil)
      try writeFile(data, backup)
      for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        where item.lastPathComponent.range(of: "^native-state-unreadable-[0-9A-Fa-f-]{36}\\.json$", options: .regularExpression) != nil {
        if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { try manager.removeItem(at: item) }
      }
    }
    // The durable primary is the commit point. Before it succeeds, the privacy
    // candidate cannot grant recovery/deletion authority, including after a crash.
    try writeFile(data, file)
    if purgeRecovery {
      // Failure here only loses a redundant recovery copy. Reporting a failed
      // transaction would incorrectly roll memory back after the primary committed.
      try? setBackupProof(data)
    }
  }
}

enum AtomicStoreFile {
  static func write(_ data: Data, to destination: URL) throws {
    // Open the exact parent before any mutation. All operations use that same
    // directory descriptor, so a path replacement cannot bypass its final fsync.
    let directory = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(directory) }
    let temporary = ".zacro-\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor); _ = Darwin.unlinkat(directory, temporary, 0) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, Darwin.renameat(directory, temporary, directory, destination.lastPathComponent) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}
