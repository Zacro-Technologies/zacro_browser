import AppKit
import Foundation
import ZacroChromium

/// A document-scoped DOM event adapter. No binding is installed in the page's
/// main world, and a message never authorizes a different native document.
@MainActor
final class NativePeekLinkBridge {
  @MainActor private final class Submission {
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
      if let result { return try result.get() }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        self.continuation = continuation
      }
    }
    func finish(_ result: Result<Void, Error>) {
      guard self.result == nil else { return }
      self.result = result
      let continuation = self.continuation; self.continuation = nil
      continuation?.resume(with: result)
    }
  }
  private struct Frame: Equatable {
    let id: String
    let loaderID: String
    let url: String
  }
  private struct Context {
    let id: Int
    let uniqueID: String
    let frameID: String
  }
  private struct Armed {
    let frame: Frame
    let context: Context
    let nonce: String
    let observedSnapshot: NativePeekLinkSnapshot?
    let snapshot: NativePeekLinkSnapshot?
  }
  private weak var page: ChromiumPage?
  private let usesOwnedSession: () async throws -> Bool
  private let snapshot: () -> NativePeekLinkSnapshot?
  private let didRequest: (URL, CGPoint) -> Void
  private let worldName = "Zacro.Peek." + UUID().uuidString
  private let bindingName = "__zacroPeek_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  private var browser: CefBrowser?
  private var parentSessionID: String?
  private var sessionID: String?
  private var diagnosticRootSession = false
  private var eventToken: UUID?
  private var scriptID: String?
  private var attachmentTask: Task<String?, Error>?
  private var diagnosticScriptTask: Task<Void, Error>?
  private var pageEnableTask: Task<Void, Error>?
  private var startTask: Task<Void, Error>?
  private var bootstrapResult: Result<Void, Error>?
  private var bootstrapWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var refreshTask: Task<Void, Never>?
  private var cleanupTask: Task<Void, Never>?
  private var contexts: [Int: Context] = [:]
  // The document-start world is also created in subframes, where its script
  // exits immediately. Only a verified main-frame context receives a binding.
  // Cleanup must not scale with the number of unrelated iframe worlds.
  private var boundContexts: [String: Context] = [:]
  private var mainFrameID: String?
  private var armed: Armed?
  private var generation: UInt64 = 0
  private var desiredRevision: UInt64 = 0
  private var handledRevision: UInt64 = 0
  private var requestGeneration: UInt64 = 0
  private var lastSequence = 0
  private var started = false
  private var stopped = false

  var isArmed: Bool {
    guard let armed, let expected = armed.snapshot else { return false }
    return valid(expected) && contexts[armed.context.id]?.uniqueID == armed.context.uniqueID
  }

  init(page: ChromiumPage, usesOwnedSession: @escaping () async throws -> Bool,
    snapshot: @escaping () -> NativePeekLinkSnapshot?,
    didRequest: @escaping (URL, CGPoint) -> Void) {
    self.page = page; self.usesOwnedSession = usesOwnedSession
    self.snapshot = snapshot; self.didRequest = didRequest
  }

  func start() async throws {
    guard !stopped else { throw CancellationError() }
    try await beginStart().value
  }

  /// Browser-side PageHandler records document-start scripts synchronously
  /// when the native message is submitted. Its renderer acknowledgement can
  /// only arrive after the initial navigation; never wait for that here.
  func prepareBootstrap() async throws {
    guard !stopped else { throw CancellationError() }
    _ = beginStart()
    let token = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled || stopped { continuation.resume(throwing: CancellationError()) }
        else if let bootstrapResult { continuation.resume(with: bootstrapResult) }
        else { bootstrapWaiters[token] = continuation }
      }
    } onCancel: { [weak self] in
      Task { @MainActor in self?.bootstrapWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError()) }
    }
  }

  private func finishBootstrap(_ result: Result<Void, Error>) {
    guard bootstrapResult == nil else { return }
    bootstrapResult = result
    let waiters = bootstrapWaiters.values
    bootstrapWaiters.removeAll()
    for waiter in waiters { waiter.resume(with: result) }
  }

  private func beginStart() -> Task<Void, Error> {
    if let startTask { return startTask }
    let task = Task { @MainActor [weak self] in
      guard let self, let page = self.page else { throw CancellationError() }
      do {
        // Probe through the engine's initialized global broker, not a fresh
        // URL-less document whose unknown-method response needs a renderer.
        let usesOwnedSession = try await self.usesOwnedSession()
        guard !self.stopped else { throw CancellationError() }
        self.trace("start.waitReady")
        let browser = try await page.ready()
        guard !self.stopped, self.page === page, page.browser === browser else { throw CancellationError() }
        self.browser = browser
        self.trace("start.ready")
        // Own the complete session rather than adding a script to a shared
        // root session whose opaque identifier might remain pending forever
        // when a tab closes before its first renderer is created.
        let attachment = Task<String?, Error> { @MainActor in
          if !usesOwnedSession {
            // Only explicit stock diagnostic packages lack the custom broker.
            // Keep their post-load adapter usable, without claiming initial
            // document capture ordering or owned-session runtime acceptance.
            self.diagnosticRootSession = true
            return nil
          }
          guard !self.stopped else { throw CancellationError() }
          let info = try await browser.devTools.call("Target.getTargetInfo", timeout: 2)
          guard !self.stopped, !browser.isClosed,
            let target = info["targetInfo"] as? [String: Any],
            let targetID = target["targetId"] as? String, !targetID.isEmpty else { throw CancellationError() }
          let parentSessionID = try await browser.devTools.browserSession()
          self.parentSessionID = parentSessionID
          guard !self.stopped else { throw CancellationError() }
          let attached = try await browser.devTools.call("Target.attachToTarget",
            parameters: ["targetId": targetID, "flatten": true], timeout: 2, sessionID: parentSessionID)
          guard let sessionID = attached["sessionId"] as? String, !sessionID.isEmpty else {
            throw CefDevToolsError.invalidMessage
          }
          // Retain the exact ID even when stop happened during attachment.
          // Cleanup awaits only these browser-process calls, never a renderer.
          self.sessionID = sessionID
          return sessionID
        }
        self.attachmentTask = attachment
        let sessionID = try await attachment.value
        try self.requireLive(browser)
        self.eventToken = try browser.devTools.observeProtocolEvents { [weak self] method, params, source in
          guard source == sessionID else { return }
          self?.receive(method, params)
        }
        if self.diagnosticRootSession {
          self.trace("bootstrap.stockPostLoadOnly")
          self.finishBootstrap(.success(()))
        } else {
          // InspectorPageAgent only receives document-start instrumentation
          // after Page.enable. Queue that command first without waiting for a
          // renderer, then submit the script before permitting navigation.
          let submission = Submission()
          let enable = Task { @MainActor in
            do {
              _ = try await self.call("Page.enable", on: browser, onSubmitted: {
                self.trace("bootstrap.pageDomainSubmitted")
                submission.finish(.success(()))
              })
            } catch {
              submission.finish(.failure(error))
              throw error
            }
          }
          self.pageEnableTask = enable
          try await submission.wait()
          try self.requireLive(browser)
          // PageHandler persists this source in browser-originating state
          // before forwarding it to the renderer. Both submissions now precede
          // navigation; neither renderer response is part of that barrier.
          let result = try await self.call("Page.addScriptToEvaluateOnNewDocument", on: browser, parameters: [
            "worldName": self.worldName, "source": self.bootstrap,
          ], onSubmitted: { [weak self] in
            guard let self, !self.stopped else { return }
            self.trace("bootstrap.submitted")
            self.finishBootstrap(.success(()))
          })
          self.scriptID = result["identifier"] as? String
          guard self.scriptID != nil else { throw CefDevToolsError.invalidMessage }
          try await enable.value
        }
        try self.requireLive(browser)
        _ = try await self.call("Runtime.enable", on: browser)
        try self.requireLive(browser)
        if self.diagnosticRootSession {
          _ = try await self.call("Page.enable", on: browser)
          try self.requireLive(browser)
          // This path runs only after a renderer exists. Preserve its result
          // through cancellation so cleanup can remove the exact root script.
          let script = Task { @MainActor in
            let result = try await self.call("Page.addScriptToEvaluateOnNewDocument", on: browser,
              parameters: ["worldName": self.worldName, "source": self.bootstrap], timeout: 2)
            self.scriptID = result["identifier"] as? String
            guard self.scriptID != nil else { throw CefDevToolsError.invalidMessage }
          }
          self.diagnosticScriptTask = script
          try await script.value
          try self.requireLive(browser)
        }
        self.started = true
        self.refresh()
        await self.refreshTask?.value
        try self.requireLive(browser)
      } catch {
        self.finishBootstrap(.failure(error))
        _ = self.stop()
        throw error
      }
    }
    startTask = task
    return task
  }

  func refresh() {
    guard !stopped else { return }
    if hasCurrentObservation { return }
    desiredRevision &+= 1
    guard started, refreshTask == nil else { return }
    refreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.refreshTask = nil }
      while !self.stopped, self.handledRevision != self.desiredRevision {
        let revision = self.desiredRevision
        // Several layout/context notifications may arrive while the same
        // document's first installation is awaiting its renderer response.
        // Once that installation succeeds, consume the redundant revisions
        // without replacing its nonce. An already-intercepted trusted click
        // must not lose its authority to an identical second installation.
        if !self.hasCurrentObservation {
          do { try await self.armCurrentDocument() }
          catch { self.trace("arm.deferred \(error.localizedDescription)") }
        }
        self.handledRevision = revision
      }
    }
  }

  private var hasCurrentObservation: Bool {
    guard let armed, snapshot() == armed.observedSnapshot,
      page?.url?.absoluteString == armed.frame.url,
      contexts[armed.context.id]?.uniqueID == armed.context.uniqueID else { return false }
    return true
  }

  /// Revokes authority immediately. Await the returned cleanup when retaining
  /// and transferring a live page; actual document destruction needs no wait.
  @discardableResult func stop() -> Task<Void, Never> {
    if let cleanupTask { return cleanupTask }
    trace("stop.revoke")
    stopped = true; invalidate()
    finishBootstrap(.failure(CancellationError()))
    startTask?.cancel(); pageEnableTask?.cancel(); refreshTask?.cancel()
    let attachment = attachmentTask
    let diagnosticScript = diagnosticScriptTask
    let task = Task { @MainActor [self] in
      defer {
        if let eventToken { self.browser?.devTools.removeEventObserver(eventToken); self.eventToken = nil }
        contexts.removeAll(); boundContexts.removeAll(); self.browser = nil; sessionID = nil
        trace("stop.finished")
      }
      _ = try? await attachment?.value
      _ = try? await diagnosticScript?.value
      guard let browser, !browser.isClosed else { return }
      if eventToken == nil {
        // Stop may precede beginStart's observer installation. Even then, only
        // this exact session/world's cleanup lifecycle may be observed.
        let sourceSession = sessionID
        eventToken = try? browser.devTools.observeProtocolEvents { [weak self] method, params, source in
          guard source == sourceSession else { return }
          self?.receive(method, params)
        }
      }
      // Do not disable shared CDP domains. Remove only our own world state,
      // binding and document-start script.
      let bindingLiteral = String(decoding: try! JSONSerialization.data(withJSONObject: bindingName,
        options: [.fragmentsAllowed]), as: UTF8.self)
      var cleanupContexts = boundContexts
      do {
        // Native commands already submitted by a cancelled arm still run.
        // Keep observing their exact contexts, then reacquire the current
        // main frame's same private world. Never infer a unique context from
        // a reusable numeric ID or evaluate in the page's default world.
        _ = try await call("Runtime.enable", on: browser, timeout: 1)
        let current = try await frame(in: browser, timeout: 1)
        let world = try await call("Page.createIsolatedWorld", on: browser, parameters: [
          "frameId": current.id, "worldName": worldName,
        ], timeout: 1)
        guard let id = world["executionContextId"] as? Int, let context = contexts[id],
          context.frameID == current.id, try await frame(in: browser, timeout: 1) == current else {
          throw CancellationError()
        }
        mainFrameID = current.id
        cleanupContexts[context.uniqueID] = context
      } catch { trace("stop.currentWorldUnavailable \(error.localizedDescription)") }
      // The document-start bootstrap owns pagehide before arming adds its
      // binding. Rapid Back/Forward may stop between executionContextCreated
      // and that binding registration. Retire that already-observed exact
      // world too; unrelated/subframe worlds never enter this cleanup set.
      if let mainFrameID {
        for context in contexts.values where context.frameID == mainFrameID {
          cleanupContexts[context.uniqueID] = context
        }
      }
      trace("stop.dispose contexts=\(cleanupContexts.count)")
      for context in cleanupContexts.values {
        _ = try? await call("Runtime.evaluate", on: browser, parameters: [
          // Runtime.removeBinding removes the inspector registration, not the
          // JavaScript function. Abort the listener and remove that function
          // before a new owner installs its own isolated document adapter.
          "expression": "globalThis.__zacroPeekState?.dispose(); delete globalThis[\(bindingLiteral)]",
          "uniqueContextId": context.uniqueID, "returnByValue": true,
          "includeCommandLineAPI": false, "userGesture": false,
        ], timeout: 1)
      }
      if let sessionID {
        // TargetHandler destroys this exact child's browser-originating script
        // state synchronously. This also works before the first document exists
        // and before addScript returns its opaque identifier.
        _ = try? await browser.devTools.call("Target.detachFromTarget",
          parameters: ["sessionId": sessionID], timeout: 2, sessionID: parentSessionID)
      } else if diagnosticRootSession {
        _ = try? await call("Runtime.removeBinding", on: browser, parameters: ["name": bindingName], timeout: 1)
        if let scriptID {
          _ = try? await call("Page.removeScriptToEvaluateOnNewDocument", on: browser,
            parameters: ["identifier": scriptID], timeout: 1)
        }
      }
    }
    cleanupTask = task
    return task
  }

  private func requireLive(_ browser: CefBrowser) throws {
    guard !stopped, !browser.isClosed, self.browser === browser, page?.browser === browser else { throw CancellationError() }
  }

  private func call(_ method: String, on browser: CefBrowser, parameters: [String: Any] = [:],
    timeout: TimeInterval = 15, onSubmitted: (() -> Void)? = nil) async throws -> [String: Any] {
    trace("protocol.begin \(method)")
    do {
      guard sessionID != nil || diagnosticRootSession else { throw CefDevToolsError.unavailable }
      let result = try await browser.devTools.call(method, parameters: parameters, timeout: timeout,
        sessionID: sessionID, onSubmitted: onSubmitted)
      trace("protocol.end \(method)")
      return result
    } catch {
      trace("protocol.failed \(method): \(error.localizedDescription)")
      throw error
    }
  }

  private func trace(_ message: String) {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance") else { return }
    let state = snapshot()
    fputs("Peek adapter [\(page?.id ?? "retired")] t=\(ProcessInfo.processInfo.systemUptime) \(message)"
      + " snapshot=\(state != nil) visible=\(state?.visible == true) urlMatches=\(state?.sourceURL == page?.url?.absoluteString)\n", stderr)
  }

  private func valid(_ expected: NativePeekLinkSnapshot) -> Bool {
    guard !stopped, let page, let browser, !browser.isClosed, page.browser === browser,
      page.id == expected.pageID, page.profileID == expected.profileID,
      page.ownerWindowID == expected.ownerWindowID, page.documentError == nil,
      page.url?.absoluteString == expected.sourceURL, expected.visible,
      snapshot() == expected else { return false }
    return true
  }

  private func invalidate() {
    generation &+= 1; requestGeneration &+= 1
    armed = nil; lastSequence = 0
  }

  private func receive(_ method: String, _ params: [String: Any]) {
    if stopped {
      // Revocation is immediate; late renderer replies may contribute only
      // exact-world cleanup identities, never click or arming authority.
      switch method {
      case "Runtime.executionContextCreated", "Runtime.executionContextDestroyed",
        "Runtime.executionContextsCleared", "Page.frameNavigated", "Page.frameDetached": break
      default: return
      }
    }
    switch method {
    case "Runtime.executionContextCreated":
      guard let value = params["context"] as? [String: Any], value["name"] as? String == worldName,
        let id = value["id"] as? Int, let uniqueID = value["uniqueId"] as? String, !uniqueID.isEmpty,
        let aux = value["auxData"] as? [String: Any], let frameID = aux["frameId"] as? String,
        aux["isDefault"] as? Bool == false else { return }
      contexts[id] = Context(id: id, uniqueID: uniqueID, frameID: frameID)
      trace("event.worldCreated context=\(id) frame=\(frameID)")
      if !stopped { refresh() }
    case "Runtime.executionContextDestroyed":
      guard let id = params["executionContextId"] as? Int else { return }
      if let uniqueID = params["executionContextUniqueId"] as? String,
        contexts[id]?.uniqueID != uniqueID { return }
      if let context = contexts.removeValue(forKey: id) {
        boundContexts.removeValue(forKey: context.uniqueID)
      }
      if armed?.context.id == id { invalidate(); if !stopped { refresh() } }
    case "Runtime.executionContextsCleared":
      trace("event.contextsCleared")
      contexts.removeAll(); boundContexts.removeAll(); invalidate(); if !stopped { refresh() }
    case "Page.frameNavigated":
      guard let frame = params["frame"] as? [String: Any], frame["parentId"] == nil else { return }
      mainFrameID = frame["id"] as? String
      trace("event.mainFrameNavigated")
      invalidate(); if !stopped { refresh() }
    case "Page.navigatedWithinDocument":
      guard let frameID = params["frameId"] as? String, mainFrameID == frameID else { return }
      trace("event.withinDocument")
      invalidate(); refresh()
    case "Page.frameDetached":
      guard let frameID = params["frameId"] as? String, mainFrameID == frameID else { return }
      mainFrameID = nil
      invalidate()
    case "Runtime.bindingCalled": receiveClick(params)
    default: break
    }
  }

  private func frame(in browser: CefBrowser, timeout: TimeInterval = 15) async throws -> Frame {
    let result = try await call("Page.getFrameTree", on: browser, timeout: timeout)
    guard let tree = result["frameTree"] as? [String: Any], let value = tree["frame"] as? [String: Any],
      let id = value["id"] as? String, let loaderID = value["loaderId"] as? String,
      let url = value["url"] as? String, !id.isEmpty, !loaderID.isEmpty else { throw CefDevToolsError.invalidMessage }
    // Page.Frame.url excludes the fragment; the native tab and location.href
    // retain it. Hash routers must bind the same exact committed destination.
    return Frame(id: id, loaderID: loaderID, url: url + (value["urlFragment"] as? String ?? ""))
  }

  private func armCurrentDocument() async throws {
    guard let browser else { throw CancellationError() }
    try requireLive(browser)
    let epoch = generation
    let frame = try await frame(in: browser)
    try requireLive(browser)
    guard generation == epoch else { throw CancellationError() }
    mainFrameID = frame.id
    let world = try await call("Page.createIsolatedWorld", on: browser, parameters: [
      "frameId": frame.id, "worldName": worldName,
    ])
    try requireLive(browser)
    guard generation == epoch, let id = world["executionContextId"] as? Int,
      let context = contexts[id], context.frameID == frame.id else { throw CancellationError() }
    // Record before yielding: stop may happen while the native registration
    // is in flight and must still dispose its exact context after it drains.
    boundContexts[context.uniqueID] = context
    _ = try await call("Runtime.addBinding", on: browser, parameters: [
      "name": bindingName, "executionContextId": id,
    ])
    try requireLive(browser)
    guard generation == epoch, contexts[id]?.uniqueID == context.uniqueID else { throw CancellationError() }
    let current = snapshot()
    let expected = current.flatMap { valid($0) && $0.sourceURL == frame.url ? $0 : nil }
    let nonce = UUID().uuidString
    let configuration: Any
    if let expected {
      configuration = ["nonce": nonce, "sourceURL": expected.sourceURL,
        "pinnedURL": expected.pinnedURL.map { $0 as Any } ?? NSNull()]
    } else { configuration = NSNull() }
    let literal = String(decoding: try JSONSerialization.data(withJSONObject: configuration, options: [.fragmentsAllowed]), as: UTF8.self)
    let response = try await call("Runtime.evaluate", on: browser, parameters: [
      "expression": bootstrap + ";globalThis.__zacroPeekState.arm(\(literal));"
        + "({url:location.href,readyState:globalThis.__zacroPeekState.installedReadyState,hasBody:globalThis.__zacroPeekState.installedWithBody})",
      "uniqueContextId": context.uniqueID, "returnByValue": true,
      "includeCommandLineAPI": false, "userGesture": false,
    ])
    try requireLive(browser)
    let installation = (response["result"] as? [String: Any])?["value"] as? [String: Any]
    guard generation == epoch, contexts[id]?.uniqueID == context.uniqueID,
      response["exceptionDetails"] == nil,
      installation?["url"] as? String == frame.url,
      snapshot() == current, expected.map(valid) ?? true else { throw CancellationError() }
    // Hidden documents still have an observed model snapshot. Cache that
    // observation separately from the nil authorization, or every shell
    // layout would repeat native setup for every unchanged background tab.
    armed = Armed(frame: frame, context: context, nonce: nonce, observedSnapshot: current, snapshot: expected)
    lastSequence = 0
    trace("arm.finished authorized=\(expected != nil) installedReadyState=\(installation?["readyState"] as? String ?? "unknown") installedWithBody=\(installation?["hasBody"] as? Bool ?? true)")
  }

  private func receiveClick(_ params: [String: Any]) {
    guard params["name"] as? String == bindingName, let contextID = params["executionContextId"] as? Int,
      let armed, contextID == armed.context.id, contexts[contextID]?.uniqueID == armed.context.uniqueID,
      let expected = armed.snapshot, valid(expected), let browser,
      let payload = params["payload"] as? String, payload.utf8.count <= 32_768,
      let data = payload.data(using: .utf8), let click = try? JSONDecoder().decode(NativePeekLinkClick.self, from: data),
      click.nonce == armed.nonce, click.sequence > lastSequence, click.sequence <= 1_000_000_000,
      let destination = NativePeekLinkPolicy.destination(click, snapshot: expected) else { return }
    lastSequence = click.sequence; requestGeneration &+= 1
    trace("click.accepted kind=\(click.kind)")
    let request = requestGeneration, epoch = generation
    Task { @MainActor [weak self, weak browser] in
      guard let self, let browser else { return }
      do {
        let currentFrame = try await self.frame(in: browser)
        guard self.generation == epoch, self.requestGeneration == request,
          self.armed?.nonce == armed.nonce, self.contexts[contextID]?.uniqueID == armed.context.uniqueID,
          self.browser === browser, currentFrame == armed.frame, self.valid(expected),
          NativePeekLinkPolicy.destination(click, snapshot: expected) == destination else {
          self.trace("click.retired epoch=\(self.generation == epoch) request=\(self.requestGeneration == request)"
            + " nonce=\(self.armed?.nonce == armed.nonce) context=\(self.contexts[contextID]?.uniqueID == armed.context.uniqueID)"
            + " browser=\(self.browser === browser) frame=\(currentFrame == armed.frame) snapshot=\(self.valid(expected))")
          return
        }
        // DOM client coordinates are CSS pixels, unlike CEF context-menu
        // coordinates. Match Electron's getZoomFactor conversion once here.
        let zoom = pow(1.2, browser.zoomLevel)
        guard zoom.isFinite, zoom > 0 else { return }
        self.trace("click.dispatch kind=\(click.kind)")
        self.didRequest(destination, CGPoint(x: click.x * zoom, y: click.y * zoom))
      } catch { /* The exact document went away or changed before dispatch. */ }
    }
  }

  private var bootstrap: String {
    // Main-world code cannot read these globals, call the binding or replace
    // this world's DOM getters. All business decisions are checked in Swift.
    let name = String(decoding: try! JSONSerialization.data(withJSONObject: bindingName, options: [.fragmentsAllowed]), as: UTF8.self)
    return #"""
    (() => {
      if (globalThis.top !== globalThis || globalThis.__zacroPeekState) return;
      const controller = new AbortController();
      const state = { configuration: null, sequence: 0,
        installedReadyState: document.readyState, installedWithBody: Boolean(document.body),
        arm(value) { this.configuration = value; this.sequence = 0; },
        dispose() { this.configuration = null; controller.abort(); delete globalThis.__zacroPeekState; }
      };
      globalThis.__zacroPeekState = state;
      const binding = \#(name);
      function linkRequest(event, kind) {
        const config = state.configuration;
        if (!config || typeof globalThis[binding] !== 'function' || location.href !== config.sourceURL ||
            !event.isTrusted || event.button !== 0 || event.ctrlKey || event.metaKey) return null;
        if (kind === 'modified' ? event.shiftKey === event.altKey :
            event.shiftKey || event.altKey || event.defaultPrevented || !config.pinnedURL) return null;
        const link = event.composedPath().find(node => node?.tagName === 'A' && node.href);
        if (!link || link.hasAttribute('download')) return null;
        try {
          const url = new URL(link.href);
          if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.href.length > 8192) return null;
          if (kind === 'pinned') {
            if ((link.target && link.target.toLowerCase() !== '_self') || /(?:^|\s)(?:noopener|noreferrer)(?:\s|$)/i.test(link.rel || '')) return null;
            const home = new URL(config.pinnedURL);
            if (!['http:', 'https:'].includes(home.protocol) || home.username || home.password ||
                url.hostname.replace(/^www\./, '') === home.hostname.replace(/^www\./, '')) return null;
          }
          return { nonce: config.nonce, sequence: ++state.sequence, kind, sourceURL: location.href,
            url: url.href, trusted: event.isTrusted, button: event.button, shift: event.shiftKey,
            alt: event.altKey, control: event.ctrlKey, meta: event.metaKey, download: false,
            defaultPrevented: event.defaultPrevented, target: link.target || '', rel: link.rel || '',
            x: event.clientX, y: event.clientY };
        } catch { return null; }
      }
      window.addEventListener('click', event => {
        const request = linkRequest(event, 'modified');
        if (!request) return;
        event.preventDefault(); event.stopImmediatePropagation();
        globalThis[binding](JSON.stringify(request));
      }, { capture: true, signal: controller.signal });
      window.addEventListener('click', event => {
        const request = linkRequest(event, 'pinned');
        if (!request) return;
        event.preventDefault(); globalThis[binding](JSON.stringify(request));
      }, { signal: controller.signal });
      window.addEventListener('pagehide', () => { state.dispose(); }, { signal: controller.signal });
    })()
    """#
  }
}
