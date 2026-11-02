import CCef
import Foundation

public struct CefResourceResponse: Sendable {
    public let url: URL
    public let mimeType: String
    public let status: Int
    public let data: Data
}

public enum CefResourceError: Error, LocalizedError, Equatable {
    case browserClosed, invalidURL, unsafeRedirect, tooLarge, timeout, unavailable
    case http(Int), network(Int)
    public var errorDescription: String? {
        switch self {
        case .browserClosed: return "The document closed while its content was being read."
        case .invalidURL: return "Only the current HTTP or HTTPS document can be read."
        case .unsafeRedirect: return "The document redirected outside its original site."
        case .tooLarge: return "The document exceeds the supported size."
        case .timeout: return "The document did not finish downloading in time."
        case .unavailable: return "The document's browser profile is unavailable."
        case .http(let code): return "The document request failed (HTTP \(code))."
        case .network(let code): return "The document request failed (Chromium \(code))."
        }
    }
}

extension CefBrowser {
    /// Fetches the current document through its Chromium profile, preserving
    /// cookies and HTTP authentication. It is a new bounded GET, not a promise
    /// of the exact bytes of an earlier response. Redirects stay on the initial
    /// origin. Callers must verify document identity after awaiting the result.
    public func fetchResource(
        _ requestedURL: URL, maximumBytes: Int = 20 * 1024 * 1024,
        maximumRedirects: Int = 3, timeout: TimeInterval = 25
    ) async throws -> CefResourceResponse {
        guard hasRawBrowser else { throw CefResourceError.browserClosed }
        guard resourceFetches.count < 4, maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024,
              (0...5).contains(maximumRedirects), timeout.isFinite, timeout > 0, timeout <= 60,
              let current = url,
              CefResourceFetch.documentURL(current) == CefResourceFetch.documentURL(requestedURL),
              CefResourceFetch.validURL(requestedURL) else { throw CefResourceError.invalidURL }
        let id = UUID()
        let operation = CefResourceFetch(browser: self, url: requestedURL, limit: maximumBytes,
                                         redirects: maximumRedirects, timeout: timeout)
        resourceFetches[id] = operation
        defer { resourceFetches.removeValue(forKey: id) }
        return try await operation.run()
    }
}

@MainActor
final class CefResourceFetch {
    private weak var browser: CefBrowser?
    private let initialURL: URL
    private var currentURL: URL
    private let limit: Int
    private var redirects: Int
    private let timeout: TimeInterval
    private var request: UnsafeMutablePointer<cef_urlrequest_t>?
    private var continuation: CheckedContinuation<CefResourceResponse, Error>?
    private var deadline: Task<Void, Never>?
    private var data = Data()

    init(browser: CefBrowser, url: URL, limit: Int, redirects: Int, timeout: TimeInterval) {
        self.browser = browser; initialURL = url; currentURL = url
        self.limit = limit; self.redirects = redirects; self.timeout = timeout
    }

