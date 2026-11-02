import AppKit
import ZacroCore

/// Reads only this application's exact owned shell accessibility hierarchy.
/// It does not use AXUIElement, assistive permissions, or desktop input.
@MainActor enum NativeSidebarAccessibilityAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Sidebar accessibility requires the disposable loopback fixture.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let existing = Set(application.windows.keys)
    application.newWindow()
    guard let owner = application.focusedCoordinator, !existing.contains(owner.windowContext.id) else {
      throw ShortcutError("No sidebar accessibility fixture owner")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native sidebar accessibility check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Sidebar accessibility acceptance failed: " + name) }
      checks.append(name)
    }
    func waitForLabel(_ id: String, _ expected: String) async throws {
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        try Task.checkCancellation()
        if try label(in: owner.windowContext.window, identifier: "tab-activate:" + id) == expected { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("The favorite action did not expose its expected accessible name: " + expected)
    }
    do {
      owner.actions.palette = false
      guard let tab = owner.store.createTab(address: url.appendingPathComponent("sidebar-accessibility").absoluteString,
        activate: false) else { throw ShortcutError("No sidebar accessibility favorite") }
      owner.store.updateTab(tab.id) { $0.customTitle = "Accessible favorite" }
      owner.store.toggleFavorite(id: tab.id)
      try await waitForLabel(tab.id, "Accessible favorite — Sleeping")
      try require(application.engine.pages[tab.id] == nil, "favoriteActionHasItsOwnSleepingAccessibleName")

      owner.actions.activate(tab.id)
      guard let current = owner.store.tab(tab.id) else { throw ShortcutError("The favorite disappeared") }
      let page = try await owner.ensurePageReady(current)
      try await application.navigation.waitForRestore(page)
      try await waitForLabel(tab.id, "Accessible favorite — Loaded")
      try require(owner.actions.loadedTabIDs.contains(tab.id), "favoriteActionReportsActualLoadedState")

      guard await owner.requestCloseTab(tab.id) else { throw ShortcutError("The favorite did not close") }
      try await waitForLabel(tab.id, "Accessible favorite — Closed")
      try require(owner.store.tab(tab.id)?.isClosed == true, "favoriteActionNamesTheRetainedClosedTile")
      owner.store.updateTab(tab.id) { $0.customTitle = "Renamed favorite" }
      try await waitForLabel(tab.id, "Renamed favorite — Closed")
      try require(true, "favoriteActionAccessibleNameTracksRenaming")
      try require(await owner.requestCloseWindow(), "sidebarAccessibilityFixtureClosesCleanly")
      originalOwner.windowContext.show()
      return checks
    } catch {
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      throw error
    }
  }

  /// Identify the actionable Button itself, not an ancestor help string or
  /// favicon child. Chromium child windows are deliberately never traversed.
  static func label(in window: NSWindow, identifier: String) throws -> String? {
    guard let root = window.contentView else { return nil }
    root.layoutSubtreeIfNeeded()
    var pending: [NSObject] = [root]
    var visited = Set<ObjectIdentifier>()
    func value(_ object: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      guard object.responds(to: selector) else { return nil }
      return object.perform(selector)?.takeUnretainedValue()
    }
    while let item = pending.popLast() {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      guard visited.count <= 8_192 else { throw ShortcutError("The owned sidebar accessibility tree exceeded its fixture bound.") }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      if value(item, "accessibilityIdentifier") as? String == identifier,
        value(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue {
        return value(item, "accessibilityLabel") as? String ?? value(item, "accessibilityTitle") as? String
      }
      pending += value(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return nil
  }
}
