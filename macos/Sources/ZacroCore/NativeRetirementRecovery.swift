import Foundation

/// A snapshot is captured only from an owned live
/// page while its exact Core identity still exists; never from imports or URLs.
public struct NativeRetirementSnapshot {
  public let pageID: String
  public let profileID: String
  public let isPrivate: Bool
  public let ownerWindowID: String
  public let source: BrowserTab
  public let preview: SavedPeek?
  public let splits: [SplitGroup]

  public init(pageID: String, profileID: String, isPrivate: Bool, ownerWindowID: String,
    source: BrowserTab, preview: SavedPeek?, splits: [SplitGroup]) {
    self.pageID = pageID; self.profileID = profileID; self.isPrivate = isPrivate
    self.ownerWindowID = ownerWindowID; self.source = source; self.preview = preview; self.splits = splits
  }

  var isPreview: Bool { pageID == "peek:" + source.id }
}

enum NativeRetirementRecoveryError: LocalizedError {
  case invalidSnapshot, profileUnavailable, windowUnavailable, spaceUnavailable
  case identityConflict, previewChanged, tabLimit
  var errorDescription: String? {
    switch self {
    case .invalidSnapshot: return "The live document does not have a valid recovery record."
    case .profileUnavailable: return "The original profile is unavailable. The live document has been retained."
    case .windowUnavailable: return "The original window is no longer open."
    case .spaceUnavailable: return "The original profile has no available Space."
    case .identityConflict: return "Another document now owns this saved tab identity."
    case .previewChanged: return "A different Peek now belongs to this source tab."
    case .tabLimit: return "Close another tab before recovering this live document."
    }
  }
}

extension BrowserStore {
  /// Internal native-lifecycle recovery. The host supplies a snapshot retained
  /// from this exact live page, never a user-imported or persisted authority.
  @discardableResult public func recoverRetiringDocumentDurably(_ snapshot: NativeRetirementSnapshot) throws -> BrowserTab {
    guard owningWindowID == nil || owningWindowID == snapshot.ownerWindowID else {
      throw NativeRetirementRecoveryError.windowUnavailable
    }
    if let repository {
      // Recovery needs the actual sessions, including a background owner's
      // open state. The ordinary reducer deliberately removes that metadata
      // and assigns new rows to its focused window; neither is valid here.
      return try repository.commitState { shared in
        let recovery = try NativeRetirementRecovery.normalizedCandidate(shared,
          snapshot: snapshot, directory: directory)
        shared = recovery.state
        return recovery.document
      }
    }
    let recovery = try NativeRetirementRecovery.normalizedCandidate(state,
      snapshot: snapshot, directory: directory)
    try commit { $0 = recovery.state }
    return recovery.document
  }
}

