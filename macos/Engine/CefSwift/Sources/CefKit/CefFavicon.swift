import CCef
import Foundation

extension CefBrowser {
    /// Uses Chromium's image decoder for SVG/ICO/PNG favicons. Favicon mode
    /// explicitly suppresses sending and accepting cookies. The returned
    /// representation is a bounded PNG suitable for an offline icon cache.
    public func downloadFavicon(_ imageURL: URL) async -> Data? {
        guard hasRawBrowser, imageURL.user == nil, imageURL.password == nil,
              imageURL.absoluteString.utf8.count <= 524_288,
              ["http", "https", "data"].contains(imageURL.scheme?.lowercased() ?? ""),
              imageURL.scheme != "data" || imageURL.absoluteString.hasPrefix("data:image/")
        else { return nil }
        return await NativeFaviconDownload().run(browser: self, url: imageURL)
    }
}

@MainActor
private final class NativeFaviconDownload {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var timer: Task<Void, Never>?
    func run(browser: CefBrowser, url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    self?.finish(nil)
                }
                var started = false
                browser.withHostInternal { host in
                    guard let download = host.pointee.download_image else { return }
                    let callback = cefAllocate(cef_download_image_callback_t.self, owner: self)
                    callback.pointee.on_download_image_finished = { rawSelf, _, status, image in
                        defer { cefRelease(image.map(UnsafeMutableRawPointer.init)) }
                        guard let owner = cefOwner(NativeFaviconDownload.self, rawSelf.map(UnsafeMutableRawPointer.init)) else { return }
                        MainActor.assumeIsolated {
                            guard status == 0 || (200..<300).contains(status), let image else { owner.finish(nil); return }
                            var width: Int32 = 0, height: Int32 = 0
                            guard let binary = image.pointee.get_as_png?(image, 1, 1, &width, &height) else { owner.finish(nil); return }
                            defer { cefRelease(UnsafeMutableRawPointer(binary)) }
                            let size = binary.pointee.get_size?(binary) ?? 0
                            guard width > 0, height > 0, width <= 256, height <= 256,
                                  size > 0, size <= 524_288 else { owner.finish(nil); return }
                            var bytes = Data(count: size)
                            let copied = bytes.withUnsafeMutableBytes { buffer in
                                binary.pointee.get_data?(binary, buffer.baseAddress, size, 0) ?? 0
                            }
                            owner.finish(copied == size ? bytes : nil)
                        }
                    }
                    CefStringUtil.withCefString(url.absoluteString) { download(host, $0, 1, 64, 0, callback) }
                    started = true
                }
                if !started { finish(nil) }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.finish(nil) } }
    }
    private func finish(_ data: Data?) {
        timer?.cancel(); timer = nil
        let pending = continuation; continuation = nil
        pending?.resume(returning: data)
    }
}
