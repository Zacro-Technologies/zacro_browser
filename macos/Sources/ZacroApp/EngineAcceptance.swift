import AppKit
import Foundation
import ZacroChromium

/// Explicit disposable-profile acceptance mode; never used in normal browsing.
@MainActor
final class EngineAcceptance {
  private let engine: ChromiumEngine
  private var timer: Timer?
  private var stage = 0
  private var started = Date()
  private var pages: [ChromiumPage] = []
  init(engine: ChromiumEngine) { self.engine = engine }
  func run(url: URL) {
    DispatchQueue.main.async { [self] in startPages(url: url) }
  }
  private func startPages(url: URL) {
    pages = [
      engine.page(id: "acceptance-a", profileID: "a", isPrivate: false, url: url),
      engine.page(id: "acceptance-b", profileID: "a", isPrivate: false, url: url),
      engine.page(id: "acceptance-isolated", profileID: "b", isPrivate: false, url: url),
      engine.page(id: "acceptance-private", profileID: "private", isPrivate: true, url: url),
    ]
    engine.showWindow()
    for (index, page) in pages.enumerated() {
      page.show(
        frame: CGRect(x: 224 + (index % 2) * 500, y: 4 + (index / 2) * 350, width: 494, height: 344)
      )
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }
  private func tick() {
    if Date().timeIntervalSince(started) > 25 {
      finish(error: "Timed out at stage \(stage)")
      return
    }
    switch stage {
    case 0:
      guard pages.allSatisfy({ !$0.isLoading && $0.title.contains("acceptance") }) else { return }
      guard Set(pages.compactMap { $0.browser?.id }).count == 4 else {
        finish(error: "Documents not independent")
        return
      }
      guard pages.allSatisfy({ $0.browser?.isChromeRuntime == true }) else {
        finish(error: "Not Chrome runtime")
        return
      }
      guard pages[0].browser?.profileCachePath == pages[1].browser?.profileCachePath,
        pages[0].browser?.profileCachePath != pages[2].browser?.profileCachePath,
        pages[3].browser?.profileCachePath == nil
      else {
        finish(error: "Profile context isolation failed")
        return
      }
      pages[0].show(frame: CGRect(x: 224, y: 4, width: 500, height: 700))
      pages[1].show(frame: CGRect(x: 730, y: 4, width: 500, height: 700))
      pages[0].browser?.executeJavaScript(
        "localStorage.setItem('zacro-acceptance','retained'); document.title='written';")
      stage = 1
    case 1:
      guard pages[0].title == "written" else { return }
      pages[0].hide()
      pages[1].browser?.executeJavaScript(
        "document.title=localStorage.getItem('zacro-acceptance')==='retained'?'shared-ok':'shared-fail'"
      )
      pages[2].browser?.executeJavaScript(
        "document.title=localStorage.getItem('zacro-acceptance')===null?'isolated-ok':'isolated-fail'"
      )
      pages[3].browser?.executeJavaScript(
        "document.title=localStorage.getItem('zacro-acceptance')===null?'private-ok':'private-fail'"
      )
      stage = 2
    case 2:
      guard pages[1].title == "shared-ok", pages[2].title == "isolated-ok",
        pages[3].title == "private-ok"
      else { return }
      pages[0].show(frame: CGRect(x: 224, y: 4, width: 500, height: 700))
      guard pages[0].title == "written" else {
        finish(error: "Hidden document lost state")
        return
      }
      finish(error: nil)
    default: break
    }
  }
  private func finish(error: String?) {
    timer?.invalidate()
    timer = nil
    let result: [String: Any] = [
      "passed": error == nil, "error": error ?? "", "documents": pages.count,
      "chromeRuntime": pages.allSatisfy { $0.browser?.isChromeRuntime == true },
      "extensionCompatibilityVerified": false,
      "pages": pages.map {
        [
          "id": $0.id, "nativeID": $0.browser?.id ?? -999, "url": $0.url?.absoluteString ?? "",
          "title": $0.title, "loading": $0.isLoading, "error": $0.error ?? "",
          "cachePath": $0.browser?.profileCachePath ?? "",
          "chrome": $0.browser?.isChromeRuntime == true,
        ] as [String: Any]
      },
    ]
    if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
      let output = ProcessInfo.processInfo.environment["ZACRO_ACCEPTANCE_OUTPUT"]
    {
      try? bytes.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    fputs("Native engine acceptance: \(error ?? "passed")\n", stderr)
    NSApp.terminate(nil)
  }
}
