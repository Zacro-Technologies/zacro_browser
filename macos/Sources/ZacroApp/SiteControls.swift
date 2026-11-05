import AppKit
import SwiftUI
import ZacroCore

struct NativeMenuAction: Identifiable {
  let id: String
  let title: String
  let glyph: String
  var shortcut: String? = nil
  var enabled = true
  var divider = false
  var keepsOpen = false
  let action: () -> Void
}

/// A single set of commands drives the pointer menu and keyboard menu.
struct NativeMenuCommands: View {
  let items: [NativeMenuAction]
  var body: some View {
    ForEach(items) { item in
      if item.divider { Divider() }
      Button(action: item.action) {
        Label { Text(item.title) } icon: { NativeGlyph.menuImage(item.glyph) }
      }.disabled(!item.enabled)
    }
  }
}

/// The renderer's compact, theme-colored action popover and focus traversal.
struct NativeActionPopover: View {
  let title: String
  let items: [NativeMenuAction]
  let colors: NativeSpacePalette
  var compactZoom = false
  var motionScale = 1.0
  var onDismiss: (() -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focus: String?
  @State private var hovered: String?
  private var enabledIDs: [String] { items.filter(\.enabled).map(\.id) }
  private var rows: [NativeMenuAction] { compactZoom ? items.filter { $0.id != "zoom-out" && $0.id != "zoom-in" } : items }
  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(spacing: 1) {
          ForEach(rows) { item in
            if item.divider || (compactZoom && item.id == "zoom-reset") { Divider().padding(.horizontal, 5).padding(.vertical, 4) }
            if compactZoom && item.id == "zoom-reset" {
              HStack(spacing: 2) {
                ForEach(items.filter { ["zoom-out", "zoom-reset", "zoom-in"].contains($0.id) }) { zoom in
                  menuButton(zoom, compact: true).frame(maxWidth: zoom.id == "zoom-reset" ? .infinity : 34)
                }
              }.padding(.horizontal, 4)
            } else {
              menuButton(item)
            }
          }
        }.padding(5)
      }.scrollIndicators(.hidden)
        .onChange(of: focus) { _, id in if let id { reader.scrollTo(id) } }
    }.frame(width: 242)
      .frame(height: min((NSScreen.main?.visibleFrame.height ?? 800) - 60,
        CGFloat(rows.count * 31 + items.filter(\.divider).count * 9 + 10)))
      .font(.system(size: 12)).foregroundStyle(colors.ink).tint(colors.accent)
      .background { NativeControlSurface().overlay(colors.chrome.opacity(0.65)) }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .contain).accessibilityLabel(title)
      .onAppear { focus = enabledIDs.first }
      .onKeyPress(keys: [.upArrow, .downArrow, .home, .end]) { key in
        guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
        let ids = enabledIDs
        guard !ids.isEmpty else { return .handled }
        let current = focus.flatMap { ids.firstIndex(of: $0) } ?? (key.key == .upArrow ? 0 : -1)
        if key.key == .home { focus = ids.first }
        else if key.key == .end { focus = ids.last }
        else { focus = ids[(current + (key.key == .downArrow ? 1 : -1) + ids.count) % ids.count] }
        return .handled
      }
      .onKeyPress(.escape) { close(); return .handled }
  }
  private func menuButton(_ item: NativeMenuAction, compact: Bool = false) -> some View {
    Button {
      if item.keepsOpen { item.action() }
      else { close(); DispatchQueue.main.async(execute: item.action) }
    } label: {
      HStack(spacing: 8) {
        if compact {
          if item.id == "zoom-reset" { Text(item.title.components(separatedBy: " · ").first ?? item.title).frame(maxWidth: .infinity) }
          else { NativeGlyph(item.glyph, size: 14).foregroundStyle(colors.accent).frame(width: 18) }
        } else {
          NativeGlyph(item.glyph, size: 14).foregroundStyle(colors.accent).frame(width: 18)
          Text(item.title).lineLimit(1)
          Spacer(minLength: 5)
          if let shortcut = item.shortcut {
            Text(NativeInterfaceEditors.keyLabel(shortcut)).font(.system(size: 10)).foregroundStyle(colors.muted)
          }
        }
      }.padding(.horizontal, 8).frame(minHeight: 30)
        .background(colors.ink.opacity(focus == item.id || hovered == item.id ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }.buttonStyle(NativePressButtonStyle(motionScale: motionScale)).disabled(!item.enabled).opacity(item.enabled ? 1 : 0.4)
      .focusable().focusEffectDisabled().focused($focus, equals: item.id).id(item.id).accessibilityLabel(item.title).accessibilityIdentifier("native-menu-action:" + item.id)
      .onHover { if $0 { hovered = item.id } else if hovered == item.id { hovered = nil } }
  }
  private func close() { if let onDismiss { onDismiss() } else { dismiss() } }
}

/// AppKit supplies native menu navigation, typeahead and Escape restoration for
/// Shift+F10, using the exact same command list as the row's context menu.
struct NativeContextMenuAnchor: NSViewRepresentable {
  let requested: Bool
  let items: [NativeMenuAction]
  let finished: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) {
    guard requested, !context.coordinator.showing else { return }
    context.coordinator.showing = true
    DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
      defer { coordinator.showing = false; coordinator.targets = []; finished() }
      guard let view, view.window != nil else { return }
      let menu = NSMenu(); menu.autoenablesItems = false
      for entry in items {
        if entry.divider { menu.addItem(.separator()) }
        let target = MenuTarget(entry.action); coordinator.targets.append(target)
        let item = NSMenuItem(title: entry.title, action: #selector(MenuTarget.run), keyEquivalent: "")
        item.target = target; item.isEnabled = entry.enabled
        let renderer = ImageRenderer(content: NativeGlyph(entry.glyph, size: 14).foregroundStyle(.primary))
        item.image = renderer.nsImage; item.image?.isTemplate = true
        menu.addItem(item)
      }
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
    }
  }
  final class Anchor: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
  final class Coordinator { var showing = false; var targets: [MenuTarget] = [] }
  final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
  }
}

