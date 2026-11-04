import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Real live Peek controls receive local NSPanel mouse events after exact
/// WindowServer/root-hit checks. No AX press, closure invocation, renderer
/// gesture shim or desktop event substitutes for the actual button action.
@MainActor enum NativePeekControlAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Peek control acceptance requires the disposable loopback browser shell.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let previous = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !previous.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else { throw ShortcutError("No exact owned Peek-control fixture shell.") }
    let window = owner.windowContext.window
    var checks = [String](), eventNumber = 0
    var lastState = ""
    func require(_ passed: Bool, _ name: String) throws {
      fputs("Native Peek control check \(passed ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard passed else { throw ShortcutError("Native Peek control acceptance failed: " + name + ": " + lastState) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing else { throw CancellationError() }
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native Peek controls timed out: " + name + ": " + lastState)
    }
    func cleanup() async throws {
      if owner.windowContext.isOpen, !(await owner.requestCloseWindow()) {
        throw ShortcutError("The exact Peek-control fixture shell did not accept normal closure.")
      }
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
    }
    func address(_ role: String) throws -> URL {
      guard var components = URLComponents(url: url.appendingPathComponent("native-history-form"), resolvingAgainstBaseURL: false) else {
        throw ShortcutError("No owned Peek-control fixture address.")
      }
      components.queryItems = [URLQueryItem(name: "peek-controls", value: role), URLQueryItem(name: "token", value: UUID().uuidString)]
      guard let value = components.url else { throw ShortcutError("No valid owned Peek-control fixture address.") }
      return value
    }
    func mouse(_ type: NSEvent.EventType, panel: NSPanel, point: NSPoint) throws -> NSEvent {
      eventNumber += 1
      guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
        context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
        event.window === panel else { throw ShortcutError("A Peek control mouse event lost its exact owned panel.") }
      return event
    }
    func buttonFrame(in panel: NSPanel, id: String) throws -> CGRect {
      guard let root = panel.contentView else { throw ShortcutError("The exact Peek panel has no live content view.") }
      var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), matches = [CGRect]()
      func object(_ value: NSObject, _ selector: String) -> Any? {
        guard value.responds(to: NSSelectorFromString(selector)) else { return nil }
        return value.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
      }
      while let item = pending.popLast(), visited.count < 8_192 {
        guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
        if item is NSWindow { continue }
        if let view = item as? NSView, view.window !== panel { continue }
        if object(item, "accessibilityIdentifier") as? String == id,
          object(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
          item.responds(to: NSSelectorFromString("accessibilityFrame")),
          let frame = (item.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
          matches.append(frame)
        }
        pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
      }
      guard matches.count == 1, let frame = matches.first,
        frame.width >= 28, frame.height >= 28,
        panel.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) else {
        throw ShortcutError("The exact Peek button has no unique live accessible frame: " + id + ": " + String(describing: matches))
      }
      return frame
    }
    func click(panel: NSPanel, preview: ChromiumPage, screen: NSPoint, phase: String) throws {
      guard panel.parent === window, panel.isVisible, let root = panel.contentView,
        preview.nativeWindow?.parent === panel, preview.nativeWindow?.frame.contains(screen) == false else {
        throw ShortcutError("The Peek control point overlaps its native document or lost its exact parent.")
      }
      let point = panel.convertPoint(fromScreen: screen)
      let parentPoint = root.superview?.convert(point, from: nil) ?? point
      let hit = root.hitTest(parentPoint)
      let front = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
      let down = try mouse(.leftMouseDown, panel: panel, point: point)
      lastState = "phase=\(phase) panel=\(panel.windowNumber) frame=\(panel.frame) key=\(NSApp.keyWindow?.windowNumber ?? -1) screenPoint=\(screen) panelPoint=\(point) hit=\(hit.map { String(reflecting: type(of: $0)) } ?? "nil") WindowServer=\(front) firstMouse=\(hit?.acceptsFirstMouse(for: down) == true)"
      fputs("Native Peek control dispatch: \(lastState)\n", stderr)
      try require(front == panel.windowNumber && hit?.window === panel,
        "peek" + phase + "ReceivesActualWindowServerAndRootHitOutsideNativePage")
      try require(!panel.isKeyWindow && hit?.acceptsFirstMouse(for: down) == true,
        "peek" + phase + "AcceptsFirstMouseWithoutTakingDocumentKeyboardFocus")
      panel.sendEvent(down)
      panel.sendEvent(try mouse(.leftMouseUp, panel: panel, point: point))
    }

    do {
      owner.actions.palette = false; owner.actions.library = nil
      guard let sourceTab = owner.store.createTab(address: try address("source").absoluteString) else {
        throw ShortcutError("No exact Peek-control source tab.")
      }
      let source = try await owner.ensurePageReady(sourceTab)
      try await application.navigation.waitForRestore(source)
      let sourceBrowser = try await source.ready()
      try await wait("source renderer") {
        guard !source.isLoading, source.documentError == nil else { return false }
        return try await sourceBrowser.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      _ = try await sourceBrowser.devTools.evaluate("document.getElementById('retained').value='source survives real Peek control clicks'")
      func sourceRetained(requireVisible: Bool = true) async throws -> Bool {
        guard application.engine.pages[sourceTab.id] === source, source.browser === sourceBrowser,
          !sourceBrowser.isClosed, !requireVisible || source.nativeWindow?.isVisible == true else { return false }
        return try await sourceBrowser.devTools.evaluate("document.getElementById('retained').value==='source survives real Peek control clicks'") as? Bool == true
      }
      func open(_ role: String) async throws -> (ChromiumPage, CefBrowser, NSPanel) {
        guard try await owner.requestOpenPeek(sourceTabID: sourceTab.id, sourcePage: source, url: try address(role)),
          let document = owner.store.document(id: "peek:" + sourceTab.id) else {
          throw ShortcutError("The exact owned live Peek did not open: " + role)
        }
        let preview = try await owner.ensurePageReady(document)
        try await application.navigation.waitForRestore(preview)
        let browser = try await preview.ready()
        var panel: NSPanel?, previousFrame = CGRect.zero, stable = 0
        try await wait("settled native Peek and controls " + role) {
          guard !preview.isLoading, preview.documentError == nil, let native = preview.nativeWindow,
            let actual = native.parent as? NSPanel, actual.parent === window,
            actual.isVisible, native.isVisible, owner.activePage === preview else { return false }
          let target = PeekPanelController.targetFrame(in: owner.actions.contentFrame)
          guard let root = window.contentView else { return false }
          let local = root.isFlipped ? target : CGRect(x: target.minX, y: root.bounds.maxY - target.maxY,
            width: target.width, height: target.height)
          let expected = window.convertToScreen(root.convert(local, to: nil))
          guard abs(native.frame.minX - expected.minX) < 1.1, abs(native.frame.minY - expected.minY) < 1.1,
            abs(native.frame.width - expected.width) < 1.1, abs(native.frame.height - expected.height) < 1.1 else { return false }
          stable = previousFrame == native.frame ? stable + 1 : 0; previousFrame = native.frame; panel = actual
          return stable >= 2
        }
        guard let panel else { throw ShortcutError("The exact native Peek has no retained controls panel.") }
        return (preview, browser, panel)
      }
      let (closing, closingBrowser, closePanel) = try await open("close")
      closing.focus()
      try await wait("native Peek focused before close control") { closing.nativeWindow?.isKeyWindow == true }
      let closeFrame = try buttonFrame(in: closePanel, id: "peek-control-close")
      try click(panel: closePanel, preview: closing,
        screen: NSPoint(x: closeFrame.midX, y: closeFrame.midY), phase: "CloseControl")
      try await wait("real close-circle action") {
        owner.store.tab(sourceTab.id)?.peek == nil && application.engine.pages["peek:" + sourceTab.id] == nil
          && closingBrowser.isClosed && !closePanel.isVisible
      }
      try require(try await sourceRetained(), "peekCloseCircleClosesOnlyPreviewAndRetainsLiveSourceDraft")

      let (outside, outsideBrowser, outsidePanel) = try await open("outside")
      outside.focus()
      try await wait("native Peek focused before outside tint") { outside.nativeWindow?.isKeyWindow == true }
      let outsidePoint = outsidePanel.convertPoint(toScreen: NSPoint(x: 12, y: outsidePanel.contentView?.bounds.midY ?? 0))
      try click(panel: outsidePanel, preview: outside, screen: outsidePoint, phase: "OutsideTint")
      try await wait("actual outside-tint action") {
        owner.store.tab(sourceTab.id)?.peek == nil && application.engine.pages["peek:" + sourceTab.id] == nil
          && outsideBrowser.isClosed && !outsidePanel.isVisible
      }
      try require(try await sourceRetained(), "peekOutsideClickClosesOnlyPreviewAndRetainsLiveSourceDraft")

      let (expanding, expandingBrowser, expandPanel) = try await open("expand")
      let nativeID = expanding.reservedNativeTabID
      let frames = try await expandingBrowser.devTools.call("Page.getFrameTree")
      let mainFrameID = ((frames["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
      _ = try await expandingBrowser.devTools.evaluate("document.getElementById('retained').value='promoted draft survives actual circle click'")
      let before = Set(owner.store.state.tabs.map(\.id))
      window.makeKeyAndOrderFront(nil)
      try await wait("parent shell focused before expand control") { window.isKeyWindow && !expandPanel.isKeyWindow }
      let expandFrame = try buttonFrame(in: expandPanel, id: "peek-control-expand")
      // This lies on the visible circle away from glyph strokes, exercising
      // the full control hit shape rather than only an opaque icon pixel.
      try click(panel: expandPanel, preview: expanding,
        screen: NSPoint(x: expandFrame.minX + 6, y: expandFrame.midY), phase: "ExpandControl")
      var promoted: BrowserTab?
      try await wait("real expand-circle promotion and animation completion") {
        guard owner.store.tab(sourceTab.id)?.peek == nil, !expandPanel.isVisible,
          let current = owner.store.state.activeTab, !before.contains(current.id),
          application.engine.pages[current.id] === expanding, expanding.browser === expandingBrowser else { return false }
        promoted = current; return true
      }
      guard let promoted else { throw ShortcutError("The actual expand control produced no owned promoted tab.") }
      try require(promoted.windowID == owner.windowContext.id && expanding.ownerWindowID == owner.windowContext.id
        && expanding.id == promoted.id && !expandingBrowser.isClosed,
        "peekExpandCirclePromotesRealPreviewThroughItsOwnedBrowserAction")
      let finalFrames = try await expandingBrowser.devTools.call("Page.getFrameTree")
      let finalMainFrameID = ((finalFrames["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
      let draft = try await expandingBrowser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(nativeID != nil && expanding.reservedNativeTabID == nativeID && mainFrameID != nil
        && finalMainFrameID == mainFrameID && draft == "promoted draft survives actual circle click",
        "peekExpandCircleRetainsExactWebContentsNativeTabIDFrameAndDraft")
      try require(try await sourceRetained(requireVisible: false), "peekExpandCircleRetainsUnderlyingSourceDocumentAndDraft")
      try await cleanup()
      try require(!owner.windowContext.isOpen, "peekControlExactOwnedShellClosesCleanly")
      return checks
    } catch {
      let failure = error
      let task = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native Peek-control cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await task.value
      throw failure
    }
  }
}
