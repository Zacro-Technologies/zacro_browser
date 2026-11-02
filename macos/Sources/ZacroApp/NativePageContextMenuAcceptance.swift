import Foundation
import ZacroChromium

/// Pure menu-policy/coordinate checks. Native clipboard and pointer execution
/// remain separate packaged-runtime and physical-input acceptance gates.
enum NativePageContextMenuAcceptance {
  static func check() -> [String: Bool] {
    typealias Policy = ChromiumPageContextMenuPolicy
    func params(_ value: String?, x: Int = 0, y: Int = 0) -> CefContextMenuParams {
      CefContextMenuParams(x: x, y: y, linkURL: value.flatMap(URL.init(string:)))
    }
    let web = params("https://example.com/path?q=one#section", x: 43, y: 67)
    var result: [String: Bool] = [:]
    result["pageMenuWebLinksUseReferenceActionsAndOrder"] = Policy.linkCommands(web)
      == [.open, .background, .peek, .copyAddress]
    result["pageMenuWebLinkKeepsExactDestination"] = Policy.webLink(web)?.absoluteString
      == "https://example.com/path?q=one#section"
    result["pageMenuRejectsUnsupportedAndMissingLinkActions"] = [nil, "mailto:user@example.com",
      "file:///tmp/image.png", "data:text/plain,hello", "javascript:alert(1)", "about:blank",
      "chrome://settings", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/page.html",
      "/relative", "https:///missing-host"].allSatisfy { value in
        Policy.linkCommands(params(value)).isEmpty && Policy.webLink(params(value)) == nil
      }
    result["pageMenuRejectsCredentialBearingLinkActions"] = ["https://user@example.com",
      "https://user:pass@example.com", "https://@example.com", "https://:pass@example.com"].allSatisfy {
        Policy.linkCommands(params($0)).isEmpty && Policy.webLink(params($0)) == nil
      }
    result["pageMenuAcceptsHTTPAndIPv6Destinations"] = ["http://example.com", "https://[::1]:8443/"].allSatisfy {
      Policy.linkCommands(params($0)).count == 4
    }
    let commands = Policy.LinkCommand.allCases
    result["pageMenuCustomCommandIdentifiersRemainStable"] = commands.map(\.commandID)
      == (0...3).map { CefMenuModel.userCommandIDFirst + $0 }
      && Set(commands.map(\.commandID)).count == 4
    result["pageMenuPeekCarriesOriginalInvocationPoint"] = Policy.invocationPoint(web) == CGPoint(x: 43, y: 67)
    result["pageMenuPeekViewportAccountsForLeftPanel"] = Policy.viewportPoint(CGPoint(x: 43, y: 67),
      documentBounds: CGRect(x: 280, y: 6, width: 600, height: 700)) == CGPoint(x: 323, y: 73)
    result["pageMenuPeekViewportDoesNotScaleByZoom"] = Policy.viewportPoint(CGPoint(x: 43, y: 67),
      documentBounds: CGRect(x: 0, y: 0, width: 600, height: 700)) == CGPoint(x: 43, y: 67)
      && Policy.viewportPoint(CGPoint(x: 43, y: 67), documentBounds: nil) == CGPoint(x: 43, y: 67)
    result["pageMenuPeekRejectsInvalidGeometry"] = Policy.viewportPoint(CGPoint(x: CGFloat.infinity, y: 0), documentBounds: nil) == nil
      && Policy.viewportPoint(.zero, documentBounds: .zero) == nil
    return result
  }
}
