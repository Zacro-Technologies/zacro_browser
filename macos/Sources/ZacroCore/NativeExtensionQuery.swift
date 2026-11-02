import Foundation
import CoreFoundation

/// Filters only non-sensitive tab fields. Chromium validates match patterns and
/// filters URL/title after applying the extension caller's actual permissions.
public enum NativeExtensionQuery {
  public struct InvalidQuery: Error, LocalizedError, Equatable {
    public let field: String
    public var errorDescription: String? { "Invalid tab query field: \(field)." }
  }
  private static let booleans: Set<String> = ["active", "audible", "autoDiscardable", "currentWindow", "discarded", "frozen", "highlighted", "lastFocusedWindow", "muted", "pinned"]
  private static let integers: Set<String> = ["index", "windowId", "groupId", "splitViewId"]
  private static let strings: Set<String> = ["status", "windowType", "title"]

  public static func matches(query: [String: Any], tab: [String: Any], currentWindowID: Int = 1,
                             lastFocusedWindowID: Int?, windowType: String = "normal") throws -> Bool {
    // Validate the entire query before matching. An earlier false field must
    // not hide a malformed later field or a property we do not implement.
    for key in query.keys.sorted() {
      let value = query[key]!
      if booleans.contains(key) {
        guard boolean(value) != nil else { throw InvalidQuery(field:key) }
      } else if integers.contains(key) {
        guard integer(value) != nil else { throw InvalidQuery(field:key) }
      } else if strings.contains(key) {
        guard value is String else { throw InvalidQuery(field:key) }
      } else if key == "url" {
        guard value is String || (value as? [Any])?.allSatisfy({ $0 is String }) == true else { throw InvalidQuery(field:key) }
      } else { throw InvalidQuery(field:key) }
    }
    for (key, value) in query {
      if key == "url" || key == "title" { continue }
      if let expected = boolean(value), booleans.contains(key) {
        let actual: Bool?
        switch key {
        case "currentWindow", "lastFocusedWindow":
          guard let window = integer(tab["windowId"]) else { return false }
          actual = key == "currentWindow" ? window == currentWindowID : lastFocusedWindowID == window
        case "muted":
          let details = tab["mutedInfo"] as? [String: Any]
          actual = boolean(details?["muted"] ?? tab["muted"])
        default: actual = boolean(tab[key])
        }
        guard actual == expected else { return false }
      } else if let expected = integer(value), integers.contains(key) {
        guard let actual = integer(tab[key]) else { return false }
        if key == "windowId" {
          if expected == -1 { return false }
          guard actual == (expected == -2 ? currentWindowID : expected) else { return false }
        } else if actual != expected { return false }
      } else if let expected = value as? String {
        let actual = key == "windowType" ? windowType : tab[key] as? String
        guard actual == expected else { return false }
      }
    }
    return true
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }
  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString:number.objCType)),
      number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { return nil }
    return number.intValue
  }
}
