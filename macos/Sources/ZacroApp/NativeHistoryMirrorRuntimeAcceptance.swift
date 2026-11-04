import Foundation
import ZacroChromium
import ZacroCore

/// Two-store proofs against the real profile HistoryService and permission-
/// checked extension API. The independent Core stores deliberately prevent the
/// application's ordinary drain from completing a simulated interrupted commit.
@MainActor enum NativeHistoryMirrorRuntimeAcceptance {
  private struct Visit: Decodable { let visitId: String; let visitTime: Double? }
  private struct DocumentState: Equatable {
    let page: ObjectIdentifier
    let browser: ObjectIdentifier?
    let address: String?
    let back: Bool
    let forward: Bool
  }
  private struct ActivityParking {
    let owner: BrowserWindowCoordinator
    let originalSpaceID: String
    let originalTabID: String?
    let emptySpaceID: String
  }
  private struct SameDocumentObservation: Codable, Equatable {
    let address: String?
    let fragment: String?
    let loading: Bool
    let back: Bool
    let forward: Bool
    let browserID: Int32?
    let documentToken: String?
    let logicalID: String?
    let eventID: String?
    let previousEvent: String
    let initialEvent: String
    let presence: String?
    let identity: ChromeHistoryIdentity?
  }

  static func run(application: ApplicationCoordinator, url: URL) async throws -> [String] {
    try validate(url)
    let profile = UUID().uuidString
    let root = application.engine.dataDirectory.appendingPathComponent("AcceptanceHistoryMirror-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    var originalTabs: [BrowserTab] = []
    var originalDocuments: [String: DocumentState] = [:]
    var activityParking: [ActivityParking] = []
    let base = url.appendingPathComponent("history-mirror-" + UUID().uuidString)
    let now = Date().addingTimeInterval(-3600)
    var addresses = Set<String>(), checks: [String] = []
    var ownedManagers: [ChromeExtensionManager] = []
    var ownedSessions: [ChromeHistoryMirrorSession] = []
    var pendingNative: [ChromeHistoryLegacyAcknowledgement] = []
    var stores: [BrowserStore] = []
    var importBoundaries: [String: String] = [:]
    var nativeBoundaries = Set<String>()
    var worker: ChromeExtensionWorkerSession?
    var session: ChromeHistoryMirrorSession?
    var cleaned = false

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native history mirror check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native history mirror acceptance failed: " + name) }
      checks.append(name)
    }
    func fixture(_ name: String, profileID: String = profile) -> BrowserStore {
      var state = BrowserState()
      state.profiles = [BrowserProfile(id: profileID, name: "Owned history mirror fixture")]
      state.spaces = [BrowserSpace(id: "history-fixture", profileID: profileID, name: "Fixture")]
      state.activeSpaceID = "history-fixture"
      let store = BrowserStore(directory: root.appendingPathComponent(name), initialState: state)
      stores.append(store)
      return store
    }
    func input(_ store: BrowserStore, _ suffix: String, at date: Date = now,
      title: String = "Owned legacy visit") throws -> NativeHistoryLegacyInput {
      let address = base.appendingPathComponent(suffix).absoluteString
      addresses.insert(address)
      guard let id = store.recordHistoryVisit(profileID: profile, address: address, title: title, visitedAt: date),
        store.lastError == nil,
        let value = store.nativeHistoryLegacyInputs(profileID: profile).first(where: { $0.coreID == id }) else {
        throw ShortcutError("Could not durably create the owned legacy Core visit.")
      }
      return value
    }
    func boundary(_ inputs: [NativeHistoryLegacyInput]) async throws {
      guard let session else { throw ShortcutError("No exact owned history mirror transport.") }
      let missing = inputs.filter { importBoundaries[$0.importID] == nil }
      guard !missing.isEmpty else { return }
      let lease = try await session.createLegacyBoundary(); nativeBoundaries.insert(lease)
      for store in stores {
        let current = Set(store.nativeHistoryLegacyInputs(profileID: profile).map(\.importID))
        let captured = missing.filter { current.contains($0.importID) }
        guard !captured.isEmpty else { continue }
        let receipts = try store.assignNativeHistoryLegacyBoundaryDurably(profileID: profile, inputs: captured, leaseID: lease)
        for receipt in receipts { importBoundaries[receipt.importID] = receipt.leaseID }
      }
      guard inputs.allSatisfy({ importBoundaries[$0.importID] != nil }) else {
        throw ShortcutError("The native import has no durably captured exact Core boundary.")
      }
    }
    func native(_ inputs: [NativeHistoryLegacyInput]) async throws -> [ChromeHistoryLegacyResult] {
      guard let session else { throw ShortcutError("No exact owned history mirror transport.") }
      try await boundary(inputs)
      let results = try await session.importLegacy(try inputs.map { try wire($0, boundaryLeaseID: importBoundaries[$0.importID]) })
      for value in results {
        let receipt = ChromeHistoryLegacyAcknowledgement(importID: value.importID, generation: value.generation)
        if !pendingNative.contains(receipt) { pendingNative.append(receipt) }
      }
      return results
    }
    func bind(_ store: BrowserStore, _ inputs: [NativeHistoryLegacyInput],
      _ results: [ChromeHistoryLegacyResult]) throws -> [NativeHistoryLegacyReceipt] {
      try store.applyNativeHistoryLegacyImportsDurably(profileID: profile, inputs: inputs, results: results.map(core))
    }
    func acknowledge(_ store: BrowserStore, _ receipts: [NativeHistoryLegacyReceipt]) async throws {
      guard let session else { throw ShortcutError("No exact owned history mirror transport.") }
      let wire = receipts.map { ChromeHistoryLegacyAcknowledgement(importID: $0.importID, generation: $0.generation) }
      try await session.acknowledgeLegacy(wire)
      try store.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts)
      pendingNative.removeAll { wire.contains($0) }
    }
    func visits(_ address: String) async throws -> [Visit] {
      guard let worker else { throw ShortcutError("No exact owned native history worker.") }
      return try await historyVisits(worker, address: address)
    }
    // Seed the old Core record before even constructing its native profile.
    // This profile is absent from the canonical app collection, so the global
    // drain cannot acknowledge this fixture's imports or replace its retention.
    let retentionStore = fixture("cold-retention")
    let retained = try input(retentionStore, "older-than-native-expiry", at: Date().addingTimeInterval(-120 * 86_400))
    guard !application.store.state.profiles.contains(where: { $0.id == profile }) else {
      throw ShortcutError("The disposable native history profile unexpectedly belongs to the application.")
    }
    let manager = ChromeExtensionManager(engine: application.engine, profileID: profile)
    ownedManagers.append(manager)
    func cleanup() async throws {
      guard !cleaned else { return }; cleaned = true
      var failure: Error?
      if let worker {
        for address in addresses {
          do { try await deleteURL(worker, address: address) } catch { failure = failure ?? error }
        }
        await worker.close()
      }
      if let session {
        for offset in stride(from: 0, to: pendingNative.count, by: 512) {
          do { try await session.acknowledgeLegacy(Array(pendingNative[offset..<min(offset + 512, pendingNative.count)])) }
          catch { failure = failure ?? error }
        }
        for lease in nativeBoundaries {
          do { try await session.finalizeLegacyBoundary(lease) } catch { failure = failure ?? error }
        }
        await session.close()
      }
      for owned in ownedSessions { await owned.close() }
      for owned in ownedManagers {
        // These UUID profiles were created solely by this fixture, with no
        // canonical browser collection or user document attached.
        do { try await owned.clearBrowsingHistory() } catch { failure = failure ?? error }
        await owned.close()
        for page in application.engine.pages.values where page.profileID == owned.profileID { page.close() }
        do {
          try await wait("owned history transport close") {
            !application.engine.pages.values.contains { $0.profileID == owned.profileID }
          }
          try application.engine.retireProfile(owned.profileID)
        } catch { failure = failure ?? error }
      }
      for parked in activityParking.reversed() {
        let owner = parked.owner
        guard application.windows[owner.windowContext.id] === owner,
          owner.windowContext.isOpen, !owner.windowContext.isClosing,
          owner.store.state.spaces.contains(where: { $0.id == parked.originalSpaceID }),
          parked.originalTabID.map({ owner.store.tab($0)?.isClosed == false }) ?? true else {
          failure = failure ?? ShortcutError("The original history fixture shell/selection cannot be restored.")
          continue
        }
        owner.store.selectSpace(id: parked.originalSpaceID)
        if let id = parked.originalTabID { owner.store.selectTab(id: id) }
        guard !owner.store.state.tabs.contains(where: { $0.spaceID == parked.emptySpaceID }),
          !owner.store.state.folders.contains(where: { $0.spaceID == parked.emptySpaceID }) else {
          failure = failure ?? ShortcutError("The owned empty history fixture Space acquired content and was preserved.")
          continue
        }
        owner.store.deleteSpace(id: parked.emptySpaceID)
        owner.layoutPages()
        guard owner.store.state.activeSpaceID == parked.originalSpaceID,
          owner.store.state.activeTabID == parked.originalTabID,
          !owner.store.state.spaces.contains(where: { $0.id == parked.emptySpaceID }) else {
          failure = failure ?? ShortcutError("The exact history fixture Space/selection did not restore.")
          continue
        }
      }
      if failure == nil { try? FileManager.default.removeItem(at: root) }
      if let failure { throw failure }
    }

