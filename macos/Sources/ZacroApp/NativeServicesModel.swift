import AppKit
import Combine
import SwiftUI
import ZacroCore
import ZacroServices

@MainActor
final class NativeServicesModel: ObservableObject {
  @Published var ai: ServiceJSON = [:]
  @Published var sync: ServiceJSON = [:]
  @Published var aiEvent: ServiceJSON = [:]
  @Published var contextTabs: [NativeAIContextTab] = []
  let aiConversation = NativeAIConversationState()
  let aiService: NativeAIService
  let syncService: NativeSyncClient?
  var sourceAction: ((String, ServiceJSON) async throws -> ServiceJSON)?
  var syncLibraryEvent: ((ServiceJSON) async -> Void)?
  var syncStorageEvent: ((ServiceJSON) async -> Void)?
  var portableLibrary: ((String) async throws -> [ServiceJSON])? {
    get { libraryFeed.reader }
    set { libraryFeed.reader = newValue }
  }
  var nativeSyncStatusChanged: (() -> Void)?
  private var nativeSyncStatusContext: ServiceJSON = .null
  var prepareNativeSync: ((String) async throws -> Void)?
  var nativeSyncAction: ((String, String, String) async throws -> Void)?
  @Published private var nativeSyncState: [String: ServiceJSON] = [:]
  private var sharedBackend: NativeServicesModel?
  private var backendSubscription: AnyCancellable?
  private var backend: NativeServicesModel { sharedBackend ?? self }
  private(set) var linkedSyncProfileIDs = Set<String>()
  private let libraryFeed: NativePortableLibraryReader
  private let store: BrowserStore
  private var tasks: [Task<Void, Never>] = []
  private var profileTask: Task<Void, Never>?
  private var profileID: String?
  private var syncStartupError: String?
  private var cleanupError: String?
  private var started = false
  private var shutdownTask: Task<Void, Never>?

