import SwiftUI

/// Original Zacro vector glyphs, converted from renderer/app.js into native
/// paths. Coordinates, rounded strokes, and line weight retain the shared UI.
struct NativeGlyph: View {
  let name: String
  var size: CGFloat = 16
  init(_ name: String, size: CGFloat = 16) { self.name = name; self.size = size }
  var body: some View {
    let key = Self.aliases[name] ?? name
    Group {
      if let commands = Self.paths[key] { GlyphPath(commands: commands).stroke(style: StrokeStyle(lineWidth: size * 1.7 / 24, lineCap: .round, lineJoin: .round)) }
      else { Image(systemName: name).resizable().scaledToFit() }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
  /// AppKit-backed SwiftUI menus extract an Image or Text from their label;
  /// a Shape-only label becomes an empty NSPopUpButton. Keep the exact same
  /// vector paths in a template image for that native control boundary.
  static func menuImage(_ name: String, size: CGFloat = 16) -> Image {
    let key = aliases[name] ?? name
    guard let commands = paths[key] else { return Image(systemName: name) }
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.setStrokeColor(NSColor.black.cgColor)
      context.setLineWidth(size * 1.7 / 24)
      context.setLineCap(.round); context.setLineJoin(.round)
      context.addPath(GlyphPath(commands: commands).path(in: rect).cgPath)
      context.strokePath()
      return true
    }
    image.isTemplate = true
    return Image(nsImage: image)
  }
  static let aliases: [String: String] = [
    "sidebar.left": "sidebar", "arrow.left": "back", "arrow.right": "forward", "arrow.clockwise": "reload",
    "magnifyingglass": "search", "xmark": "close", "slider.horizontal.3": "pageControls", "archivebox": "library",
    "rectangle.split.2x1": "split", "arrow.up.left.and.arrow.down.right": "expand", "square.stack": "layers",
    "chevron.down": "down", "chevron.up": "up", "chevron.left": "chevronLeft", "chevron.right": "chevronRight",
    "circle.fill": "circle", "house": "home", "sparkles": "sparkle", "paintpalette": "palette", "gearshape": "settings",
    "arrow.uturn.backward": "undo", "speaker.slash": "muted", "speaker.wave.2": "volume", "ellipsis": "more",
    "clock.arrow.circlepath": "history", "arrow.down.circle": "download", "puzzlepiece.extension": "extension",
    "pencil": "edit", "doc": "file", "refresh": "reload",
    "clock": "history", "arrow.down": "download", "square.and.arrow.up": "external", "checkmark": "check",
    "doc.on.doc": "copy", "printer": "print", "person": "user", "person.crop.circle": "user", "sun.max": "sun",
    "moon.stars.fill": "moon", "moon": "moon", "info.circle": "info", "exclamationmark.triangle": "alert",
    "envelope": "mail", "airplane": "plane", "gamecontroller": "gamepad", "flask": "beaker", "bolt.fill": "bolt",
  ]
  static let spaceNames = ["circle", "briefcase", "home", "code", "book", "leaf", "star", "heart", "globe", "sun", "moon", "music", "coffee", "plane", "camera", "gamepad", "palette", "beaker", "rocket", "compass", "mountain", "flame", "cloud", "bolt", "diamond", "flower", "smile", "headphones", "calendar", "film", "building", "bag"]
  static func commandName(_ id: String) -> String {
    [
      "command-palette": "plus", "open-location": "search", "sidebar-toggle": "sidebar", "focus-sidebar": "sidebar",
      "reveal-tab": "eye", "browser-menu": "more", "onboarding": "sparkle", "save-page": "download", "reopen-tab": "undo",
      "next-tab": "forward", "previous-tab": "back", "next-space": "layers", "previous-space": "layers", "bookmark": "bookmark",
      "pin-tab": "pin", "duplicate-tab": "copy", "rename-tab": "edit", "move-tab": "folder", "mute-tab": "volume",
      "new-folder": "folderPlus", "new-space": "layers", "new-private-space": "shield", "preferences": "settings",
      "shortcuts": "keyboard", "history": "history", "downloads": "download", "bookmarks": "bookmark", "archive": "archive", "windows": "layers", "reopen-window": "undo",
      "extensions": "extension", "ai": "sparkle", "find": "search", "find-next": "down", "find-previous": "up",
      "reload": "reload", "force-reload": "reload", "stop": "stop", "history-back": "back", "history-forward": "forward",
      "zoom-in": "plus", "zoom-out": "minimize", "zoom-reset": "monitor", "split": "split", "unsplit": "split",
      "peek-close": "close", "peek-promote": "external", "copy-url": "copy", "print": "print", "fullscreen": "maximize",
      "developer-tools": "terminal", "about": "info", "close-tab": "close", "close-window": "close", "open-browser": "monitor",
    ][id] ?? "keyboard"
  }
  fileprivate enum Command {
    case move(Double, Double), line(Double, Double), curve(Double, Double, Double, Double, Double, Double), close
  }
  fileprivate static let paths: [String: [Command]] = [
    "circle": [.move(20, 12), .curve(20, 16.41828, 16.41828, 20, 12, 20), .curve(7.581722, 20, 4, 16.41828, 4, 12), .curve(4, 7.581722, 7.581722, 4, 12, 4), .curve(16.41828, 4, 20, 7.581722, 20, 12)],
    "briefcase": [.move(3, 7), .line(21, 7), .line(21, 21), .line(3, 21), .close, .move(8, 7), .line(8, 3), .line(16, 3), .line(16, 7), .move(3, 12), .line(21, 12), .move(10, 12), .line(10, 15), .line(14, 15), .line(14, 12)],
    "home": [.move(3, 10), .line(12, 3), .line(21, 10), .move(5, 9), .line(5, 21), .line(19, 21), .line(19, 9), .move(9, 21), .line(9, 13), .line(15, 13), .line(15, 21)],
    "code": [.move(8, 6), .line(2, 12), .line(8, 18), .move(16, 6), .line(22, 12), .line(16, 18), .move(14, 3), .line(10, 21)],
    "book": [.move(12, 5), .line(12, 21), .move(12, 5), .curve(8, 2, 4, 3, 2, 4), .line(2, 20), .curve(6, 18, 9, 19, 12, 21), .curve(15, 19, 18, 18, 22, 20), .line(22, 4), .curve(20, 3, 16, 2, 12, 5)],
    "leaf": [.move(20, 3), .curve(10, 2, 3, 7, 4, 14), .curve(5, 21, 16, 22, 19, 12), .curve(20, 9, 20, 6, 20, 3), .move(4, 21), .line(15, 9)],
    "music": [.move(9, 18), .line(9, 5), .line(21, 2), .line(21, 15), .move(9, 8), .line(21, 5), .move(9, 18), .curve(9, 19.65685, 7.656854, 21, 6, 21), .curve(4.343146, 21, 3, 19.65685, 3, 18), .curve(3, 16.34315, 4.343146, 15, 6, 15), .curve(7.656854, 15, 9, 16.34315, 9, 18), .move(21, 15), .curve(21, 16.65685, 19.65685, 18, 18, 18), .curve(16.34315, 18, 15, 16.65685, 15, 15), .curve(15, 13.34315, 16.34315, 12, 18, 12), .curve(19.65685, 12, 21, 13.34315, 21, 15)],
    "plus": [.move(12, 5), .line(12, 19), .move(5, 12), .line(19, 12)],
    "layers": [.move(12, 3), .line(22, 9), .line(12, 15), .line(2, 9), .close, .move(2, 13), .line(12, 19), .line(22, 13), .move(2, 17), .line(12, 23), .line(22, 17)],
    "sidebar": [.move(5, 4), .line(19, 4), .curve(20.10457, 4, 21, 4.895431, 21, 6), .line(21, 18), .curve(21, 19.10457, 20.10457, 20, 19, 20), .line(5, 20), .curve(3.895431, 20, 3, 19.10457, 3, 18), .line(3, 6), .curve(3, 4.895431, 3.895431, 4, 5, 4), .close, .move(9, 4), .line(9, 20)],
    "library": [.move(4, 4), .line(20, 4), .line(20, 8), .line(4, 8), .close, .move(6, 8), .line(6, 19), .curve(6, 19.55228, 6.447715, 20, 7, 20), .line(17, 20), .curve(17.55228, 20, 18, 19.55228, 18, 19), .line(18, 8), .move(9, 12), .line(15, 12)],
    "volume": [.move(4, 9), .line(8, 9), .line(13, 4), .line(13, 20), .line(8, 15), .line(4, 15), .close, .move(16, 8), .curve(18.03715, 10.27761, 18.03715, 13.72239, 16, 16), .move(19, 5), .curve(22.81143, 8.888435, 22.81143, 15.11156, 19, 19)],
    "muted": [.move(4, 9), .line(8, 9), .line(13, 4), .line(13, 20), .line(8, 15), .line(4, 15), .close, .move(17, 9), .line(22, 15), .move(22, 9), .line(17, 15)],
    "close": [.move(7, 7), .line(17, 17), .move(17, 7), .line(7, 17)],
    "back": [.move(19, 12), .line(5, 12), .move(11, 6), .line(5, 12), .line(11, 18)],
    "forward": [.move(5, 12), .line(19, 12), .move(13, 6), .line(19, 12), .line(13, 18)],
    "chevronLeft": [.move(15, 6), .line(9, 12), .line(15, 18)],
    "chevronRight": [.move(9, 6), .line(15, 12), .line(9, 18)],
    "down": [.move(7, 10), .line(12, 15), .line(17, 10)],
    "up": [.move(7, 14), .line(12, 9), .line(17, 14)],
    "reload": [.move(19, 3), .line(19, 8), .line(14, 8), .move(19, 8), .curve(17.17497, 5.077156, 13.59311, 3.773964, 10.31655, 4.840684), .curve(7.039981, 5.907405, 4.911863, 9.069539, 5.157368, 12.50662), .curve(5.402874, 15.94369, 7.958828, 18.77125, 11.35374, 19.36144), .curve(14.74866, 19.95162, 18.10892, 18.15257, 19.5, 15)],
    "search": [.move(21, 21), .line(16, 16), .move(18, 10), .curve(18, 14.41828, 14.41828, 18, 10, 18), .curve(5.581722, 18, 2, 14.41828, 2, 10), .curve(2, 5.581722, 5.581722, 2, 10, 2), .curve(14.41828, 2, 18, 5.581722, 18, 10)],
    "star": [.move(12, 3), .line(14.8, 8.7), .line(21.1, 9.6), .line(16.5, 14.1), .line(17.6, 20.4), .line(12, 17.4), .line(6.4, 20.4), .line(7.5, 14.1), .line(3, 9.6), .line(9.2, 8.7), .close],
    "split": [.move(3, 4), .line(21, 4), .line(21, 20), .line(3, 20), .close, .move(12, 4), .line(12, 20)],
    "expand": [.move(14, 5), .line(19, 5), .line(19, 10), .move(19, 5), .line(13, 11), .move(10, 19), .line(5, 19), .line(5, 14), .move(5, 19), .line(11, 13)],
    "sparkle": [.move(12, 3), .line(14.4, 9.6), .line(21, 12), .line(14.4, 14.4), .line(12, 21), .line(9.6, 14.4), .line(3, 12), .line(9.6, 9.6), .close, .move(20, 2), .line(20, 6), .move(18, 4), .line(22, 4)],
    "globe": [.move(21, 12), .curve(21, 16.97056, 16.97056, 21, 12, 21), .curve(7.029437, 21, 3, 16.97056, 3, 12), .curve(3, 7.029437, 7.029437, 3, 12, 3), .curve(16.97056, 3, 21, 7.029437, 21, 12), .move(3, 12), .line(21, 12), .move(12, 3), .curve(17, 8, 17, 16, 12, 21), .curve(7, 16, 7, 8, 12, 3)],
    "lock": [.move(6, 10), .line(18, 10), .line(18, 21), .line(6, 21), .close, .move(8, 10), .line(8, 6), .curve(8, 3.790861, 9.790861, 2, 12, 2), .curve(14.20914, 2, 16, 3.790861, 16, 6), .line(16, 10)],
    "unlock": [.move(6, 10), .line(18, 10), .line(18, 21), .line(6, 21), .close, .move(8, 10), .line(8, 6), .curve(8.046378, 4.232307, 9.247934, 2.704821, 10.95499, 2.243455), .curve(12.66204, 1.782089, 14.46947, 2.496335, 15.4, 4)],
    "more": [.move(4, 12), .line(4.01, 12), .move(12, 12), .line(12.01, 12), .move(20, 12), .line(20.01, 12)],
    "pageControls": [.move(5, 3), .line(19, 3), .curve(20.10457, 3, 21, 3.895431, 21, 5), .line(21, 19), .curve(21, 20.10457, 20.10457, 21, 19, 21), .line(5, 21), .curve(3.895431, 21, 3, 20.10457, 3, 19), .line(3, 5), .curve(3, 3.895431, 3.895431, 3, 5, 3), .close, .move(7, 8), .line(11, 8), .move(14, 8), .line(17, 8), .move(7, 16), .line(10, 16), .move(13, 16), .line(17, 16), .move(11, 6), .line(11, 10), .move(13, 14), .line(13, 18)],
    "history": [.move(3, 11), .curve(3.349921, 6.776537, 6.598875, 3.369412, 10.80095, 2.819272), .curve(15.00302, 2.269133, 19.01957, 4.725051, 20.44495, 8.716091), .curve(21.87032, 12.70713, 20.31827, 17.15183, 16.71839, 19.38811), .curve(13.11851, 21.62438, 8.44625, 21.04626, 5.5, 18), .move(3, 4), .line(3, 11), .line(10, 11), .move(12, 7), .line(12, 12), .line(15, 14)],
    "bookmark": [.move(6, 3), .line(18, 3), .line(18, 21), .line(12, 17), .line(6, 21), .close],
    "download": [.move(12, 3), .line(12, 15), .move(7, 10), .line(12, 15), .line(17, 10), .move(4, 16), .line(4, 21), .line(20, 21), .line(20, 16)],
    "settings": [.move(9, 3), .line(8, 6), .line(5, 7), .line(3, 11), .line(5, 14), .line(6, 18), .line(9, 19), .line(12, 21), .line(15, 19), .line(18, 18), .line(19, 14), .line(21, 11), .line(19, 7), .line(16, 6), .line(15, 3), .close, .move(16, 12), .curve(16, 14.20914, 14.20914, 16, 12, 16), .curve(9.790861, 16, 8, 14.20914, 8, 12), .curve(8, 9.790861, 9.790861, 8, 12, 8), .curve(14.20914, 8, 16, 9.790861, 16, 12)],
    "archive": [.move(3, 4), .line(21, 4), .line(21, 8), .line(3, 8), .close, .move(5, 8), .line(5, 20), .line(19, 20), .line(19, 8), .move(9, 12), .line(15, 12)],
    "folder": [.move(3, 7), .line(3, 5.5), .curve(3, 4.671573, 3.671573, 4, 4.5, 4), .line(9, 4), .line(12, 7), .line(19.5, 7), .curve(20.32843, 7, 21, 7.671573, 21, 8.5), .line(21, 19.5), .curve(21, 20.32843, 20.32843, 21, 19.5, 21), .line(4.5, 21), .curve(3.671573, 21, 3, 20.32843, 3, 19.5), .close, .move(3, 9), .line(21, 9)],
    "folderPlus": [.move(3, 5), .line(10, 5), .line(12, 8), .line(21, 8), .line(21, 20), .line(3, 20), .close, .move(12, 11), .line(12, 17), .move(9, 14), .line(15, 14)],
    "pin": [.move(16, 3), .line(21, 8), .line(16, 9), .line(13, 14), .line(14, 17), .line(12, 19), .line(5, 12), .line(7, 10), .line(10, 11), .line(15, 8), .close, .move(5, 19), .line(3, 21)],
    "external": [.move(14, 3), .line(21, 3), .line(21, 10), .move(21, 3), .line(10, 14), .move(10, 3), .line(3, 3), .line(3, 21), .line(21, 21), .line(21, 14)],
    "user": [.move(16, 7), .curve(16, 9.209139, 14.20914, 11, 12, 11), .curve(9.790861, 11, 8, 9.209139, 8, 7), .curve(8, 4.790861, 9.790861, 3, 12, 3), .curve(14.20914, 3, 16, 4.790861, 16, 7), .move(4, 21), .line(4, 19), .curve(4, 14.58172, 7.581722, 11, 12, 11), .curve(16.41828, 11, 20, 14.58172, 20, 19), .line(20, 21)],
    "shield": [.move(12, 3), .line(20, 6), .line(20, 12), .curve(20, 16, 16, 19, 12, 21), .curve(8, 19, 4, 16, 4, 12), .line(4, 6), .close, .move(8, 12), .line(11, 15), .line(16, 10)],
    "trash": [.move(3, 6), .line(21, 6), .move(9, 6), .line(9, 3), .line(15, 3), .line(15, 6), .move(5, 6), .line(6, 21), .line(18, 21), .line(19, 6), .move(10, 10), .line(10, 17), .move(14, 10), .line(14, 17)],
    "edit": [.move(16, 3), .line(21, 8), .line(9, 20), .line(4, 20), .line(4, 15), .close, .move(13, 6), .line(18, 11)],
    "check": [.move(5, 12), .line(9, 16), .line(19, 6)],
    "arrow": [.move(4, 12), .line(20, 12), .move(14, 6), .line(20, 12), .line(14, 18)],
    "send": [.move(3, 3), .line(22, 12), .line(3, 21), .line(7, 12), .close, .move(7, 12), .line(22, 12)],
    "stop": [.move(6, 6), .line(18, 6), .line(18, 18), .line(6, 18), .close],
    "pause": [.move(8, 4), .line(8, 20), .move(16, 4), .line(16, 20)],
    "play": [.move(7, 3), .line(21, 12), .line(7, 21), .close],
    "file": [.move(5, 2), .line(14, 2), .line(19, 7), .line(19, 22), .line(5, 22), .close, .move(14, 2), .line(14, 8), .line(19, 8), .move(8, 13), .line(16, 13), .move(8, 17), .line(13, 17)],
    "extension": [.move(4, 4), .line(9, 4), .line(9, 3), .curve(9, 1.343146, 10.34315, 0, 12, 0), .curve(13.65685, 0, 15, 1.343146, 15, 3), .line(15, 4), .line(20, 4), .line(20, 9), .line(21, 9), .curve(22.65685, 9, 24, 10.34315, 24, 12), .curve(24, 13.65685, 22.65685, 15, 21, 15), .line(20, 15), .line(20, 20), .line(15, 20), .line(15, 19), .curve(15, 17.34315, 13.65685, 16, 12, 16), .curve(10.34315, 16, 9, 17.34315, 9, 19), .line(9, 20), .line(4, 20), .close],
    "sun": [.move(16, 12), .curve(16, 14.20914, 14.20914, 16, 12, 16), .curve(9.790861, 16, 8, 14.20914, 8, 12), .curve(8, 9.790861, 9.790861, 8, 12, 8), .curve(14.20914, 8, 16, 9.790861, 16, 12), .move(12, 2), .line(12, 4), .move(12, 20), .line(12, 22), .move(2, 12), .line(4, 12), .move(20, 12), .line(22, 12), .move(5, 5), .line(6, 6), .move(18, 18), .line(19, 19), .move(5, 19), .line(6, 18), .move(18, 6), .line(19, 5)],
    "moon": [.move(20, 15), .curve(16.67376, 16.03284, 13.05019, 15.05379, 10.69671, 12.48635), .curve(8.343224, 9.918916, 7.682368, 6.224043, 9, 3), .curve(5.006875, 4.239914, 2.393587, 8.066588, 2.691831, 12.23714), .curve(2.990075, 16.40769, 6.121292, 19.82356, 10.25022, 20.48265), .curve(14.37914, 21.14174, 18.41819, 18.87044, 20, 15)],
    "monitor": [.move(3, 4), .line(21, 4), .line(21, 17), .line(3, 17), .close, .move(8, 21), .line(16, 21), .move(12, 17), .line(12, 21)],
    "info": [.move(12, 11), .line(12, 17), .move(12, 7), .line(12.01, 7), .move(21, 12), .curve(21, 16.97056, 16.97056, 21, 12, 21), .curve(7.029437, 21, 3, 16.97056, 3, 12), .curve(3, 7.029437, 7.029437, 3, 12, 3), .curve(16.97056, 3, 21, 7.029437, 21, 12)],
    "alert": [.move(12, 3), .line(22, 21), .line(2, 21), .close, .move(12, 9), .line(12, 14), .move(12, 17), .line(12.01, 17)],
    "minimize": [.move(5, 12), .line(19, 12)],
    "maximize": [.move(5, 5), .line(19, 5), .line(19, 19), .line(5, 19), .close],
    "restore": [.move(8, 3), .line(21, 3), .line(21, 16), .move(3, 8), .line(16, 8), .line(16, 21), .line(3, 21), .close],
    "keyboard": [.move(2, 5), .line(22, 5), .line(22, 19), .line(2, 19), .close, .move(5, 8), .line(5.01, 8), .move(9, 8), .line(9.01, 8), .move(13, 8), .line(13.01, 8), .move(17, 8), .line(17.01, 8), .move(5, 12), .line(5.01, 12), .move(9, 12), .line(9.01, 12), .move(13, 12), .line(13.01, 12), .move(17, 12), .line(17.01, 12), .move(7, 16), .line(17, 16)],
    "eye": [.move(2, 12), .curve(2, 12, 6, 5, 12, 5), .curve(18, 5, 22, 12, 22, 12), .curve(22, 12, 18, 19, 12, 19), .curve(6, 19, 2, 12, 2, 12), .move(15, 12), .curve(15, 13.65685, 13.65685, 15, 12, 15), .curve(10.34315, 15, 9, 13.65685, 9, 12), .curve(9, 10.34315, 10.34315, 9, 12, 9), .curve(13.65685, 9, 15, 10.34315, 15, 12)],
    "coffee": [.move(3, 8), .line(16, 8), .line(16, 16), .curve(16, 18.76142, 13.76142, 21, 11, 21), .line(8, 21), .curve(5.238576, 21, 3, 18.76142, 3, 16), .close, .move(16, 8), .line(18, 8), .curve(19.65685, 8, 21, 9.343146, 21, 11), .curve(21, 12.65685, 19.65685, 14, 18, 14), .line(16, 14), .move(6, 2), .line(6, 5), .move(10, 2), .line(10, 5), .move(14, 2), .line(14, 5)],
    "undo": [.move(3, 4), .line(3, 11), .line(10, 11), .move(3, 11), .curve(3.713052, 7.372239, 6.81913, 4.705646, 10.51303, 4.550005), .curve(14.20692, 4.394364, 17.5263, 6.790223, 18.542, 10.34514), .curve(19.55769, 13.90006, 18.00508, 17.68792, 14.78653, 19.50727), .curve(11.56798, 21.32661, 7.521974, 20.70347, 5, 18)],
    "copy": [.move(9, 9), .line(21, 9), .line(21, 21), .line(9, 21), .close, .move(4, 15), .line(3, 15), .line(3, 3), .line(15, 3), .line(15, 4)],
    "print": [.move(6, 9), .line(6, 3), .line(18, 3), .line(18, 9), .move(6, 17), .line(3, 17), .line(3, 9), .line(21, 9), .line(21, 17), .line(18, 17), .move(6, 14), .line(18, 14), .line(18, 21), .line(6, 21), .close],
    "terminal": [.move(4, 6), .line(10, 12), .line(4, 18), .move(12, 18), .line(20, 18)],
    "mail": [.move(3, 5), .line(21, 5), .line(21, 19), .line(3, 19), .close, .move(3, 5), .line(12, 12), .line(21, 5)],
    "heart": [.move(20.5, 5.5), .curve(18.55578, 3.594286, 15.44422, 3.594286, 13.5, 5.5), .line(12, 7), .line(10.5, 5.5), .curve(8.509398, 4.007049, 5.723926, 4.205006, 3.964466, 5.964466), .curve(2.205006, 7.723926, 2.007049, 10.5094, 3.5, 12.5), .line(12, 21), .line(20.5, 12.5), .curve(22.40571, 10.55578, 22.40571, 7.444218, 20.5, 5.5), .close],
    "plane": [.move(22, 2), .line(15, 22), .line(11, 13), .line(2, 9), .close, .move(11, 13), .line(22, 2)],
    "camera": [.move(3, 7), .line(7, 7), .line(9, 4), .line(15, 4), .line(17, 7), .line(21, 7), .line(21, 21), .line(3, 21), .close, .move(16, 13), .curve(16, 15.20914, 14.20914, 17, 12, 17), .curve(9.790861, 17, 8, 15.20914, 8, 13), .curve(8, 10.79086, 9.790861, 9, 12, 9), .curve(14.20914, 9, 16, 10.79086, 16, 13)],
    "gamepad": [.move(7, 7), .line(17, 7), .curve(20, 7, 22, 19, 19, 19), .line(15, 16), .line(9, 16), .line(5, 19), .curve(2, 19, 4, 7, 7, 7), .close, .move(7, 10), .line(7, 15), .move(4.5, 12.5), .line(9.5, 12.5), .move(16, 11), .line(16.01, 11), .move(19, 14), .line(19.01, 14)],
    "palette": [.move(12, 3), .curve(7.029437, 3, 3, 7.029437, 3, 12), .curve(3, 16.97056, 7.029437, 21, 12, 21), .line(14, 21), .curve(15.10457, 21, 16, 20.10457, 16, 19), .curve(16, 17.89543, 15.10457, 17, 14, 17), .curve(12.89543, 17, 12, 16.10457, 12, 15), .curve(12, 13.89543, 12.89543, 13, 14, 13), .line(17, 13), .curve(19.20914, 13, 21, 11.20914, 21, 9), .curve(21, 6, 17, 3, 12, 3), .close, .move(7, 8), .line(7.01, 8), .move(12, 6), .line(12.01, 6), .move(6, 13), .line(6.01, 13), .move(17, 8), .line(17.01, 8)],
    "beaker": [.move(8, 3), .line(16, 3), .move(9, 3), .line(9, 10), .line(3, 20), .line(21, 20), .line(15, 10), .line(15, 3), .move(7, 14), .line(17, 14)],
    "rocket": [.move(14, 4), .curve(17, 2, 20, 2, 21, 3), .curve(22, 4, 22, 7, 20, 10), .line(12, 18), .line(6, 12), .close, .move(14, 4), .line(7, 4), .line(3, 11), .line(8, 12), .move(20, 10), .line(20, 17), .line(13, 21), .line(12, 16), .move(5, 16), .line(3, 21), .line(8, 19), .move(17, 6), .line(17.01, 6)],
    "compass": [.move(21, 12), .curve(21, 16.97056, 16.97056, 21, 12, 21), .curve(7.029437, 21, 3, 16.97056, 3, 12), .curve(3, 7.029437, 7.029437, 3, 12, 3), .curve(16.97056, 3, 21, 7.029437, 21, 12), .move(16, 8), .line(13, 13), .line(8, 16), .line(11, 11), .close],
    "mountain": [.move(2, 20), .line(9, 6), .line(14, 15), .line(17, 10), .line(22, 20), .close, .move(6, 12), .line(9, 14), .line(12, 12)],
    "flame": [.move(12, 2), .curve(13, 8, 7, 9, 7, 14), .curve(7, 16.76142, 9.238576, 19, 12, 19), .curve(14.76142, 19, 17, 16.76142, 17, 14), .curve(17, 11, 16, 9, 15, 7), .curve(15, 11, 13, 11, 13, 11), .curve(14, 7, 13, 4, 12, 2), .close],
    "cloud": [.move(6, 19), .curve(3.238576, 19.27614, 0.7761424, 17.26142, 0.5, 14.5), .curve(0.2238576, 11.73858, 2.238576, 9.276142, 5, 9), .curve(5.840733, 6.243312, 8.285111, 4.283661, 11.15866, 4.062619), .curve(14.03221, 3.841576, 16.74755, 5.404326, 18, 8), .curve(21.03757, 8, 23.5, 10.46243, 23.5, 13.5), .curve(23.5, 16.53757, 21.03757, 19, 18, 19), .close],
    "bolt": [.move(13, 2), .line(4, 14), .line(11, 14), .line(10, 22), .line(20, 9), .line(12, 9), .close],
    "diamond": [.move(12, 2), .line(22, 12), .line(12, 22), .line(2, 12), .close],
    "flower": [.move(12, 8), .curve(4, -4, -1, 9, 7, 12), .curve(-1, 15, 4, 28, 12, 16), .curve(20, 28, 25, 15, 17, 12), .curve(25, 9, 20, -4, 12, 8), .close, .move(14, 12), .curve(14, 13.10457, 13.10457, 14, 12, 14), .curve(10.89543, 14, 10, 13.10457, 10, 12), .curve(10, 10.89543, 10.89543, 10, 12, 10), .curve(13.10457, 10, 14, 10.89543, 14, 12)],
    "smile": [.move(21, 12), .curve(21, 16.97056, 16.97056, 21, 12, 21), .curve(7.029437, 21, 3, 16.97056, 3, 12), .curve(3, 7.029437, 7.029437, 3, 12, 3), .curve(16.97056, 3, 21, 7.029437, 21, 12), .move(8, 9), .line(8.01, 9), .move(16, 9), .line(16.01, 9), .move(8, 14), .curve(10.66667, 17.33333, 13.33333, 17.33333, 16, 14)],
    "headphones": [.move(4, 14), .line(4, 11), .curve(4, 6.581722, 7.581722, 3, 12, 3), .curve(16.41828, 3, 20, 6.581722, 20, 11), .line(20, 14), .move(4, 12), .line(7, 12), .line(7, 21), .line(4, 21), .curve(2.895431, 21, 2, 20.10457, 2, 19), .line(2, 14), .curve(2, 12.89543, 2.895431, 12, 4, 12), .move(20, 12), .line(17, 12), .line(17, 21), .line(20, 21), .curve(21.10457, 21, 22, 20.10457, 22, 19), .line(22, 14), .curve(22, 12.89543, 21.10457, 12, 20, 12)],
    "calendar": [.move(3, 5), .line(21, 5), .line(21, 21), .line(3, 21), .close, .move(3, 10), .line(21, 10), .move(8, 2), .line(8, 8), .move(16, 2), .line(16, 8), .move(8, 14), .line(8.01, 14), .move(12, 14), .line(12.01, 14), .move(16, 14), .line(16.01, 14), .move(8, 18), .line(8.01, 18), .move(12, 18), .line(12.01, 18)],
    "film": [.move(3, 3), .line(21, 3), .line(21, 21), .line(3, 21), .close, .move(7, 3), .line(7, 21), .move(17, 3), .line(17, 21), .move(3, 8), .line(7, 8), .move(3, 16), .line(7, 16), .move(17, 8), .line(21, 8), .move(17, 16), .line(21, 16)],
    "building": [.move(4, 21), .line(4, 7), .line(10, 7), .line(10, 3), .line(20, 3), .line(20, 21), .move(2, 21), .line(22, 21), .move(14, 7), .line(16, 7), .move(14, 11), .line(16, 11), .move(14, 15), .line(16, 15), .move(7, 11), .line(7.01, 11), .move(7, 15), .line(7.01, 15), .move(10, 21), .line(10, 17), .line(14, 17), .line(14, 21)],
    "bag": [.move(4, 7), .line(20, 7), .line(21, 21), .line(3, 21), .close, .move(8, 8), .line(8, 6), .curve(8, 3.790861, 9.790861, 2, 12, 2), .curve(14.20914, 2, 16, 3.790861, 16, 6), .line(16, 8)],
  ]
}
private struct GlyphPath: Shape {
  let commands: [NativeGlyph.Command]
  func path(in rect: CGRect) -> Path {
    var path = Path()
    for command in commands {
      switch command {
      case .move(let x, let y): path.move(to: CGPoint(x: x, y: y))
      case .line(let x, let y): path.addLine(to: CGPoint(x: x, y: y))
      case .curve(let x1, let y1, let x2, let y2, let x, let y):
        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
      case .close: path.closeSubpath()
      }
    }
    return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
  }
}
