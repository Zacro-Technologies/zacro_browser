import AppKit
import SwiftUI
import ZacroCore

enum NativePaletteRequest: Equatable {
  case move(tabID: String, pin: Bool)
  case result(kind: String, id: String, title: String, url: String)
  case split
  case siteSearches
}

struct NativeCommandPalette: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  @State private var selection = 0
  @State private var selectedID: String?
  @State private var restoredQuery: String?
  @State private var focusRequest = 0
  @State private var scope = "all"
  @State private var context: NativePaletteRequest?
  @State private var site: SiteSearchEngine?
  @State private var trail: [PaletteStep] = []
  @State private var editingSearch: SiteSearchEngine?
  @State private var searchName = ""
  @State private var searchKeyword = ""
  @State private var searchURL = ""
  @State private var error: String?
  @State private var entered = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.presentedSpaceTheme) private var presentedTheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var colors: NativeSpacePalette {
    let theme = presentedTheme ?? store.state.activeSpace?.theme ?? SpaceTheme()
    return NativeSpacePalette(theme: theme, dark: colorScheme == .dark, increasedContrast: contrast == .increased)
  }
  private let scopes = [("all", "All"), ("tab", "Tabs"), ("space", "Spaces"), ("folder", "Folders"), ("bookmark", "Bookmarks"), ("history", "History"), ("action", "Actions")]
  private var raw: String { NativeCommandSearchMatching.trimmedQuery(actions.query) }
  private var prefix: String? { [">": "action", "/": "action", "@": "tab", "#": "space"][String(raw.prefix(1))] }
  private var query: String { NativeCommandSearchMatching.trimmedQuery(prefix == nil ? raw : String(raw.dropFirst())) }
  private var filter: String { prefix ?? scope }
  private var isNested: Bool { context != nil || site != nil }
  private var profileTabs: [BrowserTab] {
    store.state.tabs.filter { store.profileID(for: $0) == store.activeProfileID && ($0.url != "about:blank" || $0.homePage == true) }
      .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
  }
  private var currentDocumentURL: String? {
    if let peek = store.state.activeTab?.peek, peek.isPresented != false { return peek.url }
    return store.state.activeTab?.url
  }
  private var selectedEntry: Entry? { results.indices.contains(selection) ? results[selection] : nil }
  private var placeholder: String {
    if let site { return "Search \(site.name)" }
    switch context {
    case .move(_, let pin): return pin ? "Pin to…" : "Move to…"
    case .result(_, _, let title, _): return title
    case .split: return "Split view with…"
    case .siteSearches: return "Site Search"
    case nil: return "Search or enter a URL"
    }
  }

  private var inputLabel: String {
    if case .result(_, _, let title, _) = context { return "Actions for \(title)" }
    return isNested ? placeholder : "Search tabs, history, Spaces and actions, or enter a URL"
  }
  private var resultStatus: String {
    guard let selectedEntry else {
      return inputLabel + ". " + (site.map { raw.count > 8000
        ? "Use a search of up to 8,000 characters" : "Type to search \($0.name)" } ?? "No matches in this scope")
    }
    return "\(inputLabel). \(results.count) results. \(selectedEntry.title), \(selectedEntry.type). Result \(selection + 1) of \(results.count)."
  }
  private func resultImage(_ item: Entry) -> NSImage? {
    guard item.kind != "navigation", let url = item.url else { return nil }
    if item.kind == "tab", let image = actions.icons[String(item.id.dropFirst(4))] { return image }
    return actions.iconForURL(url)
  }

  var body: some View {
    GeometryReader { geometry in
      let available = max(200, geometry.size.width)
      ZStack(alignment: .topLeading) {
        Color.clear.contentShape(Rectangle()).onTapGesture { actions.palette = false }
        VStack(spacing: 4) {
          input
          if !isNested { filters }
          resultList
        }.padding(8).frame(width: min(590, available - 32))
          .background { NativeControlSurface().overlay(colors.chrome.opacity(0.86)).clipShape(RoundedRectangle(cornerRadius: 12)) }
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.ink.opacity(0.08), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
          .opacity(entered || reduceMotion ? 1 : 0)
          .scaleEffect(entered || reduceMotion ? 1 : 0.99)
          .offset(y: entered || reduceMotion ? 0 : -4)
          .padding(.top, max(36, min(110, geometry.size.height * 0.12)))
          .frame(width: available)
      }
    }.font(.system(size: 13)).foregroundStyle(colors.ink).tint(colors.accent)
      .onAppear {
        resetSession()
        withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.16 * store.state.settings.motionScale)) {
          entered = true
        }
        actions.handlePaletteEscape = {
          if editingSearch != nil { editingSearch = nil; error = nil }
          else if !back() { actions.palette = false }
          return true
        }
      }
      .onDisappear { actions.handlePaletteEscape = { false } }
      .onChange(of: actions.paletteSession) { _, _ in resetSession() }
      .onChange(of: store.activeProfileID) { _, _ in
        actions.paletteRequest = nil; actions.query = ""
        editingSearch = nil; error = nil
        resetSession()
      }
      .onChange(of: actions.paletteRequest) { _, request in if let request { enter(request, remember: false) } }
      .onChange(of: actions.query) { _, value in
        if restoredQuery == value { restoredQuery = nil }
        else { selection = 0; selectedID = nil }
      }
      .onChange(of: selection) { _, index in selectedID = results.indices.contains(index) ? results[index].id : nil }
      .onChange(of: results.map(\.id)) { _, values in
        if let selectedID, let index = values.firstIndex(of: selectedID) { selection = index }
        else { selection = min(selection, max(0, values.count - 1)) }
      }
      .sheet(item: $editingSearch) { engine in searchEditor(engine) }
      .alert("Couldn’t update Site Search", isPresented: Binding(get: { error != nil && editingSearch == nil }, set: { if !$0 { error = nil } })) {
        Button("OK") { error = nil }
      } message: { Text(error ?? "") }
  }
  private var input: some View {
    HStack(spacing: 10) {
      NativeGlyph("magnifyingglass").font(.system(size: 16)).foregroundStyle(colors.muted)
      CommandSearchField(text: $actions.query, placeholder: placeholder, accessibilityLabel: inputLabel, resultStatus: resultStatus, textColor: NSColor(colors.ink), placeholderColor: NSColor(colors.muted), focusRequest: focusRequest, selectAllRequest: actions.paletteSession,
        submit: { activate(separate: $0) }, move: moveSelection,
        cancel: { if !back() { actions.palette = false } }, tab: enterSelected,
        backward: back, backspace: { raw.isEmpty && back() })
      Button {
        if !back() { actions.setPaletteDestination(editsAddress: !actions.paletteEditsAddress) }
      } label: {
        Text(isNested ? "Back" : actions.paletteEditsAddress ? "This tab" : "New tab")
          .font(.system(size: 10, weight: .medium)).foregroundStyle(colors.muted)
          .padding(.horizontal, 6).padding(.vertical, 5)
          .background(colors.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
      }.buttonStyle(.plain).accessibilityLabel(isNested ? "Back to previous command step" : "Destination: \(actions.paletteEditsAddress ? "current tab" : "new tab"). Change destination")
    }.frame(height: 48).padding(.horizontal, 12)
      .background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }
  private var filters: some View {
    HStack(spacing: 3) {
      ForEach(scopes, id: \.0) { value, label in
        Button {
          scope = value
          if prefix != nil { actions.query = query }
          selection = 0; selectedID = nil; focusRequest += 1
        } label: {
          Text(label).font(.system(size: 10, weight: filter == value ? .semibold : .regular))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(colors.card.opacity(filter == value ? 0.4 : 0), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? [.isSelected] : [])
      }
      Spacer(minLength: 0)
    }.padding(.vertical, 2).accessibilityElement(children: .contain).accessibilityLabel("Search scope")
  }
  private var resultList: some View {
    ScrollViewReader { reader in
      ScrollView {
        LazyVStack(spacing: 2) {
          if results.isEmpty {
            Text(site.map { raw.count > 8000 ? "Use a search of up to 8,000 characters" : "Type to search \($0.name)" } ?? "No matches in this scope")
              .foregroundStyle(colors.muted).font(.system(size: 12)).padding(18)
          }
          ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
            Button { run(item) } label: {
              HStack(spacing: 8) {
                Group {
                  if let image = resultImage(item) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                  } else { NativeGlyph(item.url != nil && item.kind != "navigation" ? "globe" : item.icon).font(.system(size: 14)) }
                }.frame(width: 22, height: 24).foregroundStyle(selection == index ? colors.ink : colors.muted)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).lineLimit(1)
                  if !item.detail.isEmpty { Text(item.detail).font(.system(size: 11)).foregroundStyle(selection == index ? colors.ink : colors.muted).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(item.type).font(.system(size: 10)).foregroundStyle(colors.muted).lineLimit(1)
              }.frame(minHeight: 26).padding(.horizontal, 10).padding(.vertical, 7)
                .background(colors.card.opacity(selection == index ? 0.46 : 0), in: RoundedRectangle(cornerRadius: 10))
                .modifier(NativeSelectionContrast(selected: selection == index, color: colors.ink, radius: 10))
                .shadow(color: .black.opacity(selection == index ? 0.07 : 0), radius: 1.5, y: 1).contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { if $0 { selection = index } }
              .accessibilityLabel(item.title + (item.detail.isEmpty ? "" : ", \(item.detail)"))
              .accessibilityAddTraits(selection == index ? [.isSelected] : []).id(item.id)
              .contextMenu {
                if ["tab", "history", "bookmark"].contains(item.kind) {
                  Button("Actions for this page") { enter(.result(kind: item.kind, id: item.id, title: item.title, url: item.url ?? "")) }
                }
              }
          }
        }
      }.scrollIndicators(.hidden)
        .frame(height: min(360, min(max(46, Double(results.count) * 44), max(120, Double(actions.contentFrame.height) - 200))))
        .onChange(of: selection) { _, index in
          guard results.indices.contains(index) else { return }
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1 * store.state.settings.motionScale)) { reader.scrollTo(results[index].id, anchor: .center) }
        }
    }
  }
  private var results: [Entry] {
    if let requested = site {
      guard let engine = requested.id == "current-website" ? requested : store.state.settings.siteSearches.first(where: { $0.id == requested.id }),
        let url = engine.searchURL(raw) else { return [] }
      return [Entry(id: "site-search", kind: "navigation", title: raw, icon: "magnifyingglass", type: "Search \(engine.name)", url: url.absoluteString) { navigate(url.absoluteString) }]
    }
    if let context { return contextEntries(context).map { entry -> Entry in
      var value = entry; value.score = raw.isEmpty ? 0 : max(Self.fuzzy(raw, entry.title), Self.fuzzy(raw, entry.detail) * 0.8); return value
    }.filter { raw.isEmpty || $0.score >= 20 }.sorted { $0.score > $1.score } }
    var candidates = [Entry]()
    func add(_ entry: Entry, priority: Double = 0) {
      guard filter == "all" || entry.kind == filter else { return }
      let score = query.isEmpty ? 0 : max(Self.fuzzy(query, entry.title), max(Self.fuzzy(query, entry.detail) * 0.75, Self.fuzzy(query, entry.keywords) * 0.7))
      guard query.isEmpty || score >= 20 else { return }
      var value = entry; value.score = score + priority; candidates.append(value)
    }
    if filter != "action" {
      for (index, tab) in profileTabs.enumerated() {
        if query.isEmpty && filter == "all" && (tab.id == store.state.activeTabID || index > 5) { continue }
        let detail = tab.spaceID == store.state.activeSpaceID ? NativePageIdentity.label(tab.url) : (store.state.spaces.first { $0.id == tab.spaceID }?.name ?? "")
        add(Entry(id: "tab:\(tab.id)", kind: "tab", title: tab.displayTitle, icon: "globe", detail: detail,
          type: tab.isPinned && (tab.isClosed || !actions.loadedTabIDs.contains(tab.id))
            ? tab.isFavorite ? "Open favorite" : "Open pinned tab" : "Switch to tab",
          keywords: "\(tab.url) \(tab.title) \(tab.savedURL ?? "")", url: tab.url) {
            close { store.selectTab(id: tab.id); actions.activate(tab.id) }
          }, priority: query.isEmpty ? Double(100 - index) : 14)
      }
      var seen = Set(candidates.compactMap(\.url))
      for (index, item) in store.state.bookmarks.filter({ $0.profileID == store.activeProfileID }).enumerated() {
        guard !seen.contains(item.url), !query.isEmpty || filter != "all" || index <= 2 else { continue }
        let before = candidates.count
        add(Entry(id: "bookmark:\(item.id)", kind: "bookmark", title: item.title, icon: "bookmark", detail: item.url,
          type: "Bookmark", url: item.url) { activateURL(item.url) }, priority: query.isEmpty ? Double(60 - index) : 8)
        if candidates.count > before { seen.insert(item.url) }
      }
      for (index, item) in store.state.history.filter({ $0.profileID == store.activeProfileID }).enumerated() {
        guard !seen.contains(item.url), !query.isEmpty || filter != "all" || index <= 2 else { continue }
        let before = candidates.count
        add(Entry(id: "history:\(item.id)", kind: "history", title: item.title, icon: "clock", detail: item.url,
          type: "History", url: item.url) { activateURL(item.url) }, priority: query.isEmpty ? Double(60 - index) : 0)
        if candidates.count > before { seen.insert(item.url) }
      }
      for space in store.state.spaces where space.profileID == store.activeProfileID && space.id != store.state.activeSpaceID {
        add(Entry(id: "space:\(space.id)", kind: "space", title: space.name, icon: space.icon, type: "Space", keywords: "switch space workspace") {
          close { store.selectSpace(id: space.id) }
        }, priority: query.isEmpty ? 30 : 9)
      }
      for folder in store.state.folders {
        guard let space = store.state.spaces.first(where: { $0.id == folder.spaceID && $0.profileID == store.activeProfileID }) else { continue }
        add(Entry(id: "folder:\(folder.id)", kind: "folder", title: folder.name, icon: "folder", detail: space.name, type: "Folder", keywords: "folder reveal find organize") {
          close { _ = actions.performInterfaceCommand("focus-folder:\(folder.id)") }
        }, priority: query.isEmpty ? 15 : 10)
      }
    }
    for command in actions.runtimeCommands where command.available {
      guard NativePalettePolicy.showsCommand(command.id,
        hasVisibleSplit: actions.runtimeCommands.contains { $0.id == "unsplit" && $0.available }) else { continue }
      if query.isEmpty && filter != "action" && !["new-folder", "new-space", "preferences", "shortcuts"].contains(command.id) { continue }
      add(Entry(id: "action:\(command.id)", kind: "action", title: command.id == "command-palette" ? "New tab" : command.title,
        icon: command.icon, type: command.shortcut.map(NativeInterfaceEditors.keyLabel) ?? "Action",
        keywords: NativePalettePolicy.commandKeywords(id: command.id, additional: command.keywords)) {
          if command.id == "split", let tab = store.state.activeTab, store.split(for: tab.id) == nil { enter(.split) }
          else if command.id == "move-tab", let tab = store.state.activeTab { enter(.move(tabID: tab.id, pin: false)) }
          else if command.id == "site-searches" { enter(.siteSearches) }
          else { close(command.action) }
        }, priority: query.isEmpty ? 20 : 4)
    }
    for entry in extraCommands {
      if query.isEmpty && filter != "action" { continue }
      add(entry, priority: 5)
    }
    if filter == "all" {
      if let url = currentDocumentURL,
        let website = SiteSearchEngine.currentWebsite(url, engines: store.state.settings.siteSearches, searchEngine: store.state.settings.searchEngine) {
        var entry = Entry(id: "current-website", kind: "action", title: "Search in \(website.name)", icon: "magnifyingglass", detail: query, type: "This website") {
          if let url = website.searchURL(query) { navigate(url.absoluteString) } else { enterSite(website) }
        }
        entry.score = query.isEmpty ? 90 : 40; candidates.append(entry)
      }
      if !query.isEmpty {
        if let engine = store.state.settings.siteSearches.first(where: { $0.keyword == query.lowercased() }) {
          var entry = Entry(id: "site:\(engine.id)", kind: "action", title: "Search \(engine.name)", icon: "magnifyingglass", detail: URL(string: engine.url)?.host ?? "", type: "Tab") { enterSite(engine) }
          entry.score = 44; candidates.append(entry)
        }
        if BrowserAddress.resolve(query, engine: store.state.settings.searchEngine) != nil {
          let address = !query.contains(where: \.isWhitespace) && (query.contains("://") || query.contains(".") || query.hasPrefix("localhost"))
          var entry = Entry(id: "navigation", kind: "navigation", title: query, icon: address ? "globe" : "magnifyingglass",
            type: address ? actions.paletteEditsAddress ? "Go to address" : "Open page" : "Search \(store.state.settings.searchEngine.rawValue.capitalized)", url: query) { navigate(query) }
          entry.score = address ? 220 : 45; candidates.append(entry)
        }
        if let question = NativePalettePolicy.askQuery(query, scope: filter, configured: actions.aiConfigured,
          isPrivate: store.state.activeProfile?.isPrivate != false, busy: actions.aiBusy) {
          let profileID = store.activeProfileID
          var entry = Entry(id: "ask", kind: "action", title: "Ask Zacro: \(question)", icon: "sparkle",
            type: actions.runtimeCommands.first(where: { $0.id == "ai" })?.shortcut.map(NativeInterfaceEditors.keyLabel) ?? "Ask AI") {
            guard store.activeProfileID == profileID,
              NativePalettePolicy.askQuery(question, scope: filter, configured: actions.aiConfigured,
                isPrivate: store.state.activeProfile?.isPrivate != false, busy: actions.aiBusy) != nil else { return }
            close { actions.askAI(question) }
          }
          entry.score = 10; candidates.append(entry)
        }
      }
    }
    return Array(candidates.sorted { $0.score > $1.score }.prefix(filter == "action" ? 80 : !query.isEmpty || filter != "all" ? 32 : 8))
  }

  private var extraCommands: [Entry] {
    var entries = [
      task("space-theme", "Customize this Space", "paintpalette", keywords: "color icon gradient grain transparency blur theme") { close { _ = actions.performInterfaceCommand("space-theme") } },
      task("site-searches", "Manage Site Search", "magnifyingglass", keywords: "site search engines keyword shortcut custom website") { enter(.siteSearches) },
    ]
    if let tab = store.state.activeTab, tab.url != "about:blank" {
      entries.append(task("pin-destination", "Pin tab to…", "pin", keywords: "pin space folder organize") { enter(.move(tabID: tab.id, pin: true)) })
      entries.append(task("favorite-tab", tab.isFavorite ? "Move favorite to this Space" : "Favorite tab", "star", keywords: "favorite icon all spaces") { close { store.toggleFavorite(id: tab.id) } })
      if tab.isPinned {
        entries.append(task("reset-pin", "Reset pinned tab", "arrow.uturn.backward", keywords: "reset original saved URL") { close { store.resetPinnedDestination(id: tab.id) } })
        if tab.savedURL != tab.url { entries.append(task("replace-pin", "Replace pin with current page", "pin") { close { store.replacePinnedDestination(id: tab.id) } }) }
      }
      if store.split(for: tab.id) != nil { entries.append(task("unsplit", "Unsplit tabs", "rectangle.split.2x1", keywords: "separate panes restore single view") { close { store.unsplit(tabID: tab.id) } }) }
    }
    let pins = store.state.tabs.filter { $0.spaceID == store.state.activeSpaceID && $0.isPinned && !$0.isFavorite }
    if !pins.isEmpty { entries.append(task("reset-space-pins", "Reset pins in this Space", "arrow.uturn.backward") { close { for tab in pins { store.resetPinnedDestination(id: tab.id) } } }) }
    let existing = Set(actions.runtimeCommands.map(\.id))
    return entries.filter { !existing.contains(String($0.id.dropFirst(7))) }
  }
  private func contextEntries(_ request: NativePaletteRequest) -> [Entry] {
    switch request {
    case .move(let tabID, let pin):
      guard let tab = store.tab(tabID), store.profileID(for: tab) == store.activeProfileID else { return [] }
      return store.state.spaces.filter { $0.profileID == store.activeProfileID }.flatMap { space in
        [task("destination:\(space.id)", space.name, space.icon) { move(tabID, space: space.id, folder: nil, pin: pin) }]
          + store.state.folders.filter { $0.spaceID == space.id }.map { folder in
            task("destination:\(folder.id)", folder.name, "folder", detail: space.name) { move(tabID, space: space.id, folder: folder.id, pin: pin) }
          }
      }
    case .split:
      guard let active = store.state.activeTabID else { return [] }
      return profileTabs.filter { $0.id != active && $0.url != "about:blank" && ($0.spaceID == store.state.activeSpaceID || $0.isFavorite) && store.split(for: $0.id) == nil }.map { tab in
        task("split:\(tab.id)", tab.displayTitle, "rectangle.split.2x1", detail: tab.url) { close { store.setSplit(left: active, right: tab.id) } }
      }
    case .siteSearches:
      return [task("search:add", "Add site search", "plus") { editSearch(nil) }]
        + store.state.settings.siteSearches.map { engine in
          var entry = task("search:edit:\(engine.id)", engine.name, "magnifyingglass", detail: URL(string: engine.url)?.host ?? "") { editSearch(engine) }
          entry.type = engine.keyword; return entry
        }
    case .result(let kind, let id, let title, let url):
      let tab = kind == "tab" ? store.tab(String(id.dropFirst(4))) : nil
      if kind == "tab" && (tab == nil || store.profileID(for: tab!) != store.activeProfileID) { return [] }
      let pageURL = tab?.url ?? url
      var items = [task("result:open", tab == nil ? "Open page" : "Switch to tab", "arrow.right") {
        if let tab { close { store.selectTab(id: tab.id); actions.activate(tab.id) } } else { activateURL(pageURL) }
      }]
      if BrowserAddress.webURL(pageURL) != nil {
        items.append(task("result:newtab", "Open in new tab", "plus") { navigate(pageURL, separate: true) })
        if actions.libraryCapabilities.contains("peek:open") {
          items.append(task("result:peek", "Peek at page", "eye") {
            guard let operation = actions.performLibraryAction else { return }
            let profileID = store.activeProfileID
            close {
              Task { @MainActor in
                do { try await operation("peek:open", ["url": pageURL, "profileId": profileID]) }
                catch { actions.interfaceError = error.localizedDescription }
              }
            }
          })
        }
      } else if let tab, NativePageIdentity.hasDocument(URL(string: pageURL)) {
        items.append(task("result:newtab", "Open in new tab", "plus") { duplicate(tab) })
      }
      if NativePageIdentity.hasDocument(URL(string: pageURL)) {
        items.append(task("result:copy", "Copy address", "link") { close { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pageURL, forType: .string) } })
      }
      if let tab {
        if tab.id != store.state.activeTabID, tab.spaceID == store.state.activeSpaceID,
          store.split(for: tab.id) == nil, let current = store.state.activeTabID, store.split(for: current) == nil {
          items.append(task("result:split", "Open in split view", "rectangle.split.2x1") { close { store.setSplit(left: current, right: tab.id) } })
        }
        items += [task("result:pin", tab.isPinned ? "Unpin tab" : "Pin tab", "pin") { close { store.togglePin(id: tab.id) } },
          task("result:favorite", tab.isFavorite ? "Move favorite to this Space" : "Favorite tab", "star") { close { store.toggleFavorite(id: tab.id) } },
          task("result:move", "Move to…", "folder") { enter(.move(tabID: tab.id, pin: false)) },
          task("result:pin-to", "Pin to…", "pin") { enter(.move(tabID: tab.id, pin: true)) }]
        if tab.isPinned {
          items.append(task("result:reset", "Reset pinned tab", "arrow.uturn.backward") { close { store.resetPinnedDestination(id: tab.id) } })
          if tab.savedURL != tab.url { items.append(task("result:replace", "Replace pin with current page", "pin") { close { store.replacePinnedDestination(id: tab.id) } }) }
        }
        if !tab.isClosed { items.append(task("result:close", tab.isPinned ? "Close page · keep pin" : "Close tab", "xmark") { close { actions.closeTab(tab.id) } }) }
      }
      _ = title
      return items
    }
  }
  private func task(_ id: String, _ title: String, _ icon: String, detail: String = "", keywords: String = "", action: @escaping () -> Void) -> Entry {
    Entry(id: "action:\(id)", kind: "action", title: title, icon: icon, detail: detail, keywords: keywords, run: action)
  }
  private func move(_ id: String, space: String, folder: String?, pin: Bool) {
    close {
      store.moveTab(id: id, spaceID: space, folderID: folder,
        pinned: pin ? true : nil, favorite: pin ? false : nil, clearFolder: true)
    }
  }
  private func navigate(_ url: String, separate: Bool = false) {
    context = nil; site = nil; trail.removeAll(); actions.paletteRequest = nil
    if separate { actions.palette = false; actions.newTab(url) } else { actions.submit(url) }
  }
  private func activateURL(_ url: String) {
    if let tab = profileTabs.first(where: { $0.url == url }) { close { store.selectTab(id: tab.id); actions.activate(tab.id) } }
    else { navigate(url) }
  }
  private func close(_ action: () -> Void) {
    context = nil; site = nil; trail.removeAll(); actions.paletteRequest = nil; actions.palette = false; action()
  }
  private func run(_ item: Entry) { item.run() }
  private func activate(separate: Bool) {
    guard let entry = selectedEntry else { return }
    if separate, entry.kind == "tab", let tab = store.tab(String(entry.id.dropFirst(4))),
      BrowserAddress.webURL(tab.url) == nil {
      duplicate(tab)
    } else if separate, let url = entry.url { navigate(url, separate: true) } else { run(entry) }
  }
  private func duplicate(_ tab: BrowserTab) {
    close {
      if let duplicate = store.duplicateTab(id: tab.id) { actions.activate(duplicate.id) }
    }
  }
  private func moveSelection(_ offset: Int) {
    guard !results.isEmpty else { return }
    selection = abs(offset) == 1 ? (selection + offset + results.count) % results.count : min(results.count - 1, max(0, selection + offset))
  }
  private func remember() {
    trail.append(PaletteStep(query: actions.query, selection: selection, scope: scope, context: context, site: site))
    actions.query = ""; selection = 0; selectedID = nil; scope = "all"; context = nil; site = nil
  }
  private func resetSession() {
    trail.removeAll(); context = nil; site = nil; scope = "all"; selection = 0; selectedID = nil; restoredQuery = nil
    focusRequest += 1
    if let request = actions.paletteRequest { enter(request, remember: false) }
  }
  private func enter(_ request: NativePaletteRequest, remember save: Bool = true) {
    if save { remember() } else { trail.removeAll(); actions.query = ""; selection = 0 }
    context = request; site = nil; focusRequest += 1
  }
  private func enterSite(_ engine: SiteSearchEngine) { remember(); site = engine; focusRequest += 1 }
  @discardableResult private func back() -> Bool {
    guard let step = trail.popLast() else { return false }
    restoredQuery = step.query
    context = step.context; site = step.site; scope = step.scope; actions.query = step.query; selection = step.selection
    selectedID = results.indices.contains(selection) ? results[selection].id : nil
    focusRequest += 1
    return true
  }
  private func enterSelected() -> Bool {
    if !isNested, filter == "all", let engine = store.state.settings.siteSearches.first(where: { $0.keyword == raw.lowercased() }) { enterSite(engine); return true }
    if !isNested, let item = selectedEntry, ["tab", "history", "bookmark"].contains(item.kind) {
      enter(.result(kind: item.kind, id: item.id, title: item.title, url: item.url ?? "")); return true
    }
    if !isNested && ["", "/", ">"].contains(raw) { actions.query = raw.isEmpty ? "/" : ""; return true }
    return false
  }
  private func editSearch(_ engine: SiteSearchEngine?) {
    guard engine != nil || store.state.settings.siteSearches.count < 20 else { error = "You can save up to 20 site searches."; return }
    let value = engine ?? SiteSearchEngine(name: "", keyword: "", url: "")
    searchName = value.name; searchKeyword = value.keyword; searchURL = value.url; error = nil; editingSearch = value
  }
  private func searchEditor(_ engine: SiteSearchEngine) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.state.settings.siteSearches.contains(where: { $0.id == engine.id }) ? "Edit site search" : "Add site search").font(.headline)
      TextField("Name", text: $searchName)
      TextField("Keyword", text: $searchKeyword)
      TextField("Search URL", text: $searchURL)
      Text("Use %s in place of the search query.").font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if store.state.settings.siteSearches.contains(where: { $0.id == engine.id }) {
          Button("Remove search", role: .destructive) {
            do { try store.setSiteSearches(store.state.settings.siteSearches.filter { $0.id != engine.id }); error = nil; editingSearch = nil }
            catch { self.error = error.localizedDescription; store.clearError() }
          }
        }
        Spacer()
        Button("Cancel") { editingSearch = nil; error = nil }.keyboardShortcut(.cancelAction)
        Button("Save") {
          let value = SiteSearchEngine(id: engine.id, name: searchName, keyword: searchKeyword, url: searchURL)
          do { try store.setSiteSearches(store.state.settings.siteSearches.filter { $0.id != engine.id } + [value]); error = nil; editingSearch = nil }
          catch { self.error = error.localizedDescription; store.clearError() }
        }.keyboardShortcut(.defaultAction)
      }
    }.textFieldStyle(.roundedBorder).padding(20).frame(width: 410)
  }
  private static func fuzzy(_ query: String, _ value: String) -> Double {
    NativeCommandSearchMatching.score(query, value)
  }
  private struct Entry: Identifiable {
    let id: String
    let kind: String
    let title: String
    let icon: String
    var detail = ""
    var type = ""
    var keywords = ""
    var url: String?
    var score = 0.0
    let run: () -> Void
  }
  private struct PaletteStep {
    let query: String; let selection: Int; let scope: String
    let context: NativePaletteRequest?; let site: SiteSearchEngine?
  }
}

