import CCef
import Foundation

/// A snapshot of one file download's state, delivered through
/// ``CefBrowserDelegate/browser(_:decidePolicyForDownload:suggestedName:)``
/// and ``CefBrowserDelegate/browser(_:downloadDidProgress:)``.
public struct CefDownload: Sendable, Equatable {
    /// CEF's identifier for this download (stable across updates).
    public var id: UInt32
    /// The download URL.
    public var url: URL?
    /// Bytes received so far.
    public var receivedBytes: Int64
    /// Total bytes, or 0 when the server didn't say.
    public var totalBytes: Int64
    /// Whether the download finished successfully.
    public var isComplete: Bool
    /// Whether the download was canceled or interrupted.
    public var isCanceled: Bool
    public var isInterrupted: Bool
    public var isPaused: Bool
    public var isInProgress: Bool
    /// Where the file is being written, once a destination is known.
    public var fullPath: URL?

    public init(
        id: UInt32,
        url: URL?,
        receivedBytes: Int64,
        totalBytes: Int64,
        isComplete: Bool,
        isCanceled: Bool,
        fullPath: URL?,
        isInterrupted: Bool = false,
        isPaused: Bool = false,
        isInProgress: Bool = true
    ) {
        self.id = id
        self.url = url
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.isComplete = isComplete
        self.isCanceled = isCanceled
        self.isInterrupted = isInterrupted
        self.isPaused = isPaused
        self.isInProgress = isInProgress
        self.fullPath = fullPath
    }
}

/// Verdict for a download that is about to begin.
public enum CefDownloadDecision: Sendable {
    /// Proceed. `destination` is the full file path to write (including the
    /// file name); `nil` saves to `~/Downloads/<suggestedName>`.
    case allow(destination: URL?)
    /// Cancel the download.
    case deny
}

/// Resolves a ``CefDownloadDecision`` into a concrete destination path
/// (nil = canceled). Internal so tests can exercise the plumbing.
enum CefDownloadDestination {
    static func resolve(decision: CefDownloadDecision, suggestedName: String) -> URL? {
        switch decision {
        case .deny:
            return nil
        case .allow(let destination):
            if let destination { return destination }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            // Never write outside the directory on a hostile suggested name.
            let safeName = (suggestedName as NSString).lastPathComponent
            return downloads.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
        }
    }
}

extension CefDownload {
    /// Reads a snapshot out of a borrowed `cef_download_item_t`.
    init(item: UnsafeMutablePointer<cef_download_item_t>) {
        let urlString = CefStringUtil.takingUserFree(item.pointee.get_url?(item)) ?? ""
        let path = CefStringUtil.takingUserFree(item.pointee.get_full_path?(item)) ?? ""
        self.init(
            id: item.pointee.get_id?(item) ?? 0,
            url: URL(string: urlString),
            receivedBytes: item.pointee.get_received_bytes?(item) ?? 0,
            totalBytes: item.pointee.get_total_bytes?(item) ?? 0,
            isComplete: (item.pointee.is_complete?(item) ?? 0) != 0,
            isCanceled: (item.pointee.is_canceled?(item) ?? 0) != 0,
            fullPath: path.isEmpty ? nil : URL(fileURLWithPath: path),
            isInterrupted: (item.pointee.is_interrupted?(item) ?? 0) != 0,
            isPaused: (item.pointee.is_paused?(item) ?? 0) != 0,
            isInProgress: (item.pointee.is_in_progress?(item) ?? 0) != 0
        )
    }
}

/// Controls Chromium's original download, including after its source tab closes.
/// A successful call means the command was sent; the following download update
/// is authoritative for the resulting state.
@MainActor
public final class CefDownloadControl {
    nonisolated(unsafe) private var raw: UnsafeMutablePointer<cef_download_item_callback_t>?
    init(raw: UnsafeMutablePointer<cef_download_item_callback_t>) { self.raw = raw }
    deinit { cefRelease(raw.map(UnsafeMutableRawPointer.init)) }

    @discardableResult public func pause() -> Bool {
        guard let raw, let pause = raw.pointee.pause else { return false }
        pause(raw)
        return true
    }
    @discardableResult public func resume() -> Bool {
        guard let raw, let resume = raw.pointee.resume else { return false }
        resume(raw)
        return true
    }
    @discardableResult public func cancel() -> Bool {
        guard let raw, let cancel = raw.pointee.cancel else { return false }
        cancel(raw)
        return true
    }
    /// Release before Chromium is shut down. Repeated calls are harmless.
    public func invalidate() {
        let old = raw
        raw = nil
        cefRelease(old.map(UnsafeMutableRawPointer.init))
    }
}
