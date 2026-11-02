import AppKit
import ZacroChromium

/// Reads only an owned renderer's already-existing native accessibility tree.
/// Do not start at NSApp/NSWindow or ask RenderWidgetHostViewCocoa for its role:
/// that role getter can itself enable process-wide AX on macOS. Likewise this
/// fixture never calls the DevTools Accessibility domain or an AX mode setter.
/// Removing the production force-renderer-accessibility switch requires a
/// separate launch without it, with the negative control checked first.
@MainActor
enum NativeAccessibilityAcceptance {
  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  struct Snapshot {
    let rendererViews: Int
    let roots: Int
    let nodes: Int
    let strings: Set<String>
  }

  /// Call on a loaded page that has never been shown or AX-enabled, before
  /// querying any other accessibility object. A nonempty tree invalidates the
  /// causal test (a platform assistive client/global mode may already be active).
  static func checkUnshownControl(_ page: ChromiumPage) throws -> Bool {
    let value = try snapshot(page)
    return value.rendererViews > 0 && value.roots == 0 && value.nodes == 0
  }

  /// The caller supplies a small, owned loopback fixture and an actual shell
  /// hide/show or tab-switch cycle. No synthetic pointer/keyboard input is used.
  /// A pass proves native-tree retention, not physical assistive interaction.
  static func checkRetainedTree(_ page: ChromiumPage, expectedText: String,
    inputID: String, expectedValue: String,
    hideAndReshow: @MainActor () async throws -> Void) async throws -> [String: Bool] {
    guard page.url?.host == "127.0.0.1", !expectedText.isEmpty,
      !inputID.isEmpty, !expectedValue.isEmpty,
      expectedText.utf8.count <= 1_024, inputID.utf8.count <= 256,
      expectedValue.utf8.count <= 4_096 else {
      throw Failure("Accessibility acceptance requires a bounded, owned loopback document.")
    }
    let browser = try await page.ready()
    let browserID = browser.id
    let url = page.url
    let quotedID = String(decoding: try JSONSerialization.data(withJSONObject: inputID,
      options: [.fragmentsAllowed]), as: UTF8.self)
    let expression = "document.getElementById(\(quotedID))?.value ?? null"
    guard try await browser.devTools.evaluate(expression) as? String == expectedValue else {
      throw Failure("The owned accessibility fixture does not contain its expected draft.")
    }
    let before = try await waitForTree(page, expectedText: expectedText, expectedValue: expectedValue)
    try await hideAndReshow()
    try Task.checkCancellation()
    guard page.browser === browser, browser.id == browserID, page.url == url else {
      throw Failure("The document was replaced during accessibility retention acceptance.")
    }
    let after = try await waitForTree(page, expectedText: expectedText, expectedValue: expectedValue)
    let retainedValue = try await browser.devTools.evaluate(expression) as? String
    return [
      "renderer_native_ax_tree_exists_before_visibility_cycle": before.roots > 0 && before.nodes > 0,
      "renderer_native_ax_tree_retains_text_after_visibility_cycle": after.strings.contains(expectedText),
      "renderer_native_ax_tree_retains_draft_after_visibility_cycle": after.strings.contains(expectedValue),
      "renderer_native_ax_visibility_cycle_preserves_document": page.browser === browser
        && browser.id == browserID && page.url == url && retainedValue == expectedValue,
    ]
  }

  private static func waitForTree(_ page: ChromiumPage, expectedText: String,
    expectedValue: String) async throws -> Snapshot {
    let deadline = Date().addingTimeInterval(8)
    var last: Snapshot?
    repeat {
      try Task.checkCancellation()
      let value = try snapshot(page)
      if value.strings.contains(expectedText) && value.strings.contains(expectedValue) { return value }
      last = value
      try await Task.sleep(for: .milliseconds(80))
    } while Date() < deadline
    throw Failure("The owned renderer's existing native accessibility tree is incomplete "
      + "(views: \(last?.rendererViews ?? 0), roots: \(last?.roots ?? 0), nodes: \(last?.nodes ?? 0)).")
  }

  /// Chromium's pinned accessibilityChildren path reads the existing manager:
  /// RenderWidgetHostViewCocoa -> GetRootBrowserAccessibilityElement ->
  /// GetRootBrowserAccessibilityManager (never GetOrCreate...). Find the view
  /// through NSView.subviews, without traversing application/window AX objects.
  static func snapshot(_ page: ChromiumPage) throws -> Snapshot {
    guard let nativeView = page.browser?.nativeView,
      let rendererClass = NSClassFromString("RenderWidgetHostViewCocoa"),
      let nodeClass = NSClassFromString("AXPlatformNodeCocoa") else {
      throw Failure("The owned Chromium Cocoa accessibility classes are unavailable.")
    }
    var pendingViews = [nativeView]
    var visitedViews = Set<ObjectIdentifier>()
    var renderers: [NSView] = []
    while let view = pendingViews.popLast() {
      guard visitedViews.insert(ObjectIdentifier(view)).inserted else { continue }
      guard visitedViews.count <= 2_048 else { throw Failure("The owned native view tree exceeds the fixture bound.") }
      if view.isKind(of: rendererClass) { renderers.append(view) }
      pendingViews.append(contentsOf: view.subviews)
    }

    let childrenSelector = NSSelectorFromString("accessibilityChildren")
    func children(_ object: NSObject) -> [NSObject] {
      guard object.responds(to: childrenSelector) else { return [] }
      return object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] ?? []
    }
    let roots = renderers.flatMap(children)
    var pending = roots
    var visited = Set<ObjectIdentifier>()
    var strings = Set<String>()
    var stringBytes = 0
    let textSelectors = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].map(NSSelectorFromString)
    while let node = pending.popLast() {
      guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
      // Never query a foreign embedded NSView/application element. The three
      // getters below are passive only on Chromium's existing platform nodes.
      guard node.isKind(of: nodeClass) else { continue }
      guard visited.count <= 4_096 else { throw Failure("The owned accessibility tree exceeds the fixture bound.") }
      for selector in textSelectors where node.responds(to: selector) {
        if let value = node.perform(selector)?.takeUnretainedValue() as? String {
          stringBytes += value.utf8.count
          guard stringBytes <= 256 * 1_024 else { throw Failure("The owned accessibility text exceeds the fixture bound.") }
          strings.insert(value)
        }
      }
      pending.append(contentsOf: children(node))
    }
    return Snapshot(rendererViews: renderers.count, roots: roots.count, nodes: visited.count, strings: strings)
  }
}
