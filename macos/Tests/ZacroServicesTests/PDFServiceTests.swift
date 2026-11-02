import XCTest
@testable import ZacroServices

final class PDFServiceTests: XCTestCase {
  private func reader() throws -> NativePDFExtractor {
    guard let path = ProcessInfo.processInfo.environment["ZACRO_TEST_PDF_HELPER"], FileManager.default.isExecutableFile(atPath:path) else {
      throw XCTSkip("Build ZacroTextExtractor and set ZACRO_TEST_PDF_HELPER for isolated PDF process tests.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroPDFTests-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
    return NativePDFExtractor(directory:directory,executable:URL(fileURLWithPath:path))
  }
  private func pdf(_ texts:[String], action:Bool = false) -> Data {
    var objects = [
      "<< /Type /Catalog /Pages 2 0 R \(action ? "/OpenAction << /S /JavaScript /JS (app.alert('must not execute')) >>" : "") >>",
      "<< /Type /Pages /Kids [\(texts.indices.map { "\($0 * 2 + 4) 0 R" }.joined(separator:" "))] /Count \(texts.count) >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    for (index,text) in texts.enumerated() {
      let stream = "BT /F1 12 Tf 50 700 Td (\(text)) Tj ET"
      objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(index*2+5) 0 R >>")
      objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    }
    var bytes = Data("%PDF-1.4\n".utf8), offsets = [0]
    for (index,object) in objects.enumerated() {
      offsets.append(bytes.count); bytes.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8))
    }
    let xref = bytes.count
    bytes.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() { bytes.append(Data(String(format:"%010d 00000 n \n",offset).utf8)) }
    bytes.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return bytes
  }
  func testRealPDFTextPhysicalPagesAndUnchangedSource() async throws {
    let reader = try reader(), bytes = pdf(["Alpha evidence","Beta evidence"],action:true), original = bytes
    let result = try await reader.extract(bytes)
    expectEqual(result.pages.count,2); expectEqual(result.pages[1].page,2)
    expectTrue(result.text.contains("Alpha evidence")); expectTrue(result.text.contains("Beta evidence"))
    expectEqual(result.totalPages,2); expectFalse(result.truncated); expectEqual(bytes,original)
  }
  func testPDFBudgetsDiscloseTruncation() async throws {
    let result = try await reader().extract(pdf(["Alpha evidence","Beta evidence"]),maxPages:1,maxCharacters:5)
    expectEqual(result.text,"Alpha"); expectEqual(result.pages.count,1); expectTrue(result.truncated)
  }
  func testImageOnlyAndInvalidPDFNeverClaimText() async throws {
    let reader = try reader()
    do { _ = try await reader.extract(pdf([""])); XCTFail("Expected missing text") }
    catch let error as ServiceError { expectEqual(error.code,"PDF_NO_TEXT") }
    do { _ = try await reader.extract(Data("not PDF content".utf8)); XCTFail("Expected invalid PDF") }
    catch let error as ServiceError { expectEqual(error.code,"PDF_INVALID") }
    do { _ = try await reader.extract(pdf(["Text"]),maxPages:101); XCTFail("Expected page limit") }
    catch let error as ServiceError { expectEqual(error.code,"PDF_INPUT") }
  }
}
