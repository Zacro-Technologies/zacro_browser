import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Exercise the same model action used by the native extension buttons. Each
/// target owns a real two-entry controller; only its loopback network request
/// is failed or paused. The extension popup/panel remain ordinary Chrome UI.
@MainActor enum NativeExtensionActionReadinessAcceptance {
  private final class Target {
    let id: String
    let entries: [URL]
    let paused: Bool
    let token: String
    var browser: CefBrowser?
    var installed = false
    var nativeID: Int?
    var released = false
    init(id: String, entries: [URL], paused: Bool, token: String) {
      self.id = id; self.entries = entries; self.paused = paused; self.token = token
    }
  }
  private final class Gate { var entered = false; var released = false }

  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    manager: ChromeExtensionManager, identifier: String,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil, !page.isPrivate,
      application.extensionBrowser.enabled, application.engine.pages[page.id] === page,
      page.ownerWindowID == owner.windowContext.id,
      owner.store.activeProfileID == page.profileID,
      owner.windowContext.isOpen, !owner.windowContext.isClosing else {
      throw ShortcutError("Extension action readiness requires the owned disposable public loopback fixture.")
    }
    let sourceBrowser = try await page.ready(), sourceNativeID = page.reservedNativeTabID
    guard try await sourceBrowser.nativeCapabilities().historyInstallation == true else {
      throw ShortcutError("Extension actions require actual native history-installation receipts.")
    }
    let originalSelection = owner.store.state.activeTabID
    let originalSpace = owner.store.state.activeSpaceID
    let originalTabs = Set(application.store.state.tabs.map(\.id))
    let originalWindows = Set(application.windows.keys)
    let originalAuxiliary = Set(application.engine.auxiliaryBrowsers(profileID: page.profileID, isPrivate: false).map(\.id))
    let token = UUID().uuidString.lowercased()
    var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    origin.path = "/"; origin.query = nil; origin.fragment = nil
    guard let originURL = origin.url else { throw ShortcutError("The owned readiness fixture has no loopback origin.") }
    let fixtureRoot = originURL.appendingPathComponent("native-extension-action")
    let networkConfiguration = URLSessionConfiguration.ephemeral
    networkConfiguration.httpCookieStorage = nil; networkConfiguration.urlCache = nil
    networkConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    networkConfiguration.timeoutIntervalForRequest = 15; networkConfiguration.timeoutIntervalForResource = 15
    let network = URLSession(configuration: networkConfiguration)
    var targets = [Target](), checks = [String]()
    var temporaryOwner: BrowserWindowCoordinator?
    var foreignProfile: String?
    var cancellationTask: Task<ChromiumPage, Error>?
    let cancellationGate = Gate()
    defer {
      cancellationGate.released = true; cancellationTask?.cancel()
      network.invalidateAndCancel()
    }

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension action readiness check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Extension action readiness failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ predicate: () async throws -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
      }
      throw ShortcutError("Extension action readiness timed out: " + phase)
    }
    func history(_ target: Target) async throws -> ([String], Int) {
      guard let browser = target.browser else { throw ShortcutError("The owned action controller disappeared.") }
      let value = try await browser.devTools.call("Page.getNavigationHistory")
      guard let entries = value["entries"] as? [[String: Any]], let index = value["currentIndex"] as? Int,
        entries.indices.contains(index) else { throw ShortcutError("The owned action controller returned no real history.") }
      let addresses = entries.compactMap { $0["url"] as? String }
      guard addresses.count == entries.count else { throw ShortcutError("A real action history entry lost its URL.") }
      return (addresses, index)
    }
    func requireHistory(_ target: Target, page targetPage: ChromiumPage, name: String) async throws {
      let actual = try await history(target)
      try require(actual.0 == target.entries.map(\.absoluteString) && actual.1 == 1
        && application.engine.pages[target.id] === targetPage && targetPage.browser === target.browser
        && targetPage.profileID == page.profileID && !targetPage.isPrivate
        && targetPage.ownerWindowID == owner.windowContext.id
        && owner.store.tab(target.id)?.url == target.entries[1].absoluteString,
        name)
    }
    func requireIdentity(_ target: Target, page targetPage: ChromiumPage, name: String) throws {
      try require(target.installed && target.nativeID != nil
        && targetPage.reservedNativeTabID == target.nativeID
        && application.engine.pages[target.id] === targetPage && targetPage.browser === target.browser
        && targetPage.ownerWindowID == owner.windowContext.id && targetPage.profileID == page.profileID
        && !targetPage.isPrivate && owner.store.tab(target.id)?.url == target.entries[1].absoluteString,
        name)
    }
    func fixtureRequest(_ operation: String, target: Target, method: String = "GET") async throws -> [String: Any] {
      guard target.paused, ["state", "release"].contains(operation),
        targets.contains(where: { $0 === target }) else { throw ShortcutError("No exact owned readiness network gate.") }
      let endpoint = fixtureRoot.appendingPathComponent(operation).appendingPathComponent(target.token)
      var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
      request.httpMethod = method
      let (bytes, response) = try await network.data(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.url == endpoint, bytes.count <= 4096,
        let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw ShortcutError("The exact owned readiness server returned an invalid gate receipt.")
      }
      return result
    }
    func closePopup() async throws {
      _ = try await worker.evaluate("zacroAcceptance.closePopup()", timeout: 15)
      try await wait("the exact action popup closes") {
        !NSApp.windows.contains { application.engine.extensionPopupOwner($0) === owner.windowContext }
      }
    }
    func clickPublishedAction(on targetPage: ChromiumPage) async throws {
      var perform: (() -> Void)?
      try await wait("the exact selected document publishes its native extension action") {
        guard owner.store.activeProfileID == page.profileID, owner.activePage === targetPage,
          owner.selectedDocumentID == targetPage.id,
          let item = owner.actions.siteControls.extensions.first(where: { $0.id == identifier }),
          item.enabled, item.actionEnabled else { return false }
        perform = item.perform
        return true
      }
      guard let perform, owner.actions.siteControls.extensionError == nil else {
        throw ShortcutError("The published native extension action was unavailable: "
          + (owner.actions.siteControls.extensionError ?? "missing exact action"))
      }
      perform()
    }
    func releaseNetwork(_ target: Target) async throws {
      guard target.paused, !target.released else { return }
      guard try await fixtureRequest("release", target: target, method: "POST")["released"] as? Bool == true else {
        throw ShortcutError("The exact owned readiness server did not release its held response.")
      }
      target.released = true
    }
    func cleanup() async throws {
      cancellationGate.released = true; cancellationTask?.cancel()
      _ = await cancellationTask?.result; cancellationTask = nil
      var failure: Error?
      do {
        if NSApp.windows.contains(where: { application.engine.extensionPopupOwner($0) === owner.windowContext }) {
          try await closePopup()
        }
        if targets.contains(where: { application.engine.pages[$0.id]?.isSidePanelVisible == true }) {
          _ = try await worker.evaluate("zacroAcceptance.closePanel(\(owner.windowContext.nativeID))", timeout: 15)
        }
        _ = try await worker.evaluate("zacroAcceptance.configureAction('record')", timeout: 15)
      } catch { failure = error }
      for target in targets {
        do { try await releaseNetwork(target) } catch { failure = failure ?? error }
        if owner.store.tab(target.id)?.isClosed == false, !(await owner.requestCloseTab(target.id)) {
          failure = failure ?? ShortcutError("An exact owned action fixture tab refused normal closure.")
        }
      }
      if let temporaryOwner, temporaryOwner.windowContext.isOpen,
        !(await temporaryOwner.requestCloseWindow()) {
        failure = failure ?? ShortcutError("The exact owned action cancellation window refused closure.")
      }
      owner.store.selectSpace(id: originalSpace)
      if let originalSelection, owner.store.tab(originalSelection)?.isClosed == false {
        owner.store.selectTab(id: originalSelection)
      }
      if let id = foreignProfile, owner.store.state.profiles.contains(where: { $0.id == id }) {
        do { try owner.store.deleteProfileDurably(id: id); foreignProfile = nil }
        catch { failure = failure ?? error }
      }
      owner.windowContext.show(); owner.scheduleLayout()
      if let failure { throw failure }
    }

    do {
      guard worker.extensionID == identifier,
        try await manager.snapshot().extensions.first(where: { $0.id == identifier })?.isEnabled == true else {
        throw ShortcutError("Action readiness requires the same enabled installed fixture extension.")
      }
      guard try await worker.evaluate("chrome.runtime.getContexts({contextTypes:['POPUP']}).then(contexts=>contexts.length)") as? Int == 0 else {
        throw ShortcutError("Action readiness cannot borrow an existing fixture popup.")
      }
      owner.actions.palette = false; owner.actions.library = nil; owner.windowContext.show()

      for phase in ["Failed", "Loading"] {
        let gateToken = UUID().uuidString.lowercased()
        let first = url.appendingPathComponent("native-action-" + phase.lowercased() + "-first-" + token)
        var failed = origin; failed.port = 1; failed.path = "/native-action-failed-selected-" + gateToken
        guard let failedURL = failed.url else { throw ShortcutError("No exact owned failed loopback destination.") }
        let selected = phase == "Loading" ? fixtureRoot.appendingPathComponent("hold").appendingPathComponent(gateToken) : failedURL
        let entries = [first, selected]
        guard let tab = owner.store.createTab(address: entries[1].absoluteString, activate: false) else {
          throw ShortcutError("The exact owned cold action tab could not be created.")
        }
        let target = Target(id: tab.id, entries: entries, paused: phase == "Loading", token: gateToken); targets.append(target)
        owner.store.updateTab(tab.id) {
          $0.navigation = entries.map { NavigationEntry(url: $0.absoluteString, title: "Owned action history") }
          $0.navigationIndex = 1
        }
        try require(application.engine.pages[tab.id] == nil,
          "extensionAction" + phase + "StartsWithColdSavedHistory")
        owner.store.selectTab(id: tab.id)
        let targetPage = try await owner.ensurePageReady(owner.store.tab(tab.id) ?? tab)
        target.browser = try await targetPage.ready()
        try await application.navigation.waitForNavigationInstallation(targetPage)
        target.installed = true; target.nativeID = targetPage.reservedNativeTabID
        try await wait(phase + " owned network condition") {
          if target.paused {
            let state = try await fixtureRequest("state", target: target)
            return state["seen"] as? Bool == true && state["released"] as? Bool == false && targetPage.isLoading
          }
          return !application.navigation.isRestoring(targetPage) && !targetPage.isLoading
            && targetPage.documentError?.url == entries[1]
        }
        if target.paused {
          try requireIdentity(target, page: targetPage,
            name: "extensionActionLoadingReceivesActualControllerInstallationBeforeHTTP")
        } else {
          try await requireHistory(target, page: targetPage,
            name: "extensionActionFailedInstallsBothRealNativeHistoryEntries")
        }
        _ = try await worker.evaluate("zacroAcceptance.configureAction('popup')", timeout: 15)
        try await clickPublishedAction(on: targetPage)
        guard let popup = try await worker.evaluate("zacroAcceptance.popupResult()", timeout: 15) as? [String: Any],
          let nativeID = targetPage.reservedNativeTabID else { throw ShortcutError("The original action popup returned no actual context.") }
        try require(popup["windowID"] as? Int == owner.windowContext.nativeID
          && popup["tabIDs"] as? [Int] == [nativeID]
          && owner.actions.siteControls.extensionError == nil
          && (target.paused ? !target.released && targetPage.isLoading : targetPage.documentError != nil),
          "extensionAction" + phase + "NativeButtonOpensActualPopupBeforeSuccessfulHTTP")
        if target.paused {
          try requireIdentity(target, page: targetPage,
            name: "extensionActionLoadingPopupPreservesInstalledControllerIdentityBeforeHTTP")
        } else {
          try await requireHistory(target, page: targetPage,
            name: "extensionActionFailedPopupPreservesControllerAndNativeIdentity")
        }
        try await closePopup()
        _ = try await worker.evaluate("zacroAcceptance.configureAction('panel')", timeout: 15)
        owner.windowContext.show()
        try await clickPublishedAction(on: targetPage)
        guard let panel = try await worker.evaluate("zacroAcceptance.panelState('action-readiness-\(phase)-\(token)')", timeout: 15) as? [String: Any] else {
          throw ShortcutError("The original action side panel returned no actual context.")
        }
        try await wait("the exact native action side panel is presented") { targetPage.isSidePanelVisible }
        try require(panel["windowID"] as? Int == owner.windowContext.nativeID
          && panel["draft"] as? String == "action-readiness-\(phase)-\(token)"
          && targetPage.isSidePanelVisible && owner.actions.siteControls.extensionError == nil,
          "extensionAction" + phase + "NativeButtonOpensActualSidePanelWithoutHTTP")
        _ = try await worker.evaluate("zacroAcceptance.closePanel(\(owner.windowContext.nativeID))", timeout: 15)
        try await wait("the exact action side panel closes") { !targetPage.isSidePanelVisible }
        if target.paused {
          try requireIdentity(target, page: targetPage,
            name: "extensionActionLoadingSidePanelPreservesInstalledControllerIdentityBeforeHTTP")
        } else {
          try await requireHistory(target, page: targetPage,
            name: "extensionActionFailedSidePanelPreservesControllerAndNativeIdentity")
        }
        try await releaseNetwork(target)
        if target.paused {
          try await application.navigation.waitForRestore(targetPage)
          try require(targetPage.documentError == nil && targetPage.url == entries[1],
            "extensionActionPausedHTTPResumesAndCommitsNormally")
          try await requireHistory(target, page: targetPage,
            name: "extensionActionLoadingPopupAndSidePanelPreserveBothActualNativeHistoryEntries")
        }
      }

      owner.store.selectTab(id: page.id); owner.windowContext.show()
      let beforeCancellation = Set(application.store.state.tabs.map(\.id))
      cancellationTask = Task { @MainActor in
        try await owner.extensionActionPage(profileID: page.profileID, authorize: {
          cancellationGate.entered = true
          while !cancellationGate.released {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
          }
        })
      }
      try await wait("the original action caller enters authorization") { cancellationGate.entered }
      cancellationTask?.cancel(); cancellationGate.released = true
      var callerCancelled = false
      do { _ = try await cancellationTask?.value } catch is CancellationError { callerCancelled = true }
      cancellationTask = nil
      try require(callerCancelled && Set(application.store.state.tabs.map(\.id)) == beforeCancellation,
        "extensionActionCancelledCallerCreatesNoReplacementDocument")

      var profileChanged = false
      do {
        _ = try await owner.extensionActionPage(profileID: page.profileID, authorize: {
          foreignProfile = try owner.store.createProfileDurably(name: "Disposable action scope " + token).id
        })
      } catch is CancellationError { profileChanged = true }
      // Restore/delete synchronously before a new profile can materialize a
      // guest document. This test owns the new empty profile and its Space.
      owner.store.selectSpace(id: originalSpace); owner.store.selectTab(id: page.id)
      if let id = foreignProfile {
        guard !application.engine.pages.values.contains(where: { $0.profileID == id }) else {
          throw ShortcutError("The cancelled action unexpectedly materialized its foreign profile.")
        }
        try owner.store.deleteProfileDurably(id: id)
        foreignProfile = nil
      }
      try require(profileChanged && Set(application.store.state.tabs.map(\.id)) == beforeCancellation,
        "extensionActionProfileChangeRejectsTheCapturedSource")

      let windowsBefore = Set(application.windows.keys)
      application.newWindow()
      let added = application.windows.values.filter { !windowsBefore.contains($0.windowContext.id) && $0.windowContext.isOpen }
      guard added.count == 1, let closedOwner = added.first else { throw ShortcutError("No exact action cancellation window.") }
      temporaryOwner = closedOwner
      closedOwner.actions.palette = false
      let defaults = closedOwner.store.state.tabs.filter { !$0.isClosed && $0.windowID == closedOwner.windowContext.id }
      guard defaults.allSatisfy({ !originalTabs.contains($0.id) && $0.url == "about:blank"
        && closedOwner.store.profileID(for: $0) == page.profileID }) else {
        throw ShortcutError("The new action cancellation window contained an unexpected source document.")
      }
      for tab in defaults {
        guard await closedOwner.requestCloseTab(tab.id) else {
          throw ShortcutError("The exact new default action tab refused normal closure.")
        }
      }
      try await wait("the new action cancellation owner is genuinely empty") {
        closedOwner.windowContext.isOpen && !closedOwner.windowContext.isClosing
          && !closedOwner.store.state.tabs.contains { !$0.isClosed && $0.windowID == closedOwner.windowContext.id }
          && !application.engine.pages.values.contains { $0.ownerWindowID == closedOwner.windowContext.id }
      }
      var windowClosed = false
      do {
        _ = try await closedOwner.extensionActionPage(profileID: page.profileID, authorize: {
          guard await closedOwner.requestCloseWindow() else { throw ShortcutError("The owned empty action window refused closure.") }
        })
      } catch is CancellationError { windowClosed = true }
      try require(windowClosed && !closedOwner.windowContext.isOpen
        && !application.engine.pages.values.contains { $0.ownerWindowID == closedOwner.windowContext.id },
        "extensionActionClosedWindowCannotCreateAnAboutBlankFallback")
      temporaryOwner = nil

      try await cleanup()
      try require(application.engine.pages[page.id] === page && page.browser === sourceBrowser
        && page.reservedNativeTabID == sourceNativeID && owner.store.state.activeTabID == originalSelection
        && application.windows.values.filter { $0.windowContext.isOpen }.allSatisfy { originalWindows.contains($0.windowContext.id) }
        && Set(application.engine.auxiliaryBrowsers(profileID: page.profileID, isPrivate: false).map(\.id)) == originalAuxiliary
        && application.store.state.tabs.filter { !originalTabs.contains($0.id) }.allSatisfy(\.isClosed),
        "extensionActionReadinessCleanupPreservesOriginalSourceAndNativeOwnership")
      return checks
    } catch {
      let original = error
      do { try await cleanup() } catch { fputs("Extension action readiness cleanup: \(error.localizedDescription)\n", stderr) }
      throw original
    }
  }
}
