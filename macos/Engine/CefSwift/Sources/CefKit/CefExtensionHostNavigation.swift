import CCef
import Foundation

/// Private native CEF producer. The original extension RFH remains Chromium's
/// initiator/opener; this bridge supplies only native shell policy and a client
/// for the actual created child, without constructing a surrogate CefFrame.
@MainActor enum CefExtensionHostNavigation {
    private static var installed = false
    static func installIfAvailable() {
        guard !installed, ccef_extension_host_navigation_available() != 0 else { return }
        var callbacks = ccef_extension_host_navigation_callbacks_t()
        callbacks.size = UInt32(MemoryLayout<ccef_extension_host_navigation_callbacks_t>.size)
        callbacks.prepare = { owner, rawRequest, replacement in
            guard let owner, let rawRequest, let replacement else { return 0 }
            replacement.pointee = nil
            return MainActor.assumeIsolated {
                let native = rawRequest.pointee
                let tracing = CommandLine.arguments.contains("--engine-acceptance")
                    && CommandLine.arguments.contains("--native-integration-acceptance")
                if tracing {
                    fputs("Native extension-host ingress popup=\(native.popup_id) window=\(native.owner_window_id) disposition=\(native.disposition) gesture=\(native.user_gesture) bytes=\(native.size)\n", stderr)
                }
                guard native.size == MemoryLayout<ccef_extension_host_navigation_request_t>.size,
                    native.reserved == 0, native.popup_id > 0, native.owner_window_id > 0,
                    native.disposition >= 0, native.disposition <= 13,
                    (native.user_gesture == 0 || native.user_gesture == 1), native.feature_flags & ~31 == 0,
                    let identifier = native.source_extension_id.map({ String(cString: $0) }),
                    identifier.utf8.count == 32, identifier.utf8.allSatisfy({ (97...112).contains($0) }),
                    let client = BrowserClient.fromNativeClient(owner),
                    let browser = client.browser, !browser.isClosed, client.osrHost == nil,
                    let factory = client.popupClientFactory else {
                    if tracing { fputs("Native extension-host rejection popup=\(native.popup_id) stage=abi-or-native-client\n", stderr) }
                    return 0
                }
                let flags = native.feature_flags
                let target = native.target_url.map { String(cString: $0) } ?? ""
                let request = CefWindowOpenRequest(
                    targetURL: target.isEmpty ? nil : URL(string: target),
                    frameName: native.frame_name.map { String(cString: $0) } ?? "",
                    disposition: CefWindowOpenDisposition(cefValue: cef_window_open_disposition_t(rawValue: UInt32(native.disposition))),
                    userGesture: native.user_gesture != 0,
                    features: CefPopupFeatures(x: flags & 1 != 0 ? Int(native.x) : nil,
                        y: flags & 2 != 0 ? Int(native.y) : nil,
                        width: flags & 4 != 0 ? Int(native.width) : nil,
                        height: flags & 8 != 0 ? Int(native.height) : nil,
                        isPopup: flags & 16 != 0), sourceExtensionID: identifier)
                let action = browser.delegate?.browser(browser, decideWindowOpenFor: request)
                    ?? CefWindowOpenPolicy.defaultAction(for: request)
                let resolved = CefWindowOpenPolicy.resolve(action, for: request)
                guard resolved == .allowNativePopup else {
                    if tracing { fputs("Native extension-host rejection popup=\(native.popup_id) browser=\(browser.id) stage=native-policy action=\(action) resolved=\(resolved)\n", stderr) }
                    return 0
                }
                guard let child = factory(native.popup_id, request) else {
                    if tracing { fputs("Native extension-host rejection popup=\(native.popup_id) browser=\(browser.id) stage=client-factory\n", stderr) }
                    return 0
                }
                // Count/adopt the actual native browser at OnAfterCreated,
                // including a later failure before any BrowserView exists.
                child.adoptCreatedNativePopup = true
                replacement.pointee = UnsafeMutableRawPointer(child.makeClient())
                if tracing { fputs("Native extension-host accepted popup=\(native.popup_id) browser=\(browser.id) window=\(native.owner_window_id)\n", stderr) }
                return 1
            }
        }
        callbacks.aborted = { owner, identifier in
            guard let owner else { return }
            MainActor.assumeIsolated { BrowserClient.fromNativeClient(owner)?.popupAborted?(identifier) }
        }
        installed = ccef_extension_host_navigation_install(&callbacks) == 1
    }
}
