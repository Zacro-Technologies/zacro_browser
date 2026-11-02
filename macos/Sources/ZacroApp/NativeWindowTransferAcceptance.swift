import AppKit
import ZacroChromium
import ZacroCore

/// Exercises the actual transfer authority with retained closed coordinators
/// present. Uses disposable loopback documents, never desktop input.
@MainActor enum NativeWindowTransferAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Window transfer requires the disposable loopback fixture.")
    }
    let engine = application.engine
    var created: [BrowserWindowCoordinator] = []
    var checks: [String] = []
    @MainActor func require(_ value: Bool, _ name: String) throws {
      fputs("Native window transfer check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Window transfer acceptance failed: " + name) }
      checks.append(name)
    }
    @MainActor func makeWindow() throws -> BrowserWindowCoordinator {
      let previous = Set(application.windows.keys)
      application.newWindow()
      let added = application.windows.values.filter {
        !previous.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
      }
      guard added.count == 1, let owner = added.first else {
        throw ShortcutError("No exact new transfer fixture owner")
      }
      created.append(owner)
      owner.actions.palette = false
      return owner
    }
    @MainActor func loaded(_ page: ChromiumPage, address: String) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        guard engine.pages[page.id] === page else { throw CancellationError() }
        if page.url?.absoluteString == address, !page.isLoading, let browser = page.browser,
          try await browser.devTools.evaluate("document.readyState === 'complete' && !!document.body") as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("The transfer fixture document did not finish loading")
    }
    @MainActor func cleanup() async {
      for owner in created.reversed() where owner.windowContext.isOpen { _ = await owner.requestCloseWindow() }
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
    }
    do {
      originalOwner.windowContext.show()
      application.repository.focusWindow(originalOwner.windowContext.id)
      let parked = try makeWindow()
      try require(await parked.requestCloseWindow()
        && application.windows[parked.windowContext.id] === parked && !parked.windowContext.isOpen,
        "windowTransferRetainsClosedCoordinatorWithoutSelectingIt")
      originalOwner.windowContext.show()
      application.repository.focusWindow(originalOwner.windowContext.id)
      let source = try makeWindow()
      guard let left = source.store.createTab(address: url.appendingPathComponent("window-transfer-left").absoluteString),
        let right = source.store.createTab(address: url.appendingPathComponent("window-transfer-right").absoluteString) else {
        throw ShortcutError("Window transfer fixture tabs could not be created")
      }
      let leftPage = try await source.ensurePageReady(left)
      let rightPage = try await source.ensurePageReady(right)
      try await application.navigation.waitForRestore(leftPage)
      try await application.navigation.waitForRestore(rightPage)
      try await loaded(leftPage, address: left.url)
      try await loaded(rightPage, address: right.url)
      let leftBrowser = try await leftPage.ready(), rightBrowser = try await rightPage.ready()
      let leftNativeID = leftBrowser.id, rightNativeID = rightBrowser.id
      _ = try await leftBrowser.devTools.evaluate("document.body.innerHTML='<textarea id=transferDraft></textarea>'; document.querySelector('#transferDraft').value='left unsaved draft'; null")
      _ = try await rightBrowser.devTools.evaluate("document.body.innerHTML='<textarea id=transferDraft></textarea>'; document.querySelector('#transferDraft').value='right unsaved draft'; null")
      source.store.setSplit(left: left.id, right: right.id)
      source.store.selectTab(id: left.id)
      source.layoutPages()
      guard let split = source.store.split(for: left.id) else { throw ShortcutError("Window transfer split is missing") }
      let destination = try makeWindow()
      try require(destination !== parked && destination.windowContext.isOpen
        && source.windowContext.isOpen, "windowTransferBindsExactNewOpenDestination")

      var rejectedClosedOwner = false
      do { try await application.moveTabs([left.id], toWindowID: parked.windowContext.id, index: 0, authorize: {}) }
      catch is CancellationError { rejectedClosedOwner = true }
      try require(rejectedClosedOwner && application.store.tab(left.id)?.windowID == source.windowContext.id
        && application.store.tab(right.id)?.windowID == source.windowContext.id
        && engine.pages[left.id] === leftPage && engine.pages[right.id] === rightPage,
        "windowTransferRejectsClosedOwnerWithoutChangingModelOrDocuments")

      try await application.moveTabs([left.id], toWindowID: destination.windowContext.id, index: 0, authorize: {
        // Focus may change during authorization; exact ownership may not.
        originalOwner.windowContext.show()
        await Task.yield()
      })
      destination.store.selectTab(id: left.id)
      destination.layoutPages()
      try require(destination.store.split(for: left.id)?.id == split.id
        && destination.store.split(for: right.id)?.id == split.id,
        "windowTransferMovesPersistentSplitAsOneUnit")
      let leftDraft = try await leftBrowser.devTools.evaluate("document.querySelector('#transferDraft').value") as? String
      let rightDraft = try await rightBrowser.devTools.evaluate("document.querySelector('#transferDraft').value") as? String
      try require(engine.pages[left.id] === leftPage && engine.pages[right.id] === rightPage
        && leftPage.browser === leftBrowser && rightPage.browser === rightBrowser
        && leftBrowser.id == leftNativeID && rightBrowser.id == rightNativeID
        && leftDraft == "left unsaved draft" && rightDraft == "right unsaved draft",
        "windowTransferPreservesBothNativeDocumentsAndUnsavedDrafts")
      try require(leftPage.ownerWindowID == destination.windowContext.id
        && rightPage.ownerWindowID == destination.windowContext.id
        && source.store.tab(left.id) == nil && source.store.tab(right.id) == nil
        && application.store.tab(left.id)?.windowID == destination.windowContext.id
        && application.store.tab(right.id)?.windowID == destination.windowContext.id,
        "windowTransferHasExactlyOneAuthoritativeOwnerAfterFocusChange")

      let closingDestination = try makeWindow()
      var rejectedChangedOwner = false
      do {
        try await application.moveTabs([left.id], toWindowID: closingDestination.windowContext.id, index: 0, authorize: {
          guard await closingDestination.requestCloseWindow() else { throw ShortcutError("Transfer destination did not close") }
        })
      } catch is CancellationError { rejectedChangedOwner = true }
      try require(rejectedChangedOwner && !closingDestination.windowContext.isOpen
        && application.store.tab(left.id)?.windowID == destination.windowContext.id
        && application.store.tab(right.id)?.windowID == destination.windowContext.id
        && leftPage.ownerWindowID == destination.windowContext.id
        && rightPage.ownerWindowID == destination.windowContext.id,
        "windowTransferRevalidatesDestinationAfterAuthorization")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }
}
