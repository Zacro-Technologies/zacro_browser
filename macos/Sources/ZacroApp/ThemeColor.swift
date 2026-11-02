import AppKit

/// Puck coordinates use the renderer’s sRGB HSV space, with rounded byte output.
enum ThemeColor {
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
      format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
  }
  private static func byte(_ channel: CGFloat) -> Int {
    guard channel.isFinite else { return 0 }
    return Int((min(1, max(0, channel)) * 255).rounded())
  }
  static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> NSColor {
    NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
  }
  static func hsv(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
    let rgb = color.usingColorSpace(.sRGB) ?? color
    return (rgb.hueComponent, rgb.saturationComponent, rgb.brightnessComponent)
  }
}

