import AppKit
import Foundation
import ZacroChromium

/// JavaScript dialogs belong to the exact live document and logical shell.
/// Native resets revoke their callback before dismissing any owned sheet.
@MainActor
final class NativeWebDialogCoordinator {
  @MainActor private final class Request {
    let id = UUID()
    weak var page: ChromiumPage?
    weak var browser: CefBrowser?
    weak var window: NSWindow?
    let pageID: String
    let profileID: String
    let ownerID: String
    let address: URL?
    let beforeUnload: Bool
    let callback: CefJSDialogCallback
    let alert: NSAlert
    let input: NSTextField?
    var task: Task<Void, Never>?

    init(page: ChromiumPage, browser: CefBrowser, ownerID: String, window: NSWindow,
      beforeUnload: Bool, callback: CefJSDialogCallback, alert: NSAlert, input: NSTextField?) {
      self.page = page; self.browser = browser; self.window = window
      pageID = page.id; profileID = page.profileID; self.ownerID = ownerID
      address = page.url; self.beforeUnload = beforeUnload; self.callback = callback
      self.alert = alert; self.input = input
      alert.window.identifier = NSUserInterfaceItemIdentifier(
        "ZacroWebDialog:" + (beforeUnload ? "beforeunload:" : "javascript:") + id.uuidString)
    }
  }

  private weak var application: ApplicationCoordinator?
  private var requests: [UUID: Request] = [:]
  private var order: [UUID] = []
  private var observers: [NSObjectProtocol] = []
  private var stopped = false

