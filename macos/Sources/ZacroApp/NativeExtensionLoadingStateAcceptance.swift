import Foundation
import ZacroChromium
import ZacroCore

/// Observe genuine extension metadata while one owned fresh document is held
/// between native bootstrap and its first HTTP navigation. The production
/// bootstrap still runs; only this disposable target's scheduling is gated.
@MainActor enum NativeExtensionLoadingStateAcceptance {
  private final class Gate {
    weak var page: ChromiumPage?
    var entered = false
    var released = false
  }

  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_SEARCH_FIXTURE"] == "1",
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      application.extensionBrowser.enabled, application.engine.pages[page.id] === page,
      page.ownerWindowID == owner.windowContext.id, !page.isPrivate,
      owner.windowContext.isOpen, !owner.windowContext.isClosing else {
      throw ShortcutError("Loading-state acceptance requires the owned disposable public loopback fixture.")
    }
    let originalBootstrap = application.navigation.beforeRestore
    let originalSelection = owner.store.state.activeTabID
    let originalSourceURL = owner.store.tab(page.id)?.url
    let sourceBrowser = try await page.ready(), sourceNativeID = page.reservedNativeTabID
    let originalWindows = Set(application.windows.keys)
    let originalAuxiliaries = Set(application.engine.auxiliaryBrowsers(profileID: page.profileID, isPrivate: false).map(\.id))
    let originalTabs = Set(application.store.state.tabs.map(\.id))
    let token = UUID().uuidString.lowercased()
    let eventKey = "__zacroLoadingState_" + token.replacingOccurrences(of: "-", with: "")
    var gates = [Gate]()
    var ownedIDs = [String]()
    var destinations = Set<String>()
    var createTask: Task<Void, Never>?
    var checks = [String]()
    defer {
      for gate in gates { gate.released = true }
      createTask?.cancel()
      application.navigation.beforeRestore = originalBootstrap
    }

    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension loading-state check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native loading-state acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw ShortcutError("Native loading-state acceptance timed out: " + phase)
    }
    func metadata(_ nativeID: Int) async throws -> [String: Any] {
      guard let value = try await worker.evaluate("chrome.tabs.get(\(nativeID))", timeout: 15) as? [String: Any] else {
        throw ShortcutError("The original Chrome tabs.get returned no loading-state metadata.")
      }
      return value
    }
    func cleanup() async throws {
      for gate in gates { gate.released = true }
      application.navigation.beforeRestore = originalBootstrap
      await createTask?.value
      createTask = nil
      var failure: Error?
      do {
        _ = try await worker.evaluate("""
          (()=>{const state=globalThis[\(try literal(eventKey))];
            if(state?.listener)chrome.tabs.onUpdated.removeListener(state.listener);
            delete globalThis[\(try literal(eventKey))];return true;})()
          """, timeout: 15)
      } catch { failure = error }
      let createdIDs = owner.store.state.tabs.filter {
        !originalTabs.contains($0.id) && $0.windowID == owner.windowContext.id
          && owner.store.profileID(for: $0) == page.profileID && destinations.contains($0.url)
      }.map(\.id)
      for id in Set(ownedIDs + createdIDs).sorted() where owner.store.tab(id)?.isClosed == false {
        if !(await owner.requestCloseTab(id)) {
          failure = failure ?? ShortcutError("An exact owned loading-state fixture tab refused normal closure.")
        }
      }
      if let originalSelection, owner.store.tab(originalSelection)?.isClosed == false {
        owner.store.selectTab(id: originalSelection)
      }
      owner.scheduleLayout()
      if let failure { throw failure }
    }

    do {
      _ = try await worker.evaluate("""
        (()=>{const state={events:[]};state.listener=(id,change,tab)=>{
          if(tab?.url?.includes(\(try literal(token))))state.events.push({id,status:change.status??null,url:tab.url});
        };globalThis[\(try literal(eventKey))]=state;chrome.tabs.onUpdated.addListener(state.listener);return true;})()
        """, timeout: 15)

      for phase in ["Commit", "Cancel", "Failure"] {
        var components = URLComponents(url: url.appendingPathComponent("native-delayed-commit"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "loading-state", value: token), URLQueryItem(name: "phase", value: phase)]
        guard let destination = components.url else { throw ShortcutError("No exact loading-state fixture URL.") }
        destinations.insert(destination.absoluteString)
        let gate = Gate(); gates.append(gate)
        application.navigation.beforeRestore = { candidate in
          try await originalBootstrap?(candidate)
          guard application.store.document(id: candidate.id)?.url == destination.absoluteString else { return }
          guard candidate.id != page.id, !originalTabs.contains(candidate.id),
            application.engine.pages[candidate.id] === candidate,
            candidate.ownerWindowID == owner.windowContext.id, candidate.profileID == page.profileID,
            !candidate.isPrivate, owner.windowPages[candidate.id] === candidate,
            let tab = owner.store.tab(candidate.id), !tab.isClosed, tab.windowID == owner.windowContext.id,
            owner.store.profileID(for: tab) == page.profileID,
            owner.windowContext.isOpen, !owner.windowContext.isClosing else {
            throw ShortcutError("The loading-state gate lost its exact fresh native owner.")
          }
          gate.page = candidate; gate.entered = true
          let deadline = ContinuousClock.now.advanced(by: .seconds(15))
          while !gate.released {
            try Task.checkCancellation()
            guard application.engine.pages[candidate.id] === candidate,
              owner.store.tab(candidate.id)?.url == destination.absoluteString,
              owner.windowContext.isOpen, !owner.windowContext.isClosing else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw CefDevToolsError.timeout }
            try await Task.sleep(for: .milliseconds(10))
          }
          if phase == "Failure" { throw ShortcutError("Owned loading-state fixture bootstrap rejection.") }
        }
        var result: Result<[String: Any], Error>?
        let createExpression = """
          (async()=>{const tab=await chrome.tabs.create({url:\(try literal(destination.absoluteString)),active:false,windowId:\(owner.windowContext.nativeID)});
            return {id:tab.id,windowId:tab.windowId,url:tab.url,status:tab.status};})()
          """
        createTask = Task { @MainActor in
          do {
            guard let value = try await worker.evaluate(createExpression, timeout: 15) as? [String: Any] else {
              throw ShortcutError("The original Chrome tabs.create returned no loading-state result.")
            }
            result = .success(value)
          } catch { result = .failure(error) }
        }
        try await wait(phase + " real native bootstrap gate and original API return") {
          if let result, case .failure(let error) = result { throw error }
          return gate.entered && result != nil
        }
        guard let target = gate.page, let result, let nativeID = try result.get()["id"] as? Int,
          let browser = target.browser, target.reservedNativeTabID == nativeID, nativeID > 0 else {
          throw ShortcutError("The loading-state fixture did not retain its real native identity.")
        }
        ownedIDs.append(target.id)
        let created = try result.get(), pending = try await metadata(nativeID)
        try require(created["status"] as? String == "loading" && pending["status"] as? String == "loading"
          && created["windowId"] as? Int == owner.windowContext.nativeID
          && application.navigation.isRestoring(target) && !target.isLoading
          && target.url?.absoluteString != destination.absoluteString,
          "extensionFresh" + phase + "ReportsLoadingBeforeInitialHTTPAndOriginalAPIReturns")
        await application.extensionBrowser.waitForTopologyPublication()
        if phase == "Cancel" { application.navigation.cancelRestore(target) }
        gate.released = true
        if phase == "Commit" {
          try await application.navigation.waitForRestore(target)
          try await wait("actual delayed fresh document commits") {
            !target.isLoading && target.url == destination && target.documentError == nil
          }
          let location = try await browser.devTools.evaluate("location.href") as? String
          try require(location == destination.absoluteString,
            "extensionFreshCommitLoadsActualLoopbackDocumentAfterGateRelease")
        } else {
          try await wait(phase + " retires its exact current restore") { !application.navigation.isRestoring(target) }
        }
        await application.extensionBrowser.waitForTopologyPublication()
        let finished = try await metadata(nativeID)
        try await wait(phase + " original Chrome completion event") {
          let events = try await worker.evaluate("globalThis[\(try literal(eventKey))].events", timeout: 15) as? [[String: Any]] ?? []
          return events.contains { $0["id"] as? Int == nativeID && $0["status"] as? String == "complete" }
        }
        try require(finished["status"] as? String == "complete"
          && application.engine.pages[target.id] === target && target.browser === browser
          && target.reservedNativeTabID == nativeID && target.ownerWindowID == owner.windowContext.id
          && target.profileID == page.profileID && !target.isPrivate,
          "extensionFresh" + phase + "PublishesCompleteForExactNativeIdentityWithoutZombieLoading")
        await createTask?.value; createTask = nil
      }
      try require(application.engine.pages[page.id] === page && page.browser === sourceBrowser
        && page.reservedNativeTabID == sourceNativeID && owner.store.tab(page.id)?.url == originalSourceURL
        && owner.store.state.activeTabID == originalSelection && Set(application.windows.keys) == originalWindows
        && Set(application.engine.auxiliaryBrowsers(profileID: page.profileID, isPrivate: false).map(\.id)) == originalAuxiliaries,
        "extensionFreshLoadingStatePreservesUnrelatedSourceSelectionAndNativeOwnership")
      try await cleanup()
      return checks
    } catch {
      let original = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native loading-state fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw original
    }
  }
}