    do {
      let owners = application.windows.values.filter { $0.windowContext.isOpen && !$0.windowContext.isClosing }
        .sorted { $0.windowContext.id < $1.windowContext.id }
      guard !owners.isEmpty, owners.count <= 64,
        application.store.state.spaces.count + owners.count <= 500 else {
        throw ShortcutError("The history fixture cannot safely park every existing shell within its Space bounds.")
      }
      if let popup = owners.first(where: { $0.isPopup }) {
        throw ShortcutError("The history fixture requires normal shells; unparkable popup: " + popup.windowContext.id)
      }
      // The ordinary activity heartbeat and native age expiration both run at
      // 30 seconds. Select real empty Spaces so that heartbeat has no visible
      // tab to mark. Do not stop its timer or exempt lastAccessedAt from whole-
      // tab equality; every retained WebContents/history stays live and exact.
      for owner in owners {
        let originalSpaceID = owner.store.state.activeSpaceID
        let originalTabID = owner.store.state.activeTabID
        let existing = Set(owner.store.state.spaces.map(\.id))
        let empty = owner.store.createSpace(name: "Owned history isolation " + UUID().uuidString,
          profileID: owner.store.activeProfileID)
        guard !existing.contains(empty.id) else { throw ShortcutError("The empty history fixture Space was not created.") }
        activityParking.append(ActivityParking(owner: owner, originalSpaceID: originalSpaceID,
          originalTabID: originalTabID, emptySpaceID: empty.id))
        guard owner.store.state.activeSpaceID == empty.id, owner.store.state.activeTabID == nil else {
          throw ShortcutError("The owned history fixture Space did not select its empty state.")
        }
        owner.layoutPages()
      }
      try await wait("real empty Space presentation before isolation baseline") {
        activityParking.allSatisfy { parked in
          parked.owner.store.state.activeSpaceID == parked.emptySpaceID && parked.owner.store.state.activeTabID == nil
            && !parked.owner.windowPages.values.contains {
              parked.owner.store.document(id: $0.id) != nil && $0.nativeWindow?.isVisible == true
            }
        }
      }
      // Finish the initial load's debounced native navigation capture before
      // recording the exact Core/browser baseline, rather than waiting a guess.
      await application.navigation.captureAll()
      for parked in activityParking { parked.owner.layoutPages() }
      originalTabs = application.store.state.tabs
      originalDocuments = documents(application)
      try require(activityParking.allSatisfy { $0.owner.store.state.activeTabID == nil },
        "historyMirrorParksEveryNormalShellWithoutSuppressingTheRealActivityHeartbeat")
      session = try await manager.historyMirrorSession()
      guard let session else { throw ShortcutError("The cold profile did not open its native history mirror.") }
      _ = try await session.retentionStatus()
      let oldNative = try await native([retained])
      guard let retainedIdentity = oldNative.first?.identity else { throw ShortcutError("The cold imported visit has no native identity.") }
      let oldReceipts = try bind(retentionStore, [retained], oldNative)
      try await session.replaceRetention([retainedIdentity])
      try await acknowledge(retentionStore, oldReceipts)
      guard let initialBoundary = importBoundaries[retained.importID] else { throw ShortcutError("No initial native boundary.") }
      try await session.finalizeLegacyBoundary(initialBoundary, completedInitial: true)
      nativeBoundaries.remove(initialBoundary)
      let installedRetention = try await session.retentionStatus()
      // Only a reader that runs AFTER native acknowledgement can prove the
      // bound-retention table, rather than the pending import journal, saved it.
      let postAcknowledgementExpirationCount = installedRetention.automaticExpirationReads
      try require(retentionStore.nativeHistoryLegacyReceipts(profileID: profile).isEmpty
        && retentionStore.nativeHistoryBindings(profileID: profile).first?.identity.visitID == retainedIdentity.visitID
        && installedRetention.retainedVisits >= 1,
        "historyColdOldVisitHasDurableBindingAndRetentionAfterImportJournalAcknowledgement")
      let extensionDirectory = root.appendingPathComponent("history-extension")
      try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: false)
      let manifest: [String: Any] = ["manifest_version": 3, "name": "Owned native history mirror fixture",
        "version": "1.0", "permissions": ["history"], "background": ["service_worker": "worker.js"]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: extensionDirectory.appendingPathComponent("manifest.json"), options: .atomic)
      try Data("chrome.runtime.onInstalled.addListener(() => {});".utf8).write(to: extensionDirectory.appendingPathComponent("worker.js"), options: .atomic)
      try await manager.setDeveloperMode(true)
      let extensionID = try await manager.loadUnpackedExtension(at: extensionDirectory)
      worker = try await manager.workerSession(extensionID)
      guard let worker else { throw ShortcutError("The owned history-permission worker did not attach.") }
      let retryStore = fixture("lost-native-reply")
      let captured = try input(retryStore, "lost-native-reply")
      let first = try await native([captured]) // Committed reply intentionally not applied to Core.
      guard let identity = first.first?.identity else { throw ShortcutError("Native legacy import returned no actual visit identity.") }
      retryStore.updateHistoryVisitTitle(id: captured.coreID, profileID: profile,
        address: captured.address, title: "Title arrived after the native commit")
      let fresh = try one(retryStore.nativeHistoryLegacyInputs(profileID: profile))
      let replay = try await native([fresh])
      try require(captured.importID == fresh.importID && first == replay,
        "historyLegacyLostNativeReplyReusesExactSQLVisitAndImportJournal")
      try require(try await visits(captured.address).map(\.visitId) == [identity.visitID],
        "historyLegacyTitleRetryDoesNotInsertAnotherNativeVisit")
      let receipts = try bind(retryStore, [fresh], replay)
      let committed = retryStore.state
      try require(try bind(retryStore, [fresh], replay) == receipts && retryStore.state == committed,
        "historyLegacyLostNativeAcknowledgementDoesNotDuplicateCoreVisit")
      let relaunched = BrowserStore(directory: retryStore.directory)
      try require(relaunched.nativeHistoryLegacyReceipts(profileID: profile) == receipts
        && relaunched.nativeHistoryBindings(profileID: profile).first?.identity.visitID == identity.visitID
        && relaunched.state.history.first?.title == fresh.title,
        "historyLegacyBindingAndOpaqueReceiptSurviveActualCoreRelaunch")
      // The first native acknowledgement reply is treated as lost. Repeating
      // that native operation is safe before the durable Core receipt is erased.
      try await session.acknowledgeLegacy(receipts.map { .init(importID: $0.importID, generation: $0.generation) })
      try await acknowledge(relaunched, receipts)
      let visitsAfterAcknowledgement = try await visits(captured.address)
      try require(relaunched.nativeHistoryLegacyReceipts(profileID: profile).isEmpty
        && relaunched.state.history.count == 1 && visitsAfterAcknowledgement.count == 1,
        "historyLegacyLostAcknowledgementReplaysExactReceiptWithoutSecondVisit")

