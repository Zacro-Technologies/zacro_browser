import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import ZacroCore

/// One identity is shared by the native menu, key bindings, and command search.
struct BrowserRuntimeCommand: Identifiable {
  let id: String
  let title: String
  let icon: String
  var shortcut: String?
  var keywords: String
  var available: Bool
  let action: () -> Void
  init(id: String, title: String, icon: String, shortcut: String? = nil,
       keywords: String = "", available: Bool = true, action: @escaping () -> Void) {
    self.id = id; self.title = title; self.icon = icon; self.shortcut = shortcut
    self.keywords = keywords; self.available = available; self.action = action
  }
}

@MainActor
final class BrowserActions: ObservableObject {
  @Published var palette = false
  @Published private(set) var paletteSession: UInt64 = 0
  @Published private(set) var paletteEditsAddress = false
  @Published var query = ""
  @Published var homeQuery = ""
  @Published var library: String?
  @Published var themeEditor = false
  @Published var siteControls = SiteControlActions()
  @Published var canGoBack = false
  @Published var canGoForward = false
  @Published var loading = false
  @Published var icons: [String: NSImage] = [:]
  @Published var iconColors: [String: Color] = [:]
  @Published var peekIcons: [String: NSImage] = [:]
  var iconForURL: (String) -> NSImage? = { _ in nil }
  @Published var audibleTabIDs: Set<String> = []
  @Published var loadedTabIDs: Set<String> = []
  @Published var recordingShortcut = false
  @Published var findVisible = false
  @Published var findQuery = ""
  @Published var findMatchCount = 0
  @Published var findActiveMatch = 0
  var findNext: () -> Void = {}
  var findPrevious: () -> Void = {}
  var closeFind: () -> Void = {}
  var updateFind: (String) -> Void = { _ in }
  @Published var nativePageVisible = false
  @Published var contentFrame = CGRect.zero
  @Published var paletteRequest: NativePaletteRequest?
  @Published var runtimeCommands: [BrowserRuntimeCommand] = []
  @Published var libraryCapabilities: Set<String> = []
  @Published var defaultBrowser: Bool?
  var performInterfaceCommand: (String) -> Bool = { _ in false }
  var handlePaletteEscape: () -> Bool = { false }
  var handleInterfaceEscape: () -> Bool = { false }
  var libraryContent: (String) -> AnyView? = { _ in nil }
  var settingsContent: () -> AnyView? = { nil }
  var pinnedExtensionsContent: () -> AnyView? = { nil }
  var performLibraryAction: ((String, [String: String]) async throws -> Void)?
  var openExtensions: () -> Void = {}
  var openExtensionStore: () -> Void = {}
  var onLayout: (CGRect, Double) -> Void = { _, _ in }
  var navigate: (String) -> Void = { _ in }
  var newTab: (String) -> Void = { _ in }
  var back: () -> Void = {}
  var forward: () -> Void = {}
  var reload: () -> Void = {}
  var find: () -> Void = {}
  var printPage: () -> Void = {}
  var zoom: (Double) -> Void = { _ in }
  var activate: (String) -> Void = { _ in }
  var closeTab: (String) -> Void = { _ in }
  var deleteSpace: (String) -> Void = { _ in }
  var deleteProfile: (String) -> Void = { _ in }
  func openPalette(address: String = "") {
    paletteRequest = nil
    paletteEditsAddress = !address.isEmpty
    query = address
    paletteSession &+= 1
    palette = true
  }
  func submit(_ value: String) {
    palette = false
    if paletteEditsAddress { navigate(value) } else { newTab(value) }
  }
  func setPaletteDestination(editsAddress: Bool) { paletteEditsAddress = editsAddress }
}

