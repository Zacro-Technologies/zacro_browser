import CCef
import Foundation

public struct CefNetworkData: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let cookies = CefNetworkData(rawValue: 1 << 0)
    public static let cache = CefNetworkData(rawValue: 1 << 1)
    public static let httpAuthentication = CefNetworkData(rawValue: 1 << 2)
    public static let certificateExceptions = CefNetworkData(rawValue: 1 << 3)
    public static let all: CefNetworkData = [.cookies, .cache, .httpAuthentication, .certificateExceptions]
}

extension CefProfile {
    /// Clears exactly the selected network stores in this profile. This does
    /// not clear IndexedDB, local storage, service workers, or extension data.
    /// A full site-data purge must use Chromium's browsing-data remover.
    public func clearNetworkData(_ selected: CefNetworkData = .all) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in whenReady { continuation.resume() } }
        guard let context = makeRequestContext() ?? cef_request_context_get_global_context() else {
            throw CefDevToolsError.unavailable
        }
        defer { cefRelease(UnsafeMutableRawPointer(context)) }
        if selected.contains(.cookies) {
            var manager: UnsafeMutablePointer<cef_cookie_manager_t>?
            _ = try await NativeCompletion().wait { completion in
                guard let get = context.pointee.get_cookie_manager else { return false }
                manager = get(context, completion.makeCallback())
                return manager != nil
            }
            guard let manager else { throw CefDevToolsError.unavailable }
            defer { cefRelease(UnsafeMutableRawPointer(manager)) }
            _ = try await NativeCompletion().wait { completion in
                guard let remove = manager.pointee.delete_cookies else { return false }
                let callback = cefAllocate(cef_delete_cookies_callback_t.self, owner: completion)
                callback.pointee.on_complete = { rawSelf, count in
                    guard let owner = cefOwner(NativeCompletion.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
                    MainActor.assumeIsolated { owner.finish(.success(Int(count))) }
                }
                return remove(manager, nil, nil, callback) != 0
            }
        }
        if selected.contains(.cache) {
            _ = try await NativeCompletion().wait { completion in
                guard let clear = context.pointee.clear_http_cache else { return false }
                clear(context, completion.makeCallback()); return true
            }
        }
        if selected.contains(.httpAuthentication) {
            _ = try await NativeCompletion().wait { completion in
                guard let clear = context.pointee.clear_http_auth_credentials else { return false }
                clear(context, completion.makeCallback()); return true
            }
        }
        if selected.contains(.certificateExceptions) {
            _ = try await NativeCompletion().wait { completion in
                guard let clear = context.pointee.clear_certificate_exceptions else { return false }
                clear(context, completion.makeCallback()); return true
            }
        }
        try Task.checkCancellation()
    }
}

@MainActor
private final class NativeCompletion {
    private var continuation: CheckedContinuation<Int, Error>?
    private var timer: Task<Void, Never>?

    func wait(_ start: (NativeCompletion) -> Bool) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                self?.finish(.failure(CefDevToolsError.timeout))
            }
            if !start(self) { finish(.failure(CefDevToolsError.unavailable)) }
        }
    }

    func makeCallback() -> UnsafeMutablePointer<cef_completion_callback_t> {
        let callback = cefAllocate(cef_completion_callback_t.self, owner: self)
        callback.pointee.on_complete = { rawSelf in
            guard let owner = cefOwner(NativeCompletion.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { owner.finish(.success(0)) }
        }
        return callback
    }

    func finish(_ result: Result<Int, Error>) {
        timer?.cancel(); timer = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
