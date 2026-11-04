import AppKit

/// Owns only the failed-Quit recovery presentation. Native admission authority
/// remains in the injected, freshly read capability closures at the root.
@MainActor final class NativeAuxiliaryTerminationRecovery {
  typealias Operation = @MainActor () async throws -> Void
  @MainActor struct Capability {
    /// UI episode identity only; it is not a native admission/termination token.
    let id: UUID
    let message: String
    let canCancelQuit: Bool
    let retry: Operation
    let cancelQuit: Operation
  }

  private let capability: @MainActor () -> Capability?
  private let preferredWindow: @MainActor () -> NSWindow?
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var presentation: Presentation?
  @MainActor private final class WeakClosedOwner {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
  }
  private var closedOwners: [WeakClosedOwner] = []
  private var closedOwnerEpisode: UUID?

  var presentedAlert: NSAlert? { presentation?.alert }
  var presentationWindow: NSWindow? { presentation?.parent.window }
  var presentedCapabilityID: UUID? { presentation?.capabilityID }
  var usesFallbackWindow: Bool { presentation?.parent.fallback != nil }
  var hasPendingPresentation: Bool { task != nil }

  init(capability: @escaping @MainActor () -> Capability?,
    preferredWindow: @escaping @MainActor () -> NSWindow?) {
    self.capability = capability; self.preferredWindow = preferredWindow
  }

  /// Cancels only this controller's exact sheet Task. The replacement awaits
  /// its completion before attaching another sheet, including cancellation's
  /// asynchronously dispatched AppKit endSheet completion.
  func refresh(error: Error? = nil) {
    replace(with: error?.localizedDescription, shouldPresent: true)
  }
  func cancel() { replace(with: nil, shouldPresent: false) }

  private func replace(with initialError: String?, shouldPresent: Bool) {
    let token = UUID(); generation = token
    let old = task; old?.cancel()
    task = Task { @MainActor [weak self] in
      await old?.value
      guard !Task.isCancelled, self?.generation == token else { return }
      var parent: Parent?
      var lastError = initialError
      var errorEpisode: UUID?
      defer {
        parent?.finishFallback()
        if self?.generation == token { self?.task = nil }
      }
      guard shouldPresent else { return }
      while !Task.isCancelled, self?.generation == token {
        guard self?.capability() != nil else { break }
        // An unrelated application-modal security dialog is not ours to end.
        // Retain the intent without immediately re-presenting a refused sheet.
        if NSApp.modalWindow != nil || NSApp.isHidden {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
          continue
        }
        guard let request = self?.prepare(token: token, parent: &parent,
          error: lastError, errorEpisode: errorEpisode) else { break }
        let response = await NativeWindowSheet.present(request.alert, for: request.parent.window)
        request.removeObservations()
        if self?.presentation === request { self?.presentation = nil }
        // Task/owner cancellation only dismisses UI. It never means the user
        // pressed Cancel Quit and must never release a held native fence.
        guard !Task.isCancelled, self?.generation == token else { break }
        guard let decision = self?.decision(response, request: request, token: token) else { break }
        switch decision {
        case .stop: return
        case .refresh:
          lastError = nil; errorEpisode = nil
        case .perform(let operation):
          do {
            try await operation()
            lastError = nil; errorEpisode = nil
          } catch {
            lastError = error.localizedDescription
            errorEpisode = request.capabilityID
          }
        }
      }
    }
  }

  private func prepare(token: UUID, parent: inout Parent?, error: String?,
    errorEpisode: UUID?) -> Presentation? {
    guard generation == token, !Task.isCancelled, let failure = capability() else { return nil }
    if closedOwnerEpisode != failure.id {
      closedOwners.removeAll(); closedOwnerEpisode = failure.id
    } else { closedOwners.removeAll { $0.window == nil } }
    let selected: Parent
    if let preferred = preferredWindow(), eligible(preferred) {
      selected = parent?.window === preferred ? parent! : Parent(window: preferred)
    } else if let current = parent, current.fallback != nil, eligible(current.window) {
      selected = current
    } else {
      let fallback = RecoveryWindow()
      fallback.center(); fallback.makeKeyAndOrderFront(nil)
      selected = Parent(window: fallback, fallback: fallback)
    }
    if parent !== selected { parent?.finishFallback(); parent = selected }
    guard selected.window.isVisible, selected.window.attachedSheet == nil else { return nil }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Authorization windows could not finish closing"
    var details = [failure.message]
    if let error, errorEpisode == nil || errorEpisode == failure.id,
      !error.isEmpty, error != failure.message { details.append(error) }
    alert.informativeText = String(details.filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(8192))
    alert.addButton(withTitle: "Retry")
    if failure.canCancelQuit {
      alert.addButton(withTitle: "Cancel Quit").keyEquivalent = "\u{1b}"
    }
    alert.window.identifier = NSUserInterfaceItemIdentifier("ZacroAuxiliaryTerminationRecovery:" + token.uuidString)
    let request = Presentation(parent: selected, alert: alert, capabilityID: failure.id,
      offeredCancel: failure.canCancelQuit)
    presentation = request
    request.observeOwner { [weak self, weak request] closing in
      guard let self, let request, self.generation == token, self.presentation === request else { return }
      if closing, !self.closedOwners.contains(where: { $0.window === request.parent.window }) {
        self.closedOwners.append(WeakClosedOwner(request.parent.window))
      }
      self.refresh()
    }
    return request
  }

