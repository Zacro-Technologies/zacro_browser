import AppKit
import SwiftUI
import ZacroCore

private struct NativeInterfaceAlignmentRecordingKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var nativeInterfaceAlignmentRecording: Bool {
    get { self[NativeInterfaceAlignmentRecordingKey.self] }
    set { self[NativeInterfaceAlignmentRecordingKey.self] = newValue }
  }
}

/// Passive geometry witnesses are installed only in an explicitly instrumented
/// acceptance host. Ordinary browser windows create no additional native views.
struct NativeInterfaceAlignmentMark: View {
  let id: String
  @Environment(\.nativeInterfaceAlignmentRecording) private var recording
  var body: some View {
    if recording { NativeInterfaceAlignmentAnchor(id: id) }
  }
}

private struct NativeInterfaceAlignmentAnchor: NSViewRepresentable {
  let id: String
  func makeNSView(context: Context) -> NativeInterfaceAlignmentFrame {
    let view = NativeInterfaceAlignmentFrame()
    view.identifier = NSUserInterfaceItemIdentifier(id)
    return view
  }
  func updateNSView(_ view: NativeInterfaceAlignmentFrame, context: Context) {
    view.identifier = NSUserInterfaceItemIdentifier(id)
  }
}

final class NativeInterfaceAlignmentFrame: NSView {
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func isAccessibilityElement() -> Bool { false }
}