/// A presentation snapshot of actual engine extension state. Every operation is
/// scoped by the coordinator to the profile/generation that produced the tile.
@MainActor
struct SiteExtensionItem: Identifiable {
  let id: String
  var name: String
  var image: NSImage?
  var badgeText = ""
  var badgeColor: NSColor?
  var badgeForeground: NSColor?
  var enabled = true
  var actionEnabled = true
  var actionLoading = false
  var actionError: String?
  var canRetryAction = false
  var pinned = false
  var canPin = true
  var perform: () -> Void = {}
  var togglePin: () -> Void = {}
}

@MainActor
struct SiteControlActions {
  var url: URL?
  var title = ""
  var profileName = "Personal"
  var spaceName = "Personal"
  var isPrivate = false
  var isBookmarked = false
  var isSplit = false
  var pageError = false
  var zoomPercent = 100
  var extensions: [SiteExtensionItem] = []
  var extensionsReady = false
  var extensionError: String?
  var bookmark: () -> Void = {}
  var printPage: () -> Void = {}
  var find: () -> Void = {}
  var split: () -> Void = {}
  var customizeSpace: () -> Void = {}
  var permissions: () -> Void = {}
  var browserMenu: () -> Void = {}
  var pageActions: () -> Void = {}
  var openDefaultBrowser: () -> Void = {}
  var zoomIn: () -> Void = {}
  var zoomOut: () -> Void = {}
  var resetZoom: () -> Void = {}
  var developerTools: () -> Void = {}
  var showExtensions: () -> Void = {}
  var manageExtensions: () -> Void = {}
  var extensionStore: () -> Void = {}

  var hasDocument: Bool { NativePageIdentity.hasDocument(url) }
  var hasWebPage: Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }
  var origin: String {
    guard let url, hasDocument else { return "No page open" }
    return NativePageIdentity.label(url.absoluteString)
  }
}

