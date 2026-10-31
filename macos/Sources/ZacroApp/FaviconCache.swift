import AppKit
import CryptoKit
import Foundation

@MainActor
final class FaviconCache {
  private let directory: URL
  private var images: [String: NSImage] = [:]
  private var pending: Set<String> = []
  init(directory: URL) { self.directory = directory }
  private func key(profile: String, url: URL) -> String {
    SHA256.hash(data: Data((profile + "\n" + url.absoluteString).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
  func cached(profile: String, url: URL, isPrivate: Bool) -> NSImage? {
    let id = key(profile: profile, url: url)
    if let image = images[id] { return image }
    guard !isPrivate,
      let bytes = try? Data(contentsOf: directory.appendingPathComponent(id + ".png")),
      bytes.count <= 512_000,
      let image = NSImage(data: bytes)
    else { return nil }
    images[id] = image
    return image
  }
  func load(
    profile: String, pageURL: URL, iconURL: URL, isPrivate: Bool, persist: Bool,
    completion: @escaping (NSImage) -> Void
  ) {
    let id = key(profile: profile, url: pageURL)
    if let cached = cached(profile: profile, url: pageURL, isPrivate: isPrivate) {
      completion(cached)
    }
    guard ["http", "https"].contains(iconURL.scheme?.lowercased() ?? ""), iconURL.user == nil,
      iconURL.password == nil,
      pending.insert(id).inserted
    else { return }
    Task {
      defer { pending.remove(id) }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.timeoutIntervalForRequest = 8
      configuration.urlCache = nil
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      do {
        let (stream, response) = try await session.bytes(from: iconURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        var data = Data()
        for try await byte in stream {
          guard data.count < 512_000 else { return }
          data.append(byte)
        }
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide <= 1024,
          bitmap.pixelsHigh <= 1024,
          let image = NSImage(data: data)
        else { return }
        images[id] = image
        completion(image)
        if persist && !isPrivate, let png = bitmap.representation(using: .png, properties: [:]) {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try png.write(to: directory.appendingPathComponent(id + ".png"), options: .atomic)
        }
      } catch { /* Keep cached icons when offline. */  }
    }
  }
}
