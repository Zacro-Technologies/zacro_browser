import XCTest
@testable import ZacroServices

final class PortableExtensionTests: XCTestCase {
  private let id = String(repeating: "a", count: 32)
  private func record(_ state: String = "ENABLED", location: String = "FROM_STORE",
                      userMayModify: Bool = true, mustRemainInstalled: Bool = false) -> NativePortableExtension? {
    NativePortableExtension(chromiumID: id, location: location, state: state,
                            userMayModify: userMayModify, mustRemainInstalled: mustRemainInstalled)
  }
  func testOnlyAuthoritativeStoreSourceAndUserOwnedRecordsArePortable() {
    for source in ["UNPACKED", "THIRD_PARTY", "UNKNOWN", "INSTALLED_BY_DEFAULT", "https://chromewebstore.google.com"] {
      XCTAssertNil(record(location: source))
    }
    XCTAssertNil(record(userMayModify: false)); XCTAssertNil(record(mustRemainInstalled: true))
    XCTAssertNil(NativePortableExtension(chromiumID: "untrusted", location: "FROM_STORE", state: "ENABLED", userMayModify: true, mustRemainInstalled: false))
    XCTAssertNil(record("FUTURE_STATE"))
  }
  func testCrashPreservesEnabledIntentAndBlocklistCannotEnableAnotherDevice() {
    XCTAssertEqual(record("TERMINATED")?.state, .enabled)
    XCTAssertEqual(record("ENABLED")?.state, .enabled)
    XCTAssertEqual(record("DISABLED")?.state, .disabled)
    XCTAssertEqual(record("BLOCKLISTED")?.state, .disabled)
  }
  func testMinimalDescriptorDeduplicationAndVerifiedUninstallTombstone() throws {
    let enabled = try XCTUnwrap(record()), disabled = try XCTUnwrap(record("DISABLED"))
    XCTAssertEqual(enabled.descriptor, ["extensionId": .string(id), "source": ["kind": "web-store", "id": .string(id)], "state": "enabled"])
    XCTAssertEqual(NativePortableExtension.library([enabled, disabled]), [disabled.descriptor])
    XCTAssertEqual(enabled.removed().descriptor["state"], "removed")
    XCTAssertEqual(enabled.state, .enabled)
  }
}
