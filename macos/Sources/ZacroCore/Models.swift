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
    if text.isEmpty { return URL(string: "about:blank") }
    guard text.utf16.count <= 8_192,
      !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return nil }
    if text == "about:blank" || text == "zacro://newtab" { return URL(string: "about:blank") }
    let hostWithPort =
      text.range(
        of: #"^(?:localhost|[A-Za-z0-9_.-]+|\[[A-Fa-f0-9:]+\]):[0-9]+(?:[/?#]|$)"#,
        options: .regularExpression) != nil
    if let scheme = URLComponents(string: text)?.scheme, !hostWithPort {
      guard ["https", "http"].contains(scheme.lowercased()) else { return nil }
      return webURL(text)
    }
    let explicitHost = text.range(of: #"^(?:localhost|\[[A-Fa-f0-9:]+\])(?:[/?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
      || text.range(of: #"^[^/]+\.[^/]+(?:[/?#]|$)"#, options: .regularExpression) != nil
    if !text.contains(where: \.isWhitespace), hostWithPort || explicitHost
    {
      let local = text.range(of: #"^(?:localhost|127\.\d+\.\d+\.\d+|\[::1\])(?=[:/?#]|$)"#, options: [.regularExpression,.caseInsensitive]) != nil
      if let url = webURL((local ? "http://" : "https://") + text) { return url }
    }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: engine.endpoint + query)
  }
  public static func webURL(_ value: String) -> URL? {
    guard value.utf16.count <= 8_192,
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return nil }
    guard var parts = URLComponents(string: value),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host,
      !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.port.map({ (0...65535).contains($0) }) ?? true
    else { return nil }
    parts.scheme = parts.scheme?.lowercased()
    parts.host = host.lowercased()
    if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
    if parts.path.isEmpty { parts.path = "/" }
    return parts.url
  }
  public static func webOrigin(_ value: String) -> String? {
    guard let url = webURL(value), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    parts.path = ""; parts.query = nil; parts.fragment = nil
    return parts.string
  }
  /// Extension destinations are accepted only through the trusted extension action path.
  /// Address entry/search continues to accept HTTP(S) exclusively.
  public static func extensionURL(_ value: String) -> URL? {
    guard value.utf16.count <= 8_192, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      let parts = URLComponents(string: value), parts.scheme == "chrome-extension", let host = parts.host,
      host.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
      parts.user == nil, parts.password == nil, parts.port == nil,
      !parts.path.hasPrefix("/zacro-compat-") else { return nil }
    return parts.url
  }
  static func documentURL(_ value: String) -> URL? {
    webURL(value) ?? extensionURL(value) ?? (value == "about:blank" ? URL(string: value) : nil)
  }
}

