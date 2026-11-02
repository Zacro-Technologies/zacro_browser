import Combine
import Foundation
import ZacroChromium
import ZacroCore

/// Chromium owns the hierarchy; Core is a bounded Library cache plus an import
/// queue for pre-native/portable bookmarks. Shared with every browser window.
@MainActor final class NativeBookmarkSync {
  var enabled = false { didSet { if enabled { refreshProfiles() } } }
  var onStatus: ((String, String?) -> Void)?
  var ensureObservation: ((String) async throws -> Void)?
  private let engine: ChromiumEngine
  private let store: BrowserStore
  private var observation: AnyCancellable?
  private var started = false, closed = false
  private var initialized = Set<String>()
  private var observed = Set<String>()
  private var epochs: [String: Int] = [:]
  private var tails: [String: Task<Void, Error>] = [:]
  private var operations: [UUID: (profile: String, task: Task<Void, Error>)] = [:]
  private var queued = Set<String>(), again = Set<String>()
  private var messages: [String: String] = [:]
  init(engine: ChromiumEngine, store: BrowserStore) { self.engine = engine; self.store = store }

  func start() {
    guard !started, !closed else { return }; started = true
    observation = store.$state.map(\.bookmarks).removeDuplicates().dropFirst().sink { [weak self] records in
      guard let self, self.enabled else { return }
      for profile in self.activeProfiles() where records.contains(where: { $0.profileID == profile && $0.nativeIdentity == nil }) {
        self.requestRefresh(profile)
      }
    }
    refreshProfiles()
  }
  func status(profileID: String) -> String? { messages[profileID] }
  func observationReady(profileID: String) {
    guard !closed else { return }
    observed.insert(profileID)
    if enabled { requestRefresh(profileID) }
  }
  func refreshProfiles() {
    guard started, enabled, !closed, !engine.isTerminating else { return }
    let publicIDs = Set(store.state.profiles.filter { !$0.isPrivate }.map(\.id))
    for id in initialized.subtracting(publicIDs) { removeProfile(id) }
    for id in activeProfiles().intersection(observed) where !initialized.contains(id) { requestRefresh(id) }
  }
  func nativeEvent(profileID: String, event: ChromeExtensionEvent) {
    if case .bookmarksChanged = event, observed.contains(profileID), initialized.contains(profileID) || activeProfiles().contains(profileID) {
      requestRefresh(profileID)
    }
  }
  func removeProfile(_ id: String) {
    epochs[id, default: 0] += 1
    for operation in operations.values where operation.profile == id { operation.task.cancel() }
    tails.removeValue(forKey: id); queued.remove(id); again.remove(id); initialized.remove(id); observed.remove(id); messages.removeValue(forKey: id)
  }
  func close() async {
    closed = true; observation?.cancel(); observation = nil
    let pending = operations.values.map(\.task)
    for task in pending { task.cancel() }
    for task in pending { _ = try? await task.value }
    operations.removeAll(); tails.removeAll(); queued.removeAll(); again.removeAll(); observed.removeAll(); onStatus = nil; ensureObservation = nil
  }
  func refresh(profileID: String) async throws {
    let task = enqueue(profileID) { try await self.synchronize(profileID) }
    try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  func toggle(profileID: String, url: String, title: String) async throws {
    guard let address = BrowserAddress.webURL(url), store.state.profiles.contains(where: { $0.id == profileID }) else {
      throw ShortcutError("Choose a web page in an available profile.")
    }
    if store.state.profiles.first(where: { $0.id == profileID })?.isPrivate == true {
      store.toggleBookmark(url: address.absoluteString, title: title, profileID: profileID); return
    }
    if !enabled { try localToggle(profileID, address.absoluteString, title); return }
    let task = enqueue(profileID) {
      try await self.synchronize(profileID)
      if let existing = self.store.state.bookmarks.first(where: { $0.profileID == profileID && $0.url == address.absoluteString }) {
        try await self.removeNative(existing)
      } else {
        try self.localToggle(profileID, address.absoluteString, title)
      }
      try await self.synchronize(profileID)
    }
    try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  func remove(profileID: String, bookmarkID: String) async throws {
    guard let bookmark = store.state.bookmarks.first(where: { $0.id == bookmarkID && $0.profileID == profileID }) else { return }
    if store.state.profiles.first(where: { $0.id == profileID })?.isPrivate == true {
      store.removeBookmark(id: bookmarkID); return
    }
    if !enabled { try store.commit { $0.bookmarks.removeAll { $0.id == bookmarkID && $0.profileID == profileID } }; return }
    let task = enqueue(profileID) {
      // Migrate before deleting an unbound legacy entry so an already accepted
      // but unacknowledged native import cannot reappear after a restart.
      try await self.synchronize(profileID)
      if let current = self.store.state.bookmarks.first(where: { $0.id == bookmarkID && $0.profileID == profileID }) {
        try await self.removeNative(current)
      } else if let identity = bookmark.nativeIdentity {
        // The native snapshot may already reflect an extension deletion.
        guard !self.store.state.bookmarks.contains(where: { $0.profileID == profileID && $0.nativeIdentity?.key == identity.key }) else { throw CancellationError() }
      }
      try await self.synchronize(profileID)
    }
    try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  private func localToggle(_ profileID: String, _ url: String, _ title: String) throws {
    guard store.state.bookmarks.count < 20_000 || store.state.bookmarks.contains(where: { $0.profileID == profileID && $0.url == url }) else {
      throw ShortcutError("Remove a bookmark before adding more to the Library.")
    }
    try store.commit { state in
      if let index = state.bookmarks.firstIndex(where: { $0.profileID == profileID && $0.url == url }) { state.bookmarks.remove(at: index) }
      else {
        state.bookmarks.insert(.init(profileID: profileID, url: url, title: String(title.prefix(500))), at: 0)
      }
    }
  }
  private func removeNative(_ bookmark: Bookmark) async throws {
    guard let identity = bookmark.nativeIdentity, identity.editable else { throw ShortcutError("This bookmark is managed and cannot be removed.") }
    try await ChromeExtensionManager(engine: engine, profileID: bookmark.profileID)
      .removeBookmark(nodeID: identity.nodeID, uuid: identity.uuid, storage: identity.storage)
  }
  private func activeProfiles() -> Set<String> {
    let open = Set(engine.contexts.values.filter { $0.isOpen && !$0.isClosing }.map(\.id))
    let publicIDs = Set(store.state.profiles.filter { !$0.isPrivate }.map(\.id))
    return Set((store.state.windowSessions ?? []).filter { $0.isOpen && open.contains($0.id) }
      .compactMap { window in store.state.spaces.first { $0.id == window.activeSpaceID }?.profileID }).intersection(publicIDs)
  }
  private func check(_ profileID: String, epoch: Int? = nil) throws {
    guard !closed, !Task.isCancelled, enabled, !engine.isTerminating,
      epoch == nil || epochs[profileID, default: 0] == epoch,
      store.state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }) else { throw CancellationError() }
  }
  private func enqueue(_ profileID: String, action: @escaping () async throws -> Void) -> Task<Void, Error> {
    let previous = tails[profileID], token = UUID(), epoch = epochs[profileID, default: 0]
    let task = Task { @MainActor [weak self] in
      _ = try? await previous?.value
      guard let self else { throw CancellationError() }
      defer { self.operations.removeValue(forKey: token) }
      try self.check(profileID, epoch: epoch)
      do { try await action(); try self.check(profileID, epoch: epoch) }
      catch {
        if !(error is CancellationError), !self.closed, self.epochs[profileID, default: 0] == epoch {
          self.setStatus(profileID, error.localizedDescription)
        }
        throw error
      }
    }
    operations[token] = (profileID, task); tails[profileID] = task
    return task
  }
  private func requestRefresh(_ profileID: String) {
    guard started, enabled, !closed, observed.contains(profileID) else { return }
    guard queued.insert(profileID).inserted else { again.insert(profileID); return }
    let epoch = epochs[profileID, default: 0]
    let task = enqueue(profileID) {
      try await Task.sleep(for: .milliseconds(100))
      try await self.synchronize(profileID)
    }
    Task { [weak self] in
      _ = try? await task.value
      guard let self, self.epochs[profileID, default: 0] == epoch else { return }
      self.queued.remove(profileID)
      if self.again.remove(profileID) != nil { self.requestRefresh(profileID) }
    }
  }
  private func setStatus(_ profileID: String, _ message: String?) {
    guard messages[profileID] != message else { return }
    messages[profileID] = message; onStatus?(profileID, message)
  }
  private func synchronize(_ profileID: String) async throws {
    try check(profileID)
    if !observed.contains(profileID) { try await ensureObservation?(profileID); try check(profileID) }
    guard observed.contains(profileID) else { throw ShortcutError("The bookmark observer is not ready. Try again after this profile finishes opening.") }
    let manager = ChromeExtensionManager(engine: engine, profileID: profileID)
    let legacy = store.state.bookmarks.filter { $0.profileID == profileID && $0.nativeIdentity == nil }
    var imported: [ChromeBookmarkImportResult] = []
    for start in stride(from: 0, to: legacy.count, by: 512) {
      let batch = Array(legacy[start..<min(legacy.count, start + 512)])
      let results = try await manager.importBookmarks(batch.map {
        .init(logicalID: $0.id, url: $0.url, title: $0.title, dateAdded: max(0, $0.createdAt.timeIntervalSince1970 * 1000))
      })
      try check(profileID)
      guard results.count == batch.count, Set(results.map(\.logicalID)) == Set(batch.map(\.id)),
        results.allSatisfy({ UUID(uuidString: $0.uuid) != nil && ($0.removed || $0.node != nil) }) else {
        throw ShortcutError("The native bookmark import acknowledgement is invalid.")
      }
      imported += results
    }
    var snapshot: (records: [NativeBookmarkRecord], limited: Bool)?
    var snapshotError: Error?
    for _ in 0..<3 {
      do { snapshot = try await readSnapshot(manager, profileID); break }
      catch { snapshotError = error; try check(profileID) }
    }
    guard let snapshot else { throw snapshotError ?? ShortcutError("The native bookmarks changed before they could be read.") }
    try check(profileID)
    let count = try store.reconcileNativeBookmarks(profileID: profileID, records: snapshot.records,
      resolvedLegacyIDs: Set(imported.map(\.logicalID)), acknowledgements: imported.map {
        .init(profileID: profileID, logicalID: $0.logicalID, uuid: $0.uuid)
      })
    // The migration commit also sanitizes recovery files before acknowledging.
    let acknowledgements = store.state.bookmarkImportAcknowledgements.filter { $0.profileID == profileID }
    for start in stride(from: 0, to: acknowledgements.count, by: 512) {
      let batch = Array(acknowledgements[start..<min(acknowledgements.count, start + 512)])
      try await manager.acknowledgeBookmarkBindings(batch.map { .init(logicalID: $0.logicalID, uuid: $0.uuid) })
      try check(profileID)
      try store.acknowledgeNativeBookmarkImports(batch)
    }
    initialized.insert(profileID)
    setStatus(profileID, snapshot.limited || count < snapshot.records.count
      ? "The Library shows up to 20,000 bookmarks. All bookmarks remain available to Chrome extensions." : nil)
  }
  private func readSnapshot(_ manager: ChromeExtensionManager, _ profileID: String) async throws -> (records: [NativeBookmarkRecord], limited: Bool) {
    var offset = 0, revision: String?, total: Int?, records: [NativeBookmarkRecord] = []
    repeat {
      let page = try await manager.bookmarkPage(offset: offset, revision: revision)
      try check(profileID)
      guard !page.revision.isEmpty, page.revision.count <= 128, page.total >= 0,
        page.nodes.count <= 512, page.nextOffset == offset + page.nodes.count,
        page.nextOffset <= page.total, total == nil || total == page.total,
        revision == nil || revision == page.revision,
        page.complete == (page.nextOffset == page.total), page.complete || page.nextOffset > offset else {
        throw ShortcutError("The native bookmark snapshot is incomplete or changed while reading.")
      }
      revision = page.revision; total = page.total; offset = page.nextOffset
      var pageLimited = false
      for node in page.nodes where !node.folder {
        guard let value = node.url, BrowserAddress.webURL(value) != nil else { continue }
        if records.count == 20_000 { pageLimited = true; continue }
        guard node.dateAdded.isFinite else { throw ShortcutError("The native bookmark date is invalid.") }
        records.append(.init(identity: .init(nodeID: node.nodeID, uuid: node.uuid, storage: node.storage, editable: node.editable),
          url: value, title: node.title, createdAt: Date(timeIntervalSince1970: node.dateAdded / 1000), logicalID: node.logicalID))
      }
      if page.complete { return (records, pageLimited) }
      if records.count == 20_000 || offset >= 200_000 { return (records, true) }
    } while true
  }
}
