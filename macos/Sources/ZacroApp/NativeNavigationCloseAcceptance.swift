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
      _ = try await browser.devTools.evaluate("(() => { for(let i=0;i<120;i++) history.pushState({},'', '?native-close-step='+i); history.replaceState({},'',location.pathname); })()")
      try await wait { page.url == formURL && owner.store.document(id: page.id)?.url == formURL.absoluteString }
      try await setForm("'saved draft'")
      try require(await application.navigation.capture(page, tabID: tab.id, peek: false),
        "navigationCloseFixtureSavesRealFormState")
      let saved = try await vault.read(profileID: page.profileID, tabID: tab.id, address: formURL.absoluteString)
      try require(saved != nil, "navigationCloseFixtureHasEncryptedSnapshot")
      let retainedHistory = owner.store.document(id: page.id)?.navigation ?? []
      try require(retainedHistory.count > 1 && retainedHistory.count <= 100
        && retainedHistory.last?.url == formURL.absoluteString,
        "navigationCloseRetainsBoundedLiveAddressHistory")
      let firstCapture = Task { await application.navigation.capture(page, tabID: tab.id, peek: false) }
      let secondCapture = Task { await application.navigation.capture(page, tabID: tab.id, peek: false) }
      let firstCaptured = await firstCapture.value, secondCaptured = await secondCapture.value
      try require(firstCaptured && secondCaptured, "concurrentNavigationCapturesShareOneNativeOperation")
      try await setForm("'oversized-form-'.repeat(600000)")
      pendingClose = Task { await owner.requestCloseTab(tab.id) }
      try await wait { window.attachedSheet?.identifier?.rawValue == "ZacroNavigationSaveFailure" }
      try require(application.engine.pages[page.id] === page && page.browser?.isClosed == false,
        "navigationSaveFailureRetainsLiveDocumentWhileChoosing")
      guard let firstSheet = window.attachedSheet else { throw ShortcutError("Missing navigation close sheet") }
      window.endSheet(firstSheet, returnCode: .alertFirstButtonReturn)
      let kept = await pendingClose!.value; pendingClose = nil
      try require(!kept && application.engine.pages[page.id] === page,
        "navigationSaveFailureKeepOpenCancelsTabClosure")
      let retained = try await browser.devTools.evaluate("document.getElementById('retained').value.length") as? Int
      try require(retained == "oversized-form-".count * 600000,
        "navigationSaveFailureKeepOpenPreservesOversizedDraft")

      guard let stale = await application.navigation.captureIssueForClose(page, tabID: tab.id, peek: false) else {
        throw ShortcutError("Oversized history did not report a capture issue")
      }
      try await setForm("'newer saved draft'")
      try require(await application.navigation.capture(page, tabID: tab.id, peek: false),
        "navigationCaptureRecoversAfterOversizedFormShrinks")
      let staleAccepted = try await application.navigation.continueWithoutPageState([stale])
      let newer = try await vault.read(profileID: page.profileID, tabID: tab.id, address: formURL.absoluteString)
      try require(!staleAccepted && newer != nil && newer != saved,
        "staleNavigationFallbackCannotEraseNewerSnapshot")

      try await setForm("'oversized-form-'.repeat(600000)")
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
      let removed = try await vault.read(profileID: page.profileID, tabID: tab.id, address: formURL.absoluteString)
      try require(removed == nil, "navigationFallbackDurablyRemovesOlderEncryptedSnapshot")
      let restoredOwner = try application.reopenWindow(id: owner.windowContext.id)
      guard let restoredTab = restoredOwner.store.document(id: tab.id) else {
        throw ShortcutError("Navigation fallback lost the saved tab")
      }
      let restored = try await restoredOwner.ensurePageReady(restoredTab)
      try await application.navigation.waitForRestore(restored)
      let restoredBrowser = try await restored.ready()
      try await wait {
        guard !restored.isLoading else { return false }
        return (try await restoredBrowser.devTools.evaluate(
          "document.getElementById('retained')?.value === ''") as? Bool) == true
      }
      try require(restored.url == formURL, "navigationFallbackReopensAddressWithoutStaleFormContents")
      try require(await restoredOwner.requestCloseWindow(), "navigationFallbackFixtureClosesCleanly")
      originalOwner.windowContext.show()
      return checks
    } catch {
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
