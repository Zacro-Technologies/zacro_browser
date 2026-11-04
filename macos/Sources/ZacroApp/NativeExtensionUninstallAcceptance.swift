import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Uses Chrome's actual setUninstallURL + uninstallSelf producers. Only the
/// short-lived acceptance extensions are removed; every destination is loopback.
@MainActor enum NativeExtensionUninstallAcceptance {
  static func run(application: ApplicationCoordinator, url: URL,
    owner: BrowserWindowCoordinator, page: ChromiumPage,
    triggerWorker: ChromeExtensionWorkerSession) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, CefAuxiliaryAdmissionLease.isSupported,
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      owner.store.state.activeProfile?.isPrivate == false, !page.isPrivate,
      owner.store.activeProfileID == page.profileID,
      owner.store.tab(page.id).map({ owner.store.profileID(for: $0) == page.profileID }) == true,
      application.engine.pages[page.id] === page, page.ownerWindowID == owner.windowContext.id,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil else {
      throw ShortcutError("Uninstall navigation acceptance requires the disposable custom-runtime loopback owner.")
    }
    let engine = application.engine, profile = page.profileID
    let manager = ChromeExtensionManager(engine: engine, profileID: profile)
    let originalTabs = Set(application.store.state.tabs.map(\.id))
    let originalWindows = Set(application.windows.keys)
    let originalAuxiliary = Set(engine.auxiliaryBrowsers(profileID: profile, isPrivate: false).map(\.id))
    let sourceURL = owner.store.tab(page.id)?.url, sourceNativeID = page.reservedNativeTabID
    let prefix = "uninstall-" + UUID().uuidString + "-"
    var checks: [String] = []
    var lease: CefAuxiliaryAdmissionLease?
    var workers: [String: ChromeExtensionWorkerSession] = [:]
    var directories: [String: URL] = [:]
    var nonces: [String: String] = [:]
    var currentPhase = "setup", currentStage = "validate-primary", currentIdentifier: String?

