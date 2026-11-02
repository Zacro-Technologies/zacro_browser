import Foundation

public struct BrowserShortcut: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let category: String
  public var accelerator: String
  public var aliases: [String]
  public static let defaults: [BrowserShortcut] = [
    .init(id: "command-palette", title: "Command palette", category: "Navigation", accelerator: "Mod+T", aliases: ["Mod+K"]),
    .init(id: "paste-search", title: "Paste and search", category: "Navigation", accelerator: "Ctrl+Mod+V", aliases: []),
    .init(id: "open-location", title: "Edit current address", category: "Navigation", accelerator: "Mod+L", aliases: []),
    .init(id: "sidebar-toggle", title: "Toggle sidebar", category: "Navigation", accelerator: "Mod+S", aliases: []),
    .init(id: "focus-sidebar", title: "Focus sidebar", category: "Navigation", accelerator: "Mod+Alt+S", aliases: []),
    .init(id: "reveal-tab", title: "Reveal tab in sidebar", category: "Navigation", accelerator: "", aliases: []),
    .init(id: "history-back", title: "Back", category: "Navigation", accelerator: "Mod+Left", aliases: ["Mod+["]),
    .init(id: "history-forward", title: "Forward", category: "Navigation", accelerator: "Mod+Right", aliases: ["Mod+]"]),
    .init(id: "focus-chrome", title: "Focus page / browser controls", category: "Navigation", accelerator: "F6", aliases: []),
    .init(id: "copy-url", title: "Copy page address", category: "Navigation", accelerator: "Mod+Shift+C", aliases: []),
    .init(id: "next-space", title: "Next Space", category: "Spaces", accelerator: "Mod+Alt+Right", aliases: []),
    .init(id: "previous-space", title: "Previous Space", category: "Spaces", accelerator: "Mod+Alt+Left", aliases: []),
    .init(id: "new-space", title: "Create Space", category: "Spaces", accelerator: "Mod+Shift+E", aliases: []),
    .init(id: "new-folder", title: "Create folder", category: "Spaces", accelerator: "Mod+Shift+O", aliases: []),
    .init(id: "new-private-space", title: "New private session", category: "Spaces", accelerator: "Mod+Shift+N", aliases: []),
    .init(id: "close-tab", title: "Close tab or preview", category: "Tabs", accelerator: "Mod+W", aliases: []),
    .init(id: "reopen-tab", title: "Restore closed tab", category: "Tabs", accelerator: "Mod+Shift+T", aliases: []),
    .init(id: "recent-tab", title: "Next recent tab", category: "Tabs", accelerator: "Ctrl+Tab", aliases: []),
    .init(id: "previous-recent-tab", title: "Previous recent tab", category: "Tabs", accelerator: "Ctrl+Shift+Tab", aliases: []),
    .init(id: "next-tab", title: "Next tab in sidebar", category: "Tabs", accelerator: "Mod+Alt+Down", aliases: ["Mod+Shift+]"]),
    .init(id: "previous-tab", title: "Previous tab in sidebar", category: "Tabs", accelerator: "Mod+Alt+Up", aliases: ["Mod+Shift+["]),
    .init(id: "pin-tab", title: "Pin / unpin tab", category: "Tabs", accelerator: "Mod+D", aliases: []),
    .init(id: "duplicate-tab", title: "Duplicate tab", category: "Tabs", accelerator: "Mod+Shift+D", aliases: []),
    .init(id: "rename-tab", title: "Rename tab", category: "Tabs", accelerator: "Mod+Alt+R", aliases: []),
    .init(id: "move-tab", title: "Move tab", category: "Tabs", accelerator: "Mod+Alt+M", aliases: []),
    .init(id: "mute-tab", title: "Mute / unmute tab", category: "Tabs", accelerator: "Mod+Shift+M", aliases: []),
    .init(id: "split", title: "Split view", category: "Tabs", accelerator: "Ctrl+Shift+=", aliases: []),
    .init(id: "peek-close", title: "Close preview", category: "Tabs", accelerator: "Mod+Shift+Escape", aliases: []),
    .init(id: "peek-promote", title: "Open preview as tab", category: "Tabs", accelerator: "Mod+Shift+Enter", aliases: []),
    .init(id: "reload", title: "Reload page", category: "Page", accelerator: "Mod+R", aliases: []),
    .init(id: "force-reload", title: "Reload without cache", category: "Page", accelerator: "Mod+Shift+R", aliases: []),
    .init(id: "stop", title: "Stop loading", category: "Page", accelerator: "Mod+.", aliases: []),
    .init(id: "find", title: "Find on page", category: "Page", accelerator: "Mod+F", aliases: []),
    .init(id: "find-next", title: "Find next", category: "Page", accelerator: "Mod+G", aliases: []),
    .init(id: "find-previous", title: "Find previous", category: "Page", accelerator: "Mod+Shift+G", aliases: []),
    .init(id: "bookmark", title: "Bookmark page", category: "Page", accelerator: "Mod+Alt+D", aliases: []),
    .init(id: "save-page", title: "Save page as…", category: "Page", accelerator: "Mod+Shift+S", aliases: []),
    .init(id: "print", title: "Print page", category: "Page", accelerator: "Mod+P", aliases: []),
    .init(id: "zoom-in", title: "Zoom in", category: "Page", accelerator: "Mod+=", aliases: ["Mod+Shift+="]),
    .init(id: "zoom-out", title: "Zoom out", category: "Page", accelerator: "Mod+-", aliases: []),
    .init(id: "zoom-reset", title: "Actual size", category: "Page", accelerator: "Mod+0", aliases: []),
    .init(id: "history", title: "History", category: "Library", accelerator: "Mod+Y", aliases: []),
    .init(id: "downloads", title: "Downloads", category: "Library", accelerator: "Mod+J", aliases: []),
    .init(id: "bookmarks", title: "Bookmarks", category: "Library", accelerator: "Mod+Shift+B", aliases: []),
    .init(id: "archive", title: "Archived tabs", category: "Library", accelerator: "Mod+Shift+A", aliases: []),
    .init(id: "extensions", title: "Extensions", category: "Library", accelerator: "Mod+E", aliases: []),
    .init(id: "ai", title: "Ask AI / open sources", category: "Library", accelerator: "Mod+Alt+G", aliases: ["Mod+Enter"]),
    .init(id: "preferences", title: "Settings", category: "Browser", accelerator: "Mod+,", aliases: []),
    .init(id: "shortcuts", title: "Keyboard shortcuts", category: "Browser", accelerator: "Mod+Alt+K", aliases: []),
    .init(id: "browser-menu", title: "Browser menu", category: "Browser", accelerator: "", aliases: []),
    .init(id: "onboarding", title: "Welcome tour", category: "Browser", accelerator: "", aliases: []),
    .init(id: "open-browser", title: "New window", category: "Browser", accelerator: "Mod+N", aliases: []),
    .init(id: "close-window", title: "Close window", category: "Browser", accelerator: "Mod+Shift+W", aliases: []),
    .init(id: "fullscreen", title: "Toggle full screen", category: "Browser", accelerator: "Ctrl+Mod+F", aliases: []),
    .init(id: "developer-tools", title: "Developer tools", category: "Browser", accelerator: "Mod+Alt+I", aliases: []),
    .init(id: "tab-1", title: "Tab 1", category: "Tab positions", accelerator: "Mod+1", aliases: []),
    .init(id: "tab-2", title: "Tab 2", category: "Tab positions", accelerator: "Mod+2", aliases: []),
    .init(id: "tab-3", title: "Tab 3", category: "Tab positions", accelerator: "Mod+3", aliases: []),
    .init(id: "tab-4", title: "Tab 4", category: "Tab positions", accelerator: "Mod+4", aliases: []),
    .init(id: "tab-5", title: "Tab 5", category: "Tab positions", accelerator: "Mod+5", aliases: []),
    .init(id: "tab-6", title: "Tab 6", category: "Tab positions", accelerator: "Mod+6", aliases: []),
    .init(id: "tab-7", title: "Tab 7", category: "Tab positions", accelerator: "Mod+7", aliases: []),
    .init(id: "tab-8", title: "Tab 8", category: "Tab positions", accelerator: "Mod+8", aliases: []),
    .init(id: "tab-9", title: "Last tab", category: "Tab positions", accelerator: "Mod+9", aliases: []),
    .init(id: "space-1", title: "Space 1", category: "Space positions", accelerator: "Ctrl+1", aliases: []),
    .init(id: "space-2", title: "Space 2", category: "Space positions", accelerator: "Ctrl+2", aliases: []),
    .init(id: "space-3", title: "Space 3", category: "Space positions", accelerator: "Ctrl+3", aliases: []),
    .init(id: "space-4", title: "Space 4", category: "Space positions", accelerator: "Ctrl+4", aliases: []),
    .init(id: "space-5", title: "Space 5", category: "Space positions", accelerator: "Ctrl+5", aliases: []),
    .init(id: "space-6", title: "Space 6", category: "Space positions", accelerator: "Ctrl+6", aliases: []),
    .init(id: "space-7", title: "Space 7", category: "Space positions", accelerator: "Ctrl+7", aliases: []),
    .init(id: "space-8", title: "Space 8", category: "Space positions", accelerator: "Ctrl+8", aliases: []),
    .init(id: "space-9", title: "Space 9", category: "Space positions", accelerator: "Ctrl+9", aliases: []),
  ]
  public static func catalog(overrides: [String: String] = [:]) -> [BrowserShortcut] {
    defaults.map { entry in
      guard let binding = overrides[entry.id] else { return entry }
      var entry = entry; entry.accelerator = binding; entry.aliases = []; return entry
    }
  }
  public static func normalized(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    guard trimmed.count <= 80 else { throw ShortcutError("Choose a valid keyboard shortcut.") }
    var pieces = trimmed.components(separatedBy: "+")
    var key = pieces.removeLast()
    key = ["Plus": "=", "Minus": "-", "Comma": ","][key] ?? key
    if key.count == 1 { key = key.uppercased() }
    let names: Set<String> = ["Left", "Right", "Up", "Down", "Tab", "Enter", "Escape", "Space", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown", "Insert"]
    let function = key.range(of: "^F([1-9]|1[0-9]|2[0-4])$", options: .regularExpression) != nil
    let punctuation = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,.[/];='`\\-")
    guard names.contains(key) || function || (key.count == 1 && key.first.map(punctuation.contains) == true) else {
      throw ShortcutError("That key cannot be used as a browser shortcut.")
    }
    let modifiers = ["Ctrl", "Mod", "Alt", "Shift"]
    guard Set(pieces).count == pieces.count, pieces.allSatisfy(modifiers.contains),
      function || pieces.contains(where: { ["Ctrl", "Mod", "Alt"].contains($0) }) else {
      throw ShortcutError("Include Command, Control or Option so ordinary typing stays available.")
    }
    return (modifiers.filter(pieces.contains) + [key]).joined(separator: "+")
  }
  public static func updating(_ overrides: [String: String], id: String, accelerator: String) throws -> [String: String] {
    guard let entry = defaults.first(where: { $0.id == id }) else { throw ShortcutError("Unknown browser shortcut.") }
    let value = try normalized(accelerator)
    let reserved = ["Mod+A", "Mod+C", "Mod+V", "Mod+X", "Mod+Z", "Mod+Shift+Z", "Mod+Shift+V", "Mod+H", "Mod+Alt+H", "Mod+Q", "Mod+Tab", "Mod+Shift+Tab", "Mod+M", "Mod+Alt+Shift+V", "Ctrl+Space", "Ctrl+F2", "Mod+Space", "Mod+Alt+Escape", "Mod+Shift+3", "Mod+Shift+4", "Mod+Shift+5", "Ctrl+H", "Alt+Backspace"]
    guard value.isEmpty || !reserved.contains(value) else { throw ShortcutError("That shortcut belongs to macOS or text editing. Choose another combination.") }
    let candidates = value == entry.accelerator ? [entry.accelerator] + entry.aliases : [value]
    let requested = Set(candidates.filter { !$0.isEmpty })
    if let conflict = catalog(overrides: overrides).first(where: { other in
      other.id != id && !requested.isDisjoint(with: [other.accelerator] + other.aliases)
    }) { throw ShortcutError("Already used by \(conflict.title). Change or disable that shortcut first.") }
    var result = overrides
    if value == entry.accelerator { result.removeValue(forKey: id) } else { result[id] = value }
    return result
  }
  public static func sanitized(_ raw: [String: String]) -> [String: String] {
    var result = Dictionary(uniqueKeysWithValues: defaults.filter { raw[$0.id] != nil }.map { ($0.id, "") })
    for entry in defaults {
      guard let value = raw[entry.id] else { continue }
      if let next = try? updating(result, id: entry.id, accelerator: value) { result = next }
      else { result.removeValue(forKey: entry.id) }
    }
    var seen = Set<String>()
    for entry in catalog(overrides: result) {
      let keys = Set(([entry.accelerator] + entry.aliases).filter { !$0.isEmpty })
      if !seen.isDisjoint(with: keys) { result[entry.id] = "" } else { seen.formUnion(keys) }
    }
    return result
  }
}
public struct ShortcutError: LocalizedError, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
