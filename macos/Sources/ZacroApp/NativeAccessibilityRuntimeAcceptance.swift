import AppKit
import Foundation
import ZacroChromium

/// A fresh-process causal check, separate from every application/AX render
/// fixture. Only production show/hide requests accessibility for the positive
/// document. The never-shown control must stay unrequested and tree-free.
@MainActor enum NativeAccessibilityRuntimeAcceptance {
  static func run(engine: ChromiumEngine, url: URL) async throws -> [String: Bool] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-accessibility-acceptance"),
      !CommandLine.arguments.contains("--native-integration-acceptance"),
      !CommandLine.arguments.contains("--native-ui-review"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil else {
      throw Failure("Scoped accessibility requires its fresh, isolated loopback launch.")
    }
    guard try await engine.nativeCapabilities().browserProtocol else {
      throw Failure("Scoped accessibility requires the custom native runtime; stock is not an accepted substitute.")
    }
    var checks: [String: Bool] = [:]
    var owned: [ChromiumPage] = []
    func record(_ value: Bool, _ name: String) throws {
      fputs("Native scoped accessibility check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw Failure(name) }
      checks[name] = true
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw Failure("Timed out during scoped accessibility: " + phase)
    }
    func create(_ id: String) async throws -> (ChromiumPage, CefBrowser) {
      let page = engine.page(id: id, profileID: "scoped-accessibility", isPrivate: false, url: url)
      owned.append(page)
      let browser = try await page.ready()
      try await wait("never-shown fixture document load") {
        guard !page.isLoading, page.url == url else { return false }
        return try await browser.devTools.evaluate("document.readyState==='complete'") as? Bool == true
      }
      return (page, browser)
    }
    func closeOwned() async {
      for page in owned { page.close() }
      let deadline = Date().addingTimeInterval(5)
      while owned.contains(where: { engine.pages[$0.id] === $0 }), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(40))
      }
    }
    do {
      // This passive child getter must be the very first accessibility access
      // in this launch. No NSWindow/NSApplication AX enumeration or renderer
      // role getter may precede it, as those can enable a global mode.
      let (control, controlBrowser) = try await create("accessibility-never-shown")
      let controlNativeID = controlBrowser.id
      try record(try NativeAccessibilityAcceptance.checkUnshownControl(control),
        "scopedAXControlHasNoTreeBeforeAnyAccessibilityAccess")

      let (positive, browser) = try await create("accessibility-shown")
      let nativeID = browser.id
      try record(browser.isChromeRuntime && controlBrowser.isChromeRuntime && nativeID != controlNativeID,
        "scopedAXUsesTwoRealIndependentChromeDocuments")
      try record(try NativeAccessibilityAcceptance.checkUnshownControl(positive),
        "scopedAXPositiveStartsWithoutAnAccessibilityRequest")
      _ = try await browser.devTools.evaluate("""
        (() => {
          document.body.innerHTML='<h1>Scoped accessibility sentinel</h1><label for="scopedAXDraft">Retained draft</label><input id="scopedAXDraft">';
          document.getElementById('scopedAXDraft').value='retained scoped accessibility value';
          return true;
        })()
        """)
      let frame = CGRect(x: 20, y: 20, width: 900, height: 650)
      engine.showWindow()
      positive.show(frame: frame)
      let retained = try await NativeAccessibilityAcceptance.checkRetainedTree(positive,
        expectedText: "Scoped accessibility sentinel", inputID: "scopedAXDraft",
        expectedValue: "retained scoped accessibility value") {
          try record(try NativeAccessibilityAcceptance.checkUnshownControl(control),
            "scopedAXPositiveTreeDoesNotEnableNeverShownControl")
          positive.hide()
          try await wait("native positive document hidden") { positive.nativeWindow?.isVisible == false }
          _ = try await browser.devTools.evaluate("document.getElementById('scopedAXDraft').value")
          positive.show(frame: frame)
          try await wait("same native positive document reshown") { positive.nativeWindow?.isVisible == true }
        }
      for (name, value) in retained { try record(value, name) }
      try record(try NativeAccessibilityAcceptance.checkUnshownControl(control),
        "scopedAXControlRemainsTreeFreeAfterRetainedVisibilityCycle")
      try record(positive.browser === browser && browser.id == nativeID
        && control.browser === controlBrowser && controlBrowser.id == controlNativeID,
        "scopedAXPositiveAndControlKeepTheirOriginalNativeDocuments")
      await closeOwned()
      try record(owned.allSatisfy { engine.pages[$0.id] == nil && $0.browser == nil },
        "scopedAXFixtureDocumentsCloseCleanly")
      return checks
    } catch {
      await closeOwned()
      throw error
    }
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
