import XCTest
@testable import ZacroCore

@MainActor final class NativeHistoryLegacyMigrationTests: XCTestCase {
  private let database = "75269840-881f-4cc6-a67c-c15ae1aeb802"
  private var generation: String { database + ":1" }
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroLegacyHistory-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func store(memoryOnly: Bool = true) throws -> BrowserStore {
    BrowserStore(directory: try directory(), memoryOnly: memoryOnly)
  }
  private func input(_ store: BrowserStore, address: String = "https://legacy.example/",
    time: TimeInterval = 1_700_000_000, title: String = "Legacy title") throws -> NativeHistoryLegacyInput {
    let id = try XCTUnwrap(store.recordHistoryVisit(profileID: store.activeProfileID,
      address: address, title: title, visitedAt: Date(timeIntervalSince1970: time)))
    return try XCTUnwrap(store.nativeHistoryLegacyInputs(profileID: store.activeProfileID).first { $0.coreID == id })
  }
  private func present(_ input: NativeHistoryLegacyInput, visitID: String = "21",
    generation: String? = nil) -> NativeHistoryLegacyImportResult {
    let generation = generation ?? self.generation
    return .init(importID: input.importID, presence: .present, generation: generation,
      identity: .init(generation: generation, visitID: visitID,
        timeMicroseconds: input.nativeTimeMicroseconds ?? "1", url: input.address))
  }
  private func absent(_ input: NativeHistoryLegacyInput, generation: String? = nil) -> NativeHistoryLegacyImportResult {
    .init(importID: input.importID, presence: .absent, generation: generation ?? self.generation)
  }
  @discardableResult private func apply(_ store: BrowserStore, _ inputs: [NativeHistoryLegacyInput],
    _ results: [NativeHistoryLegacyImportResult]) throws -> [NativeHistoryLegacyReceipt] {
    try store.applyNativeHistoryLegacyImportsDurably(profileID: store.activeProfileID, inputs: inputs, results: results)
  }
  private func blockWrites(_ store: BrowserStore) throws {
    let file = store.directory.appendingPathComponent("native-state.json")
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
  }

