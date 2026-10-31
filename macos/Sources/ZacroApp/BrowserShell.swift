import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import ZacroCore

@MainActor
final class BrowserActions: ObservableObject {
  @Published var palette = false
  @Published private(set) var paletteEditsAddress = false
  @Published var query = ""
  @Published var library: String?
  @Published var themeEditor = false
  @Published var siteControls = SiteControlActions()
  @Published var canGoBack = false
  @Published var canGoForward = false
  @Published var loading = false
  @Published var icons: [String: NSImage] = [:]
  @Published var iconColors: [String: Color] = [:]
  @Published var nativePageVisible = false
  @Published var contentFrame = CGRect.zero
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
    paletteEditsAddress = !address.isEmpty
    query = address
    palette = true
  }
  func submit(_ value: String) {
    palette = false
    if paletteEditsAddress { navigate(value) } else { newTab(value) }
  }
}

struct BrowserShell<Content: View>: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  @ViewBuilder var content: () -> Content
  @StateObject private var drag = SidebarDragSession()
  @State private var gestureProgress: Double = 0
  @State private var name = ""
  @State private var creation: String?
  @State private var renameTarget: SidebarNamedItem?
  @State private var showSiteControls = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var paletteSelection = 0
  @State private var themeSaveTask: Task<Void, Never>?
  private var theme: SpaceTheme { store.state.activeSpace?.theme ?? SpaceTheme() }
  private var effectiveMotion: Double { reduceMotion ? 0 : store.state.settings.motionScale }
  private var accent: Color { Color(nsColor: NSColor(hex: theme.primaryColor)) }
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
    store.state.activeTab.map { !$0.isClosed && $0.url != "about:blank" } ?? false
  }
  private var sidebarWidth: Double {
    store.state.settings.sidebarVisible ? store.state.settings.sidebarWidth : 0
  }
  private var libraryBinding: Binding<LibrarySheet?> {
    Binding(
      get: { actions.library.map { LibrarySheet(id: $0) } }, set: { actions.library = $0?.id })
  }
  private var themeBinding: Binding<SpaceTheme> {
    Binding(
      get: { theme },
      set: { updated in
        guard
          let index = store.state.spaces.firstIndex(where: { $0.id == store.state.activeSpaceID })
        else { return }
        store.state.spaces[index].theme = updated
        themeSaveTask?.cancel()
        themeSaveTask = Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(180))
          if !Task.isCancelled { store.save() }
        }
      })
  }

  var body: some View {
    ZStack {
      NativeThemeBackground(theme: theme)
        .mask(
          WindowMaterialMask(
            hole: (hasPage || actions.nativePageVisible) ? actions.contentFrame : .zero,
            radius: store.state.settings.pageRadius
          ).fill(style: FillStyle(eoFill: true)))
      HStack(spacing: 0) {
        if store.state.settings.sidebarVisible {
          sidebar.frame(width: sidebarWidth)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        pageArea
      }

    }
    .background {
      NativePalettePresenter(
        isPresented: $actions.palette,
        content: AnyView(
          palette.tint(accent)
            .preferredColorScheme(
              theme.appearance == "dark" ? .dark : theme.appearance == "light" ? .light : nil)),
        motionScale: effectiveMotion
      )
      .frame(width: 0, height: 0).allowsHitTesting(false)
    }
    .coordinateSpace(name: "browserWindow")
    .tint(accent)
    .preferredColorScheme(
      theme.appearance == "dark" ? .dark : theme.appearance == "light" ? .light : nil
    )
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 0.18 * effectiveMotion),
      value: store.state.settings.sidebarVisible
    )
    .onPreferenceChange(ContentFramePreference.self) { frame in
      guard frame != actions.contentFrame else { return }
      actions.contentFrame = frame
      actions.onLayout(frame, sidebarWidth)
    }
    .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
      if drag.id != nil && NSEvent.pressedMouseButtons == 0 { drag.cancel() }
    }
    .sheet(
      isPresented: $actions.themeEditor,
      onDismiss: {
        themeSaveTask?.cancel()
        store.save()
      }
    ) { ThemeEditor(theme: themeBinding) }
    .sheet(item: libraryBinding) { NativeLibrary(store: store, actions: actions, section: $0.id) }
    .alert(
      renameTarget.map { "Rename \($0.kind)" } ?? "New \(creation ?? "item")",
      isPresented: Binding(
        get: { creation != nil || renameTarget != nil },
        set: {
          if !$0 {
            creation = nil
            renameTarget = nil
          }
        })
    ) {
      TextField("Name", text: $name)
      Button(renameTarget == nil ? "Create" : "Save") { saveName() }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Cancel", role: .cancel) {
        creation = nil
        renameTarget = nil
      }
    }
  }

  private var pageArea: some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: ContentFramePreference.self, value: geometry.frame(in: .named("browserWindow")))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: store.state.settings.pageRadius))
      .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
      .padding(store.state.settings.pageGutter)
      .overlay(alignment: .topLeading) {
        if !store.state.settings.sidebarVisible { revealButton }
      }
  }
  private var revealButton: some View {
    Button {
      toggleSidebar()
    } label: {
      Image(systemName: "sidebar.left").frame(width: 32, height: 32)
    }
    .buttonStyle(.plain).background { NativeControlSurface().clipShape(Circle()) }
    .padding(12).help("Show sidebar").accessibilityLabel("Show sidebar")
  }
  private var sidebar: some View {
    VStack(spacing: 12) {
      navigation
      addressButton
      SpaceGestureSurface(
        index: spaces.firstIndex(where: { $0.id == store.state.activeSpaceID }) ?? 0,
        count: spaces.count, onProgress: { gestureProgress = $0 },
        onSelect: { index in
          if spaces.indices.contains(index) { store.selectSpace(id: spaces[index].id) }
        }
      ) {
        ScrollView {
          tabList.padding(2)
            .offset(x: reduceMotion ? 0 : -gestureProgress * 24)
            .opacity(reduceMotion ? 1 : 1 - min(0.35, abs(gestureProgress) * 0.2))
        }.scrollIndicators(.hidden)
      }
      spaceFooter
    }.padding(.horizontal, 10)
      .overlay(alignment: .leading) { spaceEdge(-1) }
      .overlay(alignment: .trailing) { spaceEdge(1) }
  }
  private var navigation: some View {
    HStack(spacing: 12) {
      Spacer().frame(width: 60)
      Button {
        toggleSidebar()
      } label: {
        Image(systemName: "sidebar.left")
      }.help("Hide sidebar")
      Spacer(minLength: 0)
      Button(action: actions.back) { Image(systemName: "arrow.left") }.disabled(!actions.canGoBack)
        .help("Back")
      Button(action: actions.forward) { Image(systemName: "arrow.right") }.disabled(
        !actions.canGoForward
      ).help("Forward")
      Button(action: actions.reload) {
        Image(systemName: actions.loading ? "xmark" : "arrow.clockwise")
      }.help(actions.loading ? "Stop" : "Reload")
    }.buttonStyle(.plain).padding(.top, 12)
  }
  private var addressButton: some View {
    HStack(spacing: 2) {
      Button {
        actions.openPalette(address: store.state.activeTab?.url ?? "")
      } label: {
        Text(store.state.activeTab.flatMap { URL(string: $0.url)?.host } ?? "Search or enter URL")
          .lineLimit(1).font(.system(size: 12, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10).padding(
            .vertical, 10
          )
          .contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Edit address or search")
      Button {
        showSiteControls.toggle()
      } label: {
        Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
          .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 8))
      }.buttonStyle(.plain).padding(.trailing, 4)
        .help("Site controls").accessibilityLabel("Site controls")
        .popover(isPresented: $showSiteControls, arrowEdge: .bottom) {
          SiteControls(actions: actions.siteControls, accent: accent)
        }
    }.background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
  }
  private var tabList: some View {
    VStack(alignment: .leading, spacing: 5) {
      favoriteGrid
      HStack {
        Image(systemName: store.state.activeSpace?.icon ?? "circle.fill")
        Text(store.state.activeSpace?.name ?? "Personal").fontWeight(.semibold)
      }.font(.system(size: 12)).foregroundStyle(accent).padding(.vertical, 8)
        .contextMenu {
          if let space = store.state.activeSpace { spaceMenu(space) }
        }
      ForEach(store.state.folders.filter { $0.spaceID == store.state.activeSpaceID }) { folder in
        DisclosureGroup(
          isExpanded: Binding(
            get: { store.state.folders.first(where: { $0.id == folder.id })?.isExpanded ?? true },
            set: { store.updateFolder(id: folder.id, isExpanded: $0) })
        ) {
          rows(
            tabs.filter { $0.folderID == folder.id && !$0.isFavorite }, section: .folder(folder.id))
        } label: {
          Label(folder.name, systemImage: "folder").foregroundStyle(accent)
        }
        .padding(8)
        .contextMenu {
          Button("Rename folder…") { beginRename(.folder(folder.id), name: folder.name) }
          Button("Delete folder…", role: .destructive) {
            confirmDelete(.folder(folder.id), name: folder.name)
          }
        }
        .onDrop(of: [.plainText], delegate: dropDelegate(section: .folder(folder.id)))
      }
      VStack(spacing: 5) {
        rows(tabs.filter { $0.isPinned && !$0.isFavorite && $0.folderID == nil }, section: .pinned)
        Color.clear.frame(height: drag.id == nil ? 0 : 14)
      }.contentShape(Rectangle()).onDrop(of: [.plainText], delegate: dropDelegate(section: .pinned))
      Divider().padding(.vertical, 10)
      Button {
        actions.openPalette()
      } label: {
        Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .buttonStyle(.plain).foregroundStyle(.secondary)
      VStack(spacing: 5) {
        rows(
          tabs.filter { !$0.isPinned && !$0.isFavorite && !$0.isClosed && $0.folderID == nil },
          section: .regular)
        Color.clear.frame(height: 28)
      }.contentShape(Rectangle()).onDrop(
        of: [.plainText], delegate: dropDelegate(section: .regular))
    }
  }
  private var favoriteGrid: some View {
    let favorites = tabs.filter(\.isFavorite)
    let columns = max(2, min(4, favorites.count))
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: columns), spacing: 7
    ) {
      ForEach(
        favorites.filter { tab in store.split(for: tab.id).map { $0.leftTabID == tab.id } ?? true }
      ) { tab in
        if let group = store.split(for: tab.id),
          let partner = tabs.first(where: { $0.id == group.rightTabID })
        {
          HStack(spacing: 0) {
            tabRow(tab, section: .favorite, grouped: true)
            Divider().frame(height: 20)
            tabRow(partner, section: .favorite, grouped: true)
          }.background(
            selectionBackground(group.tabIDs.contains(store.state.activeTabID ?? "")),
            in: RoundedRectangle(cornerRadius: 11))
        } else {
          tabRow(tab, section: .favorite)
        }
      }
      if favorites.isEmpty && drag.id != nil {
        Color.clear.frame(height: 45).gridCellColumns(columns)
      }
    }.padding(.bottom, 8).contentShape(Rectangle())
      .onDrop(of: [.plainText], delegate: dropDelegate(section: .favorite))
  }
  private func rows(_ candidates: [BrowserTab], section: SidebarSection) -> some View {
    ForEach(
      candidates.filter { tab in
        guard let group = store.split(for: tab.id) else { return true }
        return group.leftTabID == tab.id
      }
    ) { tab in
      if let group = store.split(for: tab.id),
        let left = tabs.first(where: { $0.id == group.leftTabID }),
        let right = tabs.first(where: { $0.id == group.rightTabID })
      {
        HStack(spacing: 0) {
          tabRow(left, section: section, grouped: true)
          Divider().frame(height: 20)
          tabRow(right, section: section, grouped: true)
        }.background(
          selectionBackground(group.tabIDs.contains(store.state.activeTabID ?? "")),
          in: RoundedRectangle(cornerRadius: 11))
      } else {
        tabRow(tab, section: section)
      }
    }
  }
  private func selectionBackground(_ selected: Bool) -> Color {
    Color.primary.opacity(selected ? 0.085 : 0)
  }
  private func tabRow(_ tab: BrowserTab, section: SidebarSection, grouped: Bool = false)
    -> some View
  {
    let favorite = section == .favorite
    return Button {
      store.selectTab(id: tab.id)
      actions.activate(tab.id)
    } label: {
      HStack(spacing: 8) {
        Group {
          if let icon = actions.icons[tab.id] {
            Image(nsImage: icon).resizable().scaledToFit()
          } else {
            Image(systemName: "globe")
          }
        }.frame(width: 18, height: 18)
          .overlay(alignment: .topTrailing) {
            if tab.peek != nil {
              Image(systemName: "rectangle.on.rectangle").font(.system(size: 9)).padding(2)
                .background(.regularMaterial, in: Circle()).offset(x: 5, y: -5)
            }
          }
        if !favorite {
          Text(tab.displayTitle).lineLimit(1)
          Spacer(minLength: 0)
        }
      }.font(.system(size: 13, weight: tab.id == store.state.activeTabID ? .medium : .regular))
        .frame(maxWidth: .infinity, minHeight: favorite ? 45 : 32)
        .padding(.horizontal, 8)
        .background(
          grouped
            ? .clear
            : tab.id == store.state.activeTabID
              ? (favorite
                ? (actions.iconColors[tab.id] ?? accent).opacity(0.22) : selectionBackground(true))
              : favorite ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 11)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }.buttonStyle(.plain).help(tab.displayTitle)
      .contextMenu {
        Button("Rename tab…") { beginRename(.tab(tab.id), name: tab.displayTitle) }
        Button(isBookmarked(tab.url) ? "Remove bookmark" : "Bookmark tab") {
          store.toggleBookmark(url: tab.url, title: tab.displayTitle)
        }
        Divider()
        Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
          store.toggleFavorite(id: tab.id)
        }
        Button(tab.isPinned ? "Unpin" : "Pin") { store.togglePin(id: tab.id) }
        if let current = store.state.activeTabID, current != tab.id {
          Button("Split with active tab") { store.setSplit(left: current, right: tab.id) }
        }
        if store.split(for: tab.id) != nil { Button("Unsplit") { store.unsplit(tabID: tab.id) } }
        Button("Close tab") { actions.closeTab(tab.id) }
      }
      .onDrag {
        drag.start(tab.id, tabs: store.state.tabs)
        return NSItemProvider(object: tab.id as NSString)
      }
      .onDrop(of: [.plainText], delegate: dropDelegate(section: section, before: tab.id))
  }
  private var spaceFooter: some View {
    HStack {
      Menu {
        ForEach(["Bookmarks", "History", "Downloads", "Archive", "Settings"], id: \.self) {
          section in Button(section) { actions.library = section }
        }
        Button("Extensions", action: actions.openExtensions)
        Button("Chrome Web Store", action: actions.openExtensionStore)
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
        Image(systemName: "archivebox")
      }.menuStyle(.borderlessButton).frame(width: 24)
      Spacer(minLength: 4)
      ForEach(spaces) { space in
        Button {
          store.selectSpace(id: space.id)
        } label: {
          Image(systemName: space.icon).font(.system(size: 12)).opacity(
            space.id == store.state.activeSpaceID ? 1 : 0.4)
        }.buttonStyle(.plain).help(space.name).accessibilityLabel("Switch to \(space.name)")
          .accessibilityAddTraits(space.id == store.state.activeSpaceID ? [.isSelected] : [])
          .padding(3).contextMenu { spaceMenu(space) }
          .onDrop(
            of: [.plainText],
            delegate: SpaceHoverDropDelegate(store: store, drag: drag, target: { space.id }))
      }
      Spacer(minLength: 4)
      Button {
        name = ""
        creation = "Space"
      } label: {
        Image(systemName: "plus")
      }.buttonStyle(.plain)
    }.foregroundStyle(accent).padding(.bottom, 10)
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

  private var paletteResults: [PaletteResult] {
    var result = [PaletteResult]()
    let query = actions.query.trimmingCharacters(in: .whitespacesAndNewlines)
    func matches(_ values: String...) -> Bool {
      query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    let profileTabs = store.state.tabs.filter { store.profileID(for: $0) == store.activeProfileID }
    let commandNames = [
      "Unsplit", "Customize Space", "Bookmark Tab", "Bookmarks", "History", "Downloads", "Archive",
      "Settings", "Extensions", "Extension Store",
    ].filter { command in
      if command == "Bookmark Tab" {
        return store.state.activeTab.map { BrowserAddress.webURL($0.url) != nil } ?? false
      }
      if command == "Unsplit" {
        return store.state.activeTabID.flatMap { store.split(for: $0) } != nil
      }
      return true
    }
    let exactCommand = commandNames.first { $0.caseInsensitiveCompare(query) == .orderedSame }
    func commandResult(_ command: String) -> PaletteResult {
      PaletteResult(
        id: "command:\(command)", title: command,
        icon: command == "Bookmark Tab" ? "bookmark" : "command", detail: "Action"
      ) {
        actions.palette = false
        if command == "Unsplit" {
          if let id = store.state.activeTabID { store.unsplit(tabID: id) }
        } else if command == "Customize Space" {
          actions.themeEditor = true
        } else if command == "Bookmark Tab" {
          if let tab = store.state.activeTab {
            store.toggleBookmark(url: tab.url, title: tab.displayTitle)
          }
        } else if command == "Extensions" {
          actions.openExtensions()
        } else if command == "Extension Store" {
          actions.openExtensionStore()
        } else {
          actions.library = command
        }
      }
    }
    if let exactCommand { result.append(commandResult(exactCommand)) }
    if !query.isEmpty {
      let address = BrowserAddress.resolve(query, engine: store.state.settings.searchEngine)
      let isAddress =
        !query.contains(where: \.isWhitespace)
        && (query.contains("://") || query.contains(".") || query.hasPrefix("localhost"))
      let title =
        isAddress
        ? "Open \(query)"
        : "Search \(store.state.settings.searchEngine.rawValue.capitalized) for “\(query)”"
      if address != nil {
        result.append(
          PaletteResult(
            id: "search:web", title: title, icon: isAddress ? "arrow.up.right" : "magnifyingglass"
          ) { actions.submit(query) })
      }
      if let host = store.state.activeTab.flatMap({ URL(string: $0.url)?.host }) {
        result.append(
          PaletteResult(id: "search:site", title: "Search \(host)", icon: "globe", detail: query) {
            actions.submit("site:\(host) \(query)")
          })
      }
    }
    var representedURLs = Set<String>()
    for tab in profileTabs.filter({ matches($0.displayTitle, $0.url) }).prefix(6) {
      representedURLs.insert(tab.url)
      let owner = store.state.spaces.first { $0.id == tab.spaceID }?.name ?? "Tab"
      result.append(
        PaletteResult(
          id: "tab:\(tab.id)", title: tab.displayTitle,
          icon: tab.isFavorite ? "star" : tab.isPinned ? "pin" : "globe", detail: owner
        ) {
          store.selectTab(id: tab.id)
          actions.activate(tab.id)
          actions.palette = false
        })
    }
    if !query.isEmpty {
      for space in spaces.filter({ matches($0.name) }).prefix(4) {
        result.append(
          PaletteResult(
            id: "space:\(space.id)", title: space.name, icon: space.icon, detail: "Space"
          ) {
            store.selectSpace(id: space.id)
            actions.palette = false
            if let id = store.state.activeTabID { actions.activate(id) }
          })
      }
      for bookmark in store.state.bookmarks.filter({
        $0.profileID == store.activeProfileID && matches($0.title, $0.url)
      }).prefix(4) {
        representedURLs.insert(bookmark.url)
        result.append(
          PaletteResult(
            id: "bookmark:\(bookmark.id)",
            title: bookmark.title.isEmpty ? bookmark.url : bookmark.title, icon: "bookmark",
            detail: bookmark.url
          ) { actions.submit(bookmark.url) })
      }
      var historyCount = 0
      for visit in store.state.history
      where visit.profileID == store.activeProfileID && matches(visit.title, visit.url)
        && !representedURLs.contains(visit.url)
      {
        representedURLs.insert(visit.url)
        result.append(
          PaletteResult(
            id: "history:\(visit.id)", title: visit.title.isEmpty ? visit.url : visit.title,
            icon: "clock", detail: visit.url
          ) { actions.submit(visit.url) })
        historyCount += 1
        if historyCount == 4 { break }
      }
    }
    for command in commandNames where command != exactCommand && matches(command) {
      if command == "Bookmark Tab" && store.state.activeTab == nil { continue }
      if command == "Unsplit" && store.state.activeTabID.flatMap({ store.split(for: $0) }) == nil {
        continue
      }
      result.append(commandResult(command))
    }
    return result
  }
  private var palette: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { actions.palette = false }
      VStack(spacing: 5) {
        PaletteSearchField(
          text: $actions.query, submit: activatePaletteSelection, move: movePaletteSelection,
          cancel: { actions.palette = false }
        )
        .frame(height: 40).padding(.horizontal, 10)
        Divider()
        paletteResultList
      }.padding(12).frame(width: 560)
        .background { NativeControlSurface().clipShape(RoundedRectangle(cornerRadius: 12)) }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8).padding(.top, 70)
    }.onAppear { paletteSelection = 0 }.onChange(of: actions.query) { _, _ in paletteSelection = 0 }
      .onChange(of: paletteResults.map(\.id)) { _, values in
        paletteSelection = min(paletteSelection, max(0, values.count - 1))
      }
  }
  private var paletteResultList: some View {
    ScrollViewReader { reader in
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(Array(paletteResults.enumerated()), id: \.element.id) { index, item in
            Button(action: item.action) {
              HStack(spacing: 10) {
                Image(systemName: item.icon).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).lineLimit(1)
                  if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 0)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(
                  selectionBackground(index == paletteSelection),
                  in: RoundedRectangle(cornerRadius: 11)
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { if $0 { paletteSelection = index } }
              .accessibilityLabel(item.title + (item.detail.map { ", " + $0 } ?? ""))
              .accessibilityAddTraits(index == paletteSelection ? [.isSelected] : [])
              .id(item.id)
          }
        }
      }.scrollIndicators(.hidden)
        .frame(maxHeight: min(420, max(120, actions.contentFrame.height - 180)))
        .onChange(of: paletteSelection) { _, index in
          let items = paletteResults
          guard items.indices.contains(index) else { return }
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
            reader.scrollTo(items[index].id, anchor: .center)
          }
        }
    }
  }
  private func movePaletteSelection(_ offset: Int) {
    guard !paletteResults.isEmpty else { return }
    paletteSelection = min(paletteResults.count - 1, max(0, paletteSelection + offset))
  }
  private func activatePaletteSelection() {
    let results = paletteResults
    guard results.indices.contains(paletteSelection) else { return }
    results[paletteSelection].action()
  }
  private func toggleSidebar() {
    store.state.settings.sidebarVisible.toggle()
    store.save()
  }
  private func beginRename(_ target: SidebarNamedItem, name: String) {
    creation = nil
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
    switch target {
    case .tab(let id): store.updateTab(id) { $0.customTitle = value }
    case .folder(let id): store.updateFolder(id: id, name: value)
    case .space(let id): store.updateSpace(id) { $0.name = value }
    case .profile(let id):
      if let index = store.state.profiles.firstIndex(where: { $0.id == id }) {
        store.state.profiles[index].name = value
        store.save()
      }
    }
    renameTarget = nil
  }
  private func canDeleteProfile(_ id: String) -> Bool {
    store.state.profiles.contains { !$0.isPrivate && $0.id != id }
  }
  private func canDeleteSpace(_ space: BrowserSpace) -> Bool {
    store.state.spaces.filter { $0.profileID == space.profileID }.count > 1
  }
  @ViewBuilder private func spaceMenu(_ space: BrowserSpace) -> some View {
    Button("Customize Space") {
      store.selectSpace(id: space.id)
      actions.themeEditor = true
    }
    Button("Rename Space…") { beginRename(.space(space.id), name: space.name) }
    Button("Delete Space…", role: .destructive) {
      confirmDelete(.space(space.id), name: space.name)
    }.disabled(!canDeleteSpace(space))
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
      let count = store.state.tabs.filter { $0.spaceID == id }.count
      alert.informativeText =
        "This removes the Space, its folders, and \(count) saved or open tabs."
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
    let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    guard !trimmed.isEmpty else { return }
    if creation == "Space" {
      _ = store.createSpace(name: trimmed)
    } else if creation == "profile" {
      _ = store.createProfile(name: trimmed)
    } else {
      _ = store.createFolder(name: trimmed)
    }
    creation = nil
  }
}

