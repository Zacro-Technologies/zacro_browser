import CryptoKit
import Foundation

/// A cache identity, not authority to change Chromium's BookmarkModel.
public struct NativeBookmarkIdentity: Codable, Equatable, Sendable {
  public var nodeID: String
  public var uuid: String
  public var storage: String
  public var editable: Bool
  public init(nodeID: String, uuid: String, storage: String = "local", editable: Bool = true) {
    self.nodeID = nodeID; self.uuid = uuid; self.storage = storage; self.editable = editable
  }
  public var key: String { storage + ":" + uuid.lowercased() }
  public var isValid: Bool {
    !nodeID.isEmpty && nodeID.utf8.count <= 20 && nodeID.utf8.allSatisfy { (48...57).contains($0) }
      && UInt64(nodeID).map { String($0) == nodeID } == true && UUID(uuidString: uuid) != nil
      && ["local", "account"].contains(storage)
  }
}

/// A trusted native adapter snapshot projected into the flat Library view.
public struct NativeBookmarkRecord: Sendable {
  public var identity: NativeBookmarkIdentity
  public var url: String
  public var title: String
  public var createdAt: Date
  public var logicalID: String?
  public init(identity: NativeBookmarkIdentity, url: String, title: String,
              createdAt: Date = .distantPast, logicalID: String? = nil) {
    self.identity = identity; self.url = url; self.title = title
    self.createdAt = createdAt; self.logicalID = logicalID
  }
}

public struct NativeBookmarkImportAcknowledgement: Codable, Equatable, Sendable {
  public var profileID: String
  public var logicalID: String
  public var uuid: String
  public init(profileID: String, logicalID: String, uuid: String) {
    self.profileID = profileID; self.logicalID = logicalID; self.uuid = uuid
  }
}

extension BrowserStore {
  /// Replaces only the native cache. Absence here never requests native deletion.
  /// The caller must read a revision-consistent snapshot and explicitly report
  /// any display limit. Unacknowledged legacy records remain queued for import.
  @discardableResult public func reconcileNativeBookmarks(profileID: String,
      records: [NativeBookmarkRecord], resolvedLegacyIDs: Set<String> = [],
      acknowledgements: [NativeBookmarkImportAcknowledgement] = []) throws -> Int {
    if let repository {
      return try repository.mutateDurably(windowID: owningWindowID) {
        try $0.reconcileNativeBookmarks(profileID: profileID, records: records, resolvedLegacyIDs: resolvedLegacyIDs, acknowledgements: acknowledgements)
      }
    }
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }), records.count <= 20_000 else {
      throw ShortcutError("Choose a public profile and a bounded native bookmark snapshot.")
    }
    guard records.allSatisfy({ $0.identity.isValid }),
      Set(records.map { $0.identity.key }).count == records.count,
      Set(records.map { $0.identity.nodeID }).count == records.count else {
      throw ShortcutError("The native bookmark snapshot has invalid identities.")
    }
    guard acknowledgements.count <= 20_000, acknowledgements.allSatisfy({
      $0.profileID == profileID && resolvedLegacyIDs.contains($0.logicalID) && UUID(uuidString: $0.uuid) != nil
    }), Set(acknowledgements.map(\.logicalID)).count == acknowledgements.count else {
      throw ShortcutError("The bookmark migration acknowledgement is invalid.")
    }
    let existing = state.bookmarks.filter { $0.profileID == profileID }
    let byNative = Dictionary(existing.compactMap { item in item.nativeIdentity.map { ($0.key, item) } }, uniquingKeysWith: { first, _ in first })
    let byLogical = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    let pending = existing.filter { $0.nativeIdentity == nil && !resolvedLegacyIDs.contains($0.id) }
    let others = state.bookmarks.filter { $0.profileID != profileID }
    let capacity = max(0, 20_000 - others.count - pending.count)
    var used = Set((others + pending).map(\.id)), bookmarks: [Bookmark] = []
    for record in records {
      guard let url = BrowserAddress.webURL(record.url), bookmarks.count < capacity else { continue }
      let prior = byNative[record.identity.key]
        ?? record.logicalID.flatMap { id in resolvedLegacyIDs.contains(id) ? byLogical[id] : nil }
      var id = prior?.id ?? "native-" + SHA256.hash(data: Data((profileID + "\u{0}" + record.identity.key).utf8)).map { String(format: "%02x", $0) }.joined()
      if used.contains(id) { id = UUID().uuidString }
      used.insert(id)
      var bookmark = Bookmark(id: id, profileID: profileID, url: url.absoluteString,
        title: String(record.title.prefix(500)), createdAt: record.createdAt.timeIntervalSince1970.isFinite ? record.createdAt : .distantPast)
      bookmark.nativeIdentity = record.identity
      bookmarks.append(bookmark)
    }
    let changed = others + pending + bookmarks
    let newIDs = Set(acknowledgements.map(\.logicalID))
    let pendingAcknowledgements = state.bookmarkImportAcknowledgements.filter { $0.profileID != profileID || !newIDs.contains($0.logicalID) } + acknowledgements
    guard pendingAcknowledgements.count <= 20_000 else { throw ShortcutError("Finish the pending native bookmark imports before importing more.") }
    if changed != state.bookmarks || pendingAcknowledgements != state.bookmarkImportAcknowledgements || !resolvedLegacyIDs.isEmpty {
      try commit(purgeRecovery: !resolvedLegacyIDs.isEmpty) {
        $0.bookmarks = changed; $0.bookmarkImportAcknowledgements = pendingAcknowledgements
      }
    }
    return bookmarks.count
  }
}

extension BrowserStore {
  public func acknowledgeNativeBookmarkImports(_ entries: [NativeBookmarkImportAcknowledgement]) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.acknowledgeNativeBookmarkImports(entries) } }
    guard !entries.isEmpty else { return }
    try commit { state in state.bookmarkImportAcknowledgements.removeAll { entries.contains($0) } }
  }
}
