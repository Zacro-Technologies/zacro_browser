import Foundation

/// Local Chromium database authority. Never carried by portable collections or
/// sync. Decimal strings preserve Chromium's signed 64-bit identifiers/times.
public struct NativeHistoryIdentity: Codable, Equatable, Sendable {
  public let generation: String
  public let visitID: String
  public let timeMicroseconds: String
  public let url: String
  public let originator: String
  public init(generation: String, visitID: String, timeMicroseconds: String, url: String, originator: String = "") {
    self.generation = generation; self.visitID = visitID; self.timeMicroseconds = timeMicroseconds
    self.url = url; self.originator = originator
  }
  public var isValid: Bool {
    Self.validGeneration(generation) && Self.positiveDecimal(visitID)
      && Self.positiveDecimal(timeMicroseconds) && url.utf8.count <= 8192
      && URL(string: url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && $0.user == nil && $0.password == nil } == true
      && originator.utf8.count <= 256 && !originator.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
  private static func positiveDecimal(_ value: String) -> Bool {
    guard let number = Int64(value), number > 0 else { return false }
    return String(number) == value
  }
  private static func validGeneration(_ value: String) -> Bool {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 2, let database = UUID(uuidString: String(fields[0])),
      database.uuidString.lowercased() == fields[0] else { return false }
    return positiveDecimal(String(fields[1]))
  }
}

public struct NativeHistoryBinding: Codable, Equatable, Sendable {
  public let coreID: String
  public let profileID: String
  public let coreAddress: String
  public let coreVisitedAt: Date
  public let identity: NativeHistoryIdentity
  public let eventID: String?
  public init(coreID: String, profileID: String, coreAddress: String, coreVisitedAt: Date, identity: NativeHistoryIdentity, eventID: String? = nil) {
    self.coreID = coreID; self.profileID = profileID; self.coreAddress = coreAddress
    self.coreVisitedAt = coreVisitedAt; self.identity = identity; self.eventID = eventID
  }
  public func matches(_ row: HistoryEntry) -> Bool {
    row.id == coreID && row.profileID == profileID && row.url == coreAddress && row.visitedAt == coreVisitedAt
  }
}

public struct NativeHistoryAcknowledgement: Codable, Equatable, Sendable {
  public let profileID: String
  public let lease: String
  public let revision: String
  public init(profileID: String, lease: String, revision: String) {
    self.profileID = profileID; self.lease = lease; self.revision = revision
  }
}

public struct NativeHistoryVerificationResult: Codable, Equatable, Sendable {
  public enum Presence: String, Codable, Sendable { case present, absent, error }
  public let input: NativeHistoryBinding
  public let presence: Presence
  public let title: String?
  public init(input: NativeHistoryBinding, presence: Presence, title: String? = nil) {
    self.input = input; self.presence = presence; self.title = title
  }
}
public struct NativeHistoryVerificationPage: Codable, Equatable, Sendable {
  public let lease: String
  public let revision: String
  public let offset: Int
  public let complete: Bool
  public let results: [NativeHistoryVerificationResult]
  public init(lease: String, revision: String, offset: Int, complete: Bool, results: [NativeHistoryVerificationResult]) {
    self.lease = lease; self.revision = revision; self.offset = offset; self.complete = complete; self.results = results
  }
}
public enum NativeHistoryReconciliationError: Error, LocalizedError {
  case invalidSnapshot, incompleteSnapshot, changedSnapshot, unavailableDatabase, invalidProfile
  public var errorDescription: String? {
    switch self {
    case .invalidSnapshot: return "Chromium returned an invalid history verification response. No Library visits were removed."
    case .incompleteSnapshot: return "Chromium did not verify every Library visit. Retry history synchronization."
    case .changedSnapshot: return "The native history changed during verification. Retry history synchronization."
    case .unavailableDatabase: return "Chromium could not read its history database. Existing Library history was preserved."
    case .invalidProfile: return "The public profile is no longer available."
    }
  }
}

public enum NativeHistoryVerification {
  public static func absentBindings(inputs: [NativeHistoryBinding], pages: [NativeHistoryVerificationPage],
      profileID: String, lease: String, revision: String, confirmedRevision: String) throws -> [NativeHistoryBinding] {
    guard UUID(uuidString: lease) != nil, !revision.isEmpty, revision.utf8.count <= 128,
      inputs.count <= 20_000, Set(inputs.map(\.coreID)).count == inputs.count,
      inputs.allSatisfy({ $0.profileID == profileID && $0.identity.isValid }) else {
      throw NativeHistoryReconciliationError.invalidSnapshot
    }
    guard revision == confirmedRevision else { throw NativeHistoryReconciliationError.changedSnapshot }
    var offset = 0, finished = false, missing: [NativeHistoryBinding] = []
    for page in pages {
      guard !finished, page.lease == lease, page.revision == revision, page.offset == offset,
        page.results.count <= 512, offset + page.results.count <= inputs.count,
        !page.results.isEmpty || (inputs.isEmpty && page.complete) else {
        throw NativeHistoryReconciliationError.invalidSnapshot
      }
      for result in page.results {
        guard result.input == inputs[offset], result.title.map({ $0.utf8.count <= 8192 }) ?? true else {
          throw NativeHistoryReconciliationError.invalidSnapshot
        }
        switch result.presence {
        case .present: break
        case .absent: missing.append(result.input)
        case .error: throw NativeHistoryReconciliationError.unavailableDatabase
        }
        offset += 1
      }
      finished = page.complete
      if finished && offset != inputs.count { throw NativeHistoryReconciliationError.incompleteSnapshot }
    }
    guard finished, offset == inputs.count else { throw NativeHistoryReconciliationError.incompleteSnapshot }
    return missing
  }
}

extension BrowserStore {
  public func nativeHistoryBindings(profileID: String) -> [NativeHistoryBinding] {
    let rows = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0) })
    return state.nativeHistoryBindings.values.filter { binding in
      binding.profileID == profileID && rows[binding.coreID].map(binding.matches) == true
    }.sorted { $0.coreID < $1.coreID }
  }
  public var nativeHistoryAcknowledgements: [NativeHistoryAcknowledgement] {
    Array(state.pendingNativeHistoryAcknowledgements.values)
  }

  /// Binds a known Core visit only when its exact captured version still exists.
  /// The caller must have matched the native document/navigation token; matching
  /// an address or a nearest timestamp is never sufficient authorization.
  @discardableResult public func bindNativeHistoryVisitDurably(_ binding: NativeHistoryBinding) throws -> Bool {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.bindNativeHistoryVisitDurably(binding)
    } }
    guard binding.identity.isValid,
      state.profiles.contains(where: { $0.id == binding.profileID && !$0.isPrivate }),
      state.history.contains(where: binding.matches) else { return false }
    try commit { $0.nativeHistoryBindings[binding.coreID] = binding }
    return true
  }

  /// The only history-deletion mutation used by native reconciliation. It does
  /// not touch tabs, archive, Peek navigation, native history, or encrypted vaults.
  @discardableResult public func applyNativeHistoryVerificationDurably(profileID: String,
      inputs: [NativeHistoryBinding], pages: [NativeHistoryVerificationPage], lease: String,
      revision: String, confirmedRevision: String) throws -> Int {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.applyNativeHistoryVerificationDurably(profileID: profileID, inputs: inputs, pages: pages,
        lease: lease, revision: revision, confirmedRevision: confirmedRevision)
    } }
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      !state.pendingNativeProfileRetirements.contains(profileID) else { throw NativeHistoryReconciliationError.invalidProfile }
    let missing = try NativeHistoryVerification.absentBindings(inputs: inputs, pages: pages,
      profileID: profileID, lease: lease, revision: revision, confirmedRevision: confirmedRevision)
    var removed = 0
    try commit(purgeRecovery: true) { state in
      let rows = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0) })
      let ids = Set(missing.filter { state.nativeHistoryBindings[$0.coreID] == $0
        && rows[$0.coreID].map($0.matches) == true }.map(\.coreID))
      removed = ids.count
      state.history.removeAll { ids.contains($0.id) }
      for id in ids { state.nativeHistoryBindings.removeValue(forKey: id) }
      // Metadata updates never create visits or bind by URL. Only the same
      // captured native visit may update its existing Library display title.
      for result in pages.flatMap(\.results) where result.presence == .present {
        guard let title = result.title, state.nativeHistoryBindings[result.input.coreID] == result.input,
          let index = state.history.firstIndex(where: result.input.matches) else { continue }
        let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if !value.isEmpty { state.history[index].title = value }
      }
      state.pendingNativeHistoryAcknowledgements[profileID] = .init(profileID: profileID, lease: lease, revision: revision)
    }
    return removed
  }

  public func acknowledgeNativeHistoryVerificationDurably(_ receipt: NativeHistoryAcknowledgement) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.acknowledgeNativeHistoryVerificationDurably(receipt)
    } }
    guard state.pendingNativeHistoryAcknowledgements[receipt.profileID] == receipt else { return }
    try commit { $0.pendingNativeHistoryAcknowledgements.removeValue(forKey: receipt.profileID) }
  }

  static func normalizeNativeHistoryMetadata(_ state: inout BrowserState) {
    normalizeNativeHistoryLegacyMetadata(&state)
    let publicProfiles = Set(state.profiles.filter { !$0.isPrivate }.map(\.id))
    let rows = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0) })
    state.nativeHistoryPublicationReceipts = state.nativeHistoryPublicationReceipts.filter { id, receipt in
      id == receipt.leaseID && receipt.isValid && publicProfiles.contains(receipt.profileID)
    }
    state.nativeHistoryBindings = state.nativeHistoryBindings.filter { id, binding in
      id == binding.coreID && publicProfiles.contains(binding.profileID) && binding.identity.isValid
        && rows[binding.coreID].map(binding.matches) == true
    }
    state.nativeHistoryVisitReceipts = state.nativeHistoryVisitReceipts.filter { id, receipt in
      id == receipt.eventID && publicProfiles.contains(receipt.profileID)
        && UUID(uuidString: receipt.eventID) != nil && UUID(uuidString: receipt.documentToken) != nil
        && Int64(receipt.sequence).map { $0 > 0 && String($0) == receipt.sequence } == true
    }
    state.pendingNativeHistoryAcknowledgements = state.pendingNativeHistoryAcknowledgements.filter { id, receipt in
      id == receipt.profileID && publicProfiles.contains(id) && UUID(uuidString: receipt.lease) != nil
        && !receipt.revision.isEmpty && receipt.revision.utf8.count <= 128
    }
  }
}
