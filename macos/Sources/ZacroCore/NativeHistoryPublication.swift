import Foundation

/// A native-prepared publication boundary, not permission inferred from a URL.
/// The native owner captures this before Core adoption/promotion. Its pending
/// journal preserves subsequent commits until the durable receipt is replayed.
public struct NativeHistoryPublication: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case popup, preview }
  public let leaseID: String
  public let documentToken: String
  public let profileID: String
  public let kind: Kind
  public let capturedEvent: NativeHistoryVisitEvent?
  public init(leaseID: String, documentToken: String, profileID: String,
    kind: Kind, capturedEvent: NativeHistoryVisitEvent? = nil) {
    self.leaseID = leaseID; self.documentToken = documentToken; self.profileID = profileID
    self.kind = kind; self.capturedEvent = capturedEvent
  }
  public var isValid: Bool {
    guard UUID(uuidString: leaseID)?.uuidString.lowercased() == leaseID,
      UUID(uuidString: documentToken)?.uuidString.lowercased() == documentToken,
      NativeProfileRetirement.validID(profileID) else { return false }
    if let capturedEvent {
      return kind == .preview && capturedEvent.isValid && !capturedEvent.publish
        && capturedEvent.documentToken == documentToken
    }
    return true
  }
}

/// Authored only with the actual model adoption/promotion transaction. It is
/// excluded from portable state and remains after the tab closes: publication
/// records a past user action, never authority to reopen a document or profile.
public struct NativeHistoryPublicationReceipt: Codable, Equatable, Sendable {
  public let publication: NativeHistoryPublication
  public let logicalID: String
  public let ownerWindowID: String
  public let createdAt: Date
  public var leaseID: String { publication.leaseID }
  public var profileID: String { publication.profileID }
  public init(publication: NativeHistoryPublication, logicalID: String,
    ownerWindowID: String, createdAt: Date) {
    // The native lease already retains its event boundary. A durable receipt
    // needs opaque IDs only, never an extra URL/title copy after history clear.
    self.publication = NativeHistoryPublication(leaseID: publication.leaseID,
      documentToken: publication.documentToken, profileID: publication.profileID,
      kind: publication.kind)
    self.logicalID = logicalID
    self.ownerWindowID = ownerWindowID; self.createdAt = createdAt
  }
  public var isValid: Bool {
    publication.isValid && publication.capturedEvent == nil && NativeProfileRetirement.validID(logicalID)
      && NativeProfileRetirement.validID(ownerWindowID) && createdAt.timeIntervalSince1970.isFinite
  }
}

extension BrowserStore {
  public func nativeHistoryPublicationReceipts(profileID: String) -> [NativeHistoryPublicationReceipt] {
    state.nativeHistoryPublicationReceipts.values.filter { $0.profileID == profileID }
      .sorted { $0.leaseID < $1.leaseID }
  }

  /// The tab and receipt are one durable write. The caller must already have
  /// acquired this lease on the exact native popup, and must cancel it if this
  /// method fails. No history row is guessed from the popup's address/title.
  @discardableResult public func adoptNativeHistoryPopupDurably(_ tab: BrowserTab,
    publication: NativeHistoryPublication, activate: Bool = false) throws -> BrowserTab {
    guard owningWindowID == nil || owningWindowID == tab.windowID else {
      throw NativeHistoryReconciliationError.invalidProfile
    }
    if let repository {
      return try repository.commitState { state in
        try Self.adoptNativeHistoryPopupCandidate(tab, publication: publication, activate: activate, state: &state)
      }
    }
    var candidate = state
    let result = try Self.adoptNativeHistoryPopupCandidate(tab, publication: publication,
      activate: activate, state: &candidate)
    try commit { $0 = candidate }
    return result
  }

  /// Native promotion has a publication boundary prepared on the retained
  /// WebContents. Its captured visit and all later pending events belong to
  /// the same user action, even if another navigation commits during the await.
  @discardableResult public func promoteNativeHistoryPeekDurably(tabID: String,
    publication: NativeHistoryPublication, activate: Bool = true) throws -> BrowserTab {
    guard let source = tab(tabID), let owner = source.windowID,
      owningWindowID == nil || owningWindowID == owner else {
      throw NativeHistoryReconciliationError.invalidProfile
    }
    if let repository {
      return try repository.commitState { state in
        try Self.promoteNativeHistoryPeekCandidate(tabID: tabID, ownerID: owner,
          publication: publication, activate: activate, state: &state)
      }
    }
    var candidate = state
    let promoted = try Self.promoteNativeHistoryPeekCandidate(tabID: tabID, ownerID: owner,
      publication: publication, activate: activate, state: &candidate)
    try commit { $0 = candidate }
    return promoted
  }

  public func acknowledgeNativeHistoryPublicationsDurably(_ receipts: [NativeHistoryPublicationReceipt]) throws {
    guard receipts.count <= 512 else { throw NativeHistoryReconciliationError.invalidSnapshot }
    if let repository { return try repository.mutateDurably(windowID: owningWindowID) {
      try $0.acknowledgeNativeHistoryPublicationsDurably(receipts)
    } }
    // Native may finalize the lease only after this succeeds. A recovery copy
    // must not revive a receipt after its native idempotency record is removed.
    try commit(purgeRecovery: true) { state in
      for receipt in receipts where state.nativeHistoryPublicationReceipts[receipt.leaseID] == receipt {
        state.nativeHistoryPublicationReceipts.removeValue(forKey: receipt.leaseID)
      }
    }
  }

