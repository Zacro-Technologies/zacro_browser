import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Actual trusted input in a dedicated extension document, Chrome's original
/// optional-bookmarks permission warning, and its real Cancel action. The
/// fixture never grants a permission or reads browser/user data.
@MainActor enum NativeExtensionUIOwnerAcceptance {
  @MainActor private final class WindowReference {
    weak var value: NSWindow?
    init(_ value: NSWindow) { self.value = value }
  }
  @MainActor private final class PromptReadiness {
    var since: TimeInterval?
    var button: ObjectIdentifier?
    var frame: NSRect?
    var buttonFrame: NSRect?
    func reset() { since = nil; button = nil; frame = nil; buttonFrame = nil }
  }
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    triggerWorker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, owner.windowContext.isOpen,
      !owner.windowContext.isClosing, owner.store.state.activeProfile?.isPrivate == false,
      !page.isPrivate, owner.store.activeProfileID == page.profileID,
      owner.store.tab(page.id).map({ owner.store.profileID(for: $0) == page.profileID }) == true,
      application.engine.pages[page.id] === page, page.ownerWindowID == owner.windowContext.id,
      owner.windowContext.window.attachedSheet == nil, NSApp.modalWindow == nil,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Native extension prompt ownership requires the disposable loopback browser owner.")
    }
    let engine = application.engine, profile = page.profileID
    let manager = ChromeExtensionManager(engine: engine, profileID: profile)
    let directory = engine.dataDirectory.appendingPathComponent("AcceptancePromptOwner-" + UUID().uuidString)
    let originalWindows = Set(application.windows.keys)
    let originalSourceURL = owner.store.tab(page.id)?.url, sourceNativeID = page.reservedNativeTabID
    let cleanupNonce = UUID().uuidString.lowercased()
    var checks: [String] = []
    var identifier: String?
    var worker: ChromeExtensionWorkerSession?
    var document: ChromiumPage?
    var documentTabID: String?
    var isolated: BrowserWindowCoordinator?
    var ownedPrompt: WindowReference?
    var promptBaseline = Set<ObjectIdentifier>()
    var permissionStates = [[String: Any]]()
    var lastPermissionState: Data?
    var cleanupStarted = false, cleanupTriggered = false
    var cleanupStage = "setup"

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension UI owner check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native extension UI owner acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native extension UI owner acceptance timed out: " + phase)
    }
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func logCleanupFailure(_ error: Error) async {
      var value: [String: Any] = ["stage": cleanupStage, "profile": profile,
        "activeProfile": owner.store.activeProfileID, "owner": owner.windowContext.id,
        "primaryID": triggerWorker.extensionID, "targetID": identifier ?? "",
        "ownedCanonicalPath": String(directory.resolvingSymlinksInPath().standardizedFileURL.path.prefix(500)),
        "targetInspectorOpen": worker != nil, "cleanupTriggered": cleanupTriggered,
        "error": String(error.localizedDescription.prefix(1_000))]
      do {
        let snapshot = try await manager.snapshot()
        value["registry"] = snapshot.extensions.filter {
          $0.id == identifier || $0.id == triggerWorker.extensionID
        }.map { ["id": $0.id, "enabled": $0.isEnabled, "state": $0.state,
          "path": String(($0.path ?? "").prefix(500)),
          "canonicalPath": String(($0.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } ?? "").prefix(500))] as [String: Any] }
      } catch { value["registryError"] = String(error.localizedDescription.prefix(500)) }
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native permission cleanup \(text)\n", stderr) }
    }
    func ancestor(_ window: NSWindow, _ expected: NSWindow) -> Bool {
      var current: NSWindow? = window
      var seen = Set<ObjectIdentifier>()
      while let value = current, seen.insert(ObjectIdentifier(value)).inserted {
        if value === expected { return true }
        current = value.sheetParent ?? value.parent
      }
      return false
    }
    func object(_ value: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      guard value.responds(to: selector) else { return nil }
      return value.perform(selector)?.takeUnretainedValue()
    }
    func hasNativePromptParent(_ item: NSObject, prompt: NSWindow) -> Bool {
      var current: NSObject? = item, visited = Set<ObjectIdentifier>()
      while let value = current, visited.count < 64 {
        guard visited.insert(ObjectIdentifier(value)).inserted, !(value is NSWindow) else { return false }
        if let view = value as? NSView { return view.window === prompt }
        current = object(value, "accessibilityParent") as? NSObject
      }
      return false
    }
    func promptElements(_ prompt: NSWindow,
      excluded: ((NSObject, String, NSWindow?) -> Void)? = nil) -> [NSObject] {
      guard let root = prompt.contentView else { return [] }
      var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), result = [NSObject]()
      while let item = pending.popLast(), visited.count < 2_048 {
        guard visited.insert(ObjectIdentifier(item)).inserted, !(item is NSWindow) else { continue }
        if let view = item as? NSView {
          guard view.window === prompt else { excluded?(item, "foreign-native-view", view.window); continue }
          // A sheet content view may inherit its semantic AX window from the
          // source shell. Its actual native NSView.window is the stronger
          // ownership proof; its children still receive their own checks.
        } else if let window = object(item, "accessibilityWindow") as? NSWindow, window !== prompt {
          // Views' AX parent chain ends at its exact widget host NSView.
          // A sheet's semantic source-shell alias is valid only with this
          // separate live native ancestry proof, never by window/profile alone.
          guard window === owner.windowContext.window, hasNativePromptParent(item, prompt: prompt) else {
            excluded?(item, "foreign-ax-window", window); continue
          }
        }
        result.append(item)
        if let view = item as? NSView { pending.append(contentsOf: view.subviews) }
        pending.append(contentsOf: object(item, "accessibilityChildren") as? [NSObject] ?? [])
      }
      return result
    }
    func cancelButtons(_ prompt: NSWindow) -> [NSObject] {
      promptElements(prompt).filter { item in
        guard object(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
          [object(item, "accessibilityTitle"), object(item, "accessibilityLabel")]
            // InstallPromptData::PERMISSIONS_PROMPT labels its kCancel action
            // "Deny" (IDS_EXTENSION_PROMPT_PERMISSIONS_ABORT_BUTTON).
            .contains(where: { $0 as? String == "Deny" }),
          item is NSAccessibilityProtocol, item.responds(to: NSSelectorFromString("accessibilityPerformPress")),
          item.responds(to: NSSelectorFromString("isAccessibilityEnabled")),
          item.responds(to: NSSelectorFromString("accessibilityFrame")),
          (item.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue == true,
          let frame = (item.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
          frame.width > 0, frame.height > 0,
          prompt.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) else { return false }
        return true
      }
    }
    func logPrompt(_ phase: String, _ prompt: NSWindow) {
      var views = [NSView](), pending = prompt.contentView.map { [$0] } ?? []
      while let view = pending.popLast(), views.count < 48 {
        guard view.window === prompt else { continue }
        views.append(view); pending.append(contentsOf: view.subviews)
      }
      var excludedNodes = [[String: Any]]()
      let elements = promptElements(prompt) { item, reason, window in
        guard excludedNodes.count < 24 else { return }
        excludedNodes.append(["reason": reason, "class": String(describing: type(of: item)),
          "role": String((object(item, "accessibilityRole") as? String ?? "").prefix(160)),
          "title": String((object(item, "accessibilityTitle") as? String ?? "").prefix(240)),
          "window": window?.windowNumber ?? -1,
          "parentClass": (object(item, "accessibilityParent") as? NSObject).map { String(describing: type(of: $0)) } ?? ""])
      }
      let nodes = elements.prefix(48).map { item -> [String: Any] in
        ["class": String(describing: type(of: item)),
          "role": String((object(item, "accessibilityRole") as? String ?? "").prefix(160)),
          "title": String((object(item, "accessibilityTitle") as? String ?? "").prefix(240)),
          "label": String((object(item, "accessibilityLabel") as? String ?? "").prefix(240)),
          "identifier": String((object(item, "accessibilityIdentifier") as? String ?? "").prefix(160)),
          "actions": object(item, "accessibilityActionNames") as? [String] ?? [],
          "press": item.responds(to: NSSelectorFromString("accessibilityPerformPress")),
          "enabled": item.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
            ? (item.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? false : false,
          "frame": item.responds(to: NSSelectorFromString("accessibilityFrame"))
            ? String(describing: item.value(forKey: "accessibilityFrame")).prefix(180).description : "",
          "protocol": item is NSAccessibilityProtocol,
          "parentBoundToPrompt": hasNativePromptParent(item, prompt: prompt),
          "window": (object(item, "accessibilityWindow") as? NSWindow)?.windowNumber ?? -1]
      }
      let value: [String: Any] = ["phase": phase, "number": prompt.windowNumber,
        "class": String(describing: type(of: prompt)), "visible": prompt.isVisible,
        "key": prompt.isKeyWindow, "sourceShell": owner.windowContext.window.windowNumber,
        "parent": prompt.parent?.windowNumber ?? -1, "sheetParent": prompt.sheetParent?.windowNumber ?? -1,
        "exactOwner": ancestor(prompt, owner.windowContext.window),
        "newWindow": !promptBaseline.contains(ObjectIdentifier(prompt)),
        "windowCancel": prompt.accessibilityCancelButton() != nil,
        "cancelCandidates": cancelButtons(prompt).count, "nodes": nodes, "excludedNodes": excludedNodes,
        "nativeViews": views.map { String(describing: type(of: $0)) }]
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native permission prompt \(text)\n", stderr) }
    }
    func cancelOwnedPrompt() async throws {
      guard let prompt = ownedPrompt?.value, prompt.isVisible,
        ancestor(prompt, owner.windowContext.window),
        !promptBaseline.contains(ObjectIdentifier(prompt)) else {
        throw ShortcutError("The exact owned native permission warning lost its original owner.")
      }
      if prompt.accessibilityCancelButton() == nil { logPrompt("window-cancel-unavailable", prompt) }
      let readiness = PromptReadiness()
      // Pinned Views metrics_mac.cc uses a fixed 500ms activation cooldown.
      // Respect that and the actual platform preference, plus one poll margin.
      let cooldown = max(0.5, NSEvent.doubleClickInterval) + 0.03
      var observations: [NSObjectProtocol] = []
      for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        NSWindow.didChangeOcclusionStateNotification] {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: prompt, queue: .main) { _ in
          MainActor.assumeIsolated { readiness.reset() }
        })
      }
      for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { _ in
          MainActor.assumeIsolated { readiness.reset() }
        })
      }
      defer { observations.forEach { NotificationCenter.default.removeObserver($0) } }
      do {
        try await wait("exact owned permission Deny readiness after native input protection") {
          guard ownedPrompt?.value === prompt, prompt.isVisible,
            ancestor(prompt, owner.windowContext.window) else { throw CancellationError() }
          let buttons = cancelButtons(prompt)
          guard buttons.count <= 1 else { throw ShortcutError("The exact permission warning has ambiguous Cancel actions.") }
          guard NSApp.isActive, prompt.isKeyWindow, NSApp.keyWindow === prompt, !prompt.isMiniaturized,
            let button = buttons.first,
            let buttonFrame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
            readiness.reset(); return false
          }
          let now = ProcessInfo.processInfo.systemUptime
          if readiness.button != ObjectIdentifier(button) || readiness.frame != prompt.frame
            || readiness.buttonFrame != buttonFrame || readiness.since == nil {
            readiness.button = ObjectIdentifier(button); readiness.frame = prompt.frame
            readiness.buttonFrame = buttonFrame; readiness.since = now
            return false
          }
          return readiness.since.map { now - $0 >= cooldown } == true
        }
      } catch { logPrompt("cancel-action-unavailable", prompt); throw error }
      // Chrome's Views buttons implement the complete NSAccessibility protocol,
      // rather than the narrower NSAccessibilityButton role protocol. Select
      // only the live exact-owned semantic Cancel ("Deny") and its real AXPress.
      let buttons = cancelButtons(prompt)
      let buttonFrame = buttons.first.flatMap { ($0.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
      guard ownedPrompt?.value === prompt, prompt.isVisible,
        ancestor(prompt, owner.windowContext.window), NSApp.isActive,
        prompt.isKeyWindow, NSApp.keyWindow === prompt, !prompt.isMiniaturized, buttons.count == 1,
        readiness.frame == prompt.frame, readiness.buttonFrame == buttonFrame,
        buttons.first.map(ObjectIdentifier.init) == readiness.button,
        readiness.since.map({ ProcessInfo.processInfo.systemUptime - $0 >= cooldown }) == true,
        let button = buttons.first as? NSAccessibilityProtocol, button.accessibilityPerformPress() else {
        logPrompt("cancel-action-rejected", prompt)
        throw ShortcutError("The exact owned native permission warning has no real Cancel action.")
      }
    }
    func state() async throws -> [String: Any] {
      guard let document, let browser = document.browser,
        engine.pages[document.id] === document, document.ownerWindowID == owner.windowContext.id,
        let identifier, document.url?.absoluteString == "chrome-extension://" + identifier + "/request.html",
        let value = try await browser.devTools.evaluate("globalThis.zacroPermissionOwnerState") as? [String: Any] else {
        throw ShortcutError("The exact extension permission document changed.")
      }
      return value
    }
    func promptStatus() -> [String: Any] {
      guard let prompt = ownedPrompt?.value else {
        return ["released": true, "sourceSheet": owner.windowContext.window.attachedSheet?.windowNumber ?? -1,
          "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]
      }
      return ["released": false, "number": prompt.windowNumber, "visible": prompt.isVisible,
        "key": prompt.isKeyWindow, "parent": prompt.parent?.windowNumber ?? -1,
        "sheetParent": prompt.sheetParent?.windowNumber ?? -1,
        "exactOwner": ancestor(prompt, owner.windowContext.window),
        "sourceSheet": owner.windowContext.window.attachedSheet?.windowNumber ?? -1,
        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]
    }
    func logPermissionStates(_ phase: String) {
      let value: [String: Any] = ["phase": phase, "states": permissionStates, "prompt": promptStatus()]
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native permission callback \(text)\n", stderr) }
    }
    func click() async throws {
      guard let document, let browser = document.browser, !browser.isClosed else { throw ShortcutError("The native permission document closed.") }
      _ = try await browser.devTools.evaluate("globalThis.zacroPermissionOwnerState={phase:'ready'}; true")
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": 60, "y": 36, "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0])
      }
      try await wait("actual trusted native input reaches extension request") {
        let value = try await state()
        return value["trusted"] as? Bool == true && value["userActivation"] as? Bool == true
      }
    }
    func cleanup() async throws {
      guard !cleanupStarted else { return }; cleanupStarted = true
      var failure: Error?
      if let prompt = ownedPrompt?.value, prompt.isVisible {
        do { try await cancelOwnedPrompt() } catch { failure = error }
      }
      owner.windowContext.show()
      if let documentTabID, owner.store.tab(documentTabID)?.isClosed == false,
        !(await application.extensionBrowser.closeTab(documentTabID)) {
        failure = failure ?? ShortcutError("The owned native permission document refused closure.")
      }
      // Complete inspection before independently revoking the target. A timer
      // inside its own inspector can uninstall it before that inspector's
      // mandatory native postvalidation finishes on a busy application.
      await worker?.close(); worker = nil
      if let identifier {
        do {
          cleanupStage = "owned-target-registry"
          let installed = try await manager.snapshot().extensions.first { $0.id == identifier }
          if let installed {
            guard identifier != triggerWorker.extensionID, installed.isEnabled,
              installed.path.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path }) == true else {
              throw ShortcutError("The exact owned permission cleanup installation changed.")
            }
            cleanupStage = "fresh-target-inspector"
            let inspector = try await manager.workerSession(identifier)
            do {
              let result = try await inspector.evaluate("""
                (async()=>{const result=await chrome.runtime.setUninstallURL('');
                  return {configured:true,identifier:chrome.runtime.id,originalVoidResult:result===undefined};})()
                """, timeout: 10) as? [String: Any]
              guard result?["configured"] as? Bool == true, result?["identifier"] as? String == identifier,
                result?["originalVoidResult"] as? Bool == true else {
                throw ShortcutError("The exact owned permission cleanup could not clear its original uninstall URL.")
              }
            } catch { await inspector.close(); throw error }
            await inspector.close()
            cleanupStage = "stable-primary-original-message"
            guard !cleanupTriggered else { throw ShortcutError("The owned permission cleanup was already dispatched.") }
            cleanupTriggered = true
            let dispatch = try await triggerWorker.evaluate("""
              (async()=>await chrome.runtime.sendMessage(\(try literal(identifier)),
                {kind:'zacro-owned-permission-uninstall',nonce:\(try literal(cleanupNonce))}))()
              """, timeout: 10) as? [String: Any]
            guard dispatch?["accepted"] as? Bool == true, dispatch?["identifier"] as? String == identifier,
              dispatch?["nonce"] as? String == cleanupNonce else {
              throw ShortcutError("The stable original permission cleanup message did not reach its exact target.")
            }
            cleanupStage = "actual-owned-native-removal"
            try await wait("actual owned permission fixture uninstall") {
              try await !manager.snapshot().extensions.contains { $0.id == identifier }
            }
          }
          guard try await !manager.snapshot().extensions.contains(where: { $0.id == identifier }) else {
            throw ShortcutError("The exact permission fixture remains installed after cleanup.")
          }
          try FileManager.default.removeItem(at: directory)
          try require(true, "permissionCleanupUsesStablePeerAndOriginalNativeRemoval")
        } catch { failure = failure ?? error; await logCleanupFailure(error) }
      } else if identifier == nil { try? FileManager.default.removeItem(at: directory) }
      if let isolated, isolated.windowContext.isOpen, !(await isolated.requestCloseWindow()) {
        failure = failure ?? ShortcutError("The isolated permission owner did not accept normal closure.")
      }
      owner.store.selectTab(id: page.id); owner.windowContext.show()
      application.repository.focusWindow(owner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      do {
        try await wait("exact original prompt fixture source restoration") {
          engine.pages[page.id] === page && page.reservedNativeTabID == sourceNativeID
            && owner.store.tab(page.id)?.url == originalSourceURL && page.url?.absoluteString == originalSourceURL
            && !page.isLoading && page.documentError == nil
        }
      } catch { failure = failure ?? error }
      if let failure { throw failure }
    }

    do {
      let primary = try await triggerWorker.evaluate("({id:chrome.runtime.id,incognito:chrome.extension.inIncognitoContext})", timeout: 10) as? [String: Any]
      guard primary?["id"] as? String == triggerWorker.extensionID, primary?["incognito"] as? Bool == false,
        try await manager.snapshot().extensions.contains(where: { $0.id == triggerWorker.extensionID && $0.isEnabled }) else {
        throw ShortcutError("The stable permission cleanup trigger is not installed in the exact public source profile.")
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let manifest: [String: Any] = ["manifest_version": 3, "name": "Zacro owned permission warning fixture",
        "version": "1.0", "optional_permissions": ["bookmarks"], "background": ["service_worker": "worker.js"],
        "externally_connectable": ["ids": [triggerWorker.extensionID]]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
      let cleanupScript = """
        let consumed=false;
        chrome.runtime.onInstalled.addListener(()=>{});
        chrome.runtime.onMessageExternal.addListener((message,sender,sendResponse)=>{
          if(consumed||sender.id!==\(try literal(triggerWorker.extensionID))||
            message?.kind!=='zacro-owned-permission-uninstall'||message.nonce!==\(try literal(cleanupNonce)))return false;
          consumed=true;sendResponse({accepted:true,identifier:chrome.runtime.id,nonce:\(try literal(cleanupNonce))});
          void chrome.management.uninstallSelf({showConfirmDialog:false});return false;
        });
        """
      try Data(cleanupScript.utf8).write(to: directory.appendingPathComponent("worker.js"), options: .atomic)
      try Data("<!doctype html><meta charset=utf-8><title>Owned permission document</title><style>body{margin:0}button{position:absolute;left:20px;top:16px;width:120px;height:40px}</style><button id=request>Request</button><script src=request.js></script>".utf8)
        .write(to: directory.appendingPathComponent("request.html"), options: .atomic)
      let script = """
        globalThis.zacroPermissionOwnerState={phase:'ready'};
        document.getElementById('request').addEventListener('click',async event=>{
          const state={phase:'requesting',trusted:event.isTrusted,userActivation:navigator.userActivation.isActive};
          globalThis.zacroPermissionOwnerState=state;
          try { state.result=await chrome.permissions.request({permissions:['bookmarks']});state.phase='resolved'; }
          catch(error){state.error=String(error);state.phase='rejected';}
          state.granted=await chrome.permissions.contains({permissions:['bookmarks']});
        });
        """
      try Data(script.utf8).write(to: directory.appendingPathComponent("request.js"), options: .atomic)
      try await manager.setDeveloperMode(true)
      let id = try await manager.loadUnpackedExtension(at: directory); identifier = id
      let session = try await manager.workerSession(id); worker = session
      let address = "chrome-extension://" + id + "/request.html"
      let addressJSON = String(decoding: try JSONSerialization.data(withJSONObject: address, options: [.fragmentsAllowed]), as: UTF8.self)
      _ = try await session.evaluate("chrome.tabs.create({url:\(addressJSON),active:true})")
      try await wait("actual Core/native extension permission document") {
        guard let tab = owner.store.state.tabs.first(where: { $0.url == address && !$0.isClosed }),
          let native = engine.pages[tab.id], native.url?.absoluteString == address,
          !native.isLoading, native.documentError == nil else { return false }
        documentTabID = tab.id; document = native; return true
      }
      owner.windowContext.show()
      application.repository.focusWindow(owner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()

      application.newWindow()
      guard let other = application.windows.values.first(where: { !originalWindows.contains($0.windowContext.id) && $0.windowContext.isOpen }) else {
        throw ShortcutError("No exact isolated permission fixture owner.")
      }
      isolated = other; other.actions.palette = false
      let foreign = try other.store.createProfileDurably(name: "Permission prompt isolation fixture")
      guard foreign.id != profile,
        let foreignTab = other.store.createTab(address: url.appendingPathComponent("permission-foreign-owner").absoluteString) else {
        throw ShortcutError("The isolated permission profile did not materialize.")
      }
      let foreignPage = try await other.ensurePageReady(foreignTab)
      try await application.navigation.waitForRestore(foreignPage)
      other.windowContext.show(); application.repository.focusWindow(other.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
      let beforeWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
      promptBaseline = beforeWindows
      try await click()
      try await wait("actual native optional permission warning in exact source owner") {
        let candidates = NSApp.windows.filter { $0.isVisible && !beforeWindows.contains(ObjectIdentifier($0)) && ancestor($0, owner.windowContext.window) }
        guard candidates.count == 1, let prompt = candidates.first else { return false }
        ownedPrompt = WindowReference(prompt); return true
      }
      if let prompt = ownedPrompt?.value {
        fputs("Native permission fixture prompt=\(prompt.windowNumber) sourceShell=\(owner.windowContext.window.windowNumber) foreignShell=\(other.windowContext.window.windowNumber) cancelAvailable=\(prompt.accessibilityCancelButton() != nil)\n", stderr)
      }
      try require(ownedPrompt?.value.map { ancestor($0, owner.windowContext.window) && !ancestor($0, other.windowContext.window) } == true,
        "permissionWarningUsesExactSourceProfileShellDespiteForeignFocus")
      try await cancelOwnedPrompt()
      logPermissionStates("real-deny-press-dispatched")
      try await wait("original native permission callback resolves false after real Cancel") {
        let value = try await state()
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if encoded != lastPermissionState {
          lastPermissionState = encoded
          permissionStates.append(value)
          permissionStates = Array(permissionStates.suffix(8))
        }
        return value["phase"] as? String == "resolved" && value["result"] as? Bool == false && value["granted"] as? Bool == false
      }
      logPermissionStates("real-deny-callback-resolved")
      try require(true, "permissionRealCancelReturnsFalseAndGrantsNoBookmarksPermission")
      ownedPrompt = nil

      owner.windowContext.window.orderOut(nil)
      let beforeNoOwner = Set(NSApp.windows.map(ObjectIdentifier.init))
      try await click()
      try await wait("original Chrome missing-owner error") {
        let value = try await state()
        return value["phase"] as? String == "rejected" && value["granted"] as? Bool == false
          && (value["error"] as? String ?? "").contains("Could not find an active window")
      }
      try require(!NSApp.windows.contains { $0.isVisible && !beforeNoOwner.contains(ObjectIdentifier($0)) },
        "permissionNoEligibleShellRejectsWithoutHiddenOrCrossProfilePrompt")
      owner.windowContext.show()
      try await cleanup()
      return checks
    } catch {
      let failure = error
      logPermissionStates("operation-failed-before-cleanup")
      if let prompt = ownedPrompt?.value { logPrompt("operation-failed-before-cleanup", prompt) }
      let task = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native permission fixture retained owned cleanup: \(error.localizedDescription)\n", stderr) }
      }
      await task.value
      throw failure
    }
  }
}
