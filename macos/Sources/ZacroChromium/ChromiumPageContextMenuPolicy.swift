import Foundation
import CefKit

/// Host-owned link actions only. Chromium retains image clipboard/download,
/// editing, spelling and installed-extension commands in its native menu.
public enum ChromiumPageContextMenuPolicy {
  public enum LinkCommand: Int, CaseIterable, Sendable {
    case peek = 0, open = 1, background = 2, copyAddress = 3

    public var commandID: Int { CefMenuModel.userCommandIDFirst + rawValue }
    public var title: String {
      switch self {
      case .peek: return "Peek at link"
      case .open: return "Open link in new tab"
      case .background: return "Open link in background"
      case .copyAddress: return "Copy link address"
      }
    }
  }

  /// Matches the original renderer/main-process web-link boundary at both
  /// presentation and dispatch; a visible custom item must be actionable.
  public static func webLink(_ params: CefContextMenuParams) -> URL? {
    guard let url = params.linkURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
    return url
  }

  public static func linkCommands(_ params: CefContextMenuParams) -> [LinkCommand] {
    webLink(params) == nil ? [] : [.open, .background, .peek, .copyAddress]
  }

  /// CEF already transforms nested-frame coordinates into the root renderer
  /// view. They are top-left view points, not CSS pixels: never scale by zoom.
  public static func invocationPoint(_ params: CefContextMenuParams) -> CGPoint {
    CGPoint(x: params.x, y: params.y)
  }

  /// documentBounds is the native WebContents slot relative to its hosted
  /// BrowserView, including any left-side extension panel. The caller then
  /// converts this viewport point through the exact owning native window.
  public static func viewportPoint(_ point: CGPoint, documentBounds: CGRect?) -> CGPoint? {
    guard point.x.isFinite, point.y.isFinite else { return nil }
    guard let bounds = documentBounds else { return point }
    guard bounds.minX.isFinite, bounds.minY.isFinite,
      bounds.width.isFinite, bounds.height.isFinite,
      bounds.width > 0, bounds.height > 0 else { return nil }
    let result = CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y)
    return result.x.isFinite && result.y.isFinite ? result : nil
  }
}
