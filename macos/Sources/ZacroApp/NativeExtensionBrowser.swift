import AppKit
import CoreFoundation
import Foundation
import ZacroCore
import ZacroChromium

/// Validated logical window creation. Bounds retain Chrome's screen-coordinate
/// convention (top-left origin) until the window coordinator applies them.
struct NativeExtensionWindowRequest {
  enum Kind: String { case normal, popup }
  let profileID: String
  let kind: Kind
  let urls: [String]
  let nativeAuthorizations: [String: NativeNavigationProvenance]
  let movingTabID: String?
  let focused: Bool
  let state: String?
  let left: Int?
  let top: Int?
  let width: Int?
  let height: Int?
  let openerRequestID: String?
  let authorize: @MainActor () async throws -> Void
}

/// The authoritative Zacro tab/window model behind Chromium's native extension
/// dispatcher. Chromium owns API schemas, permission checks, URL preparation,
/// response redaction and query filtering. This object never injects an API shim.
@MainActor
final class NativeExtensionBrowser {
  var enabled = false
  var materializePage: ((BrowserTab) async throws -> ChromiumPage)?
  var prepareActionPopupDocument: ((String, String, @MainActor () async throws -> Void) async throws -> ChromiumPage)?
  var closeTab: (String) async -> Bool = { _ in false }
  var promotePeek: ((String, Bool, @MainActor () async throws -> Void) async throws -> BrowserTab)?
  var navigateTab: (BrowserTab, String) -> Void = { _, _ in }
  var activateTab: (String) throws -> Void = { _ in }
  var discardTab: ((String) async throws -> Bool)?
  var closeWindow: ((String) async -> Bool)?
  var restoreWindow: ((String, @MainActor () async throws -> Void) async throws -> String)?
  var createWindow: ((NativeExtensionWindowRequest) async throws -> String)?
  var moveTabs: (([String], String, Int, @MainActor () async throws -> Void) async throws -> Void)?
  var isDiscarded: (String) -> Bool = { _ in false }
  var isAudible: (String) -> Bool = { _ in false }
  var profileAvailable: (String) -> Bool = { _ in true }
  var didChange: () -> Void = {}

  private let repository: BrowserRepository
  private var store: BrowserStore { repository.canonicalStore }
  private let engine: ChromiumEngine
  private var lastFocusedWindows: [String: String] = [:]
  private var identities: [String: Identity] = [:]
  private var creationOpeners: [String: String] = [:]
  private var optionsWindows: [String: OptionsWindow] = [:]
  private var optionsTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  private var groupIdentities: [String: Int] = [:]
  private var groupKeys: [String: Data] = [:]
  private var groupRevisions: [String: UInt64] = [:]
  private var groupMembers: [String: Set<String>] = [:]
  private var groupSnapshots: [String: GroupSnapshot] = [:]
  private var requestedGroupMoves = Set<String>()
  private var attentionRequests: [String: Int] = [:]
  private var catalogTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  private var catalogKeys: [String: Data] = [:]
  private var catalogRevisions: [String: UInt64] = [:]
  private var catalogMembers: [String: Set<String>] = [:]
  private var splitIdentities: [String: Int] = [:]
  private var nextSplitIdentity = 1
  private var snapshots: [String: Snapshot] = [:]
  private var sessionSnapshots: [String: [String]] = [:]
  private var focusSnapshots: [String: Int] = [:]
  private var lastFocusSnapshots: [String: Int] = [:]
  private var highlightSnapshots: [String: [Int]] = [:]
  private var windowSnapshots: [String: [String: Any]] = [:]
  private var tails: [String: Task<Void, Never>] = [:]
  private var pending = Set<String>()
  private var reconciliation: Task<Void, Never>?
  private var closingEvents: Task<Void, Never>?
  private var epoch: UInt64 = 0
  private var publishedWindows = Set<String>()
  private var reconcileAgain = false
  private var stopped = false

  private final class Identity {
    weak var page: ChromiumPage?
    let id: Int
    var signature: String
    init(_ page: ChromiumPage?, id: Int, signature: String) {
      self.page = page; self.id = id; self.signature = signature
    }
  }
  private struct Snapshot { let profile: String; let value: [String: Any] }
  private struct OptionsWindow {
    let windowID: String
    let tabID: String
    let incarnationID: String
    let url: String
  }
  private struct GroupSnapshot { let profile: String; let value: [String: Any]; let index: Int }
  private struct Failure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  init(repository: BrowserRepository, engine: ChromiumEngine) {
    self.repository = repository; self.engine = engine
  }

  /// Peek has its own real WebContents identity, projected from the source's
  /// saved preview rather than duplicated in the persistent tab collection.
  func documentTab(_ logicalID: String) -> BrowserTab? { store.document(id: logicalID) }
  func peekSourceID(_ logicalID: String) -> String? {
    guard logicalID.hasPrefix("peek:") else { return nil }
    let source = String(logicalID.dropFirst(5))
    return store.tab(source)?.peek != nil ? source : nil
  }
  func didPromotePeek(sourceID: String, targetID: String) {
    let previous = "peek:" + sourceID
    if let identity = identities.removeValue(forKey: previous) {
      identity.signature = ""; identities[targetID] = identity
    }
    if let snapshot = snapshots.removeValue(forKey: previous) { snapshots[targetID] = snapshot }
    if let profile = store.tab(targetID).flatMap({ store.profileID(for: $0) }) {
      catalogKeys.removeValue(forKey: profile)
      if catalogMembers[profile]?.remove(previous) != nil { catalogMembers[profile]?.insert(targetID) }
    }
    creationOpeners.removeValue(forKey: previous)
  }
  private func activeDocumentID(_ window: BrowserWindowSession) -> String? {
    guard let id = window.activeTabID else { return nil }
    if let peek = store.tab(id)?.peek, peek.isPresented != false { return "peek:" + id }
    return id
  }
  private func highlightedDocuments(_ window: BrowserWindowSession) -> Set<String> {
    var result = window.highlightedTabIDs
    if let source = window.activeTabID, let active = activeDocumentID(window), active != source {
      result.remove(source); result.insert(active)
    }
    return result
  }
  private func documentIsDiscarded(_ id: String) -> Bool {
    peekSourceID(id) == nil ? isDiscarded(id) : engine.pages[id] == nil
  }
  private func persistentTab(_ tab: BrowserTab, request: ChromeExtensionHostRequest, profile: String,
                             manager: ChromeExtensionManager) async throws -> BrowserTab {
    guard let source = peekSourceID(tab.id) else { return tab }
    guard let promotePeek else { throw Failure("Peek promotion is unavailable.") }
    let wasActive = repository.windows.first(where: { $0.id == tab.windowID }).map { activeDocumentID($0) == tab.id } ?? false
    guard let previousID = identities[tab.id]?.id else { throw Failure("The preview has no registered native identity.") }
    let result = try await promotePeek(source, wasActive, { [weak self] in
      guard let self else { throw CancellationError() }
      try await self.authorize(request, profile: profile, manager: manager)
      guard let current = self.documentTab(tab.id), current.windowID == tab.windowID,
        self.store.profileID(for: current) == profile, self.identities[tab.id]?.id == previousID else {
        throw Failure("The preview changed before it could be promoted.")
      }
    })
    try await authorize(request, profile: profile, manager: manager)
    guard let current = documentTab(result.id), !current.isClosed, store.profileID(for: current) == profile,
      identities[result.id]?.id == previousID else { throw Failure("The preview identity changed during promotion.") }
    return current
  }

  private func persistentTabs(_ values: [BrowserTab], request: ChromeExtensionHostRequest, profile: String,
                              manager: ChromeExtensionManager) async throws -> [BrowserTab] {
    var result: [BrowserTab] = []
    for value in values {
      guard let current = documentTab(value.id), !current.isClosed else { throw Failure("A tab closed before the operation completed.") }
      result.append(try await persistentTab(current, request: request, profile: profile, manager: manager))
    }
    return result
  }

  /// Registered synchronously before a new window can schedule its first page.
  /// The opaque native request remains authoritative for the real opener frame.
  func setCreationOpener(tabIDs: [String], requestID: String) {
    for id in tabIDs where engine.pages[id] == nil { creationOpeners[id] = requestID }
  }

  /// Both the Library and runtime.openOptionsPage use a registered, profile-owned
  /// browser window. The hidden management document never opens visible pages.
  func openOptions(profileID: String, extensionID: String, sourceWindowID: Int? = nil) async throws {
    try await openOptions(profileID: profileID, extensionID: extensionID,
      sourceWindowID: sourceWindowID, request: nil)
  }

  private func openOptions(profileID: String, extensionID: String, sourceWindowID: Int?,
                           request: ChromeExtensionHostRequest?) async throws {
    try checkProfile(profileID, request: request)
    let key = profileID + ":" + extensionID
    let previous = optionsTasks[key]?.task
    let identifier = UUID()
    let task = Task { @MainActor [weak self] in
      // Coalesce presentation through one ordered queue while retaining each
      // caller's own native authorization, including a later revoked request.
      _ = try? await previous?.value
      guard let self else { throw CancellationError() }
      try await self.presentOptions(profileID: profileID, extensionID: extensionID,
        sourceWindowID: sourceWindowID, request: request)
    }
    optionsTasks[key] = (identifier, task)
    defer { if optionsTasks[key]?.id == identifier { optionsTasks.removeValue(forKey: key) } }
    try await task.value
  }

  private func presentOptions(profileID: String, extensionID: String, sourceWindowID: Int?,
                              request: ChromeExtensionHostRequest?) async throws {
    try checkProfile(profileID, request: request)
    let manager = ChromeExtensionManager(engine: engine, profileID: profileID)
    if let request { try await authorize(request, profile: profileID, manager: manager) }
    let options = try await manager.optionsPage(extensionID)
    let approval = options.approval
    let address = approval.url.absoluteString
    guard approval.profileID == profileID, approval.extensionID == extensionID,
      let proof = NativeNavigationProvenance(extensionID: extensionID,
        incarnationID: approval.incarnationID, approvedURL: address) else {
      throw Failure("The extension options page is unavailable.")
    }
    let validate: @MainActor () async throws -> Void = { [weak self] in
      guard let self else { throw CancellationError() }
      try self.checkProfile(profileID, request: request)
      let current = try await manager.validateNavigation(extensionID: extensionID,
        incarnationID: approval.incarnationID, url: approval.url)
      guard current.profileID == profileID, current.extensionID == extensionID,
        current.incarnationID == approval.incarnationID, current.url == approval.url else {
        throw Failure("The extension options page changed before it could open.")
      }
      if let request { try await self.authorize(request, profile: profileID, manager: manager) }
      try self.checkProfile(profileID, request: request)
      if let sourceWindowID {
        let source = try self.targetWindow(sourceWindowID, profile: profileID, request: request)
        try self.canActivate(profileID, in: source.id)
      }
    }
    try await validate()
    let key = profileID + ":" + extensionID
    if let existing = optionsWindows[key], existing.incarnationID == approval.incarnationID,
      existing.url == address, let tab = store.tab(existing.tabID), !tab.isClosed,
      tab.url == address, tab.windowID == existing.windowID, store.profileID(for: tab) == profileID,
      let context = engine.context(id: existing.windowID), context.isOpen, !context.isClosing {
      try canActivate(profileID, in: existing.windowID)
      try activateTab(tab.id)
      repository.focusWindow(existing.windowID)
      NSApp.activate(ignoringOtherApps: true); context.window.makeKeyAndOrderFront(nil)
      _ = try await requireDocument(tab)
      try await validate()
      return
    }
    guard let createWindow else { throw Failure("Native window creation is unavailable.") }
    // Electron presents extension settings in an 850×650 managed window even
    // for options_ui. Preserve that experience with a real catalogued popup.
    let creation = NativeExtensionWindowRequest(profileID: profileID, kind: .popup,
      urls: [address], nativeAuthorizations: [address: proof], movingTabID: nil,
      focused: true, state: nil, left: nil, top: nil, width: 850, height: 650,
      openerRequestID: nil, authorize: validate)
    let windowID = try await createWindow(creation)
    try await validate()
    guard let tab = tabs(profileID, in: windowID).first(where: { $0.url == address }),
      engine.context(id: windowID)?.isOpen == true else {
      throw Failure("The extension options window closed before it could open.")
    }
    optionsWindows[key] = OptionsWindow(windowID: windowID, tabID: tab.id,
      incarnationID: approval.incarnationID, url: address)
    _ = try await requireDocument(tab)
    try await validate()
    didChange()
  }

