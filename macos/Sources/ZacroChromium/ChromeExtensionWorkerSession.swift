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
  private let parentSessionID: String
  private let sessionID: String
  private var closed = false

  init(browser: CefBrowser, extensionID: String, installationID: String, targetID: String,
       parentSessionID: String, sessionID: String) {
    self.browser = browser; self.extensionID = extensionID; self.installationID = installationID
    self.targetID = targetID; self.parentSessionID = parentSessionID; self.sessionID = sessionID
  }

  deinit {
    guard !closed else { return }
    let browser = browser, sessionID = sessionID, parentSessionID = parentSessionID
    Task { @MainActor in
      _ = try? await browser.devTools.call("Target.detachFromTarget",
        parameters: ["sessionId": sessionID], sessionID: parentSessionID)
    }
  }

  public func evaluate(_ expression: String, userGesture: Bool = false, timeout: TimeInterval = 30) async throws -> Any? {
    try await validate()
    let result = try await browser.devTools.evaluate(expression, userGesture: userGesture,
      timeout: timeout, sessionID: sessionID)
    try await validate()
    return result
  }

  private func validate() async throws {
    guard !closed else { throw CefDevToolsError.browserClosed }
    let current = try await browser.devTools.call("Zacro.extensionWorkerTarget", parameters: ["id": extensionID])
    guard current["installationID"] as? String == installationID,
      current["targetID"] as? String == targetID else { throw ChromeExtensionError.managementUnavailable }
  }

  public func close() async {
    guard !closed else { return }; closed = true
    _ = try? await browser.devTools.call("Target.detachFromTarget",
      parameters: ["sessionId": sessionID], sessionID: parentSessionID)
  }
}
