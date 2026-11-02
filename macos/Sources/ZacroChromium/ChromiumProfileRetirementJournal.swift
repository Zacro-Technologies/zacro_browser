import Darwin
import Foundation

/// Internal deletion receipts. Only a successful durable write authorizes the
/// application to acknowledge its corresponding Core transaction.
struct ChromiumProfileRetirementJournal {
  let file: URL
  static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 1_024
      && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  func read() throws -> Set<String> {
    var attributes = stat()
    guard lstat(file.path, &attributes) == 0 else {
      if errno == ENOENT { return [] }
      throw Self.failure()
    }
    guard attributes.st_mode & S_IFMT == S_IFREG,
      attributes.st_size >= 0, attributes.st_size <= 3 * 1024 * 1024 else { throw POSIXError(.EINVAL) }
    let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
    guard values.count <= 1_000, values.allSatisfy(Self.validID) else { throw POSIXError(.EINVAL) }
    return Set(values)
  }

  func write(_ values: Set<String>) throws {
    guard values.count <= 1_000, values.allSatisfy(Self.validID) else { throw POSIXError(.EINVAL) }
    let bytes = try JSONEncoder().encode(values.sorted())
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".retirement-\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw Self.failure() }
    defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
    try bytes.withUnsafeBytes { data in
      var offset = 0
      while offset < data.count {
        let count = Darwin.write(descriptor, data.baseAddress!.advanced(by: offset), data.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Self.failure() }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, Darwin.rename(temporary.path, file.path) == 0 else { throw Self.failure() }
    try Self.synchronizeDirectory(file.deletingLastPathComponent())
  }

  static func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure() }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw failure() }
  }

  static func removeProfileDirectory(root: URL, hash: String) throws {
    guard hash.utf8.count == 64,
      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw POSIXError(.EINVAL)
    }
    var rootAttributes = stat()
    guard lstat(root.path, &rootAttributes) == 0 else {
      if errno == ENOENT { return }
      throw failure()
    }
    guard rootAttributes.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.EINVAL) }
    let directory = root.appendingPathComponent(hash, isDirectory: true)
    var profileAttributes = stat()
    if lstat(directory.path, &profileAttributes) == 0 {
      guard profileAttributes.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.EINVAL) }
      try FileManager.default.removeItem(at: directory)
    } else if errno != ENOENT {
      throw failure()
    }
    // A previous unlink may have succeeded before its directory fsync failed.
    // Retrying an absent leaf still has to commit that unlink before acknowledgement.
    try synchronizeDirectory(root)
  }

  private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
