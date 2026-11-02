import AppKit

enum NativeKeyBinding {
  static func candidates(_ event: NSEvent) -> Set<String> {
    var modifiers: [String] = []
    for (flag, name): (NSEvent.ModifierFlags, String) in [(.control, "Ctrl"), (.command, "Mod"), (.option, "Alt"), (.shift, "Shift")] {
      if event.modifierFlags.contains(flag) { modifiers.append(name) }
    }
    let special: [UInt16: String] = [123:"Left",124:"Right",125:"Down",126:"Up",48:"Tab",36:"Enter",76:"Enter",53:"Escape",49:"Space",51:"Backspace",117:"Delete",115:"Home",119:"End",116:"PageUp",121:"PageDown",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
    if let key = special[event.keyCode] { return [(modifiers + [key]).joined(separator: "+")] }
    var keys = Set<String>()
    if let key = event.charactersIgnoringModifiers, key.count == 1 {
      let unshifted = ["+":"=", "_":"-", "{":"[", "}":"]", ":":";", "\"":"'", "<":",", ">":".", "?":"/", "~":"`", "|":"\\"]
      keys.insert(unshifted[key] ?? key.uppercased())
    }
    // Command shortcuts remain usable with a non-Latin keyboard layout, as in Chromium.
    if event.modifierFlags.contains(.command), keys.allSatisfy({ !$0.unicodeScalars.allSatisfy(\.isASCII) }) {
      let physical: [UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M"]
      if let key = physical[event.keyCode] { keys.insert(key) }
    }
    return Set(keys.map { (modifiers + [$0]).joined(separator: "+") })
  }
}
