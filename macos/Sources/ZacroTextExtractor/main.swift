import Foundation
import PDFKit
import Darwin

// This helper never receives a URL, opens links, displays a PDFView, or invokes PDF actions.
// Its parent owns the 20-second wall-clock watchdog and can kill this disposable process.
struct Input: Decodable { let data: String; let maxPages: Int; let maxCharacters: Int }
struct Page: Encodable { let page: Int; let text: String }
struct Result: Encodable { let text: String; let pages: [Page]; let totalPages: Int; let truncated: Bool }
struct Failure: Error, Encodable { let code: String; let message: String }
struct Output: Encodable { var result: Result?; var error: Failure? }
func clean(_ text: String) -> String {
  text.replacingOccurrences(of:"[\\u0000-\\u0008\\u000b\\u000c\\u000e-\\u001f]",with:"",options:.regularExpression)
    .replacingOccurrences(of:"[^\\S\\n]+",with:" ",options:.regularExpression)
    .replacingOccurrences(of:"\\n{3,}",with:"\n\n",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
}
func prefixUTF16(_ text: String, count: Int) -> String { String(decoding:text.utf16.prefix(max(0,count)),as:UTF16.self) }
func extract() throws -> Result {
  var data = Data()
  while let chunk = try FileHandle.standardInput.read(upToCount:65_536), !chunk.isEmpty {
    guard data.count + chunk.count <= 29 * 1024 * 1024 else { throw Failure(code:"PDF_SIZE",message:"This PDF exceeds the 20 MB limit.") }; data.append(chunk)
  }
  let input = try JSONDecoder().decode(Input.self,from:data)
  guard (1...100).contains(input.maxPages), (1...60_000).contains(input.maxCharacters),
    let bytes = Data(base64Encoded:input.data), bytes.count <= 20 * 1024 * 1024,
    bytes.prefix(1024).range(of:Data("%PDF-".utf8)) != nil else { throw Failure(code:"PDF_INPUT",message:"Invalid PDF extraction input.") }
  guard let document = PDFDocument(data:bytes) else { throw Failure(code:"PDF_INVALID",message:"This PDF is damaged or uses an unsupported format.") }
  guard !document.isLocked else { throw Failure(code:"PDF_PASSWORD",message:"Password-protected PDFs cannot be shared with AI. Export an unlocked copy first.") }
  var pages: [Page] = [], text = "", truncated = document.pageCount > input.maxPages
  for index in 0..<min(document.pageCount,input.maxPages) {
    let original = autoreleasepool { clean(document.page(at:index)?.string ?? "") }
    let separator = text.isEmpty ? "" : "\n\n", remaining = input.maxCharacters - text.utf16.count - separator.utf16.count
    if remaining <= 0 { truncated = true; break }
    let pageText = prefixUTF16(original,count:remaining)
    if original.utf16.count > remaining { truncated = true }
    pages.append(Page(page:index+1,text:pageText)); text += separator + pageText
    if text.utf16.count >= input.maxCharacters { truncated = truncated || index + 1 < document.pageCount; break }
  }
  guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw Failure(code:"PDF_NO_TEXT",message:"This PDF contains no extractable text. Scanned and image-only documents require OCR, which is not available.") }
  return Result(text:text,pages:pages,totalPages:document.pageCount,truncated:truncated)
}
var cpu = rlimit(rlim_cur:20,rlim_max:20)
_ = setrlimit(RLIMIT_CPU,&cpu)
let response: Output
do { response = Output(result:try extract()) }
catch let failure as Failure { response = Output(error:failure) }
catch { response = Output(error:Failure(code:"PDF_PARSE",message:"This PDF could not be read. It may be damaged, encrypted, or use unsupported fonts.")) }
do { try FileHandle.standardOutput.write(contentsOf:JSONEncoder().encode(response)) }
catch { exit(1) }
