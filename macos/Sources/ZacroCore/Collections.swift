import Foundation

extension BrowserStore {
  /// Portable collections intentionally exclude visited history, page state,
  /// permissions, downloads, extension registrations, and every private profile.
  public func exportData(to url: URL) throws {
    if let repository { return try repository.exportData(to: url) }
    let profiles = state.profiles.filter { !$0.isPrivate }
    let ids = Set(profiles.map(\.id))
    let spaces = state.spaces.filter { ids.contains($0.profileID) }
    let spaceIDs = Set(spaces.map(\.id))
    let tabs = state.tabs.filter { spaceIDs.contains($0.spaceID) && BrowserAddress.documentURL($0.url) != nil }
    let tabIDs = Set(tabs.map(\.id))
    let null = NSNull()
    let profilesJSON: [[String: Any]] = profiles.map {
      ["id": $0.id, "name": $0.name, "private": false, "archiveAfterHours": $0.archiveAfterHours as Any? ?? null]
    }
    let spacesJSON: [[String: Any]] = spaces.map { space in
      ["id": space.id, "profileId": space.profileID, "name": space.name, "color": space.theme.primaryColor,
       "icon": space.icon, "lastActiveTabId": space.lastActiveTabID as Any? ?? null,
       "theme": ["secondaryColor": space.theme.secondaryColor, "gradient": space.theme.blend * 100,
                 "vibrancy": space.theme.intensity * 100, "opacity": space.theme.opacity * 100,
                 "grain": space.theme.grain * 200, "blur": space.theme.blur * 32, "appearance": space.theme.appearance]]
    }
    let tabsJSON: [[String: Any]] = tabs.map { tab in
      var value: [String: Any] = ["id": tab.id, "spaceId": tab.spaceID, "profileId": profileID(for: tab) ?? "",
        "url": tab.url == "about:blank" ? "zacro://newtab" : tab.url, "title": tab.title,
        "pinned": tab.isPinned, "favorite": tab.isFavorite, "closed": tab.isClosed,
        "folderId": tab.folderID as Any? ?? null, "createdAt": tab.createdAt.timeIntervalSince1970 * 1000,
        "lastActiveAt": tab.lastAccessedAt.timeIntervalSince1970 * 1000]
      if let title = tab.customTitle { value["customTitle"] = title }
      if tab.homePage == true { value["homePage"] = true }
      if let autoDiscardable = tab.autoDiscardable { value["autoDiscardable"] = autoDiscardable }
      if let group = tab.groupID { value["groupId"] = group }
      if let opener = tab.openerTabID {
        let source = opener.hasPrefix("peek:") ? String(opener.dropFirst(5)) : opener
        if tabIDs.contains(source), !opener.hasPrefix("peek:") || tabs.contains(where: { $0.id == source && $0.peek.flatMap { BrowserAddress.webURL($0.url) } != nil }) {
          value["openerTabId"] = opener
        }
      }
      if let saved = tab.savedURL, BrowserAddress.webURL(saved) != nil { value["pinnedUrl"] = saved }
      if let title = tab.savedTitle { value["pinnedTitle"] = title }
      if let peek = tab.peek, BrowserAddress.webURL(peek.url) != nil { value["savedPeek"] = ["url": peek.url, "title": peek.title] }
      return value
    }
    var settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.settings)) as! [String: Any]
    settings["theme"] = state.settings.appearance
    settings["shortcutOverrides"] = ["darwin": state.settings.shortcutOverrides]
    let root: [String: Any] = ["format": "zacro-export", "version": 1,
      "exportedAt": ISO8601DateFormatter().string(from: Date()), "profiles": profilesJSON, "spaces": spacesJSON,
      "tabs": tabsJSON,
      "tabGroups": state.tabGroups.filter { ids.contains($0.profileID) }.map {
        ["id": $0.id, "profileId": $0.profileID, "windowId": $0.windowID,
         "title": $0.title, "color": $0.color, "collapsed": $0.collapsed] as [String: Any]
      },
      "folders": state.folders.filter { spaceIDs.contains($0.spaceID) }.map {
        ["id": $0.id, "spaceId": $0.spaceID, "name": $0.name, "parentId": $0.parentID as Any? ?? null, "collapsed": !$0.isExpanded] as [String: Any]
      },
      "splitGroups": state.splits.filter { spaceIDs.contains($0.spaceID) && $0.tabIDs.allSatisfy(tabIDs.contains) }.map {
        ["id": $0.id, "spaceId": $0.spaceID, "tabIds": $0.tabIDs, "ratio": $0.ratio] as [String: Any]
      },
      "bookmarks": state.bookmarks.filter { ids.contains($0.profileID) }.map {
        ["id": $0.id, "profileId": $0.profileID, "url": $0.url, "title": $0.title,
         "createdAt": max(0, $0.createdAt.timeIntervalSince1970 * 1000)] as [String: Any]
      }, "settings": settings]
    try AtomicStoreFile.write(JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: url)
  }

  public func importData(from url: URL) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) { try $0.importData(from: url) } }

    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 20 * 1024 * 1024 else { throw ShortcutError("Choose a browser export smaller than 20 MB.") }
    let data = try Data(contentsOf: url)
    if ["html", "htm"].contains(url.pathExtension.lowercased()) {
      try importBookmarksHTML(data)
      return
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LegacyImportError.invalidState }
    if root["format"] as? String == "zacro-export" {
      try importLegacy(from: url)
    } else if root["activeSpaceID"] != nil {
      guard root["version"] as? Int == 1 else { throw LegacyImportError.invalidState }
      var collection = root
      collection.removeValue(forKey: "pendingNativeProfileRetirements")
      try mergeCollection(JSONDecoder().decode(BrowserState.self,
        from: JSONSerialization.data(withJSONObject: collection)))
    } else { throw LegacyImportError.invalidState }
  }

  func mergeCollection(_ source: BrowserState, includeHistory: Bool = false) throws {
    var sanitized = source
    sanitized.pendingNativeProfileRetirements = []
    for i in sanitized.tabs.indices {
      sanitized.tabs[i].nativeNavigation = nil; sanitized.tabs[i].savedNativeNavigation = nil
      sanitized.tabs[i].peek?.nativeNavigation = nil
      if let navigation = sanitized.tabs[i].peek?.navigation {
        sanitized.tabs[i].peek?.navigation = navigation.map { NavigationEntry(url: $0.url, title: $0.title) }
      }
      for j in sanitized.tabs[i].navigation.indices { sanitized.tabs[i].navigation[j].nativeNavigation = nil }
    }
    for i in sanitized.archive.indices {
      sanitized.archive[i].tab.nativeNavigation = nil; sanitized.archive[i].tab.savedNativeNavigation = nil
      sanitized.archive[i].tab.peek = nil
      for j in sanitized.archive[i].tab.navigation.indices { sanitized.archive[i].tab.navigation[j].nativeNavigation = nil }
    }
    let validation = BrowserStore(directory: directory.appendingPathComponent("import-validation"), initialState: sanitized)
    validation.repair()
    var source = validation.state
    source.profiles.removeAll(where: \.isPrivate)
    let allowed = Set(source.profiles.map(\.id))
    source.spaces.removeAll { !allowed.contains($0.profileID) }
    let spaces = Set(source.spaces.map(\.id))
    source.tabs.removeAll { !spaces.contains($0.spaceID) }
    source.folders.removeAll { !spaces.contains($0.spaceID) }
    source.bookmarks.removeAll { !allowed.contains($0.profileID) }
    guard state.tabs.count + source.tabs.count <= 1000, state.profiles.count + source.profiles.count <= 100,
      state.spaces.count + source.spaces.count <= 500, state.folders.count + source.folders.count <= 1000,
      state.bookmarks.count + source.bookmarks.count <= 20_000 else { throw ShortcutError("This import would exceed the browser’s collection limits.") }
    func mapping<T: Identifiable>(_ values: [T]) -> [String: String] where T.ID == String {
      var reserved = Set(state.pendingNativeProfileRetirements).union(state.profiles.map(\.id))
      return Dictionary(uniqueKeysWithValues: values.map {
        var id = UUID().uuidString
        while reserved.contains(id) { id = UUID().uuidString }
        reserved.insert(id)
        return ($0.id, id)
      })
    }
    let profilesMap = mapping(source.profiles), spacesMap = mapping(source.spaces), tabsMap = mapping(source.tabs), foldersMap = mapping(source.folders)
    let groupsMap = mapping(source.tabGroups)
    let destinationWindow = creationWindowID ?? state.focusedWindowID ?? state.tabs.compactMap(\.windowID).first ?? "main"
    var merged = state
    for var profile in source.profiles {
      profile.id = profilesMap[profile.id]!
      profile.name += " (imported)"
      profile.archiveAfterHours = profile.archiveAfterHours ?? source.settings.archiveAfterHours
      profile.pinnedExtensionIDs = []
      merged.profiles.append(profile)
    }
    for var space in source.spaces {
      space.id = spacesMap[space.id]!; space.profileID = profilesMap[space.profileID]!
      space.lastActiveTabID = space.lastActiveTabID.flatMap { tabsMap[$0] }
      merged.spaces.append(space)
    }
    for var folder in source.folders {
      folder.id = foldersMap[folder.id]!; folder.spaceID = spacesMap[folder.spaceID]!
      folder.parentID = folder.parentID.flatMap { foldersMap[$0] }
      merged.folders.append(folder)
    }
    for var tab in source.tabs {
      tab.id = tabsMap[tab.id]!; tab.spaceID = spacesMap[tab.spaceID]!
      tab.folderID = tab.folderID.flatMap { foldersMap[$0] }
      tab.windowID = destinationWindow; tab.groupID = tab.groupID.flatMap { groupsMap[$0] }
      tab.openerTabID = tab.openerTabID.flatMap { id in
        if id.hasPrefix("peek:") { return tabsMap[String(id.dropFirst(5))].map { "peek:" + $0 } }
        return tabsMap[id]
      }
      if !includeHistory { tab.navigation = [NavigationEntry(url: tab.url, title: tab.title)]; tab.navigationIndex = 0 }
      merged.tabs.append(tab)
    }
    for var group in source.tabGroups {
      guard let profile = profilesMap[group.profileID], let id = groupsMap[group.id] else { continue }
      group.id = id; group.profileID = profile; group.windowID = destinationWindow
      merged.tabGroups.append(group)
    }
    for group in source.splits {
      guard let space = spacesMap[group.spaceID], let left = tabsMap[group.leftTabID], let right = tabsMap[group.rightTabID] else { continue }
      merged.splits.append(.init(spaceID: space, leftTabID: left, rightTabID: right, ratio: group.ratio))
    }
    for bookmark in source.bookmarks {
      guard let profile = profilesMap[bookmark.profileID] else { continue }
      merged.bookmarks.append(.init(profileID: profile, url: bookmark.url, title: bookmark.title, createdAt: bookmark.createdAt))
    }
    if includeHistory {
      for entry in source.history {
        guard let profile = profilesMap[entry.profileID] else { continue }
        merged.history.append(.init(profileID: profile, url: entry.url, title: entry.title, visitedAt: entry.visitedAt))
      }
      for var archived in source.archive {
        guard let space = spacesMap[archived.tab.spaceID] else { continue }
        archived.tab.id = UUID().uuidString; archived.tab.spaceID = space
        archived.tab.folderID = archived.tab.folderID.flatMap { foldersMap[$0] }
        merged.archive.append(archived)
      }
    }
    try commit { $0 = merged }
  }

  private func importBookmarksHTML(_ data: Data) throws {
    guard data.count <= 16 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else {
      throw ShortcutError("Choose a UTF-8 bookmarks file of up to 16 MB.")
    }
    let anchor = try NSRegularExpression(pattern: "<a\\b([^>]{0,20000})>([\\s\\S]*?)</a\\s*>", options: [.caseInsensitive])
    let href = try NSRegularExpression(pattern: "\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive])
    let tags = try NSRegularExpression(pattern: "<[^>]*>")
    let text = html as NSString
    var bookmarks: [(String, String)] = []
    for match in anchor.matches(in: html, range: NSRange(location: 0, length: text.length)) {
      let attributes = text.substring(with: match.range(at: 1)) as NSString
      guard let link = href.firstMatch(in: attributes as String, range: NSRange(location: 0, length: attributes.length)),
        let range = (1..<link.numberOfRanges).map({ link.range(at: $0) }).first(where: { $0.location != NSNotFound }),
        let url = BrowserAddress.webURL(Self.decodeEntities(attributes.substring(with: range))) else { continue }
      let label = text.substring(with: match.range(at: 2))
      let clean = tags.stringByReplacingMatches(in: label, range: NSRange(location: 0, length: (label as NSString).length), withTemplate: "")
      let title = String(Self.decodeEntities(clean).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
      bookmarks.append((url.absoluteString, title.isEmpty ? url.absoluteString : title))
      guard bookmarks.count <= 20_000 else { throw ShortcutError("Bookmark file exceeds 20,000 entries.") }
    }
    guard !bookmarks.isEmpty else { throw ShortcutError("No supported HTTP or HTTPS bookmarks were found.") }
    guard state.bookmarks.count + bookmarks.count <= 20_000 else { throw ShortcutError("Bookmark import is too large (maximum 20,000).") }
    let profile = activeProfileID
    try commit { state in
      var existing = Set(state.bookmarks.filter { $0.profileID == profile }.map(\.url))
      for (url, title) in bookmarks where existing.insert(url).inserted {
        state.bookmarks.append(.init(profileID: profile, url: url, title: title))
      }
    }
  }

  private static func decodeEntities(_ text: String) -> String {
    guard let pattern = try? NSRegularExpression(pattern: "&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);", options: [.caseInsensitive]) else { return text }
    var result = text
    for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
      let entity = (text as NSString).substring(with: match.range(at: 1)).lowercased()
      let decoded: String
      if entity.hasPrefix("#") {
        let hex = entity.hasPrefix("#x")
        let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10) ?? 0
        decoded = number > 0 ? UnicodeScalar(number).map(String.init) ?? "�" : "�"
      } else { decoded = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "][entity] ?? entity }
      if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decoded) }
    }
    return result
  }
}
