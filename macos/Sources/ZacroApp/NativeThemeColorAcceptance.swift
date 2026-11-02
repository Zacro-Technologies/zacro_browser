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
    let span = CGSize(width: 280, height: 110)
    let stationary = ThemeColor.puckAdjustment(hue: 0, saturation: 0, brightness: 0,
      translation: .zero, span: span)
    let right = ThemeColor.puckAdjustment(hue: 0.5, saturation: 1, brightness: 1,
      translation: CGSize(width: 280, height: 0), span: span)
    let left = ThemeColor.puckAdjustment(hue: 0.5, saturation: 1, brightness: 1,
      translation: CGSize(width: -280, height: 0), span: span)
    let blackMove = ThemeColor.puckAdjustment(hue: 0, saturation: 0, brightness: 0,
      translation: CGSize(width: 0, height: -55), span: span)
    let returnedToOrigin = ThemeColor.puckAdjustment(hue: 0, saturation: 0, brightness: 0,
      translation: .zero, span: span, hasMoved: blackMove != nil)
    func hex(_ value: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)?) -> String? {
      value.map { ThemeColor.hex(ThemeColor.color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness)) }
    }
    let nearRed = ThemeColor.hsv(ThemeColor.nsColor("#FF0001"))
    let nearRedPosition = 54 + ThemeColor.puckProgress(hue: nearRed.hue) * span.width
    // Exact renderer formula for RGB(255,0,1): hue=(360-60/255) degrees.
    let expectedNearRedPosition: CGFloat = 54 + (360 - 60 / 255) / 359 * span.width
    return [
      "theme_color_srgb_hsv_round_trip_preserves_selected_bytes": roundTrips,
      "theme_color_keyboard_and_half_bytes_match_renderer": keyboard,
      "theme_color_wide_gamut_conversion_clamps_hex_bytes": ThemeColor.hex(wide) == "#00FF80",
      "theme_puck_click_preserves_black_without_pointer_movement": stationary == nil,
      "theme_puck_right_edge_matches_renderer_359_degrees_without_wrapping": hex(right) == "#FF0004"
        && ThemeColor.puckProgress(hue: right?.hue ?? 0) == 1,
      "theme_puck_left_edge_remains_red": hex(left) == "#FF0000",
      "theme_puck_real_black_drag_matches_renderer_brightness_fallback": hex(blackMove) == "#FF8080",
      "theme_puck_drag_return_to_origin_recomputes_original_coordinates": hex(returnedToOrigin) == "#FFFFFF",
      "theme_puck_hex_near_red_preserves_renderer_unclamped_position": nearRedPosition > 54 + span.width
        && abs(nearRedPosition - expectedNearRedPosition) < 0.001,
    ]
  }
}
