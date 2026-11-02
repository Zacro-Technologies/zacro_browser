import CCef
import Testing
@testable import CefKit

@Suite @MainActor struct LoadErrorCallbackTests {
    private final class Delegate: CefBrowserDelegate {
        var failures: [(Int, String, String)] = []
        func browser(_ browser: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
            failures.append((code, errorText, failedURL))
        }
    }
    private final class Frame {
        let main: Bool
        init(main: Bool) { self.main = main }
    }

    @Test func subframeFailuresCannotReplaceTheMainDocumentAndTransferredFramesAreReleased() {
        let delegate = Delegate(), client = BrowserClient()
        let pointer = client.makeClient()
        defer { cefRelease(UnsafeMutableRawPointer(pointer)) }
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(browser)
        guard let load = pointer.pointee.get_load_handler?(pointer) else {
            Issue.record("The native client did not supply its load handler")
            return
        }
        defer { cefRelease(UnsafeMutableRawPointer(load)) }
        for isMain in [false, true] {
            weak var released: Frame?
            do {
                let owner = Frame(main: isMain); released = owner
                let frame = cefAllocate(cef_frame_t.self, owner: owner)
                frame.pointee.is_main = { pointer in
                    cefOwner(Frame.self, pointer.map(UnsafeMutableRawPointer.init))?.main == true ? 1 : 0
                }
                CefStringUtil.withCefString("ERR_NAME_NOT_RESOLVED") { text in
                    CefStringUtil.withCefString("https://missing.invalid/") { url in
                        load.pointee.on_load_error?(load, nil, frame,
                            cef_errorcode_t(rawValue: -105), text, url)
                    }
                }
                #expect(delegate.failures.count == (isMain ? 1 : 0))
            }
            #expect(released == nil)
        }
        #expect(delegate.failures.first?.0 == -105)
        #expect(delegate.failures.first?.1 == "ERR_NAME_NOT_RESOLVED")
        #expect(delegate.failures.first?.2 == "https://missing.invalid/")
    }
}
