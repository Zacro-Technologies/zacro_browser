import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Actual native editing through the installed Edit menu and its equivalent,
/// with renderer/field-editor selection readback. All text belongs to owned
/// disposable controls; no clipboard contents or desktop events are changed.
@MainActor enum NativeEditingRuntimeAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      owner.windowContext.isOpen, !owner.windowContext.isClosing else {
      throw ShortcutError("Native editing acceptance requires the disposable loopback browser shell.")
    }
    let originalSelection = owner.store.state.activeTabID
    let originalKey = NSApp.keyWindow
    let text = "Owned native editing selection " + UUID().uuidString
    let literal = String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
    var tabID: String?
    var fieldWindow: NSWindow?
    var checks = [String](), failures = [String]()
    func record(_ passed: Bool, _ name: String) {
      fputs("Native editing check \(passed ? "PASS" : "FAIL"): \(name)\n", stderr)
      if passed { checks.append(name) } else { failures.append(name) }
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native editing acceptance timed out: " + phase)
    }
    func menuItem() throws -> (NSMenu, NSMenuItem) {
      func failure(_ message: String) -> ShortcutError {
        let roots = NSApp.mainMenu?.items.prefix(16).map {
          ["itemTitle": $0.title, "submenuTitle": $0.submenu?.title ?? "nil", "count": $0.submenu?.items.count ?? 0] as [String: Any]
        } ?? []
        let editItems = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu?.items.prefix(24).map {
          ["title": $0.title, "id": $0.representedObject as? String ?? "nil", "key": $0.keyEquivalent,
            "modifiers": $0.keyEquivalentModifierMask.rawValue, "enabled": $0.isEnabled,
            "target": $0.target.map { String(reflecting: type(of: $0)) } ?? "nil",
            "action": $0.action.map(NSStringFromSelector) ?? "nil"] as [String: Any]
        } ?? []
        let details: [String: Any] = ["reason": message, "menus": roots, "editItems": editItems,
          "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
          "responder": NSApp.keyWindow?.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil"]
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
          let description = String(data: data, encoding: .utf8) { fputs("Native editing installed menu: \(description)\n", stderr) }
        return ShortcutError(message)
      }
      // The menu-bar parent item can have an empty title; AppKit draws the
      // attached menu's title. Identify the actual named submenu, then retain
      // the exact command-ID, target, selector and equivalent assertions.
      guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu,
        let item = menu.items.first(where: { $0.representedObject as? String == "edit:select-all" }),
        item.target == nil, item.action == NativeEditingMenu.action(for: "select-all"),
        item.keyEquivalent == "a", item.keyEquivalentModifierMask == .command else {
        throw failure("The installed Edit menu does not retain its native first-responder Select All action and equivalent.")
      }
      menu.update()
      guard item.isEnabled else { throw failure("The real first responder did not validate the Select All menu item.") }
      return (menu, item)
    }
    func keyEquivalent(window: NSWindow) -> NSEvent? {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
    }
    func cleanup() async throws {
      fieldWindow?.close(); fieldWindow = nil
      if let tabID, owner.store.tab(tabID)?.isClosed == false,
        !(await owner.requestCloseTab(tabID)) {
        throw ShortcutError("The exact owned editing fixture document did not accept normal closure.")
      }
      if let originalSelection, owner.store.tab(originalSelection)?.isClosed == false {
        owner.store.selectTab(id: originalSelection)
      }
      owner.scheduleLayout()
      if let originalKey, originalKey.isVisible { originalKey.makeKeyAndOrderFront(nil) }
    }
    do {
      let address = url.appendingPathComponent("native-history-form")
      guard let tab = owner.store.createTab(address: address.absoluteString) else {
        throw ShortcutError("No exact owned native editing fixture tab could be created.")
      }
      tabID = tab.id
      let page = try await owner.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready()
      try await wait("owned renderer editing control") {
        guard !page.isLoading, page.url == address, page.documentError == nil else { return false }
        return try await browser.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      func prepareRenderer() async throws {
        page.focus()
        _ = try await browser.devTools.evaluate("""
          (() => { const input=document.getElementById('retained');
            input.style.cssText='display:block;position:fixed;left:24px;top:24px;width:420px;height:80px';
            input.value=\(literal);input.defaultValue=\(literal);input.focus();input.setSelectionRange(0,0); })()
          """)
        try await wait("actual focused native renderer input") {
          guard page.nativeWindow?.isKeyWindow == true, owner.activePage === page else { return false }
          return try await browser.devTools.evaluate("document.hasFocus() && document.activeElement?.id==='retained'") as? Bool == true
        }
      }
      func rendererSelection(_ phase: String, dispatched: Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        var state = [String: Any]()
        var passed = false
        while Date() < deadline {
          state = try await browser.devTools.evaluate("""
            (() => {const input=document.getElementById('retained');return {
              focused:document.hasFocus()&&document.activeElement===input,
              start:input.selectionStart,end:input.selectionEnd,value:input.value};})()
            """) as? [String: Any] ?? [:]
          passed = dispatched && state["focused"] as? Bool == true && state["start"] as? Int == 0
            && state["end"] as? Int == text.utf16.count && state["value"] as? String == text
          if passed { break }
          try await Task.sleep(for: .milliseconds(30))
        }
        let diagnostic: [String: Any] = ["phase": phase, "dispatched": dispatched,
          "browserID": browser.id, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
          "nativeWindow": page.nativeWindow?.windowNumber ?? -1,
          "mainWindow": NSApp.mainWindow?.windowNumber ?? -1,
          "responder": NSApp.keyWindow?.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil",
          "nativeTarget": NativeEditingMenu.action(for: "select-all").flatMap { NSApp.target(forAction: $0) }
            .map { String(reflecting: type(of: $0)) } ?? "nil", "selection": state]
        if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
          let description = String(data: bytes, encoding: .utf8) { fputs("Native editing renderer: \(description)\n", stderr) }
        record(passed, phase)
      }

      try await prepareRenderer()
      let nativeStyle = NativeEditingMenu.matchStyleTarget()
      record(nativeStyle?.action == NSSelectorFromString("pasteAndMatchStyle:")
        && (nativeStyle?.target as? NSView)?.window === page.nativeWindow,
        "editingMatchStyleResolvesActualChromiumNativeResponderWithoutClipboardAccess")
      let (_, installed) = try menuItem()
      record(installed.target == nil, "editingInstalledMenuUsesNativeResponderAndRetainsCommandEquivalent")
      if let action = installed.action {
        let dispatched = NSApp.sendAction(action, to: installed.target, from: installed)
        try await rendererSelection("editingMenuSelectAllSelectsActualChromiumInput", dispatched: dispatched)
      }
      try await prepareRenderer()
      let (edit, _) = try menuItem()
      let equivalent = page.nativeWindow.flatMap(keyEquivalent)
      let dispatchedEquivalent = equivalent.map { edit.performKeyEquivalent(with: $0) } ?? false
      try await rendererSelection("editingCommandEquivalentSelectsActualChromiumInput", dispatched: dispatchedEquivalent)
      try await prepareRenderer()
      browser.selectAll()
      try await rendererSelection("editingNativeFrameCommandSelectsItsActualFocusedInput", dispatched: true)

      try await prepareRenderer()
      let nativeFieldWindow = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 440, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
      nativeFieldWindow.isReleasedWhenClosed = false
      fieldWindow = nativeFieldWindow
      let field = NSTextField(frame: NSRect(x: 20, y: 30, width: 400, height: 28))
      field.stringValue = text; nativeFieldWindow.contentView?.addSubview(field)
      nativeFieldWindow.makeKeyAndOrderFront(nil)
      guard nativeFieldWindow.makeFirstResponder(field),
        let editor = field.currentEditor() as? NSTextView else {
        throw ShortcutError("The exact owned native text field did not acquire its real field editor.")
      }
      editor.setSelectedRange(NSRange(location: 0, length: 0))
      let fieldStyle = NativeEditingMenu.matchStyleTarget()
      record(fieldStyle?.target === editor && fieldStyle?.action == NSSelectorFromString("pasteAsPlainText:"),
        "editingMatchStyleResolvesActualNativeFieldEditorWithoutClipboardAccess")
      let (_, fieldItem) = try menuItem()
      let fieldDispatched = fieldItem.action.map { NSApp.sendAction($0, to: fieldItem.target, from: fieldItem) } ?? false
      record(fieldDispatched && editor.selectedRange() == NSRange(location: 0, length: text.utf16.count)
        && field.stringValue == text, "editingMenuSelectAllTargetsActualNativeTextField")
      editor.setSelectedRange(NSRange(location: 0, length: 0))
      let fieldEquivalent = keyEquivalent(window: nativeFieldWindow)
      let fieldMenu = try menuItem().0
      let fieldKeyDispatched = fieldEquivalent.map { fieldMenu.performKeyEquivalent(with: $0) } ?? false
      record(fieldKeyDispatched && editor.selectedRange() == NSRange(location: 0, length: text.utf16.count)
        && field.stringValue == text, "editingCommandEquivalentTargetsActualNativeTextField")
      let untouched = try await browser.devTools.evaluate("""
        (() => { const input=document.getElementById('retained');return input.value===\(literal)
          && input.selectionStart===0 && input.selectionEnd===0; })()
        """) as? Bool
      record(untouched == true, "editingNativeTextFieldDoesNotSelectOrChangeUnderlyingPage")
      try await cleanup()
      if !failures.isEmpty { throw ShortcutError("Native editing checks failed: " + failures.joined(separator: ", ")) }
      return checks
    } catch {
      let failure = error
      let task = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native editing fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await task.value
      throw failure
    }
  }
}
