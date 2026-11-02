import Foundation
import ZacroChromium
import ZacroCore
import ZacroServices

/// Keeps Chrome's native session history separate from the lightweight tab list.
/// Only Chromium-encrypted envelopes cross the persistence boundary.
@MainActor
final class NativeNavigationCoordinator {
  private let engine: ChromiumEngine
  private let store: BrowserStore
  private let vault: NativeNavigationStateStore
  private var restores: [String: Task<Void, Never>] = [:]
  private var restoreTokens: [String: UUID] = [:]
  private var restoreFailures: [String: String] = [:]
  private var captures: [String: Task<Void, Never>] = [:]
  private var inFlightCaptures: [String: (id: UUID, task: Task<CaptureOutcome, Never>)] = [:]
  private var captureIssues: [String: CaptureIssue] = [:]
  private var captureEpochs: [String: UInt64] = [:]
  private var fallbackDocuments = Set<String>()

  struct CaptureIssue {
    let id: UUID
    let pageID: String
    let profileID: String
    let ownerWindowID: String?
    let address: String
    let reason: String
    fileprivate weak var page: ChromiumPage?
    fileprivate let browserID: Int32
    fileprivate let tabID: String
    fileprivate let peek: Bool
    fileprivate let history: CapturedHistory?
  }
  fileprivate struct CapturedHistory: Equatable {
    let entries: [NavigationEntry]
    let index: Int
  }
  private enum CaptureOutcome {
    case saved, skipped, cancelled, failed(CaptureIssue)
    var wasSaved: Bool { if case .saved = self { return true }; return false }
  }
  private var historyCapability: [String: Bool] = [:]
  private var urlOnlyRestorations = Set<String>()
  private var resettingProfiles = Set<String>()
  var didRestore: ((String, Bool) -> Void)?
  var beforeRestore: ((ChromiumPage) async throws -> Void)?
  /// Renderer-side adapters must wait for the real restored/initial document.
  /// A temporary blank navigation would invalidate Chromium's fresh-history
  /// restore precondition and could become a user-visible Back entry.
  var afterRestore: ((ChromiumPage) async throws -> Void)?
  var didFailPreparation: ((String, String) -> Void)?

  init(engine: ChromiumEngine, store: BrowserStore) {
    self.engine = engine; self.store = store
    vault = NativeNavigationStateStore(directory: engine.dataDirectory) { [store] id in
      await MainActor.run {
        store.state.profiles.first { $0.id == id }.map { AIProfileScope(id: $0.id, isPrivate: $0.isPrivate) }
      }
    }
  }

  func isRestoring(_ page: ChromiumPage) -> Bool { restores[page.id] != nil }
  func waitForRestore(_ page: ChromiumPage) async throws {
    while let task = restores[page.id] {
      await task.value
      try Task.checkCancellation()
      guard engine.pages[page.id] === page else { throw CancellationError() }
    }
    guard engine.pages[page.id] === page else { throw CancellationError() }
    if let failure = restoreFailures[page.id] { throw ShortcutError(failure) }
  }

  func validateDestination(of tab: BrowserTab) async throws -> ChromeNavigationApproval? {
    guard let profileID = store.profileID(for: tab),
      let profile = store.state.profiles.first(where: { $0.id == profileID }) else { throw CancellationError() }
    return try await approval(address: tab.url, provenance: tab.nativeNavigation,
      profileID: profileID, isPrivate: profile.isPrivate)
  }

  func loadDestination(_ page: ChromiumPage, tab: BrowserTab) async throws {
    let peek = tab.id.hasPrefix("peek:"), sourceID = tab.id.hasPrefix("peek:") ? String(tab.id.dropFirst(5)) : tab.id
    guard owns(page, tabID: sourceID, peek: peek, address: tab.url) else { throw CancellationError() }
    let approval = try await validateDestination(of: tab)
    try Task.checkCancellation()
    guard owns(page, tabID: sourceID, peek: peek, address: tab.url) else { throw CancellationError() }
    if let approval { try await page.loadApprovedNavigation(approval) }
    else if let url = BrowserAddress.documentURL(tab.url) { page.load(url) }
  }

