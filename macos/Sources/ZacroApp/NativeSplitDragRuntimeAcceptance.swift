import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Dispatches only local NSEvents to one exact owned shell. Real root hit
/// testing and NSWindow mouse capture must reach the installed resize view;
/// no handle methods, desktop events or forced native layout are used.
@MainActor enum NativeSplitDragRuntimeAcceptance {
  private struct Stroke {
    let handle: NativeResizeHandleView
    let start: NSPoint
    let end: NSPoint
    let baseline: Double
    let target: Double
  }

  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Split drag acceptance requires the disposable loopback browser shell.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let previousWindows = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !previousWindows.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else {
      throw ShortcutError("No exact new split-drag fixture owner.")
    }
    let window = owner.windowContext.window
    var checks = [String]()
    var eventNumber = 0
    var stroke: Stroke?
    var lastDiagnostic = ""
    var savedTheme: (spaceID: String, value: SpaceTheme)?

    func require(_ passed: Bool, _ name: String) throws {
      fputs("Native split drag check \(passed ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard passed else { throw ShortcutError("Native split drag acceptance failed: " + name + ": " + lastDiagnostic) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing else { throw CancellationError() }
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native split drag timed out: " + phase + ": " + lastDiagnostic)
    }
    func handle() -> NativeResizeHandleView? {
      guard let root = window.contentView else { return nil }
      var pending = [root], matches = [NativeResizeHandleView]()
      while let view = pending.popLast() {
        if let resize = view as? NativeResizeHandleView,
          resize.configuration?.label == "Resize split view", resize.window === window,
          !resize.isHiddenOrHasHiddenAncestor { matches.append(resize) }
        pending += view.subviews
      }
      return matches.count == 1 ? matches.first : nil
    }
    func mouse(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
      eventNumber += 1
      guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
        event.window === window else {
        throw ShortcutError("The local split-drag event did not belong to its exact owned shell.")
      }
      return event
    }
    func escape() throws {
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53), event.window === window else {
        throw ShortcutError("The local split-drag Escape did not belong to its exact owned shell.")
      }
      window.sendEvent(event)
    }
    func cleanup() async throws {
      if let pending = stroke {
        window.makeKeyAndOrderFront(nil)
        try escape()
        window.sendEvent(try mouse(.leftMouseUp, point: pending.end))
        stroke = nil
      }
      if let savedTheme {
        owner.store.updateSpace(savedTheme.spaceID) { $0.theme = savedTheme.value }
      }
      if owner.windowContext.isOpen, !(await owner.requestCloseWindow()) {
        throw ShortcutError("The exact owned split-drag fixture window did not accept normal closure.")
      }
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
    }

