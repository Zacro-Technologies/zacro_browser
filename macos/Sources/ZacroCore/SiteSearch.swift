import Foundation

public struct SiteSearchEngine: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var keyword: String
  public var url: String
  public init(id: String = UUID().uuidString, name: String, keyword: String, url: String) {
    self.id = id; self.name = name; self.keyword = keyword; self.url = url
  }
  public static let defaults: [SiteSearchEngine] = [
    .init(id: "wikipedia", name: "Wikipedia", keyword: "w", url: "https://en.wikipedia.org/w/index.php?search=%s"),
    .init(id: "github", name: "GitHub", keyword: "gh", url: "https://github.com/search?q=%s"),
    .init(id: "youtube", name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query=%s"),
  ]
  public var validationError: String? {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 40 else {
      return "Use a name of 1–40 characters."
    }
    guard keyword.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^[a-z0-9][a-z0-9_-]{0,23}$", options: .caseInsensitive.union(.regularExpression)) != nil else {
      return "Use a keyword of 1–24 letters, numbers, underscores or hyphens."
    }
    guard url.utf16.count <= 2048, url.components(separatedBy: "%s").count == 2,
      let parts = URLComponents(string: url.replacingOccurrences(of: "%s", with: "zacro-search-placeholder")),
      let host = parts.host, !host.isEmpty
    else { return "Use a complete search URL containing exactly one %s." }
    guard parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())) else {
      return "Use an HTTPS search URL. HTTP is supported only for local development."
    }
    guard parts.user == nil, parts.password == nil else { return "Search URLs cannot contain account credentials." }
    guard !host.contains("zacro-search-placeholder"),
      parts.fragment?.contains("zacro-search-placeholder") != true,
      (parts.path + (parts.query ?? "")).contains("zacro-search-placeholder")
    else { return "Place %s in the URL path or query, after the website address." }
    return nil
  }
  public func searchURL(_ query: String) -> URL? {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard validationError == nil, !value.isEmpty, value.utf16.count <= 8_000 else { return nil }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: url.replacingOccurrences(of: "%s", with: encoded))
  }
  public static func normalized(_ engines: [SiteSearchEngine]) -> [SiteSearchEngine] {
    var keywords = Set<String>(); var ids = Set<String>(); var result: [SiteSearchEngine] = []
    for var engine in engines.prefix(100) {
      engine.name = engine.name.trimmingCharacters(in: .whitespacesAndNewlines)
      engine.keyword = engine.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      engine.url = engine.url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard engine.validationError == nil, !keywords.contains(engine.keyword) else { continue }
      if engine.id.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) == nil { engine.id = engine.keyword }
      if ids.contains(engine.id) { engine.id = "search-" + engine.keyword }
      guard ids.insert(engine.id).inserted else { continue }
      keywords.insert(engine.keyword); result.append(engine)
      if result.count == 20 { break }
    }
    return result
  }
  public static func currentWebsite(_ url: String, engines: [SiteSearchEngine], searchEngine: SearchEngine) -> SiteSearchEngine? {
    guard let page = BrowserAddress.webURL(url), let host = page.host else { return nil }
    if let saved = normalized(engines).first(where: {
      guard let candidate = URL(string: $0.url.replacingOccurrences(of: "%s", with: "query")) else { return false }
      let candidateScheme = candidate.scheme?.lowercased(), pageScheme = page.scheme?.lowercased()
      let candidatePort = candidate.port ?? (candidateScheme == "https" ? 443 : 80)
      let pagePort = page.port ?? (pageScheme == "https" ? 443 : 80)
      return candidateScheme == pageScheme && candidate.host?.lowercased() == page.host?.lowercased() && candidatePort == pagePort
    }) { return saved }
    let encoded = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    let prefix = "site:\(host) ".addingPercentEncoding(withAllowedCharacters: encoded) ?? ""
    return .init(id: "current-website", name: String(host.prefix(40)), keyword: "site", url: searchEngine.endpoint + prefix + "%s")
  }
}

public struct WebsitePermission: Codable, Equatable, Identifiable, Sendable {
  public var profileID: String
  public var origin: String
  public var permission: String
  public var allowed: Bool
  public var id: String { "\(profileID)|\(origin)|\(permission)" }
  public init(profileID: String, origin: String, permission: String, allowed: Bool) {
    self.profileID = profileID; self.origin = origin; self.permission = permission; self.allowed = allowed
  }
}
