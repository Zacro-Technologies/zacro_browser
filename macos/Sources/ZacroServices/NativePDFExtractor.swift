import Foundation

public struct NativePDFText: Sendable {
  public let text: String
  public let pages: [(page: Int,text: String)]
  public let totalPages: Int
  public let truncated: Bool
}

/// Parse untrusted PDF bytes in a disposable native helper, never on the browser UI or engine process.
public struct NativePDFExtractor: Sendable {
  public static let maximumBytes = 20 * 1024 * 1024
  private let executable: URL?
  private let directory: URL
  public init(directory: URL, executable: URL? = Bundle.main.resourceURL?.appendingPathComponent("Providers/ZacroTextExtractor")) {
    self.directory = directory; self.executable = executable
  }
  public func extract(_ bytes: Data, maxPages: Int = 100, maxCharacters: Int = 60_000) async throws -> NativePDFText {
    guard bytes.count <= Self.maximumBytes else { throw ServiceError("PDF_SIZE","This PDF exceeds the 20 MB limit. Choose a smaller document.") }
    guard bytes.count >= 8, bytes.prefix(1024).range(of:Data("%PDF-".utf8)) != nil else { throw ServiceError("PDF_INVALID","The selected document is not a readable PDF.") }
    guard (1...100).contains(maxPages), (1...60_000).contains(maxCharacters) else { throw ServiceError("PDF_INPUT","PDF extraction supports 1–100 pages and up to 60,000 characters per request.") }
    guard let executable, ProviderProcessPolicy.nativeExecutable(executable) else { throw ServiceError("PDF_UNAVAILABLE","The native PDF text helper is missing. Reinstall Zacro to read PDFs with AI.") }
    try Task.checkCancellation()
    let input: ServiceJSON = ["data":.string(bytes.base64EncodedString()),"maxPages":.number(Double(maxPages)),"maxCharacters":.number(Double(maxCharacters))]
    let result: (Int32,Data)
    do { result = try await OwnedProviderCommand().run(executable:executable,arguments:[],home:directory.appendingPathComponent("pdf-reader"),provider:.codex,input:input.text,timeout:20,maximum:1024 * 1024,maximumResidentBytes:192 * 1024 * 1024) }
    catch let error as ServiceError {
      if error.code == "TIMEOUT" { throw ServiceError("PDF_TIMEOUT","This PDF took too long to read. Try a smaller document.") }
      if error.code == "MEMORY" { throw ServiceError("PDF_PARSE","This PDF could not be read within the supported memory and format limits.") }
      if error.code == "CANCELLED" { throw ServiceError("PDF_CANCELLED","PDF extraction was cancelled.") }; throw error
    }
    guard result.0 == 0, let response = try? ServiceJSON.decode(result.1) else { throw ServiceError("PDF_PARSE","This PDF could not be read within the supported memory and format limits.") }
    if response.contains("error") { throw ServiceError(response["error"]["code"].string,response["error"]["message"].string) }
    let value = response["result"]
    guard !value["text"].string.isEmpty, value["text"].string.utf16.count <= maxCharacters, value["pages"].array.count <= maxPages else { throw ServiceError("PDF_PARSE","The PDF text helper returned an invalid extraction.") }
    return NativePDFText(text:value["text"].string,pages:value["pages"].array.map { ($0["page"].int,$0["text"].string) },totalPages:value["totalPages"].int,truncated:value["truncated"].bool)
  }
}