struct BrowserShell<Content: View>: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  @ViewBuilder var content: () -> Content
  @StateObject private var drag = SidebarDragSession()
  @State private var gestureProgress: Double = 0
  @State private var gestureTracking = false
  @State private var gestureSettleDuration = 0.18
  @State private var name = ""
  @State private var creation: String?
  @State private var renameTarget: SidebarNamedItem?
  @State private var showSiteControls = false
  @State private var showBrowserMenu = false
  @State private var showPageActions = false
  @State private var contextMenuRequest: String?
  @State private var editor: NativeInterfaceEditor?
  @State private var hoveredTab: String?
  @State private var hoveredFolder: String?
  @State private var hoveredPin: String?
  @State private var operationError: String?
  @State private var nameError: String?
  @FocusState private var sidebarFocus: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var themeDraft: BrowserSpace?
  @State private var themeError: String?
  @State private var creatingSpace = false
  @State private var availableWindowWidth: CGFloat = 1280
  @State private var sidebarWidthDraft: Double?
  @State private var libraryWidthDraft: Double?
  @State private var offeredOnboarding = false
  @State private var blankPaletteContext: String?
  private var savedTheme: SpaceTheme {
    var value = store.state.activeSpace?.theme ?? SpaceTheme()
    value.appearance = store.state.settings.appearance
    return value
  }
  private var editingTheme: SpaceTheme {
    creatingSpace || themeDraft?.id == store.state.activeSpaceID ? (themeDraft?.theme ?? savedTheme) : savedTheme
  }
  private var theme: SpaceTheme {
    guard gestureProgress != 0, let current = spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }) else { return editingTheme }
    let position = min(Double(spaces.count - 1), max(0, Double(current) + gestureProgress))
    let first = Int(floor(position)), last = Int(ceil(position))
    var value = NativeSpaceAppearance.blend(spaces[first].theme, spaces[last].theme, progress: position - Double(first))
    value.appearance = editingTheme.appearance
    return value
  }
  private var effectiveMotion: Double { reduceMotion ? 0 : store.state.settings.motionScale }
  private var colors: NativeSpacePalette {
    NativeSpacePalette(theme: theme, dark: theme.appearance == "dark"
      || (theme.appearance == "system" && colorScheme == .dark))
  }
  private var accent: Color { colors.accent }
  private var tabHeight: CGFloat { store.state.settings.tabDensity == "compact" ? 28 : 36 }
  private var spaces: [BrowserSpace] {
    store.state.spaces.filter { $0.profileID == store.activeProfileID }
  }
  private var tabs: [BrowserTab] {
    (drag.preview ?? store.state.tabs).filter { tab in
      tab.spaceID == store.state.activeSpaceID
        || (tab.isFavorite && store.profileID(for: tab) == store.activeProfileID)
    }
  }
  private var hasPage: Bool {
    store.state.activeTab.map { !$0.isClosed && currentAddress != "about:blank" } ?? false
  }
  private var currentAddress: String { store.state.activeTab?.peek?.url ?? store.state.activeTab?.url ?? "" }
  private var sidebarWidth: Double {
    let expanded = min(max(200, min(380, sidebarWidthDraft ?? store.state.settings.sidebarWidth)), max(0, availableWindowWidth - 240 - store.state.settings.pageGutter * 2))
    let fits = actions.library == nil || availableWindowWidth >= expanded + 260 + 240 + store.state.settings.pageGutter * 2
    return store.state.settings.sidebarVisible && fits ? expanded : 0
  }
  private var libraryWidth: Double {
    min(libraryWidthDraft ?? store.state.settings.panelWidth, max(0, availableWindowWidth - sidebarWidth - 240 - store.state.settings.pageGutter * 2))
  }
  private var sidebarResizeRange: ClosedRange<Double> {
    200...max(200, min(380, availableWindowWidth - (actions.library == nil ? 0 : 260) - 240 - store.state.settings.pageGutter * 2))
  }
  private var libraryResizeRange: ClosedRange<Double> {
    260...max(260, min(560, availableWindowWidth - sidebarWidth - 240 - store.state.settings.pageGutter * 2))
  }
  private var themeBinding: Binding<SpaceTheme> {
    Binding(get: { editingTheme }, set: { themeDraft?.theme = $0 })
  }
  private func saveTheme() {
    guard let draft = themeDraft, creatingSpace || draft.id == store.state.activeSpaceID else { return }
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    do {
      try store.commit { state in
        if creatingSpace {
          var saved = draft; saved.name = String(name.prefix(60))
          state.spaces.append(saved); state.activeSpaceID = saved.id; state.activeTabID = nil
        } else if let index = state.spaces.firstIndex(where: { $0.id == draft.id }) {
          state.spaces[index].theme = draft.theme
          state.spaces[index].name = String(name.prefix(60))
          state.spaces[index].icon = draft.icon
        }
        state.settings.appearance = draft.theme.appearance
      }
      themeError = nil; actions.themeEditor = false; themeDraft = nil
    } catch { themeError = error.localizedDescription }
  }


  var body: some View {
    ZStack {
      NativeThemeBackground(theme: theme)
        .mask(
          WindowMaterialMask(
            hole: (hasPage || actions.nativePageVisible) ? actions.contentFrame : .zero,
            radius: store.state.settings.pageRadius
          ).fill(style: FillStyle(eoFill: true)))
      VStack(spacing: 0) {
       HStack(spacing: 0) {
        if sidebarWidth > 0 {
          sidebar.frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
              NativeResizeHandle(value: sidebarWidth, range: sidebarResizeRange,
                reset: 224, label: "Resize sidebar", preview: { sidebarWidthDraft = $0.rounded() },
                commit: { saveRailWidth($0, sidebar: true) }, cancel: { sidebarWidthDraft = nil })
                .frame(width: 5)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        pageArea
        if let section = actions.library {
          NativeLibrary(store: store, actions: actions, section: section)
            .frame(width: libraryWidth)
            .overlay(alignment: .leading) {
              NativeResizeHandle(value: libraryWidth, range: libraryResizeRange, direction: -1,
                reset: 336, label: "Resize Library", preview: { libraryWidthDraft = $0.rounded() },
                commit: { saveRailWidth($0, sidebar: false) }, cancel: { libraryWidthDraft = nil })
                .frame(width: 5)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
       }
       if let message = store.lastError, editor == nil, themeError == nil, operationError == nil, nameError == nil {
         HStack(spacing: 8) {
           NativeGlyph("info.circle").foregroundStyle(accent).frame(width: 16)
           Text(message).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
           Button { store.clearError() } label: { NativeGlyph("xmark").frame(width: 24, height: 24) }
             .buttonStyle(.plain).help("Dismiss message").accessibilityLabel("Dismiss message")
         }.padding(.horizontal, 12).padding(.vertical, 5)
           .background(colors.chrome.opacity(0.9))
           .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently)
       }
      }
    }
    .ignoresSafeArea()
    .background {
      GeometryReader { geometry in
        Color.clear.onAppear { availableWindowWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in availableWindowWidth = width }
      }
    }
    .background {
      NativePalettePresenter(
        isPresented: $actions.palette,
        content: AnyView(
          palette.tint(accent).environment(\.presentedSpaceTheme, theme)
            .preferredColorScheme(
              theme.appearance == "dark" ? .dark : theme.appearance == "light" ? .light : nil)),
        motionScale: effectiveMotion,
        frame: actions.contentFrame.width > 0 ? actions.contentFrame : nil,
        presentationID: actions.paletteSession
      )
      .frame(width: 0, height: 0).allowsHitTesting(false)
    }
    .background {
      NativePalettePresenter(
        isPresented: Binding(get: { canDropSplit }, set: { if !$0 { drag.cancel() } }),
        content: AnyView(NativeSplitDropOverlay(store: store, actions: actions, drag: drag, colors: colors)),
        motionScale: effectiveMotion, frame: actions.contentFrame.insetBy(dx: store.state.settings.pageGutter, dy: store.state.settings.pageGutter),
        takesKey: false, dismissOnOutsideClick: false, dismissOnResign: true)
        .frame(width: 0, height: 0).allowsHitTesting(false)
      NativePalettePresenter(
        isPresented: $actions.findVisible,
        content: AnyView(NativeFindBar(actions: actions, colors: colors)), motionScale: effectiveMotion,
        frame: CGRect(x: max(actions.contentFrame.minX + 8, actions.contentFrame.maxX - 326), y: max(4, actions.contentFrame.minY),
          width: min(310, max(200, actions.contentFrame.width - 24)), height: 32),
        takesKey: true, dismissOnOutsideClick: false, dismissOnResign: false)
        .frame(width: 0, height: 0).allowsHitTesting(false)
      if sidebarWidth == 0 {
        let items = showPageActions ? pageMenuItems : browserMenuItems
        NativePalettePresenter(
          isPresented: Binding(get: { showBrowserMenu || showPageActions }, set: { if !$0 { showBrowserMenu = false; showPageActions = false } }),
          content: AnyView(NativeActionPopover(title: showPageActions ? "Page actions" : "Browser menu", items: items, colors: colors,
            compactZoom: showPageActions,
            onDismiss: { showBrowserMenu = false; showPageActions = false })),
          motionScale: effectiveMotion,
          frame: CGRect(x: actions.contentFrame.minX + 8, y: actions.contentFrame.minY + 40, width: 242,
            height: max(80, min(actions.contentFrame.height - 48, CGFloat((items.count - (showPageActions ? 2 : 0)) * 31 + items.filter(\.divider).count * 9 + 10)))))
          .frame(width: 0, height: 0).allowsHitTesting(false)
      }
    }
    .coordinateSpace(name: "browserWindow")
    .font(.system(size: 13))
    .foregroundStyle(colors.ink)
    .tint(accent)
    .preferredColorScheme(
      theme.appearance == "dark" ? .dark : theme.appearance == "light" ? .light : nil
    )
    .environment(\.presentedSpaceTheme, theme)
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 0.18 * effectiveMotion),
      value: store.state.settings.sidebarVisible
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16 * effectiveMotion), value: actions.library != nil)
    .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
      if drag.id != nil && NSEvent.pressedMouseButtons == 0 { drag.cancel() }
    }
    .onAppear {
      actions.performInterfaceCommand = performInterfaceCommand
      actions.handleInterfaceEscape = dismissInterface
      if !offeredOnboarding && !store.state.settings.onboardingCompleted && !CommandLine.arguments.contains("--engine-acceptance") {
        offeredOnboarding = true; editor = .onboarding
      } else { maybeOpenBlankPalette() }
    }
    .sheet(item: $editor) { destination in
      NativeInterfaceEditors(store: store, actions: actions, destination: destination)
    }
    .onChange(of: actions.themeEditor) { _, presented in
      themeError = nil
      if presented {
        actions.palette = false; showSiteControls = false; showBrowserMenu = false; showPageActions = false
        if creatingSpace {
          var initial = SpaceTheme(); initial.appearance = store.state.settings.appearance
          themeDraft = BrowserSpace(profileID: store.activeProfileID, name: "", theme: initial)
        }
        else { themeDraft = store.state.activeSpace; themeDraft?.theme = savedTheme }
      } else { themeDraft = nil; creatingSpace = false }
    }
    .onChange(of: store.state.activeSpaceID) { _, _ in
      discardThemePreview()
      maybeOpenBlankPalette()
    }
    .onChange(of: store.state.activeTabID) { _, _ in maybeOpenBlankPalette() }
    .onChange(of: actions.palette) { _, presented in if presented { discardThemePreview() } }
    .onChange(of: editor) { _, value in if value == nil { maybeOpenBlankPalette() } else { discardThemePreview() } }
    .onChange(of: actions.library) { _, value in if value == nil { maybeOpenBlankPalette() } else { discardThemePreview() } }
    .onChange(of: creation) { _, value in if value != nil { discardThemePreview() } }
    .onChange(of: renameTarget) { _, value in if value != nil { discardThemePreview() } }
    .onChange(of: showSiteControls) { _, presented in if presented { discardThemePreview() } }
    .onChange(of: showBrowserMenu) { _, presented in if presented { discardThemePreview() } }
    .onChange(of: showPageActions) { _, presented in if presented { discardThemePreview() } }
    .alert("Couldn’t complete the action", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
      Button("OK") { operationError = nil }
    } message: { Text(operationError ?? "") }
    .sheet(isPresented: Binding(
        get: { creation != nil || renameTarget != nil },
        set: {
          if !$0 {
            creation = nil
            renameTarget = nil
            nameError = nil
          }
        })) {
      NativeNameEditor(title: renameTarget.map { "Rename \($0.kind)" } ?? "New \(creation ?? "item")",
        name: $name, limit: nameLimit, saveTitle: renameTarget == nil ? "Create" : "Save", error: nameError, colors: colors,
        save: saveName, cancel: { creation = nil; renameTarget = nil; nameError = nil })
    }
  }

  private var canDropSplit: Bool {
    guard let id = drag.id, let source = store.tab(id), let active = store.state.activeTab,
      id != active.id, source.url != "about:blank", active.url != "about:blank", !active.isClosed,
      active.peek == nil, store.profileID(for: source) == store.activeProfileID,
      store.split(for: source.id) == nil, store.split(for: active.id) == nil else { return false }
    return true
  }
  private var pageArea: some View {
    ZStack {
      content()
      if store.state.activeTab?.homePage == true && store.state.activeTab?.url == "about:blank" && !actions.nativePageVisible {
        NativeHomePage(store: store, actions: actions, colors: colors, sidebarVisible: sidebarWidth > 0)
      }
    }
      .environment(\.presentedSpaceTheme, theme)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        NativeContentFrameReporter { frame in publishContentFrame(frame) }
          .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: store.state.settings.pageRadius))
      .background {
        // Chromium pages are sibling native windows. The clear overlay has no
        // alpha to cast a shadow, so the pane needs a retained solid underlay.
        RoundedRectangle(cornerRadius: store.state.settings.pageRadius)
          .fill(colors.chrome)
          .shadow(color: Color(red: 32 / 255, green: 19 / 255, blue: 36 / 255).opacity(0.11), radius: 9, y: 4)
      }
      .padding(store.state.settings.pageGutter)
      .overlay(alignment: .topLeading) {
        if sidebarWidth == 0 { revealButton }
      }
  }
  private func publishContentFrame(_ frame: CGRect) {
    guard frame.width > 0, frame.height > 0, frame != actions.contentFrame else { return }
    actions.contentFrame = frame
    actions.onLayout(frame, sidebarWidth)
  }
  private var revealButton: some View {
    Button {
      toggleSidebar()
    } label: {
      NativeGlyph("sidebar.left").frame(width: 32, height: 32)
    }
    .buttonStyle(.plain).background { NativeControlSurface().clipShape(Circle()) }
    .padding(12).help("Show sidebar").accessibilityLabel("Show sidebar")
  }
  private var sidebar: some View {
    VStack(spacing: 0) {
      navigation
      addressButton.padding(.bottom, 8)
      if let extensions = actions.pinnedExtensionsContent() { extensions.padding(.bottom, 8) }
      else if !actions.siteControls.isPrivate && actions.siteControls.extensions.contains(where: { $0.pinned }) {
        NativePinnedExtensions(extensions: actions.siteControls.extensions, colors: colors, width: sidebarWidth - 16).padding(.bottom, 8)
      }
      SpaceGestureSurface(
        index: spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }) ?? 0,
        count: spaces.count,
        contextKey: store.activeProfileID,
        onProgress: { value in
          var transaction = Transaction(); transaction.animation = nil
          withTransaction(transaction) { gestureTracking = value != 0; gestureProgress = value }
        },
        onSelect: { index, duration in
          guard spaces.indices.contains(index) else { return }
          gestureSettleDuration = duration
          withAnimation(reduceMotion ? nil : .easeOut(duration: duration * effectiveMotion)) {
            gestureTracking = false
            gestureProgress = 0
            store.selectSpace(id: spaces[index].id)
          }
        }
      ) {
        GeometryReader { geometry in
          let activeIndex = spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }) ?? 0
          ZStack(alignment: .topLeading) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
              spacePage(space, height: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: (Double(index - activeIndex) - gestureProgress) * geometry.size.width)
                .animation(gestureTracking || reduceMotion ? nil : .easeOut(duration: gestureSettleDuration * effectiveMotion), value: Double(activeIndex) + gestureProgress)
            }
          }.clipped()
        }
      }
      spaceFooter
    }.padding(.horizontal, 8)
      .overlay(alignment: .leading) { spaceEdge(-1) }
      .overlay(alignment: .trailing) { spaceEdge(1) }
  }
  private func favorites(in space: BrowserSpace) -> [BrowserTab] {
    (drag.preview ?? store.state.tabs).filter {
      $0.isFavorite && store.profileID(for: $0) == space.profileID && store.split(for: $0.id)?.spaceID != space.id
    }
  }
  private func spacePage(_ space: BrowserSpace, height: CGFloat) -> some View {
    let active = space.id == store.state.activeSpaceID
    let favorites = favorites(in: space)
    let rows = Int(ceil(Double(favorites.count) / 4))
    let naturalHeight: CGFloat = favorites.isEmpty ? (drag.id != nil && active ? 52 : 4) : CGFloat(rows * 46 + max(0, rows - 1) * 7 + 8)
    return VStack(spacing: 0) {
      ScrollViewReader { reader in
        ScrollView {
          if active { favoriteGrid }
          else { previewFavorites(favorites, selectedID: space.lastActiveTabID) }
        }.scrollIndicators(.hidden).frame(height: min(naturalHeight, min(176, max(0, height * 0.35))))
          .onChange(of: sidebarFocus) { _, id in
            if active, let id, favorites.contains(where: { $0.id == id }) { reader.scrollTo(id) }
          }
      }
      ScrollViewReader { reader in
        ScrollView {
          if active { tabList }
          else { previewTabList(space) }
        }.scrollIndicators(.hidden)
          .onChange(of: sidebarFocus) { _, id in
            if active, let id, !favorites.contains(where: { $0.id == id }) { reader.scrollTo(id) }
          }
      }
    }.allowsHitTesting(active).accessibilityHidden(!active)
      .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end, KeyEquivalent("\u{F70D}"), KeyEquivalent("\u{F735}")]) { handleSidebarKey($0) }
  }
  private func previewFavorites(_ favorites: [BrowserTab], selectedID: String?) -> some View {
    let count = max(1, Int(ceil(Double(favorites.count) / 4)))
    let size = favorites.count / count, fuller = favorites.count % count
    return VStack(spacing: 7) {
      if favorites.isEmpty { Color.clear.frame(height: 4) }
      else {
        ForEach(0..<count, id: \.self) { row in
          HStack(spacing: 7) {
            ForEach(Array(favorites.dropFirst(row * size + min(row, fuller)).prefix(size + (row < fuller ? 1 : 0)))) { tab in
              previewRow(tab, selected: tab.id == selectedID, favorite: true)
            }
          }
        }
      }
    }.padding(.bottom, favorites.isEmpty ? 0 : 8)
  }
  private func previewTabList(_ space: BrowserSpace) -> some View {
    let profileID = space.profileID
    let all = store.state.tabs.filter { $0.spaceID == space.id || ($0.isFavorite && store.profileID(for: $0) == profileID) }
    let groups = store.state.splits.filter { $0.spaceID == space.id }
    let grouped = Set(groups.flatMap(\.tabIDs))
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 7) {
        NativeGlyph(store.state.profiles.first(where: { $0.id == space.profileID })?.isPrivate == true ? "shield" : space.icon).frame(width: 14)
        Text(space.name).fontWeight(.semibold)
        Spacer()
        if store.state.profiles.first(where: { $0.id == space.profileID })?.isPrivate == true { Text("Private").font(.system(size: 10)) }
      }.font(.system(size: 12)).foregroundStyle(accent).padding(.horizontal, 8).frame(height: 32)
      ForEach(store.state.folders.filter { $0.spaceID == space.id }) { folder in
        HStack(spacing: 8) {
          NativeGlyph("folder").font(.system(size: 16)).foregroundStyle(accent).frame(width: 16)
          Text(folder.name).fontWeight(.semibold)
          Spacer()
        }.padding(.horizontal, 8).frame(height: 36)
        if folder.isExpanded {
          VStack(spacing: 2) {
            ForEach(all.filter { $0.folderID == folder.id && !$0.isFavorite && !grouped.contains($0.id) }) { tab in
              previewRow(tab, selected: tab.id == space.lastActiveTabID)
            }
          }.padding(.leading, 16)
        }
      }
      ForEach(all.filter { $0.isPinned && !$0.isFavorite && $0.folderID == nil && !grouped.contains($0.id) }) { tab in
        previewRow(tab, selected: tab.id == space.lastActiveTabID)
      }
      Rectangle().fill(colors.ink.opacity(0.12)).frame(height: 1).padding(.horizontal, 7).padding(.vertical, 10)
      Label("New Tab", systemImage: "plus").foregroundStyle(colors.muted).padding(.horizontal, 8).frame(height: 36)
      ForEach(groups) { group in
        HStack(spacing: 0) {
          if let left = store.tab(group.leftTabID) { previewRow(left, selected: false) }
          Rectangle().fill(colors.ink.opacity(0.14)).frame(width: 1, height: 18)
          if let right = store.tab(group.rightTabID) { previewRow(right, selected: false) }
        }.background(group.tabIDs.contains(space.lastActiveTabID ?? "") ? selectionBackground(true) : colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      }
      ForEach(all.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil && !grouped.contains($0.id) && ($0.url != "about:blank" || $0.homePage == true) }) { tab in
        previewRow(tab, selected: tab.id == space.lastActiveTabID)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func previewRow(_ tab: BrowserTab, selected: Bool, favorite: Bool = false) -> some View {
    HStack(spacing: 8) {
      Group {
        if let image = actions.icons[tab.id] { Image(nsImage: image).resizable().scaledToFit() }
        else { NativeGlyph("globe") }
      }.frame(width: favorite ? 20 : 16, height: favorite ? 20 : 16)
      if !favorite { Text(tab.displayTitle).lineLimit(1); Spacer(minLength: 0) }
    }.font(.system(size: 13, weight: selected ? .medium : .regular))
      .frame(maxWidth: .infinity, minHeight: favorite ? 46 : 36).padding(.horizontal, 8)
      .background(selected && !tab.isClosed ? (favorite ? favoriteSelection(tab) : selectionBackground(true)) : favorite ? colors.ink.opacity(0.05) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
  }
  private var navigation: some View {
    HStack(spacing: 0) {
      Spacer().frame(width: 70)
      Button {
        toggleSidebar()
      } label: {
        NativeGlyph("sidebar.left").font(.system(size: 16))
          .frame(width: 26, height: 26)
      }.help("Hide sidebar")
      Spacer(minLength: 0)
      Button(action: actions.back) { NativeGlyph("arrow.left").frame(width: 26, height: 26) }.disabled(!actions.canGoBack)
        .help("Back")
      Button(action: actions.forward) { NativeGlyph("arrow.right").frame(width: 26, height: 26) }.disabled(
        !actions.canGoForward
      ).help("Forward")
      Button(action: actions.reload) {
        NativeGlyph(actions.loading ? "xmark" : "arrow.clockwise")
          .frame(width: 26, height: 26)
      }.help(actions.loading ? "Stop" : "Reload").disabled(!hasPage)
    }.font(.system(size: 14, weight: .regular)).foregroundStyle(accent)
      .buttonStyle(.plain).frame(height: 36)
  }
  private var addressButton: some View {
    HStack(spacing: 2) {
      Button {
        actions.openPalette(address: hasPage ? currentAddress : "")
      } label: {
        HStack(spacing: 7) {
          NativeGlyph(hasPage ? (currentAddress.hasPrefix("https://") ? "lock" : "globe") : "magnifyingglass")
            .font(.system(size: 12)).foregroundStyle(accent)
          Text(hasPage ? (URL(string: currentAddress)?.host ?? currentAddress) : "Search or enter URL")
            .lineLimit(1).font(.system(size: 13, weight: .medium))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
          .frame(height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Edit address or search").focused($sidebarFocus, equals: "address")
        .contextMenu { NativeMenuCommands(items: pageMenuItems) }
        .popover(isPresented: $showPageActions, arrowEdge: .bottom) {
          NativeActionPopover(title: "Page actions", items: pageMenuItems, colors: colors, compactZoom: true)
        }
      Button {
        showSiteControls.toggle()
      } label: {
        NativeGlyph("slider.horizontal.3").font(.system(size: 12, weight: .medium))
          .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 8))
      }.buttonStyle(.plain).padding(.trailing, 4)
        .help("Site controls").accessibilityLabel("Site controls")
        .popover(isPresented: $showSiteControls, arrowEdge: .bottom) {
          SiteControls(actions: actions.siteControls, accent: accent, palette: colors)
        }
        .popover(isPresented: $showBrowserMenu, arrowEdge: .bottom) {
          NativeActionPopover(title: "Browser menu", items: browserMenuItems, colors: colors)
        }
    }.background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }
  private var tabList: some View {
    VStack(alignment: .leading, spacing: 2) {
      Button { editor = .spaces } label: {
        HStack(spacing: 7) {
          NativeGlyph(store.state.activeProfile?.isPrivate == true ? "shield" : store.state.activeSpace?.icon ?? "circle.fill").frame(width: 14)
          Text(store.state.activeSpace?.name ?? "Personal").fontWeight(.semibold)
          Spacer()
          if store.state.activeProfile?.isPrivate == true { Text("Private").font(.system(size: 10)) }
          NativeGlyph("chevron.down", size: 12)
        }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel("Spaces & profiles")
        .contextMenu {
          if let space = store.state.activeSpace { spaceMenu(space) }
        }
      ForEach(store.state.folders.filter { $0.spaceID == store.state.activeSpaceID }) { folder in
        VStack(spacing: 2) {
          Button {
            store.updateFolder(id: folder.id, isExpanded: !folder.isExpanded)
          } label: {
            HStack(spacing: 8) {
              ZStack {
                NativeGlyph("folder").opacity(hoveredFolder == folder.id || sidebarFocus == "folder:\(folder.id)" ? 0 : 1)
                NativeGlyph("chevron.down")
                  .rotationEffect(.degrees(folder.isExpanded ? 0 : -90))
                  .animation(effectiveMotion > 0 ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.12 * effectiveMotion) : nil, value: folder.isExpanded)
                  .opacity(hoveredFolder == folder.id || sidebarFocus == "folder:\(folder.id)" ? 1 : 0)
              }.foregroundStyle(accent).frame(width: 16, height: 16)
                .animation(effectiveMotion > 0 ? .easeOut(duration: 0.12 * effectiveMotion) : nil, value: hoveredFolder == folder.id || sidebarFocus == "folder:\(folder.id)")
              Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
              Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("\(folder.isExpanded ? "Collapse" : "Expand") \(folder.name)")
            .focused($sidebarFocus, equals: "folder:\(folder.id)").id("folder:\(folder.id)")
            .onHover { if $0 { hoveredFolder = folder.id } else if hoveredFolder == folder.id { hoveredFolder = nil } }
          if folder.isExpanded {
            VStack(spacing: 2) {
              rows(tabs.filter { $0.folderID == folder.id && !$0.isFavorite }, section: .folder(folder.id))
            }.padding(.leading, 8)
              .overlay(alignment: .leading) { Rectangle().fill(accent.opacity(0.22)).frame(width: 1) }
              .padding(.leading, 8)
          }
        }
        .contextMenu { NativeMenuCommands(items: folderMenuItems(folder)) }
        .background { menuAnchor(id: "folder:\(folder.id)", items: folderMenuItems(folder)) }
        .onDrop(of: [.plainText], delegate: dropDelegate(section: .folder(folder.id)))
      }
      VStack(spacing: 2) {
        rows(tabs.filter { $0.isPinned && !$0.isFavorite && $0.folderID == nil }, section: .pinned)
        Color.clear.frame(height: drag.id == nil ? 0 : 14)
      }.contentShape(Rectangle()).onDrop(of: [.plainText], delegate: dropDelegate(section: .pinned))
      Rectangle().fill(colors.ink.opacity(0.12)).frame(height: 1)
        .padding(.horizontal, 7).padding(.vertical, 10)
      Button {
        actions.openPalette()
      } label: {
        HStack(spacing: 8) {
          NativeGlyph("plus").font(.system(size: 16)).foregroundStyle(accent).frame(width: 16)
          Text("New Tab")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 36)
      }
      .buttonStyle(.plain).foregroundStyle(colors.muted)
      VStack(spacing: 2) {
        splitRows
        rows(
          tabs.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil && ($0.url != "about:blank" || $0.homePage == true) },
          section: .regular)
        Color.clear.frame(height: 28)
      }.contentShape(Rectangle()).onDrop(
        of: [.plainText], delegate: dropDelegate(section: .regular))
    }
  }
  private var favoriteGrid: some View {
    let favorites = tabs.filter { $0.isFavorite && store.split(for: $0.id)?.spaceID != store.state.activeSpaceID }
    // Balance rows just like the original twelve-track Favorites grid: six
    // favorites are two rows of three, five are a row of three then two.
    let rowCount = max(1, Int(ceil(Double(favorites.count) / 4)))
    let rowSize = favorites.count / rowCount
    let fullerRows = favorites.count % rowCount
    return VStack(spacing: 7) {
      if favorites.isEmpty {
        Color.clear.frame(height: drag.id == nil ? 4 : 44)
      } else { ForEach(0..<rowCount, id: \.self) { row in
        let count = rowSize + (row < fullerRows ? 1 : 0)
        let start = row * rowSize + min(row, fullerRows)
        HStack(spacing: 7) {
          ForEach(Array(favorites.dropFirst(start).prefix(count))) { tab in
            tabRow(tab, section: .favorite)
          }
        }
      } }
    }.padding(.bottom, favorites.isEmpty && drag.id == nil ? 0 : 8).contentShape(Rectangle())
      .onDrop(of: [.plainText], delegate: dropDelegate(section: .favorite))
  }
  private var splitRows: some View {
    ForEach(store.state.splits.filter { $0.spaceID == store.state.activeSpaceID }) { group in
      HStack(spacing: 0) {
        if let left = store.tab(group.leftTabID) { tabRow(left, section: .regular, grouped: true) }
        Rectangle().fill(colors.ink.opacity(0.14)).frame(width: 1, height: 18)
        if let right = store.tab(group.rightTabID) { tabRow(right, section: .regular, grouped: true) }
      }.background(group.tabIDs.contains(store.state.activeTabID ?? "") ? selectionBackground(true) : colors.ink.opacity(0.06),
        in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
        .accessibilityElement(children: .contain).accessibilityLabel("Split view")
    }
  }
  private func rows(_ candidates: [BrowserTab], section: SidebarSection) -> some View {
    ForEach(candidates.filter { store.split(for: $0.id) == nil }) { tab in tabRow(tab, section: section) }
  }
  private func selectionBackground(_ selected: Bool) -> Color {
    colors.card.opacity(selected ? 0.46 : 0)
  }
  private func favoriteSelection(_ tab: BrowserTab) -> Color {
    let logo = NSColor(actions.iconColors[tab.id] ?? accent)
    let card = NSColor(colors.card)
    return Color(nsColor: card.blended(withFraction: 0.22, of: logo) ?? card).opacity(0.86)
  }
  @ViewBuilder private func tabIcon(_ tab: BrowserTab, size: CGFloat) -> some View {
    Group {
      if tab.id == store.state.activeTabID && actions.loading { ProgressView().controlSize(.mini).scaleEffect(0.7) }
      else if let icon = actions.icons[tab.id] { Image(nsImage: icon).resizable().scaledToFit() }
      else { NativeGlyph("globe") }
    }.frame(width: size, height: size)
      .opacity(tab.isClosed ? 0.65 : 1)
      .overlay(alignment: .topTrailing) {
        if let peek = tab.peek {
          Group {
            if let icon = actions.peekIcons[tab.id] { Image(nsImage: icon).resizable().scaledToFit() }
            else { NativeGlyph("globe").font(.system(size: 9)) }
          }.frame(width: 12, height: 12).padding(2)
            .background(colors.card.opacity(0.95), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1).offset(x: 6, y: -6)
            .accessibilityLabel("Preview: \(peek.title.isEmpty ? (URL(string: peek.url)?.host ?? peek.url) : peek.title)")
        }
      }
  }
  private func tabRow(_ tab: BrowserTab, section: SidebarSection, grouped: Bool = false) -> some View {
    let favorite = section == .favorite
    let selected = tab.id == store.state.activeTabID && !tab.isClosed
    let hovered = hoveredTab == tab.id || sidebarFocus == tab.id
    let away = tab.isPinned && !tab.isClosed && tab.savedURL != nil && tab.savedURL != tab.url
    return HStack(spacing: 0) {
      if !favorite && !grouped && tab.isPinned {
        Button { store.resetPinnedDestination(id: tab.id); actions.activate(tab.id) } label: {
          Group {
            if hoveredPin == tab.id { NativeGlyph("arrow.left").frame(width: 16, height: 16) }
            else { tabIcon(tab, size: 16) }
          }.frame(width: 28, height: 28)
        }.buttonStyle(.plain).padding(.leading, 3).help("Reset to saved page")
          .onHover { if $0 { hoveredPin = tab.id } else if hoveredPin == tab.id { hoveredPin = nil } }
      }
      Button { store.selectTab(id: tab.id); actions.activate(tab.id) } label: {
        HStack(spacing: 8) {
          if favorite || grouped || !tab.isPinned { tabIcon(tab, size: favorite ? 20 : 16) }
          if !favorite {
            if away && !grouped { Text("/").foregroundStyle(colors.muted).padding(.trailing, -5) }
            Text(tab.displayTitle).lineLimit(1)
            Spacer(minLength: 0)
          }
        }.frame(maxWidth: .infinity, minHeight: favorite ? 46 : tabHeight)
          .padding(.leading, grouped ? 6 : !favorite && tab.isPinned ? 2 : 8)
          .padding(.trailing, hovered && !favorite ? 0 : 8)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).focused($sidebarFocus, equals: tab.id).id(tab.id)
      if !favorite && (tab.isMuted || actions.audibleTabIDs.contains(tab.id)) {
        Button { performTabAction("tab:mute", tab: tab) } label: {
          NativeGlyph(tab.isMuted ? "speaker.slash" : "speaker.wave.2").font(.system(size: 12)).frame(width: 24, height: 24)
        }.buttonStyle(.plain).foregroundStyle(accent).help(tab.isMuted ? "Unmute tab" : "Mute tab")
      }
      if !favorite && hovered {
        Button { actions.closeTab(tab.id) } label: {
          NativeGlyph("xmark").font(.system(size: 11)).frame(width: grouped ? 20 : 24, height: 24)
        }.buttonStyle(.plain).foregroundStyle(colors.muted).padding(.trailing, 3)
          .help(tab.isPinned ? "Close page · keep pin" : "Close tab").accessibilityLabel("Close \(tab.displayTitle)")
      }
    }.font(.system(size: 13, weight: selected ? .medium : .regular))
      .frame(maxWidth: .infinity)
      .background(grouped ? .clear : selected ? (favorite ? favoriteSelection(tab) : selectionBackground(true)) : favorite || hovered ? colors.ink.opacity(0.05) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
      .opacity(drag.id == tab.id ? 0.45 : 1)
      .shadow(color: .black.opacity(selected && !grouped && drag.id == nil ? 0.07 : 0), radius: 1.5, y: 1)
      .onHover { if $0 { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil } }
      .help("\(tab.displayTitle) — \(tab.isClosed ? "Closed" : actions.loadedTabIDs.contains(tab.id) ? "Loaded" : "Sleeping")\n\(tab.savedURL ?? tab.url)")
      .accessibilityElement(children: .contain).accessibilityAddTraits(selected ? [.isSelected] : [])
      .contextMenu { tabMenu(tab) }
      .background { menuAnchor(id: tab.id, items: tabMenuItems(tab)) }
      .onDrag {
        guard !grouped else { return NSItemProvider() }
        drag.start(tab.id, tabs: store.state.tabs)
        return NSItemProvider(object: tab.id as NSString)
      }
      .background {
        GeometryReader { geometry in
          Color.clear.onDrop(of: [.plainText], delegate: SidebarDropDelegate(store: store, drag: drag,
            section: section, spaceID: store.state.activeSpaceID, before: tab.id, extent: geometry.size))
        }
      }
  }
  private func tabMenu(_ tab: BrowserTab) -> some View { NativeMenuCommands(items: tabMenuItems(tab)) }
  private func tabMenuItems(_ tab: BrowserTab) -> [NativeMenuAction] {
    var items = [
      NativeMenuAction(id: "pin", title: tab.isPinned ? "Unpin tab" : "Pin tab", glyph: "pin") { store.togglePin(id: tab.id) },
      NativeMenuAction(id: "favorite", title: tab.isFavorite ? "Move to pinned tabs" : "Add to Favorites", glyph: "star") { store.toggleFavorite(id: tab.id) },
    ]
    if tab.isPinned {
      items.append(.init(id: "reset", title: "Reset to saved page", glyph: "undo") { store.resetPinnedDestination(id: tab.id); actions.activate(tab.id) })
      if !tab.isClosed && tab.savedURL != tab.url { items.append(.init(id: "replace", title: "Replace pin with current page", glyph: "edit") { store.replacePinnedDestination(id: tab.id) }) }
    }
    items.append(.init(id: "duplicate", title: "Duplicate tab", glyph: "copy", divider: true) { if let duplicate = store.duplicateTab(id: tab.id) { actions.activate(duplicate.id) } })
    if store.split(for: tab.id) != nil { items.append(.init(id: "split", title: "Unsplit tabs", glyph: "split") { store.unsplit(tabID: tab.id) }) }
    else { items.append(.init(id: "split", title: "Open in split view", glyph: "split") { store.selectTab(id: tab.id); actions.activate(tab.id); showPalette(.split) }) }
    items.append(.init(id: "move", title: "Move to Space or folder", glyph: "folder") { showPalette(.move(tabID: tab.id, pin: false)) })
    items.append(.init(id: "rename", title: "Rename tab…", glyph: "edit") { beginRename(.tab(tab.id), name: tab.displayTitle) })
    items.append(.init(id: "bookmark", title: isBookmarked(tab.url) ? "Remove bookmark" : "Bookmark tab", glyph: "bookmark") { store.toggleBookmark(url: tab.url, title: tab.displayTitle) })
    if tab.isPinned && tab.id != store.state.activeTabID && actions.loadedTabIDs.contains(tab.id) {
      items.append(.init(id: "sleep", title: "Put to sleep", glyph: "moon") { performTabAction("tab:sleep", tab: tab) })
    }
    items.append(.init(id: "close", title: tab.isPinned ? "Close page · keep pin" : "Close tab", glyph: "close", divider: true) { actions.closeTab(tab.id) })
    return items
  }
  private var spaceFooter: some View {
    HStack {
      Menu {
        ForEach(["Bookmarks", "History", "Downloads", "Archive", "Settings", "Extensions", "AI"], id: \.self) {
          section in Button(section) { actions.library = section }
        }
        Divider()
        Button("New folder") {
          name = ""
          creation = "folder"
        }
        Button("New profile") {
          name = ""
          creation = "profile"
        }
        Button("Private profile") { _ = store.createProfile(name: "Private", isPrivate: true) }
        Divider()
        ForEach(store.state.profiles) { profile in
          Menu(profile.name) {
            Button("Switch to profile") {
              if let space = store.state.spaces.first(where: { $0.profileID == profile.id }) {
                store.selectSpace(id: space.id)
              }
            }
            Button("Rename profile…") { beginRename(.profile(profile.id), name: profile.name) }
            Button("Delete profile…", role: .destructive) {
              confirmDelete(.profile(profile.id), name: profile.name)
            }
            .disabled(!canDeleteProfile(profile.id))
          }
        }
      } label: {
        NativeGlyph("archivebox")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
      Spacer(minLength: 4)
      ForEach(spaces) { space in
        Button {
          store.selectSpace(id: space.id)
        } label: {
          NativeGlyph(space.icon).font(.system(size: 13)).opacity(
            space.id == store.state.activeSpaceID ? 1 : 0.45)
            .frame(width: 26, height: 26)
            .background(selectionBackground(space.id == store.state.activeSpaceID), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(space.name).accessibilityLabel("Switch to \(space.name)")
          .accessibilityAddTraits(space.id == store.state.activeSpaceID ? [.isSelected] : [])
          .contextMenu { spaceMenu(space) }
          .focused($sidebarFocus, equals: "space:\(space.id)")
          .onKeyPress(keys: [KeyEquivalent("\u{F70D}"), KeyEquivalent("\u{F735}")]) { key in
            guard isContextMenuKey(key) else { return .ignored }
            contextMenuRequest = "space:\(space.id)"; return .handled
          }
          .background { menuAnchor(id: "space:\(space.id)", items: spaceMenuItems(space)) }
          .onDrop(
            of: [.plainText],
            delegate: SpaceHoverDropDelegate(store: store, drag: drag, target: { space.id }))
      }
      Spacer(minLength: 4)
      Menu {
        Button("New tab") { actions.openPalette() }
        Button("New folder") { name = ""; creation = "folder" }
        Button("New Space") { openNewSpace() }
        Divider()
        Button("Private session") { actions.runtimeCommands.first(where: { $0.id == "new-private-space" })?.action() }
      } label: {
        NativeGlyph("plus")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 26).accessibilityLabel("Add")
    }.foregroundStyle(accent).frame(height: 32).padding(.bottom, 4)
      .popover(isPresented: $actions.themeEditor, arrowEdge: .bottom) {
        ThemeEditor(theme: themeBinding,
          identity: AnyView(VStack(alignment: .leading, spacing: 10) {
            NativeSpaceIdentity(name: Binding(get: { themeDraft?.name ?? "" }, set: { themeDraft?.name = $0 }),
              icon: Binding(get: { themeDraft?.icon ?? "circle" }, set: { themeDraft?.icon = $0 }), initiallyExpanded: creatingSpace)
            if creatingSpace {
              Picker("Profile", selection: Binding(get: { themeDraft?.profileID ?? store.activeProfileID }, set: { themeDraft?.profileID = $0 })) {
                ForEach(store.state.profiles) { profile in Text(profile.name).tag(profile.id) }
              }.font(.system(size: 12))
            }
          }),
          canSave: !(themeDraft?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
          errorMessage: themeError,
          saveTitle: creatingSpace ? "Create Space" : "Save changes",
          motionScale: effectiveMotion,
          onSave: saveTheme, onCancel: { actions.themeEditor = false })
      }
  }
  private func spaceEdge(_ offset: Int) -> some View {
    Color.clear.frame(width: drag.id == nil ? 0 : 12).contentShape(Rectangle())
      .onDrop(
        of: [.plainText],
        delegate: SpaceHoverDropDelegate(
          store: store, drag: drag, repeatNavigation: true,
          target: {
            guard let current = spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }),
              spaces.indices.contains(current + offset)
            else { return nil }
            return spaces[current + offset].id
          }))
  }
  private func dropDelegate(section: SidebarSection, before: String? = nil) -> SidebarDropDelegate {
    SidebarDropDelegate(
      store: store, drag: drag, section: section, spaceID: store.state.activeSpaceID, before: before
    )
  }

  private var palette: some View { NativeCommandPalette(store: store, actions: actions) }
  private func toggleSidebar() {
    if store.state.settings.sidebarVisible && sidebarWidth == 0 { actions.library = nil }
    else { store.state.settings.sidebarVisible.toggle(); store.save() }
  }
  private func showPalette(_ request: NativePaletteRequest) {
    actions.openPalette()
    actions.paletteRequest = request
  }
  private func performInterfaceCommand(_ id: String) -> Bool {
    if id.hasPrefix("focus-folder:"), let folder = store.state.folders.first(where: { $0.id == String(id.dropFirst(13)) }),
      store.state.spaces.contains(where: { $0.id == folder.spaceID && $0.profileID == store.activeProfileID }) {
      store.selectSpace(id: folder.spaceID); store.updateFolder(id: folder.id, isExpanded: true)
      store.state.settings.sidebarVisible = true
      if sidebarWidth == 0 { actions.library = nil }
      DispatchQueue.main.async { sidebarFocus = "folder:\(folder.id)" }
      return true
    }
    switch id {
    case "new-space": openNewSpace()
    case "new-folder": name = ""; creation = "folder"
    case "rename-tab":
      guard let tab = store.state.activeTab else { return true }
      beginRename(.tab(tab.id), name: tab.displayTitle)
    case "move-tab":
      if let id = store.state.activeTabID { showPalette(.move(tabID: id, pin: false)) }
    case "split":
      if let id = store.state.activeTabID, store.split(for: id) != nil { store.unsplit(tabID: id) }
      else { showPalette(.split) }
    case "shortcuts": editor = .shortcuts
    case "profiles": editor = .profiles
    case "spaces": editor = .spaces
    case "onboarding": editor = .onboarding
    case "permissions": editor = .permissions
    case "home-page":
      actions.palette = false; actions.library = nil
      if let tab = store.createTab(address: "about:blank") {
        store.updateTab(tab.id) { $0.homePage = true }
        actions.activate(tab.id)
      }
    case "space-theme", "customize-space":
      actions.library = nil; store.state.settings.sidebarVisible = true; actions.themeEditor = true
    case "site-searches": showPalette(.siteSearches)
    case "focus-sidebar", "reveal-tab":
      store.state.settings.sidebarVisible = true
      if sidebarWidth == 0 { actions.library = nil }
      if let tab = store.state.activeTab, let folder = tab.folderID { store.updateFolder(id: folder, isExpanded: true) }
      sidebarFocus = store.state.activeTabID ?? sidebarKeyboardItems.first ?? "address"
    case "browser-menu":
      showSiteControls = false; showPageActions = false; showBrowserMenu = true
    case "page-actions":
      showSiteControls = false; showBrowserMenu = false; showPageActions = true
    default: return false
    }
    return true
  }
  private func dismissInterface() -> Bool {
    if showSiteControls { showSiteControls = false }
    else if showPageActions { showPageActions = false }
    else if showBrowserMenu { showBrowserMenu = false }
    else if actions.themeEditor { actions.themeEditor = false }
    else if editor != nil { editor = nil }
    else if creation != nil || renameTarget != nil { creation = nil; renameTarget = nil; nameError = nil }
    else { return false }
    return true
  }
  private func saveRailWidth(_ proposed: Double, sidebar: Bool) {
    let range = sidebar ? sidebarResizeRange : libraryResizeRange
    let value = min(range.upperBound, max(range.lowerBound, proposed.rounded()))
    do {
      try store.commit { state in
        if sidebar { state.settings.sidebarWidth = value } else { state.settings.panelWidth = value }
      }
    } catch { operationError = error.localizedDescription; store.clearError() }
    if sidebar { sidebarWidthDraft = nil } else { libraryWidthDraft = nil }
  }

  private func discardThemePreview() {
    guard actions.themeEditor || themeDraft != nil else { return }
    actions.themeEditor = false; themeDraft = nil; themeError = nil; creatingSpace = false
  }
  private func openNewSpace() {
    guard store.state.spaces.count < 500 else { operationError = "Space limit reached."; return }
    actions.palette = false; actions.library = nil; store.state.settings.sidebarVisible = true
    creatingSpace = true; actions.themeEditor = true
  }
  private var sidebarKeyboardItems: [String] {
    var items = tabs.filter { $0.isFavorite && store.split(for: $0.id)?.spaceID != store.state.activeSpaceID }.map(\.id)
    for folder in store.state.folders where folder.spaceID == store.state.activeSpaceID {
      items.append("folder:\(folder.id)")
      if folder.isExpanded { items += tabs.filter { $0.folderID == folder.id && !$0.isFavorite && store.split(for: $0.id) == nil }.map(\.id) }
    }
    items += tabs.filter { $0.isPinned && !$0.isFavorite && $0.folderID == nil && store.split(for: $0.id) == nil }.map(\.id)
    items += store.state.splits.filter { $0.spaceID == store.state.activeSpaceID }.flatMap(\.tabIDs)
    items += tabs.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil && ($0.url != "about:blank" || $0.homePage == true) && store.split(for: $0.id) == nil }.map(\.id)
    return items
  }
  private func handleSidebarKey(_ key: KeyPress) -> KeyPress.Result {
    if isContextMenuKey(key), let current = sidebarFocus {
      contextMenuRequest = current; return .handled
    }
    guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
      let current = sidebarFocus, let index = sidebarKeyboardItems.firstIndex(of: current) else { return .ignored }
    let items = sidebarKeyboardItems
    switch key.key {
    case .home: sidebarFocus = items.first
    case .end: sidebarFocus = items.last
    case .upArrow: sidebarFocus = items[max(0, index - 1)]
    case .downArrow: sidebarFocus = items[min(items.count - 1, index + 1)]
    case .leftArrow, .rightArrow:
      let folderID = current.hasPrefix("folder:") ? String(current.dropFirst(7)) : store.tab(current)?.folderID
      if let folderID, let folder = store.state.folders.first(where: { $0.id == folderID }) {
        if key.key == .leftArrow {
          if current != "folder:\(folderID)" { sidebarFocus = "folder:\(folderID)" }
          else { store.updateFolder(id: folderID, isExpanded: false) }
        } else if !folder.isExpanded { store.updateFolder(id: folderID, isExpanded: true) }
        else { sidebarFocus = items[min(items.count - 1, index + 1)] }
      } else if store.tab(current)?.isFavorite == true {
        let favorites = items.filter { store.tab($0)?.isFavorite == true }
        guard let position = favorites.firstIndex(of: current) else { return .ignored }
        sidebarFocus = favorites[min(favorites.count - 1, max(0, position + (key.key == .leftArrow ? -1 : 1)))]
      } else { return .ignored }
    default: return .ignored
    }
    return .handled
  }
  private func performTabAction(_ action: String, tab: BrowserTab) {
    guard let operation = actions.performLibraryAction, let profileID = store.profileID(for: tab) else { return }
    Task { @MainActor in
      do { try await operation(action, ["tabID": tab.id, "profileId": profileID]) }
      catch { operationError = error.localizedDescription }
    }
  }
  private func maybeOpenBlankPalette() {
    let tab = store.state.activeTab
    guard (tab == nil || (tab?.url == "about:blank" && tab?.homePage != true)),
      !actions.palette, actions.library == nil, !actions.themeEditor, editor == nil,
      !showBrowserMenu, !showPageActions, !showSiteControls,
      creation == nil, renameTarget == nil, drag.id == nil else { return }
    let context = "\(store.state.activeSpaceID):\(store.state.activeTabID ?? "empty")"
    guard blankPaletteContext != context else { return }
    blankPaletteContext = context
    DispatchQueue.main.async {
      guard "\(store.state.activeSpaceID):\(store.state.activeTabID ?? "empty")" == context,
        editor == nil, actions.library == nil, !actions.themeEditor,
        store.state.activeTab?.homePage != true,
        store.state.activeTab == nil || store.state.activeTab?.url == "about:blank" else { return }
      actions.openPalette()
    }
  }
  private func beginRename(_ target: SidebarNamedItem, name: String) {
    creation = nil
    nameError = nil
    self.name = name
    renameTarget = target
  }
  private func saveName() {
    let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    guard !value.isEmpty else { return }
    guard let target = renameTarget else {
      createNamedItem()
      return
    }
    do {
      try store.commit { state in
        switch target {
        case .tab(let id):
          if let index = state.tabs.firstIndex(where: { $0.id == id }) { state.tabs[index].customTitle = value }
        case .folder(let id):
          if let index = state.folders.firstIndex(where: { $0.id == id }) { state.folders[index].name = String(value.prefix(60)) }
        case .space(let id):
          if let index = state.spaces.firstIndex(where: { $0.id == id }) { state.spaces[index].name = String(value.prefix(60)) }
        case .profile(let id):
          if let index = state.profiles.firstIndex(where: { $0.id == id }) { state.profiles[index].name = String(value.prefix(60)) }
        }
      }
      renameTarget = nil; nameError = nil
    } catch { nameError = error.localizedDescription; store.clearError() }
  }
  private var nameLimit: Int { if let renameTarget, case .tab = renameTarget { return 200 }; return 60 }
  private func canDeleteProfile(_ id: String) -> Bool {
    store.state.profiles.contains { !$0.isPrivate && $0.id != id }
  }
  private func canDeleteSpace(_ space: BrowserSpace) -> Bool {
    store.state.spaces.filter { $0.profileID == space.profileID }.count > 1
  }
  private func spaceMenu(_ space: BrowserSpace) -> some View { NativeMenuCommands(items: spaceMenuItems(space)) }
  private func spaceMenuItems(_ space: BrowserSpace) -> [NativeMenuAction] {
    var items: [NativeMenuAction] = []
    if space.id != store.state.activeSpaceID { items.append(.init(id: "switch", title: "Switch to Space", glyph: "arrow") { store.selectSpace(id: space.id) }) }
    items.append(.init(id: "customize", title: "Customize Space", glyph: "settings") {
      store.selectSpace(id: space.id)
      actions.themeEditor = true
    })
    items.append(.init(id: "rename", title: "Rename Space…", glyph: "edit") { beginRename(.space(space.id), name: space.name) })
    if let tab = store.state.activeTab, tab.spaceID != space.id, tab.url != "about:blank" {
      items.append(.init(id: "move", title: "Move current tab here", glyph: "folder") { store.moveTab(id: tab.id, spaceID: space.id) })
    }
    items.append(.init(id: "new", title: "New Space", glyph: "plus", divider: true) { openNewSpace() })
    items.append(.init(id: "delete", title: "Delete Space…", glyph: "trash", enabled: canDeleteSpace(space)) {
      confirmDelete(.space(space.id), name: space.name)
    })
    return items
  }
  private func folderMenuItems(_ folder: BrowserFolder) -> [NativeMenuAction] {
    [
      .init(id: "rename", title: "Rename folder…", glyph: "edit") { beginRename(.folder(folder.id), name: folder.name) },
      .init(id: "delete", title: "Remove folder", glyph: "trash") { store.deleteFolder(id: folder.id) },
    ]
  }
  private func menuAnchor(id: String, items: [NativeMenuAction]) -> some View {
    NativeContextMenuAnchor(requested: contextMenuRequest == id, items: items) {
      if contextMenuRequest == id { contextMenuRequest = nil }
      if editor == nil, creation == nil, renameTarget == nil, !actions.palette, !actions.themeEditor,
        !showBrowserMenu, !showPageActions,
        store.tab(id) != nil || id.hasPrefix("space:") || id.hasPrefix("folder:") { sidebarFocus = id }
    }.allowsHitTesting(false)
  }
  private func isContextMenuKey(_ key: KeyPress) -> Bool {
    key.modifiers.intersection([.command, .control, .option]).isEmpty
      && (key.key == KeyEquivalent("\u{F735}") || (key.key == KeyEquivalent("\u{F70D}") && key.modifiers.contains(.shift)))
  }
  private var pageMenuItems: [NativeMenuAction] {
    let controls = actions.siteControls
    let shortcuts = BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides)
    func shortcut(_ id: String) -> String? { shortcuts.first(where: { $0.id == id })?.accelerator }
    return [
      .init(id: "bookmark", title: controls.isBookmarked ? "Remove bookmark" : "Bookmark this page", glyph: "star", shortcut: shortcut("bookmark"), enabled: hasPage, action: controls.bookmark),
      .init(id: "split", title: controls.isSplit ? "Unsplit tabs" : "Split view", glyph: "split", action: controls.split),
      .init(id: "find", title: "Find on page", glyph: "search", shortcut: shortcut("find"), enabled: hasPage, action: controls.find),
      .init(id: "print", title: "Print page", glyph: "print", shortcut: shortcut("print"), enabled: hasPage, action: controls.printPage),
      .init(id: "zoom-out", title: "Zoom out", glyph: "minimize", enabled: hasPage, divider: true, keepsOpen: true, action: controls.zoomOut),
      .init(id: "zoom-reset", title: "\(controls.zoomPercent)% · Actual size", glyph: "monitor", enabled: hasPage, keepsOpen: true, action: controls.resetZoom),
      .init(id: "zoom-in", title: "Zoom in", glyph: "plus", enabled: hasPage, keepsOpen: true, action: controls.zoomIn),
      .init(id: "external", title: "Open in default browser", glyph: "external", enabled: hasPage, divider: true, action: controls.openDefaultBrowser),
      .init(id: "menu", title: "Browser menu", glyph: "more", shortcut: shortcut("browser-menu"), action: controls.browserMenu),
    ]
  }
  private var browserMenuItems: [NativeMenuAction] {
    let order = ["command-palette", "new-private-space", "spaces", "page-actions", "find", "zoom-in", "zoom-out", "zoom-reset", "print", "developer-tools", "extensions", "preferences", "shortcuts", "onboarding", "home-page", "about"]
    return order.compactMap { id in
      if id == "spaces" { return .init(id: id, title: "Spaces & profiles", glyph: "user") { _ = performInterfaceCommand("spaces") } }
      if id == "page-actions" { return .init(id: id, title: "Page actions", glyph: "pageControls") { _ = performInterfaceCommand(id) } }
      if id == "home-page" { return .init(id: id, title: "Home page", glyph: "monitor") { _ = performInterfaceCommand(id) } }
      guard let command = actions.runtimeCommands.first(where: { $0.id == id }) else { return nil }
      return .init(id: id, title: id == "command-palette" ? "New tab" : command.title, glyph: command.icon,
        shortcut: command.shortcut, enabled: command.available, divider: id == "find" || id == "extensions", action: command.action)
    }
  }
  private func confirmDelete(_ target: SidebarNamedItem, name: String) {
    let alert = NSAlert()
    alert.messageText = "Delete \(target.kind.lowercased()) “\(name)”?"
    alert.alertStyle = .warning
    switch target {
    case .folder: alert.informativeText = "The tabs inside this folder will remain in this Space."
    case .space(let id):
      guard let space = store.state.spaces.first(where: { $0.id == id }), canDeleteSpace(space)
      else { return }
      alert.informativeText = "Tabs will move to another Space in this profile."
    case .profile(let id):
      guard canDeleteProfile(id) else { return }
      alert.informativeText =
        "This removes the profile and its Spaces, tabs, bookmarks, and history. Other profiles are kept."
    case .tab: return
    }
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    alert.buttons.last?.keyEquivalent = "\r"
    alert.buttons.first?.keyEquivalent = ""
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    switch target {
    case .folder(let id): store.deleteFolder(id: id)
    case .space(let id): actions.deleteSpace(id)
    case .profile(let id): actions.deleteProfile(id)
    case .tab: break
    }
  }
  private func isBookmarked(_ url: String) -> Bool {
    store.state.bookmarks.contains { $0.profileID == store.activeProfileID && $0.url == url }
  }
  private func createNamedItem() {
    let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    guard !trimmed.isEmpty else { return }
    do {
      if creation == "Space" {
        let space = BrowserSpace(profileID: store.activeProfileID, name: trimmed)
        try store.commit { state in state.spaces.append(space); state.activeSpaceID = space.id; state.activeTabID = nil }
      } else if creation == "profile" {
        _ = try store.createProfileDurably(name: trimmed)
      } else {
        _ = try store.createFolderDurably(name: trimmed)
      }
      creation = nil; nameError = nil
    } catch {
      nameError = error.localizedDescription; store.clearError()
    }
  }
}

/// Native child browser windows need actual AppKit bounds. A SwiftUI preference
/// can disappear across hosting boundaries, so publish from a retained native
/// view after each layout, in the parent's top-left content coordinates.
private struct NativeContentFrameReporter: NSViewRepresentable {
  var changed: (CGRect) -> Void
  func makeNSView(context: Context) -> FrameView {
    let view = FrameView(); view.changed = changed; return view
  }
  func updateNSView(_ view: FrameView, context: Context) { view.changed = changed; view.report() }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrameView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
  final class FrameView: NSView {
    var changed: (CGRect) -> Void = { _ in }
    private var pending = false
    private var last = CGRect.zero
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); report() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); report() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); report() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); last = .zero; report() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); report() }
    func report() {
      guard !pending else { return }
      pending = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pending = false
        guard let root = self.window?.contentView, self.bounds.width > 0, self.bounds.height > 0 else { return }
        let native = root.convert(self.bounds, from: self)
        let frame = root.isFlipped ? native : CGRect(x: native.minX, y: root.bounds.height - native.maxY, width: native.width, height: native.height)
        guard frame != self.last else { return }
        self.last = frame; self.changed(frame)
      }
    }
  }
}
private struct WindowMaterialMask: Shape {
  var hole: CGRect
  var radius: Double
  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    if !hole.isEmpty {
      path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius))
    }
    return path
  }
}
private enum SidebarNamedItem: Equatable {
  case tab(String)
  case folder(String)
  case space(String)
  case profile(String)
  var kind: String {
    switch self {
    case .tab: "Tab"
    case .folder: "Folder"
    case .space: "Space"
    case .profile: "Profile"
    }
  }
}
private enum SidebarSection: Equatable {
  case favorite, pinned, regular
  case folder(String)
  var folderID: String? {
    if case .folder(let id) = self { return id }
    return nil
  }
  var pinned: Bool { self != .regular }
}
@MainActor private final class SidebarDragSession: ObservableObject {
  @Published var id: String?
  @Published var preview: [BrowserTab]?
  private var hover: DispatchWorkItem?
  func start(_ id: String, tabs: [BrowserTab]) {
    cancel()
    self.id = id
    preview = tabs
  }
  func cancel() {
    hover?.cancel()
    hover = nil
    id = nil
    preview = nil
  }
  func stopHover() {
    hover?.cancel()
    hover = nil
  }
  func scheduleHover(_ action: @escaping () -> Void) {
    stopHover()
    let work = DispatchWorkItem(block: action)
    hover = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
  }
  func project(store: BrowserStore, space: String, section: SidebarSection, before: String?, after: Bool = false) {
    guard let id, let source = store.tab(id), before != id,
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else { return }
    var projected = preview ?? store.state.tabs
    guard let index = projected.firstIndex(where: { $0.id == id }) else { return }
    var moved = projected.remove(at: index)
    moved.spaceID = space; moved.folderID = section.folderID
    moved.isFavorite = section == .favorite; moved.isPinned = section.pinned
    moved.savedURL = section.pinned ? (moved.savedURL ?? moved.url) : nil
    if !section.pinned { moved.isClosed = false }
    let destination: Int
    if let before, let target = projected.firstIndex(where: { $0.id == before }) {
      destination = target + (after ? 1 : 0)
    } else {
      let last = projected.lastIndex { tab in
        if section == .favorite { return tab.isFavorite && store.profileID(for: tab) == store.activeProfileID }
        guard tab.spaceID == space, !tab.isFavorite else { return false }
        if let folder = section.folderID { return tab.folderID == folder }
        return tab.folderID == nil && tab.isPinned == section.pinned
      }
      destination = last.map { $0 + 1 } ?? projected.count
    }
    projected.insert(moved, at: min(projected.count, destination))
    guard projected != preview else { return }
    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.14)) { preview = projected }
  }
  func commit(store: BrowserStore, space: String, section: SidebarSection? = nil) -> Bool {
    guard let id, let source = store.tab(id),
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else { cancel(); return false }
    let index = section == nil ? nil : preview?.firstIndex(where: { $0.id == id })
    store.moveTab(id: id, spaceID: space, folderID: section?.folderID, index: index,
      pinned: section?.pinned, favorite: section.map { $0 == .favorite }, clearFolder: section != nil)
    cancel(); return true
  }

}
private struct SidebarDropDelegate: DropDelegate {
  let store: BrowserStore
  let drag: SidebarDragSession
  let section: SidebarSection
  let spaceID: String
  var before: String?
  var extent: CGSize?
  func validateDrop(info: DropInfo) -> Bool { drag.id != nil }
  func dropEntered(info: DropInfo) {
    drag.stopHover()
    project(info)
  }
  private func project(_ info: DropInfo) {
    let after = extent.map { section == .favorite ? info.location.x > $0.width / 2 : info.location.y > $0.height / 2 } ?? false
    drag.project(store: store, space: spaceID, section: section, before: before, after: after)
  }
  func dropUpdated(info: DropInfo) -> DropProposal? { project(info); return DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    project(info)
    return drag.commit(store: store, space: spaceID, section: section)
  }
}
private struct SpaceHoverDropDelegate: DropDelegate {
  let store: BrowserStore
  let drag: SidebarDragSession
  var repeatNavigation = false
  let target: () -> String?
  func validateDrop(info: DropInfo) -> Bool { drag.id != nil }
  func dropEntered(info: DropInfo) { schedule() }
  private func schedule() {
    drag.scheduleHover {
      guard drag.id != nil, let next = target() else { return }
      store.selectSpace(id: next)
      if repeatNavigation { schedule() }
    }
  }
  func dropExited(info: DropInfo) { drag.stopHover() }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    let destination =
      repeatNavigation ? store.state.activeSpaceID : (target() ?? store.state.activeSpaceID)
    return drag.commit(store: store, space: destination)
  }
}
extension NSColor {
  fileprivate convenience init(hex: String) {
    let value =
      UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x9D4460
    self.init(
      srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255, alpha: 1)
  }
}

