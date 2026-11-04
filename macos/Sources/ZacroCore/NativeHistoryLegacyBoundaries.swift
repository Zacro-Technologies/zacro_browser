import Foundation

/// An opaque native deletion boundary, durably associated with one exact
/// unbound Core visit version. It contains no address, title or copied history.
public struct NativeHistoryLegacyBoundaryReceipt: Codable, Equatable, Sendable {
  public let profileID: String
  public let importID: String
  public let leaseID: String
  public init(profileID: String, importID: String, leaseID: String) {
    self.profileID = profileID; self.importID = importID; self.leaseID = leaseID
  }
  public var isValid: Bool {
    NativeProfileRetirement.validID(profileID)
      && importID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      && Self.validLease(leaseID)
  }
  static func validLease(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }
}

extension BrowserStore {
  public func nativeHistoryLegacyBoundaries(profileID: String) -> [NativeHistoryLegacyBoundaryReceipt] {
    let current = Set(nativeHistoryLegacyInputs(profileID: profileID).map(\.importID))
    return state.nativeHistoryLegacyBoundaries.values.filter {
      $0.profileID == profileID && $0.isValid && current.contains($0.importID)
    }.sorted { $0.importID < $1.importID }
  }

  /// Install one captured snapshot before submitting any of its native imports.
  /// A prior exact visit boundary wins: replacing it with a later boundary
  /// would forget a native deletion that occurred while the old one was held.
  @discardableResult public func assignNativeHistoryLegacyBoundaryDurably(profileID: String,
    inputs: [NativeHistoryLegacyInput], leaseID: String) throws -> [NativeHistoryLegacyBoundaryReceipt] {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.assignNativeHistoryLegacyBoundaryDurably(profileID: profileID, inputs: inputs, leaseID: leaseID)
    } }
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      !state.pendingNativeProfileRetirements.contains(profileID) else { throw NativeHistoryReconciliationError.invalidProfile }
    guard NativeHistoryLegacyBoundaryReceipt.validLease(leaseID), inputs.count <= 20_000,
      Set(inputs.map(\.coreID)).count == inputs.count,
      inputs.allSatisfy({ $0.profileID == profileID && $0.isValid }) else {
      throw NativeHistoryReconciliationError.invalidSnapshot
    }
    var normalized = state
    Self.normalizeNativeHistoryLegacyBoundaries(&normalized)
    let rows = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0) })
    var receipts: [NativeHistoryLegacyBoundaryReceipt] = []
    for input in inputs where state.nativeHistoryBindings[input.coreID] == nil
      && rows[input.coreID].map(input.matches) == true {
      if let previous = normalized.nativeHistoryLegacyBoundaries[input.importID] {
        guard previous.isValid, previous.profileID == profileID, previous.importID == input.importID else {
          throw NativeHistoryReconciliationError.invalidSnapshot
        }
        receipts.append(previous)
      } else {
        receipts.append(.init(profileID: profileID, importID: input.importID, leaseID: leaseID))
      }
    }
    let additions = Set(receipts.map(\.importID)).subtracting(normalized.nativeHistoryLegacyBoundaries.keys)
    guard normalized.nativeHistoryLegacyBoundaries.count + additions.count <= 20_000 else {
      throw NativeHistoryReconciliationError.incompleteSnapshot
    }
    guard !receipts.isEmpty else { return [] }
    try commit(purgeRecovery: true) { candidate in
      candidate.nativeHistoryLegacyBoundaries = normalized.nativeHistoryLegacyBoundaries
      for receipt in receipts { candidate.nativeHistoryLegacyBoundaries[receipt.importID] = receipt }
    }
    return receipts
  }

  static func normalizeNativeHistoryLegacyBoundaries(_ state: inout BrowserState) {
    let profiles = Set(state.profiles.filter { !$0.isPrivate }.map(\.id)).subtracting(state.pendingNativeProfileRetirements)
    var current: [String: String] = [:]
    for row in state.history where profiles.contains(row.profileID) && state.nativeHistoryBindings[row.id] == nil {
      let input = NativeHistoryLegacyInput(profileID: row.profileID, coreID: row.id,
        address: row.url, visitedAt: row.visitedAt, title: row.title)
      if input.isValid { current[input.importID] = row.profileID }
    }
    state.nativeHistoryLegacyBoundaries = state.nativeHistoryLegacyBoundaries.filter { key, receipt in
      key == receipt.importID && receipt.isValid && current[key] == receipt.profileID
    }
  }
}
