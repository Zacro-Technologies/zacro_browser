import AppKit

/// Editing belongs to AppKit's focused responder, including Chromium's native
/// RenderWidgetHostViewCocoa and ordinary browser text fields. A nil target
/// preserves AppKit's key-then-main responder search during menu tracking.
enum NativeEditingMenu {
  static func action(for id: String) -> Selector? {
    let names = ["undo": "undo:", "redo": "redo:", "cut": "cut:", "copy": "copy:",
      "paste": "paste:", "paste-match-style": "pasteAndMatchStyle:", "select-all": "selectAll:"]
    return names[id].map(NSSelectorFromString)
  }

  @MainActor static func configure(_ item: NSMenuItem, id: String) {
    item.action = action(for: id)
    // Cocoa's text system and Chromium name this one action differently.
    // Keep ordinary editing entirely on the native nil-target chain.
    item.target = id == "paste-match-style" ? styleDispatcher : nil
  }

  @MainActor @discardableResult static func perform(_ id: String, sender: Any?) -> Bool {
    if id == "paste-match-style" { return styleDispatcher.perform(sender) }
    guard let action = action(for: id) else { return false }
    return NSApp.sendAction(action, to: nil, from: sender)
  }

  @MainActor static func matchStyleTarget() -> (target: NSObject, action: Selector)? {
    let native = NSSelectorFromString("pasteAndMatchStyle:")
    let plain = NSSelectorFromString("pasteAsPlainText:")
    if let window = NSApp.keyWindow {
      var next = window.firstResponder
      var visited = Set<ObjectIdentifier>()
      while let responder = next, visited.count < 128, visited.insert(ObjectIdentifier(responder)).inserted {
        if responder is NSTextView, responder.responds(to: plain) { return (responder, plain) }
        if responder.responds(to: native) { return (responder, native) }
        if responder.responds(to: plain) { return (responder, plain) }
        if responder === window { break }
        next = responder.nextResponder
      }
    }
    for selector in [native, plain] {
      if let target = NSApp.target(forAction: selector) as? NSObject { return (target, selector) }
    }
    return nil
  }

  @MainActor private static let styleDispatcher = MatchStyleDispatcher()

  @MainActor private final class MatchStyleDispatcher: NSObject, NSMenuItemValidation {
    @objc func pasteAndMatchStyle(_ sender: Any?) { _ = perform(sender) }
    func perform(_ sender: Any?) -> Bool {
      guard let destination = NativeEditingMenu.matchStyleTarget() else { return false }
      return NSApp.sendAction(destination.action, to: destination.target, from: sender)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
      guard let destination = NativeEditingMenu.matchStyleTarget() else { return false }
      let nativeItem = NSMenuItem(title: item.title, action: destination.action, keyEquivalent: "")
      if let validator = destination.target as? NSMenuItemValidation { return validator.validateMenuItem(nativeItem) }
      if let validator = destination.target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(nativeItem) }
      return true
    }
  }
}
