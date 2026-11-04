import Foundation
import ZacroChromium
import ZacroCore

/// Original Chrome tabs.update calls against a cold reserved tab and a real
/// retained discard. Only the owned selected URL is made offline by Chromium;
/// its replacement and the unrelated source document remain online.
@MainActor enum NativeExtensionTabsUpdateHistoryAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_SEARCH_FIXTURE"] == "1",
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      application.engine.pages[page.id] === page, !page.isPrivate,
      page.ownerWindowID == owner.windowContext.id, owner.windowContext.isOpen,
      !owner.windowContext.isClosing, application.extensionBrowser.enabled else {
      throw ShortcutError("Tab-update history acceptance requires the owned public loopback fixture.")
    }
    let originalSelection = owner.store.state.activeTabID
    let sourceBrowser = try await page.ready(), sourceNativeID = page.reservedNativeTabID
    guard try await sourceBrowser.nativeCapabilities().historyInstallation == true else {
      throw ShortcutError("Tab-update history acceptance requires native history installation receipts.")
    }
    var ownedID: String?, conditionedBrowser: CefBrowser?
    var checks = [String]()
    func require(_ condition: Bool, _ name: String) throws {
      fputs("Native extension tab-update history check \(condition ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard condition else { throw ShortcutError("Native tab-update history acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native tab-update history acceptance timed out: " + phase)
    }
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func history(_ browser: CefBrowser) async throws -> (urls: [String], index: Int) {
      let response = try await browser.devTools.call("Page.getNavigationHistory")
      guard let values = response["entries"] as? [[String: Any]], let index = response["currentIndex"] as? Int,
        values.indices.contains(index) else { throw ShortcutError("The owned native history response is invalid.") }
      let urls = values.compactMap { $0["url"] as? String }
      guard urls.count == values.count else { throw ShortcutError("A native history entry lost its URL.") }
      return (urls, index)
    }
    func update(_ nativeID: Int, destination: URL) async throws {
      guard let response = try await worker.evaluate("""
        (async()=>{try{const tab=await chrome.tabs.update(\(nativeID),
          {url:\(try literal(destination.absoluteString)),active:false});
          return {resolved:true,id:tab.id,windowId:tab.windowId,url:tab.url};
        }catch(error){return {resolved:false,error:String(error).slice(0,2000)};}})()
        """, timeout: 20) as? [String: Any] else {
        throw ShortcutError("The original tabs.update returned no actual API result.")
      }
      guard response["resolved"] as? Bool == true, response["id"] as? Int == nativeID,
        response["windowId"] as? Int == owner.windowContext.nativeID,
        response["url"] as? String == destination.absoluteString else {
        throw ShortcutError("The original tabs.update did not resolve its owned native tab: "
          + String((response["error"] as? String ?? String(describing: response)).prefix(2_000)))
      }
    }
    func backThroughSavedEntries(_ target: ChromiumPage, browser: CefBrowser, nativeID: Int,
      first: URL, selected: URL, replacement: URL, phase: String) async throws {
      try await wait(phase + " replacement commits") {
        !target.isLoading && target.url == replacement && target.documentError == nil
      }
      let expected = [first.absoluteString, selected.absoluteString, replacement.absoluteString]
      let current = try await history(browser)
      try require(current.urls == expected && current.index == 2 && target.reservedNativeTabID == nativeID,
        "tabsUpdate" + phase + "PreservesBothSavedEntriesAndExactNativeIdentity")
      for (destination, index) in [(selected, 1), (first, 0)] {
        target.goBack()
        try await wait(phase + " native Back " + String(index)) {
          !target.isLoading && target.url == destination && target.documentError == nil
        }
        let actual = try await history(browser)
        let location = try await browser.devTools.evaluate("location.href") as? String
        try require(actual.urls == expected && actual.index == index && location == destination.absoluteString
          && target.browser === browser && application.engine.pages[target.id] === target
          && target.reservedNativeTabID == nativeID && target.ownerWindowID == owner.windowContext.id,
          "tabsUpdate" + phase + "NativeBackCommitsSavedEntry" + String(index))
      }
    }
    func clearConditions() async throws {
      guard let browser = conditionedBrowser else { return }
      guard !browser.isClosed else { conditionedBrowser = nil; return }
      _ = try await browser.devTools.call("Network.emulateNetworkConditionsByRule",
        parameters: ["matchedNetworkConditions": []])
      _ = try await browser.devTools.call("Network.setCacheDisabled", parameters: ["cacheDisabled": false])
      conditionedBrowser = nil
    }
    func cleanup() async throws {
      var failure: Error?
      do { try await clearConditions() } catch { failure = error }
      if let ownedID, owner.store.tab(ownedID)?.isClosed == false, !(await owner.requestCloseTab(ownedID)) {
        failure = failure ?? ShortcutError("The exact owned tab-update fixture refused normal close.")
      }
      if let originalSelection, owner.store.tab(originalSelection)?.isClosed == false {
        owner.store.selectTab(id: originalSelection)
      }
      owner.scheduleLayout()
      if let failure { throw failure }
    }

    do {
      let token = UUID().uuidString.lowercased()
      let first = url.appendingPathComponent("native-tab-update-first-" + token)
      var selectedComponents = URLComponents(url: url.appendingPathComponent("native-delayed-commit"), resolvingAgainstBaseURL: false)!
      selectedComponents.queryItems = [URLQueryItem(name: "tab-update-history", value: token)]
      guard let selected = selectedComponents.url,
        let tab = owner.store.createTab(address: selected.absoluteString, activate: false) else {
        throw ShortcutError("The owned cold tab-update history could not be created.")
      }
      ownedID = tab.id
      owner.store.updateTab(tab.id) {
        $0.navigation = [NavigationEntry(url: first.absoluteString), NavigationEntry(url: selected.absoluteString)]
        $0.navigationIndex = 1
      }
      try require(application.engine.pages[tab.id] == nil && owner.store.state.activeTabID == originalSelection,
        "tabsUpdateColdStartsWithSavedStackAndNoWebContents")
      await application.extensionBrowser.waitForTopologyPublication()
      guard let matches = try await worker.evaluate("""
        (async()=>(await chrome.tabs.query({})).filter(tab=>tab.url===\(try literal(selected.absoluteString)))
          .map(tab=>({id:tab.id,discarded:tab.discarded})))()
        """) as? [[String: Any]], matches.count == 1, let nativeID = matches.first?["id"] as? Int, nativeID > 0 else {
        throw ShortcutError("The real Chrome API did not reserve one exact cold tab-update target.")
      }
      try require(application.engine.pages[tab.id] == nil && matches.first?["discarded"] as? Bool == true,
        "tabsUpdateColdQueryDoesNotMaterializeReservedNativeTab")
      let coldReplacement = url.appendingPathComponent("native-tab-update-cold-" + token)
      try await update(nativeID, destination: coldReplacement)
      try require(true, "tabsUpdateColdResolvesOriginalChromeAPI")
      guard let target = application.engine.pages[tab.id] else { throw ShortcutError("The actual updated native page is missing.") }
      let browser = try await target.ready()
      try await backThroughSavedEntries(target, browser: browser, nativeID: nativeID,
        first: first, selected: selected, replacement: coldReplacement, phase: "Cold")
      target.goForward()
      try await wait("middle entry before actual discard") {
        !target.isLoading && target.url == selected && target.documentError == nil
      }
      func checkRetiredAdapterSafety(_ name: String) async throws {
        let lease = try await application.peekLinks.suspendForDiscard(target)
        do {
          let safety = try await browser.documentSafetyState()
          try require(!safety.beforeUnload && !safety.loading && !safety.crashed
            && application.engine.pages[target.id] === target && target.browser === browser
            && target.reservedNativeTabID == nativeID && target.ownerWindowID == owner.windowContext.id,
            name)
        } catch {
          await application.peekLinks.resumeAfterDiscard(lease)
          throw error
        }
        await application.peekLinks.resumeAfterDiscard(lease)
      }
      // Retire/recreate the bridge while another actual document remains in
      // native Back history. Restoring that predecessor must not revive the
      // retired bridge's pagehide listener or leave a native unload blocker.
      try await checkRetiredAdapterSafety("tabsUpdateCurrentAdapterRetiresOnlyItsOwnUnloadHandlers")
      _ = try await browser.devTools.call("Page.enable")
      var cachedPredecessorRestored = false
      let lifecycleObserver = try browser.devTools.observeProtocolEvents { method, parameters, source in
        guard source == nil, method == "Page.frameNavigated",
          parameters["type"] as? String == "BackForwardCacheRestore",
          let frame = parameters["frame"] as? [String: Any], frame["parentId"] == nil,
          frame["url"] as? String == first.absoluteString else { return }
        cachedPredecessorRestored = true
      }
      defer { browser.devTools.removeEventObserver(lifecycleObserver) }
      target.goBack()
      try await wait("cached predecessor after exact adapter replacement") {
        !target.isLoading && target.url == first && target.documentError == nil
      }
      let predecessor = try await history(browser)
      let predecessorLocation = try await browser.devTools.evaluate("location.href") as? String
      try require(cachedPredecessorRestored && predecessor.index == 0
        && predecessor.urls == [first.absoluteString, selected.absoluteString, coldReplacement.absoluteString]
        && predecessorLocation == first.absoluteString,
        "tabsUpdateRetiredAdapterPredecessorRestoresFromActualBackForwardCache")
      try await checkRetiredAdapterSafety("tabsUpdateCachedRetiredAdapterHasNoNativeUnloadBlocker")
      target.goForward()
      try await wait("original middle entry after cached adapter replacement") {
        !target.isLoading && target.url == selected && target.documentError == nil
      }
      let discarded = try await owner.unloadInactiveTab(tab.id)
      try require(discarded && owner.isDiscarded(tab.id) && application.engine.pages[tab.id] === target
        && target.browser === browser && target.reservedNativeTabID == nativeID,
        "tabsUpdateDormantRetainsActualDiscardedWebContentsAndIdentity")
      conditionedBrowser = browser
      _ = try await browser.devTools.call("Network.enable")
      _ = try await browser.devTools.call("Network.setCacheDisabled", parameters: ["cacheDisabled": true])
      let rule = try await browser.devTools.call("Network.emulateNetworkConditionsByRule", parameters: [
        "matchedNetworkConditions": [["urlPattern": selected.absoluteString, "offline": true,
          "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1]],
      ])
      try require((rule["ruleIds"] as? [String])?.count == 1 && owner.isDiscarded(tab.id),
        "tabsUpdateDormantNativeOfflineRuleTargetsOnlyOldSelectedURL")
      let dormantReplacement = url.appendingPathComponent("native-tab-update-dormant-" + token)
      try await update(nativeID, destination: dormantReplacement)
      try require(true, "tabsUpdateDormantOldOfflineRequestDoesNotRejectOriginalChromeAPI")
      try await clearConditions()
      try await backThroughSavedEntries(target, browser: browser, nativeID: nativeID,
        first: first, selected: selected, replacement: dormantReplacement, phase: "Dormant")
      try require(application.engine.pages[page.id] === page && page.browser === sourceBrowser
        && page.reservedNativeTabID == sourceNativeID && owner.store.state.activeTabID == originalSelection,
        "tabsUpdateSavedHistoryPreservesUnrelatedSourceAndSelection")
      try await cleanup()
      return checks
    } catch {
      let original = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native tab-update history cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw original
    }
  }
}
