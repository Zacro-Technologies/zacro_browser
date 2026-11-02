import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Dispatches Chromium input only into a disposable loopback fixture. This
/// exercises real trusted DOM events and isolated bindings, not desktop input,
/// physical trackpad delivery, or visual animation fidelity.
@MainActor
enum NativePeekLinkRuntimeAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Trusted Peek input requires the disposable loopback acceptance fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native Peek link check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Peek link acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Peek link acceptance timed out: " + name)
    }
    func literal(_ value: String) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let originalDestinations = Dictionary(uniqueKeysWithValues: originalOwner.store.state.tabs.map {
      ($0.id, $0.peek?.url ?? "")
    })
    func originalWindowUnchanged() -> Bool {
      originalDestinations.allSatisfy { id, address in
        guard let tab = originalOwner.store.tab(id) else { return false }
        return (tab.peek?.url ?? "") == address
      }
    }
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner else {
      throw ShortcutError("No trusted Peek fixture window")
    }
    owner.actions.palette = false
    let documentStartCapture = application.extensionBrowser.enabled
    let sourceURL = url.appendingPathComponent(documentStartCapture ? "native-peek-first-inline" : "native-peek-link-source")
    let destinationURL = url.appendingPathComponent("native-peek-link-target")
    guard let tab = owner.store.createTab(address: sourceURL.absoluteString) else {
      _ = await owner.requestCloseWindow()
      throw ShortcutError("No trusted Peek fixture tab")
    }
    do {
      let page = try await owner.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready()
      try await wait("source document and isolated world") {
        !page.isLoading && page.url == sourceURL && application.peekLinks.isArmed(page)
      }
      try require(true, "peekTrustedFixtureArmsActualIsolatedMainFrame")

      func installDocument(destination: URL? = nil, draft: String = "retained Peek source draft") async throws {
        let address = try literal((destination ?? destinationURL).absoluteString), value = try literal(draft)
        _ = try await browser.devTools.evaluate("""
          (() => {
            document.body.innerHTML = '<input id="peekSourceDraft"><a id="peekFixtureLink">Open preview</a>';
            document.body.style.cssText = 'margin:0;min-height:300px;background:white';
            const field = document.getElementById('peekSourceDraft');
            field.value = \(value); field.style.cssText = 'position:absolute;left:24px;top:14px;width:220px;height:24px';
            const link = document.getElementById('peekFixtureLink');
            link.href = \(address);
            link.style.cssText = 'position:absolute;left:24px;top:64px;display:block;width:180px;height:44px;line-height:44px';
            // Prevent synthetic clicks from navigating the fixture. The real
            // isolated adapter must independently reject their untrusted flag.
            link.addEventListener('click', event => { if (!event.isTrusted) event.preventDefault(); });
            globalThis.__peekFixtureDocument = 'installed';
            return true;
          })()
          """)
      }
      func click(modifiers: Int) async throws {
        guard let point = try await browser.devTools.evaluate("""
          (() => { const r=document.getElementById('peekFixtureLink').getBoundingClientRect();
            return {x:r.left+r.width/2,y:r.top+r.height/2}; })()
          """) as? [String: Any], let x = point["x"] as? Double, let y = point["y"] as? Double else {
          throw ShortcutError("Missing trusted Peek anchor geometry")
        }
        _ = try await browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1,
          "clickCount": 1, "modifiers": modifiers,
        ])
        _ = try await browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0,
          "clickCount": 1, "modifiers": modifiers,
        ])
      }
      func waitForPreview(_ destination: URL) async throws {
        try await wait("trusted click creates the correct retained Peek") {
          if !originalWindowUnchanged() {
            try require(false, "peekTrustedClickCannotMutateAnotherWindowDestination")
          }
          guard owner.store.tab(tab.id)?.peek?.url == destination.absoluteString,
            let preview = application.engine.pages["peek:" + tab.id] else { return false }
          return preview.url == destination && !preview.isLoading && owner.activePage === preview
        }
      }
      func retainedSource(_ draft: String) async throws -> Bool {
        let value = try await browser.devTools.evaluate("document.getElementById('peekSourceDraft')?.value") as? String
        return application.engine.pages[tab.id] === page && page.browser === browser
          && !browser.isClosed && page.url == sourceURL && owner.store.tab(tab.id)?.url == sourceURL.absoluteString
          && value == draft && page.nativeWindow?.isVisible == true
      }
      func closePreview() async throws {
        guard await owner.requestCloseTab("peek:" + tab.id) else { throw ShortcutError("Could not close fixture Peek") }
        try await wait("source adapter rearms after Peek closure") {
          owner.store.tab(tab.id)?.peek == nil && owner.activePage === page && application.peekLinks.isArmed(page)
        }
      }

      // The server installs its competing capture handler in the first parser
      // script, before body markup. A late world injection cannot pass this:
      // the site's stopImmediatePropagation would prevent the Peek listener.
      if documentStartCapture {
        let inlineCalls = try await browser.devTools.evaluate("globalThis.__peekFirstInlineCalls") as? Int
        try require(inlineCalls == 0, "peekFirstInlineCaptureFixtureLoadedBeforeBody")
        try await click(modifiers: 8)
        let intercepted = try await browser.devTools.evaluate("globalThis.__peekFirstInlineCalls") as? Int
        try require(intercepted == 0, "peekCapturePreemptsFirstInlineSiteHandler")
        try await waitForPreview(destinationURL)
        try require(originalWindowUnchanged(), "peekTrustedClickCannotMutateAnotherWindowDestination")
        let handledBySite = try await browser.devTools.evaluate("globalThis.__peekFirstInlineCalls") as? Int
        let retainedFirstDocument = try await retainedSource("first-inline retained draft")
        try require(handledBySite == 0 && retainedFirstDocument,
          "peekDocumentStartCapturePrecedesFirstInlineSiteHandler")
        try await closePreview()
      }

      try await installDocument()
      let isolated = try await browser.devTools.evaluate("""
        !Object.getOwnPropertyNames(globalThis).some(key => key.startsWith('__zacroPeek_') || key === '__zacroPeekState')
        """) as? Bool
      try require(isolated == true, "peekBindingAndStateAreAbsentFromPageMainWorld")
      _ = try await browser.devTools.evaluate("""
        document.getElementById('peekFixtureLink').dispatchEvent(new MouseEvent('click',
          {bubbles:true,cancelable:true,button:0,shiftKey:true,clientX:100,clientY:80})); true
        """)
      // A bounded quiet period verifies that the asynchronous native dispatch
      // did not create a preview after the untrusted event finished.
      try await Task.sleep(for: .milliseconds(180))
      try require(owner.store.tab(tab.id)?.peek == nil && page.url == sourceURL,
        "peekSyntheticPageClickCannotInvokeNativePreview")

      try await click(modifiers: 8) // DevTools Input: Shift.
      try await waitForPreview(destinationURL)
      try require(try await retainedSource("retained Peek source draft"), "peekTrustedShiftRetainsSourceDocumentAndDraft")
      try await closePreview()
      try await click(modifiers: 1) // DevTools Input: Alt.
      try await waitForPreview(destinationURL)
      try require(try await retainedSource("retained Peek source draft"), "peekTrustedAltRetainsSourceDocumentAndDraft")
      try await closePreview()

      // A real navigation replaces the execution context. The original
      // listener cannot remain the authority for the replacement document.
      page.reload()
      try await wait("replacement document and isolated context") {
        guard !page.isLoading, page.url == sourceURL, application.peekLinks.isArmed(page) else { return false }
        return (try await browser.devTools.evaluate("typeof globalThis.__peekFixtureDocument === 'undefined'") as? Bool) == true
      }
      try await installDocument(draft: "replacement source draft")
      try await click(modifiers: 8)
      try await waitForPreview(destinationURL)
      try require(try await retainedSource("replacement source draft"), "peekTrustedLinkRearmsAfterActualDocumentReload")
      try await closePreview()

      // Dispatch to the visible, inactive pane without relying on AppKit focus
      // events. Root must select that source before presenting its preview.
      guard let other = owner.store.createTab(address: url.appendingPathComponent("native-peek-other-pane").absoluteString) else {
        throw ShortcutError("No split Peek fixture tab")
      }
      let otherPage = try await owner.ensurePageReady(other)
      try await application.navigation.waitForRestore(otherPage)
      owner.store.setSplit(left: tab.id, right: other.id)
      try owner.store.selectDocumentDurably(id: other.id)
      owner.layoutPages()
      try await wait("inactive split source is visible and armed") {
        !otherPage.isLoading && owner.activePage === otherPage && application.peekLinks.isArmed(page)
      }
      try await click(modifiers: 8)
      try await waitForPreview(destinationURL)
      let retainedSplitSource = try await retainedSource("replacement source draft")
      try require(owner.store.state.activeTabID == tab.id && owner.store.split(for: tab.id) != nil
        && retainedSplitSource, "peekTrustedInactiveSplitClickSelectsItsSource")
      try await closePreview()
      owner.store.unsplit(tabID: tab.id)

      var external = URLComponents(url: destinationURL, resolvingAgainstBaseURL: false)
      external?.host = "localhost"
      guard let externalURL = external?.url else { throw ShortcutError("No loopback external-host fixture") }
      try owner.store.commit { state in
        guard let index = state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        state.tabs[index].isPinned = true
        state.tabs[index].savedURL = sourceURL.absoluteString
      }
      try await installDocument(destination: externalURL, draft: "saved pin source draft")
      try await wait("saved pin policy is armed") { application.peekLinks.isArmed(page) }
      try await click(modifiers: 0)
      try await waitForPreview(externalURL)
      let retainedPinSource = try await retainedSource("saved pin source draft")
      try require(owner.store.tab(tab.id)?.savedURL == sourceURL.absoluteString
        && retainedPinSource, "peekTrustedSavedPinExternalLinkKeepsSavedAddressAndDraft")
      try await closePreview()
      try require(await owner.requestCloseWindow(), "peekTrustedFixtureWindowClosesCleanly")
      try require(!application.peekLinks.isArmed(page), "peekClosedDocumentRevokesIsolatedLinkAuthority")
      originalOwner.windowContext.show()
      return checks
    } catch {
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      throw error
    }
  }
}
