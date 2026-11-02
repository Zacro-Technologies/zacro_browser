import CCef
import Foundation

public enum CefDevToolsError: Error, LocalizedError {
    case browserClosed
    case timeout
    case unavailable
    case invalidMessage
    case responseTooLarge
    case rejected(String)
    case protocolError(code: Int, message: String)

    public var isUnsupportedMethod: Bool {
        if case .protocolError(code: -32601, message: _) = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .browserClosed: return "The browser document closed before the operation completed."
        case .timeout: return "The browser did not finish the operation in time."
        case .unavailable: return "The Chromium protocol channel is unavailable."
        case .invalidMessage: return "Chromium returned an invalid protocol response."
        case .responseTooLarge: return "The browser response exceeded the supported size."
        case .rejected(let message): return message
        case .protocolError(_, let message): return message
        }
    }
}

/// A process-local protocol channel owned by a specific live browser. It opens
/// no debugging port and installs no JavaScript globals in visited documents.
@MainActor
public final class CefDevTools {
    private weak var browser: CefBrowser?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var sequence: Int32 = 0
    private var closed = false
    private var pending: [Int32: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int32: Task<Void, Never>] = [:]
    private var browserSessionID: String?
    private var eventObservers: [UUID: (String, [String: Any]) -> Void] = [:]
    private static let responseLimit = 10 * 1024 * 1024

    init(browser: CefBrowser) { self.browser = browser }

    @discardableResult public func observeEvents(_ callback: @escaping (String, [String: Any]) -> Void) throws -> UUID {
        guard !closed, let browser, browser.hasRawBrowser else { throw CefDevToolsError.browserClosed }
        try attach(to: browser)
        let token = UUID(); eventObservers[token] = callback; return token
    }
    public func removeEventObserver(_ token: UUID) { eventObservers.removeValue(forKey: token) }

