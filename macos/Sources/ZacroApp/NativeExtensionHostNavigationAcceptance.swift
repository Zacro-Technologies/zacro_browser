import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Genuine DOM producers in Chrome's real POPUP/SIDE_PANEL hosts. Target
/// attachment only inspects and dispatches a single native Chromium input pair;
/// no Runtime userGesture flag or replacement window.open implementation is used.
@MainActor enum NativeExtensionHostNavigationAcceptance {
  private struct Host {
    let browser: CefBrowser
    let parentSession: String
    let target: String
    let session: String
    let context: String
    let address: String
    let role: String
    let instance: String
  }

  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    triggerWorker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, CefAuxiliaryAdmissionLease.isSupported,
      owner.windowContext.isOpen, !owner.windowContext.isClosing, !page.isPrivate,
      application.engine.pages[page.id] === page, page.ownerWindowID == owner.windowContext.id,
      owner.store.activeProfileID == page.profileID,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil else {
      throw ShortcutError("Extension-host navigation requires the fresh custom-runtime loopback owner.")
    }
    let engine = application.engine, profile = page.profileID
    let originalNative = try await page.ready()
    let originalAddress = owner.store.tab(page.id)?.url
    let originalNativeID = page.reservedNativeTabID
    let originalTabs = Set(application.store.state.tabs.map(\.id))
    let originalWindows = Set(application.windows.keys)
    let originalAuxiliary = Set(CefRuntime.shared.auxiliaryBrowsers.map(\.id))
    let directory = engine.dataDirectory.appendingPathComponent("AcceptanceExtensionHost-" + UUID().uuidString)
    let cleanupNonce = UUID().uuidString.lowercased()
    let manager = ChromeExtensionManager(engine: engine, profileID: profile)
    var identifier: String?
    var worker: ChromeExtensionWorkerSession?
    var attachments: [(browser: CefBrowser, parent: String, session: String)] = []
    var hostEventObservers: [(browser: CefBrowser, token: UUID)] = []
    var hostNavigationEvents: [String: [[String: Any]]] = [:]
    var lease: CefAuxiliaryAdmissionLease?
    var foreign: BrowserWindowCoordinator?
    var foreignProfileID: String?
    var ownedTabs = Set<String>()
    var childNativeIDs: [ObjectIdentifier: Int] = [:]
    var checks: [String] = []
    var cleanupStarted = false, cleanupTriggered = false
    var cleanupStage = "setup"

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native extension host check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native extension host acceptance failed: " + name) }
      checks.append(name)
    }
    func source() throws {
      guard owner.windowContext.isOpen, !owner.windowContext.isClosing,
        engine.pages[page.id] === page, page.browser === originalNative,
        page.profileID == profile, page.ownerWindowID == owner.windowContext.id,
        page.reservedNativeTabID == originalNativeID, owner.store.tab(page.id)?.url == originalAddress else {
        throw ShortcutError("The exact original extension-host source changed.")
      }
    }
    func selectSource() async throws {
      try source()
      owner.store.selectTab(id: page.id); owner.windowContext.show()
      application.repository.focusWindow(owner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
    }
    func attach(_ role: String) async throws -> Host {
      try source()
      guard let identifier, let worker else { throw ShortcutError("No exact installed extension-host fixture.") }
      let address = "chrome-extension://" + identifier + "/" + role + ".html"
      let parent = try await originalNative.devTools.browserSession()
      var targetID: String?
      try await wait("real " + role + " extension target") {
        let contexts = try await worker.evaluate("chrome.runtime.getContexts({contextTypes:[\(try literal(role == "popup" ? "POPUP" : "SIDE_PANEL"))]})") as? [[String: Any]] ?? []
        guard contexts.filter({ $0["documentUrl"] as? String == address }).count == 1 else { return false }
        let result = try await originalNative.devTools.call("Target.getTargets", sessionID: parent)
        let values = (result["targetInfos"] as? [[String: Any]] ?? []).filter { $0["url"] as? String == address }
        guard values.count == 1 else { return false }
        targetID = values.first?["targetId"] as? String
        return targetID != nil
      }
      guard let targetID else { throw ShortcutError("No exact Chrome extension host target.") }
      let attached = try await originalNative.devTools.call("Target.attachToTarget",
        parameters: ["targetId": targetID, "flatten": true], sessionID: parent)
      guard let session = attached["sessionId"] as? String else { throw ShortcutError("No exact extension host target session.") }
      attachments.append((browser: originalNative, parent: parent, session: session))
      var contexts = Set<String>()
      let observer = try originalNative.devTools.observeProtocolEvents { method, parameters, source in
        guard source == session, method == "Runtime.executionContextCreated",
          let context = parameters["context"] as? [String: Any],
          let data = context["auxData"] as? [String: Any], data["isDefault"] as? Bool == true,
          let unique = context["uniqueId"] as? String else { return }
        contexts.insert(unique)
      }
      defer { originalNative.devTools.removeEventObserver(observer) }
      _ = try await originalNative.devTools.call("Runtime.enable", sessionID: session)
      guard contexts.count == 1, let context = contexts.first else {
        _ = try? await originalNative.devTools.call("Target.detachFromTarget", parameters: ["sessionId": session], sessionID: parent)
        throw ShortcutError("The extension host has no unique actual document execution context.")
      }
      var state: [String: Any]?
      try await wait("real extension host initialized") {
        state = try await originalNative.devTools.evaluate("globalThis.nativeHostNavigation?.ready?({instance:nativeHostNavigation.instance,role:nativeHostNavigation.role,windowID:nativeHostNavigation.windowID,address:location.href}):null",
          sessionID: session, uniqueContextID: context) as? [String: Any]
        return state != nil
      }
      guard let state, state["address"] as? String == address, state["role"] as? String == role,
        state["windowID"] as? Int == owner.windowContext.nativeID,
        let instance = state["instance"] as? String else {
        _ = try? await originalNative.devTools.call("Target.detachFromTarget", parameters: ["sessionId": session], sessionID: parent)
        throw ShortcutError("The actual extension host belongs to another document/window.")
      }
      let host = Host(browser: originalNative, parentSession: parent, target: targetID, session: session,
        context: context, address: address, role: role, instance: instance)
      let navigationObserver = try originalNative.devTools.observeProtocolEvents { method, parameters, source in
        guard source == session else { return }
        var event: [String: Any] = ["method": method, "role": role]
        switch method {
        case "Page.windowOpen":
          event["url"] = (parameters["url"] as? String).map { String($0.prefix(2048)) }
          event["windowName"] = (parameters["windowName"] as? String).map { String($0.prefix(128)) }
          event["userGesture"] = parameters["userGesture"] as? Bool
        case "Log.entryAdded":
          guard let entry = parameters["entry"] as? [String: Any] else { return }
          event["source"] = entry["source"] as? String
          event["level"] = entry["level"] as? String
          event["text"] = (entry["text"] as? String).map { String($0.prefix(1200)) }
        case "Runtime.exceptionThrown":
          guard let detail = parameters["exceptionDetails"] as? [String: Any] else { return }
          event["text"] = (detail["text"] as? String).map { String($0.prefix(1200)) }
          event["description"] = ((detail["exception"] as? [String: Any])?["description"] as? String).map { String($0.prefix(1200)) }
        default: return
        }
        var events = hostNavigationEvents[session] ?? []
        events.append(event)
        hostNavigationEvents[session] = Array(events.suffix(12))
      }
      hostEventObservers.append((originalNative, navigationObserver))
      _ = try await originalNative.devTools.call("Page.enable", sessionID: session)
      _ = try await originalNative.devTools.call("Log.enable", sessionID: session)
      return host
    }
    func popup() async throws -> Host {
      try await selectSource()
      guard let identifier, let worker else { throw ShortcutError("No owned action fixture.") }
      let oldPopups = NSApp.windows.filter { engine.extensionPopupOwner($0) === owner.windowContext }
      _ = try await worker.evaluate("chrome.runtime.sendMessage({closeOwnedHostPopup:true}).catch(()=>null)")
      try await wait("old owned popup closes before replacement") {
        let contexts = try await worker.evaluate("chrome.runtime.getContexts({contextTypes:['POPUP']})") as? [[String: Any]] ?? []
        return !contexts.contains { ($0["documentUrl"] as? String ?? "").hasPrefix("chrome-extension://" + identifier + "/") }
          && oldPopups.allSatisfy { !$0.isVisible && engine.extensionPopupOwner($0) == nil }
      }
      // ExtensionHost disappears before its native widget necessarily finishes
      // closing. Restore the actual owned document focus after that close,
      // rather than assuming the previous popup restored the shell's key window.
      try await selectSource()
      page.focus()
      try await wait("exact owned source focus after popup close") {
        try source()
        guard NSApp.isActive, let nativeWindow = originalNative.nativeView?.window,
          nativeWindow === page.nativeWindow, nativeWindow === NSApp.keyWindow,
          nativeWindow.isVisible, owner.windowContext.window.isVisible,
          page.ownerWindowID == owner.windowContext.id else { return false }
        return try await originalNative.devTools.evaluate("document.hasFocus()") as? Bool == true
      }
      let window = owner.windowContext.window
      let anchor = window.convertToScreen(NSRect(x: 180, y: max(0, window.frame.height - 80), width: 20, height: 20))
      try await manager.performAction(identifier, on: page, anchorWindow: window, anchorRect: anchor)
      return try await attach("popup")
    }
    func configure(_ host: Host, phase: String, destination: URL, name: String = "") async throws -> String {
      let token = UUID().uuidString
      let values: [String: Any] = ["token": token, "phase": phase, "destination": destination.absoluteString, "name": name]
      let result = try await evaluate(host, "return nativeHostNavigation.configure(\(try literal(values)));")
      guard result as? Bool == true else { throw ShortcutError("The exact extension-host fixture did not accept its configuration.") }
      return token
    }
    func click(_ host: Host, element: String, token: String, modifiers: Int = 0) async throws {
      try source()
      let coordinates = try await evaluate(host, """
        const element=document.getElementById(\(try literal(element)));if(!element)return null;
        const rect=element.getBoundingClientRect(),x=rect.x+rect.width/2,y=rect.y+rect.height/2;
        return document.elementFromPoint(x,y)===element?[x,y]:null;
        """) as? [Double]
      guard let coordinates, coordinates.count == 2 else { throw ShortcutError("The actual extension-host input target is obscured.") }
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await host.browser.devTools.call("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": coordinates[0], "y": coordinates[1], "button": "left", "clickCount": 1,
          "buttons": type == "mousePressed" ? 1 : 0, "modifiers": modifiers,
        ], sessionID: host.session)
      }
      guard let worker else { throw ShortcutError("No exact extension-host observation worker.") }
      var receipt: [String: Any]?
      try await wait("actual extension host DOM click receipt") {
        let result = try await worker.evaluate("chrome.storage.local.get('nativeHostNavigationReceipt')") as? [String: Any]
        receipt = result?["nativeHostNavigationReceipt"] as? [String: Any]
        return receipt?["token"] as? String == token
      }
      try require(receipt?["trusted"] as? Bool == true && receipt?["primary"] as? Bool == true
        && receipt?["active"] as? Bool == true && receipt?["instance"] as? String == host.instance
        && receipt?["role"] as? String == host.role && receipt?["windowID"] as? Int == owner.windowContext.nativeID,
        "extensionHost" + host.role.capitalized + "ActualTrusted" + element)
      if let receipt, let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
        fputs("Native extension-host DOM receipt: \(String(decoding: data, as: UTF8.self))\n", stderr)
      }
    }
    func blockedExternal(_ host: Host, destination: URL, token: String) async throws {
      guard let worker else { throw ShortcutError("No exact extension-host cancellation witness.") }
      _ = try await host.browser.devTools.call("Page.enable", sessionID: host.session)
      _ = try await host.browser.devTools.call("Network.enable", sessionID: host.session)
      _ = try await host.browser.devTools.call("Target.setDiscoverTargets", parameters: ["discover": true],
        sessionID: host.parentSession)
      let tree = try await host.browser.devTools.call("Page.getFrameTree", sessionID: host.session)
      guard let root = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any],
        root["url"] as? String == host.address, let frameID = root["id"] as? String,
        let loaderID = root["loaderId"] as? String else {
        throw ShortcutError("The blocked navigation has no exact original native host frame.")
      }
      let history = try await host.browser.devTools.call("Page.getNavigationHistory", sessionID: host.session)
      let priorHistory = try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
      let priorTabs = Set(application.store.state.tabs.map(\.id))
      let priorPages = Set(engine.pages.keys), priorWindows = Set(application.windows.keys)
      let priorAuxiliary = Set(CefRuntime.shared.auxiliaryBrowsers.map(\.id))
      func tabIDs() async throws -> [Int] {
        guard let ids = try await worker.evaluate("chrome.tabs.query({}).then(rows=>rows.map(row=>row.id).sort((a,b)=>a-b))") as? [Int] else {
          throw ShortcutError("The exact extension-host native catalog is unavailable.")
        }
        return ids
      }
      let priorNativeTabs = try await tabIDs()
      var attempted = false, cancelled = false, stopped = false, destroyed = false, committedExternal = false
      var requests = Set<String>()
      var events: [String] = []
      let observer = try host.browser.devTools.observeProtocolEvents { method, parameters, session in
        if session == host.parentSession, method == "Target.targetDestroyed",
          parameters["targetId"] as? String == host.target {
          destroyed = true; events.append("targetDestroyed"); return
        }
        guard session == host.session else { return }
        if method == "Page.frameRequestedNavigation", parameters["frameId"] as? String == frameID,
          parameters["url"] as? String == destination.absoluteString {
          attempted = parameters["reason"] as? String == "anchorClick"
            && parameters["disposition"] as? String == "currentTab"
          events.append("requestedCurrentHostNavigation")
        } else if method == "Network.requestWillBeSent", parameters["frameId"] as? String == frameID,
          parameters["type"] as? String == "Document",
          (parameters["request"] as? [String: Any])?["url"] as? String == destination.absoluteString,
          let id = parameters["requestId"] as? String {
          requests.insert(id); events.append("nativeDocumentRequest")
        } else if method == "Network.loadingFailed", let id = parameters["requestId"] as? String,
          requests.contains(id), parameters["type"] as? String == "Document" {
          cancelled = parameters["canceled"] as? Bool == true && parameters["errorText"] as? String == "net::ERR_ABORTED"
          events.append(cancelled ? "nativeDocumentCancelled" : "unexpectedDocumentFailure")
        } else if method == "Page.frameStoppedLoading", parameters["frameId"] as? String == frameID {
          stopped = true; events.append("hostStoppedLoading")
        } else if method == "Page.frameNavigated", let frame = parameters["frame"] as? [String: Any],
          frame["id"] as? String == frameID, frame["url"] as? String != host.address {
          committedExternal = true; events.append("unexpectedExternalCommit")
        }
        if events.count > 12 { events.removeFirst(events.count - 12) }
      }
      defer { host.browser.devTools.removeEventObserver(observer) }
      try await click(host, element: "external", token: token)
      do {
        try await wait("exact targetless extension-host cancellation") {
          guard !committedExternal else { throw ShortcutError("The extension UI committed an external document.") }
          // Retained hosts require a completed native abort. A popup may instead
          // be dismissed by Chrome; destruction of its exact target is terminal
          // proof that this requested navigation cannot later replace that UI.
          return attempted && ((cancelled && stopped) || (host.role == "popup" && destroyed))
        }
      } catch {
        fputs("Native extension-host blocked-navigation witness: requested=\(attempted) cancelled=\(cancelled) stopped=\(stopped) destroyed=\(destroyed) externalCommit=\(committedExternal) events=\(events)\n", stderr)
        throw error
      }
      var exactHost = false
      if destroyed {
        let targets = try await host.browser.devTools.call("Target.getTargets", sessionID: host.parentSession)
        guard let targetInfos = targets["targetInfos"] as? [[String: Any]],
          let contexts = try await worker.evaluate("chrome.runtime.getContexts({contextTypes:['POPUP']})") as? [[String: Any]] else {
          throw ShortcutError("The exact dismissed native popup could not be inspected.")
        }
        exactHost = host.role == "popup" && !targetInfos.contains { $0["targetId"] as? String == host.target }
          && !contexts.contains { $0["documentUrl"] as? String == host.address }
      } else {
        let retainedTree = try await host.browser.devTools.call("Page.getFrameTree", sessionID: host.session)
        let retained = (retainedTree["frameTree"] as? [String: Any])?["frame"] as? [String: Any]
        let retainedHistory = try await host.browser.devTools.call("Page.getNavigationHistory", sessionID: host.session)
        let retainedHistoryData = try JSONSerialization.data(withJSONObject: retainedHistory, options: [.sortedKeys])
        let sameContext = try await evaluate(host, "return document.readyState==='complete'&&nativeHostNavigation.config.token===\(try literal(token));") as? Bool == true
        exactHost = cancelled && stopped && sameContext && retained?["id"] as? String == frameID
          && retained?["loaderId"] as? String == loaderID && retained?["url"] as? String == host.address
          && retainedHistoryData == priorHistory
      }
      try source()
      await application.extensionBrowser.waitForTopologyPublication()
      let currentNativeTabs = try await tabIDs()
      try require(exactHost && !committedExternal && currentNativeTabs == priorNativeTabs
        && Set(application.store.state.tabs.map(\.id)) == priorTabs && Set(engine.pages.keys) == priorPages
        && Set(application.windows.keys) == priorWindows
        && Set(CefRuntime.shared.auxiliaryBrowsers.map(\.id)) == priorAuxiliary,
        "extensionHost" + host.role.capitalized + "TargetlessExternalNavigationIsBlockedWithoutAChild")
    }
    func nativeTab(_ destination: URL, id: Int? = nil) async throws -> [String: Any]? {
      guard let worker else { throw ShortcutError("No exact native extension-host tab witness.") }
      if let id {
        guard id > 0 else { throw ShortcutError("The actual adopted child has no valid Chrome tab identity.") }
        return try await worker.evaluate("chrome.tabs.get(\(id))") as? [String: Any]
      }
      let rows = try await worker.evaluate("chrome.tabs.query({}).then(rows=>rows.filter(tab=>tab.url===\(try literal(destination.absoluteString))))") as? [[String: Any]] ?? []
      guard rows.count == 1 else { return nil }; return rows.first
    }
    func child(_ destination: URL, before: Set<String>, active: Bool) async throws -> ChromiumPage {
      var captured: ChromiumPage?
      var capturedNativeID: Int?
      defer {
        if captured == nil,
          let data = try? JSONSerialization.data(withJSONObject: hostNavigationEvents, options: [.sortedKeys]) {
          fputs("Native extension-host navigation events before missing child: \(String(decoding: data, as: UTF8.self))\n", stderr)
        }
      }
      var previousDiagnostic: Data?
      var diagnosticCount = 0
      var previousRejectedState: Data?
      func rejected(_ reason: String, catalog: [String: Any]? = nil) async -> Bool {
        guard diagnosticCount < 8 else { return false }
        let newTabs = application.store.state.tabs.filter { !before.contains($0.id) && application.store.profileID(for: $0) == profile }
        let candidates = engine.pages.values.filter {
          !before.contains($0.id) && $0.profileID == profile && !$0.isPrivate && !$0.id.hasPrefix("extensions:")
        }.sorted { $0.id < $1.id }.prefix(6)
        let cheapState: [String: Any] = ["reason": reason, "activeID": owner.store.state.activeTabID ?? "nil",
          "model": newTabs.prefix(6).map { ["id": $0.id, "window": $0.windowID ?? "nil",
            "opener": $0.openerTabID ?? "nil", "closed": String($0.isClosed),
            "urlMatches": String($0.url == destination.absoluteString)] },
          "native": candidates.map { ["id": $0.id, "window": $0.ownerWindowID ?? "nil",
            "reserved": $0.reservedNativeTabID.map { String($0) } ?? "nil",
            "browser": $0.browser.map { String($0.id) } ?? "nil", "loading": String($0.isLoading),
            "urlMatches": String($0.url == destination), "error": String($0.documentError != nil)] },
          "catalog": ["id": catalog?["id"] ?? NSNull(), "window": catalog?["windowId"] ?? NSNull(),
            "active": catalog?["active"] ?? NSNull(), "status": catalog?["status"] ?? NSNull(),
            "opener": catalog?["openerTabId"] ?? NSNull()]]
        guard let cheapBytes = try? JSONSerialization.data(withJSONObject: cheapState, options: [.sortedKeys]),
          cheapBytes != previousRejectedState else { return false }
        previousRejectedState = cheapBytes
        var records: [[String: Any]] = []
        for candidate in candidates {
          var value: [String: Any] = ["logicalID": candidate.id, "profileID": candidate.profileID,
            "modelPresent": newTabs.contains { $0.id == candidate.id },
            "ownerWindowID": candidate.ownerWindowID ?? "nil", "private": candidate.isPrivate,
            "reservedTabID": candidate.reservedNativeTabID.map { String($0) } ?? "nil",
            "loading": candidate.isLoading, "documentError": candidate.documentError != nil,
            "urlMatches": candidate.url == destination]
          // Borrow an existing, ready native client only. Diagnostics never
          // create/materialize/register a document or supply missing metadata.
          if let browser = candidate.browser, !browser.isClosed {
            do {
              let ready = try await candidate.ready()
              value["cefBrowserID"] = Int(ready.id)
              let nativeOwner = try await ready.devTools.call("Zacro.historyDocument")
              value["nativeLogicalID"] = nativeOwner["logicalID"]
              value["nativeOwnerWindowID"] = nativeOwner["ownerWindowID"]
              value["nativePreview"] = nativeOwner["preview"]
              value["nativeProvisional"] = nativeOwner["provisional"]
            } catch { value["nativeReadError"] = String(error.localizedDescription.prefix(200)) }
          } else { value["cefBrowserID"] = "not-ready" }
          records.append(value)
        }
        let model = newTabs.prefix(6).map { tab -> [String: Any] in
          ["logicalID": tab.id, "windowID": tab.windowID ?? "nil", "openerTabID": tab.openerTabID ?? "nil",
            "closed": tab.isClosed, "urlMatches": tab.url == destination.absoluteString,
            "nativePresent": engine.pages[tab.id] != nil]
        }
        var payload: [String: Any] = ["reason": reason, "requiredActive": active,
          "sourceWindowID": owner.windowContext.id, "sourceNativeWindowID": owner.windowContext.nativeID,
          "activeCoreID": owner.store.state.activeTabID ?? "nil", "newCoreTabs": model, "nativeCandidates": records]
        if let catalog {
          payload["chromeTab"] = ["id": catalog["id"] ?? NSNull(), "windowId": catalog["windowId"] ?? NSNull(),
            "openerTabId": catalog["openerTabId"] ?? NSNull(), "active": catalog["active"] ?? NSNull(),
            "status": catalog["status"] ?? NSNull(), "incognito": catalog["incognito"] ?? NSNull()]
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          bytes != previousDiagnostic, let text = String(data: bytes, encoding: .utf8) {
          previousDiagnostic = bytes; diagnosticCount += 1
          fputs("Native extension-host child rejection: " + text + "\n", stderr)
        }
        return false
      }
      try await wait("actual adopted extension child document") {
        let fresh = application.store.state.tabs.filter { !before.contains($0.id) && !$0.isClosed && $0.url == destination.absoluteString }
        guard fresh.count == 1, let tab = fresh.first else { return await rejected("matchingCoreTabCount=\(fresh.count)") }
        ownedTabs.insert(tab.id)
        guard let native = engine.pages[tab.id] else { return await rejected("missingNativePage") }
        guard native.url == destination, !native.isLoading, native.documentError == nil else { return await rejected("nativeDocumentNotCommitted") }
        guard tab.windowID == owner.windowContext.id, tab.openerTabID == nil,
          native.ownerWindowID == owner.windowContext.id, native.profileID == profile, !native.isPrivate,
          !active || owner.store.state.activeTabID == tab.id else { return await rejected("CoreOrNativeOwnershipMismatch") }
        let observedCatalog = try await nativeTab(destination)
        guard let catalog = observedCatalog, let actualID = catalog["id"] as? Int, actualID > 0,
          catalog["windowId"] as? Int == owner.windowContext.nativeID,
          catalog["url"] as? String == destination.absoluteString, catalog["incognito"] as? Bool == false,
          catalog["status"] as? String == "complete", catalog["active"] as? Bool == active,
          catalog["openerTabId"] == nil || catalog["openerTabId"] is NSNull else {
          return await rejected("actualChromeTabIdentityMismatch", catalog: observedCatalog)
        }
        // A genuine pre-existing popup has no reservation token. Its actual
        // SessionTabHelper ID comes from Chrome registration/query instead.
        guard native.reservedNativeTabID.map({ $0 == actualID }) ?? true else {
          return await rejected("reservedIdentityDisagreesWithActualChromeTab", catalog: catalog)
        }
        captured = native; capturedNativeID = actualID; return true
      }
      guard let captured, let capturedNativeID else { throw ShortcutError("The extension host did not produce one exact owned Core/native document.") }
      childNativeIDs[ObjectIdentifier(captured)] = capturedNativeID
      let history = try await captured.historyMirrorSession()
      do {
        let document = try await history.document(captured)
        guard let eventID = document.currentEventID, document.logicalID == captured.id,
          document.ownerWindowID == owner.windowContext.nativeID else {
          throw ShortcutError("The adopted child has no exact native history document identity.")
        }
        try await wait("adopted child native history publication") {
          try await application.historyMirror.refresh(profileID: profile)
          return application.store.nativeHistoryBindings(profileID: profile).contains {
            $0.eventID == eventID && $0.coreAddress == destination.absoluteString
          }
        }
        await history.close()
      } catch { await history.close(); throw error }
      try require(true, "extensionHostChildPublishesExactActualNativeHistory")
      return captured
    }
    func callback(_ host: Host, token: String) async throws {
      try await wait("actual named child opener callback") {
        try await evaluate(host, "return nativeHostNavigation.callbacks.some(value=>value.token===\(try literal(token))&&value.sameNamedChild);") as? Bool == true
      }
    }
    func destination(_ phase: String, token: String) -> URL {
      var components = URLComponents(url: url.appendingPathComponent("native-extension-host/document"), resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "phase", value: phase)]
      return components.url!
    }
    func cleanup() async throws {
      guard !cleanupStarted else { return }; cleanupStarted = true
      var failure: Error?
      do { try lease?.release(); lease = nil } catch { failure = error }
      for observer in hostEventObservers { observer.browser.devTools.removeEventObserver(observer.token) }
      hostEventObservers.removeAll()
      for attachment in attachments {
        _ = try? await attachment.browser.devTools.call("Target.detachFromTarget",
          parameters: ["sessionId": attachment.session], sessionID: attachment.parent)
      }
      if let worker {
        _ = try? await worker.evaluate("chrome.runtime.sendMessage({closeOwnedHostPopup:true}).catch(()=>null)")
      }
      ownedTabs.formUnion(application.store.state.tabs.filter {
        !originalTabs.contains($0.id) && application.store.profileID(for: $0) == profile
      }.map(\.id))
      for id in ownedTabs where owner.store.tab(id)?.isClosed == false {
        if !(await owner.requestCloseTab(id)) { failure = failure ?? ShortcutError("An owned extension child refused normal close.") }
      }
      // The inspected worker must survive both SDK identity checks. Revoke it
      // only after detaching that inspector, from the independently retained
      // primary fixture's genuine external-message sender.
      await worker?.close(); worker = nil
      if let identifier {
        do {
          cleanupStage = "owned-target-registry"
          let installed = try await manager.snapshot().extensions.first { $0.id == identifier }
          if let installed {
            guard identifier != triggerWorker.extensionID, installed.isEnabled,
              installed.path.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path }) == true else {
              throw ShortcutError("The exact owned extension-host cleanup installation changed.")
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
                throw ShortcutError("The exact extension-host cleanup could not clear its original uninstall URL.")
              }
            } catch { await inspector.close(); throw error }
            await inspector.close()
            cleanupStage = "stable-primary-original-message"
            guard !cleanupTriggered else { throw ShortcutError("The extension-host cleanup was already dispatched.") }
            cleanupTriggered = true
            let dispatch = try await triggerWorker.evaluate("""
              (async()=>await chrome.runtime.sendMessage(\(try literal(identifier)),
                {kind:'zacro-owned-host-uninstall',nonce:\(try literal(cleanupNonce))}))()
              """, timeout: 10) as? [String: Any]
            guard dispatch?["accepted"] as? Bool == true, dispatch?["identifier"] as? String == identifier,
              dispatch?["nonce"] as? String == cleanupNonce else {
              throw ShortcutError("The stable original extension-host cleanup message did not reach its exact target.")
            }
            cleanupStage = "actual-owned-native-removal"
            try await wait("actual owned host fixture uninstall") {
              try await !manager.snapshot().extensions.contains { $0.id == identifier }
            }
          }
          guard try await !manager.snapshot().extensions.contains(where: { $0.id == identifier }) else {
            throw ShortcutError("The exact extension-host fixture remains installed after cleanup.")
          }
          try FileManager.default.removeItem(at: directory)
          try require(true, "extensionHostCleanupUsesStablePeerAndOriginalNativeRemoval")
        } catch {
          failure = failure ?? error
          var diagnostic: [String: Any] = ["stage": cleanupStage, "profile": profile,
            "activeProfile": owner.store.activeProfileID, "owner": owner.windowContext.id,
            "primaryID": triggerWorker.extensionID, "targetID": identifier,
            "ownedCanonicalPath": String(directory.resolvingSymlinksInPath().standardizedFileURL.path.prefix(500)),
            "cleanupTriggered": cleanupTriggered, "error": String(error.localizedDescription.prefix(1_000))]
          do {
            let snapshot = try await manager.snapshot()
            diagnostic["registry"] = snapshot.extensions.filter {
              $0.id == identifier || $0.id == triggerWorker.extensionID
            }.map { ["id": $0.id, "enabled": $0.isEnabled, "state": $0.state,
              "path": String(($0.path ?? "").prefix(500))] as [String: Any] }
          } catch { diagnostic["registryError"] = String(error.localizedDescription.prefix(500)) }
          if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8) { fputs("Native extension-host cleanup \(text)\n", stderr) }
        }
      } else if identifier == nil { try? FileManager.default.removeItem(at: directory) }
      if let foreignProfileID, let foreign,
        application.store.state.profiles.contains(where: { $0.id == foreignProfileID }) {
        do {
          try await wait("owned foreign profile cleanup is available") {
            application.deletingProfileID == nil && application.pendingDeletion == nil
          }
          foreign.actions.deleteProfile(foreignProfileID)
          try await wait("owned foreign host-isolation profile deletion") {
            application.deletingProfileID == nil
              && !application.store.state.profiles.contains { $0.id == foreignProfileID }
              && !application.store.pendingNativeProfileRetirements.contains(foreignProfileID)
              && !engine.pages.values.contains { $0.profileID == foreignProfileID }
          }
        } catch { failure = failure ?? error }
      }
      if let foreign, foreign.windowContext.isOpen, application.deletingProfileID == nil,
        !(await foreign.requestCloseWindow()) {
        failure = failure ?? ShortcutError("The owned foreign host-isolation window refused normal close.")
      }
      if owner.windowContext.isOpen, let originalAddress, owner.store.tab(page.id)?.isClosed == false,
        owner.store.tab(page.id)?.url != originalAddress {
        owner.store.selectTab(id: page.id); owner.navigate(originalAddress)
        do { try await wait("exact original host source restoration") {
          page.url?.absoluteString == originalAddress && !page.isLoading && page.documentError == nil
        } } catch { failure = failure ?? error }
      }
      do { try await selectSource() } catch { failure = failure ?? error }
      if let failure { throw failure }
    }

    do {
      let primary = try await triggerWorker.evaluate("({id:chrome.runtime.id,incognito:chrome.extension.inIncognitoContext})", timeout: 10) as? [String: Any]
      guard primary?["id"] as? String == triggerWorker.extensionID, primary?["incognito"] as? Bool == false,
        try await manager.snapshot().extensions.contains(where: { $0.id == triggerWorker.extensionID && $0.isEnabled }) else {
        throw ShortcutError("The stable extension-host cleanup trigger is not installed in the exact public source profile.")
      }
      try writeFixture(at: directory, primaryID: triggerWorker.extensionID, cleanupNonce: cleanupNonce)
      try await manager.setDeveloperMode(true)
      let id = try await manager.loadUnpackedExtension(at: directory); identifier = id
      worker = try await manager.workerSession(id)
      let firstPopup = try await popup()
      let popupBlank = destination("popup-blank", token: UUID().uuidString)
      let popupToken = try await configure(firstPopup, phase: "popup-blank", destination: popupBlank)
      let beforePopup = Set(application.store.state.tabs.map(\.id))
      try await click(firstPopup, element: "blank", token: popupToken, modifiers: 4)
      let popupChild = try await child(popupBlank, before: beforePopup, active: false)
      try require(owner.store.state.activeTabID == page.id && popupChild.ownerWindowID == owner.windowContext.id,
        "extensionHostPopupMetaBlankLinkOpensBackgroundTabInExactSourceShell")
      let externalPopup = try await popup()
      let popupExternal = destination("popup-external", token: UUID().uuidString)
      let externalToken = try await configure(externalPopup, phase: "popup-external", destination: popupExternal)
      try await blockedExternal(externalPopup, destination: popupExternal, token: externalToken)
      try require(owner.store.tab(page.id)?.url == originalAddress,
        "extensionHostPopupExternalLinkPreservesOriginalPublicSource")

      try await selectSource()
      try await manager.openSidePanel(id, on: page)
      let panel = try await attach("panel")
      let name = "zacro-host-child-" + UUID().uuidString
      let firstURL = destination("panel-named", token: UUID().uuidString)
      let firstToken = try await configure(panel, phase: "panel-named", destination: firstURL, name: name)
      let beforeNamed = Set(application.store.state.tabs.map(\.id))
      try await click(panel, element: "open", token: firstToken)
      let named = try await child(firstURL, before: beforeNamed, active: true)
      let namedBrowser = try await named.ready()
      guard let namedNativeID = childNativeIDs[ObjectIdentifier(named)], namedNativeID > 0 else {
        throw ShortcutError("The actual named child has no witnessed Chrome tab identity.")
      }
      try await callback(panel, token: URLComponents(url: firstURL, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)
      try require(try await namedBrowser.devTools.evaluate("globalThis.nativeExtensionHostReceipt?.hasOpener") as? Bool == true,
        "extensionHostSidePanelWindowOpenPreservesActualNativeOpener")
      let reusedURL = destination("panel-reused", token: UUID().uuidString)
      let reusedToken = try await configure(panel, phase: "panel-reused", destination: reusedURL, name: name)
      let beforeReuse = Set(application.store.state.tabs.map(\.id))
      try await click(panel, element: "reuse", token: reusedToken)
      try await wait("existing named child actual native navigation") { named.url == reusedURL && !named.isLoading }
      try await callback(panel, token: URLComponents(url: reusedURL, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)
      let reusedProxy = try await evaluate(panel, "return nativeHostNavigation.reused;") as? Bool
      let reusedNative = try await nativeTab(reusedURL, id: namedNativeID)
      try require(Set(application.store.state.tabs.map(\.id)) == beforeReuse && engine.pages[named.id] === named
        && named.browser === namedBrowser && reusedNative?["id"] as? Int == namedNativeID
        && reusedNative?["url"] as? String == reusedURL.absoluteString
        && reusedNative?["windowId"] as? Int == owner.windowContext.nativeID
        && reusedNative?["openerTabId"] == nil && owner.store.tab(named.id)?.openerTabID == nil && reusedProxy == true,
        "extensionHostNamedWindowReusePreservesExactCoreTabAndNativeWebContents")
      let postedURL = destination("panel-post", token: UUID().uuidString)
      let postToken = try await configure(panel, phase: "panel-post", destination: postedURL, name: name)
      let beforePost = Set(application.store.state.tabs.map(\.id))
      try await click(panel, element: "post", token: postToken)
      try await wait("real named POST response") { named.url == postedURL && !named.isLoading }
      try await callback(panel, token: URLComponents(url: postedURL, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)
      let post = try await namedBrowser.devTools.evaluate("globalThis.nativeExtensionHostReceipt") as? [String: Any]
      let postedNative = try await nativeTab(postedURL, id: namedNativeID)
      try require(post?["method"] as? String == "POST" && post?["body"] as? String == "owned=" + postToken + "&role=panel"
        && post?["hasOpener"] as? Bool == true && Set(application.store.state.tabs.map(\.id)) == beforePost
        && named.browser === namedBrowser && postedNative?["id"] as? Int == namedNativeID
        && postedNative?["url"] as? String == postedURL.absoluteString
        && postedNative?["windowId"] as? Int == owner.windowContext.nativeID
        && postedNative?["openerTabId"] == nil && owner.store.tab(named.id)?.openerTabID == nil,
        "extensionHostNamedFormSubmissionPreservesOriginalPOSTBodyAndOpener")

      for scope in ["profile", "process"] {
        let blockedURL = destination("blocked-" + scope, token: UUID().uuidString)
        let token = try await configure(panel, phase: "blocked-" + scope, destination: blockedURL, name: name + scope)
        let before = Set(application.store.state.tabs.map(\.id))
        let beforeWindows = Set(application.windows.keys)
        lease = scope == "profile" ? try engine.acquireAuxiliaryAdmission(profileID: profile, isPrivate: false)
          : try CefAuxiliaryAdmissionLease.acquireProcess()
        guard lease != nil else { throw ShortcutError("No actual native admission lease for extension-host navigation.") }
        try await click(panel, element: "open", token: token)
        _ = try await manager.snapshot()
        try require(Set(application.store.state.tabs.map(\.id)) == before
          && Set(application.windows.keys) == beforeWindows
          && !application.store.state.tabs.contains { $0.url == blockedURL.absoluteString }
          && Set(CefRuntime.shared.auxiliaryBrowsers.map(\.id)) == originalAuxiliary,
          "extensionHost" + scope.capitalized + "AdmissionFenceBlocksDOMChildBeforeCreation")
        try lease?.release(); lease = nil
      }

      try await selectSource()
      application.newWindow()
      let added = application.windows.values.filter { !originalWindows.contains($0.windowContext.id) && $0.windowContext.isOpen }
      guard added.count == 1, let other = added.first else { throw ShortcutError("No exact foreign host-isolation shell.") }
      foreign = other; other.actions.palette = false
      // A normal new window starts with its own blank tab in the current
      // profile. Retire this exact fixture-created tab before switching the
      // shell to the foreign profile, so it cannot become an unexplained tab
      // in the original profile's final ownership census.
      let placeholders = application.store.state.tabs.filter {
        !originalTabs.contains($0.id) && $0.windowID == other.windowContext.id
          && application.store.profileID(for: $0) == profile
      }
      guard placeholders.count == 1, let placeholder = placeholders.first,
        placeholder.url == "about:blank", !placeholder.isPinned, !placeholder.isFavorite,
        placeholder.peek == nil, !placeholder.isClosed,
        await other.requestCloseTab(placeholder.id) else {
        throw ShortcutError("The exact foreign shell's new-window placeholder could not close normally.")
      }
      try await wait("foreign shell placeholder Core and native retirement") {
        other.store.tab(placeholder.id) == nil && engine.pages[placeholder.id] == nil
      }
      try require(true, "extensionHostForeignOwnerRetiresItsExactNewWindowPlaceholder")
      let otherProfile = try other.store.createProfileDurably(name: "Host RFH isolation fixture")
      foreignProfileID = otherProfile.id
      guard otherProfile.id != profile,
        let otherTab = other.store.createTab(address: url.appendingPathComponent("extension-host-foreign-owner").absoluteString) else {
        throw ShortcutError("No foreign profile document for host focus isolation.")
      }
      let otherPage = try await other.ensurePageReady(otherTab)
      try await application.navigation.waitForRestore(otherPage)
      other.windowContext.show(); application.repository.focusWindow(other.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
      let foreignAddress = other.store.tab(otherTab.id)?.url
      let isolatedURL = destination("panel-foreign-focus", token: UUID().uuidString)
      let isolatedToken = try await configure(panel, phase: "panel-foreign-focus", destination: isolatedURL, name: name + "foreign")
      let beforeIsolation = Set(application.store.state.tabs.map(\.id))
      try await click(panel, element: "open", token: isolatedToken)
      _ = try await child(isolatedURL, before: beforeIsolation, active: true)
      try require(other.store.tab(otherTab.id)?.url == foreignAddress && engine.pages[otherTab.id] === otherPage
        && otherPage.ownerWindowID == other.windowContext.id,
        "extensionHostBackgroundSidePanelUsesSourceRFHDespiteForeignProfileFocus")

      try await selectSource()
      var panelPresentation: [String: Any] = [:]
      var panelDocument: [String: Any] = [:]
      var stablePanelPresentations = 0
      do {
        try await wait("retained panel physically presented in the selected source browser") {
          try source()
          panelPresentation = try await originalNative.devTools.call("Zacro.observeDocument", parameters: ["enabled": true])
          panelDocument = try await evaluate(panel, "return {visible:document.visibilityState==='visible',focused:document.hasFocus(),instance:nativeHostNavigation.instance};") as? [String: Any] ?? [:]
          guard owner.activePage === page, owner.store.state.activeTabID == page.id,
            page.nativeWindow?.isVisible == true, owner.windowContext.window.isVisible,
            panelPresentation["sidePanelVisible"] as? Bool == true,
            panelDocument["visible"] as? Bool == true,
            panelDocument["instance"] as? String == panel.instance else {
            stablePanelPresentations = 0
            return false
          }
          stablePanelPresentations += 1
          return stablePanelPresentations >= 2
        }
      } catch {
        let diagnostics: [String: Any] = ["sourceID": page.id,
          "activeID": owner.store.state.activeTabID ?? "nil",
          "sourceNativeWindow": page.nativeWindow?.windowNumber ?? -1,
          "sourceNativeVisible": page.nativeWindow?.isVisible ?? false,
          "shellWindow": owner.windowContext.window.windowNumber,
          "appKeyWindow": NSApp.keyWindow?.windowNumber ?? -1,
          "nativePanel": panelPresentation, "hostDocument": panelDocument,
          "panelPages": engine.pages.values.filter { $0.profileID == profile && $0.isSidePanelVisible }.map {
            ["id": $0.id, "window": $0.nativeWindow?.windowNumber ?? -1,
             "visible": $0.nativeWindow?.isVisible ?? false] as [String: Any]
          }]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
          fputs("Native extension-host retained panel presentation: \(String(decoding: data, as: UTF8.self))\n", stderr)
        }
        throw error
      }
      try require(stablePanelPresentations >= 2,
        "extensionHostRetainedPanelIsPhysicallyVisibleAfterSourceSelection")
      let blankURL = destination("panel-blank", token: UUID().uuidString)
      let blankToken = try await configure(panel, phase: "panel-blank", destination: blankURL)
      let beforeBlank = Set(application.store.state.tabs.map(\.id))
      try await click(panel, element: "blank", token: blankToken, modifiers: 4)
      _ = try await child(blankURL, before: beforeBlank, active: false)
      try require(owner.store.state.activeTabID == page.id,
        "extensionHostSidePanelMetaBlankLinkKeepsSourceSelection")
      let directURL = destination("panel-external", token: UUID().uuidString)
      let directToken = try await configure(panel, phase: "panel-external", destination: directURL)
      try await blockedExternal(panel, destination: directURL, token: directToken)
      let actualAuxiliary = Set(CefRuntime.shared.auxiliaryBrowsers.map(\.id))
      let expectedWindows = originalWindows.union([other.windowContext.id])
      let actualWindows = Set(application.windows.keys)
      let newProfileTabs = application.store.state.tabs.filter {
        !originalTabs.contains($0.id) && application.store.profileID(for: $0) == profile
      }
      let ownedProfileTabs = newProfileTabs.allSatisfy {
        ownedTabs.contains($0.id) && $0.windowID == owner.windowContext.id
      }
      if actualAuxiliary != originalAuxiliary || actualWindows != expectedWindows || !ownedProfileTabs {
        let diagnostics: [String: Any] = [
          "actualAuxiliary": actualAuxiliary.sorted(), "expectedAuxiliary": originalAuxiliary.sorted(),
          "actualWindows": actualWindows.sorted(), "expectedWindows": expectedWindows.sorted(),
          "newProfileTabs": newProfileTabs.map { tab -> [String: Any] in
            ["id": tab.id, "window": tab.windowID ?? "nil", "ownedChild": ownedTabs.contains(tab.id),
             "closed": tab.isClosed, "blank": tab.url == "about:blank", "nativePresent": engine.pages[tab.id] != nil]
          }]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
          fputs("Native extension-host final ownership census: \(String(decoding: data, as: UTF8.self))\n", stderr)
        }
      }
      try require(actualAuxiliary == originalAuxiliary
        && actualWindows == expectedWindows && ownedProfileTabs,
        "extensionHostDOMAndExternalLinksCreateNoUnmodeledNativeBrowser")
      try await cleanup()
      return checks
    } catch {
      let failure = error
      let cleanupTask = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native extension-host fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
      }
      await cleanupTask.value
      throw failure
    }
  }

  private static func literal(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
  }
  private static func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      try Task.checkCancellation()
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(40))
    }
    throw ShortcutError("Native extension-host acceptance timed out: " + phase)
  }
  private static func evaluate(_ host: Host, _ body: String) async throws -> Any? {
    guard !host.browser.isClosed else { throw CancellationError() }
    return try await host.browser.devTools.evaluate("""
      (()=>{if(location.href!==\(try literal(host.address))||nativeHostNavigation.instance!==\(try literal(host.instance)))
        throw new Error('Extension host document changed');\(body)})()
      """, sessionID: host.session, uniqueContextID: host.context)
  }
  private static func writeFixture(at directory: URL, primaryID: String, cleanupNonce: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let manifest: [String: Any] = ["manifest_version": 3, "name": "Owned genuine extension-host navigation",
      "version": "1.0", "permissions": ["tabs", "storage", "sidePanel"],
      "background": ["service_worker": "worker.js"], "action": ["default_popup": "popup.html"],
      "side_panel": ["default_path": "panel.html"], "externally_connectable": ["ids": [primaryID]]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    let cleanupScript = """
      let consumed=false;
      chrome.runtime.onInstalled.addListener(()=>{});
      chrome.runtime.onMessageExternal.addListener((message,sender,sendResponse)=>{
        if(consumed||sender.id!==\(try literal(primaryID))||
          message?.kind!=='zacro-owned-host-uninstall'||message.nonce!==\(try literal(cleanupNonce)))return false;
        consumed=true;sendResponse({accepted:true,identifier:chrome.runtime.id,nonce:\(try literal(cleanupNonce))});
        void chrome.management.uninstallSelf({showConfirmDialog:false});return false;
      });
      """
    try Data(cleanupScript.utf8).write(to: directory.appendingPathComponent("worker.js"), options: .atomic)
    for role in ["popup", "panel"] {
      let html = """
        <!doctype html><meta charset=utf-8><title>Owned \(role) host</title>
        <style>body{margin:12px;width:240px;font:14px sans-serif}button,a{box-sizing:border-box;display:block;width:220px;height:34px;margin:6px 0;padding:7px;text-align:left}form{margin:0}</style>
        <body data-role="\(role)"><button id=open>Open named child</button><button id=reuse>Reuse named child</button>
        <form id=postForm method=post><input type=hidden name=owned id=owned><input type=hidden name=role value="\(role)"><button id=post type=submit>Submit real POST</button></form>
        <a id=blank target=_blank>Open background link</a><a id=external>Open external link</a><script src=host.js></script>
        """
      try Data(html.utf8).write(to: directory.appendingPathComponent(role + ".html"), options: .atomic)
    }
    let script = """
      const host=globalThis.nativeHostNavigation={instance:crypto.randomUUID(),role:document.body.dataset.role,ready:false,windowID:null,callbacks:[],config:null,namedChild:null};
      chrome.windows.getCurrent().then(window=>{host.windowID=window.id;host.ready=true;});
      host.configure=config=>{host.config=config;document.getElementById('blank').href=config.destination;
        document.getElementById('external').href=config.destination;document.getElementById('postForm').action=config.destination;
        document.getElementById('postForm').target=config.name;document.getElementById('owned').value=config.token;return true;};
      document.addEventListener('click',event=>{if(!host.config)return;const id=event.target.id;
        if(!['open','reuse','post','blank','external'].includes(id))return;
        void chrome.storage.local.set({nativeHostNavigationReceipt:{token:host.config.token,instance:host.instance,role:host.role,
          windowID:host.windowID,trusted:event.isTrusted,primary:event.button===0,active:navigator.userActivation.isActive,element:id,
          meta:event.metaKey,control:event.ctrlKey,shift:event.shiftKey,alt:event.altKey,defaultPrevented:event.defaultPrevented,
          visible:document.visibilityState,focused:document.hasFocus(),href:event.target.href??null,target:event.target.target??null}});
      },true);
      for(const id of ['open','reuse'])document.getElementById(id).addEventListener('click',()=>{
        const prior=host.namedChild;host.namedChild=window.open(host.config.destination,host.config.name);
        host.reused=prior!==null&&prior===host.namedChild;
      });
      window.addEventListener('message',event=>{if(event.data?.zacroExtensionHostToken)
        host.callbacks.push({token:event.data.zacroExtensionHostToken,sameNamedChild:event.source===host.namedChild});});
      chrome.runtime.onMessage.addListener((message,_sender,respond)=>{
        if(message?.closeOwnedHostPopup&&host.role==='popup'){respond({closing:true});setTimeout(()=>window.close(),0);}
      });
      """
    try Data(script.utf8).write(to: directory.appendingPathComponent("host.js"), options: .atomic)
  }
}
