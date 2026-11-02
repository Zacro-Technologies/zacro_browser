import XCTest
@testable import ZacroCore

final class DownloadCollectionTests: XCTestCase {
  private func record(_ id: String, profile: String = "default", status: String = "complete", date: TimeInterval = 1, native: Bool = true) -> DownloadRecord {
    var value = DownloadRecord(id: id, profileID: profile, url: "https://example.com/file", filename: id, status: status)
    value.createdAt = Date(timeIntervalSince1970: date)
    if native { value.nativeGUID = UUID().uuidString }
    return value
  }
  func testOldActiveAndResumableDownloadsSurviveHistoryCap() {
    let active = record("active", status: "downloading"), paused = record("paused", status: "paused")
    var resumable = record("resumable", status: "interrupted"); resumable.canResume = true
    let history = (0..<1_000).map { record("history-\($0)", date: Double($0 + 10)) }
    let result = DownloadCollection.ordered(history + [active, paused, resumable])
    XCTAssertEqual(result.count, 1_000)
    XCTAssertEqual(Set(result.prefix(3).map(\.id)), ["active", "paused", "resumable"])
  }
  func testCompleteSnapshotRemovesOnlyUnchangedMissingNativeRecordsInItsProfile() {
    let erased = record("erased"), concurrent = record("event"), other = record("other", profile: "other"), legacy = record("legacy", native: false)
    let result = DownloadCollection.reconcile(existing: [erased, concurrent, other, legacy], updates: [], profileID: "default",
      nativeGUIDs: [], complete: true, unchangedGUIDs: [erased.nativeGUID!, other.nativeGUID!])
    XCTAssertEqual(Set(result.map(\.id)), [concurrent.id, other.id, legacy.id])
  }
  func testTruncatedSnapshotNeverInfersDeletionAndUpdatesKeepOtherProfiles() {
    let missing = record("old"), original = record("updated", status: "paused"), other = record("other", profile: "other")
    var changed = original; changed.status = "complete"
    var foreign = other; foreign.filename = "Wrong profile"
    let result = DownloadCollection.reconcile(existing: [missing, original, other], updates: [changed, foreign], profileID: "default",
      nativeGUIDs: [original.nativeGUID!], complete: false, unchangedGUIDs: [missing.nativeGUID!, original.nativeGUID!])
    XCTAssertEqual(result.first { $0.id == original.id }?.status, "complete")
    XCTAssertEqual(result.first { $0.id == other.id }, other)
    XCTAssertTrue(result.contains { $0.id == missing.id })
  }
  @MainActor func testStoreNormalizationKeepsActiveDownloadsWhenNewHistoryArrives() {
    var state = BrowserState()
    let active = record("active", status: "downloading")
    state.downloads = (0..<1_000).map { record("history-\($0)", date: Double($0 + 10)) } + [active]
    let store = BrowserStore(directory: FileManager.default.temporaryDirectory, initialState: state, memoryOnly: true)
    store.repair()
    XCTAssertEqual(store.state.downloads.count, 1_000)
    XCTAssertEqual(store.state.downloads.first?.id, active.id)
    store.recordDownload(record("new-history", date: 10_000))
    XCTAssertEqual(store.state.downloads.count, 1_000)
    XCTAssertEqual(store.state.downloads.first?.id, active.id)
  }
}
