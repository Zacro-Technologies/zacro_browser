import AppKit
import SwiftUI
import ZacroCore

/// Diagnostic output is available only in the explicitly gated disposable
/// acceptance process. It never changes routing or recognizer decisions.
@MainActor private enum NativeSpaceGestureTrace {
  static let enabled = CommandLine.arguments.contains("--engine-acceptance")
    && CommandLine.arguments.contains("--native-integration-acceptance")
    && ProcessInfo.processInfo.environment["ZACRO_NATIVE_SPACE_INPUT_TRACE"] == "1"
  static func write(_ message: @autoclosure () -> String) {
    guard enabled else { return }
    fputs("Native space route: " + message() + "\n", stderr)
  }
}

@MainActor private protocol NativeSpaceGestureInterruptible: AnyObject {
  func cancelSpaceGesture()
  func inputDiagnosticSnapshot() -> String
}

/// Reads the actual installed rail only in the explicitly traced disposable
/// acceptance process. It never attaches a monitor or sends gesture input.
@MainActor enum NativeSpaceGestureDiagnostics {
  static func snapshot(of view: NSView) -> String? {
    guard NativeSpaceGestureTrace.enabled else { return nil }
    return (view as? NativeSpaceGestureInterruptible)?.inputDiagnosticSnapshot()
  }
}

@MainActor enum NativeSpaceGestureCancellation {
  static func cancel(in window: NSWindow) {
    guard let root = window.contentView else { return }
    func visit(_ view: NSView) {
      (view as? NativeSpaceGestureInterruptible)?.cancelSpaceGesture()
      for child in view.subviews { visit(child) }
    }
    visit(root)
  }
}

/// AppKit supplies real contact/momentum phases to the shared, tested recognizer.
struct SpaceGestureSurface<Content: View>: NSViewRepresentable {
  var index: Int
  var count: Int
  var contextKey: String
  var isEnabled = true
  var onProgress: (Double) -> Void
  var onSelect: (Int, Double) -> Void
  var onCancel: (() -> Void)? = nil
  @ViewBuilder var content: () -> Content
  func makeNSView(context: Context) -> SpaceScrollHost<Content> {
    let view = SpaceScrollHost(rootView: content())
    view.identifier = NSUserInterfaceItemIdentifier("NativeSpaceGestureSurface")
    configure(view); return view
  }
  func updateNSView(_ view: SpaceScrollHost<Content>, context: Context) {
    view.rootView = content(); configure(view)
  }
  private func configure(_ view: SpaceScrollHost<Content>) {
    if view.index != index || view.count != count || view.contextKey != contextKey { view.contextWillChange() }
    view.index = index; view.count = count; view.contextKey = contextKey
    view.isEnabled = isEnabled
    view.onProgress = onProgress; view.onSelect = onSelect; view.onCancel = onCancel
  }
  static func dismantleNSView(_ view: SpaceScrollHost<Content>, coordinator: ()) { view.detach() }
}

final class SpaceScrollHost<Content: View>: NSHostingView<Content>, NativeSpaceGestureInterruptible {
  var index = 0
  var count = 1
  var contextKey = ""
  var isEnabled = true {
    didSet { if oldValue && !isEnabled { contextWillChange() } }
  }
  var onProgress: (Double) -> Void = { _ in }
  var onSelect: (Int, Double) -> Void = { _, _ in }
  var onCancel: (() -> Void)?
  private var gesture = SpaceGesture()
  private var fallbackRelease: DispatchWorkItem?
  private weak var monitoredWindow: NSWindow?
  private var scrollMonitor: Any?
  private var cancellationObservers: [NSObjectProtocol] = []
  private var diagnosticMonitorCallbacks: UInt64 = 0
  private var diagnosticOwnedMonitorCallbacks: UInt64 = 0

  func inputDiagnosticSnapshot() -> String {
    guard NativeSpaceGestureTrace.enabled else { return "disabled" }
    return "host=\(ObjectIdentifier(self)) actualWindow=\(window?.windowNumber ?? -1) monitoredWindow=\(monitoredWindow?.windowNumber ?? -1) "
      + "exactWindowMatch=\(window != nil && monitoredWindow === window) hasMonitor=\(scrollMonitor != nil) enabled=\(isEnabled) index=\(index) count=\(count) "
      + "tracking=\(gesture.isTracking) pending=\(gesture.isPending) callbacks=\(diagnosticMonitorCallbacks) ownedCallbacks=\(diagnosticOwnedMonitorCallbacks) "
      + "hidden=\(isHiddenOrHasHiddenAncestor) bounds=\(bounds) visibleRect=\(visibleRect)"
  }

