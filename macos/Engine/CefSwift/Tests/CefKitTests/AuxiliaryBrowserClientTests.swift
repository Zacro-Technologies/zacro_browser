import AppKit
import CCef
import Testing
@testable import CefKit

@Suite @MainActor struct AuxiliaryBrowserClientTests {
    private final class BrowserIdentity {
        let id: Int32
        init(_ id: Int32) { self.id = id }
    }
    private final class Decisions { var values: [Int32] = [] }

    private func nativeBrowser(_ id: Int32) -> UnsafeMutablePointer<cef_browser_t> {
        let pointer = cefAllocate(cef_browser_t.self, owner: BrowserIdentity(id))
        pointer.pointee.get_identifier = { pointer in
            cefOwner(BrowserIdentity.self, pointer.map(UnsafeMutableRawPointer.init))?.id ?? -1
        }
        return pointer
    }

    @Test func defaultClientExistsWithoutInjectingPageOrPermissionHandlers() throws {
        let context = CefAppContext(extraSwitches: [:], useMockKeychain: false,
                                    userCommandLineHook: nil, customSchemes: [], pump: CefMessagePump())
        let app = context.makeApp()
        let handler = try #require(app.pointee.get_browser_process_handler?(app))
        defer { cefRelease(UnsafeMutableRawPointer(handler)); cefRelease(UnsafeMutableRawPointer(app)) }
        let first = try #require(handler.pointee.get_default_client?(handler))
        let second = try #require(handler.pointee.get_default_client?(handler))
        defer { cefRelease(UnsafeMutableRawPointer(first)); cefRelease(UnsafeMutableRawPointer(second)) }
        #expect(first != second)
        #expect(first.pointee.get_request_handler == nil)
        #expect(first.pointee.get_permission_handler == nil)
        #expect(first.pointee.get_load_handler == nil)
        #expect(first.pointee.get_download_handler == nil)
        let dialogs = try #require(first.pointee.get_jsdialog_handler?(first))
        defer { cefRelease(UnsafeMutableRawPointer(dialogs)) }
        #expect(dialogs.pointee.on_jsdialog == nil, "Auth alert/prompt content stays in Chrome's UI")
        #expect(dialogs.pointee.on_before_unload_dialog != nil)
    }

