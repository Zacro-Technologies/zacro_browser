import AppKit

/// Presents actual owned AppKit alerts and completes their exact sheet model
/// operations. It neither creates browser/Core windows nor sends desktop input.
@MainActor enum NativeAuxiliaryTerminationRecoveryAcceptance {
  private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  @MainActor private final class State {
    var id: UUID? = UUID()
    var message = "Owned recovery fixture"
    var canCancel = true
    var cancellationFailures = 0
    var retries: [UUID] = []
    var cancellations: [UUID] = []
    var released: () -> Void = {}
    func capability() -> NativeAuxiliaryTerminationRecovery.Capability? {
      guard let id else { return nil }
      return .init(id: id, message: message, canCancelQuit: canCancel, retry: { [weak self] in
        guard let self, self.id == id else { throw CancellationError() }
        self.retries.append(id); self.id = nil; self.released()
      }, cancelQuit: { [weak self] in
        guard let self, self.id == id, self.canCancel else { throw CancellationError() }
        self.cancellations.append(id)
        if self.cancellationFailures > 0 {
          self.cancellationFailures -= 1
          throw Failure(message: "Owned admission release failed")
        }
        self.id = nil; self.released()
      })
    }
  }

  static func run() async throws -> [String] {
    guard CommandLine.arguments.contains("--native-integration-acceptance") else {
      throw Failure(message: "Auxiliary recovery acceptance requires the disposable application fixture.")
    }
    var checks: [String] = []
    var controllers: [NativeAuxiliaryTerminationRecovery] = []
    var windows: [NSWindow] = []
    var foreignTasks: [Task<NSApplication.ModalResponse, Never>] = []
    func require(_ condition: Bool, _ name: String) throws {
      fputs("Native auxiliary recovery check \(condition ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard condition else { throw Failure(message: "Auxiliary recovery acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ phase: String, _ condition: () -> Bool) async throws {
      let end = Date().addingTimeInterval(10)
      while Date() < end {
        try Task.checkCancellation()
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw Failure(message: "Auxiliary recovery acceptance timed out: " + phase)
    }
    func presented(_ controller: NativeAuxiliaryTerminationRecovery) -> Bool {
      guard let alert = controller.presentedAlert, let parent = controller.presentationWindow else { return false }
      return parent.isVisible && parent.attachedSheet === alert.window && alert.window.sheetParent === parent
    }
    func make(_ state: State, preferred: @escaping @MainActor () -> NSWindow? = { nil }) -> NativeAuxiliaryTerminationRecovery {
      let controller = NativeAuxiliaryTerminationRecovery(capability: { [weak state] in state?.capability() }, preferredWindow: preferred)
      state.released = { [weak controller] in controller?.cancel() }
      controllers.append(controller)
      return controller
    }
    func end(_ controller: NativeAuxiliaryTerminationRecovery, response: NSApplication.ModalResponse) throws {
      guard let parent = controller.presentationWindow, let alert = controller.presentedAlert,
        parent.attachedSheet === alert.window else { throw Failure(message: "The exact owned recovery sheet disappeared.") }
      parent.endSheet(alert.window, returnCode: response)
    }
    func visibleWindow() -> NSWindow {
      let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 320),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.identifier = NSUserInterfaceItemIdentifier("ZacroAuxiliaryRecoveryAcceptanceOwner:" + UUID().uuidString)
      window.orderFront(nil); windows.append(window)
      return window
    }
    func cleanup() async {
      controllers.forEach { $0.cancel() }
      foreignTasks.forEach { $0.cancel() }
      for task in foreignTasks { _ = await task.value }
      for controller in controllers { try? await wait("owned recovery cleanup") { !controller.hasPendingPresentation } }
      windows.forEach { $0.close() }
    }
    do {
      let firstState = State(), first = make(firstState)
      first.refresh()
      try await wait("fallback attached actual alert") { presented(first) }
      guard let fallback = first.presentationWindow, let firstAlert = first.presentedAlert else {
        throw Failure(message: "No actual owned fallback")
      }
      try require(first.usesFallbackWindow && firstAlert.buttons.map(\.title) == ["Retry", "Cancel Quit"],
        "auxiliaryRecoveryCreatesOwnedFallbackWithoutBrowserWindow")
      fallback.performClose(nil); fallback.close(); fallback.performMiniaturize(nil); fallback.miniaturize(nil)
      try require(fallback.isVisible && !fallback.isMiniaturized && !fallback.styleMask.contains(.closable)
        && !fallback.styleMask.contains(.miniaturizable),
        "auxiliaryRecoveryFallbackCannotCloseOrMiniaturizeUnresolvedFailure")
      try end(first, response: .alertFirstButtonReturn)
      try await wait("retry finishes and closes only fallback") { !first.hasPendingPresentation && !fallback.isVisible }
      try require(firstState.retries.count == 1 && firstState.cancellations.isEmpty,
        "auxiliaryRecoveryRetryDismissesOnlyOwnedFallback")

      let releaseState = State(); releaseState.cancellationFailures = 1
      let release = make(releaseState)
      release.refresh()
      try await wait("release failure initial controls") { presented(release) }
      let previousAlert = release.presentedAlert, releaseParent = release.presentationWindow
      try end(release, response: .alertSecondButtonReturn)
      try await wait("fresh controls after native release error") {
        presented(release) && release.presentedAlert !== previousAlert
          && release.presentedAlert?.informativeText.contains("Owned admission release failed") == true
      }
      try require(releaseState.id != nil && releaseState.cancellations.count == 1
        && release.presentationWindow === releaseParent
        && release.presentedAlert?.buttons.map(\.title) == ["Retry", "Cancel Quit"],
        "auxiliaryRecoveryCancelFailureRepresentsFreshRecoverableControls")
      try end(release, response: .alertSecondButtonReturn)
      try await wait("successful explicit cancellation closes recovery") { !release.hasPendingPresentation }
      try require(releaseState.id == nil && releaseState.cancellations.count == 2 && releaseState.retries.isEmpty,
        "auxiliaryRecoveryExplicitCancelReleaseCompletesExactlyOnce")

      let replacementState = State(), replacement = make(replacementState)
      let oldID = replacementState.id!
      replacement.refresh()
      try await wait("old failure sheet") { presented(replacement) }
      let oldAlert = replacement.presentedAlert!, oldParent = replacement.presentationWindow!
      let nextID = UUID(); replacementState.id = nextID; replacementState.message = "Replacement failure"
      replacement.refresh()
      // Race an old actual sheet response with replacement cancellation. Both
      // its task generation and fresh provider must prevent native invocation.
      if oldParent.attachedSheet === oldAlert.window { oldParent.endSheet(oldAlert.window, returnCode: .alertFirstButtonReturn) }
      try await wait("replacement waits then attaches its own sheet") {
        presented(replacement) && replacement.presentedCapabilityID == nextID && replacement.presentedAlert !== oldAlert
      }
      try require(replacementState.retries.isEmpty && replacementState.cancellations.isEmpty
        && !oldParent.isVisible && oldAlert.window.sheetParent == nil,
        "auxiliaryRecoveryReplacementWaitsForOldSheetAndRejectsOldResponse")
      try end(replacement, response: .alertFirstButtonReturn)
      try await wait("replacement retry completes") { !replacement.hasPendingPresentation }
      try require(replacementState.retries == [nextID] && !replacementState.retries.contains(oldID),
        "auxiliaryRecoveryOnlyCurrentFailureCanInvokeRetry")

      let foreignOwner = visibleWindow(), foreign = NSAlert()
      foreign.messageText = "Owned unrelated sheet fixture"; foreign.addButton(withTitle: "Done")
      let foreignTask = Task { @MainActor in await NativeWindowSheet.present(foreign, for: foreignOwner) }
      foreignTasks.append(foreignTask)
      try await wait("unrelated sheet attaches first") { foreignOwner.attachedSheet === foreign.window }
      let isolatedState = State(), isolated = make(isolatedState, preferred: { foreignOwner })
      isolated.refresh()
      try await wait("busy preferred window uses separate fallback") { presented(isolated) && isolated.usesFallbackWindow }
      let isolatedParent = isolated.presentationWindow!
      isolated.cancel()
      try await wait("controller cancels only its own sheet") { !isolated.hasPendingPresentation && !isolatedParent.isVisible }
      try require(foreignOwner.attachedSheet === foreign.window && foreign.window.sheetParent === foreignOwner
        && isolatedState.retries.isEmpty && isolatedState.cancellations.isEmpty && isolatedState.id != nil,
        "auxiliaryRecoveryCancellationDoesNotReleaseQuitOrDismissForeignSheet")
      foreignOwner.endSheet(foreign.window, returnCode: .alertFirstButtonReturn)
      _ = await foreignTask.value

      let modalOwner = visibleWindow(), modalState = State(), modalRecovery = make(modalState)
      var observedForeignModal = false
      modalRecovery.refresh()
      let modalTimer = Timer(timeInterval: 0.12, repeats: false) { _ in
        MainActor.assumeIsolated {
          observedForeignModal = NSApp.modalWindow === modalOwner
            && modalRecovery.presentedAlert == nil && modalState.id != nil
            && modalState.retries.isEmpty && modalState.cancellations.isEmpty
          // Only the fixture that owns this unrelated modal ends it.
          NSApp.stopModal(withCode: .OK)
        }
      }
      RunLoop.main.add(modalTimer, forMode: .common)
      let modalResponse = NSApp.runModal(for: modalOwner)
      modalTimer.invalidate(); modalOwner.orderOut(nil)
      try await wait("recovery resumes after unrelated application modal") { presented(modalRecovery) }
      try require(observedForeignModal && modalResponse == .OK,
        "auxiliaryRecoveryWaitsForForeignApplicationModalWithoutDismissingIt")
      modalRecovery.cancel()
      try await wait("application-modal waiting cleanup") { !modalRecovery.hasPendingPresentation }

      let disappearingOwner = visibleWindow(), disappearingState = State()
      let disappearing = make(disappearingState, preferred: { disappearingOwner })
      disappearing.refresh()
      try await wait("eligible Core-like owner is preferred") { presented(disappearing) && !disappearing.usesFallbackWindow }
      disappearingOwner.orderOut(nil)
      try await wait("disappearing owner transfers recovery to fallback") {
        presented(disappearing) && disappearing.usesFallbackWindow && disappearing.presentationWindow !== disappearingOwner
      }
      try require(disappearingState.id != nil && disappearingState.retries.isEmpty && disappearingState.cancellations.isEmpty,
        "auxiliaryRecoveryOwnerDisappearanceRetainsRecoveryOnFallback")
      disappearing.cancel()
      try await wait("disappearing-owner cleanup") { !disappearing.hasPendingPresentation }

      let reusedOwner = visibleWindow(), reusedState = State(), reused = make(reusedState, preferred: { reusedOwner })
      reused.refresh()
      try await wait("reusable owner presents initial failure") { presented(reused) && !reused.usesFallbackWindow }
      reusedOwner.close()
      try await wait("closed owner is excluded within current failure") { presented(reused) && reused.usesFallbackWindow }
      reusedOwner.orderFront(nil)
      reused.refresh()
      try await wait("same failure does not revive its closing owner") { presented(reused) && reused.usesFallbackWindow }
      reusedState.id = UUID(); reused.refresh()
      try await wait("later failure can use the intentionally reopened exact window") {
        presented(reused) && !reused.usesFallbackWindow && reused.presentationWindow === reusedOwner
      }
      try require(reusedState.retries.isEmpty && reusedState.cancellations.isEmpty,
        "auxiliaryRecoveryClosedOwnerExclusionEndsWithItsFailureEpisode")
      reused.cancel()
      try await wait("reopened-owner cleanup") { !reused.hasPendingPresentation }

      let finalState = State(), final = make(finalState)
      final.refresh()
      try await wait("pre-final cleanup can offer Cancel") { presented(final) }
      finalState.canCancel = false
      try end(final, response: .alertSecondButtonReturn)
      try await wait("fresh final-cleanup capability removes Cancel") {
        presented(final) && final.presentedAlert?.buttons.map(\.title) == ["Retry"]
      }
      try require(finalState.cancellations.isEmpty && finalState.id != nil,
        "auxiliaryRecoveryFinalCleanupOffersRetryWithoutCancelQuit")
      try end(final, response: .alertFirstButtonReturn)
      try await wait("final cleanup retry finishes") { !final.hasPendingPresentation }
      await cleanup()
      try require(controllers.allSatisfy { !$0.hasPendingPresentation && $0.presentedAlert == nil }
        && windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil },
        "auxiliaryRecoveryCleanupLeavesNoOwnedSheetOrWindow")
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }
}
