import Foundation
import ZacroChromium

/// Owns document link adapters across window transfers and Peek promotion.
/// An old adapter is revoked synchronously; its native cleanup drains before
/// another adapter can arm the same retained ChromiumPage instance.
@MainActor
final class NativePeekLinkCoordinator {
  @MainActor final class DiscardLease {
    fileprivate let id = UUID()
    fileprivate weak var page: ChromiumPage?
    fileprivate let pageID: String
    fileprivate let profileID: String
    fileprivate let ownerWindowID: String
    fileprivate init(page: ChromiumPage, ownerWindowID: String) {
      self.page = page; pageID = page.id; profileID = page.profileID
      self.ownerWindowID = ownerWindowID
    }
  }
  private struct Binding: Equatable {
    let pageID: String
    let profileID: String
    let ownerWindowID: String
  }

  private final class Entry {
    let id: UUID
    weak var page: ChromiumPage?
    let binding: Binding
    let bridge: NativePeekLinkBridge
    let predecessor: Task<Void, Never>?
    var startTask: Task<Void, Error>?

    init(id: UUID, page: ChromiumPage, binding: Binding, bridge: NativePeekLinkBridge,
      predecessor: Task<Void, Never>?) {
      self.id = id; self.page = page; self.binding = binding; self.bridge = bridge
      self.predecessor = predecessor
    }
  }

  private weak var application: ApplicationCoordinator?
  private var entries: [ObjectIdentifier: Entry] = [:]
  private var retirements: [UUID: Task<Void, Never>] = [:]
  private var retirementByPage: [ObjectIdentifier: (id: UUID, task: Task<Void, Never>)] = [:]
  private var discardLeases: [ObjectIdentifier: DiscardLease] = [:]
  private var stopped = false

  init(application: ApplicationCoordinator) { self.application = application }

  /// Called only with an existing engine page. Looking up its Core document
  /// excludes extension brokers, maintenance pages, and retired model records.
  func connect(_ page: ChromiumPage) {
    let key = ObjectIdentifier(page)
    guard let binding = binding(for: page) else { forget(page); return }
    if let current = entries[key] {
      if current.page === page, current.binding == binding {
        current.bridge.refresh()
        return
      }
      retire(key: key, entry: current)
    }
    let predecessor = retirementByPage[key]?.task
    let token = UUID()
    let bridge = NativePeekLinkBridge(page: page, usesOwnedSession: { [weak application] in
      guard let application else { throw CancellationError() }
      do { return try await application.engine.nativeCapabilities().browserProtocol }
      catch let error as CefDevToolsError where error.isUnsupportedMethod { return false }
    }, snapshot: { [weak self, weak page] in
      guard let self, let page else { return nil }
      return self.snapshot(page: page, key: key, token: token, binding: binding)
    }, didRequest: { [weak self, weak page] url, point in
      guard let self, let page,
        let snapshot = self.snapshot(page: page, key: key, token: token, binding: binding),
        snapshot.visible, page.url?.absoluteString == snapshot.sourceURL else { return }
      page.onPeek?(url, point)
    })
    let entry = Entry(id: token, page: page, binding: binding, bridge: bridge, predecessor: predecessor)
    entries[key] = entry
    entry.startTask = Task { @MainActor [weak self, weak entry] in
      do {
        await predecessor?.value
        guard let self, let entry, let page = entry.page,
          !Task.isCancelled, self.entries[key] === entry,
          self.binding(for: page) == binding else { throw CancellationError() }
        try await entry.bridge.start()
        guard !Task.isCancelled, self.entries[key] === entry,
          self.binding(for: page) == binding else { throw CancellationError() }
      } catch {
        if let self, let entry, self.entries[key] === entry { self.retire(key: key, entry: entry) }
        if !(error is CancellationError) {
          fputs("Zacro could not prepare Peek links: \(error.localizedDescription)\n", stderr)
        }
        throw error
      }
    }
  }

  /// Navigation waits for the exact adapter registered for this page/owner.
  /// A concurrent transfer or retirement cancels that preparation, never arms
  /// its replacement on behalf of the original caller.
  func prepare(_ page: ChromiumPage) async throws {
    connect(page)
    let key = ObjectIdentifier(page)
    guard let entry = entries[key], entry.page === page, let task = entry.startTask else {
      throw CancellationError()
    }
    try await task.value
    guard !Task.isCancelled, entries[key] === entry, entry.page === page,
      binding(for: page) == entry.binding else { throw CancellationError() }
    entry.bridge.refresh()
  }

  /// The initial navigation needs ordered script submission, not a renderer
  /// response from a document that does not exist yet. Retired adapter cleanup
  /// still precedes every command from this exact replacement entry.
  func prepareBootstrap(_ page: ChromiumPage) async throws {
    connect(page)
    let key = ObjectIdentifier(page)
    guard let entry = entries[key], entry.page === page else { throw CancellationError() }
    await entry.predecessor?.value
    guard !Task.isCancelled, entries[key] === entry, entry.page === page,
      binding(for: page) == entry.binding else { throw CancellationError() }
    try await entry.bridge.prepareBootstrap()
    guard !Task.isCancelled, entries[key] === entry, entry.page === page,
      binding(for: page) == entry.binding else { throw CancellationError() }
  }

