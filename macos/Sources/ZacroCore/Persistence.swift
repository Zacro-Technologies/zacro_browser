import Foundation
import Darwin

/// All session writes share one serial queue. Encoding and fsync never run on the UI thread
/// for ordinary autosaves; a durable commit/quit waits behind any in-flight write.
final class SessionPersistence: @unchecked Sendable {
  private let queue = DispatchQueue(label: "tech.zacro.session-persistence", qos: .utility)
  private let file: URL
  private var preserveUnreadable = false
  init(file: URL) { self.file = file }
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
      try AtomicStoreFile.write(previous, to: backup)
    }
    if purgeRecovery {
      try AtomicStoreFile.write(data, to: backup)
      for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        where item.lastPathComponent.range(of: "^native-state-unreadable-[0-9A-Fa-f-]{36}\\.json$", options: .regularExpression) != nil {
        if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { try manager.removeItem(at: item) }
      }
    }
    // Privacy transactions purge recovery copies first. A recovery-write failure
    // therefore cannot replace the primary with a candidate the caller rejected.
    try AtomicStoreFile.write(data, to: file)
  }
}

enum AtomicStoreFile {
  static func write(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".zacro-\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, Darwin.rename(temporary.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let directory = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY)
    if directory >= 0 { defer { Darwin.close(directory) }; guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
  }
}