/// Matches the original site-control-center geometry and original actions.
struct SiteControls: View {
  let actions: SiteControlActions
  var accent: Color = .accentColor
  var palette: NativeSpacePalette? = nil
  var maximumHeight: CGFloat = 600
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var copied = false
  @State private var hoveredExtension: String?
  @FocusState private var focus: String?
  @State private var measuredHeight: CGFloat = 0
  private var colors: NativeSpacePalette { palette ?? NativeSpacePalette(theme: SpaceTheme(), dark: colorScheme == .dark) }

  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        content.background {
          GeometryReader { geometry in
            Color.clear.preference(key: NativeSiteControlsHeight.self, value: geometry.size.height)
          }
        }
      }.scrollIndicators(.hidden)
        .frame(width: 304, height: NativeSiteControlsLayout.height(content: measuredHeight, maximum: maximumHeight))
        .onPreferenceChange(NativeSiteControlsHeight.self) { height in
          if height > 0, abs(height - measuredHeight) > 0.5 { measuredHeight = height }
        }
        .onChange(of: focus) { _, id in if let id { reader.scrollTo(id) } }
    }
      .foregroundStyle(colors.ink).font(.system(size: 13)).tint(accent)
      .background { NativeControlSurface().overlay(colors.chrome.opacity(0.32)) }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityElement(children: .contain).accessibilityLabel("Site controls")
      .onAppear { focus = focusIDs.first }
      .onKeyPress(keys: [.upArrow, .downArrow, .home, .end]) { key in
        guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
        let ids = focusIDs
        guard !ids.isEmpty else { return .handled }
        let current = focus.flatMap { ids.firstIndex(of: $0) } ?? (key.key == .upArrow ? 0 : -1)
        if key.key == .home { focus = ids.first }
        else if key.key == .end { focus = ids.last }
        else { focus = ids[(current + (key.key == .downArrow ? 1 : -1) + ids.count) % ids.count] }
        return .handled
      }
      .onKeyPress(.escape) { dismiss(); return .handled }
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        quick(copied ? "checkmark" : "copy", label: copied ? "Address copied" : "Copy link", focusID: "copy") {
          guard let url = actions.url else { return }
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
          copied = true
        }
        quick("star", label: actions.isBookmarked ? "Remove bookmark" : "Bookmark page", selected: actions.isBookmarked, enabled: actions.hasWebPage) { perform(actions.bookmark) }
        quick("split", label: actions.isSplit ? "Unsplit tabs" : "Split view", selected: actions.isSplit) { perform(actions.split) }
        quick("search", label: "Find on page") { perform(actions.find) }
      }
      HStack {
        sectionHeading("Extensions")
        Spacer()
        Button { perform(actions.manageExtensions) } label: { NativeGlyph("plus").frame(width: 16, height: 16).frame(width: 26, height: 26) }
          .buttonStyle(.plain).foregroundStyle(accent).help("Manage extensions").accessibilityLabel("Manage extensions").disabled(actions.isPrivate)
          .focusable().focusEffectDisabled().focused($focus, equals: "extensions")
          .id("extensions")
          .padding(.top, 8)
      }
      if actions.isPrivate {
        empty("Unavailable in private profiles.")
      } else if let error = actions.extensionError {
        VStack(alignment: .leading, spacing: 6) {
          Text(error).font(.system(size: 12)).foregroundStyle(colors.muted)
          Button("Manage extensions") { perform(actions.manageExtensions) }.buttonStyle(.plain)
        }.padding(10)
      } else if !actions.extensionsReady {
        ProgressView().controlSize(.small).padding(10).accessibilityLabel("Loading extensions")
      } else if actions.extensions.isEmpty {
        empty("No extensions installed.")
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
          ForEach(actions.extensions) { extensionItem in extensionTile(extensionItem) }
        }.padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 6)
      }
      sectionHeading("Settings")
      setting("Space theme", caption: actions.spaceName, glyph: "palette", action: actions.customizeSpace)
      setting("Site permissions", caption: "Manage access", glyph: "shield", disabled: !actions.hasWebPage, action: actions.permissions)
      setting("Developer tools", caption: "Inspect page", glyph: "terminal", disabled: !actions.hasDocument, action: actions.developerTools)
      Divider().overlay(colors.ink.opacity(0.08)).padding(.top, 8)
      HStack {
        Button { perform(actions.permissions) } label: {
          HStack(spacing: 6) {
            NativeGlyph(actions.url?.scheme == "https" && !actions.pageError ? "lock" : "globe").frame(width: 15, height: 15).foregroundStyle(accent)
            Text(NativePageIdentity.securityLabel(actions.url, failed: actions.pageError))
          }.padding(.horizontal, 9).padding(.vertical, 7).background(colors.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!actions.hasWebPage).help(actions.origin).focusable().focusEffectDisabled().focused($focus, equals: "security").id("security")
        Spacer()
        moreActions
      }.padding(.top, 12).padding(.horizontal, 2)
    }.padding(12).frame(width: 304)
  }
  private var focusIDs: [String] {
    var result = actions.hasDocument ? ["copy"] : []
    if actions.hasWebPage { result.append("star") }
    if actions.hasDocument { result += ["split", "search"] }
    if !actions.isPrivate { result.append("extensions") }
    if !actions.isPrivate, actions.extensionsReady, actions.extensionError == nil {
      for item in actions.extensions {
        if item.enabled && !item.actionLoading { result.append("extension:\(item.id)") }
        if item.canPin { result.append("pin:\(item.id)") }
      }
    }
    result.append("Space theme")
    if actions.hasWebPage { result.append("Site permissions") }
    if actions.hasDocument { result.append("Developer tools") }
    if actions.hasWebPage { result.append("security") }
    result.append("more")
    return result
  }
  private func quick(_ glyph: String, label: String, focusID: String? = nil, selected: Bool = false, enabled: Bool? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      NativeGlyph(glyph).frame(width: 18, height: 18).frame(maxWidth: .infinity).frame(height: 42)
        .background(colors.card.opacity(selected ? 0.46 : 0.24), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
    }.buttonStyle(.plain).foregroundStyle(accent).disabled(!(enabled ?? actions.hasDocument))
      .focusable().focusEffectDisabled().focused($focus, equals: focusID ?? glyph)
      .id(focusID ?? glyph).accessibilityIdentifier("native-site-control:" + (focusID ?? glyph))
      .help(label).accessibilityLabel(label).accessibilityAddTraits(selected ? [.isSelected] : [])
  }
  private func sectionHeading(_ title: String) -> some View {
    Text(title).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 8)
  }
  private func empty(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(colors.muted).padding(10) }
  private func extensionTile(_ item: SiteExtensionItem) -> some View {
    Button {
      if item.canRetryAction { item.perform() } else { perform(item.perform) }
    } label: {
      ExtensionTileGlyph(item: item, size: 22, colors: colors)
        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
        .background(colors.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .overlay(alignment: .topTrailing) {
          if !item.badgeText.isEmpty { badge(item, small: false) }
        }
        .overlay { ExtensionActionStatus(item: item, colors: colors) }
    }.buttonStyle(.plain).disabled(!item.enabled || item.actionLoading)
      .help(item.actionHelp).accessibilityLabel(item.actionLabel)
      .focusable().focusEffectDisabled().focused($focus, equals: "extension:\(item.id)")
      .id("extension:\(item.id)")
      .overlay(alignment: .bottomTrailing) {
        Button(action: item.togglePin) {
          NativeGlyph("pin").frame(width: 13, height: 13).frame(width: 19, height: 19)
            .foregroundStyle(item.pinned ? colors.card : accent)
            .background(item.pinned ? accent : colors.chrome, in: Circle())
            .shadow(color: .black.opacity(0.13), radius: 1.5, y: 1)
        }.buttonStyle(.plain).offset(x: 4, y: 4).disabled(!item.canPin)
          .opacity(item.pinned || hoveredExtension == item.id || focus == "pin:\(item.id)" || focus == "extension:\(item.id)" ? 1 : 0)
          .focusable().focusEffectDisabled().focused($focus, equals: "pin:\(item.id)")
          .id("pin:\(item.id)")
          .help((item.pinned ? "Unpin " : "Pin ") + item.name)
          .accessibilityLabel((item.pinned ? "Unpin " : "Pin ") + item.name)
      }.onHover { if $0 { hoveredExtension = item.id } else if hoveredExtension == item.id { hoveredExtension = nil } }
  }
  private func setting(_ title: String, caption: String, glyph: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
    Button { perform(action) } label: {
      HStack(spacing: 12) {
        NativeGlyph(glyph).frame(width: 19, height: 19).frame(width: 36, height: 36)
          .foregroundStyle(accent).background(accent.opacity(0.13), in: Circle())
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 13, weight: .semibold))
          Text(caption).font(.system(size: 12)).foregroundStyle(colors.muted)
        }
        Spacer(minLength: 0)
      }.padding(10).contentShape(RoundedRectangle(cornerRadius: 9))
    }.buttonStyle(.plain).disabled(disabled).focusable().focusEffectDisabled().focused($focus, equals: title).id(title)
  }
  private var moreActions: some View {
    Button { perform(actions.pageActions) } label: {
      NativeGlyph("more").frame(width: 18, height: 18).frame(width: 32, height: 32).background(colors.ink.opacity(0.045), in: Circle())
    }.buttonStyle(.plain).foregroundStyle(accent).help("More page actions").accessibilityLabel("More page actions").focusable().focusEffectDisabled().focused($focus, equals: "more").id("more")
  }
  private func badge(_ item: SiteExtensionItem, small: Bool) -> some View {
    Text(String(item.badgeText.prefix(4))).font(.system(size: small ? 8 : 9)).lineLimit(1)
      .foregroundStyle(item.badgeForeground.map(Color.init(nsColor:)) ?? colors.card)
      .padding(.horizontal, 3).padding(.vertical, 1)
      .background(item.badgeColor.map(Color.init(nsColor:)) ?? accent, in: RoundedRectangle(cornerRadius: 4))
  }
  private func perform(_ action: @escaping () -> Void) {
    dismiss(); DispatchQueue.main.async(execute: action)
  }
}

