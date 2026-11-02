import AppKit

/// Uses non-presented owned windows with a test visibility predicate. No sheet
/// or desktop input is opened; these checks cover asynchronous view ownership.
@MainActor
enum NativeWindowDialogOwnerAcceptance {
  static func check() async -> [String: Bool] {
    let first = window(), second = window()
    defer { first.close(); second.close() }
    let owner = NativeWindowDialogOwner()
    let anchor = NativeWindowDialogAnchor.Anchor(frame: .zero)
    anchor.owner = owner
    first.contentView?.addSubview(anchor)
    let firstGate = Gate(), secondGate = Gate()
    var firstContext: NativeWindowDialogOwner.Context?
    var secondContext: NativeWindowDialogOwner.Context?
    var firstAccepted: Bool?, secondAccepted: Bool?
    owner.perform { context in
      firstContext = context
      await firstGate.wait()
      firstAccepted = context.isCurrent
    }
    await until { firstContext != nil }
    anchor.removeFromSuperview()
    second.contentView?.addSubview(anchor)
    owner.perform { context in
      secondContext = context
      await secondGate.wait()
      secondAccepted = context.isCurrent
    }
    await until { secondContext != nil }
    firstGate.release()
    await until { firstAccepted != nil }
    owner.cancel()
    secondGate.release()
    await until { secondAccepted != nil }
    anchor.removeFromSuperview()
    var detachedRan = false
    owner.perform { _ in detachedRan = true }
    await Task.yield()
    return [
      "native_dialog_binds_exact_initiating_view_window": firstContext?.window === first && secondContext?.window === second,
      "native_dialog_reparenting_rejects_old_completion": firstAccepted == false,
      "native_dialog_cancellation_rejects_pending_completion": secondAccepted == false,
      "native_dialog_detached_view_cannot_present": !detachedRan,
    ]
  }

  private static func until(_ predicate: () -> Bool) async {
    for _ in 0..<30 {
      if predicate() { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
  private static func window() -> VisibleTestWindow {
    let value = VisibleTestWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: false)
    value.isReleasedWhenClosed = false
    return value
  }
  private final class VisibleTestWindow: NSWindow {
    override var isVisible: Bool { true }
  }
  private final class Gate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      if released { return }
      await withCheckedContinuation { continuation = $0 }
    }
    func release() {
      released = true
      let value = continuation; continuation = nil
      value?.resume()
    }
  }
}
