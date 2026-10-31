import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZacroCore

struct NativeLibrary: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  @State var section: String
  @State private var query = ""
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  private let sections = ["Bookmarks", "History", "Downloads", "Archive", "Settings"]
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Library").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(20)
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(sections, id: \.self) { item in
            Button {
              section = item
              query = ""
            } label: {
              Text(item).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(
                  .primary.opacity(section == item ? 0.08 : 0),
                  in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
          }
          Divider().padding(.vertical, 5)
          Button("Extensions", action: actions.openExtensions).buttonStyle(.plain).padding(10)
          Spacer()
        }.padding(10).frame(width: 150)
        VStack(alignment: .leading) {
          if section != "Settings" {
            TextField("Search \(section.lowercased())", text: $query).textFieldStyle(.roundedBorder)
              .padding(.horizontal)
          }
          content
        }.padding(.vertical)
      }
    }.frame(width: 800, height: 560)
      .alert(
        "Couldn’t complete the action",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK") { error = nil }
      } message: {
        Text(error ?? "")
      }
  }
  @ViewBuilder private var content: some View {
    switch section {
    case "Bookmarks":
      List {
        ForEach(
          store.state.bookmarks.filter {
            $0.profileID == store.activeProfileID && matches($0.title, $0.url)
          }
        ) { item in
          HStack {
            entry(item.title, url: item.url)
            Spacer()
            Button {
              store.removeBookmark(id: item.id)
            } label: {
              Image(systemName: "trash")
            }.buttonStyle(.borderless)
          }
        }
      }.overlay {
        if store.state.bookmarks.isEmpty {
          ContentUnavailableView("No bookmarks", systemImage: "bookmark")
        }
      }
    case "History":
      VStack {
        List(
          store.state.history.filter {
            $0.profileID == store.activeProfileID && matches($0.title, $0.url)
          }
        ) { item in
          HStack {
            entry(item.title, url: item.url)
            Spacer()
            Text(item.visitedAt, style: .date).foregroundStyle(.secondary).font(.caption)
          }
        }
        Button("Clear history", role: .destructive) { store.clearHistory() }.padding(8)
      }
    case "Downloads":
      List(
        store.state.downloads.filter {
          $0.profileID == store.activeProfileID && matches($0.filename, $0.url)
        }
      ) { item in
        HStack {
          Image(systemName: "arrow.down.document")
          VStack(alignment: .leading) {
            Text(item.filename)
            Text(item.status).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if let path = item.path {
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
          }
        }
      }
    case "Archive":
      List(
        store.state.archive.filter {
          store.profileID(for: $0.tab) == store.activeProfileID
            && matches($0.tab.displayTitle, $0.tab.url)
        }
      ) { item in
        HStack {
          VStack(alignment: .leading) {
            Text(item.tab.displayTitle)
            Text(item.tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button("Restore") {
            if let tab = store.restoreTab(id: item.id) {
              actions.activate(tab.id)
              dismiss()
            }
          }
        }
      }
    default:
      Form {
        Section("Browsing") {
          Picker("Search engine", selection: setting(\.searchEngine)) {
            ForEach(SearchEngine.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }
          Toggle("Restore tabs on startup", isOn: setting(\.restoreSession))
          HStack {
            Text("Archive inactive tabs after")
            TextField("Hours", value: setting(\.archiveAfterHours), format: .number).frame(
              width: 60)
            Text("hours")
          }
        }
        Section("Appearance") {
          Picker("Appearance", selection: setting(\.appearance)) {
            Text("System").tag("system")
            Text("Light").tag("light")
            Text("Dark").tag("dark")
          }
          LabeledContent("Page spacing", value: "\(Int(store.state.settings.pageGutter))px")
          Slider(value: setting(\.pageGutter), in: 4...20, step: 1)
          LabeledContent("Page corners", value: "\(Int(store.state.settings.pageRadius))px")
          Slider(value: setting(\.pageRadius), in: 0...24, step: 1)
          LabeledContent("Sidebar width", value: "\(Int(store.state.settings.sidebarWidth))px")
          Slider(value: setting(\.sidebarWidth), in: 200...380, step: 1)
          LabeledContent("Motion", value: "\(Int(store.state.settings.motionScale * 100))%")
          Slider(value: setting(\.motionScale), in: 0...2, step: 0.1)
        }
        Section("Browser data") {
          Button("Export browser data…") { exportData() }
          Button("Import browser data…") { importData(legacy: false) }
          Button("Import from Electron Zacro…") { importData(legacy: true) }
        }
      }.formStyle(.grouped)
    }
  }
  private func entry(_ title: String, url: String) -> some View {
    Button {
      actions.newTab(url)
      dismiss()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(title.isEmpty ? url : title).lineLimit(1)
        Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }.buttonStyle(.plain)
  }
  private func matches(_ title: String, _ url: String) -> Bool {
    query.isEmpty || title.localizedCaseInsensitiveContains(query)
      || url.localizedCaseInsensitiveContains(query)
  }
  private func setting<Value>(_ keyPath: WritableKeyPath<BrowserSettings, Value>) -> Binding<Value>
  {
    Binding(
      get: { store.state.settings[keyPath: keyPath] },
      set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
  }
  private func exportData() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Zacro.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try store.exportData(to: url) } catch { self.error = error.localizedDescription }
  }
  private func importData(legacy: Bool) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      if legacy { try store.importLegacy(from: url) } else { try store.importData(from: url) }
    } catch { self.error = error.localizedDescription }
  }
}