    do {
      owner.actions.palette = false; owner.actions.library = nil
      window.setContentSize(NSSize(width: 1120, height: 760))
      func address(_ side: String) throws -> URL {
        guard var components = URLComponents(url: url.appendingPathComponent("native-history-form"), resolvingAgainstBaseURL: false) else {
          throw ShortcutError("No owned split-drag address.")
        }
        components.queryItems = [URLQueryItem(name: "split-drag", value: UUID().uuidString), URLQueryItem(name: "side", value: side)]
        guard let value = components.url else { throw ShortcutError("No valid owned split-drag address.") }
        return value
      }
      let leftAddress = try address("left"), rightAddress = try address("right")
      guard let leftTab = owner.store.createTab(address: leftAddress.absoluteString) else {
        throw ShortcutError("No owned left split-drag document.")
      }
      let left = try await owner.ensurePageReady(leftTab)
      try await application.navigation.waitForRestore(left)
      let leftBrowser = try await left.ready()
      guard let rightTab = owner.store.createTab(address: rightAddress.absoluteString) else {
        throw ShortcutError("No owned right split-drag document.")
      }
      let right = try await owner.ensurePageReady(rightTab)
      try await application.navigation.waitForRestore(right)
      let rightBrowser = try await right.ready()
      try await wait("both actual loopback documents") {
        guard !left.isLoading, !right.isLoading, left.documentError == nil, right.documentError == nil else { return false }
        let first = try await leftBrowser.devTools.evaluate("!!document.getElementById('retained')") as? Bool
        let second = try await rightBrowser.devTools.evaluate("!!document.getElementById('retained')") as? Bool
        return first == true && second == true
      }
      _ = try await leftBrowser.devTools.evaluate("document.getElementById('retained').value='owned left split-drag draft'")
      _ = try await rightBrowser.devTools.evaluate("document.getElementById('retained').value='owned right split-drag draft'")
      owner.store.setSplit(left: leftTab.id, right: rightTab.id)
      guard let split = owner.store.split(for: leftTab.id) else { throw ShortcutError("The owned split was not created.") }
      owner.store.setSplitRatio(id: split.id, ratio: 0.5)
      let leftNativeID = left.reservedNativeTabID, rightNativeID = right.reservedNativeTabID
      func frameIdentity(_ browser: CefBrowser) async throws -> String? {
        let result = try await browser.devTools.call("Page.getFrameTree")
        return ((result["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
      }
      let leftFrameID = try await frameIdentity(leftBrowser), rightFrameID = try await frameIdentity(rightBrowser)
      func closeEnough(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1.1 && abs(a.minY - b.minY) < 1.1
          && abs(a.width - b.width) < 1.1 && abs(a.height - b.height) < 1.1
      }
      func screenFrame(_ frame: CGRect) -> CGRect {
        guard let root = window.contentView else { return .zero }
        let local = root.isFlipped ? frame : CGRect(x: frame.minX, y: root.bounds.maxY - frame.maxY,
          width: frame.width, height: frame.height)
        return window.convertToScreen(root.convert(local, to: nil))
      }
      func framesMatch(_ ratio: Double) -> Bool {
        guard let leftWindow = left.nativeWindow, let rightWindow = right.nativeWindow,
          let active = owner.visibleSplit, active.id == split.id,
          abs(active.ratio - ratio) < 0.000_001,
          leftWindow.isVisible, rightWindow.isVisible else { return false }
        let content = owner.actions.contentFrame
        let firstWidth = (content.width - 6) * ratio
        let first = CGRect(x: content.minX, y: content.minY, width: firstWidth, height: content.height)
        let second = CGRect(x: first.maxX + 6, y: content.minY,
          width: content.width - firstWidth - 6, height: content.height)
        lastDiagnostic = "key=\(NSApp.keyWindow?.windowNumber ?? -1) shell=\(window.windowNumber) responder=\(window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil") content=\(content) visibleRatio=\(active.ratio) CoreRatio=\(owner.store.split(for: leftTab.id)?.ratio ?? -1) left=\(leftWindow.frame) right=\(rightWindow.frame)"
        return closeEnough(leftWindow.frame, screenFrame(first)) && closeEnough(rightWindow.frame, screenFrame(second))
      }
      func settledFrames(_ ratio: Double, phase: String) async throws {
        var previous: [CGRect] = [], samples = 0
        try await wait(phase) {
          guard framesMatch(ratio), let first = left.nativeWindow?.frame, let second = right.nativeWindow?.frame else {
            previous = []; samples = 0; return false
          }
          let current = [first, second]
          samples = current == previous ? samples + 1 : 0
          previous = current
          return samples >= 2
        }
      }
      try await settledFrames(0.5, phase: "initial actual split and handle geometry")

      func begin(_ phase: String, target: Double, nativeOrigin: Bool) async throws -> Stroke {
        guard window.attachedSheet == nil, NSApp.modalWindow == nil, let root = window.contentView,
          let resize = handle(), let configuration = resize.configuration,
          let baseline = owner.store.split(for: leftTab.id)?.ratio,
          configuration.range.contains(target) else { throw ShortcutError("The exact owned split-drag handle is unavailable.") }
        if nativeOrigin {
          owner.store.selectTab(id: leftTab.id)
          left.focus()
          try await wait("native child owns focus before " + phase) {
            guard left.nativeWindow?.isKeyWindow == true else { return false }
            return try await leftBrowser.devTools.evaluate("document.hasFocus()") as? Bool == true
          }
        } else {
          window.makeKeyAndOrderFront(nil)
          try await wait("shell owns focus before " + phase) { window.isKeyWindow }
        }
        let start = resize.convert(NSPoint(x: resize.bounds.midX, y: resize.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + (target - baseline) * configuration.pixelsPerUnit / configuration.direction, y: start.y)
        let hitPoint = root.superview?.convert(start, from: nil) ?? start
        let actualHit = root.hitTest(hitPoint)
        let screen = window.convertPoint(toScreen: start)
        let windowServerHit = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        let clearNativeGap = left.nativeWindow?.frame.contains(screen) == false
          && right.nativeWindow?.frame.contains(screen) == false
        lastDiagnostic = "phase=\(phase) startWindow=\(start) endWindow=\(end) screen=\(screen) shell=\(window.windowNumber) key=\(NSApp.keyWindow?.windowNumber ?? -1) handleWindow=\(resize.window?.windowNumber ?? -1) hit=\(actualHit.map { String(reflecting: type(of: $0)) } ?? "nil") nativeGap=\(clearNativeGap) windowServerHit=\(windowServerHit)"
        fputs("Native split drag start: \(lastDiagnostic)\n", stderr)
        try require(actualHit === resize && resize.window === window && clearNativeGap && windowServerHit == window.windowNumber,
          "splitDrag" + phase + "StartsThroughActualWindowServerAndRootHitTestInsideNativeGap")
        let next = Stroke(handle: resize, start: start, end: end, baseline: baseline, target: target)
        stroke = next
        window.sendEvent(try mouse(.leftMouseDown, point: start))
        try require(window.isKeyWindow && window.firstResponder === resize,
          "splitDrag" + phase + "WindowDispatchCapturesActualHandleAndShellFocus")
        window.sendEvent(try mouse(.leftMouseDragged, point: end))
        try await settledFrames(target, phase: phase + " actual preview through native window capture")
        try require(owner.store.split(for: leftTab.id)?.ratio == baseline && window.isKeyWindow
          && window.firstResponder === resize && handle() === resize,
          "splitDrag" + phase + "PreviewsBothNativePanesWithoutDurableMutationOrFocusLoss")
        return next
      }
      func commit(_ phase: String, target: Double, nativeOrigin: Bool) async throws {
        let next = try await begin(phase, target: target, nativeOrigin: nativeOrigin)
        window.sendEvent(try mouse(.leftMouseUp, point: next.end))
        stroke = nil
        try await wait(phase + " actual mouse-up commit") {
          guard let committed = owner.store.split(for: leftTab.id)?.ratio else { return false }
          return abs(committed - next.target) < 0.000_001 && framesMatch(next.target)
        }
        try require(window.isKeyWindow && window.firstResponder === next.handle && handle() === next.handle,
          "splitDrag" + phase + "MouseUpCommitsRatioThroughSameCapturedHandle")
      }
      try await commit("ShellOrigin", target: 0.65, nativeOrigin: false)
      guard let originalSpace = owner.store.state.activeSpace else { throw ShortcutError("The exact split-drag Space disappeared.") }
      savedTheme = (originalSpace.id, originalSpace.theme)
      owner.store.updateSpace(originalSpace.id) { $0.theme.opacity = 0; $0.theme.blur = 0 }
      try await settledFrames(0.65, phase: "fully clear Space before native-origin drag")
      try require(owner.store.state.activeSpace?.theme.opacity == 0 && owner.store.state.activeSpace?.theme.blur == 0,
        "splitDragTestsExactOwnedSpaceWithZeroOpacityAndZeroBlur")
      try await commit("NativeOrigin", target: 0.4, nativeOrigin: true)
      let cancelled = try await begin("Cancel", target: 0.57, nativeOrigin: false)
      try escape()
      try await settledFrames(cancelled.baseline, phase: "Escape restores committed native geometry")
      try require(owner.store.split(for: leftTab.id)?.ratio == cancelled.baseline
        && window.isKeyWindow && window.firstResponder === cancelled.handle,
        "splitDragEscapeCancelsActualCapturedStrokeAndRestoresCommittedRatio")
      window.sendEvent(try mouse(.leftMouseUp, point: cancelled.end))
      stroke = nil
      try require(owner.store.split(for: leftTab.id)?.ratio == cancelled.baseline
        && framesMatch(cancelled.baseline), "splitDragCancelledMouseUpCannotCommitStalePreview")
      let leftDraft = try await leftBrowser.devTools.evaluate("document.getElementById('retained').value") as? String
      let rightDraft = try await rightBrowser.devTools.evaluate("document.getElementById('retained').value") as? String
      let finalLeftFrameID = try await frameIdentity(leftBrowser), finalRightFrameID = try await frameIdentity(rightBrowser)
      try require(application.engine.pages[leftTab.id] === left && application.engine.pages[rightTab.id] === right
        && left.browser === leftBrowser && right.browser === rightBrowser
        && leftNativeID != nil && rightNativeID != nil && left.reservedNativeTabID == leftNativeID && right.reservedNativeTabID == rightNativeID
        && leftFrameID != nil && rightFrameID != nil && finalLeftFrameID == leftFrameID && finalRightFrameID == rightFrameID
        && leftDraft == "owned left split-drag draft" && rightDraft == "owned right split-drag draft",
        "splitDragCommitAndCancelRetainBothRealDocumentsNativeIDsFramesAndDrafts")
      owner.store.updateSpace(originalSpace.id) { $0.theme = originalSpace.theme }
      try require(owner.store.state.spaces.first(where: { $0.id == originalSpace.id })?.theme == originalSpace.theme,
        "splitDragRestoresExactOwnedSpaceThemeAfterClearWindowInputChecks")
      savedTheme = nil
      try await cleanup()
      try require(!owner.windowContext.isOpen, "splitDragExactOwnedWindowClosesCleanly")
      return checks
    } catch {
      let failure = error
      let task = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native split-drag fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await task.value
      throw failure
    }
  }
}
