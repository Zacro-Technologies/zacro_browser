import CefKit
import Foundation

/// Wire values deliberately do not depend on ZacroCore. Decimal identifiers
/// preserve native int64 values and the private journal owns their authority.
public struct ChromeHistoryIdentity: Codable, Equatable, Sendable {
  public let generation: String
  public let visitID: String
  public let timeMicroseconds: String
  public let url: String
  public let originator: String
  public init(generation: String, visitID: String, timeMicroseconds: String,
    url: String, originator: String) {
    self.generation = generation; self.visitID = visitID; self.timeMicroseconds = timeMicroseconds
    self.url = url; self.originator = originator
  }
}
public struct ChromeHistoryLegacyInput: Codable, Equatable, Sendable {
  public let importID: String
  public let boundaryLeaseID: String?
  public let url: String
  public let timeMicroseconds: String
  public let title: String
  public init(importID: String, url: String, timeMicroseconds: String, title: String, boundaryLeaseID: String? = nil) {
    self.importID = importID; self.url = url; self.timeMicroseconds = timeMicroseconds; self.title = title; self.boundaryLeaseID = boundaryLeaseID
  }
}
public struct ChromeHistoryLegacyResult: Codable, Equatable, Sendable {
  public let importID: String
  public let boundaryLeaseID: String
  public let presence: ChromeHistoryPresence
  public let generation: String
  public let identity: ChromeHistoryIdentity?
  public let sourceAddress: String?
}
public struct ChromeHistoryLegacyAcknowledgement: Codable, Equatable, Sendable {
  public let importID: String
  public let generation: String
  public init(importID: String, generation: String) { self.importID = importID; self.generation = generation }
}
public struct ChromeHistoryRetentionStatus: Decodable, Equatable, Sendable {
  public let automaticExpirationReads: String
  public let retainedVisits: Int
}
public enum ChromeHistoryPresence: String, Codable, Equatable, Sendable { case present, absent, error }
public struct ChromeHistoryEvent: Codable, Equatable, Sendable {
  public let eventID: String
  public let documentToken: String
  public let logicalID: String
  public let sequence: String
  public let publish: Bool
  public let libraryVisit: Bool
  public let presence: ChromeHistoryPresence
  public let identity: ChromeHistoryIdentity?
  public let title: String
}
public struct ChromeHistoryEventPage: Decodable, Sendable {
  public let events: [ChromeHistoryEvent]
  public let complete: Bool
  public let nextSequence: String
}
public struct ChromeHistoryDocument: Decodable, Equatable, Sendable {
  public let documentToken: String
  public let logicalID: String
  public let ownerWindowID: Int
  public let preview: Bool
  public let provisional: Bool
  public let currentEventID: String?
}
public struct ChromeHistoryPublication: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Equatable, Sendable { case popup, preview }
  public enum Disposition: String, Codable, Equatable, Sendable { case prepared, committed, cancelled }
  public let leaseID: String
  public let documentToken: String
  public let kind: Kind
  public let capturedEventID: String?
  public let capturedEvent: ChromeHistoryEvent?
  public let logicalID: String?
  public let disposition: Disposition
}
public struct ChromeHistoryVerificationLease: Decodable, Sendable {
  public let lease: String
  public let revision: String
  public let total: Int
}
public struct ChromeHistoryVerificationRow: Decodable, Sendable {
  public let input: ChromeHistoryIdentity
  public let presence: ChromeHistoryPresence
  public let title: String?
}
public struct ChromeHistoryVerificationPage: Decodable, Sendable {
  public let lease: String
  public let revision: String
  public let offset: Int
  public let complete: Bool
  public let results: [ChromeHistoryVerificationRow]
}

/// One exact native profile transport. A close/replacement cannot cause a later
/// operation to construct another manager/context. App epoch validation remains
/// necessary before any durable Core write after these awaits.
@MainActor public final class ChromeHistoryMirrorSession {
  public let profileID: String
  private let browser: CefBrowser
  private var closed = false
  private var verificationLeases = Set<String>()

  init(profileID: String, browser: CefBrowser) { self.profileID = profileID; self.browser = browser }

  func prepareObservation() async throws {
    struct Ready: Decodable { let ready: Bool; let revision: String }
    let result: Ready = try await request("observeHistory", [:])
    guard result.ready, !result.revision.isEmpty, result.revision.utf8.count <= 128 else {
      throw CefDevToolsError.invalidMessage
    }
  }