    @Test func auxiliaryCallbackOwnsExactlyItsBrowsersAndDrainsTheRegistry() throws {
        weak var weakClient: CefAuxiliaryBrowserClient?
        let client: UnsafeMutablePointer<cef_client_t>
        do {
            let owner = CefAuxiliaryBrowserClient(); weakClient = owner
            client = owner.makeClient()
        }
        let life = try #require(client.pointee.get_life_span_handler?(client))
        let first = nativeBrowser(810001), second = nativeBrowser(810002)
        // One local reference and one transferred callback reference each.
        cefAddRef(UnsafeMutableRawPointer(first)); cefAddRef(UnsafeMutableRawPointer(second))
        life.pointee.on_after_created?(life, first)
        life.pointee.on_after_created?(life, second)
        #expect(CefRuntime.shared.auxiliaryBrowsers.contains { $0.id == 810001 })
        #expect(CefRuntime.shared.auxiliaryBrowsers.contains { $0.id == 810002 })
        #expect(!CefRuntime.shared.activeBrowsers.contains { $0.id == 810001 || $0.id == 810002 },
                "Auth documents must not receive application bridge broadcasts")
        let firstWrapper = try #require(CefRuntime.shared.auxiliaryBrowsers.first { $0.id == 810001 })
        cefAddRef(UnsafeMutableRawPointer(first))
        life.pointee.on_after_created?(life, first)
        #expect(CefRuntime.shared.auxiliaryBrowsers.filter { $0.id == 810001 }.count == 1)
        // CEF may retain a handler beyond the original client reference.
        cefRelease(UnsafeMutableRawPointer(client))
        #expect(weakClient != nil)
        cefAddRef(UnsafeMutableRawPointer(first)); life.pointee.on_before_close?(life, first)
        #expect(firstWrapper.isClosed)
        #expect(!CefRuntime.shared.auxiliaryBrowsers.contains { $0.id == 810001 })
        #expect(CefRuntime.shared.auxiliaryBrowsers.contains { $0.id == 810002 })
        cefAddRef(UnsafeMutableRawPointer(second)); life.pointee.on_before_close?(life, second)
        #expect(!CefRuntime.shared.auxiliaryBrowsers.contains { $0.id == 810002 })
        cefRelease(UnsafeMutableRawPointer(first)); cefRelease(UnsafeMutableRawPointer(second))
        cefRelease(UnsafeMutableRawPointer(life))
        #expect(weakClient == nil)
    }

    @Test func ownerlessBeforeUnloadRefusesRatherThanUsingAnotherWindow() throws {
        let owner = CefAuxiliaryBrowserClient(), decisions = Decisions()
        let client = owner.makeClient()
        let life = try #require(client.pointee.get_life_span_handler?(client))
        let dialogs = try #require(client.pointee.get_jsdialog_handler?(client))
        defer {
            cefRelease(UnsafeMutableRawPointer(dialogs)); cefRelease(UnsafeMutableRawPointer(life))
            cefRelease(UnsafeMutableRawPointer(client))
        }
        let raw = nativeBrowser(810003)
        cefAddRef(UnsafeMutableRawPointer(raw)); life.pointee.on_after_created?(life, raw)
        let browser = try #require(CefRuntime.shared.auxiliaryBrowsers.first { $0.id == 810003 })
        var cancellations = 0
        browser.onCloseCancelled = { cancellations += 1 }
        let callback = cefAllocate(cef_jsdialog_callback_t.self, owner: decisions)
        callback.pointee.cont = { pointer, success, _ in
            cefOwner(Decisions.self, pointer.map(UnsafeMutableRawPointer.init))?.values.append(success)
        }
        cefAddRef(UnsafeMutableRawPointer(raw))
        #expect(dialogs.pointee.on_before_unload_dialog?(dialogs, raw, nil, 0, callback) == 1)
        #expect(decisions.values == [0] && cancellations == 1)
        cefAddRef(UnsafeMutableRawPointer(raw)); life.pointee.on_before_close?(life, raw)
        cefRelease(UnsafeMutableRawPointer(raw))
    }

    @Test func nativeClosureResolvesWaiterAndVetoKeepsBrowserAlive() async throws {
        let client = CefAuxiliaryBrowserClient().makeClient()
        let life = try #require(client.pointee.get_life_span_handler?(client))
        defer { cefRelease(UnsafeMutableRawPointer(life)); cefRelease(UnsafeMutableRawPointer(client)) }
        let raw = nativeBrowser(810004)
        cefAddRef(UnsafeMutableRawPointer(raw)); life.pointee.on_after_created?(life, raw)
        let browser = try #require(CefRuntime.shared.auxiliaryBrowsers.first { $0.id == 810004 })
        let vetoed = Task { @MainActor in try await CefRuntime.shared.closeAuxiliaryBrowser(browser) }
        await Task.yield()
        browser.auxiliaryCloseWasCancelled()
        do { try await vetoed.value; Issue.record("A veto must reject the close waiter") }
        catch is CancellationError {} catch { Issue.record("Unexpected veto: \(error)") }
        #expect(!browser.isClosed)
        let closed = Task { @MainActor in try await CefRuntime.shared.closeAuxiliaryBrowser(browser) }
        await Task.yield()
        cefAddRef(UnsafeMutableRawPointer(raw)); life.pointee.on_before_close?(life, raw)
        try await closed.value
        #expect(browser.isClosed)
        cefRelease(UnsafeMutableRawPointer(raw))
    }
}
