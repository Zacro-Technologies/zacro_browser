import CCef
import Foundation

/// An isolated browsing profile — a CEF request context with its own cookies,
/// `localStorage`, cache, and HTTP state.
///
/// ```swift
/// let work = CefProfile.persistent(name: "Work")
/// let temp = CefProfile.incognito()
/// var options = CefBrowserOptions()
/// options.profile = work
/// ```
///
/// - ``default`` uses the global request context (shared with the runtime's
///   `cachePath`).
/// - ``incognito()`` is in-memory: nothing is persisted to disk.
/// - ``persistent(name:)`` stores its data under
///   `<rootCachePath>/<name>`, isolated from other profiles.
///
/// Create profiles after ``CefRuntime/initialize(configuration:)`` succeeds.
@MainActor
public final class CefProfile {
    /// How the underlying request context is materialized.
    enum Kind: Equatable {
        case global
        case incognito
        case persistent(name: String)
    }

    let kind: Kind

    /// Owned +1 reference to the underlying `cef_request_context_t`, created
    /// lazily on first use. `nil` for ``default`` until first accessed.
    /// `nonisolated(unsafe)`: only mutated on the main actor; the nonisolated
    /// deinit reads it once to release, by which point no other access races.
    nonisolated(unsafe) private var raw: UnsafeMutablePointer<cef_request_context_t>?

    private var initialized = false
    private var readyCallbacks: [() -> Void] = []

    private init(kind: Kind) {
        self.kind = kind
    }

    deinit {
        if let raw {
            cefRelease(UnsafeMutableRawPointer(raw))
        }
    }

    /// The global (default) profile — shares storage with the runtime's
    /// configured cache path.
    public static var `default`: CefProfile {
        CefProfile(kind: .global)
    }

    /// A fresh in-memory profile. Cookies and storage live only in RAM and
    /// vanish when the profile is released.
    public static func incognito() -> CefProfile {
        CefProfile(kind: .incognito)
    }

    /// A named on-disk profile stored under
    /// `<rootCachePath>/<name>`. Reusing the same `name` reuses the
    /// same storage.
    public static func persistent(name: String) -> CefProfile {
        CefProfile(kind: .persistent(name: name))
    }

    /// The on-disk cache path for a profile kind given a root, or `nil` for
    /// the global and incognito kinds (global = runtime cache; incognito =
    /// in-memory). Pure function, exposed for testing.
    static func cachePath(for kind: Kind, rootCachePath: URL?) -> URL? {
        switch kind {
        case .global, .incognito:
            return nil
        case .persistent(let name):
            let safe = sanitize(name)
            return rootCachePath?
                .appendingPathComponent(safe, isDirectory: true)
        }
    }

    /// Strips path separators and leading dots so a profile name can't escape
    /// the Profiles directory.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let trimmed = cleaned.drop(while: { $0 == "." })
        return trimmed.isEmpty ? "Profile" : String(trimmed)
    }

    /// Returns the underlying `cef_request_context_t` to hand to CEF at
    /// browser creation. The returned pointer carries a +1 reference the
    /// caller must release (CEF consumes one ref when it stores the context).
    /// Returns `nil` for ``default`` (callers pass `nil` to use the global
    /// context implicitly).
    func makeRequestContext() -> UnsafeMutablePointer<cef_request_context_t>? {
        switch kind {
        case .global:
            return nil
        case .incognito, .persistent:
            if raw == nil {
                raw = createContext()
            }
            guard let raw else { preconditionFailure("Chromium failed to create isolated profile context") }
            cefAddRef(UnsafeMutableRawPointer(raw))
            return raw
        }
    }

    /// Chrome BrowserViews require a fully initialized request context.
    /// Disk profile initialization is asynchronous, unlike an OTR context.
    func whenReady(_ callback: @escaping () -> Void) {
        if kind == .global { callback(); return }
        if raw == nil { raw = createContext() }
        guard raw != nil else { preconditionFailure("Chromium failed to create isolated profile context") }
        if initialized { callback() } else { readyCallbacks.append(callback) }
    }

    fileprivate func didInitialize() {
        initialized = true
        let callbacks = readyCallbacks
        readyCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    private func createContext() -> UnsafeMutablePointer<cef_request_context_t>? {
        var settings = cef_request_context_settings_t()
        settings.size = MemoryLayout<cef_request_context_settings_t>.stride

        let root = CefRuntime.shared.configuration?.rootCachePath
        if let path = CefProfile.cachePath(for: kind, rootCachePath: root) {
            do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            catch { preconditionFailure("Cannot create isolated Chromium profile directory") }
            CefStringUtil.set(path.path, into: &settings.cache_path)
            if CefRuntime.shared.configuration?.persistSessionCookies == true {
                settings.persist_session_cookies = 1
            }
        }
        // Empty cache_path => incognito/in-memory (the CEF default).
        defer { ccef_string_clear(&settings.cache_path) }
        // No request-context handler needed: cookies/storage isolation is
        // driven entirely by the distinct cache_path.
        let handler = cefAllocate(cef_request_context_handler_t.self, owner: ProfileReadyHandler(profile: self))
        handler.pointee.on_request_context_initialized = { handlerSelf, context in
            defer { cefRelease(context.map(UnsafeMutableRawPointer.init)) }
            guard let owner = cefOwner(ProfileReadyHandler.self, handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { owner.profile?.didInitialize() }
        }
        return cef_request_context_create_context(&settings, handler)
    }
}

@MainActor
private final class ProfileReadyHandler {
    weak var profile: CefProfile?
    init(profile: CefProfile) { self.profile = profile }
}