  /// Ordering only: this is not database durability/deletion proof. The app
  /// pauses/cancels its producer first, then awaits all previously submitted
  /// native imports before starting a user-requested history clear.
  public func orderedQueueBarrier() async throws {
    try await mutation("historyMirrorBarrier", [:])
  }

  /// Only identifiers cross this retention boundary. Native automatic aging
  /// respects these exact tuples; explicit user and extension deletion does not.
  public func replaceRetention(_ identities: [ChromeHistoryIdentity]) async throws {
    guard identities.count <= 20_000, identities.allSatisfy(Self.validIdentity),
      Set(identities.map { $0.generation + ":" + $0.visitID }).count == identities.count else {
      throw CefDevToolsError.invalidMessage
    }
    let groups: [[String: Any]] = Dictionary(grouping: identities, by: \.generation).sorted { $0.key < $1.key }.map {
      ["generation": $0.key, "visits": $0.value.map { [$0.visitID, $0.timeMicroseconds] }]
    }
    guard try JSONSerialization.data(withJSONObject: groups).count <= 960 * 1024 else { throw CefDevToolsError.invalidMessage }
    try await mutation("replaceHistoryRetention", ["groups": groups])
  }
  public func retentionStatus() async throws -> ChromeHistoryRetentionStatus {
    let value: ChromeHistoryRetentionStatus = try await request("historyRetentionStatus", [:])
    guard Self.decimal(value.automaticExpirationReads, allowZero: true), (0...40_000).contains(value.retainedVisits) else {
      throw CefDevToolsError.invalidMessage
    }
    return value
  }

  public func createLegacyBoundary() async throws -> String {
    struct Result: Decodable { let leaseID: String }
    let result: Result = try await request("createLegacyHistoryBoundary", [:])
    guard Self.uuid(result.leaseID) else { throw CefDevToolsError.invalidMessage }; return result.leaseID
  }
  public func legacyBoundaries() async throws -> [String] {
    struct Result: Decodable { let leases: [String] }
    let result: Result = try await request("legacyHistoryBoundaries", [:])
    guard result.leases.count <= 1000, Set(result.leases).count == result.leases.count,
      result.leases.allSatisfy(Self.uuid) else { throw CefDevToolsError.invalidMessage }
    return result.leases
  }
  public func finalizeLegacyBoundary(_ leaseID: String, completedInitial: Bool = false) async throws {
    guard Self.uuid(leaseID) else { throw CefDevToolsError.invalidMessage }
    try await mutation("finalizeLegacyHistoryBoundary", ["leaseID": leaseID, "completedInitial": completedInitial])
  }

  public func importLegacy(_ inputs: [ChromeHistoryLegacyInput]) async throws -> [ChromeHistoryLegacyResult] {
    struct Results: Decodable { let results: [ChromeHistoryLegacyResult] }
    guard !inputs.isEmpty, inputs.count <= 512, Set(inputs.map(\.importID)).count == inputs.count,
      inputs.allSatisfy({ Self.hash($0.importID) && $0.boundaryLeaseID.map(Self.uuid) == true && Self.decimal($0.timeMicroseconds)
        && $0.url.utf8.count <= 8192 && $0.title.utf8.count <= 8192 }) else { throw CefDevToolsError.invalidMessage }
    let bytes = try JSONEncoder().encode(inputs)
    guard bytes.count <= 512 * 1024 else { throw CefDevToolsError.invalidMessage }
    let result: Results = try await request("importLegacyHistory", ["inputs": try JSONSerialization.jsonObject(with: bytes)])
    guard result.results.count == inputs.count else { throw CefDevToolsError.invalidMessage }
    for (input, value) in zip(inputs, result.results) {
      guard value.importID == input.importID, value.boundaryLeaseID == input.boundaryLeaseID, Self.generation(value.generation),
        value.sourceAddress == input.url, value.presence != .error else { throw CefDevToolsError.invalidMessage }
      switch value.presence {
      case .present:
        guard let identity = value.identity, Self.validIdentity(identity), identity.generation == value.generation,
          identity.timeMicroseconds == input.timeMicroseconds else { throw CefDevToolsError.invalidMessage }
      case .absent: guard value.identity == nil else { throw CefDevToolsError.invalidMessage }
      case .error: throw CefDevToolsError.invalidMessage
      }
    }
    return result.results
  }
  public func acknowledgeLegacy(_ receipts: [ChromeHistoryLegacyAcknowledgement]) async throws {
    guard receipts.count <= 512, Set(receipts.map(\.importID)).count == receipts.count,
      receipts.allSatisfy({ Self.hash($0.importID) && Self.generation($0.generation) }) else {
      throw CefDevToolsError.invalidMessage
    }
    let bytes = try JSONEncoder().encode(receipts)
    try await mutation("acknowledgeLegacyHistoryImports", ["entries": try JSONSerialization.jsonObject(with: bytes)])
  }

