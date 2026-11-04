import AppKit
import Foundation

@MainActor private final class ChromeManagementCancellation {
  let browser: CefBrowser
  let operationID: String
  private var task: Task<Void, Never>?
  init(browser: CefBrowser, operationID: String) {
    self.browser = browser; self.operationID = operationID
  }
  func cancel() {
    guard task == nil else { return }
    task = Task { [browser, operationID] in
      _ = try? await browser.devTools.call("Zacro.cancelExtensionManagement",
        parameters: ["operationID": operationID], timeout: 10)
    }
  }
  func cancelAndWait() async { cancel(); await task?.value }
}

public struct ChromeExtension: Decodable, Identifiable, Sendable {
  public struct Permission: Decodable, Sendable {
    public let message: String
    public let submessages: [String]
  }
  public struct Host: Decodable, Sendable {
    public let host: String
    public let granted: Bool
  }
  public struct HostPermissions: Decodable, Sendable {
    public let hasAllHosts: Bool
    public let hostAccess: String
    public let hosts: [Host]
  }
  public struct Permissions: Decodable, Sendable {
    public let simplePermissions: [Permission]
    public let runtimeHostPermissions: HostPermissions?
  }
  public struct Access: Decodable, Sendable {
    public let isEnabled: Bool
    public let isActive: Bool
  }
  public struct SafetyCheck: Decodable, Sendable {
    public let panelString: String?
    public let detailString: String?
  }
  public struct ControlledInfo: Decodable, Sendable { public let text: String }
  public struct DisableReasons: Decodable, Sendable {
    public let suspiciousInstall: Bool
    public let corruptInstall: Bool
    public let updateRequired: Bool
    public let publishedInStoreRequired: Bool
    public let blockedByPolicy: Bool
    public let reloading: Bool
    public let custodianApprovalRequired: Bool
    public let parentDisabledPermissions: Bool
    public let unsupportedManifestVersion: Bool
    public let unsupportedDeveloperExtension: Bool
    public let disabledByAnotherExtension: Bool
    public let disabledByExtensionName: String?
  }
  public struct OptionsPage: Decodable, Sendable {
    public let openInTab: Bool
    public let url: String
  }
  public struct Command: Decodable, Sendable {
    public let description: String
    public let keybinding: String
    public let name: String
    public let isActive: Bool
    public let scope: String
    public let isExtensionAction: Bool
  }
  public struct View: Decodable, Sendable {
    public let url: String
    public let renderProcessId: Int
    public let renderViewId: Int
    public let incognito: Bool
    public let type: String
  }
  public let id: String
  public let name: String
  public let version: String
  public let description: String
  public let state: String
  public let iconUrl: String
  public let location: String
  public let userMayModify: Bool
  public let mustRemainInstalled: Bool
  public let pinnedToToolbar: Bool?
  public let permissions: Permissions
  public let incognitoAccess: Access
  public let fileAccess: Access
  public let userScriptsAccess: Access
  public let isCommandRegistrationHandledExternally: Bool
  public let blocklistText: String?
  public let safetyCheckText: SafetyCheck?
  public let controlledInfo: ControlledInfo?
  public let disableReasons: DisableReasons
  public let webStoreUrl: String
  public let installWarnings: [String]
  public let runtimeWarnings: [String]
  public let optionsPage: OptionsPage?
  public let commands: [Command]
  public let views: [View]
  public let updateUrl: String
  public let path: String?
  public let type: String
  public let offlineEnabled: Bool
  public var isEnabled: Bool { state == "ENABLED" }
  /// A crashed extension retains its enabled intent for portable library sync.
  public var isUserEnabled: Bool { state == "ENABLED" || state == "TERMINATED" }
  public var hasVerifiedWebStoreSource: Bool { location == "FROM_STORE" }
  public var isPinned: Bool { pinnedToToolbar == true }
}

public struct ChromeExtensionProfile: Decodable, Sendable {
  public let canLoadUnpacked: Bool
  public let inDeveloperMode: Bool
  public let isDeveloperModeControlledByPolicy: Bool
  public let isIncognitoAvailable: Bool
}

public struct ChromeExtensionSnapshot: Decodable, Sendable {
  public let extensions: [ChromeExtension]
  public let profile: ChromeExtensionProfile
}

public struct ChromeExtensionAction: Decodable, Sendable {
  public let hasAction: Bool
  public let hasSidePanel: Bool
  public let title: String
  public let badgeText: String
  public let badgeColor: [Int]
  public let badgeForeground: [Int]
  public let enabled: Bool
  public let iconPNG: String?
}

public struct ChromeExtensionStorageSnapshot {
  public let installationID: String
  public let incarnationID: String?
  public let values: [String: Any]
}

public struct ChromeExtensionHostRequest: Sendable {
  public let requestID: String
  public let extensionID: String
  public let method: String
  public let argumentsJSON: Data
  public let sourceTabID: Int?
  public let sourceWindowID: Int?
  public let userGesture: Bool
  public let incognito: Bool
}

public enum ChromeExtensionEvent {
  case registryChanged
  case commandsChanged
  case bookmarksChanged(revision: String)
  case historyChanged(revision: String)
  case downloadChanged(ChromeNativeDownload)
  case downloadRemoved(guid: String)
  case installationChanged(extensionID: String, kind: String)
  case actionChanged(extensionID: String, nativeTabID: Int?)
  case storageChanged(extensionID: String, installationID: String, changes: [String: Any], origin: String)
  case hostRequest(ChromeExtensionHostRequest)
  /// One-use receipt from Chrome's completed-uninstall URL producer. The
  /// removed extension has no outstanding API invocation or retained authority.
  case postUninstallNavigation(requestID: String)
}