  private func approval(address: String, provenance: NativeNavigationProvenance?,
                        profileID: String, isPrivate: Bool) async throws -> ChromeNavigationApproval? {
    guard let url = BrowserAddress.documentURL(address, provenance: provenance) else {
      throw ShortcutError("This saved page does not have a valid navigation authorization.")
    }
    guard let provenance else { return nil }
    guard (!isPrivate || provenance.extensionID == ChromeExtensionManager.bundledPDFExtensionID),
      provenance.matches(address) else {
      throw ShortcutError("The extension authorization no longer matches this page.")
    }
    let approval = try await ChromeExtensionManager(engine: engine, profileID: profileID, isPrivate: isPrivate).validateNavigation(
      extensionID: provenance.extensionID, incarnationID: provenance.incarnationID, url: url)
    guard approval.url == url, approval.profileID == profileID else { throw ChromeExtensionError.invalidResponse }
    return approval
  }

  private func authorizeHistory(_ page: ChromiumPage, tab: BrowserTab) async throws {
    let peek = tab.id.hasPrefix("peek:"), sourceID = tab.id.hasPrefix("peek:") ? String(tab.id.dropFirst(5)) : tab.id
    var validated: [String: NativeNavigationProvenance] = [:]
    for entry in tab.navigation {
      guard let provenance = entry.nativeNavigation, validated[entry.url] != provenance else { continue }
      let approval = try await approval(address: entry.url, provenance: provenance,
        profileID: page.profileID, isPrivate: page.isPrivate)
      try Task.checkCancellation()
      guard owns(page, tabID: sourceID, peek: peek, address: tab.url) else { throw CancellationError() }
      if let approval { try page.authorizeNavigation(approval) }
      validated[entry.url] = provenance
    }
  }

  func restore(_ page: ChromiumPage, tabID: String, peek: Bool, address: String, dormant: Bool = false) {
    let id = page.id
    restores[id]?.cancel()
    restoreFailures.removeValue(forKey: id)
    let token = UUID(); restoreTokens[id] = token
    restores[id] = Task { [weak self, weak page] in
      guard let self, let page else { return }
      defer {
        if self.restoreTokens[id] == token {
          self.restores.removeValue(forKey: id)
          self.restoreTokens.removeValue(forKey: id)
        }
      }
      var restored = false
      var historyNavigationStarted = false
      var destinationApproval: ChromeNavigationApproval?
      do {
        let browser = try await page.ready()
        try Task.checkCancellation()
        do { try await self.beforeRestore?(page) }
        catch {
          fputs("Zacro could not prepare native tab ownership: \(error.localizedDescription)\n", stderr)
          if !(error is CancellationError) { self.failPreparation(id: id, token: token, error: error) }
          return
        }
        guard self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
        do {
          destinationApproval = try await self.approval(address: address,
            provenance: self.store.document(id: page.id)?.nativeNavigation,
            profileID: page.profileID, isPrivate: page.isPrivate)
          try Task.checkCancellation()
          guard self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
          if let destinationApproval { try page.authorizeNavigation(destinationApproval) }
        } catch {
          if !(error is CancellationError) { self.failPreparation(id: id, token: token, error: error) }
          return
        }
        if let tab = self.store.document(id: page.id) { try await self.authorizeHistory(page, tab: tab) }
        if dormant {
          historyNavigationStarted = true
          try await browser.restoreDiscardedDocument()
          restored = true
        } else if !page.isPrivate, await self.supportsHistory(page) {
          let state = try await self.vault.read(profileID: page.profileID, tabID: tabID, peek: peek, address: address)
          try Task.checkCancellation()
          guard self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
          if let state {
            historyNavigationStarted = true
            try await browser.restoreNavigationState(state)
            restored = true
          } else if let tab = self.store.document(id: page.id), tab.navigation.count > 1,
            tab.navigation.indices.contains(tab.navigationIndex) {
            let entries = tab.navigation.compactMap { entry -> CefNavigationEntry? in
              guard let url = BrowserAddress.documentURL(entry.url, provenance: entry.nativeNavigation) else { return nil }
              return CefNavigationEntry(url: url, title: entry.title)
            }
            if entries.count == tab.navigation.count {
              historyNavigationStarted = true
              try await browser.restoreNavigationEntries(entries, selectedIndex: tab.navigationIndex)
              restored = true
            }
          }
        }
      } catch is CancellationError { return }
      catch {
        fputs("Zacro could not restore native navigation: \(error.localizedDescription)\n", stderr)
        // Once Chromium has started a navigation, a replacement/cancellation
        // must not silently load the saved URL over the user's newer choice.
        if historyNavigationStarted || page.browser == nil {
          self.failPreparation(id: id, token: token, error: error)
          return
        }
      }
      guard !Task.isCancelled, self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
      if !restored && (self.store.document(id: page.id)?.navigation.count ?? 0) > 1 {
        self.urlOnlyRestorations.insert(id)
      } else { self.urlOnlyRestorations.remove(id) }
      if !restored {
        do {
          if let destinationApproval { try await page.loadApprovedNavigation(destinationApproval) }
          else if let url = BrowserAddress.documentURL(address) {
            if await self.supportsHistory(page), let browser = page.browser {
              try await browser.loadAndWaitForNavigationCommit(url)
            } else { page.load(url) }
          }
        } catch {
          if !(error is CancellationError) { self.failPreparation(id: id, token: token, error: error) }
          return
        }
      }
      guard !Task.isCancelled, self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
      do { try await self.afterRestore?(page) }
      catch {
        if !(error is CancellationError) { self.failPreparation(id: id, token: token, error: error) }
        return
      }
      guard !Task.isCancelled, self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
      self.restores.removeValue(forKey: id)
      self.didRestore?(id, restored)
      self.observe(page, tabID: tabID, peek: peek)
    }
  }

