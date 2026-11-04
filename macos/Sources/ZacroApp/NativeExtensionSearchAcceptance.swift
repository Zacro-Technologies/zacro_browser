import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Real permission-checked Chrome search.query calls in an owned disposable
/// extension worker. Provider lookups are blocked before runtime initialization;
/// generated queries never need an external search page to count as a pass.
@MainActor enum NativeExtensionSearchAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_SEARCH_FIXTURE"] == "1",
      let rules = CefRuntime.shared.configuration?.extraCommandLineSwitches["host-resolver-rules"] ?? nil,
      ["www.google.com", "duckduckgo.com", "www.bing.com", "search.brave.com"].allSatisfy({ rules.contains("MAP " + $0 + " ^NOTFOUND") }),
      application.extensionBrowser.enabled, CefAuxiliaryAdmissionLease.isSupported,
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      owner.store.state.activeProfile?.isPrivate == false,
      page.ownerWindowID == owner.windowContext.id,
      application.engine.pages[page.id] === page,
      ProcessInfo.processInfo.environment["ZACRO_NATIVE_EXTENSION_FIXTURE"]?.isEmpty == false else {
      throw ShortcutError("Search acceptance requires the fresh custom-runtime fixture and blocked external provider lookups.")
    }
    let profile = page.profileID, originalProvider = owner.store.state.settings.searchEngine
    let originalSourceURL = owner.store.tab(page.id)?.url ?? page.url?.absoluteString ?? url.absoluteString
    let originalNativeID = page.reservedNativeTabID
    let originalWindowIDs = Set(application.windows.keys)
    let originalTabs = Set(application.store.state.tabs.map(\.id))
    let originalAuxiliaryIDs = Set(application.engine.auxiliaryBrowsers(profileID: profile, isPrivate: false).map(\.id))
    var checks: [String] = []
    var isolationOwner: BrowserWindowCoordinator?
    var lease: CefAuxiliaryAdmissionLease?
    var ownedNewWindows = Set<String>()

    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func require(_ value: Bool, _ name: String, detail: String? = nil) throws {
      fputs("Native extension search check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else {
        throw ShortcutError("Native search acceptance failed: " + name + (detail.map { ": " + String($0.prefix(1_000)) } ?? ""))
      }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        if condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native search acceptance timed out: " + name)
    }
    func query(_ arguments: [String: Any]) async throws -> [String: Any] {
      let expression = """
        (async () => {
          try {
            const result = await chrome.search.query(\(try literal(arguments)));
            return {resolved:true, returnedUndefined:result === undefined};
          } catch(error) { return {resolved:false, error:String(error).slice(0,2000),
            errorName:String(error?.name ?? '').slice(0,160), errorMessage:String(error?.message ?? '').slice(0,2000)}; }
        })()
        """
      guard let result = try await worker.evaluate(expression, timeout: 15) as? [String: Any] else {
        throw ShortcutError("The real Chrome search API returned no fixture result.")
      }
      return result
    }
    func logResult(_ result: [String: Any], _ name: String) {
      let tabs = application.store.state.tabs.filter { $0.id == page.id || !originalTabs.contains($0.id) }.prefix(8).map { tab -> [String: Any] in
        let native = application.engine.pages[tab.id]
        return ["id": tab.id, "windowID": tab.windowID ?? "", "closed": tab.isClosed,
          "modelURL": String(tab.url.prefix(1_000)), "nativeURL": String((native?.url?.absoluteString ?? "").prefix(1_000)),
          "nativeID": native?.reservedNativeTabID ?? -1, "loading": native?.isLoading ?? false,
          "nativeOwner": native?.ownerWindowID ?? "", "profile": native?.profileID ?? "",
          "documentErrorCode": native?.documentError?.code ?? 0,
          "documentError": String((native?.documentError?.message ?? "").prefix(500))]
      }
      let diagnostic: [String: Any] = ["check": name, "result": result,
        "owner": owner.windowContext.id, "ownerOpen": owner.windowContext.isOpen,
        "ownerClosing": owner.windowContext.isClosing, "activeTab": owner.store.state.activeTabID ?? "",
        "tabs": tabs]
      if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) {
        fputs("Native extension search result \(name): \(text)\n", stderr)
      }
    }
    func requireResolved(_ result: [String: Any], _ name: String) throws {
      let valid = result["resolved"] as? Bool == true && result["returnedUndefined"] as? Bool == true
      if !valid { logResult(result, name) }
      try require(valid, name, detail: result["error"] as? String
        ?? "resolved=\(String(describing: result["resolved"])) returnedUndefined=\(String(describing: result["returnedUndefined"]))")
    }
    func requireRejected(_ result: [String: Any], _ name: String) throws {
      let valid = result["resolved"] as? Bool == false && !(result["error"] as? String ?? "").isEmpty
      if !valid { logResult(result, name) }
      try require(valid, name, detail: result["error"] as? String ?? "The real native API did not reject this call.")
    }
    func selected(_ provider: SearchEngine) {
      owner.store.updateSettings { $0.searchEngine = provider }
    }
    func freshTabs() -> [BrowserTab] {
      application.store.state.tabs.filter { !originalTabs.contains($0.id) && !$0.isClosed }
    }
    func cleanup() async throws {
      var failure: Error?
      do { try lease?.release(); lease = nil }
      catch { failure = error }
      for id in ownedNewWindows {
        if let child = application.windows[id], child.windowContext.isOpen, !(await child.requestCloseWindow()) {
          failure = failure ?? ShortcutError("An owned search fixture window did not accept normal closure.")
        }
      }
      if let isolationOwner, isolationOwner.windowContext.isOpen, !(await isolationOwner.requestCloseWindow()) {
        failure = failure ?? ShortcutError("The isolated search fixture owner did not accept normal closure.")
      }
      for tab in freshTabs() where tab.windowID == owner.windowContext.id {
        if !(await application.extensionBrowser.closeTab(tab.id)) {
          failure = failure ?? ShortcutError("An owned search fixture tab did not accept normal closure.")
        }
      }
      owner.store.updateSettings { $0.searchEngine = originalProvider }
      if owner.windowContext.isOpen, owner.store.tab(page.id)?.isClosed == false {
        owner.store.selectTab(id: page.id)
        owner.navigate(originalSourceURL)
        owner.windowContext.show()
        do {
          try await wait("exact original search source document restoration") {
            originalNativeID != nil && application.engine.pages[page.id] === page
              && page.reservedNativeTabID == originalNativeID
              && owner.store.tab(page.id)?.url == originalSourceURL
              && page.url?.absoluteString == originalSourceURL
              && !page.isLoading && page.documentError == nil
          }
        } catch { failure = failure ?? error }
      } else {
        failure = failure ?? ShortcutError("The original search fixture document owner closed before restoration.")
      }
      if let failure { throw failure }
    }

    do {
      owner.store.selectTab(id: page.id)
      owner.windowContext.show()
      NSApp.activate(ignoringOtherApps: true)
      application.repository.focusWindow(owner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
      guard let nativeSource = page.reservedNativeTabID else { throw ShortcutError("The search source has no real native tab ID.") }
      selected(.google)
      let invalidBefore = application.store.state.tabs
      try requireRejected(try await query(["text": ""]), "searchNativeSchemaRejectsEmptyText")
      try requireRejected(try await query(["text": "owned", "tabId": nativeSource, "disposition": "CURRENT_TAB"]),
        "searchNativeSchemaRejectsTabAndDispositionTogether")
      try require(application.store.state.tabs == invalidBefore, "searchInvalidArgumentsDoNotMutateLogicalTabs")
      checks += try await NativeExtensionLoadingStateAcceptance.run(application: application,
        url: url, owner: owner, page: page, worker: worker)
      checks += try await NativeExtensionSearchHistoryAcceptance.run(application: application,
        url: url, owner: owner, page: page, worker: worker)

      let literalQuery = "https://example.com/owned?q=one&two=three+four#five"
      let google = try BrowserAddress.searchURL(literalQuery, engine: .google).unwrap(or: ShortcutError("No fixture search URL."))
      try requireResolved(try await query(["text": literalQuery, "tabId": nativeSource]),
        "searchExplicitNativeTabResolvesWithOriginalVoidAPIResult")
      try await wait("literal search navigation") {
        owner.store.tab(page.id)?.url == google.absoluteString && page.url?.absoluteString == google.absoluteString
      }
      try require(application.engine.pages[page.id] === page && page.reservedNativeTabID == nativeSource
        && page.ownerWindowID == owner.windowContext.id
        && URLComponents(string: owner.store.tab(page.id)?.url ?? "")?.queryItems?.first?.value == literalQuery,
        "searchLiteralURLRemainsQueryAndRetainsExactDocumentIdentity")

      selected(.bing)
      owner.store.selectTab(id: page.id)
      application.repository.focusWindow(owner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
      let currentText = "Zacro native selected provider " + UUID().uuidString
      let bing = try BrowserAddress.searchURL(currentText, engine: .bing).unwrap(or: ShortcutError("No Bing fixture URL."))
      try requireResolved(try await query(["text": currentText]), "searchWorkerCurrentTabUsesLogicalFocusedProfileWindow")
      try await wait("selected provider navigation") {
        owner.store.tab(page.id)?.url == bing.absoluteString && page.url?.absoluteString == bing.absoluteString
      }
      try require(owner.store.tab(page.id)?.url == bing.absoluteString, "searchCurrentTabHonorsUserSelectedProvider")

      selected(.brave)
      let beforeNewTab = Set(application.store.state.tabs.map(\.id))
      let newText = "Zacro native new tab " + UUID().uuidString
      let brave = try BrowserAddress.searchURL(newText, engine: .brave).unwrap(or: ShortcutError("No Brave fixture URL."))
      try requireResolved(try await query(["text": newText, "disposition": "NEW_TAB"]),
        "searchNewTabResolvesThroughRealChromeAPI")
      let added = application.store.state.tabs.filter { !beforeNewTab.contains($0.id) && !$0.isClosed }
      guard added.count == 1, let newTab = added.first,
        let newPage = application.engine.pages[newTab.id] else { throw ShortcutError("Search did not create exactly one real logical tab.") }
      try await wait("actual new-tab provider navigation") { newPage.url?.absoluteString == brave.absoluteString }
      try require(newTab.windowID == owner.windowContext.id && newTab.url == brave.absoluteString
        && newPage.ownerWindowID == owner.windowContext.id && newPage.profileID == profile,
        "searchNewTabOwnsItsActualNativePageInSelectedLogicalWindow")
      try require(Set(application.windows.keys) == originalWindowIDs,
        "searchNewTabCreatesNoUnmodeledBrowserWindow")

      selected(.duckduckgo)
      let beforeNewWindow = Set(application.windows.keys)
      let windowText = "Zacro native new window " + UUID().uuidString
      let duck = try BrowserAddress.searchURL(windowText, engine: .duckduckgo).unwrap(or: ShortcutError("No DuckDuckGo fixture URL."))
      try requireResolved(try await query(["text": windowText, "disposition": "NEW_WINDOW"]),
        "searchNewWindowResolvesThroughRealChromeAPI")
      let windows = application.windows.values.filter { !beforeNewWindow.contains($0.windowContext.id) && $0.windowContext.isOpen }
      ownedNewWindows.formUnion(windows.map { $0.windowContext.id })
      guard windows.count == 1, let created = windows.first,
        let createdTab = created.store.state.tabs.first(where: { $0.windowID == created.windowContext.id && !$0.isClosed }),
        let createdPage = application.engine.pages[createdTab.id] else {
        throw ShortcutError("Search did not create exactly one real logical browser window.")
      }
      try await wait("actual new-window provider navigation") { createdPage.url?.absoluteString == duck.absoluteString }
      try require(application.repository.windows.first(where: { $0.id == created.windowContext.id })?.kind == .normal
        && createdTab.url == duck.absoluteString && createdPage.ownerWindowID == created.windowContext.id
        && createdPage.profileID == profile,
        "searchNewWindowRegistersCoreWindowAndActualProviderDocument")
      try require(Set(application.engine.auxiliaryBrowsers(profileID: profile, isPrivate: false).map(\.id)) == originalAuxiliaryIDs,
        "searchDispositionsDoNotCreateChromeOwnedAuxiliaryBrowsers")

      let beforeIsolation = Set(application.windows.keys)
      application.newWindow()
      let isolated = application.windows.values.filter { !beforeIsolation.contains($0.windowContext.id) && $0.windowContext.isOpen }
      guard isolated.count == 1, let foreign = isolated.first else { throw ShortcutError("No exact isolated search fixture owner.") }
      isolationOwner = foreign
      let foreignProfile = try foreign.store.createProfileDurably(name: "Search profile isolation fixture")
      guard foreignProfile.id != profile,
        let foreignTab = foreign.store.createTab(address: url.appendingPathComponent("search-foreign-profile").absoluteString) else {
        throw ShortcutError("The isolated search fixture profile did not materialize.")
      }
      let foreignPage = try await foreign.ensurePageReady(foreignTab)
      try await application.navigation.waitForRestore(foreignPage)
      await application.extensionBrowser.waitForTopologyPublication()
      guard let foreignNative = foreignPage.reservedNativeTabID else { throw ShortcutError("No foreign native tab ID.") }
      let foreignURL = foreign.store.tab(foreignTab.id)?.url
      try requireRejected(try await query(["text": "must stay isolated", "tabId": foreignNative]),
        "searchRejectsTabFromDifferentExactNativeProfile")
      try require(foreign.store.tab(foreignTab.id)?.url == foreignURL
        && foreignPage.ownerWindowID == foreign.windowContext.id,
        "searchRejectedCrossProfileTargetRemainsUnchanged")

      guard let fence = try CefAuxiliaryAdmissionLease.acquireProcess() else { throw ShortcutError("The custom search fixture admission ABI is absent.") }
      lease = fence
      let beforeFencedTabs = application.store.state.tabs
      let beforeFencedWindows = Set(application.windows.keys)
      for disposition in ["CURRENT_TAB", "NEW_TAB", "NEW_WINDOW"] {
        try requireRejected(try await query(["text": "fenced search", "disposition": disposition]),
          "searchAdmissionRejects" + disposition + "ThroughOriginalAPIError")
      }
      try require(application.store.state.tabs == beforeFencedTabs && Set(application.windows.keys) == beforeFencedWindows,
        "searchAdmissionRejectsBeforeLogicalOrNativeCreation")
      try fence.release(); lease = nil
      let resumedText = "resumed exact search " + UUID().uuidString
      let resumed = try BrowserAddress.searchURL(resumedText, engine: .duckduckgo).unwrap(or: ShortcutError("No resumed fixture URL."))
      try requireResolved(try await query(["text": resumedText, "tabId": nativeSource]),
        "searchReleasedAdmissionAcceptsOriginalNativeAPIAgain")
      try await wait("actual search after reversible admission release") {
        owner.store.tab(page.id)?.url == resumed.absoluteString && page.url?.absoluteString == resumed.absoluteString
      }
      try require(page.reservedNativeTabID == nativeSource,
        "searchReleasedAdmissionPreservesExactOriginalNativeTab")

      try await cleanup()
      return checks
    } catch {
      let failure = error
      let clean = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native search fixture cleanup retained an unresolved owned document: \(error.localizedDescription)\n", stderr) }
      }
      await clean.value
      throw failure
    }
  }
}

private extension Optional {
  func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
    guard let self else { throw error() }
    return self
  }
}
