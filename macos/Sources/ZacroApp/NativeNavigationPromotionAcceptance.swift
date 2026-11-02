import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Real pending beforeunload must settle before a retained Peek changes ID.
@MainActor enum NativeNavigationPromotionAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Navigation promotion requires the disposable loopback fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native navigation promotion check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Navigation promotion acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Navigation promotion acceptance timed out: " + phase)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let otherPeeks = Dictionary(uniqueKeysWithValues: originalOwner.store.state.tabs.map { ($0.id, $0.peek) })
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner else {
      throw ShortcutError("No navigation promotion fixture owner")
    }
    owner.actions.palette = false
    let sourceURL = url.appendingPathComponent("native-promotion-source")
    let formURL = url.appendingPathComponent("native-history-form")
    let destination = url.appendingPathComponent("native-promotion-veto-destination")
    guard let tab = owner.store.createTab(address: sourceURL.absoluteString) else {
      throw ShortcutError("No navigation promotion source")
    }
    let source = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(source)
    let sourceBrowser = try await source.ready()
    var preview: ChromiumPage?
    var browser: CefBrowser?
    var promotion: Task<BrowserTab, Error>?
    do {
      _ = try await owner.requestOpenPeek(sourceTabID: tab.id, sourcePage: source, url: formURL)
      try require(owner.store.tab(tab.id)?.peek?.url == formURL.absoluteString
        && Dictionary(uniqueKeysWithValues: originalOwner.store.state.tabs.map { ($0.id, $0.peek) }) == otherPeeks,
        "peekCommitResolvesCanonicalSourceWithoutMutatingOtherWindow")
      guard let document = owner.store.document(id: "peek:" + tab.id) else {
        throw ShortcutError("Missing promotion Peek")
      }
      let retained = try await owner.ensurePageReady(document)
      preview = retained
      try await application.navigation.waitForRestore(retained)
      let native = try await retained.ready(); browser = native
      try await wait("initial preview document") {
        guard !retained.isLoading, retained.url == formURL else { return false }
        return try await native.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      var previousFrame: NSRect?
      var stableFrames = 0
      try await wait("visible active preview with settled native viewport") {
        guard owner.windowContext.isOpen, owner.activePage === retained,
          owner.hasPresentedPeek, retained.browser === native,
          let view = native.nativeView, let window = view.window, window.isVisible,
          view.bounds.width > 180, view.bounds.height > 90 else {
          stableFrames = 0; previousFrame = nil; return false
        }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        stableFrames = frame == previousFrame ? stableFrames + 1 : 0
        previousFrame = frame
        return stableFrames >= 2
      }
      // Select the actual displayed document before delivering Chromium input.
      // This does not synthesize activation or bypass beforeunload policy.
      retained.focus()
      try await wait("preview document owns native focus") {
        guard owner.activePage === retained, retained.browser === native else { return false }
        return try await native.devTools.evaluate("document.hasFocus()") as? Bool == true
      }
      _ = try await native.devTools.evaluate("""
        (() => {
          document.getElementById('retained').value='pending promotion draft';
          const button=document.createElement('button');button.textContent='Edit';button.id='promotionActivate';
          button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
          document.body.appendChild(button);
          globalThis.promotionClick=null;
          button.addEventListener('click',event=>{globalThis.promotionClick={trusted:event.isTrusted,button:event.button};});
          window.onbeforeunload=event=>{event.preventDefault();event.returnValue='Unsaved draft';};
          return true;
        })()
        """)
      let targetReady = try await native.devTools.evaluate("document.hasFocus() && document.elementFromPoint(60,36)?.id==='promotionActivate'") as? Bool
      try require(targetReady == true, "peekPromotionInputTargetsVisibleFocusedPreviewControl")
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await native.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      let activated = try await native.devTools.evaluate("""
        ({trusted:globalThis.promotionClick?.trusted===true,
          primary:globalThis.promotionClick?.button===0,
          sticky:navigator.userActivation.hasBeenActive,
          focused:document.hasFocus(), guarded:typeof window.onbeforeunload==='function'})
        """) as? [String: Any] ?? [:]
      fputs("Native navigation promotion activation: \(activated)\n", stderr)
      try require(["trusted", "primary", "sticky", "focused", "guarded"].allSatisfy { activated[$0] as? Bool == true },
        "peekPromotionGetsActualTrustedStickyActivationBeforeNavigation")
      owner.navigate(destination.absoluteString)
      let window = owner.windowContext.window
      try await wait("owned beforeunload sheet for the pending preview navigation") {
        guard let sheet = window.attachedSheet else { return false }
        return application.webDialogs.owns(sheet, page: retained)
          && owner.hasPendingLiveNavigation("peek:" + tab.id)
      }
      var finished = false
      promotion = Task { @MainActor in
        defer { finished = true }
        return try await owner.promotePeekDocument(sourceID: tab.id, activate: true, authorize: {})
      }
      // A roundtrip in the separate source renderer allows the promotion task
      // to reach its suspension without touching the blocked preview renderer.
      _ = try await sourceBrowser.devTools.evaluate("document.readyState")
      try require(!finished && retained.id == "peek:" + tab.id && owner.store.tab(tab.id)?.peek != nil,
        "peekPromotionWaitsForExactPendingNativeNavigation")
      guard let sheet = window.attachedSheet, application.webDialogs.owns(sheet, page: retained) else {
        throw ShortcutError("Promotion beforeunload ownership changed")
      }
      window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      let promoted = try await promotion!.value; promotion = nil
      try require(application.engine.pages[promoted.id] === retained && retained.browser === native
        && application.engine.pages["peek:" + tab.id] == nil && promoted.url == formURL.absoluteString
        && !owner.hasPendingLiveNavigation("peek:" + tab.id) && !owner.hasPendingLiveNavigation(promoted.id),
        "vetoThenPromotionKeepsNativeIdentityAndClearsOriginalRequest")
      let draft = try await native.devTools.evaluate("document.getElementById('retained').value") as? String
      _ = try await native.devTools.evaluate("document.title='Promoted after navigation veto'; window.onbeforeunload=null")
      try await wait("metadata after vetoed document promotion") { owner.store.tab(promoted.id)?.title == "Promoted after navigation veto" }
      try require(draft == "pending promotion draft" && owner.store.tab(promoted.id)?.url == formURL.absoluteString,
        "promotedVetoedDocumentKeepsDraftAndReceivesFreshMetadata")
      try require(await application.navigation.captureBeforeDiscard(retained, tabID: promoted.id, peek: false),
        "promotedVetoedDocumentCanCaptureUnderItsNewIdentity")
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      return checks
    } catch {
      promotion?.cancel()
      if let preview, let sheet = owner.windowContext.window.attachedSheet,
        application.webDialogs.owns(sheet, page: preview) {
        owner.windowContext.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      }
      _ = try? await promotion?.value
      if let browser, !browser.isClosed { _ = try? await browser.devTools.evaluate("window.onbeforeunload=null") }
      _ = await owner.requestCloseWindow()
      throw error
    }
  }
}
