import AppKit
import SwiftUI
import ZacroCore

/// The optional Home Page, distinct from the empty tinted page behind the command bar.
struct NativeHomePage: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  let colors: NativeSpacePalette
  let sidebarVisible: Bool
  @FocusState private var searchFocused: Bool
  private var query: String { actions.homeQuery }
  private struct Link: Identifiable { let url: String; let title: String; var tabID: String? = nil; var id: String { url } }
  private var saved: [Link] {
    let pins = store.visibleTabs.filter { $0.isPinned }
    var seen = Set(sidebarVisible ? pins.map(\.url) : [])
    let candidates = (sidebarVisible ? [] : pins.map { Link(url: $0.url, title: $0.displayTitle, tabID: $0.id) })
      + store.state.bookmarks.filter { $0.profileID == store.activeProfileID }.map { Link(url: $0.url, title: $0.title) }
    return Array(candidates.filter { seen.insert($0.url).inserted }.prefix(6))
  }
  private var recent: [Link] {
    var seen = Set<String>()
    return Array(store.state.history.filter { $0.profileID == store.activeProfileID }
      .sorted { $0.visitedAt > $1.visitedAt }.filter { seen.insert($0.url).inserted }.prefix(3)
      .map { Link(url: $0.url, title: $0.title) })
  }
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        homeContents.frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }.scrollIndicators(.hidden)
    }
    .onChange(of: actions.homeFocusSession) { _, _ in searchFocused = true }
  }
  private var homeContents: some View {
    VStack(spacing: 20) {
      if store.state.activeProfile?.isPrivate == true {
        VStack(spacing: 10) {
          NativeGlyph("shield", size: 28).foregroundStyle(colors.muted)
          Text("Private browsing").font(.system(size: 20, weight: .semibold))
          Text("History and tabs stay in this session.").foregroundStyle(colors.muted)
        }.padding(.bottom, 6)
      }
      HStack(spacing: 10) {
        NativeGlyph("magnifyingglass").foregroundStyle(colors.muted)
        TextField("Search or enter a URL", text: $actions.homeQuery).textFieldStyle(.plain)
          .focused($searchFocused)
          .accessibilityLabel("Search the web or enter a URL")
          .onSubmit { navigate(query) }
        Button { navigate(query) } label: { NativeGlyph("arrow.right").frame(width: 24, height: 26) }
          .buttonStyle(.plain).help("Go").accessibilityLabel("Go")
          .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(.horizontal, 12).frame(height: 40)
        .background(colors.card.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
        .modifier(NativeSelectionContrast(selected: true, color: colors.ink, radius: 11))
      if !saved.isEmpty {
        HStack(alignment: .top, spacing: 4) {
          ForEach(saved) { link in
            Button { open(link) } label: {
              VStack(spacing: 8) {
                favicon(link.url).frame(width: 18, height: 18).frame(width: 32, height: 32)
                  .background(colors.card.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                Text(link.title.isEmpty ? domain(link.url) : link.title).font(.system(size: 11)).lineLimit(1)
              }.frame(maxWidth: .infinity).frame(height: 64).contentShape(Rectangle())
                .modifier(NativeSelectionContrast(selected: true, color: colors.ink, radius: 9))
            }.buttonStyle(NativePressButtonStyle(scale: 0.96, motionScale: store.state.settings.motionScale)).help("\(link.title) — \(link.url)")
          }
        }.accessibilityElement(children: .contain).accessibilityLabel("Saved pages")
      }
      if !recent.isEmpty {
        VStack(spacing: 5) {
          HStack {
            Text("Recent").font(.system(size: 11, weight: .medium)).foregroundStyle(colors.muted)
            Spacer()
            Button { actions.library = "History" } label: { NativeGlyph("clock.arrow.circlepath").frame(width: 24, height: 24) }
              .buttonStyle(.plain).help("History").accessibilityLabel("History")
          }
          ForEach(recent) { link in
            Button { open(link) } label: {
              HStack(spacing: 10) {
                favicon(link.url).frame(width: 16, height: 16)
                Text(link.title.isEmpty ? domain(link.url) : link.title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(domain(link.url)).font(.system(size: 10)).foregroundStyle(colors.muted).lineLimit(1)
                NativeGlyph("arrow.right", size: 12).foregroundStyle(colors.muted)
              }.padding(.horizontal, 10).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(NativePressButtonStyle(motionScale: store.state.settings.motionScale)).help(link.url)
          }
        }
      }
    }.font(.system(size: 13)).foregroundStyle(colors.ink).tint(colors.accent)
      .frame(maxWidth: 420).padding(32)
  }
  @ViewBuilder private func favicon(_ url: String) -> some View {
    if let image = actions.iconForURL(url) ?? store.state.tabs.first(where: { $0.url == url }).flatMap({ actions.icons[$0.id] }) {
      Image(nsImage: image).resizable().scaledToFit()
    } else { NativeGlyph("globe") .foregroundStyle(colors.muted) }
  }
  private func domain(_ url: String) -> String { NativePageIdentity.label(url).replacingOccurrences(of: "www.", with: "") }
  private func open(_ link: Link) {
    if let id = link.tabID, let tab = store.tab(id), store.profileID(for: tab) == store.activeProfileID,
      BrowserAddress.webURL(tab.url) == nil {
      actions.homeQuery = ""; actions.activate(id)
    } else { navigate(link.url) }
  }
  private func navigate(_ value: String) {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    actions.homeQuery = ""
    actions.navigate(value)
  }
}
