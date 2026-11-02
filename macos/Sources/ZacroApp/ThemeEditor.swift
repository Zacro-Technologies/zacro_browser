import AppKit
import SwiftUI
import ZacroCore

/// The same color recipe as renderer/theme.js, including contrast-fitting.
/// Cache derivations because the palette is shared by every sidebar row.
struct NativeSpacePalette {
  let ink: Color
  let muted: Color
  let accent: Color
  let chrome: Color
  let primary: Color
  let secondary: Color
  let card: Color
  let dark: Bool
  private static let cache = NSCache<NSString, CachedPalette>()
  private final class CachedPalette: NSObject {
    let value: NativeSpacePalette
    init(_ value: NativeSpacePalette) { self.value = value }
  }

  init(theme: SpaceTheme, dark: Bool, increasedContrast: Bool = false) {
    let key = "\(theme.primaryColor):\(theme.secondaryColor):\(theme.intensity):\(theme.grain):\(dark):\(increasedContrast)" as NSString
    if let cached = Self.cache.object(forKey: key) { self = cached.value; return }
    self.dark = dark
    let primary = Self.rgb(theme.primaryColor)
    let secondary = Self.rgb(theme.secondaryColor)
    let intensity = min(1, max(0, theme.intensity))
    let surface = Self.rgb(dark ? "#222425" : "#f8f7f4")
    let card = Self.rgb(dark ? "#363839" : "#ffffff")
    let ink = Self.mix(Self.rgb(dark ? "#eeedeb" : "#302f2d"), Self.rgb(dark ? "#ffffff" : "#151219"), intensity)
    let muted = Self.mix(Self.rgb(dark ? "#bfb7c4" : "#574c59"), Self.rgb(dark ? "#f5f0fa" : "#211c23"), intensity)
    let noiseAlpha = min(1, max(0, theme.grain)) * 0.18 * 0.7
    let endpoint = Array(repeating: dark ? 0.0 : 255.0, count: 3)
    let noise = Array(repeating: dark ? 255.0 : 0.0, count: 3)
    func tone(_ value: [Double]) -> [Double] {
      let edge = dark ? value.max()! : value.min()!
      let amount = dark ? (edge > 61 ? 1 - 61 / edge : 0) : (edge < 208 ? (208 - edge) / (255 - edge) : 0)
      let bounded = Self.mix(value, endpoint, amount).map { dark ? floor($0) : ceil($0) }
      let colorful = Self.mix(bounded, value, intensity)
      var low = 0.0, high = 1.0
      for _ in 0..<24 {
        let middle = (low + high) / 2
        let background = Self.mix(Self.mix(colorful, endpoint, middle), noise, noiseAlpha)
        if Self.contrast(muted.map { $0.rounded() }, background) >= 5.1 + intensity * 0.9 { high = middle } else { low = middle }
      }
      return Self.mix(colorful, endpoint, high).map { dark ? floor($0) : ceil($0) }
    }
    let chrome = tone(Self.mix(Self.rgb(dark ? "#28262d" : "#e9e5e9"), primary, (dark ? 0.18 : 0.19) + intensity * 0.78))
    let tintPrimary = tone(Self.mix(surface, primary, 0.3 + intensity * 0.7))
    let tintSecondary = tone(Self.mix(surface, secondary, 0.28 + intensity * 0.72))
    let hover = tone(Self.mix(Self.rgb(dark ? "#343637" : "#deddd8"), primary, dark ? 0.06 : 0.05))
    let accentSoft = tone(dark ? primary.map { $0 * 0.35 + 25 } : Self.mix([255, 255, 255], primary, 0.15))
    var surfaces = [chrome, tintPrimary, tintSecondary, hover, accentSoft, surface, card]
    for first in [chrome, tintPrimary, tintSecondary] {
      for second in [chrome, tintPrimary, tintSecondary] {
        for amount in [0.25, 0.5, 0.75] { surfaces.append(Self.mix(first, second, amount)) }
      }
    }
    let backgrounds = surfaces.flatMap { [Self.mix($0, [0, 0, 0], noiseAlpha), Self.mix($0, [255, 255, 255], noiseAlpha)] }
    let accentInk = Self.rgb(dark ? "#2b1720" : "#ffffff")
    let originalAccent = (dark ? Self.mix(primary, [255, 255, 255], 0.48) : primary).map { $0.rounded() }
    let accentEndpoint = Array(repeating: dark ? 255.0 : 0.0, count: 3)
    func readable(_ candidate: [Double]) -> Bool {
      Self.contrast(candidate, accentInk) >= 4.5 && backgrounds.allSatisfy { background in
        Self.contrast(candidate, background) >= 4.65
      }
    }
    var fittedAccent = originalAccent
    if !readable(originalAccent) {
      var low = 0.0, high = 1.0
      for _ in 0..<24 {
        let middle = (low + high) / 2
        if readable(Self.mix(originalAccent, accentEndpoint, middle).map { $0.rounded() }) { high = middle } else { low = middle }
      }
      fittedAccent = Self.mix(originalAccent, accentEndpoint, high).map { $0.rounded() }
    }
    self.ink = Self.color(ink.map { $0.rounded() })
    self.muted = Self.color((increasedContrast ? ink : muted).map { $0.rounded() })
    self.accent = Self.color(fittedAccent)
    self.chrome = Self.color(chrome)
    self.primary = Self.color(tintPrimary)
    self.secondary = Self.color(tintSecondary)
    self.card = Self.color(card)
    Self.cache.countLimit = 32
    Self.cache.setObject(CachedPalette(self), forKey: key)
  }
  private static func rgb(_ value: String) -> [Double] {
    let color = ThemeColor.nsColor(value).usingColorSpace(.sRGB)!
    return [color.redComponent, color.greenComponent, color.blueComponent].map { Double($0) * 255 }
  }
  private static func mix(_ first: [Double], _ second: [Double], _ amount: Double) -> [Double] {
    zip(first, second).map { $0 * (1 - amount) + $1 * amount }
  }
  private static func contrast(_ first: [Double], _ second: [Double]) -> Double {
    func luminance(_ channels: [Double]) -> Double {
      zip(channels, [0.2126, 0.7152, 0.0722]).reduce(0) { result, pair in
        let value = pair.0 / 255
        return result + (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)) * pair.1
      }
    }
    let a = luminance(first), b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
  private static func color(_ channels: [Double]) -> Color {
    Color(.sRGB, red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255, opacity: 1)
  }
}