      let tombstoneStore = fixture("deleted-before-bind")
      let deleted = try input(tombstoneStore, "deleted-before-bind")
      _ = try await native([deleted])
      let other = BrowserProfile(name: "Independent public fixture")
      let foreign = HistoryEntry(profileID: other.id, url: deleted.address, title: "Foreign Core row")
      tombstoneStore.state.profiles.append(other); tombstoneStore.state.history.append(foreign)
      guard let document = tombstoneStore.createTab(address: base.appendingPathComponent("retained-document").absoluteString) else {
        throw ShortcutError("No owned back/forward document model.")
      }
      tombstoneStore.navigate(tabID: document.id, address: base.appendingPathComponent("retained-next").absoluteString,
        recordHistory: false)
      let navigationBeforeDelete = tombstoneStore.state.tabs
      try await deleteURL(worker, address: deleted.address)
      let absent = try await native([deleted])
      try require(absent.first?.presence == .absent && absent.first?.identity == nil,
        "historyNativeDeleteBetweenImportAndBindingReturnsDurableTombstone")
      try await acknowledge(tombstoneStore, bind(tombstoneStore, [deleted], absent))
      try require(tombstoneStore.state.history == [foreign] && tombstoneStore.state.tabs == navigationBeforeDelete,
        "historyNativeTombstoneRemovesOnlyCapturedLegacyRowAndPreservesNavigation")

      let queuedStore = fixture("deleted-before-native-submission")
      let queuedURL = try input(queuedStore, "not-native-yet-url")
      try await boundary([queuedURL])
      try require(try await visits(queuedURL.address).isEmpty,
        "historyCapturedLegacyBoundaryPrecedesAnyNativeURLVisit")
      try await deleteURL(worker, address: queuedURL.address)
      let deletedBeforeImport = try await native([queuedURL])
      try await acknowledge(queuedStore, bind(queuedStore, [queuedURL], deletedBeforeImport))
      try require(deletedBeforeImport.first?.presence == .absent && queuedStore.state.history.isEmpty,
        "historyNativeURLDeleteBeforeSubmissionCannotResurrectCapturedLegacyVisit")
      let queuedRange = try input(queuedStore, "not-native-yet-range", at: now.addingTimeInterval(300))
      try await boundary([queuedRange])
      try await deleteRange(worker, start: queuedRange.visitedAt.addingTimeInterval(-1), end: queuedRange.visitedAt.addingTimeInterval(1))
      let rangeBeforeImport = try await native([queuedRange])
      try await acknowledge(queuedStore, bind(queuedStore, [queuedRange], rangeBeforeImport))
      try require(rangeBeforeImport.first?.presence == .absent && queuedStore.state.history.isEmpty,
        "historyNativeRangeDeleteBeforeSubmissionCannotResurrectCapturedLegacyVisit")