    public func call(
        _ method: String, parameters: [String: Any] = [:], timeout: TimeInterval = 15,
        sessionID: String? = nil
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !closed, let browser, browser.hasRawBrowser else { throw CefDevToolsError.browserClosed }
        guard !method.isEmpty, method.count < 256, pending.count < 32,
              timeout.isFinite, timeout > 0, timeout <= 120,
              JSONSerialization.isValidJSONObject(parameters) else { throw CefDevToolsError.invalidMessage }
        try attach(to: browser)
        sequence = sequence == Int32.max ? 1 : sequence + 1
        let identifier = sequence
        guard pending[identifier] == nil else { throw CefDevToolsError.unavailable }
        var payload: [String: Any] = [
            "id": identifier, "method": method, "params": parameters,
        ]
        if let sessionID { payload["sessionId"] = sessionID }
        let message = try JSONSerialization.data(withJSONObject: payload)
        let messageLimit = method == "Zacro.restoreNavigation" ? 9 * 1024 * 1024 : 1024 * 1024
        guard message.count <= messageLimit else { throw CefDevToolsError.invalidMessage }
        let response: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[identifier] = continuation
                deadlines[identifier] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.finish(identifier, with: .failure(CefDevToolsError.timeout))
                }
                var sent = false
                browser.withHostInternal { host in
                    sent = message.withUnsafeBytes { bytes in
                        (host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0) != 0
                    }
                }
                if !sent { finish(identifier, with: .failure(CefDevToolsError.unavailable)) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(identifier, with: .failure(CancellationError())) }
        }
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw CefDevToolsError.invalidMessage
        }
        return result
    }

    /// Attaches a process-local browser session; it exposes no TCP endpoint.
    /// Chromium requires this trusted session for native extension actions.
    public func browserSession() async throws -> String {
        if let browserSessionID { return browserSessionID }
        let result = try await call("Target.attachToBrowserTarget")
        guard let session = result["sessionId"] as? String, !session.isEmpty else { throw CefDevToolsError.invalidMessage }
        browserSessionID = session
        return session
    }

    /// Returns this document's native tab target. A Chrome-style CEF BrowserView
    /// owns one Browser window; matching its native window ID avoids confusing
    /// duplicate URLs, background documents, or documents in another profile.
    public func nativeTabTarget() async throws -> String {
        let session = try await browserSession()
        let info = try await call("Target.getTargetInfo")
        guard let current = info["targetInfo"] as? [String: Any], let pageID = current["targetId"] as? String else {
            throw CefDevToolsError.invalidMessage
        }
        let window = try await call("Browser.getWindowForTarget", parameters: ["targetId": pageID], sessionID: session)
        guard let windowID = window["windowId"] as? Int else { throw CefDevToolsError.invalidMessage }
        let targets = try await call("Target.getTargets", parameters: ["filter": [["type": "tab", "exclude": false]]], sessionID: session)
        guard let infos = targets["targetInfos"] as? [[String: Any]] else { throw CefDevToolsError.invalidMessage }
        var matches: [String] = []
        for target in infos where target["type"] as? String == "tab" {
            guard let id = target["targetId"] as? String else { continue }
            let candidate = try await call("Browser.getWindowForTarget", parameters: ["targetId": id], sessionID: session)
            if candidate["windowId"] as? Int == windowID { matches.append(id) }
        }
        guard matches.count == 1, let target = matches.first else { throw CefDevToolsError.unavailable }
        return target
    }

    /// Returns the evaluated value by copy. A rejected promise or JavaScript
    /// exception is an error; it is never presented as an empty successful value.
    public func evaluate(
        _ expression: String, userGesture: Bool = false, timeout: TimeInterval = 15,
        sessionID: String? = nil
    ) async throws -> Any? {
        let response = try await call("Runtime.evaluate", parameters: [
            "expression": expression, "returnByValue": true, "awaitPromise": true,
            "userGesture": userGesture,
        ], timeout: timeout, sessionID: sessionID)
        return try value(from: response)
    }

    /// Evaluates host-owned extraction code in a separate JavaScript world.
    /// Page scripts cannot replace that world's DOM getters or access its
    /// globals. The caller must still validate its document/profile identity
    /// after awaiting a result before using or transmitting extracted content.
    public func evaluateIsolated(_ expression: String, timeout: TimeInterval = 15) async throws -> Any? {
        let tree = try await call("Page.getFrameTree", timeout: timeout)
        guard let root = tree["frameTree"] as? [String: Any],
              let frame = root["frame"] as? [String: Any], let identifier = frame["id"] as? String else {
            throw CefDevToolsError.invalidMessage
        }
        let world = try await call("Page.createIsolatedWorld", parameters: [
            "frameId": identifier, "worldName": "Zacro.Native",
        ], timeout: timeout)
        guard let context = world["executionContextId"] as? NSNumber else { throw CefDevToolsError.invalidMessage }
        let response = try await call("Runtime.evaluate", parameters: [
            "expression": expression, "contextId": context, "returnByValue": true,
            "awaitPromise": true, "includeCommandLineAPI": false, "userGesture": false,
        ], timeout: timeout)
        return try value(from: response)
    }

    private func value(from response: [String: Any]) throws -> Any? {
        if let details = response["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw CefDevToolsError.rejected(exception?["description"] as? String
                ?? details["text"] as? String ?? "JavaScript evaluation failed.")
        }
        guard let result = response["result"] as? [String: Any] else { throw CefDevToolsError.invalidMessage }
        if result["type"] as? String == "undefined" { return nil }
        guard result.keys.contains("value") else {
            throw CefDevToolsError.rejected("The JavaScript result cannot be copied as JSON.")
        }
        return result["value"]
    }

    func close() {
        guard !closed else { return }
        closed = true
        browserSessionID = nil
        failPending(CefDevToolsError.browserClosed)
        if let registration {
            self.registration = nil
            cefRelease(UnsafeMutableRawPointer(registration))
        }
        browser = nil
        eventObservers.removeAll()
    }

    private func attach(to browser: CefBrowser) throws {
        guard registration == nil else { return }
        let observer = cefAllocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_method_result = { rawSelf, rawBrowser, identifier, success, bytes, count in
            cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
            guard let owner = cefOwner(CefDevTools.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                guard count <= CefDevTools.responseLimit else {
                    owner.finish(identifier, with: .failure(CefDevToolsError.responseTooLarge))
                    return
                }
                let data = bytes.map { Data(bytes: $0, count: count) } ?? Data("{}".utf8)
                guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    owner.finish(identifier, with: .failure(CefDevToolsError.invalidMessage))
                    return
                }
                if success != 0 { owner.finish(identifier, with: .success(data)) }
                else {
                    owner.finish(identifier, with: .failure(CefDevToolsError.protocolError(
                        code: result["code"] as? Int ?? -32000,
                        message: result["message"] as? String ?? "Chromium rejected the protocol request.")))
                }
            }
        }
        observer.pointee.on_dev_tools_agent_detached = { rawSelf, rawBrowser in
            cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
            guard let owner = cefOwner(CefDevTools.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { owner.failPending(CefDevToolsError.browserClosed) }
        }
        observer.pointee.on_dev_tools_event = { rawSelf, rawBrowser, rawMethod, bytes, count in
            cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
            guard count <= CefDevTools.responseLimit,
              let owner = cefOwner(CefDevTools.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let method = CefStringUtil.string(from: rawMethod)
            let data = bytes.map { Data(bytes: $0, count: count) } ?? Data("{}".utf8)
            guard let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            MainActor.assumeIsolated {
                for callback in Array(owner.eventObservers.values) { callback(method, params) }
            }
        }
        var transferred = false
        browser.withHostInternal { host in
            if let addObserver = host.pointee.add_dev_tools_message_observer {
                registration = addObserver(host, observer)
                transferred = true
            }
        }
        if !transferred { cefRelease(UnsafeMutableRawPointer(observer)) }
        guard registration != nil else { throw CefDevToolsError.unavailable }
    }

    private func finish(_ identifier: Int32, with result: Result<Data, Error>) {
        deadlines.removeValue(forKey: identifier)?.cancel()
        pending.removeValue(forKey: identifier)?.resume(with: result)
    }

    private func failPending(_ error: Error) {
        for identifier in Array(pending.keys) { finish(identifier, with: .failure(error)) }
    }
}
