import Foundation
import ZacroCore
import ZacroServices
import ZacroChromium

/// Connects the reviewed cloud library to Chromium's real registry and storage
/// backend. No extension script is injected, and private profiles never enter it.
@MainActor
final class NativeExtensionSync {
  private final class Profile {
    let manager: ChromeExtensionManager
    var observing = false
    var pendingLifecycle = 0
    var lifecycleRetries: [String: (token: UUID, kind: String)] = [:]
    var nativeInstallations: [String:String] = [:]
    var records: [String: ChromeExtension] = [:]
    var portable: [String: NativePortableExtension] = [:]
    var baseline = false
    var nativeRevision: [String: Int] = [:]
    var seededThrough: [String: Int] = [:]
    var processedThrough: [String: Int] = [:]
    var pending: [ServiceJSON] = []
    var errors: [String: String] = [:]
    var failedContexts: [String: ServiceJSON] = [:]
    var recoveryNeeded = Set<String>()
    var pendingNative: [String: (installation: String, changes: ServiceJSON)] = [:]
    init(_ manager: ChromeExtensionManager) { self.manager = manager }
  }
  var nativeEvent: ((String, ChromeExtensionEvent) -> Void)?
  var nativeObservationReady: ((String) -> Void)?
  private let engine: ChromiumEngine
  private let store: BrowserStore
  private let services: NativeServicesModel
  private var profiles: [String: Profile] = [:]
  private var tails: [String: Task<Void, Never>] = [:]
  private var epochs: [String: Int] = [:]
  private var pausedProfiles = Set<String>()
  private var refreshQueued = Set<String>()
  private var refreshAgain = Set<String>()
  private var cancellations: [UUID: (profile: String, cancel: () -> Void)] = [:]
  private var started = false
  private var closed = false

