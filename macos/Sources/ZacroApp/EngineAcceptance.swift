import AppKit
import CryptoKit
import Foundation
import ZacroChromium

/// Explicit disposable-profile acceptance mode; never used in normal browsing.
@MainActor
final class EngineAcceptance {
  private let engine: ChromiumEngine
  private var timer: Timer?
  private var stage = 0
  private var started = Date()
  private var pages: [ChromiumPage] = []
  private var task: Task<Void, Never>?
  private var finished = false
  private var checks: [String: Bool] = [:]
  private var capabilities: [String: Bool] = [:]
  private var popup: ChromiumPage?
  init(engine: ChromiumEngine) { self.engine = engine }
  func run(url: URL) {
    task = Task { @MainActor [self] in
      do {
        let probeStarted = Date()
        do { _ = try await engine.nativeCapabilities() }
        catch let error as CefDevToolsError where error.isUnsupportedMethod { /* Stock runtime. */ }
        try require(Date().timeIntervalSince(probeStarted) < 3, "coldRuntimeCapabilityProbe")
        startPages(url: url)
      } catch { finish(error: error.localizedDescription) }
    }
  }
  private func startPages(url: URL) {
    pages = [
      engine.page(id: "acceptance-a", profileID: "a", isPrivate: false, url: url),
      engine.page(id: "acceptance-b", profileID: "a", isPrivate: false, url: url),
      engine.page(id: "acceptance-isolated", profileID: "b", isPrivate: false, url: url),
      engine.page(id: "acceptance-private", profileID: "private", isPrivate: true, url: url),
    ]
    engine.showWindow()
    for (index, page) in pages.enumerated() {
      page.show(
        frame: CGRect(x: 224 + (index % 2) * 500, y: 4 + (index / 2) * 350, width: 494, height: 344)
      )
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }
  private func tick() {
    if Date().timeIntervalSince(started) > 40 {
      finish(error: "Timed out at stage \(stage)")
      return
    }
    switch stage {
    case 0:
      guard pages.allSatisfy({ !$0.isLoading && $0.title.contains("acceptance") }) else { return }
      guard Set(pages.compactMap { $0.browser?.id }).count == 4 else {
        finish(error: "Documents not independent")
        return
      }
      guard pages.allSatisfy({ $0.browser?.isChromeRuntime == true }) else {
        finish(error: "Not Chrome runtime")
        return
      }
      guard pages[0].browser?.profileCachePath == pages[1].browser?.profileCachePath,
        pages[0].browser?.profileCachePath != pages[2].browser?.profileCachePath,
        pages[3].browser?.profileCachePath == nil
      else {
        finish(error: "Profile context isolation failed")
        return
      }
      pages[0].show(frame: CGRect(x: 224, y: 4, width: 500, height: 700))
      pages[1].show(frame: CGRect(x: 730, y: 4, width: 500, height: 700))
      pages[0].browser?.executeJavaScript(
        "localStorage.setItem('zacro-acceptance','retained'); document.title='written';")
      stage = 1
    case 1:
      guard pages[0].title == "written" else { return }
      pages[0].hide()
      pages[1].browser?.executeJavaScript(
        "document.title=localStorage.getItem('zacro-acceptance')==='retained'?'shared-ok':'shared-fail'"
      )
      pages[2].browser?.executeJavaScript(
        "document.title=localStorage.getItem('zacro-acceptance')===null?'isolated-ok':'isolated-fail'"
      )
      pages[3].browser?.executeJavaScript(
        "document.title=localStorage.getItem('zacro-acceptance')===null?'private-ok':'private-fail'"
      )
      stage = 2
    case 2:
      guard pages[1].title == "shared-ok", pages[2].title == "isolated-ok",
        pages[3].title == "private-ok"
      else { return }
      pages[0].show(frame: CGRect(x: 224, y: 4, width: 500, height: 700))
      guard pages[0].title == "written" else {
        finish(error: "Hidden document lost state")
        return
      }
      stage = 3
      task = Task { [weak self] in
        guard let self else { return }
        do { try await self.checkNativeProtocols(); self.finish(error: nil) }
        catch { self.finish(error: error.localizedDescription) }
      }
    default: break
    }
  }
  private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  private func require(_ condition: Bool, _ name: String) throws {
    guard condition else { throw Failure(message: name) }; checks[name] = true
  }
  private func checkNativeProtocols() async throws {
    guard let page = pages.first, let browser = page.browser, let url = page.url else { throw Failure(message: "Missing test document") }
    let value = try await browser.devTools.evaluate("({number:42,text:'native-json'})") as? [String: Any]
    try require(value?["number"] as? Int == 42 && value?["text"] as? String == "native-json", "devToolsJSON")
    let icon = await browser.downloadFavicon(url.appendingPathComponent("favicon.svg"))
    try require(icon?.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]), "nativeSVGFaviconDecode")
    do {
      let nativeTab = try await browser.devTools.nativeTabTarget()
      capabilities["trustedNativeTabTarget"] = !nativeTab.isEmpty
    } catch { capabilities["trustedNativeTabTarget"] = false }
    do {
      _ = try await browser.devTools.evaluate("Promise.reject(new Error('expected-acceptance-error'))")
      throw Failure(message: "JavaScript rejection was reported as success")
    } catch let error as CefDevToolsError {
      try require(error.localizedDescription.contains("expected-acceptance-error"), "devToolsRejection")
    }
    _ = try await browser.devTools.evaluate("window.zacroMainWorldMarker='private-to-page'; document.body.innerHTML='<input id=retained value=initial><p>Local engine check</p>'; document.querySelector('input').value='unsaved-form-value'; null")
    let isolated = try await browser.devTools.evaluateIsolated("typeof window.zacroMainWorldMarker") as? String
    try require(isolated == "undefined", "isolatedWorld")
    let response = try await browser.fetchResource(url, maximumBytes: 1024 * 1024)
    try require(response.status == 200 && String(data: response.data, encoding: .utf8)?.contains("acceptance") == true, "profileResourceFetch")
    do {
      _ = try await browser.fetchResource(url, maximumBytes: 8)
      throw Failure(message: "Resource limit was ignored")
    } catch let error as CefResourceError {
      try require(error == .tooLarge, "resourceByteLimit")
    }
    let nativeID = browser.id
    let adopted = engine.adoptPage(fromID: page.id, toID: "acceptance-promoted")
    try require(adopted === page && adopted?.browser?.id == nativeID, "documentAdoptionIdentity")
    let draft = try await browser.devTools.evaluate("document.querySelector('input').value") as? String
    try require(draft == "unsaved-form-value", "documentAdoptionRetainsForm")
    page.onPopupCreated = { [weak self] child, _ in self?.popup = child }
    _ = try await browser.devTools.evaluate("window.zacroPopup=window.open('about:blank','zacro-acceptance-popup'); !!window.zacroPopup", userGesture: true)
    let deadline = Date().addingTimeInterval(5)
    while popup?.browser == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    guard let popup, let popupBrowser = popup.browser else { throw Failure(message: "Native popup was not adopted") }
    let opener = try await popupBrowser.devTools.evaluate("!!window.opener && window.opener.zacroMainWorldMarker==='private-to-page'") as? Bool
    try require(opener == true && popup.profileID == page.profileID, "popupRetainsOpener")
    let promotedWithPopup = engine.adoptPage(fromID: page.id, toID: "acceptance-promoted-with-popup")
    try require(promotedWithPopup === page && popup.openerID == page.id && page.browser?.id == nativeID,
      "documentAdoptionRemapsRetainedPopupOpener")
    _ = try await popupBrowser.devTools.evaluate("window.opener.zacroPopupReply='retained-callback'; null")
    let reply = try await browser.devTools.evaluate("window.zacroPopupReply") as? String
    try require(reply == "retained-callback", "popupCallback")
    let manager = ChromeExtensionManager(engine: engine, profileID: "a")
    let snapshot = try await manager.snapshot()
    try require(snapshot.extensions.allSatisfy { $0.id.count == 32 }, "nativeExtensionRegistry")
    let initial = engine.page(id: "acceptance-initial", profileID: "a", isPrivate: false, url: nil)
    let initialBrowser = try await initial.ready()
    try require(initialBrowser.id >= 0 && initial.browser === initialBrowser, "nativeDocumentReadiness")
    let initialAddress = initialBrowser.url
    let probeStarted = Date()
    do { _ = try await engine.nativeCapabilities() }
    catch let error as CefDevToolsError where error.isUnsupportedMethod { /* Stock runtime, explicitly unsupported. */ }
    try require(Date().timeIntervalSince(probeStarted) < 3 && initialBrowser.url == initialAddress,
      "freshDocumentCapabilityProbe")
    let firstLoadStarted = Date()
    initial.load(url)
    while (initialBrowser.url != url || initialBrowser.isLoading), Date().timeIntervalSince(firstLoadStarted) < 5 {
      try await Task.sleep(for: .milliseconds(30))
    }
    try require(initialBrowser.url == url && !initialBrowser.isLoading,
      "freshDocumentFirstLoad")
    if let native = try? await engine.nativeCapabilities(), native.navigationState {
      try await checkNavigationCommits(url: url)
    }
    var closeAttempts = 0
    popup.beforeClose = {
      closeAttempts += 1
      _ = try? await popupBrowser.devTools.evaluate("window.opener.zacroPopupReply")
      return closeAttempts > 1
    }
    popup.close()
    let cancellationDeadline = Date().addingTimeInterval(3)
    while closeAttempts == 0, Date() < cancellationDeadline { try await Task.sleep(for: .milliseconds(30)) }
    try await Task.sleep(for: .milliseconds(100))
    try require(closeAttempts == 1 && popup.browser === popupBrowser, "nativeClosePreparationCancellation")
    popup.close()
    let closeDeadline = Date().addingTimeInterval(3)
    while popup.browser != nil, Date() < closeDeadline { try await Task.sleep(for: .milliseconds(30)) }
    try require(popup.browser == nil && closeAttempts == 2, "nativeClosePreparationRetry")
    try await checkWindowContexts(page: page, browser: browser, url: url)
    // Keep a real native popup alive through multi-profile shutdown. Closing
    // it earlier missed the longer GUI sequence that exposed teardown hangs.
    self.popup = nil
    _ = try await browser.devTools.evaluate("window.zacroQuitPopup=window.open(location.href+'?retained-popup=1','zacro-quit-popup'); !!window.zacroQuitPopup", userGesture: true)
    let retainedDeadline = Date().addingTimeInterval(5)
    while (self.popup?.browser == nil || self.popup?.isLoading == true), Date() < retainedDeadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    try require(self.popup?.browser != nil, "retainedPopupForTermination")
  }

  private func checkNavigationCommits(url: URL) async throws {
    func fresh(_ name: String) async throws -> CefBrowser {
      let page = engine.page(id: "acceptance-commit-" + name, profileID: "a", isPrivate: false, url: nil)
      return try await page.ready()
    }
    func actualAddress(_ browser: CefBrowser) async throws -> String? {
      try await browser.devTools.evaluate("location.href") as? String
    }
    let loaded = try await fresh("load")
    try await loaded.loadAndWaitForNavigationCommit(url)
    try require(try await actualAddress(loaded) == url.absoluteString, "navigationLoadAwaitsPrimaryCommit")
    let state = try await loaded.serializedNavigationState()
    let encrypted = try await fresh("encrypted")
    try await encrypted.restoreNavigationState(state)
    try require(try await actualAddress(encrypted) == url.absoluteString, "encryptedRestoreAwaitsPrimaryCommit")
    let legacy = try await fresh("legacy")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.query = "native-history=second"
    let second = components.url!
    try await legacy.restoreNavigationEntries([
      CefNavigationEntry(url: url, title: "First"), CefNavigationEntry(url: second, title: "Second")
    ], selectedIndex: 1)
    try require(try await actualAddress(legacy) == second.absoluteString, "legacyRestoreAwaitsPrimaryCommit")
    let loadingDeadline = Date().addingTimeInterval(5)
    while legacy.isLoading && Date() < loadingDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try await legacy.discardDocument()
    try require(try await actualAddress(legacy) == "about:blank", "navigationDiscardReachesBlank")
    try await legacy.restoreDiscardedDocument()
    try require(try await actualAddress(legacy) == second.absoluteString, "discardRestoreAwaitsPrimaryCommit")
    var delayedComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    delayedComponents.path = "/native-delayed-commit"; delayedComponents.query = nil
    let delayedURL = delayedComponents.url!
    func awaitPending(_ browser: CefBrowser) async throws {
      let deadline = Date().addingTimeInterval(3)
      repeat {
        let state = try await browser.devTools.call("Zacro.getDocumentState")
        if state["navigationPending"] as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(10))
      } while Date() < deadline
      throw Failure(message: "The delayed native navigation never entered its commit barrier")
    }
    let replacement = try await fresh("replacement")
    let replaced = Task { try await replacement.loadAndWaitForNavigationCommit(delayedURL) }
    try await awaitPending(replacement)
    replacement.load(second)
    do {
      try await replaced.value
      throw Failure(message: "Replacement navigation incorrectly fulfilled the original commit barrier")
    } catch let error as CefDevToolsError {
      try require(error.localizedDescription.contains("replaced") || error.localizedDescription.contains("cancelled"),
        "navigationCommitRejectsReplacement")
    }
    let cancelled = try await fresh("cancelled")
    let pending = Task { try await cancelled.loadAndWaitForNavigationCommit(delayedURL) }
    try await awaitPending(cancelled)
    cancelled.stopLoading()
    do {
      try await pending.value
      throw Failure(message: "Cancelled navigation incorrectly fulfilled its commit barrier")
    } catch let error as CefDevToolsError {
      try require(error.localizedDescription.contains("cancelled"), "navigationCommitRejectsCancellation")
    }
    let failed = try await fresh("failure")
    do {
      try await failed.loadAndWaitForNavigationCommit(URL(string: "http://127.0.0.1:1/native-unreachable")!)
      throw Failure(message: "A failed primary navigation was reported as committed")
    } catch let error as CefDevToolsError {
      try require(error.localizedDescription.contains("failed") || error.localizedDescription.contains("cancelled"),
        "navigationCommitRejectsFailedDocument")
    }
    try await checkLargeNativeHistory(url: url)
  }

  private func checkLargeNativeHistory(url: URL) async throws {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.path = "/native-history-form"; components.query = nil
    let formURL = components.url!
    func fresh(_ name: String) async throws -> CefBrowser {
      try await engine.page(id: "acceptance-large-history-" + name,
        profileID: "a", isPrivate: false, url: nil).ready()
    }
    func waitForForm(_ browser: CefBrowser, expression: String) async throws -> Bool {
      let deadline = Date().addingTimeInterval(5)
      repeat {
        if (try? await browser.devTools.evaluate(expression)) as? Bool == true { return true }
        try await Task.sleep(for: .milliseconds(30))
      } while Date() < deadline
      return false
    }
    let source = try await fresh("source")
    try await source.loadAndWaitForNavigationCommit(formURL)
    try require(try await waitForForm(source, expression: "!!document.getElementById('retained')"),
      "largeHistoryFormLoaded")
    let expected = "'Zacro native history · '.repeat(30000)"
    _ = try await source.devTools.evaluate("(() => { const field=document.getElementById('retained'); field.value=\(expected); field.dispatchEvent(new Event('input',{bubbles:true})); field.dispatchEvent(new Event('change',{bubbles:true})); })()")
    try await source.loadAndWaitForNavigationCommit(url)
    let saved = try await source.serializedNavigationState()
    let restored = try await fresh("restored")
    try await restored.restoreNavigationState(saved)
    restored.goBack()
    try require(try await waitForForm(restored,
      expression: "document.getElementById('retained')?.value === \(expected)"),
      "encryptedHistoryRetainsLargeFormWithoutTruncation")
    _ = try await restored.devTools.evaluate("(() => { const field=document.getElementById('retained'); field.value='oversized-form-'.repeat(600000); field.dispatchEvent(new Event('input',{bubbles:true})); field.dispatchEvent(new Event('change',{bubbles:true})); })()")
    try await restored.loadAndWaitForNavigationCommit(url)
    do {
      _ = try await restored.serializedNavigationState()
      throw Failure(message: "Oversized navigation was reported as successfully captured")
    } catch let error as CefDevToolsError {
      try require(error.localizedDescription.contains("supported size"), "oversizedHistoryCaptureFailsExplicitly")
    }
    try require(try await restored.devTools.evaluate("location.href") as? String == url.absoluteString,
      "oversizedHistoryCapturePreservesLiveDocument")
  }

  private func checkWindowContexts(page: ChromiumPage, browser: CefBrowser, url: URL) async throws {
    guard let primary = engine.primaryWindow else { throw Failure(message: "Missing primary window") }
    let secondary = engine.createWindow(id: "acceptance-second-window")
    let firstWindowID = secondary.nativeID
    try require(firstWindowID != primary.nativeID && secondary !== primary, "independentWindowContexts")
    let documentID = browser.id
    try require(engine.movePage(id: page.id, toWindowID: secondary.id), "retainedDocumentWindowTransfer")
    secondary.show()
    page.show(frame: CGRect(x: 8, y: 8, width: 900, height: 650))
    let draft = try await browser.devTools.evaluate("document.querySelector('input').value") as? String
    try require(page.browser === browser && browser.id == documentID && draft == "unsaved-form-value" &&
      page.ownerWindowID == secondary.id && page.nativeWindow?.parent === secondary.window,
      "windowTransferRetainsIdentityAndForm")

    var attempts = 0
    secondary.beforeClosingDocuments = { attempts += 1; return false }
    secondary.close()
    let vetoDeadline = Date().addingTimeInterval(3)
    while (attempts == 0 || secondary.isClosing), Date() < vetoDeadline { try await Task.sleep(for: .milliseconds(30)) }
    try require(attempts == 1 && secondary.isOpen && !secondary.isClosing && page.browser === browser &&
      primary.isOpen && pages[1].browser != nil, "windowCloseVetoIsScoped")

    try require(engine.movePage(id: page.id, toWindowID: primary.id), "retainedDocumentWindowReturn")
    page.show(frame: CGRect(x: 224, y: 4, width: 500, height: 700))
    let closingPage = engine.page(id: "acceptance-window-close", profileID: "a", isPrivate: false,
      url: url, ownerWindowID: secondary.id)
    _ = try await closingPage.ready()
    let privateID = "acceptance-empty-private-session"
    let privatePage = engine.page(id: "acceptance-empty-private-before", profileID: privateID,
      isPrivate: true, url: url, ownerWindowID: primary.id)
    let privateBrowser = try await privatePage.ready()
    _ = try await privateBrowser.devTools.call("Network.setCookie", parameters: [
      "name": "zacro-empty-private", "value": "retained", "url": url.absoluteString
    ])
    privatePage.close()
    try await waitForPageClose(privatePage)
    let manager = engine.extensionsPage(profileID: "a")
    secondary.beforeClosingDocuments = { true }
    secondary.close()
    let closeDeadline = Date().addingTimeInterval(5)
    while secondary.isOpen, Date() < closeDeadline { try await Task.sleep(for: .milliseconds(30)) }
    try require(!secondary.isOpen && closingPage.browser == nil && primary.isOpen &&
      page.browser === browser && pages[3].browser != nil && manager.browser != nil && manager.ownerWindowID == nil,
      "windowClosePreservesOtherDocumentsAndManager")
    let retainedPrivate = engine.page(id: "acceptance-empty-private-after", profileID: privateID,
      isPrivate: true, url: url, ownerWindowID: primary.id)
    let retainedBrowser = try await retainedPrivate.ready()
    let retainedCookies = try await retainedBrowser.devTools.call("Network.getCookies", parameters: ["urls": [url.absoluteString]])
    try require((retainedCookies["cookies"] as? [[String: Any]])?.contains {
      $0["name"] as? String == "zacro-empty-private" && $0["value"] as? String == "retained"
    } == true, "unrelatedWindowClosePreservesEmptyPrivateSession")
    retainedPrivate.close()
    try await waitForPageClose(retainedPrivate)
    try engine.releasePrivateProfile(privateID)
    let freshPrivate = engine.page(id: "acceptance-empty-private-fresh", profileID: privateID,
      isPrivate: true, url: url, ownerWindowID: primary.id)
    let freshBrowser = try await freshPrivate.ready()
    let freshCookies = try await freshBrowser.devTools.call("Network.getCookies", parameters: ["urls": [url.absoluteString]])
    try require((freshCookies["cookies"] as? [[String: Any]])?.contains {
      $0["name"] as? String == "zacro-empty-private"
    } == false, "explicitPrivateRetirementClearsItsCookies")
    freshPrivate.close()
    try await waitForPageClose(freshPrivate)
    try engine.releasePrivateProfile(privateID)
    try await checkProfileRetirement(primary: primary, url: url)
    let reopened = engine.createWindow(id: secondary.id)
    try require(reopened === secondary && reopened.isOpen && reopened.nativeID != firstWindowID,
      "windowReopenGetsFreshNativeIdentity")
    reopened.show()
    page.focus()
  }
  private func waitForPageClose(_ page: ChromiumPage) async throws {
    let deadline = Date().addingTimeInterval(5)
    while engine.pages[page.id] != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard engine.pages[page.id] == nil, page.browser == nil else { throw Failure(message: "Native profile document did not close") }
  }
  private func checkProfileRetirement(primary: ChromiumWindowContext, url: URL) async throws {
    let identifier = "acceptance-retirement-receipt"
    let name = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    let directory = engine.dataDirectory.appendingPathComponent("Chromium").appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let marker = directory.appendingPathComponent("receipt-fixture")
    try Data("retained until confirmed cleanup".utf8).write(to: marker)
    try engine.retireProfile(identifier)
    let rejected = engine.page(id: "acceptance-retired-reuse", profileID: identifier,
      isPrivate: false, url: url, ownerWindowID: primary.id)
    var rejectedCleanly = false
    do { _ = try await rejected.ready() } catch { rejectedCleanly = rejected.creationFailed }
    try require(rejectedCleanly && engine.pages[rejected.id] == nil && FileManager.default.fileExists(atPath: marker.path),
      "pendingRetirementCannotReopenAProfileIdentity")
    try engine.replayProfileRetirement(identifier)
    try require(!FileManager.default.fileExists(atPath: directory.path), "unopenedProfileRetirementReplaysDurably")
    do {
      try engine.replayProfileRetirement("a")
      throw Failure(message: "Replay accepted an already opened profile")
    } catch is Failure { throw Failure(message: "Replay accepted an already opened profile") }
    catch { checks["retirementReplayRejectsOpenedProfiles"] = true }
  }
  private func finish(error: String?) {
    guard !finished else { return }; finished = true
    timer?.invalidate()
    timer = nil
    let result: [String: Any] = [
      "passed": error == nil, "error": error ?? "", "documents": pages.count,
      "chromeRuntime": pages.allSatisfy { $0.browser?.isChromeRuntime == true },
      "extensionCompatibilityVerified": false,
      "checks": checks,
      "capabilities": capabilities,
      "pages": pages.map {
        [
          "id": $0.id, "nativeID": $0.browser?.id ?? -999, "url": $0.url?.absoluteString ?? "",
          "title": $0.title, "loading": $0.isLoading, "error": $0.error ?? "",
          "cachePath": $0.browser?.profileCachePath ?? "",
          "chrome": $0.browser?.isChromeRuntime == true,
        ] as [String: Any]
      },
    ]
    if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
      let output = ProcessInfo.processInfo.environment["ZACRO_ACCEPTANCE_OUTPUT"]
    {
      try? bytes.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    fputs("Native engine acceptance: \(error ?? "passed")\n", stderr)
    NSApp.terminate(nil)
  }
}
