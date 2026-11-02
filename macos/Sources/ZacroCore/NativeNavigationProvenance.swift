import CryptoKit
import Foundation

/// Records why a native-only URL was retained. This is never a loading grant:
/// Chromium must revalidate the current installed incarnation and URL policy
/// before restoring or loading it. Imports deliberately discard this metadata.
public struct NativeNavigationProvenance: Codable, Equatable, Sendable {
  public let extensionID: String
  public let incarnationID: String
  public let urlDigest: String
  public init?(extensionID: String, incarnationID: String, approvedURL: String) {
    guard Self.validIdentity(extensionID, incarnationID), Self.structuralURL(approvedURL) != nil else { return nil }
    self.extensionID = extensionID; self.incarnationID = incarnationID
    urlDigest = Self.digest(approvedURL)
  }
  public func matches(_ url: String) -> Bool {
    Self.validIdentity(extensionID, incarnationID) && urlDigest == Self.digest(url)
      && Self.structuralURL(url) != nil
  }
  private static func validIdentity(_ extensionID: String, _ incarnationID: String) -> Bool {
    guard extensionID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
      incarnationID.hasPrefix(extensionID + ":") else { return false }
    let stamp = incarnationID.dropFirst(extensionID.count + 1)
    return !stamp.isEmpty && stamp.utf8.count <= 20 && stamp.utf8.allSatisfy { (48...57).contains($0) }
      && UInt64(stamp).map { $0 > 0 } == true
  }
  private static func digest(_ url: String) -> String {
    SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func structuralURL(_ value: String) -> URL? {
    guard value.utf8.count <= 1024 * 1024, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      let url = URL(string: value), let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
      !["javascript", "devtools", "chrome-untrusted"].contains(scheme),
      url.absoluteString == value else { return nil }
    return url
  }
}

extension BrowserStore {
  /// The caller must validate the live native receipt before invoking this.
  public func setNativePage(tabID: String, url: String, title: String = "",
                            provenance: NativeNavigationProvenance) throws {
    if let repository {
      return try repository.mutateDurably(windowID: owningWindowID) {
        try $0.setNativePage(tabID: tabID, url: url, title: title, provenance: provenance)
      }
    }
    guard provenance.matches(url), BrowserAddress.documentURL(url, provenance: provenance) != nil,
      tab(tabID) != nil else { throw ShortcutError("The native navigation receipt does not match this tab and address.") }
    try commit { state in
      guard let i = state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
      var tab = state.tabs[i]
      tab.url = url; tab.nativeNavigation = provenance; tab.homePage = nil
      if !title.isEmpty { tab.title = String(title.prefix(500)) }
      let entry = NavigationEntry(url: url, title: tab.title, nativeNavigation: provenance)
      if tab.navigation.indices.contains(tab.navigationIndex), tab.navigation[tab.navigationIndex].url == url {
        tab.navigation[tab.navigationIndex] = entry
      } else {
        tab.navigation = Array((Array(tab.navigation.prefix(max(0, tab.navigationIndex + 1))) + [entry]).suffix(100))
        tab.navigationIndex = tab.navigation.count - 1
      }
      state.tabs[i] = tab
    }
  }
}
