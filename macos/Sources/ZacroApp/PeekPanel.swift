import AppKit
import SwiftUI
import ZacroCore

/// A retained tint layer above the source document and below the live Peek.
/// Updating layout never detaches its host or reorders an already-visible page.
@MainActor
final class PeekPanelController {
  private var panel: NSPanel?
  private var hosting: NSHostingView<PeekBackdrop>?
  private let model = PeekBackdropModel()
  private weak var orderedPreview: NSWindow?
  private enum Phase { case opening, open, closing, expanding }
  private var phase = Phase.open
  private let clock = NativeMotionClock()
  private var motion: Motion?
  private struct Motion {
    let from: Double
    let to: Double
    let started: TimeInterval
    let duration: TimeInterval
  }
  private var progress = 1.0
  private var motionScale = 1.0
  private var contentFrame = CGRect.zero
  private var target = CGRect.zero
  private var origin = CGRect.zero
  private var expansionOrigin = CGRect.zero
  private var updatePreview: ((CGRect) -> Void)?
  private var completion: (() -> Void)?
  private var closingSnapshot = false
  private(set) var presentationFrame = CGRect.zero
  var presentationWindow: NSWindow? { panel }
  var isAnimating: Bool { clock.isRunning }

  /// The geometry in src/main/layout.cjs, including the room for the side controls.
  static func targetFrame(in content: CGRect) -> CGRect {
    let x = min(112, max(32, (content.width * 0.12).rounded()))
    let right = max(48, x)
    let y = min(40, max(20, (content.height * 0.04).rounded()))
    return CGRect(x: content.minX + x, y: content.minY + y,
      width: max(1, content.width - x - right), height: max(1, content.height - y * 2))
  }

  func show(
    parent: NSWindow, contentFrame: CGRect, preview: NSWindow?, close: @escaping () -> Void,
    expand: @escaping () -> Void, theme: SpaceTheme = SpaceTheme(), radius: Double = 12,
    motionScale: Double = 1, previewFrame: CGRect? = nil, originFrame: CGRect? = nil,
    updatePreviewFrame: ((CGRect) -> Void)? = nil,
    error: String? = nil, url: String = "", retry: (() -> Void)? = nil
  ) {
    guard let content = parent.contentView else { return }
    // A failed document is explicitly hidden while this retained tint/card
    // keeps its geometry. Recovery (or an asynchronously arriving native
    // window) must restore presentation even if rounding already reached the
    // final animation frame and no further geometry callback will fire.
    let needsPreviewPresentation = preview.map { orderedPreview !== $0 || !$0.isVisible } ?? false
    let replacesSnapshot = closingSnapshot
    if closingSnapshot {
      cancelMotion(); closingSnapshot = false; model.snapshot = nil
      phase = .open; progress = 1; orderedPreview = nil
    }
    let first = panel == nil
    let panel: NSPanel
    if let existing = self.panel {
      panel = existing
      if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
    } else {
      panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
      panel.level = .normal
      panel.isMovable = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
      panel.collectionBehavior = [.fullScreenAuxiliary]
      let hosting = TransparentPeekHostingView(rootView: PeekBackdrop(model: model))
      hosting.wantsLayer = true; hosting.layer?.backgroundColor = NSColor.clear.cgColor
      hosting.autoresizingMask = [.width, .height]
      panel.contentView = hosting
      self.hosting = hosting; self.panel = panel
      parent.addChildWindow(panel, ordered: .above)
    }
    let rect = content.isFlipped ? contentFrame : CGRect(x: contentFrame.minX, y: content.bounds.height - contentFrame.maxY, width: contentFrame.width, height: contentFrame.height)
    let screenRect = parent.convertToScreen(content.convert(rect, to: nil))
    if panel.frame != screenRect { panel.setFrame(screenRect, display: true) }
    self.contentFrame = contentFrame
    target = previewFrame ?? Self.targetFrame(in: contentFrame)
    self.motionScale = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : max(0, motionScale)
    updatePreview = updatePreviewFrame
    model.close = close; model.expand = expand
    model.update(theme: theme, radius: radius, error: error, url: url)
    model.retry = retry ?? {}
    // CEF creates its child asynchronously. The first arriving window belongs
    // to the opening already in progress; it must not restart that animation.
    let freshPreview = preview != nil && orderedPreview != nil && orderedPreview !== preview
    if first || freshPreview || replacesSnapshot {
      cancelMotion()
      origin = originFrame ?? target.insetBy(dx: min(12, target.width / 4), dy: min(12, target.height / 4))
      progress = updatePreviewFrame == nil ? 1 : 0
      phase = progress == 0 ? .opening : .open
      applyPresentation()
      panel.alphaValue = 1; panel.orderFront(nil)
      if phase == .opening { animate(.opening, completion: nil) }
    } else {
      applyPresentation()
      if !panel.isVisible { panel.alphaValue = 1; panel.orderFront(nil) }
    }
    if needsPreviewPresentation, presentationFrame.width > 0, presentationFrame.height > 0 {
      updatePreview?(presentationFrame)
    }
    if let preview, orderedPreview !== preview {
      preview.order(.above, relativeTo: panel.windowNumber); orderedPreview = preview
    }
  }

