import AppKit
import Foundation

// Pure event-value regression. This does not send or post keyboard input.
@main struct ShortcutMatcherAcceptance {
  static func main() throws {
    func check(_ value: Bool) { precondition(value) }
    func binding(_ code: Int, _ flags: NSEvent.ModifierFlags) throws -> ChromeExtensionShortcut {
      let value: [String: Any] = ["extensionID": String(repeating: "a", count: 32),
        "incarnationID": "fixture:1", "name": "fixture", "keybinding": "Command+Y",
        "keyCode": code, "shift": flags.contains(.shift), "control": flags.contains(.control),
        "alt": flags.contains(.option), "command": flags.contains(.command), "isAction": false]
      return try JSONDecoder().decode(ChromeExtensionShortcut.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func event(_ key: UInt16, _ characters: String, _ ignoring: String,
               _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> NSEvent {
      NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: ignoring,
        isARepeat: false, keyCode: key)!
    }
    let command: NSEvent.ModifierFlags = [.command], shifted: NSEvent.ModifierFlags = [.command, .shift]
    let y = try binding(89, command)
    check(y.matches(event(16, "y", "y", command)))
    check(!y.matches(event(16, "Y", "y", shifted)))
    check(!y.matches(event(16, "y", "y", command, type: .keyUp)))
    // Dvorak-QWERTY Command uses the generated character before the underlying
    // physical key or charactersIgnoringModifiers, just as Chromium does.
    check(y.matches(event(17, "y", "t", command)))
    check(try binding(49, shifted).matches(event(18, "!", "!", shifted)))
    check(!(try binding(49, command).matches(event(83, "1", "1", command))))
    check(try binding(97, command).matches(event(83, "1", "1", command)))
    check(try binding(188, shifted).matches(event(43, "<", ",", shifted)))
    check(try binding(65, command).matches(event(0, "å", "a", command)))
    check(try binding(37, command).matches(event(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), "", command)))
    print("10 native shortcut matching checks passed")
  }
}
