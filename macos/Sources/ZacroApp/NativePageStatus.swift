import AppKit
import SwiftUI
import ZacroCore

/// The browser's error presentation, while the failed native document remains
/// retained for Retry/history. Only a confirmed document failure belongs here.
struct NativePageErrorView: View {
  let message: String
  let url: String
  var isPeek = false
  let theme: SpaceTheme
  let retry: () -> Void
  var editAddress: (() -> Void)? = nil
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  private var colors: NativeSpacePalette {
    NativeSpacePalette(theme: theme, dark: theme.appearance == "dark"
      || (theme.appearance == "system" && colorScheme == .dark), increasedContrast: contrast == .increased)
  }
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          NativeGlyph("globe", size: 26).foregroundStyle(colors.accent).frame(width: 56, height: 56)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(colors.ink.opacity(0.12), lineWidth: 1))
            .padding(.bottom, 25)
          Text(isPeek ? "This preview couldn’t be loaded." : "This page couldn’t be reached.")
            .font(.system(size: 22, weight: .medium)).tracking(-0.5).padding(.bottom, 12)
          Text(message.isEmpty ? "Check the address and your connection." : message)
            .font(.system(size: 13)).lineSpacing(8).foregroundStyle(colors.muted)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.bottom, 20)
          if !isPeek {
            Text(NativePageIdentity.label(url)).font(.system(size: 11, design: .monospaced))
              .foregroundStyle(colors.muted).textSelection(.enabled).padding(.bottom, 22)
          }
          HStack(spacing: 8) {
            Button(action: retry) {
              HStack(spacing: 7) { NativeGlyph("reload", size: 14); Text("Try again") }
                .padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(colors.dark ? Color(red: 43/255, green: 23/255, blue: 32/255) : .white)
                .background(colors.accent, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
            if let editAddress, !isPeek {
              Button(action: editAddress) {
                HStack(spacing: 7) { NativeGlyph("edit", size: 14); Text("Edit address") }
                  .padding(.horizontal, 12).frame(height: 34)
                  .background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
              }.buttonStyle(.plain)
            }
          }.font(.system(size: 13))
        }.frame(maxWidth: 440, alignment: .leading)
          .padding(isPeek ? 20 : 40)
          .padding(.top, isPeek ? 50 : 0)
          .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: isPeek ? .top : .center)
      }.scrollIndicators(.hidden)
    }.foregroundStyle(colors.ink).tint(colors.accent)
      .background(isPeek ? colors.card : colors.surface)
      .accessibilityElement(children: .contain).accessibilityLabel(isPeek ? "Preview failed to load" : "Page failed to load")
  }
}

struct NativeDocumentErrorPresentation {
  let window: NSWindow
  /// Top-left document rectangle inside the Chromium window's viewport. It
  /// excludes extension side panels, whose live document stays visible.
  let bounds: CGRect
  let message: String
  let url: String
  var isPeek = false
  let retry: () -> Void
  var editAddress: (() -> Void)? = nil
}