private struct ContentFramePreference: PreferenceKey {
  static var defaultValue = CGRect.zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
private enum SidebarNamedItem {
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
private struct LibrarySheet: Identifiable { let id: String }
private struct PaletteResult: Identifiable {
  let id: String
  let title: String
  let icon: String
  let detail: String?
  let action: () -> Void
  init(id: String, title: String, icon: String, detail: String? = nil, action: @escaping () -> Void)
  {
    self.id = id
    self.title = title
    self.icon = icon
    self.detail = detail
    self.action = action
  }
}
private struct PaletteSearchField: NSViewRepresentable {
  @Binding var text: String
  var submit: () -> Void
  var move: (Int) -> Void
  var cancel: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.focusRingType = .none
    field.placeholderString = "Search or enter URL"
    field.setAccessibilityLabel("Search tabs, Spaces, bookmarks, history, or the web")
    field.isBordered = false
    field.drawsBackground = false
    field.font = .systemFont(ofSize: 20)
    field.delegate = context.coordinator
    DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: PaletteSearchField
    init(_ parent: PaletteSearchField) { self.parent = parent }
    func controlTextDidChange(_ obj: Notification) {
      if let field = obj.object as? NSTextField { parent.text = field.stringValue }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      switch selector {
      case #selector(NSResponder.moveUp(_:)): parent.move(-1)
      case #selector(NSResponder.moveDown(_:)): parent.move(1)
      case #selector(NSResponder.insertNewline(_:)): parent.submit()
      case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
      default: return false
      }
      return true
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
  }
  func project(store: BrowserStore, space: String, section: SidebarSection, before: String?) {
    guard let id, let source = store.tab(id),
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else { return }
    var tabs = preview ?? store.state.tabs
    let members = store.split(for: id)?.tabIDs ?? [id]
    for member in members {
      guard let index = tabs.firstIndex(where: { $0.id == member }) else { continue }
      tabs[index].spaceID = space
      tabs[index].folderID = section.folderID
      tabs[index].isFavorite = section == .favorite
      tabs[index].isPinned = section.pinned
    }
    if let before, before != id, let from = tabs.firstIndex(where: { $0.id == id }) {
      let moved = tabs.remove(at: from)
      let destination = tabs.firstIndex(where: { $0.id == before }) ?? tabs.count
      tabs.insert(moved, at: destination)
    }
    withAnimation(
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.15)
    ) { preview = tabs }
  }
  func commit(store: BrowserStore, space: String, section: SidebarSection? = nil) -> Bool {
    guard let id, let source = store.tab(id),
      store.state.spaces.first(where: { $0.id == space })?.profileID == store.profileID(for: source)
    else {
      cancel()
      return false
    }
    let members = store.split(for: id)?.tabIDs ?? [id]
    let index = preview?.firstIndex(where: { $0.id == id })
    store.moveTab(id: id, spaceID: space, folderID: section?.folderID, index: index)
    if let section {
      for member in members {
        store.updateTab(member) { tab in
          tab.isFavorite = section == .favorite
          tab.isPinned = section.pinned
          tab.savedURL = section.pinned ? (tab.savedURL ?? tab.url) : nil
          if section == .regular { tab.isClosed = false }
        }
      }
    }
    cancel()
    return true
  }
}
private struct SidebarDropDelegate: DropDelegate {
  let store: BrowserStore
  let drag: SidebarDragSession
  let section: SidebarSection
  let spaceID: String
  var before: String?
  func validateDrop(info: DropInfo) -> Bool { drag.id != nil }
  func dropEntered(info: DropInfo) {
    drag.stopHover()
    drag.project(store: store, space: spaceID, section: section, before: before)
  }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    drag.commit(store: store, space: spaceID, section: section)
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
    init(_ presenter: NativePalettePresenter) { self.presenter = presenter }

