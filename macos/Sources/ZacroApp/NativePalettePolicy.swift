import Foundation

enum NativePalettePolicy {
  private static let aliases = [
    "preferences": "settings appearance theme search engine sidebar width",
    "command-palette": "new tab search open", "new-space": "create workspace",
    "new-private-space": "incognito private browsing", "shortcuts": "keyboard keybindings hotkeys edit",
    "onboarding": "welcome introduction tour help learn keyboard",
    "focus-sidebar": "keyboard focus tabs sidebar navigate", "reveal-tab": "show active current tab sidebar",
    "browser-menu": "menu browser controls options", "ai": "ask zacro assistant codex chatgpt",
    "split": "split view compare side by side", "bookmarks": "saved favorites library",
    "archive": "closed tabs restore", "save-page": "save as html download page", "copy-url": "copy link address"
  ]

  static func commandKeywords(id: String, additional: String = "") -> String {
    [id.replacingOccurrences(of: "-", with: " "), aliases[id] ?? "", additional]
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  static func askQuery(_ value: String, scope: String, configured: Bool, isPrivate: Bool, busy: Bool) -> String? {
    let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard scope == "all", configured, !isPrivate, !busy,
      !query.isEmpty, query.utf16.count <= 8_000 else { return nil }
    return query
  }

  /// The shortcut remains a toggle. Only its palette presentation changes to
  /// the explicit Unsplit action while the pair is visible.
  static func showsCommand(_ id: String, hasVisibleSplit: Bool) -> Bool {
    id != "split" || !hasVisibleSplit
  }
}
