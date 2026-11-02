import CCef
import Testing
@testable import CefKit

@Suite @MainActor struct PermissionCallbackTests {
    private final class Delegate: CefBrowserDelegate {
        var received: [CefPermissionRequest] = []
        func browser(_ browser: CefBrowser, requestsPermission request: CefPermissionRequest) -> CefPermissionDecision {
            received.append(request); return .useDefault
        }
    }
    private final class Decisions { var count = 0 }

    @Test func defaultDesktopChooserDoesNotReceiveAnAutomaticGrantOrDenial() {
        let delegate = Delegate(), client = BrowserClient(), decisions = Decisions()
        let pointer = client.makeClient()
        defer { cefRelease(UnsafeMutableRawPointer(pointer)) }
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(browser)
        let callback = cefAllocate(cef_media_access_callback_t.self, owner: decisions)
        callback.pointee.cont = { pointer, _ in
            cefOwner(Decisions.self, pointer.map(UnsafeMutableRawPointer.init))?.count += 1
        }
        callback.pointee.cancel = { pointer in
            cefOwner(Decisions.self, pointer.map(UnsafeMutableRawPointer.init))?.count += 1
        }
        let result = CefStringUtil.withCefString("https://example.test") { origin in
            client.permissionPointer?.pointee.on_request_media_access_permission?(
                client.permissionPointer, nil, nil, origin,
                UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue), callback)
        }
        #expect(result == 0 && decisions.count == 0)
        #expect(delegate.received.first?.kinds == .screenCapture)
    }

    @Test func defaultExtensionPermissionLeavesChromiumInControl() {
        let delegate = Delegate(), client = BrowserClient(), decisions = Decisions()
        let pointer = client.makeClient()
        defer { cefRelease(UnsafeMutableRawPointer(pointer)) }
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(browser)
        let callback = cefAllocate(cef_permission_prompt_callback_t.self, owner: decisions)
        callback.pointee.cont = { pointer, _ in
            cefOwner(Decisions.self, pointer.map(UnsafeMutableRawPointer.init))?.count += 1
        }
        let result = CefStringUtil.withCefString("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") { origin in
            client.permissionPointer?.pointee.on_show_permission_prompt?(
                client.permissionPointer, nil, 1, origin,
                UInt32(CEF_PERMISSION_TYPE_CAMERA_STREAM.rawValue), callback)
        }
        #expect(result == 0 && decisions.count == 0)
        #expect(delegate.received.first?.kinds == .camera)
    }
}
