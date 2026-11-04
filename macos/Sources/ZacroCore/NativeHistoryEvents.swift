import Foundation

/// Native journal sequence is a decimal string for lossless protocol transport.
/// Only the native-owned, checked-commit event reader supplies these records.
public struct NativeHistoryVisitEvent: Codable, Equatable, Sendable {
  public let eventID: String
  public let documentToken: String
  public let logicalID: String
  public let sequence: String
  public let publish: Bool
  public let libraryVisit: Bool
  public let presence: NativeHistoryVerificationResult.Presence
  public let identity: NativeHistoryIdentity?
  public let title: String
  public init(eventID: String, documentToken: String, logicalID: String, sequence: String,
    publish: Bool, presence: NativeHistoryVerificationResult.Presence,
    identity: NativeHistoryIdentity?, title: String = "", libraryVisit: Bool = true) {
    self.eventID = eventID; self.documentToken = documentToken; self.logicalID = logicalID
    self.sequence = sequence; self.publish = publish; self.presence = presence
    self.identity = identity; self.title = title; self.libraryVisit = libraryVisit
  }
  public var isValid: Bool {
    guard UUID(uuidString: eventID) != nil, UUID(uuidString: documentToken) != nil,
      let sequenceValue = Int64(sequence), sequenceValue > 0, String(sequenceValue) == sequence,
      !logicalID.isEmpty, logicalID.utf8.count <= 1024,
      !logicalID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      title.utf8.count <= 8192 else { return false }
    switch presence {
    case .present: return identity?.isValid == true
    case .absent: return identity == nil
    case .error: return false
    }
  }
}

public struct NativeHistoryVisitReceipt: Codable, Equatable, Sendable {
  public let profileID: String
  public let eventID: String
  public let documentToken: String
  public let sequence: String
  public let coreID: String?
}

extension BrowserStore {
  public func nativeHistoryVisitReceipts(profileID: String) -> [NativeHistoryVisitReceipt] {
    state.nativeHistoryVisitReceipts.values.filter { $0.profileID == profileID }
      .sorted { (Int64($0.sequence) ?? 0) < (Int64($1.sequence) ?? 0) }
  }

  /// Replay a complete checked native journal page atomically. A Core receipt
  /// survives a crash before native ack and prevents a second visit on replay.
  /// This operation cannot publish a transient Peek; promotion is separate.
  public func applyNativeHistoryVisitEventsDurably(profileID: String,
    events: [NativeHistoryVisitEvent]) throws -> [NativeHistoryVisitReceipt] {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.applyNativeHistoryVisitEventsDurably(profileID: profileID, events: events)
    } }
    try Self.validateNativeHistoryEvents(events, profileID: profileID, in: state)
    var candidate = state
    var receipts: [NativeHistoryVisitReceipt] = []
    for event in events where event.publish || (event.presence == .absent && candidate.nativeHistoryVisitReceipts[event.eventID] != nil) {
      receipts.append(try Self.applyNativeHistoryVisitEvent(event, profileID: profileID, to: &candidate))
    }
    // A successful native absence may remove an already committed event whose
    // ack was lost. Sanitize recovery copies in that same deletion transaction.
    try commit(purgeRecovery: events.contains { $0.presence == .absent }) { $0 = candidate }
    return receipts
  }

  public func acknowledgeNativeHistoryVisitReceiptsDurably(_ receipts: [NativeHistoryVisitReceipt]) throws {
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.acknowledgeNativeHistoryVisitReceiptsDurably(receipts)
    } }
    guard receipts.count <= 512 else { throw NativeHistoryReconciliationError.invalidSnapshot }
    try commit { state in
      for receipt in receipts where state.nativeHistoryVisitReceipts[receipt.eventID] == receipt {
        state.nativeHistoryVisitReceipts.removeValue(forKey: receipt.eventID)
      }
    }
  }

  static func validateNativeHistoryEvents(_ events: [NativeHistoryVisitEvent], profileID: String,
    in state: BrowserState) throws {
    guard state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }),
      !state.pendingNativeProfileRetirements.contains(profileID) else {
      throw NativeHistoryReconciliationError.invalidProfile
    }
    guard events.count <= 512, Set(events.map(\.eventID)).count == events.count,
      events.allSatisfy(\.isValid), zip(events, events.dropFirst()).allSatisfy({ pair in
        (Int64(pair.0.sequence) ?? 0) < (Int64(pair.1.sequence) ?? 0)
      }) else { throw NativeHistoryReconciliationError.invalidSnapshot }
  }

  /// Also used inside the existing durable Peek promotion transaction after
  /// exact native document/token/URL validation. No native call occurs here.
  static func applyNativeHistoryVisitEvent(_ event: NativeHistoryVisitEvent,
    profileID: String, to state: inout BrowserState, forceLibraryVisit: Bool = false) throws -> NativeHistoryVisitReceipt {
    if let receipt = state.nativeHistoryVisitReceipts[event.eventID] {
      guard receipt.profileID == profileID, receipt.documentToken == event.documentToken,
        receipt.sequence == event.sequence else { throw NativeHistoryReconciliationError.invalidSnapshot }
      if event.presence == .absent, let id = receipt.coreID,
        let binding = state.nativeHistoryBindings[id], binding.eventID == event.eventID,
        let index = state.history.firstIndex(where: binding.matches) {
        state.history.remove(at: index); state.nativeHistoryBindings.removeValue(forKey: id)
      }
      return receipt
    }
    guard state.nativeHistoryVisitReceipts.count < 20_000 else {
      throw NativeHistoryReconciliationError.incompleteSnapshot
    }
    var coreID: String?
    if event.presence == .present, event.libraryVisit || forceLibraryVisit, let identity = event.identity {
      guard let microseconds = Int64(identity.timeMicroseconds) else {
        throw NativeHistoryReconciliationError.invalidSnapshot
      }
      let date = Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
      guard let id = appendHistoryVisit(to: &state, profileID: profileID,
        address: identity.url, title: event.title, visitedAt: date, historical: true) else {
        throw NativeHistoryReconciliationError.invalidSnapshot
      }
      // Old replay outside the existing 20,000-row Library retention limit is
      // still durably consumed. Its receipt has no row, so it cannot delete one.
      if let row = state.history.first(where: { $0.id == id }) {
        state.nativeHistoryBindings[id] = NativeHistoryBinding(coreID: id, profileID: profileID,
          coreAddress: row.url, coreVisitedAt: row.visitedAt, identity: identity, eventID: event.eventID)
        coreID = id
      }
    }
    let receipt = NativeHistoryVisitReceipt(profileID: profileID, eventID: event.eventID,
      documentToken: event.documentToken, sequence: event.sequence, coreID: coreID)
    state.nativeHistoryVisitReceipts[event.eventID] = receipt
    return receipt
  }
}
