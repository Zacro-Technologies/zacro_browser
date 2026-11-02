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

/// A two-pixel, noninteractive child of each actual Chromium window keeps the
/// loading strip above that document and naturally below any covering Peek.
@MainActor
final class NativeLoadingStripController {
  private final class Entry {
    weak var parent: NSWindow?
    let panel: NSPanel
    let model: NativeLoadingStripModel
    init(parent: NSWindow, panel: NSPanel, model: NativeLoadingStripModel) {
      self.parent = parent; self.panel = panel; self.model = model
    }
  }
  private var entries: [String: Entry] = [:]
  func update(windows: [String: NSWindow], theme: SpaceTheme, motionScale: Double) {
    for id in Array(entries.keys) where windows[id] == nil { remove(id) }
    for (id, parent) in windows {
      guard let content = parent.contentView, parent.isVisible else { remove(id); continue }
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
      let local = NSRect(x: content.bounds.minX, y: content.isFlipped ? content.bounds.minY : content.bounds.maxY - 2,
        width: content.bounds.width, height: 2)
      let frame = parent.convertToScreen(content.convert(local, to: nil))
      if entry.panel.frame != frame { entry.panel.setFrame(frame, display: true) }
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
