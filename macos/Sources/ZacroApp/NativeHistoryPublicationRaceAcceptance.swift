import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Real native Peek preparation crosses an actual application History clear.
/// Only the authorization continuation is held; native replies and Core writes
/// use the production path, and a later promotion needs a fresh actual visit.
@MainActor enum NativeHistoryPublicationRaceAcceptance {
  @MainActor private final class AuthorizationGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      entered = true
      guard !released else { return }
      await withCheckedContinuation { continuation = $0 }
    }
    func release() {
      guard !released else { return }; released = true
      let pending = continuation; continuation = nil; pending?.resume()
    }
  }

  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, application.supportsHistoryMirror,
      application.deletingProfileID == nil, application.pendingDeletion == nil,
      originalOwner.windowContext.isOpen, !originalOwner.windowContext.isClosing,
      originalOwner.store.state.activeProfile?.isPrivate == false,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil else {
      throw ShortcutError("History publication-race acceptance requires the disposable custom-runtime public loopback owner.")
    }
    let engine = application.engine, priorWindows = Set(application.windows.keys)
    let survivors = engine.pages.values.filter {
      $0.ownerWindowID == originalOwner.windowContext.id && !$0.isPrivate && $0.browser?.isClosed == false
    }.map { (page: $0, browser: $0.browser!, url: $0.url) }
    guard !survivors.isEmpty else { throw ShortcutError("Keep an actual original document for history publication isolation.") }
    let gate = AuthorizationGate()
    var owner: BrowserWindowCoordinator?
    var profileID: String?
    var nativeSession: ChromeHistoryMirrorSession?
    var preview: ChromiumPage?
    var previewBrowser: CefBrowser?
    var promotion: Task<BrowserTab, Error>?
    var promotionFinished = false
    var cleaned = false
    var checks: [String] = []

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native history publication race \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("History publication-race acceptance failed: " + name) }
      checks.append(name)
    }
    func cleanup() async throws {
      guard !cleaned else { return }; cleaned = true
      gate.release(); promotion?.cancel(); _ = try? await promotion?.value; promotion = nil
      await nativeSession?.close(); nativeSession = nil
      if let preview, let previewBrowser, preview.browser === previewBrowser, !previewBrowser.isClosed,
        preview.url?.host == "127.0.0.1", preview.url?.port == url.port {
        _ = try? await previewBrowser.devTools.evaluate("window.onbeforeunload=null;true")
      }
      var failure: Error?
      if let profileID, let owner, application.store.state.profiles.contains(where: { $0.id == profileID }),
        application.deletingProfileID == nil {
        owner.actions.deleteProfile(profileID)
        do { try await wait("owned publication fixture profile cleanup", timeout: 30) {
          application.deletingProfileID == nil
            && !application.store.state.profiles.contains { $0.id == profileID }
            && !application.store.pendingNativeProfileRetirements.contains(profileID)
            && !engine.pages.values.contains { $0.profileID == profileID }
        } } catch { failure = error }
      }
      if let owner, owner.windowContext.isOpen, !(await owner.requestCloseWindow()) {
        failure = failure ?? ShortcutError("The owned publication fixture window did not accept normal cleanup.")
      }
      if originalOwner.windowContext.isOpen {
        originalOwner.windowContext.show()
        application.repository.focusWindow(originalOwner.windowContext.id)
        application.extensionBrowser.windowFocusChanged()
      }
      if let failure { throw failure }
    }

    do {
      originalOwner.windowContext.show(); application.repository.focusWindow(originalOwner.windowContext.id)
      application.newWindow()
      let added = application.windows.values.filter {
        !priorWindows.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
      }
      guard added.count == 1, let fixture = added.first else { throw ShortcutError("No exact new publication fixture window.") }
      owner = fixture; fixture.actions.palette = false
      let profile = try fixture.store.createProfileDurably(name: "History publication clear fixture")
      profileID = profile.id
      guard !profile.isPrivate, fixture.store.activeProfileID == profile.id,
        profile.id != originalOwner.store.activeProfileID, let clear = fixture.actions.performLibraryAction else {
        throw ShortcutError("The publication fixture has no isolated public profile or real History clear action.")
      }
      let suffix = UUID().uuidString
      let sourceURL = url.appendingPathComponent("history-publication-source-" + suffix)
      var oldForm = URLComponents(url: url.appendingPathComponent("native-history-form"), resolvingAgainstBaseURL: false)!
      oldForm.queryItems = [URLQueryItem(name: "publication-old", value: suffix)]
      var freshForm = oldForm
      freshForm.queryItems = [URLQueryItem(name: "publication-fresh", value: suffix)]
      guard let oldURL = oldForm.url, let freshURL = freshForm.url,
        let sourceTab = fixture.store.createTab(address: sourceURL.absoluteString) else {
        throw ShortcutError("No owned publication fixture source and form URLs.")
      }
      let source = try await fixture.ensurePageReady(sourceTab)
      try await application.navigation.waitForRestore(source)
      try await wait("actual publication source") { !source.isLoading && source.url == sourceURL && source.documentError == nil }
      try await application.extensionSync.ensureNativeObservation(profileID: profile.id)
      try await application.historyMirror.refresh(profileID: profile.id)
      _ = try await fixture.requestOpenPeek(sourceTabID: sourceTab.id, sourcePage: source, url: oldURL)
      guard let peekDocument = fixture.store.document(id: "peek:" + sourceTab.id) else { throw ShortcutError("No actual saved publication Peek.") }
      let retained = try await fixture.ensurePageReady(peekDocument); preview = retained
      try await application.navigation.waitForRestore(retained)
      let native = try await retained.ready(); previewBrowser = native
      try await wait("actual old preview form") {
        guard !retained.isLoading, retained.url == oldURL, retained.documentError == nil else { return false }
        return try await native.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      let draft = "retained across actual history clear " + suffix
      _ = try await native.devTools.evaluate("document.getElementById('retained').value=\(try literal(draft));true")
      let session = try await retained.historyMirrorSession(); nativeSession = session
      let before = try await session.document(retained)
      guard before.preview, let oldEventID = before.currentEventID else { throw ShortcutError("The real preview has no native history event.") }
      let tabIDs = Set(application.store.state.tabs.filter { application.store.profileID(for: $0) == profile.id }.map(\.id))
      promotion = Task { @MainActor in
        defer { promotionFinished = true }
        return try await fixture.promotePeekDocument(sourceID: sourceTab.id, activate: true, authorize: { await gate.wait() })
      }
      try await wait("authorization reached after actual native preparation") {
        if gate.entered { return true }
        if promotionFinished, let promotion { _ = try await promotion.value }
        return false
      }
      let prepared = try await session.publications().filter {
        $0.documentToken == before.documentToken && $0.capturedEventID == oldEventID && $0.disposition == .prepared
      }
      let captured = try await event(oldEventID, documentToken: before.documentToken, session: session)
      guard prepared.count == 1, captured?.presence == .present, let oldIdentity = captured?.identity else {
        throw ShortcutError("The authorization gate did not hold an exact real prepared native visit.")
      }
      try require(!promotionFinished && retained.id == "peek:" + sourceTab.id
        && application.store.nativeHistoryPublicationReceipts(profileID: profile.id).isEmpty,
        "historyPublicationGateHoldsAfterRealNativePrepareBeforeCoreCommit")

      try await clear("history:clear", ["profileId": profile.id])
      guard !application.clearingHistoryProfiles.contains(profile.id), let clearedSource = fixture.store.tab(sourceTab.id),
        let clearedPeek = clearedSource.peek else { throw ShortcutError("Actual History clear lost the retained Peek or did not finish.") }
      let afterClearBack = retained.canGoBack, afterClearForward = retained.canGoForward
      let clearedDraft = try await native.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(gate.entered && !promotionFinished && clearedDraft == draft
        && engine.pages["peek:" + sourceTab.id] === retained && retained.browser === native && !native.isClosed
        && clearedPeek.url == oldURL.absoluteString
        && clearedPeek.navigation == [NavigationEntry(url: clearedPeek.url, title: clearedPeek.title, nativeNavigation: clearedPeek.nativeNavigation)]
        && clearedPeek.navigationIndex == 0 && !afterClearBack && !afterClearForward
        && !application.store.state.history.contains { $0.profileID == profile.id },
        "historyActualClearCompletesWhileAuthorizationHeldAndRetainsPeekDocumentWithClearedStack")
      gate.release()
      var cancelled = false
      do { _ = try await promotion!.value } catch is CancellationError { cancelled = true }
      promotion = nil
      try require(cancelled, "historyPreparedPromotionFromBeforeCompletedClearRejectsWithCancellation")
      let afterCancel = fixture.store.tab(sourceTab.id)
      try require(afterCancel?.peek == clearedPeek && afterCancel?.navigation == clearedSource.navigation
        && afterCancel?.navigationIndex == clearedSource.navigationIndex
        && engine.pages["peek:" + sourceTab.id] === retained && retained.browser === native
        && retained.url == oldURL && retained.canGoBack == afterClearBack && retained.canGoForward == afterClearForward
        && Set(application.store.state.tabs.filter { application.store.profileID(for: $0) == profile.id }.map(\.id)) == tabIDs
        && !application.store.state.history.contains { $0.profileID == profile.id }
        && application.store.nativeHistoryPublicationReceipts(profileID: profile.id).isEmpty,
        "historyStalePromotionCannotAddTabReviveHistoryOrMutateRetainedPeekAndStacks")
      try await wait("cancelled publication settles natively") { try await session.publications().isEmpty }
      let oldEvent = try await event(oldEventID, documentToken: before.documentToken, session: session)
      try require(oldEvent?.presence == .absent && oldEvent?.identity == nil,
        "historyClearedCapturedVisitRemainsAnActualNativeTombstone")

      // A fresh epoch does not resurrect the old VisitID. Obtain a genuine new
      // renderer commit before asking the same retained Peek to promote again.
      fixture.navigate(freshURL.absoluteString)
      try await wait("real post-clear preview navigation") {
        !retained.isLoading && retained.url == freshURL && retained.documentError == nil
          && fixture.store.document(id: "peek:" + sourceTab.id)?.url == freshURL.absoluteString
          && !fixture.hasPendingLiveNavigation("peek:" + sourceTab.id)
      }
      let freshDocument = try await session.document(retained)
      guard let freshEventID = freshDocument.currentEventID,
        let freshEvent = try await event(freshEventID, documentToken: before.documentToken, session: session),
        freshEvent.presence == .present, let freshIdentity = freshEvent.identity else {
        throw ShortcutError("No exact actual native visit for the post-clear commit.")
      }
      try require(freshDocument.documentToken == before.documentToken && freshDocument.preview
        && freshEventID != oldEventID && freshIdentity.generation != oldIdentity.generation
        && freshIdentity.url == freshURL.absoluteString && !freshEvent.publish
        && !application.store.state.history.contains { $0.profileID == profile.id },
        "historyFreshPreparationUsesNewActualPostClearNativeVisitWithoutRevivingOldVisit")
      let promoted = try await fixture.promotePeekDocument(sourceID: sourceTab.id, activate: true, authorize: {})
      try await wait("fresh publication registers the retained native owner") {
        let current = try await session.document(retained)
        return current.logicalID == promoted.id && !current.preview && !current.provisional
          && current.currentEventID == freshEventID
      }
      let rows = application.store.state.history.filter { $0.profileID == profile.id }
      let binding = application.store.nativeHistoryBindings(profileID: profile.id).first { $0.eventID == freshEventID }
      try require(engine.pages[promoted.id] === retained && retained.browser === native && !native.isClosed
        && engine.pages["peek:" + sourceTab.id] == nil && fixture.store.tab(sourceTab.id)?.peek == nil
        && rows.count == 1 && rows.first?.url == freshURL.absoluteString
        && binding?.coreID == rows.first?.id && binding?.identity == NativeHistoryMirrorDrain.coreIdentity(freshIdentity),
        "historyFreshPostClearPromotionCommitsExactNativeCoreIdentityAndRetainsBrowser")
      try await cleanup()
      try require(originalOwner.windowContext.isOpen
        && survivors.allSatisfy { engine.pages[$0.page.id] === $0.page && $0.page.browser === $0.browser
          && !$0.browser.isClosed && $0.page.url == $0.url },
        "historyPublicationRaceAndCleanupPreserveOriginalWindowNativeDocuments")
      return checks
    } catch {
      let failure = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("History publication-race cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw failure
    }
  }

  private static func event(_ eventID: String, documentToken: String,
    session: ChromeHistoryMirrorSession) async throws -> ChromeHistoryEvent? {
    var sequence = "0", count = 0
    repeat {
      let page = try await session.eventPage(after: sequence)
      count += page.events.count
      guard count <= 20_000 else { throw NativeHistoryReconciliationError.incompleteSnapshot }
      if let found = page.events.first(where: { $0.eventID == eventID && $0.documentToken == documentToken }) { return found }
      if page.complete { return nil }; sequence = page.nextSequence
    } while true
  }
  private static func literal(_ text: String) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
  }
  private static func wait(_ phase: String, timeout: TimeInterval = 20,
    _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try Task.checkCancellation()
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ShortcutError("History publication-race acceptance timed out: " + phase)
  }
}