  override func layout() { super.layout(); hideScrollbars(in: self) }
  private func hideScrollbars(in root: NSView) {
    for child in root.subviews {
      if let scroll = child as? NSScrollView {
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
      }
      hideScrollbars(in: child)
    }
  }
  func contextWillChange() {
    guard gesture.isTracking || gesture.isPending else { return }
    fallbackRelease?.cancel(); fallbackRelease = nil
    _ = gesture.interrupt(at: ProcessInfo.processInfo.systemUptime)
    cancelPresentation()
  }
  func cancelSpaceGesture() {
    fallbackRelease?.cancel(); fallbackRelease = nil
    _ = gesture.interrupt(at: ProcessInfo.processInfo.systemUptime)
    cancelPresentation()
  }
  private func cancelPresentation() {
    if let onCancel { onCancel() } else { onProgress(0) }
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow { detach() }
    super.viewWillMove(toWindow: newWindow)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attach()
  }
  private func attach() {
    guard monitoredWindow !== window || scrollMonitor == nil else { return }
    detach()
    guard let window else { return }
    monitoredWindow = window
    // SwiftUI's nested NSScrollViews handle horizontal wheel events themselves
    // instead of forwarding them to this hosting view's responder. Observe the
    // exact rail before native dispatch; only recognized horizontal input is
    // consumed, so scrolling lists and clicking controls keep their own paths.
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
      var result: NSEvent? = event
      MainActor.assumeIsolated {
        guard let self else { return }
        if NativeSpaceGestureTrace.enabled {
          self.diagnosticMonitorCallbacks &+= 1
          if let window = self.window, event.window === window {
            self.diagnosticOwnedMonitorCallbacks &+= 1
          }
        }
        if self.receive(event) == true { result = nil }
      }
      return result
    }
    NativeSpaceGestureTrace.write("attach window=\(window.windowNumber) monitor=\(scrollMonitor != nil) host=\(ObjectIdentifier(self))")
    for name in [NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification,
      NSWindow.willMiniaturizeNotification] {
      cancellationObservers.append(NotificationCenter.default.addObserver(forName: name,
        object: window, queue: .main) { [weak self] notification in
        MainActor.assumeIsolated {
          if notification.name == NSWindow.willCloseNotification { self?.detach() }
          else { self?.cancelSpaceGesture() }
        }
      })
    }
    cancellationObservers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelSpaceGesture() }
    })
  }
  func detach() {
    if let window = monitoredWindow, scrollMonitor != nil {
      NativeSpaceGestureTrace.write("detach window=\(window.windowNumber) host=\(ObjectIdentifier(self))")
    }
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    scrollMonitor = nil; monitoredWindow = nil
    cancellationObservers.forEach(NotificationCenter.default.removeObserver)
    cancellationObservers.removeAll()
    fallbackRelease?.cancel(); fallbackRelease = nil
    // A new host attaches during SwiftUI's layout transaction. An idle detach
    // has no strip feedback to publish back into that transaction.
    contextWillChange()
  }
  private func receive(_ event: NSEvent) -> Bool {
    guard event.type == .scrollWheel, let window, monitoredWindow === window else { return false }
    let ownsEvent = event.window === window
    if ownsEvent {
      NativeSpaceGestureTrace.write("receive window=\(window.windowNumber) host=\(ObjectIdentifier(self)) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) ageMS=\((ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000) enabled=\(isEnabled) index=\(index) count=\(count) key=\(window.isKeyWindow) responder=\(window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil")")
    }
    guard isEnabled, event.window === window, window.isVisible, !window.isMiniaturized,
      window.attachedSheet == nil, NSApp.modalWindow == nil, !isHiddenOrHasHiddenAncestor,
      NSEvent.pressedMouseButtons == 0,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let root = window.contentView else {
      if ownsEvent {
        NativeSpaceGestureTrace.write("reject admission window=\(window.windowNumber) enabled=\(isEnabled) visible=\(window.isVisible) miniaturized=\(window.isMiniaturized) sheet=\(window.attachedSheet != nil) modal=\(NSApp.modalWindow != nil) hidden=\(isHiddenOrHasHiddenAncestor) mouseButtons=\(NSEvent.pressedMouseButtons) blockedModifiers=\(!event.modifierFlags.intersection([.command, .control, .option]).isEmpty) root=\(window.contentView != nil)")
      }
      contextWillChange(); return false
    }
    let point = convert(event.locationInWindow, from: nil)
    let rootPoint = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    guard bounds.contains(point), visibleRect.contains(point) else {
      NativeSpaceGestureTrace.write("reject bounds window=\(window.windowNumber) point=\(point) bounds=\(bounds) visible=\(visibleRect)")
      contextWillChange(); return false
    }
    let hit = root.hitTest(rootPoint)
    let hitsRail = hit.map { $0 === self || $0.isDescendant(of: self) } ?? false
    // Capture an admitted contact, just as AppKit latches a scroll sequence
    // to its initial view. Moving the strip exposes noninteractive previews
    // under the same pointer; their hit-test result must not cancel release.
    // A new contact still needs its own native descendant admission.
    let capturedContact = (gesture.isTracking || gesture.isPending) && !event.phase.contains(.began)
    guard hitsRail || capturedContact else {
      NativeSpaceGestureTrace.write("reject root-hit window=\(window.windowNumber) point=\(point)")
      contextWillChange(); return false
    }
    if capturedContact && !hitsRail {
      NativeSpaceGestureTrace.write("retain captured-contact window=\(window.windowNumber) phase=\(event.phase.rawValue) point=\(point)")
    }
    guard !isEditing(hit: hit, in: window) else {
      NativeSpaceGestureTrace.write("reject editing window=\(window.windowNumber) hit=\(hit.map { String(reflecting: type(of: $0)) } ?? "nil") responder=\(window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil")")
      contextWillChange(); return false
    }
    let phase: SpaceGesture.ContactPhase
    if event.phase.contains(.cancelled) { phase = .cancelled }
    else if event.phase.contains(.ended) { phase = .ended }
    else if event.phase.contains(.began) { phase = .began }
    else if event.phase.contains(.changed) || event.phase.contains(.stationary) { phase = .changed }
    else { phase = .none }
    let momentum: Bool? = !event.momentumPhase.isEmpty ? true : event.phase.isEmpty ? nil : false
    let result = gesture.update(.init(time: event.timestamp,
      deltaX: -Double(event.scrollingDeltaX), deltaY: -Double(event.scrollingDeltaY),
      width: Double(bounds.width), index: index, count: count, contextKey: contextKey,
      phase: phase, momentum: momentum,
      deltaMode: event.hasPreciseScrollingDeltas ? .pixels : .lines,
      shiftKey: event.modifierFlags.contains(.shift)))
    NativeSpaceGestureTrace.write("result window=\(window.windowNumber) phase=\(result.phase) consumed=\(result.consumed) progress=\(result.progress) origin=\(result.originIndex) selected=\(String(describing: result.selectedIndex)) released=\(result.didRelease)")
    apply(result)
    return result.consumed
  }
  private func isEditing(hit: NSView?, in window: NSWindow) -> Bool {
    if let editor = window.firstResponder as? NSText, editor.isEditable { return true }
    var candidate: NSView? = hit
    while let view = candidate {
      if let text = view as? NSText, text.isEditable { return true }
      if let field = view as? NSTextField, field.isEditable { return true }
      if view === self { break }
      candidate = view.superview
    }
    return false
  }
  private func apply(_ result: SpaceGesture.Output) {
    fallbackRelease?.cancel(); fallbackRelease = nil
    if result.didRelease, let selected = result.selectedIndex,
      result.contextKey == contextKey, result.originIndex == index {
      onSelect(selected, result.duration)
    } else if result.phase == .tracking || result.phase == .edge {
      onProgress(result.progress)
    } else if result.phase == .idle || result.phase == .blocked { cancelPresentation() }
    // Native fingers can pause indefinitely. Only devices with no contact phase
    // use the original quiet-release deadline; timers never end a held swipe.
    guard result.idleDelay > 0, !gesture.hasKnownContactPhase else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.apply(self.gesture.settle(at: ProcessInfo.processInfo.systemUptime))
    }
    fallbackRelease = work
    DispatchQueue.main.asyncAfter(deadline: .now() + result.idleDelay, execute: work)
  }
  deinit {
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    cancellationObservers.forEach(NotificationCenter.default.removeObserver)
    fallbackRelease?.cancel()
  }
}