  init(engine: ChromiumEngine, store: BrowserStore, services: NativeServicesModel) {
    self.engine = engine; self.store = store; self.services = services
  }
  func start() {
    guard !started, !closed else { return }; started = true
    services.portableLibrary = { [weak self] id in
      guard let self else { throw CancellationError() }
      return try await self.ordered(id) { profile in
        try await self.prepare(id, profile, requireComplete:true)
        return NativePortableExtension.library(Array(profile.portable.values))
      }
    }
    services.prepareNativeSync = { [weak self] id in
      guard let self else { throw CancellationError() }
      try await self.ordered(id) { try await self.prepare(id, $0, requireComplete:true) }
    }
    services.nativeSyncStatusChanged = { [weak self] in
      guard let self else { return }
      self.refreshProfiles()
      for id in self.services.linkedSyncProfileIDs { self.requestRefresh(id) }
      if self.store.state.activeProfile?.isPrivate == false { self.requestRefresh(self.store.activeProfileID) }
    }
    services.syncLibraryEvent = { [weak self] event in self?.requestRefresh(event["profileId"].string) }
    services.syncStorageEvent = { [weak self] event in self?.requestRefresh(event["profileId"].string) }
    services.nativeSyncAction = { [weak self] action, id, extensionID in
      guard let self else { throw CancellationError() }
      try await self.ordered(id) { profile in
        if ["sync:native-keep-local", "sync:native-use-remote"].contains(action) {
          try await self.resolveRecovery(id, profile, extensionID, useLocal:action == "sync:native-keep-local")
        }
        profile.errors = profile.errors.filter { profile.pendingNative[$0.key] != nil || profile.recoveryNeeded.contains($0.key) }
        profile.failedContexts.removeAll()
        try await self.prepare(id, profile)
        for ext in Array(profile.pendingNative.keys) {
          if let pending = profile.pendingNative[ext] {
            try await self.receiveStorage(id, profile, ext, pending.installation,
              self.object(pending.changes), profile.nativeRevision[ext, default: 0], retry: true)
          }
        }
        if action == "sync:native-install" { try await self.reviewInstallation(id, profile, extensionID) }
        try await self.reconcile(id, profile)
      }
    }
    refreshProfiles()
  }
  func refreshProfiles() {
    guard started, !closed, !engine.isTerminating,
      engine.contexts.values.contains(where: { $0.isOpen && !$0.isClosing }) else { return }
    let ids = Set(store.state.profiles.filter { !$0.isPrivate }.map(\.id))
    for id in profiles.keys where !ids.contains(id) { Task { await self.removeProfile(id) } }
    var needed = services.linkedSyncProfileIDs.intersection(ids)
    let openWindows = Set(engine.contexts.values.filter { $0.isOpen && !$0.isClosing }.map(\.id))
    for window in store.state.windowSessions ?? [] where window.isOpen && openWindows.contains(window.id) {
      if let id = store.state.spaces.first(where: { $0.id == window.activeSpaceID })?.profileID, ids.contains(id) {
        needed.insert(id)
      }
    }
    for id in needed where profiles[id] == nil { requestRefresh(id) }
  }
  func ensureNativeObservation(profileID: String) async throws {
    try await ordered(profileID) { profile in
      if !profile.observing {
        do { try await self.prepare(profileID, profile) }
        catch { if !profile.observing { throw error } }
      }
      try self.check(profileID, profile)
      guard profile.observing else { throw CancellationError() }
    }
  }
  func removeProfile(_ id: String) async {
    epochs[id, default: 0] += 1
    let removalEpoch = epochs[id, default: 0]
    for item in cancellations.values where item.profile == id { item.cancel() }
    let tail = tails.removeValue(forKey: id); tail?.cancel()
    refreshQueued.remove(id); refreshAgain.remove(id)
    let profile = profiles.removeValue(forKey: id)
    await profile?.manager.close()
    if epochs[id, default: 0] == removalEpoch, profiles[id] == nil {
      services.updateNativeSync(profileID: id, pending: [], errors: [])
    }
  }
  func pauseProfile(_ id: String) async {
    pausedProfiles.insert(id)
    await removeProfile(id)
  }
  func resumeProfile(_ id: String) {
    pausedProfiles.remove(id)
    requestRefresh(id)
  }
  func close() async {
    guard !closed else { return }; closed = true
    services.portableLibrary = nil; services.prepareNativeSync = nil; services.nativeSyncStatusChanged = nil
    services.syncLibraryEvent = nil; services.syncStorageEvent = nil; services.nativeSyncAction = nil; nativeEvent = nil; nativeObservationReady = nil
    for id in Array(profiles.keys) { await removeProfile(id) }
    for task in tails.values { task.cancel() }; tails.removeAll()
  }
  private func valid(_ id: String, epoch: Int) -> Bool {
    !closed && !pausedProfiles.contains(id) && epochs[id, default: 0] == epoch && !Task.isCancelled &&
      store.state.profiles.contains { $0.id == id && !$0.isPrivate }
  }
  private func check(_ id: String, _ profile: Profile) throws {
    guard !closed, !pausedProfiles.contains(id), !Task.isCancelled, profiles[id] === profile,
      store.state.profiles.contains(where: { $0.id == id && !$0.isPrivate }) else { throw CancellationError() }
  }
  private func enqueue<T>(_ id: String, operation: @escaping (Profile) async throws -> T) -> Task<T, Error> {
    let epoch = epochs[id, default: 0], previous = tails[id], token = UUID()
    let task = Task { @MainActor [weak self] () throws -> T in
      await previous?.value
      guard let self else { throw CancellationError() }
      defer { self.cancellations.removeValue(forKey:token) }
      guard self.valid(id, epoch:epoch) else { throw CancellationError() }
      let profile = self.profiles[id] ?? Profile(ChromeExtensionManager(engine: self.engine, profileID: id))
      self.profiles[id] = profile
      do {
        let result = try await operation(profile)
        try self.check(id, profile); self.publish(id, profile); return result
      } catch {
        if self.valid(id, epoch:epoch) {
          if !(error is CancellationError) { profile.errors[""] = String(error.localizedDescription.prefix(500)) }
          self.publish(id, profile)
        }
        throw error
      }
    }
    cancellations[token] = (id, { task.cancel() })
    tails[id] = Task { _ = try? await task.value }
    return task
  }
  private func ordered<T>(_ id: String, operation: @escaping (Profile) async throws -> T) async throws -> T {
    let task = enqueue(id,operation:operation)
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  private func requestRefresh(_ id: String) {
    guard !closed, !pausedProfiles.contains(id), store.state.profiles.contains(where: { $0.id == id && !$0.isPrivate }) else { return }
    guard !refreshQueued.contains(id) else { refreshAgain.insert(id); return }
    refreshQueued.insert(id)
    let epoch = epochs[id,default:0]
    let task = enqueue(id) { profile in
      try await self.prepare(id,profile)
      try await self.reconcile(id,profile)
    }
    Task { [weak self] in
      _ = try? await task.value
      guard let self, self.epochs[id,default:0] == epoch else { return }
      self.refreshQueued.remove(id)
      if self.refreshAgain.remove(id) != nil { self.requestRefresh(id) }
    }
  }
  private func prepare(_ id: String, _ profile: Profile, requireComplete: Bool = false) async throws {
    try check(id, profile)
    if !profile.observing {
      try await profile.manager.observeChanges { [weak self, weak profile] event in
        guard let self, let profile, self.profiles[id] === profile, !self.closed else { return }
        self.nativeEvent?(id, event)
        switch event {
        case .registryChanged: self.requestRefresh(id)
        case .installationChanged(let ext, let kind):
          let token = UUID()
          if kind == "installed" || kind == "uninstalled" { profile.lifecycleRetries[ext] = (token,kind) }
          profile.pendingLifecycle += 1
          let task = self.enqueue(id) { profile in
            defer { profile.pendingLifecycle = max(0,profile.pendingLifecycle - 1); self.requestRefresh(id) }
            try await self.installationChanged(id,profile,ext,kind)
            if profile.lifecycleRetries[ext]?.token == token { profile.lifecycleRetries.removeValue(forKey:ext) }
          }
          Task { _ = try? await task.value }
        case .storageChanged(let ext, let installation, let changes, let origin):
          guard origin.isEmpty else { return } // Chromium already delivered remote/private writes locally.
          profile.nativeRevision[ext, default: 0] += 1
          let revision = profile.nativeRevision[ext, default: 0]
          let task = self.enqueue(id) { profile in
            try await self.receiveStorage(id, profile, ext, installation, changes, revision)
          }
          Task { _ = try? await task.value }
        default: break // Action/host requests are handled by the application fanout.
        }
      }
      try check(id, profile); profile.observing = true
      nativeObservationReady?(id)
    }
    guard profile.pendingLifecycle == 0 else { throw CancellationError() }
    // An uninstall/reinstall must retire its previous recovery checkpoint
    // before native values are reconciled. A failed disk write remains queued
    // here; it must never make fresh defaults look like old local deletions.
    for (ext,retry) in profile.lifecycleRetries {
      try await installationChanged(id,profile,ext,retry.kind)
      try check(id,profile)
      guard profile.pendingLifecycle == 0 else { throw CancellationError() }
      if profile.lifecycleRetries[ext]?.token == retry.token { profile.lifecycleRetries.removeValue(forKey:ext) }
    }
    try await refreshRegistry(id, profile)
    guard let sync = services.syncService else { return }
    for record in profile.records.values where record.isUserEnabled && profile.portable[record.id] != nil {
      guard try await profile.manager.hasStoragePermission(record.id) else { continue }
      try check(id, profile)
      let revision = profile.nativeRevision[record.id, default: 0]
      let snapshot = try await storageSnapshot(id, profile, record.id)
      try check(id, profile)
      guard profile.pendingLifecycle == 0 else { throw CancellationError() }
      guard profile.nativeRevision[record.id, default: 0] == revision else { continue }
      profile.nativeInstallations[record.id] = snapshot.installationID
      do {
        let values = try json(snapshot.values)
        let recovered = try await sync.reconcileNativeSnapshot(context(id, record.id), values:values,incarnationID:snapshot.incarnationID)
        let neededRecovery = profile.recoveryNeeded.remove(record.id) != nil
        let pendingLocal = profile.pendingNative.removeValue(forKey:record.id) != nil
        if recovered || neededRecovery || pendingLocal {
          profile.errors.removeValue(forKey:record.id); profile.failedContexts.removeValue(forKey:record.id)
        }
        _ = try await sync.seedNativeStorage(context(id, record.id), values:values)
        profile.seededThrough[record.id] = revision
      } catch let error as ServiceError where error.code == "NATIVE_RECOVERY" {
        profile.recoveryNeeded.insert(record.id); profile.errors[record.id] = error.localizedDescription
      }
    }
    if requireComplete, !profile.recoveryNeeded.isEmpty {
      throw ServiceError("NATIVE_RECOVERY", "Resolve interrupted extension settings in Account & sync before changing synchronization.")
    }
    profile.errors.removeValue(forKey: "")
  }
  private func refreshRegistry(_ id: String, _ profile: Profile, suppress: Set<String> = []) async throws {
    let snapshot = try await profile.manager.snapshot(); try check(id, profile)
    if suppress.isEmpty, profile.pendingLifecycle > 0 { throw CancellationError() }
    let next = Dictionary(uniqueKeysWithValues: snapshot.extensions.compactMap { record -> (String, NativePortableExtension)? in
      guard let portable = NativePortableExtension(chromiumID: record.id, location: record.location, state: record.state,
        userMayModify: record.userMayModify, mustRemainInstalled: record.mustRemainInstalled) else { return nil }
      return (record.id, portable)
    })
    if profile.baseline, let sync = services.syncService {
      for key in Set(next.keys).union(profile.portable.keys).sorted() where !suppress.contains(key) {
        guard next[key] != profile.portable[key] else { continue }
        if let change = next[key] ?? profile.portable[key]?.removed() { try await sync.queueExtension(profileID: id, item: change.descriptor) }
        try check(id, profile)
      }
    }
    if let sync = services.syncService {
      try await sync.pruneNativeStorage(profileID:id, installedIDs:Set(next.keys))
      if profile.baseline {
        for record in snapshot.extensions where next[record.id] != nil && profile.portable[record.id] == nil && record.isUserEnabled {
          guard try await profile.manager.hasStoragePermission(record.id) else { continue }
          try check(id, profile)
          let storage = try await storageSnapshot(id, profile, record.id)
          try check(id, profile)
          try await sync.adoptNativeInstallation(context(id,record.id),values:json(storage.values),incarnationID:storage.incarnationID)
          profile.nativeInstallations[record.id] = storage.installationID
        }
      }
    }
    profile.records = Dictionary(uniqueKeysWithValues: snapshot.extensions.map { ($0.id, $0) })
    profile.portable = next; profile.baseline = true
    for ext in profile.pendingNative.keys where next[ext] == nil {
      profile.pendingNative.removeValue(forKey: ext)
      profile.errors.removeValue(forKey: ext); profile.failedContexts.removeValue(forKey: ext); profile.recoveryNeeded.remove(ext)
    }
  }
  private func installationChanged(_ id: String, _ profile: Profile, _ ext: String, _ kind: String) async throws {
    try check(id,profile)
    guard let sync = services.syncService else { return }
    if kind == "uninstalled" {
      if let previous = profile.portable[ext] {
        try await sync.queueExtension(profileID:id,item:previous.removed().descriptor)
        try check(id,profile)
      }
      try await sync.forgetNativeInstallation(profileID:id,extensionID:ext)
      try check(id,profile)
      profile.portable.removeValue(forKey:ext); profile.records.removeValue(forKey:ext)
      profile.nativeInstallations.removeValue(forKey:ext); profile.pendingNative.removeValue(forKey:ext)
      profile.recoveryNeeded.remove(ext); profile.errors.removeValue(forKey:ext); profile.failedContexts.removeValue(forKey:ext)
    } else if kind == "installed" {
      let records = try await profile.manager.snapshot().extensions
      try check(id,profile)
      guard let record = records.first(where: { $0.id == ext }), record.isUserEnabled,
        NativePortableExtension(chromiumID:ext,location:record.location,state:record.state,
          userMayModify:record.userMayModify,mustRemainInstalled:record.mustRemainInstalled) != nil,
        try await profile.manager.hasStoragePermission(ext) else { return }
      try check(id,profile)
      let snapshot = try await storageSnapshot(id, profile, ext)
      try check(id,profile)
      if profile.nativeInstallations[ext] != snapshot.installationID {
        try await sync.forgetNativeInstallation(profileID:id,extensionID:ext)
        try check(id,profile)
        try await sync.adoptNativeInstallation(context(id,ext),values:json(snapshot.values),incarnationID:snapshot.incarnationID)
        try check(id,profile)
        profile.nativeInstallations[ext] = snapshot.installationID
      }
    }
    // Updates retain their native baseline: storage survives extension updates.
  }
  private func receiveStorage(_ id: String, _ profile: Profile, _ ext: String, _ installation: String,
                              _ changes: [String: Any], _ revision: Int, retry: Bool = false) async throws {
    defer { profile.processedThrough[ext] = max(profile.processedThrough[ext, default: 0], revision); requestRefresh(id) }
    guard let sync = services.syncService else { return }
    if !retry, revision <= profile.seededThrough[ext, default: -1] { return }
    try check(id, profile)
    guard let record = profile.records[ext], record.isUserEnabled, profile.portable[ext] != nil else { return }
    let snapshot = try await storageSnapshot(id, profile, ext); try check(id, profile)
    guard snapshot.installationID == installation else {
      if profile.pendingNative[ext]?.installation == installation {
        profile.pendingNative.removeValue(forKey: ext); profile.errors.removeValue(forKey: ext)
      }
      return
    }
    let received = try json(changes)
    let oldPending = profile.pendingNative[ext]
    var pending = oldPending?.installation == installation ? oldPending!.changes : ServiceJSON.object([:])
    for (key, delta) in received.object { pending[key] = delta }
    // Keep the latest mutation for each touched key, pruning changes that are
    // already durable. At most512 existing +512 final keys can remain pending.
    let mirror = try await sync.nativeStorageValues(context(id, ext))
    let native = try json(snapshot.values)
    var compact: ServiceJSON = [:]
    for key in pending.object.keys where mirror.object[key] != native.object[key] {
      var delta: ServiceJSON = [:]
      if mirror.contains(key) { delta["oldValue"] = mirror[key] }
      if native.contains(key) { delta["newValue"] = native[key] }
      compact[key] = delta
    }
    profile.pendingNative[ext] = (installation, compact)
    do {
      try await sync.observeNativeStorageChanges(context(id, ext), changes: compact)
      try check(id, profile)
      profile.pendingNative.removeValue(forKey: ext)
      profile.errors.removeValue(forKey: ext)
    } catch {
      // Chromium already accepted the write. Do not let a later cloud apply
      // erase it while our durable mirror cannot be updated.
      profile.errors[ext] = "Local extension settings are waiting to be saved. " + String(error.localizedDescription.prefix(350))
    }
  }
  private func reconcile(_ id: String, _ profile: Profile) async throws {
    guard let sync = services.syncService else { return }
    for (ext, failed) in profile.failedContexts {
      let current = failed["extension"] == .null ? await sync.isCurrentNativeStorageProjection(failed) : await currentIntent(failed)
      if !current {
        profile.failedContexts.removeValue(forKey: ext)
        if profile.pendingNative[ext] == nil { profile.errors.removeValue(forKey: ext) }
      }
    }
    let intents = try await sync.extensionIntents(profileID: id)
    profile.pending = []
    for intent in intents {
      try check(id, profile)
      let ext = intent["extension"]["extensionId"].string, state = intent["extension"]["state"].string
      guard let record = profile.records[ext] else {
        if state != "removed" { profile.pending.append(intent["extension"]) }; continue
      }
      guard profile.portable[ext] != nil else { continue }
      let action = state == "removed" ? "remove" : state == "disabled" && record.isUserEnabled ? "disable" :
        state == "enabled" && record.state == "DISABLED" ? "enable" : nil
      guard let action, profile.errors[ext] == nil, await currentIntent(intent) else { continue }
      try check(id, profile)
      do {
        if action == "remove" { try await profile.manager.uninstall(ext) }
        else { try await profile.manager.setEnabled(ext, enabled: action == "enable") }
        try check(id, profile)
        guard await currentIntent(intent) else { throw ServiceError("cancelled", "The library changed while this action was being reviewed.") }
        profile.errors.removeValue(forKey: ext)
      } catch {
        if await currentIntent(intent) {
          profile.errors[ext] = String(error.localizedDescription.prefix(500)); profile.failedContexts[ext] = intent
        }
      }
      // Native registry events caused by this accepted cloud intent must not
      // become another local library mutation. Other local changes still count.
      try await refreshRegistry(id, profile, suppress: [ext])
    }
    for projection in try await sync.nativeStorageProjections(profileID: id) {
      let ext = projection["extensionId"].string
      guard profile.portable[ext] != nil, profile.records[ext]?.isUserEnabled == true,
        profile.errors[ext] == nil, profile.pendingNative[ext] == nil else { continue }
      do { try await applyStorage(id, profile, projection) }
      catch {
        if await sync.isCurrentNativeStorageProjection(projection) {
          profile.errors[ext] = String(error.localizedDescription.prefix(500)); profile.failedContexts[ext] = projection
        }
      }
    }
    publish(id, profile)
  }
  private func applyStorage(_ id: String, _ profile: Profile, _ projection: ServiceJSON) async throws {
    guard let sync = services.syncService else { return }
    let ext = projection["extensionId"].string
    guard try await profile.manager.hasStoragePermission(ext) else { return }
    try check(id, profile)
    let revision = profile.nativeRevision[ext, default: 0]
    guard max(profile.processedThrough[ext, default: 0], profile.seededThrough[ext, default: 0]) >= revision else { return }
    let snapshot = try await storageSnapshot(id, profile, ext)
    let before = try json(snapshot.values), after = projection["values"]
    var changes: ServiceJSON = [:]
    for key in Set(before.object.keys).union(after.object.keys) where before.object[key] != after.object[key] {
      changes[key] = after.contains(key) ? ["newValue":after[key]] : [:]
    }
    guard !changes.object.isEmpty else { return }
    try check(id, profile)
    guard profile.nativeRevision[ext, default: 0] == revision,
      await sync.isCurrentNativeStorageProjection(projection) else { return }
    let token = try await sync.beginNativeStorageApply(context(id, ext), projection:projection, expectedValues:before,incarnationID:snapshot.incarnationID)
    try check(id, profile)
    // The marker is intentionally retained on any error/timeout. Recovery reads
    // the actual native dictionary to determine whether the write committed.
    try await profile.manager.applyStorageChanges(ext, expectedInstallationID: snapshot.installationID,
      changes: object(changes), origin: "zacro.remote:" + token, expectedValues: snapshot.values)
    try check(id, profile)
    try await sync.completeNativeStorageApply(context(id, ext), token:token)
  }
  private func resolveRecovery(_ id: String, _ profile: Profile, _ ext: String, useLocal: Bool) async throws {
    guard store.activeProfileID == id, profile.recoveryNeeded.contains(ext), let sync = services.syncService,
      profile.portable[ext] != nil, profile.records[ext]?.isUserEnabled == true else { throw CancellationError() }
    let snapshot = try await storageSnapshot(id, profile, ext)
    try check(id, profile)
    guard store.activeProfileID == id else { throw CancellationError() }
    try await sync.resolveNativeStorageRecovery(context(id, ext), values:json(snapshot.values), useLocal:useLocal)
    profile.recoveryNeeded.remove(ext); profile.pendingNative.removeValue(forKey:ext)
    profile.errors.removeValue(forKey:ext); profile.failedContexts.removeValue(forKey:ext)
  }
  private func reviewInstallation(_ id: String, _ profile: Profile, _ ext: String) async throws {
    guard let sync = services.syncService, store.activeProfileID == id,
      let intent = try await sync.extensionIntents(profileID: id).first(where: { $0["extension"]["extensionId"].string == ext && $0["extension"]["state"] != "removed" }),
      await currentIntent(intent) else { throw ServiceError("cancelled", "This remote installation request changed. Review the library again.") }
    try check(id, profile)
    guard store.activeProfileID == id else { throw CancellationError() }
    try await profile.manager.installWebStoreExtension(ext)
    try check(id, profile)
    try await refreshRegistry(id, profile, suppress: [ext])
    guard await currentIntent(intent) else { throw ServiceError("cancelled", "The sync library changed during installation. The extension you approved remains installed locally.") }
  }
  private func currentIntent(_ intent: ServiceJSON) async -> Bool {
    guard let sync = services.syncService, await sync.isCurrentLink(intent),
      let current = try? await sync.extensionIntents(profileID: intent["profileId"].string) else { return false }
    return current.contains { $0["extension"]["extensionId"] == intent["extension"]["extensionId"] &&
      $0["extension"]["generation"] == intent["extension"]["generation"] && $0["extension"]["state"] == intent["extension"]["state"] }
  }
  private func publish(_ id: String, _ profile: Profile) {
    services.updateNativeSync(profileID: id, pending: profile.pending.sorted { $0["extensionId"].string < $1["extensionId"].string },
      errors: profile.errors.keys.sorted().map { ["extensionId":.string($0), "name":.string(profile.records[$0]?.name ?? ""),
        "recovery":.bool(profile.recoveryNeeded.contains($0)), "message":.string(profile.errors[$0] ?? "")] })
  }
  /// Cloud recovery must never confuse missing installation metadata with the
  /// previous installation. Local extension APIs remain independent of sync.
  private func storageSnapshot(_ id: String, _ profile: Profile, _ ext: String) async throws -> ChromeExtensionStorageSnapshot {
    try check(id, profile)
    let snapshot = try await profile.manager.storageSnapshot(ext)
    try check(id, profile)
    let prefix = ext + ":"
    let identity = snapshot.incarnationID ?? ""
    let timestamp = identity.hasPrefix(prefix) ? String(identity.dropFirst(prefix.count)) : ""
    guard !timestamp.isEmpty, timestamp.count <= 20,
      timestamp.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(timestamp) != nil else {
      let name = String((profile.records[ext]?.name ?? ext).prefix(160))
      throw ServiceError("NATIVE_IDENTITY", "Chromium could not verify the installation history for \(name). Restart Zacro and retry synchronization. The extension remains available locally.")
    }
    return snapshot
  }
  private func context(_ profile: String, _ ext: String) -> ExtensionStorageContext {
    ExtensionStorageContext(profileID: profile, extensionID: ext, permissions: ["storage"], trusted: true)
  }
  private func json(_ value: [String: Any]) throws -> ServiceJSON {
    try ServiceJSON.decode(JSONSerialization.data(withJSONObject: value))
  }
  private func object(_ value: ServiceJSON) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any] else { throw ChromeExtensionError.invalidResponse }
    return object
  }
}
