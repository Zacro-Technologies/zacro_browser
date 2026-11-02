import AppKit

/// The search field keeps keyboard focus while the native result selection
/// changes. Announce that result without rewriting the user's query or moving
/// focus away from the field, matching the renderer's live status/active option.
@MainActor
final class NativeCommandSearchControl: NSTextField {
  private var searchStatus = ""
  private var announcement: DispatchWorkItem?
  private var announcementGeneration: UInt64 = 0

  func updateSearchAccessibility(label: String, status: String) {
    let changed = accessibilityLabel() != label || searchStatus != status
    setAccessibilityLabel(label)
    setAccessibilityHelp(status)
    searchStatus = status
    if changed { announceSearchStatus() }
  }

  func announceSearchStatus() {
    cancelSearchAnnouncement()
    let generation = announcementGeneration
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.announcementGeneration == generation,
          let window = self.window, window.isVisible, window.isKeyWindow, NSApp.isActive,
          !self.isHiddenOrHasHiddenAncestor,
          let editor = self.currentEditor() as? NSTextView, !editor.hasMarkedText(),
          window.firstResponder === editor, !self.searchStatus.isEmpty else { return }
        NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
          userInfo: [.announcement: self.searchStatus, .priority: NSAccessibilityPriorityLevel.low.rawValue])
      }
    }
    announcement = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  func cancelSearchAnnouncement() {
    announcementGeneration &+= 1
    announcement?.cancel(); announcement = nil
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { cancelSearchAnnouncement() }
    super.viewWillMove(toWindow: newWindow)
  }
}