    func attach(to window: NSWindow?) {
      if parent !== window {
        hide()
        parent = window
      }
      guard presenter.isPresented, let parent else {
        hide()
        return
      }
      if let hosting {
        hosting.rootView = presenter.content
        resize()
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
      panel.setAccessibilityLabel("Command palette")
      let hosting = NSHostingView(rootView: presenter.content)
      hosting.autoresizingMask = [.width, .height]
      panel.contentView = hosting
      self.hosting = hosting
      self.panel = panel
      parent.addChildWindow(panel, ordered: .above)
      panel.alphaValue = presenter.motionScale > 0 ? 0 : 1
      panel.makeKeyAndOrderFront(nil)
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
        ) { [weak self] _ in Task { @MainActor in self?.dismiss() } })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.dismiss() } })
      mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, let parent = self.parent, let clicked = event.window,
          clicked !== self.panel
        else { return event }
        // Never inspect or consume mouse events from another app/window tree.
        var candidate: NSWindow? = clicked
        while let window = candidate {
          if window === parent {
            self.dismiss()
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
      return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
    private func resize() {
      guard let parent, let panel else { return }
      panel.setFrame(contentRect(parent), display: true)
    }
    private func dismiss() {
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
      let restoreKey = NSApp.keyWindow === panel
      parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      panel.contentView = nil
      hosting = nil
      self.panel = nil
      if restoreKey, parent?.isVisible == true { parent?.makeKey() }
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
