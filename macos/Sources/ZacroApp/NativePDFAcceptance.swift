import Foundation
import ZacroChromium

/// Matches Chromium's EnsurePDFHasLoaded handshake in the real PDF extension
/// frame. A PDF MIME response or navigator.pdfViewerEnabled alone is insufficient.
@MainActor
enum NativePDFAcceptance {
  static func check(_ page: ChromiumPage,
    onLoaded: (@MainActor (CefDevTools, String) async throws -> Void)? = nil) async throws -> Bool {
    let browser = try await page.ready()
    let tools = browser.devTools
    let origin = "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai"
    let parent = try await tools.call("Target.getTargetInfo")
    guard let info = parent["targetInfo"] as? [String: Any] else {
      throw CefDevToolsError.invalidMessage
    }
    let contextID = info["browserContextId"] as? String
    // The stock framework deliberately prohibits browser-wide attachment.
    // Page-scoped auto-attach grants access only to this document's children.
    var attached: [String: (session: String, target: [String: Any])] = [:]
    var observedTargets: [[String: Any]] = []
    var lastTree: [String: Any] = [:]
    let observation = try tools.observeEvents { method, parameters in
      if method == "Target.attachedToTarget", let target = parameters["targetInfo"] as? [String: Any],
        let id = target["targetId"] as? String, let session = parameters["sessionId"] as? String {
        observedTargets = Array((observedTargets + [target]).suffix(8))
        attached[id] = (session, target)
      } else if method == "Target.detachedFromTarget", let id = parameters["targetId"] as? String {
        attached.removeValue(forKey: id)
      }
    }
    defer { tools.removeEventObserver(observation) }
    do {
      _ = try await tools.call("Target.setAutoAttach", parameters: ["autoAttach": true,
        "waitForDebuggerOnStart": false, "flatten": true,
        "filter": [["type": "iframe", "exclude": false], ["exclude": true]]])
      var session: String?
      let deadline = Date().addingTimeInterval(15)
      while session == nil && Date() < deadline {
        try Task.checkCancellation()
        guard browser === page.browser, page.url?.host == "127.0.0.1",
          page.url?.path == "/media/synthetic.pdf" else { throw CefDevToolsError.browserClosed }
        let tree = try await tools.call("Page.getFrameTree")
        lastTree = tree
        let frames = frameIDs(tree["frameTree"] as? [String: Any] ?? [:])
        let matches = attached.filter { id, candidate in
          guard candidate.target["type"] as? String == "iframe",
            let url = candidate.target["url"] as? String, url.hasPrefix(origin + "/"),
            candidate.target["browserContextId"] as? String == contextID else { return false }
          // PDF inner frame trees are omitted from the embedder's frameTree.
          // Chromium still supplies their actual parentFrameId in TargetInfo.
          return frames.contains(id)
            || (candidate.target["parentFrameId"] as? String).map { frames.contains($0) } == true
        }
        if matches.count == 1 { session = matches.values.first?.session }
        if session == nil { try await Task.sleep(for: .milliseconds(80)) }
      }
      guard let session else {
        let detail = try JSONSerialization.data(withJSONObject: ["tree": lastTree,
          "attached": observedTargets, "context": contextID ?? "default"], options: [.sortedKeys])
        throw CefDevToolsError.rejected("The owned PDF extension frame did not become available: " + String(decoding: detail, as: UTF8.self))
      }
      let loaded = try await tools.evaluate(#"""
        new Promise((resolve, reject) => {
          const origin = 'chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai';
          if (location.origin !== origin) { reject(new Error('Unexpected PDF viewer origin')); return; }
          const finish = value => { clearTimeout(timer); window.removeEventListener('message', receive); resolve(value); };
          const receive = event => {
            if (event.origin !== origin) return;
            if (event.data?.type === 'documentLoaded') finish(event.data.load_state === 'success');
            if (event.data?.type === 'passwordPrompted') finish(false);
          };
          const timer = setTimeout(() => finish(false), 12000);
          window.addEventListener('message', receive);
          window.postMessage({type: 'initialize'}, origin);
        })
        """#, sessionID: session) as? Bool
      if loaded == true { try await onLoaded?(tools, session) }
      _ = try await tools.call("Target.setAutoAttach", parameters: ["autoAttach": false, "waitForDebuggerOnStart": false, "flatten": true])
      return loaded == true
    } catch {
      _ = try? await tools.call("Target.setAutoAttach", parameters: ["autoAttach": false, "waitForDebuggerOnStart": false, "flatten": true])
      throw error
    }
  }

  private static func frameIDs(_ node: [String: Any]) -> Set<String> {
    var result = Set<String>()
    if let frame = node["frame"] as? [String: Any], let id = frame["id"] as? String { result.insert(id) }
    for child in node["childFrames"] as? [[String: Any]] ?? [] { result.formUnion(frameIDs(child)) }
    return result
  }
}