/// A separate native panel stays above Chromium's child windows without hiding
/// or taking snapshots of any browser documents.
private struct NativePalettePresenter: NSViewRepresentable {
  @Binding var isPresented: Bool
  var content: AnyView
  var motionScale: Double
  var frame: CGRect? = nil
  var presentationID: UInt64 = 0
  var takesKey = true
  var dismissOnOutsideClick = true
  var dismissOnResign = true

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> PaletteAnchorView {
    let view = PaletteAnchorView()
    view.didAttach = { [weak coordinator = context.coordinator] window in
      coordinator?.attach(to: window)
    }
    return view
  }
  func updateNSView(_ view: PaletteAnchorView, context: Context) {
    context.coordinator.presenter = self
    context.coordinator.attach(to: view.window)
  }
  static func dismantleNSView(_ view: PaletteAnchorView, coordinator: Coordinator) {
    coordinator.hide()
  }

  @MainActor final class Coordinator {
    var presenter: NativePalettePresenter
    weak var parent: NSWindow?
    private var panel: PalettePanel?
    private var hosting: NSHostingView<AnyView>?
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var lastPresentationID: UInt64?
    init(_ presenter: NativePalettePresenter) { self.presenter = presenter }

    func attach(to window: NSWindow?) {
      if parent !== window {
        hide()
        parent = window
      }
      guard presenter.isPresented, let parent else {
        if presenter.isPresented { trace("awaiting parent") }
        hide()
        return
      }
      if let hosting, let panel {
        hosting.rootView = presenter.content
        resize()
        // AppKit may hide a floating panel during native popup/application
        // activation. An explicit command must always bring that panel back.
        if !panel.isVisible || lastPresentationID != presenter.presentationID {
          lastPresentationID = presenter.presentationID
          panel.alphaValue = 1
          if presenter.takesKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
          trace("restore panel \(panel.windowNumber)")
        }
        lastPresentationID = presenter.presentationID
        return
      }
      let panel = PalettePanel(
        contentRect: contentRect(parent), styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.hidesOnDeactivate = true
      panel.isReleasedWhenClosed = false
      panel.level = .floating
      panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
      panel.setAccessibilityLabel(presenter.takesKey && presenter.dismissOnOutsideClick ? "Command palette" : "Browser controls")
      let hosting = NativeOverlayHostingView(rootView: presenter.content)
      hosting.autoresizingMask = [.width, .height]
      panel.contentView = hosting
      self.hosting = hosting
      self.panel = panel
      lastPresentationID = presenter.presentationID
      parent.addChildWindow(panel, ordered: .above)
      panel.alphaValue = presenter.motionScale > 0 ? 0 : 1
      if presenter.takesKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
      trace("show panel \(panel.windowNumber) parent \(parent.windowNumber) frame \(panel.frame)")
      if presenter.motionScale > 0 {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.12 * presenter.motionScale
          panel.animator().alphaValue = 1
        }
      }
      for name in [
        NSWindow.didMoveNotification, NSWindow.didResizeNotification,
        NSWindow.didEndLiveResizeNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.resize() }
          })
      }
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self, weak panel] _ in Task { @MainActor in
          guard let self, let panel, self.panel === panel else { return }
          self.dismiss(reason: "parent closed")
        } })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self, weak panel] _ in Task { @MainActor in
          guard let self, let panel, self.panel === panel, !NSApp.isActive,
            self.presenter.dismissOnResign else { return }
          self.dismiss(reason: "application resigned")
        } })
      mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, self.presenter.dismissOnOutsideClick, let parent = self.parent, let clicked = event.window,
          clicked !== self.panel
        else { return event }
        // Never inspect or consume mouse events from another app/window tree.
        var candidate: NSWindow? = clicked
        while let window = candidate {
          if window === parent {
            self.dismiss(reason: "outside click")
            break
          }
          candidate = window.parent
        }
        return event
      }
    }
    private func contentRect(_ window: NSWindow) -> NSRect {
      guard let view = window.contentView else {
        return window.contentRect(forFrameRect: window.frame)
      }
      let rect: CGRect
      if let frame = presenter.frame {
        // Shared browser geometry is top-left based; AppKit content views are not.
        rect = view.isFlipped ? frame : CGRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height)
      } else { rect = view.bounds }
      return window.convertToScreen(view.convert(rect, to: nil))
    }
    private func resize() {
      guard let parent, let panel else { return }
      let next = contentRect(parent)
      if panel.frame != next { panel.setFrame(next, display: true) }
    }
    private func dismiss(reason: String) {
      trace("dismiss \(reason)")
      presenter.isPresented = false
      hide()
    }
    func hide() {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll()
      if let mouseMonitor {
        NSEvent.removeMonitor(mouseMonitor)
        self.mouseMonitor = nil
      }
      guard let panel else { return }
      trace("hide panel \(panel.windowNumber)")
      let restoreKey = NSApp.keyWindow === panel
      parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      panel.contentView = nil
      hosting = nil
      self.panel = nil
      lastPresentationID = nil
      if restoreKey, parent?.isVisible == true { parent?.makeKey() }
    }
    private func trace(_ message: String) {
      guard ProcessInfo.processInfo.environment["ZACRO_NATIVE_LAYOUT_TRACE"] == "1" else { return }
      fputs("[Native overlay] \(message); presented=\(presenter.isPresented) key=\(NSApp.keyWindow?.windowNumber ?? -1) active=\(NSApp.isActive)\n", stderr)
    }
  }
}

