import AppKit
import SwiftUI
import ZacroCore

/// Deterministic owned-view renders of the actual Home layout, not a duplicate
/// implementation or desktop screenshot. No window is shown or made key.
@MainActor
enum NativeHomePageRenderEvidence {
  static func capture(directory: URL) async throws {
    guard CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_RENDER_EVIDENCE"] == "1" else { return }
    var state = BrowserState()
    guard let profile = state.activeProfile else { throw ShortcutError("Missing owned Home render profile") }
    state.bookmarks = ["Reading", "Projects", "Design notes", "Music", "Research", "Saved recipes"].enumerated().map {
      Bookmark(profileID: profile.id, url: "https://home-fixture.invalid/page-\($0.offset)", title: $0.element)
    }
    state.history = ["Recent reading", "Project notes", "Reference material"].enumerated().map {
      HistoryEntry(profileID: profile.id, url: "https://recent-fixture.invalid/page-\($0.offset)",
        title: $0.element, visitedAt: Date(timeIntervalSince1970: Double(100 - $0.offset)))
    }
    for isPrivate in [false, true] {
      var initial = state
      if isPrivate {
        guard let index = initial.profiles.firstIndex(where: { $0.id == profile.id }) else { continue }
        initial.profiles[index].isPrivate = true
        initial.history = []; initial.bookmarks = []
      }
      let store = BrowserStore(directory: directory.appendingPathComponent("HomeRenderOnly"), initialState: initial, memoryOnly: true)
      let actions = BrowserActions()
      for dark in [false, true] {
        for width in [CGFloat(640), CGFloat(340)] {
          let size = NSSize(width: width, height: 560)
          let colors = NativeSpacePalette(theme: state.activeSpace?.theme ?? SpaceTheme(), dark: dark)
          let view = NSHostingView(rootView: NativeHomePage(store: store, actions: actions,
            colors: colors, sidebarVisible: true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(colors.chrome))
          let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.contentView = view
          defer { window.close() }
          view.frame = NSRect(origin: .zero, size: size)
          view.layoutSubtreeIfNeeded()
          await Task.yield()
          view.layoutSubtreeIfNeeded()
          try NativeViewRenderEvidence.capture("home-\(isPrivate ? "private-" : "")\(dark ? "dark" : "light")-\(Int(width))", window: window)
        }
      }
    }
  }
}
