import Testing
@testable import CCef
@testable import CefKit

@Suite @MainActor struct BrowserClientLifetimeTests {
    @Test func clientReleasesHandlerOwners() {
        weak var owner: BrowserClient?
        let pointer: UnsafeMutablePointer<cef_client_t>
        do {
            let client = BrowserClient()
            owner = client
            pointer = client.makeClient()
            #expect(BrowserClient.fromNativeClient(UnsafeMutableRawPointer(pointer)) === client)
        }
        #expect(owner != nil)
        cefRelease(UnsafeMutableRawPointer(pointer))
        #expect(owner == nil, "The client and its initial handler references must release together")
    }

    @Test func borrowedHandlerOutlivesClientReference() {
        weak var owner: BrowserClient?
        let pointer: UnsafeMutablePointer<cef_client_t>
        do {
            let client = BrowserClient()
            owner = client
            pointer = client.makeClient()
        }
        let handler = pointer.pointee.get_life_span_handler?(pointer)
        #expect(handler != nil)
        cefRelease(UnsafeMutableRawPointer(pointer))
        #expect(owner != nil, "Chromium can retain a handler after releasing the client")
        cefRelease(handler.map(UnsafeMutableRawPointer.init))
        #expect(owner == nil)
    }

    @Test func creationFailureClosesOnceAndRejectsReadiness() async {
        final class Observer: CefBrowserDelegate {
            var failures = 0
            var closes = 0
            func browser(_ browser: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
                failures += 1
                #expect(browser.creationFailed)
            }
            func browserDidClose(_ browser: CefBrowser) { closes += 1 }
        }
        let observer = Observer()
        let browser = CefBrowser(raw: nil, client: nil, delegate: observer)
        browser.failCreation("Rejected native creation")
        browser.failCreation("Repeated failure")
        browser.handleBeforeClose()
        #expect(browser.isClosed && browser.creationFailed)
        #expect(observer.failures == 1 && observer.closes == 1)
        do {
            try await browser.waitUntilReady()
            Issue.record("A closed native document must not report readiness")
        } catch let failure as CefDevToolsError {
            if case .browserClosed = failure {} else { Issue.record("Unexpected native creation error: \(failure)") }
        } catch { Issue.record("Unexpected native creation error: \(error)") }
    }
}
