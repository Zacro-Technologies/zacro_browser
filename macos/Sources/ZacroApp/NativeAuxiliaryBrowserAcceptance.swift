import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Actual Chrome-owned auth documents and their original beforeunload callbacks.
/// Only token-bound HTTP loopback fixture pages receive DOM setup and Chromium
/// input. This does not automate the desktop or test real account credentials.
@MainActor
enum NativeAuxiliaryBrowserAcceptance {
  @MainActor private final class WindowClosureState {
    var first = false
    var second = false
  }
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, owner.windowContext.isOpen,
      owner.store.state.activeProfile?.isPrivate == false,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil,
      let fixture = ProcessInfo.processInfo.environment["ZACRO_NATIVE_EXTENSION_FIXTURE"] else {
      throw ShortcutError("Auxiliary browser acceptance requires the disposable native identity fixture.")
    }
    let profileA = owner.store.activeProfileID
    guard application.engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).isEmpty else {
      throw ShortcutError("Finish earlier auth flows before running the auxiliary close fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native auxiliary check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Auxiliary browser acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Auxiliary browser acceptance timed out: " + phase)
    }
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func matches(_ browser: CefBrowser, token: String) -> Bool {
      guard !browser.isClosed, let address = browser.url,
        address.scheme == url.scheme, address.host == url.host, address.port == url.port,
        address.user == nil, address.password == nil, address.path == "/native-auth/document" else { return false }
      return URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "token" && $0.value == token }) == true
    }
    func status(_ session: ChromeExtensionWorkerSession, token: String) async throws -> [String: Any] {
      guard let value = try await session.evaluate("zacroIdentityAcceptance.status(\(try literal(token)))") as? [String: Any] else {
        throw ShortcutError("Missing actual identity worker status")
      }
      return value
    }
    func evaluate(_ browser: CefBrowser, token: String, body: String) async throws -> Any? {
      guard matches(browser, token: token) else { throw ShortcutError("The owned auth fixture navigated away.") }
      return try await browser.devTools.evaluate("""
        (() => {
          if(location.origin!==\(try literal(url.scheme! + "://" + url.host! + ":" + String(url.port!))) ||
             location.pathname!=='/native-auth/document' ||
             new URL(location.href).searchParams.get('token')!==\(try literal(token)))
            throw new Error('Auth fixture ownership changed');
          \(body)
        })()
        """, timeout: 3)
    }
    func ownedSheet(_ browser: CefBrowser, window: NSWindow) -> NSWindow? {
      guard browser.nativeView?.window === window, let sheet = window.attachedSheet,
        sheet.sheetParent === window,
        sheet.identifier?.rawValue.hasPrefix("ZacroAuxiliaryBeforeUnload:\(browser.id):") == true else { return nil }
      return sheet
    }

    owner.windowContext.show()
    application.repository.focusWindow(owner.windowContext.id)
    application.newWindow()
    guard let other = application.focusedCoordinator, other !== owner else {
      throw ShortcutError("No isolated auth fixture owner")
    }
    other.actions.palette = false
    var otherManager: ChromeExtensionManager?
    var otherWorker: ChromeExtensionWorkerSession?
    var browserA: CefBrowser?, browserB: CefBrowser?
    var windowA: NSWindow?, windowB: NSWindow?
    var observers: [NSObjectProtocol] = []
    var closeTask: Task<Void, Error>?
    let tokenA = "zacro-aux-a-" + UUID().uuidString
    let tokenB = "zacro-aux-b-" + UUID().uuidString
    var startedA = false, startedB = false
    let closureState = WindowClosureState()
    defer { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    do {
      let profileB = try other.store.createProfileDurably(name: "Auxiliary isolation fixture")
      guard profileB.id != profileA, !profileB.isPrivate,
        owner.store.activeProfileID == profileA else { throw ShortcutError("Auth profile isolation setup changed its owner") }
      guard let tab = other.store.createTab(address: url.appendingPathComponent("auxiliary-isolation-owner").absoluteString) else {
        throw ShortcutError("Missing isolated auth owner page")
      }
      let page = try await other.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      await application.extensionBrowser.waitForTopologyPublication()
      let manager = ChromeExtensionManager(engine: application.engine, profileID: profileB.id)
      otherManager = manager
      let copy = application.engine.dataDirectory.appendingPathComponent("AcceptanceAuxiliary-" + UUID().uuidString)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: copy)
      try await manager.setDeveloperMode(true)
      let identifier = try await manager.loadUnpackedExtension(at: copy)
      let secondWorker = try await manager.workerSession(identifier)
      otherWorker = secondWorker

      for (session, token) in [(worker, tokenA), (secondWorker, tokenB)] {
        let input = try literal(["baseURL": url.absoluteString, "token": token, "holdMilliseconds": 90_000] as [String: Any])
        _ = try await session.evaluate("zacroIdentityAcceptance.startInteractive(\(input))")
        if token == tokenA { startedA = true } else { startedB = true }
      }
      try await wait("two exact context-bound native auth windows") {
        browserA = application.engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).first { matches($0, token: tokenA) }
        browserB = application.engine.auxiliaryBrowsers(profileID: profileB.id, isPrivate: false).first { matches($0, token: tokenB) }
        windowA = browserA?.nativeView?.window; windowB = browserB?.nativeView?.window
        return windowA?.isVisible == true && windowB?.isVisible == true
      }
      guard let first = browserA, let second = browserB, let firstWindow = windowA, let secondWindow = windowB else {
        throw ShortcutError("Missing adopted native auth document")
      }
      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
        object: firstWindow, queue: nil) { _ in MainActor.assumeIsolated { closureState.first = true } })
      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
        object: secondWindow, queue: nil) { _ in MainActor.assumeIsolated { closureState.second = true } })
      let aIDs = Set(application.engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).map(\.id))
      let bIDs = Set(application.engine.auxiliaryBrowsers(profileID: profileB.id, isPrivate: false).map(\.id))
      try require(first !== second && first.id != second.id && firstWindow !== secondWindow
        && aIDs == [first.id] && bIDs == [second.id] && aIDs.isDisjoint(with: bIDs),
        "auxiliaryBrowsersUseExactDistinctNativeProfileContexts")
      for (session, token) in [(worker, tokenA), (secondWorker, tokenB)] {
        let value = try await status(session, token: token)
        try require(value["state"] as? String == "pending"
          && (value["logicalAuthTabIDs"] as? [Int])?.isEmpty == true
          && (value["logicalAuthWindowIDs"] as? [Int])?.isEmpty == true,
          token == tokenA ? "auxiliaryFirstProfileAuthRemainsOutsideLogicalCatalog" : "auxiliaryOtherProfileAuthRemainsOutsideLogicalCatalog")
      }
      _ = try await evaluate(second, token: tokenB, body: """
        const draft=document.createElement('textarea');draft.id='otherProfileDraft';
        draft.value='other profile retained';document.body.appendChild(draft);return true;
        """)
      _ = try await evaluate(first, token: tokenA, body: """
        const button=document.createElement('button');button.id='auxiliaryActivate';button.textContent='Edit draft';
        button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
        const draft=document.createElement('textarea');draft.id='auxiliaryDraft';draft.value='native auth unsaved work';
        document.body.append(button,draft);globalThis.auxiliaryClick=null;
        button.addEventListener('click',event=>{globalThis.auxiliaryClick={trusted:event.isTrusted,button:event.button};});
        window.onbeforeunload=event=>{event.preventDefault();event.returnValue='Unsaved fixture work';};return true;
        """)
      firstWindow.makeKeyAndOrderFront(nil)
      first.setFocus(true)
      try await wait("auth document owns focus and its trusted input target") {
        try await evaluate(first, token: tokenA, body:
          "return document.hasFocus() && document.elementFromPoint(60,36)?.id==='auxiliaryActivate';") as? Bool == true
      }
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await first.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0,
        ])
      }
      let activated = try await evaluate(first, token: tokenA, body: """
        return {trusted:globalThis.auxiliaryClick?.trusted===true,primary:globalThis.auxiliaryClick?.button===0,
          sticky:navigator.userActivation.hasBeenActive,focused:document.hasFocus()};
        """) as? [String: Any] ?? [:]
      try require(["trusted", "primary", "sticky", "focused"].allSatisfy { activated[$0] as? Bool == true },
        "auxiliaryBeforeUnloadUsesActualTrustedStickyActivation")

      closeTask = Task { @MainActor in try await application.engine.closeAuxiliaryBrowsers(profileID: profileA, isPrivate: false) }
      try await wait("exact auxiliary beforeunload sheet") { ownedSheet(first, window: firstWindow) != nil }
      guard let rejected = ownedSheet(first, window: firstWindow) else { throw ShortcutError("Missing owned auxiliary sheet") }
      try require(!first.isClosed && firstWindow.isVisible && !closureState.first
        && !second.isClosed && secondWindow.isVisible && !closureState.second,
        "auxiliaryProfileDrainWaitsForItsOwnNativeDecision")
      firstWindow.endSheet(rejected, returnCode: .alertSecondButtonReturn)
      do { try await closeTask!.value; throw ShortcutError("A native Stay unexpectedly accepted profile cleanup") }
      catch is CancellationError {}
      closeTask = nil
      let retained = try await evaluate(first, token: tokenA, body: "return document.getElementById('auxiliaryDraft').value;") as? String
      let pending = try await status(worker, token: tokenA)
      try require(retained == "native auth unsaved work" && pending["state"] as? String == "pending"
        && !first.isClosed && firstWindow.isVisible && !closureState.first
        && application.engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).contains(where: { $0 === first }),
        "auxiliaryStayRetainsExactNativeDocumentWindowDraftAndWorkerFlow")

      closeTask = Task { @MainActor in try await application.engine.closeAuxiliaryBrowsers(profileID: profileA, isPrivate: false) }
      try await wait("replacement auxiliary close sheet") {
        guard let sheet = ownedSheet(first, window: firstWindow) else { return false }
        return sheet !== rejected
      }
      guard let accepted = ownedSheet(first, window: firstWindow) else { throw ShortcutError("Missing second auxiliary sheet") }
      firstWindow.endSheet(accepted, returnCode: .alertFirstButtonReturn)
      try await closeTask!.value; closeTask = nil
      try await wait("accepted auth native browser and window close") {
        let value = try await status(worker, token: tokenA)
        return first.isClosed && closureState.first && !firstWindow.isVisible && value["state"] as? String == "rejected"
      }
      try require(application.engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).isEmpty,
        "auxiliaryLeaveDrainsActualDocumentAndNativeWindowBeforeProfileRelease")
      let otherDraft = try await evaluate(second, token: tokenB, body: "return document.getElementById('otherProfileDraft').value;") as? String
      let otherStatus = try await status(secondWorker, token: tokenB)
      try require(otherDraft == "other profile retained" && otherStatus["state"] as? String == "pending"
        && !second.isClosed && secondWindow.isVisible && !closureState.second
        && application.engine.auxiliaryBrowsers(profileID: profileB.id, isPrivate: false).contains(where: { $0 === second }),
        "auxiliaryProfileCleanupPreservesUnrelatedProfileAuthDocumentAndDraft")
      _ = try await secondWorker.evaluate("zacroIdentityAcceptance.release(\(try literal(tokenB)))")
      try await wait("unrelated profile completes its real identity callback") {
        let value = try await status(secondWorker, token: tokenB)
        return second.isClosed && closureState.second && !secondWindow.isVisible
          && value["state"] as? String == "resolved" && value["exactCallback"] as? Bool == true
      }
      try require(application.engine.auxiliaryBrowsers(profileID: profileB.id, isPrivate: false).isEmpty,
        "auxiliaryOtherProfileStillCompletesItsExactNativeIdentityCallback")
      _ = try await worker.evaluate("zacroIdentityAcceptance.finish(\(try literal(tokenA)))"); startedA = false
      _ = try await secondWorker.evaluate("zacroIdentityAcceptance.finish(\(try literal(tokenB)))"); startedB = false
      await secondWorker.close(); otherWorker = nil
      await manager.close(); otherManager = nil
      try require(await other.requestCloseWindow(), "auxiliaryFixtureShellClosesCleanly")
      owner.windowContext.show()
      return checks
    } catch {
      if let first = browserA, let window = windowA, let sheet = ownedSheet(first, window: window) {
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      }
      closeTask?.cancel()
      _ = try? await closeTask?.value
      for (browser, token) in [(browserA, tokenA), (browserB, tokenB)] {
        if let browser, matches(browser, token: token) {
          _ = try? await evaluate(browser, token: token, body: "window.onbeforeunload=null;return true;")
          browser.close(force: false)
        }
      }
      if startedA { _ = try? await worker.evaluate("zacroIdentityAcceptance.finish(\(try literal(tokenA)))", timeout: 2) }
      if let otherWorker {
        if startedB { _ = try? await otherWorker.evaluate("zacroIdentityAcceptance.finish(\(try literal(tokenB)))", timeout: 2) }
        await otherWorker.close()
      }
      await otherManager?.close()
      _ = await other.requestCloseWindow()
      owner.windowContext.show()
      throw error
    }
  }
}