public enum ChromeExtensionError: Error, LocalizedError {
  case invalidIdentifier, managementUnavailable, invalidResponse
  case loadFailed(String)
  case reviewRequired(String), operationCancelled
  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier: return "The extension identifier is invalid."
    case .managementUnavailable: return "Chromium's extension manager is unavailable in this profile."
    case .invalidResponse: return "Chromium returned an invalid extension response."
    case .loadFailed(let message): return message
    case .reviewRequired(let message): return message
    case .operationCancelled: return "The extension change was cancelled."
    }
  }
}

public struct ChromeLogicalTabRegistration: Sendable {
  public let logicalID: String
  public let windowID: Int
  public let index: Int
  public let active: Bool
  public let highlighted: Bool
  public let pinned: Bool
  public let discarded: Bool
  public let autoDiscardable: Bool
  public let splitViewID: Int
  public let openerLogicalID: String?
  public let groupID: Int
  public init(logicalID: String, windowID: Int, index: Int, active: Bool, pinned: Bool,
              discarded: Bool, autoDiscardable: Bool = true, splitViewID: Int = -1,
              openerLogicalID: String? = nil, highlighted: Bool? = nil, groupID: Int = -1) {
    self.logicalID = logicalID; self.windowID = windowID; self.index = index
    self.active = active; self.pinned = pinned; self.discarded = discarded
    self.highlighted = highlighted ?? active
    self.autoDiscardable = autoDiscardable; self.splitViewID = splitViewID
    self.openerLogicalID = openerLogicalID
    self.groupID = groupID
  }
  fileprivate var parameters: [String: Any] {
    var value: [String: Any] = ["logicalID": logicalID, "windowID": windowID, "index": index,
      "active": active, "highlighted": highlighted, "pinned": pinned, "discarded": discarded,
      "autoDiscardable": autoDiscardable, "splitViewID": splitViewID, "groupID": groupID]
    if let openerLogicalID { value["openerLogicalID"] = openerLogicalID }
    return value
  }
}

public struct ChromeLogicalTabIdentity: Sendable {
  public let logicalID: String
  public let nativeID: Int
  public let materialized: Bool
}

public struct ChromeLogicalGroupRegistration: Sendable {
  public let logicalID: String
  public let windowID: Int
  public let title: String
  public let color: String
  public let collapsed: Bool
  public let shared: Bool
  public init(logicalID: String, windowID: Int, title: String, color: String,
              collapsed: Bool, shared: Bool = false) {
    self.logicalID = logicalID; self.windowID = windowID; self.title = title
    self.color = color; self.collapsed = collapsed; self.shared = shared
  }
  fileprivate var parameters: [String: Any] {
    ["logicalID": logicalID, "windowID": windowID, "title": title, "color": color,
     "collapsed": collapsed, "shared": shared]
  }
}

public struct ChromeLogicalGroupIdentity: Sendable {
  public let logicalID: String
  public let nativeID: Int
}

public struct ChromeTabMaterialization: Sendable {
  public let logicalID: String
  public let profileID: String
  public let nativeID: Int
  public let token: String
}

/// Reads and controls Chromium's real extension registry through its trusted
/// internal management document. It never loads privileged APIs into websites.
/// Native action dispatch uses Chromium's trusted browser protocol session.
/// Logical Zacro tab/window grouping is a separate engine integration.
@MainActor
public final class ChromeExtensionManager {
  /// Chromium's built-in PDF component. Private transport never hosts an
  /// installed third-party extension or participates in extension sync.
  public nonisolated static let bundledPDFExtensionID = "mhjfbmdgcfjbbpaeojofohoefgiehjai"
  public let profileID: String
  public let isPrivate: Bool
  private unowned let engine: ChromiumEngine
  private var eventToken: UUID?
  private weak var observedBrowser: CefBrowser?
  private var privateTransportRetired = false
  public init(engine: ChromiumEngine, profileID: String, isPrivate: Bool = false) {
    self.engine = engine; self.profileID = profileID; self.isPrivate = isPrivate
  }

  public var isPrivateComponentObserverActive: Bool {
    guard isPrivate, !privateTransportRetired, eventToken != nil, let browser = observedBrowser,
      !browser.isClosed, let page = engine.pages[transportID] else { return false }
    return page.isPrivate && page.profileID == profileID && page.browser === browser
  }

  public func snapshot() async throws -> ChromeExtensionSnapshot {
    let value = try await evaluate("""
      const [extensions, profile] = await Promise.all([
        chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true}),
        chrome.developerPrivate.getProfileConfiguration()
      ]);
      return {extensions,profile};
      """)
    guard let value, JSONSerialization.isValidJSONObject(value) else { throw ChromeExtensionError.invalidResponse }
    let snapshot = try JSONDecoder().decode(ChromeExtensionSnapshot.self,
      from: JSONSerialization.data(withJSONObject: value))
    engine.updateExtensionAccess(snapshot, profileID: profileID)
    return snapshot
  }

  /// Native registry, action and storage observation does not depend on any
  /// extension renderer running or subscribing to JavaScript events.
  public func observeChanges(_ callback: @escaping (ChromeExtensionEvent) -> Void) async throws {
    guard !isPrivate else { throw ChromeExtensionError.managementUnavailable }
    try await observeNativeChanges(componentsOnly: false, callback)
  }

