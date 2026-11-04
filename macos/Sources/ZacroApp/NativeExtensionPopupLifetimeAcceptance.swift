import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Exercises a real action popup across the exact owning Browser's close.
/// Owned sheet replies and Chromium input are internal fixture operations;
/// they do not claim physical desktop-input verification.
@MainActor enum NativeExtensionPopupLifetimeAcceptance {
  enum Mode: Equatable { case vetoAndAcceptedClose, acceptedCloseOnly }
  @MainActor private final class PopupRecord {
    weak var window: NSWindow?
    let windowNumber: Int
    var observedClose = false
    init(_ window: NSWindow) { self.window = window; windowNumber = window.windowNumber }
  }
  @MainActor private final class PopupEvents {
    weak var owner: NSWindow?
    var latest: PopupRecord?
    var records: [PopupRecord] = []
    private var observers: [NSObjectProtocol] = []

    init(owner: NSWindow) {
      self.owner = owner
      observers.append(NotificationCenter.default.addObserver(
        forName: NSNotification.Name("ZacroNativeExtensionPopupOpened"), object: nil, queue: nil
      ) { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, let popup = notification.object as? NSWindow,
            let reportedOwner = notification.userInfo?["ownerWindow"] as? NSWindow,
            reportedOwner === self.owner else { return }
          let record = PopupRecord(popup)
          self.latest = record
          self.records.append(record)
        }
      })
      observers.append(NotificationCenter.default.addObserver(
        forName: NSNotification.Name("ZacroNativeExtensionPopupClosed"), object: nil, queue: nil
      ) { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, let popup = notification.object as? NSWindow else { return }
          for record in self.records where record.window === popup { record.observedClose = true }
        }
      })
    }

    func stop() {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll()
    }
  }

  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator, unrelatedPage: ChromiumPage,
    manager: ChromeExtensionManager, identifier: String,
    worker: ChromeExtensionWorkerSession, mode: Mode = .vetoAndAcceptedClose) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Popup lifetime acceptance requires the disposable loopback fixture.")
    }
    var checks: [String] = []
    @MainActor func require(_ value: Bool, _ name: String) throws {
      fputs("Native popup lifetime check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Popup lifetime acceptance failed: " + name) }
      checks.append(mode == .acceptedCloseOnly ? "popup-close:" + name : name)
    }
    @MainActor func wait(_ phase: String, _ condition: @MainActor () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Popup lifetime acceptance timed out: " + phase)
    }
    @MainActor func popupContextIDs() async throws -> [String] {
      guard let ids = try await worker.evaluate(
        "chrome.runtime.getContexts({contextTypes:['POPUP']}).then(contexts=>contexts.map(context=>context.contextId))"
      ) as? [String] else { throw ShortcutError("Invalid actual popup context list") }
      return ids
    }
    let originalBrowser = try await unrelatedPage.ready()
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let previousWindows = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !previousWindows.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else {
      throw ShortcutError("No exact new popup lifetime owner")
    }
    owner.actions.palette = false
    owner.actions.library = nil
    let window = owner.windowContext.window
    let events = PopupEvents(owner: window)
    defer { events.stop() }
    let address = url.appendingPathComponent("native-history-form")
    var page: ChromiumPage?
    var browser: CefBrowser?
    var close: Task<Bool, Never>?
    @MainActor func ownedSheet() -> NSWindow? {
      guard let page, let sheet = window.attachedSheet,
        sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:beforeunload:") == true,
        application.webDialogs.owns(sheet, page: page) else { return nil }
      return sheet
    }
    do {
      guard let tab = owner.store.createTab(address: address.absoluteString) else {
        throw ShortcutError("No popup lifetime fixture tab")
      }
      let document = try await owner.ensurePageReady(tab)
      page = document
      try await application.navigation.waitForRestore(document)
      let native = try await document.ready()
      browser = native
      guard document.profileID == unrelatedPage.profileID else {
        throw ShortcutError("Popup lifetime fixture changed native profile")
      }
      try await wait("loaded form") {
        guard !document.isLoading, document.url == address else { return false }
        return try await native.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      if mode == .vetoAndAcceptedClose {
        var previousFrame: NSRect?
        var previousViewport: [Double]?
        var stableFrames = 0
        try await wait("stable visible document and viewport") {
          guard owner.activePage === document, application.engine.pages[tab.id] === document,
            document.browser === native, let view = native.nativeView, let nativeWindow = view.window,
            nativeWindow.isVisible, view.bounds.width > 180, view.bounds.height > 90,
            let viewport = try await native.devTools.evaluate("[innerWidth,innerHeight]") as? [Double],
            viewport.count == 2, viewport[0] > 180, viewport[1] > 90 else {
            stableFrames = 0; previousFrame = nil; previousViewport = nil; return false
          }
          let frame = nativeWindow.convertToScreen(view.convert(view.bounds, to: nil))
          stableFrames = previousFrame == frame && previousViewport == viewport ? stableFrames + 1 : 0
          previousFrame = frame; previousViewport = viewport
          return stableFrames >= 2
        }
        document.focus()
        try await wait("document focus") {
          try await native.devTools.evaluate("document.hasFocus()") as? Bool == true
        }
        _ = try await native.devTools.evaluate("""
          (() => {
            document.getElementById('retained').value='popup owner unsaved draft';
            const button=document.createElement('button');button.id='popupLifetimeActivate';button.textContent='Edit';
            button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
            document.body.appendChild(button);
            globalThis.popupLifetimeClick=null;
            button.addEventListener('click',event=>{globalThis.popupLifetimeClick={trusted:event.isTrusted,button:event.button};});
            window.onbeforeunload=event=>{event.preventDefault();event.returnValue='Unsaved draft';};
            return true;
          })()
          """)
        try await wait("actual trusted-input target") {
          try await native.devTools.evaluate("document.hasFocus() && document.elementFromPoint(60,36)?.id==='popupLifetimeActivate'") as? Bool == true
        }
        let activation = try await NativeDocumentActivationAcceptance.click(application: application,
          owner: owner, page: document, buttonID: "popupLifetimeActivate", label: "popup-owner-veto")
        fputs("Native popup lifetime activation: \(activation)\n", stderr)
        try require(["trusted", "primary", "sticky", "focused"].allSatisfy { activation[$0] as? Bool == true },
          "popupLifetimeUsesActualActivatedOwnerDocument")
      }
      try await application.extensionBrowser.prepareInitialNavigation(document)
      await application.extensionBrowser.waitForTopologyPublication()

      @MainActor func openPopup() async throws -> (contextID: String, record: PopupRecord) {
        owner.windowContext.show()
        _ = try await worker.evaluate("zacroAcceptance.configureAction('popup')")
        let anchor = window.convertToScreen(NSRect(x: 180, y: max(0, window.frame.height - 80), width: 20, height: 20))
        try await manager.performAction(identifier, on: document, anchorWindow: window, anchorRect: anchor)
        guard let result = try await worker.evaluate("zacroAcceptance.popupResult()") as? [String: Any],
          result["windowID"] as? Int == owner.windowContext.nativeID,
          result["tabIDs"] as? [Int] == document.reservedNativeTabID.map({ [$0] }),
          let contexts = result["contexts"] as? [[String: Any]], contexts.count == 1,
          let contextID = contexts[0]["contextId"] as? String else {
          throw ShortcutError("Popup lifetime received a foreign or incomplete native popup")
        }
        try await wait("actual visible popup with exact native owner") {
          guard let record = events.latest, let popup = record.window else { return false }
          return popup.isVisible && application.engine.extensionPopupOwner(popup) === owner.windowContext
            && !record.observedClose
        }
        guard let record = events.latest,
          try await popupContextIDs().contains(contextID) else {
          throw ShortcutError("Popup lifetime context disappeared before close")
        }
        return (contextID, record)
      }

      var firstContextID: String?
      if mode == .vetoAndAcceptedClose {
        let first = try await openPopup()
        firstContextID = first.contextID
        try require(first.record.window?.isVisible == true && !native.isClosed,
          "popupLifetimeOpensRealPopupBeforeOwnerVeto")
        close = Task { @MainActor in await owner.requestCloseWindow() }
        try await wait("exact owner beforeunload") { ownedSheet() != nil }
        try require(NSApp.modalWindow == nil && application.webDialogs.pendingRequestCount(for: document) == 1,
          "popupOwnerCloseUsesOriginalOwnedBeforeunload")
        guard let sheet = ownedSheet() else { throw ShortcutError("Popup lifetime veto sheet changed") }
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        let vetoed = await close!.value; close = nil
        try await wait("veto completion") { !owner.windowContext.isClosing && window.attachedSheet == nil }
        let draft = try await native.devTools.evaluate("document.getElementById('retained').value") as? String
        try require(!vetoed && owner.windowContext.isOpen && document.browser === native && !native.isClosed
          && application.engine.pages[tab.id] === document && document.ownerWindowID == owner.windowContext.id
          && owner.store.tab(tab.id)?.url == address.absoluteString && draft == "popup owner unsaved draft",
          "popupOwnerStayPreservesExactBrowserDocumentDraftAndModel")

        // Chromium may dismiss a popup when a genuine security sheet appears.
        // End that first popup if still live, then exercise a fresh popup through
        // approved Browser destruction without closing it ourselves.
        if try await popupContextIDs().contains(first.contextID) {
          _ = try await worker.evaluate("zacroAcceptance.closePopup()")
        }
        _ = try await native.devTools.evaluate("window.onbeforeunload=null")
      }
      let finalPopup = try await openPopup()
      try require((firstContextID.map { finalPopup.contextID != $0 } ?? true) && finalPopup.record.window?.isVisible == true
        && !finalPopup.record.observedClose && !native.isClosed,
        "popupLifetimeKeepsFreshPopupOpenIntoApprovedOwnerClose")
      let accepted = await owner.requestCloseWindow()
      try require(accepted && !owner.windowContext.isOpen && native.isClosed
        && application.engine.pages[tab.id] == nil,
        "popupLifetimeApprovedCloseDestroysExactOwningBrowser")
      try await wait("popup host and native anchor close after Browser acceptance") {
        if let popup = finalPopup.record.window,
          popup.isVisible || application.engine.extensionPopupOwner(popup) != nil { return false }
        let ids = try await popupContextIDs()
        return !ids.contains(finalPopup.contextID)
      }
      fputs("Native popup lifetime close window=\(finalPopup.record.windowNumber) notification=\(finalPopup.record.observedClose) windowAlive=\(finalPopup.record.window != nil)\n", stderr)
      // Closed notification is best-effort because its native NSWindow is weak.
      // Exact context disappearance plus the actual weak window's gone/hidden
      // state is the teardown evidence; do not extend NSWindow lifetime here.
      let remainingContexts = try await popupContextIDs()
      let contextGone = !remainingContexts.contains(finalPopup.contextID)
      let windowGone = finalPopup.record.window.map {
        !$0.isVisible && application.engine.extensionPopupOwner($0) == nil
      } ?? true
      try require(contextGone && windowGone,
        "popupLifetimeReleasesRealHostAndNativeAnchorWithoutLateBrowserUse")
      let otherValue = try await originalBrowser.devTools.evaluate("1+2") as? Int
      try require(otherValue == 3 && originalOwner.windowContext.isOpen
        && application.engine.pages[unrelatedPage.id] === unrelatedPage
        && unrelatedPage.browser === originalBrowser && !originalBrowser.isClosed,
        "popupOwnerClosurePreservesUnrelatedWindowAndRenderer")
      _ = try await worker.evaluate("zacroAcceptance.configureAction('record')")
      originalOwner.windowContext.show()
      return checks
    } catch {
      if let sheet = ownedSheet() { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
      _ = await close?.value
      if let browser, !browser.isClosed { _ = try? await browser.devTools.evaluate("window.onbeforeunload=null") }
      if owner.windowContext.isOpen { _ = await owner.requestCloseWindow() }
      _ = try? await worker.evaluate("zacroAcceptance.configureAction('record')")
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
      throw error
    }
  }
}