  public func eventPage(after sequence: String = "0", limit: Int = 512) async throws -> ChromeHistoryEventPage {
    guard Self.decimal(sequence, allowZero: true), (1...512).contains(limit) else { throw CefDevToolsError.invalidMessage }
    let page: ChromeHistoryEventPage = try await request("historyEventPage", ["afterSequence": sequence, "limit": limit])
    guard page.events.count <= limit, Self.decimal(page.nextSequence, allowZero: true),
      !page.events.isEmpty || page.complete,
      page.nextSequence == (page.events.last?.sequence ?? sequence),
      page.events.allSatisfy({ Self.validEvent($0) }),
      zip([sequence] + page.events.map(\.sequence), page.events.map(\.sequence)).allSatisfy({
        (Int64($0.0) ?? -1) < (Int64($0.1) ?? -1)
      }) else { throw CefDevToolsError.invalidMessage }
    return page
  }

  public func acknowledgeEvents(_ eventIDs: [String]) async throws {
    guard eventIDs.count <= 512, eventIDs.allSatisfy(Self.uuid) else { throw CefDevToolsError.invalidMessage }
    try await mutation("acknowledgeHistoryEvents", ["eventIDs": eventIDs])
  }

  public func publications() async throws -> [ChromeHistoryPublication] {
    struct Result: Decodable { let publications: [ChromeHistoryPublication] }
    let result: Result = try await request("historyPublications", [:])
    guard result.publications.count <= 1000,
      Set(result.publications.map(\.leaseID)).count == result.publications.count,
      Set(result.publications.map(\.documentToken)).count == result.publications.count,
      result.publications.allSatisfy(Self.validPublication) else { throw CefDevToolsError.invalidMessage }
    return result.publications
  }

  public func commitPublication(leaseID: String, documentToken: String, logicalID: String) async throws {
    guard Self.uuid(leaseID), Self.uuid(documentToken), Self.identifier(logicalID) else { throw CefDevToolsError.invalidMessage }
    try await mutation("commitHistoryPublication", ["leaseID": leaseID, "documentToken": documentToken, "logicalID": logicalID])
  }
  public func cancelPublication(leaseID: String, documentToken: String) async throws {
    guard Self.uuid(leaseID), Self.uuid(documentToken) else { throw CefDevToolsError.invalidMessage }
    try await mutation("cancelHistoryPublication", ["leaseID": leaseID, "documentToken": documentToken])
  }
  public func finalizePublication(leaseID: String, documentToken: String, logicalID: String?) async throws {
    guard Self.uuid(leaseID), Self.uuid(documentToken), logicalID == nil || Self.identifier(logicalID!) else {
      throw CefDevToolsError.invalidMessage
    }
    var arguments: [String: Any] = ["leaseID": leaseID, "documentToken": documentToken]
    if let logicalID { arguments["logicalID"] = logicalID }
    try await mutation("finalizeHistoryPublication", arguments)
  }

  public func document(_ page: ChromiumPage) async throws -> ChromeHistoryDocument {
    try check()
    guard !page.isPrivate, page.profileID == profileID else { throw CefDevToolsError.invalidMessage }
    let native = try await page.ready()
    let result = try await native.devTools.call("Zacro.historyDocument")
    try check()
    guard !native.isClosed, page.browser === native else { throw CancellationError() }
    let descriptor = try Self.decode(ChromeHistoryDocument.self, result)
    guard Self.uuid(descriptor.documentToken), Self.identifier(descriptor.logicalID), descriptor.ownerWindowID > 0,
      descriptor.currentEventID == nil || Self.uuid(descriptor.currentEventID!) else { throw CefDevToolsError.invalidMessage }
    return descriptor
  }

