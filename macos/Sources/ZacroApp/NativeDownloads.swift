import AppKit
import Darwin
import ZacroCore
import ZacroChromium

@MainActor
final class NativeDownloads {
  private let store: BrowserStore
  private let engine: ChromiumEngine
  private var identifiers: [String: String] = [:]
  private var nativeIDs: [String: UInt32] = [:]
  private var reservations: [String: String] = [:] // Destination path -> owning profile.
  private var publication: [String: Date] = [:]
  private var sourceTabs: [String: String] = [:]
  private var nativeRevision: [String: Int] = [:]
  private var snapshotTasks: [String: Task<Void, Error>] = [:]
  private var profileEpochs: [String: Int] = [:]
  private var stopped = false
  var enabled = false
  /// The acceptance harness supplies a directory inside its disposable profile.
  /// Ordinary browsing retains the user's Downloads directory.
  var destinationDirectory: URL?
  var onStarted: (String) -> Void = { _ in }
  var onStatus: ((String, String?) -> Void)?
  init(store: BrowserStore, engine: ChromiumEngine) { self.store = store; self.engine = engine }
  func install() {
    engine.onDownload = { [weak self] profile, isPrivate, download in self?.update(profile, isPrivate, download) }
  }
  func decide(_ download: CefDownload, suggested: String, source: BrowserTab, profile: String) -> CefDownloadDecision {
    let safe = (try? Self.filename(suggested)) ?? "download-\(Int(Date().timeIntervalSince1970))"
    guard let directory = destinationDirectory
      ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return .deny }
    let name = safe as NSString, ext = name.pathExtension
    let stem = name.deletingPathExtension
    for number in 0..<10_000 {
      let suffix = number == 0 ? "" : " (\(number))"
      let path = directory.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
      guard !FileManager.default.fileExists(atPath: path.path), reservations[path.path] == nil else { continue }
      reservations[path.path] = profile
      let key = "\(profile):\(download.id)"
      let id = identifiers[key] ?? UUID().uuidString
      identifiers[key] = id; nativeIDs[id] = download.id
      sourceTabs[id] = source.id
      var record = store.state.downloads.first { $0.id == id }
        ?? DownloadRecord(id: id, profileID: profile, url: download.url?.absoluteString ?? "", filename: path.lastPathComponent)
      record.filename = path.lastPathComponent; record.path = path.path
      record.sourceURL = source.url; record.sourceTitle = source.displayTitle
      store.recordDownload(record); onStarted(source.id)
      return .allow(destination: path)
    }
    return .deny
  }
  func protects(_ tab: BrowserTab, profileID: String) -> Bool {
    store.state.downloads.contains {
      $0.profileID == profileID && nativeIDs[$0.id] != nil && !["complete","cancelled"].contains($0.status)
        && (sourceTabs[$0.id] == tab.id || (sourceTabs[$0.id] == nil && $0.sourceURL == tab.url))
    }
  }
  private func update(_ profile: String, _ isPrivate: Bool, _ value: CefDownload) {
    guard !stopped, store.state.profiles.contains(where: { $0.id == profile && $0.isPrivate == isPrivate }) else { return }
    let key = "\(profile):\(value.id)"
    let id = identifiers[key] ?? UUID().uuidString
    identifiers[key] = id; nativeIDs[id] = value.id
    let status = value.isComplete ? "complete" : value.isCanceled ? "cancelled" : value.isInterrupted ? "interrupted" : value.isPaused ? "paused" : "downloading"
    if status == "downloading", let time = publication[id], Date().timeIntervalSince(time) < 0.15 { return }
    publication[id] = Date()
    var record = store.state.downloads.first { $0.id == id } ?? DownloadRecord(id: id, profileID: profile, url: value.url?.absoluteString ?? "", filename: value.fullPath?.lastPathComponent ?? "Download")
    // Once the real DownloadManager supplies a GUID, its profile-owned events
    // also cover worker downloads, resume and source-document destruction.
    if enabled, record.nativeGUID != nil { return }
    if let path = value.fullPath { record.path = path.path; record.filename = path.lastPathComponent }
    record.receivedBytes = value.receivedBytes; record.totalBytes = value.totalBytes; record.status = status
    store.recordDownload(record)
    if ["complete", "cancelled"].contains(status) {
      if let path = record.path { reservations.removeValue(forKey: path) }; nativeIDs.removeValue(forKey: id)
    }
  }
  func nativeEvent(profileID: String, event: ChromeExtensionEvent) {
    guard enabled, !stopped else { return }
    switch event {
    case .downloadChanged(let item):
      nativeRevision[profileID + ":" + item.guid, default: 0] += 1
      updateNative(profileID: profileID, item: item)
    case .downloadRemoved(let guid):
      nativeRevision[profileID + ":" + guid, default: 0] += 1
      let removed = store.state.downloads.filter { $0.profileID == profileID && $0.nativeGUID == guid }
      do {
        try store.commit { $0.downloads.removeAll { $0.profileID == profileID && $0.nativeGUID == guid } }
        for record in removed {
          nativeIDs.removeValue(forKey: record.id); sourceTabs.removeValue(forKey: record.id)
          publication.removeValue(forKey: record.id)
          identifiers = identifiers.filter { $0.value != record.id }
          if let path = record.path { reservations.removeValue(forKey: path) }
        }
      } catch { onStatus?(profileID, error.localizedDescription) }
    default: break
    }
  }
  func refresh(profileID: String) async throws {
    guard enabled, !stopped, !engine.isTerminating,
      store.state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }) else { return }
    if let existing = snapshotTasks[profileID] { return try await existing.value }
    let epoch = profileEpochs[profileID, default: 0]
    let task = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      defer { if self.profileEpochs[profileID, default: 0] == epoch { self.snapshotTasks.removeValue(forKey: profileID) } }
      do {
        let revisions = self.nativeRevision
        let snapshot = try await ChromeExtensionManager(engine: self.engine, profileID: profileID).downloadSnapshot()
        try Task.checkCancellation()
        guard !self.stopped, !self.engine.isTerminating, self.profileEpochs[profileID, default: 0] == epoch else { throw CancellationError() }
        let nativeGUIDs = Set(snapshot.downloads.map(\.guid))
        guard snapshot.total >= snapshot.downloads.count,
          nativeGUIDs.count == snapshot.downloads.count,
          nativeGUIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
          !snapshot.complete || snapshot.total == snapshot.downloads.count else {
          throw ShortcutError("The native download snapshot is incomplete or invalid.")
        }
        var records: [DownloadRecord] = []
        let visible = snapshot.downloads.sorted { lhs, rhs in
          let leftActive = DownloadCollection.isActive(status: lhs.paused ? "paused" : lhs.status, canResume: lhs.canResume)
          let rightActive = DownloadCollection.isActive(status: rhs.paused ? "paused" : rhs.status, canResume: rhs.canResume)
          if leftActive != rightActive { return leftActive }
          if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
          return lhs.guid < rhs.guid
        }.prefix(1_000)
        for item in visible {
          let key = profileID + ":" + item.guid
          // Events received after this snapshot began are newer than its rows.
          if self.nativeRevision[key, default: 0] == revisions[key, default: 0] {
            if let record = self.updateNative(profileID: profileID, item: item, publish: false) { records.append(record) }
          }
        }
        let unchanged = Set(self.store.state.downloads.compactMap { record -> String? in
          guard record.profileID == profileID, let guid = record.nativeGUID else { return nil }
          let key = profileID + ":" + guid
          return self.nativeRevision[key, default: 0] == revisions[key, default: 0] ? guid : nil
        })
        let merged = DownloadCollection.reconcile(existing: self.store.state.downloads, updates: records,
          profileID: profileID, nativeGUIDs: nativeGUIDs, complete: snapshot.complete, unchangedGUIDs: unchanged)
        if merged != self.store.state.downloads {
          let retainedIDs = Set(merged.map(\.id))
          let removed = self.store.state.downloads.filter { $0.profileID == profileID && !retainedIDs.contains($0.id) }
          try self.store.commit { $0.downloads = merged }
          for record in removed {
            self.nativeIDs.removeValue(forKey: record.id); self.sourceTabs.removeValue(forKey: record.id)
            self.publication.removeValue(forKey: record.id)
            self.identifiers = self.identifiers.filter { $0.value != record.id }
            if let path = record.path { self.reservations.removeValue(forKey: path) }
          }
        }
        self.onStatus?(profileID, snapshot.total > 1_000 ? "The Library shows your most recent 1,000 downloads." : nil)
      } catch {
        if !(error is CancellationError) { self.onStatus?(profileID, error.localizedDescription) }
        throw error
      }
    }
    snapshotTasks[profileID] = task
    try await task.value
  }
  @discardableResult private func updateNative(profileID: String, item: ChromeNativeDownload, publish: Bool = true) -> DownloadRecord? {
    guard !item.isPrivate, UUID(uuidString: item.guid) != nil,
      store.state.profiles.contains(where: { $0.id == profileID && !$0.isPrivate }) else { return nil }
    let key = "\(profileID):\(item.id)"
    let recordForID = identifiers[key].flatMap { id in store.state.downloads.first { $0.id == id } }
    let existing = store.state.downloads.first { $0.profileID == profileID && $0.nativeGUID == item.guid }
      ?? recordForID.flatMap { $0.nativeGUID == nil || $0.nativeGUID == item.guid ? $0 : nil }
    var record = existing ?? DownloadRecord(profileID: profileID, url: item.url,
      filename: item.path.isEmpty ? "Download" : URL(fileURLWithPath: item.path).lastPathComponent)
    record.nativeGUID = item.guid; record.canResume = item.canResume; record.isDangerous = item.dangerous
    record.url = item.url
    if !item.path.isEmpty {
      record.path = item.path; record.filename = URL(fileURLWithPath: item.path).lastPathComponent
    }
    if item.startedAt.isFinite, item.startedAt > 0 { record.createdAt = Date(timeIntervalSince1970: item.startedAt / 1000) }
    if record.sourceURL == nil, !item.sourceURL.isEmpty { record.sourceURL = item.sourceURL }
    if let native = item.sourceTabID,
      let page = engine.pages.values.first(where: { $0.profileID == profileID && $0.reservedNativeTabID == native }),
      let tab = store.tab(page.id) {
      sourceTabs[record.id] = tab.id
      record.sourceURL = tab.url; record.sourceTitle = tab.displayTitle
    }
    let download = item.download
    record.receivedBytes = download.receivedBytes; record.totalBytes = download.totalBytes
    record.status = item.paused ? "paused" : item.status
    identifiers[key] = record.id
    if ["complete", "cancelled"].contains(record.status) {
      nativeIDs.removeValue(forKey: record.id)
      if let path = record.path { reservations.removeValue(forKey: path) }
    } else { nativeIDs[record.id] = item.id }
    if existing != record {
      if publish {
        if record.status == "downloading", existing?.status == record.status,
          existing?.nativeGUID == record.nativeGUID, existing?.isDangerous == record.isDangerous,
          existing?.path == record.path, let date = publication[record.id], Date().timeIntervalSince(date) < 0.15 { return nil }
        publication[record.id] = Date()
        store.recordDownload(record)
      }
      return record
    }
    return nil
  }
  func close() async {
    stopped = true
    let tasks = Array(snapshotTasks.values)
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    onStatus = nil
  }
  func removeProfile(_ id: String) {
    func belongsToProfile(_ key: String) -> Bool {
      key.lastIndex(of: ":").map { String(key[..<$0]) == id } ?? false
    }
    profileEpochs[id, default: 0] += 1
    snapshotTasks.removeValue(forKey: id)?.cancel()
    nativeRevision = nativeRevision.filter { !belongsToProfile($0.key) }
    let removed = Set(identifiers.filter { belongsToProfile($0.key) }.map(\.value))
    identifiers = identifiers.filter { !belongsToProfile($0.key) }
    nativeIDs = nativeIDs.filter { !removed.contains($0.key) }
    sourceTabs = sourceTabs.filter { !removed.contains($0.key) }
    publication = publication.filter { !removed.contains($0.key) }
    reservations = reservations.filter { $0.value != id }
  }
  func record(_ id: String, profileID: String? = nil) throws -> DownloadRecord {
    guard let value = store.state.downloads.first(where: { $0.id == id && $0.profileID == (profileID ?? store.activeProfileID) }) else { throw ShortcutError("This download is not available in this profile.") }
    return value
  }
  func perform(_ action: String, id: String, name: String = "", profileID: String? = nil) async throws {
    var value = try record(id, profileID: profileID)
    if ["download:pause", "download:resume", "download:cancel"].contains(action) {
      if enabled, let guid = value.nativeGUID {
        try await ChromeExtensionManager(engine: engine, profileID: value.profileID)
          .controlDownload(guid: guid, action: String(action.dropFirst("download:".count)))
        try await refresh(profileID: value.profileID)
        return
      }
      guard let native = nativeIDs[id] else { throw ShortcutError("This download is no longer running. Download it again from the source page.") }
      let success: Bool
      switch action {
      case "download:pause": success = engine.pauseDownload(profileID: value.profileID, id: native)
      case "download:resume": success = engine.resumeDownload(profileID: value.profileID, id: native)
      default: success = engine.cancelDownload(profileID: value.profileID, id: native)
      }
      guard success else { throw ShortcutError("This download can no longer be changed. Download it again from the source page.") }
      value.status = action == "download:pause" ? "paused" : action == "download:resume" ? "downloading" : "cancelled"
    } else if action == "download:rename" || action == "download:undo" {
      guard value.status == "complete", value.isDangerous != true, let path = value.path else { throw ShortcutError("Wait for the download to finish before renaming it.") }
      let current = URL(fileURLWithPath: path), destination: URL
      if action == "download:undo" {
        guard let previous = value.previousPath, URL(fileURLWithPath: previous).deletingLastPathComponent() == current.deletingLastPathComponent() else { throw ShortcutError("There is no rename to undo.") }
        destination = URL(fileURLWithPath: previous)
      } else { destination = current.deletingLastPathComponent().appendingPathComponent(try Self.filename(name, existing: value.filename)) }
      if current == destination { return }
      if enabled, let guid = value.nativeGUID {
        try await ChromeExtensionManager(engine: engine, profileID: value.profileID)
          .renameDownload(guid: guid, newName: destination.lastPathComponent)
        try await refresh(profileID: value.profileID)
        value = try record(id, profileID: value.profileID)
        guard value.path == destination.path else { throw ShortcutError("The download location changed during the rename.") }
        value.previousPath = action == "download:undo" ? nil : path
        store.recordDownload(value)
        return
      }
      // Atomic no-replace rename prevents another process's file being overwritten.
      guard renamex_np(current.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST { throw ShortcutError("A file with that name already exists. Choose another name.") }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      value.previousPath = action == "download:undo" ? nil : path
      value.path = destination.path; value.filename = destination.lastPathComponent
    } else { throw ShortcutError("Unknown download action.") }
    store.recordDownload(value)
  }
  static func filename(_ input: String, existing: String = "") throws -> String {
    var name = input.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
    guard !name.isEmpty, name.utf16.count <= 200, !name.hasPrefix("."), !name.hasSuffix("."),
      !name.unicodeScalars.contains(where: { invalid.contains($0) || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value) }),
      name.range(of: #"^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)"#, options: [.regularExpression,.caseInsensitive]) == nil
    else { throw ShortcutError("Use a filename of 1–200 characters without path separators or reserved characters.") }
    let ext = (existing as NSString).pathExtension
    if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
      guard (name as NSString).pathExtension.isEmpty else { throw ShortcutError("Keep the original .\(ext) file extension.") }
      name += "." + ext
    }
    return name
  }
}
