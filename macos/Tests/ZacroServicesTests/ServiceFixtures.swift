import Foundation
import XCTest
@testable import ZacroServices

func expectEqual<T:Equatable>(_ actual:T,_ expected:T,file:StaticString = #filePath,line:UInt = #line) { XCTAssertEqual(actual,expected,file:file,line:line) }
func expectTrue(_ actual:Bool,file:StaticString = #filePath,line:UInt = #line) { XCTAssertTrue(actual,file:file,line:line) }
func expectFalse(_ actual:Bool,file:StaticString = #filePath,line:UInt = #line) { XCTAssertFalse(actual,file:file,line:line) }
func expectGreater<T:Comparable>(_ actual:T,_ expected:T,file:StaticString = #filePath,line:UInt = #line) { XCTAssertGreaterThan(actual,expected,file:file,line:line) }

final class MemorySecrets: NativeSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String:Data] = [:]
  private(set) var reads = 0
  var unavailable = false
  func read(_ key: String) throws -> Data? { try lock.withLock { reads += 1; if unavailable { throw ServiceError("LOCKED","Locked") }; return values[key] } }
  func write(_ bytes: Data,key: String) throws { try lock.withLock { if unavailable { throw ServiceError("LOCKED","Locked") }; values[key] = bytes } }
  func remove(_ key: String) throws { try lock.withLock { if unavailable { throw ServiceError("LOCKED","Locked") }; values.removeValue(forKey:key) } }
}
actor FixtureTransport: ServiceHTTPTransport {
  var response: ServiceJSON
  var calls: [ServiceHTTPRequest] = []
  var delay = Duration.zero
  init(_ response: ServiceJSON) { self.response = response }
  func setDelay(_ delay: Duration) { self.delay = delay }
  func send(_ request: ServiceHTTPRequest) async throws -> ServiceHTTPResponse {
    calls.append(request); try await Task.sleep(for:delay); return ServiceHTTPResponse(status:200,body:response)
  }
}
actor FixtureProfile {
  var id = "personal", isPrivate = false
  func change(_ id: String, privateMode: Bool = false) { self.id = id; isPrivate = privateMode }
  func current() -> AIProfileScope { AIProfileScope(id:id,isPrivate:isPrivate) }
}
actor FixtureSubscription: AISubscriptionConnection {
  var calls: [(messages:[ServiceJSON],research:Bool)] = []
  var delay = Duration.zero
  var configured = true
  var loginPending = false, cancelLoginCount = 0
  func status() -> ServiceJSON { ["available":true,"configured":.bool(configured),"loginPending":.bool(loginPending),"models":[["id":"model","isDefault":true]]] }
  func refresh() -> ServiceJSON { status() }
  func login() -> URL? { loginPending = true; return nil }
  func cancelLogin() { loginPending = false; cancelLoginCount += 1 }
  func logout() { configured = false }
  func setStorage(_ value: String) {}
  func setDelay(_ delay: Duration) { self.delay = delay }
  func run(model: String,instructions: String,messages: [ServiceJSON],research: Bool,onDelta: @escaping @Sendable (String) async -> Void) async throws -> ServiceJSON {
    calls.append((messages,research)); await onDelta("Partial "); try await Task.sleep(for:delay)
    return ["answer":"Evidence [1:1]","sources":[],"citations":[],"historyContent":"Evidence [1:1]","usage":[:]]
  }
  func close() {}
}
actor FixtureSyncServer: ServiceHTTPTransport {
  static let extensionID = String(repeating:"a",count:32)
  var revision = 0
  var library: [String:ServiceJSON] = [:], values: [String:ServiceJSON] = [:], revisions: [String:ServiceJSON] = [:]
  var changes: [ServiceJSON] = [], accepted: [String:ServiceJSON] = [:], calls: [ServiceHTTPRequest] = []
  var offline = false, loseAcknowledgement = false, rejectSettings = false
  var snapshotDelay = Duration.zero
  func setOffline(_ value: Bool) { offline = value }
  func setLostAcknowledgement(_ value: Bool) { loseAcknowledgement = value }
  func setRejectSettings(_ value: Bool) { rejectSettings = value }
  func setSnapshotDelay(_ delay: Duration) { snapshotDelay = delay }
  func send(_ request: ServiceHTTPRequest) async throws -> ServiceHTTPResponse {
    calls.append(request)
    if offline { throw ServiceError("NETWORK","Offline") }
    let path = request.url.path, body = request.body ?? [:]
    var result: ServiceJSON = [:]
    if path == "/v1/accounts" || path == "/v1/sessions" || path == "/v1/accounts/recover" {
      result = ["account":["id":body["username"].string.isEmpty ? "account" : body["username"],"username":body["username"]],"device":["id":"device","name":"Fixture Mac"],"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":9_000_000_000_000,"recoveryCodes":["fixture-recovery"]]
    } else if path == "/v1/sessions/refresh" {
      result = ["accessToken":"rotated-access","refreshToken":"rotated-refresh","expiresAt":9_000_000_000_000]
    } else if path.hasSuffix("/snapshot") {
      // Deliberately ignore cancellation to verify late responses cannot commit.
      try? await Task.sleep(for:snapshotDelay)
      result = ["dataset":["id":"dataset","name":"Synced","epoch":"epoch"],"extensions":.array(Array(library.values)),"settings":.array(values.map { key,value in
        let bits = key.split(separator:"/").map(String.init)
        return ["extensionId":.string(bits[0]),"generation":.string(bits[1]),"values":value,"revisions":revisions[key] ?? [:]]
      }),"cursor":.number(Double(revision))]
    } else if path.hasSuffix("/changes") {
      let query = URLComponents(url:request.url,resolvingAgainstBaseURL:false)!.queryItems ?? []
      let after = Int(query.first(where:{$0.name == "after"})?.value ?? "0") ?? 0
      let includeSettings = query.first(where:{$0.name == "settings"})?.value != "0"
      result = ["changes":.array(changes.filter { $0["revision"].int > after && (includeSettings || $0["kind"] != "settings") }),"cursor":.number(Double(revision)),"through":.number(Double(revision)),"hasMore":false]
    } else if path.hasSuffix("/operations") {
      var results: [ServiceJSON] = []
      for op in body["operations"].array {
        let id = op["id"].string
        if let old = accepted[id] { results.append(old.merging(["status":"duplicate"])); continue }
        if rejectSettings && op["kind"] == "settings" { results.append(["id":op["id"],"status":"quota","code":"storage_quota"]); continue }
        revision += 1
        var change = op.removing("id","baseRevision"); change["revision"] = .number(Double(revision))
        if op["kind"] == "extension" {
          let identity: ServiceJSON = ["extensionId":op["extensionId"],"generation":op["generation"],"revision":.number(Double(revision))]
          library[op["extensionId"].string] = identity.merging(op["payload"])
        } else {
          let key = op["extensionId"].string + "/" + op["generation"].string, old = values[key] ?? [:]
          let next = SyncModel.apply(old,op["payload"],revisions:revisions[key] ?? [:],base:op["baseRevision"].number)
          let difference = SyncModel.difference(old,next); values[key] = next
          for name in difference.object.keys { revisions[key,default:[:]][name] = .number(Double(revision)) }
          change["payload"] = ["changes":difference]
        }
        changes.append(change)
        let response: ServiceJSON = ["id":op["id"],"status":"applied","revision":.number(Double(revision))]
        accepted[id] = response; results.append(response)
      }
      if loseAcknowledgement { loseAcknowledgement = false; throw ServiceError("NETWORK","Acknowledgement lost") }
      result = ["results":.array(results),"revision":.number(Double(revision))]
    }
    return ServiceHTTPResponse(status:200,body:result)
  }
}
