import AppKit
import SwiftUI

private struct NativeChromeControlContextKey: EnvironmentKey {
  static let defaultValue = ""
}
extension EnvironmentValues {
  /// Open native menus belong to the window/profile/Space that presented
  /// them, even when replacement options happen to share the same labels.
  var nativeChromeControlContext: String {
    get { self[NativeChromeControlContextKey.self] }
    set { self[NativeChromeControlContextKey.self] = newValue }
  }
}

/// Browser-owned controls share the renderer's flat surfaces, original vector
/// glyphs and dimensions. Native menu/keyboard/accessibility behavior remains.
struct NativeChromeButtonStyle: ButtonStyle {
  let colors: NativeSpacePalette
  var prominent = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: prominent ? .medium : .regular))
      .padding(.horizontal, prominent ? 12 : 10).padding(.vertical, prominent ? 8 : 7)
      .foregroundStyle(prominent ? (colors.dark ? Color(red: 43 / 255, green: 23 / 255, blue: 32 / 255) : .white) : colors.ink)
      .background(prominent ? colors.accent : hovered ? colors.hover : colors.card.opacity(0.84), in: RoundedRectangle(cornerRadius: 7))
      .overlay { if !prominent { RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line, lineWidth: 1) } }
      .contentShape(RoundedRectangle(cornerRadius: 7))
      .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
      .opacity(enabled ? 1 : 0.38)
      .onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.14), value: configuration.isPressed)
  }
}

/// CSS .setting-toggle: 31×19 track, 13px thumb and 12px travel.
struct NativeChromeToggleStyle: ToggleStyle {
  let colors: NativeSpacePalette
  var showsLabel = true
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 12) {
        if showsLabel { configuration.label.frame(maxWidth: .infinity, alignment: .leading) }
        ZStack(alignment: .leading) {
          Capsule().fill(configuration.isOn ? colors.accent : colors.surface.overlayColor(colors.muted, fraction: 0.3))
          Capsule().strokeBorder(configuration.isOn ? colors.accent : colors.muted.opacity(0.25), lineWidth: 1)
          Circle().fill(configuration.isOn ? (colors.dark ? Color(red: 43 / 255, green: 23 / 255, blue: 32 / 255) : .white) : colors.card)
            .frame(width: 13, height: 13).shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .offset(x: configuration.isOn ? 15 : 3)
        }.frame(width: 31, height: 19)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).opacity(enabled ? 1 : 0.38)
      .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.14), value: configuration.isOn)
      .accessibilityRepresentation {
        // Semantic proxy only; explicitly stop this custom style recursing.
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox).disabled(!enabled)
      }
  }
}

struct NativeChromeCheckboxStyle: ToggleStyle {
  let colors: NativeSpacePalette
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(alignment: .top, spacing: 8) {
        ZStack {
          RoundedRectangle(cornerRadius: 4).fill(configuration.isOn ? colors.accent : colors.card)
          RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? colors.accent : colors.line, lineWidth: 1)
          if configuration.isOn { NativeGlyph("check", size: 13).foregroundStyle(colors.dark ? colors.chrome : .white) }
        }.frame(width: 16, height: 16)
        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).opacity(enabled ? 1 : 0.38)
      .accessibilityRepresentation {
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox).disabled(!enabled)
      }
  }
}

struct NativeChromeDisclosureStyle: DisclosureGroupStyle {
  let colors: NativeSpacePalette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { configuration.isExpanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          configuration.label.frame(maxWidth: .infinity, alignment: .leading)
          NativeGlyph("chevronRight", size: 12).rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
        }.padding(.vertical, 4).frame(minHeight: 28).contentShape(Rectangle())
      }.buttonStyle(NativeHoverPressButtonStyle(hover: colors.hover, radius: 4, scale: 1)).foregroundStyle(colors.ink)
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      if configuration.isExpanded { configuration.content }
    }
  }
}

struct NativeChromeSelect<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [(Value, String)]
  let colors: NativeSpacePalette
  var showsLabel = true
  @Environment(\.isEnabled) private var enabled
  @Environment(\.nativeChromeControlContext) private var contextID
  private var selected: String { options.first { $0.0 == selection }?.1 ?? "" }
  var body: some View {
    HStack(spacing: 8) {
      if showsLabel { Text(title).foregroundStyle(colors.muted) }
      NativeChromeSelectButton(title: title, selected: selected,
        selectedIndex: options.firstIndex { $0.0 == selection },
        options: options.map(\.1), optionKeys: options.map { AnyHashable($0.0) },
        contextID: contextID, colors: colors, enabled: enabled) { index in
          guard options.indices.contains(index) else { return }
          selection = options[index].0
        }.frame(minHeight: 34, maxHeight: 34)
    }.font(.system(size: 12)).foregroundStyle(colors.ink).opacity(enabled ? 1 : 0.38)
  }
}

struct NativeChromeTextFieldStyle: TextFieldStyle {
  let colors: NativeSpacePalette
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.textFieldStyle(.plain).padding(.horizontal, 9).padding(.vertical, 7)
      .background(colors.card.opacity(0.84), in: RoundedRectangle(cornerRadius: 7))
      .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line, lineWidth: 1) }
  }
}

/// Use one contour for the SwiftUI pane, its shadow and the material opening.
/// The hosted Chromium layer mask is generated from this same SwiftUI contour.
struct NativePaneShape: Shape {
  var radius: CGFloat
  var animatableData: CGFloat { get { radius } set { radius = newValue } }
  func path(in rect: CGRect) -> Path {
    RoundedRectangle(cornerRadius: max(0, radius), style: .continuous).path(in: rect)
  }
}

enum NativePaneGeometry {
  static func frames(in rect: CGRect, splitRatio: Double?) -> [CGRect] {
    guard let splitRatio, splitRatio.isFinite, rect.width > 6 else { return [rect] }
    let left = (rect.width - 6) * min(1, max(0, splitRatio))
    return [CGRect(x: rect.minX, y: rect.minY, width: left, height: rect.height),
      CGRect(x: rect.minX + left + 6, y: rect.minY,
        width: rect.width - left - 6, height: rect.height)]
  }
}

struct NativeChromeProgressStyle: ProgressViewStyle {
  let colors: NativeSpacePalette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 5) {
      if let fraction = configuration.fractionCompleted {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(colors.ink.opacity(0.12))
            Capsule().fill(colors.accent).frame(width: geometry.size.width * min(1, max(0, fraction)))
          }
        }.frame(height: 3)
      } else {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
          Circle().trim(from: 0.08, to: 0.8).stroke(colors.accent, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }.frame(width: 14, height: 14)
      }
      configuration.label
      configuration.currentValueLabel
    }
  }
}

private extension Color {
  func overlayColor(_ other: Color, fraction: CGFloat) -> Color {
    Color(nsColor: NSColor(self).blended(withFraction: fraction, of: NSColor(other)) ?? NSColor(self))
  }
}
