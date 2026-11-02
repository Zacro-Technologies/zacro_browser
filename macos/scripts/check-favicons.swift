// Run: swiftc macos/Sources/ZacroApp/FaviconCache.swift macos/scripts/check-favicons.swift -o /tmp/zacro-favicon-check && /tmp/zacro-favicon-check
// No browser, GUI events, network, user profile, or Keychain access.
import AppKit
import Foundation

@main @MainActor
struct FaviconChecks {
  static func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
  }
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zacro-favicon-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = FaviconCache(directory: root)
    let urls = (0..<140).map { URL(string: "https://fixture.invalid/page/\($0)")! }
    cache.retain(urls.map { ("public", $0) } + [("private", urls[0])])
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 512, bitsPerPixel: 32)!
    let pixels = bitmap.bitmapData!
    for pixel in 0..<(128 * 128) {
      pixels[pixel * 4] = 26; pixels[pixel * 4 + 1] = 153
      pixels[pixel * 4 + 2] = 51; pixels[pixel * 4 + 3] = 255
    }
    let png = bitmap.representation(using: .png, properties: [:])!
    func load(_ url: URL, profile: String, isPrivate: Bool) async -> NSImage {
      await withCheckedContinuation { continuation in
        cache.load(profile: profile, pageURL: url, iconURL: URL(string: "https://fixture.invalid/favicon.png")!,
          isPrivate: isPrivate, persist: true, nativeImage: { png }) { image in
          continuation.resume(returning: image)
        }
      }
    }
    for url in urls { _ = await load(url, profile: "public", isPrivate: false) }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    check(files.count == 140, "Every saved destination must survive memory eviction on disk")
    let privateImage = await load(urls[0], profile: "private", isPrivate: true)
    check(privateImage.size.width <= 64, "Raster allocation must be bounded")
    check(cache.accent(privateImage)?.greenComponent ?? 0 > 0.5, "Website accent must survive normalization")
    check(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 140, "Private favicon must not be persisted")
    let restarted = FaviconCache(directory: root)
    restarted.retain(urls.map { ("public", $0) })
    check(restarted.cached(profile: "public", url: urls[0], isPrivate: false) != nil,
      "Saved icon must load after restart without network")
    check(restarted.cached(profile: "private", url: urls[0], isPrivate: true) == nil,
      "Private icon must not survive restart")
    check((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int) == 0o600,
      "Saved favicon should be owner-readable only")
    restarted.retain([("public", urls[0])])
    check(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1,
      "Unpinned destinations must be pruned")
    restarted.clear(profile: "public")
    check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
      "Clearing a profile must remove its saved icons")

    let lateURL = URL(string: "https://fixture.invalid/late")!
    let late = FaviconCache(directory: root)
    late.retain([("public", lateURL)])
    var gate: CheckedContinuation<Data?, Never>?
    var received = false
    late.load(profile: "public", pageURL: lateURL, iconURL: lateURL,
      isPrivate: false, persist: true,
      nativeImage: { await withCheckedContinuation { gate = $0 } }) { _ in received = true }
    while gate == nil { await Task.yield() }
    late.clear(profile: "public")
    gate?.resume(returning: png)
    for _ in 0..<20 { await Task.yield() }
    check(!received && late.cached(profile: "public", url: lateURL, isPrivate: false) == nil,
      "A response arriving after clear must not repopulate the profile")
    check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
      "A late favicon must not recreate a cleared disk entry")
    print("PASS: bounded raster cache, saved-icon retention, offline restart, private isolation, pruning, permissions, and late-clear cancellation")
  }
}
