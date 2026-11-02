import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Consumes genuine tabCapture MediaStreams inside a disposable installed
/// extension. Pixels stay in its owned decoder; this never captures the desktop.
@MainActor
enum NativeTabCaptureAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      let fixture = ProcessInfo.processInfo.environment["ZACRO_NATIVE_EXTENSION_FIXTURE"] else {
      throw ShortcutError("Native tab capture requires the custom runtime and disposable loopback fixture.")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native tab capture check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native tab capture acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Native tab capture acceptance timed out: " + name)
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    application.newWindow()
    guard let owner = application.focusedCoordinator, owner !== originalOwner,
      owner.store.state.activeProfile?.isPrivate == false else {
      throw ShortcutError("No public tab capture fixture window")
    }
    owner.actions.palette = false
    let manager = ChromeExtensionManager(engine: application.engine, profileID: owner.store.activeProfileID)
    var worker: ChromeExtensionWorkerSession?
    var additionalOwner: BrowserWindowCoordinator?
    do {
      func makePage(_ suffix: String, in window: BrowserWindowCoordinator) async throws -> ChromiumPage {
        guard let tab = window.store.createTab(address: url.appendingPathComponent(suffix).absoluteString) else {
          throw ShortcutError("No owned tab capture page")
        }
        let page = try await window.ensurePageReady(tab)
        try await application.navigation.waitForRestore(page)
        try await wait("capture source loaded") {
          !page.isLoading && page.documentError == nil && page.url == url.appendingPathComponent(suffix)
        }
        try await application.extensionBrowser.prepareInitialNavigation(page)
        return page
      }
      let first = try await makePage("capture-first", in: owner)
      let second = try await makePage("capture-second", in: owner)
      let copy = application.engine.dataDirectory.appendingPathComponent("AcceptanceTabCapture-" + UUID().uuidString)
      let source = URL(fileURLWithPath: fixture).deletingLastPathComponent().appendingPathComponent("native-tab-capture")
      try FileManager.default.copyItem(at: source, to: copy)
      try await manager.setDeveloperMode(true)
      let identifier = try await manager.loadUnpackedExtension(at: copy)
      let session = try await manager.workerSession(identifier)
      worker = session
      _ = try await session.evaluate("zacroTabCaptureFixture.setup(\(owner.windowContext.nativeID))", timeout: 30)

      func nativeID(_ page: ChromiumPage) throws -> Int {
        guard let id = page.reservedNativeTabID else { throw ShortcutError("Missing actual capture tab identity") }
        return id
      }
      func select(_ page: ChromiumPage, in window: BrowserWindowCoordinator) async throws {
        try window.activateExtensionTab(page.id)
        window.windowContext.show()
        application.repository.focusWindow(window.windowContext.id)
        window.layoutPages()
        try await application.extensionBrowser.prepareInitialNavigation(page)
        await application.extensionBrowser.waitForTopologyPublication()
        try await wait("capture target is active and visible") {
          window.activePage === page && page.nativeWindow?.isVisible == true && !page.isLoading
        }
      }
      func paint(_ page: ChromiumPage, rgb: [Int]) async throws {
        _ = try await session.evaluate("zacroTabCaptureFixture.paint(\(try nativeID(page)),\(rgb))")
      }
      func grant(_ page: ChromiumPage, in window: BrowserWindowCoordinator) async throws {
        try await select(page, in: window)
        try await manager.performAction(identifier, on: page, anchorWindow: window.windowContext.window)
        try await wait("real native action grants exact capture target") {
          guard let action = try await session.evaluate("zacroTabCaptureFixture.actions.at(-1)") as? [String: Any] else { return false }
          return action["id"] as? Int == page.reservedNativeTabID
            && action["windowId"] as? Int == window.windowContext.nativeID
        }
      }
      func capture(_ page: ChromiumPage, rgb: [Int], name: String,
        explicit: Bool = false, legacy: Bool = false) async throws {
        let options: [String: Any] = ["expectedTabID": try nativeID(page), "expectedRGB": rgb,
          "explicit": explicit, "legacy": legacy]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
        guard let result = try await session.evaluate("zacroTabCaptureFixture.capture(\(json))", timeout: 30) as? [String: Any],
          let colors = result["rgb"] as? [Int], let frames = result["frames"] as? Int,
          let events = result["events"] as? [[String: Any]] else { throw ShortcutError("Invalid native capture result") }
        let matchesColor = colors.count == 3 && zip(colors, rgb).allSatisfy { abs($0.0 - $0.1) < 24 }
        let becameActive = events.contains { $0["status"] as? String == "active" && $0["tabId"] as? Int == page.reservedNativeTabID }
        let stopped = events.contains { $0["status"] as? String == "stopped" && $0["tabId"] as? Int == page.reservedNativeTabID }
        try require(result["target"] as? Int == page.reservedNativeTabID && frames >= 2
          && matchesColor && becameActive && stopped, name)
      }

      let red = [214, 43, 62], blue = [34, 91, 221], yellow = [229, 183, 36], green = [42, 184, 83]
      try await select(first, in: owner)
      try await paint(first, rgb: red)
      try await paint(second, rgb: blue)
      let denied = try await session.evaluate("zacroTabCaptureFixture.expectDenied(\(try nativeID(first)))") as? [String: Any]
      try require(denied?["denied"] as? Bool == true, "tabCaptureHostPermissionDoesNotReplaceNativeUserGrant")
      try await grant(first, in: owner)
      try await capture(first, rgb: red, name: "tabCaptureDefaultStreamDecodesActualSelectedDocument")
      try await capture(first, rgb: red, name: "tabCaptureLegacyExtensionDocumentUsesLogicalOwner", legacy: true)

      try await select(second, in: owner)
      try await capture(first, rgb: red, name: "tabCaptureExplicitBackgroundTargetKeepsItsNativeIdentity", explicit: true)
      owner.store.setSplit(left: first.id, right: second.id)
      try await grant(second, in: owner)
      try await capture(second, rgb: blue, name: "tabCaptureFocusedSplitPaneIsTheActualVideoSource")
      owner.store.unsplit(tabID: second.id)

      owner.store.setPeek(tabID: second.id, address: url.appendingPathComponent("capture-peek").absoluteString)
      guard let previewDocument = owner.store.tab(second.id)?.peekDocument else { throw ShortcutError("Missing capture Peek") }
      let preview = try await owner.ensurePageReady(previewDocument)
      try await application.navigation.waitForRestore(preview)
      try await wait("capture preview loaded") { !preview.isLoading && preview.documentError == nil }
      try await application.extensionBrowser.prepareInitialNavigation(preview)
      await application.extensionBrowser.waitForTopologyPublication()
      try await paint(preview, rgb: yellow)
      try await grant(preview, in: owner)
      try await capture(preview, rgb: yellow, name: "tabCapturePreviewUsesItsOwnDocumentRatherThanSource")
      try require(await owner.requestCloseTab(preview.id), "tabCapturePreviewClosesAfterNativeTracksStop")

      application.newWindow()
      guard let other = application.focusedCoordinator, other !== owner,
        other.store.activeProfileID == owner.store.activeProfileID else { throw ShortcutError("No second capture window") }
      additionalOwner = other
      other.actions.palette = false
      let otherPage = try await makePage("capture-other-window", in: other)
      try await paint(otherPage, rgb: green)
      try await grant(otherPage, in: other)
      try await capture(otherPage, rgb: green, name: "tabCaptureDefaultFollowsFocusedLogicalWindow")

      _ = try await session.evaluate("zacroTabCaptureFixture.cleanup()", timeout: 15)
      await session.close(); worker = nil
      let otherClosed = await other.requestCloseWindow()
      let ownerClosed = await owner.requestCloseWindow()
      try require(otherClosed && ownerClosed, "tabCaptureOwnedConsumersAndWindowsCloseCleanly")
      originalOwner.windowContext.show()
      return checks
    } catch {
      if let worker {
        _ = try? await worker.evaluate("zacroTabCaptureFixture.cleanup()", timeout: 10)
        await worker.close()
      }
      if let additionalOwner { _ = await additionalOwner.requestCloseWindow() }
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      throw error
    }
  }
}
