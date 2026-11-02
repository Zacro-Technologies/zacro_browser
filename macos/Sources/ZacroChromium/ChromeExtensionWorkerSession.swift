import Foundation
import CefKit

/// Process-local inspection of an actual extension worker, never a page shim.
/// The session is tied to the enabled installation and profile at attachment.
@MainActor
public final class ChromeExtensionWorkerSession {
  public let extensionID: String
  private let browser: CefBrowser
  private let installationID: String
  private let targetID: String
  private let workerToken: String
  private var uniqueContextID: String?
  private let parentSessionID: String
  private let sessionID: String
  private var closed = false

  init(browser: CefBrowser, extensionID: String, installationID: String, targetID: String, workerToken: String,
       parentSessionID: String, sessionID: String) {
    self.browser = browser; self.extensionID = extensionID; self.installationID = installationID
    self.targetID = targetID; self.workerToken = workerToken; self.parentSessionID = parentSessionID; self.sessionID = sessionID
  }

  deinit {
    guard !closed else { return }
    let browser = browser, sessionID = sessionID, parentSessionID = parentSessionID
    Task { @MainActor in
      _ = try? await browser.devTools.call("Target.detachFromTarget",
        parameters: ["sessionId": sessionID], sessionID: parentSessionID)
    }
  }

  /// Enable inspection only after Chromium reports the exact worker running.
  /// Runtime.enable publishes existing contexts before its response; this does
  /// not execute a readiness expression in a possibly uninitialized global.
  func prepareExecutionContext() async throws {
    try await validate()
    var contexts = Set<String>()
    let observer = try browser.devTools.observeProtocolEvents { [sessionID] method, parameters, source in
      guard source == sessionID, method == "Runtime.executionContextCreated",
        let context = parameters["context"] as? [String: Any],
        let uniqueID = context["uniqueId"] as? String, !uniqueID.isEmpty else { return }
      contexts.insert(uniqueID)
    }
    defer { browser.devTools.removeEventObserver(observer) }
    _ = try await browser.devTools.call("Runtime.enable", sessionID: sessionID)
    try await validate()
    guard contexts.count == 1, let context = contexts.first else { throw ChromeExtensionError.invalidResponse }
    uniqueContextID = context
  }

  public func evaluate(_ expression: String, userGesture: Bool = false, timeout: TimeInterval = 30) async throws -> Any? {
    try await validate()
    guard let uniqueContextID else { throw ChromeExtensionError.managementUnavailable }
    let result = try await browser.devTools.evaluate(expression, userGesture: userGesture,
      timeout: timeout, sessionID: sessionID, uniqueContextID: uniqueContextID)
    try await validate()
    return result
  }

  private func validate() async throws {
    guard !closed else { throw CefDevToolsError.browserClosed }
    let current = try await browser.devTools.call("Zacro.extensionWorkerTarget", parameters: ["id": extensionID])
    try Task.checkCancellation()
    guard !closed else { throw CefDevToolsError.browserClosed }
    guard current["installationID"] as? String == installationID,
      current["targetID"] as? String == targetID,
      current["workerToken"] as? String == workerToken else { throw ChromeExtensionError.managementUnavailable }
  }

  public func close() async {
    guard !closed else { return }; closed = true
    _ = try? await browser.devTools.call("Target.detachFromTarget",
      parameters: ["sessionId": sessionID], sessionID: parentSessionID)
  }
}
