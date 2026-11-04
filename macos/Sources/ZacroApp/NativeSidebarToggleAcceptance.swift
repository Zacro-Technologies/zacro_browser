import AppKit
import ZacroChromium
import ZacroCore

/// Exact owned shell commands and document/AX reads. No desktop input is sent.
/// Explicit document-origin command calls test the admitted root/UI handoff;
/// physical keyboard routing remains a separate acceptance gate.
@MainActor enum NativeSidebarToggleAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Sidebar toggle requires the disposable loopback fixture.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let existing = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !existing.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else {
      throw ShortcutError("No exact new sidebar-toggle fixture owner")
    }
    let window = owner.windowContext.window
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native sidebar toggle check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Sidebar-toggle acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing else { throw CancellationError() }
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      let diagnostic: [String: Any] = [
        "phase": phase, "ownerID": owner.windowContext.id,
        "sidebarPreference": owner.store.state.settings.sidebarVisible,
        "contentX": owner.actions.contentFrame.minX,
        "appActive": NSApp.isActive, "ownerMain": window.isMainWindow, "ownerKey": window.isKeyWindow,
        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
        "mainWindow": NSApp.mainWindow?.windowNumber ?? -1,
        "ownerWindow": window.windowNumber,
        "palette": owner.actions.palette,
        "paletteWindow": owner.actions.paletteWindow?.windowNumber ?? -1,
        "paletteVisible": owner.actions.paletteWindow?.isVisible == true,
        "menuWindow": owner.actions.browserMenuWindow?.windowNumber ?? -1,
        "nativeWindow": owner.activePage?.nativeWindow?.windowNumber ?? -1,
        "nativeVisible": owner.activePage?.nativeWindow?.isVisible == true,
        "nativeKey": owner.activePage?.nativeWindow?.isKeyWindow == true,
        "presentation": owner.actions.interfacePresentationState().sorted(),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native sidebar toggle timeout: \(text)\n", stderr) }
      throw ShortcutError("Sidebar-toggle acceptance timed out: " + phase)
    }
    func cleanup() async {
      if owner.windowContext.isOpen { _ = await owner.requestCloseWindow() }
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
    }
    do {
      owner.actions.palette = false; owner.actions.library = nil
      owner.store.updateSettings { $0.sidebarVisible = true }
      guard let tab = owner.store.createTab(address: url.appendingPathComponent("sidebar-toggle").absoluteString) else {
        throw ShortcutError("The sidebar-toggle document could not be created")
      }
      let page = try await owner.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready()
      try await wait("exact visible loaded document") {
        owner.activePage === page && page.browser === browser && page.nativeWindow?.isVisible == true
          && !page.isLoading && !owner.actions.palette && owner.actions.contentFrame.minX > 180
      }
      func pageFocused() async throws -> Bool {
        guard owner.activePage === page, page.browser === browser, page.nativeWindow?.isVisible == true else { return false }
        return try await browser.devTools.evaluate("document.hasFocus()") as? Bool == true
      }
      func focusPage() async throws {
        page.focus()
        try await wait("native document focus", pageFocused)
      }
      try await focusPage()
      owner.runCommand("sidebar-toggle", fromPage: true)
      try await wait("hidden rail with document focus") {
        guard !owner.store.state.settings.sidebarVisible, owner.actions.contentFrame.minX < 20 else { return false }
        return try await pageFocused()
      }
      try require(owner.store.state.activeTabID == tab.id,
        "sidebarGuestHidePreservesSelectedNativeDocumentFocus")

      // Menu/palette origin remains false even while this page is key.
      owner.runCommand("sidebar-toggle")
      try await wait("menu shows rail and focuses actual address Button") {
        guard owner.store.state.settings.sidebarVisible, owner.actions.contentFrame.minX > 180,
          window.isKeyWindow else { return false }
        return try addressFocused(in: window)
      }
      try require(owner.activePage === page && page.browser === browser,
        "sidebarMenuShowUsesAddressFocusDespitePreviouslyKeyPage")

      try await focusPage()
      owner.runCommand("sidebar-toggle", fromPage: true)
      try await wait("guest hide before guest show") { !owner.store.state.settings.sidebarVisible }
      owner.runCommand("sidebar-toggle", fromPage: true)
      try await wait("guest show retains document focus") {
        guard owner.store.state.settings.sidebarVisible, owner.actions.contentFrame.minX > 180 else { return false }
        return try await pageFocused()
      }
      try require(page.nativeWindow?.isKeyWindow == true && !window.isKeyWindow,
        "sidebarGuestShowIsNotOverriddenByGenericParentActivation")

      owner.actions.openPalette()
      try await wait("real owned palette") { owner.actions.paletteWindow?.isVisible == true && owner.actions.palette }
      owner.runCommand("sidebar-toggle")
      try await wait("palette dismissal then page focus") {
        guard !owner.actions.palette, owner.actions.paletteWindow == nil,
          !owner.store.state.settings.sidebarVisible else { return false }
        return try await pageFocused()
      }
      try require(!owner.actions.interfacePresentationState().contains("palette"),
        "sidebarToggleClosesPaletteBeforeRestoringDocumentFocus")

      _ = owner.actions.performInterfaceCommand("browser-menu")
      try await wait("real hidden-rail browser menu") { owner.actions.browserMenuWindow?.isVisible == true }
      owner.runCommand("sidebar-toggle")
      try await wait("hidden-rail menu dismissal then address focus") {
        guard owner.actions.browserMenuWindow == nil, owner.store.state.settings.sidebarVisible,
          window.isKeyWindow else { return false }
        return try addressFocused(in: window)
      }
      try require(!owner.actions.interfacePresentationState().contains("browser-menu"),
        "sidebarToggleClosesFloatingMenuWithoutLateFocusRestoration")

      // This width causes Library alone to suppress an explicitly visible
      // rail. The command must close Library without flipping the preference.
      window.setContentSize(NSSize(width: 640, height: 700))
      owner.actions.library = "bookmarks"
      try await wait("Library compresses the visible rail") {
        owner.actions.library == "bookmarks" && owner.store.state.settings.sidebarVisible
          && owner.actions.contentFrame.minX < 20
      }
      owner.runCommand("sidebar-toggle")
      try await wait("compact Library closes and rail returns") {
        owner.actions.library == nil && owner.store.state.settings.sidebarVisible
          && owner.actions.contentFrame.minX > 180
      }
      try require(owner.activePage === page && owner.store.state.activeTabID == tab.id,
        "sidebarCompactLibraryTogglePreservesExplicitRailPreferenceAndSelection")
      try require(await owner.requestCloseWindow(), "sidebarToggleFixtureClosesCleanly")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }

  private static func addressFocused(in window: NSWindow) throws -> Bool {
    guard let root = window.contentView else { return false }
    root.layoutSubtreeIfNeeded()
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
    func object(_ value: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      guard value.responds(to: selector) else { return nil }
      return value.perform(selector)?.takeUnretainedValue()
    }
    while let item = pending.popLast() {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      guard visited.count <= 8_192 else { throw ShortcutError("The sidebar-toggle AX tree exceeded its fixture bound") }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      if object(item, "accessibilityLabel") as? String == "Edit address or search",
        object(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
        item.responds(to: NSSelectorFromString("isAccessibilityFocused")),
        let focused = item.value(forKey: "accessibilityFocused") as? NSNumber {
        return focused.boolValue
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return false
  }
}