  /// Reserves an immutable native identity without creating a document/view.
  /// The caller must pass the returned token to the CEF factory, not a page.
  func preparePageCreation(tabID: String) async throws -> ChromeTabMaterialization? {
    guard enabled, let tab = documentTab(tabID), !tab.isClosed,
      let profile = store.profileID(for: tab),
      store.state.profiles.contains(where: { $0.id == profile && !$0.isPrivate }) else { return nil }
    try await synchronizeCatalog(profile)
    let ticket = try await ChromeExtensionManager(engine: engine, profileID: profile).prepareTabMaterialization(tabID, openerRequestID: creationOpeners[tabID])
    try checkProfile(profile)
    guard documentTab(tabID)?.isClosed == false, identities[tabID]?.id == ticket.nativeID,
      ticket.logicalID == tabID, ticket.profileID == profile else { throw Failure("The tab changed before its document could load.") }
    creationOpeners.removeValue(forKey: tabID)
    return ticket
  }

  /// Adopts an existing real popup/startup page, or verifies that a newly
  /// materialized page received its reserved ID before any document script runs.
  func prepareInitialNavigation(_ page: ChromiumPage) async throws {
    guard enabled, !page.isPrivate, let tab = documentTab(page.id), !tab.isClosed,
      store.profileID(for: tab) == page.profileID else { return }
    try await registerMaterialized(page, profile: page.profileID)
    catalogKeys.removeValue(forKey: page.profileID)
  }

