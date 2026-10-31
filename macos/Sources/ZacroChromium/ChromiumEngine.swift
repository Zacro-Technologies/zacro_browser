import AppKit
@_exported import CefKit
import CryptoKit
import Foundation

/// Owns the Chromium runtime and native Chrome-style window. Never uses Alloy.
@MainActor
public final class ChromiumEngine {
  public let dataDirectory: URL
  public private(set) var pages: [String: ChromiumPage] = [:]
  private var profiles: [String: CefProfile] = [:]
  private var host: CefChromeBrowser?
  public var window: NSWindow? { host?.nsWindow }
  public var onLayout: (() -> Void)?

  public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

  /// Call before NSApplication.shared or SwiftUI's App.main().
  public func start() throws {
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    var configuration = CefConfiguration()
    configuration.rootCachePath = dataDirectory.appendingPathComponent(
      "Chromium", isDirectory: true)
    configuration.noSandbox = false
    configuration.safeStorage = .keychain
    if CommandLine.arguments.contains("--engine-acceptance") {
      let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
      let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        .resolvingSymlinksInPath()
      guard
        let fixtureURL = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SMOKE_URL"].flatMap(
          URL.init(string:)),
        fixtureURL.scheme == "http", fixtureURL.host == "127.0.0.1",
        fixtureURL.user == nil, fixtureURL.password == nil,
        directory.deletingLastPathComponent() == temporary,
        directory.lastPathComponent.hasPrefix("zacro-native-acceptance-"),
        try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
      else {
        throw NSError(
          domain: "ZacroEngine", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Engine acceptance requires a fresh empty zacro-native-acceptance-* directory inside the system temporary directory."
          ])
      }
      configuration.safeStorage = .mockKeychain
    }
    configuration.persistSessionCookies = true
    configuration.defaultRuntimeStyle = .chrome
    configuration.logFile = dataDirectory.appendingPathComponent("chromium.log")
    try CefRuntime.shared.initialize(configuration: configuration)
    CefRuntime.shared.bridge.autoInjectsShim = false
    var options = CefChromeBrowserOptions()
    options.initialBounds = CGRect(x: 80, y: 80, width: 1280, height: 820)
    options.profile = .incognito()
    host = CefChromeBrowser.create(url: URL(string: "about:blank")!, options: options)
    host?.setPageVisible(false)
    host?.onLayout = { [weak self] in self?.onLayout?() }
    window?.title = "Zacro"
    window?.minSize = NSSize(width: 680, height: 480)
  }

  public func page(id: String, profileID: String, isPrivate: Bool, url: URL) -> ChromiumPage {
    if let page = pages[id] {
      precondition(
        page.profileID == profileID && page.isPrivate == isPrivate,
        "Cannot move a live page across profiles")
      return page
    }
    precondition(host != nil, "Start Chromium before creating pages")
    let key = (isPrivate ? "private:" : "persistent:") + profileID
    let profile: CefProfile
    if let existing = profiles[key] {
      profile = existing
    } else {
      let safeID = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }
        .joined()
      profile = isPrivate ? .incognito() : .persistent(name: safeID)
      profiles[key] = profile
    }
    let page = ChromiumPage(id: id, profileID: profileID, isPrivate: isPrivate)
    let chrome = host!.createPage(url: url, profile: profile, delegate: page)
    page.chrome = chrome
    page.onClosedInternal = { [weak self, weak page] in
      guard let self, let page else { return }
      if self.pages[id] === page { self.pages.removeValue(forKey: id) }
    }
    pages[id] = page
    return page
  }

  public func hideAll() { for page in pages.values { page.hide() } }
  public func close(id: String) { pages[id]?.close() }
  public func showWindow() { host?.show() }
  /// Chromium asks every document about unsaved changes before closing.
  public func closeWindow() { host?.close() }
}

/// One retained Chromium document, including its own back/forward and form state.
@MainActor
public final class ChromiumPage: CefBrowserDelegate, Identifiable {
  public let id: String
  public let profileID: String
  public let isPrivate: Bool
  fileprivate var chrome: CefChromeBrowser?
  fileprivate var onClosedInternal: (() -> Void)?
  public var browser: CefBrowser? { chrome?.browser }
  public var nativeWindow: NSWindow? { chrome?.nsWindow }
  public private(set) var title = ""
  public private(set) var url: URL?
  public private(set) var isLoading = false
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var progress = 0.0
  public private(set) var error: String?
  public private(set) var faviconURL: URL?
  public var onChange: (() -> Void)?
  public var onOpenURL: ((URL, Bool) -> Void)?
  public var onPeek: ((URL) -> Void)?
  public var onDownload: ((CefDownload) -> Void)?
  public var onClosed: (() -> Void)?

