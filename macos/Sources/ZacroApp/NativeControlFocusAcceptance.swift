import AppKit
import SwiftUI
import ZacroCore

/// Hosts the actual browser surfaces in an existing owned fixture window.
/// Local AppKit key delivery exercises their real SwiftUI handlers; no desktop
/// event, accessibility permission, OS setting change or Chromium page is used.
@MainActor enum NativeControlFocusAcceptance {
  static func check(in window: NSWindow) async -> [String: Bool] {
    let previousContent = window.contentView
    let previousKey = NSApp.keyWindow
    let previouslyVisible = window.isVisible
    let keyboardNavigation = NSApp.isFullKeyboardAccessEnabled
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zacro-control-focus-" + UUID().uuidString, isDirectory: true)
    var result = [String: Bool]()
    var activations = 0
    defer {
      window.contentView = previousContent
      if !previouslyVisible { window.orderOut(nil) }
      if let previousKey, previousKey !== window, previousKey.isVisible { previousKey.makeKeyAndOrderFront(nil) }
      try? FileManager.default.removeItem(at: root)
    }
    func host<Content: View>(_ content: Content, size: CGSize) async {
      window.setContentSize(size)
      let view = NSHostingView(rootView: content)
      view.sizingOptions = []; view.frame = CGRect(origin: .zero, size: size)
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      for _ in 0..<8 {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(12))
      }
    }
    func keyDown() -> Bool {
      guard window.isKeyWindow, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
        charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) else { return false }
      window.sendEvent(event)
      return true
    }
    func waitForElement(_ identifier: String, role: NSAccessibility.Role = .button) async -> Bool {
      let deadline = Date().addingTimeInterval(3)
      while Date() < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        if window.isKeyWindow && focusedElement(in: window, identifier: identifier, role: role) { return true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      fputs("Native control focus diagnostics: target=\(identifier) role=\(role.rawValue) key=\(window.isKeyWindow) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled) responder=\(window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil") AX=\(focusDiagnostics(in: window))\n", stderr)
      return false
    }

    var site = SiteControlActions()
    site.url = URL(string: "https://example.invalid/owned-control-focus")
    site.extensionsReady = true
    site.bookmark = { activations += 1 }
    await host(SiteControls(actions: site, maximumHeight: 640), size: CGSize(width: 304, height: 640))
    result["siteControlsInitialActionHasActualFocusedButtonWithoutSystemKeyboardNavigation"] =
      await waitForElement("native-site-control:copy")
    let siteDown = keyDown()
    let siteStarFocused = await waitForElement("native-site-control:star")
    result["siteControlsArrowMovesActualFocusWithoutActivatingAction"] = siteDown
      && siteStarFocused && activations == 0

    let colors = NativeSpacePalette(theme: SpaceTheme(), dark: false)
    let items = [
      NativeMenuAction(id: "disabled", title: "Unavailable owned action", glyph: "copy", enabled: false, action: { activations += 1 }),
      NativeMenuAction(id: "first", title: "First owned action", glyph: "copy", action: { activations += 1 }),
      NativeMenuAction(id: "second", title: "Second owned action", glyph: "star", action: { activations += 1 }),
    ]
    await host(NativeActionPopover(title: "Owned browser actions", items: items, colors: colors),
      size: CGSize(width: 242, height: 130))
    result["browserActionMenuSkipsDisabledActionAndFocusesActualButton"] =
      await waitForElement("native-menu-action:first")
    let menuDown = keyDown()
    let secondMenuFocused = await waitForElement("native-menu-action:second")
    result["browserActionMenuArrowMovesActualFocusWithoutActivation"] = menuDown
      && secondMenuFocused && activations == 0

    var state = BrowserState()
    let profile = state.profiles[0], space = state.spaces[0]
    let openID = UUID().uuidString, closedID = UUID().uuidString
    let open = BrowserWindowSession(id: openID, activeSpaceID: space.id)
    var closed = BrowserWindowSession(id: closedID, activeSpaceID: space.id)
    closed.isOpen = false; closed.closedAt = Date()
    var saved = BrowserTab(spaceID: space.id, url: "https://example.invalid/owned-saved-window", title: "Owned saved window")
    saved.windowID = closedID; closed.activeTabID = saved.id
    state.tabs = [saved]; state.activeTabID = nil
    state.windowSessions = [open, closed]; state.focusedWindowID = openID
    let historyID = UUID().uuidString
    state.history = [HistoryEntry(id: historyID, profileID: profile.id,
      url: "https://example.invalid/owned-history", title: "Owned history entry")]
    let repository = BrowserRepository(directory: root, initialState: state)
    guard let store = repository.store(for: openID) else {
      result["libraryFocusFixtureHasExactOwnedCoreWindow"] = false
      return result
    }
    let actions = BrowserActions()
    actions.newTab = { _ in activations += 1 }
    actions.libraryCapabilities = ["window:restore"]
    actions.performLibraryAction = { _, _ in activations += 1 }
    actions.library = "History"
    await host(NativeLibrary(store: store, actions: actions, section: "History"),
      size: CGSize(width: 336, height: 420))
    let historySearchFocused = await waitForElement("native-library-search", role: .textField)
    let historyDown = keyDown()
    let historyFocused = await waitForElement("native-library-row:" + historyID)
    result["librarySearchArrowFocusesActualHistoryActionWithoutOpeningIt"] = historySearchFocused && historyDown
      && historyFocused && activations == 0
    result["libraryFocusFixtureRetainsRealClosedWindowAndItsOwnedTab"] =
      repository.savedWindows.contains { $0.id == closedID && $0.tabCount == 1 }
      && repository.canonicalStore.tab(saved.id)?.windowID == closedID
      && repository.windows.first(where: { $0.id == closedID })?.isOpen == false
    // Switch the actual existing Library through its production observed
    // command. Replacing its host in the middle of this focus transaction
    // would race the retiring text field against the new host's onAppear.
    actions.library = "Windows"
    let windowsSearchFocused = await waitForElement("native-library-search", role: .textField)
    let windowsDown = keyDown()
    let savedWindowFocused = await waitForElement("native-library-window:" + closedID)
    result["librarySearchArrowFocusesActualSavedWindowWithoutReopeningIt"] = windowsSearchFocused && windowsDown
      && savedWindowFocused && activations == 0
      && repository.windows.first(where: { $0.id == closedID })?.isOpen == false
    result["browserControlFocusPreservesSystemKeyboardNavigationPreference"] =
      keyboardNavigation == NSApp.isFullKeyboardAccessEnabled
    return result
  }

  private static func focusedElement(in window: NSWindow, identifier: String, role: NSAccessibility.Role) -> Bool {
    guard let root = window.contentView else { return false }
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
    func object(_ value: NSObject, _ name: String) -> Any? {
      guard value.responds(to: NSSelectorFromString(name)) else { return nil }
      return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    while let item = pending.popLast(), visited.count <= 8_192 {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      if object(item, "accessibilityIdentifier") as? String == identifier,
        object(item, "accessibilityRole") as? String == role.rawValue {
        return item.responds(to: NSSelectorFromString("isAccessibilityFocused"))
          && (item.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue == true
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return false
  }

  private static func focusDiagnostics(in window: NSWindow) -> [[String: String]] {
    guard let root = window.contentView else { return [] }
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), result = [[String: String]]()
    func object(_ value: NSObject, _ name: String) -> Any? {
      guard value.responds(to: NSSelectorFromString(name)) else { return nil }
      return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    while let item = pending.popLast(), visited.count <= 8_192, result.count < 24 {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      let identifier = object(item, "accessibilityIdentifier") as? String
      let focused = item.responds(to: NSSelectorFromString("isAccessibilityFocused"))
        && (item.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue == true
      if identifier?.hasPrefix("native-") == true || focused {
        result.append(["id": identifier ?? "nil", "role": object(item, "accessibilityRole") as? String ?? "nil",
          "label": object(item, "accessibilityLabel") as? String ?? "nil", "focused": String(focused)])
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return result
  }
}
