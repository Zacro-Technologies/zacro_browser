import AppKit

/// AppKit key ownership stays with the real document or editor. The logical
/// browser shell supplies main-window ownership for that same native family.
@MainActor
final class NativeBrowserFocusFamily {
  private let ownerForWindow: (NSWindow) -> NSWindow?
  private var observations: [NSObjectProtocol] = []
  private var pending = false
  private var generation = UUID()

  init(ownerForWindow: @escaping (NSWindow) -> NSWindow?) {
    self.ownerForWindow = ownerForWindow
    for name in [NSWindow.didBecomeMainNotification, NSApplication.didBecomeActiveNotification] {
      observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleReconciliation() }
      })
    }
    observations.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelPending() }
    })
  }

  func scheduleReconciliation() {
    guard !pending else { return }
    pending = true
    let token = generation
    // AppKit may make a Chrome child main after its didBecomeKey callback.
    // Reconcile once after that native ordering, including tracking modes.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == token else { return }
        self.pending = false
        self.reconcile()
      }
    }
  }

  private func cancelPending() { generation = UUID(); pending = false }

  private func isWithin(_ window: NSWindow, ancestor: NSWindow) -> Bool {
    var current: NSWindow? = window
    var visited = Set<ObjectIdentifier>()
    while let next = current, visited.insert(ObjectIdentifier(next)).inserted {
      if next === ancestor { return true }
      current = next.sheetParent ?? next.parent
    }
    return false
  }

  private func reconcile() {
    guard NSApp.isActive, let key = NSApp.keyWindow,
      key.isKeyWindow, key.isVisible, !key.isMiniaturized,
      let shell = ownerForWindow(key), shell.isVisible, !shell.isMiniaturized,
      shell.canBecomeMain else { return }
    if let modal = NSApp.modalWindow {
      guard ownerForWindow(modal) === shell, isWithin(key, ancestor: modal) else { return }
    }
    if let sheet = shell.attachedSheet, !isWithin(key, ancestor: sheet) { return }
    guard NSApp.mainWindow !== shell || !shell.isMainWindow else { return }
    // This public operation changes only main ownership. It must not make the
    // shell key, activate the app, or replace the document/editor responder.
    shell.makeMain()
  }

  deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}
