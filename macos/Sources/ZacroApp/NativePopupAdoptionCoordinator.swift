import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// A native popup exists before the asynchronous history publication can give
/// it a Core tab. Only this exact admitted handoff may occupy that interval.
@MainActor final class NativePopupAdoptionCoordinator {
  private enum Phase { case preparing, closing, invalid }
  @MainActor private final class Entry {
    let page: ChromiumPage
    let browser: CefBrowser
    let originalID: String
    let nativeID: Int32
    let source: ChromiumPage
    let sourceBrowser: CefBrowser
    var sourceID: String
    let sourceNativeID: Int32
    let sourceOwnerID: String?
    let sourceContext: ChromiumWindowContext?
    let sourceWindowNativeID: Int?
    let owner: BrowserWindowCoordinator
    let context: ChromiumWindowContext
    let windowNativeID: Int
    let profileID: String
    let isPrivate: Bool
    var openerID: String?
    var sourceCreatedAt: Date?
    var sourceParent: Entry?
    let sourceIsInternal: Bool
    let spaceID: String
    let foreground: Bool
    var phase = Phase.preparing
    var resumesAfterCloseVeto = false
    var closeVetoed = false
    var profileCloseArmed = false
    var sourceProfileCloseArmed = false
    var task: Task<Void, Never>?
    var taskID: UUID?
    var coreTargetID: String?
    init(page: ChromiumPage, browser: CefBrowser, source: ChromiumPage, sourceBrowser: CefBrowser,
      owner: BrowserWindowCoordinator, sourceContext: ChromiumWindowContext?, sourceCreatedAt: Date?,
      sourceParent: Entry?, sourceIsInternal: Bool, spaceID: String, foreground: Bool) {
      self.page = page; self.browser = browser; originalID = page.id; nativeID = browser.id
      self.source = source; self.sourceBrowser = sourceBrowser; sourceID = source.id
      sourceNativeID = sourceBrowser.id; sourceOwnerID = source.ownerWindowID
      self.sourceContext = sourceContext; sourceWindowNativeID = sourceContext?.nativeID
      self.owner = owner; context = owner.windowContext; windowNativeID = owner.windowContext.nativeID
      profileID = page.profileID; isPrivate = page.isPrivate; openerID = page.openerID
      self.sourceCreatedAt = sourceCreatedAt; self.sourceParent = sourceParent
      self.sourceIsInternal = sourceIsInternal
      self.spaceID = spaceID; self.foreground = foreground
    }
  }

  private weak var application: ApplicationCoordinator?
  private var entries: [ObjectIdentifier: Entry] = [:]
  /// A cancellation-aware barrier for actual native acceptance only.
  var acceptanceBeforePreparation: ((ChromiumPage) async throws -> Void)?

  init(application: ApplicationCoordinator) { self.application = application }