  /// Requests remain ordered within their originating profile. A later request
  /// cannot overtake an earlier beforeunload decision or native-ID reservation.
  func handle(profileID: String, request: ChromeExtensionHostRequest) async {
    let key = profileID + ":" + request.requestID
    guard pending.insert(key).inserted else { return }
    let previous = tails[profileID]
    let task = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      defer {
        self.pending.remove(key)
        self.creationOpeners = self.creationOpeners.filter { $0.value != request.requestID }
      }
      let manager = ChromeExtensionManager(engine: self.engine, profileID: profileID)
      do {
        try self.checkProfile(profileID, request: request)
        guard request.argumentsJSON.count <= 1_048_576,
          let arguments = try JSONSerialization.jsonObject(with: request.argumentsJSON) as? [Any]
        else { throw Failure("Invalid browser API arguments.") }
        let result = try await self.perform(request, profile: profileID, arguments: arguments, manager: manager)
        try await manager.completeHostRequest(request.requestID, results: result)
      } catch {
        try? await manager.completeHostRequest(request.requestID, error: error.localizedDescription)
      }
      self.reconcile()
    }
    tails[profileID] = task
    await task.value
  }

  func reconcile() {
    guard enabled, !stopped, !engine.isTerminating else { return }
    reconcileAgain = true
    guard reconciliation == nil else { return }
    let revision = epoch
    reconciliation = Task { [weak self] in
      guard let self else { return }
      await self.closingEvents?.value
      defer { if self.epoch == revision { self.reconciliation = nil } }
      while self.reconcileAgain && self.epoch == revision && !Task.isCancelled {
        self.reconcileAgain = false
        await self.publishChanges()
      }
    }
  }

  func waitForTopologyPublication() async {
    reconcile()
    while let task = reconciliation {
      await task.value
      if Task.isCancelled || stopped { return }
    }
  }

  func windowFocusChanged() {
    for profile in store.state.profiles where !profile.isPrivate {
      if let window = windows(profile.id).first(where: { isWindowFocused($0.id, profile: profile.id) }) {
        lastFocusedWindows[profile.id] = window.id
      }
    }
    reconcile()
  }

  /// Model ownership has already retired this window after native beforeunload
  /// acceptance. The next atomic catalog publishes removals for only that owner.
  func didCloseWindow(_ id: String) async {
    guard enabled, !stopped else { return }
    optionsWindows = optionsWindows.filter { $0.value.windowID != id }
    if let attention = attentionRequests.removeValue(forKey: id) { NSApp.cancelUserAttentionRequest(attention) }
    for profile in Array(catalogKeys.keys) { catalogKeys.removeValue(forKey: profile) }
    windowFocusChanged()
    await reconciliation?.value
  }

  func close() async {
    stopped = true; epoch &+= 1; reconciliation?.cancel(); reconciliation = nil; closingEvents?.cancel()
    for task in tails.values { task.cancel() }
    for pending in catalogTasks.values { pending.task.cancel() }
    for pending in optionsTasks.values { pending.task.cancel() }
    optionsTasks.removeAll(); optionsWindows.removeAll()
    catalogTasks.removeAll(); catalogKeys.removeAll(); catalogMembers.removeAll()
    groupKeys.removeAll(); groupMembers.removeAll(); groupIdentities.removeAll(); groupSnapshots.removeAll()
    // A pending windows.remove can itself be awaiting this shutdown. Chromium
    // owns revocation of its request; do not deadlock termination on that wait.
    tails.removeAll(); identities.removeAll(); snapshots.removeAll(); pending.removeAll(); creationOpeners.removeAll()
  }

  private func checkProfile(_ profile: String, request: ChromeExtensionHostRequest? = nil) throws {
    guard enabled, !stopped, !Task.isCancelled else { throw Failure("The native browser extension bridge is unavailable.") }
    guard !engine.isTerminating else { throw Failure("The browser is closing.") }
    guard store.state.profiles.contains(where: { $0.id == profile && !$0.isPrivate }), request?.incognito != true else {
      throw Failure("This extension cannot access this browsing profile.")
    }
    guard profileAvailable(profile) else { throw Failure("This browsing profile is being updated.") }
  }

  private func authorize(_ request: ChromeExtensionHostRequest, profile: String,
                         manager: ChromeExtensionManager) async throws {
    try checkProfile(profile, request: request)
    try await manager.validateHostRequest(requestID: request.requestID)
    try checkProfile(profile, request: request)
  }

  private func windows(_ profile: String) -> [BrowserWindowSession] {
    repository.windows.filter { window in
      guard window.isOpen, engine.context(id: window.id)?.isOpen == true else { return false }
      return store.state.spaces.first(where: { $0.id == window.activeSpaceID })?.profileID == profile
        || store.state.tabs.contains { !$0.isClosed && $0.windowID == window.id && store.profileID(for: $0) == profile }
    }
  }

  private func tabs(_ profile: String, in window: String? = nil) -> [BrowserTab] {
    let open = Set(windows(profile).map(\.id))
    let persistent = store.state.tabs.filter { !$0.isClosed && store.profileID(for: $0) == profile
      && $0.windowID.map(open.contains) == true && (window == nil || $0.windowID == window) }
    return persistent + persistent.compactMap(\.peekDocument)
  }

  private func owner(_ tab: BrowserTab) throws -> BrowserStore {
    guard let id = documentTab(tab.id)?.windowID, engine.context(id: id)?.isOpen == true,
      engine.context(id: id)?.isClosing == false, let scope = repository.store(for: id) else {
      throw Failure("The tab's window is closed.")
    }
    return scope
  }

  private func record(_ profile: String, nativeID: Int) throws -> BrowserTab {
    guard let tab = tabs(profile).first(where: { identities[$0.id]?.id == nativeID }) else {
      throw Failure("Unknown profile tab.")
    }
    return tab
  }

  private func currentWindow(_ profile: String, request: ChromeExtensionHostRequest?) throws -> BrowserWindowSession {
    let available = windows(profile)
    if let id = request?.sourceWindowID,
      let window = available.first(where: { engine.context(id: $0.id)?.nativeID == id }) { return window }
    if let id = request?.sourceTabID, let tab = try? record(profile, nativeID: id),
      let window = available.first(where: { $0.id == tab.windowID }) { return window }
    if let id = lastFocusedWindows[profile], let window = available.first(where: { $0.id == id }) { return window }
    if let window = available.first(where: { $0.id == repository.focusedWindowID }) { return window }
    guard let window = available.first else { throw Failure("This profile has no browser window.") }
    return window
  }

  private func defaultRecord(_ profile: String, id: Any?, request: ChromeExtensionHostRequest? = nil) throws -> BrowserTab {
    if let id, !(id is NSNull) { return try record(profile, nativeID: integer(id)) }
    let window = try currentWindow(profile, request: request)
    guard let tab = tabs(profile, in: window.id).first(where: { $0.id == activeDocumentID(window) }) else {
      throw Failure("This profile has no active tab in that window.")
    }
    return tab
  }

  private func registrations(_ profile: String) throws -> [ChromeLogicalTabRegistration] {
    let records = tabs(profile), valid = Set(records.map(\.id))
    let sessions = Dictionary(uniqueKeysWithValues: windows(profile).map { ($0.id, $0) })
    var indices: [String: Int] = [:]
    return try records.map { tab in
      guard let id = tab.windowID, let window = sessions[id], let context = engine.context(id: id) else {
        throw Failure("The tab's window is closed.")
      }
      let index = indices[id, default: 0]; indices[id] = index + 1
      let opener = tab.openerTabID ?? engine.pages[tab.id]?.openerID
      return ChromeLogicalTabRegistration(logicalID: tab.id, windowID: context.nativeID, index: index,
        active: activeDocumentID(window) == tab.id, pinned: tab.isPinned, discarded: documentIsDiscarded(tab.id),
        autoDiscardable: tab.autoDiscardable != false, splitViewID: try splitIdentity(tab.id, profile: profile),
        openerLogicalID: opener.flatMap { $0 != tab.id && valid.contains($0) ? $0 : nil },
        highlighted: highlightedDocuments(window).contains(tab.id), groupID: nativeGroupID(tab))
    }
  }
  private func catalogKey(_ entries: [ChromeLogicalTabRegistration]) throws -> Data {
    try JSONSerialization.data(withJSONObject: entries.map { item -> [String: Any] in
      ["id": item.logicalID, "window": item.windowID, "index": item.index, "active": item.active,
       "pinned": item.pinned, "highlighted": item.highlighted, "discarded": item.discarded, "automatic": item.autoDiscardable,
       "split": item.splitViewID, "group": item.groupID, "opener": item.openerLogicalID ?? "",
       "page": engine.pages[item.logicalID].map { String(describing: ObjectIdentifier($0)) } ?? ""]
    }, options: [.sortedKeys])
  }

  /// One atomic catalog synchronization per changed profile snapshot; no page
  /// factory is called here. Concurrent callers share the same in-flight work.
  private func synchronizeCatalog(_ profile: String) async throws {
    while true {
      try checkProfile(profile)
      if let pending = catalogTasks[profile] {
        do { try await pending.task.value }
        catch { if catalogTasks[profile]?.id == pending.id { catalogTasks.removeValue(forKey: profile) }; throw error }
        if catalogTasks[profile]?.id == pending.id { catalogTasks.removeValue(forKey: profile) }
        continue
      }
      let desired = try catalogKey(registrations(profile))
      let desiredGroups = try groupCatalogKey(profile)
      if catalogKeys[profile] == desired && groupKeys[profile] == desiredGroups { return }
      let token = UUID(), generation = epoch
      let task = Task { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        try await self.synchronizeGroups(profile)
        // Adopt only pages that already exist. Real popups and startup pages
        // keep their assigned SessionID; absent models reserve an ID afterward.
        let existing = self.tabs(profile).compactMap { self.engine.pages[$0.id] }
        for page in existing { try await self.registerMaterialized(page, profile: profile) }
        try self.checkProfile(profile)
        guard generation == self.epoch else { throw CancellationError() }
        let entries = try self.registrations(profile), key = try self.catalogKey(entries)
        let revision = (self.catalogRevisions[profile] ?? 0) + 1
        self.catalogRevisions[profile] = revision
        let values = try await ChromeExtensionManager(engine: self.engine, profileID: profile)
          .synchronizeTabs(entries, revision: revision)
        try self.checkProfile(profile)
        guard generation == self.epoch else { throw CancellationError() }
        // A native response may arrive after a Peek was promoted or tabs were
        // transferred. Never apply the stale membership over the synchronous
        // identity handoff; the next loop adopts the current live documents.
        guard try self.catalogKey(self.registrations(profile)) == key else { return }
        let expected = Set(entries.map(\.logicalID))
        guard values.count == expected.count, Set(values.map(\.logicalID)) == expected,
          Set(values.map(\.nativeID)).count == values.count, values.allSatisfy({ $0.nativeID > 0 }) else {
          throw Failure("The native tab identity catalog is invalid.")
        }
        for value in values {
          let old = self.identities[value.logicalID]
          if let old, old.id == value.nativeID { continue }
          self.identities[value.logicalID] = Identity(nil, id: value.nativeID, signature: "")
        }
        for removed in (self.catalogMembers[profile] ?? []).subtracting(expected) { self.identities.removeValue(forKey: removed) }
        self.catalogMembers[profile] = expected; self.catalogKeys[profile] = key
      }
      catalogTasks[profile] = (token, task)
      do { try await task.value }
      catch { if catalogTasks[profile]?.id == token { catalogTasks.removeValue(forKey: profile) }; throw error }
      if catalogTasks[profile]?.id == token { catalogTasks.removeValue(forKey: profile) }
    }
  }

  private func registerMaterialized(_ page: ChromiumPage, profile: String) async throws {
    try checkProfile(profile)
    let logicalID = page.id
    guard page.profileID == profile, !page.isPrivate, engine.pages[logicalID] === page else {
      throw Failure("The tab closed before its document could load.")
    }
    let browser = try await page.ready()
    try checkProfile(profile)
    // Promotion keeps this page and its immutable native ID, but renames the
    // logical record. Its new registration belongs to the next catalog pass.
    guard page.id == logicalID else { return }
    guard engine.pages[logicalID] === page, documentTab(logicalID)?.isClosed == false,
      let entry = try registrations(profile).first(where: { $0.logicalID == logicalID }) else {
      throw Failure("The tab closed before its document could load.")
    }
    let opener = entry.openerLogicalID.flatMap { identities[$0]?.id }
    let signature = "\(entry.windowID):\(entry.index):\(entry.active):\(entry.highlighted):\(entry.pinned):\(entry.discarded):\(entry.autoDiscardable):\(entry.splitViewID):\(entry.groupID):\(opener ?? -1)"
    if let existing = identities[logicalID], existing.page === page, existing.signature == signature { return }
    let nativeID = try await browser.registerExtensionTab(logicalID: logicalID, windowID: entry.windowID,
      index: entry.index, active: entry.active, pinned: entry.pinned, discarded: entry.discarded,
      autoDiscardable: entry.autoDiscardable, splitViewID: entry.splitViewID, openerTabID: opener, highlighted: entry.highlighted, groupID: entry.groupID)
    try checkProfile(profile)
    guard page.id == logicalID else { return }
    guard engine.pages[logicalID] === page, documentTab(logicalID)?.isClosed == false,
      page.reservedNativeTabID.map({ $0 == nativeID }) ?? true else { throw Failure("The native tab identity changed.") }
    identities[logicalID] = Identity(page, id: nativeID, signature: signature)
  }

  private func tabData(_ logicalID: String, profile: String, synchronize: Bool = true) async throws -> [String: Any] {
    if synchronize { try await synchronizeCatalog(profile) }
    try checkProfile(profile)
    let records = tabs(profile)
    guard let tab = records.first(where: { $0.id == logicalID }),
      let index = tabs(profile, in: tab.windowID).firstIndex(where: { $0.id == logicalID }) else { throw Failure("Unknown profile tab.") }
    return try tabMetadata(tab, index: index, profile: profile, validIDs: Set(records.map(\.id)))
  }

  private func tabMetadata(_ tab: BrowserTab, index: Int, profile: String, validIDs: Set<String>) throws -> [String: Any] {
    guard let identity = identities[tab.id] else { throw Failure("Unknown profile tab.") }
    guard let window = repository.windows.first(where: { $0.id == tab.windowID }),
      let context = engine.context(id: window.id), context.isOpen else { throw Failure("Unknown profile window.") }
    let page = engine.pages[tab.id], active = activeDocumentID(window) == tab.id
    let highlighted = highlightedDocuments(window).contains(tab.id)
    let muted = page?.browser?.isAudioMuted ?? tab.isMuted
    var value: [String: Any] = [
      "id": identity.id, "windowId": context.nativeID, "index": index,
      "active": active, "highlighted": highlighted, "pinned": tab.isPinned, "incognito": false,
      "selected": active, "groupId": nativeGroupID(tab), "splitViewId": try splitIdentity(tab.id, profile: profile), "frozen": false,
      "lastAccessed": tab.lastAccessedAt.timeIntervalSince1970 * 1_000,
      "url": tab.url, "title": tab.title, "status": page?.isLoading == true ? "loading" : "complete",
      "audible": isAudible(tab.id), "mutedInfo": ["muted": muted], "muted": muted,
      "discarded": documentIsDiscarded(tab.id), "autoDiscardable": tab.autoDiscardable != false,
    ]
    if let favicon = page?.faviconURL { value["favIconUrl"] = favicon.absoluteString }
    let opener = tab.openerTabID ?? page?.openerID
    if let opener, validIDs.contains(opener), let id = identities[opener]?.id { value["openerTabId"] = id }
    return value
  }

  private func allTabData(_ profile: String) async throws -> [[String: Any]] {
    try await synchronizeCatalog(profile)
    let records = tabs(profile), validIDs = Set(records.map(\.id))
    var indices: [String: Int] = [:]
    return try records.map { tab in
      let key = tab.windowID ?? "", index = indices[key, default: 0]; indices[key] = index + 1
      return try tabMetadata(tab, index: index, profile: profile, validIDs: validIDs)
    }
  }

  private func groups(_ profile: String) -> [BrowserTabGroup] {
    let available = Set(windows(profile).map(\.id))
    let members = Set(tabs(profile).compactMap(\.groupID))
    return store.state.tabGroups.filter { $0.profileID == profile && available.contains($0.windowID) && members.contains($0.id) }
  }
  private func nativeGroupID(_ tab: BrowserTab) -> Int {
    tab.groupID.flatMap { groupIdentities[$0] } ?? -1
  }
  private func groupRecord(_ profile: String, nativeID: Int) throws -> BrowserTabGroup {
    guard let group = groups(profile).first(where: { groupIdentities[$0.id] == nativeID }) else { throw Failure("Unknown profile tab group.") }
    return group
  }
  private func groupRegistrations(_ profile: String) -> [ChromeLogicalGroupRegistration] {
    groups(profile).compactMap { group in
      guard let context = engine.context(id: group.windowID), context.isOpen else { return nil }
      return ChromeLogicalGroupRegistration(logicalID: group.id, windowID: context.nativeID,
        title: group.title, color: group.color, collapsed: group.collapsed, shared: false)
    }
  }
  private func groupCatalogKey(_ profile: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: groupRegistrations(profile).map { group -> [String: Any] in
      ["id": group.logicalID, "window": group.windowID, "title": group.title,
       "color": group.color, "collapsed": group.collapsed, "shared": group.shared]
    }, options: [.sortedKeys])
  }
  private func synchronizeGroups(_ profile: String) async throws {
    let key = try groupCatalogKey(profile)
    if groupKeys[profile] == key { return }
    let entries = groupRegistrations(profile), revision = (groupRevisions[profile] ?? 0) + 1
    groupRevisions[profile] = revision
    let identities = try await ChromeExtensionManager(engine: engine, profileID: profile).synchronizeGroups(entries, revision: revision)
    try checkProfile(profile)
    let expected = Set(entries.map(\.logicalID))
    guard identities.count == expected.count, Set(identities.map(\.logicalID)) == expected,
      Set(identities.map(\.nativeID)).count == expected.count,
      identities.allSatisfy({ $0.nativeID >= 0 }) else { throw Failure("The native group identity catalog is invalid.") }
    for identity in identities { groupIdentities[identity.logicalID] = identity.nativeID }
    for removed in (groupMembers[profile] ?? []).subtracting(expected) { groupIdentities.removeValue(forKey: removed) }
    groupMembers[profile] = expected; groupKeys[profile] = key
  }
  private func groupData(_ group: BrowserTabGroup) throws -> [String: Any] {
    guard let id = groupIdentities[group.id], let context = engine.context(id: group.windowID), context.isOpen else { throw Failure("Unknown profile tab group.") }
    return ["id": id, "windowId": context.nativeID, "title": group.title,
      "color": group.color, "collapsed": group.collapsed, "shared": false]
  }
  private func performGroup(_ request: ChromeExtensionHostRequest, profile: String,
                            arguments: [Any], manager: ChromeExtensionManager) async throws -> [Any] {
    func arg(_ index: Int) -> Any? { arguments.indices.contains(index) ? arguments[index] : nil }
    try await synchronizeCatalog(profile)
    try await authorize(request, profile: profile, manager: manager)
    switch request.method {
    case "tabGroups.get": return [try groupData(groupRecord(profile, nativeID: integer(arg(0))))]
    case "tabGroups.query":
      let props = try properties(arg(0), allowed: ["collapsed", "color", "title", "shared", "windowId"])
      try validateGroup(props)
      let current = try currentWindow(profile, request: request)
      let target: Int?
      if let value = props["windowId"] {
        let id = try integer(value, minimum: -2)
        target = id == -2 ? engine.context(id: current.id)?.nativeID : id == -1 ? nil : id
      } else { target = nil }
      // The native broker applies Chromium's exact title glob after validation.
      return [try groups(profile).filter { group in
        (target == nil || engine.context(id: group.windowID)?.nativeID == target) && (props["shared"] as? Bool != true)
          && ((props["collapsed"] as? Bool).map { $0 == group.collapsed } ?? true)
          && ((props["color"] as? String).map { $0 == group.color } ?? true)
      }.map(groupData)]
    case "tabGroups.update":
      let group = try groupRecord(profile, nativeID: integer(arg(0)))
      let props = try properties(arg(1), allowed: ["collapsed", "color", "title"])
      guard engine.context(id: group.windowID)?.isClosing == false else { throw Failure("The browser window is closing.") }
      try validateGroup(props)
      try repository.updateTabGroup(group.id, title: props["title"] as? String,
        color: props["color"] as? String, collapsed: props["collapsed"] as? Bool)
      didChange(); try await synchronizeCatalog(profile)
      guard let current = groups(profile).first(where: { $0.id == group.id }) else { throw Failure("The group closed.") }
      return [try groupData(current)]
    case "tabs.ungroup":
      let ids = try identifiers(arg(0)).map { value -> String in
        let tab = try record(profile, nativeID: value); _ = try owner(tab); return tab.id
      }
      let grouped = Array(Set(ids)).filter { documentTab($0)?.groupID != nil }
      if !grouped.isEmpty { try repository.ungroupTabs(grouped); didChange() }
      return []
    case "tabs.group":
      let props = try properties(arg(0), allowed: ["tabIds", "groupId", "createProperties"])
      if props["groupId"] != nil && props["createProperties"] != nil { throw Failure("Choose an existing group or new-group properties.") }
      let requested = try identifiers(props["tabIds"]).map { try record(profile, nativeID: $0).id }
      var seen = Set<String>(); var ids = requested.filter { seen.insert($0).inserted }
      let existing = try props["groupId"].map { try groupRecord(profile, nativeID: integer($0)) }
      let creation = try properties(props["createProperties"], allowed: ["windowId"])
      let target = try existing.map { group -> BrowserWindowSession in
        guard let window = windows(profile).first(where: { $0.id == group.windowID }) else { throw Failure("Unknown profile window.") }
        return window
      } ?? targetWindow(creation["windowId"], profile: profile, request: request)
      guard target.kind == .normal else { throw Failure("Tab groups require a normal browser window.") }
      let current = try ids.map { id -> BrowserTab in
        guard let tab = documentTab(id) else { throw Failure("Unknown profile tab.") }; return tab
      }
      ids = try await persistentTabs(current, request: request, profile: profile, manager: manager).map(\.id)
      try await authorize(request, profile: profile, manager: manager)
      let foreign = ids.filter { documentTab($0)?.windowID != target.id }
      if !foreign.isEmpty {
        guard let moveTabs else { throw Failure("Native tab transfer is unavailable.") }
        try await moveTabs(foreign, target.id, -1) { [weak self] in
          guard let self else { throw CancellationError() }
          try await self.authorize(request, profile: profile, manager: manager)
        }
        try await authorize(request, profile: profile, manager: manager)
      }
      guard engine.context(id: target.id)?.isOpen == true, engine.context(id: target.id)?.isClosing == false else { throw Failure("The browser window is closing.") }
      let group = try repository.groupTabs(ids, groupID: existing?.id, inWindowID: target.id)
      didChange(); try await synchronizeCatalog(profile)
      guard let id = groupIdentities[group.id] else { throw Failure("The group could not be registered.") }
      return [id]
    case "tabGroups.move":
      let group = try groupRecord(profile, nativeID: integer(arg(0)))
      let props = try properties(arg(1), allowed: ["windowId", "index"])
      let index = try integer(props["index"], minimum: -1)
      let destination = try targetWindow(props["windowId"] ?? engine.context(id: group.windowID)?.nativeID,
        profile: profile, request: request)
      guard destination.kind == .normal, repository.windows.first(where: { $0.id == group.windowID })?.kind == .normal else {
        throw Failure("Groups can only move between normal browser windows.")
      }
      let members = tabs(profile, in: group.windowID).filter { $0.groupID == group.id }.map(\.id)
      let position = try validateGroupMove(group, members: members, destination: destination.id, index: index, profile: profile)
      guard let moveTabs else { throw Failure("Native tab transfer is unavailable.") }
      let previousIndex = tabs(profile, in: group.windowID).firstIndex(where: { $0.groupID == group.id })
      if destination.id == group.windowID && previousIndex != position { requestedGroupMoves.insert(group.id) }
      do {
        try await moveTabs(members, destination.id, index) { [weak self] in
          guard let self else { throw CancellationError() }
          try await self.authorize(request, profile: profile, manager: manager)
          _ = try self.validateGroupMove(group, members: members, destination: destination.id, index: index, profile: profile)
        }
      } catch { requestedGroupMoves.remove(group.id); throw error }
      try await authorize(request, profile: profile, manager: manager)
      didChange(); try await synchronizeCatalog(profile)
      guard let current = groups(profile).first(where: { $0.id == group.id }) else { throw Failure("The group closed.") }
      return [try groupData(current)]
    default: throw Failure("Unsupported native group API.")
    }
  }
  private func validateGroupMove(_ group: BrowserTabGroup, members: [String], destination: String,
                                 index: Int, profile: String) throws -> Int {
    guard groups(profile).contains(where: { $0.id == group.id && $0.windowID == group.windowID }),
      tabs(profile, in: group.windowID).filter({ $0.groupID == group.id }).map(\.id) == members,
      engine.context(id: group.windowID)?.isClosing == false,
      let target = windows(profile).first(where: { $0.id == destination }), target.kind == .normal,
      engine.context(id: destination)?.isClosing == false else { throw Failure("The tab group changed while preparing its move.") }
    let remaining = tabs(profile, in: destination).filter { !members.contains($0.id) }
    let position = index < 0 ? remaining.count : min(index, remaining.count)
    if position < remaining.count {
      if remaining[position].isPinned { throw Failure("A group cannot move into pinned tabs.") }
      if position > 0, let id = remaining[position].groupID, remaining[position - 1].groupID == id {
        throw Failure("A group cannot move inside another group.")
      }
    }
    return position
  }
  private func validateGroup(_ props: [String: Any]) throws {
    for key in ["collapsed", "shared"] where props[key] != nil {
      guard let value = props[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure("Invalid group option.") }
    }
    if let value = props["title"], !(value is String) { throw Failure("Invalid group title.") }
    if let value = props["color"] {
      guard let value = value as? String,
        ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"].contains(value) else { throw Failure("Invalid group color.") }
    }
  }
  private func publishGroupChanges(_ profile: String, manager: ChromeExtensionManager) async {
    var next: [String: GroupSnapshot] = [:]
    for group in groups(profile) {
      guard !Task.isCancelled, let value = try? groupData(group) else { continue }
      let index = tabs(profile, in: group.windowID).firstIndex(where: { $0.groupID == group.id }) ?? 0
      next[group.id] = GroupSnapshot(profile: profile, value: value, index: index)
      let previous = groupSnapshots[group.id]
      if previous == nil || !equal(previous?.value["id"], value["id"]) || !equal(previous?.value["windowId"], value["windowId"]) {
        if let previous { try? await manager.publishBrowserEvent("tabGroups.onRemoved", arguments: [previous.value]) }
        try? await manager.publishBrowserEvent("tabGroups.onCreated", arguments: [value])
      } else if let previous {
        if ["title", "color", "collapsed", "shared"].contains(where: { !equal(previous.value[$0], value[$0]) }) {
          try? await manager.publishBrowserEvent("tabGroups.onUpdated", arguments: [value])
        }
        if previous.index != index, requestedGroupMoves.remove(group.id) != nil {
          try? await manager.publishBrowserEvent("tabGroups.onMoved", arguments: [value])
        }
      }
    }
    for (id, previous) in groupSnapshots where previous.profile == profile && next[id] == nil {
      try? await manager.publishBrowserEvent("tabGroups.onRemoved", arguments: [previous.value])
      requestedGroupMoves.remove(id)
    }
    groupSnapshots = groupSnapshots.filter { $0.value.profile != profile }
    groupSnapshots.merge(next) { _, value in value }
  }

  private func splitIdentity(_ tabID: String, profile: String) throws -> Int {
    guard let group = store.split(for: tabID) else { return -1 }
    let key = profile + ":" + group.id
    if let identity = splitIdentities[key] { return identity }
    guard nextSplitIdentity < Int32.max else { throw Failure("Split view identity limit reached.") }
    let identity = nextSplitIdentity; nextSplitIdentity += 1; splitIdentities[key] = identity
    return identity
  }

  private func validateSplitPair(_ pair: [BrowserTab], profile: String) throws {
    guard pair.count == 2, pair[0].windowID == pair[1].windowID,
      pair[0].spaceID == pair[1].spaceID, pair[0].isPinned == pair[1].isPinned,
      pair[0].groupID == pair[1].groupID else { throw Failure("Split tabs must be in the same Space, tab group, and pinned state.") }
    let ordered = tabs(profile, in: pair[0].windowID)
    guard let first = ordered.firstIndex(where: { $0.id == pair[0].id }),
      let second = ordered.firstIndex(where: { $0.id == pair[1].id }), abs(first - second) == 1 else {
      throw Failure("Split tabs must be adjacent.")
    }
    guard pair.allSatisfy({ store.split(for: $0.id) == nil }) else { throw Failure("A tab is already in split view.") }
  }

  private func perform(_ request: ChromeExtensionHostRequest, profile: String,
                       arguments: [Any], manager: ChromeExtensionManager) async throws -> [Any] {
    func arg(_ index: Int) -> Any? { arguments.indices.contains(index) ? arguments[index] : nil }
    try await authorize(request, profile: profile, manager: manager)
    switch request.method {
    case "runtime.openOptionsPage":
      guard arguments.isEmpty else { throw Failure("Invalid options-page arguments.") }
      try await openOptions(profileID: profile, extensionID: request.extensionID,
        sourceWindowID: request.sourceWindowID, request: request)
      return []
    case "native.prepareDocument":
      try await synchronizeCatalog(profile)
      let tab = try record(profile, nativeID: integer(arg(0)))
      _ = try await requireDocument(tab)
      try await authorize(request, profile: profile, manager: manager)
      guard documentTab(tab.id)?.isClosed == false else { throw Failure("The tab closed before its document could load.") }
      return []
    case "native.prepareActionPopup":
      guard arguments.count == 1, let prepareActionPopupDocument else { throw Failure("Extension popup preparation is unavailable.") }
      let nativeWindowID = try integer(arg(0))
      let target = try targetWindow(nativeWindowID, profile: profile, request: request)
      let windowID = target.id
      let validate: @MainActor () async throws -> Void = { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.authorize(request, profile: profile, manager: manager)
        guard let context = self.engine.context(id: windowID), context.isOpen, !context.isClosing,
          context.nativeID == nativeWindowID, self.isWindowFocused(windowID, profile: profile) else {
          throw Failure("The extension popup requires its focused browser window.")
        }
      }
      try await validate()
      let page = try await prepareActionPopupDocument(windowID, profile, validate)
      try await prepareInitialNavigation(page)
      try await synchronizeCatalog(profile)
      try await validate()
      guard let current = windows(profile).first(where: { $0.id == windowID }),
        let scope = repository.store(for: windowID), let context = engine.context(id: windowID),
        activeDocumentID(current) == page.id, page.ownerWindowID == windowID,
        engine.pages[page.id] === page, !page.isPrivate, page.profileID == profile,
        let content = context.window.contentView else { throw Failure("The active document changed before its extension popup opened.") }
      let sidebar = current.kind == .popup || !scope.state.settings.sidebarVisible ? 0 : scope.state.settings.sidebarWidth
      let anchor = context.window.convertToScreen(NSRect(x: max(8, sidebar - 34), y: content.bounds.height - 68, width: 26, height: 26))
      try await manager.prepareActionPopup(requestID: request.requestID, on: page,
        anchorWindow: context.window, anchorRect: anchor)
      return []
    case "sessions.getRecentlyClosed", "sessions.getDevices", "sessions.restore":
      return try await performSession(request, profile: profile, arguments: arguments, manager: manager)
    case "tabs.group", "tabs.ungroup", "tabGroups.get", "tabGroups.query", "tabGroups.update", "tabGroups.move":
      return try await performGroup(request, profile: profile, arguments: arguments, manager: manager)
    case "tabs.query", "tabs.getAllInWindow":
      var query = request.method == "tabs.query" ? try properties(arg(0)) : [:]
      let current = try? currentWindow(profile, request: request)
      let currentID = current.flatMap { engine.context(id: $0.id)?.nativeID } ?? -1
      let lastID = lastFocusedWindow(profile).flatMap { engine.context(id: $0.id)?.nativeID }
      if request.method == "tabs.getAllInWindow" {
        let target = try targetWindow(arg(0), profile: profile, request: request)
        query["windowId"] = engine.context(id: target.id)!.nativeID
      }
      _ = try NativeExtensionQuery.matches(query: query, tab: [:], currentWindowID: currentID,
        lastFocusedWindowID: lastID, windowType: "normal")
      try await authorize(request, profile: profile, manager: manager)
      // Chromium applies URL/title matching after its permission redaction.
      let values = try await allTabData(profile)
      return [try values.filter { value in
        let window = windows(profile).first { engine.context(id: $0.id)?.nativeID == value["windowId"] as? Int }
        return try NativeExtensionQuery.matches(query: query, tab: value,
          currentWindowID: currentID, lastFocusedWindowID: lastID, windowType: window?.kind.rawValue ?? "normal")
      }]
    case "tabs.get":
      let id = try integer(arg(0))
      try await synchronizeCatalog(profile)
      return [try await tabData(record(profile, nativeID: id).id, profile: profile)]
    case "tabs.getCurrent":
      guard let id = request.sourceTabID else { return [] }
      try await synchronizeCatalog(profile)
      guard let tab = try? record(profile, nativeID: id) else { return [] }
      return [try await tabData(tab.id, profile: profile)]
    case "tabs.getSelected":
      let window = try targetWindow(arg(0), profile: profile, request: request)
      guard let id = activeDocumentID(window), tabs(profile, in: window.id).contains(where: { $0.id == id }) else { throw Failure("This profile has no active tab in that window.") }
      return [try await tabData(id, profile: profile)]
    case "tabs.create":
      let props = try properties(arg(0))
      return [try await create(props, request: request, profile: profile, manager: manager)]
    case "tabs.update":
      let propertiesFirst = arg(0) is [String: Any]
      var props = try properties(propertiesFirst ? arg(0) : arg(1), allowed: ["url", "active", "selected", "pinned", "muted", "highlighted", "autoDiscardable", "openerTabId"])
      if props["active"] == nil, let selected = props["selected"] { props["active"] = selected }
      try await synchronizeCatalog(profile)
      var tab = try defaultRecord(profile, id: propertiesFirst ? nil : arg(0), request: request)
      try validateTabProperties(props)
      var scope = try owner(tab)
      let activate = props["active"] as? Bool == true
      if props["highlighted"] as? Bool == false, activate || repository.windows.first(where: { $0.id == tab.windowID }).map({ activeDocumentID($0) == tab.id }) == true { throw Failure("The active tab cannot be unhighlighted independently.") }
      if activate || props["highlighted"] as? Bool == true { try canActivate(profile, in: tab.windowID) }
      let destination = try await navigationDestination(props["url"], request: request, profile: profile, manager: manager)
      if peekSourceID(tab.id) != nil, props["pinned"] as? Bool == true || props["openerTabId"] != nil || (props["highlighted"] as? Bool == true && !activate) {
        tab = try await persistentTab(tab, request: request, profile: profile, manager: manager)
      }
      try await authorize(request, profile: profile, manager: manager)
      guard let currentTab = documentTab(tab.id), !currentTab.isClosed else { throw Failure("Unknown profile tab.") }
      scope = try owner(currentTab)
      if activate || props["highlighted"] as? Bool == true { try canActivate(profile, in: currentTab.windowID) }
      guard documentTab(tab.id)?.isClosed == false else { throw Failure("Unknown profile tab.") }
      let openerID = try props["openerTabId"].map { try record(profile, nativeID: integer($0)).id }
      if openerID == tab.id { throw Failure("A tab cannot be its own opener.") }
      if let source = peekSourceID(tab.id) {
        try scope.updatePeekDurably(tabID: source) { peek in
          if let muted = props["muted"] as? Bool { peek.isMuted = muted }
          if let automatic = props["autoDiscardable"] as? Bool { peek.autoDiscardable = automatic }
          if let destination {
            let history = peek.navigation ?? [NavigationEntry(url: peek.url, title: peek.title, nativeNavigation: peek.nativeNavigation)]
            let index = peek.navigationIndex ?? max(0, history.count - 1)
            let entry = NavigationEntry(url: destination.url, nativeNavigation: destination.provenance)
            peek.url = destination.url; peek.nativeNavigation = destination.provenance
            peek.navigation = Array((Array(history.prefix(max(0, index + 1))) + [entry]).suffix(100))
            peek.navigationIndex = (peek.navigation?.count ?? 1) - 1
          }
        }
      } else {
        try scope.commit { state in
          guard let i = state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
          if let pinned = props["pinned"] as? Bool, pinned != state.tabs[i].isPinned {
            state.tabs[i].isPinned = pinned; state.tabs[i].isFavorite = false; state.tabs[i].folderID = nil
            state.tabs[i].savedURL = pinned ? state.tabs[i].url : nil
            state.tabs[i].savedTitle = pinned ? state.tabs[i].title : nil
            state.tabs[i].savedNativeNavigation = pinned ? state.tabs[i].nativeNavigation : nil
          }
          if let muted = props["muted"] as? Bool { state.tabs[i].isMuted = muted }
          if let automatic = props["autoDiscardable"] as? Bool { state.tabs[i].autoDiscardable = automatic }
          if let openerID { state.tabs[i].openerTabID = openerID }
          if let destination {
            state.tabs[i].url = destination.url; state.tabs[i].nativeNavigation = destination.provenance
            state.tabs[i].homePage = nil
            let entry = NavigationEntry(url: destination.url, nativeNavigation: destination.provenance)
            state.tabs[i].navigation = Array((Array(state.tabs[i].navigation.prefix(max(0, state.tabs[i].navigationIndex + 1))) + [entry]).suffix(100))
            state.tabs[i].navigationIndex = state.tabs[i].navigation.count - 1
          }
        }
      }
      if let muted = props["muted"] as? Bool { engine.pages[tab.id]?.browser?.isAudioMuted = muted }
      if let destination, let current = documentTab(tab.id) {
        navigateTab(current, destination.url)
        _ = try await requireDocument(current)
        try await authorize(request, profile: profile, manager: manager)
      }
      if activate { try canActivate(profile, in: documentTab(tab.id)?.windowID); try activateTab(tab.id) }
      if let highlighted = props["highlighted"] as? Bool, peekSourceID(tab.id) == nil, let id = documentTab(tab.id)?.windowID {
        if highlighted { try canActivate(profile, in: id) }
        try repository.updateWindow(id) { window in
          if highlighted { window.highlightedTabIDs.insert(tab.id) }
          else { window.highlightedTabIDs.remove(tab.id) }
        }
      }
      didChange()
      return [try await tabData(tab.id, profile: profile)]
    case "tabs.remove":
      try await synchronizeCatalog(profile)
      for id in try identifiers(arg(0)) {
        let tab = try record(profile, nativeID: id)
        try await authorize(request, profile: profile, manager: manager)
        guard await closeTab(tab.id) else { throw Failure("The page kept its unsaved changes.") }
      }
      return []
    case "tabs.reload", "tabs.goBack", "tabs.goForward":
      try await synchronizeCatalog(profile)
      let propertiesFirst = arg(0) is [String: Any]
      let props = request.method == "tabs.reload" ? try properties(propertiesFirst ? arg(0) : arg(1), allowed: ["bypassCache"]) : [:]
      try validateTabProperties(props)
      let tab = try defaultRecord(profile, id: propertiesFirst ? nil : arg(0), request: request)
      try await authorize(request, profile: profile, manager: manager)
      let wasDiscarded = documentIsDiscarded(tab.id)
      let page = try await requireDocument(tab)
      let browser = try await page.ready()
      try await authorize(request, profile: profile, manager: manager)
      guard engine.pages[tab.id] === page, documentTab(tab.id)?.isClosed == false else { throw Failure("Unknown profile tab.") }
      if request.method == "tabs.reload" {
        if !wasDiscarded { browser.reload(ignoreCache: props["bypassCache"] as? Bool ?? false) }
      }
      else if request.method == "tabs.goBack" {
        guard browser.canGoBack else { throw Failure("The tab has no previous page.") }; page.goBack()
      } else {
        guard browser.canGoForward else { throw Failure("The tab has no next page.") }; page.goForward()
      }
      return []
    case "tabs.duplicate":
      try await synchronizeCatalog(profile)
      let tab = try record(profile, nativeID: integer(arg(0)))
      let props: [String: Any] = ["url": tab.url, "active": (try owner(tab)).activeProfileID == profile, "pinned": tab.isPinned, "windowId": engine.context(id: tab.windowID!)!.nativeID]
      return [try await create(props, request: request, profile: profile, manager: manager, duplicateOf: tab)]
    case "tabs.createSplit":
      let ids = try identifiers(arg(0))
      guard ids.count == 2, Set(ids).count == 2 else { throw Failure("Choose exactly two different tabs for split view.") }
      try await synchronizeCatalog(profile)
      try await authorize(request, profile: profile, manager: manager)
      let initial = try ids.map { try record(profile, nativeID: $0) }
      try validateSplitPair(initial, profile: profile)
      let pair = try await persistentTabs(initial, request: request, profile: profile, manager: manager)
      try await authorize(request, profile: profile, manager: manager)
      let ordered = tabs(profile, in: pair[0].windowID)
      guard let first = ordered.firstIndex(where: { $0.id == pair[0].id }),
        let second = ordered.firstIndex(where: { $0.id == pair[1].id }), abs(first - second) == 1 else {
        throw Failure("Split tabs must be adjacent.")
      }
      guard pair[0].windowID == pair[1].windowID, pair[0].spaceID == pair[1].spaceID, pair[0].isPinned == pair[1].isPinned, pair[0].groupID == pair[1].groupID else {
        throw Failure("Split tabs must be in the same Space, tab group, and pinned state.")
      }
      guard pair.allSatisfy({ store.split(for: $0.id) == nil }) else { throw Failure("A tab is already in split view.") }
      guard nextSplitIdentity < Int32.max else { throw Failure("Split view identity limit reached.") }
      let group = SplitGroup(spaceID: pair[0].spaceID, leftTabID: pair[0].id, rightTabID: pair[1].id)
      try owner(pair[0]).commit { $0.splits.append(group) }
      didChange()
      return [try splitIdentity(pair[0].id, profile: profile)]
    case "tabs.unsplit":
      let id = try integer(arg(0))
      try await synchronizeCatalog(profile)
      try await authorize(request, profile: profile, manager: manager)
      guard let group = store.state.splits.first(where: { group in
        splitIdentities[profile + ":" + group.id] == id
          && store.state.spaces.first(where: { $0.id == group.spaceID })?.profileID == profile
      }), group.tabIDs.allSatisfy({ tabID in tabs(profile).contains { $0.id == tabID } }) else {
        throw Failure("Unknown profile split view.")
      }
      try store.commit { $0.splits.removeAll { $0.id == group.id } }
      didChange(); return []
    case "tabs.move":
      try await synchronizeCatalog(profile)
      let ids = try identifiers(arg(0)), props = try properties(arg(1), allowed: ["index", "windowId"])
      let position = try integer(props["index"], minimum: -1)
      guard Set(ids).count == ids.count else { throw Failure("Duplicate tab IDs are not allowed.") }
      var records = try ids.map { try record(profile, nativeID: $0) }
      let destination: BrowserWindowSession
      if props["windowId"] != nil { destination = try targetWindow(props["windowId"], profile: profile, request: request) }
      else {
        guard let id = records.first?.windowID, records.allSatisfy({ $0.windowID == id }),
          let window = windows(profile).first(where: { $0.id == id }) else { throw Failure("Choose a destination window for tabs from different windows.") }
        destination = window
      }
      guard let moveTabs else { throw Failure("Native tab transfer is unavailable.") }
      records = try await persistentTabs(records, request: request, profile: profile, manager: manager)
      try await authorize(request, profile: profile, manager: manager)
      for tab in records { _ = try owner(tab) }
      try await moveTabs(records.map(\.id), destination.id, position) { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.authorize(request, profile: profile, manager: manager)
      }
      try await authorize(request, profile: profile, manager: manager)
      didChange()
      var result: [[String: Any]] = []
      for tab in records { result.append(try await tabData(tab.id, profile: profile)) }
      return arg(0) is [Any] ? [result] : [result.first ?? [:]]
    case "tabs.highlight":
      let props = try properties(arg(0), allowed: ["tabs", "windowId"])
      let window = try targetWindow(props["windowId"], profile: profile, request: request)
      let indices = try identifiers(props["tabs"]), available = tabs(profile, in: window.id)
      guard Set(indices).count == indices.count, indices.allSatisfy({ available.indices.contains($0) }),
        indices.first != nil else { throw Failure("Invalid tab selection indices.") }
      try canActivate(profile, in: window.id)
      try await authorize(request, profile: profile, manager: manager)
      try canActivate(profile, in: window.id)
      let selected = try await persistentTabs(indices.map { available[$0] }, request: request, profile: profile, manager: manager)
      try await authorize(request, profile: profile, manager: manager)
      try canActivate(profile, in: window.id)
      guard let active = selected.first else { throw Failure("Choose tabs to highlight.") }
      try repository.selectTabs(selected.map(\.id), activeID: active.id, inWindowID: window.id, presentPeek: false)
      didChange()
      return [try await windowData(window.id, profile: profile, info: ["populate": true])]
    case "tabs.discard":
      try await synchronizeCatalog(profile)
      guard let discardTab else { throw Failure("Native tab suspension is unavailable.") }
      let explicit = arg(0) != nil && !(arg(0) is NSNull)
      let candidates = explicit ? [try defaultRecord(profile, id: arg(0), request: request)]
        : tabs(profile).filter { tab in peekSourceID(tab.id) == nil && !repository.windows.contains(where: { activeDocumentID($0) == tab.id }) && !documentIsDiscarded(tab.id) }.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
      for candidate in candidates {
        let tab = try await persistentTab(candidate, request: request, profile: profile, manager: manager)
        try await authorize(request, profile: profile, manager: manager)
        let discarded: Bool
        if isDiscarded(tab.id) { discarded = true } else { discarded = try await discardTab(tab.id) }
        if discarded {
          return [try await tabData(tab.id, profile: profile)]
        }
      }
      if explicit { throw Failure("The tab is busy or has unsaved work.") }
      return []
    case "tabs.getZoom", "tabs.setZoom":
      try await synchronizeCatalog(profile)
      let factorOnly = request.method == "tabs.setZoom" && arguments.count == 1
      let tab = try defaultRecord(profile, id: factorOnly ? nil : arg(0), request: request)
      guard !documentIsDiscarded(tab.id), let page = engine.pages[tab.id], let browser = page.browser else { throw Failure("The target tab is not currently loaded.") }
      if request.method == "tabs.getZoom" { return [pow(1.2, browser.zoomLevel)] }
      try await authorize(request, profile: profile, manager: manager)
      let factor = try number(arg(factorOnly ? 0 : 1))
      guard factor == 0 || (0.25...5).contains(factor) else { throw Failure("Zoom factor must be from 0.25 to 5, or zero to reset.") }
      browser.zoomLevel = factor == 0 ? 0 : log(factor) / log(1.2)
      didChange(); return []
    case "tabs.getZoomSettings", "tabs.setZoomSettings":
      throw Failure("This operation requires Chromium’s native zoom settings bridge.")
    case "windows.get", "windows.getCurrent", "windows.getLastFocused", "windows.getAll":
      let hasID = request.method == "windows.get"
      let info = try properties(arg(hasID ? 1 : 0), allowed: ["populate", "windowTypes"])
      try validateWindowInfo(info)
      let targets: [BrowserWindowSession]
      if request.method == "windows.getAll" { targets = windows(profile) }
      else if request.method == "windows.getLastFocused" {
        guard let window = lastFocusedWindow(profile) else { throw Failure("This profile has no browser window.") }
        targets = [window]
      } else { targets = [try targetWindow(hasID ? arg(0) : nil, profile: profile, request: request)] }
      var values: [[String: Any]] = []
      for window in targets where (info["windowTypes"] as? [String]).map({ $0.contains(window.kind.rawValue) }) ?? true {
        values.append(try await windowData(window.id, profile: profile, info: info))
      }
      return request.method == "windows.getAll" ? [values] : values.map { $0 as Any }
    case "windows.update":
      let target = try targetWindow(arg(0), profile: profile, request: request)
      let props = try properties(arg(1), allowed: ["focused", "state", "left", "top", "width", "height", "drawAttention"])
      try validateWindow(props)
      if props["focused"] as? Bool == true { try canActivate(profile, in: target.id) }
      try await authorize(request, profile: profile, manager: manager)
      guard let context = engine.context(id: target.id), context.isOpen, !context.isClosing else { throw Failure("Browser window is closed.") }
      let window = context.window
      if props["focused"] as? Bool == true { try canActivate(profile, in: target.id) }
      if let state = props["state"] as? String {
        if state == "normal" {
          if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
          if window.isZoomed { window.zoom(nil) }; if window.isMiniaturized { window.deminiaturize(nil) }
        } else if state == "minimized" { window.miniaturize(nil) }
        else if state == "maximized", !window.isZoomed { window.zoom(nil) }
        else if state == "fullscreen", !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      }
      if ["left", "top", "width", "height"].contains(where: { props[$0] != nil }) {
        let topEdge = NSScreen.screens.first?.frame.maxY ?? 0
        var frame = window.frame
        let top = (props["top"] as? NSNumber)?.doubleValue ?? (topEdge - frame.maxY)
        frame.origin.x = (props["left"] as? NSNumber)?.doubleValue ?? frame.minX
        frame.size.width = (props["width"] as? NSNumber)?.doubleValue ?? frame.width
        frame.size.height = (props["height"] as? NSNumber)?.doubleValue ?? frame.height
        frame.origin.y = topEdge - top - frame.height
        window.setFrame(frame, display: true)
      }
      if let attention = props["drawAttention"] as? Bool {
        if let previous = attentionRequests.removeValue(forKey: target.id) { NSApp.cancelUserAttentionRequest(previous) }
        if attention && !isWindowFocused(target.id, profile: profile) {
          attentionRequests[target.id] = NSApp.requestUserAttention(.informationalRequest)
        }
      }
      if props["focused"] as? Bool == true { repository.focusWindow(target.id); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
      else if props["focused"] as? Bool == false, isWindowFocused(target.id, profile: profile) { NSApp.keyWindow?.resignKey() }
      didChange(); return [try await windowData(target.id, profile: profile)]
    case "windows.remove":
      let target = try targetWindow(arg(0), profile: profile, request: request)
      guard let closeWindow else { throw Failure("Window closure is unavailable.") }
      try await authorize(request, profile: profile, manager: manager)
      try canActivate(profile, in: target.id)
      guard await closeWindow(target.id) else { throw Failure("A page kept its unsaved changes.") }; return []
    case "windows.create":
      let props = try properties(arg(0), allowed: ["url", "tabId", "left", "top", "width", "height", "focused", "incognito", "type", "state", "setSelfAsOpener"])
      try validateWindow(props)
      guard props["incognito"] as? Bool != true else { throw Failure("This extension cannot access private browsing.") }
      let kind = NativeExtensionWindowRequest.Kind(rawValue: props["type"] as? String ?? "normal")
      guard let kind else { throw Failure("Unsupported browser window type.") }
      var urls: [String] = []
      var nativeAuthorizations: [String: NativeNavigationProvenance] = [:]
      if let addresses = props["url"] {
        let values = (addresses as? [Any]) ?? [addresses]
        guard !values.isEmpty, values.count <= 1_000 else { throw Failure("Invalid window URLs.") }
        for value in values {
          guard let destination = try await navigationDestination(value, request: request, profile: profile, manager: manager) else { throw Failure("Invalid window URL.") }
          urls.append(destination.url)
          if let proof = destination.provenance { nativeAuthorizations[destination.url] = proof }
        }
      }
      try await synchronizeCatalog(profile)
      var moving = try props["tabId"].map { try record(profile, nativeID: integer($0)) }
      if let value = moving {
        _ = try owner(value)
        moving = try await persistentTab(value, request: request, profile: profile, manager: manager)
      }
      guard let createWindow else { throw Failure("Native window creation is unavailable.") }
      try await authorize(request, profile: profile, manager: manager)
      let creation = NativeExtensionWindowRequest(profileID: profile, kind: kind, urls: urls, nativeAuthorizations: nativeAuthorizations,
        movingTabID: moving?.id, focused: props["focused"] as? Bool ?? true, state: props["state"] as? String,
        left: props["left"] as? Int, top: props["top"] as? Int, width: props["width"] as? Int, height: props["height"] as? Int,
        openerRequestID: props["setSelfAsOpener"] as? Bool == true ? request.requestID : nil,
        authorize: { [weak self] in
          guard let self else { throw CancellationError() }
          try await self.authorize(request, profile: profile, manager: manager)
        })
      let id = try await createWindow(creation)
      try await authorize(request, profile: profile, manager: manager)
      didChange(); return [try await windowData(id, profile: profile, info: ["populate": true])]
    default: throw Failure("Unsupported native browser API: \(request.method)")
    }
  }

  private func create(_ props: [String: Any], request: ChromeExtensionHostRequest, profile: String,
                      manager: ChromeExtensionManager, duplicateOf: BrowserTab? = nil) async throws -> [String: Any] {
    var props = try properties(props, allowed: ["url", "active", "selected", "index", "pinned", "windowId", "openerTabId"])
    if props["active"] == nil, let selected = props["selected"] { props["active"] = selected }
    try validateTabProperties(props)
    let target = try targetWindow(props["windowId"], profile: profile, request: request)
    guard let scope = repository.store(for: target.id) else { throw Failure("Unknown profile window.") }
    let active = props["active"] as? Bool ?? true
    if active { try canActivate(profile, in: target.id) }
    if let opener = props["openerTabId"] { try await synchronizeCatalog(profile); _ = try record(profile, nativeID: integer(opener)) }
    let destination: NavigationDestination
    if let original = duplicateOf {
      destination = try await duplicateDestination(original, profile: profile, manager: manager)
    } else {
      destination = try await navigationDestination(props["url"], request: request, profile: profile, manager: manager)
        ?? NavigationDestination(url: "about:blank", provenance: nil)
    }
    let address = destination.url
    try await authorize(request, profile: profile, manager: manager)
    if active { try canActivate(profile, in: target.id) }
    _ = try targetWindow(engine.context(id: target.id)?.nativeID, profile: profile, request: request)
    let openerID = try props["openerTabId"].map { try record(profile, nativeID: integer($0)).id }
    guard store.state.tabs.count < 1_000 else { throw Failure("Close some tabs before opening more.") }
    guard let space = store.state.spaces.first(where: { $0.id == scope.state.activeSpaceID && $0.profileID == profile })
      ?? store.state.spaces.first(where: { $0.profileID == profile }) else { throw Failure("Profile has no Space.") }
    var tab = BrowserTab(spaceID: space.id, url: address, title: address == "about:blank" ? "New tab" : NativePageIdentity.label(address),
      isPinned: props["pinned"] as? Bool ?? false)
    tab.windowID = target.id; tab.openerTabID = openerID; tab.nativeNavigation = destination.provenance
    tab.navigation = [NavigationEntry(url: address, nativeNavigation: destination.provenance)]; tab.navigationIndex = 0
    if tab.isPinned { tab.savedURL = address; tab.savedTitle = tab.title; tab.savedNativeNavigation = destination.provenance }
    try scope.commit { state in
      if let index = props["index"] as? Int, index >= 0 {
        let own = state.tabs.indices.filter { i in !state.tabs[i].isClosed && state.tabs[i].windowID == target.id && store.profileID(for: state.tabs[i]) == profile }
        state.tabs.insert(tab, at: index < own.count ? own[index] : (own.last.map { $0 + 1 } ?? state.tabs.count))
      } else { state.tabs.append(tab) }
    }
    try await synchronizeCatalog(profile)
    try await authorize(request, profile: profile, manager: manager)
    if active { try canActivate(profile, in: target.id) }
    guard documentTab(tab.id)?.isClosed == false else { throw Failure("The tab closed before the operation completed.") }
    if address != "about:blank" { navigateTab(tab, address) }
    _ = try await requireDocument(tab)
    try await authorize(request, profile: profile, manager: manager)
    if active { try canActivate(profile, in: documentTab(tab.id)?.windowID); try activateTab(tab.id) }
    didChange()
    return try await tabData(tab.id, profile: profile)
  }

  private struct ClosedSession {
    enum Kind: Equatable { case tab, window }
    let kind: Kind
    let id: String
    let token: String
    let date: Date
    let tabs: [BrowserTab]
    let window: BrowserWindowSession?
    var signature: String { token + ":" + tabs.map(\.id).joined(separator: ",") }
  }
  private func sessionToken(_ kind: String, id: String, date: Date) -> String {
    "zacro:" + kind + ":" + id + ":" + String(date.timeIntervalSince1970.bitPattern)
  }
  private func closedSessions(_ profile: String) -> [ClosedSession] {
    var entries = store.state.archive.filter { store.profileID(for: $0.tab) == profile }.map { item in
      ClosedSession(kind: .tab, id: item.id, token: sessionToken("tab", id: item.id, date: item.archivedAt),
        date: item.archivedAt, tabs: [item.tab], window: nil)
    }
    entries += store.state.tabs.compactMap { tab -> ClosedSession? in
      guard tab.isClosed, store.profileID(for: tab) == profile, let date = tab.closedAt else { return nil }
      return ClosedSession(kind: .tab, id: tab.id, token: sessionToken("pin", id: tab.id, date: date),
        date: date, tabs: [tab], window: nil)
    }
    for window in repository.windows where !window.isOpen {
      let owned = store.state.tabs.filter { $0.windowID == window.id }
      // Restoring a physical shell must not awaken another browsing profile.
      guard !owned.isEmpty, owned.allSatisfy({ store.profileID(for: $0) == profile }),
        store.state.spaces.first(where: { $0.id == window.activeSpaceID })?.profileID == profile else { continue }
      let persistent = owned.filter { !$0.isClosed }
      let tabs = persistent + persistent.compactMap(\.peekDocument)
      guard !tabs.isEmpty else { continue }
      let date = window.closedAt ?? .distantPast
      entries.append(ClosedSession(kind: .window, id: window.id,
        token: sessionToken("window", id: window.id, date: date), date: date, tabs: tabs, window: window))
    }
    return entries.sorted { $0.date == $1.date ? $0.token < $1.token : $0.date > $1.date }
  }
  private func closedSession(_ token: String?, profile: String) throws -> ClosedSession {
    let entries = closedSessions(profile)
    guard let token else {
      guard let first = entries.first else { throw Failure("There are no recently closed tabs or windows.") }
      return first
    }
    for entry in entries {
      if entry.token == token { return entry }
      if entry.kind == .window, let tab = entry.tabs.first(where: { sessionToken("window-tab", id: $0.id, date: entry.date) == token }) {
        return ClosedSession(kind: .tab, id: tab.id, token: token, date: entry.date, tabs: [tab], window: entry.window)
      }
    }
    throw Failure("This recently closed session is no longer available in this profile.")
  }
  private func closedTabData(_ tab: BrowserTab, token: String, index: Int, active: Bool) -> [String: Any] {
    ["sessionId": token, "index": index, "windowId": -1, "groupId": -1, "splitViewId": -1,
      "selected": active, "active": active, "highlighted": active, "pinned": tab.isPinned,
      "frozen": false, "discarded": false, "autoDiscardable": tab.autoDiscardable != false,
      "incognito": false, "lastAccessed": tab.lastAccessedAt.timeIntervalSince1970 * 1_000,
      "url": tab.url, "title": tab.title, "favIconUrl": ""]
  }
  private func closedSessionData(_ entry: ClosedSession) -> [String: Any] {
    let modified = Int(max(0, min(Double(Int32.max), entry.date.timeIntervalSince1970)))
    if entry.kind == .tab {
      return ["lastModified": modified, "tab": closedTabData(entry.tabs[0], token: entry.token, index: 0, active: false)]
    }
    let tabs = entry.tabs.enumerated().map { index, tab in
      closedTabData(tab, token: sessionToken("window-tab", id: tab.id, date: entry.date),
        index: index, active: entry.window.map { activeDocumentID($0) == tab.id } ?? false)
    }
    return ["lastModified": modified, "window": ["sessionId": entry.token, "tabs": tabs,
      "type": entry.window?.kind.rawValue ?? "normal", "state": "normal", "incognito": false,
      "alwaysOnTop": false, "focused": false]]
  }
  private func performSession(_ request: ChromeExtensionHostRequest, profile: String,
                              arguments: [Any], manager: ChromeExtensionManager) async throws -> [Any] {
    if request.method != "sessions.restore" {
      let filter = try properties(arguments.first, allowed: ["maxResults"])
      let count = try filter["maxResults"].map { try integer($0, minimum: 0) } ?? 25
      guard count <= 25 else { throw Failure("At most 25 sessions may be requested.") }
      // No browser session sync account is configured. Do not expose physical
      // Chrome manager/child windows as local or foreign browsing sessions.
      if request.method == "sessions.getDevices" { return [[Any]()] }
      return [closedSessions(profile).prefix(count).map { closedSessionData($0) }]
    }
    let token: String?
    if let value = arguments.first, !(value is NSNull) {
      guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512 else { throw Failure("Invalid session ID.") }
      token = value
    } else { token = nil }
    let entry = try closedSession(token, profile: profile)
    for tab in entry.tabs {
      if let proof = tab.nativeNavigation {
        _ = try await duplicateDestination(tab, profile: profile, manager: manager, requireOpen: false)
        guard proof.matches(tab.url) else { throw Failure("The saved page is no longer authorized.") }
      }
    }
    try await authorize(request, profile: profile, manager: manager)
    guard try closedSession(entry.token, profile: profile).tabs == entry.tabs else { throw Failure("The saved session changed.") }
    let now = Int(Date().timeIntervalSince1970)
    if entry.kind == .window {
      guard let restoreWindow else { throw Failure("Window restoration is unavailable.") }
      let id = try await restoreWindow(entry.id, { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.authorize(request, profile: profile, manager: manager)
        guard try self.closedSession(entry.token, profile: profile).tabs == entry.tabs else { throw Failure("The saved window changed.") }
      })
      try await authorize(request, profile: profile, manager: manager)
      didChange()
      return [["lastModified": now, "window": try await windowData(id, profile: profile, info: ["populate": true])]]
    }
    let target: BrowserWindowSession
    if let retained = documentTab(entry.id), retained.isClosed,
      let existing = windows(profile).first(where: { $0.id == retained.windowID }) {
      target = existing
    } else { target = try currentWindow(profile, request: request) }
    try canActivate(profile, in: target.id)
    guard let scope = repository.store(for: target.id) else { throw Failure("Unknown profile window.") }
    let tab = try scope.restoreSessionTabDurably(id: entry.id)
    _ = try await requireDocument(tab)
    try await authorize(request, profile: profile, manager: manager)
    try canActivate(profile, in: documentTab(tab.id)?.windowID)
    try activateTab(tab.id); didChange()
    return [["lastModified": now, "tab": try await tabData(tab.id, profile: profile)]]
  }

  private func requireDocument(_ tab: BrowserTab) async throws -> ChromiumPage {
    let page: ChromiumPage
    if let materializePage { page = try await materializePage(tab) }
    else if let existing = engine.pages[tab.id] { page = existing }
    else { throw Failure("The tab could not be loaded.") }
    guard engine.pages[tab.id] === page, let current = documentTab(tab.id), !current.isClosed,
      store.profileID(for: current) == page.profileID else { throw Failure("The tab closed before the operation completed.") }
    return page
  }

  private func windowData(_ id: String, profile: String, info: [String: Any] = [:]) async throws -> [String: Any] {
    try checkProfile(profile)
    guard let session = windows(profile).first(where: { $0.id == id }),
      let context = engine.context(id: id), context.isOpen else { throw Failure("Unknown profile window.") }
    let window = context.window
    let bounds = window.frame, top = (NSScreen.screens.first?.frame.maxY ?? 0) - bounds.maxY
    var data: [String: Any] = ["id": context.nativeID, "type": session.kind.rawValue,
      "focused": isWindowFocused(id, profile: profile), "incognito": false,
      "alwaysOnTop": window.level.rawValue > NSWindow.Level.normal.rawValue,
      "state": window.styleMask.contains(.fullScreen) ? "fullscreen" : window.isMiniaturized ? "minimized" : window.isZoomed ? "maximized" : "normal",
      "left": Int(bounds.minX.rounded()), "top": Int(top.rounded()), "width": Int(bounds.width.rounded()), "height": Int(bounds.height.rounded())]
    if info["populate"] as? Bool == true {
      data["tabs"] = try await allTabData(profile).filter { $0["windowId"] as? Int == context.nativeID }
    }
    return data
  }

  private func publishChanges() async {
    let revision = epoch
    var next: [String: Snapshot] = [:]
    let profiles = store.state.profiles.filter({ !$0.isPrivate }).map(\.id)
    // A failed topology refresh must not leave another profile's global
    // shortcut registry active. Clear inactive focus before any catalog await.
    for profile in profiles where !windows(profile).contains(where: { isWindowFocused($0.id, profile: profile) }) {
      guard revision == epoch, !Task.isCancelled else { return }
      await publishFocus(profile, manager: ChromeExtensionManager(engine: engine, profileID: profile))
    }
    for profile in profiles {
      let manager = ChromeExtensionManager(engine: engine, profileID: profile)
      do { try await synchronizeCatalog(profile) }
      catch {
        for (id, previous) in snapshots where previous.profile == profile { next[id] = previous }
        continue
      }
      let closed = closedSessions(profile).map(\.signature)
      if let previous = sessionSnapshots[profile], previous != closed {
        do {
          try await manager.publishBrowserEvent("sessions.onChanged", arguments: [])
          sessionSnapshots[profile] = closed
        } catch { }
      } else if sessionSnapshots[profile] == nil { sessionSnapshots[profile] = closed }
      await publishGroupChanges(profile, manager: manager)
      let sessions = windows(profile)
      var currentWindows: [String: [String: Any]] = [:]
      for session in sessions {
        guard revision == epoch, !Task.isCancelled else { return }
        guard let value = try? await windowData(session.id, profile: profile), let id = value["id"] as? Int else { continue }
        let key = profile + ":" + String(id)
        currentWindows[key] = value
        if !publishedWindows.contains(key) {
          do {
            try await manager.publishBrowserEvent("windows.onCreated", arguments: [value])
            publishedWindows.insert(key); windowSnapshots[key] = value
          } catch { }
        }
      }
      for tab in tabs(profile) {
        guard revision == epoch, !Task.isCancelled, enabled, !stopped else { return }
        do {
          let value = try await tabData(tab.id, profile: profile, synchronize: false)
          guard revision == epoch, !Task.isCancelled else { return }
          let old = snapshots[tab.id]
          next[tab.id] = Snapshot(profile: profile, value: value)
          if let old, !equal(old.value["id"], value["id"]) {
            try await manager.publishBrowserEvent("tabs.onRemoved", arguments: [old.value["id"]!,
              ["windowId": old.value["windowId"]!, "isWindowClosing": isRetiredWindow(old.value["windowId"])]] )
          }
          if old == nil || !equal(old?.value["id"], value["id"]) {
            try await manager.publishBrowserEvent("tabs.onCreated", arguments: [value])
          } else if let old {
            if !equal(old.value["windowId"], value["windowId"]) {
              try await manager.publishBrowserEvent("tabs.onDetached", arguments: [value["id"]!,
                ["oldWindowId": old.value["windowId"]!, "oldPosition": old.value["index"]!]])
              try await manager.publishBrowserEvent("tabs.onAttached", arguments: [value["id"]!,
                ["newWindowId": value["windowId"]!, "newPosition": value["index"]!]])
            } else if !equal(old.value["index"], value["index"]) {
              try await manager.publishBrowserEvent("tabs.onMoved", arguments: [value["id"]!,
                ["windowId": value["windowId"]!, "fromIndex": old.value["index"]!, "toIndex": value["index"]!]])
            }
            var changes: [String: Any] = [:]
            for key in ["url", "title", "pinned", "audible", "status", "favIconUrl", "mutedInfo", "discarded", "autoDiscardable", "splitViewId", "groupId"] {
              if let item = value[key], !equal(old.value[key], item) { changes[key] = item }
            }
            if !changes.isEmpty { try await manager.publishBrowserEvent("tabs.onUpdated", arguments: [value["id"]!, changes, value]) }
          }
          if value["active"] as? Bool == true,
            old == nil || old?.value["active"] as? Bool != true || !equal(old?.value["windowId"], value["windowId"]) || !equal(old?.value["id"], value["id"]) {
            let legacy: [Any] = [value["id"]!, ["windowId": value["windowId"]!]]
            try await manager.publishBrowserEvent("tabs.onSelectionChanged", arguments: legacy)
            try await manager.publishBrowserEvent("tabs.onActiveChanged", arguments: legacy)
            try await manager.publishBrowserEvent("tabs.onActivated", arguments: [["tabId": value["id"]!, "windowId": value["windowId"]!]])
          }
        } catch {
          if let old = snapshots[tab.id] { next[tab.id] = old }
        }
      }
      guard revision == epoch, !Task.isCancelled else { return }
      for (id, previous) in snapshots where previous.profile == profile && next[id] == nil {
        try? await manager.publishBrowserEvent("tabs.onRemoved", arguments: [previous.value["id"]!,
          ["windowId": previous.value["windowId"]!, "isWindowClosing": isRetiredWindow(previous.value["windowId"])]])
        identities.removeValue(forKey: id)
      }
      for session in sessions {
        guard let context = engine.context(id: session.id) else { continue }
        let key = profile + ":" + String(context.nativeID)
        let highlighted = tabs(profile, in: session.id).filter { highlightedDocuments(session).contains($0.id) }
          .compactMap { next[$0.id]?.value["id"] as? Int }
        if highlightSnapshots[key] != highlighted {
          do {
            let selection: [Any] = [["windowId": context.nativeID, "tabIds": highlighted]]
            try await manager.publishBrowserEvent("tabs.onHighlightChanged", arguments: selection)
            try await manager.publishBrowserEvent("tabs.onHighlighted", arguments: selection)
            highlightSnapshots[key] = highlighted
          } catch { }
        }
        // Chromium sends committed bounds, not intermediate native drag frames.
        if context.window.contentView?.inLiveResize != true,
          let value = currentWindows[key], let previous = windowSnapshots[key],
          ["left", "top", "width", "height"].contains(where: { !equal(previous[$0], value[$0]) }) {
          do {
            try await manager.publishBrowserEvent("windows.onBoundsChanged", arguments: [value])
            windowSnapshots[key] = value
          } catch { }
        }
      }
      for key in publishedWindows.filter({ $0.hasPrefix(profile + ":") && currentWindows[$0] == nil }) {
        if let id = windowSnapshots[key]?["id"] {
          try? await manager.publishBrowserEvent("windows.onRemoved", arguments: [id])
        }
        publishedWindows.remove(key); windowSnapshots.removeValue(forKey: key); highlightSnapshots.removeValue(forKey: key)
      }
      await publishFocus(profile, manager: manager)
    }
    if revision == epoch, !Task.isCancelled { snapshots = next }
  }

  private func publishFocus(_ profile: String, manager: ChromeExtensionManager) async {
    let focused = windows(profile).first(where: { isWindowFocused($0.id, profile: profile) })
      .flatMap { engine.context(id: $0.id)?.nativeID }
    let lastFocused = lastFocusedWindow(profile).flatMap { engine.context(id: $0.id)?.nativeID }
    guard focusSnapshots[profile] != (focused ?? -1) || lastFocusSnapshots[profile] != (lastFocused ?? -1) else { return }
    do {
      try await manager.setFocusedWindow(focused, lastFocusedID: lastFocused)
      if focusSnapshots[profile] != (focused ?? -1) {
        try await manager.publishBrowserEvent("windows.onFocusChanged", arguments: [focused ?? -1])
      }
      focusSnapshots[profile] = focused ?? -1; lastFocusSnapshots[profile] = lastFocused ?? -1
    } catch { }
  }

  private func isRetiredWindow(_ value: Any?) -> Bool {
    guard let id = value as? Int else { return false }
    return !engine.contexts.values.contains { $0.nativeID == id && $0.isOpen }
  }
  private func isWindowFocused(_ id: String, profile: String) -> Bool {
    guard repository.store(for: id)?.activeProfileID == profile, NSApp.isActive,
      let context = engine.context(id: id), context.isOpen else { return false }
    var candidate = NSApp.keyWindow
    while let window = candidate { if window === context.window { return true }; candidate = window.parent }
    return NSApp.keyWindow.map { engine.extensionPopupOwner($0)?.id == id } ?? false
  }
  private func lastFocusedWindow(_ profile: String) -> BrowserWindowSession? {
    let available = windows(profile)
    if let current = available.first(where: { isWindowFocused($0.id, profile: profile) }) {
      lastFocusedWindows[profile] = current.id; return current
    }
    return available.first(where: { $0.id == lastFocusedWindows[profile] })
      ?? available.first(where: { $0.id == repository.focusedWindowID }) ?? available.first
  }
  private func canActivate(_ profile: String, in id: String?) throws {
    guard let id, engine.context(id: id)?.isOpen == true, engine.context(id: id)?.isClosing == false,
      repository.store(for: id)?.activeProfileID == profile else { throw Failure("A hidden profile cannot take focus.") }
  }
  private func targetWindow(_ value: Any?, profile: String, request: ChromeExtensionHostRequest?) throws -> BrowserWindowSession {
    let target: BrowserWindowSession
    if value == nil || value is NSNull || (try? integer(value, minimum: -2)) == -2 {
      target = try currentWindow(profile, request: request)
    } else {
      let id = try integer(value)
      guard let window = windows(profile).first(where: { engine.context(id: $0.id)?.nativeID == id }) else { throw Failure("Unknown profile window.") }
      target = window
    }
    guard engine.context(id: target.id)?.isClosing == false else { throw Failure("The browser window is closing.") }
    return target
  }
  private func validateWindowInfo(_ info: [String: Any]) throws {
    if let value = info["populate"] {
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure("Invalid window populate option.") }
    }
    if let value = info["windowTypes"] {
      guard let types = value as? [String], types.allSatisfy({ ["normal", "popup", "panel", "app", "devtools"].contains($0) }) else { throw Failure("Invalid window type filter.") }
    }
  }
  private func properties(_ value: Any?, allowed: Set<String>? = nil) throws -> [String: Any] {
    guard let value, !(value is NSNull) else { return [:] }
    guard let object = value as? [String: Any] else { throw Failure("Invalid browser API properties.") }
    if let allowed, let unsupported = object.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw Failure("Unsupported native browser property: \(unsupported)")
    }
    return object
  }
  private func identifiers(_ value: Any?) throws -> [Int] {
    if let list = value as? [Any] { guard !list.isEmpty, list.count <= 1_000 else { throw Failure("Invalid tab IDs.") }; return try list.map { try integer($0) } }
    return [try integer(value)]
  }
  private func number(_ value: Any?) throws -> Double {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
      throw Failure("Invalid numeric browser API property.")
    }
    return number.doubleValue
  }
  private func integer(_ value: Any?, minimum: Int = 0) throws -> Int {
    let number = try number(value)
    guard number.rounded() == number, number >= Double(minimum), number <= Double(Int32.max) else { throw Failure("Invalid tab or window ID/index.") }
    return Int(number)
  }
  private func validateTabProperties(_ props: [String: Any]) throws {
    for key in ["active", "selected", "pinned", "muted", "highlighted", "bypassCache", "autoDiscardable"] where props[key] != nil {
      guard let value = props[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure("Invalid tab property.") }
    }
    if let index = props["index"] { _ = try integer(index, minimum: -1) }
  }
  private func validateWindow(_ props: [String: Any]) throws {
    for key in ["left", "top", "width", "height"] where props[key] != nil {
      let value = try number(props[key])
      guard value.rounded() == value, abs(value) <= 32768, !["width", "height"].contains(key) || value >= 200 else { throw Failure("Invalid window bounds.") }
    }
    for key in ["focused", "drawAttention", "incognito", "setSelfAsOpener"] where props[key] != nil {
      guard let number = props[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure("Invalid window option.") }
    }
    if let value = props["state"] {
      guard let value = value as? String, ["normal", "minimized", "maximized", "fullscreen"].contains(value) else { throw Failure("Invalid window state.") }
      if value != "normal", ["left", "top", "width", "height"].contains(where: { props[$0] != nil }) { throw Failure("Window bounds require the normal window state.") }
      if value == "minimized", props["focused"] as? Bool == true { throw Failure("A minimized window cannot be focused.") }
      if ["fullscreen", "maximized"].contains(value), props["focused"] as? Bool == false { throw Failure("This window state requires focus.") }
    }
  }
  private struct NavigationDestination {
    let url: String
    let provenance: NativeNavigationProvenance?
  }
  private func navigationDestination(_ value: Any?, request: ChromeExtensionHostRequest, profile: String,
                                     manager: ChromeExtensionManager) async throws -> NavigationDestination? {
    guard let value, !(value is NSNull) else { return nil }
    guard let text = value as? String, !text.isEmpty, let url = URL(string: text), url.absoluteString == text else {
      throw Failure("Unsupported navigation URL.")
    }
    // Chromium has already normalized and authorized the request's URL. Keep
    // ordinary documents independent of the lifetime of the creating extension.
    if BrowserAddress.documentURL(text)?.absoluteString == text {
      return NavigationDestination(url: text, provenance: nil)
    }
    let approval = try await manager.authorizeHostNavigation(requestID: request.requestID, url: url)
    try checkProfile(profile, request: request)
    guard approval.profileID == profile, approval.extensionID == request.extensionID,
      approval.url.absoluteString == text,
      let proof = NativeNavigationProvenance(extensionID: approval.extensionID,
        incarnationID: approval.incarnationID, approvedURL: text) else {
      throw Failure("The browser did not approve this navigation.")
    }
    return NavigationDestination(url: text, provenance: proof)
  }
  private func duplicateDestination(_ tab: BrowserTab, profile: String,
                                    manager: ChromeExtensionManager, requireOpen: Bool = true) async throws -> NavigationDestination {
    if BrowserAddress.documentURL(tab.url)?.absoluteString == tab.url {
      return NavigationDestination(url: tab.url, provenance: nil)
    }
    guard let proof = tab.nativeNavigation, proof.matches(tab.url), let url = URL(string: tab.url) else {
      throw Failure("This page cannot be duplicated.")
    }
    let approval = try await manager.validateNavigation(extensionID: proof.extensionID,
      incarnationID: proof.incarnationID, url: url)
    try checkProfile(profile)
    guard approval.profileID == profile, approval.extensionID == proof.extensionID,
      approval.incarnationID == proof.incarnationID, approval.url.absoluteString == tab.url else {
      throw Failure("The page is no longer authorized.")
    }
    if requireOpen {
      guard let current = documentTab(tab.id), !current.isClosed, current.url == tab.url,
        current.nativeNavigation == proof else { throw Failure("The page changed before it could be duplicated.") }
    }
    return NavigationDestination(url: tab.url, provenance: proof)
  }
  private func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs else { return rhs == nil }; guard let rhs else { return false }
    return (lhs as? NSObject)?.isEqual(rhs) == true
  }
}