  /// A separate, memory-only channel for the built-in PDF viewer. Registry,
  /// storage, downloads and cloud events are not subscribed or forwarded here.
  public func observePrivateComponentRequests(_ callback: @escaping (ChromeExtensionHostRequest) -> Void) async throws {
    guard isPrivate else { throw ChromeExtensionError.managementUnavailable }
    try await observeNativeChanges(componentsOnly: true) { event in
      if case .hostRequest(let request) = event, request.incognito,
        request.extensionID == Self.bundledPDFExtensionID { callback(request) }
    }
  }

  private func observeNativeChanges(componentsOnly: Bool,
      _ callback: @escaping (ChromeExtensionEvent) -> Void) async throws {
    await close()
    let browser = try await nativeBrowser()
    let token = try browser.devTools.observeEvents { method, params in
      switch method {
      case "Zacro.extensionRegistryChanged": callback(.registryChanged)
      case "Zacro.extensionCommandsChanged": callback(.commandsChanged)
      case "Zacro.downloadChanged":
        if let data = try? JSONSerialization.data(withJSONObject: params),
          let value = try? JSONDecoder().decode(ChromeNativeDownload.self, from: data) { callback(.downloadChanged(value)) }
      case "Zacro.downloadRemoved":
        if let guid = params["guid"] as? String { callback(.downloadRemoved(guid: guid)) }
      case "Zacro.historyChanged":
        if let revision = params["revision"] as? String { callback(.historyChanged(revision: revision)) }
      case "Zacro.bookmarksChanged":
        if let revision = params["revision"] as? String { callback(.bookmarksChanged(revision: revision)) }
      case "Zacro.extensionInstallationChanged":
        if let id = params["id"] as? String, let kind = params["kind"] as? String,
          ["installed", "updated", "uninstalled"].contains(kind) { callback(.installationChanged(extensionID: id, kind: kind)) }
      case "Zacro.extensionActionChanged":
        if let id = params["id"] as? String { callback(.actionChanged(extensionID: id, nativeTabID: params["tabID"] as? Int)) }
      case "Zacro.extensionStorageChanged":
        if let id = params["id"] as? String, let installation = params["installationID"] as? String,
          let changes = params["changes"] as? [String: Any], let origin = params["origin"] as? String {
          callback(.storageChanged(extensionID: id, installationID: installation, changes: changes, origin: origin))
        }
      case "Zacro.extensionHostRequest":
        if let requestID = params["requestID"] as? String, let id = params["extensionID"] as? String,
          let method = params["method"] as? String, let arguments = params["arguments"] as? [Any],
          let data = try? JSONSerialization.data(withJSONObject: arguments),
          let gesture = params["userGesture"] as? Bool, let incognito = params["incognito"] as? Bool {
          callback(.hostRequest(ChromeExtensionHostRequest(requestID: requestID, extensionID: id,
            method: method, argumentsJSON: data, sourceTabID: params["sourceTabID"] as? Int,
            sourceWindowID: params["sourceWindowID"] as? Int,
            userGesture: gesture, incognito: incognito)))
        }
      case "Zacro.postUninstallNavigation":
        if let requestID = params["requestID"] as? String {
          callback(.postUninstallNavigation(requestID: requestID))
        }
      default: break
      }
    }
    do {
      _ = try await browser.devTools.call("Zacro.observeExtensions", parameters: [
        "enabled": true, "componentsOnly": componentsOnly])
      eventToken = token; observedBrowser = browser
    } catch { browser.devTools.removeEventObserver(token); throw error }
  }

  public func close() async {
    guard let browser = observedBrowser else { eventToken = nil; return }
    if let eventToken { browser.devTools.removeEventObserver(eventToken) }
    eventToken = nil; observedBrowser = nil
    _ = try? await browser.devTools.call("Zacro.observeExtensions", parameters: [
      "enabled": false, "componentsOnly": isPrivate])
  }

  /// Await the actual native close before releasing the ephemeral context.
  /// This private transport has no model document, form state or unload veto.
  public func closePrivateComponentTransport() async {
    guard isPrivate else { return }
    privateTransportRetired = true
    await close()
    guard let page = engine.pages[transportID], page.isPrivate,
      page.profileID == profileID else { return }
    await withCheckedContinuation { continuation in
      let previous = page.onClosed
      page.onClosed = {
        previous?()
        continuation.resume()
      }
      // CefChromeBrowser remembers closeRequested before its CEF window is
      // created. Calling the raw CefBrowser host here would silently do
      // nothing while that host is still pending.
      page.close()
    }
  }

  /// Rechecks the native caller and installation immediately before a host mutation.
  public func validateHostRequest(requestID: String) async throws {
    guard !requestID.isEmpty, requestID.count <= 128 else { throw ChromeExtensionError.invalidResponse }
    _ = try await nativeBrowser().devTools.call("Zacro.validateExtensionHostRequest", parameters: ["requestID": requestID])
  }

  /// Consumes an exact-profile native receipt once. This does not authorize a
  /// caller as the extension which was already uninstalled.
  public func takePostUninstallNavigation(requestID: String) async throws -> URL {
    guard !isPrivate, !requestID.isEmpty, requestID.count <= 128 else { throw ChromeExtensionError.invalidResponse }
    let result = try await nativeBrowser().devTools.call("Zacro.takePostUninstallNavigation",
      parameters: ["requestID": requestID])
    guard let address = result["url"] as? String, address.utf8.count <= 8192,
      let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false, url.user == nil, url.password == nil else {
      throw ChromeExtensionError.invalidResponse
    }
    return url
  }

  public func completeHostRequest(_ requestID: String, results: [Any] = [], error: String? = nil) async throws {
    guard !requestID.isEmpty, requestID.count <= 128, JSONSerialization.isValidJSONObject(results) else {
      throw ChromeExtensionError.invalidResponse
    }
    var params: [String: Any] = ["requestID": requestID, "results": results]
    if let error { params["error"] = String(error.prefix(4096)) }
    _ = try await nativeBrowser().devTools.call("Zacro.completeExtensionHostRequest", parameters: params)
  }