@MainActor
final class NativeDocumentErrorPanelController {
  @MainActor private final class Entry {
    weak var parent: NSWindow?
    let panel: NativeDocumentErrorPanel
    let model: NativeDocumentErrorModel
    var bounds: CGRect
    private var observations: [NSObjectProtocol] = []
    init(presentation: NativeDocumentErrorPresentation, theme: SpaceTheme) {
      parent = presentation.window; bounds = presentation.bounds
      model = NativeDocumentErrorModel(presentation: presentation, theme: theme)
      panel = NativeDocumentErrorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.identifier = NSUserInterfaceItemIdentifier("ZacroDocumentError")
      panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
      panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
      panel.level = presentation.window.level; panel.collectionBehavior = [.fullScreenAuxiliary]
      let hosting = NativeLoadingHostingView(rootView: NativeDocumentErrorContent(model: model))
      hosting.wantsLayer = true; hosting.layer?.backgroundColor = NSColor.clear.cgColor
      hosting.autoresizingMask = [.width, .height]; panel.contentView = hosting
      presentation.window.addChildWindow(panel, ordered: .above)
      for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: presentation.window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateFrame() }
        })
      }
      if let content = presentation.window.contentView {
        content.postsFrameChangedNotifications = true; content.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
          observations.append(NotificationCenter.default.addObserver(forName: name, object: content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrame() }
          })
        }
      }
    }
    deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }
    var documentBounds: CGRect? {
      guard let content = parent?.contentView else { return nil }
      let value = bounds.intersection(CGRect(origin: .zero, size: content.bounds.size))
      return value.width > 1 && value.height > 1 ? value : nil
    }
    func updateFrame() {
      guard let parent, let content = parent.contentView, let bounds = documentBounds else { panel.orderOut(nil); return }
      let local = NSRect(x: content.bounds.minX + bounds.minX,
        y: content.isFlipped ? content.bounds.minY + bounds.minY : content.bounds.maxY - bounds.maxY,
        width: bounds.width, height: bounds.height)
      let frame = parent.convertToScreen(content.convert(local, to: nil))
      if panel.frame != frame { panel.setFrame(frame, display: true) }
      if parent.isVisible, !panel.isVisible { panel.orderFront(nil) }
    }
  }
  private var entries: [String: Entry] = [:]
  func update(_ presentations: [String: NativeDocumentErrorPresentation], theme: SpaceTheme) {
    for id in Array(entries.keys) where presentations[id] == nil { remove(id) }
    for (id, presentation) in presentations {
      guard presentation.window.isVisible, presentation.bounds.width > 1, presentation.bounds.height > 1 else { remove(id); continue }
      if let entry = entries[id], entry.parent !== presentation.window { remove(id) }
      let entry = entries[id] ?? Entry(presentation: presentation, theme: theme)
      entries[id] = entry
      entry.bounds = presentation.bounds
      entry.model.update(presentation: presentation, theme: theme)
      entry.updateFrame()
    }
  }
  func isPresented(documentID: String) -> Bool { entries[documentID]?.panel.isVisible == true }
  func presentedBounds(documentID: String) -> CGRect? { entries[documentID]?.documentBounds }
  func owns(_ window: NSWindow) -> Bool { entries.values.contains { $0.panel === window } }
  func hide() { for id in Array(entries.keys) { remove(id) } }
  private func remove(_ id: String) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    let restoreKey = entry.panel.isKeyWindow
    entry.panel.parent?.removeChildWindow(entry.panel)
    entry.panel.orderOut(nil); entry.panel.contentView = nil
    if restoreKey, entry.parent?.isVisible == true { entry.parent?.makeKey() }
  }
}

private final class NativeDocumentErrorPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
@MainActor private final class NativeDocumentErrorModel: ObservableObject {
  @Published var message: String
  @Published var url: String
  @Published var isPeek: Bool
  @Published var theme: SpaceTheme
  var retry: () -> Void
  var editAddress: (() -> Void)?
  init(presentation: NativeDocumentErrorPresentation, theme: SpaceTheme) {
    message = presentation.message; url = presentation.url; isPeek = presentation.isPeek; self.theme = theme
    retry = presentation.retry; editAddress = presentation.editAddress
  }
  func update(presentation: NativeDocumentErrorPresentation, theme: SpaceTheme) {
    retry = presentation.retry; editAddress = presentation.editAddress
    if message != presentation.message { message = presentation.message }
    if url != presentation.url { url = presentation.url }
    if isPeek != presentation.isPeek { isPeek = presentation.isPeek }
    if self.theme != theme { self.theme = theme }
  }
}
private struct NativeDocumentErrorContent: View {
  @ObservedObject var model: NativeDocumentErrorModel
  var body: some View {
    NativePageErrorView(message: model.message, url: model.url, isPeek: model.isPeek,
      theme: model.theme, retry: { model.retry() }, editAddress: model.editAddress)
      .preferredColorScheme(model.theme.appearance == "dark" ? .dark : model.theme.appearance == "light" ? .light : nil)
  }
}

