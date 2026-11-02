import Foundation

public enum NativeAIProvider: String, CaseIterable, Codable, Sendable {
  case codex, claudeCode = "claude-code", openai, anthropic, compatible, openrouter
  public var name: String {
    switch self { case .codex: "ChatGPT subscription"; case .claudeCode: "Claude subscription"
    case .openai: "OpenAI API"; case .anthropic: "Claude API"; case .compatible: "OpenAI-compatible API"; case .openrouter: "OpenRouter" }
  }
  public var isSubscription: Bool { self == .codex || self == .claudeCode }
  public var supportsResearch: Bool { self != .compatible && self != .claudeCode }
  public var defaultModel: String {
    switch self { case .codex: ""; case .claudeCode: "sonnet"; case .openai: "gpt-5-mini"
    case .anthropic: "claude-sonnet-4-6"; case .compatible: ""; case .openrouter: "openai/gpt-5-mini" }
  }
  public var endpoint: String {
    switch self { case .openai: "https://api.openai.com/v1"; case .anthropic: "https://api.anthropic.com/v1"
    case .openrouter: "https://openrouter.ai/api/v1"; default: "" }
  }
}

public enum AIValidation {
  public static func isLoopback(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    if ["localhost", "::1", "[::1]"].contains(host) { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
  }
  public static func endpoint(_ provider: NativeAIProvider, _ value: String = "") throws -> String {
    guard !provider.isSubscription else { throw ServiceError("INPUT", "Subscription connections do not accept API endpoints.") }
    let trim = value.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    if provider != .compatible {
      guard value.isEmpty || trim == provider.endpoint else { throw ServiceError("ENDPOINT", "This provider uses its official endpoint. Choose OpenAI-compatible for a custom server.") }
      return provider.endpoint
    }
    guard !value.isEmpty, value.count <= 2048, !value.contains("\\"),
      !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
      let url = URL(string: trim), url.host != nil, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil,
      url.scheme == "https" || (url.scheme == "http" && isLoopback(url))
    else { throw ServiceError("ENDPOINT", "Use an HTTPS API base URL, or HTTP on localhost. Credentials, query strings, and fragments are not allowed.") }
    return url.absoluteString
  }
  public static func model(_ value: String) throws -> String {
    guard value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._:/@+-]{0,159}$", options: .regularExpression) != nil else {
      throw ServiceError("MODEL", "Enter a valid model ID from your provider.")
    }
    return value
  }
  public static func sourceURL(_ value: String) -> URL? {
    guard value.count <= 8192, let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
      url.host != nil, url.user == nil, url.password == nil else { return nil }
    return url
  }
  static func clean(_ value: String, maximum: Int) -> String {
    let safe = String(value.unicodeScalars.filter { scalar in
      !(scalar.value <= 8 || scalar.value == 11 || scalar.value == 12 || (14...31).contains(scalar.value))
    })
    return String(decoding: safe.utf16.prefix(maximum), as: UTF16.self)
  }
}

