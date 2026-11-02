import CCef
import Foundation
import Testing
@testable import CefKit

@Suite @MainActor struct DevToolsRoutingTests {
    private final class Registration {
        let observer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>
        init(_ observer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>) { self.observer = observer }
        deinit { cefRelease(UnsafeMutableRawPointer(observer)) }
    }
    private final class Transport {
        var raw: UnsafeMutablePointer<cef_browser_t>!
        var observer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
        var request: (([String: Any]) -> Void)?
        @MainActor func makeBrowser() -> CefBrowser {
            raw = cefAllocate(cef_browser_t.self, owner: self)
            raw.pointee.get_identifier = { _ in 101 }
            raw.pointee.get_host = { pointer in
                guard let owner = cefOwner(Transport.self, pointer.map(UnsafeMutableRawPointer.init)) else { return nil }
                let host = cefAllocate(cef_browser_host_t.self, owner: owner)
                host.pointee.add_dev_tools_message_observer = { host, observer in
                    guard let observer, let owner = cefOwner(Transport.self, host.map(UnsafeMutableRawPointer.init)) else { return nil }
                    MainActor.assumeIsolated { owner.observer = observer }
                    return cefAllocate(cef_registration_t.self, owner: Registration(observer))
                }
                host.pointee.send_dev_tools_message = { host, bytes, count in
                    guard let bytes, let owner = cefOwner(Transport.self, host.map(UnsafeMutableRawPointer.init)),
                        let value = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count)) as? [String: Any] else { return 0 }
                    MainActor.assumeIsolated { owner.request?(value) }
                    return 1
                }
                return host
            }
            return CefBrowser(raw: raw, client: nil, delegate: nil)
        }
        func emit(_ value: [String: Any]) throws {
            guard let observer else { Issue.record("Missing observer"); return }
            let data = try JSONSerialization.data(withJSONObject: value)
            cefAddRef(UnsafeMutableRawPointer(raw)) // CEF transfers +1 to each callback.
            let handled = data.withUnsafeBytes { bytes in
                observer.pointee.on_dev_tools_message?(observer, raw, bytes.baseAddress, bytes.count)
            }
            #expect(handled == 1)
        }
    }

    @Test func flattenedRepliesRequireTheirOwnSessionAndRawBrowserReferencesBalance() async throws {
        weak var released: Transport?
        do {
            let transport = Transport(); released = transport
            let browser = transport.makeBrowser()
            let channel = browser.devTools
            transport.request = { [weak transport] request in
                guard let transport, let id = request["id"] as? Int else { return }
                try? transport.emit(["id": id, "result": ["value": "wrong-root"]])
                try? transport.emit(["id": id, "sessionId": "another-child", "result": ["value": "wrong-child"]])
                try? transport.emit(["id": id + 1, "sessionId": "child", "result": ["value": "wrong-id"]])
                try? transport.emit(["id": id, "sessionId": "child", "result": ["value": "correct"]])
            }
            let result = try await channel.call("Runtime.evaluate", timeout: 1, sessionID: "child")
            #expect(result["value"] as? String == "correct")
            browser.handleBeforeClose()
        }
        #expect(released == nil, "Raw callback browser references and observer registration must balance")
    }

    @Test func rootObserversCannotReceiveChildEventsAndProtocolObserversKeepScope() throws {
        let transport = Transport(), browser: CefBrowser
        browser = transport.makeBrowser()
        var rootEvents = 0
        var scopes: [String?] = []
        _ = try browser.devTools.observeEvents { _, _ in rootEvents += 1 }
        _ = try browser.devTools.observeProtocolEvents { _, _, session in scopes.append(session) }
        try transport.emit(["method": "Runtime.executionContextCreated", "params": [:], "sessionId": "child"])
        try transport.emit(["method": "Runtime.executionContextCreated", "params": [:]])
        #expect(rootEvents == 1 && scopes.count == 2)
        #expect(scopes[0] == "child" && scopes[1] == nil)
        browser.handleBeforeClose()
    }

    @Test func detachedChildRejectsPendingRequestWithoutWaitingForDeadline() async throws {
        let transport = Transport(), browser: CefBrowser
        browser = transport.makeBrowser()
        transport.request = { [weak transport] _ in
            try? transport?.emit(["method": "Target.detachedFromTarget", "params": ["sessionId": "child"]])
        }
        do {
            _ = try await browser.devTools.call("Runtime.evaluate", timeout: 1, sessionID: "child")
            Issue.record("Detached child must reject its pending call")
        } catch let error as CefDevToolsError {
            if case .browserClosed = error {} else { Issue.record("Unexpected detach result: \(error)") }
        }
        browser.handleBeforeClose()
    }
}
