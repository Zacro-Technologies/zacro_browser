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
  private var reservations = Set<String>()
  private var publication: [String: Date] = [:]
  private var sourceTabs: [String: String] = [:]
  var onStarted: (String) -> Void = { _ in }
  init(store: BrowserStore, engine: ChromiumEngine) { self.store = store; self.engine = engine }
  func install() {
    engine.onDownload = { [weak self] profile, isPrivate, download in self?.update(profile, isPrivate, download) }
  }
  func decide(_ download: CefDownload, suggested: String, source: BrowserTab, profile: String) -> CefDownloadDecision {
    let safe = (try? Self.filename(suggested)) ?? "download-\(Int(Date().timeIntervalSince1970))"
    guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return .deny }
    let name = safe as NSString, ext = name.pathExtension
    let stem = name.deletingPathExtension
    for number in 0..<10_000 {
      let suffix = number == 0 ? "" : " (\(number))"
      let path = directory.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
      guard !FileManager.default.fileExists(atPath: path.path), reservations.insert(path.path).inserted else { continue }
      let id = UUID().uuidString
      identifiers["\(profile):\(download.id)"] = id; nativeIDs[id] = download.id
      sourceTabs[id] = source.id
      var record = DownloadRecord(id: id, profileID: profile, url: download.url?.absoluteString ?? "", filename: path.lastPathComponent, path: path.path)
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
    guard store.state.profiles.contains(where: { $0.id == profile && $0.isPrivate == isPrivate }) else { return }
    let key = "\(profile):\(value.id)"
    let id = identifiers[key] ?? UUID().uuidString
    identifiers[key] = id; nativeIDs[id] = value.id
    let status = value.isComplete ? "complete" : value.isCanceled ? "cancelled" : value.isInterrupted ? "interrupted" : value.isPaused ? "paused" : "downloading"
    if status == "downloading", let time = publication[id], Date().timeIntervalSince(time) < 0.15 { return }
    publication[id] = Date()
    var record = store.state.downloads.first { $0.id == id } ?? DownloadRecord(id: id, profileID: profile, url: value.url?.absoluteString ?? "", filename: value.fullPath?.lastPathComponent ?? "Download")
    if let path = value.fullPath { record.path = path.path; record.filename = path.lastPathComponent }
    record.receivedBytes = value.receivedBytes; record.totalBytes = value.totalBytes; record.status = status
    store.recordDownload(record)
    if ["complete", "cancelled"].contains(status) {
      if let path = record.path { reservations.remove(path) }; nativeIDs.removeValue(forKey: id)
    }
  }
  func record(_ id: String, profileID: String? = nil) throws -> DownloadRecord {
    guard let value = store.state.downloads.first(where: { $0.id == id && $0.profileID == (profileID ?? store.activeProfileID) }) else { throw ShortcutError("This download is not available in this profile.") }
    return value
  }
  func perform(_ action: String, id: String, name: String = "", profileID: String? = nil) throws {
    var value = try record(id, profileID: profileID)
    if ["download:pause", "download:resume", "download:cancel"].contains(action) {
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
      guard value.status == "complete", let path = value.path else { throw ShortcutError("Wait for the download to finish before renaming it.") }
      let current = URL(fileURLWithPath: path), destination: URL
      if action == "download:undo" {
        guard let previous = value.previousPath, URL(fileURLWithPath: previous).deletingLastPathComponent() == current.deletingLastPathComponent() else { throw ShortcutError("There is no rename to undo.") }
        destination = URL(fileURLWithPath: previous)
      } else { destination = current.deletingLastPathComponent().appendingPathComponent(try Self.filename(name, existing: value.filename)) }
      if current == destination { return }
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