private final class PaletteAnchorView: NSView {
  var didAttach: ((NSWindow?) -> Void)?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    didAttach?(window)
  }
}
private final class PalettePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Keep the original browser's unobtrusive scrolling even when macOS is set to
/// show legacy scrollbars. Scrolling and accessibility scrolling remain intact.
private final class NativeOverlayHostingView: NSHostingView<AnyView> {
  override func layout() {
    super.layout()
    func visit(_ view: NSView) {
      if let scroll = view as? NSScrollView {
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        scroll.autohidesScrollers = true
      }
      for child in view.subviews { visit(child) }
    }
    for child in subviews { visit(child) }
  }
}

private struct NativeSplitDropOverlay: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  @ObservedObject var drag: SidebarDragSession
  let colors: NativeSpacePalette
  @State private var hovered: String?
  var body: some View {
    HStack(spacing: 6) {
      ForEach(["left", "right"], id: \.self) { side in
        ZStack {
          RoundedRectangle(cornerRadius: store.state.settings.pageRadius)
            .fill(colors.chrome.opacity(hovered == side ? 0.58 : 0))
          Text("Split \(side)").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colors.ink).padding(.horizontal, 14).padding(.vertical, 9)
            .background(colors.card, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }.contentShape(Rectangle())
          .onDrop(of: [.plainText], isTargeted: Binding(get: { hovered == side }, set: { if $0 { hovered = side } else if hovered == side { hovered = nil } })) { _ in
            guard let id = drag.id, let source = store.tab(id), let target = store.state.activeTab,
              target.id != id, store.profileID(for: source) == store.activeProfileID,
              store.split(for: id) == nil, store.split(for: target.id) == nil else { return false }
            if source.spaceID != store.state.activeSpaceID && !source.isFavorite { store.moveTab(id: id, spaceID: store.state.activeSpaceID) }
            if source.isClosed { store.updateTab(id) { $0.isClosed = false } }
            store.setSplit(left: side == "left" ? id : target.id, right: side == "right" ? id : target.id)
            store.selectTab(id: id); actions.activate(id); drag.cancel(); return true
          }
      }
    }
  }
}

