import Foundation
import ZacroChromium
import ZacroCore

/// Application-owned reconciliation lane. Native events only request a drain;
/// complete checked DB responses, exact Core row versions and durable receipts
/// authorize changes. This never edits navigation stacks or opens a user page.
@MainActor final class NativeHistoryMirrorDrain {
  typealias SessionFactory = @MainActor (String) async throws -> ChromeHistoryMirrorSession
  private let store: BrowserStore
  private let sessionFactory: SessionFactory
  private let available: @MainActor (String) -> Bool
  var onStatus: ((String, String?) -> Void)?
  private var observed = Set<String>()
  private var epochs: [String: UUID] = [:]
  private var running: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  private var again = Set<String>()
  private var livePublications: [String: Set<String>] = [:]
  private var suspended = Set<String>()
  private var closed = false

  init(store: BrowserStore, available: @escaping @MainActor (String) -> Bool,
    sessionFactory: @escaping SessionFactory) {
    self.store = store; self.available = available; self.sessionFactory = sessionFactory
  }

  /// Called only after the native profile History observer was registered.
  /// Startup/reconnect always verifies bound visits, even without a deletion
  /// notification, covering native DB commit followed immediately by a crash.
  func observationReady(profileID: String) {
    guard !closed else { return }
    observed.insert(profileID)
    requestRefresh(profileID)
  }
  func nativeHistoryChanged(profileID: String) { requestRefresh(profileID) }

  /// The adopting caller acquires this synchronously BEFORE native prepare,
  /// and releases it only after Core commit or native cancellation settles.
  /// This prevents a concurrent drain from classifying a live handoff as an
  /// orphan. These pins are deliberately ephemeral: restart has no live caller.
  func retainPublication(profileID: String, leaseID: String) throws {
    guard !closed, available(profileID), UUID(uuidString: leaseID)?.uuidString.lowercased() == leaseID,
      !(livePublications[profileID]?.contains(leaseID) ?? false),
      livePublications.values.reduce(0, { $0 + $1.count }) < 1000 else { throw CancellationError() }
    livePublications[profileID, default: []].insert(leaseID)
  }
  func releasePublication(profileID: String, leaseID: String) {
    livePublications[profileID]?.remove(leaseID)
    if livePublications[profileID]?.isEmpty == true { livePublications.removeValue(forKey: profileID) }
    requestRefresh(profileID)
  }

  func preparePublication(_ page: ChromiumPage) async throws -> NativeHistoryPublicationPreparation {
    let profileID = page.profileID, requestID = UUID().uuidString.lowercased()
    guard !page.isPrivate else { throw NativeHistoryReconciliationError.invalidProfile }
    try retainPublication(profileID: profileID, leaseID: requestID)
    let epoch = epochs[profileID] ?? UUID(); epochs[profileID] = epoch
    do {
      let session = try await sessionFactory(profileID)
      var prepared: ChromeHistoryPublication?
      do {
        let document = try await session.document(page)
        let native = try await session.preparePublication(page, expected: document, requestID: requestID)
        prepared = native
        let publication = NativeHistoryPublication(leaseID: native.leaseID, documentToken: native.documentToken,
          profileID: profileID, kind: native.kind == .preview ? .preview : .popup,
          capturedEvent: native.capturedEvent.map(Self.coreEvent))
        guard publication.isValid else { throw NativeHistoryReconciliationError.invalidSnapshot }
        try validatePublication(profileID: profileID, leaseID: requestID, epoch: epoch)
        return NativeHistoryPublicationPreparation(publication: publication, session: session, owner: self, epoch: epoch)
      } catch {
        if let prepared {
          try? await session.cancelPublication(leaseID: prepared.leaseID, documentToken: prepared.documentToken)
          try? await session.finalizePublication(leaseID: prepared.leaseID, documentToken: prepared.documentToken, logicalID: nil)
        }
        await session.close(); throw error
      }
    } catch {
      releasePublication(profileID: profileID, leaseID: requestID)
      throw error
    }
  }

  fileprivate func validatePublication(profileID: String, leaseID: String, epoch: UUID) throws {
    try Task.checkCancellation()
    // A completed clear must invalidate a preparation even after its visible
    // operation flag has been removed. No await separates this validation from
    // the caller's atomic Core adoption/promotion commit.
    guard !closed, !suspended.contains(profileID), epochs[profileID] == epoch, available(profileID),
      livePublications[profileID]?.contains(leaseID) == true else { throw CancellationError() }
  }

