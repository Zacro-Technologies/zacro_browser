import AppKit
import SwiftUI

/// Renderer toggleSidebar keeps the explicit preference when Library alone
/// compresses the rail, and distinguishes shell actions from document keys.
enum NativeSidebarTogglePlan: Equatable {
  enum Focus: Equatable { case page, address, library }
  case closeLibrary(focus: Focus)
  case setVisible(Bool, focus: Focus)
  static func make(visiblePreference: Bool, effectiveWidth: Double, libraryOpen: Bool,
    fromPage: Bool) -> Self {
    if visiblePreference && effectiveWidth == 0 && libraryOpen {
      return .closeLibrary(focus: fromPage ? .page : .library)
    }
    let next = !visiblePreference
    return .setVisible(next, focus: fromPage || !next ? .page : .address)
  }
  var focus: Focus {
    switch self { case .closeLibrary(let focus), .setVisible(_, let focus): return focus }
  }
}

/// A dismissal handoff waits on the exact owned palette/sheet windows. It never
/// guesses a timing delay, traverses another browser's windows, or retries an
/// obsolete profile/selection intent after the user has moved elsewhere.
@MainActor final class NativeSidebarToggleHandoff: ObservableObject {
  weak private(set) var window: NSWindow?
  @MainActor private final class WeakWindow {
    weak var value: NSWindow?
    init(_ value: NSWindow) { self.value = value }
  }
  private var generation = UUID()
  private var blockers: [WeakWindow] = []
  private var valid: (() -> Bool)?
  private var ownsFocus: ((NSWindow?) -> Bool)?
  private var focus: (() -> Void)?
  private var ready: (() -> Bool)?
  private var armed = false
  private var hadOwnedFocus = false
  private var lastTrace: String?
  /// Access is confined to MainActor. A Sendable holder lets nonisolated
  /// deinitialization transfer cleanup to the main queue without moving raw
  /// AppKit observer tokens across executors or retaining the dying owner.
  private final class Registrations: @unchecked Sendable {
    var inputMonitor: Any?
    var observations: [NSObjectProtocol] = []
    @MainActor func removeAll() {
      if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
      observations.forEach(NotificationCenter.default.removeObserver)
      observations.removeAll()
    }
  }
  private let registrations = Registrations()
  var hasPending: Bool { focus != nil }

  func attach(_ window: NSWindow?) {
    if self.window !== window { cancel(); self.window = window }
  }
  func begin(blockingWindows: [NSWindow], ownsFocus: @escaping (NSWindow?) -> Bool,
    valid: @escaping () -> Bool, ready: @escaping () -> Bool = { true }, focus: @escaping () -> Void) {
    cancel()
    guard let window else { return }
    let token = generation
    self.valid = valid; self.focus = focus; self.ownsFocus = ownsFocus; self.ready = ready
    blockers = blockingWindows.filter { $0 !== window }.map(WeakWindow.init)
    if let key = NSApp.keyWindow { hadOwnedFocus = ownsFocus(key) }
    trace("begin ownedOrigin=\(hadOwnedFocus) blockers=\(blockers.count)")
    for watched in [window] + blockingWindows {
      for name in [NSWindow.didEndSheetNotification, NSWindow.didChangeOcclusionStateNotification,
        NSWindow.willCloseNotification] {
        registrations.observations.append(NotificationCenter.default.addObserver(forName: name, object: watched, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.generation == token else { return }
            self.retry()
          }
        })
      }
    }
    // Observe focus changes, never sweep other windows. A new foreground
    // owner permanently invalidates this dismissal even if focus later returns.
    for name in [NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification] {
      registrations.observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.generation == token else { return }
          self.retry()
        }
      })
    }
    let initiatingEvent = NSApp.currentEvent
    registrations.inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
      MainActor.assumeIsolated {
        if let self, self.generation == token, event !== initiatingEvent { self.cancel() }
      }
      return event
    }
    // The caller first dismisses its owned controls, then explicitly retries.
  }
  func retry() {
    guard armed, let focus else { return }
    guard let window, window.isVisible, valid?() == true else { trace("reject owner/context"); cancel(); return }
    // A dismissed child may briefly remain key after its parent link is gone.
    // Only a child captured by this exact intent may use the no-key fallback.
    let key = NSApp.keyWindow
    if let sheet = window.attachedSheet, !blockers.contains(where: { $0.value === sheet }) { trace("reject foreign owner sheet"); cancel(); return }
    if let key, key.sheetParent != nil, !blockers.contains(where: { $0.value === key }) { trace("reject foreign key sheet"); cancel(); return }
    let retiringOwnedControl = key.map { candidate in blockers.contains { $0.value === candidate } } ?? false
    let directlyOwned = ownsFocus?(key) == true
    if directlyOwned, key != nil { hadOwnedFocus = true }
    // A real native page can remain the main window while a non-main palette
    // takes key. Removing that exact palette can then leave a brief nil key.
    // Revalidate the exact owner from the captured owned origin; shell-main
    // status is not authority for a document/palette dismissal transaction.
    let ownedDismissalGap = hadOwnedFocus && !blockers.isEmpty
      && (retiringOwnedControl || key == nil) && ownsFocus?(window) == true
    guard directlyOwned || ownedDismissalGap else { trace("reject foreign key"); cancel(); return }
    guard ready?() == true, window.attachedSheet == nil, NSApp.modalWindow == nil,
      blockers.allSatisfy({ $0.value?.isVisible != true }) else { trace("wait owned dismissal"); return }
    trace("deliver focus")
    cancel()
    focus()
  }
  func activate() { armed = true; retry() }
  func cancel() {
    generation = UUID(); armed = false; valid = nil; focus = nil; ownsFocus = nil; ready = nil; blockers.removeAll()
    hadOwnedFocus = false; lastTrace = nil
    registrations.removeAll()
  }
  private func trace(_ message: String) {
    guard CommandLine.arguments.contains("--native-integration-acceptance"), lastTrace != message else { return }
    lastTrace = message
    fputs("Native sidebar toggle handoff: \(message) armed=\(armed) pending=\(focus != nil) visibleBlockers=\(blockers.filter { $0.value?.isVisible == true }.count)\n", stderr)
  }
  deinit {
    let registrations = registrations
    DispatchQueue.main.async { registrations.removeAll() }
  }
}

struct NativeSidebarToggleAnchor: NSViewRepresentable {
  let handoff: NativeSidebarToggleHandoff
  func makeNSView(context: Context) -> Anchor {
    let view = Anchor(frame: .zero); view.handoff = handoff; return view
  }
  func updateNSView(_ view: Anchor, context: Context) { handoff.attach(view.window) }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.handoff?.attach(nil) }
  final class Anchor: NSView {
    weak var handoff: NativeSidebarToggleHandoff?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); handoff?.attach(window) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
  }
}