  private func eligible(_ window: NSWindow) -> Bool {
    window.isVisible && !window.isMiniaturized && window.sheetParent == nil
      && window.attachedSheet == nil && !closedOwners.contains(where: { $0.window === window })
  }
  private enum Decision { case stop, refresh, perform(Operation) }
  private func decision(_ response: NSApplication.ModalResponse, request: Presentation,
    token: UUID) -> Decision {
    guard generation == token, !Task.isCancelled, let fresh = capability() else { return .stop }
    guard fresh.id == request.capabilityID else { return .refresh }
    if response == .alertFirstButtonReturn { return .perform(fresh.retry) }
    if response == .alertSecondButtonReturn, request.offeredCancel, fresh.canCancelQuit {
      return .perform(fresh.cancelQuit)
    }
    return .refresh
  }

  @MainActor private final class Parent {
    let window: NSWindow
    let fallback: RecoveryWindow?
    init(window: NSWindow, fallback: RecoveryWindow? = nil) { self.window = window; self.fallback = fallback }
    func finishFallback() { fallback?.finishWhenUnblocked() }
  }
  @MainActor private final class Presentation {
    let parent: Parent
    let alert: NSAlert
    let capabilityID: UUID
    let offeredCancel: Bool
    private var observations: [NSObjectProtocol] = []
    private var visibilityTimer: Timer?
    init(parent: Parent, alert: NSAlert, capabilityID: UUID, offeredCancel: Bool) {
      self.parent = parent; self.alert = alert; self.capabilityID = capabilityID; self.offeredCancel = offeredCancel
    }
    func observeOwner(_ changed: @escaping @MainActor (Bool) -> Void) {
      observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
        object: parent.window, queue: .main) { _ in MainActor.assumeIsolated { changed(true) } })
      observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
        object: parent.window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            if self?.parent.window.isVisible == false { changed(false) }
          }
        })
      // A parked shell can already be fully occluded; orderOut then changes
      // isVisible without an occlusion notification. Watch only this exact
      // recovery owner while its sheet is pending, including tracking modes.
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          if self?.parent.window.isVisible == false { changed(false) }
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      visibilityTimer = timer
    }
    func removeObservations() {
      visibilityTimer?.invalidate(); visibilityTimer = nil
      observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
    }
  }
  private final class RecoveryWindow: NSWindow {
    private var mayClose = false
    private var closeAfterSheet: NSObjectProtocol?
    init() {
      super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
        styleMask: [.titled], backing: .buffered, defer: false)
      title = "Zacro"
      identifier = NSUserInterfaceItemIdentifier("ZacroAuxiliaryTerminationRecoveryOwner")
      isReleasedWhenClosed = false
    }
    override func performClose(_ sender: Any?) {}
    override func performMiniaturize(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
    override func close() { if mayClose { super.close() } }
    func finishWhenUnblocked() {
      // Even this exclusively owned fallback must not close an unrelated
      // sheet that may have appeared after our own presentation completed.
      guard attachedSheet == nil else {
        if closeAfterSheet == nil {
          closeAfterSheet = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
            object: self, queue: .main) { [self] _ in MainActor.assumeIsolated { finishWhenUnblocked() } }
        }
        return
      }
      if let closeAfterSheet { NotificationCenter.default.removeObserver(closeAfterSheet); self.closeAfterSheet = nil }
      mayClose = true; super.close()
    }
  }

  deinit { task?.cancel() }
}
