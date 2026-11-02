import AppKit
import Foundation

/// One native shell in the shared Chromium process. Moving a document between
/// contexts preserves its renderer, navigation history and extension tab ID.
@MainActor
public final class ChromiumWindowContext: NSObject, NSWindowDelegate {
  public internal(set) var id: String
  public internal(set) var nativeID: Int
  public let window: NSWindow
  public internal(set) var isOpen = true
  public internal(set) var isClosing = false
  public var onLayout: (() -> Void)?
  public var onClosed: (() -> Void)?
  public var onCloseCancelled: (() -> Void)?
  public var onFocused: (() -> Void)?
  public var beforeClosingDocuments: (() async -> Bool)?
  weak var engine: ChromiumEngine?
  var closingPreparation: Task<Bool, Never>?

  init(id: String, nativeID: Int, engine: ChromiumEngine) {
    self.id = id
    self.nativeID = nativeID
    self.engine = engine
    window = NSWindow(
      contentRect: CGRect(x: 80, y: 80, width: 1280, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init()
    window.title = "Zacro"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 680, height: 480)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.delegate = self
  }

  public func show() { engine?.showWindow(id: id) }
  public func close() { engine?.closeWindow(id: id) }
  public func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
  public func windowDidResize(_ notification: Notification) { onLayout?() }
  public func windowDidMove(_ notification: Notification) { onLayout?() }
  public func windowDidBecomeKey(_ notification: Notification) { engine?.windowDidFocus(id: id) }
}
