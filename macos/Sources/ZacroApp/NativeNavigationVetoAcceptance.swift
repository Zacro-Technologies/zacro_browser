import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Exercises real beforeunload and JavaScript callbacks in disposable pages.
/// Programmatic replies target only the coordinator's exact owned sheet; they
/// are not evidence of physical desktop input.
@MainActor
enum NativeNavigationVetoAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Navigation veto acceptance requires the disposable loopback fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native navigation veto check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Navigation veto acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ name: String, _ predicate: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Navigation veto acceptance timed out: " + name)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner else {
      throw ShortcutError("Missing navigation veto fixture owner")
    }
    let window = owner.windowContext.window
    owner.actions.palette = false
    let formURL = url.appendingPathComponent("native-history-form")
    let destination = url.appendingPathComponent("native-veto-destination-" + UUID().uuidString)
    guard let tab = owner.store.createTab(address: formURL.absoluteString) else {
      _ = await owner.requestCloseWindow()
      throw ShortcutError("Missing navigation veto fixture tab")
    }
    let page = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    let browser = try await page.ready()
    var promptTask: Task<String?, Error>?
    var restoredOwner: BrowserWindowCoordinator?
    func ownedSheet(_ page: ChromiumPage, owner: BrowserWindowCoordinator,
      kind: String) -> NSWindow? {
      guard let sheet = owner.windowContext.window.attachedSheet,
        sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:" + kind + ":") == true,
        application.webDialogs.owns(sheet, page: page) else { return nil }
      return sheet
    }
    do {
      try await wait("form ready") {
        guard !page.isLoading, page.url == formURL else { return false }
        return try await browser.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      _ = try await browser.devTools.evaluate("""
        (() => {
          const field = document.getElementById('retained');
          field.value = 'draft retained after Stay';
          field.dispatchEvent(new Event('input', {bubbles:true}));
          field.dispatchEvent(new Event('change', {bubbles:true}));
          const button = document.createElement('button');
          button.id='vetoActivation'; button.textContent='Edit document';
          button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
          document.body.appendChild(button);
          window.onbeforeunload = event => { event.preventDefault(); event.returnValue='Unsaved draft'; };
          return true;
        })()
        """)
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      let originalHistory = owner.store.document(id: tab.id)?.navigation
      owner.navigate(destination.absoluteString)
      try await wait("beforeunload sheet") { ownedSheet(page, owner: owner, kind: "beforeunload") != nil }
      try require(NSApp.modalWindow == nil && application.webDialogs.pendingRequestCount(for: page) == 1,
        "beforeunloadUsesOneOwnedNonblockingSheet")
      try require(owner.store.document(id: tab.id)?.url == formURL.absoluteString
        && owner.store.document(id: tab.id)?.navigation == originalHistory,
        "uncommittedOrdinaryNavigationPreservesSavedAddressAndHistory")
      originalOwner.windowContext.window.makeKeyAndOrderFront(nil)
      guard let otherPage = originalOwner.activePage else { throw ShortcutError("Missing second window renderer") }
      let otherBrowser = try await otherPage.ready()
      let concurrentValue = try await otherBrowser.devTools.evaluate("1 + 2") as? Int
      try require(concurrentValue == 3 && window.attachedSheet != nil && NSApp.modalWindow == nil,
        "beforeunloadLeavesOtherWindowRendererUsable")
      guard let sheet = ownedSheet(page, owner: owner, kind: "beforeunload") else {
        throw ShortcutError("Beforeunload ownership changed")
      }
      window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      try await wait("navigation veto settled") {
        application.webDialogs.pendingRequestCount(for: page) == 0 && window.attachedSheet == nil
          && !page.isLoading && !owner.hasPendingLiveNavigation(tab.id)
      }
      let draft = try await browser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(page.url == formURL && draft == "draft retained after Stay"
        && owner.store.document(id: tab.id)?.url == formURL.absoluteString,
        "navigationStayKeepsExactLiveDocumentAndCoreAddress")
      try require(await application.navigation.captureBeforeDiscard(page, tabID: tab.id, peek: false),
        "navigationVetoStillCapturesCurrentEncryptedPageState")

      // Ordinary prompt uses the same owned callback lane and actual text input.
      _ = try await browser.devTools.evaluate("window.onbeforeunload = null")
      promptTask = Task { @MainActor in
        try await browser.devTools.evaluate("prompt('Native prompt fixture', 'original')", timeout: 20) as? String
      }
      try await wait("prompt sheet") { ownedSheet(page, owner: owner, kind: "javascript") != nil }
      guard let promptSheet = ownedSheet(page, owner: owner, kind: "javascript") else {
        throw ShortcutError("Missing owned prompt")
      }
      func input(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let found = input(in: child) { return found } }
        return nil
      }
      guard let content = promptSheet.contentView, let field = input(in: content) else {
        throw ShortcutError("Missing native prompt input")
      }
      field.stringValue = "owned prompt response"
      window.endSheet(promptSheet, returnCode: .alertFirstButtonReturn)
      let response = try await promptTask!.value; promptTask = nil
      try require(response == "owned prompt response", "javascriptPromptReturnsExactOwnedInput")
      try await wait("prompt retired") {
        application.webDialogs.pendingRequestCount(for: page) == 0 && window.attachedSheet == nil
      }

      // Native external reset must dismiss the old alert without publishing a
      // second UI decision through the retained callback.
      // Dialog handling is session-local: the Peek adapter enables Page only
      // in its own child session. Register this fixture's root Page observer
      // before opening the dialog that its root command will reset.
      _ = try await browser.devTools.call("Page.enable")
      promptTask = Task { @MainActor in
        try await browser.devTools.evaluate("confirm('Reset this obsolete dialog')", timeout: 20) as? String
      }
      try await wait("resettable dialog") { ownedSheet(page, owner: owner, kind: "javascript") != nil }
      // Dismiss through the actual native reset path; the callback release is
      // exactly once and deliberately carries no new UI decision.
      _ = try await browser.devTools.call("Page.handleJavaScriptDialog", parameters: ["accept": false])
      _ = try? await promptTask?.value; promptTask = nil
      try await wait("native dialog reset") {
        application.webDialogs.pendingRequestCount(for: page) == 0 && window.attachedSheet == nil
      }
      try require(!browser.isClosed && page.url == formURL,
        "nativeDialogResetRevokesOwnedSheetWithoutClosingPage")

      let closed = await owner.requestCloseWindow()
      try require(closed && !owner.windowContext.isOpen, "vetoedNavigationWindowClosesAfterExplicitGuardRemoval")
      let reopened = try application.reopenWindow(id: owner.windowContext.id)
      restoredOwner = reopened
      guard let saved = reopened.store.document(id: tab.id) else { throw ShortcutError("Missing vetoed saved tab") }
      let restored = try await reopened.ensurePageReady(saved)
      try await application.navigation.waitForRestore(restored)
      let restoredBrowser = try await restored.ready()
      try await wait("vetoed state restored") {
        guard !restored.isLoading, restored.url == formURL else { return false }
        return try await restoredBrowser.devTools.evaluate("document.getElementById('retained')?.value") as? String
          == "draft retained after Stay"
      }
      try require(saved.url == formURL.absoluteString && restored.url == formURL,
        "windowReopenRestoresVetoedSourceAndDraftInsteadOfRequestedDestination")
      _ = await reopened.requestCloseWindow(); restoredOwner = nil
      originalOwner.windowContext.show()
      return checks
    } catch {
      promptTask?.cancel()
      if let sheet = window.attachedSheet, application.webDialogs.owns(sheet, page: page) {
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      }
      _ = try? await promptTask?.value
      if !browser.isClosed { _ = try? await browser.devTools.evaluate("window.onbeforeunload=null") }
      if let restoredOwner { _ = await restoredOwner.requestCloseWindow() }
      else { _ = await owner.requestCloseWindow() }
      throw error
    }
  }
}
