import AppKit
import Foundation

/// An active binding supplied by Chromium's CommandService. Global bindings
/// are handled by Chromium's OS registry and never appear in this snapshot.
public struct ChromeExtensionShortcut: Decodable, Sendable {
  public let extensionID: String
  public let incarnationID: String
  public let name: String
  public let keybinding: String
  public let keyCode: Int
  public let shift: Bool
  public let control: Bool
  public let alt: Bool
  public let command: Bool
  public let isAction: Bool

  public func matches(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let flags = event.modifierFlags
    guard shift == flags.contains(.shift), control == flags.contains(.control),
      alt == flags.contains(.option), command == flags.contains(.command) else { return false }
    return Self.chromiumKeyCode(event) == keyCode && keyCode != 0
  }

  // Follow Chromium 156's KeyboardCodeFromNSEvent ordering. In particular,
  // number-row/keypad keys retain their physical numeric identity, while
  // Dvorak-QWERTY Command uses characters before charactersIgnoringModifiers.
  // The values are the platform-independent Chromium/Windows virtual key IDs.
  private static func chromiumKeyCode(_ event: NSEvent) -> Int {
    let physical = Int(event.keyCode)
    let numeric: Set<Int> = [18,19,20,21,22,23,25,26,28,29,
      65,67,69,71,75,76,78,81,82,83,84,85,86,87,88,89,91,92]
    if !numeric.contains(physical) {
      if let code = characterCode(event.characters) { return code }
      if let code = characterCode(event.charactersIgnoringModifiers) { return code }
    }
    return physical < nativeCodes.count ? nativeCodes[physical] : 0
  }
  private static func characterCode(_ text: String?) -> Int? {
    guard let value = text?.utf16.first else { return nil }
    switch value {
    case 65...90, 48...57: return Int(value)
    case 97...122: return Int(value - 32)
    case 59,58: return 186
    case 61,43: return 187
    case 44,60: return 188
    case 45,95: return 189
    case 46,62: return 190
    case 47,63: return 191
    case 96,126: return 192
    case 91,123: return 219
    case 92,124: return 220
    case 93,125: return 221
    case 39,34: return 222
    case UInt16(NSPauseFunctionKey): return 19
    case UInt16(NSSelectFunctionKey): return 41
    case UInt16(NSPrintFunctionKey): return 42
    case UInt16(NSExecuteFunctionKey): return 43
    case UInt16(NSPrintScreenFunctionKey): return 44
    case UInt16(NSInsertFunctionKey): return 45
    case UInt16(NSF21FunctionKey): return 132
    case UInt16(NSF22FunctionKey): return 133
    case UInt16(NSF23FunctionKey): return 134
    case UInt16(NSF24FunctionKey): return 135
    case UInt16(NSScrollLockFunctionKey): return 145
    default: return nil
    }
  }
  private static let nativeCodes: [Int] = [
    65,83,68,70,72,71,90,88,67,86,192,66,81,87,69,82,
    89,84,49,50,51,52,54,53,187,57,55,189,56,48,221,79,
    85,219,73,80,13,76,74,222,75,186,220,188,191,78,77,190,
    9,32,192,8,0,27,93,91,16,20,18,17,16,18,17,0,
    128,110,0,106,0,107,0,12,175,174,173,111,13,0,109,129,
    130,187,96,97,98,99,100,101,102,103,131,104,105,0,0,0,
    116,117,118,114,119,120,0,122,0,124,127,125,0,121,93,123,
    0,126,45,36,33,46,115,35,113,34,112,37,39,40,38,0
  ]
}
