import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Staged runtime acceptance for real WebAuthFlow requests whose initial HTTP
/// response has not arrived. No injected auth document, user gesture, account,
/// desktop input, or timer-based substitute for native destruction is used.
@MainActor enum NativeAuxiliaryAdmissionAcceptance {
  @MainActor private final class Flow {
    let worker: ChromeExtensionWorkerSession
    let profileID: String
    let token = "zacro-admission-" + UUID().uuidString
    var started = false
    var finished = false
    init(worker: ChromeExtensionWorkerSession, profileID: String) {
      self.worker = worker; self.profileID = profileID
    }
  }
  @MainActor private final class WindowReference {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
  }

  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, owner.windowContext.isOpen,
      !owner.windowContext.isClosing, owner.store.state.activeProfile?.isPrivate == false,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil,
      let fixture = ProcessInfo.processInfo.environment["ZACRO_NATIVE_EXTENSION_FIXTURE"],
      CefAuxiliaryAdmissionLease.isSupported else {
      throw ShortcutError("Auxiliary admission acceptance requires the custom runtime ABI and disposable loopback identity fixture.")
    }
    let engine = application.engine
    let profileA = owner.store.activeProfileID
    guard engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).isEmpty else {
      throw ShortcutError("Finish earlier authorization windows before the admission fixture.")
    }
    var checks: [String] = []
    var flows: [Flow] = []
    var other: BrowserWindowCoordinator?
    var otherManager: ChromeExtensionManager?
    var otherWorker: ChromeExtensionWorkerSession?
    var profileLease: CefAuxiliaryAdmissionLease?
    var processLease: CefAuxiliaryAdmissionLease?

    @MainActor func require(_ value: Bool, _ name: String) throws {
      fputs("Native auxiliary admission check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Auxiliary admission acceptance failed: " + name) }
      checks.append(name)
    }
    @MainActor func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Auxiliary admission acceptance timed out: " + phase)
    }
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    @MainActor func call(_ flow: Flow, _ method: String) async throws -> Any? {
      try await flow.worker.evaluate("zacroIdentityAcceptance.\(method)(\(try literal(flow.token)))", timeout: 7)
    }
    @MainActor func record(_ flow: Flow, _ method: String) async throws -> [String: Any] {
      guard let result = try await call(flow, method) as? [String: Any] else {
        throw ShortcutError("The owned identity fixture returned no " + method + " record.")
      }
      return result
    }
    @MainActor func start(_ session: ChromeExtensionWorkerSession, profileID: String) async throws -> Flow {
      let flow = Flow(worker: session, profileID: profileID)
      flows.append(flow)
      // Retain the cleanup record before the asynchronous evaluation: a lost
      // response must not cause us to forget an already-started native request.
      flow.started = true
      let input = try literal(["baseURL": url.absoluteString, "token": flow.token,
        "holdMilliseconds": 90_000] as [String: Any])
      guard let result = try await session.evaluate("zacroIdentityAcceptance.startPending(\(input))", timeout: 7) as? [String: Any],
        result["token"] as? String == flow.token else {
        throw ShortcutError("The exact pending authorization request did not start.")
      }
      return flow
    }
    @MainActor func matches(_ browser: CefBrowser, _ flow: Flow) -> Bool {
      guard !browser.isClosed, let address = browser.url,
        address.scheme == url.scheme, address.host == url.host, address.port == url.port,
        address.user == nil, address.password == nil,
        address.path == "/native-auth/pending" else { return false }
      return URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "token" && $0.value == flow.token }) == true
    }
    @MainActor func browsers(_ flow: Flow) -> [CefBrowser] {
      engine.auxiliaryBrowsers(profileID: flow.profileID, isPrivate: false).filter { matches($0, flow) }
    }
    @MainActor func isPendingBeforeHeaders(_ flow: Flow) async throws -> Bool {
      let server = try await record(flow, "pendingServerState")
      let status = try await record(flow, "status")
      return server["entered"] as? Bool == true && server["released"] as? Bool == false
        && server["completed"] as? Bool == false && server["expired"] as? Bool == false
        && status["state"] as? String == "pending"
        && engine.auxiliaryBrowsers(profileID: flow.profileID, isPrivate: false).isEmpty
    }
    @MainActor func isRejected(_ flow: Flow) async throws -> Bool {
      let value = try await record(flow, "status")
      return value["state"] as? String == "rejected" && !(value["error"] as? String ?? "").isEmpty
    }
    @MainActor func finish(_ flow: Flow) async throws {
      _ = try await call(flow, "finish"); flow.finished = true
    }
    @MainActor func releaseLateHeaders(_ flow: Flow, lease: CefAuxiliaryAdmissionLease,
      name: String) async throws {
      guard try await call(flow, "releasePending") as? Bool == true else {
        throw ShortcutError("The exact pending HTTP response was not released.")
      }
      try await wait("cancelled HTTP response finishes without presentation") {
        let server = try await record(flow, "pendingServerState")
        return server["released"] as? Bool == true && server["completed"] as? Bool == true
          && server["expired"] as? Bool == false
      }
      let rejected = try await isRejected(flow)
      try require(rejected && (try lease.status()).isQuiescent
        && engine.auxiliaryBrowsers(profileID: flow.profileID, isPrivate: false).isEmpty, name)
    }
    @MainActor func completePresented(_ flow: Flow, presentedName: String,
      completionName: String) async throws {
      guard try await call(flow, "releasePending") as? Bool == true else {
        throw ShortcutError("The owned auth headers could not be released.")
      }
      var actual: CefBrowser?
      var nativeWindow: WindowReference?
      try await wait("real native authorization presentation after headers") {
        let candidates = browsers(flow)
        guard candidates.count == 1, let candidate = candidates.first,
          let window = candidate.nativeView?.window, window.isVisible else { return false }
        actual = candidate; nativeWindow = WindowReference(window)
        return true
      }
      guard let browser = actual, let window = nativeWindow else {
        throw ShortcutError("The real authorization document/window was not adopted.")
      }
      let status = try await record(flow, "status")
      let server = try await record(flow, "pendingServerState")
      try require(status["state"] as? String == "pending"
        && (status["logicalAuthTabIDs"] as? [Int])?.isEmpty == true
        && (status["logicalAuthWindowIDs"] as? [Int])?.isEmpty == true
        && server["expired"] as? Bool == false && window.window?.isVisible == true,
        presentedName)
      guard try await call(flow, "release") as? Bool == true else {
        throw ShortcutError("The exact native identity callback was not released.")
      }
      try await wait("native identity result and exact auth window destruction") {
        let result = try await record(flow, "status")
        return result["state"] as? String == "resolved" && result["exactCallback"] as? Bool == true
          && browser.isClosed && window.window?.isVisible != true && browsers(flow).isEmpty
      }
      try require(browser.isClosed && window.window?.isVisible != true, completionName)
      try await finish(flow)
    }

    do {
      owner.windowContext.show()
      application.repository.focusWindow(owner.windowContext.id)
      let existingWindowIDs = Set(application.windows.keys)
      application.newWindow()
      let added = application.windows.values.filter {
        !existingWindowIDs.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
      }
      guard added.count == 1, let second = added.first else {
        throw ShortcutError("No exact new auxiliary admission fixture owner.")
      }
      other = second; second.actions.palette = false
      let profileB = try second.store.createProfileDurably(name: "Auxiliary admission isolation fixture")
      guard profileB.id != profileA, !profileB.isPrivate, owner.store.activeProfileID == profileA,
        let tab = second.store.createTab(address: url.appendingPathComponent("admission-owner").absoluteString) else {
        throw ShortcutError("The admission fixture profile setup changed its original owner.")
      }
      let page = try await second.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      await application.extensionBrowser.waitForTopologyPublication()
      let manager = ChromeExtensionManager(engine: engine, profileID: profileB.id)
      otherManager = manager
      let copy = engine.dataDirectory.appendingPathComponent("AcceptanceAuxiliaryAdmission-" + UUID().uuidString)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: copy)
      try await manager.setDeveloperMode(true)
      let identifier = try await manager.loadUnpackedExtension(at: copy)
      let secondWorker = try await manager.workerSession(identifier)
      otherWorker = secondWorker

      let first = try await start(worker, profileID: profileA)
      let unrelated = try await start(secondWorker, profileID: profileB.id)
      try await wait("both native requests enter the server without receiving headers") {
        let a = try await isPendingBeforeHeaders(first)
        let b = try await isPendingBeforeHeaders(unrelated)
        return a && b
      }
      try require(true, "auxiliaryAdmissionHasTwoRealUnpresentedHTTPRequests")
      guard let lease = try engine.acquireAuxiliaryAdmission(profileID: profileA, isPrivate: false) else {
        throw ShortcutError("The custom runtime omitted its exact-profile admission lease.")
      }
      profileLease = lease
      // No await between acquire and this snapshot. Cancellation posts native
      // destruction/Forget; this proves pending destruction after acquisition,
      // not a pre-acquisition count or a fabricated WebContents identifier.
      let acquired = try lease.status()
      try require(acquired.requests == 1 && acquired.unpresented == 1 && acquired.presented == 0,
        "auxiliaryProfileAdmissionCountsPendingNativeDestruction")
      try await wait("original profile request rejects and native destruction completes") {
        let rejected = try await isRejected(first)
        return try rejected && lease.status().isQuiescent
      }
      try await lease.waitForQuiescence()
      try require(try lease.status().isQuiescent, "auxiliaryProfileAdmissionWaitsForActualNativeQuiescence")
      try require(try await isPendingBeforeHeaders(unrelated),
        "auxiliaryProfileAdmissionPreservesOtherProfilePendingRequest")
      try await releaseLateHeaders(first, lease: lease,
        name: "auxiliaryProfileAdmissionRejectsLateHeadersWithoutCreatingWindow")
      try await finish(first)
      try lease.release(); profileLease = nil
      try await completePresented(unrelated,
        presentedName: "auxiliaryUnrelatedProfileStillPresentsRealAuthOutsideCatalog",
        completionName: "auxiliaryUnrelatedProfileStillCompletesExactCallback")

      let processPending = try await start(worker, profileID: profileA)
      try await wait("process test request reaches the held HTTP headers") { try await isPendingBeforeHeaders(processPending) }
      guard let globalLease = try CefAuxiliaryAdmissionLease.acquireProcess() else {
        throw ShortcutError("The custom runtime omitted its process admission lease.")
      }
      processLease = globalLease
      let processAcquired = try globalLease.status()
      try require(processAcquired.requests == 1 && processAcquired.unpresented == 1 && processAcquired.presented == 0,
        "auxiliaryProcessAdmissionCountsPendingNativeDestruction")
      try await wait("process request rejects and native destruction completes") {
        let rejected = try await isRejected(processPending)
        return try rejected && globalLease.status().isQuiescent
      }
      try await globalLease.waitForQuiescence()
      try require(try globalLease.status().isQuiescent,
        "auxiliaryProcessAdmissionWaitsForActualNativeQuiescence")

      let blocked = try await start(secondWorker, profileID: profileB.id)
      try await wait("fresh auth API rejects through its original completion while admission is fenced") {
        try await isRejected(blocked)
      }
      let absent = try await record(blocked, "pendingServerState")
      try require(["entered", "released", "completed", "expired"].allSatisfy { absent[$0] as? Bool == false }
        && engine.auxiliaryBrowsers(profileID: profileA, isPrivate: false).isEmpty
        && engine.auxiliaryBrowsers(profileID: profileB.id, isPrivate: false).isEmpty,
        "auxiliaryProcessAdmissionRejectsFreshAuthBeforeHTTPOrWindowCreation")
      try await wait("rejected fresh request releases its native operation") { try globalLease.status().isQuiescent }
      try await finish(blocked)
      try await releaseLateHeaders(processPending, lease: globalLease,
        name: "auxiliaryProcessAdmissionRejectsLateHeadersWithoutCreatingWindow")
      try await finish(processPending)
      try globalLease.release(); processLease = nil

      let reopened = try await start(worker, profileID: profileA)
      try await wait("released admission accepts a fresh native request") { try await isPendingBeforeHeaders(reopened) }
      try await completePresented(reopened,
        presentedName: "auxiliaryReleasedAdmissionAllowsNewActualAuthWindow",
        completionName: "auxiliaryReleasedAdmissionAllowsExactNativeCallbackAndClose")
      await secondWorker.close(); otherWorker = nil
      await manager.close(); otherManager = nil
      try require(await second.requestCloseWindow(), "auxiliaryAdmissionFixtureShellClosesCleanly")
      other = nil
      if owner.windowContext.isOpen { owner.windowContext.show() }
      return checks
    } catch {
      let failure = error
      // Cleanup releases only the leases this fixture owns. It does not force
      // browser shutdown or turn a failed runtime predicate into a pass.
      let cleanup = Task { @MainActor in
        for lease in [profileLease, processLease].compactMap({ $0 }) {
          do { try lease.release() }
          catch { fputs("Auxiliary admission cleanup could not release its native lease: \(error.localizedDescription)\n", stderr) }
        }
        profileLease = nil; processLease = nil
        for flow in flows where flow.started && !flow.finished {
          do {
            let server = try await record(flow, "pendingServerState")
            if server["entered"] as? Bool == true && server["released"] as? Bool == false {
              _ = try await call(flow, "releasePending")
            }
            // Only this loopback token's real callback is released. If its native
            // request was cancelled before headers, there may be no session yet.
            if server["entered"] as? Bool == true {
              try await wait("failure cleanup HTTP completion") {
                let value = try await record(flow, "pendingServerState")
                return value["completed"] as? Bool == true
              }
              _ = try await call(flow, "release")
            }
            try await wait("failure cleanup original native completion") {
              let value = try await record(flow, "status")
              return value["state"] as? String != "pending" && browsers(flow).isEmpty
            }
            try await finish(flow)
          } catch {
            // A visible match can be closed through its ordinary native path;
            // never close arbitrary profile/window lists or inject page handlers.
            for browser in browsers(flow) { browser.close(force: false) }
            fputs("Auxiliary admission cleanup retained an unresolved owned flow: \(error.localizedDescription)\n", stderr)
          }
        }
        await otherWorker?.close()
        await otherManager?.close()
        if let other, other.windowContext.isOpen { _ = await other.requestCloseWindow() }
        if owner.windowContext.isOpen { owner.windowContext.show() }
      }
      await cleanup.value
      throw failure
    }
  }
}
