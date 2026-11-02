import AppKit
import CryptoKit
import Foundation
import ImageIO

@MainActor
final class FaviconCache {
  private let directory: URL
  private var images: [String: NSImage] = [:]
  private var pending: [String: UUID] = [:]
  private var loadedURLs: [String: URL] = [:]
  private var retryAfter: [String: Date] = [:]
  private var persisted: Set<String> = []
  private var missing = Set<String>()
  private let accents = NSMapTable<NSImage, NSColor>.weakToStrongObjects()
  private let colorless = NSHashTable<NSImage>.weakObjects()
  private var generations: [String:Int] = [:]
  private var retained = Set<String>()
  private var initialized = false
  private var recency: [String] = []
  private let maximumEntries = 128
  init(directory: URL) { self.directory = directory }

  /// Memory eviction never deletes an icon for a saved destination. Disk entries
  /// follow saved home/current/Peek URLs, so unpinning and profile deletion prune
  /// old browsing metadata instead of accumulating an unbounded history cache.
  func retain(_ destinations: [(profile: String, url: URL)]) {
    let next = Set(destinations.map { key(profile: $0.profile, url: $0.url) })
    guard !initialized || next != retained else { return }
    retained = next; initialized = true
    persisted.formIntersection(next)
    missing.formIntersection(next)
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
      let name = file.deletingPathExtension().lastPathComponent
      if file.pathExtension == "png", name.count == 129,
         name.allSatisfy({ $0.isHexDigit || $0 == "-" }), !next.contains(name) {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
  private func key(profile: String, url: URL) -> String {
    namespace(profile) + "-" + SHA256.hash(data: Data(url.absoluteString.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
  private func namespace(_ profile: String) -> String {
    SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  func cached(profile: String, url: URL, isPrivate: Bool, persist: Bool = false) -> NSImage? {
    let id = key(profile: profile, url: url)
    if let image = images[id] {
      touch(id)
      if persist && !isPrivate { persistImage(image, id: id) }
      return image
    }
    guard !isPrivate, retained.contains(id), !missing.contains(id) else { return nil }
    let file = directory.appendingPathComponent(id + ".png")
    guard
      let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
      size <= 524_288,
      let bytes = try? Data(contentsOf: file),
      let image = normalizedImage(bytes)
    else { missing.insert(id); return nil }
    remember(image, id: id)
    persisted.insert(id)
    return image
  }
  func load(
    profile: String, pageURL: URL, iconURL: URL, isPrivate: Bool, persist: Bool,
    nativeImage: (() async -> Data?)? = nil,
    completion: @escaping (NSImage) -> Void
  ) {
    let id = key(profile: profile, url: pageURL)
    if let cached = cached(profile: profile, url: pageURL, isPrivate: isPrivate) {
      completion(cached)
      if persist && !isPrivate { persistImage(cached, id: id) }
      if loadedURLs[id] == iconURL { return }
    }
    guard retryAfter[id].map({ $0 <= Date() }) ?? true else { return }
    guard (["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") || (nativeImage != nil && iconURL.absoluteString.hasPrefix("data:image/"))), iconURL.user == nil,
      iconURL.password == nil,
      pending[id] == nil, pending.count < 16
    else { return }
    let request = UUID()
    pending[id] = request
    retryAfter[id] = Date().addingTimeInterval(60)
    if retryAfter.count > 512 {
      for key in retryAfter.sorted(by: { $0.value < $1.value }).prefix(128).map(\.key) {
        retryAfter.removeValue(forKey: key)
      }
    }
    let generation = generations[profile, default: 0]
    Task {
      defer { if pending[id] == request { pending.removeValue(forKey: id) } }
      do {
        let data: Data
        if let native = await nativeImage?() { data = native }
        else {
          guard ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") else { return }
          let configuration = URLSessionConfiguration.ephemeral
          configuration.httpCookieStorage = nil
          configuration.timeoutIntervalForRequest = 8
          configuration.urlCache = nil
          let session = URLSession(configuration: configuration)
          defer { session.invalidateAndCancel() }
          let (stream, response) = try await session.bytes(from: iconURL)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
          var bytes = Data()
          for try await byte in stream {
            guard bytes.count < 512_000 else { return }
            bytes.append(byte)
          }
          data = bytes
        }
        guard let image = normalizedImage(data)
        else { return }
        guard generations[profile, default: 0] == generation else { return }
        missing.remove(id)
        remember(image, id: id)
        loadedURLs[id] = iconURL
        retryAfter.removeValue(forKey: id)
        persisted.remove(id)
        completion(image)
        if persist && !isPrivate { persistImage(image, id: id) }
      } catch { /* Keep cached icons when offline. */  }
    }
  }

  func clear(profile: String) {
    generations[profile, default: 0] += 1
    let prefix = namespace(profile) + "-"
    images = images.filter { !$0.key.hasPrefix(prefix) }
    recency.removeAll { $0.hasPrefix(prefix) }
    pending = pending.filter { !$0.key.hasPrefix(prefix) }
    retryAfter = retryAfter.filter { !$0.key.hasPrefix(prefix) }
    loadedURLs = loadedURLs.filter { !$0.key.hasPrefix(prefix) }
    persisted = persisted.filter { !$0.hasPrefix(prefix) }
    missing = missing.filter { !$0.hasPrefix(prefix) }
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "png" { try? FileManager.default.removeItem(at: file) }
  }
  /// Same weighted 32×32 color buckets as renderer/favicon-accent.js.
  func accent(_ image: NSImage) -> NSColor? {
    if let color = accents.object(forKey: image) { return color }
    guard !colorless.contains(image), let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    var buckets: [Int:(weight:Double, red:Double, green:Double, blue:Double)] = [:]
    for y in 0..<32 { for x in 0..<32 {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
      let r = color.redComponent * 255, g = color.greenComponent * 255, b = color.blueComponent * 255, a = color.alphaComponent
      let maximum = max(r,g,b), minimum = min(r,g,b), saturation = maximum > 0 ? (maximum-minimum)/maximum : 0
      guard a * 255 >= 96, maximum >= 40, minimum <= 225, saturation >= 0.22 else { continue }
      let weight = a * saturation, key = (Int(r)>>5)*64 + (Int(g)>>5)*8 + (Int(b)>>5)
      let bucket = buckets[key] ?? (0,0,0,0)
      buckets[key] = (bucket.weight+weight, bucket.red+r*weight, bucket.green+g*weight, bucket.blue+b*weight)
    } }
    guard let chosen = buckets.values.max(by: { $0.weight < $1.weight }), chosen.weight >= 1.5 else { colorless.add(image); return nil }
    let color = NSColor(srgbRed: (chosen.red/chosen.weight).rounded()/255, green: (chosen.green/chosen.weight).rounded()/255, blue: (chosen.blue/chosen.weight).rounded()/255, alpha: 1)
    accents.setObject(color, forKey: image); return color
  }

  private func touch(_ id: String) {
    recency.removeAll { $0 == id }; recency.append(id)
  }
  private func remember(_ image: NSImage, id: String) {
    images[id] = image; touch(id)
    while recency.count > maximumEntries {
      let oldest = recency.removeFirst()
      images.removeValue(forKey: oldest); loadedURLs.removeValue(forKey: oldest)
    }
  }
  private func normalizedImage(_ data: Data) -> NSImage? {
    guard !data.isEmpty, data.count <= 524_288,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 1024, height <= 1024,
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 64,
        kCGImageSourceCreateThumbnailWithTransform: true
      ] as CFDictionary) else { return nil }
    return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
  }

  private func persistImage(_ image: NSImage, id: String) {
    guard retained.contains(id), !persisted.contains(id), let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let file = directory.appendingPathComponent(id + ".png")
      try png.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      persisted.insert(id)
    } catch { /* Keep the in-memory icon if the cache cannot be written. */ }
  }
}
