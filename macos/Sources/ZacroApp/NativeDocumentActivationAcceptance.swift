import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// A single real Chromium input pair, followed by an observed DOM receipt.
/// Dispatch acknowledgement alone is not evidence that the document handled
/// the input. This helper neither retries input nor synthesizes activation.
@MainActor enum NativeDocumentActivationAcceptance {
  static func click(application: ApplicationCoordinator, owner: BrowserWindowCoordinator,
    page: ChromiumPage, buttonID: String, label: String) async throws -> [String: Any] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      let url = page.url, url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Native document activation requires the disposable loopback fixture.")
    }
    let browser = try await page.ready()
    let pageID = page.id, profileID = page.profileID, ownerID = owner.windowContext.id
    guard let inputView = browser.nativeView, let inputWindow = inputView.window else {
      throw ShortcutError("Native document activation has no exact native input target: " + label)
    }
    let token = UUID().uuidString
    let values = String(decoding: try JSONSerialization.data(withJSONObject: [token, buttonID]), as: UTF8.self)
    let stateExpression = """
      (()=>{const [token,buttonID]=\(values),trace=globalThis.__zacroActivationReceipt;
        return {token:trace?.token??null,acknowledged:trace?.token===token&&trace.click!=null,
          trusted:trace?.click?.trusted===true,primary:trace?.click?.button===0,
          sticky:navigator.userActivation.hasBeenActive,focused:document.hasFocus(),
          guarded:typeof window.onbeforeunload==='function',ready:document.readyState,
          viewport:[innerWidth,innerHeight],scale:devicePixelRatio,
          visualViewport:visualViewport?{width:visualViewport.width,height:visualViewport.height,
            scale:visualViewport.scale,offsetLeft:visualViewport.offsetLeft,offsetTop:visualViewport.offsetTop}:null,
          hit:document.elementFromPoint(60,36)?.id??null,buttonPresent:!!document.getElementById(buttonID),
          events:trace?.token===token?trace.events:[]};})()
      """
    @MainActor func requireOwner() throws {
      guard !browser.isClosed, page.browser === browser, page.id == pageID, page.url == url,
        page.profileID == profileID, page.ownerWindowID == ownerID,
        application.engine.pages[pageID] === page, owner.windowContext.isOpen, !owner.windowContext.isClosing,
        owner.activePage === page, owner.selectedDocumentID == pageID else { throw CancellationError() }
    }
    @MainActor func log(_ phase: String, state: [String: Any]?) {
      let view = browser.nativeView, nativeWindow = view?.window
      var details: [String: Any] = [
        "phase": phase, "label": label, "pageID": pageID, "ownerID": ownerID,
        "appActive": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
        "keyResponder": (NSApp.keyWindow?.firstResponder).map { String(reflecting: type(of: $0)) } ?? "nil",
        "nativeWindow": nativeWindow?.windowNumber ?? -1, "nativeVisible": nativeWindow?.isVisible == true,
        "nativeParent": nativeWindow?.parent?.windowNumber ?? -1,
        "nativeBounds": view.map { NSStringFromRect($0.bounds) } ?? "nil",
        "nativeFrame": nativeWindow.map { NSStringFromRect($0.frame) } ?? "nil",
        "shellWindow": owner.windowContext.window.windowNumber,
        "ownerSheet": owner.windowContext.window.attachedSheet?.identifier?.rawValue ?? "nil",
      ]
      if let state { details["document"] = state }
      if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native activation receipt: \(text)\n", stderr) }
    }
    @MainActor func cleanup() async {
      guard !browser.isClosed, page.browser === browser else { return }
      _ = try? await browser.devTools.evaluate("""
        (()=>{const [token]=\(values),trace=globalThis.__zacroActivationReceipt;
          if(trace?.token===token){trace.controller.abort();delete globalThis.__zacroActivationReceipt;}return true;})()
        """, timeout: 2)
    }
    var latest: [String: Any]?
    do {
      try requireOwner()
      // DOM focus and viewport size can become observable before a newly
      // shown/focused native document has presented its corresponding frame.
      // Observe settled native/renderer geometry, then await an actual frame
      // from this exact compositor before sending the single input pair.
      var previousFrame: NSRect?, previousBounds: NSRect?, previousViewport: [Int]?
      var stablePresentationReads = 0
      let presentationDeadline = Date().addingTimeInterval(5)
      repeat {
        try Task.checkCancellation()
        try requireOwner()
        guard browser.nativeView === inputView, inputView.window === inputWindow else { throw CancellationError() }
        latest = try await browser.devTools.evaluate(stateExpression, timeout: 2) as? [String: Any]
        let viewport = latest?["viewport"] as? [Int]
        let ready = NSApp.isActive && inputWindow.isVisible && inputWindow.isKeyWindow
          && NSApp.keyWindow === inputWindow && latest?["focused"] as? Bool == true
          && latest?["buttonPresent"] as? Bool == true && latest?["hit"] as? String == buttonID
          && latest?["guarded"] as? Bool == true && viewport?.count == 2
          && (viewport?.first ?? 0) > 180 && (viewport?.last ?? 0) > 56
        if ready, previousFrame == inputWindow.frame, previousBounds == inputView.bounds,
          previousViewport == viewport { stablePresentationReads += 1 }
        else { stablePresentationReads = ready ? 1 : 0 }
        previousFrame = inputWindow.frame; previousBounds = inputView.bounds; previousViewport = viewport
        if stablePresentationReads >= 2 { break }
        try await Task.sleep(for: .milliseconds(40))
      } while Date() < presentationDeadline
      guard stablePresentationReads >= 2 else {
        throw ShortcutError("Actual native/renderer input presentation did not settle: " + label)
      }
      log("settled-native-and-renderer-presentation", state: latest)
      let frame = try await browser.devTools.call("Page.captureScreenshot",
        parameters: ["format": "png", "captureBeyondViewport": false], timeout: 5)
      guard let frameData = frame["data"] as? String, !frameData.isEmpty else {
        throw ShortcutError("The exact native input compositor did not provide a frame: " + label)
      }
      try requireOwner()
      guard browser.nativeView === inputView, inputView.window === inputWindow,
        inputWindow.isVisible, inputWindow.isKeyWindow, NSApp.keyWindow === inputWindow else {
        throw ShortcutError("The exact native input presentation changed after its frame: " + label)
      }
      let installed = try await browser.devTools.evaluate("""
        (()=>{const [token,buttonID]=\(values),button=document.getElementById(buttonID);
          if(!button||!document.hasFocus()||document.elementFromPoint(60,36)!==button)return false;
          globalThis.__zacroActivationReceipt?.controller?.abort();
          const controller=new AbortController(),trace={token,controller,events:[],click:null};
          globalThis.__zacroActivationReceipt=trace;
          for(const type of ['pointerdown','mousedown','pointerup','mouseup','click']){
            document.addEventListener(type,event=>{
              const value={type:event.type,trusted:event.isTrusted,button:event.button,
                target:event.target?.id??null,x:event.clientX,y:event.clientY};
              if(trace.events.length<12)trace.events.push(value);
              if(event.type==='click'&&event.target===button)trace.click=value;
            },{capture:true,signal:controller.signal});
          }return true;})()
        """) as? Bool
      guard installed == true else { throw ShortcutError("Actual activation target changed before input: " + label) }
      latest = try await browser.devTools.evaluate(stateExpression) as? [String: Any]
      log("before-dispatch", state: latest)
      for type in ["mousePressed", "mouseReleased"] {
        try requireOwner()
        guard browser.nativeView === inputView, inputView.window === inputWindow,
          inputWindow.isVisible, inputWindow.isKeyWindow, NSApp.keyWindow === inputWindow else {
          throw ShortcutError("The exact native input target changed during dispatch: " + label)
        }
        _ = try await browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      let deadline = Date().addingTimeInterval(5)
      repeat {
        try Task.checkCancellation()
        try requireOwner()
        latest = try await browser.devTools.evaluate(stateExpression, timeout: 2) as? [String: Any]
        if latest?["token"] as? String == token, latest?["acknowledged"] as? Bool == true,
          let latest {
          log("dom-click-received", state: latest)
          await cleanup()
          return latest
        }
        try await Task.sleep(for: .milliseconds(40))
      } while Date() < deadline
      throw ShortcutError("Actual document did not acknowledge the single primary click: " + label)
    } catch {
      log("failed: " + error.localizedDescription, state: latest)
      await cleanup()
      throw error
    }
  }
}
