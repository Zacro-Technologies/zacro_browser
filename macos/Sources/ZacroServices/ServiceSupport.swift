import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

/// The service boundary is JSON, never an untyped executable bridge or a secret-bearing view model.
public enum ServiceJSON: Codable, Equatable, Sendable {
  case null, bool(Bool), number(Double), string(String), array([ServiceJSON]), object([String: ServiceJSON])
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([ServiceJSON].self) { self = .array(v) }
    else { self = .object(try c.decode([String: ServiceJSON].self)) }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): guard v.isFinite else { throw ServiceError("INPUT", "Invalid JSON number.") }; try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
  public var object: [String: ServiceJSON] { if case .object(let v) = self { return v }; return [:] }
  public var array: [ServiceJSON] { if case .array(let v) = self { return v }; return [] }
  public var string: String { if case .string(let v) = self { return v }; return "" }
  public var bool: Bool { if case .bool(let v) = self { return v }; return false }
  public var number: Double { if case .number(let v) = self { return v }; return 0 }
  public var int: Int { guard number.isFinite, number >= Double(Int.min), number < Double(Int.max) else { return 0 }; return Int(number) }
  public subscript(_ key: String) -> ServiceJSON {
    get { object[key] ?? .null }
    set { var v = object; v[key] = newValue; self = .object(v) }
  }
  public func contains(_ key: String) -> Bool { object[key] != nil }
  public func removing(_ keys: String...) -> ServiceJSON { .object(object.filter { !keys.contains($0.key) }) }
  public func merging(_ other: ServiceJSON) -> ServiceJSON { .object(object.merging(other.object) { _, b in b }) }
  public func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) }
  public var text: String { String(data: (try? encoded()) ?? Data(), encoding: .utf8) ?? "null" }
  public static func decode(_ bytes: Data) throws -> ServiceJSON {
    let value = try JSONDecoder().decode(Self.self, from: bytes)
    try value.validateDepth()
    return value
  }
  public func validateDepth(_ depth: Int = 0) throws {
    guard depth <= 64 else { throw ServiceError("INPUT", "JSON value nesting is too deep.") }
    if case .number(let value) = self, !value.isFinite { throw ServiceError("INPUT", "Invalid JSON number.") }
    for v in array { try v.validateDepth(depth + 1) }
    for v in object.values { try v.validateDepth(depth + 1) }
  }
}
extension ServiceJSON: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension ServiceJSON: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension ServiceJSON: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .number(Double(value)) } }
extension ServiceJSON: ExpressibleByArrayLiteral { public init(arrayLiteral elements: ServiceJSON...) { self = .array(elements) } }
extension ServiceJSON: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, ServiceJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
}

public struct ServiceError: Error, LocalizedError, Sendable, Equatable {
  public let code: String
  public let message: String
  public let status: Int?
  public init(_ code: String, _ message: String, status: Int? = nil) { self.code = code; self.message = message; self.status = status }
  public var errorDescription: String? { message }
}

public struct ServiceHTTPRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: ServiceJSON?
  public var timeout: TimeInterval
  public var maximumBytes: Int
  public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: ServiceJSON? = nil,
              timeout: TimeInterval = 120, maximumBytes: Int = 2 * 1024 * 1024) {
    self.url = url; self.method = method; self.headers = headers; self.body = body
    self.timeout = timeout; self.maximumBytes = maximumBytes
  }
}
public struct ServiceHTTPResponse: Sendable {
  public var status: Int
  public var body: ServiceJSON
  public init(status: Int, body: ServiceJSON) { self.status = status; self.body = body }
}
public protocol ServiceHTTPTransport: Sendable { func send(_ request: ServiceHTTPRequest) async throws -> ServiceHTTPResponse }

