import AppKit
import Foundation
import ZacroChromium

/// Runs only against the disposable real-extension integration fixture. It
/// cancels genuine Chrome confirmation UI; it never accepts an uninstall.
@MainActor
enum NativeManagementAcceptance {
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  @MainActor private final class OperationState {
    var result: Result<Void, Error>?
    var completed: Bool { result != nil }
    var diagnostic: [String: Any] {
      switch result {
      case nil: return ["completed": false]
      case .some(.success): return ["completed": true, "result": "success"]
      case .some(.failure(let error)):
        let native = error as NSError
        return ["completed": true, "result": "failure", "type": String(describing: type(of: error)),
          "domain": native.domain, "code": native.code,
          "message": String(error.localizedDescription.prefix(1_000))]
      }
    }
  }

  static func check(manager: ChromeExtensionManager, identifier: String,
                    owner: ChromiumWindowContext) async throws -> [String: Bool] {
    owner.show()
    guard owner.isOpen, owner.window.isVisible, owner.window.attachedSheet == nil,
      NSApp.modalWindow == nil else { throw Failure("The management fixture owner is unavailable.") }
    let before = Set(NSApp.windows.map(ObjectIdentifier.init))
    let state = OperationState()
    let operation = Task {
      do {
        try await manager.uninstall(identifier, ownerWindowID: owner.id)
        state.result = .success(())
      } catch {
        state.result = .failure(error)
        throw error
      }
    }
    func dialogs() -> [NSWindow] {
      NSApp.windows.filter { window in
        !before.contains(ObjectIdentifier(window)) && window.isVisible
          && (window.sheetParent === owner.window || window.parent === owner.window)
      }
    }
    func windowDiagnostic(_ window: NSWindow) -> [String: Any] {
      var ancestors: [Int] = []
      var current = window.sheetParent ?? window.parent
      var seen = Set<ObjectIdentifier>()
      while let value = current, ancestors.count < 6, seen.insert(ObjectIdentifier(value)).inserted {
        ancestors.append(value.windowNumber)
        current = value.sheetParent ?? value.parent
      }
      return ["number": window.windowNumber, "class": String(describing: type(of: window)),
        "identifier": String((window.identifier?.rawValue ?? "").prefix(160)),
        "visible": window.isVisible, "miniaturized": window.isMiniaturized,
        "key": window.isKeyWindow, "main": window.isMainWindow,
        "level": window.level.rawValue, "alpha": window.alphaValue,
        "parent": window.parent?.windowNumber ?? -1, "sheetParent": window.sheetParent?.windowNumber ?? -1,
        "attachedSheet": window.attachedSheet?.windowNumber ?? -1, "ancestors": ancestors,
        "directExactOwner": window.sheetParent === owner.window || window.parent === owner.window,
        "newWindow": !before.contains(ObjectIdentifier(window)),
        "frame": ["x": window.frame.minX, "y": window.frame.minY,
          "width": window.frame.width, "height": window.frame.height]]
    }
    func log(_ phase: String) {
      let relevant = NSApp.windows.filter { window in
        !before.contains(ObjectIdentifier(window)) || window.sheetParent === owner.window || window.parent === owner.window
      }.prefix(12)
      let value: [String: Any] = ["phase": phase, "operation": state.diagnostic,
        "ownerID": owner.id, "ownerNativeID": owner.nativeID, "ownerOpen": owner.isOpen,
        "ownerClosing": owner.isClosing, "owner": windowDiagnostic(owner.window),
        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
        "mainWindow": NSApp.mainWindow?.windowNumber ?? -1,
        "modalWindow": NSApp.modalWindow?.windowNumber ?? -1,
        "exactDialogCount": dialogs().count, "windows": relevant.map(windowDiagnostic)]
      if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) {
        fputs("Native management acceptance \(phase): \(text)\n", stderr)
      }
    }
    do {
      log("started")
      let deadline = Date().addingTimeInterval(12)
      while dialogs().isEmpty && !state.completed && Date() < deadline {
        try await Task.sleep(for: .milliseconds(60))
      }
      guard !dialogs().isEmpty, !state.completed, NSApp.modalWindow == nil else {
        log("missing-exact-prompt")
        if let result = state.result, case .failure(let error) = result { throw error }
        if state.completed { throw Failure("Native uninstall completed before its exact-owner confirmation was observed.") }
        throw Failure("Chrome did not present the uninstall confirmation on its exact native owner.")
      }
      log("exact-prompt-visible")
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
      log("cancelled-and-closed")
      return ["nativeManagementUsesExactVisibleOwner": true,
        "nativeManagementWaitsForOriginalChromeConsent": true,
        "nativeManagementCancellationClosesOriginalPrompt": true,
        "nativeManagementCancellationPreservesInstallation": true]
    } catch {
      log("failed-before-cleanup")
      operation.cancel()
      _ = try? await operation.value
      log("cleanup-finished")
      throw error
    }
  }
}