  /// Called synchronously by the native popup callback, before scheduling Task.
  func begin(popup: ChromiumPage, source: ChromiumPage, owner: BrowserWindowCoordinator,
    spaceID: String? = nil, foreground: Bool) {
    guard let application, !application.engine.isTerminating,
      popup !== source, let browser = popup.browser, !browser.isClosed,
      let sourceBrowser = source.browser, !sourceBrowser.isClosed,
      application.engine.pages[popup.id] === popup, application.engine.pages[source.id] === source,
      entries[ObjectIdentifier(popup)] == nil, application.store.document(id: popup.id) == nil,
      popup.profileID == source.profileID, popup.isPrivate == source.isPrivate,
      popup.ownerWindowID == source.ownerWindowID,
      application.deletingProfileID != popup.profileID,
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      application.windows[owner.windowContext.id] === owner,
      let space = owner.store.state.spaces.first(where: { $0.id == (spaceID ?? owner.store.state.activeSpaceID) }),
      space.profileID == popup.profileID else { popup.close(); return }
    let sourceContext = source.ownerWindowID.flatMap(application.engine.context(id:))
    let sourceDocument = application.store.document(id: source.id)
    let sourceParent = entries[ObjectIdentifier(source)]
    let sourceIsInternal = application.engine.ownsInternalPopupSource(source)
    guard sourceDocument.map({ !$0.isClosed && $0.windowID == source.ownerWindowID
      && application.store.profileID(for: $0) == source.profileID }) == true
      || (sourceParent != nil && isPending(source)) || sourceIsInternal else { popup.close(); return }
    guard source.ownerWindowID == nil || (sourceContext === owner.windowContext
      && sourceContext?.isOpen == true && sourceContext?.isClosing == false),
      application.engine.movePage(id: popup.id, toWindowID: owner.windowContext.id) else {
      popup.close(); return
    }
    let entry = Entry(page: popup, browser: browser, source: source, sourceBrowser: sourceBrowser,
      owner: owner, sourceContext: sourceContext, sourceCreatedAt: sourceDocument?.createdAt,
      sourceParent: sourceParent, sourceIsInternal: sourceIsInternal, spaceID: space.id, foreground: foreground)
    entries[ObjectIdentifier(popup)] = entry
    // A pending document must still negotiate genuine native beforeunload.
    application.webDialogs.connect(popup)
    popup.onClosed = { [weak self, weak popup] in
      guard let self, let popup else { return }
      self.entries.removeValue(forKey: ObjectIdentifier(popup))?.task?.cancel()
      self.application?.webDialogs.forget(popup)
      self.application?.profileDeletionPageIDs.remove(popup.id)
      self.application?.scheduleAllWindows()
    }
    popup.onCloseCancelled = { [weak self, weak popup] in
      guard let self, let popup else { return }
      self.application?.cancelProfileOperation(forPage: popup.id)
      self.entries[ObjectIdentifier(popup)]?.closeVetoed = true
      self.resumeAvailable()
    }
    start(entry)
  }

  func pendingCount(ownerID: String) -> Int {
    entries.values.filter { $0.context.id == ownerID && isPending($0.page) }.count
  }

  func isPending(_ page: ChromiumPage) -> Bool {
    guard let entry = entries[ObjectIdentifier(page)], entry.phase != .invalid else { return false }
    guard nativeIdentity(entry) else { invalidate(entry); return false }
    // A synchronous Core publisher can reenter layout before the immediately
    // following native remap/wire. This is still the same admitted handoff.
    if let target = entry.coreTargetID {
      guard let application, let document = application.store.document(id: target),
        !document.isClosed, document.windowID == entry.context.id,
        application.store.profileID(for: document) == entry.profileID else { invalidate(entry); return false }
      return true
    }
    if entry.phase == .preparing && !sourceIdentity(entry) { invalidate(entry); return false }
    return true
  }

  /// The ordinary dialog guard still validates exact browser, URL, profile,
  /// owner and native context. This substitutes only for the not-yet-created row.
  func authorizesPendingDialog(_ page: ChromiumPage) -> Bool { isPending(page) }

  func validatePreparation(_ page: ChromiumPage) throws {
    guard let entry = entries[ObjectIdentifier(page)], entry.phase == .preparing,
      entry.coreTargetID == nil, nativeIdentity(entry), sourceIdentity(entry),
      let application, !Task.isCancelled, !application.engine.isTerminating,
      application.deletingProfileID != entry.profileID,
      !entry.context.isClosing else { throw CancellationError() }
  }

  /// Core publication and native remapping have no suspension between them.
  func didCommitCore(_ page: ChromiumPage, tabID: String) {
    guard let entry = entries[ObjectIdentifier(page)], entry.page === page,
      entry.phase == .preparing, entry.coreTargetID == nil else { return }
    entry.coreTargetID = tabID
  }

  func didAdopt(_ page: ChromiumPage) {
    guard let application, let entry = entries[ObjectIdentifier(page)],
      entry.page === page, entry.browser === page.browser, entry.nativeID == page.browser?.id,
      entry.coreTargetID == page.id, application.engine.pages[page.id] === page,
      page.ownerWindowID == entry.context.id, page.profileID == entry.profileID,
      application.engine.context(id: entry.context.id) === entry.context,
      entry.context.nativeID == entry.windowNativeID,
      let document = application.store.document(id: page.id), !document.isClosed,
      document.windowID == entry.context.id,
      application.store.profileID(for: document) == entry.profileID else { return }
    application.webDialogs.didAdoptPendingPopup(page, fromID: entry.originalID)
    for child in entries.values where child.sourceParent === entry && child.source === page
      && child.sourceBrowser === entry.browser {
      if child.openerID == entry.originalID, child.page.openerID == page.id { child.openerID = page.id }
      child.sourceID = page.id; child.sourceCreatedAt = document.createdAt; child.sourceParent = nil
    }
    entries.removeValue(forKey: ObjectIdentifier(page))
  }

