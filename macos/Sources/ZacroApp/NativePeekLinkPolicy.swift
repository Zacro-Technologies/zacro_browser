import Foundation
import ZacroCore

struct NativePeekLinkSnapshot: Equatable {
  let pageID: String
  let profileID: String
  let ownerWindowID: String
  let sourceURL: String
  let pinnedURL: String?
  let visible: Bool
}

/// These facts come only from our binding in the main frame's isolated world.
/// The bridge also validates the native document/context, not just this payload.
struct NativePeekLinkClick: Decodable {
  let nonce: String
  let sequence: Int
  let kind: String
  let sourceURL: String
  let url: String
  let trusted: Bool
  let button: Int
  let shift: Bool
  let alt: Bool
  let control: Bool
  let meta: Bool
  let download: Bool
  let defaultPrevented: Bool
  let target: String
  let rel: String
  let x: Double
  let y: Double
}

enum NativePeekLinkPolicy {
  static func destination(_ click: NativePeekLinkClick, snapshot: NativePeekLinkSnapshot) -> URL? {
    guard snapshot.visible, click.sourceURL == snapshot.sourceURL, click.trusted, click.button == 0,
      !click.control, !click.meta, !click.download,
      click.x.isFinite, click.y.isFinite, abs(click.x) <= 1_000_000, abs(click.y) <= 1_000_000,
      click.url.utf16.count <= 8_192, let destination = BrowserAddress.webURL(click.url) else { return nil }
    if click.kind == "modified" {
      return click.shift != click.alt ? destination : nil
    }
    guard click.kind == "pinned", !click.shift, !click.alt, !click.defaultPrevented,
      click.target.isEmpty || click.target.lowercased() == "_self",
      !hasOpenerExclusion(click.rel), let pinned = snapshot.pinnedURL.flatMap(BrowserAddress.webURL),
      host(destination) != host(pinned) else { return nil }
    return destination
  }

  private static func host(_ url: URL) -> String {
    let value = (url.host ?? "").lowercased()
    return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
  }

  private static func hasOpenerExclusion(_ value: String) -> Bool {
    value.unicodeScalars.split { scalar in
      switch scalar.value {
      case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
      default: return false
      }
    }.contains { token in
      let word = String(String.UnicodeScalarView(token)).lowercased()
      return word == "noopener" || word == "noreferrer"
    }
  }
}
