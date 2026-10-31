import Foundation

public enum SearchEngine: String, Codable, CaseIterable, Sendable {
  case google, duckduckgo, bing, brave
  public var endpoint: String {
    switch self {
    case .google: "https://www.google.com/search?q="
    case .duckduckgo: "https://duckduckgo.com/?q="
    case .bing: "https://www.bing.com/search?q="
    case .brave: "https://search.brave.com/search?q="
    }
  }
}

public enum BrowserAddress {
  public static func resolve(_ input: String, engine: SearchEngine = .google) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 8_000,
      !text.unicodeScalars.contains(where: { $0.value < 32 })
    else { return nil }
    if text == "about:blank" || text == "zacro://newtab" { return URL(string: "about:blank") }
    let hostWithPort =
      text.range(
        of: #"^(localhost|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+):[0-9]+(?:/|$)"#,
        options: .regularExpression) != nil
    if let scheme = URLComponents(string: text)?.scheme, !hostWithPort {
      guard ["https", "http"].contains(scheme.lowercased()) else { return nil }
      return webURL(text)
    }
    if !text.contains(where: \.isWhitespace),
      text.contains(".") || text.hasPrefix("localhost") || text.hasPrefix("[")
    {
      let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")
      if let url = webURL((local ? "http://" : "https://") + text) { return url }
    }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#%")
    guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: engine.endpoint + query)
  }
  public static func webURL(_ value: String) -> URL? {
    guard value.count <= 8_000,
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return nil }
    guard let parts = URLComponents(string: value),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host,
      !host.isEmpty, parts.user == nil, parts.password == nil
    else { return nil }
    return parts.url
  }
}

