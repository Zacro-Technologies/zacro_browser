import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Exercises the application's real local AppKit input path. The right pane
/// already owns keyboard focus when a newer logical selection chooses left;
/// one mouse pair must still select the pane the user actually interacts with.
/// The Find variant begins with the exact owned field editor holding focus.
/// These are process-local NSEvents, not physical desktop input.
@MainActor enum NativeSplitSelectionInputAcceptance {
  static func run(application: ApplicationCoordinator, owner: BrowserWindowCoordinator,
    left: ChromiumPage, right: ChromiumPage, withFindBar: Bool = false) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      let leftURL = left.url, let rightURL = right.url,
      leftURL.scheme == "http", rightURL.scheme == "http",
      leftURL.host == "127.0.0.1", rightURL.host == "127.0.0.1",
      leftURL.port != nil, leftURL.port == rightURL.port,
      leftURL.path == "/focus-left", rightURL.path == "/focus-right",
      left !== right, !left.isPrivate, !right.isPrivate,
      left.profileID == right.profileID, owner.store.activeProfileID == right.profileID else {
      throw ShortcutError("Split selection input requires its two owned public loopback fixture documents.")
    }
    let browser = try await right.ready()
    guard let inputView = browser.nativeView, let inputWindow = inputView.window else {
      throw ShortcutError("The split selection fixture has no exact native input target.")
    }
    let leftID = left.id, rightID = right.id, profileID = right.profileID
    let ownerID = owner.windowContext.id, nativeID = browser.id
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let key = "__zacroSplitSelection_" + token, buttonID = "zacroSplitSelection_" + token
    let values = String(decoding: try JSONSerialization.data(withJSONObject: [key, token, buttonID]), as: UTF8.self)
    var checks: [String] = [], latest: [String: Any]?
    var findControlsWindow: NSWindow?

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native split selection input check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native split selection input acceptance failed: " + name) }
      checks.append(name)
    }
    func requireOwnership() throws {
      guard owner.windowContext.isOpen, !owner.windowContext.isClosing,
        !application.engine.isTerminating, application.deletingProfileID == nil,
        application.engine.pages[leftID] === left, application.engine.pages[rightID] === right,
        left.id == leftID, right.id == rightID, left.url == leftURL, right.url == rightURL,
        left.profileID == profileID, right.profileID == profileID,
        left.ownerWindowID == ownerID, right.ownerWindowID == ownerID,
        owner.store.activeProfileID == profileID,
        owner.store.tab(leftID)?.isClosed == false, owner.store.tab(rightID)?.isClosed == false,
        owner.store.tab(leftID)?.peek == nil, owner.store.tab(rightID)?.peek == nil,
        let split = owner.store.split(for: leftID), split.leftTabID == leftID, split.rightTabID == rightID,
        right.browser === browser, browser.id == nativeID, !browser.isClosed,
        browser.nativeView === inputView, inputView.window === inputWindow,
        left.nativeWindow?.isVisible == true, inputWindow.isVisible,
        !owner.actions.palette, !owner.actions.themeEditor, owner.actions.library == nil,
        owner.actions.findVisible == withFindBar, !owner.actions.recordingShortcut,
        owner.window?.attachedSheet == nil, NSApp.modalWindow == nil else { throw CancellationError() }
    }
    func findEditorOwnsKeyWindow() -> Bool {
      guard withFindBar, owner.actions.findVisible, let controls = NSApp.keyWindow,
        controls.identifier == NSUserInterfaceItemIdentifier("ZacroBrowserControls"),
        controls.parent === owner.window, controls.isVisible, controls.isKeyWindow,
        let editor = controls.firstResponder as? NSTextView, editor.window === controls else { return false }
      return findControlsWindow == nil || controls === findControlsWindow
    }
    func expectedInputContext() -> Bool {
      if withFindBar { return findEditorOwnsKeyWindow() && !inputWindow.isKeyWindow }
      return NSApp.keyWindow === inputWindow && inputWindow.isKeyWindow
    }
    func log(_ phase: String) {
      var details: [String: Any] = ["phase": phase, "leftID": leftID, "rightID": rightID,
        "owner": ownerID, "nativeID": nativeID, "activeTabID": owner.store.state.activeTabID ?? "",
        "selectedDocumentID": owner.selectedDocumentID ?? "", "appActive": NSApp.isActive,
        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1, "nativeWindow": inputWindow.windowNumber,
        "nativeKey": inputWindow.isKeyWindow, "nativeVisible": inputWindow.isVisible,
        "nativeFrame": NSStringFromRect(inputWindow.frame), "nativeBounds": NSStringFromRect(inputView.bounds),
        "withFindBar": withFindBar, "findVisible": owner.actions.findVisible,
        "findControlsWindow": findControlsWindow?.windowNumber ?? -1,
        "findEditorOwnsKeyWindow": findEditorOwnsKeyWindow()]
      if let latest { details["document"] = latest }
      if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
        fputs("Native split selection input: \(String(decoding: data, as: UTF8.self))\n", stderr)
      }
    }
    func cleanup() async {
      guard !browser.isClosed, right.browser === browser,
        application.engine.pages[rightID] === right, right.id == rightID,
        right.ownerWindowID == ownerID, right.profileID == profileID else { return }
      _ = try? await browser.devTools.evaluate("""
        (()=>{const [key,token]=\(values),state=globalThis[key];
          if(state?.token===token){state.controller.abort();state.button.remove();delete globalThis[key];}return true;})()
        """, timeout: 2)
    }
    let stateExpression = """
      (()=>{const [key,token,buttonID]=\(values),state=globalThis[key];
        return {token:state?.token??null,click:state?.click??null,events:state?.events??[],
          focused:document.hasFocus(),viewport:[innerWidth,innerHeight],
          hit:document.elementFromPoint(60,36)?.id??null,buttonPresent:!!document.getElementById(buttonID)};})()
      """
    do {
      try requireOwnership()
      if withFindBar {
        let findDeadline = Date().addingTimeInterval(5)
        while !findEditorOwnsKeyWindow(), Date() < findDeadline {
          try Task.checkCancellation(); try requireOwnership()
          try await Task.sleep(for: .milliseconds(30))
        }
        guard findEditorOwnsKeyWindow() else {
          throw ShortcutError("The split selection fixture did not receive its exact owned Find field editor.")
        }
        findControlsWindow = NSApp.keyWindow
      }
      guard owner.activePage === right, owner.selectedDocumentID == rightID,
        NSApp.isActive, expectedInputContext() else {
        throw ShortcutError("The split selection fixture did not begin in its exact expected input context.")
      }
      let installed = try await browser.devTools.evaluate("""
        (()=>{const [key,token,buttonID]=\(values);if(globalThis[key]||document.getElementById(buttonID))return false;
          const controller=new AbortController(),button=document.createElement('button');
          button.id=buttonID;button.textContent='Select pane';
          button.style.cssText='position:fixed;left:20px;top:16px;width:120px;height:40px;box-sizing:border-box;z-index:2147483647';
          const state={token,controller,button,events:[],click:null};globalThis[key]=state;document.body.appendChild(button);
          for(const type of ['pointerdown','mousedown','pointerup','mouseup','click']){
            button.addEventListener(type,event=>{const value={type:event.type,trusted:event.isTrusted,
              primary:event.button===0,target:event.target?.id??null};
              if(state.events.length<8)state.events.push(value);if(event.type==='click')state.click=value;
            },{signal:controller.signal});
          }return true;})()
        """) as? Bool
      guard installed == true else { throw ShortcutError("The exact split selection input fixture could not be installed.") }
      var previousFrame: NSRect?, previousBounds: NSRect?, previousViewport: [Int]?
      var stableReads = 0
      let presentationDeadline = Date().addingTimeInterval(5)
      repeat {
        try Task.checkCancellation(); try requireOwnership()
        latest = try await browser.devTools.evaluate(stateExpression, timeout: 2) as? [String: Any]
        let viewport = latest?["viewport"] as? [Int]
        let ready = owner.activePage === right && owner.selectedDocumentID == rightID
          && NSApp.isActive && expectedInputContext()
          && (withFindBar || latest?["focused"] as? Bool == true) && latest?["buttonPresent"] as? Bool == true
          && latest?["hit"] as? String == buttonID && viewport?.count == 2
          && (viewport?.first ?? 0) > 180 && (viewport?.last ?? 0) > 56
        if ready, previousFrame == inputWindow.frame, previousBounds == inputView.bounds,
          previousViewport == viewport { stableReads += 1 }
        else { stableReads = ready ? 1 : 0 }
        previousFrame = inputWindow.frame; previousBounds = inputView.bounds; previousViewport = viewport
        if stableReads >= 2 { break }
        try await Task.sleep(for: .milliseconds(40))
      } while Date() < presentationDeadline
      guard stableReads >= 2 else { throw ShortcutError("The exact right split document did not settle for local input.") }
      let frame = try await browser.devTools.call("Page.captureScreenshot",
        parameters: ["format": "png", "captureBeyondViewport": false], timeout: 5)
      guard let rendered = frame["data"] as? String, !rendered.isEmpty else {
        throw ShortcutError("The exact right split document did not provide its rendered input frame.")
      }
      try requireOwnership()
      guard owner.activePage === right, NSApp.isActive, expectedInputContext(),
        inputWindow.frame == previousFrame, inputView.bounds == previousBounds else {
        throw ShortcutError("The exact right split input presentation changed after its rendered frame.")
      }
      let zoom = pow(1.2, browser.zoomLevel)
      guard zoom.isFinite, zoom > 0 else { throw ShortcutError("The right split input scale is invalid.") }
      let nativePoint = NSPoint(x: inputView.bounds.minX + 60 * zoom,
        y: inputView.isFlipped ? inputView.bounds.minY + 36 * zoom : inputView.bounds.maxY - 36 * zoom)
      let point = inputView.convert(nativePoint, to: nil)
      guard inputView.bounds.contains(nativePoint), let root = inputWindow.contentView,
        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point),
        hit.window === inputWindow, hit === inputView || hit.isDescendant(of: inputView) else {
        throw ShortcutError("The right split mouse point does not hit its exact native document.")
      }
      let timestamp = ProcessInfo.processInfo.systemUptime
      guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
        timestamp: timestamp, windowNumber: inputWindow.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1),
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
          timestamp: timestamp + 0.001, windowNumber: inputWindow.windowNumber, context: nil,
          eventNumber: 2, clickCount: 1, pressure: 0),
        down.window === inputWindow, up.window === inputWindow else {
        throw ShortcutError("The local split mouse pair lost its exact native window.")
      }
      // No await separates the new logical intent and the genuine AppKit
      // interaction in the visible sibling, including when its native window
      // is already key or the owned Find field editor currently holds focus.
      owner.store.selectTab(id: leftID)
      try require(owner.store.state.activeTabID == leftID && owner.activePage === left
        && expectedInputContext(), withFindBar
          ? "splitInputStartsWithNewLeftSelectionAndOwnedFindEditor"
          : "splitInputStartsWithNewLeftSelectionAndAlreadyKeyRightPane")
      NSApp.sendEvent(down)
      let selectedByDown = owner.store.state.activeTabID == rightID && owner.activePage === right
        && owner.selectedDocumentID == rightID && NSApp.keyWindow === inputWindow && inputWindow.isKeyWindow
        && owner.actions.findVisible == withFindBar
      NSApp.sendEvent(up)
      try require(selectedByDown, withFindBar
        ? "findEditorSplitPaneMouseInputSelectsItsActualDocumentSynchronously"
        : "alreadyKeySplitPaneMouseInputSelectsItsActualDocumentSynchronously")
      let receiptDeadline = Date().addingTimeInterval(5)
      var delivered = false
      repeat {
        try Task.checkCancellation(); try requireOwnership()
        latest = try await browser.devTools.evaluate(stateExpression, timeout: 2) as? [String: Any]
        let click = latest?["click"] as? [String: Any]
        delivered = latest?["token"] as? String == token && click?["trusted"] as? Bool == true
          && click?["primary"] as? Bool == true && click?["target"] as? String == buttonID
          && owner.activePage === right && owner.selectedDocumentID == rightID
          && NSApp.keyWindow === inputWindow && inputWindow.isKeyWindow
          && owner.actions.findVisible == withFindBar
        if delivered { break }
        try await Task.sleep(for: .milliseconds(40))
      } while Date() < receiptDeadline
      log("single-local-mouse-pair-receipt")
      try require(delivered, withFindBar
        ? "findEditorSplitPaneMouseInputReachesItsExactNativeDocumentAndRetainsFind"
        : "alreadyKeySplitPaneMouseInputReachesItsExactNativeDocument")
      await cleanup()
      return checks
    } catch {
      log("failed: " + String(error.localizedDescription.prefix(500)))
      await cleanup()
      throw error
    }
  }
}
