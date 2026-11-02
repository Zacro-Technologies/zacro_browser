import Foundation

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
  public let userGesture: Bool
  public let incognito: Bool
}

public enum ChromeExtensionEvent {
  case registryChanged
  case installationChanged(extensionID: String, kind: String)
  case actionChanged(extensionID: String, nativeTabID: Int?)
  case storageChanged(extensionID: String, installationID: String, changes: [String: Any], origin: String)
  case hostRequest(ChromeExtensionHostRequest)
}

public enum ChromeExtensionError: Error, LocalizedError {
  case invalidIdentifier, managementUnavailable, invalidResponse
  case loadFailed(String)
  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier: return "The extension identifier is invalid."
    case .managementUnavailable: return "Chromium's extension manager is unavailable in this profile."
    case .invalidResponse: return "Chromium returned an invalid extension response."
    case .loadFailed(let message): return message
    }
  }
}

public struct ChromeLogicalTabRegistration: Sendable {
  public let logicalID: String
  public let windowID: Int
  public let index: Int
  public let active: Bool
  public let pinned: Bool
  public let discarded: Bool
  public let autoDiscardable: Bool
  public let splitViewID: Int
  public let openerLogicalID: String?
  public init(logicalID: String, windowID: Int, index: Int, active: Bool, pinned: Bool,
              discarded: Bool, autoDiscardable: Bool = true, splitViewID: Int = -1,
              openerLogicalID: String? = nil) {
    self.logicalID = logicalID; self.windowID = windowID; self.index = index
    self.active = active; self.pinned = pinned; self.discarded = discarded
    self.autoDiscardable = autoDiscardable; self.splitViewID = splitViewID
    self.openerLogicalID = openerLogicalID
  }
  fileprivate var parameters: [String: Any] {
    var value: [String: Any] = ["logicalID": logicalID, "windowID": windowID, "index": index,
      "active": active, "pinned": pinned, "discarded": discarded,
      "autoDiscardable": autoDiscardable, "splitViewID": splitViewID]
    if let openerLogicalID { value["openerLogicalID"] = openerLogicalID }
    return value
  }
}