  /// requestID is chosen before native dispatch, allowing cancellation even if
  /// prepare's response is lost. Cancellation is only legal BEFORE Core commit;
  /// after that the caller retains/replays its durable receipt instead.
  public func preparePublication(_ page: ChromiumPage, expected: ChromeHistoryDocument,
    requestID: String) async throws -> ChromeHistoryPublication {
    try check()
    guard !page.isPrivate, page.profileID == profileID, Self.uuid(requestID),
      Self.uuid(expected.documentToken), expected.preview || expected.provisional else { throw CefDevToolsError.invalidMessage }
    let native = try await page.ready()
    let beforeID = page.id, beforeOwner = page.ownerWindowID
    let cancellation = HistoryPreparationCancellation(browser: browser, requestID: requestID, documentToken: expected.documentToken)
    do {
      let result = try await withTaskCancellationHandler {
        try await native.devTools.call("Zacro.prepareHistoryPublication", parameters: [
          "leaseID": requestID, "documentToken": expected.documentToken,
          "logicalID": expected.logicalID, "ownerWindowID": expected.ownerWindowID,
        ])
      } onCancel: { Task { @MainActor in cancellation.cancel() } }
      try check()
      guard !native.isClosed, page.browser === native, page.id == beforeID, page.ownerWindowID == beforeOwner else {
        throw CancellationError()
      }
      let value = try Self.decode(ChromeHistoryPublication.self, result)
      guard Self.validPublication(value), value.leaseID == requestID,
        value.documentToken == expected.documentToken, value.disposition == .prepared,
        value.kind == (expected.preview ? .preview : .popup) else { throw CefDevToolsError.invalidMessage }
      return value
    } catch {
      // Never borrow a recreated manager to clean up a previous operation.
      await cancellation.cancelAndWait()
      throw error
    }
  }

  public func beginVerification(total: Int) async throws -> ChromeHistoryVerificationLease {
    guard (0...20_000).contains(total) else { throw CefDevToolsError.invalidMessage }
    let value: ChromeHistoryVerificationLease = try await request("beginHistoryVerification", ["total": total])
    guard Self.uuid(value.lease), !value.revision.isEmpty, value.revision.utf8.count <= 128, value.total == total else {
      throw CefDevToolsError.invalidMessage
    }
    verificationLeases.insert(value.lease)
    return value
  }
  public func verify(_ lease: ChromeHistoryVerificationLease, offset: Int,
    inputs: [ChromeHistoryIdentity], eventIDs: [String?]? = nil) async throws -> ChromeHistoryVerificationPage {
    guard verificationLeases.contains(lease.lease), offset >= 0, inputs.count <= 512,
      offset + inputs.count <= lease.total, !inputs.isEmpty || lease.total == 0 else { throw CefDevToolsError.invalidMessage }
    guard eventIDs == nil || (eventIDs!.count == inputs.count && eventIDs!.allSatisfy { $0 == nil || Self.uuid($0!) }) else {
      throw CefDevToolsError.invalidMessage
    }
    let bytes = try JSONEncoder().encode(inputs)
    guard var values = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { throw CefDevToolsError.invalidMessage }
    if let eventIDs { for (index, event) in eventIDs.enumerated() { if let event { values[index]["eventID"] = event } } }
    guard try JSONSerialization.data(withJSONObject: values).count <= 512 * 1024 else { throw CefDevToolsError.invalidMessage }
    let page: ChromeHistoryVerificationPage = try await request("verifyHistoryPage", [
      "lease": lease.lease, "revision": lease.revision, "offset": offset, "inputs": values,
    ])
    guard page.lease == lease.lease, page.revision == lease.revision, page.offset == offset,
      page.complete == (offset + inputs.count == lease.total), page.results.map(\.input) == inputs,
      page.results.allSatisfy({ $0.presence != .error && ($0.title.map { $0.utf8.count <= 8192 } ?? true) }) else {
      throw CefDevToolsError.invalidMessage
    }
    return page
  }
  public func confirm(_ lease: ChromeHistoryVerificationLease) async throws -> String {
    struct Result: Decodable { let revision: String }
    guard verificationLeases.contains(lease.lease) else { throw CefDevToolsError.invalidMessage }
    let result: Result = try await request("confirmHistoryVerification", ["lease": lease.lease, "revision": lease.revision])
    guard result.revision == lease.revision else { throw CefDevToolsError.invalidMessage }
    return result.revision
  }
  public func acknowledgeVerification(lease: String, revision: String) async throws {
    guard Self.uuid(lease), !revision.isEmpty, revision.utf8.count <= 128 else { throw CefDevToolsError.invalidMessage }
    // Unknown already-released leases are a successful release, never new proof.
    try await mutation("acknowledgeHistoryVerification", ["lease": lease, "revision": revision])
    verificationLeases.remove(lease)
  }

