import AppKit
import ZacroChromium

/// Runs only against the disposable real-extension integration fixture. It
/// cancels genuine Chrome confirmation UI; it never accepts an uninstall.
@MainActor
enum NativeManagementAcceptance {
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  static func check(manager: ChromeExtensionManager, identifier: String,
                    owner: ChromiumWindowContext) async throws -> [String: Bool] {
    owner.show()
    guard owner.isOpen, owner.window.isVisible, owner.window.attachedSheet == nil,
      NSApp.modalWindow == nil else { throw Failure("The management fixture owner is unavailable.") }
    let before = Set(NSApp.windows.map(ObjectIdentifier.init))
    var completed = false
    let operation = Task {
      defer { completed = true }
      try await manager.uninstall(identifier, ownerWindowID: owner.id)
    }
    func dialogs() -> [NSWindow] {
      NSApp.windows.filter { window in
        !before.contains(ObjectIdentifier(window)) && window.isVisible
          && (window.sheetParent === owner.window || window.parent === owner.window)
      }
    }
    do {
      let deadline = Date().addingTimeInterval(12)
      while dialogs().isEmpty && !completed && Date() < deadline {
        try await Task.sleep(for: .milliseconds(60))
      }
      guard !dialogs().isEmpty, !completed, NSApp.modalWindow == nil else {
        throw Failure("Chrome did not present the uninstall confirmation on its exact native owner.")
      }
      let installedWhilePrompted = try await manager.snapshot().extensions.contains { $0.id == identifier }
      guard installedWhilePrompted else { throw Failure("Uninstall changed the installation before confirmation.") }
      operation.cancel()
      do {
        try await operation.value
        throw Failure("A cancelled native uninstall reported success.")
      } catch is CancellationError { }
      catch ChromeExtensionError.operationCancelled { }
      let closeDeadline = Date().addingTimeInterval(5)
      while !dialogs().isEmpty && Date() < closeDeadline {
        try await Task.sleep(for: .milliseconds(40))
      }
      guard dialogs().isEmpty, owner.window.attachedSheet == nil,
        try await manager.snapshot().extensions.contains(where: { $0.id == identifier }) else {
        throw Failure("Cancelling the native operation did not close its prompt and preserve the extension.")
      }
      return ["nativeManagementUsesExactVisibleOwner": true,
        "nativeManagementWaitsForOriginalChromeConsent": true,
        "nativeManagementCancellationClosesOriginalPrompt": true,
        "nativeManagementCancellationPreservesInstallation": true]
    } catch {
      operation.cancel()
      _ = try? await operation.value
      throw error
    }
  }
}
