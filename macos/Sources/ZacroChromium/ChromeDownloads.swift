import Foundation

public struct ChromeNativeDownload: Decodable, Sendable {
  public let id: UInt32
  public let guid: String
  public let url: String
  public let path: String
  private let receivedBytes: String
  private let totalBytes: String
  public let status: String
  public let paused: Bool
  public let canResume: Bool
  public let dangerous: Bool
  public let dangerType: Int
  public let interruptReason: Int
  public let startedAt: Double
  public let sourceURL: String
  public let sourceTabID: Int?
  public let isPrivate: Bool
  public var download: CefDownload {
    CefDownload(id: id, url: URL(string: url), receivedBytes: Int64(receivedBytes) ?? 0,
      totalBytes: Int64(totalBytes) ?? 0, isComplete: status == "complete",
      isCanceled: status == "cancelled", fullPath: path.isEmpty ? nil : URL(fileURLWithPath: path),
      isInterrupted: status == "interrupted", isPaused: paused,
      isInProgress: status == "downloading" || status == "paused")
  }
}

public struct ChromeDownloadSnapshot: Decodable, Sendable {
  public let downloads: [ChromeNativeDownload]
  public let total: Int
  /// False means the snapshot contains active downloads and the newest 20,000
  /// items. It must never be interpreted as a deletion of older Library rows.
  public let complete: Bool
}

@MainActor
extension ChromeExtensionManager {
  public func downloadSnapshot() async throws -> ChromeDownloadSnapshot {
    let value = try await nativeBrowser().devTools.call("Zacro.downloadSnapshot")
    return try JSONDecoder().decode(ChromeDownloadSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
  }
  public func renameDownload(guid: String, newName: String) async throws {
    guard !guid.isEmpty, guid.count <= 128, !newName.isEmpty,
      (newName as NSString).lastPathComponent == newName, !newName.contains("\0") else {
      throw ChromeExtensionError.invalidResponse
    }
    let value = try await nativeBrowser().devTools.call("Zacro.renameDownload", parameters: ["guid": guid, "name": newName], timeout: 120)
    guard value["renamed"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
  }
  public func controlDownload(guid: String, action: String) async throws {
    guard !guid.isEmpty, guid.count <= 128, ["pause", "resume", "cancel"].contains(action) else {
      throw ChromeExtensionError.invalidResponse
    }
    let value = try await nativeBrowser().devTools.call("Zacro.controlDownload", parameters: ["guid": guid, "action": action])
    guard value["accepted"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
  }
}