public struct SpaceTheme: Codable, Equatable, Sendable {
  public var primaryColor = "#9D4460"
  public var secondaryColor = "#B695B8"
  public var intensity: Double = 0
  public var blend: Double = 0.5
  public var opacity: Double = 1
  public var blur: Double = 0
  public var grain: Double = 0
  public var appearance = "system"
  public init() {}
}
public struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var isPrivate: Bool
  public var archiveAfterHours: Double?
  public var pinnedExtensionIDs: [String] = []
  public init(id: String = UUID().uuidString, name: String, isPrivate: Bool = false) {
    self.id = id
    self.name = name
    self.isPrivate = isPrivate
  }
  private enum CodingKeys: String, CodingKey { case id, name, isPrivate, archiveAfterHours, pinnedExtensionIDs }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    isPrivate = try values.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    archiveAfterHours = try values.decodeIfPresent(Double.self, forKey: .archiveAfterHours)
    pinnedExtensionIDs = try values.decodeIfPresent([String].self, forKey: .pinnedExtensionIDs) ?? []
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
  /// Persistent logical shell identity. Native Chromium/window IDs are process-local.
  public var windowID: String?
  public var groupID: String?
  public var spaceID: String
  public var folderID: String?
  public var url: String
  public var title: String
  public var customTitle: String?
  public var isFavorite: Bool
  public var isPinned: Bool
  public var isClosed: Bool
  public var savedURL: String?
  public var savedTitle: String?
  public var muted: Bool?
  public var homePage: Bool?
  /// Missing in older snapshots; automatic memory discard is allowed by default.
  public var autoDiscardable: Bool?
  /// Logical Zacro identity, never a Chromium session tab ID.
  public var openerTabID: String?
  public var isMuted: Bool { get { muted ?? false } set { muted = newValue } }
  public var peek: SavedPeek?
  public var navigation: [NavigationEntry]
  public var navigationIndex: Int
  public var createdAt: Date
  public var lastAccessedAt: Date
  public var displayTitle: String {
    customTitle ?? (isPinned ? savedTitle : nil) ?? (title.isEmpty ? (URL(string: url)?.host ?? "New tab") : title)
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
  public var createdAt: Date
  public init(id: String = UUID().uuidString, profileID: String, url: String, title: String, createdAt: Date = Date()) {
    self.id = id
    self.profileID = profileID
    self.url = url
    self.title = title
    self.createdAt = createdAt
  }
  private enum CodingKeys: String, CodingKey { case id, profileID, url, title, createdAt }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    profileID = try values.decode(String.self, forKey: .profileID)
    url = try values.decode(String.self, forKey: .url)
    title = try values.decode(String.self, forKey: .title)
    createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
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
  public var previousPath: String?
  public var sourceURL: String?
  public var sourceTitle: String?
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
  public var panelWidth: Double = 336
  public var tabDensity = "comfortable"
  public var pinnedSleepMinutes = 20
  public var openSourcesLimit = 3
  public var siteSearches = SiteSearchEngine.defaults
  public var shortcutOverrides: [String: String] = [:]
  public var onboardingCompleted = false
  public var aiProvider = "codex"
  public var aiModel = ""
  public var sharePageContext = false
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case searchEngine, pageGutter, pageRadius, sidebarWidth, sidebarVisible, restoreSession,
      archiveAfterHours, motionScale, appearance, panelWidth, tabDensity, pinnedSleepMinutes,
      openSourcesLimit, siteSearches, shortcutOverrides, onboardingCompleted, aiProvider, aiModel, sharePageContext
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
    panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth) ?? panelWidth
    tabDensity = try c.decodeIfPresent(String.self, forKey: .tabDensity) ?? tabDensity
    pinnedSleepMinutes = try c.decodeIfPresent(Int.self, forKey: .pinnedSleepMinutes) ?? pinnedSleepMinutes
    openSourcesLimit = try c.decodeIfPresent(Int.self, forKey: .openSourcesLimit) ?? openSourcesLimit
    siteSearches = try c.decodeIfPresent([SiteSearchEngine].self, forKey: .siteSearches) ?? siteSearches
    shortcutOverrides = try c.decodeIfPresent([String: String].self, forKey: .shortcutOverrides) ?? [:]
    onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    aiProvider = try c.decodeIfPresent(String.self, forKey: .aiProvider) ?? aiProvider
    aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? ""
    sharePageContext = try c.decodeIfPresent(Bool.self, forKey: .sharePageContext) ?? false
  }
}
public struct BrowserState: Codable, Equatable, Sendable {
  public var version = 1
  public var profiles: [BrowserProfile]
  public var spaces: [BrowserSpace]
  public var tabs: [BrowserTab] = []
  public var folders: [BrowserFolder] = []
  public var splits: [SplitGroup] = []
  public var tabGroups: [BrowserTabGroup] = []
  public var history: [HistoryEntry] = []
  public var bookmarks: [Bookmark] = []
  public var archive: [ArchivedTab] = []
  public var downloads: [DownloadRecord] = []
  public var permissions: [WebsitePermission] = []
  public var settings = BrowserSettings()
  public var windowBounds = BrowserWindowBounds()
  public var windowSessions: [BrowserWindowSession]?
  public var focusedWindowID: String?
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
  private enum CodingKeys: String, CodingKey {
    case version, profiles, spaces, tabs, folders, splits, tabGroups, history, bookmarks, archive, downloads,
      permissions, settings, windowBounds, windowSessions, focusedWindowID, activeSpaceID, activeTabID
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    guard version == 1 else { throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported browser state version") }
    profiles = try c.decodeIfPresent([BrowserProfile].self, forKey: .profiles) ?? profiles
    spaces = try c.decodeIfPresent([BrowserSpace].self, forKey: .spaces) ?? spaces
    tabs = try c.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? []
    folders = try c.decodeIfPresent([BrowserFolder].self, forKey: .folders) ?? []
    splits = try c.decodeIfPresent([SplitGroup].self, forKey: .splits) ?? []
    tabGroups = try c.decodeIfPresent([BrowserTabGroup].self, forKey: .tabGroups) ?? []
    history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
    bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
    archive = try c.decodeIfPresent([ArchivedTab].self, forKey: .archive) ?? []
    downloads = try c.decodeIfPresent([DownloadRecord].self, forKey: .downloads) ?? []
    permissions = try c.decodeIfPresent([WebsitePermission].self, forKey: .permissions) ?? []
    settings = try c.decodeIfPresent(BrowserSettings.self, forKey: .settings) ?? settings
    windowBounds = try c.decodeIfPresent(BrowserWindowBounds.self, forKey: .windowBounds) ?? windowBounds
    windowSessions = try c.decodeIfPresent([BrowserWindowSession].self, forKey: .windowSessions)
    focusedWindowID = try c.decodeIfPresent(String.self, forKey: .focusedWindowID)
    activeSpaceID = try c.decodeIfPresent(String.self, forKey: .activeSpaceID) ?? activeSpaceID
    activeTabID = try c.decodeIfPresent(String.self, forKey: .activeTabID)
  }
}

public struct BrowserWindowBounds: Codable, Equatable, Sendable {
  public var width: Double = 1440
  public var height: Double = 940
  public var x: Double?
  public var y: Double?
  public var maximized = false
  public var sizeKind = "content"
  public init() {}
  private enum CodingKeys: String, CodingKey { case width, height, x, y, maximized, sizeKind }
  public init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    width = try values.decodeIfPresent(Double.self, forKey: .width) ?? width
    height = try values.decodeIfPresent(Double.self, forKey: .height) ?? height
    x = try values.decodeIfPresent(Double.self, forKey: .x)
    y = try values.decodeIfPresent(Double.self, forKey: .y)
    maximized = try values.decodeIfPresent(Bool.self, forKey: .maximized) ?? false
    sizeKind = try values.decodeIfPresent(String.self, forKey: .sizeKind) ?? "content"
  }
}
