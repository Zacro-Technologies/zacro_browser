import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZacroCore

/// The live Library rail. The page keeps its document and remains visible beside it.
struct NativeLibrary: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  @State var section: String
  @State private var query = ""
  @State private var error: String?
  @State private var busy = Set<String>()
  @State private var renameDownload: DownloadRecord?
  @State private var renameError: String?
  @State private var filename = ""
  @State private var layoutExpanded = false
  @FocusState private var focus: String?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.presentedSpaceTheme) private var presentedTheme
  private let sections = ["Bookmarks", "History", "Downloads", "Archive", "Settings", "Extensions", "AI"]
  private var colors: NativeSpacePalette {
    let theme = presentedTheme ?? store.state.activeSpace?.theme ?? SpaceTheme()
    return NativeSpacePalette(theme: theme, dark: colorScheme == .dark)
  }
  private var isRecords: Bool { ["Bookmarks", "History", "Downloads", "Archive"].contains(section) }
  private var rows: [LibraryRow] {
    switch section {
    case "Bookmarks": return store.state.bookmarks.filter { $0.profileID == store.activeProfileID }.map {
      LibraryRow(id: $0.id, title: $0.title, url: $0.url, date: $0.createdAt)
    }
    case "History": return store.state.history.filter { $0.profileID == store.activeProfileID }.map {
      LibraryRow(id: $0.id, title: $0.title, url: $0.url, date: $0.visitedAt)
    }
    case "Archive": return store.state.archive.filter { store.profileID(for: $0.tab) == store.activeProfileID }.map {
      LibraryRow(id: $0.id, title: $0.tab.displayTitle, url: $0.tab.url, date: $0.archivedAt)
    }
    default: return []
    }
  }
  private var filteredRows: [LibraryRow] {
    Array(rows.filter { matches($0.title, $0.url) }.sorted { $0.date > $1.date }.prefix(500))
  }
  private var downloads: [DownloadRecord] {
    Array(store.state.downloads.filter {
      $0.profileID == store.activeProfileID && matches($0.filename, $0.url)
    }.sorted { $0.createdAt > $1.createdAt }.prefix(500))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if isRecords {
        HStack(spacing: 7) {
          NativeGlyph("magnifyingglass").foregroundStyle(colors.muted)
          TextField("Search \(section.lowercased())", text: $query)
            .textFieldStyle(.plain).focused($focus, equals: "search")
            .accessibilityLabel("Search \(section.lowercased())")
            .onKeyPress(.downArrow) {
              guard let first = filteredRows.first else { return .ignored }
              focus = first.id
              return .handled
            }
        }.padding(.horizontal, 10).frame(height: 32)
          .background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
          .padding(.horizontal, 12).padding(.bottom, 10)
      }
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(colors.ink).tint(colors.accent).font(.system(size: 13))
    .buttonStyle(LibraryActionStyle(colors: colors))
    .onAppear { if isRecords { focus = "search" } }
    .onChange(of: actions.library) { _, value in
      guard let value else { return }
      section = value; query = ""; focus = isRecords ? "search" : "section"
    }
    .onChange(of: store.activeProfileID) { _, _ in query = ""; renameDownload = nil; renameError = nil }
    .onKeyPress(.escape) { actions.library = nil; return .handled }
    .alert("Couldn’t complete the action", isPresented: Binding(
      get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: { Text(error ?? "") }
    .sheet(item: $renameDownload) { download in
      NativeNameEditor(title: "Rename download", name: $filename, limit: 255, saveTitle: "Rename", fieldLabel: "Filename", error: renameError,
        canSave: !busy.contains(download.id), colors: colors, save: { rename(download) },
        cancel: { renameDownload = nil; renameError = nil })
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Menu {
        ForEach(sections, id: \.self) { item in
          Button {
            actions.library = item
          } label: {
            Label(item == "AI" ? "Ask AI" : item, systemImage: symbol(item))
          }
        }
      } label: {
        HStack(spacing: 7) {
          NativeGlyph(symbol(section)).foregroundStyle(colors.accent)
          Text(section == "AI" ? "Ask AI" : section).fontWeight(.semibold)
          NativeGlyph("chevron.down").font(.system(size: 8))
        }.frame(height: 28).contentShape(Rectangle())
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focused($focus, equals: "section").accessibilityLabel("Choose Library section")
      Spacer(minLength: 0)
      if section == "History" || section == "Archive" {
        Button { confirmClear() } label: { NativeGlyph("trash").frame(width: 24, height: 26) }
          .buttonStyle(.plain).help(section == "History" ? "Clear history" : "Empty archive")
          .accessibilityLabel(section == "History" ? "Clear history" : "Empty archive")
          .disabled(rows.isEmpty || busy.contains("") || !actions.libraryCapabilities.contains(section == "History" ? "history:clear" : "archive:clear"))
      }
      Button { actions.library = nil } label: { NativeGlyph("xmark").frame(width: 26, height: 26) }
        .buttonStyle(.plain).help("Close Library").accessibilityLabel("Close Library")
    }.frame(height: 36).padding(.horizontal, 12)
  }

  @ViewBuilder private var content: some View {
    if section == "Settings" {
      settings
    } else if section == "Downloads" {
      ScrollView {
        if downloads.isEmpty { emptyState }
        else {
          LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(downloadGroups, id: \.label) { group in
              groupHeading(group.label, count: group.items.count)
              ForEach(group.items) { download in downloadRow(download) }
            }
          }.padding(.horizontal, 12).padding(.bottom, 12)
        }
      }.scrollIndicators(.hidden)
    } else if isRecords {
      ScrollViewReader { reader in
        ScrollView {
          if filteredRows.isEmpty { emptyState }
          else {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(groups, id: \.label) { group in
                groupHeading(group.label, count: group.items.count)
                ForEach(group.items) { row in recordRow(row).id(row.id) }
              }
            }.padding(.horizontal, 12).padding(.bottom, 12)
          }
        }.scrollIndicators(.hidden)
          .onChange(of: focus) { _, id in
            guard let id, id != "search", id != "section" else { return }
            reader.scrollTo(id, anchor: .center)
          }
      }
    } else if let view = actions.libraryContent(section) {
      view
    }
  }

  private var groups: [LibraryGroup] {
    var result: [LibraryGroup] = []
    for row in filteredRows {
      let label = dateLabel(row.date)
      if let index = result.firstIndex(where: { $0.label == label }) { result[index].items.append(row) }
      else { result.append(LibraryGroup(label: label, items: [row])) }
    }
    return result
  }
  private var downloadGroups: [LibraryDownloadGroup] {
    var result: [LibraryDownloadGroup] = []
    for item in downloads {
      let label = dateLabel(item.createdAt)
      if let index = result.firstIndex(where: { $0.label == label }) { result[index].items.append(item) }
      else { result.append(LibraryDownloadGroup(label: label, items: [item])) }
    }
    return result
  }
  private func groupHeading(_ title: String, count: Int) -> some View {
    HStack {
      Text(title).fontWeight(.semibold)
      Spacer()
      Text("\(count)")
    }.font(.system(size: 11)).foregroundStyle(colors.muted)
      .padding(.horizontal, 5).padding(.top, 12).padding(.bottom, 4)
  }
  private var emptyState: some View {
    VStack(spacing: 9) {
      NativeGlyph(query.isEmpty ? symbol(section) : "magnifyingglass")
        .font(.system(size: 24)).foregroundStyle(colors.accent).padding(.bottom, 4)
      Text(query.isEmpty ? emptyTitle : "No matches").font(.system(size: 14, weight: .semibold))
      Text(query.isEmpty ? emptyDescription : "Try a different title or address.")
        .font(.system(size: 12)).foregroundStyle(colors.muted).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity).padding(.horizontal, 22).padding(.top, 48)
  }
  private var emptyTitle: String {
    switch section {
    case "History": "No history yet"
    case "Archive": "No archived tabs"
    case "Downloads": "No downloads yet"
    default: "No bookmarks yet"
    }
  }
  private var emptyDescription: String {
    switch section {
    case "History": "Pages you visit appear here."
    case "Archive": "Closed tabs will appear here."
    case "Downloads": "Files you download appear here."
    default: "Bookmark a page to keep it here."
    }
  }
  private func recordRow(_ row: LibraryRow) -> some View {
    HStack(spacing: 8) {
      Group {
        if let icon = actions.iconForURL(row.url) { Image(nsImage: icon).resizable().scaledToFit() }
        else { NativeGlyph("globe").foregroundStyle(colors.accent) }
      }.frame(width: 16, height: 16)
      Button {
        if section == "Archive" {
          if let tab = store.restoreTab(id: row.id) { actions.activate(tab.id) }
        } else { actions.newTab(row.url) }
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(row.title.isEmpty ? (URL(string: row.url)?.host ?? row.url) : row.title).lineLimit(1)
          Text(URL(string: row.url)?.host ?? row.url).font(.system(size: 11))
            .foregroundStyle(colors.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).focused($focus, equals: row.id)
        .onKeyPress(.downArrow) { moveFocus(row.id, offset: 1); return .handled }
        .onKeyPress(.upArrow) { moveFocus(row.id, offset: -1); return .handled }
        .onKeyPress(.home) { focus = filteredRows.first?.id; return .handled }
        .onKeyPress(.end) { focus = filteredRows.last?.id; return .handled }
      if section == "History" {
        Text(row.date, style: .time).font(.system(size: 10)).foregroundStyle(colors.muted)
      }
      if section == "Bookmarks" {
        Button { store.removeBookmark(id: row.id) } label: { NativeGlyph("xmark").frame(width: 24, height: 26) }
          .buttonStyle(.plain).accessibilityLabel("Remove bookmark \(row.title)")
      } else if section == "Archive" {
        Button {
          if let tab = store.restoreTab(id: row.id) { actions.activate(tab.id) }
        } label: { NativeGlyph("arrow.uturn.backward").frame(width: 24, height: 26) }
          .buttonStyle(.plain).accessibilityLabel("Restore \(row.title)")
      } else if actions.libraryCapabilities.contains("peek:open") {
        Button { perform("peek:open", values: ["url": row.url]) } label: {
          NativeGlyph("eye").frame(width: 24, height: 26)
        }.buttonStyle(.plain).accessibilityLabel("Preview \(row.title)")
      }
    }.padding(.vertical, 8).padding(.horizontal, 5)
      .background(colors.card.opacity(focus == row.id ? 0.46 : 0), in: RoundedRectangle(cornerRadius: 8))
      .contextMenu {
        Button("Open in new tab") { actions.newTab(row.url) }
        if actions.libraryCapabilities.contains("peek:open") {
          Button("Peek at page") { perform("peek:open", values: ["url": row.url]) }
        }
        Button("Copy address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.url, forType: .string) }
      }
  }

  private func downloadRow(_ item: DownloadRecord) -> some View {
    let complete = item.status == "completed"
    let paused = item.status == "paused"
    let running = ["downloading", "progressing", "paused"].contains(item.status)
    return HStack(alignment: .top, spacing: 8) {
      NativeGlyph("doc").font(.system(size: 19)).foregroundStyle(colors.accent).frame(width: 22, height: 32)
      VStack(alignment: .leading, spacing: 5) {
        Text(item.filename).lineLimit(2)
        Text(complete ? bytes(max(item.totalBytes, item.receivedBytes)) : paused ? "Paused" : running ? "\(bytes(item.receivedBytes)) / \(bytes(item.totalBytes))" : item.status.capitalized)
          .font(.system(size: 11)).foregroundStyle(colors.muted)
        if running {
          ProgressView(value: item.totalBytes > 0 ? Double(item.receivedBytes) / Double(item.totalBytes) : nil)
            .progressViewStyle(.linear).accessibilityLabel("Download progress")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if complete, let path = item.path {
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
          NativeGlyph("folder").frame(width: 24, height: 26)
        }.buttonStyle(.plain).help("Show in Finder")
      } else if running, actions.libraryCapabilities.contains(paused ? "download:resume" : "download:pause") {
        Button { perform(paused ? "download:resume" : "download:pause", id: item.id) } label: {
          NativeGlyph(paused ? "play" : "pause").frame(width: 24, height: 26)
        }.buttonStyle(.plain).help(paused ? "Resume download" : "Pause download")
      }
      Menu {
        if complete, let path = item.path {
          Button("Open file") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
          if actions.libraryCapabilities.contains("download:rename") {
            Button("Rename…") { filename = item.filename; renameError = nil; renameDownload = item }
          }
          if actions.libraryCapabilities.contains("download:suggest") {
            Button("Suggest name…") { perform("download:suggest", id: item.id) }
          }
          if item.previousPath != nil, actions.libraryCapabilities.contains("download:undo") {
            Button("Undo rename") { perform("download:undo", id: item.id) }
          }
        }
        if running, actions.libraryCapabilities.contains("download:cancel") {
          Button("Cancel download") { perform("download:cancel", id: item.id) }
        }
      } label: { NativeGlyph("ellipsis").frame(width: 24, height: 26) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Actions for \(item.filename)")
    }.padding(8).background(colors.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
      .disabled(busy.contains(item.id))
  }

  private var settings: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        settingsSection("Appearance") {
          if actions.libraryCapabilities.contains("app:set-default-browser") {
            HStack {
              Text("Default browser")
              Spacer()
              if actions.defaultBrowser == true { Text("Zacro").foregroundStyle(colors.muted) }
              else { Button("Make default") { perform("app:set-default-browser") } }
            }
          }
          DisclosureGroup("Layout & motion", isExpanded: $layoutExpanded) {
            VStack(spacing: 10) {
              settingPicker("Tab spacing", value: setting(\.tabDensity), options: [("compact", "Compact"), ("comfortable", "Comfortable")])
              choice("Page inset", value: setting(\.pageGutter), options: customOptions([4, 8, 12, 16, 20], current: store.state.settings.pageGutter) { "\(Int($0))px" })
              choice("Page corners", value: setting(\.pageRadius), options: customOptions([0, 8, 12, 16, 20], current: store.state.settings.pageRadius) {
                [0.0: "Square", 8: "Soft", 12: "Rounded", 16: "Rounder", 20: "Pillowy"][$0] ?? "\(Int($0))px"
              })
              choice("Motion", value: setting(\.motionScale), options: customOptions([0.7, 1, 1.25, 1.4], current: store.state.settings.motionScale) {
                [0.7: "Quick", 1: "Balanced", 1.25: "Relaxed", 1.4: "Gentle"][$0] ?? "Custom · \($0.formatted())×"
              })
              choice("Sleep idle favorites", value: setting(\.pinnedSleepMinutes), options: [0, 5, 10, 20, 30, 60, 120].map { ($0, $0 == 0 ? "Never" : "After \($0) minutes") })
            }.padding(.top, 10)
          }.font(.system(size: 12))
          settingPicker("Appearance", value: setting(\.appearance), options: [("system", "Follow system"), ("light", "Light"), ("dark", "Dark")])
          choice("Search engine", value: setting(\.searchEngine), options: SearchEngine.allCases.map { ($0, $0 == .duckduckgo ? "DuckDuckGo" : $0 == .brave ? "Brave Search" : $0.rawValue.capitalized) })
          choice("Archive Today tabs", value: archiveSetting, options: archiveOptions)
          choice("Sidebar width", value: setting(\.sidebarWidth), options: customOptions([224, 260, 300], current: store.state.settings.sidebarWidth) {
            [224.0: "Compact", 260: "Comfortable", 300: "Spacious"][$0] ?? "\(Int($0))px"
          })
          Toggle("Restore session", isOn: setting(\.restoreSession)).toggleStyle(.switch).controlSize(.mini)
          HStack {
            Button("Customize Space") { _ = actions.performInterfaceCommand("space-theme") }
            Button("Profiles") { _ = actions.performInterfaceCommand("profiles") }
            Button("Shortcuts") { _ = actions.performInterfaceCommand("shortcuts") }
          }
        }
        if let serviceSettings = actions.settingsContent() { serviceSettings }
        settingsSection("Site Search") {
          Button("Manage Site Search…") { _ = actions.performInterfaceCommand("site-searches") }
        }
        settingsSection("Your data") {
          Text(store.state.profiles.first(where: { $0.id == store.activeProfileID })?.name ?? "Profile")
            .fontWeight(.medium)
          HStack {
            Button("Export data…") { exportData() }
            Button("Import data…") { importData(legacy: false) }
          }
          Button("Import from Electron Zacro…") { importData(legacy: true) }
          if actions.libraryCapabilities.contains("data:clear") {
            Button("Clear browsing data…") { confirmClearData() }.disabled(busy.contains(""))
          }
          if actions.libraryCapabilities.contains("permission:list") {
            Button("Site permissions…") { perform("permission:list") }
          }
        }
        settingsSection("Extensions") {
          Button("Manage extensions") { actions.library = "Extensions" }
          Button("Chrome Web Store", action: actions.openExtensionStore)
        }
        settingsSection("About Zacro") {
          Text("An independent, open-source browser.").foregroundStyle(colors.muted)
          HStack {
            Button("Version details") {
              actions.runtimeCommands.first(where: { $0.id == "about" })?.action()
            }
            Button("Welcome tour") { _ = actions.performInterfaceCommand("onboarding") }
          }
        }
      }.padding(14)
    }.scrollIndicators(.hidden)
  }
  @ViewBuilder private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    if title == "Appearance" {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.accent)
        content()
      }.frame(maxWidth: .infinity, alignment: .leading)
    } else {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 10) { content() }.padding(.top, 10)
      } label: { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.accent) }
    }
  }
  private func customOptions(_ values: [Double], current: Double, title: (Double) -> String) -> [(Double, String)] {
    (values.contains(current) ? values : values + [current]).map { ($0, title($0)) }
  }
  private var archiveOptions: [(Double, String)] {
    var options: [(Double, String)] = [(12, "After 12 hours"), (24, "After 24 hours"), (72, "After 3 days"), (168, "After 7 days"), (720, "After 30 days"), (0, "Never")]
    if store.activeProfileID != store.state.profiles.first(where: { !$0.isPrivate })?.id {
      options.insert((-1, "Use default"), at: 0)
    }
    let selected = archiveSetting.wrappedValue
    if !options.contains(where: { $0.0 == selected }) { options.append((selected, "After \(selected.formatted()) hours")) }
    return options
  }
  private func settingPicker(_ title: String, value: Binding<String>, options: [(String, String)]) -> some View {
    choice(title, value: value, options: options)
  }
  private func choice<Value: Hashable>(_ title: String, value: Binding<Value>, options: [(Value, String)]) -> some View {
    let selected = options.first { $0.0 == value.wrappedValue }?.1 ?? ""
    return HStack(spacing: 8) {
      Text(title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        ForEach(options.indices, id: \.self) { index in
          Button {
            value.wrappedValue = options[index].0
          } label: {
            if options[index].0 == value.wrappedValue { Label(options[index].1, systemImage: "checkmark") }
            else { Text(options[index].1) }
          }
        }
      } label: {
        HStack(spacing: 7) {
          Text(selected).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
          NativeGlyph("chevron.down", size: 10).foregroundStyle(colors.muted)
        }.font(.system(size: 12)).padding(.horizontal, 9).frame(height: 29)
          .background(colors.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 142)
        .accessibilityLabel(title).accessibilityValue(selected)
    }
  }
  private func metricSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
    VStack(spacing: 4) {
      HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))\(suffix)").foregroundStyle(colors.muted).monospacedDigit() }
      Slider(value: value, in: range, step: 1).labelsHidden().accessibilityLabel(title)
    }
  }
  private var archiveSetting: Binding<Double> {
    Binding(get: {
      guard let profile = store.state.profiles.first(where: { $0.id == store.activeProfileID }) else { return store.state.settings.archiveAfterHours }
      return profile.id == store.state.profiles.first(where: { !$0.isPrivate })?.id ? store.state.settings.archiveAfterHours : (profile.archiveAfterHours ?? -1)
    }, set: { value in
      if store.activeProfileID == store.state.profiles.first(where: { !$0.isPrivate })?.id {
        store.updateSettings { $0.archiveAfterHours = value }
      } else if let index = store.state.profiles.firstIndex(where: { $0.id == store.activeProfileID }) {
        store.state.profiles[index].archiveAfterHours = value < 0 ? nil : value
        store.save()
      }
    })
  }
  private func setting<Value>(_ keyPath: WritableKeyPath<BrowserSettings, Value>) -> Binding<Value> {
    Binding(get: { store.state.settings[keyPath: keyPath] }, set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
  }
  private func confirmClear() {
    let clearingSection = section, profileID = store.activeProfileID
    let alert = NSAlert()
    alert.messageText = section == "History" ? "Clear this profile’s history?" : "Empty the archive?"
    alert.informativeText = section == "History" ? "Your tabs, bookmarks, and other profiles stay available." : "Archived tabs in this profile will no longer be recoverable."
    alert.addButton(withTitle: section == "History" ? "Clear history" : "Empty archive")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    guard alert.runModal() == .alertFirstButtonReturn, profileID == store.activeProfileID else { return }
    perform(clearingSection == "History" ? "history:clear" : "archive:clear")
  }
  private func confirmClearData() {
    let profile = store.state.activeProfile
    let alert = NSAlert()
    alert.messageText = "Clear browsing data for \(profile?.name ?? "this profile")?"
    alert.informativeText = "This removes history, site permissions, cookies, cached files, and site storage. You will be signed out of websites. Bookmarks and saved tabs stay."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear data")
    alert.buttons.first?.keyEquivalent = "\r"
    alert.buttons.last?.keyEquivalent = ""; alert.buttons.last?.hasDestructiveAction = true
    guard alert.runModal() == .alertSecondButtonReturn, profile?.id == store.activeProfileID else { return }
    perform("data:clear")
  }
  private func perform(_ action: String, id: String = "", values: [String: String] = [:]) {
    guard let operation = actions.performLibraryAction else { return }
    let profile = store.activeProfileID
    busy.insert(id)
    Task { @MainActor in
      defer { busy.remove(id) }
      do { try await operation(action, values.merging(["id": id, "profileId": profile]) { first, _ in first }) }
      catch { self.error = error.localizedDescription }
    }
  }
  private func rename(_ download: DownloadRecord) {
    guard let operation = actions.performLibraryAction, !busy.contains(download.id) else { return }
    let draft = filename
    busy.insert(download.id); renameError = nil
    Task { @MainActor in
      defer { busy.remove(download.id) }
      do {
        try await operation("download:rename", ["id": download.id, "profileId": download.profileID, "name": draft])
        if renameDownload?.id == download.id { renameDownload = nil; renameError = nil }
      } catch {
        if renameDownload?.id == download.id, store.activeProfileID == download.profileID {
          renameError = error.localizedDescription; store.clearError()
        }
      }
    }
  }
  private func moveFocus(_ id: String, offset: Int) {
    guard let index = filteredRows.firstIndex(where: { $0.id == id }) else { return }
    let next = index + offset
    focus = next < 0 ? "search" : filteredRows[min(filteredRows.count - 1, next)].id
  }
  private func matches(_ title: String, _ url: String) -> Bool {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || title.localizedCaseInsensitiveContains(text) || url.localizedCaseInsensitiveContains(text)
  }
  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
  private func dateLabel(_ date: Date) -> String {
    if date == .distantPast { return "Earlier" }
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
  private func symbol(_ section: String) -> String {
    switch section {
    case "Bookmarks": "bookmark"
    case "History": "clock.arrow.circlepath"
    case "Downloads": "arrow.down.circle"
    case "Archive": "archivebox"
    case "Settings": "gearshape"
    case "Extensions": "puzzlepiece.extension"
    default: "sparkles"
    }
  }
  private func exportData() {
    let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Zacro.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try store.exportData(to: url) } catch { self.error = error.localizedDescription }
  }
  private func importData(legacy: Bool) {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .html]; panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      if url.pathExtension.lowercased() == "html", let operation = actions.performLibraryAction {
        Task { @MainActor in do { try await operation("data:import-bookmarks", ["path": url.path, "profileId": store.activeProfileID]) } catch { self.error = error.localizedDescription } }
      } else if legacy { try store.importLegacy(from: url) } else { try store.importData(from: url) }
    } catch { self.error = error.localizedDescription }
  }
}
private struct LibraryRow: Identifiable {
  let id: String
  let title: String
  let url: String
  let date: Date
}
private struct LibraryGroup {
  let label: String
  var items: [LibraryRow]
}
private struct LibraryDownloadGroup {
  let label: String
  var items: [DownloadRecord]
}

private struct LibraryActionStyle: ButtonStyle {
  let colors: NativeSpacePalette
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 9).padding(.vertical, 6)
      .foregroundStyle(colors.ink)
      .background(colors.card.opacity(configuration.isPressed ? 0.65 : 0.36), in: RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? 1 : 0.4)
  }
}
