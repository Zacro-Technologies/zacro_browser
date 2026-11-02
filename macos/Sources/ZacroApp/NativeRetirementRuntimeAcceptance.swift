import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Uses only disposable loopback content and exact owned NSAlert replies.
@MainActor enum NativeRetirementRuntimeAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Retirement acceptance requires the disposable fixture.")
    }
    var checks: [String] = []
    @MainActor func require(_ value: Bool, _ name: String) throws {
      fputs("Native retirement check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Retirement acceptance failed: " + name) }
      checks.append(name)
    }
    @MainActor func wait(_ phase: String = "condition", _ condition: @MainActor () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Retirement acceptance timed out: " + phase)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner else {
      throw ShortcutError("No retirement fixture owner")
    }
    owner.actions.palette = false
    let address = url.appendingPathComponent("native-history-form")
    guard let tab = owner.store.createTab(address: address.absoluteString) else {
      throw ShortcutError("No retirement fixture tab")
    }
    let page = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    let browser = try await page.ready()
    let window = owner.windowContext.window
    var close: Task<Bool, Never>?
    @MainActor func ownedSheet() -> NSWindow? {
      guard let sheet = window.attachedSheet,
        sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:beforeunload:") == true,
        application.webDialogs.owns(sheet, page: page) else { return nil }
      return sheet
    }
    @MainActor func prepareGuardedDocument(_ target: ChromiumPage, native: CefBrowser,
      draft: String) async throws -> Bool {
      try await wait("loaded retirement form") {
        guard !target.isLoading, target.url == address, target.browser === native else { return false }
        return try await native.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      var previousFrame: NSRect?
      var previousViewport: [Double]?
      var stableFrames = 0
      try await wait("visible active retirement document with settled native and renderer viewport") {
        guard owner.windowContext.isOpen, owner.activePage === target,
          application.engine.pages[target.id] === target, target.browser === native,
          let view = native.nativeView, let nativeWindow = view.window, nativeWindow.isVisible,
          view.bounds.width > 180, view.bounds.height > 90 else {
          stableFrames = 0; previousFrame = nil; previousViewport = nil; return false
        }
        let frame = nativeWindow.convertToScreen(view.convert(view.bounds, to: nil))
        guard let viewport = try await native.devTools.evaluate("[innerWidth,innerHeight]") as? [Double],
          viewport.count == 2, viewport[0] > 180, viewport[1] > 90 else {
          stableFrames = 0; previousFrame = nil; previousViewport = nil; return false
        }
        stableFrames = frame == previousFrame && viewport == previousViewport ? stableFrames + 1 : 0
        previousFrame = frame; previousViewport = viewport
        return stableFrames >= 2
      }
      target.focus()
      try await wait("retirement document owns native focus") {
        guard owner.activePage === target, target.browser === native else { return false }
        return try await native.devTools.evaluate("document.hasFocus()") as? Bool == true
      }
      let draftJSON = String(decoding: try JSONSerialization.data(withJSONObject: [draft]), as: UTF8.self)
      _ = try await native.devTools.evaluate("""
        (() => {
          const field=document.getElementById('retained');
          field.value=\(draftJSON)[0];
          field.dispatchEvent(new Event('input',{bubbles:true}));
          field.dispatchEvent(new Event('change',{bubbles:true}));
          document.getElementById('retirementActivate')?.remove();
          const button=document.createElement('button');button.textContent='Edit';button.id='retirementActivate';
          button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
          document.body.appendChild(button);
          globalThis.retirementClick=null;
          button.addEventListener('click',event=>{globalThis.retirementClick={trusted:event.isTrusted,button:event.button};});
          window.onbeforeunload=event=>{event.preventDefault();event.returnValue='Unsaved draft';};
          return true;
        })()
        """)
      try await wait("actual retirement input target is focused and hit-testable") {
        guard owner.activePage === target, target.browser === native else { return false }
        return try await native.devTools.evaluate("document.hasFocus() && document.elementFromPoint(60,36)?.id==='retirementActivate'") as? Bool == true
      }
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await native.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      let activated = try await native.devTools.evaluate("""
        ({trusted:globalThis.retirementClick?.trusted===true,
          primary:globalThis.retirementClick?.button===0,
          sticky:navigator.userActivation.hasBeenActive,
          focused:document.hasFocus(), guarded:typeof window.onbeforeunload==='function',
          target:document.elementFromPoint(60,36)?.id, viewport:[innerWidth,innerHeight]})
        """) as? [String: Any] ?? [:]
      fputs("Native retirement activation id=\(target.id): \(activated)\n", stderr)
      return ["trusted", "primary", "sticky", "focused", "guarded"].allSatisfy { activated[$0] as? Bool == true }
    }
    do {
      try require(try await prepareGuardedDocument(page, native: browser, draft: "model-first retirement draft"),
        "modelFirstRetirementUsesActuallyActivatedDocument")
      // Deliberately exercise the production layout-driven retirement route.
      // Ordinary requestCloseTab already negotiates before mutating Core.
      owner.store.closeTab(id: tab.id)
      owner.scheduleLayout()
      try await wait { ownedSheet() != nil }
      try require(owner.store.tab(tab.id)?.isClosed == false,
        "modelFirstRetirementRestoresAuthorityBeforeCloseNegotiation")
      try require(application.engine.pages[tab.id] === page && page.browser === browser && !browser.isClosed,
        "modelFirstRetirementRetainsExactNativeDocument")
      guard let sheet = ownedSheet() else { throw ShortcutError("Missing retirement sheet") }
      window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      try await wait { application.webDialogs.pendingRequestCount(for: page) == 0 && window.attachedSheet == nil }
      let draft = try await browser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(draft == "model-first retirement draft" && owner.store.tab(tab.id)?.url == address.absoluteString,
        "modelFirstRetirementVetoPreservesDraftAndSavedURL")
      try require(!owner.store.state.archive.contains(where: { $0.id == tab.id }),
        "modelFirstRetirementVetoRemovesOnlyDuplicateArchiveRecord")
      // Each browser roundtrip lets queued layout retirements run. A repeated
      // prompt or disconnected callback is observable without arbitrary delay.
      for _ in 0..<2 {
        owner.layoutPages()
        _ = try await browser.devTools.evaluate("document.readyState")
      }
      try require(application.webDialogs.pendingRequestCount(for: page) == 0 && ownedSheet() == nil,
        "retirementVetoDoesNotRestartOnSubsequentLayouts")
      close = Task { @MainActor in await owner.requestCloseTab(tab.id) }
      try await wait { ownedSheet() != nil }
      guard let accepted = ownedSheet() else { throw ShortcutError("Missing final retirement sheet") }
      window.endSheet(accepted, returnCode: .alertFirstButtonReturn)
      let closed = await close!.value; close = nil
      try require(closed && browser.isClosed && application.engine.pages[tab.id] == nil,
        "recoveredDocumentCanCloseAfterExplicitLeave")
      try require(owner.store.state.archive.filter { $0.id == tab.id }.count == 1,
        "acceptedRecoveredCloseArchivesExactlyOnce")
      let restoredTab = try owner.store.restoreSessionTabDurably(id: tab.id)
      let restored = try await owner.ensurePageReady(restoredTab)
      try await application.navigation.waitForRestore(restored)
      let restoredBrowser = try await restored.ready()
      try await wait {
        guard !restored.isLoading else { return false }
        return try await restoredBrowser.devTools.evaluate("document.getElementById('retained')?.value") as? String
          == "model-first retirement draft"
      }
      try require(restored.url == address, "recoveredCloseSavedActualFormStateForSessionRestore")

      @MainActor func retainedCase(peek: Bool) async throws {
        let home = url.appendingPathComponent(peek ? "retirement-peek-source" : "retirement-pin-home")
        guard let sourceTab = owner.store.createTab(address: home.absoluteString) else {
          throw ShortcutError("No retained retirement source")
        }
        if !peek { owner.store.togglePin(id: sourceTab.id) }
        let source = try await owner.ensurePageReady(try XCTab(owner.store.tab(sourceTab.id)))
        try await application.navigation.waitForRestore(source)
        try await wait { !source.isLoading && source.url == home }
        let target: ChromiumPage
        if peek {
          _ = try await owner.requestOpenPeek(sourceTabID: sourceTab.id, sourcePage: source, url: address)
          try owner.store.updatePeekDurably(tabID: sourceTab.id) { $0.autoDiscardable = false; $0.isMuted = true }
          target = try await owner.ensurePageReady(try XCTab(owner.store.document(id: "peek:" + sourceTab.id)))
          try await application.navigation.waitForRestore(target)
        } else {
          owner.navigate(address.absoluteString)
          target = source
        }
        let native = try await target.ready()
        guard try await prepareGuardedDocument(target, native: native, draft: "retained model-first draft") else {
          throw ShortcutError("Retained retirement source did not receive a trusted primary click and sticky activation")
        }
        owner.layoutPages()
        let saved = try XCTab(owner.store.tab(sourceTab.id))
        if peek { owner.store.closePeek(tabID: sourceTab.id) }
        else { owner.store.closeTab(id: sourceTab.id) }
        owner.scheduleLayout()
        @MainActor func sheet() -> NSWindow? {
          guard let sheet = window.attachedSheet,
            sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:beforeunload:") == true,
            application.webDialogs.owns(sheet, page: target) else { return nil }
          return sheet
        }
        try await wait { sheet() != nil }
        guard let stay = sheet() else { throw ShortcutError("Missing retained beforeunload") }
        window.endSheet(stay, returnCode: .alertSecondButtonReturn)
        try await wait { application.webDialogs.pendingRequestCount(for: target) == 0 && window.attachedSheet == nil }
        let current = try XCTab(owner.store.tab(sourceTab.id))
        let draft = try await native.devTools.evaluate("document.getElementById('retained').value") as? String
        try require(application.engine.pages[target.id] === target && target.browser === native
          && draft == "retained model-first draft", peek ? "retiringPeekStayRetainsSameNativeDraft" : "retiringPinStayRetainsSameNativeDraft")
        try require(peek ? current.peek == saved.peek
          : (!current.isClosed && current.url == saved.url && current.savedURL == home.absoluteString && current.navigation == saved.navigation),
          peek ? "retiringPeekRecoversFullSavedMetadata" : "retiringPinRecoversCurrentHistoryWithoutChangingHome")
        close = Task { @MainActor in await owner.requestCloseTab(target.id) }
        try await wait { sheet() != nil }
        guard let leave = sheet() else { throw ShortcutError("Missing retained final close") }
        window.endSheet(leave, returnCode: .alertFirstButtonReturn)
        let accepted = await close!.value; close = nil
        try require(accepted && native.isClosed, peek ? "recoveredPeekClosesOnExplicitLeave" : "recoveredPinClosesOnExplicitLeave")
        try require(peek ? owner.store.tab(sourceTab.id)?.peek == nil
          : (owner.store.tab(sourceTab.id)?.isClosed == true && owner.store.tab(sourceTab.id)?.url == home.absoluteString),
          peek ? "recoveredPeekLeaveKeepsItsSource" : "recoveredPinLeaveRetainsPinnedHome")
      }
      try await retainedCase(peek: false)
      try await retainedCase(peek: true)
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      return checks
    } catch {
      close?.cancel()
      let fixturePages = application.engine.pages.values.filter { $0.ownerWindowID == owner.windowContext.id }
      if let sheet = window.attachedSheet,
        fixturePages.contains(where: { application.webDialogs.owns(sheet, page: $0) }) {
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      }
      _ = await close?.value
      for page in fixturePages {
        if let browser = page.browser, !browser.isClosed { _ = try? await browser.devTools.evaluate("window.onbeforeunload=null") }
      }
      _ = await owner.requestCloseWindow()
      throw error
    }
  }
  private static func XCTab(_ value: BrowserTab?) throws -> BrowserTab {
    guard let value else { throw ShortcutError("The retirement fixture lost its exact model tab") }
    return value
  }
}