      let coalescedStore = fixture("newer-same-core-row")
      let older = try input(coalescedStore, "partial-range")
      let olderResult = try await native([older])
      let newer = try input(coalescedStore, "partial-range", at: now.addingTimeInterval(10), title: "Newer real Core visit")
      let staleReceipts = try bind(coalescedStore, [older], olderResult)
      try require(older.coreID == newer.coreID && older.importID != newer.importID
        && coalescedStore.nativeHistoryLegacyInputs(profileID: profile) == [newer]
        && coalescedStore.nativeHistoryBindings(profileID: profile).isEmpty,
        "historyLateLegacyReplyCannotBindNewerCoalescedSameURLVisit")
      let newerResult = try await native([newer])
      guard let olderIdentity = olderResult.first?.identity, let newerIdentity = newerResult.first?.identity else {
        throw ShortcutError("Coalesced Core visits need two actual native identities.")
      }
      let newerReceipts = try bind(coalescedStore, [newer], newerResult)
      try await acknowledge(coalescedStore, staleReceipts + newerReceipts)
      let coalescedNativeIDs = Set(try await visits(newer.address).map(\.visitId))
      try require(olderIdentity.visitID != newerIdentity.visitID
        && coalescedNativeIDs == Set([olderIdentity.visitID, newerIdentity.visitID])
        && coalescedStore.state.history.count == 1,
        "historyDistinctCoalescedVisitsRetainActualNativeIDsAndOneLatestCoreRow")
      try await deleteRange(worker, start: older.visitedAt.addingTimeInterval(-1), end: older.visitedAt.addingTimeInterval(1))
      let currentBeforeVerification = coalescedStore.state
      try await verify(coalescedStore, session: session, profileID: profile)
      try require(try await visits(newer.address).map(\.visitId) == [newerIdentity.visitID]
        && coalescedStore.state.history == currentBeforeVerification.history
        && coalescedStore.nativeHistoryBindings(profileID: profile).first?.identity.visitID == newerIdentity.visitID,
        "historyNativePartialRangeDeletionPreservesLatestExactBinding")