  func refresh(profileID: String) async throws {
    guard let task = schedule(profileID) else { throw CancellationError() }
    // A caller cancelling its wait does not revoke another owner's shared drain.
    try await task.value
    try Task.checkCancellation()
  }
  func removeProfile(_ profileID: String) {
    epochs[profileID] = UUID()
    running.removeValue(forKey: profileID)?.task.cancel()
    observed.remove(profileID); again.remove(profileID); suspended.remove(profileID)
    livePublications.removeValue(forKey: profileID)
  }
  /// Stop app-owned imports before a user history-clear operation. Cancelling
  /// a Swift wait alone does not retract a submitted native SQL task, so the
  /// exact profile transport also supplies an ordering-only DB queue barrier.
  func suspend(profileID: String) async throws {
    guard !closed else { throw CancellationError() }
    suspended.insert(profileID); epochs[profileID] = UUID(); again.remove(profileID)
    let pending = running.removeValue(forKey: profileID)?.task
    pending?.cancel(); _ = try? await pending?.value
    guard observed.contains(profileID) else { return }
    let session = try await sessionFactory(profileID)
    do { try await session.orderedQueueBarrier(); await session.close() }
    catch { await session.close(); throw error }
  }
  func resume(profileID: String) {
    suspended.remove(profileID); requestRefresh(profileID)
  }
  func close() async {
    guard !closed else { return }; closed = true
    let pending = running.values.map(\.task)
    for task in pending { task.cancel() }
    for task in pending { _ = try? await task.value }
    running.removeAll(); observed.removeAll(); again.removeAll(); livePublications.removeAll(); suspended.removeAll()
    onStatus = nil
  }

