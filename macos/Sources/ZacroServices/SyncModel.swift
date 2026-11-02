import Foundation

enum SyncModel {
  static func id(_ value: String) -> Bool { value.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil }
  static func extensionID(_ value: String) -> Bool { value.range(of: "^[a-p]{32}$", options: .regularExpression) != nil }
  static var emptyArea: ServiceJSON { ["values":[:],"accessLevel":"TRUSTED_AND_UNTRUSTED_CONTEXTS","writes":[]] }
  static func localKey(_ profile: String, _ extensionID: String) -> String { ServiceJSON.array(["local",.string(profile),.string(extensionID)]).text }
  static func areaKey(_ extensionID: String, _ generation: String) -> String { extensionID + "/" + generation }
  static func bytes(_ key: String, _ value: ServiceJSON) throws -> Int { key.utf8.count + (try value.encoded()).count }
  static func quota(_ values: ServiceJSON) throws {
    guard values.object.count <= 512 else { throw ServiceError("QUOTA", "MAX_ITEMS quota exceeded.") }
    var total = 0
    for (key,value) in values.object {
      let size = try bytes(key,value)
      guard size <= 8192 else { throw ServiceError("QUOTA", "QUOTA_BYTES_PER_ITEM quota exceeded.") }
      total += size
    }
    guard total <= 102400 else { throw ServiceError("QUOTA", "QUOTA_BYTES quota exceeded.") }
  }
  static func difference(_ before: ServiceJSON, _ after: ServiceJSON) -> ServiceJSON {
    var result: ServiceJSON = [:]
    for key in Set(before.object.keys).union(after.object.keys) where before.object[key] != after.object[key] {
      var delta: ServiceJSON = [:]
      if before.contains(key) { delta["oldValue"] = before[key] }
      if after.contains(key) { delta["newValue"] = after[key] }
      result[key] = delta
    }
    return result
  }
  static func apply(_ values: ServiceJSON, _ payload: ServiceJSON, revisions: ServiceJSON = [:], base: Double = .infinity) -> ServiceJSON {
    var map = values.object
    if payload["clear"].bool { for key in map.keys where revisions[key].number <= base { map.removeValue(forKey: key) } }
    for key in payload["remove"].array { map.removeValue(forKey: key.string) }
    for (key,value) in payload["set"].object { map[key] = value }
    return .object(map)
  }
  static func keys(_ value: ServiceJSON) throws -> [String] {
    if case .string(let key) = value { return [key] }
    if case .array(let values) = value {
      return try values.map { guard case .string(let key) = $0 else { throw ServiceError("INPUT", "Expected a storage key or an array of keys.") }; return key }
    }
    throw ServiceError("INPUT", "Expected a storage key or an array of keys.")
  }
  static func storage(_ area: inout ServiceJSON, method: String, args: [ServiceJSON], trusted: Bool, now: Double) throws -> (result: ServiceJSON, changes: ServiceJSON, mutation: ServiceJSON?) {
    guard trusted || area["accessLevel"] != "TRUSTED_CONTEXTS" else { throw ServiceError("DENIED", "Access to sync storage is restricted to trusted extension contexts.") }
    let query = args.first ?? .null, values = area["values"]
    switch method {
    case "get":
      if query == .null { return (values,[:],nil) }
      if case .object(let defaults) = query {
        try query.validateDepth()
        return (.object(defaults.mapValues { $0 }.merging(values.object.filter { defaults[$0.key] != nil }) { _,v in v }),[:],nil)
      }
      let keys = try keys(query)
      return (.object(values.object.filter { keys.contains($0.key) }),[:],nil)
    case "getKeys": return (.array(values.object.keys.sorted().map(ServiceJSON.string)),[:],nil)
    case "getBytesInUse":
      let keys = query == .null ? Array(values.object.keys) : try keys(query)
      return (.number(Double(try keys.filter(values.contains).reduce(0) { try $0 + bytes($1, values[$1]) })),[:],nil)
    case "setAccessLevel":
      guard trusted, ["TRUSTED_CONTEXTS","TRUSTED_AND_UNTRUSTED_CONTEXTS"].contains(query["accessLevel"].string) else { throw ServiceError("DENIED", "Invalid storage access level.") }
      area["accessLevel"] = query["accessLevel"]; return (.null,[:],nil)
    default: break
    }
    let mutation: ServiceJSON
    switch method {
    case "set":
      guard case .object = query else { throw ServiceError("INPUT", "Expected a JSON value object.") }
      try query.validateDepth(); mutation = ["set":query]
    case "remove": mutation = ["remove":.array(Array(Set(try keys(query))).sorted().map(ServiceJSON.string))]
    case "clear": mutation = ["clear":true]
    default: throw ServiceError("INPUT", "Unsupported sync storage method.")
    }
    let next = apply(values,mutation); try quota(next)
    var writes = area["writes"].array.filter { now - $0.number < 3_600_000 && $0.number <= now }
    guard writes.filter({ now - $0.number < 60_000 }).count < 120 else { throw ServiceError("QUOTA", "MAX_WRITE_OPERATIONS_PER_MINUTE quota exceeded.") }
    guard writes.count < 1800 else { throw ServiceError("QUOTA", "MAX_WRITE_OPERATIONS_PER_HOUR quota exceeded.") }
    writes.append(.number(now)); area["writes"] = .array(writes); area["values"] = next
    return (.null,difference(values,next),mutation)
  }
  static func library(_ link: ServiceJSON) -> ServiceJSON {
    var records = link["library"]
    for op in link["outbox"].array where op["kind"] == "extension" {
      let current = records[op["extensionId"].string]
      if current != .null && (current["generation"] != op["generation"] || current["state"] == "removed") && op["baseRevision"].number < current["revision"].number { continue }
      let identity: ServiceJSON = ["extensionId":op["extensionId"],"generation":op["generation"],"revision":current["revision"] == .null ? 0 : current["revision"]]
      records[op["extensionId"].string] = identity.merging(op["payload"])
    }
    return records
  }
  static func visible(_ link: ServiceJSON, _ extensionID: String) -> ServiceJSON {
    let entry = library(link)[extensionID]
    guard entry != .null, entry["state"] != "removed", !link["detachedSettings"][extensionID].bool else { return [:] }
    let base = link["base"][areaKey(extensionID,entry["generation"].string)]
    var values = base["values"] == .null ? ServiceJSON.object([:]) : base["values"]
    for op in link["rejected"].array.map({ $0["operation"] }) + link["outbox"].array where op["kind"] == "settings" && op["extensionId"].string == extensionID && op["generation"] == entry["generation"] {
      values = apply(values,op["payload"],revisions: base["revisions"],base:op["baseRevision"].number)
    }
    return values
  }
  static func allVisible(_ link: ServiceJSON, syncedOnly: Bool = false) -> ServiceJSON {
    var result: ServiceJSON = [:]
    for (id,entry) in library(link).object {
      if syncedOnly && (entry["state"] == "removed" || link["detachedSettings"][id].bool) { continue }
      result[id] = visible(link,id)
    }
    return result
  }
  static func observed(_ link: ServiceJSON, areas: ServiceJSON, profile: String) -> ServiceJSON {
    var result = allVisible(link)
    for id in link["detachedSettings"].object.keys { result[id] = areas[localKey(profile,id)]["values"] == .null ? [:] : areas[localKey(profile,id)]["values"] }
    return result
  }
  static func independent(_ link: ServiceJSON, extensionID: String, values: ServiceJSON, local: ServiceJSON) -> ServiceJSON {
    let entry = library(link)[extensionID], key = areaKey(extensionID,entry["generation"].string)
    var area = link["areas"][key]
    if area == .null { area = local == .null ? emptyArea : local }
    area["values"] = values; return area
  }
  static func applyChange(_ link: inout ServiceJSON, _ change: ServiceJSON) {
    let id = change["extensionId"].string
    if change["kind"] == "extension" {
      let identity: ServiceJSON = ["extensionId":change["extensionId"],"generation":change["generation"],"revision":change["revision"]]
      link["library"][id] = identity.merging(change["payload"])
    } else if link["settingsSync"].bool && change["kind"] == "settings" {
      let key = areaKey(id,change["generation"].string)
      var base = link["base"][key], values = base["values"].object
      for (name,delta) in change["payload"]["changes"].object {
        if delta.contains("newValue") { values[name] = delta["newValue"] } else { values.removeValue(forKey:name) }
        base["revisions"][name] = change["revision"]
      }
      base["values"] = .object(values); link["base"][key] = base
    }
  }
  static func enqueueLibrary(_ link: inout ServiceJSON, _ item: ServiceJSON) throws {
    let id = item["extensionId"].string, state = item["state"]
    guard extensionID(id), item["source"]["kind"] == "web-store", item["source"]["id"].string == id, ["enabled","disabled","removed"].contains(state.string) else { throw ServiceError("SOURCE", "Only a verified portable extension source can synchronize.") }
    let current = library(link)[id]
    if current["state"] == state { return }
    let generation = current == .null || current["state"] == "removed" && state != "removed" ? ServiceJSON.string(UUID().uuidString) : current["generation"]
    let op: ServiceJSON = ["id":.string(UUID().uuidString),"kind":"extension","extensionId":.string(id),"generation":generation,"baseRevision":link["cursor"],"payload":["source":["kind":"web-store","id":.string(id)],"state":state]]
    link["outbox"] = .array(link["outbox"].array + [op])
  }
}

public struct ExtensionStorageContext: Sendable {
  public var profileID: String
  public var extensionID: String
  public var isPrivate: Bool
  public var enabled: Bool
  public var permissions: Set<String>
  public var trusted: Bool
  public init(profileID: String, extensionID: String, isPrivate: Bool = false, enabled: Bool = true, permissions: Set<String>, trusted: Bool) {
    self.profileID = profileID; self.extensionID = extensionID; self.isPrivate = isPrivate; self.enabled = enabled; self.permissions = permissions; self.trusted = trusted
  }
}
