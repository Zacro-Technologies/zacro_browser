import AppKit
import ZacroChromium

/// Actual AppKit key/main ownership checks, separate from physical input.
@MainActor
enum NativeBrowserFocusFamilyAcceptance {
  static func run(application: ApplicationCoordinator, owner: BrowserWindowCoordinator,
    page: ChromiumPage) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      application.engine.pages[page.id] === page, page.ownerWindowID == owner.windowContext.id,
      page.url?.host == "127.0.0.1" else { throw Failure("Missing exact disposable browser family") }
    let shell = owner.windowContext.window
    var checks = [String]()
    var eventNumber = 0
    var sheetTask: Task<NSApplication.ModalResponse, Never>?
    var otherOwner: BrowserWindowCoordinator?
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw Failure(name) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while ProcessInfo.processInfo.systemUptime < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, owner.window === shell else { throw Failure("Original owner changed") }
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw Failure(name + ": key=\(NSApp.keyWindow?.windowNumber ?? -1) main=\(NSApp.mainWindow?.windowNumber ?? -1) shell=\(shell.windowNumber) active=\(NSApp.isActive)")
    }
    func isWithin(_ candidate: NSWindow?, _ ancestor: NSWindow) -> Bool {
      var current = candidate, visited = Set<ObjectIdentifier>()
      while let next = current, visited.insert(ObjectIdentifier(next)).inserted {
        if next === ancestor { return true }
        current = next.sheetParent ?? next.parent
      }
      return false
    }
    func receipt(_ stage: String, expectedKey: NSWindow?, responder: NSResponder?, pageFocused: Bool?) {
      fputs("Native browser focus-family: stage=\(stage) appActive=\(NSApp.isActive) shell=\(shell.windowNumber) shellKey=\(shell.isKeyWindow) shellMain=\(shell.isMainWindow) actualKey=\(NSApp.keyWindow?.windowNumber ?? -1) actualMain=\(NSApp.mainWindow?.windowNumber ?? -1) expectedKey=\(expectedKey?.windowNumber ?? -1) keyUnchanged=\(NSApp.keyWindow === expectedKey) responderUnchanged=\(expectedKey?.firstResponder === responder) responder=\((expectedKey?.firstResponder).map { String(reflecting: type(of: $0)) } ?? "nil") documentWindow=\(page.nativeWindow?.windowNumber ?? -1) documentKey=\(page.nativeWindow?.isKeyWindow == true) documentMain=\(page.nativeWindow?.isMainWindow == true) documentHasFocus=\(String(describing: pageFocused))\n", stderr)
    }
    func browserButtonFrame(label: String) throws -> NSRect? {
      guard let root = shell.contentView else { return nil }
      var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), frames = [NSRect]()
      func value(_ item: NSObject, _ selector: String) -> Any? {
        let method = NSSelectorFromString(selector)
        guard item.responds(to: method) else { return nil }
        return item.perform(method)?.takeUnretainedValue()
      }
      while let item = pending.popLast() {
        guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
        guard visited.count <= 8_192 else { throw Failure("Owned address accessibility tree exceeded its bound") }
        if item is NSWindow { continue }
        if let view = item as? NSView, view.window !== shell { continue }
        if value(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
          value(item, "accessibilityLabel") as? String == label,
          item.responds(to: NSSelectorFromString("accessibilityFrame")),
          let boxed = item.value(forKey: "accessibilityFrame") as? NSValue {
          let frame = boxed.rectValue
          if frame.width > 10, frame.height > 10, shell.frame.intersects(frame) { frames.append(frame) }
        }
        pending += value(item, "accessibilityChildren") as? [NSObject] ?? []
      }
      return frames.count == 1 ? frames[0] : nil
    }
    func selectedSidebarButtonIsFocused() throws -> Bool {
      guard let root = shell.contentView else { return false }
      var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
      func value(_ item: NSObject, _ selector: String) -> Any? {
        let method = NSSelectorFromString(selector)
        guard item.responds(to: method) else { return nil }
        return item.perform(method)?.takeUnretainedValue()
      }
      while let item = pending.popLast() {
        guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
        guard visited.count <= 8_192 else { throw Failure("Owned sidebar focus accessibility tree exceeded its bound") }
        if item is NSWindow { continue }
        if let view = item as? NSView, view.window !== shell { continue }
        if value(item, "accessibilityIdentifier") as? String == "tab-activate:" + page.id,
          value(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
          item.responds(to: NSSelectorFromString("isAccessibilityFocused")) {
          return (item.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue == true
        }
        pending += value(item, "accessibilityChildren") as? [NSObject] ?? []
      }
      return false
    }
    func clickBrowserControlOnce(_ frame: NSRect, label: String, firstMouseCheck: String,
      requiresDocumentKey: Bool = true) throws {
      guard let root = shell.contentView, let document = page.nativeWindow,
        NSApp.isActive, !owner.actions.palette else { throw Failure("Browser control click lost its actual owned starting state") }
      let actualStartingFocus = requiresDocumentKey
        ? NSApp.keyWindow === document && document.isKeyWindow && !shell.isKeyWindow
        : NSApp.keyWindow === shell && shell.isKeyWindow && !document.isKeyWindow
      guard actualStartingFocus else { throw Failure("Browser control click lost its exact starting focus: " + label) }
      let point = shell.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
      let rootPoint = root.superview?.convert(point, from: nil) ?? point
      guard let hit = root.hitTest(rootPoint), hit.window === shell else { throw Failure("No actual owned address hit") }
      for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: eventType, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shell.windowNumber, context: nil,
          eventNumber: eventNumber, clickCount: 1, pressure: eventType == .leftMouseDown ? 1 : 0),
          event.window === shell else { throw Failure("Owned address mouse event did not preserve its window") }
        if eventType == .leftMouseDown {
          let accepts = hit.acceptsFirstMouse(for: event)
          fputs("Native browser focus-family first-click: hit=\(String(reflecting: type(of: hit))) root=\(String(reflecting: type(of: root))) point=\(point) acceptsFirstMouse=\(accepts) originalDocumentKey=\(document.isKeyWindow) shellKey=\(shell.isKeyWindow)\n", stderr)
          try require(accepts, firstMouseCheck)
        }
        NSApp.postEvent(event, atStart: true)
        let mask: NSEvent.EventTypeMask = eventType == .leftMouseDown ? .leftMouseDown : .leftMouseUp
        let retrieved = NSApp.nextEvent(matching: mask, until: Date(), inMode: .default, dequeue: true)
        guard let retrieved, retrieved.type == eventType, retrieved.window === shell,
          retrieved.eventNumber == event.eventNumber, retrieved.locationInWindow == point,
          abs(retrieved.timestamp - event.timestamp) <= 0.000_000_001 else {
          if let retrieved { NSApp.postEvent(retrieved, atStart: true) }
          throw Failure("Address click did not dequeue its exact owned native event")
        }
        guard let current = NSApp.currentEvent, current.type == eventType, current.window === shell,
          current.eventNumber == event.eventNumber, current.locationInWindow == point,
          abs(current.timestamp - event.timestamp) <= 0.000_000_001,
          NSApp.isActive, owner.windowContext.isOpen, !owner.windowContext.isClosing,
          NSApp.modalWindow == nil, shell.attachedSheet == nil else {
          throw Failure("Address click lost its exact native current-event or admission context")
        }
        NSApp.sendEvent(retrieved)
      }
    }
    func sendKey(in target: NSWindow, characters: String, flags: NSEvent.ModifierFlags = [],
      keyCode: UInt16, label: String) throws {
      guard NSApp.isActive, NSApp.keyWindow === target, target.isKeyWindow, target.isVisible,
        owner.windowContext.isOpen, !owner.windowContext.isClosing,
        shell.attachedSheet == nil, NSApp.modalWindow == nil,
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: keyCode), event.window === target else {
        throw Failure("Keyboard round trip lost its exact key owner: " + label)
      }
      NSApp.postEvent(event, atStart: true)
      let next = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true)
      func matches(_ candidate: NSEvent?) -> Bool {
        guard let candidate, candidate.type == .keyDown else { return false }
        return candidate.window === target && candidate.keyCode == event.keyCode
          && candidate.characters == event.characters && candidate.charactersIgnoringModifiers == event.charactersIgnoringModifiers
          && candidate.modifierFlags == event.modifierFlags && candidate.isARepeat == event.isARepeat
          && abs(candidate.timestamp - event.timestamp) <= 0.000_000_001
      }
      guard matches(next), let next else {
        if let next { NSApp.postEvent(next, atStart: true) }
        throw Failure("Keyboard round trip did not dequeue its exact native event: " + label)
      }
      guard matches(NSApp.currentEvent), NSApp.keyWindow === target, NSApp.isActive else {
        throw Failure("Keyboard round trip lost its native current event: " + label)
      }
      fputs("Native browser focus-family keyboard: phase=\(label) target=\(target.windowNumber) key=\(NSApp.keyWindow?.windowNumber ?? -1) main=\(NSApp.mainWindow?.windowNumber ?? -1) keyCode=\(keyCode) modifiers=\(flags.rawValue)\n", stderr)
      NSApp.sendEvent(next)
    }
    func prepareDocument() async throws -> NSWindow {
      owner.actions.palette = false
      try await wait("Owned palette retires") { owner.actions.paletteWindow == nil }
      application.repository.focusWindow(owner.windowContext.id)
      _ = application.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
      try await wait("Explicit browser intent is active") {
        NSApp.isActive && application.focusedCoordinator === owner && application.pendingApplicationIntentCount == 0
      }
      owner.layoutPages(); page.focus()
      try await wait("Actual Chrome document is key") { page.nativeWindow?.isKeyWindow == true && NSApp.keyWindow === page.nativeWindow }
      guard let window = page.nativeWindow else { throw Failure("Actual Chrome window disappeared") }
      return window
    }
    func cleanup() async {
      if let task = sheetTask { task.cancel(); _ = await task.value; sheetTask = nil }
      owner.actions.palette = false
      if let otherOwner, otherOwner.windowContext.isOpen { _ = await otherOwner.requestCloseWindow() }
      if owner.windowContext.isOpen { _ = try? await prepareDocument() }
    }
    do {
      let document = try await prepareDocument()
      let documentResponder = document.firstResponder
      let documentFocusBefore = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("document-before-main-check", expectedKey: document, responder: documentResponder, pageFocused: documentFocusBefore)
      try await wait("Shell is main while document remains key") {
        NSApp.mainWindow === shell && shell.isMainWindow && NSApp.keyWindow === document
          && document.isKeyWindow && document.firstResponder === documentResponder
      }
      let documentFocusAfter = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("document-after-main-check", expectedKey: document, responder: documentResponder, pageFocused: documentFocusAfter)
      try require(documentResponder != nil && documentFocusAfter == true
        && NSApp.keyWindow === document && document.firstResponder === documentResponder,
        "focusFamilyKeepsShellMainAndActualChromiumDocumentKey")

      var addressFrame: NSRect?
      try await wait("Actual owned address button is visible") {
        addressFrame = try? browserButtonFrame(label: "Edit address or search")
        return addressFrame != nil
      }
      guard let addressFrame else { throw Failure("Actual address button disappeared") }
      let menuBeforeEditor = NSApp.mainMenu
      let addressClickStarted = ProcessInfo.processInfo.systemUptime
      try clickBrowserControlOnce(addressFrame, label: "Edit address or search",
        firstMouseCheck: "focusFamilyActualSidebarHitAcceptsFirstMouse")
      try await wait("Actual palette owns its field editor") {
        guard let palette = owner.actions.paletteWindow, NSApp.keyWindow === palette,
          let editor = palette.firstResponder as? NSTextView else { return false }
        return palette.isKeyWindow && editor.isEditable && editor.window === palette
      }
      fputs("Native browser focus-family single-click palette readiness: \((ProcessInfo.processInfo.systemUptime - addressClickStarted) * 1000) ms\n", stderr)
      guard let palette = owner.actions.paletteWindow, let editor = palette.firstResponder else {
        throw Failure("Actual palette editor disappeared")
      }
      let palettePageFocusBefore = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("palette-before-main-check", expectedKey: palette, responder: editor, pageFocused: palettePageFocusBefore)
      try await wait("Shell is main while palette retains its editor") {
        NSApp.mainWindow === shell && shell.isMainWindow && NSApp.keyWindow === palette
          && palette.isKeyWindow && palette.firstResponder === editor
      }
      let palettePageFocusAfter = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("palette-after-main-check", expectedKey: palette, responder: editor, pageFocused: palettePageFocusAfter)
      try require(owner.actions.palette && palettePageFocusAfter == false
        && NSApp.keyWindow === palette && palette.firstResponder === editor,
        "focusFamilyFirstClickOpensPaletteAndKeepsItsEditorKeyWithPageBlurred")
      try require(menuBeforeEditor != nil && NSApp.mainMenu === menuBeforeEditor,
        "focusFamilyReusesUnchangedNativeMenusWhenOpeningEditor")

      let draftWindow = try await prepareDocument()
      let initializedDraft = try await page.ready().devTools.evaluate("""
        (() => {
          document.getElementById('zacro-focus-family-draft')?.remove();
          const input = document.createElement('input');
          input.id = 'zacro-focus-family-draft'; input.value = 'Owned focus draft';
          input.style.cssText = 'position:fixed;left:24px;top:24px;width:320px;z-index:2147483647';
          document.body.append(input); input.focus({preventScroll:true});
          input.setSelectionRange(input.value.length,input.value.length);
          return document.hasFocus() && document.activeElement === input;
        })()
        """) as? Bool
      try require(initializedDraft == true, "focusFamilyRoundTripStartsInActualFocusedDOMInput")
      let draftResponder = draftWindow.firstResponder
      try sendKey(in: draftWindow, characters: "x", keyCode: 7, label: "type-before-palette")
      let draftBefore = try await page.ready().devTools.evaluate("document.getElementById('zacro-focus-family-draft').value") as? String
      try require(draftBefore == "Owned focus draftx", "focusFamilyNativeTypingUpdatesActualDOMDraftBeforePalette")
      try sendKey(in: draftWindow, characters: "l", flags: .command, keyCode: 37, label: "open-location")
      try await wait("Keyboard shortcut opens the actual palette editor") {
        guard let palette = owner.actions.paletteWindow, let editor = palette.firstResponder as? NSTextView else { return false }
        return owner.actions.palette && NSApp.keyWindow === palette && palette.isKeyWindow && editor.isEditable
      }
      guard let keyboardPalette = owner.actions.paletteWindow else { throw Failure("Keyboard palette disappeared") }
      try sendKey(in: keyboardPalette, characters: "\u{1b}", keyCode: 53, label: "escape-palette")
      try await wait("Escape restores the exact document key and responder") {
        !owner.actions.palette && owner.actions.paletteWindow == nil && NSApp.keyWindow === draftWindow
          && draftWindow.isKeyWindow && draftWindow.firstResponder === draftResponder
      }
      let restoredDraft = try await page.ready().devTools.evaluate("""
        (() => { const input=document.getElementById('zacro-focus-family-draft');
          return document.hasFocus() && document.activeElement===input && input.value==='Owned focus draftx'; })()
        """) as? Bool
      receipt("keyboard-palette-escape-restored", expectedKey: draftWindow, responder: draftResponder, pageFocused: restoredDraft)
      try require(restoredDraft == true, "focusFamilyKeyboardPaletteEscapeRestoresExactDOMInputAndDraft")
      try sendKey(in: draftWindow, characters: "y", keyCode: 16, label: "type-after-palette")
      let continuedDraft = try await page.ready().devTools.evaluate("""
        (() => { const input=document.getElementById('zacro-focus-family-draft');
          return document.hasFocus() && document.activeElement===input && input.value==='Owned focus draftxy'; })()
        """) as? Bool
      try require(continuedDraft == true, "focusFamilyTypingContinuesInExactDOMInputAfterPaletteEscape")
      _ = try await page.ready().devTools.evaluate("document.getElementById('zacro-focus-family-draft')?.remove(); true")

      _ = try await page.ready().devTools.evaluate("window.zacroFocusReloadSentinel='owned'; true")
      var reloadFrame: NSRect?
      try await wait("Actual Reload toolbar button is ready") {
        guard !page.isLoading else { return false }
        reloadFrame = try? browserButtonFrame(label: "Reload")
        return reloadFrame != nil
      }
      guard let reloadFrame else { throw Failure("Actual Reload button disappeared") }
      try clickBrowserControlOnce(reloadFrame, label: "Reload",
        firstMouseCheck: "focusFamilyActualReloadHitAcceptsFirstMouse")
      try await wait("Reload keeps the exact selected native page key and focuses its new document") {
        guard owner.activePage === page, NSApp.keyWindow === draftWindow, draftWindow.isKeyWindow,
          !page.isLoading, !owner.actions.palette else { return false }
        let value = try? await page.ready().devTools.evaluate("document.readyState==='complete' && typeof window.zacroFocusReloadSentinel==='undefined' && document.hasFocus()")
        return value as? Bool == true
      }
      let reloadedHasFocus = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("single-click-reload-restored", expectedKey: draftWindow, responder: draftWindow.firstResponder, pageFocused: reloadedHasFocus)
      try require(reloadedHasFocus == true && owner.activePage === page && NSApp.keyWindow === draftWindow,
        "focusFamilySingleReloadClickReturnsToExactSelectedPageAndActualDOMFocus")

      _ = try await page.ready().devTools.evaluate("window.zacroSidebarReloadSentinel='owned'; true")
      try sendKey(in: draftWindow, characters: "s", flags: [.command, .option], keyCode: 1,
        label: "focus-sidebar-before-reload")
      try await wait("Real sidebar shortcut gives the selected native Button keyboard focus") {
        guard NSApp.keyWindow === shell, shell.isKeyWindow, !draftWindow.isKeyWindow,
          try selectedSidebarButtonIsFocused() else { return false }
        let value = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
        return value == false
      }
      receipt("keyboard-sidebar-before-reload", expectedKey: shell, responder: shell.firstResponder, pageFocused: false)
      var sidebarReloadFrame: NSRect?
      try await wait("Actual Reload is visible from keyboard-focused sidebar") {
        guard !page.isLoading else { return false }
        sidebarReloadFrame = try? browserButtonFrame(label: "Reload")
        return sidebarReloadFrame != nil
      }
      guard let sidebarReloadFrame else { throw Failure("Keyboard-sidebar Reload button disappeared") }
      try clickBrowserControlOnce(sidebarReloadFrame, label: "Reload from sidebar",
        firstMouseCheck: "focusFamilySidebarReloadHitAcceptsFirstMouse", requiresDocumentKey: false)
      try await wait("Sidebar-origin Reload restores actual document focus after navigation") {
        guard owner.activePage === page, NSApp.keyWindow === draftWindow, draftWindow.isKeyWindow,
          !page.isLoading, !owner.actions.palette else { return false }
        let value = try? await page.ready().devTools.evaluate("document.readyState==='complete' && typeof window.zacroSidebarReloadSentinel==='undefined' && document.hasFocus()")
        return value as? Bool == true
      }
      try await Task.sleep(for: .milliseconds(160))
      let sidebarReloadHasFocus = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("keyboard-sidebar-reload-settled", expectedKey: draftWindow, responder: draftWindow.firstResponder, pageFocused: sidebarReloadHasFocus)
      try require(sidebarReloadHasFocus == true && NSApp.keyWindow === draftWindow && draftWindow.isKeyWindow,
        "focusFamilyReloadFromKeyboardSidebarKeepsExactPageAndDOMFocusAfterSettling")

      let alert = NSAlert(); alert.messageText = "Disposable browser focus-family fixture"
      sheetTask = Task { await NativeWindowSheet.present(alert, for: shell) }
      try await wait("Actual owned sheet is key") {
        shell.attachedSheet === alert.window && NSApp.keyWindow === alert.window && alert.window.isKeyWindow
      }
      let sheetResponder = alert.window.firstResponder
      let sheetPageFocusBefore = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("sheet-before-main-check", expectedKey: alert.window, responder: sheetResponder, pageFocused: sheetPageFocusBefore)
      try await wait("Shell is main while sheet retains its responder") {
        NSApp.mainWindow === shell && shell.isMainWindow && NSApp.keyWindow === alert.window
          && alert.window.firstResponder === sheetResponder
      }
      let sheetPageFocusAfter = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("sheet-after-main-check", expectedKey: alert.window, responder: sheetResponder, pageFocused: sheetPageFocusAfter)
      try require(sheetResponder != nil && alert.window.sheetParent === shell,
        "focusFamilyKeepsOwnedSheetKeyAndResponder")
      if let task = sheetTask { task.cancel(); _ = await task.value; sheetTask = nil }
      try await wait("Exact owned sheet has retired") { shell.attachedSheet == nil }

      let originalIDs = Set(application.windows.keys)
      application.newWindow()
      let added = application.windows.values.filter { !originalIDs.contains($0.windowContext.id) && $0.windowContext.isOpen }
      guard added.count == 1, let other = added.first else { throw Failure("No exact second browser family") }
      otherOwner = other
      let otherShell = other.windowContext.window
      // A new empty window offers its palette asynchronously. Establish the
      // intended editor before snapshotting; that ordinary opening must not be
      // mistaken for focus being stolen by the original browser family.
      other.actions.openPalette()
      try await wait("Other browser family owns actual key and main") {
        guard let palette = other.actions.paletteWindow,
          let editor = palette.firstResponder as? NSTextView,
          palette.isKeyWindow, editor.isEditable, editor.window === palette else { return false }
        return NSApp.isActive && NSApp.mainWindow === otherShell && otherShell.isMainWindow
          && NSApp.keyWindow === palette && isWithin(palette, otherShell)
          && application.focusedCoordinator === other
      }
      let otherKey = NSApp.keyWindow, otherResponder = otherKey?.firstResponder
      let otherPageFocusBefore = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("other-family-before-settle", expectedKey: otherKey, responder: otherResponder, pageFocused: otherPageFocusBefore)
      try await Task.sleep(for: .milliseconds(80))
      let otherPageFocusAfter = try await page.ready().devTools.evaluate("document.hasFocus()") as? Bool
      receipt("other-family-after-settle", expectedKey: otherKey, responder: otherResponder, pageFocused: otherPageFocusAfter)
      try require(NSApp.mainWindow === otherShell && otherShell.isMainWindow && !shell.isMainWindow
        && NSApp.keyWindow === otherKey && otherKey?.firstResponder === otherResponder,
        "focusFamilyPreservesAnotherBrowserFamilyKeyAndMain")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Native browser focus-family acceptance failed: " + message }
  }
}
