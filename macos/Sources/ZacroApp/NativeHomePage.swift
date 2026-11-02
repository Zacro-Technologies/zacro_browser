import AppKit
import SwiftUI
import ZacroCore

/// The optional Home Page, distinct from the empty tinted page behind the command bar.
struct NativeHomePage: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  let colors: NativeSpacePalette
  let sidebarVisible: Bool
  private enum SearchFocus: Hashable { case query, submit }
  @FocusState private var searchFocus: SearchFocus?
  @FocusState private var recentFocus: String?
  @State private var hoveredRecentURL: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        homeContents(width: geometry.size.width, height: geometry.size.height)
          .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }.scrollIndicators(.hidden)
    }
    .onChange(of: actions.homeFocusSession) { _, _ in searchFocus = .query }
  }
  private func homeContents(width: CGFloat, height: CGFloat) -> some View {
    let compact = width <= 350
    let padding: CGFloat = compact ? 18 : width <= 500 ? 24 : 32
    let contentWidth = min(420, max(1, width - padding * 2))
    let gap: CGFloat = width <= 500 ? 4 : 8
    let motion = reduceMotion || store.state.settings.motionScale <= 0 ? nil
      : Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.14 * store.state.settings.motionScale)
    return VStack(spacing: 0) {
      if store.state.activeProfile?.isPrivate == true {
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            NativeGlyph("shield", size: 16)
            Text("Private browsing").font(.system(size: 14, weight: .medium)).frame(height: 19.6)
              .accessibilityAddTraits(.isHeader)
          }
          Text("History and tabs stay in this session.").font(.system(size: 11))
            .lineSpacing(3.5).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 16.5)
        }.foregroundStyle(colors.muted).padding(.bottom, 18)
      }
      HStack(spacing: compact ? 8 : 10) {
        NativeGlyph("magnifyingglass", size: 18).foregroundStyle(colors.muted)
        TextField("Search or enter a URL", text: $actions.homeQuery).textFieldStyle(.plain)
          .font(.system(size: compact ? 12 : 13))
          .frame(height: compact ? 18 : 19.5).padding(.vertical, 7)
          .focused($searchFocus, equals: .query)
          .accessibilityLabel("Search the web or enter a URL")
          .onSubmit { navigate(query) }
        Button { navigate(query) } label: { NativeGlyph("arrow.right").frame(width: 30, height: 30) }
          .foregroundStyle(colors.muted)
          .buttonStyle(NativeHoverPressButtonStyle(hover: colors.hover, radius: 7, motionScale: store.state.settings.motionScale))
          .focused($searchFocus, equals: .submit).help("Go").accessibilityLabel("Go")
          .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(.leading, 12).padding(.trailing, 7).padding(.vertical, 4).frame(minHeight: 40)
        .background(colors.card.opacity(0.84), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
          RoundedRectangle(cornerRadius: 11).strokeBorder(searchFocus == nil ? colors.line : colors.accent, lineWidth: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .background {
          RoundedRectangle(cornerRadius: 14).fill(colors.accent.opacity(searchFocus == nil ? 0 : 0.08)).padding(-3)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .shadow(color: Color(red: 28 / 255, green: 23 / 255, blue: 18 / 255).opacity(searchFocus == nil ? 9 / 255 : 0), radius: 4, y: 2)
        .animation(motion, value: searchFocus)
      if !saved.isEmpty {
        NativeHomeLinksLayout(spacing: gap) {
          ForEach(saved) { link in
            Button { open(link) } label: {
              VStack(spacing: 7) {
                favicon(link.url).frame(width: 18, height: 18).frame(width: 32, height: 32)
                  .background(colors.chrome, in: RoundedRectangle(cornerRadius: 8))
                Text(link.title.isEmpty ? domain(link.url) : link.title).font(.system(size: compact ? 10 : 11)).lineLimit(1)
                  .frame(maxWidth: .infinity).frame(height: compact ? 15 : 16.5)
              }.frame(width: 64).padding(.horizontal, 4).padding(.vertical, 10).contentShape(Rectangle())
                .modifier(NativeSelectionContrast(selected: true, color: colors.ink, radius: 8))
            }.buttonStyle(NativeHoverPressButtonStyle(hover: colors.hover, radius: 8, scale: 0.96,
              pressDuration: 0.1, motionScale: store.state.settings.motionScale))
              .accessibilityIdentifier("home-saved:\(link.url)").help("\(link.title) — \(link.url)")
          }
        }.padding(.top, 18).accessibilityElement(children: .contain).accessibilityLabel("Saved pages")
      }
      if !recent.isEmpty {
        VStack(spacing: 4) {
          HStack(spacing: 8) {
            Text("Recent").font(.system(size: 11, weight: .medium)).foregroundStyle(colors.muted)
            Spacer()
            Button { actions.library = "History" } label: {
              NativeGlyph("clock.arrow.circlepath", size: 14).frame(width: 26, height: 26)
            }.foregroundStyle(colors.muted)
              .buttonStyle(NativeHoverPressButtonStyle(hover: colors.hover, motionScale: store.state.settings.motionScale))
              .help("History").accessibilityLabel("History")
          }.padding(.horizontal, 7)
          VStack(spacing: 1) {
            ForEach(recent) { link in
              Button { open(link) } label: {
                HStack(spacing: 10) {
                  favicon(link.url).frame(width: 16, height: 16).frame(width: 20, height: 20)
                  Text(link.title.isEmpty ? domain(link.url) : link.title).font(.system(size: 12)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  Text(domain(link.url)).font(.system(size: 10)).foregroundStyle(colors.muted).lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing).layoutPriority(-1)
                  NativeGlyph("arrow.right", size: 13).foregroundStyle(colors.muted)
                    .opacity(hoveredRecentURL == link.url || recentFocus == link.url ? 1 : 0)
                    .animation(reduceMotion || store.state.settings.motionScale <= 0 ? nil
                      : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.1 * store.state.settings.motionScale),
                      value: hoveredRecentURL == link.url || recentFocus == link.url)
                }.padding(.horizontal, 8).frame(height: 42).contentShape(Rectangle())
              }.buttonStyle(NativeHoverPressButtonStyle(hover: colors.hover, radius: 7, scale: 0.985,
                pressDuration: 0.1, motionScale: store.state.settings.motionScale))
                .focused($recentFocus, equals: link.url)
                .onHover { entered in
                  if entered { hoveredRecentURL = link.url }
                  else if hoveredRecentURL == link.url { hoveredRecentURL = nil }
                }.help(link.url)
            }
          }
        }.padding(.top, height <= 640 ? 18 : 25)
      }
    }.font(.system(size: 13)).foregroundStyle(colors.ink).tint(colors.accent)
      .frame(width: contentWidth).padding(.horizontal, padding).padding(.vertical, height <= 640 ? 20 : padding)
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

/// CSS flex-wrap/justify-content:center with the reference's fixed 72px tiles.
/// Every row is centered independently, including a short final row.
private struct NativeHomeLinksLayout: Layout {
  let spacing: CGFloat
  private let tileWidth: CGFloat = 72
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposedWidth(proposal, count: subviews.count)
    let rows = rows(in: width, subviews: subviews)
    return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height }
      + CGFloat(max(0, rows.count - 1)) * spacing)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(in: bounds.width, subviews: subviews) {
      let width = CGFloat(row.indices.count) * tileWidth + CGFloat(max(0, row.indices.count - 1)) * spacing
      var x = bounds.midX - width / 2
      for index in row.indices {
        subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
          proposal: ProposedViewSize(width: tileWidth, height: row.height))
        x += tileWidth + spacing
      }
      y += row.height + spacing
    }
  }
  private func proposedWidth(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
    if let width = proposal.width, width.isFinite { return max(0, width) }
    return CGFloat(count) * tileWidth + CGFloat(max(0, count - 1)) * spacing
  }
  private func rows(in width: CGFloat, subviews: Subviews) -> [(indices: Range<Int>, height: CGFloat)] {
    let columns = max(1, Int(floor((max(0, width) + spacing) / (tileWidth + spacing))))
    return stride(from: 0, to: subviews.count, by: columns).map { start in
      let indices = start..<min(subviews.count, start + columns)
      let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: tileWidth, height: nil)).height }.max() ?? 0
      return (indices, height)
    }
  }
}