      let diskStore = fixture("core-write-failure")
      let disk = try input(diskStore, "core-write-failure")
      let nativeCommitted = try await native([disk]), diskBefore = diskStore.state
      let blockedFile = diskStore.directory.appendingPathComponent("native-state.json")
      try FileManager.default.removeItem(at: blockedFile)
      try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: false)
      var rejected = false
      do { _ = try bind(diskStore, [disk], nativeCommitted) } catch { rejected = true }
      try require(rejected && diskStore.state == diskBefore
        && diskStore.nativeHistoryLegacyReceipts(profileID: profile).isEmpty,
        "historyCoreDiskFailurePublishesNeitherBindingNorReceipt")
      let diskRetry = try await native([disk])
      let diskNativeVisits = try await visits(disk.address)
      try require(diskRetry == nativeCommitted && diskNativeVisits.count == 1,
        "historyCoreDiskFailureRetainsIdempotentNativeImportJournal")
      try FileManager.default.removeItem(at: blockedFile)
      try await acknowledge(diskStore, bind(diskStore, [disk], diskRetry))

      // Keep the old binding unverified while intentionally importing a new
      // Core UUID at the exact same native URL/time. A recycled VisitID would
      // make that deleted old binding appear present in the same generation.
      let deletedBindingStore = fixture("deleted-highest-visit-id")
      let oldIdentityInput = try input(deletedBindingStore, "exact-time-reimport", at: now.addingTimeInterval(700))
      let oldIdentityResult = try await native([oldIdentityInput])
      guard let oldExactIdentity = oldIdentityResult.first?.identity else { throw ShortcutError("No exact old native identity for reimport proof.") }
      try await acknowledge(deletedBindingStore, bind(deletedBindingStore, [oldIdentityInput], oldIdentityResult))
      try await deleteURL(worker, address: oldIdentityInput.address)
      let freshIntentStore = fixture("intentional-same-time-new-core-id")
      let freshIntent = try input(freshIntentStore, "exact-time-reimport", at: oldIdentityInput.visitedAt)
      let freshIntentResult = try await native([freshIntent])
      guard let freshIdentity = freshIntentResult.first?.identity else { throw ShortcutError("No actual native identity for intentional reimport.") }
      try require(freshIntent.coreID != oldIdentityInput.coreID && freshIntent.importID != oldIdentityInput.importID
        && freshIdentity.generation == oldExactIdentity.generation
        && freshIdentity.url == oldExactIdentity.url && freshIdentity.timeMicroseconds == oldExactIdentity.timeMicroseconds
        && freshIdentity.visitID != oldExactIdentity.visitID,
        "historyDeletedHighestNativeVisitIDIsNotReusedByExactTimeFreshCoreIntent")
      try await acknowledge(freshIntentStore, bind(freshIntentStore, [freshIntent], freshIntentResult))
      try await verify(deletedBindingStore, session: session, profileID: profile)
      try await verify(freshIntentStore, session: session, profileID: profile)
      try require(deletedBindingStore.state.history.isEmpty && freshIntentStore.state.history.count == 1
        && freshIntentStore.nativeHistoryBindings(profileID: profile).first?.identity.visitID == freshIdentity.visitID,
        "historyExactTimeReimportCannotMakeDeletedOldBindingAppearPresent")

      let foreignManager = ChromeExtensionManager(engine: application.engine, profileID: UUID().uuidString)
      ownedManagers.append(foreignManager)
      let foreignSession = try await foreignManager.historyMirrorSession(); ownedSessions.append(foreignSession)
      let sourceBeforeForeignProof = coalescedStore.state
      let lease = try await foreignSession.beginVerification(total: 1)
      var foreignAuthorityRejected = false
      do {
        _ = try await foreignSession.verify(lease, offset: 0, inputs: [newerIdentity])
      } catch let failure as CefDevToolsError {
        // Another database UUID is unavailable authority, never proof that the
        // original profile's visit was deleted. Do not count arbitrary transport
        // failure, invalid parsing, timeout or cancellation as a passing check.
        if case .protocolError(let code, let message) = failure, code == -32000,
          message == "The native history verification snapshot changed or could not be read." {
          foreignAuthorityRejected = true
          fputs("Native history foreign proof rejected by database authority: code=\(code), requested=1\n", stderr)
        } else { throw failure }
      }
      // Releasing the rejected lease grants no proof. An empty, fresh native
      // confirmation then checks this exact foreign DB/observer remains healthy;
      // its zero rows are deliberately never applied to any Core collection.
      try await foreignSession.acknowledgeVerification(lease: lease.lease, revision: lease.revision)
      let healthyForeignLease = try await foreignSession.beginVerification(total: 0)
      let healthyRevision = try await foreignSession.confirm(healthyForeignLease)
      try await foreignSession.acknowledgeVerification(lease: healthyForeignLease.lease, revision: healthyForeignLease.revision)
      try require(foreignAuthorityRejected && healthyRevision == healthyForeignLease.revision
        && coalescedStore.state == sourceBeforeForeignProof,
        "historyVisitIdentityCannotResolveInAnotherActualNativeProfileDatabase")
      let privateManager = ChromeExtensionManager(engine: application.engine, profileID: profile, isPrivate: true)
      var privateRejected = false
      do { let forbidden = try await privateManager.historyMirrorSession(); await forbidden.close() }
      catch { privateRejected = true }
      try require(privateRejected, "historyPrivateNativeManagerCannotOpenPublicHistoryMirror")

      // An explicit Electron snapshot import creates fresh profile/Core UUIDs;
      // it is new user intent and must not inherit the previous import tombstone.
      let source: [String: Any] = ["profiles": [["id": profile, "name": "Explicit legacy import"]],
        "spaces": [["id": "legacy", "profileId": profile, "name": "Legacy"]], "tabs": [],
        "history": [["profileId": profile, "url": deleted.address, "title": "Explicitly imported again",
          "visitedAt": deleted.visitedAt.timeIntervalSince1970 * 1000]]]
      let sourceFile = root.appendingPathComponent("explicit-electron-snapshot.json")
      try JSONSerialization.data(withJSONObject: source).write(to: sourceFile, options: .atomic)
      let importStore = fixture("explicit-reimport")
      try importStore.importLegacy(from: sourceFile)
      guard let importedRow = importStore.state.history.first,
        let imported = importStore.nativeHistoryLegacyInputs(profileID: importedRow.profileID).first else {
        throw ShortcutError("The real Electron snapshot import did not produce a public legacy visit.")
      }
      let importedManager = ChromeExtensionManager(engine: application.engine, profileID: imported.profileID)
      ownedManagers.append(importedManager)
      let importedSession = try await importedManager.historyMirrorSession(); ownedSessions.append(importedSession)
      let importedBoundary = try await importedSession.createLegacyBoundary()
      try importStore.assignNativeHistoryLegacyBoundaryDurably(profileID: imported.profileID, inputs: [imported], leaseID: importedBoundary)
      let importedResult = try await importedSession.importLegacy([wire(imported, boundaryLeaseID: importedBoundary)])
      let importedReceipts = try importStore.applyNativeHistoryLegacyImportsDurably(profileID: imported.profileID,
        inputs: [imported], results: importedResult.map(core))
      try await importedSession.acknowledgeLegacy(importedReceipts.map { .init(importID: $0.importID, generation: $0.generation) })
      try importStore.acknowledgeNativeHistoryLegacyReceiptsDurably(importedReceipts)
      try await importedSession.finalizeLegacyBoundary(importedBoundary, completedInitial: true)
      try require(imported.coreID != deleted.coreID && imported.profileID != deleted.profileID
        && imported.importID != deleted.importID && importedResult.first?.presence == .present
        && importStore.nativeHistoryBindings(profileID: imported.profileID).count == 1,
        "historyExplicitLegacyJSONReimportUsesFreshUUIDsAndCreatesIntentionalNativeVisit")
      try await wait("actual scheduled native age-expiration reader", timeout: 90) {
        let status = try await session.retentionStatus()
        guard let current = UInt64(status.automaticExpirationReads),
          let initial = UInt64(postAcknowledgementExpirationCount) else {
          throw ShortcutError("The native expiration status is not an exact decimal counter.")
        }
        return current > initial
      }
      try require(try await visits(retained.address).map(\.visitId) == [retainedIdentity.visitID]
        && retentionStore.nativeHistoryLegacyReceipts(profileID: profile).isEmpty,
        "historyBoundVisitOlderThanNinetyDaysSurvivesActualNativeAgeExpiration")
      try await deleteURL(worker, address: retained.address)
      try await verify(retentionStore, session: session, profileID: profile)
      let afterExplicitOldDelete = try await visits(retained.address)
      try require(retentionStore.state.history.isEmpty && afterExplicitOldDelete.isEmpty,
        "historyExplicitNativeDeleteStillRemovesAgeProtectedLibraryVisit")
      let queuedAll = try input(queuedStore, "not-native-yet-delete-all", at: now.addingTimeInterval(600))
      try await boundary([queuedAll])
      let allDeleted = try await worker.evaluate("(async()=>{await chrome.history.deleteAll();return true;})()", timeout: 15)
      guard allDeleted as? Bool == true else { throw ShortcutError("The owned native history deleteAll API did not finish.") }
      let allBeforeImport = try await native([queuedAll])
      try await acknowledge(queuedStore, bind(queuedStore, [queuedAll], allBeforeImport))
      try require(allBeforeImport.first?.presence == .absent && queuedStore.state.history.isEmpty,
        "historyNativeDeleteAllBeforeSubmissionCannotResurrectCapturedLegacyVisit")
      let finalDocuments = documents(application)
      let documentsUnchanged = application.store.state.tabs == originalTabs && finalDocuments == originalDocuments
      if !documentsUnchanged {
        logDocumentDifferences(originalTabs: originalTabs, originalDocuments: originalDocuments,
          currentTabs: application.store.state.tabs, currentDocuments: finalDocuments)
      }
      try require(documentsUnchanged,
        "historyMirrorNativeDeletionsNeverAlterLiveDocumentsOrBackForwardState")
      try await cleanup()
      try require(activityParking.allSatisfy { parked in
        parked.owner.store.state.activeSpaceID == parked.originalSpaceID
          && parked.owner.store.state.activeTabID == parked.originalTabID
          && !parked.owner.store.state.spaces.contains { $0.id == parked.emptySpaceID }
      }, "historyMirrorRestoresEveryOriginalShellSpaceAndSelectionAfterStrictIsolationCheck")
      return checks
    } catch {
      let failure = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native history mirror fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw failure
    }
  }

  /// A short exclusive use of the ordinary history-clear suspension boundary
  /// keeps the app drain from acknowledging the exact native events before the
  /// fixture can inspect them. Every inspected event is durably applied and
  /// acknowledged through the same public Core/native operations before resume.
  static func runSameDocument(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, worker: ChromeExtensionWorkerSession) async throws -> [String] {
    try validate(url)
    guard owner.windowContext.isOpen, !owner.windowContext.isClosing,
      owner.store.state.activeProfile?.isPrivate == false else {
      throw ShortcutError("Same-document history acceptance requires the owned public browser shell.")
    }
    let profile = owner.store.activeProfileID
    let prior = owner.store.state.activeTabID
    let address = url.appendingPathComponent("history-native-spa-" + UUID().uuidString)
    let manager = ChromeExtensionManager(engine: application.engine, profileID: profile)
    var session: ChromeHistoryMirrorSession?
    var fixtureTab: String?
    var suspended = false
    var cleaned = false
    var activationPage: ChromiumPage?
    let activationKey = "__zacroSPAActivation_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let activationLiteral = try literal(activationKey)
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native same-document history check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native same-document history acceptance failed: " + name) }
      checks.append(name)
    }
    func removeActivation() async {
      guard let page = activationPage, application.engine.pages[page.id] === page,
        page.profileID == profile, page.ownerWindowID == owner.windowContext.id,
        let browser = page.browser, !browser.isClosed else { return }
      _ = try? await browser.devTools.evaluate("""
        (()=>{const state=globalThis[\(activationLiteral)];if(!state)return true;
          if(window.onbeforeunload===state.handler)window.onbeforeunload=state.previous;
          state.button.remove();delete globalThis[\(activationLiteral)];return true;})()
        """, timeout: 2)
      activationPage = nil
    }
    func cleanup() async throws {
      guard !cleaned else { return }; cleaned = true
      var failure: Error?
      defer {
        if suspended { application.historyMirror.resume(profileID: profile); suspended = false }
      }
      if !suspended {
        suspended = true
        do { try await application.historyMirror.suspend(profileID: profile) }
        catch { failure = error }
      }
      await removeActivation()
      if let fixtureTab, owner.store.tab(fixtureTab)?.isClosed == false,
        !(await owner.requestCloseTab(fixtureTab)) {
        failure = failure ?? ShortcutError("The exact same-document fixture tab did not accept normal close.")
      }
      for suffix in ["", "#push", "#replace"] {
        do { try await deleteURL(worker, address: address.absoluteString + suffix) }
        catch { failure = failure ?? error }
      }
      // Original deleteUrl acknowledges scheduling, before its native DB
      // deletion notifications. Order even partially failed cleanup mutations
      // before resuming unchanged revision-bound Core/native verification.
      if let session {
        do { try await session.orderedQueueBarrier() } catch { failure = failure ?? error }
      }
      await session?.close(); session = nil
      if suspended { application.historyMirror.resume(profileID: profile); suspended = false }
      do { try await application.historyMirror.refresh(profileID: profile) }
      catch { failure = failure ?? error }
      if let prior, owner.store.tab(prior)?.isClosed == false { owner.store.selectTab(id: prior) }
      owner.scheduleLayout()
      if let failure { throw failure }
    }
    do {
      guard let tab = owner.store.createTab(address: address.absoluteString) else { throw ShortcutError("No owned same-document fixture tab.") }
      fixtureTab = tab.id
      let page = try await owner.ensurePageReady(tab)
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready()
      try await wait("full document history commit") { !page.isLoading && page.url == address && page.documentError == nil }
      activationPage = page
      let buttonID = "historySPAActivate_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      _ = try await browser.devTools.evaluate("""
        (()=>{const button=document.createElement('button');button.id=\(try literal(buttonID));button.textContent='Activate';
          button.style.cssText='position:fixed;left:20px;top:16px;width:120px;height:40px;z-index:2147483647';
          const state={button,previous:window.onbeforeunload,handler:()=>{}};
          globalThis[\(activationLiteral)]=state;document.body.appendChild(button);window.onbeforeunload=state.handler;return true;})()
        """)
      owner.actions.palette = false; owner.windowContext.show(); owner.layoutPages(); page.focus()
      let activation = try await NativeDocumentActivationAcceptance.click(application: application,
        owner: owner, page: page, buttonID: buttonID, label: "same-document-native-history")
      try require(["trusted", "primary", "sticky", "focused"].allSatisfy { activation[$0] as? Bool == true },
        "historyNativeSPAUsesRealTrustedActivationBeforeHistoryMutation")
      await removeActivation()
      try await application.historyMirror.refresh(profileID: profile)
      session = try await manager.historyMirrorSession()
      guard let session else { throw ShortcutError("No exact native same-document mirror transport.") }
      suspended = true
      try await application.historyMirror.suspend(profileID: profile)
      let baseline = application.store.state.history.filter { $0.profileID == profile && $0.url.hasPrefix(address.absoluteString) }
      let initialDocument = try await session.document(page)
      guard baseline.count == 1, let initialEvent = initialDocument.currentEventID else {
        throw ShortcutError("The initial full document has no exact Library/native visit.")
      }
      var previousEvent = initialEvent
      var observations = [SameDocumentObservation]()
      func record(_ document: ChromeHistoryDocument?, event: ChromeHistoryEvent?) {
        let value = SameDocumentObservation(address: page.url.map { String($0.absoluteString.prefix(500)) },
          fragment: page.url?.fragment, loading: page.isLoading, back: page.canGoBack, forward: page.canGoForward,
          browserID: page.browser?.id, documentToken: document?.documentToken, logicalID: document?.logicalID,
          eventID: document?.currentEventID, previousEvent: previousEvent, initialEvent: initialEvent,
          presence: event?.presence.rawValue, identity: event?.identity)
        if observations.last != value { observations.append(value); observations = Array(observations.suffix(8)) }
      }
      func diagnostics(_ phase: String, nativeHistory: Bool) async {
        var detail: [String: Any] = ["phase": phase,
          "observations": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(observations))) ?? []]
        if nativeHistory {
          if let value = try? await browser.devTools.call("Page.getNavigationHistory") {
            detail["nativeHistory"] = ["currentIndex": value["currentIndex"] ?? -1,
              "entries": (value["entries"] as? [[String: Any]] ?? []).prefix(8).map {
                ["id": $0["id"] ?? -1, "url": String(($0["url"] as? String ?? "").prefix(500))]
              }]
          }
          detail["activation"] = try? await browser.devTools.evaluate("({sticky:navigator.userActivation.hasBeenActive,focused:document.hasFocus()})")
        }
        if let data = try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) { fputs("Native same-document history state \(text)\n", stderr) }
      }
      func consume(_ phase: String, fragment: String?) async throws {
        var captured: ChromeHistoryEvent?
        observations.removeAll()
        do {
          try await wait("native " + phase + " journal commit") {
            guard !page.isLoading, page.url?.fragment == fragment else { record(nil, event: nil); return false }
            let document = try await session.document(page)
            record(document, event: nil)
            guard document.documentToken == initialDocument.documentToken, document.logicalID == tab.id,
              let eventID = document.currentEventID, eventID != previousEvent else { return false }
            captured = try await nativeEvent(eventID, documentToken: document.documentToken, session: session)
            record(document, event: captured)
            return captured?.presence == .present && captured?.identity != nil
          }
        } catch {
          if let document = try? await session.document(page) { record(document, event: captured) }
          await diagnostics(phase + "-failed", nativeHistory: true)
          throw error
        }
        await diagnostics(phase + "-committed", nativeHistory: false)
        guard let event = captured, let identity = event.identity else { throw ShortcutError("No exact committed native SPA event.") }
        try require(event.publish && !event.libraryVisit && event.logicalID == tab.id
          && event.documentToken == initialDocument.documentToken,
          "historyNative" + phase + "KeepsDocumentIdentityWithoutLibraryVisit")
        let actual = try await historyVisits(worker, address: identity.url)
        try require(actual.contains { $0.visitId == identity.visitID },
          "historyNative" + phase + "IdentityMatchesActualChromeHistoryVisit")
        let receipts = try application.store.applyNativeHistoryVisitEventsDurably(profileID: profile,
          events: [NativeHistoryMirrorDrain.coreEvent(event)])
        try require(receipts.count == 1 && receipts.first?.coreID == nil
          && application.store.state.history.filter { $0.profileID == profile && $0.url.hasPrefix(address.absoluteString) } == baseline,
          "historyNative" + phase + "PreservesOriginalLibraryRow")
        try await session.acknowledgeEvents(receipts.map(\.eventID))
        try application.store.acknowledgeNativeHistoryVisitReceiptsDurably(receipts)
        previousEvent = event.eventID
      }
      _ = try await browser.devTools.evaluate("history.pushState({owned:true}, '', '#push')")
      try await consume("PushState", fragment: "push")
      _ = try await browser.devTools.evaluate("history.replaceState({owned:true}, '', '#replace')")
      try await consume("ReplaceState", fragment: "replace")
      await diagnostics("before-native-Back", nativeHistory: true)
      page.goBack()
      try await consume("Back", fragment: nil)
      page.goForward()
      try await consume("Forward", fragment: "replace")
      try require(application.engine.pages[tab.id] === page && page.browser === browser
        && page.ownerWindowID == owner.windowContext.id && page.canGoBack,
        "historyNativeSPAAndBackForwardRetainExactOwnedBrowserDocument")
      application.historyMirror.resume(profileID: profile); suspended = false
      try await application.historyMirror.refresh(profileID: profile)
      try require(application.store.state.history.filter { $0.profileID == profile && $0.url.hasPrefix(address.absoluteString) } == baseline,
        "historyNativeSPAResumeDoesNotReplayAdditionalLibraryVisits")
      try await cleanup()
      return checks
    } catch {
      let failure = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native same-document fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw failure
    }
  }

  private static func validate(_ url: URL) throws {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil else {
      throw ShortcutError("History mirror acceptance requires the disposable custom-runtime loopback fixture.")
    }
  }
  private static func literal(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
  }
  private static func wait(_ phase: String, timeout: TimeInterval = 15,
    _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try Task.checkCancellation()
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ShortcutError("Native history mirror acceptance timed out: " + phase)
  }
  private static func historyVisits(_ worker: ChromeExtensionWorkerSession, address: String) async throws -> [Visit] {
    let value = try await worker.evaluate("(async()=>await chrome.history.getVisits({url:\(try literal(address))}))()", timeout: 15)
    guard let value else { throw ShortcutError("The real Chrome history API returned no visit array.") }
    return try JSONDecoder().decode([Visit].self, from: JSONSerialization.data(withJSONObject: value))
  }
  private static func deleteURL(_ worker: ChromeExtensionWorkerSession, address: String) async throws {
    let value = try await worker.evaluate("(async()=>{await chrome.history.deleteUrl({url:\(try literal(address))});return true;})()", timeout: 15)
    guard value as? Bool == true else { throw ShortcutError("The real Chrome history deleteUrl API did not finish.") }
  }
  private static func deleteRange(_ worker: ChromeExtensionWorkerSession, start: Date, end: Date) async throws {
    let arguments = ["startTime": start.timeIntervalSince1970 * 1000, "endTime": end.timeIntervalSince1970 * 1000]
    let value = try await worker.evaluate("(async()=>{await chrome.history.deleteRange(\(try literal(arguments)));return true;})()", timeout: 15)
    guard value as? Bool == true else { throw ShortcutError("The real Chrome history deleteRange API did not finish.") }
  }
  private static func one<T>(_ values: [T]) throws -> T {
    guard values.count == 1, let value = values.first else { throw ShortcutError("Expected one exact owned history row.") }
    return value
  }
  private static func nativeEvent(_ eventID: String, documentToken: String,
    session: ChromeHistoryMirrorSession) async throws -> ChromeHistoryEvent? {
    var sequence = "0", count = 0
    repeat {
      let page = try await session.eventPage(after: sequence)
      count += page.events.count
      guard count <= 20_000 else { throw NativeHistoryReconciliationError.incompleteSnapshot }
      if let event = page.events.first(where: { $0.eventID == eventID && $0.documentToken == documentToken }) { return event }
      if page.complete { return nil }
      sequence = page.nextSequence
    } while true
  }
  private static func wire(_ input: NativeHistoryLegacyInput, boundaryLeaseID: String?) throws -> ChromeHistoryLegacyInput {
    guard input.isValid, let time = input.nativeTimeMicroseconds,
      let boundaryLeaseID, UUID(uuidString: boundaryLeaseID)?.uuidString.lowercased() == boundaryLeaseID else {
      throw NativeHistoryReconciliationError.invalidSnapshot
    }
    return .init(importID: input.importID, url: input.address, timeMicroseconds: time, title: input.title,
      boundaryLeaseID: boundaryLeaseID)
  }
  private static func core(_ value: ChromeHistoryLegacyResult) -> NativeHistoryLegacyImportResult {
    .init(importID: value.importID, presence: presence(value.presence), generation: value.generation,
      identity: value.identity.map(NativeHistoryMirrorDrain.coreIdentity), sourceAddress: value.sourceAddress,
      boundaryLeaseID: value.boundaryLeaseID)
  }
  private static func presence(_ value: ChromeHistoryPresence) -> NativeHistoryVerificationResult.Presence {
    switch value { case .present: return .present; case .absent: return .absent; case .error: return .error }
  }
  private static func wireIdentity(_ value: NativeHistoryIdentity) -> ChromeHistoryIdentity {
    .init(generation: value.generation, visitID: value.visitID, timeMicroseconds: value.timeMicroseconds,
      url: value.url, originator: value.originator)
  }
  private static func verify(_ store: BrowserStore, session: ChromeHistoryMirrorSession, profileID: String) async throws {
    // Chrome history.deleteUrl resolves immediately after scheduling its DB
    // work, before OnHistoryDeletions advances the native observer revision.
    // Finish that real queue (and its preceding UI notification) before taking
    // a revision-bound lease. The barrier supplies no deletion proof; the full
    // exact verify/confirm transaction below must still authorize every row.
    try await session.orderedQueueBarrier()
    let inputs = store.nativeHistoryBindings(profileID: profileID)
    guard !inputs.isEmpty, inputs.count <= 512 else { throw ShortcutError("Expected bounded exact Core history bindings.") }
    let lease = try await session.beginVerification(total: inputs.count)
    let page = try await session.verify(lease, offset: 0, inputs: inputs.map { wireIdentity($0.identity) })
    let confirmed = try await session.confirm(lease)
    let results = zip(inputs, page.results).map { input, row in
      NativeHistoryVerificationResult(input: input, presence: presence(row.presence), title: row.title)
    }
    _ = try store.applyNativeHistoryVerificationDurably(profileID: profileID, inputs: inputs,
      pages: [.init(lease: page.lease, revision: page.revision, offset: page.offset, complete: page.complete, results: results)],
      lease: lease.lease, revision: lease.revision, confirmedRevision: confirmed)
    let receipt = NativeHistoryAcknowledgement(profileID: profileID, lease: lease.lease, revision: lease.revision)
    try await session.acknowledgeVerification(lease: receipt.lease, revision: receipt.revision)
    try store.acknowledgeNativeHistoryVerificationDurably(receipt)
  }
  private static func documents(_ application: ApplicationCoordinator) -> [String: DocumentState] {
    Dictionary(uniqueKeysWithValues: application.engine.pages.values.filter { $0.ownerWindowID != nil }.map { page in
      (page.id, DocumentState(page: ObjectIdentifier(page), browser: page.browser.map(ObjectIdentifier.init),
        address: page.url?.absoluteString, back: page.canGoBack, forward: page.canGoForward))
    })
  }

  /// Failure-only field names and identities diagnose isolation without logging
  /// page content, URLs, native encrypted session data or an unbounded snapshot.
  private static func logDocumentDifferences(originalTabs: [BrowserTab], originalDocuments: [String: DocumentState],
    currentTabs: [BrowserTab], currentDocuments: [String: DocumentState]) {
    let before = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0) })
    let after = Dictionary(uniqueKeysWithValues: currentTabs.map { ($0.id, $0) })
    func fields(_ tab: BrowserTab) -> [String: Any] {
      guard let data = try? JSONEncoder().encode(tab),
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
      return value
    }
    let tabChanges = Set(before.keys).union(after.keys).sorted().compactMap { id -> [String: Any]? in
      guard before[id] != after[id] else { return nil }
      guard let old = before[id], let new = after[id] else {
        return ["id": id, "change": before[id] == nil ? "added" : "removed"]
      }
      let oldFields = fields(old), newFields = fields(new)
      let changed = Set(oldFields.keys).union(newFields.keys).sorted().filter {
        let previous = try? JSONSerialization.data(withJSONObject: oldFields[$0] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
        let current = try? JSONSerialization.data(withJSONObject: newFields[$0] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
        return previous != current
      }
      return ["id": id, "fields": changed,
        "beforeStackCount": old.navigation.count, "afterStackCount": new.navigation.count,
        "beforeIndex": old.navigationIndex, "afterIndex": new.navigationIndex]
    }
    let nativeChanges = Set(originalDocuments.keys).union(currentDocuments.keys).sorted().compactMap { id -> [String: Any]? in
      guard originalDocuments[id] != currentDocuments[id] else { return nil }
      guard let old = originalDocuments[id], let new = currentDocuments[id] else {
        return ["id": id, "change": originalDocuments[id] == nil ? "added" : "removed"]
      }
      return ["id": id, "samePage": old.page == new.page, "sameBrowser": old.browser == new.browser,
        "sameAddress": old.address == new.address, "beforeBack": old.back, "afterBack": new.back,
        "beforeForward": old.forward, "afterForward": new.forward]
    }
    let payload: [String: Any] = ["tabChanges": Array(tabChanges.prefix(24)), "tabChangeCount": tabChanges.count,
      "documentChanges": Array(nativeChanges.prefix(24)), "documentChangeCount": nativeChanges.count]
    if let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let text = String(data: bytes, encoding: .utf8) {
      fputs("Native history mirror document isolation mismatch: " + text + "\n", stderr)
    }
  }
}