/// Ephemeral transport does not forward credentials through redirects, persist cookies, or log bodies.
public final class NativeServiceHTTPTransport: NSObject, ServiceHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
  public override init() { super.init() }
  public func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  public func send(_ request: ServiceHTTPRequest) async throws -> ServiceHTTPResponse {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = request.timeout; configuration.timeoutIntervalForResource = request.timeout
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var outgoing = URLRequest(url: request.url, timeoutInterval: request.timeout)
    outgoing.httpMethod = request.method; outgoing.allHTTPHeaderFields = request.headers
    outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body = request.body {
      outgoing.httpBody = try body.encoded(); outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
      try Task.checkCancellation()
      let (stream, response) = try await session.bytes(for: outgoing)
      guard let response = response as? HTTPURLResponse else { throw ServiceError("PROTOCOL", "The service returned an invalid response.") }
      guard !(300..<400).contains(response.statusCode) else { throw ServiceError("REDIRECT", "The endpoint redirected. Credentials were not forwarded.") }
      guard response.expectedContentLength <= request.maximumBytes else { throw ServiceError("RESPONSE_SIZE", "The service response was too large.") }
      let type = response.mimeType?.lowercased() ?? ""
      guard type == "application/json" || type.hasSuffix("+json") else { throw ServiceError("PROTOCOL", "The endpoint did not return a JSON API response.") }
      var bytes = Data()
      for try await byte in stream {
        try Task.checkCancellation()
        guard bytes.count < request.maximumBytes else { throw ServiceError("RESPONSE_SIZE", "The service response was too large.") }
        bytes.append(byte)
      }
      return ServiceHTTPResponse(status: response.statusCode, body: try ServiceJSON.decode(bytes))
    } catch is CancellationError { throw ServiceError("CANCELLED", "Request stopped.") }
    catch let error as ServiceError { throw error }
    catch let error as URLError where error.code == .cancelled { throw ServiceError("CANCELLED", "Request stopped.") }
    catch let error as URLError where error.code == .timedOut { throw ServiceError("TIMEOUT", "The service took too long. Try again.") }
    catch let error as URLError where error.code == .networkConnectionLost { throw ServiceError("CONNECTION_RESET", "The service connection was interrupted.") }
    catch { throw ServiceError("NETWORK", "Unable to reach the service. Check its address, certificate, and your connection.") }
  }
}

public protocol NativeSecretStore: Sendable {
  func read(_ key: String) throws -> Data?
  func write(_ bytes: Data, key: String) throws
  func remove(_ key: String) throws
}

/// Status never queries Keychain. Explicit reads/writes fail closed if the login Keychain is locked.
public final class KeychainSecretStore: NativeSecretStore, @unchecked Sendable {
  private let service: String
  public init(service: String = "com.zacro.browser.native.services") { self.service = service }
  private func query(_ key: String) -> [String: Any] {
    let context = LAContext(); context.interactionNotAllowed = true
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: key, kSecUseAuthenticationContext as String: context]
  }
  public func read(_ key: String) throws -> Data? {
    var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let bytes = result as? Data else { throw storageError() }
    return bytes
  }
  public func write(_ bytes: Data, key: String) throws {
    let q = query(key)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecItemNotFound {
      var add = q; add[kSecValueData as String] = bytes
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw storageError() }
    } else if status != errSecSuccess { throw storageError() }
  }
  public func remove(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError() }
  }
  private func storageError() -> ServiceError {
    ServiceError("AUTH_STORAGE", "The macOS Keychain is unavailable or locked. Unlock it and retry, or explicitly choose this session only. No plaintext credential was saved.")
  }
}

enum ServiceFiles {
  static func read(_ file: URL, maximum: Int = 32 * 1024 * 1024) throws -> ServiceJSON? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maximum else { throw ServiceError("STORAGE", "The saved service data is too large. It has been preserved.") }
    do { return try ServiceJSON.decode(Data(contentsOf: file)) }
    catch { throw ServiceError("STORAGE", "The saved service data is unreadable. It has been preserved.") }
  }
  static func write(_ value: ServiceJSON, file: URL) throws {
    try writeData(value.encoded(), file: file)
  }
  static func writeData(_ bytes: Data, file: URL, maximum: Int = 32 * 1024 * 1024) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard bytes.count <= maximum else { throw ServiceError("STORAGE", "The service's saved data reached its storage limit.") }
    let temporary = file.appendingPathExtension(UUID().uuidString + ".pending")
    let descriptor = Darwin.open(temporary.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
    guard descriptor >= 0 else { throw ServiceError("STORAGE", "The service data could not be saved.") }
    defer { Darwin.close(descriptor); try? fm.removeItem(at:temporary) }
    try bytes.withUnsafeBytes { buffer in
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(descriptor,buffer.baseAddress!.advanced(by:written),buffer.count-written)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ServiceError("STORAGE", "The service data could not be saved.") }; written += count
      }
    }
    guard fsync(descriptor) == 0, rename(temporary.path,file.path) == 0 else { throw ServiceError("STORAGE", "The service data could not be committed.") }
    let parent = Darwin.open(file.deletingLastPathComponent().path,O_RDONLY)
    if parent >= 0 { defer { Darwin.close(parent) }; guard fsync(parent) == 0 else { throw ServiceError("STORAGE", "The service data could not be committed.") } }
  }
  static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
