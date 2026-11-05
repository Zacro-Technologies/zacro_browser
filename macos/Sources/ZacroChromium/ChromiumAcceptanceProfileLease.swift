import CryptoKit
import Darwin
import Foundation

/// Test-only authority for exactly one cold restart of an app-created profile.
/// No marker, lease or mock storage is used by ordinary browser launches.
final class ChromiumAcceptanceProfileLease {
  static let markerName = ".zacro-persisted-extension-owner.json"
  static let resumeName = ".zacro-persisted-extension-resumed"
  private let descriptor: Int32
  private init(_ descriptor: Int32) { self.descriptor = descriptor }
  deinit { Darwin.close(descriptor) }

  private struct Marker: Codable {
    var version: Int
    var directory: String
    var device: Int64
    var inode: UInt64
    var uid: UInt32
    var nonceSHA256: String
    var createdAt: Double
  }

  static func systemTemporaryDirectory() throws -> URL {
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard length > 1, length < 32_768 else { throw failure() }
    var buffer = [CChar](repeating: 0, count: length)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length else { throw failure() }
    return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
  }

  static func admit(directory: URL, persisted: Bool, resume: Bool, nonce: String?,
    now: Date = Date()) throws -> ChromiumAcceptanceProfileLease? {
    guard !resume || persisted else { throw failure() }
    let raw = directory.standardizedFileURL
    let canonical = raw.resolvingSymlinksInPath()
    guard canonical.deletingLastPathComponent() == (try systemTemporaryDirectory()),
      canonical.lastPathComponent.hasPrefix("zacro-native-acceptance-"),
      canonical.lastPathComponent.count > "zacro-native-acceptance-".count else { throw failure() }
    // Reject a linked leaf even if its target is another otherwise-valid test
    // directory. The canonical parent may include macOS's normal /var alias.
    var leaf = stat()
    if lstat(raw.path, &leaf) != 0 {
      guard errno == ENOENT, !resume, Darwin.mkdir(raw.path, mode_t(0o700)) == 0 else { throw failure() }
    } else if leaf.st_mode & S_IFMT != S_IFDIR { throw failure() }
    let parentFD = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw failure() }
    defer { Darwin.close(parentFD) }
    var status = stat()
    guard fstat(parentFD, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == getuid(), status.st_mode & mode_t(0o7777) == mode_t(0o700) else { throw failure() }
    if !resume {
      guard try FileManager.default.contentsOfDirectory(atPath: canonical.path).isEmpty else { throw failure() }
    }
    guard persisted else { return nil }
    guard let nonce, nonce.utf8.count == 64,
      nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw failure() }
    let hash = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    let flags = resume ? O_RDWR | O_NOFOLLOW | O_CLOEXEC : O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    let markerFD = Darwin.openat(parentFD, markerName, flags, mode_t(0o600))
    guard markerFD >= 0 else { throw failure() }
    var retained = false
    defer { if !retained { Darwin.close(markerFD) } }
    guard flock(markerFD, LOCK_EX | LOCK_NB) == 0 else { throw failure() }
    if resume {
      var markerStatus = stat()
      guard fstat(markerFD, &markerStatus) == 0,
        markerStatus.st_mode & S_IFMT == S_IFREG,
        markerStatus.st_uid == getuid(), markerStatus.st_nlink == 1,
        markerStatus.st_mode & mode_t(0o7777) == mode_t(0o600),
        markerStatus.st_size > 0, markerStatus.st_size <= 4_096 else { throw failure() }
      var bytes = Data(count: Int(markerStatus.st_size))
      try bytes.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let count = Darwin.read(markerFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw failure() }
          offset += count
        }
      }
      let marker = try JSONDecoder().decode(Marker.self, from: bytes)
      guard marker.version == 1, marker.directory == canonical.path,
        marker.device == Int64(status.st_dev), marker.inode == UInt64(status.st_ino),
        marker.uid == getuid(), marker.nonceSHA256 == hash,
        marker.createdAt.isFinite, now.timeIntervalSince1970 >= marker.createdAt,
        now.timeIntervalSince1970 - marker.createdAt < 6 * 60 * 60 else { throw failure() }
      // A third process cannot reuse this lease, even after a successful second
      // process exit. The first process's held flock prevents overlapping use.
      let consumed = Darwin.openat(parentFD, resumeName,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
      guard consumed >= 0 else { throw failure() }
      defer { Darwin.close(consumed) }
      guard fsync(consumed) == 0, fsync(parentFD) == 0 else { throw failure() }
    } else {
      let marker = Marker(version: 1, directory: canonical.path, device: Int64(status.st_dev),
        inode: UInt64(status.st_ino), uid: getuid(), nonceSHA256: hash, createdAt: now.timeIntervalSince1970)
      let bytes = try JSONEncoder().encode(marker)
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let count = Darwin.write(markerFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw failure() }
          offset += count
        }
      }
      guard fsync(markerFD) == 0, fsync(parentFD) == 0 else { throw failure() }
    }
    retained = true
    return ChromiumAcceptanceProfileLease(markerFD)
  }

  private static func failure() -> NSError {
    NSError(domain: "ZacroAcceptanceProfile", code: 1, userInfo: [NSLocalizedDescriptionKey:
      "Acceptance requires a private owned disposable profile; persisted restart additionally requires its app-created one-use lease."])
  }
}
