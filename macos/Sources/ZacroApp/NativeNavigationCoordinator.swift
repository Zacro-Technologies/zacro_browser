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
  private var captures: [String: Task<Void, Never>] = [:]
  private var historyCapability: [String: Bool] = [:]
  private var urlOnlyRestorations = Set<String>()
  private var resettingProfiles = Set<String>()
  var didRestore: ((String, Bool) -> Void)?
  var beforeRestore: ((ChromiumPage) async throws -> Void)?
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
    guard !isPrivate, provenance.matches(address) else {
      throw ShortcutError("The extension authorization no longer matches this page.")
    }
    let approval = try await ChromeExtensionManager(engine: engine, profileID: profileID).validateNavigation(
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
      var destinationApproval: ChromeNavigationApproval?
      do {
        let browser = try await page.ready()
        try Task.checkCancellation()
        do { try await self.beforeRestore?(page) }
        catch {
          fputs("Zacro could not prepare native tab ownership: \(error.localizedDescription)\n", stderr)
          if !(error is CancellationError) { self.didFailPreparation?(id, error.localizedDescription) }
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
          if !(error is CancellationError) { self.didFailPreparation?(id, error.localizedDescription) }
          return
        }
        if let tab = self.store.document(id: page.id) { try await self.authorizeHistory(page, tab: tab) }
        if dormant {
          try await browser.restoreDiscardedDocument()
          restored = true
        } else if !page.isPrivate, await self.supportsHistory(page) {
          let state = try await self.vault.read(profileID: page.profileID, tabID: tabID, peek: peek, address: address)
          try Task.checkCancellation()
          guard self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
          if let state {
            try await browser.restoreNavigationState(state)
            restored = true
          } else if let tab = self.store.document(id: page.id), tab.navigation.count > 1,
            tab.navigation.indices.contains(tab.navigationIndex) {
            let entries = tab.navigation.compactMap { entry -> CefNavigationEntry? in
              guard let url = BrowserAddress.documentURL(entry.url, provenance: entry.nativeNavigation) else { return nil }
              return CefNavigationEntry(url: url, title: entry.title)
            }
            if entries.count == tab.navigation.count {
              try await browser.restoreNavigationEntries(entries, selectedIndex: tab.navigationIndex)
              restored = true
            }
          }
        }
      } catch is CancellationError { return }
      catch {
        fputs("Zacro could not restore native navigation: \(error.localizedDescription)\n", stderr)
      }
      guard !Task.isCancelled, self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
      if !restored && (self.store.document(id: page.id)?.navigation.count ?? 0) > 1 {
        self.urlOnlyRestorations.insert(id)
      } else { self.urlOnlyRestorations.remove(id) }
      if !restored {
        do {
          if let destinationApproval { try await page.loadApprovedNavigation(destinationApproval) }
          else if let url = BrowserAddress.documentURL(address) { page.load(url) }
        } catch {
          if !(error is CancellationError) { self.didFailPreparation?(id, error.localizedDescription) }
          return
        }
      }
      guard !Task.isCancelled, self.owns(page, tabID: tabID, peek: peek, address: address) else { return }
      self.restores.removeValue(forKey: id)
      self.didRestore?(id, restored)
      self.observe(page, tabID: tabID, peek: peek)
    }
  }

  func cancelRestore(_ page: ChromiumPage) {
    restoreTokens.removeValue(forKey: page.id)
    restores.removeValue(forKey: page.id)?.cancel()
  }

  func observe(_ page: ChromiumPage, tabID: String, peek: Bool) {
    guard !resettingProfiles.contains(page.profileID), !isRestoring(page), !page.isLoading, let address = page.url?.absoluteString,
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
    guard !Task.isCancelled, !resettingProfiles.contains(page.profileID), !isRestoring(page), !urlOnlyRestorations.contains(page.id), !page.isLoading,
      let address = page.url?.absoluteString,
      owns(page, tabID: tabID, peek: peek, address: address), let browser = page.browser else { return false }
    do {
      if store.document(id: page.id) != nil {
        let native = try await browser.devTools.call("Page.getNavigationHistory")
        guard !Task.isCancelled, owns(page, tabID: tabID, peek: peek, address: address), page.url?.absoluteString == address else { return false }
        if let raw = native["entries"] as? [[String: Any]], let selected = native["currentIndex"] as? Int,
          raw.indices.contains(selected) {
          let start = max(0, min(selected - 250, raw.count - 500))
          let end = min(raw.count, start + 500)
          var entries: [NavigationEntry] = []
          var index: Int?
          for position in start..<end {
            guard let url = raw[position]["url"] as? String else { continue }
            let current = store.document(id: page.id)
            let provenance = current?.nativeNavigation.flatMap { $0.matches(url) ? $0 : nil }
              ?? current?.navigation.first(where: { $0.url == url && $0.nativeNavigation?.matches(url) == true })?.nativeNavigation
            guard BrowserAddress.documentURL(url, provenance: provenance) != nil else { continue }
            if position == selected { index = entries.count }
            entries.append(NavigationEntry(url: url, title: String((raw[position]["title"] as? String ?? "").prefix(500)), nativeNavigation: provenance))
          }
          if let index, entries.indices.contains(index), entries[index].url == address,
            let current = store.document(id: page.id), current.navigation != entries || current.navigationIndex != index {
            store.updateTab(tabID) {
              if peek { $0.peek?.navigation = entries; $0.peek?.navigationIndex = index }
              else { $0.navigation = entries; $0.navigationIndex = index }
            }
          }
        }
      }
      guard !page.isPrivate, await supportsHistory(page), !Task.isCancelled else { return false }
      let encrypted = try await browser.serializedNavigationState()
      guard !Task.isCancelled, owns(page, tabID: tabID, peek: peek, address: address), page.url?.absoluteString == address else { return false }
      try await vault.write(profileID: page.profileID, tabID: tabID, peek: peek, address: address, encryptedData: encrypted)
      return true
    } catch is CancellationError { }
    catch {
      // An interrupted page or unsupported protocol leaves the last valid
      // snapshot intact. It never writes partial or plaintext form state.
      fputs("Zacro could not capture native navigation: \(error.localizedDescription)\n", stderr)
    }
    return false
  }

  func forget(_ pageID: String) {
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
