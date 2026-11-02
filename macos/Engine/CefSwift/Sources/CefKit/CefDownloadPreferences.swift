import CCef
import Foundation

extension CefBrowser {
    /// Sets the real Chromium download/save destination in this browser's
    /// request context. The caller chooses and creates the directory; this
    /// never changes another profile or bypasses a managed preference.
    public func setDownloadDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.contains("\0"), directory.path.utf8.count <= 4096,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw CefDevToolsError.rejected("Choose an existing local download directory.")
        }
        var context: UnsafeMutablePointer<cef_request_context_t>?
        withHostInternal { context = $0.pointee.get_request_context?($0) }
        guard let context else { throw CefDevToolsError.unavailable }
        defer { cefRelease(UnsafeMutableRawPointer(context)) }
        try withUnsafeMutablePointer(to: &context.pointee.base) { preferences in
            let names = ["download.default_directory", "savefile.default_directory"]
            guard let canSet = preferences.pointee.can_set_preference,
                  let set = preferences.pointee.set_preference else { throw CefDevToolsError.unavailable }
            // Check every setting before changing any of them. Policy and
            // command-line values remain authoritative.
            for name in names {
                guard CefStringUtil.withCefString(name, { canSet(preferences, $0) != 0 }) else {
                    throw CefDevToolsError.rejected("Chromium does not allow changing \(name) in this profile.")
                }
            }
            guard let value = cef_value_create() else { throw CefDevToolsError.unavailable }
            defer { cefRelease(UnsafeMutableRawPointer(value)) }
            guard let setString = value.pointee.set_string else { throw CefDevToolsError.unavailable }
            guard CefStringUtil.withCefString(directory.standardizedFileURL.path, {
                setString(value, $0) != 0
            }) else { throw CefDevToolsError.unavailable }
            for name in names {
                var error = cef_string_t()
                defer { ccef_string_clear(&error) }
                // CEF's CppToC Unwrap consumes one transferred reference for
                // object arguments; retain our original value across both
                // preference writes and release that original below.
                cefAddRef(UnsafeMutableRawPointer(value))
                let changed = CefStringUtil.withCefString(name) { set(preferences, $0, value, &error) != 0 }
                guard changed else {
                    let message = CefStringUtil.string(from: error)
                    throw CefDevToolsError.rejected(message.isEmpty ? "Chromium could not update \(name)." : message)
                }
            }
        }
    }
}