    func require(_ value: Bool, _ name: String) throws {
      fputs("Native uninstall navigation check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native uninstall navigation acceptance failed: " + name) }
      checks.append(name)
    }
    func literal(_ value: Any) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func wait(_ phase: String, _ condition: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ShortcutError("Native uninstall navigation acceptance timed out: " + phase)
    }
    func diagnostics(_ phase: String, error: Error) async {
      var value: [String: Any] = ["phase": phase, "scenario": currentPhase, "stage": currentStage,
        "profile": profile, "activeProfile": owner.store.activeProfileID,
        "owner": owner.windowContext.id, "sourceProfile": page.profileID,
        "sourceCurrent": engine.pages[page.id] === page,
        "primaryID": triggerWorker.extensionID, "targetID": currentIdentifier ?? "",
        "error": String(error.localizedDescription.prefix(1_000))]
      do {
        let snapshot = try await manager.snapshot()
        value["developerMode"] = snapshot.profile.inDeveloperMode
        value["registry"] = snapshot.extensions.filter {
          directories[$0.id] != nil || $0.id == triggerWorker.extensionID
        }.prefix(8).map {
          ["id": $0.id, "state": $0.state, "name": String($0.name.prefix(160)),
            "path": String(($0.path ?? "").prefix(500))]
        }
      } catch { value["registryError"] = String(error.localizedDescription.prefix(500)) }
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native uninstall fixture state \(text)\n", stderr) }
    }
    func uninstall(_ identifier: String, destination: String, freshInspector: Bool = false) async throws {
      guard directories[identifier] != nil, let nonce = nonces[identifier],
        identifier != triggerWorker.extensionID else { throw ShortcutError("No exact owned uninstall target.") }
      if freshInspector { await workers.removeValue(forKey: identifier)?.close() }
      currentIdentifier = identifier; currentStage = "target-inspector"
      let worker: ChromeExtensionWorkerSession
      if let existing = workers[identifier] { worker = existing }
      else {
        worker = try await manager.workerSession(identifier)
        workers[identifier] = worker
      }
      currentStage = "configure-original-uninstall-url"
      let value = try await worker.evaluate("""
        (async () => {
          const result = await chrome.runtime.setUninstallURL(\(try literal(destination)));
          return {configured:true, identifier:chrome.runtime.id, originalVoidResult:result === undefined};
        })()
        """, timeout: 10) as? [String: Any]
      guard value?["configured"] as? Bool == true, value?["identifier"] as? String == identifier,
        value?["originalVoidResult"] as? Bool == true else {
        throw ShortcutError("The actual original uninstall URL was not configured on its exact target.")
      }
      // The target inspector must finish both native identity validations
      // before an independent real extension message revokes that target.
      await worker.close(); workers.removeValue(forKey: identifier)
      currentStage = "original-peer-message-trigger"
      let dispatched = try await triggerWorker.evaluate("""
        (async()=>await chrome.runtime.sendMessage(\(try literal(identifier)),
          {kind:'zacro-owned-uninstall',nonce:\(try literal(nonce))}))()
        """, timeout: 10) as? [String: Any]
      guard dispatched?["accepted"] as? Bool == true, dispatched?["identifier"] as? String == identifier,
        dispatched?["nonce"] as? String == nonce else {
        throw ShortcutError("The exact original extension message did not dispatch the owned uninstall producer.")
      }
      currentStage = "actual-native-registry-removal"
      try await wait("actual registry removal of owned extension") {
        try await !manager.snapshot().extensions.contains { $0.id == identifier }
      }
      // Original RuntimeEventRouter invokes OpenURL synchronously during the
      // completed uninstall. A subsequent native roundtrip settles that stack.
      _ = try await manager.snapshot()
    }
    func cleanup() async throws {
      var failure: Error?
      do { try lease?.release(); lease = nil } catch { failure = error }
      for id in Array(directories.keys) {
        do {
          let installed = try await manager.snapshot().extensions.contains { $0.id == id }
          if installed { try await uninstall(id, destination: "", freshInspector: true) }
          else { await workers.removeValue(forKey: id)?.close() }
        } catch {
          failure = failure ?? error
          await diagnostics("cleanup-owned-target-failed", error: error)
        }
      }
      for worker in workers.values { await worker.close() }
      workers.removeAll()
      for tab in application.store.state.tabs where !originalTabs.contains(tab.id) && !tab.isClosed {
        guard tab.url.contains(prefix) else { continue }
        if !(await application.extensionBrowser.closeTab(tab.id)) {
          failure = failure ?? ShortcutError("An owned uninstall navigation tab did not accept normal closure.")
        }
      }
      for id in Array(directories.keys) {
        do {
          guard try await !manager.snapshot().extensions.contains(where: { $0.id == id }) else { continue }
          if let directory = directories.removeValue(forKey: id) { try? FileManager.default.removeItem(at: directory) }
          nonces.removeValue(forKey: id)
        } catch { failure = failure ?? error }
      }
      if owner.windowContext.isOpen, owner.store.tab(page.id)?.isClosed == false {
        owner.store.selectTab(id: page.id); owner.windowContext.show()
        do {
          try await wait("exact original owner restoration") {
            application.engine.pages[page.id] === page && page.reservedNativeTabID == sourceNativeID
              && owner.store.tab(page.id)?.url == sourceURL && page.url?.absoluteString == sourceURL
              && !page.isLoading && page.documentError == nil
          }
        } catch { failure = failure ?? error }
      } else { failure = failure ?? ShortcutError("The original uninstall fixture owner closed.") }
      if let failure { throw failure }
    }

    do {
      owner.store.selectTab(id: page.id); owner.windowContext.show()
      application.repository.focusWindow(owner.windowContext.id)
      application.extensionBrowser.windowFocusChanged()
      await application.extensionBrowser.waitForTopologyPublication()
      let primary = try await triggerWorker.evaluate("({id:chrome.runtime.id,incognito:chrome.extension.inIncognitoContext})", timeout: 10) as? [String: Any]
      guard primary?["id"] as? String == triggerWorker.extensionID, primary?["incognito"] as? Bool == false,
        try await manager.snapshot().extensions.contains(where: { $0.id == triggerWorker.extensionID && $0.isEnabled }) else {
        throw ShortcutError("The stable original uninstall trigger is not installed in the exact source profile.")
      }
      try await manager.setDeveloperMode(true)
      for phase in ["normal", "profile-fenced", "process-fenced", "resumed"] {
        currentPhase = phase; currentStage = "create-owned-package"; currentIdentifier = nil
        let directory = engine.dataDirectory.appendingPathComponent("AcceptanceUninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Owned uninstall navigation fixture",
          "version": "1.0", "background": ["service_worker": "worker.js"],
          "externally_connectable": ["ids": [triggerWorker.extensionID]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        let nonce = UUID().uuidString.lowercased()
        let script = """
          let consumed=false;
          chrome.runtime.onInstalled.addListener(()=>{});
          chrome.runtime.onMessageExternal.addListener((message,sender,sendResponse)=>{
            if(consumed||sender.id!==\(try literal(triggerWorker.extensionID))||
              message?.kind!=='zacro-owned-uninstall'||message.nonce!==\(try literal(nonce)))return false;
            consumed=true;sendResponse({accepted:true,identifier:chrome.runtime.id,nonce:\(try literal(nonce))});
            void chrome.management.uninstallSelf({showConfirmDialog:false});return false;
          });
          """
        try Data(script.utf8).write(to: directory.appendingPathComponent("worker.js"), options: .atomic)
        currentStage = "load-owned-package"
        let identifier = try await manager.loadUnpackedExtension(at: directory)
        currentIdentifier = identifier; directories[identifier] = directory; nonces[identifier] = nonce
        currentStage = "attach-original-target-worker"
        workers[identifier] = try await manager.workerSession(identifier)
        if phase == "profile-fenced" { lease = try engine.acquireAuxiliaryAdmission(profileID: profile, isPrivate: false) }
        if phase == "process-fenced" { lease = try CefAuxiliaryAdmissionLease.acquireProcess() }
        if phase.hasSuffix("fenced"), lease == nil { throw ShortcutError("No real admission lease for uninstall fixture.") }
        let destination = url.appendingPathComponent(prefix + phase).absoluteString
        let before = Set(application.store.state.tabs.map(\.id))
        try await uninstall(identifier, destination: destination)
        currentStage = "prove-original-native-removal-navigation-and-census"
        try require(try await !manager.snapshot().extensions.contains { $0.id == identifier },
          "uninstallOriginalNativeRemovalCompletes-" + phase)
        if lease != nil {
          try require(Set(application.store.state.tabs.map(\.id)) == before,
            "uninstallAdmissionSuppressesOptionalNavigation-" + phase)
          try lease?.release(); lease = nil
          _ = try await manager.snapshot()
          try require(!application.store.state.tabs.contains { $0.url == destination },
            "uninstallSuppressedNavigationDoesNotReplayAfterRelease-" + phase)
        } else {
          try await wait("real Core/native foreground uninstall document") {
            let fresh = application.store.state.tabs.filter { !before.contains($0.id) && !$0.isClosed && $0.url == destination }
            guard fresh.count == 1, let tab = fresh.first, let native = engine.pages[tab.id] else { return false }
            return tab.windowID == owner.windowContext.id && owner.store.state.activeTab?.id == tab.id
              && native.ownerWindowID == owner.windowContext.id && native.profileID == profile
              && native.reservedNativeTabID != nil && native.url?.absoluteString == destination
              && !native.isLoading && native.documentError == nil
          }
          try require(true, "uninstallOptionalNavigationOwnsRealCoreForegroundTab-" + phase)
        }
        try require(Set(application.windows.keys) == originalWindows
          && Set(engine.auxiliaryBrowsers(profileID: profile, isPrivate: false).map(\.id)) == originalAuxiliary,
          "uninstallCreatesNoUnmodeledPhysicalBrowser-" + phase)
      }
      try await cleanup()
      return checks
    } catch {
      let failure = error
      await diagnostics("scenario-failed-before-cleanup", error: error)
      let task = Task { @MainActor in
        do { try await cleanup() }
        catch { fputs("Native uninstall fixture retained owned cleanup: \(error.localizedDescription)\n", stderr) }
      }
      await task.value
      throw failure
    }
  }
}
