import AppKit
import Foundation

/// Renders only this disposable test application's own NSView trees. This is
/// not a desktop screenshot and does not certify native child-window composition
/// or physical input. Chromium's separately hosted page windows are excluded.
@MainActor
enum NativeViewRenderEvidence {
  static func capture(_ name: String, window: NSWindow) throws {
    guard CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_RENDER_EVIDENCE"] == "1",
      let report = ProcessInfo.processInfo.environment["ZACRO_ACCEPTANCE_OUTPUT"] else { return }
    let directory = URL(fileURLWithPath: report).deletingLastPathComponent().appendingPathComponent("view-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var windows = [window]
    func appendPanels(_ owner: NSWindow) {
      for child in owner.childWindows ?? [] where child is NSPanel && child.isVisible {
        windows.append(child); appendPanels(child)
      }
    }
    appendPanels(window)
    var records: [[String: Any]] = []
    for (index, item) in windows.enumerated() {
      guard let view = item.contentView, view.bounds.width > 1, view.bounds.height > 1 else { continue }
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
      let file = name + "-" + String(index) + ".png"
      try png.write(to: directory.appendingPathComponent(file), options: .atomic)
      records.append(["file": file, "width": view.bounds.width, "height": view.bounds.height,
        "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
        "kind": index == 0 ? "owned-window-view" : "owned-panel-view"])
    }
    let metadata: [String: Any] = ["captures": records, "desktopScreenshot": false,
      "nativeWebDocumentsIncluded": false, "desktopInputVerified": false,
      "materialCompositingVerified": false]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
  }
}
