import AppKit

@MainActor
enum NativeNavigationCloseReview {
  static func present(pageCount: Int, owner: NSWindow) async -> Bool {
    let alert = NSAlert()
    alert.messageText = pageCount == 1 ? "This page’s state couldn’t be saved" : "Some page state couldn’t be saved"
    alert.informativeText = pageCount == 1
      ? "You can keep this page open, or close it with its back and forward addresses saved. Its latest form contents and scroll position won’t be restored."
      : "You can keep these pages open, or close them with their back and forward addresses saved. The latest form contents and scroll positions for \(pageCount) pages won’t be restored."
    alert.addButton(withTitle: "Keep Open")
    alert.addButton(withTitle: "Close Without Page State")
    alert.window.identifier = NSUserInterfaceItemIdentifier("ZacroNavigationSaveFailure")
    return await NativeWindowSheet.present(alert, for: owner) == .alertSecondButtonReturn
  }
}