  func refresh() {
    guard !stopped else { return }
    for (key, entry) in Array(entries) {
      guard entries[key] === entry else { continue }
      guard let page = entry.page, let current = binding(for: page) else {
        retire(key: key, entry: entry)
        continue
      }
      if current != entry.binding {
        // Promotion and transfer retain the object while changing authority.
        // connect revokes this entry before waiting for its cleanup successor.
        connect(page)
      } else { entry.bridge.refresh() }
    }
    // A veto or completed profile operation can make a previously revoked
    // live document eligible again without another navigation/wire callback.
    // Reconcile only already-existing native pages; this never calls a factory.
    if let application {
      for page in Array(application.engine.pages.values)
        where entries[ObjectIdentifier(page)] == nil && binding(for: page) != nil {
        connect(page)
      }
    }
  }

  func isArmed(_ page: ChromiumPage) -> Bool {
    guard let entry = entries[ObjectIdentifier(page)], entry.page === page,
      binding(for: page) == entry.binding else { return false }
    return entry.bridge.isArmed
  }

  /// Our own pagehide listener is an unload-time handler to Chromium. Remove
  /// only this adapter before evaluating real site unload/discard safety, and
  /// hold off layout-driven reconnection until the attempt has settled.
  func suspendForDiscard(_ page: ChromiumPage) async throws -> DiscardLease {
    let key = ObjectIdentifier(page)
    guard discardLeases[key] == nil, let original = binding(for: page) else { throw CancellationError() }
    let lease = DiscardLease(page: page, ownerWindowID: original.ownerWindowID)
    discardLeases[key] = lease
    if let entry = entries[key] { retire(key: key, entry: entry) }
    await retirementByPage[key]?.task.value
    guard !Task.isCancelled, discardLeases[key] === lease,
      binding(for: page, ignoringDiscardLease: true) == original else {
      await resumeAfterDiscard(lease)
      throw CancellationError()
    }
    return lease
  }

  /// A refused attempt restores the same live owner's adapter. A successfully
  /// dormant document stays disconnected until ordinary navigation wakes it.
  func resumeAfterDiscard(_ lease: DiscardLease) async {
    guard let page = lease.page else {
      discardLeases = discardLeases.filter { $0.value !== lease }
      return
    }
    let key = ObjectIdentifier(page)
    guard discardLeases[key] === lease else { return }
    discardLeases.removeValue(forKey: key)
    guard let current = binding(for: page) else { return }
    guard current.pageID == lease.pageID, current.profileID == lease.profileID,
      current.ownerWindowID == lease.ownerWindowID else {
      // Transfer/promotion may have attempted its normal connection while this
      // lease blocked it. Reconcile independently under the new current owner;
      // the old discard never waits for or inherits that owner's authority.
      Task { @MainActor [weak self] in self?.refresh() }
      return
    }
    connect(page)
    guard let entry = entries[key], entry.page === page else { return }
    _ = await entry.startTask?.result
    if entries[key] === entry, binding(for: page) == entry.binding { entry.bridge.refresh() }
  }

  func forget(_ page: ChromiumPage) {
    let key = ObjectIdentifier(page)
    guard let entry = entries[key], entry.page === page else { return }
    retire(key: key, entry: entry)
  }

  func close() async {
    stopped = true
    discardLeases.removeAll()
    for (key, entry) in Array(entries) { retire(key: key, entry: entry) }
    while !retirements.isEmpty {
      for task in Array(retirements.values) { await task.value }
    }
  }

  private func binding(for page: ChromiumPage, ignoringDiscardLease: Bool = false) -> Binding? {
    guard !stopped, let application, !application.engine.isTerminating,
      ignoringDiscardLease || discardLeases[ObjectIdentifier(page)] == nil,
      application.engine.pages[page.id] === page,
      application.deletingProfileID != page.profileID,
      let ownerID = page.ownerWindowID, let owner = application.windows[ownerID],
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      !owner.isDiscarded(page.id),
      let document = application.store.document(id: page.id), !document.isClosed,
      document.windowID == ownerID, application.store.profileID(for: document) == page.profileID,
      let profile = application.store.state.profiles.first(where: { $0.id == page.profileID }),
      profile.isPrivate == page.isPrivate else { return nil }
    return Binding(pageID: page.id, profileID: page.profileID, ownerWindowID: ownerID)
  }

  private func snapshot(page: ChromiumPage, key: ObjectIdentifier, token: UUID,
                        binding expected: Binding) -> NativePeekLinkSnapshot? {
    guard let entry = entries[key], entry.id == token, entry.page === page,
      entry.binding == expected, binding(for: page) == expected,
      let owner = application?.windows[expected.ownerWindowID],
      let value = owner.peekLinkSnapshot(page), value.pageID == expected.pageID,
      value.profileID == expected.profileID, value.ownerWindowID == expected.ownerWindowID else { return nil }
    return value
  }

  private func retire(key: ObjectIdentifier, entry: Entry) {
    guard entries[key] === entry else { return }
    entries.removeValue(forKey: key)
    // stop revokes binding/context authority before yielding; cancellation of
    // our waiter alone would not cancel the bridge's actual native operations.
    let cleanup = entry.bridge.stop()
    entry.startTask?.cancel()
    let predecessor = retirementByPage[key]?.task
    let retirementID = UUID()
    let task = Task { @MainActor [weak self] in
      await predecessor?.value
      await cleanup.value
      self?.retirements.removeValue(forKey: retirementID)
      if self?.retirementByPage[key]?.id == retirementID {
        self?.retirementByPage.removeValue(forKey: key)
      }
    }
    retirements[retirementID] = task
    retirementByPage[key] = (retirementID, task)
  }
}
