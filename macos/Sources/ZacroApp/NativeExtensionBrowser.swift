import AppKit
import CoreFoundation
import Foundation
import ZacroCore
import ZacroChromium

/// The authoritative Zacro tab/window model behind Chromium's native extension
/// dispatcher. Chromium owns API schemas, permission checks, URL preparation,
/// response redaction and query filtering. This object never injects an API shim.
@MainActor
final class NativeExtensionBrowser {
  var enabled = false
  var materializePage: ((BrowserTab) async throws -> ChromiumPage)?
  var closeTab: (String) async -> Bool = { _ in false }
  var navigateTab: (BrowserTab, String) -> Void = { _, _ in }
  var activateTab: (String) -> Void = { _ in }
  var discardTab: ((String) async throws -> Bool)?
  var closeWindow: (() async -> Bool)?
  var isDiscarded: (String) -> Bool = { _ in false }
  var isAudible: (String) -> Bool = { _ in false }
  var profileAvailable: (String) -> Bool = { _ in true }
  var didChange: () -> Void = {}

  private let store: BrowserStore
  private let engine: ChromiumEngine
  private let windowID = 1
  private var identities: [String: Identity] = [:]
  private var catalogTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  private var catalogKeys: [String: Data] = [:]
  private var catalogRevisions: [String: UInt64] = [:]
  private var catalogMembers: [String: Set<String>] = [:]
  private var splitIdentities: [String: Int] = [:]
  private var nextSplitIdentity = 1
  private var snapshots: [String: Snapshot] = [:]
  private var focusSnapshots: [String: Int] = [:]
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
  private struct Failure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  init(store: BrowserStore, engine: ChromiumEngine) {
    self.store = store; self.engine = engine
  }

  /// Reserves an immutable native identity without creating a document/view.
  /// The caller must pass the returned token to the CEF factory, not a page.
  func preparePageCreation(tabID: String) async throws -> ChromeTabMaterialization? {
    guard enabled, let tab = store.tab(tabID), !tab.isClosed,
      let profile = store.profileID(for: tab),
      store.state.profiles.contains(where: { $0.id == profile && !$0.isPrivate }) else { return nil }
    try await synchronizeCatalog(profile)
    let ticket = try await ChromeExtensionManager(engine: engine, profileID: profile).prepareTabMaterialization(tabID)
    try checkProfile(profile)
    guard store.tab(tabID)?.isClosed == false, identities[tabID]?.id == ticket.nativeID,
      ticket.logicalID == tabID, ticket.profileID == profile else { throw Failure("The tab changed before its document could load.") }
    return ticket
  }

