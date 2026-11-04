import XCTest
@testable import ZacroCore

@MainActor final class NativeHistoryPublicationTests: XCTestCase {
  private func repository() throws -> BrowserRepository {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroHistoryPublication-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return BrowserRepository(directory: directory)
  }
  private func claim(profile: String, kind: NativeHistoryPublication.Kind = .popup,
    token: String = UUID().uuidString.lowercased(), event: NativeHistoryVisitEvent? = nil) -> NativeHistoryPublication {
    NativeHistoryPublication(leaseID: UUID().uuidString.lowercased(), documentToken: token,
      profileID: profile, kind: kind, capturedEvent: event)
  }
  private func popup(_ store: BrowserStore) throws -> BrowserTab {
    var tab = BrowserTab(spaceID: store.state.activeSpaceID, url: "https://popup.example/", title: "Popup")
    tab.windowID = try XCTUnwrap(store.owningWindowID)
    return tab
  }

  func testPopupAdoptionAndReceiptCommitTogetherWithoutChangingAnotherWindow() throws {
    let repository = try repository(), first = repository.focusedStore
    let second = try repository.makeWindow(focus: false)
    let firstState = first.state.windowSessions, focus = repository.focusedWindowID
    let tab = try popup(second), publication = claim(profile: second.activeProfileID)
    XCTAssertEqual(try second.adoptNativeHistoryPopupDurably(tab, publication: publication, activate: true).id, tab.id)
    let canonical = repository.canonicalStore
    XCTAssertEqual(canonical.tab(tab.id)?.windowID, second.owningWindowID)
    XCTAssertNil(first.tab(tab.id)); XCTAssertEqual(repository.focusedWindowID, focus)
    XCTAssertEqual(repository.windows.first(where: { $0.id == first.owningWindowID }),
      firstState?.first(where: { $0.id == first.owningWindowID }))
    XCTAssertEqual(second.state.activeTabID, tab.id)
    XCTAssertEqual(canonical.nativeHistoryPublicationReceipts(profileID: second.activeProfileID).first?.logicalID, tab.id)
    XCTAssertTrue(canonical.state.history.isEmpty)
    let reloaded = BrowserRepository(directory: repository.directory).canonicalStore
    XCTAssertNotNil(reloaded.tab(tab.id))
    XCTAssertEqual(reloaded.nativeHistoryPublicationReceipts(profileID: second.activeProfileID).first?.leaseID, publication.leaseID)
  }

  func testForeignFacadeAndParkedOwnerCannotAuthorPublication() throws {
    let repository = try repository(), first = repository.focusedStore
    let other = try repository.makeWindow(focus: false), tab = try popup(other)
    let publication = claim(profile: other.activeProfileID)
    let before = repository.canonicalStore.state
    XCTAssertThrowsError(try first.adoptNativeHistoryPopupDurably(tab, publication: publication))
    XCTAssertEqual(repository.canonicalStore.state, before)
    _ = repository.closeWindow(try XCTUnwrap(other.owningWindowID))
    let closed = repository.canonicalStore.state
    XCTAssertThrowsError(try other.adoptNativeHistoryPopupDurably(tab, publication: publication))
    XCTAssertEqual(repository.canonicalStore.state, closed)
  }

  func testPrivateProfileAndReusedDocumentLeaseAreRejected() throws {
    let repository = try repository(), store = repository.focusedStore
    let publicSpace = store.state.activeSpaceID
    let privateProfile = try store.createProfileDurably(name: "Private", isPrivate: true)
    let privateOwner = try repository.makeWindow(profileID: privateProfile.id, focus: false)
    let before = repository.canonicalStore.state
    XCTAssertThrowsError(try privateOwner.adoptNativeHistoryPopupDurably(popup(privateOwner),
      publication: claim(profile: privateProfile.id)))
    XCTAssertEqual(repository.canonicalStore.state, before)
    store.selectSpace(id: publicSpace)
    let tab = try popup(store), publication = claim(profile: store.activeProfileID)
    _ = try store.adoptNativeHistoryPopupDurably(tab, publication: publication)
    let committed = repository.canonicalStore.state
    XCTAssertThrowsError(try store.adoptNativeHistoryPopupDurably(popup(store),
      publication: claim(profile: store.activeProfileID, token: publication.documentToken)))
    XCTAssertEqual(repository.canonicalStore.state, committed)
  }

