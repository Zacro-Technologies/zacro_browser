import AppKit

/// Checks the installed navigation row against real AppKit controls. It never
/// invokes a window-button action or sends desktop input.
@MainActor
enum NativeWindowControlsAcceptance {
  static func run(in window: NSWindow) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      window.identifier?.rawValue.hasPrefix("ZacroBrowserWindow:") == true,
      window.isVisible, !window.styleMask.contains(.fullScreen), let root = window.contentView else {
      throw Failure("Window-control acceptance requires its visible owned browser window")
    }
    let originalFrame = window.frame
    defer { if window.frame != originalFrame { window.setFrame(originalFrame, display: true) } }
    func anchor() -> NativeWindowControlsAnchorView? {
      var pending = [root], matches: [NativeWindowControlsAnchorView] = []
      while let next = pending.popLast() {
        if let view = next as? NativeWindowControlsAnchorView, view.window === window,
          !view.isHiddenOrHasHiddenAncestor { matches.append(view) }
        pending += next.subviews
      }
      return matches.count == 1 ? matches[0] : nil
    }
    func buttons() -> [NSButton] {
      NativeWindowControlsAnchorView.buttonTypes.compactMap { window.standardWindowButton($0) }
    }
    var diagnostic = ""
    func aligned() -> Bool {
      guard window.contentView === root, let row = anchor() else { return false }
      let controls = buttons()
      guard controls.count == 3 else { return false }
      let rowFrame = root.convert(row.bounds, from: row)
      let frames = controls.map { root.convert($0.bounds, from: $0) }
      let rowDistanceFromTop = root.isFlipped
        ? rowFrame.midY - root.bounds.minY : root.bounds.maxY - rowFrame.midY
      diagnostic = "root=\(root.bounds) flipped=\(root.isFlipped) row=\(rowFrame) rowDistanceFromTop=\(rowDistanceFromTop) controls=\(frames) parents=\(controls.map { $0.superview?.visibleRect ?? .zero }) visible=\(controls.map(\.visibleRect))"
      // The row itself must remain at the window's top edge. Aligning native
      // buttons to a displaced row alone would miss a nested host applying the
      // full-size window's titlebar safe area for a second time.
      return abs(rowDistanceFromTop - 18) <= 0.51
        && abs(frames[0].minX - root.bounds.minX - 16) <= 0.51
        && frames.allSatisfy { abs($0.midY - rowFrame.midY) <= 0.51 }
        && controls.allSatisfy { $0.window === window && $0.superview !== row && $0.action != nil
          && $0.visibleRect.insetBy(dx: -0.01, dy: -0.01).contains($0.bounds) }
        && frames[0].maxX < frames[1].minX && frames[1].maxX < frames[2].minX
        && frames[2].maxX <= rowFrame.maxX
    }
    func wait(_ phase: String, condition: () -> Bool) async throws {
      let end = ProcessInfo.processInfo.systemUptime + 3
      while ProcessInfo.processInfo.systemUptime < end {
        try Task.checkCancellation()
        guard window.contentView === root else { throw Failure("The owned window root changed") }
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw Failure(phase + ": " + diagnostic)
    }
    try await wait("Native controls did not align with the actual navigation row", condition: aligned)
    let controls = buttons()
    let parents = controls.map(\.superview), sizes = controls.map { $0.frame.size }
    let actions = controls.map(\.action), targets = controls.map { $0.target as AnyObject? }
    let positions = controls.map { root.convert($0.bounds, from: $0).minX }
    let accessibility = controls.map { ($0.accessibilityRole(), $0.accessibilitySubrole()) }
    var resized = originalFrame
    resized.size.width = max(window.minSize.width, originalFrame.width - 87)
    resized.size.height = max(window.minSize.height, originalFrame.height - 53)
    window.setFrame(resized, display: true)
    try await wait("Native controls lost alignment during actual window resize", condition: aligned)
    window.setFrame(originalFrame, display: true)
    try await wait("Native controls lost alignment after window size restoration", condition: aligned)
    let current = buttons()
    guard current.count == controls.count, current.indices.allSatisfy({ index in
      let button = current[index]
      return button === controls[index] && button.superview === parents[index]
        && button.frame.size == sizes[index] && button.action == actions[index]
        && (button.target as AnyObject?) === targets[index]
        && abs(root.convert(button.bounds, from: button).minX - positions[index]) <= 0.51
        && button.accessibilityRole() == accessibility[index].0
        && button.accessibilitySubrole() == accessibility[index].1
    }) else { throw Failure("Native control identity, actions or accessibility changed across resize") }
    guard window.delegate?.responds(to: #selector(NSWindowDelegate.windowDidFailToEnterFullScreen(_:))) == true else {
      throw Failure("The owned native window delegate cannot report full-screen failure")
    }
    guard let installedAnchor = anchor(), installedAnchor.window === window else {
      throw Failure("The owned native control anchor disappeared before its failure-route check")
    }
    // Suspend only our component, then exercise the actual delegate's failure
    // route. Posting an AppKit lifecycle notification would also start AppKit's
    // global event-blocking transition without a corresponding OS transition.
    installedAnchor.suspendForFullScreenEntry()
    guard installedAnchor.isAlignmentSuspendedForFullScreenTransition else {
      throw Failure("The owned native control anchor did not suspend its alignment")
    }
    window.delegate?.windowDidFailToEnterFullScreen?(window)
    try await wait("Native controls did not recover after the delegate reported full-screen failure") {
      anchor() === installedAnchor && !installedAnchor.isAlignmentSuspendedForFullScreenTransition && aligned()
    }
    return ["nativeWindowControlsAlignWithNavigationWithoutClipping",
      "nativeWindowResizePreservesControlIdentityActionsSpacingAndAccessibility",
      "nativeWindowControlsResumeAfterDelegateReportsFullScreenFailure"]
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Native window-control acceptance failed: " + message }
  }
}
