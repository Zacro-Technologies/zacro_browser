import AppKit
import Foundation
import ZacroChromium
import ZacroCore
import ZacroServices

/// Uses real renderer state and owned sheets in the disposable custom-runtime
/// fixture. Ending a sheet here is not evidence of physical desktop input.
@MainActor
enum NativeNavigationCloseAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native navigation close check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Navigation close acceptance failed: " + name) }
      checks.append(name)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner,
      let window = owner.window else { throw ShortcutError("No navigation close fixture owner") }
    owner.actions.palette = false
    let formURL = url.appendingPathComponent("native-history-form")
    guard let tab = owner.store.createTab(address: formURL.absoluteString) else {
      throw ShortcutError("No navigation close fixture tab")
    }
    let page = try await owner.ensurePageReady(tab)
    try await application.navigation.waitForRestore(page)
    let browser = try await page.ready()
    var pendingClose: Task<Bool, Never>?
    var overlappingTabClose: Task<Bool, Never>?
    var phase = "load-owned-form", method = "Runtime.evaluate"
    var historyBatch: Int?
    var pushedHistoryEntries = 0
    func setForm(_ expression: String) async throws {
      _ = try await browser.devTools.evaluate("(() => { const f=document.getElementById('retained'); f.value=\(expression); f.dispatchEvent(new Event('input',{bubbles:true})); f.dispatchEvent(new Event('change',{bubbles:true})); })()")
    }
    func wait(_ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Navigation close acceptance timed out")
    }
    let vault = NativeNavigationStateStore(directory: application.engine.dataDirectory) { id in
      await MainActor.run {
        application.store.state.profiles.first(where: { $0.id == id })
          .map { AIProfileScope(id: $0.id, isPrivate: $0.isPrivate) }
      }
    }
    do {
      try await wait {
        guard !page.isLoading, owner.store.document(id: page.id)?.url == formURL.absoluteString else { return false }
        return (try await browser.devTools.evaluate("!!document.getElementById('retained')") as? Bool) == true
      }
      // Preserve the full real history workload while allowing the native
      // address/model callbacks between renderer tasks. A single 120-push
      // script can exceed Runtime.evaluate's ordinary deadline under the full
      // suite's retained-document load before the capture checks even begin.
      phase = "seed-real-history"; method = "Runtime.evaluate"
      for start in stride(from: 0, to: 120, by: 20) {
        historyBatch = start / 20 + 1
        let end = start + 20
        let result = try await browser.devTools.evaluate("""
          (() => {
            let pushed=0;
            for(let i=\(start);i<\(end);i++) { history.pushState({},'', '?native-close-step='+i); pushed++; }
            return {pushed,lastStep:new URL(location.href).searchParams.get('native-close-step')};
          })()
          """) as? [String: Any]
        guard result?["pushed"] as? Int == 20,
          result?["lastStep"] as? String == String(end - 1) else {
          throw ShortcutError("The real history batch did not complete all of its entries.")
        }
        pushedHistoryEntries += 20
      }
      historyBatch = nil
      phase = "replace-final-history-address"
      _ = try await browser.devTools.evaluate("history.replaceState({},'',location.pathname)")
      phase = "observe-final-native-and-core-address"; method = "native/Core address observation"
      try await wait { page.url == formURL && owner.store.document(id: page.id)?.url == formURL.absoluteString }
      phase = "set-initial-draft"; method = "Runtime.evaluate"
      try await setForm("'saved draft'")
      phase = "capture-initial-encrypted-history"; method = "navigation.capture"
      try require(await application.navigation.capture(page, tabID: tab.id, peek: false),
        "navigationCloseFixtureSavesRealFormState")
      phase = "read-initial-encrypted-history"; method = "vault.read"
      let saved = try await vault.read(profileID: page.profileID, tabID: tab.id, address: formURL.absoluteString)
      try require(saved != nil, "navigationCloseFixtureHasEncryptedSnapshot")
      let retainedHistory = owner.store.document(id: page.id)?.navigation ?? []
      try require(retainedHistory.count > 1 && retainedHistory.count <= 100
        && retainedHistory.last?.url == formURL.absoluteString,
        "navigationCloseRetainsBoundedLiveAddressHistory")
      phase = "concurrent-encrypted-captures"; method = "navigation.capture"
      let firstCapture = Task { await application.navigation.capture(page, tabID: tab.id, peek: false) }
      let secondCapture = Task { await application.navigation.capture(page, tabID: tab.id, peek: false) }
      let firstCaptured = await firstCapture.value, secondCaptured = await secondCapture.value
      try require(firstCaptured && secondCaptured, "concurrentNavigationCapturesShareOneNativeOperation")
      phase = "set-oversized-draft"; method = "Runtime.evaluate"
      try await setForm("'oversized-form-'.repeat(600000)")
      phase = "close-review-keep-open"; method = "requestCloseTab/owned-sheet observation"
      pendingClose = Task { await owner.requestCloseTab(tab.id) }
      try await wait { window.attachedSheet?.identifier?.rawValue == "ZacroNavigationSaveFailure" }
      try require(application.engine.pages[page.id] === page && page.browser?.isClosed == false,
        "navigationSaveFailureRetainsLiveDocumentWhileChoosing")
      guard let firstSheet = window.attachedSheet else { throw ShortcutError("Missing navigation close sheet") }
      window.endSheet(firstSheet, returnCode: .alertFirstButtonReturn)
      let kept = await pendingClose!.value; pendingClose = nil
      try require(!kept && application.engine.pages[page.id] === page,
        "navigationSaveFailureKeepOpenCancelsTabClosure")
      phase = "read-retained-oversized-draft"; method = "Runtime.evaluate"
      let retained = try await browser.devTools.evaluate("document.getElementById('retained').value.length") as? Int
      try require(retained == "oversized-form-".count * 600000,
        "navigationSaveFailureKeepOpenPreservesOversizedDraft")

      phase = "capture-oversized-issue"; method = "navigation.captureIssueForClose"
      guard let stale = await application.navigation.captureIssueForClose(page, tabID: tab.id, peek: false) else {
        throw ShortcutError("Oversized history did not report a capture issue")
      }
      phase = "shrink-draft"; method = "Runtime.evaluate"
      try await setForm("'newer saved draft'")
      phase = "capture-shrunk-draft"; method = "navigation.capture"
      try require(await application.navigation.capture(page, tabID: tab.id, peek: false),
        "navigationCaptureRecoversAfterOversizedFormShrinks")
      phase = "reject-stale-fallback"; method = "navigation.continueWithoutPageState/vault.read"
      let staleAccepted = try await application.navigation.continueWithoutPageState([stale])
      let newer = try await vault.read(profileID: page.profileID, tabID: tab.id, address: formURL.absoluteString)
      try require(!staleAccepted && newer != nil && newer != saved,
        "staleNavigationFallbackCannotEraseNewerSnapshot")

      phase = "set-overlapping-close-draft"; method = "Runtime.evaluate"
      try await setForm("'oversized-form-'.repeat(600000)")
      phase = "overlapping-tab-and-window-close"; method = "requestCloseTab/requestCloseWindow/owned-sheet observation"
      overlappingTabClose = Task { await owner.requestCloseTab(tab.id) }
      try await wait { window.attachedSheet?.identifier?.rawValue == "ZacroNavigationSaveFailure" }
      let olderTabSheet = window.attachedSheet
      pendingClose = Task { await owner.requestCloseWindow() }
      let olderTabClosed = await overlappingTabClose!.value; overlappingTabClose = nil
      try require(!olderTabClosed, "windowCloseSupersedesOlderTabCloseReview")
      try await wait {
        window.attachedSheet?.identifier?.rawValue == "ZacroNavigationSaveFailure"
          && window.attachedSheet !== olderTabSheet && owner.windowContext.isClosing
      }
      try require(owner.windowContext.isClosing,
        "olderTabVetoCannotCancelNewerWindowCloseAttempt")
      guard let finalSheet = window.attachedSheet else { throw ShortcutError("Missing window close sheet") }
      window.endSheet(finalSheet, returnCode: .alertSecondButtonReturn)
      let closed = await pendingClose!.value; pendingClose = nil
      try require(closed && !owner.windowContext.isOpen,
        "navigationSaveFailureAllowsExplicitAddressesOnlyWindowClose")
      phase = "read-address-only-fallback"; method = "vault.read"
      let removed = try await vault.read(profileID: page.profileID, tabID: tab.id, address: formURL.absoluteString)
      try require(removed == nil, "navigationFallbackDurablyRemovesOlderEncryptedSnapshot")
      phase = "reopen-address-only-session"; method = "reopenWindow/ensurePageReady/waitForRestore"
      let restoredOwner = try application.reopenWindow(id: owner.windowContext.id)
      guard let restoredTab = restoredOwner.store.document(id: tab.id) else {
        throw ShortcutError("Navigation fallback lost the saved tab")
      }
      let restored = try await restoredOwner.ensurePageReady(restoredTab)
      try await application.navigation.waitForRestore(restored)
      let restoredBrowser = try await restored.ready()
      phase = "observe-restored-empty-form"; method = "Runtime.evaluate"
      try await wait {
        guard !restored.isLoading else { return false }
        return (try await restoredBrowser.devTools.evaluate(
          "document.getElementById('retained')?.value === ''") as? Bool) == true
      }
      try require(restored.url == formURL, "navigationFallbackReopensAddressWithoutStaleFormContents")
      phase = "close-restored-owner"; method = "requestCloseWindow"
      try require(await restoredOwner.requestCloseWindow(), "navigationFallbackFixtureClosesCleanly")
      originalOwner.windowContext.show()
      return checks
    } catch {
      fputs("Native navigation close fixture failure phase=\(phase) method=\(method) historyBatch=\(historyBatch.map(String.init) ?? "none") completedPushes=\(pushedHistoryEntries) browser=\(browser.id) nativeLoading=\(page.isLoading) nativeURL=\(String((page.url?.absoluteString ?? "nil").prefix(512))) error=\(String(describing: error).prefix(1_024))\n", stderr)
      pendingClose?.cancel()
      overlappingTabClose?.cancel()
      if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
      _ = await pendingClose?.value
      _ = await overlappingTabClose?.value
      if !browser.isClosed { try? await setForm("''") }
      _ = await owner.requestCloseWindow()
      throw error
    }
  }
}
