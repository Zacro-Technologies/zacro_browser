import Foundation

/// Native identity includes storage because Chromium permits the same UUID in
/// the local and account stores. Numeric node IDs are unique within a profile.
public struct ChromeBookmarkNode: Codable, Sendable {
  public let nodeID: String
  public let uuid: String
  public let storage: String
  public let parentID: String?
  public let url: String?
  public let title: String
  public let dateAdded: Double
  public let editable: Bool
  public let folder: Bool
  public let logicalID: String?
}

public struct ChromeBookmarkPage: Decodable, Sendable {
  public let revision: String
  public let total: Int
  public let nextOffset: Int
  public let complete: Bool
  public let nodes: [ChromeBookmarkNode]
}

public struct ChromeBookmarkImport: Sendable {
  public let logicalID: String
  public let url: String
  public let title: String
  public let dateAdded: Double
  public init(logicalID: String, url: String, title: String, dateAdded: Double) {
    self.logicalID = logicalID; self.url = url; self.title = title; self.dateAdded = dateAdded
  }
}

public struct ChromeBookmarkAcknowledgement: Sendable {
  public let logicalID: String
  public let uuid: String
  public init(logicalID: String, uuid: String) { self.logicalID = logicalID; self.uuid = uuid }
}

public struct ChromeBookmarkImportResult: Decodable, Sendable {
  public let logicalID: String
  public let uuid: String
  public let removed: Bool
  public let node: ChromeBookmarkNode?
}

@MainActor
extension ChromeExtensionManager {
  /// A revision covers the entire native tree. Restart from offset zero if a
  /// subsequent page fails; never interpret a partial snapshot as deletions.
  public func bookmarkPage(offset: Int = 0, revision: String? = nil, limit: Int = 512) async throws -> ChromeBookmarkPage {
    guard offset >= 0, (1...512).contains(limit), offset == 0 || revision != nil else {
      throw ChromeExtensionError.invalidResponse
    }
    var params: [String: Any] = ["offset": offset, "limit": limit]
    if let revision { params["revision"] = revision }
    let result = try await nativeBrowser().devTools.call("Zacro.bookmarkPage", parameters: params)
    return try JSONDecoder().decode(ChromeBookmarkPage.self, from: JSONSerialization.data(withJSONObject: result))
  }

  public func importBookmarks(_ entries: [ChromeBookmarkImport]) async throws -> [ChromeBookmarkImportResult] {
    guard entries.count <= 512 else { throw ChromeExtensionError.invalidResponse }
    let result = try await nativeBrowser().devTools.call("Zacro.importBookmarks", parameters: ["entries": entries.map {
      ["logicalID": $0.logicalID, "url": $0.url, "title": $0.title, "dateAdded": $0.dateAdded] as [String: Any]
    }])
    guard let results = result["results"] as? [[String: Any]] else { throw ChromeExtensionError.invalidResponse }
    return try JSONDecoder().decode([ChromeBookmarkImportResult].self, from: JSONSerialization.data(withJSONObject: results))
  }

  /// Call only after the Core bindings/removals and their recovery copies have
  /// committed durably. Until then native deletion remains an import tombstone.
  public func acknowledgeBookmarkImports(_ results: [ChromeBookmarkImportResult]) async throws {
    try await acknowledgeBookmarkBindings(results.map { ChromeBookmarkAcknowledgement(logicalID: $0.logicalID, uuid: $0.uuid) })
  }

  public func acknowledgeBookmarkBindings(_ entries: [ChromeBookmarkAcknowledgement]) async throws {
    guard entries.count <= 512 else { throw ChromeExtensionError.invalidResponse }
    let result = try await nativeBrowser().devTools.call("Zacro.acknowledgeBookmarkImports", parameters: ["entries": entries.map {
      ["logicalID": $0.logicalID, "uuid": $0.uuid]
    }])
    guard result["acknowledged"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
  }

  public func removeBookmark(nodeID: String, uuid: String, storage: String) async throws {
    guard ["local", "account"].contains(storage), UUID(uuidString: uuid) != nil,
      Int64(nodeID) != nil else { throw ChromeExtensionError.invalidResponse }
    let result = try await nativeBrowser().devTools.call("Zacro.removeBookmark", parameters: [
      "nodeID": nodeID, "uuid": uuid, "storage": storage,
    ])
    guard result["removed"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
  }
}