public struct NativeAPIClient: Sendable {
  public let transport: any ServiceHTTPTransport
  public init(transport: any ServiceHTTPTransport = NativeServiceHTTPTransport()) { self.transport = transport }
  public func request(provider: NativeAIProvider, baseURL: String, key: String, route: String, body: ServiceJSON? = nil) async throws -> ServiceJSON {
    let endpoint = try AIValidation.endpoint(provider, baseURL)
    guard let base = URL(string: endpoint), let url = URL(string: endpoint + "/" + route) else { throw ServiceError("ENDPOINT", "Invalid API endpoint.") }
    guard !key.isEmpty || (provider == .compatible && AIValidation.isLoopback(base)) else { throw ServiceError("NOT_CONFIGURED", "Save an API key for this provider first.") }
    guard !key.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { throw ServiceError("AUTH", "The API key is invalid.") }
    var headers: [String: String] = [:]
    if provider == .anthropic { headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01" }
    else if !key.isEmpty { headers["Authorization"] = "Bearer " + key }
    let result = try await transport.send(ServiceHTTPRequest(url: url, method: body == nil ? "GET" : "POST", headers: headers, body: body))
    guard (200..<300).contains(result.status) else {
      switch result.status {
      case 401,403: throw ServiceError("AUTH", "The provider rejected this API key or account access.", status: result.status)
      case 429: throw ServiceError("LIMIT", "The provider's usage or rate limit was reached. Check billing and limits before retrying.", status: 429)
      case 400,404,422: throw ServiceError("MODEL", "The provider rejected this model, endpoint, or feature.", status: result.status)
      default: throw ServiceError("PROVIDER", "The provider is unavailable. Try again later.", status: result.status)
      }
    }
    return result.body
  }
  public func test(provider: NativeAIProvider, baseURL: String, model: String, key: String) async throws -> ServiceJSON {
    let data = try await request(provider: provider, baseURL: baseURL, key: key, route: provider == .openrouter ? "key" : "models")
    let models = data["data"].array.prefix(500).compactMap { item -> ServiceJSON? in
      guard (try? AIValidation.model(item["id"].string)) != nil else { return nil }
      return ["id":item["id"],"name":.string(String((item["display_name"].string.isEmpty ? item["id"].string : item["display_name"].string).prefix(160)))]
    }
    var result: ServiceJSON = ["ok":true,"models":.array(models),"message":"Connected. No inference request was made."]
    if !models.isEmpty && !models.contains(where: { $0["id"].string == model }) { result["warning"] = "The configured model was not in the returned catalog. Check its exact ID before asking a question." }
    return result
  }
  public func run(provider: NativeAIProvider, baseURL: String, model: String, key: String,
                  instructions: String, messages: [ServiceJSON], research: Bool) async throws -> ServiceJSON {
    let model = try AIValidation.model(model)
    var body: ServiceJSON; let route: String
    switch provider {
    case .openai:
      route = "responses"
      body = ["model":.string(model),"instructions":.string(instructions),"input":.array(messages),"store":false,"max_output_tokens":4096]
      if research { body["tools"] = [["type":"web_search"]]; body["include"] = ["web_search_call.action.sources"] }
    case .anthropic:
      route = "messages"
      body = ["model":.string(model),"system":.string(instructions),"messages":.array(messages),"max_tokens":4096]
      if research { body["tools"] = [["type":"web_search_20250305","name":"web_search","max_uses":5]] }
    case .compatible, .openrouter:
      route = "chat/completions"
      body = ["model":.string(model),"messages":.array([["role":"system","content":.string(instructions)]] + messages),"max_tokens":4096,"stream":false]
      if provider == .openrouter {
        body["provider"] = ["allow_fallbacks":false]
        if research { body["plugins"] = [["id":"web","max_results":5]] }
      }
    default: throw ServiceError("INPUT", "Use the subscription transport for this connection.")
    }
    return try Self.parse(provider: provider, data: await request(provider: provider, baseURL: baseURL, key: key, route: route, body: body))
  }

  public static func parse(provider: NativeAIProvider, data: ServiceJSON) throws -> ServiceJSON {
    var answer = "", sources: [ServiceJSON] = [], citations: [ServiceJSON] = [], searchError = false
    func source(_ input: ServiceJSON) -> ServiceJSON? {
      guard let url = AIValidation.sourceURL(input["url"].string) else { return nil }
      let item: ServiceJSON = ["url":.string(url.absoluteString),"title":.string(String((input["title"].string.isEmpty ? url.host ?? "Source" : input["title"].string).prefix(300)))]
      if !sources.contains(where: { $0["url"] == item["url"] }) { sources.append(item) }
      return item
    }
    func append(_ text: String, annotations: [ServiceJSON] = []) {
      let offset = answer.utf16.count; answer += text
      for annotation in annotations {
        let a = annotation.contains("url_citation") ? annotation["url_citation"] : annotation
        guard let entry = source(a), case .number(let start) = a["start_index"], case .number(let end) = a["end_index"],
          start >= 0, end > start, end <= Double(text.utf16.count), start.rounded() == start, end.rounded() == end else { continue }
        citations.append(entry.merging(["start":.number(Double(offset) + start),"end":.number(Double(offset) + end)]))
      }
    }
    if data.contains("error") && data["error"] != .null { throw ServiceError("PROVIDER", "The provider could not complete this response.") }
    switch provider {
    case .openai:
      if data["status"].string == "failed" { throw ServiceError("PROVIDER", "OpenAI could not complete this response.") }
      if data["status"].string == "incomplete" { throw ServiceError("INCOMPLETE", "The response reached its output limit. Ask a narrower question.") }
      for item in data["output"].array {
        let type = item["type"].string
        if type == "message" { for part in item["content"].array {
          if part["type"].string == "output_text" { append(part["text"].string, annotations: part["annotations"].array) }
          if part["type"].string == "refusal" { append(part["refusal"].string) }
        } }
        if type == "web_search_call" { _ = source(item["action"]); for s in item["action"]["sources"].array { _ = source(s) } }
        if ["function_call","computer_call","mcp_call","shell_call"].contains(where: type.contains) { throw ServiceError("TOOL_POLICY", "The provider requested a tool that Zacro does not permit.") }
      }
    case .anthropic:
      if ["max_tokens","pause_turn"].contains(data["stop_reason"].string) { throw ServiceError("INCOMPLETE", "Claude did not finish within this request's limit.") }
      for part in data["content"].array {
        if part["type"].string == "tool_use" { throw ServiceError("TOOL_POLICY", "Claude requested a tool that Zacro does not permit.") }
        if part["type"].string == "text" {
          append(part["text"].string)
          for citation in part["citations"].array {
            guard let item = source(citation), let index = sources.firstIndex(of: item) else { continue }
            let start = answer.utf16.count + 1; answer += " [\(index + 1)]"
            citations.append(item.merging(["start":.number(Double(start)),"end":.number(Double(answer.utf16.count)),"quote":.string(String(citation["cited_text"].string.prefix(180)))]))
          }
        }
        if part["type"].string == "web_search_tool_result" {
          for item in part["content"].array { _ = source(item) }
          if part["content"]["type"].string == "web_search_tool_result_error" { searchError = true }
        }
      }
    default:
      let choice = data["choices"].array.first ?? .null
      if choice["finish_reason"].string == "length" { throw ServiceError("INCOMPLETE", "The response reached its output limit.") }
      guard choice["message"]["tool_calls"].array.isEmpty, choice["message"]["function_call"] == .null else { throw ServiceError("TOOL_POLICY", "The provider requested a tool that Zacro does not permit.") }
      append(choice["message"]["content"].string, annotations: provider == .openrouter ? choice["message"]["annotations"].array : [])
    }
    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError("EMPTY", "The provider returned no text answer.") }
    let usage = data["usage"].object.filter {
      guard case .number(let count) = $0.value else { return false }
      return ["input_tokens","output_tokens","total_tokens","prompt_tokens","completion_tokens"].contains($0.key) && count.isFinite && count >= 0
    }
    return ["answer":.string(answer),"sources":.array(Array(sources.prefix(20))),"citations":.array(citations),"usage":.object(usage),"searchError":.bool(searchError),"historyContent":provider == .anthropic ? data["content"] : .string(answer)]
  }
}
