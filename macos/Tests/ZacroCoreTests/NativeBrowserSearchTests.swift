import XCTest
@testable import ZacroCore

final class NativeBrowserSearchTests: XCTestCase {
  func testLiteralAddressesAndSchemesRemainSearchQueries() throws {
    for query in ["example.com", "https://example.com/path?q=other", "javascript:alert(1)", "about:blank", "file:///tmp/example"] {
      let url = try XCTUnwrap(BrowserAddress.searchURL(query))
      XCTAssertEqual(url.scheme, "https")
      XCTAssertEqual(url.host, "www.google.com")
      XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
    }
  }

  func testQuerySeparatorsUnicodeWhitespaceAndPlusAreEncodedAsData() throws {
    for query in ["one & two=three#four?five+six", "  exact whitespace  ", "日本語 café", "first\nsecond", "a\u{0000}b"] {
      let url = try XCTUnwrap(BrowserAddress.searchURL(query))
      let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
      XCTAssertEqual(parts.queryItems?.count, 1)
      XCTAssertEqual(parts.queryItems?.first?.name, "q")
      XCTAssertEqual(parts.queryItems?.first?.value, query)
      XCTAssertNil(parts.fragment)
    }
  }

  func testUserSelectedProvidersAreHonored() throws {
    let expected: [SearchEngine: String] = [.google: "www.google.com", .duckduckgo: "duckduckgo.com", .bing: "www.bing.com", .brave: "search.brave.com"]
    for (engine, host) in expected {
      let url = try XCTUnwrap(BrowserAddress.searchURL("literal query", engine: engine))
      XCTAssertEqual(url.host, host)
      XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "literal query")
    }
  }

  func testEmptyAndOversizedEncodedQueriesFailWithoutInventingNavigation() {
    XCTAssertNil(BrowserAddress.searchURL(""))
    XCTAssertNil(BrowserAddress.searchURL(String(repeating: "a", count: 8_193)))
    XCTAssertNil(BrowserAddress.searchURL(String(repeating: "日", count: 1_000)))
    XCTAssertNotNil(BrowserAddress.searchURL(String(repeating: "a", count: 8_000)))
  }
}
