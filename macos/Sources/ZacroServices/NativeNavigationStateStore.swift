import Foundation
import CryptoKit
import Darwin

/// Durable storage for Chromium's already encrypted native history envelope.
/// This actor never decrypts history or contacts Keychain. Chromium authenticates
/// its envelope against the native profile; this outer metadata rejects stale
/// artifacts after an explicit model navigation, reset, import, or slot change.
public actor NativeNavigationStateStore {
  public typealias ProfileReader = @Sendable (String) async -> AIProfileScope?
  public static let maximumEncryptedBytes = 6 * 1024 * 1024
  private static let maximumMetadataBytes = 32 * 1024
  private static let magic = Data([0x5a, 0x41, 0x43, 0x4e, 0x41, 0x56, 0x01, 0x00])
  private let root: URL
  private let getProfile: ProfileReader
  private var profileRevisions: [String: UInt64] = [:]
  private var slotRevisions: [String: UInt64] = [:]
  private struct Metadata: Codable {
    var profile: String
    var tab: String
    var peek: Bool
    var address: String
    var length: Int
    var digest: String
  }
  private enum InvalidArtifact: Error { case invalid }
  public init(directory: URL, getProfile: @escaping ProfileReader) {
    root = directory.appendingPathComponent("Navigation", isDirectory: true)
    self.getProfile = getProfile
  }
  public func read(profileID: String, tabID: String, peek: Bool = false, address: String) async throws -> Data? {
    let key = try path(profileID: profileID, tabID: tabID, peek: peek).path
    let revision = slotRevisions[key, default: 0]
    try await validateProfile(profileID)
    try requireSlot(key, revision)
    return try readFile(profileID: profileID, tabID: tabID, peek: peek, address: address)
  }
  public func write(profileID: String, tabID: String, peek: Bool = false,
                    address: String, encryptedData: Data) async throws {
    let key = try path(profileID: profileID, tabID: tabID, peek: peek).path
    let revision = advanceSlot(key)
    try await validateProfile(profileID)
    try requireSlot(key, revision)
    try writeFile(profileID: profileID, tabID: tabID, peek: peek, address: address, encryptedData: encryptedData)
  }
  /// Cleanup intentionally remains possible after its browser profile was removed.
  public func remove(profileID: String, tabID: String, peek: Bool = false) throws {
    let file = try path(profileID: profileID, tabID: tabID, peek: peek)
    _ = advanceSlot(file.path)
    try removeFile(file)
  }
  public func removeProfile(profileID: String) throws {
    try validateID(profileID)
    profileRevisions[profileID, default: 0] &+= 1
    guard try existingDirectory(root) else { return }
    let directory = root.appendingPathComponent(ServiceFiles.hash(profileID), isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
    try synchronizeDirectory(root)
  }
  @discardableResult public func promotePeek(profileID: String, fromTabID: String,
                                             toTabID: String, address: String) async throws -> Bool {
    let source = try path(profileID: profileID, tabID: fromTabID, peek: true).path
    let sourceRevision = slotRevisions[source, default: 0]
    let target = try path(profileID: profileID, tabID: toTabID, peek: false).path
    let targetRevision = advanceSlot(target)
    try await validateProfile(profileID)
    try requireSlot(source, sourceRevision); try requireSlot(target, targetRevision)
    guard let bytes = try readFile(profileID: profileID, tabID: fromTabID, peek: true, address: address) else { return false }
    try writeFile(profileID: profileID, tabID: toTabID, peek: false, address: address, encryptedData: bytes)
    _ = advanceSlot(source)
    try removeFile(path(profileID: profileID, tabID: fromTabID, peek: true))
    return true
  }
  @discardableResult public func copy(profileID: String, fromTabID: String,
                                      toTabID: String, peek: Bool = false, address: String) async throws -> Bool {
    if fromTabID == toTabID { return try await read(profileID: profileID, tabID: fromTabID, peek: peek, address: address) != nil }
    let source = try path(profileID: profileID, tabID: fromTabID, peek: peek).path
    let sourceRevision = slotRevisions[source, default: 0]
    let target = try path(profileID: profileID, tabID: toTabID, peek: peek).path
    let targetRevision = advanceSlot(target)
    try await validateProfile(profileID)
    try requireSlot(source, sourceRevision); try requireSlot(target, targetRevision)
    guard let bytes = try readFile(profileID: profileID, tabID: fromTabID, peek: peek, address: address) else { return false }
    try writeFile(profileID: profileID, tabID: toTabID, peek: peek, address: address, encryptedData: bytes)
    return true
  }
  private func validateProfile(_ id: String) async throws {
    try validateID(id)
    let revision = profileRevisions[id, default: 0]
    guard let profile = await getProfile(id), profile.id == id else { throw ServiceError("PROFILE", "The navigation profile is no longer available.") }
    guard profileRevisions[id, default: 0] == revision else { throw ServiceError("CANCELLED", "The navigation profile changed.") }
    guard !profile.isPrivate else { throw ServiceError("PRIVATE", "Private navigation history cannot be saved or restored.") }
    try Task.checkCancellation()
  }
  private func advanceSlot(_ key: String) -> UInt64 {
    slotRevisions[key, default: 0] &+= 1
    return slotRevisions[key, default: 0]
  }
  private func requireSlot(_ key: String, _ revision: UInt64) throws {
    guard slotRevisions[key, default: 0] == revision else { throw ServiceError("CANCELLED", "The navigation document changed.") }
  }
  private func validateID(_ id: String) throws {
    guard !id.isEmpty, id.utf8.count <= 512 else { throw ServiceError("INPUT", "Invalid navigation identity.") }
  }
  private func path(profileID: String, tabID: String, peek: Bool) throws -> URL {
    try validateID(profileID); try validateID(tabID)
    return root.appendingPathComponent(ServiceFiles.hash(profileID), isDirectory: true)
      .appendingPathComponent(ServiceFiles.hash(tabID) + (peek ? "-peek.bin" : "-main.bin"))
  }
  private func canonicalAddress(_ address: String) -> String? {
    guard !address.isEmpty, address.utf8.count <= 16_384,
      !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }),
      !address.contains("\\") else { return nil }
    if address == "about:blank" { return address }
    guard var parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(),
      let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
    if scheme == "chrome-extension" {
      guard host.range(of: "^[a-p]{32}$", options: .regularExpression) != nil, parts.port == nil else { return nil }
    } else if scheme == "http" || scheme == "https" {
      if let port = parts.port, !(1...65_535).contains(port) { return nil }
      if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
    } else { return nil }
    parts.scheme = scheme; parts.host = host
    if parts.path.isEmpty { parts.path = "/" }
    return parts.url?.absoluteString
  }
  private func writeFile(profileID: String, tabID: String, peek: Bool, address: String, encryptedData: Data) throws {
    guard let address = canonicalAddress(address) else { throw ServiceError("INPUT", "The navigation address cannot be restored.") }
    guard !encryptedData.isEmpty, encryptedData.count <= Self.maximumEncryptedBytes else {
      throw ServiceError("STORAGE_SIZE", "The encrypted navigation state exceeds its supported size.")
    }
    let file = try path(profileID: profileID, tabID: tabID, peek: peek)
    let metadata = Metadata(profile: ServiceFiles.hash(profileID), tab: ServiceFiles.hash(tabID), peek: peek,
      address: address, length: encryptedData.count, digest: Self.digest(encryptedData))
    let header = try JSONEncoder().encode(metadata)
    guard header.count <= Self.maximumMetadataBytes else { throw ServiceError("STORAGE_SIZE", "The navigation metadata exceeds its supported size.") }
    var bytes = Self.magic
    let length = UInt32(header.count)
    bytes.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
    bytes.append(header); bytes.append(encryptedData)
    try ensureDirectory(root); try ensureDirectory(file.deletingLastPathComponent())
    try ServiceFiles.writeData(bytes, file: file, maximum: Self.maximumEncryptedBytes + Self.maximumMetadataBytes + 12)
  }
  private func readFile(profileID: String, tabID: String, peek: Bool, address: String) throws -> Data? {
    let file = try path(profileID: profileID, tabID: tabID, peek: peek)
    guard try existingDirectory(root), try existingDirectory(file.deletingLastPathComponent()) else { return nil }
    guard let address = canonicalAddress(address) else { try removeFile(file); return nil }
    do {
      guard let bytes = try boundedRead(file) else { return nil }
      guard bytes.count >= 12, bytes.prefix(8) == Self.magic else { throw InvalidArtifact.invalid }
      let length = bytes[8..<12].reduce(0) { ($0 << 8) | Int($1) }
      guard length > 0, length <= Self.maximumMetadataBytes, bytes.count > 12 + length else { throw InvalidArtifact.invalid }
      guard let metadata = try? JSONDecoder().decode(Metadata.self, from: bytes.subdata(in: 12..<(12 + length))),
        metadata.profile == ServiceFiles.hash(profileID), metadata.tab == ServiceFiles.hash(tabID), metadata.peek == peek,
        metadata.address == address, metadata.length > 0, metadata.length <= Self.maximumEncryptedBytes,
        bytes.count - 12 - length == metadata.length else { throw InvalidArtifact.invalid }
      let payload = bytes.subdata(in: (12 + length)..<bytes.count)
      guard Self.digest(payload) == metadata.digest else { throw InvalidArtifact.invalid }
      return payload
    } catch is InvalidArtifact {
      try removeFile(file)
      return nil
    }
  }
  private func ensureDirectory(_ directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard try existingDirectory(directory) else { throw ServiceError("STORAGE", "The navigation directory is unavailable.") }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
  private func existingDirectory(_ directory: URL) throws -> Bool {
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      if errno == ENOENT { return false }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard info.st_mode & S_IFMT == S_IFDIR else { throw ServiceError("STORAGE", "The navigation directory is not a safe directory.") }
    return true
  }
  private func boundedRead(_ file: URL) throws -> Data? {
    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      if errno == ELOOP { throw InvalidArtifact.invalid }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let maximum = Self.maximumEncryptedBytes + Self.maximumMetadataBytes + 12
    guard info.st_mode & S_IFMT == S_IFREG else { throw ServiceError("STORAGE", "The navigation artifact is not a regular file.") }
    guard info.st_size >= 0, info.st_size <= maximum else { throw InvalidArtifact.invalid }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
    bytes.reserveCapacity(Int(info.st_size))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      if count == 0 { return bytes }
      guard bytes.count + count <= maximum else { throw InvalidArtifact.invalid }
      bytes.append(contentsOf: buffer.prefix(count))
    }
  }
  private func removeFile(_ file: URL) throws {
    guard try existingDirectory(root), try existingDirectory(file.deletingLastPathComponent()) else { return }
    if Darwin.unlink(file.path) != 0 {
      if errno == ENOENT { return }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try synchronizeDirectory(file.deletingLastPathComponent())
  }
  private func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