  static func adoptNativeHistoryPopupCandidate(_ tab: BrowserTab,
    publication: NativeHistoryPublication, activate: Bool, state: inout BrowserState) throws -> BrowserTab {
    guard publication.kind == .popup, publication.isValid,
      !tab.isClosed, !tab.isPinned, !tab.isFavorite, tab.peek == nil,
      let owner = tab.windowID,
      let windowIndex = state.windowSessions?.firstIndex(where: { $0.id == owner && $0.isOpen }),
      state.profiles.contains(where: { $0.id == publication.profileID && !$0.isPrivate }),
      !state.pendingNativeProfileRetirements.contains(publication.profileID),
      state.spaces.contains(where: { $0.id == tab.spaceID && $0.profileID == publication.profileID }),
      BrowserAddress.documentURL(tab.url, provenance: tab.nativeNavigation) != nil,
      state.tabs.count < 1_000,
      !state.tabs.contains(where: { $0.id == tab.id }), !state.archive.contains(where: { $0.id == tab.id }) else {
      throw NativeHistoryReconciliationError.invalidProfile
    }
    let receipt = NativeHistoryPublicationReceipt(publication: publication, logicalID: tab.id,
      ownerWindowID: owner, createdAt: tab.createdAt)
    try insertNativeHistoryPublicationReceipt(receipt, into: &state)
    state.tabs.append(tab)
    if activate {
      state.windowSessions![windowIndex].activeSpaceID = tab.spaceID
      state.windowSessions![windowIndex].activeTabID = tab.id
      state.windowSessions![windowIndex].highlightedTabIDs = [tab.id]
      state.windowSessions![windowIndex].lastActiveTabBySpace[tab.spaceID] = tab.id
      if state.focusedWindowID == owner {
        state.activeSpaceID = tab.spaceID; state.activeTabID = tab.id
      }
    }
    return tab
  }

  static func insertNativeHistoryPublicationReceipt(_ receipt: NativeHistoryPublicationReceipt,
    into state: inout BrowserState) throws {
    guard receipt.isValid, state.nativeHistoryPublicationReceipts.count < 1_000,
      state.nativeHistoryPublicationReceipts[receipt.leaseID] == nil,
      !state.nativeHistoryPublicationReceipts.values.contains(where: {
        $0.publication.documentToken == receipt.publication.documentToken
      }) else { throw NativeHistoryReconciliationError.invalidSnapshot }
    state.nativeHistoryPublicationReceipts[receipt.leaseID] = receipt
  }

  static func promoteNativeHistoryPeekCandidate(tabID: String, ownerID: String,
    publication: NativeHistoryPublication, activate: Bool, state: inout BrowserState) throws -> BrowserTab {
    guard publication.kind == .preview, publication.isValid,
      let index = state.tabs.firstIndex(where: { $0.id == tabID && !$0.isClosed && $0.windowID == ownerID }),
      let windowIndex = state.windowSessions?.firstIndex(where: { $0.id == ownerID && $0.isOpen }),
      state.spaces.contains(where: { $0.id == state.tabs[index].spaceID && $0.profileID == publication.profileID }),
      state.tabs.count < 1_000, var promoted = state.tabs[index].peekDocument,
      BrowserAddress.documentURL(promoted.url, provenance: promoted.nativeNavigation) != nil,
      publication.capturedEvent.map({ $0.logicalID == "peek:" + tabID }) ?? true else {
      throw NativeHistoryReconciliationError.invalidProfile
    }
    try validateNativeHistoryEvents(publication.capturedEvent.map { [$0] } ?? [],
      profileID: publication.profileID, in: state)
    promoted.id = UUID().uuidString; promoted.lastAccessedAt = Date()
    let receipt = NativeHistoryPublicationReceipt(publication: publication,
      logicalID: promoted.id, ownerWindowID: ownerID, createdAt: promoted.createdAt)
    try insertNativeHistoryPublicationReceipt(receipt, into: &state)
    if let event = publication.capturedEvent {
      _ = try applyNativeHistoryVisitEvent(event, profileID: publication.profileID, to: &state, forceLibraryVisit: true)
    }
    state.tabs[index].peek = nil
    state.tabs.insert(promoted, at: index + 1)
    for i in state.tabs.indices where state.tabs[i].openerTabID == "peek:" + tabID {
      state.tabs[i].openerTabID = promoted.id
    }
    if activate {
      state.windowSessions![windowIndex].activeSpaceID = promoted.spaceID
      state.windowSessions![windowIndex].activeTabID = promoted.id
      state.windowSessions![windowIndex].highlightedTabIDs = [promoted.id]
      state.windowSessions![windowIndex].lastActiveTabBySpace[promoted.spaceID] = promoted.id
      if state.focusedWindowID == ownerID {
        state.activeSpaceID = promoted.spaceID; state.activeTabID = promoted.id
      }
    }
    return promoted
  }
}
