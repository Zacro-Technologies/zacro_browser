import AppKit
import QuartzCore
import SwiftUI
import ZacroChromium
import ZacroCore

/// Changes only an owned disposable window. Neither native layout nor the
/// renderer viewport is forced by the fixture after resizing the shell.
@MainActor enum NativeWindowResizeAcceptance {
  @MainActor private final class TrackingProbe {
    var requested = false
    var observed = false
    var matched = false
  }
  /// Exercise AppKit's tracking run-loop mode without sending desktop input.
  /// The observation happens before returning to the ordinary event loop.
  private static func trackingResize(_ resize: @escaping @MainActor () -> Void,
    matches: @escaping @MainActor () -> Bool) -> Bool {
    let probe = TrackingProbe()
    let resizeTimer = Timer(timeInterval: 0.01, repeats: false) { _ in
      MainActor.assumeIsolated { resize(); probe.requested = true }
    }
    let sampleTimer = Timer(timeInterval: 0.4, repeats: false) { _ in
      MainActor.assumeIsolated { probe.matched = probe.requested && matches(); probe.observed = true }
    }
    RunLoop.main.add(resizeTimer, forMode: .eventTracking)
    RunLoop.main.add(sampleTimer, forMode: .eventTracking)
    defer { resizeTimer.invalidate(); sampleTimer.invalidate() }
    let deadline = Date().addingTimeInterval(1)
    while !probe.observed && Date() < deadline {
      _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
    }
    return probe.observed && probe.matched
  }
  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Resize acceptance requires the disposable loopback fixture.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let previous = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !previous.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else { throw ShortcutError("No exact resize fixture owner") }
    let window = owner.windowContext.window
    let originalRadius = application.store.state.settings.pageRadius
    defer { application.store.updateSettings { $0.pageRadius = originalRadius } }
    var checks: [String] = []
    var lastState = ""
    var lastContourState = ""
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native resize check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Window resize acceptance failed: " + name) }
      checks.append(name)
    }
    func wait(_ name: String, _ predicate: () async throws -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try Task.checkCancellation()
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      fputs("Native resize timeout \(name): \(lastState) \(lastContourState)\n", stderr)
      throw ShortcutError("Window resize did not settle: " + name)
    }
    func closeEnough(_ a: CGRect, _ b: CGRect) -> Bool {
      abs(a.minX - b.minX) < 1.1 && abs(a.minY - b.minY) < 1.1
        && abs(a.width - b.width) < 1.1 && abs(a.height - b.height) < 1.1
    }
    func expectedPane() -> CGRect {
      let bounds = window.contentView?.bounds ?? .zero
      let gutter = owner.store.state.settings.pageGutter
      let sidebar = owner.store.state.settings.sidebarVisible ? owner.store.state.settings.sidebarWidth : 0
      let top = owner.actions.findVisible ? 40.0 : gutter
      return CGRect(x: sidebar + gutter, y: top,
        width: max(1, bounds.width - sidebar - 2 * gutter),
        height: max(1, bounds.height - top - gutter))
    }
    func matchesNativeContour(_ page: ChromiumPage) -> Bool {
      guard let native = page.nativeWindow, let content = native.contentView, let layer = content.layer,
        let mask = layer.mask as? CAShapeLayer, let path = mask.path else {
        lastContourState = "nativePaneMask=missing"; return false
      }
      let bounds = CGRect(origin: .zero, size: layer.bounds.size)
      let expected = RoundedRectangle(cornerRadius: owner.store.state.settings.pageRadius, style: .continuous)
        .path(in: bounds).cgPath
      let transparent = !native.isOpaque && native.backgroundColor.alphaComponent == 0 && !native.hasShadow
        && native.styleMask == .borderless && native.canBecomeKey
        && page.browser?.nativeView?.window === native
      let exact = layer.bounds.size == content.bounds.size && mask.frame == layer.bounds
        && mask.bounds == bounds && CFEqual(path, expected)
      let singleClip = layer.cornerRadius == 0 && !layer.masksToBounds && mask.mask == nil
        && mask.fillColor?.alpha == 1 && mask.strokeColor == nil
      lastContourState = "nativePaneTransparent=\(transparent) maskFrame=\(mask.frame) layerBounds=\(layer.bounds) exactContinuousPath=\(exact) singleClip=\(singleClip)"
      return transparent && exact && singleClip
    }
    func matches(_ page: ChromiumPage, _ frame: CGRect) async throws -> Bool {
      guard let root = window.contentView, let native = page.nativeWindow,
        let browser = page.browser, !browser.isClosed else { return false }
      let local = CGRect(x: frame.minX,
        y: root.isFlipped ? frame.minY : root.bounds.maxY - frame.maxY,
        width: frame.width, height: frame.height)
      let screen = window.convertToScreen(root.convert(local, to: nil))
      let viewport = try await browser.devTools.evaluate("[innerWidth,innerHeight]") as? [Double] ?? []
      lastState = "shell=\(window.frame) root=\(root.bounds) published=\(owner.actions.contentFrame) expected=\(frame) native=\(native.frame) target=\(screen) visible=\(native.isVisible) viewport=\(viewport)"
      return native.isVisible && closeEnough(native.frame, screen) && viewport.count == 2
        && abs(viewport[0] - frame.width) < 1.1 && abs(viewport[1] - frame.height) < 1.1
        && matchesNativeContour(page)
    }
    func resize(_ size: CGSize) {
      // AppKit itself delivers the same resize delegate/layout notifications
      // used by the window border. No call to owner.layoutPages follows this.
      window.setFrame(CGRect(origin: window.frame.origin, size: size), display: true)
    }
    do {
      guard let first = owner.store.createTab(address: url.appendingPathComponent("native-history-form").absoluteString) else {
        throw ShortcutError("No resize fixture tab")
      }
      let page = try await owner.ensurePageReady(first)
      try await application.navigation.waitForRestore(page)
      let browser = try await page.ready()
      try await wait("first document") {
        guard !page.isLoading else { return false }
        return try await browser.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      owner.actions.palette = false
      _ = try await browser.devTools.evaluate("document.getElementById('retained').value='resize retained draft'; true")
      for (index, size) in [CGSize(width: 960, height: 680), CGSize(width: 1320, height: 860),
        CGSize(width: 800, height: 540), CGSize(width: 1440, height: 940)].enumerated() {
        resize(size)
        try await wait("single pane resize \(index)") {
          let target = expectedPane()
          guard closeEnough(owner.actions.contentFrame, target) else { return false }
          return try await matches(page, target)
        }
        try require(true, "singlePageTracksActualWindowResize\(index)")
        try require(matchesNativeContour(page), "singlePageHasExactTransparentContinuousContourAfterResize\(index)")
      }
      let trackingMatches = trackingResize({ resize(CGSize(width: 1160, height: 780)) }) {
        guard let root = window.contentView, let native = page.nativeWindow else { return false }
        let target = expectedPane()
        let local = CGRect(x: target.minX,
          y: root.isFlipped ? target.minY : root.bounds.maxY - target.maxY,
          width: target.width, height: target.height)
        let screen = window.convertToScreen(root.convert(local, to: nil))
        lastState = "tracking shell=\(window.frame) pane=\(owner.actions.contentFrame) expected=\(target) native=\(native.frame) target=\(screen)"
        return closeEnough(owner.actions.contentFrame, target) && closeEnough(native.frame, screen)
          && matchesNativeContour(page)
      }
      if !trackingMatches { fputs("Native tracking resize: \(lastState) \(lastContourState)\n", stderr) }
      try require(trackingMatches, "contentPaneUpdatesDuringWindowTrackingRunLoop")
      let singleDraft = try await browser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(page.browser === browser && !browser.isClosed && singleDraft == "resize retained draft",
        "windowResizePreservesNativeDocumentAndDraft")
      owner.store.updateSettings { $0.pageRadius = 0 }
      try await wait("zero radius actual native contour") { matchesNativeContour(page) }
      let zeroPath = (page.nativeWindow?.contentView?.layer?.mask as? CAShapeLayer)?.path
      try require(zeroPath?.contains(CGPoint(x: 0.25, y: 0.25)) == true,
        "zeroRadiusUsesExactSquareNativeClipWithoutSecondRoundedLayer")
      owner.store.updateSettings { $0.pageRadius = originalRadius }
      try await wait("restored exact native contour") { matchesNativeContour(page) }
      try require(owner.store.state.settings.pageRadius == originalRadius && matchesNativeContour(page),
        "nativePaneRadiusRestoresExactOriginalSettingAndContour")
      guard let second = owner.store.createTab(address: url.appendingPathComponent("native-history-form").absoluteString) else {
        throw ShortcutError("No second resize fixture tab")
      }
      let other = try await owner.ensurePageReady(second)
      try await application.navigation.waitForRestore(other)
      let otherBrowser = try await other.ready()
      try await wait("second document") {
        guard !other.isLoading else { return false }
        return try await otherBrowser.devTools.evaluate("!!document.getElementById('retained')") as? Bool == true
      }
      _ = try await otherBrowser.devTools.evaluate("document.getElementById('retained').value='other retained draft'; true")
      owner.store.setSplit(left: first.id, right: second.id)
      guard let group = owner.store.split(for: first.id) else { throw ShortcutError("No resize fixture split") }
      owner.store.setSplitRatio(id: group.id, ratio: 0.61)
      for (index, size) in [CGSize(width: 1000, height: 700), CGSize(width: 1380, height: 900)].enumerated() {
        resize(size)
        try await wait("split resize \(index)") {
          let frame = expectedPane(), width = (frame.width - 6) * 0.61
          let left = CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
          let right = CGRect(x: left.maxX + 6, y: frame.minY, width: frame.width - width - 6, height: frame.height)
          guard closeEnough(owner.actions.contentFrame, frame), try await matches(page, left) else { return false }
          return try await matches(other, right)
        }
        try require(true, "splitPagesTrackActualWindowResize\(index)")
        try require(matchesNativeContour(page) && matchesNativeContour(other),
          "splitPagesHaveIndependentExactTransparentContinuousContoursAfterResize\(index)")
      }
      let firstDraft = try await browser.devTools.evaluate("document.getElementById('retained').value") as? String
      let secondDraft = try await otherBrowser.devTools.evaluate("document.getElementById('retained').value") as? String
      try require(page.browser === browser && other.browser === otherBrowser
        && owner.store.split(for: first.id)?.ratio == 0.61
        && firstDraft == "resize retained draft" && secondDraft == "other retained draft",
        "splitResizeKeepsBothDocumentsDraftsAndDividerRatio")
      owner.store.unsplit(tabID: first.id)
      owner.store.selectTab(id: first.id)
      owner.store.updateSettings { $0.sidebarVisible = false }
      owner.actions.findVisible = true
      resize(CGSize(width: 1040, height: 720))
      try await wait("hidden sidebar and find bar") {
        guard closeEnough(owner.actions.contentFrame, expectedPane()) else { return false }
        return try await matches(page, expectedPane())
      }
      try require(true, "windowResizeRespectsHiddenSidebarAndFindBar")
      owner.actions.findVisible = false
      guard owner.store.createTab(address: "about:blank") != nil else { throw ShortcutError("No resize blank page") }
      resize(CGSize(width: 900, height: 620))
      try await wait("empty pane") {
        closeEnough(owner.actions.contentFrame, expectedPane()) && page.nativeWindow?.isVisible == false
          && other.nativeWindow?.isVisible == false
      }
      try require(true, "emptyPaneTracksWindowResizeWithoutStaleNativeContent")
      try require(await owner.requestCloseWindow(), "windowResizeFixtureClosesCleanly")
      originalOwner.windowContext.show()
      return checks
    } catch {
      _ = await owner.requestCloseWindow()
      originalOwner.windowContext.show()
      throw error
    }
  }
}