  public func close() async {
    guard !closed else { return }; closed = true
    let leases = verificationLeases; verificationLeases.removeAll()
    guard !browser.isClosed else { return }
    for lease in leases {
      _ = try? await browser.devTools.call("Zacro.releaseHistoryVerification", parameters: ["lease": lease], timeout: 5)
    }
  }
  private func check() throws {
    try Task.checkCancellation()
    guard !closed, !browser.isClosed else { throw CancellationError() }
  }
  private func request<T: Decodable>(_ method: String, _ arguments: [String: Any]) async throws -> T {
    try check()
    let result = try await browser.devTools.call("Zacro." + method, parameters: arguments)
    try check()
    return try Self.decode(T.self, result)
  }
  private func mutation(_ method: String, _ arguments: [String: Any]) async throws {
    struct Result: Decodable { let acknowledged: Bool }
    let result: Result = try await request(method, arguments)
    guard result.acknowledged else { throw CefDevToolsError.invalidMessage }
  }
  private static func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: value)
    guard data.count <= 2 * 1024 * 1024 else { throw CefDevToolsError.responseTooLarge }
    return try JSONDecoder().decode(type, from: data)
  }
  private static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
  private static func hash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  private static func generation(_ value: String) -> Bool {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    return fields.count == 2 && uuid(String(fields[0])) && decimal(String(fields[1]))
  }
  private static func validIdentity(_ value: ChromeHistoryIdentity) -> Bool {
    generation(value.generation) && decimal(value.visitID) && decimal(value.timeMicroseconds)
      && value.url.utf8.count <= 8192 && value.originator.utf8.count <= 256
      && URL(string: value.url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "")
        && $0.host != nil && $0.user == nil && $0.password == nil } == true
  }
  private static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
  private static func decimal(_ value: String, allowZero: Bool = false) -> Bool {
    Int64(value).map { $0 >= (allowZero ? 0 : 1) && String($0) == value } == true
  }
  private static func validEvent(_ event: ChromeHistoryEvent) -> Bool {
    guard uuid(event.eventID), uuid(event.documentToken), identifier(event.logicalID),
      decimal(event.sequence), event.title.utf8.count <= 8192 else { return false }
    switch event.presence {
    case .present: return event.identity.map(validIdentity) == true
    case .absent: return event.identity == nil
    case .error: return false
    }
  }
  private static func validPublication(_ value: ChromeHistoryPublication) -> Bool {
    guard uuid(value.leaseID), uuid(value.documentToken),
      value.capturedEventID == nil || (value.kind == .preview && uuid(value.capturedEventID!)),
      value.disposition == .committed ? value.logicalID.map(identifier) == true : value.logicalID == nil else { return false }
    if let event = value.capturedEvent {
      return value.kind == .preview && validEvent(event) && !event.publish
        && event.eventID == value.capturedEventID && event.documentToken == value.documentToken
    }
    return true
  }
}

@MainActor private final class HistoryPreparationCancellation {
  private let browser: CefBrowser
  private let requestID: String
  private let documentToken: String
  private var task: Task<Void, Never>?
  init(browser: CefBrowser, requestID: String, documentToken: String) {
    self.browser = browser; self.requestID = requestID; self.documentToken = documentToken
  }
  func cancel() {
    guard task == nil else { return }
    task = Task { @MainActor [browser, requestID, documentToken] in
      guard !browser.isClosed else { return }
      _ = try? await browser.devTools.call("Zacro.cancelHistoryPublication", parameters: [
        "leaseID": requestID, "documentToken": documentToken,
      ], timeout: 10)
    }
  }
  func cancelAndWait() async { cancel(); await task?.value }
}

@MainActor extension ChromeExtensionManager {
  public func historyMirrorSession() async throws -> ChromeHistoryMirrorSession {
    guard !isPrivate else { throw ChromeExtensionError.managementUnavailable }
    let browser = try await nativeBrowser()
    try Task.checkCancellation()
    guard !browser.isClosed else { throw CancellationError() }
    let session = ChromeHistoryMirrorSession(profileID: profileID, browser: browser)
    do { try await session.prepareObservation(); return session }
    catch { await session.close(); throw error }
  }
}

@MainActor extension ChromiumPage {
  /// Borrow only an already-created retained native page. Useful for a profile
  /// maintenance barrier after its ordinary extension transport has closed.
  /// This never materializes a page or creates a replacement profile context.
  public func historyMirrorSession() async throws -> ChromeHistoryMirrorSession {
    guard !isPrivate, let native = browser, !native.isClosed else { throw ChromeExtensionError.managementUnavailable }
    let session = ChromeHistoryMirrorSession(profileID: profileID, browser: native)
    do {
      try await session.prepareObservation()
      guard browser === native, !native.isClosed else { throw CancellationError() }
      return session
    } catch { await session.close(); throw error }
  }
}