  /// The caller decides when closing is permitted. It must not discard a live
  /// Chromium document before its beforeunload decision has been accepted.
  @discardableResult func animateClose(completion: @escaping () -> Void) -> Bool {
    guard panel != nil else { return false }
    guard phase != .closing else { return true }
    if phase == .expanding { origin = presentationFrame; target = presentationFrame; progress = 1 }
    animate(.closing, completion: completion)
    return true
  }
  /// Called only after Chromium confirms closure. The image lives only in RAM;
  /// saved Peek state can be cleared immediately, independently of this tail.
  @discardableResult func animateClosedSnapshot(_ image: NSImage) -> Bool {
    guard panel != nil else { return false }
    guard !closingSnapshot else { return true }
    closingSnapshot = true
    updatePreview = nil; orderedPreview = nil; model.snapshot = image
    if phase == .expanding { target = presentationFrame; origin = presentationFrame.insetBy(dx: 12, dy: 12); progress = 1 }
    animate(.closing) { [weak self] in self?.hide(immediately: true) }
    return true
  }
  @discardableResult func animateExpand(completion: @escaping () -> Void) -> Bool {
    guard panel != nil else { return false }
    guard phase != .expanding else { return true }
    expansionOrigin = presentationFrame; progress = 0
    animate(.expanding, completion: completion)
    return true
  }
  private func animate(_ next: Phase, completion: (() -> Void)?) {
    cancelMotion()
    phase = next; self.completion = completion
    let from = progress, to = next == .closing ? 0.0 : 1.0
    let duration = (next == .closing ? NativeMotion.peekClosing
      : next == .expanding ? NativeMotion.peekExpansion : NativeMotion.peekOpening) * motionScale * abs(to - from)
    guard duration >= 0.001 else { progress = to; finishMotion(); return }
    guard let hosting else { progress = to; finishMotion(); return }
    let started = ProcessInfo.processInfo.systemUptime
    motion = Motion(from: from, to: to, started: started, duration: duration)
    clock.start(in: hosting, until: started + duration) { [weak self] time in
      guard let self, let motion = self.motion else { return }
      let elapsed = min(1, max(0, (time - motion.started) / motion.duration))
      self.progress = motion.from + (motion.to - motion.from) * NativeMotion.progress(elapsed)
      self.applyPresentation()
      if elapsed >= 1 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        self.progress = motion.to; self.finishMotion()
      }
    }
    applyPresentation()
  }
  private func finishMotion() {
    clock.stop(); motion = nil
    if phase == .opening { phase = .open }
    applyPresentation()
    let done = completion; completion = nil
    done?()
  }
  private func cancelMotion() { clock.stop(); motion = nil; completion = nil }
  private func applyPresentation() {
    let start = phase == .expanding ? expansionOrigin : origin
    let end = phase == .expanding ? contentFrame : target
    let scale = panel?.backingScaleFactor ?? 2
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
      ((a + (b - a) * progress) * scale).rounded() / scale
    }
    let frame = phase == .open ? target : CGRect(x: mix(start.minX, end.minX), y: mix(start.minY, end.minY),
      width: max(1, mix(start.width, end.width)), height: max(1, mix(start.height, end.height)))
    if presentationFrame != frame { presentationFrame = frame; updatePreview?(frame) }
    model.present(frame: frame.offsetBy(dx: -contentFrame.minX, dy: -contentFrame.minY),
      opacity: phase == .expanding ? 1 - progress : progress)
  }
  func hide(immediately: Bool = false) {
    if closingSnapshot && !immediately { return }
    cancelMotion()
    closingSnapshot = false; model.snapshot = nil
    guard let panel else { return }
    panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.contentView = nil
    hosting = nil; self.panel = nil; orderedPreview = nil; updatePreview = nil
    presentationFrame = .zero; progress = 1; phase = .open
  }

}

