import AppKit

enum NativeKeyBinding {
  static func candidates(_ event: NSEvent) -> Set<String> {
    NativeShortcutEvent.matchingAccelerator(event).map { [$0] } ?? []
  }
}