  init(store: BrowserStore, directory: URL, context: @escaping NativeAIService.ContextReader) {
    self.store = store
    let libraryFeed = NativePortableLibraryReader(); self.libraryFeed = libraryFeed
    let active: NativeAIService.ProfileReader = { [store] in
      await MainActor.run {
        guard let profile = store.state.activeProfile else { return nil }
        return AIProfileScope(id: profile.id, isPrivate: profile.isPrivate)
      }
    }
    aiService = NativeAIService(directory: directory, currentProfile: active, context: context)
    do {
      syncService = try NativeSyncClient(directory: directory, getProfile: { [store] id in
        await MainActor.run {
          store.state.profiles.first { $0.id == id }.map { AIProfileScope(id: $0.id, isPrivate: $0.isPrivate) }
        }
      }, activeProfile: active, localLibrary: { id in try await libraryFeed.read(id) })
    } catch { syncService = nil; syncStartupError = error.localizedDescription }
  }
  /// Window presentation shares actors and durable storage with the application backend.
  init(store: BrowserStore, sharing backend: NativeServicesModel) {
    self.store = store; sharedBackend = backend.backend
    aiService = backend.aiService; syncService = backend.syncService
    libraryFeed = backend.libraryFeed; syncStartupError = backend.syncStartupError
  }
  private func observeBackend() {
    guard let sharedBackend, backendSubscription == nil else { return }
    backendSubscription = sharedBackend.$nativeSyncState.sink { [weak self] state in
      guard let self else { return }
      self.nativeSyncState = state
      self.applySync(self.sync)
    }
  }
  private var scope: AIProfileScope {
    AIProfileScope(id: store.activeProfileID, isPrivate: store.state.activeProfile?.isPrivate ?? true)
  }
  private func requireFocusedProfile(_ id: String) throws {
    guard store.activeProfileID == id, backend.store.activeProfileID == id,
      store.state.activeProfile?.isPrivate == false else {
      throw ServiceError("PROFILE_CHANGED", "Activate this window's profile before using these controls.")
    }
  }
  func start() {
    guard !started else { return }; started = true
    observeBackend()
    tasks.append(Task { [weak self, aiService] in
      let stream = await aiService.events()
      for await event in stream {
        guard let self, !Task.isCancelled else { break }
        guard event["profileId"].string == self.store.activeProfileID else { continue }
        self.aiEvent = event
        self.aiConversation.receive(event)
        if event["type"].string == "ai:status" { self.applyAI(event["status"]) }
      }
    })
    if let syncService {
      tasks.append(Task { [weak self] in
        let stream = await syncService.events()
        if self?.sharedBackend == nil {
          await syncService.start()
          do { try await self?.recoverProfileDeletions() } catch { self?.cleanupError = error.localizedDescription }
        }
        if let profile = self?.scope { self?.applySync(await syncService.status(profileID: profile.id)) }
        for await event in stream {
          guard let self, !Task.isCancelled else { break }
          if event["type"].string == "sync:status" { self.applySync(event["status"]) }
          else if self.sharedBackend == nil, event["type"].string == "library:changed", await syncService.isCurrentLink(event) {
            await self.syncLibraryEvent?(event)
          } else if self.sharedBackend == nil, event["type"].string == "storage:changed" {
            if !event["linkId"].string.isEmpty {
              guard await syncService.isCurrentLink(event) else { continue }
            }
            await self.syncStorageEvent?(event)
          }
        }
      })
    }
    refreshContext()
  }
  func refreshContext() {
    let current = store.activeProfileID
    let isPrivate = store.state.activeProfile?.isPrivate ?? true
    let spaces = Set(store.state.spaces.filter { $0.profileID == current }.map(\.id))
    var readable = store.state.tabs.filter { !$0.isClosed && spaces.contains($0.spaceID) && BrowserAddress.webURL($0.url) != nil }
    if let active = readable.firstIndex(where: { $0.id == store.state.activeTabID }), active > 0 {
      readable.insert(readable.remove(at: active), at: 0)
    }
    let nextTabs = readable.map {
      NativeAIContextTab(id: $0.id, title: $0.displayTitle, url: $0.url, profileID: current,
        isPDF: URL(string: $0.url)?.pathExtension.lowercased() == "pdf", isReadable: !isPrivate)
    }
    if contextTabs != nextTabs { contextTabs = nextTabs }
    guard profileID != current else { return }
    profileID = current
    ai = ["profileId":.string(current),"private":.bool(isPrivate),"configured":false]
    applySync(sync)
    aiConversation.activate(profileID: current, isPrivate: store.state.activeProfile?.isPrivate ?? true)
    profileTask?.cancel()
    profileTask = Task { [weak self, aiService, syncService] in
      guard !Task.isCancelled else { return }
      if self?.sharedBackend == nil {
        await aiService.profileChanged()
        guard !Task.isCancelled else { return }
        await syncService?.profileChanged()
      }
      let status = await aiService.status(for: AIProfileScope(id: current, isPrivate: isPrivate))
      guard !Task.isCancelled, self?.profileID == current else { return }
      self?.applyAI(status)
      if let syncService {
        let syncStatus = await syncService.status(profileID: current)
        if !Task.isCancelled, self?.profileID == current { self?.applySync(syncStatus) }
      }
    }
  }
  private func applyAI(_ status: ServiceJSON) {
    guard status["profileId"].string == store.activeProfileID else { return }
    ai = status
    aiConversation.activate(profileID: status["profileId"].string, isPrivate: status["private"].bool)
  }
  private func applySync(_ status: ServiceJSON) {
    if sharedBackend == nil, status["state"] != "private" {
      let context: ServiceJSON = ["account":status["account"]["id"], "endpoint":status["endpoint"],
        "profiles":.array(status["profiles"].array.map { ["profileId":$0["profileId"], "datasetId":$0["datasetId"],
          "librarySync":$0["librarySync"], "settingsSync":$0["settingsSync"]] })]
      let changed = context != nativeSyncStatusContext
      nativeSyncStatusContext = context
      linkedSyncProfileIDs = Set(status["profiles"].array.map { $0["profileId"].string }.filter { !$0.isEmpty })
      if changed { nativeSyncStatusChanged?() }
    }
    if store.state.activeProfile?.isPrivate != false {
      sync = ["endpoint":status["endpoint"],"account":.null,"device":.null,"profiles":[],"state":"private"]
    } else {
      sync = status
      if let cleanupError = backend.cleanupError { sync["cleanupError"] = .string(cleanupError) }
      if let syncStartupError { sync["startupError"] = .string(syncStartupError) }
      sync["native"] = nativeSyncState[store.activeProfileID] ?? [:]
    }
  }
  func updateNativeSync(profileID: String, pending: [ServiceJSON], errors: [ServiceJSON]) {
    if let sharedBackend { sharedBackend.updateNativeSync(profileID: profileID, pending: pending, errors: errors); return }
    nativeSyncState[profileID] = ["pending":.array(pending), "errors":.array(errors)]
    if profileID == store.activeProfileID { applySync(sync) }
  }
  func aiAction(_ action: String, payload: ServiceJSON = [:]) async throws -> ServiceJSON {
    let profile = store.activeProfileID
    try requireFocusedProfile(profile)
    if action == "ai:prepare" {
      guard store.state.activeProfile?.isPrivate == false else { throw ServiceError("PRIVATE","AI is unavailable in private profiles.") }
      guard !aiConversation.busy else { throw ServiceError("BUSY","Stop the current response before changing context.") }
      let intent = payload["intent"].string
      let prompts = [
        "summarize":"Summarize this page in five concise points. Highlight the main conclusion, useful details, and any important caveats. Cite the page.",
        "explain":"Explain the main ideas on this page in plain language. Define unfamiliar terms and distinguish what the page says from what it does not establish. Cite the page.",
        "compare":"Compare these pages. Organize the key similarities, differences, tradeoffs, and missing information in a concise table. Cite each page and do not guess.",
        "research":"Research "
      ]
      aiConversation.prepare(payload["question"].string.isEmpty ? prompts[intent] ?? "" : payload["question"].string)
      if ["summarize","explain","compare","research"].contains(intent) {
        _ = try await aiService.handle("ai:reset", expectedProfileID: profile)
        guard store.activeProfileID == profile, store.state.activeProfile?.isPrivate == false else {
          throw ServiceError("PROFILE_CHANGED","The active profile changed.")
        }
        let ids = payload["tabIds"].array.map(\.string)
        let tabs = contextTabs.filter { $0.profileID == profile && $0.isReadable }
        aiConversation.grants = intent == "research" ? [] : ids.isEmpty ? Array(tabs.prefix(intent == "compare" ? 0 : 1)) : tabs.filter { ids.contains($0.id) }
        aiConversation.context = intent == "research" ? "research" : intent == "compare" ? "tabs" : "page"
        if intent != "research" { aiConversation.pendingReview = aiConversation.context }
      }
      return ["prepared":true]
    }
    if ["ai:open-source", "ai:open-sources"].contains(action), let sourceAction = sourceAction ?? backend.sourceAction {
      return try await sourceAction(action, payload)
    }
    do {
      let result = try await aiService.handle(action, payload: payload, expectedProfileID: profile)
      try requireFocusedProfile(profile)
      if ["ai:login", "ai:install"].contains(action), let url = BrowserAddress.webURL(result["url"].string) { NSWorkspace.shared.open(url) }
      applyAI(await aiService.status(for: scope)); return result
    } catch {
      applyAI(await aiService.status(for: scope)); throw error
    }
  }
  func syncAction(_ action: String, payload: ServiceJSON = [:]) async throws -> ServiceJSON {
    guard let syncService else { throw ServiceError("STORAGE", syncStartupError ?? "Synchronization is unavailable.") }
    let profile = store.activeProfileID
    try requireFocusedProfile(profile)
    if action == "sync:finish-profile-cleanup" {
      guard store.state.activeProfile?.isPrivate == false else { throw ServiceError("PRIVATE", "Profile cleanup is unavailable in private browsing.") }
      try await backend.recoverProfileDeletions(); applySync(await syncService.status(profileID: profile)); return ["complete":true]
    }
    if ["sync:native-retry", "sync:native-install", "sync:native-keep-local", "sync:native-use-remote"].contains(action) {
      guard store.state.activeProfile?.isPrivate == false, let nativeSyncAction = backend.nativeSyncAction else {
        throw ServiceError("EXTENSION_SYNC", "Extension synchronization is unavailable in this profile.")
      }
      try await nativeSyncAction(action, profile, payload["id"].string)
      try requireFocusedProfile(profile)
      return ["complete":true]
    }
    if action == "sync:settings", payload["enabled"].bool {
      guard let prepareNativeSync = backend.prepareNativeSync else { throw ServiceError("EXTENSION_SYNC", "Extension synchronization is not ready.") }
      try await prepareNativeSync(profile)
      try requireFocusedProfile(profile)
    }
    let result = try await syncService.handle(action, payload: payload, expectedProfileID: profile)
    applySync(await syncService.status(profileID: profile))
    if action == "sync:export" {
      let owner = sync["account"]["id"], endpoint = sync["endpoint"]
      let panel = NSSavePanel(); panel.nameFieldStringValue = "Zacro Sync Recovery.json"
      guard await panel.begin() == .OK, let url = panel.url else { return ["saved":false] }
      let status = await syncService.status()
      try requireFocusedProfile(profile)
      guard owner == status["account"]["id"], endpoint == status["endpoint"] else { throw ServiceError("cancelled","The synchronization context changed.") }
      // Re-resolve the rejected operation after the dialog so discarded or remapped changes cannot be exported.
      let current = try await syncService.exportRejected(profile,id:payload["id"].string)
      guard current == result else { throw ServiceError("cancelled","This unsynced change is no longer available.") }
      try current.encoded().write(to:url,options:.atomic)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
      return ["saved":true]
    }
    return result
  }
  func forgetProfile(_ id: String) async throws {
    if let sharedBackend { try await sharedBackend.forgetProfile(id); return }
    try await syncService?.deleteLocalProfile(id)
    try await aiService.forgetProfile(id)
  }
  func prepareProfileDeletion(_ id: String) async throws {
    if let sharedBackend { try await sharedBackend.prepareProfileDeletion(id); return }
    try await aiService.prepareProfileDeletion(id)
    do {
      if store.state.profiles.first(where: { $0.id == id })?.isPrivate == false {
        guard let syncService else { throw ServiceError("STORAGE", syncStartupError ?? "Profile service data could not be opened. Resolve this before deleting the profile.") }
        try await syncService.prepareLocalProfileDeletion(id)
      }
    }
    catch { await aiService.cancelProfileDeletion(id); throw error }
  }
  func cancelProfileDeletion(_ id: String) async throws {
    if let sharedBackend { try await sharedBackend.cancelProfileDeletion(id); return }
    if store.state.profiles.first(where: { $0.id == id })?.isPrivate == false { try await syncService?.cancelLocalProfileDeletion(id) }
    await aiService.cancelProfileDeletion(id)
  }
  func didDeleteProfile(_ id: String) async throws {
    if let sharedBackend { try await sharedBackend.didDeleteProfile(id); return }
    do {
      try await aiService.forgetProfile(id)
      try await syncService?.completeLocalProfileDeletion(id)
    } catch {
      cleanupError = error.localizedDescription
      if let syncService { applySync(await syncService.status()) }
      throw error
    }
  }
  private func recoverProfileDeletions() async throws {
    guard let syncService else { return }
    for id in await syncService.pendingProfileDeletionIDs() {
      if store.state.profiles.contains(where: { $0.id == id }) { try await cancelProfileDeletion(id) }
      else { try await didDeleteProfile(id) }
    }
    cleanupError = nil
  }
  /// Idempotent shutdown barrier. Await before destroying Chromium or exiting the app.
  func shutdown() async {
    if let shutdownTask { await shutdownTask.value; return }
    profileTask?.cancel(); profileTask = nil
    tasks.forEach { $0.cancel() }; tasks.removeAll()
    backendSubscription?.cancel(); backendSubscription = nil
    if sharedBackend != nil {
      started = false; profileID = nil
      aiConversation.activate(profileID: "", isPrivate: true)
      contextTabs = []; ai = [:]; sync = [:]
      return
    }
    let shutdown = Task { [aiService, syncService] in
      async let ai: Void = aiService.close()
      async let sync: Void = syncService?.close() ?? ()
      _ = await (ai, sync)
    }
    shutdownTask = shutdown
    await shutdown.value
  }
  func close() async { await shutdown() }
}

@MainActor private final class NativePortableLibraryReader {
  var reader: ((String) async throws -> [ServiceJSON])?
  func read(_ profileID: String) async throws -> [ServiceJSON] {
    guard let reader else { throw ServiceError("EXTENSION_SYNC", "The extension library is not ready. Try again once the browser has opened.") }
    return try await reader(profileID)
  }
}