  /// Native didClose can precede/reenter app callbacks, including after a
  /// partial Core handoff replaced the temporary onClosed closure.
  func refresh() {
    for (key, entry) in Array(entries) where entry.browser.isClosed || entry.page.browser == nil {
      entry.task?.cancel(); entries.removeValue(forKey: key)
    }
  }

  /// Stop Core publication before the existing native close loop negotiates
  /// this exact page. The lease remains until didClose or a successful adoption.
  func beginNativeClose(ownerID: String? = nil, profileID: String? = nil) {
    for entry in Array(entries.values) where (ownerID == nil || entry.context.id == ownerID)
      && (profileID == nil || entry.profileID == profileID) {
      guard entry.phase != .invalid else { continue }
      if nativeIdentity(entry), entry.coreTargetID == nil,
        entry.phase == .closing || sourceIdentity(entry) {
        entry.phase = .closing; entry.resumesAfterCloseVeto = true; entry.task?.cancel()
      } else { invalidate(entry) }
    }
  }

  func prepareForNativeClose(ownerID: String? = nil, profileID: String? = nil) async {
    beginNativeClose(ownerID: ownerID, profileID: profileID)
    let pending = entries.values.filter { (ownerID == nil || $0.context.id == ownerID)
      && (profileID == nil || $0.profileID == profileID) }.compactMap(\.task)
    for task in pending { await task.value }
  }

  /// Record the exact snapshot already selected by profile deletion/reset,
  /// immediately before that caller submits its ordinary native close loop.
  func willCloseProfileDocuments(profileID: String, ids: Set<String>) {
    guard let application, application.deletingProfileID == profileID else { return }
    for entry in entries.values where entry.profileID == profileID && entry.phase == .closing {
      if ids.contains(entry.originalID), nativeIdentity(entry) { entry.profileCloseArmed = true }
      if ids.contains(entry.sourceID), application.engine.pages[entry.sourceID] === entry.source,
        entry.source.browser === entry.sourceBrowser, !entry.sourceBrowser.isClosed,
        sourceIdentity(entry) { entry.sourceProfileCloseArmed = true }
    }
  }

  func resumeAvailable() {
    guard let application, !application.engine.isTerminating else { return }
    for entry in Array(entries.values) where entry.phase == .closing && entry.task == nil {
      guard !entry.context.isClosing, application.deletingProfileID != entry.profileID else { continue }
      if !entry.resumesAfterCloseVeto {
        if entry.closeVetoed { invalidate(entry) }
        continue
      }
      guard nativeIdentity(entry), sourceIdentity(entry), entry.coreTargetID == nil else {
        invalidate(entry); continue
      }
      if !entry.sourceBrowser.isClosed { entry.sourceProfileCloseArmed = false }
      entry.profileCloseArmed = false
      entry.phase = .preparing; entry.closeVetoed = false; start(entry)
    }
  }

  private func nativeIdentity(_ entry: Entry) -> Bool {
    guard let application,
      entry.page.id == entry.originalID || entry.page.id == entry.coreTargetID,
      application.engine.pages[entry.page.id] === entry.page,
      entry.page.browser === entry.browser, entry.browser.id == entry.nativeID, !entry.browser.isClosed,
      entry.page.profileID == entry.profileID, entry.page.isPrivate == entry.isPrivate,
      entry.page.openerID == entry.openerID,
      entry.page.ownerWindowID == entry.context.id,
      application.windows[entry.context.id] === entry.owner,
      application.engine.context(id: entry.context.id) === entry.context,
      entry.context.nativeID == entry.windowNativeID, entry.context.isOpen,
      let profile = application.store.state.profiles.first(where: { $0.id == entry.profileID }),
      profile.isPrivate == entry.isPrivate,
      entry.owner.store.state.spaces.contains(where: { $0.id == entry.spaceID && $0.profileID == entry.profileID })
      else { return false }
    return true
  }