public struct ChromeLogicalTabIdentity: Sendable {
  public let logicalID: String
  public let nativeID: Int
  public let materialized: Bool
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
  public let profileID: String
  private unowned let engine: ChromiumEngine
  private var eventToken: UUID?
  private weak var observedBrowser: CefBrowser?
  public init(engine: ChromiumEngine, profileID: String) {
    self.engine = engine; self.profileID = profileID
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
    await close()
    let browser = try await nativeBrowser()
    let token = try browser.devTools.observeEvents { method, params in
      switch method {
      case "Zacro.extensionRegistryChanged": callback(.registryChanged)
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
            userGesture: gesture, incognito: incognito)))
        }
      default: break
      }
    }
    do {
      _ = try await browser.devTools.call("Zacro.observeExtensions", parameters: ["enabled": true])
      eventToken = token; observedBrowser = browser
    } catch { browser.devTools.removeEventObserver(token); throw error }
  }

  public func close() async {
    guard let browser = observedBrowser else { eventToken = nil; return }
    if let eventToken { browser.devTools.removeEventObserver(eventToken) }
    eventToken = nil; observedBrowser = nil
    _ = try? await browser.devTools.call("Zacro.observeExtensions", parameters: ["enabled": false])
  }

  /// Rechecks the native caller and installation immediately before a host mutation.
  public func validateHostRequest(requestID: String) async throws {
    guard !requestID.isEmpty, requestID.count <= 128 else { throw ChromeExtensionError.invalidResponse }
    _ = try await nativeBrowser().devTools.call("Zacro.validateExtensionHostRequest", parameters: ["requestID": requestID])
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

  /// A single-use creation token binds the first SessionTabHelper identity.
  public func prepareTabMaterialization(_ logicalID: String) async throws -> ChromeTabMaterialization {
    guard !logicalID.isEmpty, logicalID.utf8.count <= 256 else { throw ChromeExtensionError.invalidResponse }
    let response = try await nativeBrowser().devTools.call("Zacro.prepareTabMaterialization", parameters: ["logicalID": logicalID])
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

  public func action(_ identifier: String, on page: ChromiumPage) async throws -> ChromeExtensionAction {
    try validate(identifier)
    guard page.profileID == profileID, engine.pages[page.id] === page else { throw ChromeExtensionError.managementUnavailable }
    let browser = try await page.ready()
    let result = try await browser.devTools.call("Zacro.getExtensionAction", parameters: ["id": identifier])
    guard engine.pages[page.id] === page, page.browser === browser else { throw ChromeExtensionError.managementUnavailable }
    return try JSONDecoder().decode(ChromeExtensionAction.self, from: JSONSerialization.data(withJSONObject: result))
  }

  /// Uses Chromium's verified Web Store installer and native permission UI.
  public func installWebStoreExtension(_ identifier: String) async throws {
    try validate(identifier)
    _ = try await nativeBrowser().devTools.call("Zacro.installWebStoreExtension", parameters: ["id": identifier], timeout: 120)
  }

  private func nativeBrowser() async throws -> CefBrowser {
    guard !engine.isWindowClosing, !engine.isTerminating,
      engine.isWindowOpen || engine.pages["extensions:\(profileID)"] != nil else { throw ChromeExtensionError.managementUnavailable }
    let page = engine.pages["extensions:\(profileID)"] ?? engine.extensionsPage(profileID: profileID)
    let browser = try await page.ready()
    guard engine.pages[page.id] === page, !page.isPrivate, page.profileID == profileID else { throw ChromeExtensionError.managementUnavailable }
    return browser
  }

  public func setPinned(_ identifier: String, pinned: Bool) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.updateExtensionConfiguration",
      [["extensionId": identifier, "pinnedToToolbar": pinned]])
  }

  /// Invokes Chrome's own toolbar action model. Chromium applies activeTab
  /// grants, dispatches onClicked, or opens the extension's popup/side panel.
  /// This must only be called in direct response to a native user action.
  public func performAction(_ identifier: String, on page: ChromiumPage) async throws {
    try validate(identifier)
    guard page.profileID == profileID, engine.pages[page.id] === page, let browser = page.browser,
      let extensionInfo = try await snapshot().extensions.first(where: { $0.id == identifier }), extensionInfo.isEnabled,
      !page.isPrivate || extensionInfo.incognitoAccess.isActive else { throw ChromeExtensionError.managementUnavailable }
    guard engine.pages[page.id] === page, page.browser === browser else { throw ChromeExtensionError.managementUnavailable }
    _ = try await browser.devTools.call("Zacro.performExtensionAction", parameters: ["id": identifier])
  }

  public func setEnabled(_ identifier: String, enabled: Bool) async throws {
    try validate(identifier)
    try await invoke("management.setEnabled", [identifier, enabled], userGesture: true)
  }

  /// Chromium presents its own uninstall confirmation and propagates Cancel.
  public func uninstall(_ identifier: String) async throws {
    try validate(identifier)
    try await invoke("management.uninstall", [identifier, ["showConfirmDialog": true]], userGesture: true, timeout: 120)
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

  /// Uses Chromium's native directory picker and extension validation. The
  /// caller should show the management page before invoking this user action.
  public func chooseUnpackedExtension() async throws {
    try await invokeLoad("developerPrivate.loadUnpacked", [["failQuietly": true, "populateError": true]])
  }

  public func showOptions(_ identifier: String) async throws {
    try validate(identifier)
    try await invoke("developerPrivate.showOptions", [identifier], userGesture: true)
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
    guard let encoded = value as? String, let comma = encoded.firstIndex(of: ","),
      let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])), data.count <= 262144
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
    guard !engine.isWindowClosing, !engine.isTerminating,
      engine.isWindowOpen || engine.pages["extensions:\(profileID)"] != nil else {
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
