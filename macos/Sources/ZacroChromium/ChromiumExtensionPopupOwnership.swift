import AppKit
import Foundation

/// Receives exact browser-process popup/window identities. It deliberately
/// does not infer ownership from an extension URL, an arbitrary child window,
/// or Chrome authentication/security dialogs.
@MainActor
final class ChromiumExtensionPopupOwnership {
  private let owners = NSMapTable<NSWindow, NSWindow>.weakToWeakObjects()
  private var observers: [NSObjectProtocol] = []

  init() {
    observers.append(NotificationCenter.default.addObserver(
      forName: NSNotification.Name("ZacroNativeExtensionPopupOpened"), object: nil, queue: nil
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self, let popup = notification.object as? NSWindow,
          let owner = notification.userInfo?["ownerWindow"] as? NSWindow,
          popup !== owner else { return }
        self.owners.setObject(owner, forKey: popup)
      }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: NSNotification.Name("ZacroNativeExtensionPopupClosed"), object: nil, queue: nil
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let popup = notification.object as? NSWindow else { return }
        self?.owners.removeObject(forKey: popup)
      }
    })
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  func owner(of popup: NSWindow) -> NSWindow? {
    guard popup.isVisible, let owner = owners.object(forKey: popup),
      owner.isVisible, !owner.isMiniaturized else { return nil }
    return owner
  }
}