private struct NativeSiteControlsHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
enum NativeSiteControlsLayout {
  static func height(content: CGFloat, maximum: CGFloat) -> CGFloat {
    let limit = maximum.isFinite ? max(1, maximum) : 600
    return min(limit, content.isFinite && content > 0 ? content : 360)
  }
}

struct NativePinnedExtensions: View {
  let extensions: [SiteExtensionItem]
  let colors: NativeSpacePalette
  var width: Double = 208
  private var items: [SiteExtensionItem] { extensions.filter(\.pinned) }
  private var columns: Int { max(4, Int(ceil(Double(items.count) / max(1, ceil(Double(items.count) / 6))))) }
  var body: some View {
    if !items.isEmpty {
      GeometryReader { geometry in
        let side = min(52, max(1, (geometry.size.width - Double(columns - 1) * 6) / Double(columns)))
        ScrollView {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(items) { item in
              Button(action: item.perform) {
                ExtensionTileGlyph(item: item, size: 18, colors: colors, dimmed: !item.enabled || (!item.actionEnabled && !item.canRetryAction)).frame(width: side, height: side)
                  .background(colors.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                  .shadow(color: .black.opacity(0.05), radius: 2.5, y: 2)
                  .overlay(alignment: .bottomTrailing) {
                    if !item.badgeText.isEmpty {
                      Text(String(item.badgeText.prefix(4))).font(.system(size: 8)).lineLimit(1)
                        .foregroundStyle(item.badgeForeground.map(Color.init(nsColor:)) ?? .white)
                        .padding(.horizontal, 2).frame(minWidth: 12, minHeight: 12)
                        .background(item.badgeColor.map(Color.init(nsColor:)) ?? .black, in: RoundedRectangle(cornerRadius: 3)).padding(1)
                    }
                  }
                  .overlay { ExtensionActionStatus(item: item, colors: colors) }
              }.buttonStyle(.plain).disabled(!item.enabled || (!item.actionEnabled && !item.canRetryAction))
                .help(item.actionHelp).accessibilityLabel(item.actionLabel)
                .contextMenu { if item.canPin { Button("Unpin extension", action: item.togglePin) } }
            }
          }
        }.scrollIndicators(.hidden)
      }.frame(height: min(116, ceil(Double(items.count) / Double(columns)) * min(52, max(1, (width - Double(columns - 1) * 6) / Double(columns))) + Double(max(0, Int(ceil(Double(items.count) / Double(columns))) - 1)) * 6))
        .padding(.top, 6).padding(.bottom, 2).accessibilityElement(children: .contain).accessibilityLabel("Pinned extensions")
    }
  }
}
private extension SiteExtensionItem {
  var actionLabel: String {
    if actionLoading { return name + " · Loading action" }
    if canRetryAction { return "Retry " + name + " action" }
    return name
  }
  var actionHelp: String {
    if let actionError { return name + " · " + actionError + (canRetryAction ? " · Click to retry" : "") }
    if actionLoading { return name + " · Loading action" }
    return name + (enabled ? "" : " · Disabled")
  }
}
private struct ExtensionActionStatus: View {
  let item: SiteExtensionItem
  let colors: NativeSpacePalette
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Color.clear
      if item.actionLoading {
        ProgressView().controlSize(.mini).padding(3)
      } else if item.canRetryAction {
        NativeGlyph("reload").frame(width: 11, height: 11).padding(3)
          .foregroundStyle(colors.accent).background(colors.chrome, in: Circle()).padding(2)
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
private struct ExtensionTileGlyph: View {
  let item: SiteExtensionItem
  let size: Double
  let colors: NativeSpacePalette
  var dimmed: Bool? = nil
  var body: some View {
    Group {
      if let image = item.image { Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size) }
      else { NativeGlyph("extension").frame(width: size, height: size).foregroundStyle(colors.accent) }
    }.opacity((dimmed ?? !item.enabled) ? 0.4 : 1)
  }
}
