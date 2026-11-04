import SwiftUI
import ZacroCore

/// Carries presentation inputs through a live page hierarchy without observing
/// fractional motion there. Only NativeSpaceBackdrop subscribes to viewport.
struct NativeSpaceBackdropContext {
  let viewport: NativeSpaceViewport
  let spaces: [BrowserSpace]
  let fallback: SpaceTheme
  var prefersFallback = false
}

private struct NativeSpaceBackdropContextKey: EnvironmentKey {
  static let defaultValue: NativeSpaceBackdropContext? = nil
}

extension EnvironmentValues {
  var nativeSpaceBackdropContext: NativeSpaceBackdropContext? {
    get { self[NativeSpaceBackdropContextKey.self] }
    set { self[NativeSpaceBackdropContextKey.self] = newValue }
  }
}

/// Fractional Space presentation is observed here, separately from the shell's
/// controls and rows. Each renderer receives an exact endpoint theme; moving
/// between Spaces never asks the contrast-fitting recipe for intermediate ones.
@MainActor
struct NativeSpaceBackdrop<Content: View>: View {
  @ObservedObject var viewport: NativeSpaceViewport
  var spaces: [BrowserSpace]
  var fallback: SpaceTheme
  var prefersFallback = false
  @ViewBuilder var content: (SpaceTheme) -> Content

  init(viewport: NativeSpaceViewport, spaces: [BrowserSpace], fallback: SpaceTheme,
    prefersFallback: Bool = false, @ViewBuilder content: @escaping (SpaceTheme) -> Content) {
    _viewport = ObservedObject(wrappedValue: viewport)
    self.spaces = spaces; self.fallback = fallback
    self.prefersFallback = prefersFallback; self.content = content
  }

  init(context: NativeSpaceBackdropContext, @ViewBuilder content: @escaping (SpaceTheme) -> Content) {
    self.init(viewport: context.viewport, spaces: context.spaces, fallback: context.fallback,
      prefersFallback: context.prefersFallback, content: content)
  }

  var body: some View {
    let presentation = NativeSpaceBackdropPresentation.resolve(
      blend: viewport.blend, isTracking: viewport.isTracking,
      isAnimating: viewport.isAnimating, spaces: spaces,
      fallback: fallback, prefersFallback: prefersFallback,
      selectedID: viewport.selectedID)
    ZStack {
      ForEach(presentation.layers) { layer in
        content(layer.theme)
          .opacity(layer.opacity)
          .zIndex(layer.order)
      }
    }
    // This is live view content, not a cached image or theme-only Equatable
    // wrapper: parent geometry, accessibility and environment changes continue
    // through the supplied renderer when the window or editor changes.
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Pure presentation values also allow deterministic endpoint/draft checks
/// without creating a window or claiming compositor performance measurements.
struct NativeSpaceBackdropPresentation {
  enum ID: Hashable {
    case fallback
    case space(String)
  }
  struct Layer: Identifiable, Equatable {
    let id: ID
    let theme: SpaceTheme
    let opacity: Double
    let order: Double
  }
  let layers: [Layer]

  /// Interpolate only scalar window-composition controls. The color recipes
  /// remain exact endpoints, avoiding intermediate contrast-fit derivations.
  func interpolated(_ keyPath: KeyPath<SpaceTheme, Double>) -> Double {
    guard let first = layers.first else { return 0 }
    guard layers.count > 1, let last = layers.last else { return first.theme[keyPath: keyPath] }
    let start = first.theme[keyPath: keyPath]
    return start + (last.theme[keyPath: keyPath] - start) * last.opacity
  }

  @MainActor
  static func resolve(blend: NativeSpaceViewport.Blend?, isTracking: Bool,
    isAnimating: Bool, spaces: [BrowserSpace], fallback: SpaceTheme,
    prefersFallback: Bool = false, selectedID: String? = nil) -> Self {
    // The last destination renderer remains the same view after motion ends.
    // A live draft updates that selected renderer's theme without replacing its
    // native material view simply because presentation returned to idle.
    let fallbackID = selectedID.map(ID.space) ?? .fallback
    let exactFallback = Self(layers: [Layer(id: fallbackID, theme: fallback, opacity: 1, order: 0)])
    guard !prefersFallback, isTracking || isAnimating, let blend,
      blend.progress.isFinite,
      let first = spaces.first(where: { $0.id == blend.from }),
      let last = spaces.first(where: { $0.id == blend.to }) else { return exactFallback }
    func endpoint(_ space: BrowserSpace) -> SpaceTheme {
      var value = space.theme
      value.appearance = fallback.appearance
      return value
    }
    let source = Layer(id: .space(first.id), theme: endpoint(first), opacity: 1, order: 0)
    // A held multi-Space swipe crosses integer positions before the selected
    // model Space changes. Keep that visible endpoint instead of the original
    // selected fallback, which would flash at every page boundary.
    guard first.id != last.id else { return Self(layers: [source]) }
    let target = Layer(id: .space(last.id), theme: endpoint(last),
      opacity: min(1, max(0, blend.progress)), order: 1)
    // Keep the source at full presentation opacity and overlay the destination.
    // An opaque blank-page renderer therefore stays opaque for the entire fade;
    // fading both layers out would expose the desktop at intermediate progress.
    // Space IDs retain an endpoint's view identity as it changes stack position.
    return Self(layers: [source, target])
  }
}

/// A translucent window has one final tint alpha and at most one native blur.
/// Applying each endpoint's own alpha before crossfading would stack opacity
/// and jump when the destination becomes the single idle renderer.
struct NativeSpaceWindowBackdropStyle: Equatable {
  let tintOpacity: Double
  let materialAmount: Double

  static func resolve(_ presentation: NativeSpaceBackdropPresentation,
    reduceTransparency: Bool, increasedContrast: Bool) -> Self {
    guard !reduceTransparency, !increasedContrast else {
      return Self(tintOpacity: 1, materialAmount: 0)
    }
    let requestedOpacity = presentation.interpolated(\.opacity)
    let opacity = requestedOpacity.isFinite ? min(1, max(0, requestedOpacity)) : 1
    let requestedBlur = presentation.interpolated(\.blur)
    let blur = requestedBlur.isFinite ? min(1, max(0, requestedBlur)) : 0
    return Self(tintOpacity: opacity, materialAmount: opacity < 1 ? blur : 0)
  }
}