  func testCoreSaveFailureLeavesNeitherAdoptedTabNorReceipt() throws {
    let repository = try repository(), store = repository.focusedStore
    let tab = try popup(store), before = repository.canonicalStore.state
    let path = repository.directory.appendingPathComponent("native-state.json")
    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.adoptNativeHistoryPopupDurably(tab, publication: claim(profile: store.activeProfileID)))
    XCTAssertEqual(repository.canonicalStore.state, before)
  }

  func testClosingAdoptedTabRetainsReceiptUntilExactNativeAcknowledgement() throws {
    let repository = try repository(), store = repository.focusedStore
    let tab = try popup(store), publication = claim(profile: store.activeProfileID)
    _ = try store.adoptNativeHistoryPopupDurably(tab, publication: publication)
    let receipt = try XCTUnwrap(store.nativeHistoryPublicationReceipts(profileID: store.activeProfileID).first)
    store.closeTab(id: tab.id)
    XCTAssertEqual(store.nativeHistoryPublicationReceipts(profileID: store.activeProfileID), [receipt])
    let foreign = NativeHistoryPublicationReceipt(publication: claim(profile: store.activeProfileID),
      logicalID: tab.id, ownerWindowID: receipt.ownerWindowID, createdAt: tab.createdAt)
    try store.acknowledgeNativeHistoryPublicationsDurably([foreign])
    XCTAssertEqual(store.nativeHistoryPublicationReceipts(profileID: store.activeProfileID), [receipt])
    try store.acknowledgeNativeHistoryPublicationsDurably([receipt])
    try store.acknowledgeNativeHistoryPublicationsDurably([receipt])
    XCTAssertTrue(store.nativeHistoryPublicationReceipts(profileID: store.activeProfileID).isEmpty)
  }

  func testPeekPromotionUsesCapturedNativeIdentityWithoutURLOrTimeGuessing() throws {
    let repository = try repository(), store = repository.focusedStore
    let source = try XCTUnwrap(store.createTab(address: "https://source.example/"))
    store.setPeek(tabID: source.id, address: "https://preview.example/new", title: "New document")
    try store.updatePeekDurably(tabID: source.id) {
      $0.navigation = [.init(url: $0.url, title: $0.title)]; $0.navigationIndex = 0
    }
    let preview = try XCTUnwrap(store.tab(source.id)?.peek)
    let token = UUID().uuidString.lowercased()
    let event = NativeHistoryVisitEvent(eventID: UUID().uuidString.lowercased(), documentToken: token,
      logicalID: "peek:" + source.id, sequence: "42", publish: false, presence: .present,
      identity: NativeHistoryIdentity(generation: "75269840-881f-4cc6-a67c-c15ae1aeb802:1",
        visitID: "93", timeMicroseconds: "13438396800123456", url: "https://preview.example/captured"),
      title: "Captured at publication boundary", libraryVisit: false)
    let publication = claim(profile: store.activeProfileID, kind: .preview, token: token, event: event)
    let promoted = try store.promoteNativeHistoryPeekDurably(tabID: source.id, publication: publication)
    XCTAssertNil(store.tab(source.id)?.peek)
    XCTAssertEqual(promoted.url, preview.url)
    XCTAssertEqual(promoted.navigation, preview.navigation ?? [])
    let binding = try XCTUnwrap(store.nativeHistoryBindings(profileID: store.activeProfileID).first)
    XCTAssertEqual(binding.eventID, event.eventID); XCTAssertEqual(binding.identity, event.identity)
    XCTAssertEqual(store.state.history.count, 1)
    let receipt = try XCTUnwrap(store.nativeHistoryPublicationReceipts(profileID: store.activeProfileID).first)
    XCTAssertEqual(receipt.logicalID, promoted.id); XCTAssertNil(receipt.publication.capturedEvent)
    let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    XCTAssertFalse(encoded.contains("https://")); XCTAssertFalse(encoded.contains("Captured at"))
  }

  func testWrongPeekSourceAndDiskFailurePreservePreviewAndAllHistory() throws {
    let repository = try repository(), store = repository.focusedStore
    let source = try XCTUnwrap(store.createTab(address: "https://source.example/"))
    store.setPeek(tabID: source.id, address: "https://preview.example/", title: "Preview")
    let token = UUID().uuidString.lowercased()
    let wrong = NativeHistoryVisitEvent(eventID: UUID().uuidString.lowercased(), documentToken: token,
      logicalID: "peek:foreign", sequence: "42", publish: false, presence: .absent, identity: nil)
    let before = repository.canonicalStore.state
    XCTAssertThrowsError(try store.promoteNativeHistoryPeekDurably(tabID: source.id,
      publication: claim(profile: store.activeProfileID, kind: .preview, token: token, event: wrong)))
    XCTAssertEqual(repository.canonicalStore.state, before)
    let file = repository.directory.appendingPathComponent("native-state.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.promoteNativeHistoryPeekDurably(tabID: source.id,
      publication: claim(profile: store.activeProfileID, kind: .preview)))
    XCTAssertEqual(repository.canonicalStore.state, before)
  }

  func testPortableImportCannotInjectPublicationAuthorityAndExportOmitsIt() throws {
    let repository = try repository(), store = repository.focusedStore
    _ = try store.adoptNativeHistoryPopupDurably(popup(store), publication: claim(profile: store.activeProfileID))
    let export = repository.directory.appendingPathComponent("portable.json")
    try store.exportData(to: export)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any])
    XCTAssertNil(root["nativeHistoryPublicationReceipts"])
    let other = try self.repository().focusedStore
    let raw = repository.directory.appendingPathComponent("raw-native.json")
    try JSONEncoder().encode(repository.canonicalStore.state).write(to: raw)
    try other.importData(from: raw)
    XCTAssertTrue(other.state.nativeHistoryPublicationReceipts.isEmpty)
  }
}