  init(application: ApplicationCoordinator) {
    self.application = application
    for name in [NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification,
                 NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
        queue: .main) { [weak self] _ in
        // A sheet's completion may run after didEndSheet. Keep ownership until
        // that completion drains; the next event-loop turn can present a queue.
        Task { @MainActor [weak self] in self?.refresh() }
      })
    }
  }

  func connect(_ page: ChromiumPage) {
    guard !stopped else { return }
    page.onJavaScriptDialog = { [weak self, weak page] dialog, callback in
      guard let self, let page else { callback.cancel(); return }
      self.enqueue(page, dialog: dialog, beforeUnload: nil, callback: callback)
    }
    page.onBeforeUnloadDialog = { [weak self, weak page] message, reload, callback in
      guard let self, let page else { callback.cancel(); return }
      self.enqueue(page, dialog: nil, beforeUnload: (message, reload), callback: callback)
    }
    page.onJavaScriptDialogReset = { [weak self, weak page] in
      guard let self, let page else { return }
      self.reset(page)
    }
  }

  /// Includes requests waiting behind another owned sheet.
  func pendingRequestCount(for page: ChromiumPage) -> Int {
    requests.values.filter { $0.page === page }.count
  }

  func owns(_ sheet: NSWindow, page: ChromiumPage) -> Bool {
    requests.values.contains { $0.page === page && $0.alert.window === sheet }
  }

  func refresh() {
    guard !stopped else { return }
    for request in Array(requests.values) where !isCurrent(request) { revoke(request) }
    var occupied = Set(requests.values.filter { $0.task != nil }.map(\.ownerID))
    for id in order {
      guard let request = requests[id], request.task == nil,
        !occupied.contains(request.ownerID), let window = request.window,
        window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
        NSApp.modalWindow == nil else { continue }
      occupied.insert(request.ownerID)
      request.task = Task { @MainActor [weak self, weak request] in
        guard let self, let request, self.requests[request.id] === request else { return }
        guard self.isCurrent(request), let window = request.window else {
          self.revoke(request); return
        }
        let result = await NativeWindowSheet.present(request.alert, for: window)
        guard self.requests[request.id] === request else { return }
        guard !Task.isCancelled, self.isCurrent(request) else { self.revoke(request); return }
        // Remove authority before native Continue can synchronously reenter
        // OnDialogClosed/OnResetDialogState or create another dialog.
        self.remove(request)
        let accepted = result == .alertFirstButtonReturn
        request.callback.continue(success: accepted,
          userInput: accepted ? request.input?.stringValue : nil)
        self.refresh()
      }
    }
  }

  func forget(_ page: ChromiumPage) {
    reset(page)
    page.onJavaScriptDialog = nil
    page.onBeforeUnloadDialog = nil
    page.onJavaScriptDialogReset = nil
  }

  func close() async {
    stopped = true
    let old = Array(requests.values)
    for request in old { revoke(request) }
    for request in old { await request.task?.value }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
  }

  private func enqueue(_ page: ChromiumPage, dialog: CefJSDialog?,
    beforeUnload: (message: String, reload: Bool)?, callback: CefJSDialogCallback) {
    guard !stopped, let application, let browser = page.browser, !browser.isClosed,
      let ownerID = page.ownerWindowID, let owner = application.windows[ownerID] else {
      callback.cancel(); return
    }
    let alert = NSAlert()
    var input: NSTextField?
    if let beforeUnload {
      alert.messageText = beforeUnload.reload ? "Reload this page?" : "Leave this page?"
      alert.informativeText = beforeUnload.message.isEmpty
        ? "Changes you made may not be saved." : beforeUnload.message
      alert.addButton(withTitle: beforeUnload.reload ? "Reload" : "Leave")
      alert.addButton(withTitle: "Stay")
      alert.buttons[0].keyEquivalent = ""
      alert.buttons[1].keyEquivalent = "\r"
    } else if let dialog {
      alert.messageText = dialog.origin.isEmpty ? "This page says" : dialog.origin
      alert.informativeText = dialog.message
      alert.addButton(withTitle: "OK")
      if dialog.kind != .alert { alert.addButton(withTitle: "Cancel") }
      if dialog.kind == .prompt {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = dialog.defaultPromptText
        alert.accessoryView = field; input = field
      }
    }
    let request = Request(page: page, browser: browser, ownerID: ownerID,
      window: owner.windowContext.window, beforeUnload: beforeUnload != nil,
      callback: callback, alert: alert, input: input)
    guard isCurrent(request) else { callback.cancel(); return }
    // Chromium permits one active dialog per document. Never silently replace
    // an unresolved request and thereby accept a stale navigation decision.
    guard !requests.values.contains(where: { $0.page === page }) else { callback.cancel(); return }
    requests[request.id] = request; order.append(request.id)
    refresh()
  }

  private func isCurrent(_ request: Request) -> Bool {
    guard !stopped, let application, let page = request.page, let browser = request.browser,
      page.browser === browser, !browser.isClosed, page.id == request.pageID,
      page.profileID == request.profileID, page.ownerWindowID == request.ownerID,
      page.url == request.address, application.engine.pages[request.pageID] === page,
      (request.beforeUnload || application.deletingProfileID != request.profileID),
      let owner = application.windows[request.ownerID], owner.windowContext.isOpen,
      owner.windowContext.window === request.window,
      let document = application.store.document(id: request.pageID), !document.isClosed,
      document.windowID == request.ownerID,
      application.store.profileID(for: document) == request.profileID,
      let profile = application.store.state.profiles.first(where: { $0.id == request.profileID }),
      profile.isPrivate == page.isPrivate else { return false }
    // Real close/Quit must still negotiate beforeunload. Merely initiating
    // that close is never a reason to auto-veto its own prompt.
    return request.beforeUnload || (!owner.windowContext.isClosing && !application.engine.isTerminating)
  }

  private func reset(_ page: ChromiumPage) {
    for request in Array(requests.values) where request.page === page { revoke(request) }
  }

  private func remove(_ request: Request) {
    requests.removeValue(forKey: request.id)
    order.removeAll { $0 == request.id }
  }

  private func revoke(_ request: Request) {
    guard requests[request.id] === request else { return }
    remove(request)
    request.task?.cancel()
    request.callback.invalidate()
  }

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