/// The original interface only outlines selections when macOS requests more
/// contrast. Ordinary and drag presentations keep their translucent fill.
struct NativeSelectionContrast: ViewModifier {
  let selected: Bool
  let color: Color
  let radius: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    content.overlay {
      if selected && contrast == .increased {
        RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: 1)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
  }
}

private struct NativeThemeTint: View {
  var theme: SpaceTheme
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    let dark = theme.appearance == "dark" || (theme.appearance == "system" && colorScheme == .dark)
    let colors = NativeSpacePalette(theme: theme, dark: dark)
    GeometryReader { geometry in
      let dx = sin(155 * Double.pi / 180), dy = -cos(155 * Double.pi / 180)
      let width = max(1, geometry.size.width), height = max(1, geometry.size.height)
      let length = abs(width * dx) + abs(height * dy)
      ZStack {
        LinearGradient(stops: [
          .init(color: colors.chrome, location: 0),
          .init(color: colors.secondary, location: min(1, max(0, theme.blend))),
          .init(color: colors.chrome, location: 1),
        ], startPoint: UnitPoint(x: 0.5 - dx * length / width / 2, y: 0.5 - dy * length / height / 2),
          endPoint: UnitPoint(x: 0.5 + dx * length / width / 2, y: 0.5 + dy * length / height / 2))
        // CSS radial-gradient(ellipse at 5% 15%, primary, transparent 68%).
        // Farthest-corner radii are the farthest-side radii multiplied by √2.
        EllipticalGradient(colors: [colors.primary, .clear], center: .center, endRadiusFraction: 0.5)
          .frame(width: width * 0.95 * sqrt(2) * 0.68 * 2, height: height * 0.85 * sqrt(2) * 0.68 * 2)
          .position(x: width * 0.05, y: height * 0.15)
        Rectangle().fill(ImagePaint(image: Image(nsImage: ThemeNoise.image), scale: 0.5))
          .opacity(theme.grain * 0.18 * 0.7)
      }.frame(width: width, height: height).clipped()
    }
  }
}

