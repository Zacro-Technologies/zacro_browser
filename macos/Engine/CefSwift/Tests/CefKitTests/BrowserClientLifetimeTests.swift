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
}
