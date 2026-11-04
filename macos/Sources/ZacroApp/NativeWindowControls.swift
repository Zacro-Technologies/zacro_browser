import AppKit
import SwiftUI
import ZacroChromium

/// The reserved space in the navigation row is the geometry authority for the
/// real macOS window controls. Their native views, actions and hit targets stay
/// in AppKit's titlebar; only their position changes.
struct NativeWindowControlsAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> NativeWindowControlsAnchorView {
    NativeWindowControlsAnchorView()
  }
  func updateNSView(_ view: NativeWindowControlsAnchorView, context: Context) {
    view.scheduleAlignment()
  }
  static func dismantleNSView(_ view: NativeWindowControlsAnchorView, coordinator: ()) {
    view.detach()
  }
}

@MainActor
final class NativeWindowControlsAnchorView: NSView {
  static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
  @MainActor private final class OriginalControl {
    weak var button: NSButton?
    weak var parent: NSView?
    let frame: CGRect
    let horizontalOffset: CGFloat
    init(button: NSButton, root: NSView, leading: CGFloat) {
      self.button = button
      parent = button.superview
      frame = button.frame
      horizontalOffset = root.convert(button.bounds, from: button).minX - leading
    }
  }
  private weak var observedWindow: NSWindow?
  private var original: [OriginalControl] = []
  private var observations: [NSObjectProtocol] = []
  private var pending = false
  private var generation = UUID()
  private var fullScreenTransition = false
  private var recaptureDefaults = false
  var isAlignmentSuspendedForFullScreenTransition: Bool { fullScreenTransition }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func isAccessibilityElement() -> Bool { false }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow { detach() }
    super.viewWillMove(toWindow: newWindow)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attach()
  }
  override func layout() { super.layout(); scheduleAlignment() }
  override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); scheduleAlignment() }
  override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleAlignment() }
  override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleAlignment() }

  private func attach() {
    guard observedWindow !== window else { scheduleAlignment(); return }
    detach()
    guard let window else { return }
    observedWindow = window
    for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification,
      NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didChangeScreenNotification, NSWindow.didDeminiaturizeNotification,
      NSWindow.didBecomeKeyNotification] {
      observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleAlignment() }
      })
    }
    observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification,
      object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.suspendForFullScreenEntry() }
    })
    observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
      object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.fullScreenTransition = false }
    })
    observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification,
      object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.fullScreenTransition = true }
    })
    observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
      object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.fullScreenTransition = false
        self.recaptureDefaults = true
        self.scheduleAlignment()
      }
    })
    // Failed transitions do not send the corresponding successful completion
    // notification. The existing native window delegate forwards that case.
    observations.append(NotificationCenter.default.addObserver(
      forName: ChromiumWindowContext.fullScreenTransitionFailedNotification,
      object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.fullScreenTransition = false
        self.recaptureDefaults = true
        self.scheduleAlignment()
      }
    })
    scheduleAlignment()
  }

  /// Suspends only this component's placement policy. AppKit owns its system
  /// lifecycle notifications; component checks must never impersonate them.
  func suspendForFullScreenEntry() {
    restoreDefaults()
    fullScreenTransition = true
  }

  func scheduleAlignment() {
    guard !pending, window != nil else { return }
    pending = true
    let token = generation
    // AppKit lays out the titlebar during a border drag's tracking loop. Run
    // after that layout in common modes, rather than waiting until mouse-up.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == token else { return }
        self.pending = false
        self.align()
      }
    }
  }

  private func align() {
    guard let window, observedWindow === window, let root = window.contentView,
      !fullScreenTransition, !window.styleMask.contains(.fullScreen),
      window.styleMask.contains(.titled), !isHiddenOrHasHiddenAncestor,
      bounds.width > 0, bounds.height > 0 else { return }
    let buttons = Self.buttonTypes.compactMap { window.standardWindowButton($0) }
    guard buttons.count == 3, buttons.allSatisfy({ $0.window === window && $0.superview != nil }) else { return }
    if recaptureDefaults || original.count != buttons.count
      || zip(original, buttons).contains(where: { control, button in
        control.button !== button || control.parent !== button.superview
      }) {
      let leading = root.convert(buttons[0].bounds, from: buttons[0]).minX
      original = buttons.map { OriginalControl(button: $0, root: root, leading: leading) }
      recaptureDefaults = false
    }
    let row = root.convert(bounds, from: self)
    let scale = max(1, window.backingScaleFactor)
    func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    let leading = row.minX + 8
    let placements: [(NSButton, CGRect)] = zip(buttons, original).compactMap { button, original in
      guard let parent = button.superview else { return nil }
      let frame = root.convert(button.bounds, from: button)
      let target = CGRect(x: pixel(leading + original.horizontalOffset),
        y: pixel(row.midY - frame.height / 2), width: frame.width, height: frame.height)
      let converted = parent.convert(target, from: root)
      // Do not trade alignment for clipped native controls if AppKit changes
      // its titlebar hierarchy or temporarily reparents a full-screen button.
      guard parent.visibleRect.insetBy(dx: -0.01, dy: -0.01).contains(converted) else { return nil }
      return (button, converted)
    }
    guard placements.count == buttons.count else { return }
    // The titlebar can finish its native resize layout after the content's
    // first layout callback. A window update reconciles that final placement;
    // already aligned controls must not create another animation transaction.
    let changed = placements.filter { button, frame in button.frame.origin != frame.origin }
    guard !changed.isEmpty else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      for (button, frame) in changed { button.setFrameOrigin(frame.origin) }
    }
  }

  private func restoreDefaults() {
    guard let window = observedWindow, !window.styleMask.contains(.fullScreen) else { return }
    for control in original {
      guard let button = control.button, let parent = control.parent,
        button.superview === parent, button.window === window else { continue }
      button.frame = control.frame
    }
  }

  func detach() {
    generation = UUID(); pending = false
    if !fullScreenTransition { restoreDefaults() }
    observations.forEach(NotificationCenter.default.removeObserver)
    observations.removeAll()
    original.removeAll()
    observedWindow = nil
    fullScreenTransition = false
    recaptureDefaults = false
  }

  deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}
