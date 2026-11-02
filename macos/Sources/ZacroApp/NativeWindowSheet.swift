import AppKit

/// A window-owned native dialog that leaves other browser windows usable.
/// Cancellation and owner closure complete the request exactly once.
@MainActor
enum NativeWindowSheet {
  private static var presentations: [UUID: Presentation] = [:]

  /// Chromium parks the shell with orderOut when its logical window closes.
  /// That does not emit NSWindow.willCloseNotification, including for sheets
  /// belonging to an editor attached to the shell.
  static func cancel(for owner: NSWindow) {
    let identity = ObjectIdentifier(owner)
    for presentation in Array(presentations.values) where presentation.owners.contains(identity) {
      presentation.cancel()
    }
  }

  static func present(_ alert: NSAlert, for owner: NSWindow) async -> NSApplication.ModalResponse {
    await present(window: alert.window, owner: owner) { completion in
      alert.beginSheetModal(for: owner, completionHandler: completion)
    }
  }

  static func present(_ panel: NSSavePanel, for owner: NSWindow) async -> NSApplication.ModalResponse {
    await present(window: panel, owner: owner) { completion in
      panel.beginSheetModal(for: owner, completionHandler: completion)
    }
  }

  private static func present(window: NSWindow, owner: NSWindow,
    begin: (@escaping (NSApplication.ModalResponse) -> Void) -> Void) async -> NSApplication.ModalResponse {
    guard !Task.isCancelled, owner.isVisible, owner.attachedSheet == nil,
      NSApp.modalWindow == nil else { return .cancel }
    let presentation = Presentation(window: window, owner: owner)
    presentations[presentation.id] = presentation
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        presentation.begin(continuation: continuation, start: begin)
      }
    } onCancel: {
      Task { @MainActor in presentation.cancel() }
    }
  }

  @MainActor private final class Presentation {
    let id = UUID()
    let window: NSWindow
    let owners: Set<ObjectIdentifier>
    private weak var owner: NSWindow?
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    private var closeObserver: NSObjectProtocol?
    private var cancelled = false
    private var finished = false

    init(window: NSWindow, owner: NSWindow) {
      self.window = window; self.owner = owner
      var ancestors = Set<ObjectIdentifier>(), current: NSWindow? = owner
      while let ancestor = current, ancestors.insert(ObjectIdentifier(ancestor)).inserted {
        current = ancestor.sheetParent ?? ancestor.parent
      }
      owners = ancestors
    }

    func begin(continuation: CheckedContinuation<NSApplication.ModalResponse, Never>,
      start: (@escaping (NSApplication.ModalResponse) -> Void) -> Void) {
      self.continuation = continuation
      guard !cancelled, let owner, owner.isVisible, owner.attachedSheet == nil else {
        complete(.cancel); return
      }
      closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
        object: owner, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancel() }
      }
      start { [self] result in complete(result) }
    }

    func cancel() {
      guard !finished else { return }
      cancelled = true
      if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
      else if continuation != nil { complete(.cancel) }
    }

    private func complete(_ result: NSApplication.ModalResponse) {
      guard !finished else { return }
      finished = true
      NativeWindowSheet.presentations.removeValue(forKey: id)
      if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
      let response = continuation; continuation = nil
      response?.resume(returning: cancelled ? .cancel : result)
    }

    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
  }
}
