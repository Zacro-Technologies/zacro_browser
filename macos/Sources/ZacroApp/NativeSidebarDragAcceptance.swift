import AppKit

/// Native source-lifetime checks, separate from physical pointer/drop acceptance.
@MainActor
enum NativeSidebarDragAcceptance {
  static func check(in window: NSWindow) -> [String: Bool] {
    guard let root = window.contentView else { return ["nativeDragHasOwningWindow": false] }
    var result: [String: Bool] = [:]
    let presentation = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    let favorite = NSView(frame: presentation.bounds)
    presentation.addSubview(favorite); root.addSubview(presentation)
    defer { presentation.removeFromSuperview() }
    var completionCount = 0
    var completedOperation: NSDragOperation = .copy
    let lease = NativeSidebarDragLease(parent: root) { operation in
      completionCount += 1; completedOperation = operation
    }
    let source = lease.source
    result["nativeDragSourceAttachedToOwningWindow"] = source.window === window && source.superview === root
    favorite.removeFromSuperview()
    let pinned = NSView(frame: presentation.bounds)
    presentation.addSubview(pinned)
    result["nativeDragSourceSurvivesCategoryReparenting"] = source.window === window && source.superview === root
    presentation.removeFromSuperview()
    result["nativeDragSourceSurvivesSpacePresentationRemoval"] = source.window === window && source.superview === root
    result["nativeDragSourceDoesNotInterceptControls"] = source.hitTest(NSPoint(x: 5, y: 5)) == nil
    lease.finish(operation: [])
    lease.finish(operation: .move)
    result["nativeDragCancelReleasesSourceExactlyOnce"] = completionCount == 1 && completedOperation.isEmpty
      && source.superview == nil && source.didEnd == nil
    let moved = NativeSidebarDragLease(parent: root) { operation in
      completionCount += 1; completedOperation = operation
    }
    moved.finish(operation: .move)
    result["nativeDragDropReleasesSourceExactlyOnce"] = completionCount == 2 && completedOperation == .move
      && moved.source.superview == nil
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let identifier = "tab:東京:é"
    let written = pasteboard.writeObjects([identifier as NSString])
    result["nativeDragWritesExactUTF8TabIdentifier"] = written && pasteboard.string(forType: .string) == identifier
    return result
  }
}
