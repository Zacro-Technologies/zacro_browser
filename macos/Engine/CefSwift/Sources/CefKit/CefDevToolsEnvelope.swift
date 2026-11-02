import CoreFoundation
import Foundation

/// CEF's convenience parser does not understand flattened session envelopes.
/// Decode the complete native message once, before its fallback callbacks run.
enum CefDevToolsEnvelope {
    case response(id: Int32, sessionID: String?, result: Result<Data, Error>)
    case event(method: String, parameters: [String: Any], sessionID: String?)

    static let maximumBytes = 10 * 1024 * 1024

    static func responseSession(for requested: String?) -> String? {
        // This one process-local broker token is removed before forwarding to
        // Chromium's browser agent. Real flattened session IDs stay exact.
        requested == "zacro.native.browser.v1" ? nil : requested
    }

    static func parse(_ data: Data, maximumBytes: Int = maximumBytes) throws -> Self {
        guard data.count <= maximumBytes else { throw CefDevToolsError.responseTooLarge }
        guard !data.isEmpty, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CefDevToolsError.invalidMessage
        }
        let session: String?
        if let value = message["sessionId"] {
            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 1024 else {
                throw CefDevToolsError.invalidMessage
            }
            session = text
        } else { session = nil }
        if let value = message["id"] {
            guard let id = integer(value), id > 0, message["method"] == nil else {
                throw CefDevToolsError.invalidMessage
            }
            if let error = message["error"] {
                guard message["result"] == nil, let error = error as? [String: Any],
                    let code = integer(error["code"]), let text = error["message"] as? String else {
                    throw CefDevToolsError.invalidMessage
                }
                return .response(id: id, sessionID: session,
                    result: .failure(CefDevToolsError.protocolError(code: Int(code), message: text)))
            }
            guard message["result"] == nil || message["result"] is [String: Any] else {
                throw CefDevToolsError.invalidMessage
            }
            return .response(id: id, sessionID: session,
                result: .success(try JSONSerialization.data(withJSONObject: message["result"] ?? [:])))
        }
        guard let method = message["method"] as? String, !method.isEmpty, method.utf8.count < 256,
            message["result"] == nil, message["error"] == nil,
            message["params"] == nil || message["params"] is [String: Any] else {
            throw CefDevToolsError.invalidMessage
        }
        return .event(method: method, parameters: message["params"] as? [String: Any] ?? [:], sessionID: session)
    }

    private static func integer(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int32(exactly: number.int64Value)
    }
}