  func testOpaqueImportIDIsStableAcrossTitleAndEncodingButChangesWithExactVisitVersion() throws {
    let original = try input(store()), fields = ["profile", "id", "address", "time"]
    let title = NativeHistoryLegacyInput(profileID: original.profileID, coreID: original.coreID,
      address: original.address, visitedAt: original.visitedAt, title: "Updated title")
    XCTAssertTrue(original.isValid); XCTAssertEqual(title.importID, original.importID)
    let decoded = try JSONDecoder().decode(NativeHistoryLegacyInput.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(decoded.importID, original.importID)
    let versions = [
      NativeHistoryLegacyInput(profileID: "other", coreID: original.coreID, address: original.address, visitedAt: original.visitedAt, title: original.title),
      NativeHistoryLegacyInput(profileID: original.profileID, coreID: "different", address: original.address, visitedAt: original.visitedAt, title: original.title),
      NativeHistoryLegacyInput(profileID: original.profileID, coreID: original.coreID, address: original.address + "next", visitedAt: original.visitedAt, title: original.title),
      NativeHistoryLegacyInput(profileID: original.profileID, coreID: original.coreID, address: original.address,
        visitedAt: Date(timeIntervalSinceReferenceDate: original.visitedAt.timeIntervalSinceReferenceDate.nextUp), title: original.title),
    ]
    for (index, version) in versions.enumerated() { XCTAssertNotEqual(version.importID, original.importID, fields[index]) }
    XCTAssertEqual(original.importID.count, 64)
    XCTAssertNotNil(original.importID.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
  }

  func testPresentBindsExistingExactRowWithoutAppendingOrReplacingItsLateTitle() throws {
    let store = try store(), legacy = try input(store)
    store.updateHistoryVisitTitle(id: legacy.coreID, profileID: legacy.profileID,
      address: legacy.address, title: "Late committed title")
    let receipts = try apply(store, [legacy], [present(legacy)])
    XCTAssertEqual(store.state.history.count, 1)
    XCTAssertEqual(store.state.history[0].id, legacy.coreID)
    XCTAssertEqual(store.state.history[0].visitedAt, legacy.visitedAt)
    XCTAssertEqual(store.state.history[0].title, "Late committed title")
    XCTAssertEqual(store.nativeHistoryBindings(profileID: legacy.profileID).first?.identity, present(legacy).identity)
    XCTAssertEqual(store.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
    XCTAssertTrue(store.nativeHistoryLegacyInputs(profileID: legacy.profileID).isEmpty)
  }

  func testLostAcknowledgementReplaysWithoutSecondVisitAndSurvivesRelaunch() throws {
    let store = try store(memoryOnly: false), legacy = try input(store)
    let receipts = try apply(store, [legacy], [present(legacy)])
    let before = store.state
    XCTAssertEqual(try apply(store, [legacy], [present(legacy)]), receipts)
    XCTAssertEqual(store.state, before)
    let relaunched = BrowserStore(directory: store.directory)
    XCTAssertEqual(relaunched.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
    XCTAssertEqual(relaunched.nativeHistoryBindings(profileID: legacy.profileID).count, 1)
    XCTAssertTrue(relaunched.nativeHistoryLegacyInputs(profileID: legacy.profileID).isEmpty)
    try relaunched.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts)
    try relaunched.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts)
    XCTAssertTrue(relaunched.nativeHistoryLegacyReceipts(profileID: legacy.profileID).isEmpty)
    XCTAssertEqual(relaunched.state.history.count, 1)
  }

  func testNativeTombstoneBeforeCoreBindingRemovesOnlyCapturedLegacyRow() throws {
    let store = try store(), legacy = try input(store)
    let tab = try XCTUnwrap(store.createTab(address: "https://document.example/"))
    store.navigate(tabID: tab.id, address: "https://document.example/next", recordHistory: false)
    let other = BrowserProfile(name: "Other")
    let foreign = HistoryEntry(profileID: other.id, url: legacy.address, title: "Other profile")
    try store.commit { $0.profiles.append(other); $0.history.append(foreign) }
    let documents = store.state.tabs
    let receipts = try apply(store, [legacy], [absent(legacy)])
    XCTAssertEqual(store.state.history, [foreign]); XCTAssertEqual(store.state.tabs, documents)
    XCTAssertEqual(store.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
    XCTAssertEqual(try apply(store, [legacy], [absent(legacy)]), receipts)
    XCTAssertEqual(store.state.history, [foreign])
  }

  func testNewSameIDSameURLVersionSurvivesOldPresentAndAbsentResponses() throws {
    for presence in [NativeHistoryVerificationResult.Presence.present, .absent] {
      let store = try store(), old = try input(store)
      let newer = try input(store, time: old.visitedAt.timeIntervalSince1970 + 10, title: "New visit")
      XCTAssertEqual(newer.coreID, old.coreID); XCTAssertNotEqual(newer.importID, old.importID)
      let response = presence == .present ? present(old) : absent(old)
      try apply(store, [old], [response])
      XCTAssertEqual(store.state.history.count, 1)
      XCTAssertEqual(store.state.history[0].visitedAt, newer.visitedAt)
      XCTAssertEqual(store.state.history[0].title, "New visit")
      XCTAssertTrue(store.nativeHistoryBindings(profileID: old.profileID).isEmpty)
      XCTAssertEqual(store.nativeHistoryLegacyInputs(profileID: old.profileID), [newer])
    }
  }

  func testConcurrentNativeBindingCannotBeOverwrittenOrRemovedByLegacyResponse() throws {
    for presence in [NativeHistoryVerificationResult.Presence.present, .absent] {
      let store = try store(), legacy = try input(store)
      let native = NativeHistoryBinding(coreID: legacy.coreID, profileID: legacy.profileID,
        coreAddress: legacy.address, coreVisitedAt: legacy.visitedAt,
        identity: present(legacy, visitID: "99").identity!)
      XCTAssertTrue(try store.bindNativeHistoryVisitDurably(native))
      try apply(store, [legacy], [presence == .present ? present(legacy) : absent(legacy)])
      XCTAssertEqual(store.state.history.count, 1)
      XCTAssertEqual(store.nativeHistoryBindings(profileID: legacy.profileID), [native])
    }
  }

  func testNativeCanonicalizationRequiresExactJournalSourceAttestation() throws {
    let store = try store(), legacy = try input(store, address: "https://legacy.example/old/../actual")
    let nativeURL = "https://legacy.example/actual"
    XCTAssertNotEqual(legacy.address, nativeURL)
    let identity = NativeHistoryIdentity(generation: generation, visitID: "21",
      timeMicroseconds: legacy.nativeTimeMicroseconds!, url: nativeURL)
    let before = store.state
    for source in [nil, "https://foreign.example/"] {
      XCTAssertThrowsError(try apply(store, [legacy], [.init(importID: legacy.importID,
        presence: .present, generation: generation, identity: identity, sourceAddress: source)]))
      XCTAssertEqual(store.state, before)
    }
    try apply(store, [legacy], [.init(importID: legacy.importID, presence: .present,
      generation: generation, identity: identity, sourceAddress: legacy.address)])
    let binding = try XCTUnwrap(store.nativeHistoryBindings(profileID: legacy.profileID).first)
    XCTAssertEqual(binding.coreAddress, legacy.address)
    XCTAssertEqual(binding.identity.url, nativeURL)
    XCTAssertEqual(store.state.history.count, 1)
  }

  func testErrorIncompleteDuplicateReorderedAndForeignResponsesAreAtomic() throws {
    let store = try store(), a = try input(store), b = try input(store, address: "https://legacy.example/second")
    let original = store.state
    let invalid: [[NativeHistoryLegacyImportResult]] = [
      [], [present(a)], [present(a), present(a)], [present(b), present(a)],
      [present(a), .init(importID: b.importID, presence: .error, generation: generation)],
      [present(a), .init(importID: String(repeating: "a", count: 64), presence: .absent, generation: generation)],
      [present(a), .init(importID: b.importID, presence: .present, generation: generation,
        identity: .init(generation: generation, visitID: "22", timeMicroseconds: b.nativeTimeMicroseconds!, url: a.address))],
      [present(a), .init(importID: b.importID, presence: .present, generation: generation,
        identity: .init(generation: generation, visitID: "22", timeMicroseconds: "13438396800123456", url: b.address))],
      [present(a), present(b, visitID: "22", generation: "47f935f4-c75d-43a5-97ae-eb11457c45a1:1")],
      [present(a), present(b)], // The two distinct imports cannot share one native visit ID.
      [present(a), .init(importID: b.importID, presence: .absent, generation: generation, identity: present(b).identity)],
    ]
    for results in invalid {
      XCTAssertThrowsError(try apply(store, [a, b], results))
      XCTAssertEqual(store.state, original)
    }
    let foreign = NativeHistoryLegacyInput(profileID: "foreign", coreID: b.coreID,
      address: b.address, visitedAt: b.visitedAt, title: b.title)
    XCTAssertThrowsError(try apply(store, [a, foreign], [present(a), present(foreign, visitID: "22")]))
    XCTAssertEqual(store.state, original)
  }

  func testMixedEpochTombstoneAndNewVisitFromSameDatabaseCommitTogether() throws {
    let store = try store(), old = try input(store), fresh = try input(store, address: "https://legacy.example/new")
    let receipts = try apply(store, [old, fresh], [absent(old), present(fresh, visitID: "22", generation: database + ":2")])
    XCTAssertEqual(store.state.history.map(\.id), [fresh.coreID])
    XCTAssertEqual(receipts.map(\.generation), [generation, database + ":2"])
    XCTAssertEqual(store.nativeHistoryBindings(profileID: fresh.profileID).first?.identity.generation, database + ":2")
  }

  func testGenerationMismatchDoesNotReplacePendingNativeAcknowledgement() throws {
    let store = try store(), legacy = try input(store)
    let receipts = try apply(store, [legacy], [present(legacy)]), before = store.state
    XCTAssertThrowsError(try apply(store, [legacy], [present(legacy, generation: database + ":2")]))
    XCTAssertEqual(store.state, before)
    XCTAssertEqual(store.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
  }

  func testOnlyExactReceiptsCanAcknowledgeTheirCurrentEntry() throws {
    let store = try store(), a = try input(store), b = try input(store, address: "https://legacy.example/b")
    let receipts = try apply(store, [a, b], [present(a), present(b, visitID: "22")])
    try store.acknowledgeNativeHistoryLegacyReceiptsDurably([
      .init(profileID: "foreign", importID: receipts[0].importID, generation: generation),
      .init(profileID: b.profileID, importID: receipts[1].importID, generation: database + ":2"),
    ])
    XCTAssertEqual(store.nativeHistoryLegacyReceipts(profileID: a.profileID), receipts.sorted { $0.importID < $1.importID })
    try store.acknowledgeNativeHistoryLegacyReceiptsDurably([receipts[0]])
    XCTAssertEqual(store.nativeHistoryLegacyReceipts(profileID: a.profileID), [receipts[1]])
  }

  func testWriteFailurePublishesNeitherBindingRemovalNorReceiptAndAckFailureRetainsReceipt() throws {
    for presence in [NativeHistoryVerificationResult.Presence.present, .absent] {
      let store = try store(memoryOnly: false), legacy = try input(store), before = store.state
      try blockWrites(store)
      let result = presence == .present ? present(legacy) : absent(legacy)
      XCTAssertThrowsError(try apply(store, [legacy], [result]))
      XCTAssertEqual(store.state, before)
      try FileManager.default.removeItem(at: store.directory.appendingPathComponent("native-state.json"))
      let receipts = try apply(store, [legacy], [result]), committed = store.state
      try blockWrites(store)
      XCTAssertThrowsError(try store.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts))
      XCTAssertEqual(store.state, committed)
    }
  }

  func testRecoveryCannotResurrectUnboundLegacyRowAfterAcknowledgement() throws {
    let store = try store(memoryOnly: false), legacy = try input(store)
    let receipts = try apply(store, [legacy], [present(legacy)])
    try store.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts)
    try Data("corrupt primary".utf8).write(to: store.directory.appendingPathComponent("native-state.json"))
    let recovered = BrowserStore(directory: store.directory)
    XCTAssertEqual(recovered.state.history.count, 1)
    XCTAssertTrue(recovered.nativeHistoryLegacyInputs(profileID: legacy.profileID).isEmpty)
    XCTAssertEqual(recovered.nativeHistoryBindings(profileID: legacy.profileID).count, 1)
    XCTAssertTrue(recovered.nativeHistoryLegacyReceipts(profileID: legacy.profileID).isEmpty)
  }

  func testReceiptsContainNoURLOrTitleAndPortableImportCannotInjectThem() throws {
    let store = try store(), legacy = try input(store)
    let receipts = try apply(store, [legacy], [present(legacy)])
    let encoded = try JSONEncoder().encode(receipts[0])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["profileID", "importID", "generation"])
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("legacy.example"))
    let raw = store.directory.appendingPathComponent("native-import.json")
    try JSONEncoder().encode(store.state).write(to: raw)
    let other = try self.store()
    try other.importData(from: raw)
    XCTAssertTrue(other.state.nativeHistoryLegacyImportReceipts.isEmpty)
    let portable = store.directory.appendingPathComponent("portable.json")
    try store.exportData(to: portable)
    let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: portable)) as? [String: Any])
    XCTAssertNil(exported["nativeHistoryLegacyImportReceipts"])
  }

  func testPrivateRetiredMissingProfilesAndMalformedProofsAreRejected() throws {
    let store = try store(), legacy = try input(store), privateProfile = BrowserProfile(name: "Private", isPrivate: true)
    try store.commit { $0.profiles.append(privateProfile) }
    let privateRow = NativeHistoryLegacyInput(profileID: privateProfile.id, coreID: "private-history",
      address: legacy.address, visitedAt: legacy.visitedAt, title: "Private")
    let before = store.state
    for profile in [privateProfile.id, "missing"] {
      XCTAssertTrue(store.nativeHistoryLegacyInputs(profileID: profile).isEmpty)
      XCTAssertThrowsError(try store.applyNativeHistoryLegacyImportsDurably(profileID: profile,
        inputs: [privateRow], results: [present(privateRow)]))
      XCTAssertEqual(store.state, before)
    }
    for invalid in ["", database.uppercased() + ":1", database + ":0", database + ":01", "uuid:1"] {
      XCTAssertThrowsError(try apply(store, [legacy], [present(legacy, generation: invalid)]))
      XCTAssertEqual(store.state, before)
    }
    try store.commit { $0.pendingNativeProfileRetirements.append(legacy.profileID) }
    let retired = store.state
    XCTAssertTrue(store.nativeHistoryLegacyInputs(profileID: legacy.profileID).isEmpty)
    XCTAssertThrowsError(try apply(store, [legacy], [present(legacy)]))
    XCTAssertEqual(store.state, retired)
  }

  func testFacadePublishesBindingAndReceiptInOneCanonicalTransaction() throws {
    let repository = BrowserRepository(directory: try directory()), first = repository.focusedStore
    let legacy = try input(first)
    let second = try repository.makeWindow(addresses: ["about:blank"])
    let receipts = try apply(first, [legacy], [present(legacy)])
    XCTAssertEqual(repository.canonicalStore.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
    XCTAssertEqual(second.nativeHistoryBindings(profileID: legacy.profileID), first.nativeHistoryBindings(profileID: legacy.profileID))
    XCTAssertEqual(second.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
    let reopened = BrowserRepository(directory: repository.directory)
    XCTAssertEqual(reopened.canonicalStore.nativeHistoryLegacyReceipts(profileID: legacy.profileID), receipts)
    XCTAssertEqual(reopened.canonicalStore.nativeHistoryBindings(profileID: legacy.profileID).count, 1)
  }

  func testBoundsAndPendingReceiptCapacityFailWithoutPartialCommit() throws {
    let store = try store(), legacy = try input(store), before = store.state
    XCTAssertThrowsError(try apply(store, Array(repeating: legacy, count: 513), Array(repeating: present(legacy), count: 513)))
    XCTAssertEqual(store.state, before)
    try store.commit { candidate in
      for index in 0..<20_000 {
        let suffix = String(index, radix: 16)
        let id = String(repeating: "0", count: 64 - suffix.count) + suffix
        candidate.nativeHistoryLegacyImportReceipts[id] = .init(profileID: legacy.profileID, importID: id, generation: generation)
      }
    }
    let full = store.state
    XCTAssertThrowsError(try apply(store, [legacy], [present(legacy)]))
    XCTAssertEqual(store.state, full)
  }
}