  private func sourceIdentity(_ entry: Entry, visited: Set<ObjectIdentifier> = []) -> Bool {
    var visited = visited
    guard visited.insert(ObjectIdentifier(entry)).inserted else { return false }
    let sourceClosedWithOwner = (entry.source.closedForWindow || entry.source.closedForTermination
      || entry.sourceProfileCloseArmed)
      && entry.sourceBrowser.isClosed && entry.source.browser == nil
    guard let application, entry.source.id == entry.sourceID,
      (entry.source.browser === entry.sourceBrowser || sourceClosedWithOwner),
      entry.sourceBrowser.id == entry.sourceNativeID,
      entry.source.profileID == entry.profileID, entry.source.isPrivate == entry.isPrivate,
      entry.source.ownerWindowID == entry.sourceOwnerID else { return false }
    if let ownerID = entry.sourceOwnerID {
      guard let context = entry.sourceContext,
        application.engine.context(id: ownerID) === context, context.isOpen,
        context.nativeID == entry.sourceWindowNativeID else { return false }
    }
    var acceptedPendingParentClose = false
    if let parent = entry.sourceParent {
      guard parent.phase != .invalid, parent.page === entry.source,
        parent.browser === entry.sourceBrowser, parent.nativeID == entry.sourceNativeID,
        parent.context === entry.context, parent.windowNativeID == entry.windowNativeID,
        sourceIdentity(parent, visited: visited) else { return false }
      acceptedPendingParentClose = sourceClosedWithOwner && parent.phase == .closing
        && parent.resumesAfterCloseVeto && parent.coreTargetID == nil
        && (parent.page.closedForWindow || parent.page.closedForTermination || parent.profileCloseArmed)
        && application.engine.pages[parent.originalID] == nil
      guard acceptedPendingParentClose || (entries[ObjectIdentifier(parent.page)] === parent
        && nativeIdentity(parent)) else { return false }
    } else if entry.sourceIsInternal {
      guard application.engine.ownsInternalPopupSource(entry.source) else { return false }
    } else {
      guard let createdAt = entry.sourceCreatedAt,
        let document = application.store.document(id: entry.sourceID), !document.isClosed,
        document.createdAt == createdAt, document.windowID == entry.sourceOwnerID,
        application.store.profileID(for: document) == entry.profileID else { return false }
    }
    if application.engine.pages[entry.sourceID] === entry.source, !entry.sourceBrowser.isClosed { return true }
    // Accepted siblings can close before this popup vetoes a window/Quit.
    // Their unchanged saved Core row and exact native close origin remain.
    guard sourceClosedWithOwner, entry.sourceCreatedAt != nil || acceptedPendingParentClose else { return false }
    if let restored = application.engine.pages[entry.sourceID] {
      return restored.ownerWindowID == entry.sourceOwnerID && restored.profileID == entry.profileID
        && restored.isPrivate == entry.isPrivate
    }
    return true
  }

  private func start(_ entry: Entry) {
    guard entry.task == nil, entry.phase == .preparing else { return }
    let taskID = UUID(); entry.taskID = taskID
    entry.task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if entry.taskID == taskID { entry.task = nil; entry.taskID = nil }
        self.resumeAvailable()
      }
      do {
        try self.validatePreparation(entry.page)
        if CommandLine.arguments.contains("--engine-acceptance"),
          CommandLine.arguments.contains("--native-integration-acceptance") {
          try await self.acceptanceBeforePreparation?(entry.page)
          try self.validatePreparation(entry.page)
        }
        let adopted = await entry.owner.adoptPopup(entry.page, spaceID: entry.spaceID,
          foreground: entry.foreground, validateAdoption: { try self.validatePreparation(entry.page) })
        guard self.entries[ObjectIdentifier(entry.page)] === entry else { return }
        if adopted { self.invalidate(entry); return }
      } catch { /* Close negotiation below owns the exact remaining document. */ }
      guard self.entries[ObjectIdentifier(entry.page)] === entry else { return }
      if entry.phase == .closing { return }
      guard entry.coreTargetID == nil, self.nativeIdentity(entry), self.sourceIdentity(entry) else {
        self.invalidate(entry); return
      }
      entry.phase = .closing; entry.resumesAfterCloseVeto = false
      entry.page.close()
    }
  }

  private func invalidate(_ entry: Entry) {
    entry.phase = .invalid; entry.task?.cancel()
    application?.webDialogs.refresh()
    application?.scheduleAllWindows()
  }
}
