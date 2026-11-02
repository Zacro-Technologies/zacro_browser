import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Owns a hidden, unregistered maintenance document to exercise cancellation
/// before any navigation. It never changes a user tab or invents history.
@MainActor
enum NativePeekBootstrapAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      originalOwner.store.state.activeProfile?.isPrivate == false else {
      throw ShortcutError("Peek bootstrap requires the custom runtime and disposable loopback fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native Peek bootstrap check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Peek bootstrap acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Peek bootstrap acceptance timed out: " + name)
    }
    let id = "maintenance:peek-bootstrap:" + UUID().uuidString
    let page = application.engine.page(id: id, profileID: originalOwner.store.activeProfileID,
      isPrivate: false, url: nil, ownerWindowID: originalOwner.windowContext.id)
    page.hide()
    var bridge: NativePeekLinkBridge?
    var observation: UUID?
    var browser: CefBrowser?
    do {
      let native = try await page.ready()
      browser = native
      let target = try await native.devTools.call("Target.getTargetInfo")
      guard let info = target["targetInfo"] as? [String: Any], let targetID = info["targetId"] as? String else {
        throw ShortcutError("No exact initial target")
      }
      var attached = Set<String>(), detached = Set<String>()
      var worlds: [String: String] = [:]
      var destroyedWorlds = Set<String>()
      observation = try native.devTools.observeProtocolEvents { method, params, sessionID in
        if method == "Target.attachedToTarget", let child = params["sessionId"] as? String,
          let target = params["targetInfo"] as? [String: Any], target["targetId"] as? String == targetID {
          attached.insert(child)
        } else if method == "Target.detachedFromTarget", let child = params["sessionId"] as? String {
          detached.insert(child)
        } else if sessionID == nil, method == "Runtime.executionContextCreated",
          let context = params["context"] as? [String: Any], let name = context["name"] as? String,
          name.hasPrefix("Zacro.Peek."), let unique = context["uniqueId"] as? String {
          worlds[unique] = name
        } else if sessionID == nil, method == "Runtime.executionContextDestroyed",
          let unique = params["executionContextUniqueId"] as? String {
          destroyedWorlds.insert(unique)
        }
      }
      var dispatched = 0
      let initial = NativePeekLinkBridge(page: page, usesOwnedSession: { true }, snapshot: { nil },
        didRequest: { _, _ in dispatched += 1 })
      bridge = initial
      try await initial.prepareBootstrap()
      try require(attached.count == 1 && !page.canGoBack,
        "peekBootstrapSubmitsIntoOneOwnedSessionWithoutNavigation")
      let firstSessions = attached
      let began = ProcessInfo.processInfo.systemUptime
      await initial.stop().value
      let elapsed = ProcessInfo.processInfo.systemUptime - began
      try require(firstSessions.isSubset(of: detached) && elapsed < 3 && !initial.isArmed
        && page.browser === native && !native.isClosed,
        "peekBootstrapCancelsBeforeRendererWithoutWaitingForItsResponse")

      let destination = url.appendingPathComponent("peek-bootstrap-after-cancel")
      page.load(destination)
      try await wait("first actual document commits") { page.url == destination && !page.isLoading }
      _ = try await native.devTools.call("Runtime.enable")
      try require(worlds.isEmpty && !page.canGoBack && page.browser === native,
        "peekCancelledBootstrapLeavesNoFutureScriptOrHistoryEntry")

      let successor = NativePeekLinkBridge(page: page, usesOwnedSession: { true }, snapshot: { nil },
        didRequest: { _, _ in dispatched += 1 })
      bridge = successor
      try await successor.start()
      guard worlds.count == 1, let world = worlds.keys.first else {
        throw ShortcutError("No exact successor isolated context")
      }
      let state = try await native.devTools.evaluate("!!globalThis.__zacroPeekState && globalThis.__zacroPeekState.configuration === null",
        uniqueContextID: world) as? Bool
      try require(state == true && !successor.isArmed && dispatched == 0 && page.browser === native,
        "peekBootstrapSuccessorRetainsNativeIdentityWithoutUnownedAuthority")
      await successor.stop().value
      let cleaned: Bool
      if destroyedWorlds.contains(world) { cleaned = true }
      else {
        cleaned = (try await native.devTools.evaluate("typeof globalThis.__zacroPeekState === 'undefined' && !Object.getOwnPropertyNames(globalThis).some(name => name.startsWith('__zacroPeek_'))",
          uniqueContextID: world) as? Bool) == true
      }
      try require(cleaned && attached.isSubset(of: detached) && dispatched == 0,
        "peekBootstrapSuccessorDisposesItsListenerBindingAndOwnedSession")
      if let observation { native.devTools.removeEventObserver(observation) }
      observation = nil; bridge = nil
      application.engine.close(id: id)
      try await wait("maintenance document closes") { application.engine.pages[id] == nil && native.isClosed }
      try require(true, "peekBootstrapMaintenanceDocumentClosesCleanly")
      return checks
    } catch {
      if let bridge { await bridge.stop().value }
      if let observation { browser?.devTools.removeEventObserver(observation) }
      application.engine.close(id: id)
      throw error
    }
  }
}
