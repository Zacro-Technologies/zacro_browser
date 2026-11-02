import AppKit
import CCef
import Foundation

private final class CefAuxiliaryClientLifetime: @unchecked Sendable {
    let client: CefAuxiliaryBrowserClient
    let handlers: [UnsafeMutableRawPointer]
    init(_ client: CefAuxiliaryBrowserClient, handlers: [UnsafeMutableRawPointer]) {
        self.client = client
        self.handlers = handlers
    }
    deinit { for handler in handlers { cefRelease(handler) } }
}

/// Tracks Chrome-owned windows without making them application tabs. In
/// particular, OAuth documents keep Chromium's navigation, permissions and UI.
/// The SDK requires a default client so these browsers drain before shutdown.
@MainActor
final class CefAuxiliaryBrowserClient {
    private final class WeakBrowser {
        weak var value: CefBrowser?
        init(_ value: CefBrowser) { self.value = value }
    }
    private final class BeforeUnload {
        let id = UUID()
        let alert: NSAlert
        let callback: CefJSDialogCallback
        let reload: Bool
        weak var window: NSWindow?
        init(alert: NSAlert, callback: CefJSDialogCallback, window: NSWindow, reload: Bool) {
            self.alert = alert; self.callback = callback; self.window = window; self.reload = reload
        }
    }
    private var browsers: [Int32: WeakBrowser] = [:]
    private var beforeUnload: [Int32: BeforeUnload] = [:]
    // CEF may ask for immutable handlers from another thread.
    nonisolated(unsafe) private var lifeSpan: UnsafeMutablePointer<cef_life_span_handler_t>?
    nonisolated(unsafe) private var display: UnsafeMutablePointer<cef_display_handler_t>?
    nonisolated(unsafe) private var dialogs: UnsafeMutablePointer<cef_jsdialog_handler_t>?

    nonisolated private static func owner(_ pointer: UnsafeMutableRawPointer?) -> CefAuxiliaryBrowserClient? {
        let owner = cefOwner(AnyObject.self, pointer)
        return (owner as? CefAuxiliaryBrowserClient) ?? (owner as? CefAuxiliaryClientLifetime)?.client
    }

