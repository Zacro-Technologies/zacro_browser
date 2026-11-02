import AppKit

@MainActor
enum NativeThemeColorAcceptance {
  static func check() -> [String: Bool] {
    let palette = ["#9D4460", "#B89AB8", "#123456", "#010101", "#FEFEFE", "#000000", "#FFFFFF", "#808080", "#00FF00"]
    let roundTrips = palette.allSatisfy { hex in
      let color = ThemeColor.nsColor(hex), hsv = ThemeColor.hsv(color)
      return ThemeColor.hex(color) == hex
        && ThemeColor.hex(ThemeColor.color(hue: hsv.hue, saturation: hsv.saturation, brightness: hsv.brightness)) == hex
    }
    // Expected bytes from renderer/app.js themeColorHex, including one-degree
    // keyboard steps and half-byte rounding rather than truncation.
    let coordinates: [(CGFloat, CGFloat, CGFloat, String)] = [
      (1, 1, 1, "#FF0400"), (359, 1, 1, "#FF0004"),
      (280, 0.28, 0.72, "#A684B8"), (60, 0.5, 0.5, "#808040"),
    ]
    let keyboard = coordinates.allSatisfy { hue, saturation, brightness, expected in
      ThemeColor.hex(ThemeColor.color(hue: hue / 360, saturation: saturation, brightness: brightness)) == expected
    }
    let wide = NSColor(colorSpace: .extendedSRGB, components: [-0.1, 1.2, 0.5, 1], count: 4)
    return [
      "theme_color_srgb_hsv_round_trip_preserves_selected_bytes": roundTrips,
      "theme_color_keyboard_and_half_bytes_match_renderer": keyboard,
      "theme_color_wide_gamut_conversion_clamps_hex_bytes": ThemeColor.hex(wide) == "#00FF80",
    ]
  }
}