  private func failPreparation(id: String, token: UUID, error: Error) {
    guard restoreTokens[id] == token else { return }
    restoreFailures[id] = error.localizedDescription
    didFailPreparation?(id, error.localizedDescription)
  }

  func cancelRestore(_ page: ChromiumPage) {
    restoreFailures.removeValue(forKey: page.id)
    restoreTokens.removeValue(forKey: page.id)
    restores.removeValue(forKey: page.id)?.cancel()
  }

  func observe(_ page: ChromiumPage, tabID: String, peek: Bool) {
    guard !resettingProfiles.contains(page.profileID), !fallbackDocuments.contains(page.id),
      !isRestoring(page), !page.isLoading, let address = page.url?.absoluteString,
      owns(page, tabID: tabID, peek: peek, address: address) else { return }
    let id = page.id
    captures[id]?.cancel()
    captures[id] = Task { [weak self, weak page] in
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      guard let self, let page, !Task.isCancelled else { return }
      await self.capture(page, tabID: tabID, peek: peek)
      if !Task.isCancelled { self.captures.removeValue(forKey: id) }
    }
  }

  func captureAll(windowID: String? = nil) async {
    for id in Array(captures.keys) where windowID == nil || engine.pages[id]?.ownerWindowID == windowID {
      captures.removeValue(forKey: id)?.cancel()
    }
    // Bound concurrent native protocol traffic while preserving every live tab.
    let pages = engine.pages.values.filter { windowID == nil || $0.ownerWindowID == windowID }
    for page in pages {
      let peek = page.id.hasPrefix("peek:")
      let tabID = peek ? String(page.id.dropFirst(5)) : page.id
      await capture(page, tabID: tabID, peek: peek)
    }
  }

  @discardableResult func capture(_ page: ChromiumPage, tabID: String, peek: Bool) async -> Bool {
    await captureOutcome(page, tabID: tabID, peek: peek, fresh: false).wasSaved
  }

  /// Sleeping may destroy renderer state, so a previous background capture is
  /// only a prerequisite, never proof that the current document was saved.
  func captureBeforeDiscard(_ page: ChromiumPage, tabID: String, peek: Bool) async -> Bool {
    captures.removeValue(forKey: page.id)?.cancel()
    return await captureOutcome(page, tabID: tabID, peek: peek, fresh: true).wasSaved
  }

  /// Closing is a fresh persistence boundary. Cancelling a debounce must never
  /// abandon a native request: DevTools cancellation does not cancel Chromium's
  /// in-flight renderer barrier. Await it, then take a new final snapshot.
  func captureIssueForClose(_ page: ChromiumPage, tabID: String, peek: Bool) async -> CaptureIssue? {
    captures.removeValue(forKey: page.id)?.cancel()
    let result = await captureOutcome(page, tabID: tabID, peek: peek, fresh: true)
    guard !Task.isCancelled else { return nil }
    if case .failed(let issue) = result { return issue }
    return nil
  }