/// Cache-renders the actual shell at its narrow rail width using an isolated,
/// memory-only model. It does not present a window, borrow focus, load a page,
/// or measure a second implementation of the row layout.
@MainActor
enum NativeInterfaceAlignmentAcceptance {
  static func run() async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance") else {
      throw Failure("Interface alignment requires the disposable application fixture")
    }
    let first = "alignment-first", second = "alignment-second"
    let longName = "A very long collection for reading research inspiration and projects"
    var state = BrowserState()
    state.profiles = [BrowserProfile(id: "alignment-profile", name: "Layout fixture")]
    state.spaces = [BrowserSpace(id: first, profileID: "alignment-profile", name: longName),
      BrowserSpace(id: second, profileID: "alignment-profile", name: "Reference")]
    state.folders = [BrowserFolder(id: "alignment-long-folder", spaceID: first, name: longName),
      BrowserFolder(id: "alignment-short-folder", spaceID: second, name: "Reference")]
    state.settings.sidebarWidth = 200
    state.settings.sidebarVisible = true
    state.settings.motionScale = 0
    state.settings.onboardingCompleted = true
    let pin = BrowserTab(id: "alignment-pin", spaceID: first, url: "https://pin.example/", title: "Pinned", isPinned: true)
    let regular = BrowserTab(id: "alignment-regular", spaceID: first, url: "https://regular.example/", title: "Reading")
    let left = BrowserTab(id: "alignment-left", spaceID: first, url: "https://left.example/", title: longName)
    let right = BrowserTab(id: "alignment-right", spaceID: first, url: "https://right.example/", title: longName)
    let reference = BrowserTab(id: "alignment-reference", spaceID: second, url: "https://reference.example/", title: "Reference")
    let favorites = (0..<5).map { BrowserTab(id: "alignment-favorite-\($0)", spaceID: first,
      url: "https://favorite-\($0).example/", title: "Favorite \($0)", isFavorite: true, isPinned: true) }
    state.tabs = [pin, regular, left, right, reference] + favorites
    state.splits = [SplitGroup(id: "alignment-split", spaceID: first, leftTabID: left.id, rightTabID: right.id)]
    state.activeSpaceID = first; state.activeTabID = regular.id
    state.spaces[0].lastActiveTabID = regular.id; state.spaces[1].lastActiveTabID = reference.id
    let store = BrowserStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("zacro-interface-alignment-" + UUID().uuidString), initialState: state, memoryOnly: true)
    let actions = BrowserActions()
    let originalKeyWindow = NSApp.keyWindow
    let root = NSHostingView(rootView: BrowserShell(store: store, actions: actions) { Color.clear }
      .environment(\.nativeInterfaceAlignmentRecording, true))
    root.sizingOptions = []
    let size = NSSize(width: 680, height: 720)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root; root.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }

    func snapshot() throws -> [String: CGRect] {
      guard window.contentView === root, root.window === window, !window.isVisible else {
        throw Failure("The exact unpresented alignment host changed")
      }
      root.layoutSubtreeIfNeeded()
      var stack: [NSView] = [root], result: [String: CGRect] = [:]
      var count = 0
      while let view = stack.popLast() {
        count += 1
        guard count <= 8_192 else { throw Failure("The owned alignment view tree exceeded its bound") }
        guard view.window === window else { continue }
        if view is NativeInterfaceAlignmentFrame, let id = view.identifier?.rawValue {
          guard result[id] == nil else { throw Failure("Duplicate actual alignment witness: " + id) }
          result[id] = root.convert(view.bounds, from: view)
        }
        stack += view.subviews
      }
      return result
    }
    func layout(_ required: [String]) async throws -> [String: CGRect] {
      let end = ProcessInfo.processInfo.systemUptime + 4
      var previous: [String: CGRect]?
      while ProcessInfo.processInfo.systemUptime < end {
        try Task.checkCancellation()
        let frames = try snapshot()
        if required.allSatisfy({ frames[$0].map { !$0.isEmpty } == true }), frames == previous {
          guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw Failure("The actual shell could not produce its owned render")
          }
          root.cacheDisplay(in: root.bounds, to: image)
          guard image.pixelsWide > 0, image.pixelsHigh > 0 else { throw Failure("The owned shell render is empty") }
          return try snapshot()
        }
        previous = frames
        try await Task.sleep(for: .milliseconds(20))
      }
      let frames = try snapshot()
      throw Failure("Actual shell layout did not settle: " + required.filter { frames[$0] == nil }.joined(separator: ", "))
    }
    var checks: [String] = []
    func require(_ condition: Bool, _ name: String) throws {
      guard condition else { throw Failure(name) }
      checks.append(name)
    }
    func frame(_ id: String, in frames: [String: CGRect]) throws -> CGRect {
      guard let value = frames[id], !value.isEmpty else { throw Failure("Missing actual layout frame: " + id) }
      return value
    }
    func rowContains(_ child: CGRect, _ row: CGRect) -> Bool {
      row.insetBy(dx: -0.51, dy: -0.51).contains(child)
        && abs(child.midY - row.midY) <= 0.51
    }
    let names = ["active-tab-title:" + pin.id, "active-tab-title:" + regular.id,
      "active-tab-icon:" + pin.id, "active-tab-icon:" + regular.id,
      "active-space-title:" + first, "active-folder-title:alignment-long-folder",
      "preview-space-title:" + second, "preview-folder-title:alignment-short-folder",
      "active-tab-title:" + left.id, "active-tab-title:" + right.id]
    let initial = try await layout(names)
    let pinTitle = try frame("active-tab-title:" + pin.id, in: initial)
    let regularTitle = try frame("active-tab-title:" + regular.id, in: initial)
    let pinIcon = try frame("active-tab-icon:" + pin.id, in: initial)
    let regularIcon = try frame("active-tab-icon:" + regular.id, in: initial)
    try require(abs(pinTitle.minX - regularTitle.minX) <= 0.51
      && abs(pinIcon.midX - regularIcon.midX) <= 0.51,
      "interfaceHostedPinnedAndRegularRowsShareIconAndTitleColumns")

    let spaceTitle = try frame("active-space-title:" + first, in: initial)
    let spaceRow = try frame("active-space-row:" + first, in: initial)
    let folderTitle = try frame("active-folder-title:alignment-long-folder", in: initial)
    let folderRow = try frame("active-folder-row:alignment-long-folder", in: initial)
    let shortSpace = try frame("preview-space-title:" + second, in: initial)
    let shortFolder = try frame("preview-folder-title:alignment-short-folder", in: initial)
    try require(rowContains(spaceTitle, spaceRow) && rowContains(folderTitle, folderRow)
      && abs(spaceTitle.height - shortSpace.height) <= 0.51
      && abs(folderTitle.height - shortFolder.height) <= 0.51,
      "interfaceHostedLongNamesRemainContainedOnSingleCenteredRowsAtNarrowRail")

    let page = try frame("space-page:" + first, in: initial)
    let tiles = try favorites.map { try frame("active-tab-row:" + $0.id, in: initial) }
    var rows: [[CGRect]] = []
    for tile in tiles.sorted(by: { $0.midY < $1.midY }) {
      if let last = rows.indices.last, abs(rows[last][0].midY - tile.midY) <= 0.51 { rows[last].append(tile) }
      else { rows.append([tile]) }
    }
    try require(rows.count == 2 && rows.map(\.count).sorted() == [2, 3] && rows.allSatisfy { row in
      let sorted = row.sorted { $0.minX < $1.minX }
      return sorted.allSatisfy { page.insetBy(dx: -0.51, dy: -0.51).contains($0)
          && abs($0.width - sorted[0].width) <= 0.51 && abs($0.height - sorted[0].height) <= 0.51 }
        && zip(sorted, sorted.dropFirst()).allSatisfy { pair in pair.0.maxX < pair.1.minX }
        && abs(sorted[0].minX - page.minX) <= 0.51
        && abs(sorted[sorted.count - 1].maxX - page.maxX) <= 0.51
    }, "interfaceHostedDenseFavoritesKeepBalancedNonoverlappingRows")

    let activeSplit = try [left, right].map { tab -> (String, CGFloat, CGFloat) in
      let row = try frame("active-tab-row:" + tab.id, in: initial)
      let title = try frame("active-tab-title:" + tab.id, in: initial)
      let icon = try frame("active-tab-icon:" + tab.id, in: initial)
      return (tab.id, title.minX - row.minX, icon.midX - row.minX)
    }
    store.selectSpace(id: second)
    let preview = try await layout(["active-space-title:" + second, "preview-space-title:" + first,
      "preview-folder-title:alignment-long-folder", "preview-tab-title:" + left.id, "preview-tab-title:" + right.id])
    let previewSpace = try frame("preview-space-title:" + first, in: preview)
    let previewSpaceRow = try frame("preview-space-row:" + first, in: preview)
    let previewFolder = try frame("preview-folder-title:alignment-long-folder", in: preview)
    let previewFolderRow = try frame("preview-folder-row:alignment-long-folder", in: preview)
    try require(rowContains(previewSpace, previewSpaceRow) && rowContains(previewFolder, previewFolderRow)
      && abs(previewSpace.height - shortSpace.height) <= 0.51
      && abs(previewFolder.height - shortFolder.height) <= 0.51,
      "interfaceHostedInactiveSpacePreviewsRetainSingleLineNameAlignment")
    for (id, titleOffset, iconOffset) in activeSplit {
      let row = try frame("preview-tab-row:" + id, in: preview)
      let title = try frame("preview-tab-title:" + id, in: preview)
      let icon = try frame("preview-tab-icon:" + id, in: preview)
      try require(abs(title.minX - row.minX - titleOffset) <= 0.51
        && abs(icon.midX - row.minX - iconOffset) <= 0.51,
        "interfaceHostedSplitPreviewRetainsItsActualMemberColumns-" + id)
    }
    try require(!window.isVisible && NSApp.keyWindow === originalKeyWindow,
      "interfaceHostedLayoutEvidenceLeavesActualWindowFocusUntouched")
    return checks
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Native interface alignment failed: " + message }
  }
}