    /// Returns a caller-owned +1 client. No browser wrapper is retained until
    /// CEF actually reports creation; failed creation therefore cannot leak one.
    func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        let life = cefAllocate(cef_life_span_handler_t.self, owner: self)
        life.pointee.on_after_created = { pointer, raw in
            guard let raw else { return }
            guard let owner = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init)) else {
                cefRelease(UnsafeMutableRawPointer(raw)); return
            }
            MainActor.assumeIsolated { owner.adopt(raw) }
        }
        life.pointee.on_before_close = { pointer, raw in
            let id = raw.map { $0.pointee.get_identifier?($0) ?? -1 }
            cefRelease(raw.map(UnsafeMutableRawPointer.init))
            guard let owner = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init)), let id else { return }
            MainActor.assumeIsolated {
                if let browser = owner.browsers[id]?.value {
                    CefRuntime.shared.observeAuxiliaryWindow(browser)
                }
                owner.resetDialog(id, closing: true)
                let browser = owner.browsers.removeValue(forKey: id)?.value
                browser?.handleBeforeClose()
            }
        }
        lifeSpan = life

        let display = cefAllocate(cef_display_handler_t.self, owner: self)
        display.pointee.on_title_change = { pointer, raw, title in
            let id = raw.map { $0.pointee.get_identifier?($0) ?? -1 }
            cefRelease(raw.map(UnsafeMutableRawPointer.init))
            guard let owner = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init)), let id else { return }
            let title = CefStringUtil.string(from: title)
            MainActor.assumeIsolated { owner.browsers[id]?.value?.applyTitle(title) }
        }
        display.pointee.on_address_change = { pointer, raw, frame, address in
            let id = raw.map { $0.pointee.get_identifier?($0) ?? -1 }
            cefRelease(raw.map(UnsafeMutableRawPointer.init))
            defer { cefRelease(frame.map(UnsafeMutableRawPointer.init)) }
            guard let frame, frame.pointee.is_main?(frame) != 0,
                  let owner = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init)), let id else { return }
            let address = CefStringUtil.string(from: address)
            MainActor.assumeIsolated { owner.browsers[id]?.value?.applyURL(address) }
        }
        self.display = display

        let dialogs = cefAllocate(cef_jsdialog_handler_t.self, owner: self)
        // All ordinary JS dialogs use Chrome's original handler. A native
        // beforeunload decision also needs to cancel our outer Quit transaction.
        dialogs.pointee.on_before_unload_dialog = { pointer, raw, message, reload, callback in
            let id = raw.map { $0.pointee.get_identifier?($0) ?? -1 }
            cefRelease(raw.map(UnsafeMutableRawPointer.init))
            guard let callback else { return 0 }
            guard let owner = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init)), let id else {
                cefRelease(UnsafeMutableRawPointer(callback)); return 0
            }
            let text = CefStringUtil.string(from: message)
            return MainActor.assumeIsolated {
                owner.showBeforeUnload(id, message: text, reload: reload != 0,
                                       callback: CefJSDialogCallback(raw: callback))
            }
        }
        dialogs.pointee.on_reset_dialog_state = { pointer, raw in
            let id = raw.map { $0.pointee.get_identifier?($0) ?? -1 }
            cefRelease(raw.map(UnsafeMutableRawPointer.init))
            guard let owner = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init)), let id else { return }
            MainActor.assumeIsolated { owner.resetDialog(id) }
        }
        dialogs.pointee.on_dialog_closed = dialogs.pointee.on_reset_dialog_state
        self.dialogs = dialogs

        let lifetime = CefAuxiliaryClientLifetime(self, handlers: [UnsafeMutableRawPointer(life),
            UnsafeMutableRawPointer(display), UnsafeMutableRawPointer(dialogs)])
        let client = cefAllocate(cef_client_t.self, owner: lifetime)
        client.pointee.get_life_span_handler = { pointer in
            guard let value = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init))?.lifeSpan else { return nil }
            cefAddRef(UnsafeMutableRawPointer(value)); return value
        }
        client.pointee.get_display_handler = { pointer in
            guard let value = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init))?.display else { return nil }
            cefAddRef(UnsafeMutableRawPointer(value)); return value
        }
        client.pointee.get_jsdialog_handler = { pointer in
            guard let value = CefAuxiliaryBrowserClient.owner(pointer.map(UnsafeMutableRawPointer.init))?.dialogs else { return nil }
            cefAddRef(UnsafeMutableRawPointer(value)); return value
        }
        return client
    }

    private func adopt(_ raw: UnsafeMutablePointer<cef_browser_t>) {
        let id = raw.pointee.get_identifier?(raw) ?? -1
        guard id >= 0, browsers[id]?.value == nil else {
            cefRelease(UnsafeMutableRawPointer(raw)); return
        }
        // Ownership of this callback's +1 transfers directly to the wrapper.
        let browser = CefBrowser(raw: raw, client: nil, delegate: nil)
        browsers[id] = WeakBrowser(browser)
        // WebAuthFlow loads its document before inserting it into a Browser;
        // its initial address callback may predate the default client.
        if let frame = raw.pointee.get_main_frame?(raw) {
            if let address = CefStringUtil.takingUserFree(frame.pointee.get_url?(frame)) {
                browser.applyURL(address)
            }
            cefRelease(UnsafeMutableRawPointer(frame))
        }
        CefRuntime.shared.registerAuxiliaryBrowser(browser)
    }

    private func showBeforeUnload(_ id: Int32, message: String, reload: Bool,
                                  callback: CefJSDialogCallback) -> Int32 {
        guard let browser = browsers[id]?.value, !browser.isClosed else { callback.invalidate(); return 0 }
        callback.onDecision = { [weak browser] leave in
            guard !leave, !reload, let browser else { return }
            browser.auxiliaryCloseWasCancelled()
        }
        guard beforeUnload[id] == nil, let window = browser.nativeView?.window,
              window.isVisible, window.attachedSheet == nil else {
            callback.cancel(); return 1
        }
        let alert = NSAlert()
        alert.messageText = reload ? "Reload this page?" : "Leave this page?"
        alert.informativeText = message.isEmpty ? "Changes you made may not be saved." : message
        alert.addButton(withTitle: reload ? "Reload" : "Leave")
        alert.addButton(withTitle: "Stay")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let pending = BeforeUnload(alert: alert, callback: callback, window: window, reload: reload)
        alert.window.identifier = NSUserInterfaceItemIdentifier("ZacroAuxiliaryBeforeUnload:\(id):\(pending.id.uuidString)")
        beforeUnload[id] = pending
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.beforeUnload[id]?.id == pending.id else { return }
                self.beforeUnload[id] = nil
                pending.callback.continue(success: response == .alertFirstButtonReturn)
            }
        }
        return 1
    }

    private func resetDialog(_ id: Int32, closing: Bool = false) {
        guard let pending = beforeUnload.removeValue(forKey: id) else { return }
        pending.callback.invalidate()
        if !closing && !pending.reload { browsers[id]?.value?.auxiliaryCloseWasCancelled() }
        if let window = pending.window, pending.alert.window.sheetParent === window {
            window.endSheet(pending.alert.window, returnCode: .abort)
        }
    }
}