  public func publishBrowserEvent(_ name: String, arguments: [Any]) async throws {
    guard JSONSerialization.isValidJSONObject(arguments) else { throw ChromeExtensionError.invalidResponse }
    _ = try await nativeBrowser().devTools.call("Zacro.publishBrowserEvent", parameters: ["name": name, "arguments": arguments])
  }

  /// Focus is independent of selection: every logical window has an active tab.
  public func setFocusedWindow(_ nativeID: Int?, lastFocusedID: Int? = nil) async throws {
    guard [nativeID, lastFocusedID].allSatisfy({ $0 == nil || ($0! > 0 && $0! <= Int(Int32.max)) }) else {
      throw ChromeExtensionError.invalidResponse
    }
    _ = try await nativeBrowser().devTools.call("Zacro.setFocusedWindow", parameters: [
      "windowID": nativeID.map { $0 as Any } ?? NSNull(),
      "lastFocusedWindowID": lastFocusedID.map { $0 as Any } ?? NSNull(),
    ])
  }

  /// Publishes one authoritative tab snapshot without creating documents.
  public func synchronizeTabs(_ tabs: [ChromeLogicalTabRegistration], revision: UInt64) async throws -> [ChromeLogicalTabIdentity] {
    guard tabs.count <= 4096, revision <= 9_007_199_254_740_991,
      Set(tabs.map(\.logicalID)).count == tabs.count,
      tabs.allSatisfy({ !$0.logicalID.isEmpty && $0.logicalID.utf8.count <= 256 && $0.windowID > 0 && $0.index >= 0 }) else {
      throw ChromeExtensionError.invalidResponse
    }
    let response = try await nativeBrowser().devTools.call("Zacro.synchronizeTabs", parameters: [
      "tabs": tabs.map(\.parameters), "revision": Double(revision),
    ])
    guard let values = response["tabs"] as? [[String: Any]], values.count == tabs.count else { throw ChromeExtensionError.invalidResponse }
    let identities = try values.map { value -> ChromeLogicalTabIdentity in
      guard let logicalID = value["logicalID"] as? String, let nativeID = value["tabID"] as? Int, nativeID > 0,
        let materialized = value["materialized"] as? Bool else { throw ChromeExtensionError.invalidResponse }
      return ChromeLogicalTabIdentity(logicalID: logicalID, nativeID: nativeID, materialized: materialized)
    }
    guard Set(identities.map(\.logicalID)) == Set(tabs.map(\.logicalID)),
      Set(identities.map(\.nativeID)).count == identities.count else { throw ChromeExtensionError.invalidResponse }
    return identities
  }

