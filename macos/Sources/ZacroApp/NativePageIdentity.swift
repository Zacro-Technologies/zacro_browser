import Foundation

/// Presentation only. Navigation authority stays with Chromium and the model;
/// displaying a scheme never grants it permission to load.
enum NativePageIdentity {
  static func hasDocument(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.absoluteString != "about:blank" && url.absoluteString != "zacro://newtab"
  }

  static func label(_ address: String) -> String {
    guard let url = URL(string: address) else { return String(address.prefix(200)) }
    switch url.scheme?.lowercased() {
    case "file": return url.lastPathComponent.isEmpty ? "Local file" : url.lastPathComponent
    case "data": return "Embedded page"
    case "blob": return "Temporary page"
    case "chrome", "zacro":
      let titles = ["settings": "Settings", "extensions": "Extensions", "downloads": "Downloads",
        "history": "History", "bookmarks": "Bookmarks", "newtab": "New tab", "new-tab-page": "New tab"]
      return url.host.flatMap { titles[$0] } ?? "Browser page"
    case "chrome-extension": return "Extension page"
    default:
      if let host = url.host { return host + (url.port.map { ":\($0)" } ?? "") }
      return String(address.prefix(200))
    }
  }

  static func securityLabel(_ url: URL?, failed: Bool) -> String {
    guard hasDocument(url) else { return "No page open" }
    switch url?.scheme?.lowercased() {
    case "https": return failed ? "Not secure" : "Secure"
    case "http": return "Not secure"
    case "file": return "Local file"
    case "chrome", "zacro": return "Browser page"
    case "chrome-extension": return "Extension page"
    case "data", "blob": return "Embedded page"
    default: return "Page"
    }
  }
}