/// The window and theme editor share the tint/texture recipe. Transparency still
/// reveals each surface's actual backdrop: the desktop or the editor popover.
struct NativeThemeBackground: View {
  var theme: SpaceTheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    ZStack {
      if !reduceTransparency && contrast != .increased && theme.opacity < 1 && theme.blur > 0 {
        ThemeMaterial(amount: theme.blur)
      }
      NativeThemeTint(theme: theme).opacity(reduceTransparency || contrast == .increased ? 1 : theme.opacity)
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// An opaque empty canvas uses the Space colors without stacking another blur.
struct NativeEmptyPageBackground: View {
  var theme: SpaceTheme
  @Environment(\.presentedSpaceTheme) private var presented
  var body: some View {
    NativeThemeTint(theme: presented ?? theme).allowsHitTesting(false).accessibilityHidden(true)
  }
}

private struct ThemeMaterial: NSViewRepresentable {
  var amount: Double
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .underWindowBackground
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.alphaValue = min(1, max(0, amount))
  }
}

struct ThemeEditor: View {
  @Binding var theme: SpaceTheme
  var identity: AnyView? = nil
  var canSave = true
  var errorMessage: String?
  var saveTitle = "Save changes"
  var motionScale = 1.0
  var onSave: () -> Void = {}
  var onCancel: () -> Void = {}
  @State private var presetPage = 0
  @State private var selectedPrimary = true
  @State private var textureExpanded = true
  @State private var glassExpanded = false
  @State private var primaryValid = true
  @State private var secondaryValid = true
  @State private var puckDrag: (primary: Bool, hue: CGFloat, saturation: CGFloat, brightness: CGFloat, detent: Int)?
  @FocusState private var focusedPuck: Bool?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  private var colors: NativeSpacePalette {
    NativeSpacePalette(theme: theme, dark: theme.appearance == "dark"
      || (theme.appearance == "system" && colorScheme == .dark), increasedContrast: contrast == .increased)
  }
  private let presets = [
    "#9D4460", "#416958", "#486786", "#A56545", "#786298", "#59646E", "#CF667D", "#B68535", "#4F9485", "#6192BD", "#A466B5", "#353D60",
  ]
  private let presetNames = ["Berry", "Forest", "Ocean", "Clay", "Lavender", "Slate", "Rose", "Amber", "Mint", "Sky", "Orchid", "Ink"]
  private var valid: Bool { canSave && primaryValid && secondaryValid }
  private var pagingAnimation: Animation? { reduceMotion || motionScale <= 0 ? nil : .easeOut(duration: 0.14 * motionScale) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(saveTitle == "Create Space" ? "New Space" : "Customize Space").font(.system(size: 14, weight: .semibold))
        Spacer()
        Button(action: onCancel) { NativeGlyph("xmark").frame(width: 24, height: 24) }
          .buttonStyle(.plain).help("Close").accessibilityLabel("Close theme editor")
      }.padding(.horizontal, 18).padding(.vertical, 12)
      controls
      if let errorMessage {
        Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 8)
          .accessibilityAddTraits(.updatesFrequently)
      }
      HStack {
        Button("Cancel", action: onCancel).buttonStyle(.plain).keyboardShortcut(.cancelAction)
          .padding(.horizontal, 12).padding(.vertical, 7).background(colors.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        Spacer()
        Button(action: onSave) {
          Text(saveTitle).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(colors.dark ? Color(red: 43 / 255, green: 23 / 255, blue: 32 / 255) : .white)
            .background(colors.accent.opacity(valid ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!valid)
      }.padding(.horizontal, 14).padding(.vertical, 12)
    }.foregroundStyle(colors.ink).tint(colors.accent)
      .background { NativeControlSurface().overlay(colors.chrome.opacity(0.32)) }
      .background { NativeThemeScrollbars().frame(width: 0, height: 0) }
      .onAppear { if saveTitle != "Create Space" { focusedPuck = true } }
  }
  private var controls: some View {
    ScrollView {
      VStack(spacing: 12) {
        if saveTitle == "Create Space", let identity { identity }
        colorField
        HStack(spacing: 8) {
          ThemeColorWell(title: "Primary", hex: $theme.primaryColor, valid: $primaryValid, selected: selectedPrimary) {
            selectedPrimary = true
          }
          ThemeColorWell(title: "Secondary", hex: $theme.secondaryColor, valid: $secondaryValid, selected: !selectedPrimary)
          { selectedPrimary = false }
        }
        ScrollViewReader { reader in
          HStack(spacing: 6) {
            Button { presetPage = max(0, presetPage - 4); withAnimation(pagingAnimation) { reader.scrollTo(presetPage, anchor: .leading) } } label: { NativeGlyph("chevronLeft").frame(width: 20, height: 30) }.buttonStyle(.plain).help("Previous colors")
            ScrollView(.horizontal) {
              HStack(spacing: 9) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, hex in
                  Button {
                    if selectedPrimary { theme.primaryColor = hex } else { theme.secondaryColor = hex }
                    ThemeHaptics.tick()
                  } label: {
                    let selected = hex.caseInsensitiveCompare(selectedPrimary ? theme.primaryColor : theme.secondaryColor) == .orderedSame
                    Circle().fill(Color(nsColor: ThemeColor.nsColor(hex)))
                      .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
                      .overlay(Circle().strokeBorder(colors.accent.opacity(selected ? 1 : 0), lineWidth: 2))
                      .frame(width: 30, height: 30)
                  }.buttonStyle(.plain).help("\(presetNames[index]) · \(hex)").accessibilityLabel(presetNames[index])
                    .accessibilityValue(hex)
                    .accessibilityAddTraits(hex.caseInsensitiveCompare(selectedPrimary ? theme.primaryColor : theme.secondaryColor) == .orderedSame ? [.isSelected] : [])
                    .id(index)
                }
              }.scrollTargetLayout()
            }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
              .frame(width: 8 * 30 + 7 * 9)
            Button { presetPage = min(max(0, presets.count - 8), presetPage + 4); withAnimation(pagingAnimation) { reader.scrollTo(presetPage, anchor: .leading) } } label: { NativeGlyph("chevronRight").frame(width: 20, height: 30) }.buttonStyle(.plain).help("More colors")
          }.frame(maxWidth: .infinity)
        }

        Divider()
        if reduceTransparency {
          Text("Reduce Transparency is enabled in macOS.").font(.caption).foregroundStyle(
            .secondary)
        }
        DisclosureGroup("Gradient & texture", isExpanded: $textureExpanded) {
          HStack(alignment: .center, spacing: 14) {
            ThemeSlider(title: "Color intensity", value: $theme.intensity, colors: colors)
            HStack(spacing: 12) {
              ThemeDial(title: "Color blend", value: $theme.blend)
              ThemeDial(title: "Grain", value: $theme.grain, displayMaximum: 200)
            }.frame(width: 200)
          }.padding(.top, 10)
        }
        Divider()
        DisclosureGroup("Glass & transparency", isExpanded: $glassExpanded) {
          VStack(spacing: 12) {
            ThemeSlider(title: "Window tint opacity", value: $theme.opacity, colors: colors).disabled(reduceTransparency)
            ThemeSlider(title: "Background blur", value: $theme.blur, colors: colors, steps: 32).disabled(reduceTransparency)
          }.padding(.top, 10)
        }
        if saveTitle != "Create Space", let identity { Divider(); identity }
      }.font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 12)
    }
    .scrollIndicators(.hidden)
    .frame(width: 424, height: min(640, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 190)))
    .foregroundStyle(colors.ink).tint(colors.accent)
    .preferredColorScheme(theme.appearance == "dark" ? .dark : theme.appearance == "light" ? .light : nil)
    .accessibilityLabel("Space theme")
    .onChange(of: theme.appearance) { _, _ in ThemeHaptics.tick() }
  }

  private var colorField: some View {
    GeometryReader { geometry in
      ZStack {
        NativeThemeBackground(theme: theme)
        Canvas { context, size in
          for x in stride(from: 7.0, through: size.width, by: 8) {
            for y in stride(from: 7.0, through: size.height, by: 8) {
              context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                with: .color(.primary.opacity(0.17)))
            }
          }
        }.allowsHitTesting(false)
        puck(primary: true, size: geometry.size)
        puck(primary: false, size: geometry.size)
      }
      .coordinateSpace(name: "themeColors")
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .top) { appearanceControls.padding(.top, 12) }
    }.frame(height: 218)
  }

  private var appearanceControls: some View {
    HStack(spacing: 5) {
      ForEach(["system", "light", "dark"], id: \.self) { appearance in
        Button {
          theme.appearance = appearance
        } label: {
          NativeGlyph(appearance == "system" ? "sparkles" : appearance == "light" ? "sun.max" : "moon.stars.fill")
            .font(.system(size: 17)).frame(width: 34, height: 32)
            .background(colors.ink.opacity(theme.appearance == appearance ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help("\(appearance.capitalized) appearance")
          .accessibilityLabel("\(appearance.capitalized) appearance")
          .accessibilityAddTraits(theme.appearance == appearance ? [.isSelected] : [])
      }
    }
  }

  private func puck(primary: Bool, size: CGSize) -> some View {
    let hex = primary ? theme.primaryColor : theme.secondaryColor
    let color = ThemeColor.nsColor(hex)
    let hsv = ThemeColor.hsv(color)
    let inset: CGFloat = 54
    let span = CGSize(
      width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
    let other = ThemeColor.hsv(ThemeColor.nsColor(primary ? theme.secondaryColor : theme.primaryColor))
    let overlaps = hypot((hsv.hue - other.hue) * span.width, (hsv.saturation - other.saturation) * span.height) < 64
    return Circle().fill(Color(nsColor: color))
      .overlay(Circle().strokeBorder(.white.opacity(0.79), lineWidth: 3))
      .overlay(
        Circle().stroke(.primary.opacity(selectedPrimary == primary ? 0.45 : 0), lineWidth: 2)
          .padding(-2)
      )
      .shadow(color: .black.opacity(0.13), radius: 5, y: 3)
      .frame(width: 58, height: 58)
      .position(x: inset + hsv.hue * span.width, y: inset + (1 - hsv.saturation) * span.height)
      .offset(x: overlaps ? (primary ? -22 : 22) : 0, y: overlaps ? (primary ? -16 : 16) : 0)
      .zIndex(selectedPrimary == primary ? 2 : 1)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("themeColors")).onChanged { event in
          selectedPrimary = primary; focusedPuck = primary
          if puckDrag?.primary != primary {
            puckDrag = (primary, hsv.hue, hsv.saturation, hsv.brightness > 0 ? hsv.brightness : 1, Int(((hsv.hue + hsv.saturation) * 5).rounded()))
            ThemeHaptics.tick()
          }
          guard let drag = puckDrag else { return }
          let hue = min(1, max(0, drag.hue + event.translation.width / span.width))
          let saturation = min(1, max(0, drag.saturation - event.translation.height / span.height))
          let newColor = NSColor(
            calibratedHue: hue, saturation: saturation, brightness: drag.brightness,
            alpha: 1)
          if primary {
            theme.primaryColor = ThemeColor.hex(newColor)
          } else {
            theme.secondaryColor = ThemeColor.hex(newColor)
          }
          let detent = Int(((hue + saturation) * 5).rounded())
          if detent != drag.detent { puckDrag?.detent = detent; ThemeHaptics.tick() }
        }.onEnded { _ in puckDrag = nil }
      )
      .focusable().focused($focusedPuck, equals: primary).focusEffectDisabled()
      .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
        selectedPrimary = primary
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        var hue = hsv.hue, saturation = hsv.saturation
        if press.key == .leftArrow || press.key == .rightArrow {
          hue = (hue + (press.key == .rightArrow ? step : -step) / 360 + 1).truncatingRemainder(dividingBy: 1)
        } else { saturation = min(1, max(0, saturation + (press.key == .upArrow ? step : -step) / 100)) }
        let next = ThemeColor.hex(NSColor(calibratedHue: hue, saturation: saturation, brightness: hsv.brightness, alpha: 1))
        if primary { theme.primaryColor = next } else { theme.secondaryColor = next }
        ThemeHaptics.tick(); return .handled
      }
      .accessibilityElement()
      .accessibilityLabel(primary ? "Primary color" : "Secondary color")
      .accessibilityValue(hex)
      .accessibilityAddTraits(selectedPrimary == primary ? [.isSelected] : [])
      .accessibilityHint("Left and right adjust hue. Up and down adjust saturation. Shift makes larger adjustments.")
      .accessibilityAdjustableAction { direction in
        let change: CGFloat = direction == .increment ? 0.025 : -0.025
        let next = ThemeColor.hex(
          NSColor(
            calibratedHue: min(1, max(0, hsv.hue + change)), saturation: hsv.saturation,
            brightness: hsv.brightness, alpha: 1))
        if primary { theme.primaryColor = next } else { theme.secondaryColor = next }
        ThemeHaptics.tick()
      }
  }
}

