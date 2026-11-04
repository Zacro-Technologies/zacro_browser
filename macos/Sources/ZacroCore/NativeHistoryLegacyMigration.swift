import CryptoKit
import Foundation

/// Ephemeral exact versions of pre-native Library rows. Only the opaque digest
/// is journalled; this snapshot never adds a second durable URL/title copy.
public struct NativeHistoryLegacyInput: Codable, Equatable, Sendable {
  public let profileID: String
  public let coreID: String
  public let address: String
  public let visitedAt: Date
  public let title: String
  public init(profileID: String, coreID: String, address: String, visitedAt: Date, title: String) {
    self.profileID = profileID; self.coreID = coreID; self.address = address
    self.visitedAt = visitedAt; self.title = title
  }
  public var importID: String {
    var data = Data("zacro-native-history-legacy-v1".utf8)
    for value in [profileID, coreID, address, String(visitedAt.timeIntervalSinceReferenceDate.bitPattern)] {
      let bytes = Data(value.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public var isValid: Bool {
    NativeProfileRetirement.validID(profileID) && NativeProfileRetirement.validID(coreID)
      && address.utf8.count <= 8192 && BrowserAddress.webURL(address)?.absoluteString == address
      && visitedAt.timeIntervalSince1970.isFinite && visitedAt.timeIntervalSince1970 > 0
      && nativeTimeMicroseconds != nil && title.utf8.count <= 8192
  }
  /// The wire and Core proof share this one conversion. Native SQL inserts
  /// exactly these Windows-epoch microseconds; no nearest-time matching or
  /// independently rounded timestamp can bind a different native visit.
  public var nativeTimeMicroseconds: String? {
    let value = (visitedAt.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
    guard value.isFinite, value > 0, value < 9_223_372_036_854_775_808 else { return nil }
    return String(Int64(value.rounded(.towardZero)))
  }
  public func matches(_ row: HistoryEntry) -> Bool {
    row.id == coreID && row.profileID == profileID && row.url == address && row.visitedAt == visitedAt
  }
}

/// A complete native SQL transaction returns one ordered result for every
/// requested import ID. Native absence includes the import journal tombstone;
/// it is never inferred by matching an address or a nearby visit timestamp.
public struct NativeHistoryLegacyImportResult: Codable, Equatable, Sendable {
  public let importID: String
  public let presence: NativeHistoryVerificationResult.Presence
  public let generation: String
  public let identity: NativeHistoryIdentity?
  /// Exact requested address checked against the native import journal hash.
  /// This ephemeral attestation permits native GURL canonicalization without
  /// replacing the real native identity with Foundation's spelling.
  public let sourceAddress: String?
  public let boundaryLeaseID: String?
  public init(importID: String, presence: NativeHistoryVerificationResult.Presence,
    generation: String, identity: NativeHistoryIdentity? = nil, sourceAddress: String? = nil,
    boundaryLeaseID: String? = nil) {
    self.importID = importID; self.presence = presence; self.generation = generation
    self.identity = identity; self.sourceAddress = sourceAddress; self.boundaryLeaseID = boundaryLeaseID
  }
}

/// Opaque local acknowledgement authority. URL and title intentionally do not
/// belong here: a cleared visit must not remain in receipts or recovery copies.
public struct NativeHistoryLegacyReceipt: Codable, Equatable, Sendable {
  public let profileID: String
  public let importID: String
  public let generation: String
  public init(profileID: String, importID: String, generation: String) {
    self.profileID = profileID; self.importID = importID; self.generation = generation
  }
  public var isValid: Bool {
    NativeProfileRetirement.validID(profileID)
      && importID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      && NativeHistoryLegacyValidation.validGeneration(generation)
  }
}

private enum NativeHistoryLegacyValidation {
  static func validGeneration(_ value: String) -> Bool {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 2, let database = UUID(uuidString: String(fields[0])),
      database.uuidString.lowercased() == fields[0], let counter = Int64(fields[1]), counter > 0 else { return false }
    return String(counter) == fields[1]
  }
}

extension BrowserStore {
  public func nativeHistoryLegacyInputs(profileID: String) -> [NativeHistoryLegacyInput] {
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      !state.pendingNativeProfileRetirements.contains(profileID) else { return [] }
    return state.history.filter { $0.profileID == profileID && state.nativeHistoryBindings[$0.id] == nil }
      .map { NativeHistoryLegacyInput(profileID: profileID, coreID: $0.id, address: $0.url,
        visitedAt: $0.visitedAt, title: $0.title) }
      .filter(\.isValid).sorted { $0.coreID < $1.coreID }.prefix(20_000).map { $0 }
  }

  public func nativeHistoryLegacyReceipts(profileID: String) -> [NativeHistoryLegacyReceipt] {
    state.nativeHistoryLegacyImportReceipts.values.filter { $0.profileID == profileID }
      .sorted { $0.importID < $1.importID }
  }

  /// Bind/remove only the captured unbound version and commit its native ack
  /// receipt in the same durable privacy transaction. A newer coalesced visit
  /// or title update is never replaced with stale native display metadata.
  @discardableResult public func applyNativeHistoryLegacyImportsDurably(profileID: String,
    inputs: [NativeHistoryLegacyInput], results: [NativeHistoryLegacyImportResult]) throws -> [NativeHistoryLegacyReceipt] {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.applyNativeHistoryLegacyImportsDurably(profileID: profileID, inputs: inputs, results: results)
    } }
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      !state.pendingNativeProfileRetirements.contains(profileID) else {
      throw NativeHistoryReconciliationError.invalidProfile
    }
    guard inputs.count <= 512, results.count == inputs.count,
      Set(inputs.map(\.coreID)).count == inputs.count,
      Set(results.map(\.importID)).count == results.count,
      inputs.allSatisfy({ $0.profileID == profileID && $0.isValid }) else {
      throw NativeHistoryReconciliationError.invalidSnapshot
    }
    var receipts: [NativeHistoryLegacyReceipt] = []
    var nativeVisits = Set<String>()
    var nativeDatabases = Set<String>()
    for (input, result) in zip(inputs, results) {
      let receipt = NativeHistoryLegacyReceipt(profileID: profileID, importID: input.importID, generation: result.generation)
      guard result.importID == input.importID, receipt.isValid,
        result.sourceAddress.map({ $0 == input.address }) ?? true,
        result.boundaryLeaseID.map(NativeHistoryLegacyBoundaryReceipt.validLease) ?? true else {
        throw NativeHistoryReconciliationError.invalidSnapshot
      }
      if let boundary = state.nativeHistoryLegacyBoundaries[input.importID],
        boundary.profileID != profileID || boundary.leaseID != result.boundaryLeaseID {
        throw NativeHistoryReconciliationError.changedSnapshot
      }
      // A delete-all epoch may leave an old tombstone beside a new import in
      // one transaction. Counters may differ; the exact database UUID may not.
      nativeDatabases.insert(String(result.generation.split(separator: ":")[0]))
      guard nativeDatabases.count == 1 else { throw NativeHistoryReconciliationError.invalidSnapshot }
      if result.presence == .error { throw NativeHistoryReconciliationError.unavailableDatabase }
      switch result.presence {
      case .present:
        guard let identity = result.identity, identity.isValid, identity.generation == result.generation,
          let requestedTime = input.nativeTimeMicroseconds, identity.timeMicroseconds == requestedTime,
          (identity.url == input.address || result.sourceAddress == input.address),
          nativeVisits.insert(identity.generation + ":" + identity.visitID).inserted else {
          throw NativeHistoryReconciliationError.invalidSnapshot
        }
      case .absent:
        guard result.identity == nil else { throw NativeHistoryReconciliationError.invalidSnapshot }
      case .error: break // Rejected above, before any candidate mutation.
      }
      if let old = state.nativeHistoryLegacyImportReceipts[input.importID], old != receipt {
        throw NativeHistoryReconciliationError.changedSnapshot
      }
      receipts.append(receipt)
    }
    let newIDs = Set(receipts.map(\.importID)).subtracting(state.nativeHistoryLegacyImportReceipts.keys)
    guard state.nativeHistoryLegacyImportReceipts.count + newIDs.count <= 20_000 else {
      throw NativeHistoryReconciliationError.incompleteSnapshot
    }
    guard !inputs.isEmpty else { return [] }
    try commit(purgeRecovery: true) { candidate in
      for (index, input) in inputs.enumerated() {
        let result = results[index]
        if candidate.nativeHistoryBindings[input.coreID] == nil,
          let rowIndex = candidate.history.firstIndex(where: input.matches) {
          switch result.presence {
          case .present:
            if let identity = result.identity {
              candidate.nativeHistoryBindings[input.coreID] = NativeHistoryBinding(coreID: input.coreID,
                profileID: profileID, coreAddress: input.address, coreVisitedAt: input.visitedAt, identity: identity)
            }
          case .absent: candidate.history.remove(at: rowIndex)
          case .error: break
          }
        }
        candidate.nativeHistoryLegacyImportReceipts[input.importID] = receipts[index]
        if let boundary = candidate.nativeHistoryLegacyBoundaries[input.importID],
          boundary.profileID == profileID, boundary.leaseID == result.boundaryLeaseID {
          candidate.nativeHistoryLegacyBoundaries.removeValue(forKey: input.importID)
        }
      }
    }
    return receipts
  }

  public func acknowledgeNativeHistoryLegacyReceiptsDurably(_ receipts: [NativeHistoryLegacyReceipt]) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.acknowledgeNativeHistoryLegacyReceiptsDurably(receipts)
    } }
    guard receipts.count <= 512, Set(receipts.map(\.importID)).count == receipts.count,
      receipts.allSatisfy(\.isValid) else { throw NativeHistoryReconciliationError.invalidSnapshot }
    let matching = receipts.filter { state.nativeHistoryLegacyImportReceipts[$0.importID] == $0 }
    guard !matching.isEmpty else { return }
    try commit(purgeRecovery: true) { candidate in
      for receipt in matching { candidate.nativeHistoryLegacyImportReceipts.removeValue(forKey: receipt.importID) }
    }
  }

  static func normalizeNativeHistoryLegacyMetadata(_ state: inout BrowserState) {
    normalizeNativeHistoryLegacyBoundaries(&state)
    let publicProfiles = Set(state.profiles.filter { !$0.isPrivate }.map(\.id))
      .subtracting(state.pendingNativeProfileRetirements)
    state.nativeHistoryLegacyImportReceipts = state.nativeHistoryLegacyImportReceipts.filter { key, receipt in
      key == receipt.importID && receipt.isValid && publicProfiles.contains(receipt.profileID)
    }
  }
}