/// Produce a candidate synchronously, then commit once before native close.
/// A model-less page is never given a wider dialog/history authority exemption.
enum NativeRetirementRecovery {
  @MainActor static func normalizedCandidate(_ original: BrowserState,
    snapshot: NativeRetirementSnapshot, directory: URL) throws -> (state: BrowserState, document: BrowserTab) {
    let candidate = try Self.candidate(original, snapshot: snapshot)
    // Validate the actual normalized document BEFORE writing. A malformed or
    // conflicting snapshot must never commit and then report failure.
    let normalized = BrowserStore(directory: directory, initialState: candidate, memoryOnly: true)
    normalized.repair()
    guard let recovered = normalized.document(id: snapshot.pageID), !recovered.isClosed,
      recovered.windowID == snapshot.ownerWindowID,
      normalized.profileID(for: recovered) == snapshot.profileID,
      recovered.url == (snapshot.preview?.url ?? snapshot.source.url) else {
      throw NativeRetirementRecoveryError.invalidSnapshot
    }
    return (normalized.state, recovered)
  }
  static func candidate(_ original: BrowserState, snapshot: NativeRetirementSnapshot) throws -> BrowserState {
    guard snapshot.pageID == snapshot.source.id || snapshot.isPreview,
      snapshot.source.windowID == snapshot.ownerWindowID,
      !snapshot.source.isClosed,
      BrowserAddress.documentURL(snapshot.source.url, provenance: snapshot.source.nativeNavigation) != nil,
      (snapshot.isPreview ? (snapshot.preview != nil && snapshot.preview == snapshot.source.peek) : snapshot.preview == nil),
      snapshot.preview.map({ BrowserAddress.documentURL($0.url, provenance: $0.nativeNavigation) != nil }) ?? true else {
      throw NativeRetirementRecoveryError.invalidSnapshot
    }
    guard let profile = original.profiles.first(where: { $0.id == snapshot.profileID }),
      profile.isPrivate == snapshot.isPrivate,
      !original.pendingNativeProfileRetirements.contains(snapshot.profileID) else {
      throw NativeRetirementRecoveryError.profileUnavailable
    }
    guard original.windowSessions?.contains(where: { $0.id == snapshot.ownerWindowID && $0.isOpen }) == true else {
      throw NativeRetirementRecoveryError.windowUnavailable
    }
    let spaces = original.spaces.filter { $0.profileID == snapshot.profileID }
    guard let space = spaces.first(where: { $0.id == snapshot.source.spaceID }) ?? spaces.first else {
      throw NativeRetirementRecoveryError.spaceUnavailable
    }
    var state = original
    if snapshot.isPreview {
      if state.tabs.first(where: { $0.id == snapshot.source.id })?.isClosed != false {
        // A source with no materialized native page may still own a live Peek.
        // Recover the same cached source and full preview as one transaction;
        // the host will close the source only after this preview accepts Leave.
        return try candidate(original, snapshot: NativeRetirementSnapshot(
          pageID: snapshot.source.id, profileID: snapshot.profileID, isPrivate: snapshot.isPrivate,
          ownerWindowID: snapshot.ownerWindowID, source: snapshot.source, preview: nil, splits: snapshot.splits))
      }
      // A new preview or a source moved to another profile/window is a new
      // document identity. It must never be overwritten by an older veto.
      guard let index = state.tabs.firstIndex(where: { $0.id == snapshot.source.id }),
        !state.tabs[index].isClosed, state.tabs[index].windowID == snapshot.ownerWindowID,
        state.tabs[index].createdAt == snapshot.source.createdAt,
        spaces.contains(where: { $0.id == state.tabs[index].spaceID }) else {
        throw NativeRetirementRecoveryError.identityConflict
      }
      guard state.tabs[index].peek == nil else { throw NativeRetirementRecoveryError.previewChanged }
      state.tabs[index].peek = snapshot.preview
    } else if let index = state.tabs.firstIndex(where: { $0.id == snapshot.source.id }) {
      guard state.tabs[index].isClosed, state.tabs[index].windowID == snapshot.ownerWindowID,
        spaces.contains(where: { $0.id == state.tabs[index].spaceID }),
        state.tabs[index].createdAt == snapshot.source.createdAt else {
        throw NativeRetirementRecoveryError.identityConflict
      }
      // Preserve newer pin/custom-name/category edits. Recover only the live
      // document fields cleared by model-first close, not a stale whole record.
      state.tabs[index].isClosed = false; state.tabs[index].closedAt = nil
      state.tabs[index].url = snapshot.source.url
      state.tabs[index].title = snapshot.source.title
      state.tabs[index].nativeNavigation = snapshot.source.nativeNavigation
      state.tabs[index].navigation = snapshot.source.navigation
      state.tabs[index].navigationIndex = snapshot.source.navigationIndex
      state.tabs[index].peek = snapshot.source.peek
    } else {
      guard state.tabs.count < 1_000 else { throw NativeRetirementRecoveryError.tabLimit }
      if let archived = state.archive.first(where: { $0.id == snapshot.source.id }) {
        guard archived.tab.createdAt == snapshot.source.createdAt,
          archived.tab.windowID == snapshot.ownerWindowID,
          spaces.contains(where: { $0.id == archived.tab.spaceID }) else {
          throw NativeRetirementRecoveryError.identityConflict
        }
      }
      var recovered = snapshot.source
      recovered.spaceID = space.id
      recovered.isClosed = false; recovered.closedAt = nil
      if !state.folders.contains(where: { $0.id == recovered.folderID && $0.spaceID == space.id }) {
        recovered.folderID = nil
      }
      if !state.tabGroups.contains(where: { $0.id == recovered.groupID && $0.windowID == snapshot.ownerWindowID
        && $0.profileID == snapshot.profileID }) { recovered.groupID = nil }
      state.tabs.append(recovered)
    }
    state.archive.removeAll { $0.id == snapshot.source.id }
    // Reinstate an original split only if every retained partner still belongs
    // to this owner/profile/Space and has not joined a replacement split.
    for split in snapshot.splits where !state.splits.contains(where: { $0.id == split.id }) {
      let members = split.tabIDs.compactMap { id in state.tabs.first { $0.id == id } }
      guard members.count == split.tabIDs.count,
        members.allSatisfy({ !$0.isClosed && $0.windowID == snapshot.ownerWindowID && $0.spaceID == space.id }),
        !state.splits.contains(where: { !Set($0.tabIDs).isDisjoint(with: split.tabIDs) }) else { continue }
      var recovered = split; recovered.spaceID = space.id; state.splits.append(recovered)
    }
    return state
  }
}