private struct ThemeColorWell: View {
  let title: String
  @Binding var hex: String
  @Binding var valid: Bool
  var selected: Bool
  var select: () -> Void
  @State private var draft = ""
  @State private var invalid = false

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        ColorPicker(
          title,
          selection: Binding(
            get: { Color(nsColor: ThemeColor.nsColor(hex)) },
            set: {
              hex = ThemeColor.hex(NSColor($0))
              select()
              ThemeHaptics.tick()
            }), supportsOpacity: false
        ).labelsHidden()
        TextField("#RRGGBB", text: $draft)
          .font(.system(.caption, design: .monospaced))
          .textFieldStyle(.plain)
          .onSubmit {
            let value = draft.hasPrefix("#") ? draft : "#" + draft
            invalid = !ThemeColor.valid(value)
            if !invalid {
              hex = value.uppercased()
              select()
              ThemeHaptics.tick()
            }
          }
          .onChange(of: draft) { _, input in
            let value = input.hasPrefix("#") ? input : "#" + input
            invalid = !ThemeColor.valid(value)
            if !invalid && value.uppercased() != hex.uppercased() { hex = value.uppercased(); select() }
          }
          .accessibilityLabel("\(title) hexadecimal color")
          .help(invalid ? "Enter six hexadecimal digits" : title)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.primary.opacity(selected ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(
        invalid ? Color.red : .primary.opacity(selected ? 0.18 : 0.06))
    )
    .onTapGesture(perform: select)
    .onAppear { draft = hex; valid = ThemeColor.valid(hex) }
    .onChange(of: invalid) { _, value in valid = !value }
    .onChange(of: hex) { _, value in
      draft = value
      invalid = false
      valid = true
    }
  }
}

