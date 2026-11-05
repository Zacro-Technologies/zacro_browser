import Foundation
import ZacroCore
import ZacroChromium

/// Real model/presentation snapshots with one narrowly injected query failure;
/// every successful state still comes from the actual Chromium manager.
@MainActor
enum NativeExtensionActionRecoveryAcceptance {
  @MainActor private final class Probe {
    var failures = 0
    var attempts = 0
    var realQueries = 0
    var unexpectedInvocations = 0
  }
  private struct InjectedFailure: LocalizedError {
    var errorDescription: String? { "Disposable action-state query failure" }
  }

  static func run(application: ApplicationCoordinator, owner: BrowserWindowCoordinator,
    page: ChromiumPage, manager: ChromeExtensionManager, identifier: String,
    worker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      page.url?.scheme == "http", page.url?.host == "127.0.0.1", page.url?.port != nil,
      !page.isPrivate, application.extensionBrowser.enabled,
      application.engine.pages[page.id] === page, page.ownerWindowID == owner.windowContext.id,
      owner.store.activeProfileID == page.profileID, owner.selectedDocumentID == page.id,
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      worker.extensionID == identifier, let nativeTabID = page.reservedNativeTabID else {
      throw ShortcutError("Action-state recovery requires its exact owned native extension fixture.")
    }
    let originalPage = page, originalAddress = page.url, profile = page.profileID
    guard let installed = try await manager.snapshot().extensions.first(where: { $0.id == identifier }),
      installed.isEnabled else { throw ShortcutError("The owned recovery extension is unavailable.") }
    let originalPinned = installed.isPinned
    let presentation = BrowserActions(), probe = Probe()
    let model = NativeExtensionsModel(store: owner.store, engine: application.engine, actions: presentation,
      actionQuery: { nativeManager, id, target in
        if id == identifier {
          probe.attempts += 1
          if probe.failures > 0 { probe.failures -= 1; throw InjectedFailure() }
          probe.realQueries += 1
        }
        return try await nativeManager.action(id, on: target)
      })
    model.invokeAction = { _, _, _ in probe.unexpectedInvocations += 1; throw InjectedFailure() }
    var disabledByFixture = false, changedPin = false, checks = [String]()
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension action recovery \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Action-state recovery failed: " + name) }
      checks.append(name)
    }
    func item() -> SiteExtensionItem? { presentation.siteControls.extensions.first { $0.id == identifier } }
    func wait(_ label: String, _ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing,
          owner.store.activeProfileID == profile, owner.selectedDocumentID == originalPage.id,
          application.engine.pages[originalPage.id] === originalPage, originalPage.url == originalAddress else {
          throw ShortcutError("The recovery fixture's original page/profile/owner changed.")
        }
        if condition() { return }
        try await Task.sleep(for: .milliseconds(15))
      }
      throw ShortcutError("Action-state recovery timed out: " + label)
    }
    func cleanup() async throws {
      model.close()
      var firstFailure: Error?
      if disabledByFixture {
        do {
          _ = try await worker.evaluate("(async()=>{await chrome.action.enable(\(nativeTabID));return true})()")
          disabledByFixture = false
        } catch { firstFailure = error }
      }
      if changedPin {
        do { try await manager.setPinned(identifier, pinned: originalPinned); changedPin = false }
        catch { firstFailure = firstFailure ?? error }
      }
      if let firstFailure { throw firstFailure }
    }
    do {
      if !originalPinned { try await manager.setPinned(identifier, pinned: true); changedPin = true }
      probe.failures = 1
      model.profileChanged(); model.activePageChanged(page)
      try await wait("First cold query failure is visible before the bounded native retry") {
        model.actionErrors[identifier] != nil && model.actionLoading.contains(identifier)
      }
      try require(item()?.pinned == true && item()?.actionError != nil && item()?.actionLoading == true
        && item()?.actionEnabled == false,
        "coldActionQueryFailureIsVisibleWithoutHidingTheNativePinnedPreference")
      try await wait("Actual Chromium action warms its real installation capability") {
        item()?.pinned == true && item()?.actionEnabled == true && !model.actionLoading.contains(identifier)
      }
      try require(probe.attempts == 2 && probe.realQueries == 1,
        "coldActionQueryRetryReadsActualChromiumStateOnTheOriginalPage")
      let attemptsBeforeFailure = probe.attempts, queriesBeforeFailure = probe.realQueries
      probe.failures = 1
      model.retryActionState(id: identifier)
      try await wait("First query failure is visible while its bounded retry is pending") {
        model.actionErrors[identifier] != nil && model.actionLoading.contains(identifier)
      }
      try require(item()?.pinned == true && item()?.actionError != nil && item()?.actionLoading == true
        && item()?.actionEnabled == false && item()?.canRetryAction == false,
        "actionQueryFailureRetainsKnownPinnedTileAndPublishesRealErrorAndLoading")
      try await wait("Same-page automatic retry recovers from the real manager") {
        item()?.actionEnabled == true && item()?.actionError == nil && !model.actionLoading.contains(identifier)
      }
      try require(probe.attempts - attemptsBeforeFailure == 2 && probe.realQueries - queriesBeforeFailure == 1
        && owner.selectedDocumentID == originalPage.id && originalPage.url == originalAddress,
        "actionStateRecoversOnSamePageAndAddressAfterOneFailureWithoutNavigation")

      probe.failures = 10
      let attemptsBeforeExhaustion = probe.attempts
      model.retryActionState(id: identifier)
      try await wait("Three failed queries stop and expose explicit retry") {
        !model.actionLoading.contains(identifier) && item()?.actionError != nil && item()?.canRetryAction == true
      }
      let exhaustedAttempts = probe.attempts
      try await Task.sleep(for: .milliseconds(900))
      try require(exhaustedAttempts - attemptsBeforeExhaustion == 3 && probe.attempts == exhaustedAttempts
        && item()?.pinned == true && item()?.actionEnabled == false,
        "actionStateRetriesAreBoundedAndTerminalFailureKeepsVisibleRetryOnlyTile")
      probe.failures = 0
      guard let retryTile = item() else { throw ShortcutError("The visible retry tile disappeared.") }
      retryTile.perform()
      try await wait("The visible model tile retries state through Chromium") {
        item()?.actionEnabled == true && item()?.actionError == nil && !model.actionLoading.contains(identifier)
      }
      try require(probe.attempts == exhaustedAttempts + 1 && probe.unexpectedInvocations == 0,
        "actionErrorTileRetriesNativeStateWithoutInventingOrInvokingAnAction")

      _ = try await worker.evaluate("(async()=>{await chrome.action.disable(\(nativeTabID));return true})()")
      disabledByFixture = true
      model.retryActionState(id: identifier)
      try await wait("Actual Chromium-disabled action is published") {
        !model.actionLoading.contains(identifier) && item()?.actionError == nil && item()?.actionEnabled == false
      }
      let disabledState = try await manager.action(identifier, on: page)
      try require(disabledState.hasAction && !disabledState.enabled && item()?.pinned == true
        && item()?.canRetryAction == false && probe.unexpectedInvocations == 0,
        "actionStateRecoveryRetainsChromiumDisabledPolicyWithoutEnablingTheAction")
      try await cleanup()
      return checks
    } catch {
      try? await cleanup()
      throw error
    }
  }
}
