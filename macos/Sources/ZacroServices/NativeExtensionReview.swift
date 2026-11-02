import Foundation

/// A presentation of an existing durable sync intent, never a second queue or
/// permission grant. Native Chromium must still obtain any required consent.
public struct NativeExtensionReview: Equatable, Sendable {
  public enum Action: String, Sendable { case install, enable, disable, remove }
  public let intent: ServiceJSON
  public let action: Action
  public let name: String
  public var extensionID: String { intent["extension"]["extensionId"].string }
  public var profileID: String { intent["profileId"].string }
  public init(intent: ServiceJSON, action: Action, name: String = "") throws {
    let item = intent["extension"], state = item["state"].string
    guard SyncModel.id(intent["profileId"].string), SyncModel.id(intent["linkId"].string),
      !intent["endpoint"].string.isEmpty, !intent["accountId"].string.isEmpty,
      SyncModel.extensionID(item["extensionId"].string), SyncModel.id(item["generation"].string),
      item["source"]["kind"] == "web-store", item["source"]["id"] == item["extensionId"],
      (action == .remove && state == "removed") || (action == .install && ["enabled", "disabled"].contains(state)) ||
      (action == .enable && state == "enabled") || (action == .disable && state == "disabled") else {
      throw ServiceError("EXTENSION_SYNC", "This extension change is no longer available for review.")
    }
    self.intent = intent; self.action = action; self.name = String(name.prefix(160))
  }
  /// Revision-only updates do not invalidate a decision. A changed link,
  /// generation, source, or requested state always does.
  public var identity: ServiceJSON {
    let item = intent["extension"]
    return ["profileId":intent["profileId"], "linkId":intent["linkId"], "endpoint":intent["endpoint"],
      "accountId":intent["accountId"], "action":.string(action.rawValue),
      "extensionId":item["extensionId"], "generation":item["generation"], "state":item["state"], "source":item["source"]]
  }
  public var value: ServiceJSON { identity.merging(["name":.string(name), "intent":intent]) }
  public init(value: ServiceJSON) throws {
    guard let action = Action(rawValue:value["action"].string) else { throw ServiceError("EXTENSION_SYNC", "Review this change again.") }
    try self.init(intent:value["intent"], action:action, name:value["name"].string)
    guard identity.object.allSatisfy({ value[$0.key] == $0.value }) else {
      throw ServiceError("EXTENSION_SYNC", "The extension review changed. Open it again.")
    }
  }
  public func matches(_ other: NativeExtensionReview) -> Bool { identity == other.identity }
}
