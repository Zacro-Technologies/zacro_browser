import Foundation
import Darwin

/// Completes browser-owned disk cleanup after Core has durably deleted a
/// profile. Runtime callers must first invalidate favicon/navigation writers;
/// startup replay calls this before creating those profile's documents.
public enum NativeProfileArtifacts {
  public static func remove(directory: URL, profileID: String) throws {
    try validateProfileID(profileID)
    guard try existingDirectory(directory) else { return }
    try removeNavigation(directory: directory, profileID: profileID)
    let icons = directory.appendingPathComponent("Icons", isDirectory: true)
    guard try existingDirectory(icons) else { return }
    let prefix = ServiceFiles.hash(profileID) + "-"
    for file in try FileManager.default.contentsOfDirectory(at: icons, includingPropertiesForKeys: nil) {
      let name = file.lastPathComponent
      guard name.hasPrefix(prefix), name.hasSuffix(".png") else { continue }
      let digest = name.dropFirst(prefix.count).dropLast(4)
      guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
      var metadata = stat()
      guard lstat(file.path, &metadata) == 0 else {
        if errno == ENOENT { continue }
        throw systemError()
      }
      guard metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFLNK else {
        throw ServiceError("STORAGE", "A saved profile icon is not a safe file.")
      }
      // unlink removes an owned symbolic link itself, never its destination.
      if Darwin.unlink(file.path) != 0 && errno != ENOENT { throw systemError() }
    }
    // Also sync an empty retry: a previous attempt may have removed the files
    // successfully but failed before its directory changes became durable.
    try synchronize(icons)
  }

  static func removeNavigation(directory: URL, profileID: String) throws {
    try validateProfileID(profileID)
    guard try existingDirectory(directory) else { return }
    let navigation = directory.appendingPathComponent("Navigation", isDirectory: true)
    guard try existingDirectory(navigation) else { return }
    let profile = navigation.appendingPathComponent(ServiceFiles.hash(profileID), isDirectory: true)
    if try existingDirectory(profile) { try FileManager.default.removeItem(at: profile) }
    try synchronize(navigation)
  }

  static func validateProfileID(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw ServiceError("INPUT", "Invalid native profile cleanup identity.")
    }
  }
  private static func existingDirectory(_ directory: URL) throws -> Bool {
    var metadata = stat()
    if lstat(directory.path, &metadata) != 0 {
      if errno == ENOENT { return false }
      throw systemError()
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else {
      throw ServiceError("STORAGE", "Profile cleanup requires a real directory, not a linked path.")
    }
    return true
  }
  private static func synchronize(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw systemError() }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw systemError() }
  }
  private static func systemError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