private struct ThemeSlider: View {
  var title: String
  @Binding var value: Double
  var colors: NativeSpacePalette
  var displayMaximum: Double = 100
  var suffix = "%"
  var steps: Double?
  @State private var lastTick = -1
  @Environment(\.isEnabled) private var isEnabled
  private var divisions: Double { steps ?? displayMaximum }
  var body: some View {
    VStack(spacing: 3) {
      HStack {
        Text(title)
        Spacer()
        Text("\(Int((value * displayMaximum).rounded()))\(suffix)")
          .monospacedDigit().foregroundStyle(.secondary)
      }.font(.caption)
      GeometryReader { geometry in
        let travel = max(1, geometry.size.width - 22)
        ZStack(alignment: .leading) {
          Capsule().fill(colors.ink.opacity(0.1)).frame(height: 12)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
          Capsule().fill(colors.accent).frame(width: 11 + travel * value, height: 12)
          RoundedRectangle(cornerRadius: 7).fill(colors.card.opacity(0.86))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.07), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .frame(width: 22, height: 28).offset(x: travel * value)
        }.frame(height: 30).contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0).onChanged { event in
            guard isEnabled else { return }
            value = (min(1, max(0, (event.location.x - 11) / travel)) * divisions).rounded() / divisions
          })
      }.frame(height: 30).opacity(isEnabled ? 1 : 0.4)
        .focusable(isEnabled).accessibilityElement().accessibilityLabel(title)
        .accessibilityValue("\(Int((value * displayMaximum).rounded()))\(suffix)")
        .accessibilityAdjustableAction { adjust($0 == .increment ? 1 : -1) }
        .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow, .home, .end]) { key in
          guard isEnabled else { return .ignored }
          if key.key == .home { value = 0 }
          else if key.key == .end { value = 1 }
          else { adjust((key.key == .upArrow || key.key == .rightArrow ? 1 : -1) * (key.modifiers.contains(.shift) ? 10 : 1)) }
          return .handled
        }
        .onChange(of: value) { _, new in
          let tick = Int((new * 10).rounded())
          if tick != lastTick {
            lastTick = tick
            ThemeHaptics.tick()
          }
        }
        .accessibilityRepresentation {
          Slider(value: $value, in: 0...1, step: 1 / divisions).disabled(!isEnabled)
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((value * displayMaximum).rounded()))\(suffix)")
        }
    }
  }
  private func adjust(_ amount: Double) {
    guard isEnabled else { return }
    value = min(1, max(0, value + amount / divisions))
  }
}

