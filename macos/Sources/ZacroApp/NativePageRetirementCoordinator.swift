import Foundation
import ZacroChromium
import ZacroCore

/// Keeps last known authoritative records only for existing
/// native pages. A failed recovery retains the page and suppresses retry loops.
@MainActor final class NativePageRetirementCoordinator {
  struct Lease: Equatable {
    fileprivate let entryID: UUID
    fileprivate let attemptID: UUID
    fileprivate let pageKey: ObjectIdentifier
    let closeTargetID: String
  }
  @MainActor private final class Entry {
    let id = UUID()
    weak var page: ChromiumPage?
    weak var browser: CefBrowser?
    var snapshot: NativeRetirementSnapshot
    var attempt: UUID?
    var blocked: String?
    var recovered = false
    init(page: ChromiumPage, browser: CefBrowser, snapshot: NativeRetirementSnapshot) {
      self.page = page; self.browser = browser; self.snapshot = snapshot
    }
  }
  private weak var application: ApplicationCoordinator?
  private var entries: [ObjectIdentifier: Entry] = [:]
  @MainActor private final class BlockedDocument {
    weak var page: ChromiumPage?
    let reason: String
    init(_ page: ChromiumPage, reason: String) { self.page = page; self.reason = reason }
  }
  private var blocked: [ObjectIdentifier: BlockedDocument] = [:]

  init(application: ApplicationCoordinator) { self.application = application }

  /// Call after model metadata publication and at the start of layout. Invalid
  /// or absent model state must never overwrite the last valid snapshot.
  func remember(_ page: ChromiumPage) {
    guard let application, !application.engine.isTerminating,
      application.engine.pages[page.id] === page, let browser = page.browser, !browser.isClosed,
      let ownerID = page.ownerWindowID, let owner = application.windows[ownerID],
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      application.deletingProfileID != page.profileID,
      let document = application.store.document(id: page.id), !document.isClosed,
      document.windowID == ownerID, document.url == page.url?.absoluteString,
      application.store.profileID(for: document) == page.profileID,
      let profile = application.store.state.profiles.first(where: { $0.id == page.profileID }),
      profile.isPrivate == page.isPrivate else { return }
    let sourceID = page.id.hasPrefix("peek:") ? String(page.id.dropFirst(5)) : page.id
    guard let source = application.store.tab(sourceID), !source.isClosed else { return }
    let key = ObjectIdentifier(page)
    if let entry = entries[key], entry.attempt != nil || entry.blocked != nil { return }
    let snapshot = NativeRetirementSnapshot(pageID: page.id, profileID: page.profileID,
      isPrivate: page.isPrivate, ownerWindowID: ownerID, source: source,
      preview: page.id.hasPrefix("peek:") ? source.peek : nil,
      splits: application.store.state.splits.filter { $0.tabIDs.contains(sourceID) })
    if let entry = entries[key], entry.page === page, entry.browser === browser,
      entry.snapshot.pageID == page.id, entry.snapshot.ownerWindowID == ownerID,
      entry.snapshot.profileID == page.profileID {
      entry.snapshot = snapshot
    } else { entries[key] = Entry(page: page, browser: browser, snapshot: snapshot) }
  }

  func refresh() {
    guard let application else { return }
    for (key, entry) in Array(entries) where entry.page == nil || entry.browser?.isClosed != false {
      entries.removeValue(forKey: key)
    }
    for (key, item) in Array(blocked) where item.page == nil || item.page?.browser?.isClosed != false {
      blocked.removeValue(forKey: key)
    }
    for page in application.engine.pages.values { remember(page) }
  }

  func isBlocked(_ page: ChromiumPage) -> Bool { blocked[ObjectIdentifier(page)] != nil }
  func blockedPage(ownerID: String) -> ChromiumPage? {
    blocked.values.compactMap(\.page).filter { $0.ownerWindowID == ownerID }.sorted { $0.id < $1.id }.first
  }
  func reason(for page: ChromiumPage) -> String? { blocked[ObjectIdentifier(page)]?.reason }
  func block(_ page: ChromiumPage, reason: String) {
    blocked[ObjectIdentifier(page)] = BlockedDocument(page, reason: reason)
    entries[ObjectIdentifier(page)]?.blocked = reason
  }

