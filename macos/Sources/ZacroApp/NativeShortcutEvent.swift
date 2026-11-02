import AppKit

/// Browser accelerators follow Electron's KeyboardEvent.code contract. This is
/// independent of Chromium extension commands and never handles text composition.
enum NativeShortcutEvent {
  private static let modifiers: [(NSEvent.ModifierFlags, String)] = [
    (.control, "Ctrl"), (.command, "Mod"), (.option, "Alt"), (.shift, "Shift")
  ]
  private static let physical: [UInt16: String] = [
    0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
    12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U", 34:"I", 35:"P",
    37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 18:"1", 19:"2", 20:"3", 21:"4", 23:"5",
    22:"6", 26:"7", 28:"8", 25:"9", 29:"0", 24:"=", 27:"-", 33:"[", 30:"]", 43:",",
    47:".", 44:"/", 42:"\\", 41:";", 39:"'", 50:"`"
  ]
  private static let named: [UInt16: String] = [
    123:"Left", 124:"Right", 125:"Down", 126:"Up", 48:"Tab", 36:"Enter", 76:"Enter",
    53:"Escape", 49:"Space", 51:"Backspace", 117:"Delete", 115:"Home", 119:"End",
    116:"PageUp", 121:"PageDown", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5",
    97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12",
    105:"F13", 107:"F14", 113:"F15", 106:"F16", 64:"F17", 79:"F18", 80:"F19", 90:"F20"
  ]

  static func recordedAccelerator(_ event: NSEvent) -> String? {
    guard event.type == .keyDown, !event.isARepeat,
      let characters = event.characters, !characters.isEmpty,
      !["Dead", "Unidentified"].contains(characters) else { return nil }
    return accelerator(event, usePhysicalKey: true)
  }

  static func matchingAccelerator(_ event: NSEvent) -> String? {
    guard event.type == .keyDown else { return nil }
    let physicalKey = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    return accelerator(event, usePhysicalKey: physicalKey)
  }

  static func menuKeyEquivalent(_ key: String) -> String? {
    if key.count == 1 { return key.lowercased() }
    if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...24).contains(number), key == "F\(number)" {
      return String(UnicodeScalar(0xF704 + number - 1)!)
    }
    let namedCharacters: [String: UInt32] = [
      "Left": 0xF702, "Right": 0xF703, "Up": 0xF700, "Down": 0xF701,
      "Home": 0xF729, "End": 0xF72B, "PageUp": 0xF72C, "PageDown": 0xF72D,
      "Insert": 0xF727, "Delete": 0xF728, "Backspace": 0x08,
      "Tab": 0x09, "Enter": 0x0D, "Escape": 0x1B, "Space": 0x20
    ]
    return namedCharacters[key].flatMap(UnicodeScalar.init).map(String.init)
  }

  private static func accelerator(_ event: NSEvent, usePhysicalKey: Bool) -> String? {
    let characters = event.charactersIgnoringModifiers ?? event.characters ?? ""
    // F21–F24 have no ANSI virtual-key constants; AppKit supplies their public
    // function-key Unicode values, including on extended/remapped keyboards.
    let function: String? = characters.unicodeScalars.count == 1
      ? characters.unicodeScalars.first.flatMap { scalar in
        (0xF704...0xF71B).contains(scalar.value) ? "F\(scalar.value - 0xF704 + 1)" : nil
      } : nil
    let key: String
    if let special = function ?? named[event.keyCode] { key = special }
    else if usePhysicalKey, let code = physical[event.keyCode] { key = code }
    else {
      guard characters.count == 1, !characters.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
      }) else { return nil }
      key = characters == "+" ? "=" : characters.uppercased()
    }
    return (modifiers.compactMap { event.modifierFlags.contains($0.0) ? $0.1 : nil } + [key])
      .joined(separator: "+")
  }
}