private struct ThemeDial: View {
  var title: String
  @Binding var value: Double
  var displayMaximum: Double = 100
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 4) {
        Text(title)
        Text("\(Int((value * displayMaximum).rounded()))%").monospacedDigit()
          .foregroundStyle(.secondary)
      }.font(.caption2)
      ZStack {
        Circle().stroke(.primary.opacity(0.14), lineWidth: 1).frame(width: 76, height: 76)
        Circle().fill(
          reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            : AnyShapeStyle(.regularMaterial)
        ).frame(width: 60, height: 60)
          .shadow(color: .black.opacity(0.13), radius: 3, y: 2)
        Capsule().fill(.tint).frame(width: 4, height: 12).offset(y: -19)
          .rotationEffect(.degrees(-135 + 270 * value))
      }
      .frame(width: 76, height: 76)
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { event in
          var angle = atan2(event.location.x - 38, -(event.location.y - 38)) * 180 / .pi
          if abs(angle) > 135 { angle = value > 0.5 ? 135 : -135 }
          let next = (((angle + 135) / 270) * displayMaximum).rounded() / displayMaximum
          if Int((next * 10).rounded()) != Int((value * 10).rounded()) { ThemeHaptics.tick() }
          value = min(1, max(0, next))
        }
      )
      .focusable()
      .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow, .home, .end]) { key in
        if key.key == .home { value = 0 }
        else if key.key == .end { value = 1 }
        else { adjust((key.key == .upArrow || key.key == .rightArrow ? 1 : -1) * (key.modifiers.contains(.shift) ? 10 : 1) / displayMaximum) }
        return .handled
      }
      .accessibilityElement()
      .accessibilityLabel(title)
      .accessibilityValue("\(Int(value * displayMaximum)) percent")
      .accessibilityAdjustableAction { adjust(($0 == .increment ? 1 : -1) / displayMaximum) }
      .accessibilityRepresentation {
        Slider(value: $value, in: 0...1, step: 1 / displayMaximum)
          .accessibilityLabel(title).accessibilityValue("\(Int(value * displayMaximum)) percent")
      }
    }
  }
  private func adjust(_ delta: Double) {
    value = min(1, max(0, value + delta))
    ThemeHaptics.tick()
  }
}

