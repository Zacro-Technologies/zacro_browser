import Foundation

/// The renderer's fuzzyScore contract, including JavaScript's UTF-16 offsets.
/// Keep this in sync with src/renderer/app.js through the reference corpus.
enum NativeCommandSearchMatching {
  private static let caseLocale = Locale(identifier: "und")
  static func trimmedQuery(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    let start = scalars.firstIndex { !isWhitespace($0.value) } ?? scalars.endIndex
    let end = scalars.lastIndex { !isWhitespace($0.value) }.map { $0 + 1 } ?? start
    return String(String.UnicodeScalarView(scalars[start..<end]))
  }

  static func score(_ query: String, _ value: String) -> Double {
    let normalizedQuery = normalize(query)
    let queryUnits = Array(normalizedQuery.utf16), text = Array(normalize(value).utf16)
    guard !queryUnits.isEmpty else { return 0 }
    if text == queryUnits { return 160 }
    if text.starts(with: queryUnits) { return 125 - min(15, Double(text.count - queryUnits.count) / 8) }
    func boundary(_ index: Int) -> Bool {
      index == 0 || isWhitespace(UInt32(text[index - 1])) || [46, 47, 58, 95, 45].contains(text[index - 1])
    }
    if let at = firstIndex(of: queryUnits, in: text) {
      return (boundary(at) ? 105 : 82) - min(20, Double(at) / 3)
    }
    let words = Array(normalizedQuery.unicodeScalars).split { isWhitespace($0.value) }
    var total = 0.0
    for word in words {
      var cursor = 0, previous = -2, length = 0
      var score = 0.0
      // JS for...of visits code points, but indexOf/cursor/length use UTF-16.
      for scalar in word {
        let units = Array(String(scalar).utf16)
        length += units.count
        guard let found = firstIndex(of: units, in: text, from: cursor) else { return -1 }
        score += found == previous + 1 ? 9 : boundary(found) ? 8 : 2
        score -= min(5, Double(found - cursor) / 5)
        previous = found; cursor = found + 1
      }
      total += min(70, 35 + score - Double(text.count - length) / 12)
    }
    return total / Double(words.count)
  }

  private static func normalize(_ value: String) -> String {
    let scalars = value.decomposedStringWithCompatibilityMapping.unicodeScalars.filter {
      !(0x0300...0x036F).contains($0.value)
    }
    // Foundation's root-locale conversion retains Unicode contextual rules
    // (for example final Greek sigma). Swift's scalar conversion does not.
    return String(String.UnicodeScalarView(scalars)).lowercased(with: caseLocale)
  }

  private static func firstIndex(of needle: [UInt16], in text: [UInt16], from start: Int = 0) -> Int? {
    guard !needle.isEmpty, start >= 0, start <= text.count - needle.count else { return nil }
    for index in start...(text.count - needle.count) where text[index] == needle[0] {
      if needle.indices.allSatisfy({ text[index + $0] == needle[$0] }) { return index }
    }
    return nil
  }

  // ECMAScript \s deliberately excludes U+0085 and includes U+FEFF.
  private static func isWhitespace(_ value: UInt32) -> Bool {
    switch value {
    case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
      0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
    default: return false
    }
  }
}
