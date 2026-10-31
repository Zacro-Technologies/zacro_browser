import AppKit
import SwiftUI
import ZacroCore

/// Shared by the window and its editor: tint, texture and material use one recipe.
struct NativeThemeBackground: View {
  var theme: SpaceTheme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  private var dark: Bool {
    theme.appearance == "dark" || (theme.appearance == "system" && colorScheme == .dark)
  }

  var body: some View {
    ZStack {
      if !reduceTransparency { ThemeMaterial(amount: theme.blur) }
      LinearGradient(
        stops: [
          .init(color: tint(theme.primaryColor), location: 0),
          .init(color: tint(theme.primaryColor), location: max(0, 1 - theme.blend * 2)),
          .init(color: tint(theme.secondaryColor), location: min(1, 2 - theme.blend * 2)),
          .init(color: tint(theme.secondaryColor), location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing
      )
      .opacity(reduceTransparency ? 1 : theme.opacity)
      Rectangle().fill(ImagePaint(image: Image(nsImage: ThemeNoise.image), scale: 0.5))
        .opacity(theme.grain * 0.22 * (reduceTransparency ? 1 : theme.opacity))
        .blendMode(.softLight)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func tint(_ hex: String) -> Color {
    let color = ThemeColor.nsColor(hex)
    let neutral = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1)
    return Color(
      nsColor: neutral.blended(withFraction: 0.2 + theme.intensity * 0.8, of: color) ?? color)
  }
}

private struct ThemeMaterial: NSViewRepresentable {
  var amount: Double
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
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
  @State private var selectedPrimary = true
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  private let presets = [
    "#9D4460", "#3F806A", "#487EA8", "#B87646", "#79619D", "#59717A", "#D2617F", "#C4A344",
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        HStack {
          Text("Space theme").font(.headline)
          Spacer()
          Picker("Appearance", selection: $theme.appearance) {
            Image(systemName: "sparkles").tag("system").help("System appearance")
            Image(systemName: "sun.max").tag("light").help("Light appearance")
            Image(systemName: "moon").tag("dark").help("Dark appearance")
          }.pickerStyle(.segmented).frame(width: 132)
        }
        colorField
        HStack(spacing: 10) {
          ThemeColorWell(title: "Primary", hex: $theme.primaryColor, selected: selectedPrimary) {
            selectedPrimary = true
          }
          ThemeColorWell(title: "Secondary", hex: $theme.secondaryColor, selected: !selectedPrimary)
          { selectedPrimary = false }
        }
        HStack(spacing: 10) {
          ForEach(presets, id: \.self) { hex in
            Button {
              if selectedPrimary { theme.primaryColor = hex } else { theme.secondaryColor = hex }
              ThemeHaptics.tick()
            } label: {
              Circle().fill(Color(nsColor: ThemeColor.nsColor(hex)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
                .frame(width: 29, height: 29)
            }.buttonStyle(.plain).help(hex).accessibilityLabel("Use color \(hex)")
          }
        }
        Divider()
        if reduceTransparency {
          Text("Reduce Transparency is enabled in macOS.").font(.caption).foregroundStyle(
            .secondary)
        }
        HStack(alignment: .top, spacing: 22) {
          VStack(alignment: .leading, spacing: 12) {
            ThemeSlider(title: "Intensity", value: $theme.intensity)
            ThemeSlider(title: "Opacity", value: $theme.opacity).disabled(reduceTransparency)
            ThemeSlider(title: "Blur", value: $theme.blur).disabled(reduceTransparency)
          }
          VStack(spacing: 14) {
            ThemeDial(title: "Blend", value: $theme.blend)
            ThemeDial(title: "Grain", value: $theme.grain)
          }.frame(width: 80)
        }
      }.padding(20)
    }
    .frame(width: 370, height: 590)
    .background { NativeControlSurface() }
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
      .clipShape(RoundedRectangle(cornerRadius: 14))
    }.frame(height: 200)
  }

  private func puck(primary: Bool, size: CGSize) -> some View {
    let hex = primary ? theme.primaryColor : theme.secondaryColor
    let color = ThemeColor.nsColor(hex)
    let hsv = ThemeColor.hsv(color)
    let inset: CGFloat = 28
    let span = CGSize(
      width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
    return Circle().fill(Color(nsColor: color))
      .overlay(Circle().strokeBorder(.white.opacity(0.93), lineWidth: 5))
      .overlay(
        Circle().stroke(.primary.opacity(selectedPrimary == primary ? 0.45 : 0), lineWidth: 1)
          .padding(-3)
      )
      .shadow(color: .black.opacity(0.13), radius: 5, y: 3)
      .frame(width: 44, height: 44)
      .position(x: inset + hsv.hue * span.width, y: inset + (1 - hsv.saturation) * span.height)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("themeColors")).onChanged { event in
          selectedPrimary = primary
          let hue = min(1, max(0, (event.location.x - inset) / span.width))
          let saturation = 1 - min(1, max(0, (event.location.y - inset) / span.height))
          let newColor = NSColor(
            calibratedHue: hue, saturation: saturation, brightness: max(0.35, hsv.brightness),
            alpha: 1)
          if primary {
            theme.primaryColor = ThemeColor.hex(newColor)
          } else {
            theme.secondaryColor = ThemeColor.hex(newColor)
          }
          ThemeHaptics.tick()
        }
      )
      .accessibilityElement()
      .accessibilityLabel(primary ? "Primary color" : "Secondary color")
      .accessibilityValue(hex)
      .accessibilityHint("Adjusts hue. Use the color field below for exact values.")
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
    .onAppear { draft = hex }
    .onChange(of: hex) { _, value in
      draft = value
      invalid = false
    }
  }
}

private struct ThemeSlider: View {
  var title: String
  @Binding var value: Double
  @State private var lastTick = -1
  var body: some View {
    VStack(spacing: 3) {
      HStack {
        Text(title)
        Spacer()
        Text(value, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit().foregroundStyle(.secondary)
      }.font(.caption)
      Slider(value: $value, in: 0...1, step: 0.01).labelsHidden().accessibilityLabel(title)
        .onChange(of: value) { _, new in
          let tick = Int(new * 20)
          if tick != lastTick {
            lastTick = tick
            ThemeHaptics.tick()
          }
        }
    }
  }
}

private struct ThemeDial: View {
  var title: String
  @Binding var value: Double
  @State private var startingValue: Double?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 4) {
        Text(title)
        Text(value, format: .percent.precision(.fractionLength(0))).monospacedDigit()
          .foregroundStyle(.secondary)
      }.font(.caption2)
      ZStack {
        Circle().stroke(.primary.opacity(0.09), lineWidth: 1).frame(width: 62, height: 62)
        Circle().fill(
          reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            : AnyShapeStyle(.regularMaterial)
        ).frame(width: 50, height: 50)
          .shadow(color: .black.opacity(0.13), radius: 3, y: 2)
        Capsule().fill(.primary.opacity(0.7)).frame(width: 3, height: 9).offset(y: -16)
          .rotationEffect(.degrees(-135 + 270 * value))
      }
      .frame(width: 66, height: 66)
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { event in
          if startingValue == nil { startingValue = value }
          let next = min(
            1,
            max(
              0,
              (startingValue ?? value) - event.translation.height / 150 + event.translation.width
                / 300))
          if Int(next * 20) != Int(value * 20) { ThemeHaptics.tick() }
          value = next
        }.onEnded { _ in startingValue = nil }
      )
      .focusable()
      .onKeyPress(.upArrow) {
        adjust(0.05)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        adjust(0.05)
        return .handled
      }
      .onKeyPress(.downArrow) {
        adjust(-0.05)
        return .handled
      }
      .onKeyPress(.leftArrow) {
        adjust(-0.05)
        return .handled
      }
      .accessibilityElement()
      .accessibilityLabel(title)
      .accessibilityValue("\(Int(value * 100)) percent")
      .accessibilityAdjustableAction { adjust($0 == .increment ? 0.05 : -0.05) }
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
      calibratedRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: 1)
  }
  static func hex(_ value: NSColor) -> String {
    guard let rgb = value.usingColorSpace(.deviceRGB) else { return "#9D4460" }
    return String(
      format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
      Int(rgb.blueComponent * 255))
  }
  static func hsv(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
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
