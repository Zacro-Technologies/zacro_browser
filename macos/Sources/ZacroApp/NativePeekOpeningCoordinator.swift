import Foundation
import ZacroChromium
import ZacroCore

/// Serializes user-requested Peek replacement around the existing document's
/// actual close decision. Parking/resuming a retained Peek does not use this
/// path and never asks the document to discard its work.
@MainActor
final class NativePeekOpeningCoordinator {
  private struct Destination: Equatable {
    let createdAt: Date?
    let address: String
    let presented: Bool?
    let provenance: NativeNavigationProvenance?
    init(_ peek: SavedPeek) {
      createdAt = peek.createdAt; address = peek.url
      presented = peek.isPresented; provenance = peek.nativeNavigation
    }
  }
  private final class Lease {
    let page: ChromiumPage
    var users = 0
    var retainDestination: Bool
    init(page: ChromiumPage, retainDestination: Bool) {
      self.page = page; self.retainDestination = retainDestination
    }
  }
  private struct Source {
    let owner: BrowserWindowCoordinator
    let context: ChromiumWindowContext
    let tabID: String
    let createdAt: Date
    let profileID: String
    let spaceID: String
    let selectedSpaceID: String
    let address: String
    let selectedDocumentID: String?
    let destination: Destination?
    let page: ChromiumPage?
    let pageID: String?
    let browser: CefBrowser?
    let pageAddress: URL?
  }
  private weak var owner: BrowserWindowCoordinator?
  private var generation: UInt64 = 0
  private var closing: [String: Lease] = [:]

  init(owner: BrowserWindowCoordinator) { self.owner = owner }

  /// The root page factory must not recreate a missing old Peek while this
  /// barrier is held. An existing old page remains visible until close accepts.
  func isReplacing(sourceTabID: String) -> Bool { closing[sourceTabID] != nil }
  func pendingRequestCount(sourceTabID: String) -> Int { closing[sourceTabID]?.users ?? 0 }

  /// The root's accepted-close callback keeps the old SavedPeek until commit
  /// succeeds. If commit fails, its saved destination remains recoverable.
  func retainsDestination(sourceTabID: String, page: ChromiumPage) -> Bool {
    closing[sourceTabID].map { $0.page === page && $0.retainDestination } ?? false
  }

  /// Selection/profile/window changes invalidate only the opening intent.
  /// Explicit dismissal additionally permits the normal close callback to
  /// forget the destination. The native document still decides its own close.
  func cancel(discardDestination: Bool = false) {
    generation &+= 1
    if discardDestination { for lease in closing.values { lease.retainDestination = false } }
  }

  /// `commit` must synchronously perform the durable SavedPeek mutation and
  /// apply the previously captured animation origin only after that succeeds.
  /// Return false means stale intent or a document veto, not a new destination.
  func open(sourceTabID: String, sourcePage: ChromiumPage? = nil, url: URL,
    commit: (URL) throws -> Void) async throws -> Bool {
    guard let destination = BrowserAddress.webURL(url.absoluteString) else {
      throw ShortcutError("Choose a web link to preview.")
    }
    guard let source = source(tabID: sourceTabID, page: sourcePage), !Task.isCancelled else { return false }
    generation &+= 1
    let request = generation
    let previewID = "peek:" + sourceTabID
    let previous = source.owner.engine.pages[previewID]
    let previousAddress = previous?.url
    let previousBrowser = previous?.browser
    var lease: Lease?
    if let previous {
      guard previous.ownerWindowID == source.context.id, previous.profileID == source.profileID else { return false }
      if let current = closing[sourceTabID] {
        guard current.page === previous else { return false }
        lease = current
        // A newer explicit opening may supersede an earlier dismissal intent.
        current.retainDestination = source.owner.store.tab(sourceTabID)?.peek != nil
      } else {
        let current = Lease(page: previous, retainDestination: source.owner.store.tab(sourceTabID)?.peek != nil)
        closing[sourceTabID] = current; lease = current
      }
      lease?.users += 1
    }
    defer {
      if let lease, closing[sourceTabID] === lease {
        lease.users -= 1
        if lease.users == 0 { closing.removeValue(forKey: sourceTabID) }
      }
      source.owner.scheduleLayout()
    }

    if let previous {
      // Root coalesces requests against the same real native page. No model
      // mutation is published before its capture/beforeunload decision.
      guard await source.owner.requestCloseTab(previewID, forPeekReplacement: true) else { return false }
      guard source.owner.engine.pages[previewID] == nil else { return false }
      guard previous.url == previousAddress,
        previous.browser == nil || previous.browser === previousBrowser else { return false }
      guard valid(source, request: request, acceptedClosedPage: previous) else { return false }
    } else {
      // An unmaterialized saved Peek can be replaced in the same durable
      // mutation; there is no native document to close or draft to discard.
      guard valid(source, request: request, acceptedClosedPage: nil) else { return false }
    }
    try commit(destination)
    return true
  }

  private func source(tabID: String, page: ChromiumPage?) -> Source? {
    guard let owner, !owner.engine.isTerminating,
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      let tab = owner.store.tab(tabID), !tab.isClosed,
      tab.windowID == owner.windowContext.id,
      owner.store.state.activeTabID == tabID,
      let profileID = owner.store.profileID(for: tab), profileID == owner.store.activeProfileID,
      owner.application.deletingProfileID != profileID else { return nil }
    if let page {
      guard page.id == tabID || page.id == "peek:" + tabID,
        owner.engine.pages[page.id] === page, page.ownerWindowID == owner.windowContext.id,
        page.profileID == profileID, page.documentError == nil,
        let document = owner.store.document(id: page.id), !document.isClosed,
        let url = page.url, document.url == url.absoluteString else { return nil }
    }
    return Source(owner: owner, context: owner.windowContext, tabID: tabID,
      createdAt: tab.createdAt, profileID: profileID, spaceID: tab.spaceID,
      selectedSpaceID: owner.store.state.activeSpaceID, address: tab.url,
      selectedDocumentID: owner.selectedDocumentID, destination: tab.peek.map(Destination.init),
      page: page, pageID: page?.id, browser: page?.browser,
      pageAddress: page?.url)
  }

  private func valid(_ source: Source, request: UInt64, acceptedClosedPage: ChromiumPage?) -> Bool {
    let owner = source.owner
    guard !Task.isCancelled, generation == request, self.owner === owner,
      !owner.engine.isTerminating, owner.windowContext === source.context,
      source.context.isOpen, !source.context.isClosing,
      owner.application.deletingProfileID != source.profileID,
      owner.store.activeProfileID == source.profileID,
      owner.store.state.activeSpaceID == source.selectedSpaceID,
      owner.store.state.activeTabID == source.tabID,
      owner.selectedDocumentID == source.selectedDocumentID,
      let tab = owner.store.tab(source.tabID), !tab.isClosed,
      tab.windowID == source.context.id, tab.createdAt == source.createdAt,
      tab.spaceID == source.spaceID, tab.url == source.address,
      tab.peek.map(Destination.init) == source.destination,
      owner.store.profileID(for: tab) == source.profileID else { return false }
    guard let page = source.page else { return true }
    guard page.id == source.pageID, page.profileID == source.profileID,
      page.ownerWindowID == source.context.id, page.url == source.pageAddress,
      page.documentError == nil else { return false }
    if page === acceptedClosedPage {
      // A link inside Peek may request its own replacement. The accepted old
      // document is allowed to be gone; the parent and selection must survive.
      return owner.engine.pages[page.id] == nil
    }
    return owner.engine.pages[page.id] === page && page.browser === source.browser && page.browser?.isClosed == false
  }
}