  /// Allocates Chromium's actual TabGroupId projection independently of views.
  public func synchronizeGroups(_ groups: [ChromeLogicalGroupRegistration], revision: UInt64) async throws -> [ChromeLogicalGroupIdentity] {
    let colors = Set(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"])
    guard groups.count <= 4096, revision <= 9_007_199_254_740_991,
      Set(groups.map(\.logicalID)).count == groups.count,
      groups.allSatisfy({ !$0.logicalID.isEmpty && $0.logicalID.utf8.count <= 256 && $0.windowID > 0 &&
        $0.title.utf8.count <= 4096 && colors.contains($0.color) && !$0.shared }) else { throw ChromeExtensionError.invalidResponse }
    let response = try await nativeBrowser().devTools.call("Zacro.synchronizeGroups", parameters: [
      "groups": groups.map(\.parameters), "revision": Double(revision),
    ])
    guard let values = response["groups"] as? [[String: Any]], values.count == groups.count else { throw ChromeExtensionError.invalidResponse }
    let result = try values.map { value -> ChromeLogicalGroupIdentity in
      guard let logicalID = value["logicalID"] as? String, let nativeID = value["groupID"] as? Int,
        nativeID >= 0 else { throw ChromeExtensionError.invalidResponse }
      return ChromeLogicalGroupIdentity(logicalID: logicalID, nativeID: nativeID)
    }
    guard Set(result.map(\.logicalID)) == Set(groups.map(\.logicalID)),
      Set(result.map(\.nativeID)).count == result.count else { throw ChromeExtensionError.invalidResponse }
    return result
  }

  /// A single-use creation token binds the first SessionTabHelper identity.
  public func prepareTabMaterialization(_ logicalID: String, openerRequestID: String? = nil) async throws -> ChromeTabMaterialization {
    guard !logicalID.isEmpty, logicalID.utf8.count <= 256 else { throw ChromeExtensionError.invalidResponse }
    var parameters: [String: Any] = ["logicalID": logicalID]
    if let openerRequestID {
      guard !openerRequestID.isEmpty, openerRequestID.utf8.count <= 128 else { throw ChromeExtensionError.invalidResponse }
      parameters["openerRequestID"] = openerRequestID
    }
    let response = try await nativeBrowser().devTools.call("Zacro.prepareTabMaterialization", parameters: parameters)
    guard let nativeID = response["tabID"] as? Int, nativeID > 0,
      let token = response["token"] as? String, UUID(uuidString: token) != nil else { throw ChromeExtensionError.invalidResponse }
    return ChromeTabMaterialization(logicalID: logicalID, profileID: profileID, nativeID: nativeID, token: token)
  }

  public func storageSnapshot(_ identifier: String) async throws -> ChromeExtensionStorageSnapshot {
    try validate(identifier)
    let result = try await nativeBrowser().devTools.call("Zacro.getExtensionStorage", parameters: ["id": identifier])
    guard let installation = result["installationID"] as? String, !installation.isEmpty,
      let values = result["values"] as? [String: Any] else { throw ChromeExtensionError.invalidResponse }
    let incarnation = result["incarnationID"] as? String
    return ChromeExtensionStorageSnapshot(installationID: installation,
      incarnationID: incarnation?.isEmpty == false ? incarnation : nil, values: values)
  }

  public func hasStoragePermission(_ identifier: String) async throws -> Bool {
    try validate(identifier)
    let args = try literal([identifier])
    let result = try await evaluate("const [id] = \(args); const info = await chrome.management.get(id); return info.permissions.includes('storage');")
    guard let allowed = result as? Bool else { throw ChromeExtensionError.invalidResponse }
    return allowed
  }

  public func applyStorageChanges(_ identifier: String, expectedInstallationID: String,
                                 changes: [String: Any], origin: String, expectedValues: [String: Any]? = nil) async throws {
    try validate(identifier)
    guard !expectedInstallationID.isEmpty, origin.hasPrefix("zacro.remote:"), origin.count <= 512,
      JSONSerialization.isValidJSONObject(changes) else { throw ChromeExtensionError.invalidResponse }
    let baseline: [String: Any]
    if let expectedValues { baseline = expectedValues }
    else {
      let snapshot = try await storageSnapshot(identifier)
      guard snapshot.installationID == expectedInstallationID else { throw ChromeExtensionError.invalidResponse }
      baseline = snapshot.values
    }
    _ = try await nativeBrowser().devTools.call("Zacro.applyExtensionStorage", parameters: [
      "id": identifier, "installationID": expectedInstallationID, "changes": changes, "origin": origin,
      "expectedValues": baseline,
    ])
  }

  public func action(_ identifier: String, on page: ChromiumPage? = nil) async throws -> ChromeExtensionAction {
    try validate(identifier)
    let browser: CefBrowser
    if let page {
      guard page.profileID == profileID, engine.pages[page.id] === page else { throw ChromeExtensionError.managementUnavailable }
      browser = try await page.ready()
    } else { browser = try await nativeBrowser() }
    let result = try await browser.devTools.call("Zacro.getExtensionAction", parameters: ["id": identifier])
    if let page {
      guard engine.pages[page.id] === page, page.browser === browser else { throw ChromeExtensionError.managementUnavailable }
    }
    return try JSONDecoder().decode(ChromeExtensionAction.self, from: JSONSerialization.data(withJSONObject: result))
  }

  /// Opens Chromium's actual contextual/global panel in response to an explicit
  /// native user action. The target must be the selected registered document.
  public func openSidePanel(_ identifier: String, on page: ChromiumPage) async throws {
    try validate(identifier)
    guard page.profileID == profileID, engine.pages[page.id] === page else { throw ChromeExtensionError.managementUnavailable }
    let browser = try await page.ready()
    guard engine.pages[page.id] === page, page.browser === browser else { throw ChromeExtensionError.managementUnavailable }
    let result = try await browser.devTools.call("Zacro.openExtensionSidePanel", parameters: ["id": identifier])
    guard result["opened"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
  }

  /// Uses Chromium's verified Web Store installer and native permission UI.
  public func installWebStoreExtension(_ identifier: String, ownerWindowID: String) async throws {
    try await performManagement("install", identifier: identifier, ownerWindowID: ownerWindowID)
  }

  /// The native installer uses this manager's real profile, including policy
  /// and manifest validation. Call only for an explicitly selected directory.
  public func loadUnpackedExtension(at directory: URL) async throws -> String {
    guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path.utf8.count <= 4096 else {
      throw ChromeExtensionError.invalidResponse
    }
    let response = try await nativeBrowser().devTools.call("Zacro.loadUnpackedExtension",
      parameters: ["path": directory.standardizedFileURL.path], timeout: 120)
    guard let identifier = response["id"] as? String else { throw ChromeExtensionError.invalidResponse }
    try validate(identifier)
    _ = try await snapshot()
    return identifier
  }

  /// Connects only to this profile's current installed MV3 worker. The native
  /// target check avoids guessing targets from URLs across isolated profiles.
  public func workerSession(_ identifier: String, timeout: TimeInterval = 10) async throws -> ChromeExtensionWorkerSession {
    try validate(identifier)
    let browser = try await nativeBrowser()
    let deadline = Date().addingTimeInterval(max(0.1, min(30, timeout)))
    while true {
      try Task.checkCancellation()
      let target = try await browser.devTools.call("Zacro.extensionWorkerTarget", parameters: ["id": identifier])
      if let targetID = target["targetID"] as? String, let installation = target["installationID"] as? String,
        let workerToken = target["workerToken"] as? String {
        let parentSession = try await browser.devTools.browserSession()
        let response = try await browser.devTools.call("Target.attachToTarget",
          parameters: ["targetId": targetID, "flatten": true], sessionID: parentSession)
        guard let session = response["sessionId"] as? String else { throw ChromeExtensionError.invalidResponse }
        let worker = ChromeExtensionWorkerSession(browser: browser, extensionID: identifier,
          installationID: installation, targetID: targetID, workerToken: workerToken,
          parentSessionID: parentSession, sessionID: session)
        do { try await worker.prepareExecutionContext(); return worker }
        catch { await worker.close(); throw error }
      }
      guard Date() < deadline else { throw ChromeExtensionError.loadFailed("The extension worker has not started.") }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func nativeBrowser() async throws -> CefBrowser {
    guard !privateTransportRetired, !engine.isTerminating,
      engine.pages[transportID] != nil || engine.contexts.values.contains(where: { $0.isOpen && !$0.isClosing })
    else { throw ChromeExtensionError.managementUnavailable }
    let page = engine.pages[transportID] ?? (isPrivate
      ? engine.privateComponentsPage(profileID: profileID) : engine.extensionsPage(profileID: profileID))
    let browser = try await page.ready()
    guard !privateTransportRetired, !engine.isTerminating,
      engine.pages[page.id] === page, page.isPrivate == isPrivate, page.profileID == profileID else { throw ChromeExtensionError.managementUnavailable }
    return browser
  }

  private var transportID: String { "\(isPrivate ? "private-components" : "extensions"):\(profileID)" }

  /// Clears Chromium's real HistoryService and history-backed suggestions for
  /// this profile, including visits visible through chrome.history.
  public func clearBrowsingHistory() async throws {
    try await nativeBrowser().clearProfileBrowsingData(siteData: false, cache: false, history: true)
  }

  public func setPinned(_ identifier: String, pinned: Bool) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.updateExtensionConfiguration",
      [["extensionId": identifier, "pinnedToToolbar": pinned]])
  }

  /// Invokes Chrome's own toolbar action model. Chromium applies activeTab
  /// grants, dispatches onClicked, or opens the extension's popup/side panel.
  /// This must only be called in direct response to a native user action.
  public func performAction(_ identifier: String, on page: ChromiumPage,
                            anchorWindow: NSWindow? = nil, anchorRect: NSRect? = nil) async throws {
    try validate(identifier)
    guard page.profileID == profileID, engine.pages[page.id] === page, let browser = page.browser,
      let extensionInfo = try await snapshot().extensions.first(where: { $0.id == identifier }), extensionInfo.isEnabled,
      !page.isPrivate || extensionInfo.incognitoAccess.isActive else { throw ChromeExtensionError.managementUnavailable }
    guard engine.pages[page.id] === page, page.browser === browser else { throw ChromeExtensionError.managementUnavailable }
    let parameters = try actionParameters(identifier, on: page, anchorWindow: anchorWindow, anchorRect: anchorRect)
    _ = try await browser.devTools.call("Zacro.performExtensionAction", parameters: parameters)
  }

  /// Supplies an anchor for an already validated chrome.action.openPopup
  /// request. Chromium resumes that original API; this never synthesizes a
  /// user action, dispatches onClicked or grants activeTab.
  public func prepareActionPopup(requestID: String, on page: ChromiumPage,
                                 anchorWindow: NSWindow, anchorRect: NSRect? = nil) async throws {
    guard !requestID.isEmpty, requestID.utf8.count <= 128, !page.isPrivate,
      page.profileID == profileID, engine.pages[page.id] === page,
      let browser = page.browser else { throw ChromeExtensionError.managementUnavailable }
    let anchor = try nativeAnchor(on: page, window: anchorWindow, rect: anchorRect)
    let response = try await browser.devTools.call("Zacro.prepareExtensionActionPopup", parameters: [
      "requestID": requestID, "anchor": anchor
    ])
    guard response["prepared"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
  }

  public func shortcuts() async throws -> [ChromeExtensionShortcut] {
    let response = try await nativeBrowser().devTools.call("Zacro.getExtensionShortcuts")
    guard let values = response["shortcuts"] as? [[String: Any]] else { throw ChromeExtensionError.invalidResponse }
    return try JSONDecoder().decode([ChromeExtensionShortcut].self, from: JSONSerialization.data(withJSONObject: values))
  }

  /// Execute only a binding matched against the native snapshot in direct
  /// response to a shell key event. Chromium revalidates its current binding,
  /// installation, focused logical document, and shortcut suspension state.
  public func performShortcut(_ shortcut: ChromeExtensionShortcut, on page: ChromiumPage,
                              anchorWindow: NSWindow? = nil, anchorRect: NSRect? = nil) async throws -> Bool {
    try validate(shortcut.extensionID)
    guard !page.isPrivate, page.profileID == profileID, engine.pages[page.id] === page,
      let browser = page.browser else { throw ChromeExtensionError.managementUnavailable }
    var parameters = try actionParameters(shortcut.extensionID, on: page, anchorWindow: anchorWindow, anchorRect: anchorRect)
    parameters["name"] = shortcut.name; parameters["incarnationID"] = shortcut.incarnationID
    parameters["keybinding"] = shortcut.keybinding
    let result = try await browser.devTools.call("Zacro.performExtensionShortcut", parameters: parameters)
    guard let performed = result["performed"] as? Bool else { throw ChromeExtensionError.invalidResponse }
    return performed
  }

  private func actionParameters(_ identifier: String, on page: ChromiumPage,
                                anchorWindow: NSWindow?, anchorRect: NSRect?) throws -> [String: Any] {
    var parameters: [String: Any] = ["id": identifier]
    if let anchorWindow {
      parameters["anchor"] = try nativeAnchor(on: page, window: anchorWindow, rect: anchorRect)
    }
    return parameters
  }

  private func nativeAnchor(on page: ChromiumPage, window: NSWindow, rect: NSRect?) throws -> [String: Any] {
    guard let ownerID = page.ownerWindowID, let owner = engine.context(id: ownerID),
      owner.isOpen, !owner.isClosing, owner.window === window else { throw ChromeExtensionError.managementUnavailable }
    let rect = rect ?? window.convertToScreen(NSRect(
      x: max(0, window.contentLayoutRect.width - 40),
      y: max(0, window.contentLayoutRect.height - 48), width: 20, height: 20))
    guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
      rect.width > 0, rect.height > 0, rect.width <= 512, rect.height <= 512 else {
      throw ChromeExtensionError.invalidResponse
    }
    return ["windowNumber": window.windowNumber,
      "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
  }

  public func setEnabled(_ identifier: String, enabled: Bool, ownerWindowID: String? = nil) async throws {
    try await performManagement(enabled ? "enable" : "disable", identifier: identifier, ownerWindowID: ownerWindowID)
  }

  /// Chromium presents its own uninstall confirmation and propagates Cancel.
  public func uninstall(_ identifier: String, ownerWindowID: String) async throws {
    try await performManagement("uninstall", identifier: identifier, ownerWindowID: ownerWindowID)
  }

  private func performManagement(_ operation: String, identifier: String, ownerWindowID: String?) async throws {
    try validate(identifier)
    let owner = ownerWindowID.flatMap { engine.context(id: $0) }
    let nativeIdentity = owner?.nativeID
    if ownerWindowID != nil {
      guard let owner, owner.isOpen, !owner.isClosing, owner.window.isVisible else {
        throw ChromeExtensionError.operationCancelled
      }
    }
    let browser = try await nativeBrowser()
    try Task.checkCancellation()
    if let ownerWindowID {
      guard let owner, engine.context(id: ownerWindowID) === owner, owner.isOpen,
        !owner.isClosing, owner.nativeID == nativeIdentity, owner.window.isVisible else {
        throw ChromeExtensionError.operationCancelled
      }
    }
    let operationID = UUID().uuidString.lowercased()
    var parameters: [String: Any] = ["operationID": operationID, "action": operation, "id": identifier]
    if let owner {
      parameters["windowNumber"] = owner.window.windowNumber
      parameters["windowID"] = owner.nativeID
    }
    let cancellation = ChromeManagementCancellation(browser: browser, operationID: operationID)
    do {
      let response = try await withTaskCancellationHandler {
        try await browser.devTools.call("Zacro.extensionManagement", parameters: parameters, timeout: 600)
      } onCancel: {
        Task { @MainActor in cancellation.cancel() }
      }
      if response["reviewRequired"] as? Bool == true {
        throw ChromeExtensionError.reviewRequired(response["message"] as? String ?? "Review this extension change in its browser window.")
      }
      if response["cancelled"] as? Bool == true { throw ChromeExtensionError.operationCancelled }
      guard response["completed"] as? Bool == true else { throw ChromeExtensionError.invalidResponse }
      try Task.checkCancellation()
    } catch {
      // A lost/abandoned protocol reply is not authority for a later mutation.
      // The token is known before dispatch, so cancellation can always revoke
      // the exact native operation, including a still-open Chrome prompt.
      await cancellation.cancelAndWait()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  public func reload(_ identifier: String) async throws {
    try validate(identifier)
    try await invokeLoad("developerPrivate.reload", [identifier,
      ["failQuietly": true, "populateErrorForUnpacked": true]])
  }

  public func checkForUpdates() async throws {
    try await invoke("developerPrivate.autoUpdate", [], userGesture: true, timeout: 120)
  }

  public func setDeveloperMode(_ enabled: Bool) async throws {
    try await invoke("developerPrivate.updateProfileConfiguration", [["inDeveloperMode": enabled]], userGesture: true)
  }

  /// Keeps the directory picker on the real shell instead of the hidden
  /// engine-owned management window. Chromium validates the selected package.
  public func chooseUnpackedExtension() async throws {
    do {
      let capabilities = try await engine.nativeCapabilities()
      if capabilities.extensionBrowser != true {
        try await invokeLoad("developerPrivate.loadUnpacked", [["failQuietly": true, "populateError": true]])
        return
      }
    } catch let error as CefDevToolsError where error.isUnsupportedMethod {
      try await invokeLoad("developerPrivate.loadUnpacked", [["failQuietly": true, "populateError": true]])
      return
    }
    let picker = NSOpenPanel()
    picker.canChooseFiles = false; picker.canChooseDirectories = true
    picker.allowsMultipleSelection = false; picker.prompt = "Load Extension"
    guard picker.runModal() == .OK, let directory = picker.url else { return }
    _ = try await loadUnpackedExtension(at: directory)
  }

  public func setFileAccess(_ identifier: String, allowed: Bool) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.updateExtensionConfiguration",
      [["extensionId": identifier, "fileAccess": allowed]], userGesture: true)
  }

  public func setIncognitoAccess(_ identifier: String, allowed: Bool) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.updateExtensionConfiguration",
      [["extensionId": identifier, "incognitoAccess": allowed]], userGesture: true)
  }

  public func setUserScriptsAccess(_ identifier: String, allowed: Bool) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.updateExtensionConfiguration",
      [["extensionId": identifier, "userScriptsAccess": allowed]], userGesture: true)
  }

