import Foundation

/// Failure of the actual main-frame document. Native host operation errors
/// (for example a cancelled close preparation) never populate this value.
public struct ChromiumDocumentError: Equatable, Sendable {
  public let url: URL?
  public let code: Int
  public let message: String
  public let isRendererTermination: Bool

  public init(url: URL?, code: Int, message: String, isRendererTermination: Bool = false) {
    self.url = url
    self.code = code
    self.message = message
    self.isRendererTermination = isRendererTermination
  }
}