/// A two-pixel, noninteractive child of each actual Chromium window keeps the
/// loading strip above that document and naturally below any covering Peek.
@MainActor
final class NativeLoadingStripController {
  @MainActor private final class Entry {
    weak var parent: NSWindow?
    let panel: NSPanel
    let model: NativeLoadingStripModel
    private var observations: [NSObjectProtocol] = []
    init(parent: NSWindow, panel: NSPanel, model: NativeLoadingStripModel) {
      self.parent = parent; self.panel = panel; self.model = model
      for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateFrame() }
        })
      }
      if let content = parent.contentView {
        content.postsFrameChangedNotifications = true
        content.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
          observations.append(NotificationCenter.default.addObserver(forName: name, object: content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrame() }
          })
        }
      }
    }
    deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }
    func updateFrame() {
      guard let parent, let content = parent.contentView else { return }
      let local = NSRect(x: content.bounds.minX, y: content.isFlipped ? content.bounds.minY : content.bounds.maxY - 2,
        width: content.bounds.width, height: 2)
      let frame = parent.convertToScreen(content.convert(local, to: nil))
      if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
  }
  private var entries: [String: Entry] = [:]
  func update(windows: [String: NSWindow], theme: SpaceTheme, motionScale: Double) {
    for id in Array(entries.keys) where windows[id] == nil { remove(id) }
    for (id, parent) in windows {
      guard parent.contentView != nil, parent.isVisible else { remove(id); continue }
      if let existing = entries[id], existing.parent !== parent { remove(id) }
      let entry: Entry
      if let existing = entries[id] { entry = existing }
      else {
        let model = NativeLoadingStripModel(theme: theme, motionScale: motionScale)
        let panel = NativeLoadingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = parent.level; panel.collectionBehavior = [.fullScreenAuxiliary]
        let hosting = NativeLoadingHostingView(rootView: NativeLoadingStrip(model: model))
        hosting.wantsLayer = true; hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.autoresizingMask = [.width, .height]; panel.contentView = hosting
        parent.addChildWindow(panel, ordered: .above)
        entry = Entry(parent: parent, panel: panel, model: model); entries[id] = entry
      }
      entry.model.update(theme: theme, motionScale: motionScale)
      entry.updateFrame()
      if !entry.panel.isVisible { entry.panel.orderFront(nil) }
    }
  }
  func hide() { for id in Array(entries.keys) { remove(id) } }
  private func remove(_ id: String) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.panel.parent?.removeChildWindow(entry.panel)
    entry.panel.orderOut(nil); entry.panel.contentView = nil
  }
}

private final class NativeLoadingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
private final class NativeLoadingHostingView<Content: View>: NSHostingView<Content> {
  override var isOpaque: Bool { false }
}
@MainActor private final class NativeLoadingStripModel: ObservableObject {
  @Published private(set) var theme: SpaceTheme
  @Published private(set) var motionScale: Double
  init(theme: SpaceTheme, motionScale: Double) { self.theme = theme; self.motionScale = motionScale }
  func update(theme: SpaceTheme, motionScale: Double) {
    if self.theme != theme { self.theme = theme }
    if self.motionScale != motionScale { self.motionScale = motionScale }
  }
}
private struct NativeLoadingStrip: View {
  @ObservedObject var model: NativeLoadingStripModel
  @State private var started = Date()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  private var stationary: Bool { reduceMotion || model.motionScale <= 0 }
  private var color: Color {
    NativeSpacePalette(theme: model.theme, dark: model.theme.appearance == "dark"
      || (model.theme.appearance == "system" && colorScheme == .dark)).accent
  }
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: stationary)) { timeline in
      GeometryReader { geometry in
        let phase = timeline.date.timeIntervalSince(started).truncatingRemainder(dividingBy: 1.6) / 1.6
        let progress = stationary ? 0.5 : easeInOut(phase)
        color.frame(width: geometry.size.width * 0.32, height: 2)
          .offset(x: geometry.size.width * (-0.32 + 1.32 * progress))
      }.clipped()
    }.accessibilityHidden(true)
  }
  private func easeInOut(_ progress: Double) -> Double {
    // CSS ease-in-out: solve x(t) for cubic-bezier(.42, 0, .58, 1).
    var low = 0.0, high = 1.0
    for _ in 0..<14 {
      let t = (low + high) / 2, inverse = 1 - t
      let x = 3 * inverse * inverse * t * 0.42 + 3 * inverse * t * t * 0.58 + t * t * t
      if x < progress { low = t } else { high = t }
    }
    let t = (low + high) / 2
    return 3 * (1 - t) * t * t + t * t * t
  }
}