  /// Adopts an existing real popup/startup page, or verifies that a newly
  /// materialized page received its reserved ID before any document script runs.
  func prepareInitialNavigation(_ page: ChromiumPage) async throws {
    guard enabled, !page.isPrivate, let tab = store.tab(page.id), !tab.isClosed,
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
      defer { self.pending.remove(key) }
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
    guard enabled, !stopped, engine.isWindowOpen, !engine.isTerminating else { return }
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

  func windowFocusChanged() { reconcile() }

  /// The logical window disappears only after every document accepted close.
  /// The persistent management document remains alive to dispatch native events.
  func didCloseWindow() async {
    guard enabled, !stopped else { return }
    epoch &+= 1; reconcileAgain = false; reconciliation?.cancel(); reconciliation = nil
    for pending in catalogTasks.values { pending.task.cancel() }
    catalogTasks.removeAll(); catalogKeys.removeAll(); catalogMembers.removeAll()
    let previous = snapshots, profiles = publishedWindows
    snapshots.removeAll(); identities.removeAll(); focusSnapshots.removeAll(); highlightSnapshots.removeAll()
    windowSnapshots.removeAll(); publishedWindows.removeAll()
    let earlier = closingEvents
    let task = Task { [weak self] in
      await earlier?.value
      guard let self else { return }
      for profile in profiles where self.store.state.profiles.contains(where: { $0.id == profile && !$0.isPrivate }) {
        let manager = ChromeExtensionManager(engine: self.engine, profileID: profile)
        for item in previous.values where item.profile == profile {
          try? await manager.publishBrowserEvent("tabs.onRemoved", arguments: [item.value["id"]!, ["windowId": self.windowID, "isWindowClosing": true]])
        }
        try? await manager.publishBrowserEvent("windows.onFocusChanged", arguments: [-1])
        try? await manager.publishBrowserEvent("windows.onRemoved", arguments: [self.windowID])
        let revision = (self.catalogRevisions[profile] ?? 0) + 1
        self.catalogRevisions[profile] = revision
        _ = try? await manager.synchronizeTabs([], revision: revision)
      }
    }
    closingEvents = task
    await task.value
  }

  func close() async {
    stopped = true; epoch &+= 1; reconciliation?.cancel(); reconciliation = nil; closingEvents?.cancel()
    for task in tails.values { task.cancel() }
    for pending in catalogTasks.values { pending.task.cancel() }
    catalogTasks.removeAll(); catalogKeys.removeAll(); catalogMembers.removeAll()
    // A pending windows.remove can itself be awaiting this shutdown. Chromium
    // owns revocation of its request; do not deadlock termination on that wait.
    tails.removeAll(); identities.removeAll(); snapshots.removeAll(); pending.removeAll()
  }

  private func checkProfile(_ profile: String, request: ChromeExtensionHostRequest? = nil) throws {
    guard enabled, !stopped, !Task.isCancelled else { throw Failure("The native browser extension bridge is unavailable.") }
    guard engine.isWindowOpen, !engine.isWindowClosing, !engine.isTerminating, engine.window != nil else {
      throw Failure("Browser window is closed.")
    }
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

  private func tabs(_ profile: String) -> [BrowserTab] {
    store.state.tabs.filter { !$0.isClosed && store.profileID(for: $0) == profile }
  }

  private func record(_ profile: String, nativeID: Int) throws -> BrowserTab {
    guard let tab = tabs(profile).first(where: { identities[$0.id]?.id == nativeID }) else {
      throw Failure("Unknown profile tab.")
    }
    return tab
  }

  private func defaultRecord(_ profile: String, id: Any?) throws -> BrowserTab {
    if let id, !(id is NSNull) { return try record(profile, nativeID: integer(id)) }
    guard let tab = tabs(profile).first(where: { $0.id == store.state.activeTabID }) else {
      throw Failure("This profile has no active tab.")
    }
    return tab
  }

  private func registrations(_ profile: String) throws -> [ChromeLogicalTabRegistration] {
    let records = tabs(profile), valid = Set(records.map(\.id))
    return try records.enumerated().map { index, tab in
      let opener = tab.openerTabID ?? engine.pages[tab.id]?.openerID
      return ChromeLogicalTabRegistration(logicalID: tab.id, windowID: windowID, index: index,
        active: store.state.activeTabID == tab.id, pinned: tab.isPinned, discarded: isDiscarded(tab.id),
        autoDiscardable: tab.autoDiscardable != false, splitViewID: try splitIdentity(tab.id, profile: profile),
        openerLogicalID: opener.flatMap { $0 != tab.id && valid.contains($0) ? $0 : nil })
    }
  }
  private func catalogKey(_ entries: [ChromeLogicalTabRegistration]) throws -> Data {
    try JSONSerialization.data(withJSONObject: entries.map { item -> [String: Any] in
      ["id": item.logicalID, "window": item.windowID, "index": item.index, "active": item.active,
       "pinned": item.pinned, "discarded": item.discarded, "automatic": item.autoDiscardable,
       "split": item.splitViewID, "opener": item.openerLogicalID ?? "",
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
      if catalogKeys[profile] == desired { return }
      let token = UUID(), generation = epoch
      let task = Task { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
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
    guard page.profileID == profile, !page.isPrivate, engine.pages[page.id] === page,
      let entry = try registrations(profile).first(where: { $0.logicalID == page.id }) else {
      throw Failure("The tab closed before its document could load.")
    }
    let opener = entry.openerLogicalID.flatMap { identities[$0]?.id }
    let signature = "\(entry.index):\(entry.active):\(entry.pinned):\(entry.discarded):\(entry.autoDiscardable):\(entry.splitViewID):\(opener ?? -1)"
    if let existing = identities[page.id], existing.page === page, existing.signature == signature { return }
    let browser = try await page.ready()
    try checkProfile(profile)
    guard engine.pages[page.id] === page, store.tab(page.id)?.isClosed == false else { throw Failure("Unknown profile tab.") }
    let nativeID = try await browser.registerExtensionTab(logicalID: page.id, windowID: entry.windowID,
      index: entry.index, active: entry.active, pinned: entry.pinned, discarded: entry.discarded,
      autoDiscardable: entry.autoDiscardable, splitViewID: entry.splitViewID, openerTabID: opener)
    try checkProfile(profile)
    guard engine.pages[page.id] === page, store.tab(page.id)?.isClosed == false,
      page.reservedNativeTabID.map({ $0 == nativeID }) ?? true else { throw Failure("The native tab identity changed.") }
    identities[page.id] = Identity(page, id: nativeID, signature: signature)
  }

  private func tabData(_ logicalID: String, profile: String, synchronize: Bool = true) async throws -> [String: Any] {
    if synchronize { try await synchronizeCatalog(profile) }
    try checkProfile(profile)
    let records = tabs(profile)
    guard let index = records.firstIndex(where: { $0.id == logicalID }) else { throw Failure("Unknown profile tab.") }
    return try tabMetadata(records[index], index: index, profile: profile, validIDs: Set(records.map(\.id)))
  }

  private func tabMetadata(_ tab: BrowserTab, index: Int, profile: String, validIDs: Set<String>) throws -> [String: Any] {
    guard let identity = identities[tab.id] else { throw Failure("Unknown profile tab.") }
    let page = engine.pages[tab.id], active = store.state.activeTabID == tab.id
    let muted = page?.browser?.isAudioMuted ?? tab.isMuted
    var value: [String: Any] = [
      "id": identity.id, "windowId": windowID, "index": index,
      "active": active, "highlighted": active, "pinned": tab.isPinned, "incognito": false,
      "selected": active, "groupId": -1, "splitViewId": try splitIdentity(tab.id, profile: profile), "frozen": false,
      "lastAccessed": tab.lastAccessedAt.timeIntervalSince1970 * 1_000,
      "url": tab.url, "title": tab.title, "status": page?.isLoading == true ? "loading" : "complete",
      "audible": isAudible(tab.id), "mutedInfo": ["muted": muted], "muted": muted,
      "discarded": isDiscarded(tab.id), "autoDiscardable": tab.autoDiscardable != false,
    ]
    if let favicon = page?.faviconURL { value["favIconUrl"] = favicon.absoluteString }
    let opener = tab.openerTabID ?? page?.openerID
    if let opener, validIDs.contains(opener), let id = identities[opener]?.id { value["openerTabId"] = id }
    return value
  }

  private func allTabData(_ profile: String) async throws -> [[String: Any]] {
    try await synchronizeCatalog(profile)
    let records = tabs(profile), validIDs = Set(records.map(\.id))
    return try records.enumerated().map { try tabMetadata($0.element, index: $0.offset, profile: profile, validIDs: validIDs) }
  }

  private func splitIdentity(_ tabID: String, profile: String) throws -> Int {
    guard let group = store.split(for: tabID) else { return -1 }
    let key = profile + ":" + group.id
    if let identity = splitIdentities[key] { return identity }
    guard nextSplitIdentity < Int32.max else { throw Failure("Split view identity limit reached.") }
    let identity = nextSplitIdentity; nextSplitIdentity += 1; splitIdentities[key] = identity
    return identity
  }

  private func perform(_ request: ChromeExtensionHostRequest, profile: String,
                       arguments: [Any], manager: ChromeExtensionManager) async throws -> [Any] {
    func arg(_ index: Int) -> Any? { arguments.indices.contains(index) ? arguments[index] : nil }
    try await authorize(request, profile: profile, manager: manager)
    switch request.method {
    case "tabs.query", "tabs.getAllInWindow":
      if request.method == "tabs.getAllInWindow" { try targetWindow(arg(0)) }
      let query = request.method == "tabs.query" ? try properties(arg(0)) : [:]
      _ = try NativeExtensionQuery.matches(query: query, tab: [:], currentWindowID: windowID,
        lastFocusedWindowID: windowID, windowType: "normal")
      try await authorize(request, profile: profile, manager: manager)
      // Filter nonsensitive model fields here. Chromium filters URL/title only
      // after removing metadata that this caller is not allowed to read.
      let values = try await allTabData(profile)
      return [try values.filter { try NativeExtensionQuery.matches(query: query, tab: $0,
        currentWindowID: windowID, lastFocusedWindowID: windowID, windowType: "normal") }]
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
      try targetWindow(arg(0))
      return [try await tabData(defaultRecord(profile, id: nil).id, profile: profile)]
    case "tabs.create":
      let props = try properties(arg(0))
      return [try await create(props, request: request, profile: profile, manager: manager)]
    case "tabs.update":
      let propertiesFirst = arg(0) is [String: Any]
      var props = try properties(propertiesFirst ? arg(0) : arg(1), allowed: ["url", "active", "selected", "pinned", "muted", "highlighted", "autoDiscardable", "openerTabId"])
      if props["active"] == nil, let selected = props["selected"] { props["active"] = selected }
      try await synchronizeCatalog(profile)
      let tab = try defaultRecord(profile, id: propertiesFirst ? nil : arg(0))
      try validateTabProperties(props)
      if props["highlighted"] as? Bool == false { throw Failure("The active tab cannot be unhighlighted independently.") }
      let activate = props["active"] as? Bool == true || props["highlighted"] as? Bool == true
      if activate { try canActivate(profile) }
      let address = try navigationURL(props["url"], extensionID: request.extensionID)
      try await authorize(request, profile: profile, manager: manager)
      if activate { try canActivate(profile) }
      guard store.tab(tab.id)?.isClosed == false else { throw Failure("Unknown profile tab.") }
      let openerID = try props["openerTabId"].map { try record(profile, nativeID: integer($0)).id }
      if openerID == tab.id { throw Failure("A tab cannot be its own opener.") }
      try store.commit { state in
        guard let i = state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let pinned = props["pinned"] as? Bool, pinned != state.tabs[i].isPinned {
          state.tabs[i].isPinned = pinned; state.tabs[i].isFavorite = false; state.tabs[i].folderID = nil
          state.tabs[i].savedURL = pinned ? state.tabs[i].url : nil
          state.tabs[i].savedTitle = pinned ? state.tabs[i].title : nil
        }
        if let muted = props["muted"] as? Bool { state.tabs[i].isMuted = muted }
        if let automatic = props["autoDiscardable"] as? Bool { state.tabs[i].autoDiscardable = automatic }
        if let openerID { state.tabs[i].openerTabID = openerID }
        if let address { state.tabs[i].url = address; state.tabs[i].homePage = nil }
      }
      if let muted = props["muted"] as? Bool { engine.pages[tab.id]?.browser?.isAudioMuted = muted }
      if let address, let current = store.tab(tab.id) {
        navigateTab(current, address)
        _ = try await requireDocument(current)
        try await authorize(request, profile: profile, manager: manager)
      }
      if activate { activateTab(tab.id) }
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
      let tab = try defaultRecord(profile, id: propertiesFirst ? nil : arg(0))
      try await authorize(request, profile: profile, manager: manager)
      let wasDiscarded = isDiscarded(tab.id)
      let page = try await requireDocument(tab)
      let browser = try await page.ready()
      try await authorize(request, profile: profile, manager: manager)
      guard engine.pages[tab.id] === page, store.tab(tab.id)?.isClosed == false else { throw Failure("Unknown profile tab.") }
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
      let props: [String: Any] = ["url": tab.url, "active": store.activeProfileID == profile, "pinned": tab.isPinned]
      return [try await create(props, request: request, profile: profile, manager: manager, duplicate: true)]
    case "tabs.createSplit":
      let ids = try identifiers(arg(0))
      guard ids.count == 2, Set(ids).count == 2 else { throw Failure("Choose exactly two different tabs for split view.") }
      try await synchronizeCatalog(profile)
      try await authorize(request, profile: profile, manager: manager)
      let pair = try ids.map { try record(profile, nativeID: $0) }
      let ordered = tabs(profile)
      guard let first = ordered.firstIndex(where: { $0.id == pair[0].id }),
        let second = ordered.firstIndex(where: { $0.id == pair[1].id }), abs(first - second) == 1 else {
        throw Failure("Split tabs must be adjacent.")
      }
      guard pair[0].spaceID == pair[1].spaceID, pair[0].isPinned == pair[1].isPinned else {
        throw Failure("Split tabs must be in the same Space and have matching pinned states.")
      }
      guard pair.allSatisfy({ store.split(for: $0.id) == nil }) else { throw Failure("A tab is already in split view.") }
      guard nextSplitIdentity < Int32.max else { throw Failure("Split view identity limit reached.") }
      let group = SplitGroup(spaceID: pair[0].spaceID, leftTabID: pair[0].id, rightTabID: pair[1].id)
      try store.commit { $0.splits.append(group) }
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
      try targetWindow(props["windowId"])
      let position = try integer(props["index"], minimum: -1)
      guard Set(ids).count == ids.count else { throw Failure("Duplicate tab IDs are not allowed.") }
      let moving = try ids.map { try record(profile, nativeID: $0).id }
      try await authorize(request, profile: profile, manager: manager)
      var ordered = tabs(profile).map(\.id).filter { !moving.contains($0) }
      guard moving.allSatisfy({ id in tabs(profile).contains { $0.id == id } }) else { throw Failure("Unknown profile tab.") }
      ordered.insert(contentsOf: moving, at: position == -1 ? ordered.count : min(position, ordered.count))
      let values = Dictionary(uniqueKeysWithValues: tabs(profile).map { ($0.id, $0) })
      var cursor = 0
      try store.commit { state in
        state.tabs = state.tabs.map { tab in
          guard values[tab.id] != nil else { return tab }
          defer { cursor += 1 }; return values[ordered[cursor]]!
        }
      }
      didChange()
      var result: [[String: Any]] = []
      for id in moving { result.append(try await tabData(id, profile: profile)) }
      if arg(0) is [Any] { return [result] }
      return [result.first ?? [:]]
    case "tabs.highlight":
      let props = try properties(arg(0), allowed: ["tabs", "windowId"]); try targetWindow(props["windowId"])
      let indices = try identifiers(props["tabs"])
      guard indices.count == 1, let index = indices.first, tabs(profile).indices.contains(index) else {
        throw Failure("Zacro selects one active tab at a time.")
      }
      let tab = tabs(profile)[index]
      try canActivate(profile); try await authorize(request, profile: profile, manager: manager); try canActivate(profile)
      activateTab(tab.id); didChange()
      return [try await windowData(profile, info: ["populate": true])]
    case "tabs.discard":
      try await synchronizeCatalog(profile)
      guard let discardTab else { throw Failure("Native tab suspension is unavailable.") }
      let explicit = arg(0) != nil && !(arg(0) is NSNull)
      let candidates = explicit ? [try defaultRecord(profile, id: arg(0))]
        : tabs(profile).filter { $0.id != store.state.activeTabID && !isDiscarded($0.id) }.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
      for tab in candidates {
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
      let tab = try defaultRecord(profile, id: factorOnly ? nil : arg(0))
      guard !isDiscarded(tab.id), let page = engine.pages[tab.id], let browser = page.browser else { throw Failure("The target tab is not currently loaded.") }
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
      if hasID { try targetWindow(arg(0)) }
      let info = try properties(arg(hasID ? 1 : 0), allowed: ["populate", "windowTypes"])
      if let types = info["windowTypes"] as? [String], !types.contains("normal") { return request.method == "windows.getAll" ? [[]] : [] }
      let value = try await windowData(profile, info: info)
      return request.method == "windows.getAll" ? [[value]] : [value]
    case "windows.update":
      try targetWindow(arg(0)); try canActivate(profile)
      let props = try properties(arg(1), allowed: ["focused", "state", "left", "top", "width", "height"]); try validateWindow(props)
      try await authorize(request, profile: profile, manager: manager); try canActivate(profile)
      guard let window = engine.window else { throw Failure("Browser window is closed.") }
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
      if props["focused"] as? Bool == true { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
      else if props["focused"] as? Bool == false, isWindowFocused(profile) { NSApp.keyWindow?.resignKey() }
      didChange(); return [try await windowData(profile)]
    case "windows.remove":
      try targetWindow(arg(0)); try canActivate(profile)
      guard let closeWindow else { throw Failure("Window closure is unavailable.") }
      try await authorize(request, profile: profile, manager: manager); try canActivate(profile)
      guard await closeWindow() else { throw Failure("A page kept its unsaved changes.") }; return []
    case "windows.create": throw Failure("Creating another native browser window is not supported yet.")
    default: throw Failure("Unsupported native browser API: \(request.method)")
    }
  }

  private func create(_ props: [String: Any], request: ChromeExtensionHostRequest, profile: String,
                      manager: ChromeExtensionManager, duplicate: Bool = false) async throws -> [String: Any] {
    var props = try properties(props, allowed: ["url", "active", "selected", "index", "pinned", "windowId", "openerTabId"])
    if props["active"] == nil, let selected = props["selected"] { props["active"] = selected }
    try validateTabProperties(props); try targetWindow(props["windowId"])
    let active = props["active"] as? Bool ?? true
    if active { try canActivate(profile) }
    if let opener = props["openerTabId"] { try await synchronizeCatalog(profile); _ = try record(profile, nativeID: integer(opener)) }
    let address = duplicate && props["url"] as? String == "about:blank" ? "about:blank"
      : try navigationURL(props["url"], extensionID: request.extensionID) ?? "about:blank"
    try await authorize(request, profile: profile, manager: manager)
    if active { try canActivate(profile) }
    let openerID = try props["openerTabId"].map { try record(profile, nativeID: integer($0)).id }
    guard store.state.tabs.count < 1_000 else { throw Failure("Close some tabs before opening more.") }
    guard let space = store.state.spaces.first(where: { $0.id == store.state.activeSpaceID && $0.profileID == profile })
      ?? store.state.spaces.first(where: { $0.profileID == profile }) else { throw Failure("Profile has no Space.") }
    var tab = BrowserTab(spaceID: space.id, url: address, title: URL(string: address)?.host ?? "New tab",
      isPinned: props["pinned"] as? Bool ?? false)
    tab.openerTabID = openerID
    tab.navigation = [NavigationEntry(url: address)]; tab.navigationIndex = 0
    if tab.isPinned { tab.savedURL = address; tab.savedTitle = tab.title }
    try store.commit { state in
      if let index = props["index"] as? Int, index >= 0 {
        let own = state.tabs.indices.filter { i in !state.tabs[i].isClosed && store.profileID(for: state.tabs[i]) == profile }
        state.tabs.insert(tab, at: index < own.count ? own[index] : (own.last.map { $0 + 1 } ?? state.tabs.count))
      } else { state.tabs.append(tab) }
    }
    try await synchronizeCatalog(profile)
    try await authorize(request, profile: profile, manager: manager)
    if active { try canActivate(profile) }
    guard store.tab(tab.id)?.isClosed == false else { throw Failure("The tab closed before the operation completed.") }
    if address != "about:blank" { navigateTab(tab, address) }
    _ = try await requireDocument(tab)
    try await authorize(request, profile: profile, manager: manager)
    if active { try canActivate(profile) }
    if active { activateTab(tab.id) }
    didChange()
    return try await tabData(tab.id, profile: profile)
  }

  private func requireDocument(_ tab: BrowserTab) async throws -> ChromiumPage {
    let page: ChromiumPage
    if let materializePage { page = try await materializePage(tab) }
    else if let existing = engine.pages[tab.id] { page = existing }
    else { throw Failure("The tab could not be loaded.") }
    guard engine.pages[tab.id] === page, let current = store.tab(tab.id), !current.isClosed,
      store.profileID(for: current) == page.profileID else { throw Failure("The tab closed before the operation completed.") }
    return page
  }

  private func windowData(_ profile: String, info: [String: Any] = [:]) async throws -> [String: Any] {
    try checkProfile(profile)
    guard let window = engine.window else { throw Failure("Browser window is closed.") }
    let bounds = window.frame, top = (NSScreen.screens.first?.frame.maxY ?? 0) - bounds.maxY
    var data: [String: Any] = ["id": windowID, "type": "normal", "focused": isWindowFocused(profile), "incognito": false,
      "alwaysOnTop": window.level.rawValue > NSWindow.Level.normal.rawValue,
      "state": window.styleMask.contains(.fullScreen) ? "fullscreen" : window.isMiniaturized ? "minimized" : window.isZoomed ? "maximized" : "normal",
      "left": Int(bounds.minX.rounded()), "top": Int(top.rounded()), "width": Int(bounds.width.rounded()), "height": Int(bounds.height.rounded())]
    if info["populate"] as? Bool == true { data["tabs"] = try await allTabData(profile) }
    return data
  }

  private func publishChanges() async {
    let revision = epoch
    var next: [String: Snapshot] = [:]
    for profile in store.state.profiles.filter({ !$0.isPrivate }).map(\.id) {
      let manager = ChromeExtensionManager(engine: engine, profileID: profile)
      do { try await synchronizeCatalog(profile) }
      catch {
        for (id, previous) in snapshots where previous.profile == profile { next[id] = previous }
        continue
      }
      if !publishedWindows.contains(profile), let window = try? await windowData(profile) {
        do {
          try await manager.publishBrowserEvent("windows.onCreated", arguments: [window])
          guard revision == epoch, !Task.isCancelled else { return }
          publishedWindows.insert(profile)
          windowSnapshots[profile] = window
        } catch { }
      }
      for tab in tabs(profile) {
        guard revision == epoch, !Task.isCancelled, enabled, !stopped else { return }
        do {
          let value = try await tabData(tab.id, profile: profile, synchronize: false)
          guard revision == epoch, !Task.isCancelled else { return }
          let old = snapshots[tab.id]
          next[tab.id] = Snapshot(profile: profile, value: value)
          if let old, !equal(old.value["id"], value["id"]) {
            try await manager.publishBrowserEvent("tabs.onRemoved", arguments: [old.value["id"]!, ["windowId": windowID, "isWindowClosing": engine.isWindowClosing]])
          }
          if old == nil || !equal(old?.value["id"], value["id"]) {
            try await manager.publishBrowserEvent("tabs.onCreated", arguments: [value])
          } else if let old {
            var changes: [String: Any] = [:]
            for key in ["url", "title", "pinned", "audible", "status", "favIconUrl", "mutedInfo", "discarded", "autoDiscardable", "splitViewId"] {
              if let item = value[key], !equal(old.value[key], item) { changes[key] = item }
            }
            if !changes.isEmpty { try await manager.publishBrowserEvent("tabs.onUpdated", arguments: [value["id"]!, changes, value]) }
            if !equal(old.value["index"], value["index"]) {
              try await manager.publishBrowserEvent("tabs.onMoved", arguments: [value["id"]!, ["windowId": windowID, "fromIndex": old.value["index"]!, "toIndex": value["index"]!]])
            }
          }
          if value["active"] as? Bool == true,
            old == nil || old?.value["active"] as? Bool != true || !equal(old?.value["id"], value["id"]) {
            try await manager.publishBrowserEvent("tabs.onActivated", arguments: [["tabId": value["id"]!, "windowId": windowID]])
          }
        } catch {
          // A failed registration must not pretend the existing tab was removed.
          if let old = snapshots[tab.id] { next[tab.id] = old }
        }
      }
      guard revision == epoch, !Task.isCancelled else { return }
      let highlighted = tabs(profile).filter { $0.id == store.state.activeTabID }
        .compactMap { next[$0.id]?.value["id"] as? Int }
      if highlightSnapshots[profile] != highlighted {
        do {
          try await manager.publishBrowserEvent("tabs.onHighlighted", arguments: [["windowId": windowID, "tabIds": highlighted]])
          guard revision == epoch, !Task.isCancelled else { return }
          highlightSnapshots[profile] = highlighted
        } catch { }
      }
      // Match Chromium's committed-bounds event, not every native drag frame.
      if engine.window?.contentView?.inLiveResize != true,
        let window = try? await windowData(profile), let previous = windowSnapshots[profile],
        ["left", "top", "width", "height"].contains(where: { !equal(previous[$0], window[$0]) }) {
        do {
          try await manager.publishBrowserEvent("windows.onBoundsChanged", arguments: [window])
          guard revision == epoch, !Task.isCancelled else { return }
          windowSnapshots[profile] = window
        } catch { }
      }
      let focused = isWindowFocused(profile) ? windowID : -1
      if focusSnapshots[profile] != focused {
        do {
          try await manager.publishBrowserEvent("windows.onFocusChanged", arguments: [focused])
          guard revision == epoch, !Task.isCancelled else { return }
          focusSnapshots[profile] = focused
        } catch { }
      }
    }
    guard revision == epoch, !Task.isCancelled else { return }
    for (id, previous) in snapshots where next[id] == nil {
      if store.state.profiles.contains(where: { $0.id == previous.profile && !$0.isPrivate }) {
        let manager = ChromeExtensionManager(engine: engine, profileID: previous.profile)
        try? await manager.publishBrowserEvent("tabs.onRemoved", arguments: [previous.value["id"]!, ["windowId": windowID, "isWindowClosing": engine.isWindowClosing]])
      }
      identities.removeValue(forKey: id)
    }
    if revision == epoch, !Task.isCancelled { snapshots = next }
  }

  private func isWindowFocused(_ profile: String) -> Bool {
    guard store.activeProfileID == profile, NSApp.isActive, let main = engine.window else { return false }
    var candidate = NSApp.keyWindow
    while let window = candidate { if window === main { return true }; candidate = window.parent }
    return false
  }
  private func canActivate(_ profile: String) throws {
    guard store.activeProfileID == profile else { throw Failure("A hidden profile cannot take focus.") }
  }
  private func targetWindow(_ value: Any?) throws {
    guard let value, !(value is NSNull) else { return }
    let id = try integer(value, minimum: -2)
    guard id == windowID || id == -2 else { throw Failure("Unknown profile window.") }
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
    if let value = props["focused"] {
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure("Invalid window focus.") }
    }
    if let value = props["state"] {
      guard let value = value as? String, ["normal", "minimized", "maximized", "fullscreen"].contains(value) else { throw Failure("Invalid window state.") }
    }
  }
  private func navigationURL(_ value: Any?, extensionID: String) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    guard let text = value as? String, !text.isEmpty, !text.contains("\\") else { throw Failure("Unsupported navigation URL.") }
    if text == "about:blank" { return text }
    if let url = BrowserAddress.webURL(text) { return url.absoluteString }
    guard let base = URL(string: "chrome-extension://\(extensionID)/"),
      let absolute = URL(string: text, relativeTo: base)?.absoluteURL,
      let url = BrowserAddress.extensionURL(absolute.absoluteString), url.host == extensionID else { throw Failure("Unsupported navigation URL.") }
    return url.absoluteString
  }
  private func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs else { return rhs == nil }; guard let rhs else { return false }
    return (lhs as? NSObject)?.isEqual(rhs) == true
  }
}
