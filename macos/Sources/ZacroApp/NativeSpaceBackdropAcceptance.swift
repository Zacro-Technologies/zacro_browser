import AppKit
import SwiftUI
import ZacroCore

/// Deterministic endpoint checks plus explicitly invoked owned offscreen render
/// checks. Neither certifies physical routing or live compositor performance.
@MainActor
enum NativeSpaceBackdropAcceptance {
  static func check() -> [String: Bool] {
    var firstTheme = SpaceTheme()
    firstTheme.primaryColor = "#DE3456"; firstTheme.opacity = 0.58
    firstTheme.grain = 0.23; firstTheme.blur = 0.44; firstTheme.appearance = "light"
    var secondTheme = SpaceTheme()
    secondTheme.primaryColor = "#3456DE"; secondTheme.intensity = 0.72
    secondTheme.opacity = 0.84; secondTheme.appearance = "dark"
    var thirdTheme = SpaceTheme()
    thirdTheme.primaryColor = "#56DE34"
    let spaces = [
      BrowserSpace(id: "first", profileID: "profile", name: "First", theme: firstTheme),
      BrowserSpace(id: "second", profileID: "profile", name: "Second", theme: secondTheme),
      BrowserSpace(id: "third", profileID: "profile", name: "Third", theme: thirdTheme),
    ]
    var draft = firstTheme
    draft.primaryColor = "#FEDCBA"; draft.opacity = 0.36; draft.appearance = "dark"
    func resolve(_ from: String = "first", _ to: String = "second", _ progress: Double = 0.4,
      tracking: Bool = true, animating: Bool = false, prefersFallback: Bool = false) -> NativeSpaceBackdropPresentation {
      NativeSpaceBackdropPresentation.resolve(blend: .init(from: from, to: to, progress: progress),
        isTracking: tracking, isAnimating: animating, spaces: spaces,
        fallback: draft, prefersFallback: prefersFallback)
    }
    let moving = resolve()
    var expectedFirst = firstTheme; expectedFirst.appearance = draft.appearance
    var expectedSecond = secondTheme; expectedSecond.appearance = draft.appearance
    let idle = resolve(tracking: false)
    let editor = resolve(prefersFallback: true)
    let integer = resolve("second", "second", 0)
    let later = resolve("second", "third", 0.01)
    let sourceAlpha = moving.layers.first?.opacity ?? 0
    let targetAlpha = moving.layers.last?.opacity ?? 0
    let viewport = NativeSpaceViewport(automaticallyAdvance: false)
    viewport.synchronize(ids: spaces.map(\.id), selectedID: "first", motionScale: 1, at: 0)
    viewport.track(progress: 0.4)
    let draftContext = NativeSpaceBackdropContext(viewport: viewport, spaces: spaces,
      fallback: draft, prefersFallback: true)
    var environment = EnvironmentValues()
    let contextInitiallyNil = environment.nativeSpaceBackdropContext == nil
    environment.nativeSpaceBackdropContext = draftContext
    let carried = environment.nativeSpaceBackdropContext
    let contextPresentation = NativeSpaceBackdropPresentation.resolve(blend: viewport.blend,
      isTracking: viewport.isTracking, isAnimating: viewport.isAnimating,
      spaces: carried?.spaces ?? [], fallback: carried?.fallback ?? SpaceTheme(),
      prefersFallback: carried?.prefersFallback ?? false, selectedID: viewport.selectedID)
    let snap = NativeSpaceViewport(automaticallyAdvance: false)
    snap.synchronize(ids: spaces.map(\.id), selectedID: "first", motionScale: 1, at: 0)
    snap.track(progress: 0.7)
    snap.settle(selectedID: "second", duration: 0.2, motionScale: 1, at: 1)
    let movingTarget = NativeSpaceBackdropPresentation.resolve(blend: snap.blend,
      isTracking: snap.isTracking, isAnimating: snap.isAnimating, spaces: spaces,
      fallback: expectedSecond, selectedID: snap.selectedID).layers.last
    snap.advance(at: 1.2)
    let snapped = NativeSpaceBackdropPresentation.resolve(blend: snap.blend,
      isTracking: snap.isTracking, isAnimating: snap.isAnimating, spaces: spaces,
      fallback: expectedSecond, selectedID: snap.selectedID)
    let selectedDraft = NativeSpaceBackdropPresentation.resolve(blend: snap.blend,
      isTracking: snap.isTracking, isAnimating: snap.isAnimating, spaces: spaces,
      fallback: draft, prefersFallback: true, selectedID: snap.selectedID)
    let normalWindow = NativeSpaceWindowBackdropStyle.resolve(moving,
      reduceTransparency: false, increasedContrast: false)
    let reducedWindow = NativeSpaceWindowBackdropStyle.resolve(moving,
      reduceTransparency: true, increasedContrast: false)
    let contrastWindow = NativeSpaceWindowBackdropStyle.resolve(moving,
      reduceTransparency: false, increasedContrast: true)
    return [
      "space_backdrop_uses_exact_endpoint_recipes": moving.layers.count == 2
        && moving.layers[0].theme == expectedFirst && moving.layers[1].theme == expectedSecond,
      "space_backdrop_does_not_blend_theme_values": moving.layers[0].theme.primaryColor == firstTheme.primaryColor
        && moving.layers[1].theme.primaryColor == secondTheme.primaryColor
        && moving.layers[0].theme.grain == firstTheme.grain && moving.layers[1].theme.intensity == secondTheme.intensity,
      "space_backdrop_preserves_opaque_source_presentation": sourceAlpha == 1 && targetAlpha == 0.4
        && sourceAlpha + targetAlpha * (1 - sourceAlpha) == 1,
      "space_backdrop_obeys_global_appearance": moving.layers.allSatisfy { $0.theme.appearance == draft.appearance },
      "space_backdrop_idle_uses_exact_editing_fallback": idle.layers.count == 1
        && idle.layers[0].id == .fallback && idle.layers[0].theme == draft,
      "space_backdrop_live_draft_overrides_motion": editor.layers.count == 1
        && editor.layers[0].id == .fallback && editor.layers[0].theme == draft,
      "space_backdrop_integer_crossing_keeps_visible_endpoint": integer.layers.count == 1
        && integer.layers[0].id == .space("second") && integer.layers[0].theme == expectedSecond,
      "space_backdrop_endpoint_identity_survives_boundary": moving.layers[1].id == later.layers[0].id
        && integer.layers[0].id == later.layers[0].id,
      "space_backdrop_snap_animation_uses_endpoints": resolve(tracking: false, animating: true).layers.count == 2,
      "space_backdrop_clamps_crossfade_opacity": resolve("first", "second", -2).layers[1].opacity == 0
        && resolve("first", "second", 2).layers[1].opacity == 1,
      "space_backdrop_missing_endpoint_uses_safe_fallback": resolve("missing", "second").layers[0].theme == draft,
      "space_backdrop_nonfinite_progress_uses_safe_fallback": resolve("first", "second", .nan).layers[0].theme == draft,
      "space_backdrop_no_blend_uses_exact_fallback": NativeSpaceBackdropPresentation.resolve(blend: nil,
        isTracking: true, isAnimating: false, spaces: spaces, fallback: draft).layers[0].theme == draft,
      "space_backdrop_context_is_optional_and_preserves_owner": contextInitiallyNil
        && carried?.viewport === viewport && carried?.spaces == spaces,
      "space_backdrop_context_retains_exact_live_draft": carried?.fallback == draft
        && carried?.prefersFallback == true && contextPresentation.layers.count == 1
        && contextPresentation.layers[0].theme == draft,
      "space_backdrop_snap_completion_retains_destination_renderer": !snap.isAnimating
        && movingTarget?.id == .space("second") && snapped.layers.count == 1
        && snapped.layers[0].id == movingTarget?.id && snapped.layers[0].theme == expectedSecond,
      "space_backdrop_selected_draft_keeps_renderer_identity": selectedDraft.layers.count == 1
        && selectedDraft.layers[0].id == snapped.layers[0].id && selectedDraft.layers[0].theme == draft,
      "space_window_backdrop_interpolates_only_composition_scalars": abs(normalWindow.tintOpacity - 0.684) < 0.000_001
        && abs(normalWindow.materialAmount - 0.264) < 0.000_001,
      "space_window_backdrop_reduce_transparency_disables_material": reducedWindow.tintOpacity == 1
        && reducedWindow.materialAmount == 0,
      "space_window_backdrop_increased_contrast_disables_material": contrastWindow.tintOpacity == 1
        && contrastWindow.materialAmount == 0,
    ]
  }

