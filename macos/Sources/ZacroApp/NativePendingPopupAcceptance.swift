import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Pauses actual Chrome-created popups before Core adoption. All windows,
/// documents, input receipts and sheet responses belong to this fixture.
@MainActor enum NativePendingPopupAcceptance {
  @MainActor private final class PreparationGate {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var released = false
    private(set) var popup: ChromiumPage?
    private(set) var arrivals = 0

    func wait(for page: ChromiumPage) async throws {
      if let popup, popup !== page { throw CancellationError() }
      popup = page; arrivals += 1
      let token = UUID()
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        if released { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
          else if released { continuation.resume() }
          else { waiters[token] = continuation }
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          self?.waiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
        }
      }
    }

    func release() {
      released = true
      let pending = Array(waiters.values); waiters.removeAll()
      for waiter in pending { waiter.resume() }
    }
  }

  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Pending popup acceptance requires the disposable loopback fixture.")
    }
    let manager = application.popupAdoptions
    let previousHook = manager.acceptanceBeforePreparation
    var activeGate: PreparationGate?
    var expectedOwnerID: String?
    var expectedSourceID: String?
    var owners: [BrowserWindowCoordinator] = []
    var gates: [PreparationGate] = []
    var closes: [Task<Bool, Never>] = []
    var unmodeledPages: [ChromiumPage] = []
    var recoverySheets: [(NSWindow, NSWindow)] = []
    var checks: [String] = []
    manager.acceptanceBeforePreparation = { popup in
      if let activeGate, popup.ownerWindowID == expectedOwnerID, popup.openerID == expectedSourceID {
        try await activeGate.wait(for: popup)
      } else if let previousHook { try await previousHook(popup) }
    }

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native pending-popup check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Pending popup acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw ShortcutError("Pending popup acceptance timed out: " + phase)
    }
    func newOwner() throws -> BrowserWindowCoordinator {
      originalOwner.windowContext.show()
      application.repository.focusWindow(originalOwner.windowContext.id)
      let before = Set(application.windows.keys)
      application.newWindow()
      let added = application.windows.values.filter {
        !before.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
      }
      guard added.count == 1, let owner = added.first else {
        throw ShortcutError("No exact pending-popup fixture owner.")
      }
      owners.append(owner)
      owner.actions.palette = false; owner.actions.library = nil
      return owner
    }
    func cleanup() async {
      activeGate = nil; expectedOwnerID = nil; expectedSourceID = nil
      for gate in gates { gate.release() }
      manager.acceptanceBeforePreparation = previousHook
      for (window, sheet) in recoverySheets where window.attachedSheet === sheet && sheet.sheetParent === window {
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
      }
      for owner in owners {
        let pages = Array(application.engine.pages.values.filter { $0.ownerWindowID == owner.windowContext.id })
        if let sheet = owner.window?.attachedSheet,
          pages.contains(where: { application.webDialogs.owns(sheet, page: $0) }) {
          owner.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        for page in pages {
          if let browser = page.browser, !browser.isClosed {
            _ = try? await browser.devTools.evaluate("window.onbeforeunload=null", timeout: 2)
          }
        }
      }
      for page in unmodeledPages where application.engine.pages[page.id] === page { page.close() }
      for page in unmodeledPages {
        try? await wait("cleanup exact fixture-only unmodeled document") {
          page.browser?.isClosed != false && application.engine.pages[page.id] !== page
        }
      }
      application.pageRetirements.refresh()
      for close in closes { _ = await close.value }
      for owner in owners where owner.windowContext.isOpen { _ = await owner.requestCloseWindow() }
      if originalOwner.windowContext.isOpen { originalOwner.windowContext.show() }
    }

    func pendingCase(leave: Bool) async throws {
      let owner = try newOwner(), ownerID = owner.windowContext.id
      let sourceURL = url.appendingPathComponent(leave ? "pending-popup-leave-source" : "pending-popup-stay-source")
      guard let sourceTab = owner.store.createTab(address: sourceURL.absoluteString) else {
        throw ShortcutError("No pending-popup source.")
      }
      let source = try await owner.ensurePageReady(sourceTab)
      try await application.navigation.waitForRestore(source)
      let sourceBrowser = try await source.ready()
      try await wait("loaded exact source") {
        source.browser === sourceBrowser && !source.isLoading && source.url == sourceURL
      }
      let gate = PreparationGate(); gates.append(gate)
      activeGate = gate; expectedOwnerID = ownerID; expectedSourceID = source.id
      let targetURL = url.appendingPathComponent("native-history-form")
      let literals = String(decoding: try JSONSerialization.data(withJSONObject: [
        targetURL.absoluteString, "zacro-pending-popup-" + UUID().uuidString,
      ]), as: UTF8.self)
      let opened = try await sourceBrowser.devTools.evaluate(
        "(()=>{const [url,name]=\(literals);globalThis.pendingPopupFixture=window.open(url,name);return !!globalThis.pendingPopupFixture;})()",
        userGesture: true) as? Bool
      try require(opened == true, leave ? "pendingLeaveUsesActualWindowOpen" : "pendingStayUsesActualWindowOpen")
      try await wait("actual popup reaches the pre-Core preparation gate") {
        guard let popup = gate.popup else { return false }
        return manager.isPending(popup) && popup.ownerWindowID == ownerID
          && popup.openerID == source.id && application.store.document(id: popup.id) == nil
      }
      guard let popup = gate.popup else { throw ShortcutError("The gated popup disappeared.") }
      let native = try await popup.ready(), originalID = popup.id, nativeID = native.id
      let profileID = popup.profileID
      try await wait("loaded pre-Core popup") {
        popup.browser === native && !popup.isLoading && popup.url == targetURL
      }
      for _ in 0..<3 {
        owner.layoutPages()
        _ = try await native.devTools.evaluate("document.readyState")
      }
      try require(manager.isPending(popup) && application.engine.pages[originalID] === popup
        && popup.browser === native && application.store.document(id: originalID) == nil
        && !application.pageRetirements.isBlocked(popup) && owner.window?.attachedSheet == nil,
        leave ? "pendingLeaveLayoutsKeepExactUnadoptedDocument" : "pendingStayLayoutsKeepExactUnadoptedDocument")

      func requirePendingIdentity() throws {
        guard manager.isPending(popup), application.engine.pages[originalID] === popup,
          popup.id == originalID, popup.browser === native, !native.isClosed,
          popup.profileID == profileID, popup.ownerWindowID == ownerID, popup.openerID == source.id,
          owner.windowContext.isOpen, !owner.windowContext.isClosing,
          application.store.document(id: originalID) == nil,
          owner.store.tab(sourceTab.id)?.windowID == ownerID else { throw CancellationError() }
      }
      let draft = leave ? "pending popup explicit Leave draft" : "pending popup preserved Stay draft"
      let draftLiteral = String(decoding: try JSONSerialization.data(withJSONObject: [draft]), as: UTF8.self)
      try requirePendingIdentity()
      popup.setCornerRadius(owner.store.state.settings.pageRadius)
      popup.show(frame: owner.actions.contentFrame)
      _ = try await native.devTools.evaluate("""
        (() => {
          const field=document.getElementById('retained');field.value=\(draftLiteral)[0];
          field.dispatchEvent(new Event('input',{bubbles:true}));
          field.dispatchEvent(new Event('change',{bubbles:true}));
          const button=document.createElement('button');button.id='pendingPopupActivate';button.textContent='Edit';
          button.style.cssText='position:fixed;left:20px;top:20px;width:160px;height:36px;z-index:99999';
          document.body.appendChild(button);globalThis.pendingPopupClick=null;globalThis.pendingPopupEvents=[];
          for(const type of ['pointerdown','mousedown','pointerup','mouseup','click']){
            document.addEventListener(type,event=>{
              if(globalThis.pendingPopupEvents.length<12)globalThis.pendingPopupEvents.push({
                type:event.type,trusted:event.isTrusted,button:event.button,target:event.target?.id??null,
                x:event.clientX,y:event.clientY
              });
            },true);
          }
          button.addEventListener('click',event=>{globalThis.pendingPopupClick={trusted:event.isTrusted,button:event.button};});
          window.onbeforeunload=event=>{event.preventDefault();event.returnValue='Unsaved popup draft';};
          return true;
        })()
        """)
      // This real document intentionally has no Core selection yet. Validate
      // its lease and native owner rather than changing the shared tab model.
      guard let inputView = native.nativeView, let inputWindow = inputView.window else {
        throw ShortcutError("The exact pending-popup native input target is missing.")
      }
      var receipt: [String: Any]?
      let stateExpression = """
        ({trusted:globalThis.pendingPopupClick?.trusted===true,primary:globalThis.pendingPopupClick?.button===0,
          sticky:navigator.userActivation.hasBeenActive,focused:document.hasFocus(),
          guarded:typeof window.onbeforeunload==='function',ready:document.readyState,
          viewport:[innerWidth,innerHeight],scale:devicePixelRatio,
          hit:document.elementFromPoint(60,36)?.id??null,
          button:!!document.getElementById('pendingPopupActivate'),events:globalThis.pendingPopupEvents??[]})
        """
      func logInput(_ phase: String) {
        let state: [String: Any] = ["phase": phase, "pageID": originalID,
          "nativeID": nativeID, "ownerID": ownerID, "appActive": NSApp.isActive,
          "keyWindow": NSApp.keyWindow?.windowNumber ?? -1, "nativeWindow": inputWindow.windowNumber,
          "nativeKey": inputWindow.isKeyWindow, "nativeVisible": inputWindow.isVisible,
          "nativeParent": inputWindow.parent?.windowNumber ?? -1,
          "nativeFrame": NSStringFromRect(inputWindow.frame),
          "nativeBounds": NSStringFromRect(inputView.bounds),
          "document": receipt ?? [:]]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
          fputs("Native pending-popup input: \(String(decoding: data, as: UTF8.self))\n", stderr)
        }
      }
      do {
        try requirePendingIdentity()
        popup.focus()
        var priorViewport: [Int]?, stableViewportReads = 0
        try await wait("exact pending-popup native and document focus") {
          try requirePendingIdentity()
          guard native.nativeView === inputView, inputView.window === inputWindow else { throw CancellationError() }
          receipt = try await native.devTools.evaluate(stateExpression) as? [String: Any]
          let viewport = receipt?["viewport"] as? [Int]
          if viewport == priorViewport { stableViewportReads += 1 }
          else { priorViewport = viewport; stableViewportReads = 1 }
          return NSApp.isActive && inputWindow.isVisible && inputWindow.isKeyWindow
            && NSApp.keyWindow === inputWindow && inputWindow.parent === owner.window
            && receipt?["focused"] as? Bool == true && receipt?["hit"] as? String == "pendingPopupActivate"
            && receipt?["button"] as? Bool == true && receipt?["guarded"] as? Bool == true
            && viewport?.count == 2 && (viewport?.first ?? 0) > 180 && (viewport?.last ?? 0) > 56
            && stableViewportReads >= 2
        }
        logInput("before-single-dispatch")
        for type in ["mousePressed", "mouseReleased"] {
          try requirePendingIdentity()
          guard native.nativeView === inputView, inputView.window === inputWindow,
            inputWindow.isVisible, inputWindow.isKeyWindow, NSApp.keyWindow === inputWindow else {
            throw ShortcutError("The exact pending-popup native input focus changed.")
          }
          _ = try await native.devTools.call("Input.dispatchMouseEvent", parameters: [
            "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
            "buttons": type == "mousePressed" ? 1 : 0,
          ])
        }
        try await wait("real pending-popup trusted click receipt") {
          try requirePendingIdentity()
          receipt = try await native.devTools.evaluate(stateExpression) as? [String: Any]
          return receipt?["trusted"] as? Bool == true && receipt?["primary"] as? Bool == true
            && receipt?["sticky"] as? Bool == true && receipt?["focused"] as? Bool == true
            && receipt?["guarded"] as? Bool == true
        }
      } catch {
        logInput("failed: " + error.localizedDescription)
        throw error
      }
      let receiptData = try JSONSerialization.data(withJSONObject: receipt ?? [:], options: [.sortedKeys])
      fputs("Native pending-popup activation: \(String(decoding: receiptData, as: UTF8.self))\n", stderr)
      try require(true, leave ? "pendingLeaveUsesTrustedPrimaryAndStickyActivation" : "pendingStayUsesTrustedPrimaryAndStickyActivation")
      let window = owner.windowContext.window
      func ownedSheet() -> NSWindow? {
        guard let sheet = window.attachedSheet,
          sheet.identifier?.rawValue.hasPrefix("ZacroWebDialog:beforeunload:") == true,
          application.webDialogs.owns(sheet, page: popup) else { return nil }
        return sheet
      }
      let close = Task { @MainActor in await owner.requestCloseWindow() }; closes.append(close)
      try await wait("normal window close negotiates the exact pending popup") { ownedSheet() != nil }
      try require(manager.isPending(popup) && popup.browser === native && !native.isClosed
        && application.store.document(id: originalID) == nil && NSApp.modalWindow == nil,
        leave ? "pendingLeaveNegotiatesExactOwnedNonblockingBeforeUnload" : "pendingStayNegotiatesExactOwnedNonblockingBeforeUnload")
      guard let sheet = ownedSheet() else { throw ShortcutError("The pending-popup beforeunload sheet disappeared.") }
      window.endSheet(sheet, returnCode: leave ? .alertFirstButtonReturn : .alertSecondButtonReturn)
      let accepted = await close.value
      if leave {
        try await wait("pending Leave drains native document and lease") {
          native.isClosed && application.engine.pages[originalID] == nil
            && manager.pendingCount(ownerID: ownerID) == 0 && !owner.windowContext.isOpen
        }
        try require(accepted, "pendingPopupExplicitLeaveClosesThroughNormalWindowClose")
      } else {
        try await wait("pending Stay resumes its exact pre-Core handoff") {
          owner.windowContext.isOpen && !owner.windowContext.isClosing
            && window.attachedSheet == nil && manager.isPending(popup) && gate.arrivals >= 2
        }
        let preserved = try await native.devTools.evaluate("document.getElementById('retained').value") as? String
        try require(!accepted && application.engine.pages[originalID] === popup && popup.browser === native
          && native.id == nativeID && !native.isClosed && preserved == draft
          && !application.pageRetirements.isBlocked(popup),
          "pendingPopupStayRetainsExactNativeDocumentDraftAndAdoptionLease")
        gate.release()
        try await wait("same popup completes its normal Core adoption") {
          application.store.document(id: popup.id)?.isClosed == false
            && application.engine.pages[popup.id] === popup && !manager.isPending(popup)
        }
        let adoptedDraft = try await native.devTools.evaluate("document.getElementById('retained').value") as? String
        try require(popup.browser === native && native.id == nativeID && adoptedDraft == draft
          && application.store.document(id: popup.id)?.openerTabID == sourceTab.id
          && manager.pendingCount(ownerID: ownerID) == 0 && !application.pageRetirements.isBlocked(popup),
          "pendingPopupAdoptionAfterStayPreservesRendererDraftAndOpener")
        _ = try await native.devTools.evaluate("window.onbeforeunload=null")
        try require(await owner.requestCloseWindow(), "pendingPopupAdoptionFixtureClosesNormally")
      }
      gate.release(); activeGate = nil; expectedOwnerID = nil; expectedSourceID = nil
    }

    do {
      try await pendingCase(leave: false)
      try await pendingCase(leave: true)
      let owner = try newOwner(), window = owner.windowContext.window
      let id = "unleased-popup-probe:" + UUID().uuidString
      let unknown = application.engine.page(id: id, profileID: owner.store.activeProfileID,
        isPrivate: false, url: url.appendingPathComponent("pending-popup-unknown"), ownerWindowID: owner.windowContext.id)
      unmodeledPages.append(unknown)
      let native = try await unknown.ready()
      try await wait("exact unleased native document") { !unknown.isLoading && unknown.url?.host == "127.0.0.1" }
      try require(!manager.isPending(unknown) && manager.pendingCount(ownerID: owner.windowContext.id) == 0,
        "unknownUnmodeledNativeDocumentCannotBorrowPopupAdoptionAuthority")
      owner.layoutPages()
      try await wait("ordinary unknown-document retirement remains blocked") {
        application.pageRetirements.isBlocked(unknown)
          && window.attachedSheet?.identifier?.rawValue.hasPrefix("ZacroRetirementRecovery:") == true
      }
      guard let recovery = window.attachedSheet else { throw ShortcutError("Missing owned unknown-document recovery sheet.") }
      recoverySheets.append((window, recovery))
      try require(!manager.isPending(unknown) && application.store.document(id: id) == nil
        && application.engine.pages[id] === unknown && unknown.browser === native && !native.isClosed,
        "unknownNativeDocumentStillUsesFailClosedRetirement")
      window.endSheet(recovery, returnCode: .alertFirstButtonReturn)
      try await wait("exact unknown-document recovery response drains") { window.attachedSheet == nil }
      unknown.close()
      try await wait("unguarded fixture-only unknown document closes normally") {
        native.isClosed && application.engine.pages[id] == nil
      }
      application.pageRetirements.refresh()
      let unknownOwnerClosed = await owner.requestCloseWindow()
      try require(!application.pageRetirements.isBlocked(unknown) && unknownOwnerClosed,
        "unknownNativeDocumentFixtureReleasesItsOwnRecoveryAndWindow")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }
}