  public func setCommandScope(_ identifier: String, name: String, global: Bool) async throws {
    try validate(identifier)
    guard !name.isEmpty, name.utf8.count <= 256 else { throw ChromeExtensionError.invalidResponse }
    try await invoke("developerPrivate.updateExtensionCommand", [["extensionId": identifier,
      "commandName": name, "scope": global ? "GLOBAL" : "CHROME"]], userGesture: true)
  }

  public func setShortcutHandlingSuspended(_ suspended: Bool) async throws {
    try await invoke("developerPrivate.setShortcutHandlingSuspended", [suspended])
  }

  public func updateCommand(_ identifier: String, name: String, keybinding: String, global: Bool = false) async throws {
    try validate(identifier)
    guard !name.isEmpty, name.utf8.count <= 256, keybinding.utf8.count <= 256 else { throw ChromeExtensionError.invalidResponse }
    try await invoke("developerPrivate.updateExtensionCommand", [["extensionId": identifier,
      "commandName": name, "keybinding": keybinding, "scope": global ? "GLOBAL" : "CHROME"]], userGesture: true)
  }

  public func inspectView(_ identifier: String, view: ChromeExtension.View) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.openDevTools", [["extensionId": identifier,
      "renderViewId": view.renderViewId, "renderProcessId": view.renderProcessId,
      "isServiceWorker": view.type == "EXTENSION_SERVICE_WORKER_BACKGROUND",
      "incognito": view.incognito, "url": view.url]], userGesture: true)
  }

  public enum HostAccess: String, Sendable {
    case onClick = "ON_CLICK", specificSites = "ON_SPECIFIC_SITES", allSites = "ON_ALL_SITES"
  }
  public func setHostAccess(_ identifier: String, access: HostAccess) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.updateExtensionConfiguration",
      [["extensionId": identifier, "hostAccess": access.rawValue]], userGesture: true)
  }

  public func setHostPermission(_ identifier: String, pattern: String, allowed: Bool) async throws {
    try validate(identifier)
    guard !pattern.isEmpty, pattern.utf8.count <= 2048 else { throw ChromeExtensionError.invalidResponse }
    try await invoke(allowed ? "developerPrivate.addHostPermission" : "developerPrivate.removeHostPermission",
      [identifier, pattern], userGesture: true)
  }

  public func iconData(_ identifier: String) async throws -> Data {
    try validate(identifier)
    let argument = try literal([identifier])
    let value = try await evaluate("""
      const [id] = \(argument);
      const item = await chrome.developerPrivate.getExtensionInfo(id);
      const url = item.iconUrl;
      if (typeof url !== 'string' || !(url.startsWith('chrome://extension-icon/') || url.startsWith('data:image/')))
        throw new Error('Unsupported extension icon URL.');
      // developerPrivate already returns encoded icon bytes on current Chrome.
      // Fetching that data URL is blocked by the management page's own CSP.
      if (url.startsWith('data:image/')) {
        if (url.length > 349600 || !/^data:image\\/[a-z0-9.+-]+;base64,[a-z0-9+/]+={0,2}$/i.test(url))
          throw new Error('Invalid encoded extension icon.');
        return url;
      }
      const response = await fetch(url);
      if (!response.ok) throw new Error('Extension icon could not be loaded.');
      const blob = await response.blob();
      if (blob.size > 262144 || !blob.type.startsWith('image/')) throw new Error('Invalid extension icon.');
      return await new Promise((resolve,reject) => {
        const reader = new FileReader(); reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('Extension icon could not be read.'));
        reader.readAsDataURL(blob);
      });
      """)
    guard let encoded = value as? String, encoded.hasPrefix("data:image/"),
      let comma = encoded.firstIndex(of: ","), encoded[..<comma].hasSuffix(";base64"),
      let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])), !data.isEmpty, data.count <= 262144
    else { throw ChromeExtensionError.invalidResponse }
    return data
  }

  private func validate(_ identifier: String) throws {
    guard identifier.count == 32, identifier.utf8.allSatisfy({ (97...112).contains($0) }) else {
      throw ChromeExtensionError.invalidIdentifier
    }
  }

  private func literal(_ values: [Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(values),
      let value = String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)
    else { throw ChromeExtensionError.invalidResponse }
    return value
  }

  private func invoke(_ method: String, _ arguments: [Any], userGesture: Bool = false,
                      timeout: TimeInterval = 20) async throws {
    let args = try literal(arguments)
    _ = try await evaluate("await chrome.\(method)(...\(args)); return null;",
      userGesture: userGesture, timeout: timeout)
  }

  private func invokeLoad(_ method: String, _ arguments: [Any]) async throws {
    let args = try literal(arguments)
    let response = try await evaluate("return await chrome.\(method)(...\(args));", userGesture: true, timeout: 120)
    if let error = response as? [String: Any], let message = error["error"] as? String, !message.isEmpty {
      throw ChromeExtensionError.loadFailed(message)
    }
  }

  private func evaluate(_ body: String, userGesture: Bool = false, timeout: TimeInterval = 20) async throws -> Any? {
    guard !isPrivate, !engine.isTerminating,
      engine.pages["extensions:\(profileID)"] != nil || engine.contexts.values.contains(where: { $0.isOpen && !$0.isClosing }) else {
      throw ChromeExtensionError.managementUnavailable
    }
    let identifier = "extensions:\(profileID)"
    let page = engine.pages[identifier] ?? engine.extensionsPage(profileID: profileID)
    let deadline = Date().addingTimeInterval(15)
    while page.browser?.id ?? -1 < 0 || page.isLoading || page.url == nil {
      try Task.checkCancellation()
      guard Date() < deadline, engine.pages[identifier] === page else { throw ChromeExtensionError.managementUnavailable }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard valid(page), let browser = page.browser else { throw ChromeExtensionError.managementUnavailable }
    let result = try await browser.devTools.evaluate("""
      (async () => {
        if (location.protocol !== 'chrome:' || location.hostname !== 'extensions' || !chrome.developerPrivate)
          throw new Error('The trusted extension manager is unavailable.');
        \(body)
      })()
      """, userGesture: userGesture, timeout: timeout)
    guard valid(page), engine.pages[identifier] === page, page.browser === browser else {
      throw ChromeExtensionError.managementUnavailable
    }
    return result
  }

  private func valid(_ page: ChromiumPage) -> Bool {
    page.profileID == profileID && !page.isPrivate && page.url?.scheme == "chrome" &&
      page.url?.host == "extensions" && page.url?.user == nil && page.url?.password == nil
  }
}
