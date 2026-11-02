import Foundation

actor AICredentialVault {
  private let file: URL
  private let store: any NativeSecretStore
  private let namespace: String
  private var durable = Set<String>()
  private var session: [String: String] = [:]
  private var readError: Error?
  init(directory: URL, store: any NativeSecretStore) {
    self.store = store; file = directory.appendingPathComponent("ai-credentials-index.json")
    namespace = "ai:" + ServiceFiles.hash(directory.standardizedFileURL.path) + ":"
    do {
      if let saved = try ServiceFiles.read(file, maximum: 256 * 1024) {
        guard saved["version"] == 1, case let .array(keys) = saved["keys"],
          keys.allSatisfy({ value in
            guard case let .string(id) = value else { return false }
            return id.range(of: #"^[a-f0-9]{64}:[a-f0-9]{64}$"#, options: .regularExpression) != nil
          }) else { throw ServiceError("AUTH_STORAGE", "The credential index is unreadable and has been preserved.") }
        durable = Set(keys.map(\.string))
      }
    } catch { readError = error }
  }
  static func id(profile: String, provider: NativeAIProvider, endpoint: String) -> String {
    ServiceFiles.hash(profile) + ":" + ServiceFiles.hash(ServiceJSON.array([.string(provider.rawValue), .string(endpoint)]).text)
  }
  func status(_ id: String) -> ServiceJSON {
    ["configured":.bool(session[id] != nil || durable.contains(id)),
     "credentialStorage":.string(session[id] != nil ? "session" : durable.contains(id) ? "encrypted" : "none")]
  }
  func get(_ id: String) throws -> String {
    if let value = session[id] { return value }
    guard durable.contains(id) else { return "" }
    guard let bytes = try store.read(namespace + id), let secret = try? ServiceJSON.decode(bytes), secret["id"].string == id else {
      throw ServiceError("AUTH_STORAGE", "The saved API key could not be read. Unlock Keychain or replace the key.")
    }
    return secret["key"].string
  }
  func set(_ id: String, key: String, storage: String) throws {
    guard !key.isEmpty, key.count <= 8192, !key.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else {
      throw ServiceError("INPUT", "Enter an API key without spaces or control characters.")
    }
    guard ["encrypted","session"].contains(storage) else { throw ServiceError("INPUT", "Choose Keychain or this session only.") }
    if storage == "session" {
      // An ephemeral connection can still work without reading durable keys.
      // It neither repairs the damaged index nor claims old keys were removed.
      if durable.contains(id) { try remove(id) }
      session[id] = key; return
    }
    if let readError { throw readError }
    let previous = try store.read(namespace + id)
    try store.write(try ServiceJSON.object(["id":.string(id),"key":.string(key)]).encoded(), key: namespace + id)
    var next = durable; next.insert(id)
    do { try save(next) }
    catch {
      if let previous { try? store.write(previous, key: namespace + id) } else { try? store.remove(namespace + id) }
      throw error
    }
    durable = next; session.removeValue(forKey: id)
  }
  func remove(_ id: String) throws {
    // An empty in-memory set after a failed load is not evidence that the
    // protected store has no key. Keep deletion retryable instead of reporting
    // success and letting profile retirement acknowledge incomplete cleanup.
    if let readError { throw readError }
    if durable.contains(id) {
      try store.remove(namespace + id)
      var next = durable; next.remove(id); try save(next); durable = next
    }
    session.removeValue(forKey: id)
  }
  func forgetProfile(_ profile: String) throws {
    if let readError { throw readError }
    let prefix = ServiceFiles.hash(profile) + ":"
    for key in Set(durable).union(session.keys) where key.hasPrefix(prefix) { try remove(key) }
  }
  func close() { session.removeAll() }
  private func save(_ keys: Set<String>) throws { try ServiceFiles.write(["version":1,"keys":.array(keys.sorted().map(ServiceJSON.string))], file: file) }
}