  func captureIssuesForClose(windowID: String) async -> [CaptureIssue] {
    let pages = engine.pages.values.filter { $0.ownerWindowID == windowID }
    for page in pages { captures.removeValue(forKey: page.id)?.cancel() }
    var issues: [CaptureIssue] = []
    for page in pages {
      guard !Task.isCancelled else { return [] }
      let peek = page.id.hasPrefix("peek:")
      let tabID = peek ? String(page.id.dropFirst(5)) : page.id
      if let issue = await captureIssueForClose(page, tabID: tabID, peek: peek) { issues.append(issue) }
    }
    return issues
  }

  /// Explicit user-approved URL-only fallback. Removing the old encrypted
  /// envelope prevents silently restoring older form data at the same address.
  /// A changed page/issue requires a fresh close capture; I/O failure is thrown.
  func continueWithoutPageState(_ issues: [CaptureIssue]) async throws -> Bool {
    guard !Task.isCancelled, issues.allSatisfy(isCurrentIssue) else { return false }
    let ids = Set(issues.map(\.pageID))
    guard fallbackDocuments.isDisjoint(with: ids) else { return false }
    fallbackDocuments.formUnion(ids)
    defer { fallbackDocuments.subtract(ids) }
    for issue in issues { captures.removeValue(forKey: issue.pageID)?.cancel() }
    // A background request which started while the sheet was open owns its
    // slot until the real native result arrives. It may have superseded this
    // failure; never erase a newer successful snapshot.
    for issue in issues {
      if let operation = inFlightCaptures[issue.pageID] { _ = await operation.task.value }
      guard !Task.isCancelled, issues.allSatisfy(isCurrentIssue) else { return false }
    }
    for issue in issues {
      guard let page = issue.page else { return false }
      let history = try await readHistory(page, tabID: issue.tabID, peek: issue.peek, address: issue.address)
      guard !Task.isCancelled, isCurrentIssue(issue),
        issue.history == nil || issue.history == history else { return false }
      // Make the destinations durable before deleting the richer old envelope.
      // The following actor wait is protected from concurrent captures by the
      // fallbackDocuments lease and revalidated afterward.
      try store.commit { state in
        guard let index = state.tabs.firstIndex(where: { $0.id == issue.tabID }) else { return }
        if issue.peek {
          state.tabs[index].peek?.navigation = history.entries
          state.tabs[index].peek?.navigationIndex = history.index
        } else {
          state.tabs[index].navigation = history.entries
          state.tabs[index].navigationIndex = history.index
        }
      }
      try await vault.remove(profileID: issue.profileID, tabID: issue.tabID, peek: issue.peek)
      guard !Task.isCancelled, isCurrentIssue(issue) else { return false }
    }
    try store.flush()
    for issue in issues { captureIssues.removeValue(forKey: issue.pageID) }
    return true
  }

  private func isCurrentIssue(_ issue: CaptureIssue) -> Bool {
    guard captureIssues[issue.pageID]?.id == issue.id, let page = issue.page,
      page.id == issue.pageID, engine.pages[issue.pageID] === page,
      page.profileID == issue.profileID, page.ownerWindowID == issue.ownerWindowID, !page.isPrivate,
      page.browser?.id == issue.browserID, page.url?.absoluteString == issue.address,
      !page.isLoading, !isRestoring(page), !resettingProfiles.contains(issue.profileID),
      owns(page, tabID: issue.tabID, peek: issue.peek, address: issue.address) else { return false }
    if let history = issue.history, let current = store.document(id: issue.pageID) {
      return current.navigation == history.entries && current.navigationIndex == history.index
    }
    return true
  }

  private func captureOutcome(_ page: ChromiumPage, tabID: String, peek: Bool, fresh: Bool) async -> CaptureOutcome {
    let id = page.id
    while let pending = inFlightCaptures[id] {
      let result = await pending.task.value
      if inFlightCaptures[id]?.id == pending.id { inFlightCaptures.removeValue(forKey: id) }
      guard !Task.isCancelled, engine.pages[id] === page, page.id == id else { return .cancelled }
      if !fresh { return result }
    }
    guard !Task.isCancelled, !fallbackDocuments.contains(id) else { return .cancelled }
    let token = UUID()
    // Unstructured by design: callers can stop waiting without abandoning the
    // native operation. No code cancels this task; navigation/browser teardown
    // completes the real protocol request, and the per-page lane serializes it.
    let task = Task { [weak self, weak page] in
      guard let self, let page else { return CaptureOutcome.cancelled }
      return await self.performCapture(page, tabID: tabID, peek: peek)
    }
    inFlightCaptures[id] = (token, task)
    let result = await task.value
    if inFlightCaptures[id]?.id == token { inFlightCaptures.removeValue(forKey: id) }
    return Task.isCancelled ? .cancelled : result
  }