private struct NativeFindBar: View {
  @ObservedObject var actions: BrowserActions
  let colors: NativeSpacePalette
  var body: some View {
    HStack(spacing: 3) {
      NativeFindField(text: $actions.findQuery, ink: NSColor(colors.ink), muted: NSColor(colors.muted), changed: actions.updateFind,
        next: actions.findNext, previous: actions.findPrevious, close: close)
        .frame(minWidth: 80, maxWidth: 160)
      Text(actions.findQuery.isEmpty ? "" : "\(actions.findActiveMatch) / \(actions.findMatchCount)")
        .font(.system(size: 10)).monospacedDigit()
        .foregroundStyle(!actions.findQuery.isEmpty && actions.findMatchCount == 0 ? .red : colors.muted)
      Button(action: actions.findPrevious) { NativeGlyph("chevron.up").frame(width: 26, height: 26) }
        .help("Previous match").accessibilityLabel("Previous match")
      Button(action: actions.findNext) { NativeGlyph("chevron.down").frame(width: 26, height: 26) }
        .help("Next match").accessibilityLabel("Next match")
      Button(action: close) { NativeGlyph("xmark").frame(width: 26, height: 26) }
        .help("Close find").accessibilityLabel("Close find")
    }.buttonStyle(.plain).font(.system(size: 12)).padding(.leading, 8).padding(.trailing, 5)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(colors.ink).background { NativeControlSurface().overlay(colors.card.opacity(0.84)).clipShape(RoundedRectangle(cornerRadius: 7)) }
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.ink.opacity(0.1), lineWidth: 1))
      .shadow(color: .black.opacity(0.09), radius: 7, y: 4)
  }
  private func close() { actions.findVisible = false; actions.closeFind() }
}
private struct NativeFindField: NSViewRepresentable {
  @Binding var text: String
  let ink: NSColor
  let muted: NSColor
  let changed: (String) -> Void
  let next: () -> Void
  let previous: () -> Void
  let close: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(); field.font = .systemFont(ofSize: 12); field.drawsBackground = false; field.isBordered = false
    field.focusRingType = .none; field.placeholderString = "Find on page"; field.delegate = context.coordinator
    field.setAccessibilityLabel("Find on page")
    DispatchQueue.main.async { field.window?.makeFirstResponder(field); field.selectText(nil) }
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.textColor = ink
    field.placeholderAttributedString = NSAttributedString(string: "Find on page", attributes: [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 12)])
    if field.stringValue != text { field.stringValue = text }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NativeFindField
    init(_ parent: NativeFindField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue; parent.changed(field.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      if selector == #selector(NSResponder.cancelOperation(_:)) { parent.close(); return true }
      if selector == #selector(NSResponder.insertNewline(_:)) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { parent.previous() } else { parent.next() }
        return true
      }
      return false
    }
  }
}