public struct SpaceTheme: Codable, Equatable, Sendable {
  public var primaryColor = "#9D4460"
  public var secondaryColor = "#B695B8"
  public var intensity: Double = 0.45
  public var blend: Double = 0.5
  public var opacity: Double = 0.85
  public var blur: Double = 0.5
  public var grain: Double = 0.08
  public var appearance = "system"
  public init() {}
}
public struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var isPrivate: Bool
  public init(id: String = UUID().uuidString, name: String, isPrivate: Bool = false) {
    self.id = id
    self.name = name
    self.isPrivate = isPrivate
  }
}
public struct BrowserSpace: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var profileID: String
  public var name: String
  public var icon: String
  public var theme: SpaceTheme
  public var lastActiveTabID: String?
  public init(
    id: String = UUID().uuidString, profileID: String, name: String, icon: String = "circle.fill",
    theme: SpaceTheme = SpaceTheme()
  ) {
    self.id = id
    self.profileID = profileID
    self.name = name
    self.icon = icon
    self.theme = theme
  }
}
public struct NavigationEntry: Codable, Equatable, Sendable {
  public var url: String
  public var title: String
  public init(url: String, title: String = "") {
    self.url = url
    self.title = title
  }
}
public struct SavedPeek: Codable, Equatable, Sendable {
  public var url: String
  public var title: String
  public init(url: String, title: String = "") {
    self.url = url
    self.title = title
  }
}
public struct BrowserTab: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var spaceID: String
  public var folderID: String?
  public var url: String
  public var title: String
  public var customTitle: String?
  public var isFavorite: Bool
  public var isPinned: Bool
  public var isClosed: Bool
  public var savedURL: String?
  public var peek: SavedPeek?
  public var navigation: [NavigationEntry]
  public var navigationIndex: Int
  public var createdAt: Date
  public var lastAccessedAt: Date
  public var displayTitle: String {
    customTitle ?? (title.isEmpty ? (URL(string: url)?.host ?? "New tab") : title)
  }
  public init(
    id: String = UUID().uuidString, spaceID: String, url: String = "about:blank",
    title: String = "New tab", isFavorite: Bool = false, isPinned: Bool = false
  ) {
    self.id = id
    self.spaceID = spaceID
    self.url = url
    self.title = title
    self.isFavorite = isFavorite
    self.isPinned = isPinned
    self.isClosed = false
    navigation = []
    navigationIndex = -1
    createdAt = Date()
    lastAccessedAt = Date()
  }
}
public struct BrowserFolder: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var spaceID: String
  public var parentID: String?
  public var name: String
  public var isExpanded: Bool
  public init(
    id: String = UUID().uuidString, spaceID: String, name: String, parentID: String? = nil,
    isExpanded: Bool = true
  ) {
    self.id = id
    self.spaceID = spaceID
    self.name = name
    self.parentID = parentID
    self.isExpanded = isExpanded
  }
}
public struct SplitGroup: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var spaceID: String
  public var leftTabID: String
  public var rightTabID: String
  public var ratio: Double
  public var tabIDs: [String] { [leftTabID, rightTabID] }
  public init(
    id: String = UUID().uuidString, spaceID: String, leftTabID: String, rightTabID: String,
    ratio: Double = 0.5
  ) {
    self.id = id
    self.spaceID = spaceID
    self.leftTabID = leftTabID
    self.rightTabID = rightTabID
    self.ratio = ratio
  }
}
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var profileID: String
  public var url: String
  public var title: String
  public var visitedAt: Date
  public init(
    id: String = UUID().uuidString, profileID: String, url: String, title: String,
    visitedAt: Date = Date()
  ) {
    self.id = id
    self.profileID = profileID
    self.url = url
    self.title = title
    self.visitedAt = visitedAt
  }
}
public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var profileID: String
  public var url: String
  public var title: String
  public init(id: String = UUID().uuidString, profileID: String, url: String, title: String) {
    self.id = id
    self.profileID = profileID
    self.url = url
    self.title = title
  }
}
public struct ArchivedTab: Codable, Identifiable, Equatable, Sendable {
  public var tab: BrowserTab
  public var archivedAt: Date
  public var id: String { tab.id }
  public init(tab: BrowserTab, archivedAt: Date = Date()) {
    self.tab = tab
    self.archivedAt = archivedAt
  }
}
public struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var profileID: String
  public var url: String
  public var filename: String
  public var path: String?
  public var status: String
  public var receivedBytes: Int64
  public var totalBytes: Int64
  public var createdAt: Date
  public init(
    id: String = UUID().uuidString, profileID: String, url: String, filename: String,
    path: String? = nil, status: String = "downloading"
  ) {
    self.id = id
    self.profileID = profileID
    self.url = url
    self.filename = filename
    self.path = path
    self.status = status
    receivedBytes = 0
    totalBytes = 0
    createdAt = Date()
  }
}
public struct BrowserSettings: Codable, Equatable, Sendable {
  public var searchEngine: SearchEngine = .google
  public var pageGutter: Double = 4
  public var pageRadius: Double = 12
  public var sidebarWidth: Double = 224
  public var sidebarVisible: Bool = true
  public var restoreSession: Bool = true
  public var archiveAfterHours: Double = 12
  public var motionScale: Double = 1
  public var appearance: String = "system"
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case searchEngine, pageGutter, pageRadius, sidebarWidth, sidebarVisible, restoreSession,
      archiveAfterHours, motionScale, appearance
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    searchEngine =
      SearchEngine(rawValue: try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? "google")
      ?? .google
    pageGutter = try c.decodeIfPresent(Double.self, forKey: .pageGutter) ?? pageGutter
    pageRadius = try c.decodeIfPresent(Double.self, forKey: .pageRadius) ?? pageRadius
    sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? sidebarWidth
    sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? sidebarVisible
    restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? restoreSession
    archiveAfterHours =
      try c.decodeIfPresent(Double.self, forKey: .archiveAfterHours) ?? archiveAfterHours
    motionScale = try c.decodeIfPresent(Double.self, forKey: .motionScale) ?? motionScale
    appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
  }
}
public struct BrowserState: Codable, Equatable, Sendable {
  public var version = 1
  public var profiles: [BrowserProfile]
  public var spaces: [BrowserSpace]
  public var tabs: [BrowserTab] = []
  public var folders: [BrowserFolder] = []
  public var splits: [SplitGroup] = []
  public var history: [HistoryEntry] = []
  public var bookmarks: [Bookmark] = []
  public var archive: [ArchivedTab] = []
  public var downloads: [DownloadRecord] = []
  public var settings = BrowserSettings()
  public var activeSpaceID: String
  public var activeTabID: String?
  public var activeSpace: BrowserSpace? { spaces.first { $0.id == activeSpaceID } }
  public var activeProfile: BrowserProfile? { profiles.first { $0.id == activeSpace?.profileID } }
  public var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }
  public init() {
    profiles = [BrowserProfile(id: "default", name: "Personal")]
    spaces = [BrowserSpace(id: "home", profileID: "default", name: "Personal")]
    activeSpaceID = "home"
  }
}
