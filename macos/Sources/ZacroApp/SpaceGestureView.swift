import AppKit
import SwiftUI
import ZacroCore

/// AppKit supplies real contact/momentum phases to the shared, tested recognizer.
struct SpaceGestureSurface<Content: View>: NSViewRepresentable {
  var index: Int
  var count: Int
  var contextKey: String
  var onProgress: (Double) -> Void
  var onSelect: (Int, Double) -> Void
  @ViewBuilder var content: () -> Content
  func makeNSView(context: Context) -> SpaceScrollHost<Content> {
    let view = SpaceScrollHost(rootView: content()); configure(view); return view
  }
  func updateNSView(_ view: SpaceScrollHost<Content>, context: Context) {
    view.rootView = content(); configure(view)
  }
  private func configure(_ view: SpaceScrollHost<Content>) {
    if view.index != index || view.count != count || view.contextKey != contextKey { view.contextWillChange() }
    view.index = index; view.count = count; view.contextKey = contextKey
    view.onProgress = onProgress; view.onSelect = onSelect
  }
}

final class SpaceScrollHost<Content: View>: NSHostingView<Content> {
  var index = 0
  var count = 1
  var contextKey = ""
  var onProgress: (Double) -> Void = { _ in }
  var onSelect: (Int, Double) -> Void = { _, _ in }
  private var gesture = SpaceGesture()
  private var fallbackRelease: DispatchWorkItem?

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
    onProgress(0)
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { fallbackRelease?.cancel(); fallbackRelease = nil }
    super.viewWillMove(toWindow: newWindow)
  }
  override func scrollWheel(with event: NSEvent) {
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
      phase: phase, momentum: momentum, shiftKey: event.modifierFlags.contains(.shift),
      blocked: NSEvent.pressedMouseButtons != 0 || !event.modifierFlags.intersection([.command, .control, .option]).isEmpty))
    apply(result)
    if !result.consumed { super.scrollWheel(with: event) }
  }
  private func apply(_ result: SpaceGesture.Output) {
    fallbackRelease?.cancel(); fallbackRelease = nil
    if result.didRelease, let selected = result.selectedIndex,
      result.contextKey == contextKey, result.originIndex == index {
      onSelect(selected, result.duration)
    } else if result.phase == .tracking || result.phase == .edge {
      onProgress(result.progress)
    } else if result.phase == .idle || result.phase == .blocked { onProgress(0) }
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
}
