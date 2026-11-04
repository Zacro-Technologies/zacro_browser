import XCTest
@testable import ZacroCore

@MainActor final class NativeHistoryLegacyBoundaryTests: XCTestCase {
  private let generation = "75269840-881f-4cc6-a67c-c15ae1aeb802:1"
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroHistoryBoundary-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func store(memoryOnly: Bool = true) throws -> BrowserStore {
    BrowserStore(directory: try directory(), memoryOnly: memoryOnly)
  }
  private func input(_ store: BrowserStore, address: String = "https://boundary.example/",
    time: TimeInterval = 1_700_000_000) throws -> NativeHistoryLegacyInput {
    let id = try XCTUnwrap(store.recordHistoryVisit(profileID: store.activeProfileID,
      address: address, title: "Captured legacy visit", visitedAt: Date(timeIntervalSince1970: time)))
    return try XCTUnwrap(store.nativeHistoryLegacyInputs(profileID: store.activeProfileID).first { $0.coreID == id })
  }
  private func lease() -> String { UUID().uuidString.lowercased() }
  @discardableResult private func assign(_ store: BrowserStore, _ inputs: [NativeHistoryLegacyInput],
    _ lease: String) throws -> [NativeHistoryLegacyBoundaryReceipt] {
    try store.assignNativeHistoryLegacyBoundaryDurably(profileID: store.activeProfileID, inputs: inputs, leaseID: lease)
  }
  private func result(_ input: NativeHistoryLegacyInput, lease: String?, present: Bool = true) -> NativeHistoryLegacyImportResult {
    .init(importID: input.importID, presence: present ? .present : .absent, generation: generation,
      identity: present ? .init(generation: generation, visitID: "21", timeMicroseconds: input.nativeTimeMicroseconds!, url: input.address) : nil,
      sourceAddress: input.address, boundaryLeaseID: lease)
  }
  private func blockWrites(_ store: BrowserStore) throws -> URL {
    let url = store.directory.appendingPathComponent("native-state.json")
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testBoundarySurvivesRelaunchWithoutAddressOrTitleAndPreservesOriginalLeaseAcrossTitleChange() throws {
    let store = try store(memoryOnly: false), captured = try input(store), original = lease()
    let receipts = try assign(store, [captured], original)
    XCTAssertEqual(receipts.count, 1); XCTAssertTrue(receipts[0].isValid)
    let encoded = String(decoding: try JSONEncoder().encode(receipts), as: UTF8.self)
    XCTAssertFalse(encoded.contains("boundary.example")); XCTAssertFalse(encoded.contains(captured.title))
    store.updateHistoryVisitTitle(id: captured.coreID, profileID: captured.profileID, address: captured.address, title: "Late title")
    let updated = try XCTUnwrap(store.nativeHistoryLegacyInputs(profileID: captured.profileID).first)
    XCTAssertEqual(updated.importID, captured.importID)
    XCTAssertEqual(try assign(store, [updated], lease()), receipts)
    let relaunched = BrowserStore(directory: store.directory)
    XCTAssertEqual(relaunched.nativeHistoryLegacyBoundaries(profileID: captured.profileID), receipts)
    XCTAssertEqual(relaunched.state.history.first?.title, "Late title")
  }

  func testNewerExactVisitVersionDoesNotBorrowOldBoundaryOrGetBoundByOldResponse() throws {
    let store = try store(), old = try input(store), oldLease = lease()
    try assign(store, [old], oldLease)
    let newer = try input(store, time: old.visitedAt.timeIntervalSince1970 + 10), newLease = lease()
    XCTAssertEqual(old.coreID, newer.coreID); XCTAssertNotEqual(old.importID, newer.importID)
    XCTAssertTrue(try assign(store, [old], newLease).isEmpty)
    let current = try assign(store, [newer], newLease)
    XCTAssertEqual(current.map(\.importID), [newer.importID]); XCTAssertEqual(current.map(\.leaseID), [newLease])
    try store.applyNativeHistoryLegacyImportsDurably(profileID: old.profileID, inputs: [old],
      results: [result(old, lease: oldLease, present: false)])
    XCTAssertEqual(store.nativeHistoryLegacyBoundaries(profileID: newer.profileID), current)
    XCTAssertEqual(store.nativeHistoryLegacyInputs(profileID: newer.profileID), [newer])
    XCTAssertTrue(store.nativeHistoryBindings(profileID: newer.profileID).isEmpty)
  }

  func testBindingAndAbsenceRequireExactBoundaryAndRemoveItInSameDurableTransaction() throws {
    for present in [true, false] {
      let store = try store(memoryOnly: false), captured = try input(store), boundary = lease()
      try assign(store, [captured], boundary)
      let before = store.state
      for wrong in [nil, lease(), "invalid"] {
        XCTAssertThrowsError(try store.applyNativeHistoryLegacyImportsDurably(profileID: captured.profileID,
          inputs: [captured], results: [result(captured, lease: wrong, present: present)]))
        XCTAssertEqual(store.state, before)
      }
      let receipts = try store.applyNativeHistoryLegacyImportsDurably(profileID: captured.profileID,
        inputs: [captured], results: [result(captured, lease: boundary, present: present)])
      XCTAssertTrue(store.nativeHistoryLegacyBoundaries(profileID: captured.profileID).isEmpty)
      XCTAssertEqual(store.nativeHistoryLegacyReceipts(profileID: captured.profileID), receipts)
      XCTAssertEqual(store.state.history.count, present ? 1 : 0)
      let relaunched = BrowserStore(directory: store.directory)
      XCTAssertTrue(relaunched.nativeHistoryLegacyBoundaries(profileID: captured.profileID).isEmpty)
      XCTAssertEqual(relaunched.nativeHistoryLegacyReceipts(profileID: captured.profileID), receipts)
    }
  }

  func testAssignmentAndBindingDiskFailuresRetainExactPriorAuthority() throws {
    let store = try store(memoryOnly: false), captured = try input(store), boundary = lease(), before = store.state
    let file = try blockWrites(store)
    XCTAssertThrowsError(try assign(store, [captured], boundary)); XCTAssertEqual(store.state, before)
    try FileManager.default.removeItem(at: file)
    let assigned = try assign(store, [captured], boundary), boundBefore = store.state
    _ = try blockWrites(store)
    XCTAssertThrowsError(try store.applyNativeHistoryLegacyImportsDurably(profileID: captured.profileID,
      inputs: [captured], results: [result(captured, lease: boundary)]))
    XCTAssertEqual(store.state, boundBefore)
    XCTAssertEqual(store.nativeHistoryLegacyBoundaries(profileID: captured.profileID), assigned)
    XCTAssertTrue(store.nativeHistoryLegacyReceipts(profileID: captured.profileID).isEmpty)
  }

  func testMalformedDuplicateForeignAndNonpublicSnapshotsFailAtomically() throws {
    let store = try store(), captured = try input(store), before = store.state
    let foreign = NativeHistoryLegacyInput(profileID: "other", coreID: captured.coreID, address: captured.address,
      visitedAt: captured.visitedAt, title: captured.title)
    for (inputs, boundary) in [([captured], "invalid"), ([captured], lease().uppercased()),
      ([captured, captured], lease()), ([foreign], lease())] {
      XCTAssertThrowsError(try assign(store, inputs, boundary)); XCTAssertEqual(store.state, before)
    }
    for profile in [BrowserProfile(name: "Private", isPrivate: true), BrowserProfile(name: "Retired")] {
      var state = before
      state.profiles.append(profile)
      if !profile.isPrivate { state.pendingNativeProfileRetirements = [profile.id] }
      let rejected = BrowserStore(directory: try directory(), initialState: state, memoryOnly: true)
      XCTAssertThrowsError(try rejected.assignNativeHistoryLegacyBoundaryDurably(profileID: profile.id, inputs: [], leaseID: lease()))
      XCTAssertTrue(rejected.nativeHistoryLegacyBoundaries(profileID: profile.id).isEmpty)
    }
    XCTAssertThrowsError(try store.assignNativeHistoryLegacyBoundaryDurably(profileID: "missing", inputs: [], leaseID: lease()))
  }

  func testNormalizationRemovesChangedBoundPrivateRetiredAndMalformedMappings() throws {
    let store = try store(), captured = try input(store), boundary = lease()
    let assigned = try assign(store, [captured], boundary)
    var state = store.state
    state.nativeHistoryLegacyBoundaries["foreign"] = assigned[0]
    state.nativeHistoryLegacyBoundaries[String(repeating: "b", count: 64)] = .init(profileID: captured.profileID,
      importID: String(repeating: "b", count: 64), leaseID: boundary)
    BrowserStore.normalizeNativeHistoryLegacyBoundaries(&state)
    XCTAssertEqual(Array(state.nativeHistoryLegacyBoundaries.values), assigned)
    state.history[0].visitedAt.addTimeInterval(1)
    BrowserStore.normalizeNativeHistoryLegacyBoundaries(&state)
    XCTAssertTrue(state.nativeHistoryLegacyBoundaries.isEmpty)
    for markPrivate in [true, false] {
      state = store.state
      if markPrivate { state.profiles[0].isPrivate = true }
      else { state.pendingNativeProfileRetirements = [captured.profileID] }
      BrowserStore.normalizeNativeHistoryLegacyBoundaries(&state)
      XCTAssertTrue(state.nativeHistoryLegacyBoundaries.isEmpty)
    }
    state = store.state
    state.nativeHistoryBindings[captured.coreID] = .init(coreID: captured.coreID, profileID: captured.profileID,
      coreAddress: captured.address, coreVisitedAt: captured.visitedAt, identity: result(captured, lease: boundary).identity!)
    BrowserStore.normalizeNativeHistoryLegacyBoundaries(&state)
    XCTAssertTrue(state.nativeHistoryLegacyBoundaries.isEmpty)
  }

  func testPortableImportCannotInjectBoundaryAuthorityAndLegacyReimportGetsFreshIdentity() throws {
    let store = try store(), captured = try input(store), boundary = lease()
    try assign(store, [captured], boundary)
    let exported = try directory().appendingPathComponent("portable.json")
    try store.exportData(to: exported)
    XCTAssertFalse(String(decoding: try Data(contentsOf: exported), as: UTF8.self).contains("nativeHistoryLegacyBoundaries"))
    var serialized = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
    serialized["nativeHistoryLegacyBoundaries"] = ["malformed": "untrusted"]
    let untrusted = try directory().appendingPathComponent("untrusted-native.json")
    try JSONSerialization.data(withJSONObject: serialized).write(to: untrusted)
    let destination = try self.store()
    try destination.importData(from: untrusted)
    XCTAssertTrue(destination.state.nativeHistoryLegacyBoundaries.isEmpty)
    let legacy: [String: Any] = ["profiles": [["id": captured.profileID, "name": "Legacy"]],
      "spaces": [["id": "old", "profileId": captured.profileID]], "tabs": [],
      "history": [["profileId": captured.profileID, "url": captured.address,
        "visitedAt": captured.visitedAt.timeIntervalSince1970 * 1000]]]
    let legacyFile = try directory().appendingPathComponent("legacy.json")
    try JSONSerialization.data(withJSONObject: legacy).write(to: legacyFile)
    try destination.importLegacy(from: legacyFile)
    let imported = try XCTUnwrap(destination.state.history.first)
    let fresh = try XCTUnwrap(destination.nativeHistoryLegacyInputs(profileID: imported.profileID).first)
    XCTAssertNotEqual(fresh.importID, captured.importID); XCTAssertNotEqual(fresh.coreID, captured.coreID)
    XCTAssertTrue(destination.nativeHistoryLegacyBoundaries(profileID: fresh.profileID).isEmpty)
  }

  func testWholeSnapshotSupportsDistinctExistingLeasesButRejectsOversizedInputBeforeMutation() throws {
    let store = try store(), first = try input(store), second = try input(store, address: "https://boundary.example/second")
    let old = try assign(store, [first], lease())
    let newLease = lease(), assigned = try assign(store, [first, second], newLease)
    XCTAssertEqual(assigned.first, old.first); XCTAssertEqual(assigned.last?.leaseID, newLease)
    let before = store.state
    let oversized = (0...20_000).map { index in
      NativeHistoryLegacyInput(profileID: first.profileID, coreID: "row-\(index)", address: first.address,
        visitedAt: first.visitedAt, title: first.title)
    }
    XCTAssertThrowsError(try assign(store, oversized, lease())); XCTAssertEqual(store.state, before)
  }
}
