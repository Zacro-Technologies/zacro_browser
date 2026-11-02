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
    let invalidated = NativeSidebarDragLease(parent: root) { operation in
      completionCount += 1; completedOperation = operation
    }
    invalidated.invalidate()
    result["nativeDragLogicalCloseRetainsInertSourceUntilTerminalCallback"] = invalidated.isInvalidated
      && invalidated.source.permittedOperation.isEmpty && invalidated.source.superview === root
      && invalidated.source.window === window && completionCount == 2
    invalidated.finish(operation: .move)
    invalidated.finish(operation: .move)
    result["nativeDragLogicalCloseCannotCompleteMove"] = completionCount == 3 && completedOperation.isEmpty
      && invalidated.source.superview == nil && invalidated.source.didEnd == nil
    let controller = NativeSidebarDragController()
    let host = NSView(frame: root.bounds)
    let section = NSView(frame: NSRect(x: 40, y: 40, width: 100, height: 80))
    let newTab = NSView(frame: NSRect(x: 40, y: 122, width: 100, height: 30))
    root.addSubview(host); host.addSubview(section); host.addSubview(newTab)
    controller.attach(host)
    controller.registerRegion(section, id: "today")
    controller.registerRegion(newTab, id: "today")
    func contains(_ point: NSPoint) -> Bool? {
      controller.regionContains("today", screenPoint: window.convertPoint(toScreen: host.convert(point, to: nil)))
    }
    let row = NSView(frame: section.bounds); section.addSubview(row)
    let beforeReplacement = contains(NSPoint(x: 80, y: 70))
    row.removeFromSuperview(); section.addSubview(NSView(frame: section.bounds))
    result["nativeDragContainerSurvivesChildRowReplacement"] = beforeReplacement == true
      && contains(NSPoint(x: 80, y: 70)) == true
    result["nativeDragContainerIncludesNewTabAndItsGap"] = contains(NSPoint(x: 80, y: 140)) == true
      && contains(NSPoint(x: 80, y: 121)) == true
      && contains(NSPoint(x: 141, y: 70)) == false
      && contains(NSPoint(x: 80, y: 153)) == false
    controller.setEnabled(false); host.removeFromSuperview()
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let identifier = "tab:東京:é"
    let written = pasteboard.writeObjects([identifier as NSString])
    result["nativeDragWritesExactUTF8TabIdentifier"] = written && pasteboard.string(forType: .string) == identifier
    return result
  }
}
