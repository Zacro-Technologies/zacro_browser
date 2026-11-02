import Foundation

/// Projects an authoritative Chromium registry record into the original sync
/// descriptor. Callers must obtain these fields from the native manager, never
/// from an extension page, manifest-provided URL, or website message.
public struct NativePortableExtension: Equatable, Sendable {
  public enum State: String, Sendable { case enabled, disabled, removed }
  public let extensionID: String
  public private(set) var state: State
  public init?(chromiumID: String, location: String, state: String,
                userMayModify: Bool, mustRemainInstalled: Bool) {
    guard chromiumID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
      location == "FROM_STORE", userMayModify, !mustRemainInstalled else { return nil }
    self.extensionID = chromiumID
    switch state {
    case "ENABLED", "TERMINATED": self.state = .enabled
    case "DISABLED", "BLOCKLISTED": self.state = .disabled
    default: return nil
    }
  }
  public var descriptor: ServiceJSON {
    ["extensionId": .string(extensionID), "source": ["kind": "web-store", "id": .string(extensionID)], "state": .string(state.rawValue)]
  }
  /// An uninstall tombstone comes from a previously verified local record.
  public func removed() -> Self { var copy = self; copy.state = .removed; return copy }
  public static func library(_ records: [Self]) -> [ServiceJSON] {
    let unique = Dictionary(records.map { ($0.extensionID, $0) }, uniquingKeysWith: { _, latest in latest })
    return unique.keys.sorted().compactMap { unique[$0]?.descriptor }
  }
}