@MainActor private enum ThemeHaptics {
  private static var last = Date.distantPast
  static func tick() {
    let now = Date()
    guard now.timeIntervalSince(last) > 0.065 else { return }
    last = now
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }
}

private enum ThemeColor {
  static func valid(_ value: String) -> Bool {
    value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
  }
  static func nsColor(_ value: String) -> NSColor {
    let number =
      UInt64(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x9D4460
    return NSColor(
      srgbRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: 1)
  }
  static func hex(_ value: NSColor) -> String {
    guard let rgb = value.usingColorSpace(.sRGB) else { return "#9D4460" }
    return String(
      format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
      Int(rgb.blueComponent * 255))
  }
  static func hsv(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
    let rgb = color.usingColorSpace(.sRGB) ?? color
    return (rgb.hueComponent, rgb.saturationComponent, rgb.brightnessComponent)
  }
}

private enum ThemeNoise {
  static let image: NSImage = {
    let width = 96
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: width * 4, bitsPerPixel: 32)!
    var seed: UInt32 = 124871
    for y in 0..<width {
      for x in 0..<width {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        let gray = Int(seed % 256)
        var pixel = [gray, gray, gray, 255]
        bitmap.setPixel(&pixel, atX: x, y: y)
      }
    }
    let image = NSImage(size: NSSize(width: width, height: width))
    image.addRepresentation(bitmap)
    return image
  }()
}

