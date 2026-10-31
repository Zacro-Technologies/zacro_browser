import Foundation

public enum LegacyImportError: LocalizedError {
  case invalidState
  public var errorDescription: String? { "This file is not a supported Zacro browser collection." }
}

extension BrowserStore {
  /// Reads an Electron JSON snapshot into a new native collection. The source is never modified.
  public func importLegacy(from url: URL) throws {
    let data = try Data(contentsOf: url)
    guard data.count < 32 * 1024 * 1024,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["spaces"] is [[String: Any]], root["tabs"] is [[String: Any]]
    else { throw LegacyImportError.invalidState }
    var imported = BrowserState()
    let records = { (key: String) in root[key] as? [[String: Any]] ?? [] }
    imported.profiles = records("profiles").compactMap { item in
      guard let id = item["id"] as? String, item["private"] as? Bool != true else { return nil }
      return BrowserProfile(id: id, name: item["name"] as? String ?? "Imported")
    }
    if imported.profiles.isEmpty { imported.profiles = BrowserState().profiles }
    imported.spaces = records("spaces").compactMap { item in
      guard let id = item["id"] as? String else { return nil }
      var theme = SpaceTheme()
      theme.primaryColor = item["color"] as? String ?? theme.primaryColor
      if let old = item["theme"] as? [String: Any] {
        theme.secondaryColor = old["secondaryColor"] as? String ?? theme.secondaryColor
        theme.blend = (old["gradient"] as? Double ?? 50) / 100
        theme.intensity = (old["vibrancy"] as? Double ?? 0) / 100
        theme.opacity = (old["opacity"] as? Double ?? 100) / 100
        theme.blur = (old["blur"] as? Double ?? 0) / 32
        theme.grain = (old["grain"] as? Double ?? 0) / 100
      }
      var space = BrowserSpace(
        id: id, profileID: item["profileId"] as? String ?? imported.profiles[0].id,
        name: item["name"] as? String ?? "Imported", icon: item["icon"] as? String ?? "circle.fill",
        theme: theme)
      space.lastActiveTabID = item["lastActiveTabId"] as? String
      return space
    }
    func convertTab(_ item: [String: Any]) -> BrowserTab? {
      guard let id = item["id"] as? String, let value = item["url"] as? String,
        let url = BrowserAddress.resolve(value)
      else { return nil }
      var tab = BrowserTab(
        id: id, spaceID: item["spaceId"] as? String ?? "home", url: url.absoluteString,
        title: item["title"] as? String ?? "Imported",
        isFavorite: item["favorite"] as? Bool ?? false, isPinned: item["pinned"] as? Bool ?? false)
      tab.folderID = item["folderId"] as? String
      tab.customTitle = item["customTitle"] as? String
      tab.isClosed = item["closed"] as? Bool ?? false
      tab.savedURL = item["pinnedUrl"] as? String ?? (tab.isPinned ? tab.url : nil)
      if let peek = item["savedPeek"] as? [String: Any], let peekURL = peek["url"] as? String,
        BrowserAddress.webURL(peekURL) != nil
      {
        tab.peek = SavedPeek(url: peekURL, title: peek["title"] as? String ?? "")
      }
      if let history = item["navigationHistory"] as? [String: Any],
        let entries = history["entries"] as? [[String: Any]]
      {
        tab.navigation = entries.compactMap { entry in
          guard let url = entry["url"] as? String, BrowserAddress.webURL(url) != nil else {
            return nil
          }
          return NavigationEntry(url: url, title: entry["title"] as? String ?? "")
        }
        tab.navigationIndex = history["index"] as? Int ?? tab.navigation.count - 1
      }
      if tab.navigation.isEmpty {
        tab.navigation = [NavigationEntry(url: tab.url, title: tab.title)]
        tab.navigationIndex = 0
      }
      if let date = item["lastActiveAt"] as? Double {
        tab.lastAccessedAt = Date(timeIntervalSince1970: date / 1000)
      }
      return tab
    }
    imported.tabs = records("tabs").compactMap(convertTab)
    imported.folders = records("folders").compactMap { item in
      guard let id = item["id"] as? String, let space = item["spaceId"] as? String else {
        return nil
      }
      return BrowserFolder(
        id: id, spaceID: space, name: item["name"] as? String ?? "Folder",
        parentID: item["parentId"] as? String, isExpanded: item["collapsed"] as? Bool != true)
    }
    imported.splits = records("splitGroups").compactMap { item in
      guard let tabs = item["tabIds"] as? [String], tabs.count == 2,
        let space = item["spaceId"] as? String
      else { return nil }
      return SplitGroup(
        id: item["id"] as? String ?? UUID().uuidString, spaceID: space, leftTabID: tabs[0],
        rightTabID: tabs[1], ratio: item["ratio"] as? Double ?? 0.5)
    }
    imported.bookmarks = records("bookmarks").compactMap { item in
      guard let url = item["url"] as? String, BrowserAddress.webURL(url) != nil else { return nil }
      return Bookmark(
        profileID: item["profileId"] as? String ?? "default", url: url,
        title: item["title"] as? String ?? url)
    }
    imported.history = records("history").compactMap { item in
      guard let url = item["url"] as? String, BrowserAddress.webURL(url) != nil else { return nil }
      return HistoryEntry(
        profileID: item["profileId"] as? String ?? "default", url: url,
        title: item["title"] as? String ?? url,
        visitedAt: Date(timeIntervalSince1970: (item["visitedAt"] as? Double ?? 0) / 1000))
    }
    imported.archive = records("archive").compactMap { item in
      guard let tab = convertTab(item) else { return nil }
      return ArchivedTab(
        tab: tab,
        archivedAt: Date(timeIntervalSince1970: (item["archivedAt"] as? Double ?? 0) / 1000))
    }
    imported.activeSpaceID = root["activeSpaceId"] as? String ?? imported.spaces.first?.id ?? "home"
    imported.activeTabID = root["activeTabId"] as? String
    if let settings = root["settings"] as? [String: Any] {
      imported.settings.searchEngine =
        SearchEngine(rawValue: settings["searchEngine"] as? String ?? "google") ?? .google
      imported.settings.pageGutter = settings["pageGutter"] as? Double ?? 4
      imported.settings.pageRadius = settings["pageRadius"] as? Double ?? 12
      imported.settings.sidebarWidth = settings["sidebarWidth"] as? Double ?? 224
      imported.settings.restoreSession = settings["restoreSession"] as? Bool ?? true
      imported.settings.archiveAfterHours = settings["archiveAfterHours"] as? Double ?? 12
    }
    state = imported
    repair()
    save()
  }
}