  private func performCapture(_ page: ChromiumPage, tabID: String, peek: Bool) async -> CaptureOutcome {
    let id = page.id
    let epoch = captureEpochs[id, default: 0]
    guard !resettingProfiles.contains(page.profileID), !isRestoring(page), !urlOnlyRestorations.contains(id), !page.isLoading,
      let address = page.url?.absoluteString, owns(page, tabID: tabID, peek: peek, address: address),
      let browser = page.browser else { return .skipped }
    let browserID = browser.id
    let ownerWindowID = page.ownerWindowID
    var history: CapturedHistory?
    do {
      history = try await readHistory(page, tabID: tabID, peek: peek, address: address)
      guard captureEpochs[id, default: 0] == epoch, !resettingProfiles.contains(page.profileID),
        page.id == id, page.ownerWindowID == ownerWindowID,
        owns(page, tabID: tabID, peek: peek, address: address),
        page.browser === browser, page.url?.absoluteString == address else { return .cancelled }
      if let history, let current = store.document(id: id),
        current.navigation != history.entries || current.navigationIndex != history.index {
        store.updateTab(tabID) {
          if peek { $0.peek?.navigation = history.entries; $0.peek?.navigationIndex = history.index }
          else { $0.navigation = history.entries; $0.navigationIndex = history.index }
        }
      }
      guard !page.isPrivate, try await captureSupportsHistory(page) else { return .skipped }
      guard captureEpochs[id, default: 0] == epoch, !resettingProfiles.contains(page.profileID),
        page.id == id, page.ownerWindowID == ownerWindowID,
        engine.pages[id] === page, page.browser === browser,
        page.url?.absoluteString == address else { return .cancelled }
      let encrypted = try await browser.serializedNavigationState()
      guard captureEpochs[id, default: 0] == epoch,
        page.id == id, page.ownerWindowID == ownerWindowID,
        owns(page, tabID: tabID, peek: peek, address: address), page.browser === browser,
        page.url?.absoluteString == address, !resettingProfiles.contains(page.profileID) else { return .cancelled }
      try await vault.write(profileID: page.profileID, tabID: tabID, peek: peek, address: address, encryptedData: encrypted)
      guard captureEpochs[id, default: 0] == epoch, page.id == id, page.ownerWindowID == ownerWindowID,
        engine.pages[id] === page, !resettingProfiles.contains(page.profileID) else { return .cancelled }
      captureIssues.removeValue(forKey: id)
      return .saved
    } catch is CancellationError { return .cancelled }
    catch {
      guard captureEpochs[id, default: 0] == epoch,
        !page.isPrivate, page.id == id, page.ownerWindowID == ownerWindowID,
        engine.pages[id] === page, page.browser?.id == browserID,
        page.url?.absoluteString == address, owns(page, tabID: tabID, peek: peek, address: address),
        !resettingProfiles.contains(page.profileID) else { return .cancelled }
      let issue = CaptureIssue(id: UUID(), pageID: id, profileID: page.profileID,
        ownerWindowID: ownerWindowID, address: address,
        reason: error.localizedDescription, page: page, browserID: browserID, tabID: tabID, peek: peek, history: history)
      captureIssues[id] = issue
      fputs("Zacro could not capture native navigation: \(error.localizedDescription)\n", stderr)
      return .failed(issue)
    }
  }

