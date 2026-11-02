import XCTest
@testable import ZacroCore

@MainActor final class NativeNavigationProvenanceTests: XCTestCase {
  let extensionID = String(repeating: "a", count: 32)
  private func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroNativeURLs-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }; return dir
  }
  private func provenance(_ url: String) throws -> NativeNavigationProvenance {
    try XCTUnwrap(.init(extensionID: extensionID, incarnationID: extensionID + ":12345", approvedURL: url))
  }
  func testExactNativeReceiptPreservesSettingsFilesAndLargeDataWithoutBroadeningTypedEntry() throws {
    let values = ["chrome://settings/", "file:///tmp/example.html", "data:text/html," + String(repeating: "x", count: 20_000)]
    for value in values {
      let receipt = try provenance(value)
      XCTAssertEqual(BrowserAddress.documentURL(value, provenance: receipt)?.absoluteString, value)
      XCTAssertNil(BrowserAddress.documentURL(value))
      XCTAssertNil(BrowserAddress.resolve(value))
      XCTAssertFalse(receipt.matches(value + "changed"))
    }
    XCTAssertNil(NativeNavigationProvenance(extensionID: extensionID, incarnationID: "wrong", approvedURL: values[0]))
    for value in ["javascript:alert(1)", "devtools://devtools/", "chrome-untrusted://new-tab-page/", "file:///tmp/\nsecret"] {
      XCTAssertNil(NativeNavigationProvenance(extensionID: extensionID, incarnationID: extensionID + ":12345", approvedURL: value))
    }
  }
  func testNativeURLHistoryPinsAndAtomicWindowCreationSurviveRestart() throws {
    let dir = try directory(), repo = BrowserRepository(directory: dir)
    let first = "chrome://settings/", second = "file:///tmp/example.html"
    let a = try provenance(first), b = try provenance(second)
    let scope = try repo.makeWindow(addresses: [first], nativeAuthorizations: [first:a])
    let id = try XCTUnwrap(scope.state.activeTabID)
    try scope.setNativePage(tabID: id, url: second, title: "File", provenance: b)
    XCTAssertEqual(scope.back(tabID: id), first); XCTAssertEqual(scope.tab(id)?.nativeNavigation, a)
    scope.togglePin(id: id); scope.closeTab(id: id)
    let restored = BrowserRepository(directory: dir)
    let stored = try XCTUnwrap(restored.canonicalStore.tab(id))
    XCTAssertEqual(stored.url, first); XCTAssertEqual(stored.nativeNavigation, a)
    XCTAssertEqual(stored.savedNativeNavigation, a)
    XCTAssertEqual(stored.navigation.first?.nativeNavigation, a)
  }
  func testNativeProvenanceCannotBeImportedAndPortableExportOmitsPrivilegedURLs() throws {
    let dir = try directory(), repo = BrowserRepository(directory: dir), url = "file:///tmp/private-path.html"
    let receipt = try provenance(url)
    let scope = try repo.makeWindow(addresses: [url], nativeAuthorizations: [url:receipt])
    let portable = dir.appendingPathComponent("portable.json")
    try scope.exportData(to: portable)
    XCTAssertFalse(String(decoding: try Data(contentsOf: portable), as: UTF8.self).contains("private-path"))
    let native = dir.appendingPathComponent("native.json")
    try JSONEncoder().encode(repo.canonicalStore.state).write(to: native)
    let destination = BrowserRepository(directory: try directory())
    try destination.focusedStore.importData(from: native)
    XCTAssertFalse(destination.canonicalStore.state.tabs.contains { $0.url == url })
    XCTAssertTrue(destination.canonicalStore.state.tabs.allSatisfy { $0.nativeNavigation == nil })
  }
  func testMismatchedReceiptCannotChangeOrCreateDocument() throws {
    let repo = BrowserRepository(directory: try directory()), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com")), receipt = try provenance("chrome://settings/")
    let before = repo.canonicalStore.state
    XCTAssertThrowsError(try scope.setNativePage(tabID: tab.id, url: "file:///tmp/other", provenance: receipt))
    XCTAssertThrowsError(try repo.makeWindow(addresses: ["file:///tmp/other"], nativeAuthorizations: ["file:///tmp/other":receipt]))
    XCTAssertEqual(repo.canonicalStore.state, before)
  }
  func testHistoryClearDuplicateAndSavedPinKeepExactProvenance() throws {
    let repo = BrowserRepository(directory: try directory()), scope = repo.focusedStore
    let tab = try XCTUnwrap(scope.createTab(address: "https://example.com"))
    let url = "file:///tmp/private-path.html", proof = try provenance("file:///tmp/private-path.html")
    try scope.setNativePage(tabID: tab.id, url: url, provenance: proof)
    scope.togglePin(id: tab.id)
    scope.replacePinnedDestination(id: tab.id)
    scope.navigate(tabID: tab.id, address: "https://example.com/other")
    let portable = scope.directory.appendingPathComponent("portable.json")
    try scope.exportData(to: portable)
    XCTAssertFalse(String(decoding: try Data(contentsOf: portable), as: UTF8.self).contains("private-path"))
    scope.resetPinnedDestination(id: tab.id)
    XCTAssertEqual(scope.tab(tab.id)?.nativeNavigation, proof)
    let duplicate = try XCTUnwrap(scope.duplicateTab(id: tab.id))
    XCTAssertEqual(duplicate.url, url); XCTAssertEqual(duplicate.nativeNavigation, proof)
    scope.closeTab(id: duplicate.id)
    try scope.clearHistoryDurably()
    XCTAssertEqual(scope.tab(tab.id)?.navigation.first?.nativeNavigation, proof)
    XCTAssertEqual(scope.state.archive.first?.tab.navigation.first?.nativeNavigation, proof)
  }
}