private final class TransparentPeekHostingView<Content: View>: NSHostingView<Content> {
  override var isOpaque: Bool { false }
  // The retained nonactivating panel intentionally leaves document keyboard
  // focus in place. Its visible controls must accept that first mouse click.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class PeekBackdropModel: ObservableObject {
  @Published private(set) var theme = SpaceTheme()
  @Published private(set) var radius = 12.0
  @Published private(set) var frame = CGRect.zero
  @Published private(set) var opacity = 1.0
  @Published var snapshot: NSImage?
  @Published private(set) var error: String?
  @Published private(set) var url = ""
  var close: () -> Void = {}
  var expand: () -> Void = {}
  var retry: () -> Void = {}
  func update(theme: SpaceTheme, radius: Double, error: String?, url: String) {
    if self.theme != theme { self.theme = theme }
    if self.radius != radius { self.radius = radius }
    if self.error != error { self.error = error }
    if self.url != url { self.url = url }
  }
  func present(frame: CGRect, opacity: Double) {
    if self.frame != frame { self.frame = frame }
    if self.opacity != opacity { self.opacity = opacity }
  }
}

private struct PeekBackdrop: View {
  @ObservedObject var model: PeekBackdropModel
  @Environment(\.colorScheme) private var colorScheme
  private var colors: NativeSpacePalette {
    NativeSpacePalette(theme: model.theme, dark: model.theme.appearance == "dark" || (model.theme.appearance == "system" && colorScheme == .dark))
  }
  var body: some View {
    ZStack(alignment: .topLeading) {
      colors.chrome.opacity(0.52 * model.opacity).contentShape(Rectangle()).onTapGesture { model.close() }
        .accessibilityLabel("Close Peek").accessibilityAddTraits(.isButton)
      RoundedRectangle(cornerRadius: model.radius, style: .continuous).fill(colors.card)
        .frame(width: max(0, model.frame.width), height: max(0, model.frame.height))
        .shadow(color: Color(red: 18/255, green: 14/255, blue: 24/255).opacity(0.24), radius: 35, y: 22)
        .shadow(color: Color(red: 18/255, green: 14/255, blue: 24/255).opacity(0.12), radius: 7, y: 3)
        .offset(x: model.frame.minX, y: model.frame.minY).opacity(model.opacity).allowsHitTesting(false)
      if let snapshot = model.snapshot {
        Image(nsImage: snapshot).resizable().interpolation(.high)
          .frame(width: max(0, model.frame.width), height: max(0, model.frame.height))
          .clipShape(RoundedRectangle(cornerRadius: model.radius, style: .continuous))
          .offset(x: model.frame.minX, y: model.frame.minY).opacity(model.opacity)
          .allowsHitTesting(false).accessibilityHidden(true)
      } else if let error = model.error {
        NativePageErrorView(message: error, url: model.url, isPeek: true, theme: model.theme, retry: model.retry)
          .frame(width: max(0, model.frame.width), height: max(0, model.frame.height))
          .clipShape(RoundedRectangle(cornerRadius: model.radius, style: .continuous))
          .offset(x: model.frame.minX, y: model.frame.minY).opacity(model.opacity)
      }
      VStack(spacing: 8) {
        peekButton("xmark", id: "peek-control-close", label: "Close Peek", action: model.close)
        peekButton("arrow.up.left.and.arrow.down.right", id: "peek-control-expand", label: "Open Peek as a tab", action: model.expand)
      }.offset(x: model.frame.maxX + 8, y: model.frame.minY).opacity(model.opacity)
        .allowsHitTesting(model.opacity > 0.5 && model.snapshot == nil)
    }.preferredColorScheme(model.theme.appearance == "dark" ? .dark : model.theme.appearance == "light" ? .light : nil)
  }
  private func peekButton(_ glyph: String, id: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      NativeGlyph(glyph).frame(width: 16, height: 16).frame(width: 32, height: 32).contentShape(Circle())
    }
      .buttonStyle(.plain).foregroundStyle(colors.ink)
      .background(colors.card.opacity(0.78), in: Circle())
      .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
      .help(label).accessibilityLabel(label).accessibilityIdentifier(id)
  }
}