  private func readHistory(_ page: ChromiumPage, tabID: String, peek: Bool, address: String) async throws -> CapturedHistory {
    guard let browser = page.browser else { throw CancellationError() }
    let native = try await browser.devTools.call("Page.getNavigationHistory")
    guard owns(page, tabID: tabID, peek: peek, address: address), page.browser === browser,
      page.url?.absoluteString == address else { throw CancellationError() }
    guard let raw = native["entries"] as? [[String: Any]], let selected = native["currentIndex"] as? Int,
      raw.indices.contains(selected) else { throw ShortcutError("The page did not provide valid navigation history.") }
    // Match Core's retained address window. Otherwise normalization trims a
    // larger snapshot immediately and valid fallback consent can never match.
    let start = max(0, selected - 49)
    let end = min(raw.count, start + 100)
    var entries: [NavigationEntry] = []
    var index: Int?
    let current = store.document(id: page.id)
    for position in start..<end {
      guard let url = raw[position]["url"] as? String else { continue }
      let provenance = current?.nativeNavigation.flatMap { $0.matches(url) ? $0 : nil }
        ?? current?.navigation.first(where: { $0.url == url && $0.nativeNavigation?.matches(url) == true })?.nativeNavigation
      guard let destination = BrowserAddress.documentURL(url, provenance: provenance)?.absoluteString else { continue }
      if position == selected { index = entries.count }
      let title = (raw[position]["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      entries.append(NavigationEntry(url: destination, title: String(title.prefix(500)), nativeNavigation: provenance))
    }
    guard let index, entries.indices.contains(index), entries[index].url == address else {
      throw ShortcutError("The current page changed before its navigation history could be saved.")
    }
    return CapturedHistory(entries: entries, index: index)
  }

  private func captureSupportsHistory(_ page: ChromiumPage) async throws -> Bool {
    if let result = historyCapability[page.profileID] { return result }
    do {
      let capabilities = try await engine.nativeCapabilities()
      let result = capabilities.navigationState && capabilities.encryptedNavigation == true
      historyCapability[page.profileID] = result
      return result
    } catch let error as CefDevToolsError where error.isUnsupportedMethod {
      historyCapability[page.profileID] = false
      return false
    }
  }

  func forget(_ pageID: String) {
    if inFlightCaptures[pageID] != nil { captureEpochs[pageID, default: 0] &+= 1 }
    else { captureEpochs.removeValue(forKey: pageID) }
    captureIssues.removeValue(forKey: pageID)
    restoreFailures.removeValue(forKey: pageID)
    urlOnlyRestorations.remove(pageID)
    restoreTokens.removeValue(forKey: pageID)
    restores.removeValue(forKey: pageID)?.cancel()
    captures.removeValue(forKey: pageID)?.cancel()
  }

  func removeProfile(_ profileID: String) async throws {
    historyCapability.removeValue(forKey: profileID)
    try await vault.removeProfile(profileID: profileID)
  }

  func beginProfileReset(_ profileID: String) {
    resettingProfiles.insert(profileID)
    for page in engine.pages.values where page.profileID == profileID { forget(page.id) }
  }
  func endProfileReset(_ profileID: String) { resettingProfiles.remove(profileID) }
  func clearSavedHistory(profileID: String) async throws {
    try await vault.removeProfile(profileID: profileID)
  }
  func removeSavedTab(profileID: String, tabID: String) async throws {
    try await vault.remove(profileID: profileID, tabID: tabID, peek: false)
    try await vault.remove(profileID: profileID, tabID: tabID, peek: true)
  }

  func promotePeek(profileID: String, sourceID: String, targetID: String, address: String) async {
    do { try await vault.promotePeek(profileID: profileID, fromTabID: sourceID, toTabID: targetID, address: address) }
    catch { fputs("Zacro could not move Peek navigation: \(error.localizedDescription)\n", stderr) }
  }

  private func supportsHistory(_ page: ChromiumPage) async -> Bool {
    if let result = historyCapability[page.profileID] { return result }
    guard page.browser != nil else { return false }
    do {
      let capabilities = try await engine.nativeCapabilities()
      let result = capabilities.navigationState && capabilities.encryptedNavigation == true
      historyCapability[page.profileID] = result
      return result
    } catch is CancellationError { return false }
    catch {
      if let protocolError = error as? CefDevToolsError, protocolError.isUnsupportedMethod {
        historyCapability[page.profileID] = false
      }
      return false
    }
  }

  private func owns(_ page: ChromiumPage, tabID: String, peek: Bool, address: String) -> Bool {
    guard engine.pages[page.id] === page, let tab = store.tab(tabID), !tab.isClosed,
      store.profileID(for: tab) == page.profileID,
      let profile = store.state.profiles.first(where: { $0.id == page.profileID }), profile.isPrivate == page.isPrivate else { return false }
    return (peek ? tab.peek?.url : tab.url) == address
  }
}
