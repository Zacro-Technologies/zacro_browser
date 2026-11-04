import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// The original extension API must install a cold/dormant tab's real native
/// history before a replacement search cancels its selected network request.
/// Every tab and navigation here belongs to the disposable loopback fixture.
@MainActor enum NativeExtensionSearchHistoryAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_SEARCH_FIXTURE"] == "1",
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      let rules = CefRuntime.shared.configuration?.extraCommandLineSwitches["host-resolver-rules"] ?? nil,
      rules.contains("MAP www.google.com ^NOTFOUND"),
      application.extensionBrowser.enabled,
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      owner.store.state.activeProfile?.isPrivate == false,
      application.engine.pages[page.id] === page,
      page.ownerWindowID == owner.windowContext.id else {
      throw ShortcutError("Search history acceptance requires the isolated public loopback fixture with blocked provider DNS.")
    }
    let fixtureBrowser = try await page.ready()
    guard try await fixtureBrowser.nativeCapabilities().historyInstallation == true else {
      throw ShortcutError("Search-history acceptance requires the custom runtime's native history-installation receipt capability.")
    }
    let originalProvider = owner.store.state.settings.searchEngine
    let originalSelection = owner.store.state.activeTabID
    let originalSourceURL = owner.store.tab(page.id)?.url
    let originalBrowser = page.browser
    let originalNativeID = page.reservedNativeTabID
    var ownedTabs = [String]()
    var checks = [String]()
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension search history check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native search history acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native search history acceptance timed out: " + phase)
    }
    func queryNativeID(address: String) async throws -> Int {
      await application.extensionBrowser.waitForTopologyPublication()
      guard let matches = try await worker.evaluate("""
        (async () => (await chrome.tabs.query({})).filter(tab => tab.url === \(try literal(address)))
          .map(tab => ({id:tab.id, url:tab.url, discarded:tab.discarded})))()
        """, timeout: 15) as? [[String: Any]], matches.count == 1,
        let nativeID = matches.first?["id"] as? Int, nativeID > 0 else {
        throw ShortcutError("The real Chrome tabs API did not reserve exactly one owned cold/dormant native tab.")
      }
      return nativeID
    }
    func search(tabID: Int, text: String) async throws {
      guard let result = try await worker.evaluate("""
        (async () => {
          try { const result = await chrome.search.query({text:\(try literal(text)),tabId:\(tabID)});
            return {resolved:true,returnedUndefined:result===undefined}; }
          catch(error) { return {resolved:false,error:String(error).slice(0,2000)}; }
        })()
        """, timeout: 20) as? [String: Any], result["resolved"] as? Bool == true,
        result["returnedUndefined"] as? Bool == true else {
        throw ShortcutError("The original chrome.search.query did not resolve its void API result for the saved native tab.")
      }
    }
    func history(_ target: ChromiumPage) async throws -> (addresses: [String], selected: Int) {
      let browser = try await target.ready()
      let result = try await browser.devTools.call("Page.getNavigationHistory")
      guard let entries = result["entries"] as? [[String: Any]],
        let selected = result["currentIndex"] as? Int,
        entries.indices.contains(selected) else {
        throw ShortcutError("The actual Chromium tab did not return valid native navigation history.")
      }
      let addresses = entries.compactMap { $0["url"] as? String }
      guard addresses.count == entries.count else { throw ShortcutError("A native navigation entry lost its address.") }
      return (addresses, selected)
    }
    func exerciseSearch(tab: BrowserTab, nativeID: Int, first: URL, selected: URL,
      retainedPage: ChromiumPage?, phase: String) async throws -> ChromiumPage {
      let text = "Zacro owned " + phase + " history " + UUID().uuidString
      guard let expected = BrowserAddress.searchURL(text, engine: .google) else {
        throw ShortcutError("The owned search history fixture has no search destination.")
      }
      try await search(tabID: nativeID, text: text)
      try require(true, "search" + phase + "SavedNativeTargetResolvesOriginalAPI")
      var target: ChromiumPage?
      try await wait(phase + " actual search document") {
        guard let candidate = application.engine.pages[tab.id], !candidate.isLoading,
          candidate.url == expected else { return false }
        target = candidate
        return true
      }
      guard let target else { throw ShortcutError("The saved native search target disappeared.") }
      try require(target.reservedNativeTabID == nativeID
        && target.ownerWindowID == owner.windowContext.id
        && target.profileID == page.profileID && !target.isPrivate
        && (retainedPage == nil || target === retainedPage)
        && owner.store.tab(tab.id)?.url == expected.absoluteString,
        "search" + phase + "RetainsReservedNativeIdentityAndExactLogicalOwner")
      let afterSearch = try await history(target)
      try require(afterSearch.addresses == [first.absoluteString, selected.absoluteString, expected.absoluteString]
        && afterSearch.selected == 2 && target.canGoBack,
        "search" + phase + "InstallsBothSavedEntriesBeforeReplacingSelectedNetworkRequest")
      let browser = try await target.ready()
      target.goBack()
      try await wait(phase + " native Back to saved selected entry") {
        !target.isLoading && target.url == selected && target.documentError == nil
      }
      let backSelected = try await history(target)
      let selectedLocation = try await browser.devTools.evaluate("location.href") as? String
      try require(backSelected.addresses == afterSearch.addresses && backSelected.selected == 1
        && selectedLocation == selected.absoluteString && target.canGoBack && target.canGoForward,
        "search" + phase + "NativeBackCommitsOriginalSelectedEntry")
      target.goBack()
      try await wait(phase + " native Back to first saved entry") {
        !target.isLoading && target.url == first && target.documentError == nil
      }
      let backFirst = try await history(target)
      let firstLocation = try await browser.devTools.evaluate("location.href") as? String
      try require(backFirst.addresses == afterSearch.addresses && backFirst.selected == 0
        && firstLocation == first.absoluteString && !target.canGoBack && target.canGoForward
        && application.engine.pages[tab.id] === target && target.browser === browser
        && target.reservedNativeTabID == nativeID,
        "search" + phase + "NativeBackRetainsEarlierEntryAndSameWebContents")
      return target
    }
    func cleanup() async throws {
      var failure: Error?
      for id in ownedTabs.reversed() where owner.store.tab(id)?.isClosed == false {
        if !(await owner.requestCloseTab(id)) {
          failure = failure ?? ShortcutError("An exact owned search-history fixture tab did not accept normal closure.")
        }
      }
      owner.store.updateSettings { $0.searchEngine = originalProvider }
      if let originalSelection, owner.store.tab(originalSelection)?.isClosed == false {
        owner.store.selectTab(id: originalSelection)
      }
      owner.scheduleLayout()
      if let failure { throw failure }
    }

    do {
      owner.store.updateSettings { $0.searchEngine = .google }
      let token = UUID().uuidString.lowercased()
      let first = url.appendingPathComponent("native-search-history-first-" + token)
      // This existing loopback route delays response headers. It makes a
      // selected restore request cancellable without any external network.
      guard var selectedComponents = URLComponents(url: url.appendingPathComponent("native-delayed-commit"), resolvingAgainstBaseURL: false) else {
        throw ShortcutError("The owned delayed history address could not be constructed.")
      }
      selectedComponents.queryItems = [URLQueryItem(name: "search-history", value: token)]
      guard let selected = selectedComponents.url,
        let cold = owner.store.createTab(address: selected.absoluteString, activate: false) else {
        throw ShortcutError("The owned cold search-history tab could not be created.")
      }
      ownedTabs.append(cold.id)
      owner.store.updateTab(cold.id) {
        $0.navigation = [NavigationEntry(url: first.absoluteString, title: "First saved destination"),
          NavigationEntry(url: selected.absoluteString, title: "Selected saved destination")]
        $0.navigationIndex = 1
      }
      try require(application.engine.pages[cold.id] == nil && owner.store.state.activeTabID == originalSelection,
        "searchColdHistoryStartsWithOnlyTwoSavedCoreEntriesAndNoWebContents")
      let coldNativeID = try await queryNativeID(address: selected.absoluteString)
      try require(application.engine.pages[cold.id] == nil,
        "searchColdTabsQueryReservesNativeIdentityWithoutMaterializingDocument")
      let target = try await exerciseSearch(tab: cold, nativeID: coldNativeID, first: first,
        selected: selected, retainedPage: nil, phase: "Cold")

      // Exercise the same ordering through a real safe native discard, rather
      // than treating an absent WebContents and a retained dormant one alike.
      target.goForward()
      try await wait("selected entry before native discard") {
        !target.isLoading && target.url == selected && target.documentError == nil
      }
      let historyBeforeDiscard = try await history(target)
      try require(historyBeforeDiscard.selected == 1
        && Array(historyBeforeDiscard.addresses.prefix(2)) == [first.absoluteString, selected.absoluteString],
        "searchDormantFixtureSelectsActualMiddleEntryWithForwardHistory")
      guard owner.store.state.activeTabID != cold.id else {
        throw ShortcutError("The real search API unexpectedly activated the background fixture target.")
      }
      let discarded = try await owner.unloadInactiveTab(cold.id)
      try require(discarded && owner.isDiscarded(cold.id)
        && application.engine.pages[cold.id] === target && target.reservedNativeTabID == coldNativeID,
        "searchDormantHistoryUsesActualSafeDiscardAndRetainsNativeTabIdentity")
      let dormantNativeID = try await queryNativeID(address: selected.absoluteString)
      try require(dormantNativeID == coldNativeID && owner.isDiscarded(cold.id),
        "searchDormantTabsQueryDoesNotRestoreOrReplaceReservedNativeTarget")
      guard let dormantTab = owner.store.tab(cold.id) else { throw ShortcutError("The owned dormant Core tab disappeared.") }
      _ = try await exerciseSearch(tab: dormantTab, nativeID: dormantNativeID, first: first,
        selected: selected, retainedPage: target, phase: "Dormant")
      checks += try await NativeExtensionTabsUpdateHistoryAcceptance.run(application: application,
        url: url, owner: owner, page: page, worker: worker)
      checks += try await NativeExtensionNavigationActionsAcceptance.run(application: application,
        url: url, owner: owner, page: page, worker: worker)
      try require(application.engine.pages[page.id] === page && page.browser === originalBrowser
        && page.reservedNativeTabID == originalNativeID && owner.store.tab(page.id)?.url == originalSourceURL
        && owner.store.state.activeTabID == originalSelection,
        "searchSavedHistoryChecksPreserveUnrelatedOriginalDocumentAndSelection")
      try await cleanup()
      return checks
    } catch {
      let failure = error
      let task = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native search-history fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await task.value
      throw failure
    }
  }
}
