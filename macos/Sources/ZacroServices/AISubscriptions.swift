import Foundation

public protocol AISubscriptionConnection: Sendable {
  func status() async -> ServiceJSON
  func refresh() async throws -> ServiceJSON
  func login() async throws -> URL?
  func cancelLogin() async throws
  func logout() async throws
  func setStorage(_ value: String) async throws
  func run(model: String, instructions: String, messages: [ServiceJSON], research: Bool,
           onDelta: @escaping @Sendable (String) async -> Void) async throws -> ServiceJSON
  func close() async
}

public actor CodexSubscription: AISubscriptionConnection {
  public static let pinnedVersion = "0.164.0"
  private let executable: URL?
  private let home: URL
  private var rpc: ProviderRPC?
  private var starting: Task<Void, Error>?
  private var account: ServiceJSON = .null, models: [ServiceJSON] = []
  private var loginID = "", authStorage = "keyring", generation = 0
  private var error: ServiceError?
  private var threadID: String?, turnID: String?
  private var turnItems: [String: ServiceJSON] = [:]
  private var turnOrder: [String] = []
  private var closed = false, loginStarting = false
  private var accountRead = 0
  private var connectionID: UUID?
  private var runToken: UUID?
  private var turnContinuation: AsyncThrowingStream<[ServiceJSON], Error>.Continuation?
  private var delta: (@Sendable (String) async -> Void)?
  private var outputBytes = 0
  public init(directory: URL, executable: URL? = Bundle.main.resourceURL?.appendingPathComponent("Providers/codex")) {
    home = directory.appendingPathComponent("codex")
    self.executable = executable.flatMap { ProviderProcessPolicy.nativeExecutable($0) ? $0 : nil }
  }
  public func status() -> ServiceJSON {
    var result: ServiceJSON = ["available":.bool(executable != nil),"configured":.bool(account != .null),
      "account":account,"models":.array(models),"loginPending":.bool(loginStarting || !loginID.isEmpty),"credentialStorage":.string(authStorage)]
    if let error { result["error"] = .string(error.message); result["errorCode"] = .string(error.code) }
    if executable == nil { result["error"] = "The bundled Codex runtime is missing. Reinstall Zacro to use this connection."; result["errorCode"] = "UNAVAILABLE" }
    if authStorage == "session" { result["storageNotice"] = "ChatGPT sign-in lasts only while this connection is running. Closing Zacro or restarting it signs you out." }
    return result
  }
  public static func configuration(storage: String) -> ServiceJSON {
    var config: ServiceJSON = ["model_provider":"openai","forced_login_method":"chatgpt",
      "cli_auth_credentials_store":.string(storage == "session" ? "ephemeral" : "keyring"),
      "approval_policy":"never","sandbox_mode":"read-only","project_doc_max_bytes":0,
      "project_doc_fallback_filenames":[],"include_environment_context":false,"include_environment_context_time":false,
      "allow_login_shell":false,"web_search":"disabled","mcp_servers":[:],
      "shell_environment_policy.inherit":"none","shell_environment_policy.include_only":[],
      "skills.bundled.enabled":false,"skills.include_instructions":false,"features.skip_host_skill_discovery":true,
      "plugins._default.enabled":false,"tools.update_plan.enabled":false,"tools.experimental_request_user_input.enabled":false,
      "history.persistence":"none","analytics.enabled":false,"memories.generate_memories":false,"memories.use_memories":false]
    for feature in ["shell_tool","apply_patch_freeform","view_image","apps","hooks","plugin_hooks","multi_agent","multi_agent_v2","remote_plugin","plugins","memories","memory_tool","js_repl","code_mode","code_mode_host","browser_use","computer_use","in_app_browser","in_app_local_automation","workspace_dependencies","tool_search","search_tool","skill_search","skill_mcp_dependency_install","skill_env_var_dependency_prompt","image_generation","goals","request_permissions","request_permissions_tool","tool_suggest","multi_env_copy_file","remote_control","send_async_message","default_mode_request_user_input","collaboration_modes","shell_snapshot","external_agent_memory_import","external_migration","daemon_auto_start"] {
      config["features." + feature] = false
    }
    return config
  }
  private func start() async throws {
    guard !closed else { throw ServiceError("CLOSED", "The connection closed.") }
    if let starting { return try await starting.value }
    if rpc != nil { return }
    guard let executable else { throw ServiceError("UNAVAILABLE", "The bundled official Codex runtime is missing.") }
    let task = Task { [self] in
      try Task.checkCancellation(); guard !closed else { throw ServiceError("CLOSED", "The connection closed.") }
      let id = UUID(); connectionID = id
      let connection = ProviderRPC { [weak self] event in await self?.receive(event,connectionID:id) }
      rpc = connection
      let config = Self.configuration(storage: authStorage)
      let args = ["app-server","--strict-config","--listen","stdio://"] + config.object.keys.sorted().flatMap { ["-c",$0 + "=" + config[$0].text] }
      do {
        try await connection.start(executable: executable, arguments: args, home: home)
        _ = try await connection.call("initialize", ["clientInfo":["name":"zacro_browser","title":"Zacro","version":"0.11.0"],"capabilities":["experimentalApi":true]])
        try await connection.notify("initialized")
        let inventory = try await connection.call("mcpServerStatus/list", ["limit":100])
        guard inventory["data"].array.isEmpty, inventory["nextCursor"] == .null else { throw ServiceError("TOOL_POLICY", "This Codex runtime has external tools enabled. Zacro requires an isolated connection.") }
        let skills = try await connection.call("skills/list", ["cwds":[.string(home.appendingPathComponent("workspace").path)],"forceReload":true])
        for entry in skills["data"].array {
          guard entry["errors"].array.isEmpty else { throw ServiceError("TOOL_POLICY", "Codex could not verify its isolated skills configuration.") }
          for skill in entry["skills"].array where skill["enabled"] != false {
            _ = try await connection.call("skills/config/write", ["path":skill["path"],"enabled":false])
          }
        }
        _ = try await readAccount(withModels: false)
      } catch {
        await stop(); throw error
      }
    }
    starting = task
    defer { starting = nil }
    try await task.value
  }
  private func readAccount(withModels: Bool = true) async throws -> ServiceJSON {
    guard let rpc else { throw ServiceError("UNAVAILABLE", "The Codex connection is not running.") }
    let original = generation; accountRead += 1; let read = accountRead
    let result = try await rpc.call("account/read", ["refreshToken":false])
    guard original == generation, read == accountRead, !closed else { throw ServiceError("CANCELLED", "The connection changed.") }
    guard result["account"] == .null || result["account"]["type"].string == "chatgpt" else {
      account = .null; models = []; throw ServiceError("AUTH", "This connection requires ChatGPT subscription sign-in.")
    }
    account = result["account"] == .null ? .null : ["email":result["account"]["email"],"planType":result["account"]["planType"]]
    if account != .null && withModels {
      let catalog = try await rpc.call("model/list", ["includeHidden":false,"limit":100])
      guard original == generation, read == accountRead, !closed else { throw ServiceError("CANCELLED", "The connection changed.") }
      models = catalog["data"].array.compactMap { model in
        let id = model["model"].string.isEmpty ? model["id"].string : model["model"].string
        guard id.range(of: "^[a-zA-Z0-9._:-]{1,120}$", options: .regularExpression) != nil else { return nil }
        return ["id":.string(id),"name":model["displayName"].string.isEmpty ? .string(id) : model["displayName"],"isDefault":.bool(model["isDefault"].bool)]
      }
    } else if account == .null { models = [] }
    error = nil; return status()
  }
  public func refresh() async throws -> ServiceJSON { try await start(); return try await readAccount() }
  public func login() async throws -> URL? {
    guard !loginStarting, loginID.isEmpty else { return nil }
    loginStarting = true; generation += 1; let current = generation
    defer { if generation == current { loginStarting = false } }
    try await start(); guard let rpc, current == generation else { throw ServiceError("CANCELLED", "Sign-in cancelled.") }
    let result = try await rpc.call("account/login/start", ["type":"chatgpt"])
    guard current == generation else {
      _ = try? await rpc.call("account/login/cancel", ["loginId":result["loginId"]]); throw ServiceError("CANCELLED", "Sign-in cancelled.")
    }
    guard let url = URL(string: result["authUrl"].string), url.scheme == "https", url.host == "auth.openai.com",
      url.user == nil, url.password == nil, url.port == nil else {
      _ = try? await rpc.call("account/login/cancel", ["loginId":result["loginId"]])
      throw ServiceError("AUTH_URL", "Codex returned an unsupported sign-in address.")
    }
    loginID = result["loginId"].string; return url
  }
  public func cancelLogin() async throws {
    generation += 1; loginStarting = false; let id = loginID; loginID = ""
    if !id.isEmpty {
      do { _ = try await rpc?.call("account/login/cancel", ["loginId":.string(id)]) }
      catch { await stop(); throw error }
    }
  }
  public func logout() async throws {
    try await start(); try await cancelLogin(); account = .null; models = []
    _ = try await rpc?.call("account/logout"); error = nil
  }
  public func setStorage(_ value: String) async throws {
    guard ["keyring","session"].contains(value) else { throw ServiceError("INPUT", "Choose keychain or this session only.") }
    guard threadID == nil else { throw ServiceError("BUSY", "Stop the current answer before changing sign-in storage.") }
    if value == authStorage { return }
    if authStorage == "keyring", rpc != nil { try await logout() }
    await stop(); authStorage = value
  }
  public func run(model: String, instructions: String, messages: [ServiceJSON], research: Bool,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> ServiceJSON {
    guard runToken == nil else { throw ServiceError("BUSY", "An answer is already running.") }
    let token = UUID(); runToken = token
    defer { if runToken == token { runToken = nil } }
    try await start()
    guard account != .null else { throw ServiceError("NOT_CONFIGURED", "Sign in with ChatGPT first.") }
    guard threadID == nil, let rpc else { throw ServiceError("BUSY", "An answer is already running.") }
    return try await withTaskCancellationHandler {
      var config = Self.configuration(storage: authStorage); config["web_search"] = .string(research ? "live" : "disabled")
      var params: ServiceJSON = ["modelProvider":"openai","cwd":.string(home.appendingPathComponent("workspace").path),"approvalPolicy":"never","sandbox":"read-only","ephemeral":true,"baseInstructions":.string(instructions),"environments":[],"allowProviderModelFallback":false,"config":config]
      if !model.isEmpty { params["model"] = .string(model) }
      let started = try await rpc.call("thread/start", params)
      try Task.checkCancellation()
      let thread = started["thread"]["id"].string
      guard !thread.isEmpty else { throw ServiceError("PROTOCOL", "Codex did not create a thread.") }
      threadID = thread; turnItems = [:]; turnOrder = []; outputBytes = 0; delta = onDelta
      let events = AsyncThrowingStream<[ServiceJSON], Error> { turnContinuation = $0 }
      defer {
        threadID = nil; turnID = nil; turnContinuation = nil; delta = nil; turnItems = [:]; turnOrder = []
        Task { _ = try? await rpc.call("thread/unsubscribe", ["threadId":.string(thread)]) }
      }
      let response = try await rpc.call("turn/start", ["threadId":.string(thread),"input":[["type":"text","text":.string(ServiceJSON.array(messages).text),"text_elements":[]]],"environments":[],"approvalPolicy":"never","sandboxPolicy":["type":"readOnly","networkAccess":false]])
      turnID = response["turn"]["id"].string
      for try await items in events { try Task.checkCancellation(); return try Self.answer(items) }
      throw ServiceError("CANCELLED", "Answer stopped.")
    } onCancel: { Task { await self.cancelTurn(token) } }
  }
  private func cancelTurn(_ token: UUID) async {
    guard runToken == token else { return }
    guard let thread = threadID, let turn = turnID, !turn.isEmpty, let rpc else { await stop(); return }
    turnContinuation?.finish(throwing:ServiceError("CANCELLED","Answer stopped."))
    do { _ = try await rpc.call("turn/interrupt",["threadId":.string(thread),"turnId":.string(turn)],timeout:5) }
    catch { if runToken == token { await stop() } }
  }
  private func receive(_ message: ServiceJSON, connectionID id: UUID) async {
    guard connectionID == id, !closed else { return }
    let method = message["method"].string, p = message["params"]
    if method == "account/login/completed", p["loginId"].string == loginID {
      loginID = ""
      if p["success"].bool { _ = try? await readAccount() }
      else { let failure = Self.safeError(p); await stop(); error = failure }
    } else if method == "account/updated" { _ = try? await readAccount() }
    else if method == "zacro/ended" || method == "zacro/tool-policy" {
      account = .null; models = []; loginID = ""
      turnContinuation?.finish(throwing: ServiceError(method == "zacro/tool-policy" ? "TOOL_POLICY" : "UNAVAILABLE", "The Codex connection stopped."))
      rpc = nil; return
    }
    guard p["threadId"].string == threadID else { return }
    if method == "item/agentMessage/delta" {
      let text = p["delta"].string; outputBytes += text.utf8.count
      guard outputBytes <= 4 * 1024 * 1024 else { turnContinuation?.finish(throwing: ServiceError("RESPONSE_SIZE", "The answer was too large.")); await stop(); return }
      await delta?(text)
    } else if method == "item/completed" { record(p["item"]) }
    else if method == "item/started" && !["userMessage","agentMessage","reasoning","webSearch","plan","contextCompaction"].contains(p["item"]["type"].string) {
      turnContinuation?.finish(throwing: ServiceError("TOOL_POLICY", "Codex requested a tool that Zacro does not permit.")); await stop()
    } else if method == "turn/completed" {
      for item in p["turn"]["items"].array { record(item) }
      if p["turn"]["status"].string == "completed" { turnContinuation?.yield(turnOrder.compactMap { turnItems[$0] }); turnContinuation?.finish() }
      else { turnContinuation?.finish(throwing: p["turn"]["status"].string == "interrupted" ? ServiceError("CANCELLED", "Answer stopped.") : Self.safeError(p["turn"]["error"])) }
    }
  }
  private func record(_ item: ServiceJSON) {
    let id = item["id"].string
    if turnItems[id] == nil { turnOrder.append(id) }; turnItems[id] = item
  }
  private func stop() async {
    generation += 1; account = .null; models = []; loginID = ""; loginStarting = false
    turnContinuation?.finish(throwing: ServiceError("CANCELLED", "Answer stopped."))
    let connection = rpc; rpc = nil; connectionID = nil; await connection?.stop()
  }
  public func close() async { closed = true; starting?.cancel(); await stop() }
  static func safeError(_ value: ServiceJSON) -> ServiceError {
    let text = value.text.lowercased()
    if ["persist_failed","keyring","keychain"].contains(where: text.contains) { return ServiceError("AUTH_STORAGE", "The macOS Keychain could not save the ChatGPT sign-in. Unlock it or explicitly choose this session only. No plaintext token file was saved.") }
    if ["usage_limit","rate_limit","quota"].contains(where: text.contains) { return ServiceError("LIMIT", "Your subscription allowance is currently unavailable. No API billing fallback was used.") }
    if ["auth","unauthor","login","token"].contains(where: text.contains) { return ServiceError("AUTH", "Sign in with ChatGPT again.") }
    return ServiceError("CODEX", "Codex could not complete this request. Check your connection and try again.")
  }
  static func answer(_ items: [ServiceJSON]) throws -> ServiceJSON {
    let answer = items.filter { $0["type"].string == "agentMessage" && $0["phase"].string != "commentary" }.map { $0["text"].string }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else { throw ServiceError("EMPTY", "Codex returned no answer.") }
    var sources: [ServiceJSON] = []
    func collect(_ value: ServiceJSON, depth: Int = 0) {
      guard depth <= 8 else { return }
      if let url = AIValidation.sourceURL(value["url"].string), !sources.contains(where: { $0["url"].string == url.absoluteString }) {
        sources.append(["url":.string(url.absoluteString),"title":value["title"].string.isEmpty ? .string(url.host ?? "Source") : value["title"]])
      }
      for item in value.array { collect(item, depth: depth + 1) }
      for (key,item) in value.object where key != "url" { collect(item, depth: depth + 1) }
    }
    for item in items where item["type"].string == "webSearch" { collect(item["action"]); collect(item["results"]) }
    let verified = Array(sources.prefix(20)), ns = answer as NSString
    let regex = try! NSRegularExpression(pattern:#"\[([^\]\n]{1,300})\]\((https?://[^\s)]+)\)"#)
    let citations: [ServiceJSON] = regex.matches(in:answer,range:NSRange(location:0,length:ns.length)).compactMap { match in
      guard let url = AIValidation.sourceURL(ns.substring(with:match.range(at:2))), let source = verified.first(where: { $0["url"].string == url.absoluteString }) else { return nil }
      return source.merging(["start":.number(Double(match.range.location)),"end":.number(Double(match.range.location+match.range.length))])
    }
    return ["answer":.string(answer),"sources":.array(verified),"citations":.array(citations),"usage":[:],"historyContent":.string(answer)]
  }
}

public actor ClaudeSubscription: AISubscriptionConnection {
  public static let installURL = URL(string: "https://code.claude.com/docs/en/setup")!
  private let home: URL
  private var executable: URL?
  private var checkedVersion = false, loginPending = false
  private var account: ServiceJSON = .null
  private var command: OwnedProviderCommand?
  private var commandID: UUID?
  private var loginTask: Task<Void, Never>?
  private var failure: ServiceError?
  private var generation = 0
  private var statusRead = 0, closed = false
  private static let settings: ServiceJSON = ["forceLoginMethod":"claudeai","disableAllHooks":true,"autoMemoryEnabled":false,"enabledPlugins":[:]]
  public init(directory: URL, executable: URL? = nil) {
    home = directory.appendingPathComponent("claude-code")
    self.executable = executable ?? Self.discover()
  }
  private static func discover() -> URL? {
    let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return directories.filter { $0.hasPrefix("/") && $0 != FileManager.default.currentDirectoryPath }.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }.first(where: ProviderProcessPolicy.nativeExecutable)
  }
  public func status() -> ServiceJSON {
    var result: ServiceJSON = ["available":.bool(executable != nil),"configured":.bool(account != .null),"account":account,
      "models":[["id":"sonnet","name":"Sonnet","isDefault":true],["id":"opus","name":"Opus"],["id":"haiku","name":"Haiku"]],
      "loginPending":.bool(loginPending),"credentialStorage":"provider-managed","installUrl":.string(Self.installURL.absoluteString),
      "storageNotice":"The official Claude Code CLI owns this sign-in in a separate Zacro configuration. It uses macOS Keychain when available and may fall back to a local credential file. Zacro never reads the subscription tokens."]
    if let failure { result["error"] = .string(failure.message); result["errorCode"] = .string(failure.code) }
    return result
  }
  private func execute(_ args: [String], input: String? = nil, timeout: TimeInterval = 120) async throws -> (Int32, Data) {
    guard !closed else { throw ServiceError("CLOSED", "The connection closed.") }
    guard let executable else { throw ServiceError("UNAVAILABLE", "Install the official native Claude Code CLI first.") }
    let operation = OwnedProviderCommand(), id = UUID(); command = operation; commandID = id
    defer { if commandID == id { command = nil; commandID = nil } }
    return try await operation.run(executable: executable, arguments: args, home: home, provider: .claudeCode, input: input, timeout: timeout)
  }
  private func version() async throws {
    guard !checkedVersion else { return }
    if executable == nil { executable = Self.discover() }
    let (_,bytes) = try await execute(["--version"], timeout: 15)
    let text = String(decoding: bytes, as: UTF8.self)
    guard let range = text.range(of: #"\b\d+\.\d+\.\d+\b"#, options: .regularExpression) else { throw ServiceError("UNAVAILABLE", "Update Claude Code to version 2.1.259 or later.") }
    let numbers = text[range].split(separator: ".").compactMap { Int($0) }
    guard !numbers.lexicographicallyPrecedes([2,1,259]) else { throw ServiceError("UNAVAILABLE", "Update Claude Code to version 2.1.259 or later.") }
    checkedVersion = true
  }
  private func auth(_ action: String) -> [String] { ["--safe-mode","--setting-sources","","--settings",Self.settings.text,"auth",action] }
  public func refresh() async throws -> ServiceJSON {
    guard !loginPending else { return status() }
    let current = generation; statusRead += 1; let read = statusRead
    try await version()
    guard current == generation, read == statusRead, !closed else { throw ServiceError("CANCELLED", "The connection changed.") }
    let (code, bytes) = try await execute(auth("status"), timeout: 15)
    guard current == generation, read == statusRead, !closed else { throw ServiceError("CANCELLED", "The connection changed.") }
    let result = try ServiceJSON.decode(bytes)
    if result["loggedIn"].bool && result["authMethod"].string != "claude.ai" { throw ServiceError("AUTH", "This connection requires a Claude subscription. API keys belong in Claude API.") }
    account = code == 0 && result["loggedIn"].bool ? ["email":result["email"],"planType":result["subscriptionType"]] : .null
    failure = nil; return status()
  }
  public func login() async throws -> URL? {
    guard !loginPending else { return nil }
    generation += 1; let current = generation
    loginPending = true; account = .null; failure = nil
    do { try await version() } catch { if current == generation { loginPending = false }; throw error }
    guard current == generation, !closed else { throw ServiceError("CANCELLED", "Sign-in cancelled.") }
    loginTask = Task { [self] in
      do {
        let (code,_) = try await execute(auth("login"), timeout: 180)
        guard current == generation else { return }
        loginPending = false
        guard code == 0 else { throw ServiceError("AUTH", "Claude sign-in did not complete.") }
        _ = try await refresh()
      } catch {
        if current == generation { loginPending = false; failure = error as? ServiceError ?? ServiceError("AUTH", "Claude sign-in did not complete.") }
      }
    }
    return nil
  }
  public func cancelLogin() { generation += 1; loginTask?.cancel(); loginTask = nil; command?.cancel(); loginPending = false }
  public func logout() async throws {
    cancelLogin(); account = .null; try await version()
    let (code,_) = try await execute(auth("logout"), timeout: 15)
    guard code == 0 else { throw ServiceError("AUTH", "Claude sign-out did not complete. Retry with the official CLI available.") }
  }
  public func setStorage(_ value: String) throws { throw ServiceError("INPUT", "Claude Code manages its own subscription storage.") }
  public func run(model: String, instructions: String, messages: [ServiceJSON], research: Bool,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> ServiceJSON {
    guard account != .null else { throw ServiceError("NOT_CONFIGURED", "Sign in with your Claude subscription first.") }
    try await version()
    let args = ["--safe-mode","--restricted","--setting-sources","","--settings",Self.settings.text,
      "--strict-mcp-config","--mcp-config","{\"mcpServers\":{}}","--disallowedTools","mcp__*","--tools","",
      "--permission-mode","dontAsk","--permission-prompts","none","--no-chrome","--no-session-persistence",
      "--max-turns","1","--model",try AIValidation.model(model),"--system-prompt",instructions,"-p","--output-format","json"]
    let (code,bytes) = try await execute(args, input: ServiceJSON.array(messages).text)
    let result = try ServiceJSON.decode(bytes)
    guard code == 0, !result["is_error"].bool, result["subtype"].string == "success" else { throw ServiceError("CLAUDE", "Claude did not complete the answer. No API billing fallback was used.") }
    guard !result["result"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError("EMPTY", "Claude returned no answer.") }
    return ["answer":result["result"],"sources":[],"citations":[],"usage":[:],"historyContent":result["result"]]
  }
  public func close() async {
    closed = true
    let operation = command, pendingLogin = loginTask
    cancelLogin(); account = .null
    await operation?.shutdown()
    await pendingLogin?.value
  }
}
