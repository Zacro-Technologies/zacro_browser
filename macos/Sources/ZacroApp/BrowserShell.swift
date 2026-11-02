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
  @Published var loadingTabIDs: Set<String> = []
  @Published var documentErrors: [String: String] = [:]
  @Published var recordingShortcut = false
  @Published var shortcutCaptureReady = false
  @Published var shortcutCaptureError: String?
  @Published var findVisible = false
  @Published var findSession: UInt64 = 0
  @Published var findQuery = ""
  @Published var findMatchCount = 0
  @Published var findActiveMatch = 0
  var findNext: () -> Void = {}
  var findPrevious: () -> Void = {}
  var closeFind: () -> Void = {}
  var focusPage: () -> Void = {}
  var updateFind: (String) -> Void = { _ in }
  @Published var nativePageVisible = false
  @Published var contentFrame = CGRect.zero
  @Published var paletteRequest: NativePaletteRequest?
  @Published var runtimeCommands: [BrowserRuntimeCommand] = []
  @Published var libraryCapabilities: Set<String> = []
  @Published var libraryMessages: [String: String] = [:]
  @Published var interfaceError: String?
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
  func openFind() {
    palette = false
    _ = handleInterfaceEscape()
    findSession &+= 1
    findVisible = true
  }
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
  @StateObject private var spaceViewport = NativeSpaceViewport()
  @State private var spaceScroll = NativeSpaceScrollCache()
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
  @State private var hoveredNewTab = false
  @State private var rowMotionSpaceID: String?
  @State private var editingGroupColor: String?
  @State private var operationError: String?
  @State private var nameError: String?
  @FocusState private var sidebarFocus: String?
  @State private var libraryReturnFocus: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
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
    guard let blend = spaceViewport.blend, blend.from != blend.to,
      let first = spaces.first(where: { $0.id == blend.from }), let last = spaces.first(where: { $0.id == blend.to }) else { return editingTheme }
    var value = NativeSpaceAppearance.blend(first.theme, last.theme, progress: blend.progress)
    value.appearance = editingTheme.appearance
    return value
  }
  private var effectiveMotion: Double { reduceMotion ? 0 : store.state.settings.motionScale }
  private var allowsRowMotion: Bool {
    effectiveMotion > 0 && rowMotionSpaceID == store.state.activeSpaceID
      && !spaceViewport.isTracking && !spaceViewport.isAnimating && drag.id == nil
  }
  private var rowAnimation: Animation? {
    allowsRowMotion ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.14 * effectiveMotion) : nil
  }
  private var isPopup: Bool {
    store.state.windowSessions?.first(where: { $0.id == store.owningWindowID })?.kind == .popup
  }
  private var colors: NativeSpacePalette {
    NativeSpacePalette(theme: theme, dark: theme.appearance == "dark"
      || (theme.appearance == "system" && colorScheme == .dark), increasedContrast: contrast == .increased)
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
  private var currentAddress: String {
    if let peek = store.state.activeTab?.peek, peek.isPresented != false { return peek.url }
    return store.state.activeTab?.url ?? ""
  }
  private var sidebarWidth: Double {
    guard !isPopup else { return 0 }
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
    Group {
      if isPopup { popupShell }
      else { standardShell }
    }
  }

  /// Registered extension options and Chrome popup windows retain their own
  /// document, but do not inherit the browser's sidebar or Library presentation.
  private var popupShell: some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        NativeContentFrameReporter { frame in publishContentFrame(frame) }
          .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
      }
      .padding(.top, actions.findVisible ? 40 : 0)
      .background {
        NativePalettePresenter(
          isPresented: $actions.findVisible,
          content: AnyView(NativeFindBar(actions: actions, colors: colors)), motionScale: effectiveMotion,
          frame: CGRect(x: max(actions.contentFrame.minX + 8, actions.contentFrame.maxX - 326),
            y: 4, width: min(310, max(200, actions.contentFrame.width - 24)), height: 32),
          presentationID: actions.findSession, takesKey: true, dismissOnOutsideClick: false, dismissOnResign: false)
          .frame(width: 0, height: 0).allowsHitTesting(false)
      }
      .onAppear {
        actions.performInterfaceCommand = { _ in false }
        actions.handleInterfaceEscape = { false }
      }
  }

  private var standardShell: some View {
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
       if let message = actions.interfaceError ?? store.lastError, editor == nil, themeError == nil, operationError == nil, nameError == nil {
         HStack(spacing: 8) {
           NativeGlyph("info.circle").foregroundStyle(accent).frame(width: 16)
           Text(message).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
           Button {
             if actions.interfaceError != nil { actions.interfaceError = nil }
             else { store.clearError() }
           } label: { NativeGlyph("xmark").frame(width: 24, height: 24) }
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
        frame: CGRect(x: max(actions.contentFrame.minX + 8, actions.contentFrame.maxX - 326), y: 4,
          width: min(310, max(200, actions.contentFrame.width - 24)), height: 32),
        presentationID: actions.findSession, takesKey: true, dismissOnOutsideClick: false, dismissOnResign: false)
        .frame(width: 0, height: 0).allowsHitTesting(false)
      if sidebarWidth == 0 {
        let items = showPageActions ? pageMenuItems : browserMenuItems
        NativePalettePresenter(
          isPresented: Binding(get: { showBrowserMenu || showPageActions }, set: { if !$0 { showBrowserMenu = false; showPageActions = false } }),
          content: AnyView(NativeActionPopover(title: showPageActions ? "Page actions" : "Browser menu", items: items, colors: colors,
            compactZoom: showPageActions, motionScale: effectiveMotion,
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
      if drag.id != nil && !drag.native.isDragging && NSEvent.pressedMouseButtons == 0 { drag.cancel() }
    }
    .onAppear {
      synchronizeSpaces()
      rowMotionSpaceID = store.state.activeSpaceID
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
      synchronizeSpaces()
      rowMotionSpaceID = store.state.activeSpaceID
      drag.resetReflow(store: store)
      discardThemePreview()
      maybeOpenBlankPalette()
    }
    .onChange(of: spaces.map(\.id)) { _, _ in synchronizeSpaces() }
    .onChange(of: effectiveMotion) { _, _ in synchronizeSpaces() }
    .onDisappear { spaceViewport.stop() }
    .onChange(of: store.activeProfileID) { _, _ in drag.cancel() }
    .onChange(of: store.state.tabs) { _, _ in drag.reconcile(store: store) }
    .onChange(of: store.state.activeTabID) { _, _ in maybeOpenBlankPalette() }
    .onChange(of: actions.palette) { _, presented in if presented { discardThemePreview() } }
    .onChange(of: editor) { _, value in if value == nil { maybeOpenBlankPalette() } else { discardThemePreview() } }
    .onChange(of: actions.library) { previous, value in
      if value == nil {
        restoreLibraryFocus()
        maybeOpenBlankPalette()
      } else {
        if previous == nil { libraryReturnFocus = sidebarFocus ?? "library" }
        discardThemePreview()
      }
    }
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
      (active.peek == nil || active.peek?.isPresented == false), store.profileID(for: source) == store.activeProfileID,
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
      .padding(.horizontal, store.state.settings.pageGutter)
      .padding(.bottom, store.state.settings.pageGutter)
      .padding(.top, actions.findVisible ? 40 : store.state.settings.pageGutter)
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
          withTransaction(transaction) { spaceViewport.track(progress: value) }
        },
        onSelect: { index, duration in
          guard spaces.indices.contains(index) else { return }
          spaceViewport.settle(selectedID: spaces[index].id, duration: duration, motionScale: effectiveMotion)
          store.selectSpace(id: spaces[index].id)
        }
      ) {
        GeometryReader { geometry in
          ZStack(alignment: .topLeading) {
            ForEach(spaceViewport.frames) { frame in
              if let space = spaces.first(where: { $0.id == frame.id }) {
                spacePage(space, height: geometry.size.height)
                  .frame(width: geometry.size.width, height: geometry.size.height)
                  .offset(x: frame.offset * geometry.size.width)
              }
            }
          }.clipped()
        }.font(.system(size: 13)).foregroundStyle(colors.ink).tint(accent)
          .environment(\.presentedSpaceTheme, theme)
          .preferredColorScheme(theme.appearance == "dark" ? .dark : theme.appearance == "light" ? .light : nil)
      }
      spaceFooter
    }.padding(.horizontal, 8)
      .background {
        NativeSidebarDragHost(controller: drag.native, motionScale: effectiveMotion, canStart: { [weak store] id in
          guard let store, let tab = store.tab(id) else { return false }
          return store.profileID(for: tab) == store.activeProfileID && store.split(for: id) == nil
        }, began: { [weak drag, weak store] id in
          guard let store else { return }
          drag?.start(id, tabs: store.state.tabs)
        }, ended: { [weak drag] in drag?.cancel() })
      }
      .overlay(alignment: .leading) { spaceEdge(-1) }
      .overlay(alignment: .trailing) { spaceEdge(1) }
  }
  private func synchronizeSpaces() {
    spaceScroll.prune(spaceIDs: Set(store.state.spaces.map(\.id)))
    spaceViewport.synchronize(ids: spaces.map(\.id), selectedID: store.state.activeSpaceID, motionScale: effectiveMotion)
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
          Group {
            if active { favoriteGrid }
            else { previewFavorites(favorites, selectedID: space.lastActiveTabID) }
          }.background {
            NativeSpaceScrollAnchor(cache: spaceScroll, spaceID: space.id, favorites: true, active: active)
              .allowsHitTesting(false)
          }
        }.scrollIndicators(.hidden).frame(height: min(naturalHeight, min(176, max(0, height * 0.35))))
          .onChange(of: sidebarFocus) { _, id in
            if active, let id, favorites.contains(where: { $0.id == id }) { reader.scrollTo(id) }
          }
      }
      ScrollViewReader { reader in
        ScrollView {
          Group {
            if active { tabList }
            else { previewTabList(space) }
          }.background {
            NativeSpaceScrollAnchor(cache: spaceScroll, spaceID: space.id, favorites: false, active: active)
              .allowsHitTesting(false)
          }
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
      HStack(spacing: 8) { NativeGlyph("plus"); Text("New Tab"); Spacer() }
        .foregroundStyle(colors.muted).padding(.horizontal, 8).frame(height: 34)
      ForEach(store.state.tabGroups.filter { group in all.contains { !$0.isClosed && $0.groupID == group.id } }) { group in
        HStack(spacing: 8) {
          NativeGlyph("chevron.down", size: 12).rotationEffect(.degrees(group.collapsed ? -90 : 0)).foregroundStyle(accent).frame(width: 16)
          Text(group.title.isEmpty ? "Tab group" : group.title).fontWeight(.semibold).lineLimit(1)
          Spacer()
          Circle().fill(groupColor(group.color)).frame(width: 10, height: 10)
        }.padding(.horizontal, 8).frame(height: 36)
        if !group.collapsed {
          VStack(spacing: 2) {
            ForEach(all.filter { !$0.isClosed && $0.groupID == group.id }) { tab in
              if let split = store.split(for: tab.id) {
                if split.leftTabID == tab.id { previewSplitRow(split, selectedID: space.lastActiveTabID) }
              } else { previewRow(tab, selected: tab.id == space.lastActiveTabID) }
            }
          }.padding(.leading, 16)
        }
      }
      ForEach(groups.filter { store.tab($0.leftTabID)?.groupID == nil }) { group in
        previewSplitRow(group, selectedID: space.lastActiveTabID)
      }
      ForEach(all.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil && !grouped.contains($0.id) && $0.groupID == nil && ($0.url != "about:blank" || $0.homePage == true) }) { tab in
        previewRow(tab, selected: tab.id == space.lastActiveTabID)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func previewSplitRow(_ group: SplitGroup, selectedID: String?) -> some View {
    HStack(spacing: 0) {
      if let left = store.tab(group.leftTabID) { previewRow(left, selected: false) }
      Rectangle().fill(colors.ink.opacity(0.14)).frame(width: 1, height: 18)
      if let right = store.tab(group.rightTabID) { previewRow(right, selected: false) }
    }.background(group.tabIDs.contains(selectedID ?? "") ? selectionBackground(true) : colors.ink.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 10))
  }
  private func previewRow(_ tab: BrowserTab, selected: Bool, favorite: Bool = false) -> some View {
    HStack(spacing: 8) {
      tabIcon(tab, size: favorite ? 20 : 16, favorite: favorite)
      if !favorite {
        if tab.isPinned && !tab.isClosed && tab.savedURL != nil && tab.savedURL != tab.url {
          Text("/").foregroundStyle(colors.muted).padding(.trailing, -5)
        }
        Text(tab.displayTitle).lineLimit(1); Spacer(minLength: 0)
      }
    }.font(.system(size: 13, weight: selected ? .medium : .regular))
      .frame(maxWidth: .infinity, minHeight: favorite ? 46 : tabHeight).padding(.horizontal, 8)
      .background(selected && !tab.isClosed ? (favorite ? favoriteSelection(tab) : selectionBackground(true)) : favorite ? colors.ink.opacity(0.05) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .topTrailing) { if favorite { peekBadge(tab, favorite: true).padding(2) } }
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
          Text(hasPage ? NativePageIdentity.label(currentAddress) : "Search or enter URL")
            .lineLimit(1).font(.system(size: 13, weight: .medium))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
          .frame(height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Edit address or search").focused($sidebarFocus, equals: "address")
        .contextMenu { NativeMenuCommands(items: pageMenuItems) }
        .popover(isPresented: $showPageActions, arrowEdge: .bottom) {
          NativeActionPopover(title: "Page actions", items: pageMenuItems, colors: colors, compactZoom: true, motionScale: effectiveMotion)
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
          NativeActionPopover(title: "Browser menu", items: browserMenuItems, colors: colors, motionScale: effectiveMotion)
        }
    }.background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      .modifier(NativeSelectionContrast(selected: true, color: colors.ink, radius: 10))
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
          Spacer(minLength: 0)
          Text(NativeInterfaceEditors.keyLabel(BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides)
            .first(where: { $0.id == "command-palette" })?.accelerator ?? ""))
            .font(.system(size: 10)).opacity(hoveredNewTab || sidebarFocus == "new-tab" ? 1 : 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 34)
      }
      .buttonStyle(NativePressButtonStyle(motionScale: effectiveMotion)).foregroundStyle(colors.muted)
        .focused($sidebarFocus, equals: "new-tab").onHover { hoveredNewTab = $0 }
      VStack(spacing: 2) {
        tabGroupRows
        splitRows
        rows(
          tabs.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil && ($0.url != "about:blank" || $0.homePage == true) },
          section: .regular)
        Color.clear.frame(height: 28)
      }.contentShape(Rectangle()).onDrop(
        of: [.plainText], delegate: dropDelegate(section: .regular))
    }.animation(rowAnimation, value: sidebarKeyboardItems)
      .transaction { if !allowsRowMotion && drag.id == nil { $0.animation = nil } }
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
      .animation(rowAnimation, value: favorites.map(\.id))
      .transaction { if !allowsRowMotion && drag.id == nil { $0.animation = nil } }
      .onDrop(of: [.plainText], delegate: dropDelegate(section: .favorite))
  }
  private var visibleTabGroups: [BrowserTabGroup] {
    let ids = Set(tabs.filter { !$0.isClosed }.compactMap(\.groupID))
    return store.state.tabGroups.filter { ids.contains($0.id) }
  }
  private let groupColors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
  private func groupColor(_ name: String) -> Color {
    switch name {
    case "blue": return Color(red: 0.30, green: 0.56, blue: 0.94)
    case "red": return Color(red: 0.91, green: 0.35, blue: 0.37)
    case "yellow": return Color(red: 0.91, green: 0.72, blue: 0.24)
    case "green": return Color(red: 0.29, green: 0.69, blue: 0.43)
    case "pink": return Color(red: 0.89, green: 0.48, blue: 0.68)
    case "purple": return Color(red: 0.65, green: 0.44, blue: 0.88)
    case "cyan": return Color(red: 0.26, green: 0.69, blue: 0.77)
    case "orange": return Color(red: 0.91, green: 0.53, blue: 0.25)
    default: return colors.muted
    }
  }
  private func updateGroup(_ group: BrowserTabGroup, color: String? = nil, collapsed: Bool? = nil) {
    do { try store.updateTabGroup(group.id, color: color, collapsed: collapsed) }
    catch { operationError = error.localizedDescription; store.clearError() }
  }
  private func groupMenuItems(_ group: BrowserTabGroup) -> [NativeMenuAction] {
    [
      .init(id: "rename", title: "Rename group…", glyph: "edit") { beginRename(.tabGroup(group.id), name: group.title) },
      .init(id: "collapse", title: group.collapsed ? "Expand group" : "Collapse group", glyph: "folder") { updateGroup(group, collapsed: !group.collapsed) },
      .init(id: "ungroup", title: "Ungroup tabs", glyph: "folder", divider: true) {
        do { try store.ungroupTabs(store.state.tabs.filter { $0.groupID == group.id }.map(\.id)) }
        catch { operationError = error.localizedDescription; store.clearError() }
      },
    ]
  }
  private var tabGroupRows: some View {
    ForEach(visibleTabGroups) { group in
      let members = tabs.filter { !$0.isClosed && $0.groupID == group.id }
      VStack(spacing: 2) {
        HStack(spacing: 0) {
          Button { updateGroup(group, collapsed: !group.collapsed) } label: {
            HStack(spacing: 8) {
              NativeGlyph("chevron.down", size: 12).rotationEffect(.degrees(group.collapsed ? -90 : 0))
                .foregroundStyle(accent).frame(width: 16)
              Text(group.title.isEmpty ? "Tab group" : group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
              Spacer(minLength: 0)
              Text("\(members.count)").font(.system(size: 10)).foregroundStyle(colors.muted)
            }.padding(.leading, 8).padding(.trailing, 4).frame(height: 36).contentShape(Rectangle())
          }.buttonStyle(.plain).focused($sidebarFocus, equals: "group:\(group.id)").id("group:\(group.id)")
            .accessibilityLabel("\(group.collapsed ? "Expand" : "Collapse") \(group.title.isEmpty ? "tab group" : group.title), \(members.count) tabs")
          Button { editingGroupColor = group.id } label: {
            Circle().fill(groupColor(group.color)).frame(width: 10, height: 10).frame(width: 27, height: 28).contentShape(Rectangle())
          }.buttonStyle(.plain).help("Group color").accessibilityLabel("Group color: \(group.color)")
            .popover(isPresented: Binding(get: { editingGroupColor == group.id }, set: { if !$0 { editingGroupColor = nil } })) {
              HStack(spacing: 5) {
                ForEach(groupColors, id: \.self) { color in
                  Button { updateGroup(group, color: color); editingGroupColor = nil } label: {
                    Circle().fill(groupColor(color)).frame(width: 18, height: 18)
                      .overlay { if group.color == color { NativeGlyph("checkmark", size: 10).foregroundStyle(.white) } }
                      .frame(width: 23, height: 28)
                  }.buttonStyle(.plain).accessibilityLabel(color.capitalized)
                    .accessibilityAddTraits(group.color == color ? [.isSelected] : [])
                }
              }.padding(9).background { NativeControlSurface().overlay(colors.chrome.opacity(0.65)) }
            }
        }
        if !group.collapsed {
          VStack(spacing: 2) {
            ForEach(members) { tab in
              if let split = store.split(for: tab.id) {
                if split.leftTabID == tab.id { splitRow(split) }
              } else { tabRow(tab, section: .regular) }
            }
          }.padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(groupColor(group.color).opacity(0.35)).frame(width: 1) }
            .padding(.leading, 8)
        }
      }.animation(reduceMotion ? nil : .easeOut(duration: 0.14 * effectiveMotion), value: group.collapsed)
        .contextMenu { NativeMenuCommands(items: groupMenuItems(group)) }
        .background { menuAnchor(id: "group:\(group.id)", items: groupMenuItems(group)) }
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
          guard let id = drag.id else { return false }
          do { _ = try store.groupTabs([id], groupID: group.id); drag.cancel(); return true }
          catch { operationError = error.localizedDescription; store.clearError(); drag.cancel(); return false }
        }
    }
  }
  private var splitRows: some View {
    ForEach(store.state.splits.filter { $0.spaceID == store.state.activeSpaceID && store.tab($0.leftTabID)?.groupID == nil }) { group in
      splitRow(group)
    }
  }
  private func splitRow(_ group: SplitGroup) -> some View {
    HStack(spacing: 0) {
      if let left = store.tab(group.leftTabID) { tabRow(left, section: .regular, grouped: true) }
      Rectangle().fill(colors.ink.opacity(0.14)).frame(width: 1, height: 18)
      if let right = store.tab(group.rightTabID) { tabRow(right, section: .regular, grouped: true) }
    }.background(!highlightedTabIDs.isDisjoint(with: group.tabIDs) ? selectionBackground(true) : colors.ink.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 10))
      .modifier(NativeSelectionContrast(selected: !highlightedTabIDs.isDisjoint(with: group.tabIDs), color: colors.ink, radius: 10))
      .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
      .accessibilityElement(children: .contain).accessibilityLabel("Split view")
  }
  private func rows(_ candidates: [BrowserTab], section: SidebarSection) -> some View {
    ForEach(candidates.filter { store.split(for: $0.id) == nil && $0.groupID == nil }) { tab in tabRow(tab, section: section) }
  }
  private var highlightedTabIDs: Set<String> {
    let id = store.owningWindowID ?? store.state.focusedWindowID
    return store.state.windowSessions?.first(where: { $0.id == id })?.highlightedTabIDs
      ?? Set(store.state.activeTabID.map { [$0] } ?? [])
  }
  private func selectSidebarTab(_ tab: BrowserTab) {
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    do {
      if !tab.isClosed && modifiers.contains(.shift), let active = store.state.activeTabID {
        let visible = sidebarKeyboardItems.filter { store.tab($0)?.isClosed == false }
        if let start = visible.firstIndex(of: active), let end = visible.firstIndex(of: tab.id) {
          try store.selectTabs(Array(visible[min(start, end)...max(start, end)]), activeID: active)
          actions.activate(active); return
        }
      }
      if !tab.isClosed && modifiers.contains(.command), let active = store.state.activeTabID {
        var highlighted = highlightedTabIDs
        if highlighted.contains(tab.id), tab.id != active { highlighted.remove(tab.id) }
        else { highlighted.insert(tab.id) }
        try store.selectTabs(store.state.tabs.filter { highlighted.contains($0.id) }.map(\.id), activeID: active)
        actions.activate(active); return
      }
      store.selectTab(id: tab.id)
      try store.selectTabs([tab.id], activeID: tab.id)
      actions.activate(tab.id)
    } catch { operationError = error.localizedDescription; store.clearError() }
  }
  private func selectionBackground(_ selected: Bool) -> Color {
    colors.card.opacity(selected ? 0.46 : 0)
  }
  private func favoriteSelection(_ tab: BrowserTab) -> Color {
    let logo = NSColor(actions.iconColors[tab.id] ?? accent)
    let card = NSColor(colors.card)
    return Color(nsColor: card.blended(withFraction: 0.22, of: logo) ?? card).opacity(0.86)
  }
  @ViewBuilder private func tabIcon(_ tab: BrowserTab, size: CGFloat, favorite: Bool = false) -> some View {
    Group {
      if !favorite && actions.loadingTabIDs.contains(tab.id) { ProgressView().controlSize(.mini).scaleEffect(0.7) }
      else if let icon = actions.icons[tab.id] { Image(nsImage: icon).resizable().scaledToFit() }
      else { NativeGlyph("globe") }
    }.frame(width: size, height: size)
      .opacity(tab.isClosed || (favorite && !actions.loadedTabIDs.contains(tab.id)) ? 0.65 : 1)
      .overlay(alignment: .topTrailing) {
        if !favorite { peekBadge(tab).offset(x: 6, y: -5) }
      }
  }
  @ViewBuilder private func peekBadge(_ tab: BrowserTab, favorite: Bool = false) -> some View {
    if let peek = tab.peek {
      Group {
        if let icon = actions.peekIcons[tab.id] { Image(nsImage: icon).resizable().scaledToFit() }
        else { NativeGlyph("globe", size: 9) }
      }.frame(width: favorite ? 15 : 12, height: favorite ? 15 : 12).padding(1)
        .background(colors.card, in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .opacity(peek.isPresented == false ? 0.7 : 1)
        .contentShape(Rectangle()).onTapGesture { actions.activate(tab.id) }
        .accessibilityLabel("Show preview: \(peek.title.isEmpty ? NativePageIdentity.label(peek.url) : peek.title)")
        .accessibilityAddTraits(.isButton).accessibilityAction { actions.activate(tab.id) }
    }
  }
  private func tabRow(_ tab: BrowserTab, section: SidebarSection, grouped: Bool = false) -> some View {
    let favorite = section == .favorite
    let selected = highlightedTabIDs.contains(tab.id) && !tab.isClosed
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
      Button { selectSidebarTab(tab) } label: {
        HStack(spacing: 8) {
          if favorite || grouped || !tab.isPinned { tabIcon(tab, size: favorite ? 20 : 16, favorite: favorite) }
          if !favorite {
            if away && !grouped { Text("/").foregroundStyle(colors.muted).padding(.trailing, -5) }
            Text(tab.displayTitle).lineLimit(1)
            Spacer(minLength: 0)
          }
        }.frame(maxWidth: .infinity, minHeight: favorite ? 46 : tabHeight)
          .padding(.leading, grouped ? 6 : !favorite && tab.isPinned ? 2 : 8)
          .padding(.trailing, hovered && !favorite ? 0 : 8)
          .contentShape(Rectangle())
          .background(favorite ? (selected ? favoriteSelection(tab) : hovered ? colors.card.opacity(0.25) : colors.ink.opacity(0.05)) : .clear,
            in: RoundedRectangle(cornerRadius: 10))
          .modifier(NativeSelectionContrast(selected: favorite && selected && drag.id == nil, color: colors.ink, radius: 10))
          .shadow(color: .black.opacity(favorite && drag.id == nil ? (selected ? 0.07 : 0.05) : 0), radius: selected ? 1.5 : 2.5, y: selected ? 1 : 2)
          .overlay(alignment: .topTrailing) { if favorite { peekBadge(tab, favorite: true).padding(2) } }
      }.buttonStyle(NativePressButtonStyle(scale: favorite ? 0.96 : 0.985, motionScale: effectiveMotion))
        .focused($sidebarFocus, equals: tab.id).id(tab.id)
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
      .background(grouped || favorite ? .clear : selected ? selectionBackground(true) : hovered ? colors.ink.opacity(0.05) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
      .modifier(NativeSelectionContrast(selected: selected && !grouped && !favorite && drag.id == nil, color: colors.ink, radius: 10))
      .opacity(drag.id == tab.id ? 0.45 : 1)
      .shadow(color: .black.opacity(selected && !grouped && !favorite && drag.id == nil ? 0.07 : 0), radius: 1.5, y: 1)
      .modifier(NativeTabSelectionPulse(selected: tab.id == store.state.activeTabID && !tab.isClosed,
        enabled: allowsRowMotion, motionScale: effectiveMotion))
      .transition(allowsRowMotion ? .asymmetric(insertion: .modifier(
        active: NativeTabEntry(opacity: 0.3, offset: -3, scale: 0.985),
        identity: NativeTabEntry(opacity: 1, offset: 0, scale: 1)), removal: .identity) : .identity)
      .onHover { if $0 { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil } }
      .help("\(tab.displayTitle) — \(tab.isClosed ? "Closed" : actions.loadedTabIDs.contains(tab.id) ? "Loaded" : "Sleeping")\n\(tab.savedURL ?? tab.url)")
      .accessibilityElement(children: .contain).accessibilityAddTraits(selected ? [.isSelected] : [])
      .contextMenu { tabMenu(tab) }
      .background { menuAnchor(id: tab.id, items: tabMenuItems(tab)) }
      .background { if !grouped { NativeSidebarDragAnchor(controller: drag.native, id: tab.id) } }
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
    if !tab.isClosed {
      items.append(.init(id: "group", title: tab.groupID == nil ? "Group selected tabs" : "Remove from group", glyph: "folder") {
        let ids = highlightedTabIDs.contains(tab.id) ? Array(highlightedTabIDs) : [tab.id]
        do {
          if tab.groupID != nil { try store.ungroupTabs(ids) }
          else { let group = try store.groupTabs(ids); beginRename(.tabGroup(group.id), name: group.title) }
        } catch { operationError = error.localizedDescription; store.clearError() }
      })
    }
    items.append(.init(id: "move", title: "Move to Space or folder", glyph: "folder") { showPalette(.move(tabID: tab.id, pin: false)) })
    items.append(.init(id: "rename", title: "Rename tab…", glyph: "edit") { beginRename(.tab(tab.id), name: tab.displayTitle) })
    if BrowserAddress.webURL(tab.url) != nil {
      items.append(.init(id: "bookmark", title: isBookmarked(tab.url) ? "Remove bookmark" : "Bookmark tab", glyph: "bookmark",
        enabled: actions.libraryCapabilities.contains("bookmark:toggle")) { performTabAction("bookmark:toggle", tab: tab) })
    }
    if tab.isPinned && tab.id != store.state.activeTabID && actions.loadedTabIDs.contains(tab.id) {
      items.append(.init(id: "sleep", title: "Put to sleep", glyph: "moon") { performTabAction("tab:sleep", tab: tab) })
    }
    items.append(.init(id: "close", title: tab.isPinned ? "Close page · keep pin" : "Close tab", glyph: "close", divider: true) { actions.closeTab(tab.id) })
    return items
  }
  private var spaceFooter: some View {
    HStack {
      Menu {
        ForEach(["Bookmarks", "History", "Downloads", "Archive", "Windows", "Settings", "Extensions", "AI"], id: \.self) {
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
        NativeGlyph.menuImage("archivebox")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
        .focused($sidebarFocus, equals: "library").accessibilityLabel("Library")
      spaceDots
      Menu {
        Button("New tab") { actions.openPalette() }
        Button("New folder") { name = ""; creation = "folder" }
        Button("New Space") { openNewSpace() }
        Divider()
        Button("Private session") { actions.runtimeCommands.first(where: { $0.id == "new-private-space" })?.action() }
      } label: {
        NativeGlyph.menuImage("plus")
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
  private var spaceDots: some View {
    GeometryReader { geometry in
      ScrollViewReader { reader in
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            ForEach(spaces) { space in
              Button {
                store.selectSpace(id: space.id)
              } label: {
                NativeGlyph(space.icon).font(.system(size: 14)).opacity(
                  space.id == store.state.activeSpaceID ? 1 : 0.55)
                  .frame(width: 24, height: 28)
                  .background(colors.card.opacity(space.id == store.state.activeSpaceID ? 0.546 : 0), in: RoundedRectangle(cornerRadius: 6))
                  .modifier(NativeSelectionContrast(selected: space.id == store.state.activeSpaceID, color: colors.ink, radius: 6))
              }.buttonStyle(NativePressButtonStyle(scale: 0.96, motionScale: effectiveMotion)).help(space.name).accessibilityLabel("Switch to \(space.name)")
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
                  delegate: SpaceHoverDropDelegate(store: store, drag: drag, target: { space.id })).id(space.id)
            }
          }.frame(minWidth: geometry.size.width)
        }.scrollIndicators(.hidden)
          .onAppear { reader.scrollTo(store.state.activeSpaceID) }
          .onChange(of: store.state.activeSpaceID) { _, id in reader.scrollTo(id) }
          .onChange(of: sidebarFocus) { _, target in
            if let target, target.hasPrefix("space:") { reader.scrollTo(String(target.dropFirst(6))) }
          }
      }
    }.frame(height: 28).accessibilityElement(children: .contain).accessibilityLabel("Your Spaces")
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
    else { store.updateSettings { $0.sidebarVisible.toggle() } }
  }
  private func restoreLibraryFocus() {
    let requested = libraryReturnFocus ?? "library"
    libraryReturnFocus = nil
    guard !actions.palette, !actions.themeEditor, editor == nil,
      creation == nil, renameTarget == nil, !showSiteControls, !showBrowserMenu,
      !showPageActions, !actions.findVisible else { return }
    guard sidebarWidth > 0 else { actions.focusPage(); return }
    let exists = requested == "library" || requested == "address"
      || sidebarKeyboardItems.contains(requested)
      || spaces.contains { "space:\($0.id)" == requested }
    sidebarFocus = exists ? requested : "library"
  }
  private func showPalette(_ request: NativePaletteRequest) {
    actions.openPalette()
    actions.paletteRequest = request
  }
  private func performInterfaceCommand(_ id: String) -> Bool {
    if id.hasPrefix("focus-folder:"), let folder = store.state.folders.first(where: { $0.id == String(id.dropFirst(13)) }),
      store.state.spaces.contains(where: { $0.id == folder.spaceID && $0.profileID == store.activeProfileID }) {
      store.selectSpace(id: folder.spaceID); store.updateFolder(id: folder.id, isExpanded: true)
      store.updateSettings { $0.sidebarVisible = true }
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
      actions.library = nil; store.updateSettings { $0.sidebarVisible = true }; actions.themeEditor = true
    case "site-searches": showPalette(.siteSearches)
    case "focus-sidebar", "reveal-tab":
      store.updateSettings { $0.sidebarVisible = true }
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
    actions.palette = false; actions.library = nil; store.updateSettings { $0.sidebarVisible = true }
    creatingSpace = true; actions.themeEditor = true
  }
  private var sidebarKeyboardItems: [String] {
    var items = tabs.filter { $0.isFavorite && store.split(for: $0.id)?.spaceID != store.state.activeSpaceID }.map(\.id)
    for folder in store.state.folders where folder.spaceID == store.state.activeSpaceID {
      items.append("folder:\(folder.id)")
      if folder.isExpanded { items += tabs.filter { $0.folderID == folder.id && !$0.isFavorite && store.split(for: $0.id) == nil }.map(\.id) }
    }
    items += tabs.filter { $0.isPinned && !$0.isFavorite && $0.folderID == nil && store.split(for: $0.id) == nil }.map(\.id)
    for group in visibleTabGroups {
      items.append("group:\(group.id)")
      if !group.collapsed { items += tabs.filter { $0.groupID == group.id && !$0.isClosed }.map(\.id) }
    }
    items += store.state.splits.filter { $0.spaceID == store.state.activeSpaceID && store.tab($0.leftTabID)?.groupID == nil }.flatMap(\.tabIDs)
    items += tabs.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil && $0.groupID == nil && ($0.url != "about:blank" || $0.homePage == true) && store.split(for: $0.id) == nil }.map(\.id)
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
      let groupID = current.hasPrefix("group:") ? String(current.dropFirst(6)) : store.tab(current)?.groupID
      if let groupID, let group = store.state.tabGroups.first(where: { $0.id == groupID }) {
        if key.key == .leftArrow && current != "group:\(groupID)" { sidebarFocus = "group:\(groupID)" }
        else if key.key == .leftArrow { updateGroup(group, collapsed: true) }
        else if group.collapsed { updateGroup(group, collapsed: false) }
        else { sidebarFocus = items[min(items.count - 1, index + 1)] }
        return .handled
      }
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
        editor == nil, actions.library == nil, !actions.themeEditor, !actions.palette,
        !showBrowserMenu, !showPageActions, !showSiteControls,
        creation == nil, renameTarget == nil, drag.id == nil,
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
      if case .tabGroup(let id) = target {
        try store.updateTabGroup(id, title: value)
        renameTarget = nil; nameError = nil; return
      }
      if case .tab(let id) = target, store.tab(id) == nil { throw ShortcutError("This tab is no longer in this window.") }
      try store.commit { state in
        switch target {
        case .tab(let id):
          if let index = state.tabs.firstIndex(where: { $0.id == id }) { state.tabs[index].customTitle = value }
        case .tabGroup: break
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
        store.tab(id) != nil || id.hasPrefix("space:") || id.hasPrefix("folder:") || id.hasPrefix("group:") { sidebarFocus = id }
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
    case .tab, .tabGroup: return
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
    case .tab, .tabGroup: break
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
  case tabGroup(String)
  case folder(String)
  case space(String)
  case profile(String)
  var kind: String {
    switch self {
    case .tab: "Tab"
    case .tabGroup: "Tab group"
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
  let native = NativeSidebarDragController()
  @Published var id: String?
  @Published var preview: [BrowserTab]?
  private var hover: DispatchWorkItem?
  private var projectedGroupID: String?
  private var projection: Projection?
  private struct Projection {
    let space: String
    let section: SidebarSection
    let before: String?
    let after: Bool
  }
  func start(_ id: String, tabs: [BrowserTab]) {
    cancel()
    self.id = id
    preview = tabs
    projectedGroupID = tabs.first(where: { $0.id == id })?.groupID
  }
  func cancel() {
    hover?.cancel()
    hover = nil
    id = nil
    preview = nil
    projectedGroupID = nil
    projection = nil
  }
  func resetReflow(store: BrowserStore) {
    guard id != nil else { return }
    projection = nil
    reconcile(store: store)
  }
  func reconcile(store: BrowserStore) {
    guard let id else { return }
    guard let source = store.tab(id), store.profileID(for: source) == store.activeProfileID else {
      cancel(); return
    }
    if let projection {
      project(store: store, space: projection.space, section: projection.section,
        before: projection.before, after: projection.after)
    } else {
      projectedGroupID = source.groupID
      preview = store.state.tabs
    }
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
    // Reflow is only a presentation of the latest model. A page can finish
    // loading, open another tab, or close while a native drag is in progress.
    // Reusing the previous projection would hide those changes until drop.
    projection = Projection(space: space, section: section, before: before, after: after)
    var projected = store.state.tabs
    guard let index = projected.firstIndex(where: { $0.id == id }) else { return }
    var moved = projected.remove(at: index)
    projectedGroupID = before.flatMap { store.tab($0)?.groupID }
    if section != .regular || projectedGroupID != source.groupID { moved.groupID = nil }
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
    let duration = 0.14 * store.state.settings.motionScale
    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: duration)) {
      preview = projected
    }
  }
  func commit(store: BrowserStore, space: String, section: SidebarSection? = nil) -> Bool {
    guard let id, let source = store.tab(id),
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else { cancel(); return false }
    let index = section == nil ? nil : preview?.firstIndex(where: { $0.id == id })
    store.moveTab(id: id, spaceID: space, folderID: section?.folderID, index: index,
      pinned: section?.pinned, favorite: section.map { $0 == .favorite }, clearFolder: section != nil,
      clearGroup: section == .regular && source.groupID != nil && projectedGroupID != source.groupID)
    cancel(); return true
  }

}
private struct NativeTabEntry: ViewModifier {
  let opacity: Double
  let offset: CGFloat
  let scale: CGFloat
  func body(content: Content) -> some View {
    content.opacity(opacity).offset(y: offset).scaleEffect(scale)
  }
}

/// Selection feedback belongs to the row, not its Chromium document. Each
/// newer selection or disabled-motion state cancels the previous pending pulse.
private struct NativeTabSelectionPulse: ViewModifier {
  let selected: Bool
  let enabled: Bool
  let motionScale: Double
  @State private var opacity = 1.0
  @State private var generation = 0
  func body(content: Content) -> some View {
    content.opacity(opacity)
      .onChange(of: selected) { _, value in
        generation &+= 1
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) { opacity = value && enabled ? 0.7 : 1 }
      }
      .onChange(of: enabled) { _, value in
        if !value {
          generation &+= 1
          var transaction = Transaction(); transaction.animation = nil
          withTransaction(transaction) { opacity = 1 }
        }
      }
      .task(id: generation) {
        guard generation != 0, selected, enabled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.11 * motionScale)) { opacity = 1 }
      }
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
      panel.identifier = NSUserInterfaceItemIdentifier("ZacroBrowserControls")
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
      NativeFindField(text: $actions.findQuery, focusRequest: actions.findSession, ink: NSColor(colors.ink), muted: NSColor(colors.muted), changed: actions.updateFind,
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
  let focusRequest: UInt64
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
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.textColor = ink
    field.placeholderAttributedString = NSAttributedString(string: "Find on page", attributes: [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 12)])
    if field.stringValue != text { field.stringValue = text }
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async { [weak field] in
        guard let field, let window = field.window, window.isVisible else { return }
        window.makeFirstResponder(field); field.selectText(nil)
      }
    }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NativeFindField
    var lastFocusRequest: UInt64?
    init(_ parent: NativeFindField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue; parent.changed(field.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      if selector == #selector(NSResponder.cancelOperation(_:)) { parent.close(); return true }
      if selector == #selector(NSResponder.insertNewline(_:)) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { parent.previous() } else { parent.next() }
        return true
      }
      return false
    }
  }
}