/// A material surface that honors the macOS Reduce Transparency preference.
struct NativeControlSurface: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    if reduceTransparency {
      Color(nsColor: .windowBackgroundColor)
    } else {
      Rectangle().fill(.regularMaterial)
    }
  }
}

struct NativeSpaceIdentity: View {
  @Binding var name: String
  @Binding var icon: String
  var initiallyExpanded = false
  @State private var query = ""
  @State private var expanded = false
  var body: some View {
    DisclosureGroup("Name & icon", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        TextField("Space name", text: Binding(get: { name }, set: { name = String($0.prefix(60)) })).textFieldStyle(.roundedBorder)
        TextField("Find an icon", text: $query).textFieldStyle(.roundedBorder)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 12), spacing: 2) {
          ForEach(NativeGlyph.spaceNames.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { icon in
            Button { self.icon = icon; ThemeHaptics.tick() } label: {
              NativeGlyph(icon).frame(width: 30, height: 30)
                .background(Color.primary.opacity((NativeGlyph.aliases[self.icon] ?? self.icon) == icon ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help(icon.capitalized).accessibilityLabel("\(icon.capitalized) icon")
          }
        }
      }.padding(.top, 10)
    }.font(.system(size: 12)).onAppear { expanded = initiallyExpanded }
  }
}

private struct NativeThemeScrollbars: NSViewRepresentable {
  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) { view.suppress() }
  final class Anchor: NSView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); suppress() }
    override func layout() { super.layout(); suppress() }
    func suppress() {
      DispatchQueue.main.async { [weak self] in
        guard let root = self?.window?.contentView else { return }
        func visit(_ view: NSView) {
          if let scroll = view as? NSScrollView {
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
          }
          for child in view.subviews { visit(child) }
        }
        visit(root)
      }
    }
  }
}

private struct PresentedSpaceThemeKey: EnvironmentKey { static let defaultValue: SpaceTheme? = nil }
extension EnvironmentValues {
  var presentedSpaceTheme: SpaceTheme? {
    get { self[PresentedSpaceThemeKey.self] }
    set { self[PresentedSpaceThemeKey.self] = newValue }
  }
}
/// The presentation blend never writes a half-swiped theme into saved Spaces.
enum NativeSpaceAppearance {
  static func blend(_ first: SpaceTheme, _ second: SpaceTheme, progress: Double) -> SpaceTheme {
    let t = min(1, max(0, progress))
    if t == 0 { return first }; if t == 1 { return second }
    func scalar(_ a: Double, _ b: Double) -> Double { a * (1 - t) + b * t }
    func lab(_ hex: String) -> [Double] {
      let c = ThemeColor.nsColor(hex).usingColorSpace(.sRGB)!
      let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { value -> Double in
        let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      let l = cbrt(0.4122214708 * rgb[0] + 0.5363325363 * rgb[1] + 0.0514459929 * rgb[2])
      let m = cbrt(0.2119034982 * rgb[0] + 0.6806995451 * rgb[1] + 0.1073969566 * rgb[2])
      let s = cbrt(0.0883024619 * rgb[0] + 0.2817188376 * rgb[1] + 0.6299787005 * rgb[2])
      return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s]
    }
    func color(_ a: String, _ b: String) -> String {
      let value = zip(lab(a), lab(b)).map { scalar($0, $1) }
      let l = pow(value[0] + 0.3963377774 * value[1] + 0.2158037573 * value[2], 3)
      let m = pow(value[0] - 0.1055613458 * value[1] - 0.0638541728 * value[2], 3)
      let s = pow(value[0] - 0.0894841775 * value[1] - 1.291485548 * value[2], 3)
      let channels = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s].map { value -> Int in
          let v = min(1, max(0, value))
          return Int((255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)).rounded())
        }
      return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
    var result = first
    result.primaryColor = color(first.primaryColor, second.primaryColor)
    result.secondaryColor = color(first.secondaryColor, second.secondaryColor)
    result.blend = scalar(first.blend, second.blend); result.intensity = scalar(first.intensity, second.intensity)
    result.grain = scalar(first.grain, second.grain); result.opacity = scalar(first.opacity, second.opacity)
    result.blur = scalar(first.blur, second.blur)
    return result
  }
}
