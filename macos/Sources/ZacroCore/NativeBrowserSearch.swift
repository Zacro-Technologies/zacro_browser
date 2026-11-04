import Foundation

public extension BrowserAddress {
  /// Search APIs always treat their argument as a literal query. A URL-looking
  /// query must not be reinterpreted by the address bar's navigation resolver.
  static func searchURL(_ query: String, engine: SearchEngine = .google) -> URL? {
    guard !query.isEmpty, query.utf16.count <= 8_192 else { return nil }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    guard let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return webURL(engine.endpoint + escaped)
  }
}