private struct CommandSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var accessibilityLabel: String
  var resultStatus: String
  var textColor: NSColor
  var placeholderColor: NSColor
  var focusRequest: Int
  var selectAllRequest: UInt64
  var submit: (Bool) -> Void
  var move: (Int) -> Void
  var cancel: () -> Void
  var tab: () -> Bool
  var backward: () -> Bool
  var backspace: () -> Bool
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NativeCommandSearchControl {
    let field = NativeCommandSearchControl(); field.focusRingType = .none; field.isBordered = false; field.drawsBackground = false
    field.font = .systemFont(ofSize: 15); field.delegate = context.coordinator
    field.updateSearchAccessibility(label: accessibilityLabel, status: resultStatus)
    DispatchQueue.main.async { field.window?.makeFirstResponder(field); field.selectText(nil) }
    return field
  }
  func updateNSView(_ field: NativeCommandSearchControl, context: Context) {
    field.updateSearchAccessibility(label: accessibilityLabel, status: resultStatus)
    context.coordinator.parent = self; field.placeholderString = placeholder
    field.textColor = textColor
    (field.currentEditor() as? NSTextView)?.insertionPointColor = textColor
    field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor, .font: NSFont.systemFont(ofSize: 15)])
    if field.stringValue != text { field.stringValue = text }
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      field.window?.makeFirstResponder(field)
    }
    if context.coordinator.lastSelectionRequest != selectAllRequest {
      context.coordinator.lastSelectionRequest = selectAllRequest
      field.selectText(nil)
    }
  }
  static func dismantleNSView(_ field: NativeCommandSearchControl, coordinator: Coordinator) { field.cancelSearchAnnouncement() }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: CommandSearchField
    var lastFocusRequest = 0
    var lastSelectionRequest: UInt64 = 0
    init(_ parent: CommandSearchField) { self.parent = parent }
    func controlTextDidBeginEditing(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      (field.currentEditor() as? NSTextView)?.insertionPointColor = parent.textColor
      (field as? NativeCommandSearchControl)?.announceSearchStatus()
    }
    func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.text = field.stringValue } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard !textView.hasMarkedText() else { return false }
      switch selector {
      case #selector(NSResponder.moveUp(_:)): parent.move(-1)
      case #selector(NSResponder.moveDown(_:)): parent.move(1)
      case #selector(NSResponder.pageUp(_:)): parent.move(-6)
      case #selector(NSResponder.pageDown(_:)): parent.move(6)
      case #selector(NSResponder.insertNewline(_:)):
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard flags.intersection([.command, .control, .shift]).isEmpty else { return false }
        parent.submit(flags.contains(.option))
      case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
      case #selector(NSResponder.insertTab(_:)): return parent.tab()
      case #selector(NSResponder.insertBacktab(_:)): return parent.backward()
      case #selector(NSResponder.deleteBackward(_:)): return parent.backspace()
      default: return false
      }
      return true
    }
  }
}
