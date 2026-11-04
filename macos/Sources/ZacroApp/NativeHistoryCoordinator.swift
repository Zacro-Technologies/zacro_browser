import Foundation
import ZacroChromium
import ZacroCore

/// Library visits follow actual Chromium commits, not requested model URLs.
/// The association follows a retained page through window transfer and Peek
/// promotion, without recreating a visit when its callbacks are rewired.
@MainActor final class NativeHistoryCoordinator {
  @MainActor private final class Entry {
    weak var page: ChromiumPage?
    var visitID: String?
    var address: String?
    let profileID: String
    init(page: ChromiumPage) { self.page = page; profileID = page.profileID }
  }
  private weak var application: ApplicationCoordinator?
  private var entries: [ObjectIdentifier: Entry] = [:]
  private var stopped = false
  var nativeMirrorEnabled = false

  init(application: ApplicationCoordinator) { self.application = application }

  func connect(_ page: ChromiumPage) {
    guard !stopped, let application, application.engine.pages[page.id] === page,
      application.store.document(id: page.id) != nil else { return }
    let key = ObjectIdentifier(page)
    if entries[key]?.page === page { return }
    let entry = Entry(page: page)
    entries[key] = entry
    page.onCommittedNavigation = { [weak self, weak page, weak entry] url in
      guard let self, let page, let entry, self.entries[key] === entry,
        self.owns(page, entry: entry) else { return }
      // Any actual new document invalidates the previous title association,
      // including a privileged/internal document that is not Library history.
      entry.visitID = nil; entry.address = nil
      if self.nativeMirrorEnabled {
        self.application?.historyMirror.nativeHistoryChanged(profileID: entry.profileID)
        return
      }
      guard !page.id.hasPrefix("peek:"), let application = self.application,
        let address = BrowserAddress.webURL(url.absoluteString)?.absoluteString else { return }
      entry.address = address
      entry.visitID = application.store.recordHistoryVisit(profileID: entry.profileID,
        address: address, title: url.host ?? address)
    }
    page.onTitleChanged = { [weak self, weak page, weak entry] title in
      guard let self, let page, let entry, self.entries[key] === entry, self.owns(page, entry: entry) else { return }
      if self.nativeMirrorEnabled {
        self.application?.historyMirror.nativeHistoryChanged(profileID: entry.profileID)
        return
      }
      guard
        self.owns(page, entry: entry), !page.id.hasPrefix("peek:"),
        let visitID = entry.visitID, let address = entry.address,
        page.url.flatMap({ BrowserAddress.webURL($0.absoluteString)?.absoluteString }) == address else { return }
      self.application?.store.updateHistoryVisitTitle(id: visitID, profileID: entry.profileID,
        address: address, title: title)
    }
  }

  /// Core promotion already committed this visit atomically with the new tab.
  /// Bind its existing ID so a later title event cannot create a second visit.
  func didPromote(_ page: ChromiumPage) {
    connect(page)
    if nativeMirrorEnabled { application?.historyMirror.nativeHistoryChanged(profileID: page.profileID); return }
    guard let entry = entries[ObjectIdentifier(page)], owns(page, entry: entry),
      !page.id.hasPrefix("peek:"), let application,
      let document = application.store.document(id: page.id),
      let address = BrowserAddress.webURL(document.url)?.absoluteString,
      let visit = application.store.state.history.first(where: { $0.profileID == page.profileID && $0.url == address }) else { return }
    entry.address = address; entry.visitID = visit.id
  }

  func forget(_ page: ChromiumPage) {
    let key = ObjectIdentifier(page)
    guard entries[key]?.page === page else { return }
    entries.removeValue(forKey: key)
    page.onCommittedNavigation = nil; page.onTitleChanged = nil
  }

  func close() {
    stopped = true
    for entry in entries.values {
      entry.page?.onCommittedNavigation = nil
      entry.page?.onTitleChanged = nil
    }
    entries.removeAll()
  }

  private func owns(_ page: ChromiumPage, entry: Entry) -> Bool {
    guard !stopped, entry.page === page, page.profileID == entry.profileID, !page.isPrivate,
      let application, !application.engine.isTerminating,
      application.deletingProfileID != page.profileID, application.engine.pages[page.id] === page,
      let ownerID = page.ownerWindowID, let owner = application.windows[ownerID],
      owner.windowContext.isOpen, !owner.windowContext.isClosing,
      let document = application.store.document(id: page.id), !document.isClosed,
      document.windowID == ownerID, application.store.profileID(for: document) == page.profileID,
      application.store.state.profiles.contains(where: { $0.id == page.profileID && !$0.isPrivate }) else { return false }
    return true
  }
}
