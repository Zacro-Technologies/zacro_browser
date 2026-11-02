import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Real beforeunload negotiation through the exact preview's DevTools session.
/// Only the disposable loopback fixture receives Chromium input/dialog replies;
/// this does not automate desktop controls or establish physical-input parity.
@MainActor
enum NativePeekReplacementAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Peek replacement requires the disposable loopback fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native Peek replacement check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Peek replacement acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Peek replacement acceptance timed out: " + name)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner,
      let operation = owner.actions.performLibraryAction else {
      throw ShortcutError("No Peek replacement fixture owner")
    }
    owner.actions.palette = false
    let sourceURL = url.appendingPathComponent("peek-replacement-source")
    let initialURL = url.appendingPathComponent("peek-replacement-original")
    let firstURL = url.appendingPathComponent("peek-replacement-superseded")
    let finalURL = url.appendingPathComponent("peek-replacement-final")
    let selfReplacementURL = url.appendingPathComponent("peek-replacement-from-preview")
    guard let tab = owner.store.createTab(address: sourceURL.absoluteString) else {
      _ = await owner.requestCloseWindow()
      throw ShortcutError("No Peek replacement source")
    }
    var previewBrowser: CefBrowser?
    var operations: [Task<Void, Error>] = []
    do {
      let source = try await owner.ensurePageReady(tab)
      try await application.navigation.waitForRestore(source)
      let sourceBrowser = try await source.ready()
      try await wait("source ready") { !source.isLoading && source.url == sourceURL }
      _ = try await sourceBrowser.devTools.evaluate("document.body.innerHTML='<input id=parentDraft>'; document.getElementById('parentDraft').value='parent survives replacement'; true")
      try await operation("peek:open", ["url": initialURL.absoluteString])
      try await wait("initial Peek") {
        guard let preview = application.engine.pages["peek:" + tab.id] else { return false }
        return preview.url == initialURL && !preview.isLoading && owner.activePage === preview
      }
      guard let oldPreview = application.engine.pages["peek:" + tab.id] else { throw ShortcutError("Missing initial Peek") }
      let browser = try await oldPreview.ready()
      previewBrowser = browser
      func prompt() -> NSWindow? {
        guard let sheet = owner.windowContext.window.attachedSheet,
          sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:beforeunload:") == true,
          application.webDialogs.owns(sheet, page: oldPreview) else { return nil }
        return sheet
      }
      _ = try await browser.devTools.evaluate("""
        (() => {
          document.body.innerHTML = '<button id="activatePreview">Keep editing</button><textarea id="replacementDraft"></textarea>';
          document.body.style.cssText='margin:0;background:white';
          document.getElementById('activatePreview').style.cssText='position:absolute;left:20px;top:20px;width:160px;height:36px';
          document.getElementById('replacementDraft').value='unsaved preview work';
          window.onbeforeunload = event => { event.preventDefault(); event.returnValue='Unsaved preview work'; };
          return true;
        })()
        """)
      // Beforeunload requires real sticky activation, not a synthetic DOM event.
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      let first = Task { @MainActor in try await operation("peek:open", ["url": firstURL.absoluteString]) }
      operations.append(first)
      try await wait("first owned beforeunload sheet") { prompt() != nil }
      guard let rejectedPrompt = prompt() else { throw ShortcutError("Missing exact preview beforeunload sheet") }
      try require(owner.store.tab(tab.id)?.peek?.url == initialURL.absoluteString
        && application.engine.pages[oldPreview.id] === oldPreview && !browser.isClosed,
        "peekReplacementDoesNotPublishBeforeNativeCloseDecision")
      owner.windowContext.window.endSheet(rejectedPrompt, returnCode: .alertSecondButtonReturn)
      try await first.value
      let rejectedDraft = try await browser.devTools.evaluate("document.getElementById('replacementDraft').value") as? String
      try require(owner.store.tab(tab.id)?.peek?.url == initialURL.absoluteString
        && application.engine.pages[oldPreview.id] === oldPreview && oldPreview.url == initialURL
        && rejectedDraft == "unsaved preview work", "peekReplacementVetoRetainsExactDocumentMetadataAndDraft")

      let superseded = Task { @MainActor in try await operation("peek:open", ["url": firstURL.absoluteString]) }
      operations.append(superseded)
      try await wait("second owned beforeunload sheet") {
        guard let sheet = prompt() else { return false }
        return sheet !== rejectedPrompt
      }
      guard let acceptedPrompt = prompt() else { throw ShortcutError("Missing replacement beforeunload sheet") }
      let latest = Task { @MainActor in try await operation("peek:open", ["url": finalURL.absoluteString]) }
      operations.append(latest)
      try await wait("both replacement intents await the same native close") {
        owner.pendingPeekReplacementCount(tab.id) == 2
      }
      owner.windowContext.window.endSheet(acceptedPrompt, returnCode: .alertFirstButtonReturn)
      try await superseded.value
      try await latest.value
      try await wait("only latest replacement is displayed") {
        guard let replacement = application.engine.pages["peek:" + tab.id], replacement !== oldPreview else { return false }
        return owner.store.tab(tab.id)?.peek?.url == finalURL.absoluteString
          && replacement.url == finalURL && !replacement.isLoading && owner.activePage === replacement
      }
      try require(browser.isClosed && application.webDialogs.pendingRequestCount(for: oldPreview) == 0,
        "peekReplacementCoalescesCloseAndCommitsOnlyLatestIntent")
      let retainedParent = try await sourceBrowser.devTools.evaluate("document.getElementById('parentDraft').value") as? String
      try require(application.engine.pages[tab.id] === source && source.url == sourceURL
        && retainedParent == "parent survives replacement", "peekReplacementPreservesUnderlyingSourceDocument")

      guard let nextPreview = application.engine.pages["peek:" + tab.id] else { throw ShortcutError("Missing replacement Peek") }
      let nextBrowser = try await nextPreview.ready()
      let selfAddress = String(decoding: try JSONSerialization.data(withJSONObject: selfReplacementURL.absoluteString,
        options: [.fragmentsAllowed]), as: UTF8.self)
      _ = try await nextBrowser.devTools.evaluate("""
        (() => {
          document.body.innerHTML='<a id="selfReplacement">Next preview</a>';
          document.body.style.margin='0';
          const a=document.getElementById('selfReplacement'); a.href=\(selfAddress);
          a.style.cssText='position:absolute;left:20px;top:20px;display:block;width:160px;height:40px';
          return true;
        })()
        """)
      try await wait("replacement preview's trusted adapter") { application.peekLinks.isArmed(nextPreview) }
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await nextBrowser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1, "modifiers": 8,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      try await wait("a preview can replace its own accepted closed document") {
        guard let newest = application.engine.pages["peek:" + tab.id], newest !== nextPreview else { return false }
        return newest.url == selfReplacementURL && !newest.isLoading
          && owner.store.tab(tab.id)?.peek?.url == selfReplacementURL.absoluteString
      }
      try require(nextBrowser.isClosed, "peekTrustedSelfReplacementSurvivesOldBrowserTeardown")
      try require(await owner.requestCloseWindow(), "peekReplacementFixtureClosesCleanly")
      originalOwner.windowContext.show()
      return checks
    } catch {
      if let browser = previewBrowser, !browser.isClosed {
        if let page = application.engine.pages["peek:" + tab.id],
          let sheet = owner.windowContext.window.attachedSheet,
          application.webDialogs.owns(sheet, page: page) {
          owner.windowContext.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        _ = try? await browser.devTools.evaluate("window.onbeforeunload=null;true", timeout: 1)
      }
      for operation in operations { operation.cancel() }
      for operation in operations { _ = try? await operation.value }
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      throw error
    }
  }
}
