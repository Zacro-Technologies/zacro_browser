import Foundation
import ZacroChromium
import ZacroCore

/// Real renderer commits and title callbacks in the disposable acceptance
/// profile. No synthetic visit or desktop input is used to satisfy a check.
@MainActor enum NativeHistoryRuntimeAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
      originalOwner owner: BrowserWindowCoordinator) async throws -> [String] {
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native history check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native history acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ predicate: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Native history acceptance timed out")
    }
    let token = UUID().uuidString
    let address = url.appendingPathComponent("native-visit-" + token)
    let previewAddress = url.appendingPathComponent("native-preview-visit-" + token)
    let failedAddress = URL(string: "http://127.0.0.1:1/native-failed-visit-" + token)!
    let prior = owner.store.state.activeTabID
    let profile = owner.store.activeProfileID
    var fixtureIDs = Set<String>()
    func visits(_ address: URL) -> [HistoryEntry] {
      application.store.state.history.filter { $0.profileID == profile && $0.url == address.absoluteString }
    }
    func cleanup() async {
      for id in fixtureIDs where owner.store.tab(id) != nil { _ = await owner.requestCloseTab(id) }
      if let prior, owner.store.tab(prior)?.isClosed == false { owner.store.selectTab(id: prior) }
      owner.scheduleLayout()
    }
    do {
      owner.actions.palette = false
      guard let tab = owner.store.createTab(address: address.absoluteString) else { throw ShortcutError("Could not create history fixture tab") }
      fixtureIDs.insert(tab.id)
      try require(visits(address).isEmpty, "requestedNewTabDoesNotFabricateHistoryVisit")
      let page = try await owner.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready()
      try await wait { !page.isLoading && page.url == address && visits(address).count == 1 }
      try require(visits(address).count == 1, "initialCommittedTabAppearsInLibraryHistory")
      try require(!page.canGoBack, "initialCommittedTabDoesNotExposeBootstrapBackEntry")
      guard let first = visits(address).first else { throw ShortcutError("Missing committed fixture visit") }
      _ = try await browser.devTools.evaluate("document.title = 'Native committed title'")
      try await wait { visits(address).first?.title == "Native committed title" }
      try require(visits(address).first?.id == first.id && visits(address).first?.visitedAt == first.visitedAt,
        "nativeTitleUpdatesExactVisitWithoutChangingTime")
      page.reload()
      try await wait { !page.isLoading && visits(address).first.map { $0.visitedAt > first.visitedAt } == true }
      try require(visits(address).count == 1 && visits(address).first?.id == first.id,
        "realReloadRefreshesRecentVisitWithoutDuplicate")
      let reloadVisit = visits(address).first
      _ = try await browser.devTools.evaluate("history.pushState({}, '', '#same-document')")
      try await wait { page.url?.fragment == "same-document" }
      try require(visits(address).first == reloadVisit
        && !application.store.state.history.contains { $0.profileID == profile && $0.url == address.absoluteString + "#same-document" },
        "sameDocumentNavigationDoesNotCreateLibraryVisit")

      owner.navigate(failedAddress.absoluteString)
      try await wait { page.documentError != nil }
      try require(visits(failedAddress).isEmpty, "failedRequestedNavigationDoesNotEnterHistory")
      owner.navigate(address.absoluteString)
      try await wait { !page.isLoading && page.url == address && page.documentError == nil }

      owner.store.setPeek(tabID: tab.id, address: previewAddress.absoluteString, title: "Preview")
      guard let previewTab = owner.store.document(id: "peek:" + tab.id) else { throw ShortcutError("No history fixture Peek") }
      let preview = try await owner.ensurePageReady(previewTab)
      try await application.navigation.waitForRestore(preview)
      let previewBrowser = try await preview.ready()
      try await wait { !preview.isLoading && preview.url == previewAddress }
      try require(visits(previewAddress).isEmpty, "transientPeekCommitDoesNotEnterHistory")
      let promoted = try await owner.promotePeekDocument(sourceID: tab.id, activate: true, authorize: {})
      fixtureIDs.insert(promoted.id)
      try require(application.engine.pages[promoted.id] === preview && visits(previewAddress).count == 1,
        "peekPromotionRecordsOneVisitAndKeepsNativePage")
      let promotedVisit = visits(previewAddress).first
      _ = try await previewBrowser.devTools.evaluate("document.title = 'Promoted retained document'")
      try await wait { visits(previewAddress).first?.title == "Promoted retained document" }
      try require(visits(previewAddress).count == 1 && visits(previewAddress).first?.id == promotedVisit?.id
        && visits(previewAddress).first?.visitedAt == promotedVisit?.visitedAt,
        "promotedPageTitleRemainsBoundToItsSingleVisit")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }
}