  fileprivate init(id: String, profileID: String, isPrivate: Bool) {
    self.id = id
    self.profileID = profileID
    self.isPrivate = isPrivate
  }
  public func load(_ url: URL) { browser?.load(url) }
  public func goBack() { browser?.goBack() }
  public func goForward() { browser?.goForward() }
  public func reload() { browser?.reload() }
  public func stop() { browser?.stopLoading() }
  public func close() { chrome?.close() }
  public func show(frame: CGRect) {
    chrome?.setPageFrame(frame)
    chrome?.setPageVisible(true)
  }
  public func hide() { chrome?.setPageVisible(false) }
  public func focus() {
    if let view = browser?.nativeView { view.window?.makeFirstResponder(view) }
  }
  public func find(_ text: String, forward: Bool = true) {
    browser?.find(text, forward: forward, matchCase: false)
  }
  public func zoom(by amount: Double) { if let browser { browser.zoomLevel += amount } }
  public func resetZoom() { browser?.zoomLevel = 0 }
  public func printPage() { browser?.executeJavaScript("window.print()") }
  public func showDevTools() { browser?.showDevTools() }
  @discardableResult public func showExtensionsMenu() -> Bool {
    browser?.executeChromeCommand(named: "IDC_EXTENSIONS_SUBMENU") ?? false
  }
  @discardableResult public func manageExtensions() -> Bool {
    browser?.executeChromeCommand(named: "IDC_MANAGE_EXTENSIONS") ?? false
  }

  public func browser(_ b: CefBrowser, didChangeTitle title: String) {
    self.title = title
    onChange?()
  }
  public func browser(_ b: CefBrowser, didChangeURL url: URL?) {
    self.url = url
    error = nil
    onChange?()
  }
  public func browser(
    _ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool
  ) {
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    onChange?()
  }
  public func browser(_ b: CefBrowser, didChangeProgress progress: Double) {
    self.progress = progress
    onChange?()
  }
  public func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {
    faviconURL = urls.first
    onChange?()
  }
  public func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String)
  {
    if code != -3 {
      error = errorText
      onChange?()
    }
  }
  public func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest)
    -> CefWindowOpenAction
  {
    guard let url = request.targetURL else { return .allowNativePopup }
    guard let onOpenURL else { return .openInCurrentBrowser }
    onOpenURL(url, request.disposition.prefersForeground)
    return .handled
  }
  public func browser(_ b: CefBrowser, didRequestNewTab url: URL?) -> Bool {
    guard let url, let onOpenURL else { return false }
    onOpenURL(url, true)
    return true
  }
  public func browserDidClose(_ b: CefBrowser) {
    chrome?.detachClosedPage()
    chrome = nil
    onClosedInternal?()
    onClosed?()
  }
  public func browser(
    _ b: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams
  ) {
    if params.linkURL != nil {
      menu.addItem(commandID: CefMenuModel.userCommandIDFirst, title: "Peek Link")
    }
  }
  public func browser(
    _ b: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams
  ) -> Bool {
    if commandID == CefMenuModel.userCommandIDFirst, let url = params.linkURL {
      onPeek?(url)
      return true
    }
    return false
  }
  public func browser(
    _ b: CefBrowser, decidePolicyForDownload download: CefDownload, suggestedName: String
  ) -> CefDownloadDecision {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = URL(fileURLWithPath: suggestedName).lastPathComponent
    guard panel.runModal() == .OK, let destination = panel.url else { return .deny }
    return .allow(destination: destination)
  }
  public func browser(_ b: CefBrowser, downloadDidProgress download: CefDownload) {
    onDownload?(download)
  }
  public func browser(_ b: CefBrowser, requestsPermission request: CefPermissionRequest)
    -> CefPermissionDecision
  {
    guard let origin = URL(string: request.origin),
      ["https", "http"].contains(origin.scheme?.lowercased() ?? ""),
      !request.kinds.contains(.other)
    else { return .deny }
    let names: [(CefPermissionKind, String)] = [
      (.camera, "camera"), (.microphone, "microphone"), (.geolocation, "location"),
      (.notifications, "notifications"), (.clipboard, "clipboard"), (.midi, "MIDI devices"),
      (.pointerLock, "pointer lock"), (.storageAccess, "site storage"), (.sensors, "sensors"),
      (.windowManagement, "window management"), (.downloads, "multiple downloads"),
    ]
    let requested = names.filter { request.kinds.contains($0.0) }.map { $0.1 }.joined(
      separator: ", ")
    let alert = NSAlert()
    alert.messageText = "Allow \(origin.host ?? request.origin) to use \(requested)?"
    alert.informativeText = "This decision applies to this request in the current browser profile."
    alert.addButton(withTitle: "Don’t Allow")
    alert.addButton(withTitle: "Allow")
    return alert.runModal() == .alertSecondButtonReturn ? .allow : .deny
  }
  public func browser(
    _ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int
  ) {
    error = "This page stopped responding. Reload to continue."
    onChange?()
  }
}

extension ChromiumEngine {
  /// Chromium's real extension manager, including unpacked install, enable,
  /// disable and removal. It runs inside the selected profile's Chrome runtime.
  public func extensionsPage(profileID: String) -> ChromiumPage {
    let page = page(
      id: "extensions:\(profileID)", profileID: profileID, isPrivate: false,
      url: URL(string: "chrome://extensions/")!)
    page.load(URL(string: "chrome://extensions/")!)
    return page
  }

  public func extensionStorePage(profileID: String) -> ChromiumPage {
    page(
      id: "extension-store:\(profileID)", profileID: profileID, isPrivate: false,
      url: URL(string: "https://chromewebstore.google.com/")!)
  }
}