  /// No suspension separates canonical validation, durable commit and lease
  /// issuance. The caller must rewire normal callbacks before starting close.
  func recover(_ page: ChromiumPage) throws -> Lease {
    let key = ObjectIdentifier(page)
    guard let entry = entries[key], entry.page === page, entry.attempt == nil,
      !isBlocked(page) else {
      let error = ShortcutError("This live document has no current recovery record. Keep the window open to preserve its contents.")
      block(page, reason: error.localizedDescription); throw error
    }
    guard let application else { throw CancellationError() }
    let attempt = UUID()
    let closeTargetID = entry.snapshot.pageID.hasPrefix("peek:")
      && application.store.tab(entry.snapshot.source.id)?.isClosed != false
      ? entry.snapshot.source.id : page.id
    entry.attempt = attempt
    do {
      try requireIdentity(page, entry: entry)
      if !entry.recovered {
        try application.store.recoverRetiringDocumentDurably(entry.snapshot)
        entry.recovered = true
      }
      // A commit is synchronous but publishes observers. Recheck the same
      // native object rather than assuming a callback cannot alter ownership.
      try requireIdentity(page, entry: entry)
      guard entries[key] === entry, entry.attempt == attempt,
        let restored = application.store.document(id: page.id), !restored.isClosed,
        restored.windowID == entry.snapshot.ownerWindowID, restored.url == page.url?.absoluteString,
        application.store.profileID(for: restored) == entry.snapshot.profileID else {
        throw CancellationError()
      }
      return Lease(entryID: entry.id, attemptID: attempt, pageKey: key, closeTargetID: closeTargetID)
    } catch {
      entry.attempt = nil; block(page, reason: error.localizedDescription)
      throw error
    }
  }

  func validates(_ lease: Lease, page: ChromiumPage) -> Bool {
    guard let entry = entries[lease.pageKey], entry.id == lease.entryID,
      entry.attempt == lease.attemptID, entry.page === page else { return false }
    return (try? requireIdentity(page, entry: entry)) != nil
  }

  func finished(_ lease: Lease, page: ChromiumPage, closed: Bool) {
    guard let entry = entries[lease.pageKey], entry.id == lease.entryID,
      entry.attempt == lease.attemptID, entry.page === page else { return }
    entry.attempt = nil
    if closed { forget(page) }
    else { entry.recovered = false; remember(page) }
  }

  /// Explicit recovery retry only. Clearing an error never creates a profile
  /// or closes a page; recover() repeats all authority and persistence checks.
  func retry(_ page: ChromiumPage) throws -> Lease {
    guard let entry = entries[ObjectIdentifier(page)], entry.attempt == nil else { throw CancellationError() }
    entry.blocked = nil
    blocked.removeValue(forKey: ObjectIdentifier(page))
    return try recover(page)
  }

  func forget(_ page: ChromiumPage) {
    entries.removeValue(forKey: ObjectIdentifier(page)); blocked.removeValue(forKey: ObjectIdentifier(page))
  }

  private func requireIdentity(_ page: ChromiumPage, entry: Entry) throws {
    let saved = entry.snapshot
    let address = saved.preview?.url ?? saved.source.url
    guard !Task.isCancelled, let application, !application.engine.isTerminating,
      application.deletingProfileID != saved.profileID,
      !application.store.pendingNativeProfileRetirements.contains(saved.profileID),
      page === entry.page, page.id == saved.pageID, page.profileID == saved.profileID,
      page.isPrivate == saved.isPrivate, page.ownerWindowID == saved.ownerWindowID,
      page.browser === entry.browser, entry.browser?.isClosed == false,
      page.url?.absoluteString == address, application.engine.pages[saved.pageID] === page,
      let owner = application.windows[saved.ownerWindowID], owner.windowContext.isOpen,
      !owner.windowContext.isClosing, !owner.hasPendingLiveNavigation(saved.pageID),
      let profile = application.store.state.profiles.first(where: { $0.id == saved.profileID }),
      profile.isPrivate == saved.isPrivate else { throw CancellationError() }
  }
}