    static func documentURL(_ url: URL) -> String? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string
    }

    static func validURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    func run() async throws -> CefResourceResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 25) * 1_000_000_000)) }
                    catch { return }
                    self?.cancel(CefResourceError.timeout)
                }
                start()
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel(CancellationError()) } }
    }

    func cancel(_ error: Error) { finish(.failure(error), cancel: true) }

    private func start() {
        guard continuation != nil, let browser, browser.hasRawBrowser else {
            cancel(CefResourceError.browserClosed); return
        }
        guard let rawRequest = cef_request_create() else { cancel(CefResourceError.unavailable); return }
        CefStringUtil.withCefString(currentURL.absoluteString) { rawRequest.pointee.set_url?(rawRequest, $0) }
        CefStringUtil.withCefString("GET") { rawRequest.pointee.set_method?(rawRequest, $0) }
        CefStringUtil.withCefString(initialURL.absoluteString) {
            rawRequest.pointee.set_first_party_for_cookies?(rawRequest, $0)
        }
        rawRequest.pointee.set_flags?(rawRequest, Int32(
            UR_FLAG_ALLOW_STORED_CREDENTIALS.rawValue | UR_FLAG_STOP_ON_REDIRECT.rawValue |
            UR_FLAG_NO_RETRY_ON_5XX.rawValue))
        let client = cefAllocate(cef_urlrequest_client_t.self, owner: self)
        client.pointee.on_download_data = { rawSelf, rawRequest, bytes, count in
            defer { cefRelease(rawRequest.map(UnsafeMutableRawPointer.init)) }
            guard let owner = cefOwner(CefResourceFetch.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                guard owner.continuation != nil else { return }
                guard count <= owner.limit - owner.data.count else { owner.cancel(CefResourceError.tooLarge); return }
                if let bytes { owner.data.append(Data(bytes: bytes, count: count)) }
            }
        }
        client.pointee.on_download_progress = { rawSelf, rawRequest, current, total in
            defer { cefRelease(rawRequest.map(UnsafeMutableRawPointer.init)) }
            guard let owner = cefOwner(CefResourceFetch.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                if current > owner.limit || total > owner.limit { owner.cancel(CefResourceError.tooLarge) }
            }
        }
        client.pointee.on_request_complete = { rawSelf, rawRequest in
            defer { cefRelease(rawRequest.map(UnsafeMutableRawPointer.init)) }
            guard let rawRequest,
                  let owner = cefOwner(CefResourceFetch.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { owner.complete(rawRequest) }
        }
        client.pointee.get_auth_credentials = { _, _, _, _, _, _, callback in
            cefRelease(callback.map(UnsafeMutableRawPointer.init))
            return 0 // No new credential prompt during background extraction.
        }
        var context: UnsafeMutablePointer<cef_request_context_t>?
        browser.withHostInternal { context = $0.pointee.get_request_context?($0) }
        guard let context else {
            cefRelease(UnsafeMutableRawPointer(rawRequest)); cefRelease(UnsafeMutableRawPointer(client))
            cancel(CefResourceError.unavailable); return
        }
        // The CEF C bridge consumes the +1 input references.
        request = cef_urlrequest_create(rawRequest, client, context)
        if request == nil { cancel(CefResourceError.unavailable) }
    }

    private func complete(_ rawRequest: UnsafeMutablePointer<cef_urlrequest_t>) {
        guard continuation != nil else { return }
        guard let response = rawRequest.pointee.get_response?(rawRequest) else {
            cancel(CefResourceError.network(Int(rawRequest.pointee.get_request_error?(rawRequest).rawValue ?? 0)))
            return
        }
        defer { cefRelease(UnsafeMutableRawPointer(response)) }
        let status = Int(response.pointee.get_status?(response) ?? 0)
        if [301, 302, 303, 307, 308].contains(status) {
            let location = CefStringUtil.withCefString("Location") {
                CefStringUtil.takingUserFree(response.pointee.get_header_by_name?(response, $0))
            }
            guard redirects > 0, let location, let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                  Self.validURL(next), Self.origin(next) == Self.origin(initialURL) else {
                cancel(CefResourceError.unsafeRedirect); return
            }
            redirects -= 1; currentURL = next; data.removeAll(keepingCapacity: true)
            if let request { self.request = nil; cefRelease(UnsafeMutableRawPointer(request)) }
            start()
            return
        }
        guard rawRequest.pointee.get_request_status?(rawRequest) == UR_SUCCESS else {
            cancel(CefResourceError.network(Int(rawRequest.pointee.get_request_error?(rawRequest).rawValue ?? 0)))
            return
        }
        guard (200...299).contains(status) else { cancel(CefResourceError.http(status)); return }
        let mimeType = CefStringUtil.takingUserFree(response.pointee.get_mime_type?(response)) ?? ""
        finish(.success(CefResourceResponse(url: currentURL, mimeType: mimeType, status: status, data: data)))
    }

    private func finish(_ result: Result<CefResourceResponse, Error>, cancel: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        if let request {
            self.request = nil
            if cancel { request.pointee.cancel?(request) }
            cefRelease(UnsafeMutableRawPointer(request))
        }
        continuation.resume(with: result)
    }
}