  private func requestRefresh(_ profileID: String) { _ = schedule(profileID) }
  @discardableResult private func schedule(_ profileID: String) -> Task<Void, Error>? {
    guard !closed, !suspended.contains(profileID), observed.contains(profileID), available(profileID) else { return nil }
    if let operation = running[profileID] { again.insert(profileID); return operation.task }
    let id = UUID(), epoch = epochs[profileID] ?? UUID()
    epochs[profileID] = epoch
    let task = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      defer {
        if self.running[profileID]?.id == id {
          self.running.removeValue(forKey: profileID)
          if self.again.remove(profileID) != nil { self.requestRefresh(profileID) }
        }
      }
      do {
        try await self.drain(profileID: profileID, epoch: epoch)
        try self.check(profileID, epoch: epoch)
        self.onStatus?(profileID, nil)
      } catch {
        if !(error is CancellationError), !self.closed, self.epochs[profileID] == epoch {
          self.onStatus?(profileID, error.localizedDescription)
        }
        throw error
      }
    }
    running[profileID] = (id, task)
    return task
  }
  private func check(_ profileID: String, epoch: UUID) throws {
    try Task.checkCancellation()
    guard !closed, !suspended.contains(profileID), epochs[profileID] == epoch, observed.contains(profileID), available(profileID),
      store.state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      !store.pendingNativeProfileRetirements.contains(profileID) else { throw CancellationError() }
  }
  private func drain(profileID: String, epoch: UUID) async throws {
    try check(profileID, epoch: epoch)
    let session = try await sessionFactory(profileID)
    do {
      try check(profileID, epoch: epoch)
      guard session.profileID == profileID else { throw NativeHistoryReconciliationError.invalidProfile }
      try await replayPublications(session, epoch: epoch)
      try await replaceRetention(session, epoch: epoch)
      try await replayAcknowledgements(session, epoch: epoch)
      try await migrateLegacy(session, epoch: epoch)
      try await ingest(session, epoch: epoch)
      try await verify(session, epoch: epoch)
      try await replaceRetention(session, epoch: epoch)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  private func replayPublications(_ session: ChromeHistoryMirrorSession, epoch: UUID) async throws {
    let profileID = session.profileID
    let native = try await session.publications()
    try check(profileID, epoch: epoch)
    let known = Set(native.map(\.leaseID))
    // Missing native evidence cannot be replaced by a URL/time match or by
    // inventing a new lease. Preserve the durable Core receipt and report error.
    guard store.nativeHistoryPublicationReceipts(profileID: profileID).allSatisfy({ known.contains($0.leaseID) }) else {
      throw NativeHistoryReconciliationError.unavailableDatabase
    }
    for lease in native {
      try check(profileID, epoch: epoch)
      if livePublications[profileID]?.contains(lease.leaseID) == true { continue }
      if let receipt = store.nativeHistoryPublicationReceipts(profileID: profileID).first(where: { $0.leaseID == lease.leaseID }) {
        guard receipt.isValid, receipt.publication.documentToken == lease.documentToken,
          receipt.publication.kind.rawValue == lease.kind.rawValue, lease.disposition != .cancelled,
          lease.logicalID == nil || lease.logicalID == receipt.logicalID else {
          throw NativeHistoryReconciliationError.invalidSnapshot
        }
        try await session.commitPublication(leaseID: lease.leaseID, documentToken: lease.documentToken, logicalID: receipt.logicalID)
        try check(profileID, epoch: epoch)
        // Exact acknowledgement purges recovery copies before native may forget
        // its commit idempotency record. A closed tab keeps past authorization.
        try store.acknowledgeNativeHistoryPublicationsDurably([receipt])
        try await session.finalizePublication(leaseID: lease.leaseID, documentToken: lease.documentToken, logicalID: receipt.logicalID)
        try check(profileID, epoch: epoch)
      } else {
        // Committed-without-Core-receipt means Core acknowledgement succeeded
        // before a lost native finalization. Prepared-without-receipt means no
        // surviving Core commit; cancellation cannot erase any published visit.
        if lease.disposition == .prepared {
          try await session.cancelPublication(leaseID: lease.leaseID, documentToken: lease.documentToken)
          try check(profileID, epoch: epoch)
        }
        try await session.finalizePublication(leaseID: lease.leaseID, documentToken: lease.documentToken,
          logicalID: lease.disposition == .committed ? lease.logicalID : nil)
        try check(profileID, epoch: epoch)
      }
    }
  }

  private func replaceRetention(_ session: ChromeHistoryMirrorSession, epoch: UUID) async throws {
    try check(session.profileID, epoch: epoch)
    let identities = store.nativeHistoryBindings(profileID: session.profileID).map { Self.wireIdentity($0.identity) }
    try await session.replaceRetention(identities)
    try check(session.profileID, epoch: epoch)
  }

  private func replayAcknowledgements(_ session: ChromeHistoryMirrorSession, epoch: UUID) async throws {
    let profileID = session.profileID
    let legacy = store.nativeHistoryLegacyReceipts(profileID: profileID)
    for offset in stride(from: 0, to: legacy.count, by: 512) {
      let batch = Array(legacy[offset..<min(offset + 512, legacy.count)])
      try await session.acknowledgeLegacy(batch.map { .init(importID: $0.importID, generation: $0.generation) })
      try check(profileID, epoch: epoch)
      try store.acknowledgeNativeHistoryLegacyReceiptsDurably(batch)
    }
    for receipt in store.nativeHistoryAcknowledgements where receipt.profileID == profileID {
      try await session.acknowledgeVerification(lease: receipt.lease, revision: receipt.revision)
      try check(profileID, epoch: epoch)
      try store.acknowledgeNativeHistoryVerificationDurably(receipt)
    }
    let receipts = store.nativeHistoryVisitReceipts(profileID: profileID)
    for offset in stride(from: 0, to: receipts.count, by: 512) {
      let batch = Array(receipts[offset..<min(offset + 512, receipts.count)])
      try await session.acknowledgeEvents(batch.map(\.eventID))
      try check(profileID, epoch: epoch)
      try store.acknowledgeNativeHistoryVisitReceiptsDurably(batch)
    }
  }

  private func migrateLegacy(_ session: ChromeHistoryMirrorSession, epoch: UUID) async throws {
    let profileID = session.profileID
    var nativeBoundaries = try await session.legacyBoundaries()
    try check(profileID, epoch: epoch)
    let known = Set(nativeBoundaries)
    guard store.nativeHistoryLegacyBoundaries(profileID: profileID).allSatisfy({ known.contains($0.leaseID) }) else {
      throw NativeHistoryReconciliationError.unavailableDatabase
    }
    let captured = store.nativeHistoryLegacyInputs(profileID: profileID)
    let assigned = Set(store.nativeHistoryLegacyBoundaries(profileID: profileID).map(\.importID))
    let unassigned = captured.filter { !assigned.contains($0.importID) }
    if !unassigned.isEmpty {
      let lease = try await session.createLegacyBoundary()
      nativeBoundaries.append(lease)
      try check(profileID, epoch: epoch)
      _ = try store.assignNativeHistoryLegacyBoundaryDurably(profileID: profileID, inputs: unassigned, leaseID: lease)
    }
    let boundaryByID = Dictionary(uniqueKeysWithValues: store.nativeHistoryLegacyBoundaries(profileID: profileID).map { ($0.importID, $0.leaseID) })
    // Concurrent JSON imports/new source versions get a new boundary on the
    // next drain; an existing captured identity never borrows a newer lease.
    let inputs = store.nativeHistoryLegacyInputs(profileID: profileID).filter { boundaryByID[$0.importID] != nil }
    var offset = 0
    while offset < inputs.count {
      try check(profileID, epoch: epoch)
      var end = min(inputs.count, offset + 512)
      var wire = try Array(inputs[offset..<end]).map { try Self.wireLegacy($0, boundary: boundaryByID[$0.importID]!) }
      while try JSONEncoder().encode(wire).count > 384 * 1024 {
        guard end - offset > 1 else { throw NativeHistoryReconciliationError.invalidSnapshot }
        end = offset + (end - offset) / 2
        wire = try Array(inputs[offset..<end]).map { try Self.wireLegacy($0, boundary: boundaryByID[$0.importID]!) }
      }
      let results = try await session.importLegacy(wire)
      try check(profileID, epoch: epoch)
      let receipts = try store.applyNativeHistoryLegacyImportsDurably(profileID: profileID,
        inputs: Array(inputs[offset..<end]), results: results.map { value in
          .init(importID: value.importID, presence: Self.corePresence(value.presence), generation: value.generation,
            identity: value.identity.map(Self.coreIdentity), sourceAddress: value.sourceAddress,
            boundaryLeaseID: value.boundaryLeaseID)
        })
      try await session.acknowledgeLegacy(receipts.map { .init(importID: $0.importID, generation: $0.generation) })
      try check(profileID, epoch: epoch)
      try store.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts)
      offset = end
    }
    let remaining = Set(store.nativeHistoryLegacyBoundaries(profileID: profileID).map(\.leaseID))
    let completed = store.nativeHistoryLegacyInputs(profileID: profileID).isEmpty
    if completed && nativeBoundaries.isEmpty {
      // Empty first profile still completes the initial deletion baseline, so a
      // later intentional JSON import starts at that later user action.
      nativeBoundaries.append(try await session.createLegacyBoundary())
      try check(profileID, epoch: epoch)
    }
    for lease in nativeBoundaries where !remaining.contains(lease) {
      try await session.finalizeLegacyBoundary(lease, completedInitial: completed)
      try check(profileID, epoch: epoch)
    }
    if !completed { again.insert(profileID) }
  }

  private func ingest(_ session: ChromeHistoryMirrorSession, epoch: UUID) async throws {
    let profileID = session.profileID
    var sequence = "0", count = 0
    repeat {
      let page = try await session.eventPage(after: sequence)
      try check(profileID, epoch: epoch)
      count += page.events.count
      guard count <= 20_000 else { throw NativeHistoryReconciliationError.incompleteSnapshot }
      let events = page.events.map(Self.coreEvent)
      let receipts = try store.applyNativeHistoryVisitEventsDurably(profileID: profileID, events: events)
      if !receipts.isEmpty {
        try await session.acknowledgeEvents(receipts.map(\.eventID))
        try check(profileID, epoch: epoch)
        try store.acknowledgeNativeHistoryVisitReceiptsDurably(receipts)
      }
      sequence = page.nextSequence
      if page.complete { return }
    } while true
  }

  private func verify(_ session: ChromeHistoryMirrorSession, epoch: UUID) async throws {
    let profileID = session.profileID
    let inputs = store.nativeHistoryBindings(profileID: profileID)
    guard !inputs.isEmpty else { return }
    let lease = try await session.beginVerification(total: inputs.count)
    try check(profileID, epoch: epoch)
    var pages: [NativeHistoryVerificationPage] = [], offset = 0
    while offset < inputs.count {
      var end = min(inputs.count, offset + 128)
      var wire = Array(inputs[offset..<end]).map { Self.wireIdentity($0.identity) }
      while try JSONEncoder().encode(wire).count > 512 * 1024 {
        guard end - offset > 1 else { throw NativeHistoryReconciliationError.invalidSnapshot }
        end = offset + (end - offset) / 2
        wire = Array(inputs[offset..<end]).map { Self.wireIdentity($0.identity) }
      }
      let response = try await session.verify(lease, offset: offset, inputs: wire, eventIDs: Array(inputs[offset..<end]).map(\.eventID))
      try check(profileID, epoch: epoch)
      let rows = zip(inputs[offset..<end], response.results).map { input, result in
        NativeHistoryVerificationResult(input: input, presence: Self.corePresence(result.presence), title: result.title)
      }
      pages.append(.init(lease: response.lease, revision: response.revision,
        offset: response.offset, complete: response.complete, results: rows))
      offset = end
    }
    let confirmed = try await session.confirm(lease)
    try check(profileID, epoch: epoch)
    _ = try store.applyNativeHistoryVerificationDurably(profileID: profileID, inputs: inputs, pages: pages,
      lease: lease.lease, revision: lease.revision, confirmedRevision: confirmed)
    let receipt = NativeHistoryAcknowledgement(profileID: profileID, lease: lease.lease, revision: lease.revision)
    try await session.acknowledgeVerification(lease: receipt.lease, revision: receipt.revision)
    try check(profileID, epoch: epoch)
    try store.acknowledgeNativeHistoryVerificationDurably(receipt)
  }

  private static func corePresence(_ value: ChromeHistoryPresence) -> NativeHistoryVerificationResult.Presence {
    switch value { case .present: return .present; case .absent: return .absent; case .error: return .error }
  }
  private static func wireIdentity(_ value: NativeHistoryIdentity) -> ChromeHistoryIdentity {
    .init(generation: value.generation, visitID: value.visitID, timeMicroseconds: value.timeMicroseconds,
      url: value.url, originator: value.originator)
  }
  private static func wireLegacy(_ value: NativeHistoryLegacyInput, boundary: String) throws -> ChromeHistoryLegacyInput {
    guard value.isValid, let time = value.nativeTimeMicroseconds else { throw NativeHistoryReconciliationError.invalidSnapshot }
    return .init(importID: value.importID, url: value.address, timeMicroseconds: time, title: value.title, boundaryLeaseID: boundary)
  }
  static func coreIdentity(_ value: ChromeHistoryIdentity) -> NativeHistoryIdentity {
    .init(generation: value.generation, visitID: value.visitID, timeMicroseconds: value.timeMicroseconds,
      url: value.url, originator: value.originator)
  }
  static func coreEvent(_ value: ChromeHistoryEvent) -> NativeHistoryVisitEvent {
    .init(eventID: value.eventID, documentToken: value.documentToken, logicalID: value.logicalID,
      sequence: value.sequence, publish: value.publish, presence: corePresence(value.presence),
      identity: value.identity.map(coreIdentity), title: value.title, libraryVisit: value.libraryVisit)
  }
}


/// The caller always settles this scope. Before Core commit cancellation is
/// safe; after Core commit only its durable opaque receipt authorizes replay.
@MainActor final class NativeHistoryPublicationPreparation {
  let publication: NativeHistoryPublication
  private let session: ChromeHistoryMirrorSession
  private weak var owner: NativeHistoryMirrorDrain?
  private var settled = false
  private let epoch: UUID
  init(publication: NativeHistoryPublication, session: ChromeHistoryMirrorSession, owner: NativeHistoryMirrorDrain, epoch: UUID) {
    self.publication = publication; self.session = session; self.owner = owner; self.epoch = epoch
  }
  func validate() throws {
    guard !settled, let owner else { throw CancellationError() }
    try owner.validatePublication(profileID: publication.profileID, leaseID: publication.leaseID, epoch: epoch)
  }
  func finish(committed: Bool) async {
    guard !settled else { return }; settled = true
    if !committed {
      try? await session.cancelPublication(leaseID: publication.leaseID, documentToken: publication.documentToken)
      try? await session.finalizePublication(leaseID: publication.leaseID, documentToken: publication.documentToken, logicalID: nil)
    }
    await session.close()
    owner?.releasePublication(profileID: publication.profileID, leaseID: publication.leaseID)
  }
}
