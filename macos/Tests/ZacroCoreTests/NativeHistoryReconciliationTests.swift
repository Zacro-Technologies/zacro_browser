import XCTest
@testable import ZacroCore

@MainActor final class NativeHistoryReconciliationTests: XCTestCase {
  private let generation = "75269840-881f-4cc6-a67c-c15ae1aeb802:1"
  private let lease = "18d44784-7e79-47d7-bec3-0b137f783afe"
  private let revision = "epoch-1:4"
  private func store(memoryOnly: Bool = true) throws -> BrowserStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroHistoryProof-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return BrowserStore(directory: directory, memoryOnly: memoryOnly)
  }
  private func binding(_ store: BrowserStore, address: String = "https://example.com/",
    visitedAt: Date = Date(), nativeID: String = "12") throws -> NativeHistoryBinding {
    let profile = store.activeProfileID
    let id = try XCTUnwrap(store.recordHistoryVisit(profileID: profile, address: address, visitedAt: visitedAt))
    let row = try XCTUnwrap(store.state.history.first { $0.id == id })
    let binding = NativeHistoryBinding(coreID: id, profileID: profile, coreAddress: row.url,
      coreVisitedAt: row.visitedAt, identity: NativeHistoryIdentity(generation: generation,
        visitID: nativeID, timeMicroseconds: "13438396800123456", url: address))
    XCTAssertTrue(try store.bindNativeHistoryVisitDurably(binding))
    return binding
  }
  private func page(_ bindings: [NativeHistoryBinding], presence: NativeHistoryVerificationResult.Presence,
    offset: Int = 0, complete: Bool = true) -> NativeHistoryVerificationPage {
    NativeHistoryVerificationPage(lease: lease, revision: revision, offset: offset, complete: complete,
      results: bindings.map { .init(input: $0, presence: presence) })
  }
  @discardableResult private func apply(_ store: BrowserStore, _ inputs: [NativeHistoryBinding],
    _ pages: [NativeHistoryVerificationPage], confirmation: String? = nil) throws -> Int {
    try store.applyNativeHistoryVerificationDurably(profileID: store.activeProfileID,
      inputs: inputs, pages: pages, lease: lease, revision: revision,
      confirmedRevision: confirmation ?? revision)
  }
  func testExactAbsenceRemovesOnlyCapturedBoundVisitAndPreservesDocumentHistory() throws {
    let store = try store()
    let tab = try XCTUnwrap(store.createTab(address: "https://example.com/first"))
    store.navigate(tabID: tab.id, address: "https://example.com/current", recordHistory: false)
    store.setPeek(tabID: tab.id, address: "https://example.com/preview", title: "Preview")
    try store.updatePeekDurably(tabID: tab.id) { $0.navigation = [.init(url: $0.url, title: $0.title)]; $0.navigationIndex = 0 }
    let a = try binding(store), b = try binding(store, address: "https://example.org/", nativeID: "13")
    let documents = store.state.tabs, archive = store.state.archive, splits = store.state.splits
    let mixed = NativeHistoryVerificationPage(lease: lease, revision: revision, offset: 0, complete: true,
      results: [.init(input: a, presence: .absent), .init(input: b, presence: .present)])
    XCTAssertEqual(try apply(store, [a, b], [mixed]), 1)
    XCTAssertFalse(store.state.history.contains { $0.id == a.coreID })
    XCTAssertTrue(store.state.history.contains { $0.id == b.coreID })
    XCTAssertEqual(store.state.tabs, documents); XCTAssertEqual(store.state.archive, archive)
    XCTAssertEqual(store.state.splits, splits)
    XCTAssertEqual(store.nativeHistoryAcknowledgements, [.init(profileID: a.profileID, lease: lease, revision: revision)])
  }
  func testSameURLNewVisitAndBindingSurviveOldAbsentProof() throws {
    let store = try store(), time = Date()
    let old = try binding(store, visitedAt: time)
    let current = try binding(store, visitedAt: time.addingTimeInterval(10), nativeID: "13")
    XCTAssertEqual(old.coreID, current.coreID)
    XCTAssertEqual(try apply(store, [old], [page([old], presence: .absent)]), 0)
    XCTAssertEqual(store.nativeHistoryBindings(profileID: old.profileID), [current])
    XCTAssertEqual(store.state.history.first?.visitedAt, current.coreVisitedAt)
  }
  func testTitleOnlyUpdateDoesNotTurnDeletedVisitIntoNewVisit() throws {
    let store = try store(), input = try binding(store)
    store.updateHistoryVisitTitle(id: input.coreID, profileID: input.profileID, address: input.coreAddress, title: "Late title")
    XCTAssertEqual(try apply(store, [input], [page([input], presence: .absent)]), 1)
  }
  func testDatabaseErrorAndChangedRevisionPreserveEverythingWithoutReceipt() throws {
    let store = try store(), input = try binding(store), before = store.state
    XCTAssertThrowsError(try apply(store, [input], [page([input], presence: .error)]))
    XCTAssertEqual(store.state, before)
    XCTAssertThrowsError(try apply(store, [input], [page([input], presence: .absent)], confirmation: "epoch-2:1"))
    XCTAssertEqual(store.state, before)
  }
  func testMissingDuplicateAndWrongInputResponsesAreNotAbsence() throws {
    let store = try store(), a = try binding(store), b = try binding(store, address: "https://example.org/", nativeID: "13")
    let before = store.state
    let invalid: [[NativeHistoryVerificationPage]] = [
      [], [page([a], presence: .absent)],
      [page([a, b], presence: .absent, complete: false)],
      [page([a, a], presence: .absent)],
      [page([a], presence: .absent, complete: false), page([b], presence: .absent, offset: 0)],
      [page([b, a], presence: .absent)],
      [page([a, b], presence: .absent), page([], presence: .absent, offset: 2)],
    ]
    for pages in invalid {
      XCTAssertThrowsError(try apply(store, [a, b], pages))
      XCTAssertEqual(store.state, before)
    }
  }
  func testContiguousBoundedPagesAndRepeatedAckAreIdempotent() throws {
    let store = try store(), a = try binding(store), b = try binding(store, address: "https://example.org/", nativeID: "13")
    let pages = [page([a], presence: .absent, complete: false), page([b], presence: .absent, offset: 1)]
    XCTAssertEqual(try apply(store, [a, b], pages), 2)
    XCTAssertEqual(try apply(store, [a, b], pages), 0)
    let receipt = try XCTUnwrap(store.nativeHistoryAcknowledgements.first)
    try store.acknowledgeNativeHistoryVerificationDurably(receipt)
    try store.acknowledgeNativeHistoryVerificationDurably(receipt)
    XCTAssertTrue(store.nativeHistoryAcknowledgements.isEmpty)
  }
  func testForeignReceiptCannotClearNewPendingAcknowledgement() throws {
    let store = try store(), input = try binding(store)
    try apply(store, [input], [page([input], presence: .absent)])
    let receipts = store.nativeHistoryAcknowledgements
    try store.acknowledgeNativeHistoryVerificationDurably(.init(profileID: input.profileID,
      lease: UUID().uuidString, revision: revision))
    XCTAssertEqual(store.nativeHistoryAcknowledgements, receipts)
  }
  func testUnboundLegacyAndForeignProfileHistoryRemain() throws {
    let store = try store(), input = try binding(store)
    let legacy = HistoryEntry(profileID: input.profileID, url: "https://legacy.example/", title: "Imported")
    let other = BrowserProfile(name: "Other")
    let foreign = HistoryEntry(profileID: other.id, url: input.coreAddress, title: "Other")
    try store.commit { state in state.profiles.append(other); state.history.append(contentsOf: [legacy, foreign]) }
    try apply(store, [input], [page([input], presence: .absent)])
    XCTAssertTrue(store.state.history.contains(legacy)); XCTAssertTrue(store.state.history.contains(foreign))
  }
  func testCoreDiskFailureDoesNotPublishDeletionOrAcknowledgement() throws {
    let store = try store(memoryOnly: false), input = try binding(store), before = store.state
    let file = store.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try apply(store, [input], [page([input], presence: .absent)]))
    XCTAssertEqual(store.state, before)
  }
  func testGenerationAndDecimalIdentifiersMustBeCanonical() {
    for value in ["", "uuid:1", generation.replacingOccurrences(of: ":1", with: ":0"),
      generation.replacingOccurrences(of: ":1", with: ":01"), generation.uppercased()] {
      XCTAssertFalse(NativeHistoryIdentity(generation: value, visitID: "12", timeMicroseconds: "13438396800123456", url: "https://example.com/").isValid)
    }
    for id in ["0", "-1", "01", "+1", "9223372036854775808"] {
      XCTAssertFalse(NativeHistoryIdentity(generation: generation, visitID: id, timeMicroseconds: "13438396800123456", url: "https://example.com/").isValid)
    }
  }

  private func event(sequence: Int = 1, time: TimeInterval = 1_700_000_000,
    publish: Bool = true) -> NativeHistoryVisitEvent {
    NativeHistoryVisitEvent(eventID: UUID().uuidString.lowercased(),
      documentToken: UUID().uuidString.lowercased(), logicalID: "owned-tab", sequence: String(sequence),
      publish: publish, presence: .present,
      identity: NativeHistoryIdentity(generation: generation, visitID: String(sequence),
        timeMicroseconds: String(Int64((time + 11_644_473_600) * 1_000_000)),
        url: "https://example.com/"), title: "Native committed title")
  }
  private func absent(_ event: NativeHistoryVisitEvent) -> NativeHistoryVisitEvent {
    .init(eventID: event.eventID, documentToken: event.documentToken, logicalID: event.logicalID,
      sequence: event.sequence, publish: event.publish, presence: .absent, identity: nil)
  }
  func testNativeJournalReplayAfterLostAcknowledgementAddsNoSecondVisit() throws {
    let store = try store(), event = event(), profile = store.activeProfileID
    let receipts = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [event])
    let committed = store.state
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(store.state.history.count, 1)
    XCTAssertEqual(try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [event]), receipts)
    XCTAssertEqual(store.state, committed)
    XCTAssertEqual(store.nativeHistoryBindings(profileID: profile).first?.eventID, event.eventID)
    try store.acknowledgeNativeHistoryVisitReceiptsDurably(receipts)
    XCTAssertTrue(store.nativeHistoryVisitReceipts(profileID: profile).isEmpty)
    XCTAssertEqual(store.state.history, committed.history)
    XCTAssertEqual(store.nativeHistoryBindings(profileID: profile).count, 1)
  }
  func testNativeDeletionBeforeLostAckReplayRemovesOnlyItsExactRow() throws {
    let store = try store(), event = event(), profile = store.activeProfileID
    let receipts = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [event])
    let documents = store.state.tabs
    XCTAssertEqual(try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [absent(event)]), receipts)
    XCTAssertTrue(store.state.history.isEmpty)
    XCTAssertTrue(store.nativeHistoryBindings(profileID: profile).isEmpty)
    XCTAssertEqual(store.state.tabs, documents)
    XCTAssertEqual(store.nativeHistoryVisitReceipts(profileID: profile), receipts)
  }
  func testOldNativeEventAbsenceCannotRemoveNewCoalescedVisit() throws {
    let store = try store(), old = event(), fresh = event(sequence: 2, time: 1_700_000_010)
    let profile = store.activeProfileID
    let oldReceipt = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [old])
    let freshReceipt = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [fresh])
    XCTAssertEqual(oldReceipt.first?.coreID, freshReceipt.first?.coreID)
    let rows = store.state.history, bindings = store.nativeHistoryBindings(profileID: profile)
    _ = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [absent(old)])
    XCTAssertEqual(store.state.history, rows)
    XCTAssertEqual(store.nativeHistoryBindings(profileID: profile), bindings)
    XCTAssertEqual(bindings.first?.eventID, fresh.eventID)
  }
  func testUnpublishedPeekAndPrivateEventsDoNotCreateLibraryVisits() throws {
    let store = try store(), before = store.state
    XCTAssertTrue(try store.applyNativeHistoryVisitEventsDurably(profileID: store.activeProfileID,
      events: [event(publish: false)]).isEmpty)
    XCTAssertEqual(store.state, before)
    // The native journal must keep this unpromoted Peek tombstone until its
    // publication boundary or exact producer close. Consuming it here would
    // make full-sizing a page impossible after chrome.history.deleteUrl.
    XCTAssertTrue(try store.applyNativeHistoryVisitEventsDurably(profileID: store.activeProfileID,
      events: [absent(event(publish: false))]).isEmpty)
    XCTAssertEqual(store.state, before)
    var privateProfile = BrowserProfile(name: "Private")
    privateProfile.isPrivate = true
    try store.commit { $0.profiles.append(privateProfile) }
    let privateBefore = store.state
    XCTAssertThrowsError(try store.applyNativeHistoryVisitEventsDurably(profileID: privateProfile.id, events: [event()]))
    XCTAssertEqual(store.state, privateBefore)
  }
  func testNativeSameDocumentVisitIsDurablyConsumedWithoutAppendingOrRebindingLibrary() throws {
    let store = try store(), full = event(), profile = store.activeProfileID
    _ = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [full])
    let history = store.state.history, bindings = store.nativeHistoryBindings(profileID: profile)
    let spa = NativeHistoryVisitEvent(eventID: UUID().uuidString.lowercased(), documentToken: full.documentToken,
      logicalID: full.logicalID, sequence: "2", publish: true, presence: .present,
      identity: NativeHistoryIdentity(generation: generation, visitID: "2", timeMicroseconds: "13344473601000000",
        url: "https://example.com/spa"), title: "SPA", libraryVisit: false)
    let receipt = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [spa])
    XCTAssertEqual(receipt.count, 1); XCTAssertNil(receipt.first?.coreID)
    XCTAssertEqual(store.state.history, history); XCTAssertEqual(store.nativeHistoryBindings(profileID: profile), bindings)
    XCTAssertEqual(try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [spa]), receipt)
    try store.acknowledgeNativeHistoryVisitReceiptsDurably(receipt)
    XCTAssertEqual(store.state.history, history)
  }

  func testInvalidNativeEventPageCannotCommitItsValidPrefix() throws {
    let store = try store(), first = event(), before = store.state
    let malformed = NativeHistoryVisitEvent(eventID: UUID().uuidString.lowercased(),
      documentToken: first.documentToken, logicalID: first.logicalID, sequence: "2",
      publish: true, presence: .error, identity: nil)
    XCTAssertThrowsError(try store.applyNativeHistoryVisitEventsDurably(profileID: store.activeProfileID,
      events: [first, malformed]))
    XCTAssertEqual(store.state, before)
    XCTAssertThrowsError(try store.applyNativeHistoryVisitEventsDurably(profileID: store.activeProfileID,
      events: [event(sequence: 2), first]))
    XCTAssertEqual(store.state, before)
  }
  func testOlderJournalReplayPreservesNewerVisibleVisitAndChronology() throws {
    let store = try store(), profile = store.activeProfileID
    let newer = event(sequence: 2, time: 1_700_000_200), older = event()
    _ = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [newer])
    let latest = try XCTUnwrap(store.state.history.first)
    _ = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [older])
    XCTAssertEqual(store.state.history.count, 2)
    XCTAssertEqual(store.state.history.first, latest)
    XCTAssertEqual(store.nativeHistoryBindings(profileID: profile).count, 2)
  }
  func testFailedCoreWriteDoesNotPublishNativeEventReceiptOrVisit() throws {
    let store = try store(memoryOnly: false), profile = store.activeProfileID
    _ = try store.applyNativeHistoryVisitEventsDurably(profileID: profile, events: [event()])
    let before = store.state, file = store.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.applyNativeHistoryVisitEventsDurably(profileID: profile,
      events: [event(sequence: 2, time: 1_700_000_100)]))
    XCTAssertEqual(store.state, before)
  }
}
