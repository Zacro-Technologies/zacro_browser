import AppKit
import ZacroCore

/// Reads focused state from this application's exact owned shell AX tree.
/// It sends no desktop input and never traverses a hosted Chromium window.
@MainActor enum NativeSidebarFocusAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Sidebar focus requires the disposable loopback fixture.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let previous = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !previous.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else {
      throw ShortcutError("No exact new sidebar focus fixture owner")
    }
    let window = owner.windowContext.window
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native sidebar focus check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Sidebar focus acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ description: String, until predicate: () throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing else { throw CancellationError() }
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Sidebar focus did not reach " + description)
    }
    func focus(_ identifier: String) async throws {
      diagnostics("before-command", identifier: identifier)
      owner.runCommand("focus-sidebar")
      diagnostics("after-command", identifier: identifier)
      var samples = 0
      do {
        try await wait("the focused actionable button " + identifier) {
          samples += 1
          if [1, 4, 13, 26, 51, 126].contains(samples) { diagnostics("waiting-\(samples)", identifier: identifier) }
          let state = try button(in: window, identifier: identifier)
          return window.isKeyWindow && state?.focused == true
        }
        diagnostics("focused", identifier: identifier)
      } catch {
        diagnostics("failed: " + error.localizedDescription, identifier: identifier)
        throw error
      }
    }
    func diagnostics(_ phase: String, identifier: String) {
      let responder = window.firstResponder
      var details: [String: Any] = [
        "phase": phase, "requestedIdentifier": identifier,
        "windowID": owner.windowContext.id, "windowNumber": window.windowNumber,
        "ownerOpen": owner.windowContext.isOpen, "ownerClosing": owner.windowContext.isClosing,
        "appActive": NSApp.isActive, "windowKey": window.isKeyWindow, "windowMain": window.isMainWindow,
        "fullKeyboardAccess": NSApp.isFullKeyboardAccessEnabled,
        "windowVisible": window.isVisible, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
        "keyIdentifier": NSApp.keyWindow?.identifier?.rawValue ?? "nil",
        "windowResponder": responder.map { String(reflecting: type(of: $0)) } ?? "nil",
        "responderAcceptsFirstResponder": responder?.acceptsFirstResponder == true,
        "keyResponder": (NSApp.keyWindow?.firstResponder).map { String(reflecting: type(of: $0)) } ?? "nil",
        "firstResponderViewOwned": (responder as? NSView)?.window === window,
        "palette": owner.actions.palette, "library": owner.actions.library ?? "nil",
        "activeTabID": owner.store.state.activeTabID ?? "nil",
        "selectedDocumentID": owner.selectedDocumentID ?? "nil",
        "sheet": window.attachedSheet?.identifier?.rawValue ?? "nil",
        "children": (window.childWindows ?? []).prefix(16).map {
          ["number": $0.windowNumber, "identifier": $0.identifier?.rawValue ?? "nil", "visible": $0.isVisible] as [String: Any]
        },
        "presentation": owner.actions.interfacePresentationState().sorted(),
      ]
      do { details["accessibility"] = try focusSnapshot(in: window, identifier: identifier) }
      catch { details["accessibilityError"] = error.localizedDescription }
      if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native sidebar focus diagnostics: \(text)\n", stderr) }
    }
    func cleanup() async {
      if owner.windowContext.isOpen { _ = await owner.requestCloseWindow() }
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
    }
    do {
      guard let row = owner.store.createTab(address: url.appendingPathComponent("sidebar-focus").absoluteString,
        activate: false), let blank = owner.store.createTab(address: "about:blank") else {
        throw ShortcutError("The sidebar focus fixture tabs could not be created")
      }
      // Consume the real ordinary-blank palette presentation. Dismissing it
      // before this callback runs would leave a queued presentation stealing
      // the focus being measured.
      try await wait("the ordinary blank palette") { owner.actions.palette }
      owner.actions.palette = false
      try await wait("palette dismissal and the visible fallback row") {
        let rowButton = try button(in: window, identifier: "tab-activate:" + row.id)
        let paletteVisible = (window.childWindows ?? []).contains {
          $0.identifier?.rawValue == "ZacroBrowserControls" && $0.isVisible
        }
        return !owner.actions.palette && !paletteVisible && rowButton != nil
      }
      let blankButton = try button(in: window, identifier: "tab-activate:" + blank.id)
      try require(owner.store.tab(blank.id)?.homePage != true
        && owner.store.state.activeTabID == blank.id && blankButton == nil,
        "sidebarFocusOrdinaryBlankHasNoRenderedTabRow")
      try await focus("tab-activate:" + row.id)
      try require(owner.store.state.activeTabID == blank.id,
        "sidebarFocusBlankChoosesVisibleRowWithoutSelectingIt")

      let group = try owner.store.groupTabs([row.id])
      try owner.store.updateTabGroup(group.id, title: "Collapsed focus fixture", collapsed: true)
      owner.store.selectTab(id: row.id)
      guard let current = owner.store.tab(row.id) else { throw ShortcutError("The grouped tab disappeared") }
      let page = try await owner.ensurePageReady(current)
      try await application.navigation.waitForRestore(page)
      try await wait("the collapsed group heading without its member row") {
        let heading = try button(in: window, identifier: "tab-group:" + group.id)
        let member = try button(in: window, identifier: "tab-activate:" + row.id)
        return heading != nil && member == nil
      }
      try await focus("tab-group:" + group.id)
      try require(owner.store.state.activeTabID == row.id
        && owner.store.state.tabGroups.first(where: { $0.id == group.id })?.collapsed == true,
        "sidebarFocusCollapsedMemberChoosesHeadingWithoutExpandingOrSelecting")

      owner.store.selectTab(id: blank.id)
      guard await owner.requestCloseTab(row.id) else { throw ShortcutError("The sidebar focus row did not close") }
      try await wait("the empty sidebar Space picker") {
        let rowButton = try button(in: window, identifier: "tab-activate:" + row.id)
        let picker = try button(in: window, identifier: "space-picker")
        return !owner.actions.palette && owner.store.state.tabGroups.isEmpty && rowButton == nil && picker != nil
      }
      try await focus("space-picker")
      try require(owner.store.state.activeTabID == blank.id && owner.store.tab(blank.id)?.url == "about:blank",
        "sidebarFocusEmptySidebarChoosesActualSpacePicker")
      try require(await owner.requestCloseWindow(), "sidebarFocusFixtureClosesCleanly")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }

  private struct ButtonState { let focused: Bool }

  private static func focusSnapshot(in window: NSWindow, identifier: String) throws -> [String: Any] {
    guard let root = window.contentView else { return ["missingContentView": true] }
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
    var matches: [[String: Any]] = [], focused: [[String: Any]] = []
    func object(_ value: NSObject, _ name: String) -> Any? {
      guard value.responds(to: NSSelectorFromString(name)) else { return nil }
      return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    while let item = pending.popLast() {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      guard visited.count <= 8_192 else { throw ShortcutError("Owned focus diagnostics exceeded the AX traversal bound") }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      let itemID = object(item, "accessibilityIdentifier") as? String
      let canReadFocus = item.responds(to: NSSelectorFromString("isAccessibilityFocused"))
      let isFocused = canReadFocus ? (item.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue : nil
      if itemID == identifier || isFocused == true {
        let value: [String: Any] = [
          "identifier": itemID ?? "nil", "role": object(item, "accessibilityRole") as? String ?? "nil",
          "type": String(reflecting: type(of: item)), "canReadFocus": canReadFocus,
          "focused": isFocused ?? false,
        ]
        if itemID == identifier, matches.count < 16 { matches.append(value) }
        if isFocused == true, focused.count < 32 { focused.append(value) }
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return ["visited": visited.count, "matches": matches, "focusedElements": focused]
  }

  /// isAccessibilityFocused returns BOOL, so use KVC's boxed primitive result;
  /// NSObject.perform is appropriate only for the object-returning getters.
  private static func button(in window: NSWindow, identifier: String) throws -> ButtonState? {
    guard let root = window.contentView else { return nil }
    root.layoutSubtreeIfNeeded()
    var pending: [NSObject] = [root]
    var visited = Set<ObjectIdentifier>()
    func object(_ value: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      guard value.responds(to: selector) else { return nil }
      return value.perform(selector)?.takeUnretainedValue()
    }
    while let item = pending.popLast() {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      guard visited.count <= 8_192 else { throw ShortcutError("The owned sidebar focus AX tree exceeded its fixture bound.") }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      if object(item, "accessibilityIdentifier") as? String == identifier,
        object(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue {
        guard item.responds(to: NSSelectorFromString("isAccessibilityFocused")),
          let focused = item.value(forKey: "accessibilityFocused") as? NSNumber else {
          throw ShortcutError("The exact sidebar Button does not expose focused AX state: " + identifier)
        }
        return ButtonState(focused: focused.boolValue)
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return nil
  }
}
