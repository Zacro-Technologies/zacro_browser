import Foundation

extension CefBrowser {
  /// Terminal for this exact native request context. Call only after Core has
  /// durably authorized profile deletion (or retired the last private owner),
  /// while a hidden maintenance document still owns the request context.
  /// Failure/cancellation leaves the native fence active and must keep the
  /// durable retirement receipt pending; it must never revive a deleted profile.
  @MainActor public func retireProfileDownloads() async throws {
    let deadline = Date().addingTimeInterval(30)
    repeat {
      try Task.checkCancellation()
      let response = try await devTools.call("Zacro.retireProfileDownloads", timeout: 5)
      guard response["retiring"] as? Bool == true,
        let initialized = response["initialized"] as? Bool,
        let pending = response["pending"] as? Int, pending >= 0,
        let settled = response["settled"] as? Bool,
        settled == (initialized && pending == 0) else {
        throw CefDevToolsError.invalidMessage
      }
      if settled { return }
      try await Task.sleep(for: .milliseconds(80))
    } while Date() < deadline
    throw CefDevToolsError.rejected("Native downloads have not finished retiring. The profile deletion remains pending.")
  }
}