  /// Draw the real SwiftUI/AppKit hierarchy into native transparent bitmaps.
  /// The windows are never ordered or activated; Chromium content is absent.
  /// Blur is zero because desktop material composition needs a separate live
  /// compositor check, while tint alpha must remain exact without that effect.
  static func renderedAlphaChecks() async throws -> [String: Bool] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance") else {
      throw RenderFailure("Backdrop rendering requires the disposable integration runner.")
    }
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else {
      throw RenderFailure("The half-opacity render regression requires standard transparency/contrast; opaque accessibility overrides have separate deterministic checks.")
    }
    let originalKey = NSApp.keyWindow
    var reports: [[String: Any]] = []
    var results: [String: Bool] = [:]
    for equalColors in [true, false] {
      for opaque in [false, true] {
        let label = "\(opaque ? "empty-canvas" : "window")-\(equalColors ? "equal" : "different")"
        let model = RenderModel(equalColors: equalColors)
        let size = NSSize(width: 128, height: 96)
        let view = NSHostingView(rootView: RenderFixture(model: model, opaque: opaque)
          .environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false
        window.backgroundColor = .clear; window.hasShadow = false
        window.appearance = NSAppearance(named: .aqua)
        window.identifier = NSUserInterfaceItemIdentifier("ZacroBackdropAlphaAcceptance:" + UUID().uuidString)
        window.contentView = view
        defer { window.close() }
        view.frame = NSRect(origin: .zero, size: size)
        var samples: [String: [Pixel]] = [:]
        for stage in ["0", "0.5", "0.99", "1", "idle", "draft"] {
          if stage == "draft" {
            var draft = model.fallback
            draft.opacity = 0.36; draft.primaryColor = "#FEDCBA"; draft.appearance = "dark"
            model.fallback = draft; model.prefersFallback = true
          } else if stage == "idle" {
            model.fallback = model.spaces[1].theme
            model.viewport.settle(selectedID: model.spaces[1].id, duration: 0,
              motionScale: 0, at: 1)
          } else if let progress = Double(stage), progress > 0 {
            model.viewport.track(progress: progress)
          }
          await Task.yield()
          try await Task.sleep(for: .milliseconds(30))
          guard window.contentView === view, !window.isVisible, NSApp.keyWindow === originalKey else {
            throw RenderFailure("The exact unpresented backdrop host changed or took keyboard focus.")
          }
          view.layoutSubtreeIfNeeded()
          guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds), bitmap.hasAlpha,
            bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            throw RenderFailure("The actual backdrop did not provide an alpha-capable native bitmap.")
          }
          if let bytes = bitmap.bitmapData {
            bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
          }
          view.cacheDisplay(in: view.bounds, to: bitmap)
          let pixels = try [0.25, 0.5, 0.75].flatMap { x in
            try [0.25, 0.5, 0.75].map { y -> Pixel in
              guard let color = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                y: Int(Double(bitmap.pixelsHigh) * y))?.usingColorSpace(.sRGB) else {
                throw RenderFailure("A native backdrop alpha sample could not be read.")
              }
              return Pixel(red: Double(color.redComponent), green: Double(color.greenComponent),
                blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
            }
          }
          samples[stage] = pixels
          reports.append(["case": label, "stage": stage, "pixels": pixels.map(\.record),
            "pixelSize": [bitmap.pixelsWide, bitmap.pixelsHigh], "windowPresented": window.isVisible,
            "nativeMaterialViewCount": materialCount(in: view)])
        }
        let expectedAlpha = opaque ? 1.0 : 0.5
        results["space_\(opaque ? "empty" : "window")_rendered_\(equalColors ? "equal" : "different")_alpha_continuity"] =
          samples.count == 6 && samples.filter { $0.key != "draft" }.values.flatMap { $0 }
            .allSatisfy { abs($0.alpha - expectedAlpha) < 0.02 }
        results["space_\(opaque ? "empty" : "window")_rendered_\(equalColors ? "equal" : "different")_live_draft_alpha"] =
          samples["draft"]?.allSatisfy { abs($0.alpha - (opaque ? 1 : 0.36)) < 0.02 } == true
        if let endpoint = samples["1"], let idle = samples["idle"], let start = samples["0"], let middle = samples["0.5"] {
          results["space_\(opaque ? "empty" : "window")_rendered_\(equalColors ? "equal" : "different")_idle_matches_endpoint"] =
            zip(endpoint, idle).allSatisfy { pair in pair.0.distance(to: pair.1) < 0.025 }
          if !equalColors {
            // Catch a stale/undrawn bitmap that otherwise appears to keep the
            // previous half-alpha image through every requested progress value.
            results["space_\(opaque ? "empty" : "window")_rendered_different_tints_actually_update"] =
              zip(start, endpoint).contains { pair in pair.0.colorDistance(to: pair.1) > 0.025 }
              && zip(start, middle).contains { pair in pair.0.colorDistance(to: pair.1) > 0.01 }
          }
        }
        results["space_\(opaque ? "empty" : "window")_rendered_\(equalColors ? "equal" : "different")_zero_blur_has_no_material"] = materialCount(in: view) == 0
      }
    }
    let materialModel = RenderModel(equalColors: false, blur: 0.4)
    let materialHost = NSHostingView(rootView: RenderFixture(model: materialModel, opaque: false)
      .environment(\.colorScheme, .light).frame(width: 128, height: 96))
    materialHost.sizingOptions = []
    let materialWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 96),
      styleMask: [.borderless], backing: .buffered, defer: false)
    materialWindow.isReleasedWhenClosed = false; materialWindow.isOpaque = false
    materialWindow.backgroundColor = .clear; materialWindow.contentView = materialHost
    defer { materialWindow.close() }
    materialHost.frame = NSRect(x: 0, y: 0, width: 128, height: 96)
    var firstMaterial: NSVisualEffectView?
    var materialIdentityPreserved = true
    for stage in [0.0, 0.5, 0.99, 1.0, 2.0] {
      if stage == 2 {
        materialModel.fallback = materialModel.spaces[1].theme
        materialModel.viewport.settle(selectedID: materialModel.spaces[1].id,
          duration: 0, motionScale: 0, at: 1)
      } else if stage > 0 { materialModel.viewport.track(progress: stage) }
      await Task.yield()
      try await Task.sleep(for: .milliseconds(30))
      materialHost.layoutSubtreeIfNeeded()
      let materials = materialViews(in: materialHost)
      if firstMaterial == nil { firstMaterial = materials.first }
      materialIdentityPreserved = materialIdentityPreserved && materials.count == 1
        && materials.first === firstMaterial && !materialWindow.isVisible
    }
    results["space_window_backdrop_retains_one_actual_native_material"] = materialIdentityPreserved
      && firstMaterial != nil
    guard NSApp.keyWindow === originalKey else { throw RenderFailure("Backdrop rendering changed keyboard focus.") }
    if let reportPath = ProcessInfo.processInfo.environment["ZACRO_ACCEPTANCE_OUTPUT"] {
      let output = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        .appendingPathComponent("space-backdrop-alpha-render.json")
      try JSONSerialization.data(withJSONObject: ["ownedOffscreenNativeRender": true,
        "desktopScreenshot": false, "materialDesktopCompositingVerified": false,
        "samples": reports, "checks": results], options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
    }
    return results
  }

  private struct Pixel {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    var record: [String: Double] { ["red": red, "green": green, "blue": blue, "alpha": alpha] }
    func colorDistance(to other: Self) -> Double {
      max(abs(red - other.red), max(abs(green - other.green), abs(blue - other.blue)))
    }
    func distance(to other: Self) -> Double { max(abs(alpha - other.alpha), colorDistance(to: other)) }
  }
  @MainActor private final class RenderModel: ObservableObject {
    let viewport = NativeSpaceViewport(automaticallyAdvance: false)
    let spaces: [BrowserSpace]
    @Published var fallback: SpaceTheme
    @Published var prefersFallback = false
    init(equalColors: Bool, blur: Double = 0) {
      var first = SpaceTheme()
      first.primaryColor = "#DE3456"; first.secondaryColor = "#EFAB56"
      first.intensity = 0.8; first.opacity = 0.5; first.blur = blur; first.grain = 0; first.appearance = "light"
      var second = first
      if !equalColors { second.primaryColor = "#3456DE"; second.secondaryColor = "#56ABEF" }
      spaces = [BrowserSpace(id: "alpha-first", profileID: "alpha-profile", name: "First", theme: first),
        BrowserSpace(id: "alpha-second", profileID: "alpha-profile", name: "Second", theme: second)]
      fallback = first
      viewport.synchronize(ids: spaces.map(\.id), selectedID: spaces[0].id, motionScale: 0, at: 0)
    }
  }
  private struct RenderFixture: View {
    @ObservedObject var model: RenderModel
    let opaque: Bool
    var body: some View {
      if opaque {
        NativeEmptyPageBackground(theme: model.fallback)
          .environment(\.nativeSpaceBackdropContext, NativeSpaceBackdropContext(viewport: model.viewport,
            spaces: model.spaces, fallback: model.fallback, prefersFallback: model.prefersFallback))
      } else {
        NativeSpaceWindowBackdrop(viewport: model.viewport, spaces: model.spaces, fallback: model.fallback,
          prefersFallback: model.prefersFallback)
      }
    }
  }
  private static func materialCount(in view: NSView) -> Int {
    materialViews(in: view).count
  }
  private static func materialViews(in view: NSView) -> [NSVisualEffectView] {
    ((view as? NSVisualEffectView).map { [$0] } ?? []) + view.subviews.flatMap { materialViews(in: $0) }
  }
  private struct RenderFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
