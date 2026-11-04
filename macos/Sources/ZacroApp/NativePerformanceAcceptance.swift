import AppKit
import Foundation
import ZacroChromium
import ZacroCore

/// Diagnostic only: a fresh acceptance profile, no page navigation or input.
/// External process sampling reads the atomic phase file; this code samples
/// neither browsing data nor CPU/GPU counters and changes no runtime policy.
@MainActor final class NativePerformanceAcceptance {
  private let application: ApplicationCoordinator
  private var task: Task<Void, Never>?
  private var events: [[String: Any]] = []
  private var compositionVariant = "theme"
  init(application: ApplicationCoordinator) { self.application = application }

  func run() {
    task = Task { [weak self] in
      guard let self else { return }
      do { try await self.measure() }
      catch {
        try? self.record(phase: "failed", stage: "terminal", error: error.localizedDescription)
        fputs("Native performance diagnostic failed: \(error.localizedDescription)\n", stderr)
      }
      NSApp.terminate(nil)
    }
  }

  private func measure() async throws {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-performance-acceptance"),
      !CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_PERFORMANCE_OUTPUT"]?.isEmpty == false,
      let owner = application.focusedCoordinator,
      let spaceID = owner.store.state.activeSpace?.id else {
      throw ShortcutError("Performance diagnostics require the fresh engine acceptance profile and output path.")
    }
    // engine.start has already enforced an empty disposable directory and
    // mock key storage. Keep normal services/runtime startup otherwise intact.
    let window = owner.windowContext.window
    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1440, height: 940)), display: true)
    let frame = window.frame
    owner.actions.palette = false
    owner.store.updateSettings { $0.sidebarVisible = false }
    try requireEmpty(owner)
    try record(phase: "startup", stage: "settling")
    try await Task.sleep(for: .seconds(5))
    // A fresh empty shell normally offers its palette from onAppear. Let that
    // ordinary startup finish, then dismiss it before any material sampling.
    owner.actions.palette = false
    if ProcessInfo.processInfo.environment["ZACRO_PERFORMANCE_ISOLATE_COMPOSITION"] == "1" {
      try await measureComposition(owner, spaceID: spaceID, frame: frame)
    } else {
      for (phase, opacity, blur, grain) in [("opaque", 1.0, 0.0, 0.0),
        ("blur-only", 0.78, 0.6875, 0.0), ("grain-only", 1.0, 0.0, 0.295),
        ("user-theme", 0.78, 0.6875, 0.295), ("opaque-again", 1.0, 0.0, 0.0)] {
        try Task.checkCancellation()
        try requireEmpty(owner)
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing,
          owner.store.state.activeSpaceID == spaceID, window.frame == frame else {
          throw ShortcutError("The diagnostic window changed during measurement.")
        }
        owner.store.updateSpace(spaceID) {
          $0.theme.opacity = opacity; $0.theme.blur = blur; $0.theme.grain = grain
          $0.theme.intensity = 0.45
        }
        try record(phase: phase, stage: "warmup")
        try await Task.sleep(for: .seconds(3))
        try record(phase: phase, stage: "measuring")
        try await Task.sleep(for: .seconds(12))
        try requireEmpty(owner)
        guard window.frame == frame else { throw ShortcutError("The diagnostic window resized during sampling.") }
        try record(phase: phase, stage: "complete")
      }
    }
    try record(phase: "finished", stage: "terminal")
  }

  /// Isolates only the disposable shell's AppKit composition. The original
  /// SwiftUI subtree stays attached with its identity intact. Its reveal button
  /// still contains regularMaterial in the shell phases, even with theme blur 0.
  private func measureComposition(_ owner: BrowserWindowCoordinator, spaceID: String, frame: NSRect) async throws {
    let window = owner.windowContext.window
    guard let content = window.contentView else {
      throw ShortcutError("The diagnostic shell has no native content view.")
    }
    let originalSubviews = content.subviews.map { (view: $0, hidden: $0.isHidden) }
    let originalOpaque = window.isOpaque
    let originalBackground = window.backgroundColor
    let canvas = NativePerformanceFlatCanvas(frame: content.bounds)
    defer {
      canvas.removeFromSuperview()
      for original in originalSubviews { original.view.isHidden = original.hidden }
      window.isOpaque = originalOpaque
      window.backgroundColor = originalBackground
    }
    let variants: [(name: String, flat: Bool, opaque: Bool, visible: Bool)] = [
      ("shell-transparent-window", false, false, true),
      ("shell-opaque-window", false, true, true),
      ("flat-transparent-window", true, false, true),
      ("flat-opaque-window", true, true, true),
      ("shell-restored-transparent-window", false, false, true),
      ("shell-hidden-window", false, false, false),
    ]
    for variant in variants {
      try Task.checkCancellation()
      try requireEmpty(owner)
      guard owner.windowContext.isOpen, !owner.windowContext.isClosing,
        owner.store.state.activeSpaceID == spaceID, window.frame == frame,
        window.contentView === content else {
        throw ShortcutError("The diagnostic shell changed during composition isolation.")
      }
      owner.store.updateSpace(spaceID) {
        $0.theme.opacity = 1; $0.theme.blur = 0; $0.theme.grain = 0
        $0.theme.intensity = 0.45
      }
      compositionVariant = variant.name
      for original in originalSubviews { original.view.isHidden = variant.flat ? true : original.hidden }
      if variant.flat && canvas.superview == nil { content.addSubview(canvas, positioned: .above, relativeTo: nil) }
      canvas.isHidden = !variant.flat
      window.backgroundColor = variant.opaque ? NativePerformanceFlatCanvas.color : originalBackground
      window.isOpaque = variant.opaque
      if !variant.visible { window.orderOut(nil) }
      try record(phase: variant.name, stage: "warmup")
      try await Task.sleep(for: .seconds(3))
      try record(phase: variant.name, stage: "measuring")
      try await Task.sleep(for: .seconds(12))
      try requireEmpty(owner)
      guard window.frame == frame, window.contentView === content,
        window.isOpaque == variant.opaque, window.isVisible == variant.visible else {
        throw ShortcutError("The diagnostic composition or visibility changed during sampling.")
      }
      try record(phase: variant.name, stage: "complete")
    }
  }

  private func requireEmpty(_ owner: BrowserWindowCoordinator) throws {
    guard owner.store.state.tabs.isEmpty, owner.activePage == nil,
      !application.engine.pages.values.contains(where: { $0.ownerWindowID == owner.windowContext.id }) else {
      throw ShortcutError("The diagnostic requires an empty shell without a native page or HTML fixture.")
    }
  }

  private func record(phase: String, stage: String, error: String? = nil) throws {
    guard let path = ProcessInfo.processInfo.environment["ZACRO_PERFORMANCE_OUTPUT"] else {
      throw ShortcutError("No performance diagnostic output path was supplied.")
    }
    let owner = application.focusedCoordinator, theme = owner?.store.state.activeSpace?.theme
    let window = owner?.windowContext.window
    let frame = window?.frame ?? .zero
    var event: [String: Any] = ["phase": phase, "stage": stage,
      "timestamp": ISO8601DateFormatter().string(from: Date()), "unixTime": Date().timeIntervalSince1970,
      "systemUptime": ProcessInfo.processInfo.systemUptime, "pid": ProcessInfo.processInfo.processIdentifier,
      "startupSeconds": 5, "warmupSeconds": 3, "measurementSeconds": 12,
      "windowFrame": [frame.minX, frame.minY, frame.width, frame.height],
      "nativeWindowOpaque": window?.isOpaque == true, "windowVisible": window?.isVisible == true,
      "compositionVariant": compositionVariant,
      "focusObservationScope": "phase-transition snapshots; not continuous observation",
      "ownedNativeWindows": NSApp.windows.map { native -> [String: Any] in
        let bounds = native.frame
        return ["windowNumber": native.windowNumber, "class": NSStringFromClass(type(of: native)),
          "frame": [bounds.minX, bounds.minY, bounds.width, bounds.height],
          "isVisible": native.isVisible, "isKey": native.isKeyWindow, "isOpaque": native.isOpaque,
          "parentWindowNumber": native.parent?.windowNumber ?? -1]
      },
      "appActive": NSApp.isActive, "windowKey": owner?.windowContext.window.isKeyWindow == true,
      "sidebarVisible": owner?.store.state.settings.sidebarVisible == true,
      "ownedPageCount": application.engine.pages.values.filter { $0.ownerWindowID == owner?.windowContext.id }.count,
      "totalEnginePages": application.engine.pages.count, "desktopInputUsed": false,
      "theme": ["opacity": theme?.opacity ?? 0, "blur": theme?.blur ?? 0,
        "grain": theme?.grain ?? 0, "intensity": theme?.intensity ?? 0]]
    if let error { event["error"] = error }
    events.append(event)
    let report: [String: Any] = ["current": event, "events": events, "diagnosticOnly": true,
      "completed": phase == "finished", "failed": error != nil]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: .atomic)
    fputs("Native performance phase: \(phase) / \(stage)\n", stderr)
  }
}

/// A solid, non-SwiftUI canvas for the gated composition diagnostic only.
@MainActor private final class NativePerformanceFlatCanvas: NSView {
  static let color = NSColor(deviceWhite: 0.22, alpha: 1)
  override var isOpaque: Bool { true }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }
  private func configure() {
    autoresizingMask = [.width, .height]
    wantsLayer = true
    layer?.backgroundColor = Self.color.cgColor
  }
}
