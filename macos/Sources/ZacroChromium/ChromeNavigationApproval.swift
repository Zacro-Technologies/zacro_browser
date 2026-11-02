import Foundation

/// This value can only be created from Chromium's native permission checks.
/// Persist the identity in Core as provenance, then revalidate it on every load.
public struct ChromeNavigationApproval: Sendable {
  public let profileID: String
  public let extensionID: String
  public let incarnationID: String
  public let url: URL
  fileprivate init(profileID: String, response: [String: Any]) throws {
    guard let extensionID = response["extensionID"] as? String,
      let incarnationID = response["incarnationID"] as? String, !incarnationID.isEmpty,
      let address = response["url"] as? String, let url = URL(string: address)
    else { throw ChromeExtensionError.invalidResponse }
    self.profileID = profileID; self.extensionID = extensionID
    self.incarnationID = incarnationID; self.url = url
  }
  var parameters: [String: Any] {
    ["extensionID": extensionID, "incarnationID": incarnationID, "url": url.absoluteString]
  }
}

@MainActor
extension ChromeExtensionManager {
  public func authorizeHostNavigation(requestID: String, url: URL) async throws -> ChromeNavigationApproval {
    let result = try await nativeBrowser().devTools.call("Zacro.authorizeHostNavigation", parameters: [
      "requestID": requestID, "url": url.absoluteString,
    ])
    return try ChromeNavigationApproval(profileID: profileID, response: result)
  }
  public func validateNavigation(extensionID: String, incarnationID: String, url: URL) async throws -> ChromeNavigationApproval {
    let result = try await nativeBrowser().devTools.call("Zacro.validateNavigation", parameters: [
      "extensionID": extensionID, "incarnationID": incarnationID, "url": url.absoluteString,
    ])
    return try ChromeNavigationApproval(profileID: profileID, response: result)
  }
}
