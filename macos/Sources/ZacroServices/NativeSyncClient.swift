import Foundation

/// Actor-serialized durable state, with each request bound to a specific account and profile link.
/// The service and extension adapters consume events only after their transaction has been saved.
public actor NativeSyncClient {
  public typealias ProfileReader = @Sendable (String) async -> AIProfileScope?
  public typealias ActiveProfileReader = @Sendable () async -> AIProfileScope?
  public typealias LibraryReader = @Sendable (String) async throws -> [ServiceJSON]
  private let profileReader: ProfileReader, activeProfile: ActiveProfileReader, localLibrary: LibraryReader
  private let transport: any ServiceHTTPTransport, secrets: any NativeSecretStore
  private let file: URL, credentialKey: String
  private let allowInsecureLoopback: Bool, autoSync: Bool
  private let now: @Sendable () -> Double
  private var saved: ServiceJSON
  private var credentials: ServiceJSON?
  private var connectionState = "signed-out", epoch = 0, failures = 0, closed = false
  private var intents: [String:Int] = [:]
  private var requests: [UUID:(profile: String?, task: Task<ServiceHTTPResponse,Error>)] = [:]
  private var refreshing: (id: UUID, task: Task<Void,Error>)?
  private var running: (id: UUID, task: Task<ServiceJSON,Never>)?
  private var timer: Task<Void,Never>?
  private var subscribers: [UUID:AsyncStream<ServiceJSON>.Continuation] = [:]

  public init(directory: URL, getProfile: @escaping ProfileReader, activeProfile: @escaping ActiveProfileReader,
              localLibrary: @escaping LibraryReader = { _ in [] },
              transport: any ServiceHTTPTransport = NativeServiceHTTPTransport(), secrets: any NativeSecretStore = KeychainSecretStore(),
              allowInsecureLoopback: Bool = false, autoSync: Bool = true,
              now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
    profileReader = getProfile; self.activeProfile = activeProfile; self.localLibrary = localLibrary
    self.transport = transport; self.secrets = secrets; self.allowInsecureLoopback = allowInsecureLoopback
    self.autoSync = autoSync; self.now = now; file = directory.appendingPathComponent("sync-client.json")
    credentialKey = "sync-" + ServiceFiles.hash(directory.standardizedFileURL.path)
    saved = try ServiceFiles.read(file) ?? ["version":1,"areas":[:],"links":[:],"endpoint":"","account":.null]
    guard saved["version"] == 1 else { throw ServiceError("STORAGE", "Unsupported synchronization data version. The saved file has been preserved.") }
  }
  /// Explicit startup work is asynchronous; constructing the service never blocks the main thread on Keychain.
  public func start() async {
    guard !closed else { return }
    do {
      if let bytes = try secrets.read(credentialKey) {
        let value = try ServiceJSON.decode(bytes)
        guard value["version"] == 1, value["endpoint"] == saved["endpoint"], value["account"]["id"] == saved["account"]["id"], !value["device"]["id"].string.isEmpty, !value["accessToken"].string.isEmpty, !value["refreshToken"].string.isEmpty else { throw ServiceError("AUTH", "Reconnect this account.") }
        credentials = value; connectionState = "connected"
      } else if saved["account"] != .null { try detach("reconnect-required") }
    } catch { credentials = nil; connectionState = "reconnect-required" }
    schedule(100); notify()
  }
  public func events() -> AsyncStream<ServiceJSON> {
    let id = UUID()
    return AsyncStream { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
    }
  }
  private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey:id) }
  private func emit(_ value: ServiceJSON) { guard !closed else { return }; for s in subscribers.values { s.yield(value) } }
  private func notify() { emit(["type":"sync:status","status":status()]) }
  public func status() -> ServiceJSON {
    let profiles: [ServiceJSON] = saved["links"].object.sorted(by: { $0.key < $1.key }).map { id,link in
      ["profileId":.string(id),"linkId":link["id"],"datasetId":link["datasetId"],"name":link["name"],"librarySync":.bool(link["librarySync"] != false),"settingsSync":link["settingsSync"],"pending":.number(Double(link["outbox"].array.count)),
       "rejected":.array(link["rejected"].array.map { ["id":$0["operation"]["id"],"extensionId":$0["operation"]["extensionId"],"kind":$0["operation"]["kind"],"code":$0["code"]] }),"lastSync":link["lastSync"]]
    }
    return ["endpoint":saved["endpoint"],"account":credentials == nil ? .null : saved["account"],"device":credentials?["device"] ?? .null,"state":.string(saved["endpoint"].string.isEmpty ? "setup-required" : connectionState),"profiles":.array(profiles)]
  }
  /// Window-scoped presentation without changing the shared account or active profile.
  public func status(profileID: String) async -> ServiceJSON {
    guard let profile = await profileReader(profileID), profile.id == profileID, !profile.isPrivate,
      !saved["retiredProfiles"].array.contains(.string(profileID)), !closed else {
      return ["endpoint":saved["endpoint"],"account":.null,"device":.null,"profiles":[],"state":"private"]
    }
    return status()
  }
  private func transaction<T>(_ action: (inout ServiceJSON) throws -> T) throws -> T {
    var next = saved; let result = try action(&next)
    try ServiceFiles.write(next,file:file); saved = next; return result
  }
  private static func endpoint(_ input: String, allowLoopback: Bool) throws -> String {
    guard !input.contains(where: { $0.isWhitespace || $0.isNewline }), !input.contains("\\"), var c = URLComponents(string:input), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      c.path.isEmpty || c.path == "/", let host = c.host, !host.isEmpty,
      c.scheme == "https" || (allowLoopback && c.scheme == "http" && ["127.0.0.1","[::1]","::1"].contains(host)) else { throw ServiceError("ENDPOINT", "The service endpoint must be an HTTPS origin (explicit loopback development is allowed).") }
    c.path = ""; guard let endpoint = c.url?.absoluteString else { throw ServiceError("ENDPOINT", "Invalid service endpoint.") }; return endpoint
  }
  private func guardEpoch(_ expected: Int) throws {
    guard !closed, expected == epoch, !Task.isCancelled else { throw ServiceError("cancelled", "The synchronization context changed.") }
  }
  private func profile(_ id: String) async throws {
    guard SyncModel.id(id), !saved["retiredProfiles"].array.contains(.string(id)), let profile = await profileReader(id), profile.id == id, !profile.isPrivate,
      !saved["retiredProfiles"].array.contains(.string(id)), !closed else { throw ServiceError("cancelled", "Private, unavailable, or partially deleted profiles cannot synchronize.") }
  }
  private func identity(_ profile: String, _ link: ServiceJSON) -> ServiceJSON { ["profileId":.string(profile),"linkId":link["id"],"endpoint":link["endpoint"],"accountId":link["accountId"]] }
  public func isCurrentLink(_ identity: ServiceJSON) -> Bool {
    let id = identity["profileId"].string
    return !closed && credentials != nil && !saved["retiredProfiles"].array.contains(.string(id)) && saved["links"][id]["id"] == identity["linkId"] && saved["endpoint"] == identity["endpoint"] && saved["account"]["id"] == identity["accountId"]
  }
  private func guardLink(_ identity: ServiceJSON?, epoch: Int) throws {
    try guardEpoch(epoch)
    if let identity { guard isCurrentLink(identity) else { throw ServiceError("cancelled", "The synchronization context changed.") } }
  }
  public func invalidate() {
    epoch += 1; timer?.cancel(); timer = nil; running?.task.cancel(); running = nil
    refreshing?.task.cancel(); refreshing = nil
    for request in requests.values { request.task.cancel() }; requests.removeAll()
  }
  public func profileChanged() { invalidate(); schedule(100) }
  private func cancelProfile(_ profile: String) {
    intents[profile,default:0] += 1
    for (id,request) in requests where request.profile == profile { request.task.cancel(); requests.removeValue(forKey:id) }
  }
  public func configure(endpoint: String) throws -> ServiceJSON {
    let normalized = endpoint.isEmpty ? "" : try Self.endpoint(endpoint,allowLoopback:allowInsecureLoopback)
    if saved["endpoint"].string == normalized { return status() }
    try detach("signed-out"); try transaction { $0["endpoint"] = .string(normalized) }; notify(); return status()
  }
  private func raw(_ route: String, method: String = "GET", body: ServiceJSON? = nil, token: String? = nil, epoch expected: Int,
                   profileID: String? = nil, identity: ServiceJSON? = nil, retryRead: Bool = true) async throws -> ServiceJSON {
    try guardLink(identity,epoch:expected)
    guard let url = URL(string:saved["endpoint"].string + "/v1" + route), !saved["endpoint"].string.isEmpty else { throw ServiceError("SETUP", "Set up a synchronization service first.") }
    let id = UUID(), transport = self.transport
    let request = ServiceHTTPRequest(url:url,method:method,headers:token.map { ["Authorization":"Bearer " + $0] } ?? [:],body:body,timeout:15,maximumBytes:64 * 1024 * 1024)
    let task = Task { try await transport.send(request) }; requests[id] = (profileID,task)
    defer { requests.removeValue(forKey:id) }
    let response: ServiceHTTPResponse
    do { response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
    catch {
      try guardLink(identity,epoch:expected)
      if retryRead && method == "GET" && (error as? ServiceError)?.code == "CONNECTION_RESET" {
        return try await raw(route,method:method,body:body,token:token,epoch:expected,profileID:profileID,identity:identity,retryRead:false)
      }
      throw error
    }
    try guardLink(identity,epoch:expected)
    guard (200..<300).contains(response.status) else {
      throw ServiceError(String(response.body["error"]["code"].string.prefix(100)), String(response.body["error"]["message"].string.prefix(500)).isEmpty ? "The synchronization request failed." : String(response.body["error"]["message"].string.prefix(500)), status:response.status)
    }
    return response.body
  }
  private func saveCredentials(_ value: ServiceJSON) throws { try secrets.write(value.merging(["version":1]).encoded(),key:credentialKey) }
  private func refresh(_ expected: Int) async throws {
    if let refreshing { try await refreshing.task.value; return }
    guard let credentials, !credentials["refreshToken"].string.isEmpty else { throw ServiceError("AUTH", "Sign in to synchronize.") }
    let id = UUID(), token = credentials["refreshToken"]
    let task = Task { [weak self] in
      guard let self else { throw ServiceError("cancelled", "The synchronization context changed.") }
      try await self.performRefresh(token,epoch:expected)
    }
    refreshing = (id,task)
    defer { if refreshing?.id == id { refreshing = nil } }
    try await task.value
  }
  private func performRefresh(_ token: ServiceJSON, epoch expected: Int) async throws {
    let result = try await raw("/sessions/refresh",method:"POST",body:["refreshToken":token],epoch:expected)
    try guardEpoch(expected)
    guard let old = credentials, !result["accessToken"].string.isEmpty, !result["refreshToken"].string.isEmpty else { throw ServiceError("PROTOCOL", "Invalid account refresh response.") }
    let next = old.merging(result); try saveCredentials(next); credentials = next
  }
  private func request(_ route: String, method: String = "GET", body: ServiceJSON? = nil, epoch expected: Int? = nil,
                       profileID: String? = nil, identity: ServiceJSON? = nil) async throws -> ServiceJSON {
    let expected = expected ?? epoch; try guardLink(identity,epoch:expected)
    guard credentials != nil else { throw ServiceError("AUTH", "Sign in to synchronize.") }
    do {
      if credentials!["expiresAt"].number <= now() + 30_000 { try await refresh(expected) }
      try guardLink(identity,epoch:expected)
      return try await raw(route,method:method,body:body,token:credentials?["accessToken"].string,epoch:expected,profileID:profileID,identity:identity)
    } catch let error as ServiceError {
      if error.status == 401 && epoch == expected { try detach("reconnect-required") }; throw error
    }
  }
  private func copyLocal(_ state: inout ServiceJSON, profile: String, link: ServiceJSON) {
    guard link["settingsSync"].bool else { return }
    for (id,values) in SyncModel.allVisible(link,syncedOnly:true).object {
      let key = SyncModel.localKey(profile,id)
      state["areas"][key] = SyncModel.independent(link,extensionID:id,values:values,local:state["areas"][key])
    }
  }
  private func detach(_ state: String) throws {
    invalidate()
    try transaction { next in
      for (profile,link) in next["links"].object { copyLocal(&next,profile:profile,link:link) }
      if !next["localOwner"].string.isEmpty { next["localCopies"][next["localOwner"].string] = next["areas"] }
      next["links"] = [:]; next["account"] = .null
    }
    credentials = nil; connectionState = state
    try secrets.remove(credentialKey); notify()
  }
  public func authenticate(_ kind: String, fields: ServiceJSON) async throws -> ServiceJSON {
    let route: String
    switch kind { case "register":route = "/accounts"; case "login":route = "/sessions"; case "recover":route = "/accounts/recover"; default:throw ServiceError("INPUT","Unknown account action.") }
    // Probe OS protection before sending a password. This item contains only a random challenge.
    let probeKey = credentialKey + "-probe", probe = Data(UUID().uuidString.utf8)
    try secrets.write(probe,key:probeKey)
    do { guard try secrets.read(probeKey) == probe else { throw ServiceError("AUTH_STORAGE", "OS credential protection is unavailable. Sign-in is disabled.") }; try secrets.remove(probeKey) }
    catch { try? secrets.remove(probeKey); throw error }
    try detach("signed-out"); let expected = epoch
    let result = try await raw(route,method:"POST",body:fields,epoch:expected); try guardEpoch(expected)
    var value = result.removing("recoveryCodes")
    guard !value["account"]["id"].string.isEmpty, !value["device"]["id"].string.isEmpty, !value["accessToken"].string.isEmpty, !value["refreshToken"].string.isEmpty else { throw ServiceError("PROTOCOL", "Invalid account response.") }
    value["endpoint"] = saved["endpoint"]; try saveCredentials(value)
    do {
      try transaction { state in
        let owner = ServiceJSON.array([state["endpoint"],value["account"]["id"]]).text
        if !state["localOwner"].string.isEmpty && state["localOwner"].string != owner { state["areas"] = state["localCopies"][owner] == .null ? [:] : state["localCopies"][owner] }
        state["localOwner"] = .string(owner); state["account"] = value["account"]
      }
    } catch { try? secrets.remove(credentialKey); throw error }
    credentials = value; connectionState = "connected"; schedule(100); notify()
    var response: ServiceJSON = ["account":value["account"],"device":value["device"]]
    if result.contains("recoveryCodes") { response["recoveryCodes"] = result["recoveryCodes"] }; return response
  }
  public func logout() async throws -> ServiceJSON {
    let previous = credentials, endpoint = saved["endpoint"].string; try detach("signed-out")
    if let previous, let url = URL(string:endpoint + "/v1/sessions/current") {
      _ = try? await transport.send(ServiceHTTPRequest(url:url,method:"DELETE",headers:["Authorization":"Bearer " + previous["accessToken"].string],timeout:10))
    }
    return status()
  }
  public func close() {
    invalidate(); closed = true; credentials = nil
    for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll()
  }

  public func handle(_ action: String, payload: ServiceJSON = [:], expectedProfileID: String? = nil) async throws -> ServiceJSON {
    let active = await activeProfile()
    guard expectedProfileID == nil || active?.id == expectedProfileID else {
      throw ServiceError("cancelled", "The active profile changed. Open these controls again.")
    }
    if action == "sync:status" {
      if active?.isPrivate != false { return ["endpoint":saved["endpoint"],"account":.null,"device":.null,"profiles":[],"state":"private"] }; return status()
    }
    guard let active, !active.isPrivate else { throw ServiceError("PRIVATE", "Account and synchronization controls are unavailable in private profiles.") }
    try await profile(active.id)
    guard let current = await activeProfile(), current.id == active.id, !current.isPrivate else {
      throw ServiceError("cancelled", "The active profile changed. Open these controls again.")
    }
    guard !payload.contains("profileId") || payload["profileId"].string == active.id else { throw ServiceError("cancelled", "The active profile changed. Open these controls again.") }
    let result: ServiceJSON
    switch action {
    case "sync:configure": result = try configure(endpoint:payload["endpoint"].string)
    case "sync:register", "sync:login", "sync:recover":
      let fields: ServiceJSON = action == "sync:recover"
        ? ["username":payload["username"],"recoveryCode":payload["recoveryCode"],"newPassword":payload["newPassword"],"deviceName":payload["deviceName"],"platform":"darwin"]
        : ["username":payload["username"],"password":payload["password"],"deviceName":payload["deviceName"],"platform":"darwin"]
      result = try await authenticate(String(action.dropFirst(5)),fields:fields)
    case "sync:logout": result = try await logout()
    case "sync:devices": result = try await request("/devices")["devices"]
    case "sync:rename-device":
      result = try await request("/devices/" + Self.pathID(payload["id"]),method:"PATCH",body:["name":payload["name"]])
      if var value = credentials, value["device"]["id"] == payload["id"] { value["device"]["name"] = payload["name"]; try saveCredentials(value); credentials = value }; notify()
    case "sync:revoke-device":
      result = try await request("/devices/" + Self.pathID(payload["id"]),method:"DELETE")
      if credentials?["device"]["id"] == payload["id"] { try detach("reconnect-required") }
    case "sync:password":
      _ = try await request("/account/password",method:"POST",body:["password":payload["password"],"newPassword":payload["newPassword"]]); result = ["changed":true]
    case "sync:recovery-codes": result = try await request("/account/recovery-codes",method:"POST",body:["password":payload["password"]])
    case "sync:delete-account":
      guard payload["confirm"].bool else { throw ServiceError("CONSENT", "Confirm account deletion.") }
      _ = try await request("/account",method:"DELETE",body:["password":payload["password"],"confirm":true]); try detach("signed-out"); result = .null
    case "sync:datasets": result = try await request("/datasets")["datasets"]
    case "sync:create-dataset": result = try await request("/datasets",method:"POST",body:["name":payload["name"]])
    case "sync:delete-dataset":
      guard payload["confirm"].bool else { throw ServiceError("CONSENT", "Confirm dataset deletion.") }
      _ = try await request("/datasets/" + Self.pathID(payload["id"]),method:"DELETE",body:["password":payload["password"],"confirm":true])
      for (profile,link) in saved["links"].object where link["datasetId"] == payload["id"] { _ = try await unlinkProfile(profile) }; result = .null
    case "sync:link-preview":
      let snapshot = try await request("/datasets/" + Self.pathID(payload["datasetId"]) + "/snapshot?settings=0",profileID:active.id)
      let library = try await localLibrary(active.id)
      result = ["dataset":snapshot["dataset"],"extensions":snapshot["extensions"],"settingsAvailable":.bool(!snapshot["settings"].array.isEmpty),"localExtensions":.array(library)]
    case "sync:link":
      let library = try await localLibrary(active.id)
      result = try await linkProfile(active.id,options:payload.merging(["localLibrary":.array(library)]))
    case "sync:unlink": result = try await unlinkProfile(active.id)
    case "sync:library":
      let library = try await localLibrary(active.id)
      result = try await setLibrarySync(active.id,enabled:payload["enabled"].bool,options:payload.merging(["localLibrary":.array(library)]))
    case "sync:settings": result = try await setSettingsSync(active.id,enabled:payload["enabled"].bool,options:payload)
    case "sync:now": result = await syncNow()
    case "sync:retry": try await retryRejected(active.id,id:payload["id"].string); result = .null
    case "sync:discard": try await discardRejected(active.id,id:payload["id"].string); result = .null
    // The native UI chooses the destination with NSSavePanel and writes only after a fresh profile guard.
    case "sync:export": result = try await exportRejected(active.id,id:payload["id"].string)
    default: throw ServiceError("INPUT", "Unsupported synchronization action.")
    }
    guard let current = await activeProfile(), current.id == active.id, !current.isPrivate else { throw ServiceError("cancelled", "The active profile changed. Open these controls again.") }; return result
  }
  private static func pathID(_ value: ServiceJSON) throws -> String {
    guard SyncModel.id(value.string) else { throw ServiceError("INPUT", "Invalid synchronization identifier.") }; return value.string
  }
  public func extensionIntents(profileID: String) async throws -> [ServiceJSON] {
    try await profile(profileID); let link = saved["links"][profileID]
    guard link != .null, link["librarySync"] != false, credentials != nil else { return [] }
    return SyncModel.library(link).object.values.map { identity(profileID,link).merging(["extension":$0]) }
  }
  public func isCurrentExtensionIntent(_ intent: ServiceJSON) -> Bool {
    guard isCurrentLink(intent) else { return false }
    let link = saved["links"][intent["profileId"].string], item = intent["extension"]
    let current = SyncModel.library(link)[item["extensionId"].string]
    return link["librarySync"] != false && current != .null &&
      current["generation"] == item["generation"] && current["state"] == item["state"] && current["source"] == item["source"]
  }
  /// A full desired state is needed after restart or a missed native event. It
  /// also binds each apply to the reviewed link and current installation generation.
  public func nativeStorageProjections(profileID: String) async throws -> [ServiceJSON] {
    try await profile(profileID)
    let link = saved["links"][profileID]
    guard credentials != nil, link["settingsSync"].bool else { return [] }
    return SyncModel.library(link).object.values.filter {
      $0["state"] != "removed" && !link["detachedSettings"][$0["extensionId"].string].bool
    }.map { entry in
      identity(profileID, link).merging(["extensionId":entry["extensionId"], "generation":entry["generation"],
        "values":SyncModel.visible(link, entry["extensionId"].string)])
    }
  }
  public func isCurrentNativeStorageProjection(_ projection: ServiceJSON) -> Bool {
    guard isCurrentLink(projection) else { return false }
    let link = saved["links"][projection["profileId"].string], id = projection["extensionId"].string
    let entry = SyncModel.library(link)[id]
    return link["settingsSync"].bool && entry != .null && entry["state"] != "removed" &&
      !link["detachedSettings"][id].bool && entry["generation"] == projection["generation"] &&
      SyncModel.visible(link, id) == projection["values"]
  }
  public func linkProfile(_ profileID: String, options: ServiceJSON) async throws -> ServiceJSON {
    try await profile(profileID)
    let datasetID = try Self.pathID(options["datasetId"]), settings = options["settingsSync"].bool, libraryEnabled = options["librarySync"] != false
    guard ["remote-only","merge-local"].contains(options["libraryChoice"].string) else { throw ServiceError("CONSENT", "Review and choose the extension library changes first.") }
    guard !settings || options["settingsConsent"].bool && ["upload-local","use-remote"].contains(options["settingsChoice"].string) else { throw ServiceError("CONSENT", "Settings synchronization requires explicit consent and a local/remote choice.") }
    let expected = epoch, before = saved, oldID = saved["links"][profileID]["id"]
    intents[profileID,default:0] += 1; let intent = intents[profileID]
    guard !saved["links"].object.contains(where: { $0.key != profileID && $0.value["datasetId"].string == datasetID }) else { throw ServiceError("LINKED", "This dataset is already linked to another local profile.") }
    let snapshot = try await request("/datasets/" + datasetID + "/snapshot?settings=" + (settings ? "1" : "0"),epoch:expected,profileID:profileID)
    try await profile(profileID); try guardEpoch(expected)
    guard intents[profileID] == intent, saved["links"][profileID]["id"] == oldID, snapshot["dataset"]["id"].string == datasetID,
      SyncModel.id(snapshot["dataset"]["epoch"].string), Self.revision(snapshot["cursor"]) else { throw ServiceError("cancelled", "The synchronization context changed or its snapshot was invalid.") }
    var link: ServiceJSON = ["id":.string(UUID().uuidString),"datasetId":.string(datasetID),"name":snapshot["dataset"]["name"],"epoch":snapshot["dataset"]["epoch"],"endpoint":before["endpoint"],"accountId":before["account"]["id"],"librarySync":.bool(libraryEnabled),"settingsSync":.bool(settings),"cursor":snapshot["cursor"],"library":[:],"base":[:],"areas":[:],"outbox":[],"rejected":[]]
    for entry in snapshot["extensions"].array { try Self.validateEntry(entry); link["library"][entry["extensionId"].string] = entry }
    for area in snapshot["settings"].array {
      guard SyncModel.extensionID(area["extensionId"].string), SyncModel.id(area["generation"].string) else { throw ServiceError("PROTOCOL", "Invalid extension settings snapshot.") }
      try SyncModel.quota(area["values"])
      link["base"][SyncModel.areaKey(area["extensionId"].string,area["generation"].string)] = ["values":area["values"],"revisions":area["revisions"]]
    }
    try transaction { state in
      let previous = state["links"][profileID]; copyLocal(&state,profile:profileID,link:previous)
      if options["preserveLibrary"].bool && previous["datasetId"].string == datasetID {
        link["outbox"] = .array(previous["outbox"].array.filter { $0["kind"] == "extension" })
        link["rejected"] = .array(previous["rejected"].array.filter { $0["operation"]["kind"] == "extension" })
      }
      if options["preserveSettings"].bool && settings && previous["settingsSync"].bool && previous["datasetId"].string == datasetID {
        link["areas"] = previous["areas"]
        link["outbox"] = .array(link["outbox"].array + previous["outbox"].array.filter { $0["kind"] == "settings" })
        link["rejected"] = .array(link["rejected"].array + previous["rejected"].array.filter { $0["operation"]["kind"] == "settings" })
      }
      if libraryEnabled && options["libraryChoice"] == "merge-local" { for item in options["localLibrary"].array { try SyncModel.enqueueLibrary(&link,item) } }
      if settings && (options["preserveSettings"].bool || options["settingsChoice"] == "upload-local") {
        for entry in SyncModel.library(link).object.values where entry["state"] != "removed" {
          let id = entry["extensionId"].string
          if options["preserveSettings"].bool && link["library"][id]["generation"] == entry["generation"] { continue }
          let values = state["areas"][SyncModel.localKey(profileID,id)]["values"]
          if !values.object.isEmpty {
            let operation: ServiceJSON = ["id":.string(UUID().uuidString),"kind":"settings","extensionId":.string(id),"generation":entry["generation"],"baseRevision":link["cursor"],"payload":["set":values]]
            link["outbox"] = .array(link["outbox"].array + [operation])
          }
        }
      }
      state["links"][profileID] = link
    }
    cancelProfile(profileID)
    for entry in SyncModel.library(link).object.values { emitLibrary(profileID,link,entry) }
    if settings {
      for (id,values) in SyncModel.allVisible(link).object {
        let previous = before["links"][profileID]
        let old = previous["settingsSync"].bool && !previous["detachedSettings"][id].bool && SyncModel.library(previous)[id]["state"] != "removed" ? SyncModel.visible(previous,id) : before["areas"][SyncModel.localKey(profileID,id)]["values"]
        emitStorage(profileID,link,id,SyncModel.difference(old,values))
      }
    }
    schedule(100); notify(); return status()
  }
  public func unlinkProfile(_ profileID: String) async throws -> ServiceJSON {
    try await profile(profileID)
    try transaction { state in
      let link = state["links"][profileID]; copyLocal(&state,profile:profileID,link:link)
      state["links"] = state["links"].removing(profileID)
    }
    cancelProfile(profileID); notify(); return status()
  }
  public func deleteLocalProfile(_ profileID: String) async throws {
    if !saved["retiredProfiles"].array.contains(.string(profileID)) { try await profile(profileID) }
    try transaction { state in
      state["links"] = state["links"].removing(profileID)
      func purge(_ areas: ServiceJSON) -> ServiceJSON {
        .object(areas.object.filter { key,_ in
          guard let value = try? ServiceJSON.decode(Data(key.utf8)) else { return true }
          return value.array.count < 2 || value.array[0] != "local" || value.array[1].string != profileID
        })
      }
      state["areas"] = purge(state["areas"])
      state["nativeStorage"] = purge(state["nativeStorage"])
      state["localCopies"] = .object(state["localCopies"].object.mapValues(purge))
      state["retiredProfiles"] = .array(Array(Set(state["retiredProfiles"].array.map(\.string) + [profileID])).sorted().map(ServiceJSON.string))
    }
    cancelProfile(profileID); notify()
  }
  /// A reversible barrier before the browser's own profile transaction commits.
  public func prepareLocalProfileDeletion(_ profileID: String) async throws {
    if saved["retiredProfiles"].array.contains(.string(profileID)) { return }
    try await profile(profileID)
    try transaction { state in
      state["retiredProfiles"] = .array(Array(Set(state["retiredProfiles"].array.map(\.string) + [profileID])).sorted().map(ServiceJSON.string))
    }
    cancelProfile(profileID); notify()
  }
  public func pendingProfileDeletionIDs() -> [String] { saved["retiredProfiles"].array.map(\.string) }
  public func cancelLocalProfileDeletion(_ profileID: String) async throws {
    guard let profile = await profileReader(profileID), profile.id == profileID, !profile.isPrivate else {
      throw ServiceError("PROFILE", "Only an existing browser profile can cancel deletion.")
    }
    try transaction { $0["retiredProfiles"] = .array($0["retiredProfiles"].array.filter { $0.string != profileID }) }
    schedule(100); notify()
  }
  public func completeLocalProfileDeletion(_ profileID: String) async throws {
    guard saved["retiredProfiles"].array.contains(.string(profileID)) else { return }
    guard await profileReader(profileID) == nil else { throw ServiceError("PROFILE", "The browser profile still exists; finish removing it first.") }
    // The same purge path also handles interruption between prepare and browser commit.
    try await deleteLocalProfile(profileID)
    try transaction { $0["retiredProfiles"] = .array($0["retiredProfiles"].array.filter { $0.string != profileID }) }
  }
  public func setSettingsSync(_ profileID: String, enabled: Bool, options: ServiceJSON) async throws -> ServiceJSON {
    try await profile(profileID); let link = saved["links"][profileID]
    guard link != .null else { throw ServiceError("LINK", "Link this profile before enabling synchronization.") }
    if enabled { return try await linkProfile(profileID,options:options.merging(["datasetId":link["datasetId"],"libraryChoice":"remote-only","librarySync":.bool(link["librarySync"] != false),"settingsSync":true,"preserveLibrary":true])) }
    try transaction { state in
      var link = state["links"][profileID]; copyLocal(&state,profile:profileID,link:link)
      link["id"] = .string(UUID().uuidString); link["settingsSync"] = false; link["base"] = [:]; link["areas"] = [:]
      link["outbox"] = .array(link["outbox"].array.filter { $0["kind"] == "extension" })
      link["rejected"] = .array(link["rejected"].array.filter { $0["operation"]["kind"] == "extension" }); state["links"][profileID] = link
    }
    cancelProfile(profileID); notify(); return status()
  }
  public func setLibrarySync(_ profileID: String, enabled: Bool, options: ServiceJSON) async throws -> ServiceJSON {
    try await profile(profileID); let link = saved["links"][profileID]
    guard link != .null else { throw ServiceError("LINK", "Link this profile before enabling synchronization.") }
    if enabled { return try await linkProfile(profileID,options:options.merging(["datasetId":link["datasetId"],"librarySync":true,"settingsSync":link["settingsSync"],"settingsChoice":"use-remote","settingsConsent":link["settingsSync"],"preserveSettings":true])) }
    try transaction { state in
      var link = state["links"][profileID]; let previous = SyncModel.library(link), values = SyncModel.allVisible(link)
      link["id"] = .string(UUID().uuidString); link["librarySync"] = false
      for (id,entry) in previous.object {
        let remote = link["library"][id]
        if link["settingsSync"].bool && entry["state"] != "removed" && !link["detachedSettings"][id].bool && (remote == .null || remote["state"] == "removed" || remote["generation"] != entry["generation"]) {
          let key = SyncModel.localKey(profileID,id)
          state["areas"][key] = SyncModel.independent(link,extensionID:id,values:values[id],local:state["areas"][key])
          Self.dropSettings(&link,extensionID:id)
        }
      }
      link["outbox"] = .array(link["outbox"].array.filter { $0["kind"] == "settings" })
      link["rejected"] = .array(link["rejected"].array.filter { $0["operation"]["kind"] == "settings" }); state["links"][profileID] = link
    }
    cancelProfile(profileID); schedule(100); notify(); return status()
  }
  private static func dropSettings(_ link: inout ServiceJSON, extensionID: String) {
    link["outbox"] = .array(link["outbox"].array.filter { $0["kind"] != "settings" || $0["extensionId"].string != extensionID })
    link["rejected"] = .array(link["rejected"].array.filter { $0["operation"]["kind"] != "settings" || $0["operation"]["extensionId"].string != extensionID })
  }
  public func queueExtension(profileID: String, item: ServiceJSON) async throws {
    try await profile(profileID)
    try transaction { state in
      var link = state["links"][profileID]
      if link != .null && link["librarySync"] != false { try SyncModel.enqueueLibrary(&link,item); state["links"][profileID] = link }
    }
    schedule(250); notify()
  }
  public func exportRejected(_ profileID: String, id: String) async throws -> ServiceJSON {
    try await profile(profileID)
    guard let rejected = saved["links"][profileID]["rejected"].array.first(where: { $0["operation"]["id"].string == id }) else { throw ServiceError("MISSING", "This unsynced change is no longer available.") }; return rejected["operation"]
  }
  public func retryRejected(_ profileID: String, id: String) async throws {
    try await profile(profileID)
    try transaction { state in
      var link = state["links"][profileID]
      guard let rejected = link["rejected"].array.first(where: { $0["operation"]["id"].string == id }) else { throw ServiceError("MISSING", "This unsynced change is no longer available.") }
      let entry = SyncModel.library(link)[rejected["operation"]["extensionId"].string]
      guard entry != .null, entry["state"] != "removed", entry["generation"] == rejected["operation"]["generation"] else { throw ServiceError("REMOVED", "This installation was removed. Reinstall it explicitly.") }
      link["outbox"] = .array(link["outbox"].array + [rejected["operation"].merging(["id":.string(UUID().uuidString),"baseRevision":link["cursor"]])])
      link["rejected"] = .array(link["rejected"].array.filter { $0["operation"]["id"].string != id }); state["links"][profileID] = link
    }
    schedule(100); notify()
  }
  public func discardRejected(_ profileID: String, id: String) async throws {
    try await profile(profileID)
    let event: (ServiceJSON,String,ServiceJSON) = try transaction { state in
      var link = state["links"][profileID]
      guard let rejected = link["rejected"].array.first(where: { $0["operation"]["id"].string == id }) else { throw ServiceError("MISSING", "This unsynced change is no longer available.") }
      let ext = rejected["operation"]["extensionId"].string, old = SyncModel.visible(link,ext)
      link["rejected"] = .array(link["rejected"].array.filter { $0["operation"]["id"].string != id }); state["links"][profileID] = link
      return (link,ext,SyncModel.difference(old,SyncModel.visible(link,ext)))
    }
    emitStorage(profileID,event.0,event.1,event.2); notify()
  }
  public func callStorage(_ context: ExtensionStorageContext, method: String, args: [ServiceJSON] = []) async throws -> ServiceJSON {
    try await profile(context.profileID); try Self.validateStorage(context)
    let response: (ServiceJSON,ServiceJSON?,ServiceJSON) = try transaction { state in
      var link = state["links"][context.profileID]; let entry = SyncModel.library(link)[context.extensionID]
      let linked = link["settingsSync"].bool && entry != .null && entry["state"] != "removed" && !link["detachedSettings"][context.extensionID].bool
      let localKey = SyncModel.localKey(context.profileID,context.extensionID)
      let key = linked ? SyncModel.areaKey(context.extensionID,entry["generation"].string) : localKey
      var area = linked ? link["areas"][key] : state["areas"][key]
      if area == .null { area = linked && state["areas"][localKey] != .null ? state["areas"][localKey] : SyncModel.emptyArea }
      if linked { area["values"] = SyncModel.visible(link,context.extensionID) }
      let response = try SyncModel.storage(&area,method:method,args:args,trusted:context.trusted,now:now())
      if linked {
        link["areas"][key] = area
        if let mutation = response.mutation, !response.changes.object.isEmpty {
          let operation: ServiceJSON = ["id":.string(UUID().uuidString),"kind":"settings","extensionId":.string(context.extensionID),"generation":entry["generation"],"baseRevision":link["cursor"],"payload":mutation]
          link["outbox"] = .array(link["outbox"].array + [operation])
        }
        state["links"][context.profileID] = link
      } else { state["areas"][key] = area }
      return (response.result,linked ? link : nil,response.changes)
    }
    emitStorage(context.profileID,response.1,context.extensionID,response.2)
    if response.1 != nil { schedule(250) }; notify(); return response.0
  }
  public func forgetNativeInstallation(profileID: String, extensionID: String) async throws {
    try await profile(profileID)
    guard SyncModel.extensionID(extensionID) else { throw ServiceError("INPUT", "Invalid extension identity.") }
    let key = SyncModel.localKey(profileID,extensionID)
    guard saved["nativeStorage"][key] != .null else { return }
    try transaction { $0["nativeStorage"] = $0["nativeStorage"].removing(key) }
  }
  /// Registry-authoritative cleanup prevents an old installation's baseline
  /// from being interpreted as edits made by a later reinstall of the same ID.
  public func pruneNativeStorage(profileID: String, installedIDs: Set<String>) async throws {
    try await profile(profileID)
    guard installedIDs.allSatisfy(SyncModel.extensionID) else { throw ServiceError("INPUT", "Invalid installed extension identity.") }
    let retained = ServiceJSON.object(saved["nativeStorage"].object.filter { key,_ in
      guard let parts = try? ServiceJSON.decode(Data(key.utf8)), parts.array.count == 3,
        parts.array[0] == "local", parts.array[1].string == profileID else { return true }
      return installedIDs.contains(parts.array[2].string)
    })
    if retained.object != saved["nativeStorage"].object { try transaction { $0["nativeStorage"] = retained } }
  }
  /// Called only for an installation observed in this live native registry, not
  /// for an ambiguous pre-existing record loaded during migration.
  public func adoptNativeInstallation(_ context: ExtensionStorageContext, values: ServiceJSON, incarnationID: String? = nil) async throws {
    try await profile(context.profileID); try Self.validateStorage(context)
    try Self.validateIncarnation(incarnationID,extensionID:context.extensionID)
    guard case .object = values else { throw ServiceError("INPUT", "Invalid native storage snapshot.") }
    try values.validateDepth(); try SyncModel.quota(values)
    let key = SyncModel.localKey(context.profileID,context.extensionID)
    guard saved["nativeStorage"][key] == .null else { return }
    try transaction { $0["nativeStorage"][key] = Self.nativeRecord(values:values,incarnationID:incarnationID) }
  }
  /// Reconcile Chromium's actual dictionary with the last acknowledged native
  /// snapshot before any cloud write. This recovers local commits whose events
  /// were lost during a crash or a failed service-file write.
  @discardableResult public func reconcileNativeSnapshot(_ context: ExtensionStorageContext, values: ServiceJSON, incarnationID: String? = nil) async throws -> Bool {
    try await profile(context.profileID); try Self.validateStorage(context)
    try Self.validateIncarnation(incarnationID,extensionID:context.extensionID)
    guard case .object = values else { throw ServiceError("INPUT", "Invalid native storage snapshot.") }
    try values.validateDepth(); try SyncModel.quota(values)
    let key = SyncModel.localKey(context.profileID, context.extensionID)
    var record = saved["nativeStorage"][key]
    if record["incarnationID"] != .null {
      guard case .string(let stored) = record["incarnationID"] else { throw ServiceError("STORAGE", "The native installation identity is invalid and has been preserved.") }
      try Self.validateIncarnation(stored,extensionID:context.extensionID)
      if let incarnationID, stored != incarnationID {
        // Chromium preserves this identity through updates, and removes it on
        // uninstall. A new incarnation has no edits from the prior install.
        try transaction { $0["nativeStorage"][key] = Self.nativeRecord(values:values,incarnationID:incarnationID) }
        return true
      }
    }
    if record == .null {
      // An older linked client has no proof of whether differing native data
      // is a local edit or an unapplied remote view. Preserve both for review.
      let link = saved["links"][context.profileID], entry = SyncModel.library(link)[context.extensionID]
      let linked = link["settingsSync"].bool && entry != .null && entry["state"] != "removed" && !link["detachedSettings"][context.extensionID].bool
      let remote = SyncModel.visible(link,context.extensionID)
      if linked, remote != values {
        try transaction { state in
          state["nativeStorage"][key] = Self.nativeRecord(values:values,incarnationID:incarnationID)
          state["nativeStorage"][key]["pending"] = ["id":.string(UUID().uuidString),
            "before":remote, "target":remote, "migration":true, "context":identity(context.profileID,link)]
        }
        throw ServiceError("NATIVE_RECOVERY", "Local extension settings differ from this sync profile. Choose which settings to keep before syncing this extension.")
      }
      // Unlinked adoption never uploads data or changes the consent choices.
      try transaction { $0["nativeStorage"][key] = Self.nativeRecord(values:values,incarnationID:incarnationID) }
      return false
    }
    guard case .object = record["values"] else { throw ServiceError("STORAGE", "The native storage recovery record is invalid and has been preserved.") }
    try record["values"].validateDepth(); try SyncModel.quota(record["values"])
    let pending = record["pending"]
    if pending != .null {
      guard !pending["id"].string.isEmpty, case .object = pending["before"], case .object = pending["target"] else {
        throw ServiceError("STORAGE", "The pending native storage record is invalid and has been preserved.")
      }
      try SyncModel.quota(pending["before"]); try SyncModel.quota(pending["target"])
      let baseline: ServiceJSON
      if values == pending["target"] { baseline = pending["target"] }
      else if values == pending["before"] { baseline = pending["before"] }
      else {
        throw ServiceError("NATIVE_RECOVERY", "An interrupted sync and local extension changes overlap. Choose which settings to keep before syncing this extension.")
      }
      record = Self.nativeRecord(values:baseline,previous:record,incarnationID:incarnationID)
      try transaction { $0["nativeStorage"][key] = record }
    }
    if let incarnationID, record["incarnationID"] == .null {
      record["incarnationID"] = .string(incarnationID)
      try transaction { $0["nativeStorage"][key] = record }
    }
    let changes = SyncModel.difference(record["values"], values)
    if !changes.object.isEmpty { try await observeNativeStorageChanges(context, changes:changes) }
    return pending != .null || !changes.object.isEmpty
  }
  /// Durable intent precedes Chromium's atomic write. If the process stops at
  /// either side of that write, recovery can recognize the exact before/after.
  public func beginNativeStorageApply(_ context: ExtensionStorageContext, projection: ServiceJSON,
                                     expectedValues: ServiceJSON, incarnationID: String? = nil) async throws -> String {
    try await profile(context.profileID); try Self.validateStorage(context)
    try Self.validateIncarnation(incarnationID,extensionID:context.extensionID)
    guard projection["profileId"].string == context.profileID,
      projection["extensionId"].string == context.extensionID,
      isCurrentNativeStorageProjection(projection) else { throw ServiceError("cancelled", "The synchronized settings changed.") }
    guard case .object = expectedValues, case .object = projection["values"] else { throw ServiceError("INPUT", "Invalid native storage snapshot.") }
    try expectedValues.validateDepth(); try projection["values"].validateDepth()
    try SyncModel.quota(expectedValues); try SyncModel.quota(projection["values"])
    let key = SyncModel.localKey(context.profileID, context.extensionID), token = UUID().uuidString
    try transaction { state in
      let record = state["nativeStorage"][key]
      guard record["pending"] == .null, record["values"] == expectedValues,
        incarnationID == nil || record["incarnationID"].string == incarnationID else {
        throw ServiceError("NATIVE_BASELINE", "Local extension settings changed. Reconcile them before applying synchronization.")
      }
      state["nativeStorage"][key]["pending"] = ["id":.string(token), "before":expectedValues,
        "target":projection["values"], "context":projection.removing("values")]
    }
    return token
  }
  public func completeNativeStorageApply(_ context: ExtensionStorageContext, token: String) async throws {
    try await profile(context.profileID); try Self.validateStorage(context)
    let key = SyncModel.localKey(context.profileID, context.extensionID)
    try transaction { state in
      let pending = state["nativeStorage"][key]["pending"]
      guard pending["id"].string == token, !token.isEmpty else { throw ServiceError("cancelled", "The pending native write changed.") }
      // A successful native reply proves the target was committed. A later
      // local write will differ from this baseline and be recovered normally.
      state["nativeStorage"][key] = Self.nativeRecord(values:pending["target"],previous:state["nativeStorage"][key])
    }
  }
  /// Used only by an explicit recovery choice in native settings. The local
  /// choice and its outbox operation commit together, so retry cannot lose it.
  public func resolveNativeStorageRecovery(_ context: ExtensionStorageContext, values: ServiceJSON, useLocal: Bool) async throws {
    try await profile(context.profileID); try Self.validateStorage(context)
    guard case .object = values else { throw ServiceError("INPUT", "Invalid native storage snapshot.") }
    try values.validateDepth(); try SyncModel.quota(values)
    let mirror = try await nativeStorageValues(context)
    let mutation: ServiceJSON = ["set":values, "remove":.array(mirror.object.keys.filter { !values.contains($0) }.sorted().map(ServiceJSON.string))]
    let queued = try transaction { state in
      let key = SyncModel.localKey(context.profileID, context.extensionID)
      guard state["nativeStorage"][key]["pending"] != .null else { throw ServiceError("cancelled", "This recovery request changed.") }
      if useLocal { return try Self.recordNativeMutation(&state, context:context, mutation:mutation, nativeBaseline:values) }
      state["nativeStorage"][key] = Self.nativeRecord(values:values,previous:state["nativeStorage"][key])
      return false
    }
    if queued { schedule(250) }; notify()
  }
  /// Read-only view for retrying an already accepted native mutation. Unlike
  /// the extension API adapter, this does not rewrite the durable file on get.
  public func nativeStorageValues(_ context: ExtensionStorageContext) async throws -> ServiceJSON {
    try await profile(context.profileID); try Self.validateStorage(context)
    let link = saved["links"][context.profileID], entry = SyncModel.library(link)[context.extensionID]
    if link["settingsSync"].bool, entry != .null, entry["state"] != "removed",
      !link["detachedSettings"][context.extensionID].bool { return SyncModel.visible(link, context.extensionID) }
    let values = saved["areas"][SyncModel.localKey(context.profileID, context.extensionID)]["values"]
    return values == .null ? [:] : values
  }
  /// Records a write already accepted by Chromium's real storage backend. The
  /// native host supplies trusted provenance and validates installation identity.
  /// Do not replay a JS API call here: Chromium already enforced its write quota
  /// and delivered onChanged, and a replay would echo the write back to itself.
  public func observeNativeStorageChanges(_ context: ExtensionStorageContext, changes: ServiceJSON, origin: String = "") async throws {
    if origin == "zacro.private" || origin.hasPrefix("zacro.remote:") { return }
    guard origin.isEmpty else { throw ServiceError("ORIGIN", "Unknown native storage mutation origin.") }
    try await profile(context.profileID); try Self.validateStorage(context)
    guard case .object(let deltas) = changes, deltas.count <= 1024 else { throw ServiceError("INPUT", "Invalid native storage changes.") }
    try changes.validateDepth()
    guard try changes.encoded().count <= 1024 * 1024 else { throw ServiceError("QUOTA", "Native storage changes exceed their supported size.") }
    var set: ServiceJSON = [:], removed: [ServiceJSON] = []
    for (key, delta) in deltas {
      guard case .object = delta, delta.contains("oldValue") || delta.contains("newValue"),
        delta.object.keys.allSatisfy({ ["oldValue", "newValue"].contains($0) }) else { throw ServiceError("INPUT", "Invalid native storage change.") }
      if delta.contains("newValue") { set[key] = delta["newValue"] }
      else { removed.append(.string(key)) }
    }
    guard !deltas.isEmpty else { return }
    guard set.object.count <= 512, removed.count <= 512 else { throw ServiceError("INPUT", "Native storage changes exceed the protocol key limit.") }
    let mutation: ServiceJSON = ["set": set, "remove": .array(removed.sorted { $0.string < $1.string })]
    let key = SyncModel.localKey(context.profileID, context.extensionID)
    guard saved["nativeStorage"][key]["pending"] == .null else {
      throw ServiceError("NATIVE_RECOVERY", "Review extension settings to recover an interrupted synchronization.")
    }
    let queued = try transaction { try Self.recordNativeMutation(&$0, context:context, mutation:mutation) }
    if queued { schedule(250) }
    notify()
  }
  private static func recordNativeMutation(_ state: inout ServiceJSON, context: ExtensionStorageContext,
                                           mutation: ServiceJSON, nativeBaseline: ServiceJSON? = nil) throws -> Bool {
      var link = state["links"][context.profileID]
      let entry = SyncModel.library(link)[context.extensionID]
      let linked = link["settingsSync"].bool && entry != .null && entry["state"] != "removed" && !link["detachedSettings"][context.extensionID].bool
      let localKey = SyncModel.localKey(context.profileID, context.extensionID)
      let key = linked ? SyncModel.areaKey(context.extensionID, entry["generation"].string) : localKey
      var area = linked ? link["areas"][key] : state["areas"][key]
      if area == .null { area = state["areas"][localKey] == .null ? SyncModel.emptyArea : state["areas"][localKey] }
      let previous = linked ? SyncModel.visible(link, context.extensionID) : area["values"]
      let next = SyncModel.apply(previous, mutation); try SyncModel.quota(next)
      area["values"] = next
      if linked {
        link["areas"][key] = area
        if previous != next {
          let operation: ServiceJSON = ["id": .string(UUID().uuidString), "kind": "settings", "extensionId": .string(context.extensionID),
            "generation": entry["generation"], "baseRevision": link["cursor"], "payload": mutation]
          link["outbox"] = .array(link["outbox"].array + [operation])
        }
        state["links"][context.profileID] = link
      } else { state["areas"][key] = area }
      let native = state["nativeStorage"][localKey]["values"]
      let baseline = native == .null ? previous : native
      let nativeValues = nativeBaseline ?? SyncModel.apply(baseline, mutation)
      try SyncModel.quota(nativeValues)
      state["nativeStorage"][localKey] = Self.nativeRecord(values:nativeValues,previous:state["nativeStorage"][localKey])
      return linked && previous != next
  }
  /// Seeds the local mirror before a user reviews and chooses upload-local.
  /// A linked cloud view is never replaced by a later background snapshot.
  @discardableResult public func seedNativeStorage(_ context: ExtensionStorageContext, values: ServiceJSON) async throws -> Bool {
    try await profile(context.profileID); try Self.validateStorage(context)
    guard case .object = values else { throw ServiceError("INPUT", "Invalid native storage snapshot.") }
    try values.validateDepth(); try SyncModel.quota(values)
    let link = saved["links"][context.profileID], entry = SyncModel.library(link)[context.extensionID]
    guard !link["settingsSync"].bool || entry == .null || entry["state"] == "removed" || link["detachedSettings"][context.extensionID].bool else { return false }
    let key = SyncModel.localKey(context.profileID, context.extensionID)
    guard saved["nativeStorage"][key]["pending"] == .null else {
      throw ServiceError("NATIVE_RECOVERY", "Review extension settings to recover an interrupted synchronization.")
    }
    if saved["areas"][key]["values"] == values, saved["nativeStorage"][key]["values"] == values { return false }
    return try transaction { state in
      var area = state["areas"][key] == .null ? SyncModel.emptyArea : state["areas"][key]
      area["values"] = values; state["areas"][key] = area
      state["nativeStorage"][key] = Self.nativeRecord(values:values,previous:state["nativeStorage"][key])
      return true
    }
  }
  private static func validateIncarnation(_ value: String?, extensionID: String) throws {
    guard let value else { return }
    let prefix = extensionID + ":", suffix = value.dropFirst(prefix.count)
    guard value.hasPrefix(prefix), !suffix.isEmpty, suffix.count <= 20,
      suffix.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(suffix) != nil else {
      throw ServiceError("INPUT", "Invalid native installation identity.")
    }
  }
  private static func nativeRecord(values: ServiceJSON, previous: ServiceJSON = .null, incarnationID: String? = nil) -> ServiceJSON {
    var record: ServiceJSON = ["values":values]
    if let incarnationID { record["incarnationID"] = .string(incarnationID) }
    else if previous["incarnationID"] != .null { record["incarnationID"] = previous["incarnationID"] }
    return record
  }
  public func canAccessStorage(_ context: ExtensionStorageContext) async -> Bool {
    do {
      try await profile(context.profileID); try Self.validateStorage(context)
      let link = saved["links"][context.profileID], entry = SyncModel.library(link)[context.extensionID], local = saved["areas"][SyncModel.localKey(context.profileID,context.extensionID)]
      var area = local
      if link["settingsSync"].bool && entry != .null && entry["state"] != "removed" && !link["detachedSettings"][context.extensionID].bool {
        let linked = link["areas"][SyncModel.areaKey(context.extensionID,entry["generation"].string)]; if linked != .null { area = linked }
      }
      return context.trusted || area["accessLevel"] != "TRUSTED_CONTEXTS"
    } catch { return false }
  }
  private static func validateStorage(_ context: ExtensionStorageContext) throws {
    guard !context.isPrivate, context.enabled, SyncModel.extensionID(context.extensionID), context.permissions.contains("storage") else { throw ServiceError("DENIED", "Extension storage access denied or disabled; the storage permission is required.") }
  }
  private func emitStorage(_ profile: String, _ link: ServiceJSON?, _ extensionID: String, _ changes: ServiceJSON) {
    guard !changes.object.isEmpty else { return }
    var value: ServiceJSON = ["type":"storage:changed","profileId":.string(profile),"extensionId":.string(extensionID),"changes":changes,"area":"sync"]
    if let link { value = value.merging(identity(profile,link)) }; emit(value)
  }
  private func emitLibrary(_ profile: String, _ link: ServiceJSON, _ extensionEntry: ServiceJSON) {
    if link["librarySync"] != false { emit(identity(profile,link).merging(["type":"library:changed","extension":extensionEntry])) }
  }
  private static func revision(_ value: ServiceJSON) -> Bool {
    if case .number(let v) = value { return v.isFinite && v >= 0 && v <= 9_007_199_254_740_991 && v.rounded(.towardZero) == v }; return false
  }
  private static func validateEntry(_ entry: ServiceJSON) throws {
    guard SyncModel.extensionID(entry["extensionId"].string), SyncModel.id(entry["generation"].string), revision(entry["revision"]),
      entry["source"]["kind"] == "web-store", entry["source"]["id"] == entry["extensionId"], ["enabled","disabled","removed"].contains(entry["state"].string) else { throw ServiceError("PROTOCOL", "Invalid synchronized extension identity.") }
  }
  private func pull(_ profileID: String, link: ServiceJSON, identity: ServiceJSON, epoch expected: Int, results: [ServiceJSON] = []) async throws {
    var after = link["cursor"].number, through: ServiceJSON?
    repeat {
      let route = "/datasets/" + (try Self.pathID(link["datasetId"])) + "/changes?after=\(Int(after))&limit=100&settings=\(link["settingsSync"].bool ? 1 : 0)" + (through.map { "&through=\($0.int)" } ?? "")
      let page = try await request(route,epoch:expected,profileID:profileID,identity:identity)
      guard Self.revision(page["cursor"]), Self.revision(page["through"]), page["cursor"].number >= after,
        page["cursor"].number <= page["through"].number, !page["hasMore"].bool || page["cursor"].number > after,
        through == nil || through == page["through"] else { throw ServiceError("PROTOCOL", "Invalid synchronization cursor.") }
      try guardLink(identity,epoch:expected)
      try commitRemote(profileID,identity:identity,epoch:expected,incoming:page,results:page["hasMore"].bool ? [] : results)
      after = page["cursor"].number; through = page["through"]
      if !page["hasMore"].bool { break }
    } while true
  }
  private func commitRemote(_ profileID: String, identity: ServiceJSON, epoch expected: Int, incoming: ServiceJSON, results: [ServiceJSON]) throws {
    try guardLink(identity,epoch:expected)
    let events: (ServiceJSON,ServiceJSON,[ServiceJSON]) = try transaction { state in
      var link = state["links"][profileID]
      let old = SyncModel.observed(link,areas:state["areas"],profile:profileID), oldLibrary = SyncModel.library(link)
      for change in incoming["changes"].array {
        guard Self.revision(change["revision"]), change["revision"].number > link["cursor"].number, change["revision"].number <= incoming["cursor"].number,
          SyncModel.extensionID(change["extensionId"].string), SyncModel.id(change["generation"].string), ["extension","settings"].contains(change["kind"].string) else { throw ServiceError("PROTOCOL", "Invalid synchronization change.") }
        let id = change["extensionId"].string, previous = SyncModel.library(link)[id]
        if change["kind"] == "extension" { try Self.validateEntry(change.removing("kind","payload").merging(change["payload"])) }
        if link["librarySync"] == false && link["settingsSync"].bool && change["kind"] == "extension" && previous != .null && previous["state"] != "removed" && !link["detachedSettings"][id].bool && (change["payload"]["state"] == "removed" || change["generation"] != previous["generation"]) {
          let key = SyncModel.localKey(profileID,id)
          state["areas"][key] = SyncModel.independent(link,extensionID:id,values:SyncModel.visible(link,id),local:state["areas"][key])
          link["detachedSettings"][id] = true; Self.dropSettings(&link,extensionID:id)
        }
        SyncModel.applyChange(&link,change)
      }
      link["cursor"] = incoming["cursor"]
      for result in results {
        guard let operation = link["outbox"].array.first(where: { $0["id"] == result["id"] }) else { continue }
        link["outbox"] = .array(link["outbox"].array.filter { $0["id"] != result["id"] })
        if !["applied","duplicate"].contains(result["status"].string) { link["rejected"] = .array(link["rejected"].array + [["operation":operation,"code":result["code"] == .null ? result["status"] : result["code"]]]) }
      }
      state["links"][profileID] = link
      let next = SyncModel.observed(link,areas:state["areas"],profile:profileID), nextLibrary = SyncModel.library(link)
      var storage: ServiceJSON = [:]
      for ext in Set(old.object.keys).union(next.object.keys) { storage[ext] = SyncModel.difference(old[ext],next[ext]) }
      return (link,storage,nextLibrary.object.values.filter { oldLibrary[$0["extensionId"].string] != $0 })
    }
    for (id,changes) in events.1.object { try guardLink(identity,epoch:expected); if events.0["settingsSync"].bool { emitStorage(profileID,events.0,id,changes) } }
    for entry in events.2 { try guardLink(identity,epoch:expected); emitLibrary(profileID,events.0,entry) }
  }
  private func syncProfile(_ profileID: String, link: ServiceJSON, epoch expected: Int) async throws {
    try await profile(profileID); let identity = identity(profileID,link)
    try await pull(profileID,link:link,identity:identity,epoch:expected)
    while true {
      try guardLink(identity,epoch:expected)
      var operations: [ServiceJSON] = [], bytes = 100
      for op in saved["links"][profileID]["outbox"].array.prefix(100) {
        let count = try op.encoded().count + 1
        if !operations.isEmpty && bytes + count > 512 * 1024 { break }
        operations.append(op); bytes += count
      }
      if operations.isEmpty { break }
      let result = try await request("/datasets/" + Self.pathID(link["datasetId"]) + "/operations",method:"POST",body:["epoch":link["epoch"],"operations":.array(operations)],epoch:expected,profileID:profileID,identity:identity)
      try guardLink(identity,epoch:expected)
      guard result["results"].array.count == operations.count, zip(result["results"].array,operations).allSatisfy({ $0["id"] == $1["id"] && ["applied","duplicate","conflict","quota"].contains($0["status"].string) }) else { throw ServiceError("PROTOCOL", "Invalid synchronization acknowledgement.") }
      try await pull(profileID,link:saved["links"][profileID],identity:identity,epoch:expected,results:result["results"].array)
    }
    try guardLink(identity,epoch:expected); try transaction { $0["links"][profileID]["lastSync"] = .number(now()) }
  }
  public func syncNow() async -> ServiceJSON {
    if let running { return await running.task.value }
    let id = UUID(), expected = epoch
    let task = Task { [weak self] in await self?.performSync(epoch:expected) ?? .null }
    running = (id,task); defer { if running?.id == id { running = nil } }; return await task.value
  }
  private func performSync(epoch expected: Int) async -> ServiceJSON {
    guard credentials != nil else { return status() }
    do {
      _ = try await request("/account",epoch:expected)
      for (profile,link) in saved["links"].object {
        do { try await syncProfile(profile,link:link,epoch:expected) }
        catch let error as ServiceError {
          if expected != epoch || !isCurrentLink(identity(profile,link)) { continue }
          if error.status == 404 || error.code == "epoch_changed" { _ = try await unlinkProfile(profile); connectionState = "dataset-removed" }
          else if error.code != "cancelled" { throw error }
        }
      }
      try guardEpoch(expected); failures = 0
      if connectionState != "dataset-removed" { connectionState = status()["profiles"].array.contains(where: { !$0["rejected"].array.isEmpty }) ? "conflict" : "connected" }
    } catch {
      if (error as? ServiceError)?.code != "cancelled", credentials != nil, expected == epoch { connectionState = "offline"; failures += 1 }
    }
    if !closed {
      notify(); schedule(failures > 0 ? min(300_000,5_000 * pow(2,Double(min(failures - 1,6)))) * Double.random(in:0.9...1.1) : 30_000)
    }
    return closed ? .null : status()
  }
  private func schedule(_ milliseconds: Double) {
    timer?.cancel(); guard autoSync, !closed, credentials != nil else { return }
    timer = Task { [weak self] in
      do { try await Task.sleep(for:.milliseconds(milliseconds)); guard !Task.isCancelled else { return }; _ = await self?.syncNow() } catch { }
    }
  }
}
