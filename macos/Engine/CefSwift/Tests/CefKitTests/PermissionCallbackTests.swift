import CCef
import Foundation
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
    private final class AsyncDelegate: CefBrowserDelegate {
        var callbacks: [UUID: CefPermissionCallback] = [:]
        var dismissed: [UUID] = []
        func browser(_ browser: CefBrowser, requestsPermission request: CefPermissionRequest, callback: CefPermissionCallback) -> Bool {
            callbacks[request.id] = callback; return true
        }
        func browser(_ browser: CefBrowser, dismissedPermission id: UUID) { dismissed.append(id) }
    }

    private func prompt(_ client: BrowserClient, id: UInt64, decisions: Decisions) -> Int32? {
        let callback = cefAllocate(cef_permission_prompt_callback_t.self, owner: decisions)
        callback.pointee.cont = { pointer, _ in
            cefOwner(Decisions.self, pointer.map(UnsafeMutableRawPointer.init))?.count += 1
        }
        return CefStringUtil.withCefString("https://example.test") { origin in
            client.permissionPointer?.pointee.on_show_permission_prompt?(client.permissionPointer, nil, id, origin,
                UInt32(CEF_PERMISSION_TYPE_NOTIFICATIONS.rawValue), callback)
        }
    }

    @Test func asynchronousDecisionIsRetainedAndResolvedExactlyOnce() throws {
        let delegate = AsyncDelegate(), client = BrowserClient(), decisions = Decisions()
        let pointer = client.makeClient(); defer { cefRelease(UnsafeMutableRawPointer(pointer)) }
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate); client.attach(browser)
        #expect(prompt(client, id: 31, decisions: decisions) == 1)
        #expect(decisions.count == 0)
        let callback = try #require(delegate.callbacks.values.first)
        #expect(callback.isPending)
        callback.resolve(.allow); callback.resolve(.deny); callback.cancel()
        #expect(!callback.isPending && decisions.count == 1)
    }

    @Test func nativeDismissalOnlyInvalidatesItsRequestAndLateApprovalDoesNothing() throws {
        let delegate = AsyncDelegate(), client = BrowserClient(), first = Decisions(), second = Decisions()
        let pointer = client.makeClient(); defer { cefRelease(UnsafeMutableRawPointer(pointer)) }
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate); client.attach(browser)
        #expect(prompt(client, id: 41, decisions: first) == 1)
        let firstID = try #require(delegate.callbacks.keys.first)
        #expect(prompt(client, id: 42, decisions: second) == 1)
        let secondID = try #require(delegate.callbacks.keys.first { $0 != firstID })
        client.permissionPointer?.pointee.on_dismiss_permission_prompt?(client.permissionPointer, nil, 41, CEF_PERMISSION_RESULT_IGNORE)
        #expect(delegate.dismissed == [firstID])
        delegate.callbacks[firstID]?.resolve(.allow)
        #expect(first.count == 0 && delegate.callbacks[secondID]?.isPending == true)
        delegate.callbacks[secondID]?.resolve(.deny)
        #expect(second.count == 1)
    }

    @Test func navigationAndBrowserCloseCancelPendingRequestsBeforeLateUIResponse() throws {
        let delegate = AsyncDelegate(), client = BrowserClient(), first = Decisions(), second = Decisions()
        let pointer = client.makeClient(); defer { cefRelease(UnsafeMutableRawPointer(pointer)) }
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate); client.attach(browser)
        #expect(prompt(client, id: 51, decisions: first) == 1)
        let firstID = try #require(delegate.callbacks.keys.first)
        let frame = cefAllocate(cef_frame_t.self, owner: first)
        frame.pointee.is_main = { _ in 1 }
        _ = client.requestPointer?.pointee.on_before_browse?(client.requestPointer, nil, frame, nil, 0, 0)
        #expect(first.count == 1 && delegate.dismissed == [firstID])
        delegate.callbacks[firstID]?.resolve(.allow)
        #expect(first.count == 1)
        #expect(prompt(client, id: 52, decisions: second) == 1)
        let handler = pointer.pointee.get_life_span_handler?(pointer)
        handler?.pointee.on_before_close?(handler, nil)
        cefRelease(handler.map(UnsafeMutableRawPointer.init))
        #expect(second.count == 1 && delegate.dismissed.count == 2)
        for callback in delegate.callbacks.values { callback.resolve(.allow) }
        #expect(first.count == 1 && second.count == 1)
    }

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
