import AppKit
import SwiftUI
import ZacroCore

/// Measure the real editor in an owned, unpresented AppKit host. These checks
/// exercise SwiftUI layout and drawing without taking focus or sending input.
@MainActor
enum NativeThemeAlignmentAcceptance {
  static func run() async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance") else {
      throw Failure("Theme alignment requires the disposable integration runner")
    }
    let originalKeyWindow = NSApp.keyWindow
    let model = Model()
    let size = NSSize(width: 424, height: 800)
    let root = NSHostingView(rootView: Editor(model: model)
      .environment(\.nativeInterfaceAlignmentRecording, true)
      .frame(width: size.width, height: size.height, alignment: .top))
    root.sizingOptions = []
    root.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("ZacroThemeAlignmentAcceptance:" + UUID().uuidString)
    window.contentView = root
    defer { window.close() }

    let cases: [(name: String, primary: String, secondary: String)] = [
      ("equal-saturated", "#00FFFF", "#00FFFF"),
      ("equal-low-hue-endpoint", "#FF0000", "#FF0000"),
      ("equal-high-hue-endpoint", "#FF0001", "#FF0001"),
      ("saturation-extremes", "#FFFFFF", "#FF0000"),
      ("reversed-saturation-extremes", "#FF0000", "#FFFFFF"),
    ]
    for sample in cases {
      var theme = model.theme
      theme.primaryColor = sample.primary; theme.secondaryColor = sample.secondary
      model.theme = theme
      let end = ProcessInfo.processInfo.systemUptime + 3
      var previous: [String: CGRect]?
      var stable = 0
      var geometry: [String: CGRect]?
      var diagnostic = ""
      while ProcessInfo.processInfo.systemUptime < end {
        try Task.checkCancellation()
        guard window.contentView === root, root.window === window, !window.isVisible else {
          throw Failure("The exact owned theme host changed")
        }
        root.layoutSubtreeIfNeeded()
        let snapshot = frames(in: root)
        diagnostic = snapshot.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        if let measured = uniqueFrames(snapshot),
          wells(in: root).map({ $0.accessibilityLabel() == "Primary" ? ThemeColor.hex($0.color) : nil })
            .compactMap({ $0 }) == [sample.primary],
          wells(in: root).map({ $0.accessibilityLabel() == "Secondary" ? ThemeColor.hex($0.color) : nil })
            .compactMap({ $0 }) == [sample.secondary] {
          stable = previous == measured ? stable + 1 : 0
          previous = measured
          if stable >= 2 { geometry = measured; break }
        } else { previous = nil; stable = 0 }
        try await Task.sleep(for: .milliseconds(15))
      }
      guard geometry != nil else {
        throw Failure("The real editor did not settle for \(sample.name): \(diagnostic)")
      }
      guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds),
        bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
        throw Failure("The actual editor could not render for \(sample.name)")
      }
      root.cacheDisplay(in: root.bounds, to: bitmap)
      guard let measured = uniqueFrames(frames(in: root)),
        let region = measured["theme-puck-region"],
        let primary = measured["theme-puck-primary"], let secondary = measured["theme-puck-secondary"] else {
        throw Failure("The real editor lost its geometry during rendering")
      }
      let appearances = ["system", "light", "dark"].compactMap { measured["theme-appearance-" + $0] }
      guard appearances.count == 3,
        [primary, secondary].allSatisfy({ puck in
          region.insetBy(dx: -0.5, dy: -0.5).contains(puck)
            && appearances.allSatisfy { !$0.intersects(puck) }
        }), model.theme.primaryColor == sample.primary, model.theme.secondaryColor == sample.secondary else {
        throw Failure("A real color puck was clipped, covered an appearance control, or changed its chosen color for \(sample.name): \(diagnostic)")
      }
      fputs("Native theme alignment \(sample.name): \(diagnostic)\n", stderr)
    }
    guard !window.isVisible, NSApp.keyWindow === originalKeyWindow else {
      throw Failure("The unpresented theme layout host changed native keyboard focus")
    }
    return ["themeEqualSaturatedPucksStayBelowActualAppearanceControls",
      "themePucksRemainInsideTheirActualRegionAtBothHueEndpoints",
      "themePucksRemainInsideTheirActualRegionAtSaturationExtremes",
      "themePuckLayoutPreservesExactChosenColorsInHostedNativeWells"]
  }

  private static let identifiers = ["theme-puck-region", "theme-puck-primary", "theme-puck-secondary",
    "theme-appearance-system", "theme-appearance-light", "theme-appearance-dark"]

  private static func uniqueFrames(_ values: [String: [CGRect]]) -> [String: CGRect]? {
    var result: [String: CGRect] = [:]
    for id in identifiers {
      guard let frames = values[id], frames.count == 1, let frame = frames.first,
        frame.width > 0, frame.height > 0,
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
      result[id] = frame
    }
    return result
  }

  private static func frames(in root: NSView) -> [String: [CGRect]] {
    var result: [String: [CGRect]] = [:], pending = [root]
    while let view = pending.popLast() {
      if let marker = view as? NativeInterfaceAlignmentFrame, let id = marker.identifier?.rawValue,
        identifiers.contains(id), marker.window === root.window, !marker.isHiddenOrHasHiddenAncestor {
        result[id, default: []].append(marker.convert(marker.bounds, to: root))
      }
      pending += view.subviews
    }
    return result
  }

  private static func wells(in root: NSView) -> [NativeThemeColorWellControl] {
    var result: [NativeThemeColorWellControl] = [], pending = [root]
    while let view = pending.popLast() {
      if let well = view as? NativeThemeColorWellControl, well.window === root.window { result.append(well) }
      pending += view.subviews
    }
    return result
  }

  private final class Model: ObservableObject {
    @Published var theme = SpaceTheme()
  }
  private struct Editor: View {
    @ObservedObject var model: Model
    var body: some View { ThemeEditor(theme: $model.theme) }
  }
  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Native theme alignment failed: " + message }
  }
}
