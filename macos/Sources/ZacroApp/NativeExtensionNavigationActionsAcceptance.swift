import Foundation
import ZacroChromium
import ZacroCore

/// Original permission-checked Chrome controller/session APIs. API completion
/// certifies dispatch and real controller installation; eventual online/error
/// documents are inspected separately and never define API success.
@MainActor enum NativeExtensionNavigationActionsAcceptance {
  private struct History { let urls: [String]; let index: Int }

  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_SEARCH_FIXTURE"] == "1",
      let rules = CefRuntime.shared.configuration?.extraCommandLineSwitches["host-resolver-rules"] ?? nil,
      rules.contains("MAP www.google.com ^NOTFOUND"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil, application.extensionBrowser.enabled,
      owner.windowContext.isOpen, !owner.windowContext.isClosing, !page.isPrivate,
      owner.store.state.activeProfile?.isPrivate == false,
      page.ownerWindowID == owner.windowContext.id, application.engine.pages[page.id] === page,
      let sourceURL = owner.store.tab(page.id)?.url else {
      throw ShortcutError("Navigation actions require the owned public fixture and pre-start blocked provider DNS.")
    }
    let sourceBrowser = try await page.ready(), sourceID = page.reservedNativeTabID
    guard try await sourceBrowser.nativeCapabilities().historyInstallation == true else {
      throw ShortcutError("Navigation actions require actual native controller-installation receipts.")
    }
    let originalSelection = owner.store.state.activeTabID
    let originalWindows = Set(application.windows.keys)
    let originalAuxiliary = Set(application.engine.auxiliaryBrowsers(profileID: page.profileID, isPrivate: false).map(\.id))
    let token = UUID().uuidString.lowercased()
    var owned = Set<String>(), conditioned: [ObjectIdentifier: CefBrowser] = [:]
    var checks: [String] = []

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension navigation action check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native navigation action acceptance failed: " + name) }
      checks.append(name)
    }
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func wait(_ phase: String, _ predicate: () async throws -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native navigation action acceptance timed out: " + phase)
    }
    func local(_ name: String) -> URL { url.appendingPathComponent("navigation-actions-" + name + "-" + token) }
    func blocked(_ name: String) -> URL {
      // This exact hostname is rejected by the startup DNS rule above. No
      // request here can reach an external provider, account or service.
      URL(string: "https://www.google.com/zacro-navigation-actions-" + name + "-" + token)!
    }
    func history(_ browser: CefBrowser) async throws -> History {
      let result = try await browser.devTools.call("Page.getNavigationHistory")
      guard let rows = result["entries"] as? [[String: Any]], let index = result["currentIndex"] as? Int,
        rows.indices.contains(index) else { throw ShortcutError("The actual native controller history is invalid.") }
      let urls = rows.compactMap { $0["url"] as? String }
      guard urls.count == rows.count else { throw ShortcutError("A real native history entry lost its address.") }
      return History(urls: urls, index: index)
    }
    func seed(_ entries: [URL], index: Int) throws -> BrowserTab {
      guard entries.indices.contains(index), let tab = owner.store.createTab(address: entries[index].absoluteString, activate: false) else {
        throw ShortcutError("The owned cold controller tab could not be created.")
      }
      owned.insert(tab.id)
      owner.store.updateTab(tab.id) {
        $0.navigation = entries.map { NavigationEntry(url: $0.absoluteString, title: "Owned saved controller entry") }
        $0.navigationIndex = index
      }
      guard application.engine.pages[tab.id] == nil, owner.store.state.activeTabID == originalSelection,
        let current = owner.store.tab(tab.id) else { throw ShortcutError("The owned cold history materialized before its real API action.") }
      return current
    }
    func nativeID(_ tab: BrowserTab, cold: Bool) async throws -> Int {
      await application.extensionBrowser.waitForTopologyPublication()
      guard let rows = try await worker.evaluate("""
        chrome.tabs.query({}).then(rows=>rows.filter(tab=>tab.url===\(try literal(tab.url)))
          .map(tab=>({id:tab.id,windowId:tab.windowId,discarded:tab.discarded,incognito:tab.incognito})))
        """, timeout: 15) as? [[String: Any]], rows.count == 1, let row = rows.first,
        let id = row["id"] as? Int, id > 0, row["windowId"] as? Int == owner.windowContext.nativeID,
        row["incognito"] as? Bool == false, row["discarded"] as? Bool == true,
        (!cold || application.engine.pages[tab.id] == nil) else {
        throw ShortcutError("The real tabs catalog did not identify exactly the owned cold/discarded controller.")
      }
      return id
    }
    func action(_ method: String, id: Int, name: String) async throws {
      guard ["goBack", "goForward", "reload"].contains(method), id > 0 else { throw ShortcutError("Invalid owned controller action.") }
      let arguments = method == "reload" ? "\(id),{bypassCache:true}" : String(id)
      guard let result = try await worker.evaluate("""
        (async()=>{try{const result=await chrome.tabs[\(try literal(method))](\(arguments));
          return {resolved:true,returnedUndefined:result===undefined};
        }catch(error){return {resolved:false,error:String(error).slice(0,2000)};}})()
        """, timeout: 20) as? [String: Any] else {
        throw ShortcutError("The original Chrome controller API returned no observation.")
      }
      if result["resolved"] as? Bool != true || result["returnedUndefined"] as? Bool != true {
        fputs("Native controller API failure \(name): \(String(describing: result).prefix(2200))\n", stderr)
      }
      try require(result["resolved"] as? Bool == true && result["returnedUndefined"] as? Bool == true,
        name + "OriginalChromeAPIReturnsVoidWithoutRequiringHTTPCommit")
    }
    func exact(_ target: ChromiumPage, id: Int, browser: CefBrowser) -> Bool {
      application.engine.pages[target.id] === target && target.browser === browser
        && target.reservedNativeTabID == id && target.ownerWindowID == owner.windowContext.id
        && target.profileID == page.profileID && !target.isPrivate
    }
    func eventual(_ target: ChromiumPage, id: Int, entries: [URL], index: Int, error: Bool, phase: String) async throws {
      let browser = try await target.ready()
      try await wait(phase + " actual controller destination") {
        guard exact(target, id: id, browser: browser), !target.isLoading,
          target.url == entries[index], owner.store.tab(target.id)?.url == entries[index].absoluteString else { return false }
        let actual = try await history(browser)
        return actual.urls == entries.map(\.absoluteString) && actual.index == index
          && (error ? target.documentError != nil : target.documentError == nil)
      }
      let actual = try await history(browser)
      try require(actual.urls == entries.map(\.absoluteString) && actual.index == index && exact(target, id: id, browser: browser),
        phase + "RetainsExactNativeIdentityAndBothActualControllerEntries")
      if !error {
        let address = try await browser.devTools.evaluate("location.href") as? String
        try require(address == entries[index].absoluteString, phase + "CommitsTheActualLoopbackDestination")
      } else {
        try require(target.documentError?.url == entries[index] && target.documentError?.code != -3,
          phase + "ReportsEventualNativeNetworkErrorSeparatelyFromAPISuccess")
      }
    }
    func offline(_ browser: CefBrowser, address: URL) async throws {
      guard address.host == "127.0.0.1", address.port == url.port, owned.contains(where: { application.engine.pages[$0]?.browser === browser }) else {
        throw ShortcutError("Offline rules may affect only the exact owned target and old selected loopback URL.")
      }
      conditioned[ObjectIdentifier(browser)] = browser
      _ = try await browser.devTools.call("Network.enable")
      _ = try await browser.devTools.call("Network.setCacheDisabled", parameters: ["cacheDisabled": true])
      let result = try await browser.devTools.call("Network.emulateNetworkConditionsByRule", parameters: [
        "matchedNetworkConditions": [["urlPattern": address.absoluteString, "offline": true,
          "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1]],
      ])
      guard (result["ruleIds"] as? [String])?.count == 1 else { throw ShortcutError("The exact per-target offline rule was not installed.") }
    }
    func clearConditions(_ browser: CefBrowser) async throws {
      guard !browser.isClosed else { conditioned.removeValue(forKey: ObjectIdentifier(browser)); return }
      _ = try await browser.devTools.call("Network.emulateNetworkConditionsByRule", parameters: ["matchedNetworkConditions": []])
      _ = try await browser.devTools.call("Network.setCacheDisabled", parameters: ["cacheDisabled": false])
      conditioned.removeValue(forKey: ObjectIdentifier(browser))
    }
    func discard(_ tabID: String, target: ChromiumPage, browser: CefBrowser, id: Int, phase: String) async throws {
      guard owner.store.state.activeTabID != tabID, !target.isLoading, target.documentError == nil else {
        throw ShortcutError("Only an inactive clean owned loopback document may be discarded.")
      }
      let discarded = try await owner.unloadInactiveTab(tabID)
      try require(discarded && owner.isDiscarded(tabID) && exact(target, id: id, browser: browser),
        phase + "StartsFromActualSafeDiscardAndRetainedWebContents")
    }
    func cleanup() async throws {
      var failure: Error?
      for browser in Array(conditioned.values) {
        do { try await clearConditions(browser) } catch { failure = failure ?? error }
      }
      for id in owned.sorted() where owner.store.tab(id)?.isClosed == false {
        if !(await owner.requestCloseTab(id)) { failure = failure ?? ShortcutError("An exact owned controller fixture refused normal close.") }
      }
      if let originalSelection, owner.store.tab(originalSelection)?.isClosed == false { owner.store.selectTab(id: originalSelection) }
      owner.scheduleLayout()
      if let failure { throw failure }
    }

    do {
      for (method, entries, selected, destination, fails) in [
        ("goBack", [local("cold-back-first"), blocked("cold-back-selected")], 1, 0, false),
        ("goForward", [blocked("cold-forward-selected"), local("cold-forward-next")], 0, 1, false),
        ("reload", [local("cold-reload-first"), blocked("cold-reload-selected")], 1, 1, true),
      ] {
        let phase = "navigationCold" + method
        let tab = try seed(entries, index: selected)
        let id = try await nativeID(tab, cold: true)
        try require(application.engine.pages[tab.id] == nil, phase + "QueryReservesIdentityWithoutMaterializing")
        try await action(method, id: id, name: phase)
        guard let target = application.engine.pages[tab.id] else { throw ShortcutError("The original controller action created no native document.") }
        try await eventual(target, id: id, entries: entries, index: destination, error: fails, phase: phase)
      }

      let entries = [local("dormant-first"), local("dormant-selected")]
      let dormant = try seed(entries, index: 1)
      let dormantID = try await nativeID(dormant, cold: true)
      let retained = try await owner.ensurePageReady(dormant)
      try await application.navigation.waitForRestore(retained)
      let retainedBrowser = try await retained.ready()
      try await eventual(retained, id: dormantID, entries: entries, index: 1, error: false, phase: "navigationDormantInitial")
      for (method, selected, destination, fails) in [("goBack", 1, 0, false), ("goForward", 0, 1, false), ("reload", 1, 1, true)] {
        let phase = "navigationDormant" + method
        try await discard(dormant.id, target: retained, browser: retainedBrowser, id: dormantID, phase: phase)
        try await offline(retainedBrowser, address: entries[selected])
        guard let current = owner.store.tab(dormant.id) else { throw ShortcutError("The retained dormant Core tab disappeared.") }
        let observed = try await nativeID(current, cold: false)
        try require(observed == dormantID && owner.isDiscarded(dormant.id), phase + "CatalogAndOfflineRuleDoNotAwakenTheTarget")
        try await action(method, id: dormantID, name: phase)
        try await eventual(retained, id: dormantID, entries: entries, index: destination, error: fails, phase: phase)
        try await clearConditions(retainedBrowser)
      }

      let restoreEntries = [local("restored-first"), blocked("restored-selected")]
      let closed = try seed(restoreEntries, index: 1)
      _ = try await nativeID(closed, cold: true)
      try require(await owner.requestCloseTab(closed.id), "navigationSessionColdTabClosesThroughActualOwner")
      guard application.engine.pages[closed.id] == nil,
        let archive = owner.store.state.archive.first(where: { $0.id == closed.id }),
        archive.tab.navigation.map(\.url) == restoreEntries.map(\.absoluteString), archive.tab.navigationIndex == 1 else {
        throw ShortcutError("The actual closed session did not retain its unmaterialized two-entry history.")
      }
      guard let sessions = try await worker.evaluate("chrome.sessions.getRecentlyClosed({maxResults:25})", timeout: 15) as? [[String: Any]] else {
        throw ShortcutError("The original Chrome sessions API returned no actual closed-session list.")
      }
      let matching = sessions.compactMap { $0["tab"] as? [String: Any] }.filter { $0["url"] as? String == restoreEntries[1].absoluteString }
      guard matching.count == 1, let sessionID = matching.first?["sessionId"] as? String, !sessionID.isEmpty else {
        throw ShortcutError("The original sessions API did not expose exactly the owned cold closed session.")
      }
      guard let result = try await worker.evaluate("""
        (async()=>{try{const session=await chrome.sessions.restore(\(try literal(sessionID)));
          return {resolved:true,session};}catch(error){return {resolved:false,error:String(error).slice(0,2000)};}})()
        """, timeout: 20) as? [String: Any], result["resolved"] as? Bool == true,
        let restoredTab = (result["session"] as? [String: Any])?["tab"] as? [String: Any],
        let restoredID = restoredTab["id"] as? Int, restoredID > 0,
        restoredTab["windowId"] as? Int == owner.windowContext.nativeID,
        restoredTab["url"] as? String == restoreEntries[1].absoluteString,
        let restored = application.engine.pages[closed.id] else {
        throw ShortcutError("The original sessions.restore did not return its real offline native tab/session.")
      }
      let restoredBrowser = try await restored.ready()
      let installed = try await history(restoredBrowser)
      try require(exact(restored, id: restoredID, browser: restoredBrowser)
        && owner.store.tab(closed.id)?.id == closed.id && owner.store.tab(closed.id)?.isClosed == false
        && !owner.store.state.archive.contains { $0.id == closed.id }
        && installed.urls == restoreEntries.map(\.absoluteString) && installed.index == 1,
        "navigationSessionsRestoreReturnsExactLiveIdentityAndInstalledSavedStackWhileSelectedURLOffline")
      try await eventual(restored, id: restoredID, entries: restoreEntries, index: 1, error: true, phase: "navigationSessionRestore")
      try await action("goBack", id: restoredID, name: "navigationSessionRestoredBack")
      try await eventual(restored, id: restoredID, entries: restoreEntries, index: 0, error: false, phase: "navigationSessionRestoredBack")

      try require(application.engine.pages[page.id] === page && page.browser === sourceBrowser
        && page.reservedNativeTabID == sourceID && owner.store.tab(page.id)?.url == sourceURL
        && Set(application.windows.keys) == originalWindows
        && Set(application.engine.auxiliaryBrowsers(profileID: page.profileID, isPrivate: false).map(\.id)) == originalAuxiliary,
        "navigationControllerAndSessionActionsPreserveUnrelatedSourceAndCreateNoAuxiliaryBrowser")
      try await cleanup()
      return checks
    } catch {
      let original = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native navigation action fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw original
    }
  }
}
