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
  var conversationID: String { store.owningWindowID ?? "application" }
  let aiService: NativeAIService
  let syncService: NativeSyncClient?
  var sourceAction: ((String, ServiceJSON) async throws -> ServiceJSON)?
  /// Supplied by the owning window coordinator; never infer a global key window.
  var dialogWindow: () -> NSWindow? = { nil }
  var syncLibraryEvent: ((ServiceJSON) async -> Void)?
  var syncStorageEvent: ((ServiceJSON) async -> Void)?
  var portableLibrary: ((String) async throws -> [ServiceJSON])? {
    get { libraryFeed.reader }
    set { libraryFeed.reader = newValue }
  }
  var nativeSyncStatusChanged: (() -> Void)?
  private var nativeSyncStatusContext: ServiceJSON = .null
  var prepareNativeSync: ((String) async throws -> Void)?
  var nativeSyncAction: ((String, String, ServiceJSON, String?) async throws -> Void)?
  private var nativeSyncTasks: [UUID: Task<Void, Error>] = [:]
  private var syncExportTasks: [UUID: Task<ServiceJSON, Error>] = [:]
  var pendingSyncExportCount: Int { syncExportTasks.count }
  @Published private var nativeSyncState: [String: ServiceJSON] = [:]
  private var sharedBackend: NativeServicesModel?
  private var backendSubscription: AnyCancellable?
  private var backend: NativeServicesModel { sharedBackend ?? self }
  private(set) var linkedSyncProfileIDs = Set<String>()
  private let libraryFeed: NativePortableLibraryReader
  private let store: BrowserStore
  private var tasks: [Task<Void, Never>] = []
  private var profileTask: Task<Void, Never>?
  private var aiContextReset: Task<Void, Never>?
  private var aiSubmissionID: UUID?
  private var profileID: String?
  private var syncStartupError: String?
  private var cleanupError: String?
  private var started = false
  private var shutdownTask: Task<Void, Never>?

  init(store: BrowserStore, directory: URL, conversationProfile: NativeAIService.ConversationProfileReader? = nil,
    aiTransport: any ServiceHTTPTransport = NativeServiceHTTPTransport(), context: @escaping NativeAIService.ContextReader) {
    self.store = store
    let libraryFeed = NativePortableLibraryReader(); self.libraryFeed = libraryFeed
    let active: NativeAIService.ProfileReader = { [store] in
      await MainActor.run {
        guard let profile = store.state.activeProfile else { return nil }
        return AIProfileScope(id: profile.id, isPrivate: profile.isPrivate)
      }
    }
    aiService = NativeAIService(directory: directory, currentProfile: active, conversationProfile: conversationProfile, context: context, transport:aiTransport)
    do {
      syncService = try NativeSyncClient(directory: directory, getProfile: { [store] id in
        await MainActor.run {
          store.state.profiles.first { $0.id == id }.map { AIProfileScope(id: $0.id, isPrivate: $0.isPrivate) }
        }
      }, activeProfile: active, localLibrary: { id in try await libraryFeed.read(id) })
    } catch { syncService = nil; syncStartupError = error.localizedDescription }
  }
  /// Window presentation shares actors and durable storage with the application backend.
  init(store: BrowserStore, sharing backend: NativeServicesModel, predecessor: Task<Void, Never>? = nil) {
    self.store = store; sharedBackend = backend.backend
    aiService = backend.aiService; syncService = backend.syncService
    libraryFeed = backend.libraryFeed; syncStartupError = backend.syncStartupError
    // A reopened logical window reuses its conversation ID. Its first reset,
    // status read, and request must follow every previous model's final clear.
    aiContextReset = predecessor
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
    guard shutdownTask == nil, store.activeProfileID == id, backend.store.activeProfileID == id,
      store.owningWindowID == nil || store.state.windowSessions?.contains(where: { $0.id == store.owningWindowID && $0.isOpen }) == true,
      store.state.activeProfile?.isPrivate == false else {
      throw ServiceError("PROFILE_CHANGED", "Activate this window's profile before using these controls.")
    }
  }
  private func requireAIProfile(_ id: String) throws {
    guard shutdownTask == nil, store.activeProfileID == id, store.state.activeProfile?.isPrivate == false,
      store.owningWindowID == nil || store.state.windowSessions?.contains(where: { $0.id == store.owningWindowID && $0.isOpen }) == true else {
      throw ServiceError("PROFILE_CHANGED", "This window's profile changed. Review the request again.")
    }
  }
  func start() {
    guard !started, shutdownTask == nil else { return }; started = true
    observeBackend()
    tasks.append(Task { [weak self, aiService] in
      let stream = await aiService.events()
      for await event in stream {
        guard let self, !Task.isCancelled else { break }
        guard event["profileId"].string == self.store.activeProfileID else { continue }
        guard !event.contains("conversationId") || event["conversationId"].string == self.conversationID else { continue }
        self.aiEvent = event
        self.aiConversation.receive(event)
        if event["type"].string == "ai:status" { self.applyAI(event["status"]) }
      }
    })
    if let syncService {
      tasks.append(Task { [weak self] in
        let stream = await syncService.events()
        if let self, self.sharedBackend == nil {
          await syncService.start()
          do { try await self.recoverProfileDeletions() } catch { self.cleanupError = error.localizedDescription }
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
    guard shutdownTask == nil else { return }
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
    cancelNativeSyncActions()
    cancelSyncExports()
    aiSubmissionID = nil
    let previousProfile = profileID ?? current, conversation = conversationID
    let precedingReset = aiContextReset
    aiContextReset = Task { [aiService] in
      await precedingReset?.value
      await aiService.clearConversation(profileID: previousProfile, conversationID: conversation)
    }
    profileID = current
    ai = ["profileId":.string(current),"private":.bool(isPrivate),"configured":false]
    applySync(sync)
    aiConversation.activate(profileID: current, isPrivate: store.state.activeProfile?.isPrivate ?? true)
    profileTask?.cancel()
    profileTask = Task { [weak self, aiService, syncService] in
      await self?.aiContextReset?.value
      guard !Task.isCancelled else { return }
      if self?.sharedBackend == nil {
        await aiService.profileChanged()
        guard !Task.isCancelled else { return }
        await syncService?.profileChanged()
      }
      let status = await aiService.status(for: AIProfileScope(id: current, isPrivate: isPrivate), conversationID: self?.conversationID)
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
    if status["latestReset"] != .null { aiConversation.receive(status["latestReset"]) }
  }
  func resetAIConversations(profileID: String) async {
    guard shutdownTask == nil else { return }
    await aiService.clearProfileConversations(profileID: profileID)
    if store.activeProfileID == profileID {
      applyAI(await aiService.status(for: scope, conversationID: conversationID))
    }
  }
  private func applySync(_ status: ServiceJSON) {
    if sharedBackend == nil, status["state"] != "private" {
      let context: ServiceJSON = ["account":status["account"]["id"], "endpoint":status["endpoint"],
        "profiles":.array(status["profiles"].array.map { ["profileId":$0["profileId"], "linkId":$0["linkId"], "datasetId":$0["datasetId"],
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
  var canSubmitAIQuestion: Bool {
    (try? requireAIProfile(store.activeProfileID)) != nil && dialogWindow()?.isVisible == true &&
      ai["profileId"].string == store.activeProfileID && ai["configured"].bool && !ai["busy"].bool &&
      !aiConversation.busy && !aiConversation.submitting && aiConversation.contextChangeID == nil && aiConversation.pendingReview == nil
  }
  /// Shared by the Library composer and the explicit palette Ask action. Merely
  /// opening the Library never invokes this method or shares page context.
  func submitAIQuestion(_ value: String, expectedProfileID: String? = nil) async throws -> ServiceJSON {
    let profile = expectedProfileID ?? store.activeProfileID
    try requireAIProfile(profile)
    guard let window = dialogWindow(), window.isVisible, !window.isMiniaturized else {
      throw ServiceError("CANCELLED", "The question's browser window is unavailable.")
    }
    let identifier = window.identifier, number = window.windowNumber
    let question = value.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !question.isEmpty, question.utf16.count <= 8000 else {
      throw ServiceError("INPUT", "Enter a question of 1–8000 characters.")
    }
    guard ai["configured"].bool else { throw ServiceError("NOT_CONFIGURED", "Connect the selected provider in Settings first.") }
    guard canSubmitAIQuestion, aiSubmissionID == nil else { throw ServiceError("BUSY", "Wait for the current answer or context change to finish.") }
    let token = UUID(), conversation = aiConversation, generation = aiConversation.generation
    let kind = conversation.context, grants = conversation.grants
    let provider = ai["provider"], model = ai["model"], endpoint = ai["baseUrl"]
    aiSubmissionID = token; conversation.submitting = true
    defer { if aiSubmissionID == token { aiSubmissionID = nil; conversation.submitting = false } }
    func validateOwner() throws {
      try Task.checkCancellation(); try requireAIProfile(profile)
      guard dialogWindow() === window, window.identifier == identifier, window.windowNumber == number else {
        throw ServiceError("CANCELLED", "The question's browser window changed.")
      }
    }
    func validate() throws {
      try validateOwner()
      guard aiSubmissionID == token, conversation.profileID == profile, conversation.generation == generation,
        conversation.context == kind, conversation.grants == grants, conversation.contextChangeID == nil, conversation.pendingReview == nil else {
        throw ServiceError("CONTEXT_CHANGED", "The browsing context changed. Review the selected pages before sending.")
      }
      guard kind == "research" || !grants.isEmpty else { throw ServiceError("CONTEXT", "Choose a page to share, or switch to web research.") }
      for grant in grants {
        guard grant.profileID == profile, grant.isReadable,
          let tab = store.tab(grant.id), !tab.isClosed, tab.url == grant.url,
          store.state.spaces.first(where: { $0.id == tab.spaceID })?.profileID == profile,
          BrowserAddress.webURL(tab.url) != nil else {
          throw ServiceError("CONTEXT_CHANGED", "A shared page changed or closed. Review the context before asking again.")
        }
      }
    }
    await aiContextReset?.value
    try validate()
    let status = try await aiService.handle("ai:status", expectedProfileID:profile, conversationID:conversationID)
    try validate()
    guard status["configured"].bool, !status["private"].bool else { throw ServiceError("NOT_CONFIGURED", "Connect the selected provider in Settings first.") }
    guard !status["busy"].bool else { throw ServiceError("BUSY", "The previous request is still stopping. Try again in a moment.") }
    guard status["provider"] == provider, status["model"] == model, status["baseUrl"] == endpoint else {
      throw ServiceError("CONTEXT_CHANGED", "The AI connection changed. Review the request again.")
    }
    applyAI(status)
    try validate()
    let selected = kind == "research" ? [] : grants
    let request: ServiceJSON = ["question":.string(question),"requestId":.string(UUID().uuidString),
      "tabIds":.array(selected.map { .string($0.id) }),
      "contextTabs":.array(selected.map { ["id":.string($0.id),"url":.string($0.url),"title":.string($0.title)] })]
    conversation.begin(question:question, request:request)
    do {
      let answer = try await aiAction("ai:ask", payload:request)
      try validateOwner()
      conversation.receive(answer); return answer
    } catch {
      if conversation.profileID == profile { conversation.fail(error, request:request["requestId"].string) }
      throw error
    }
  }
  func requestAIContextReview(_ kind: String, selectedIDs: Set<String>) throws {
    let profile = store.activeProfileID
    try requireAIProfile(profile)
    guard ["page", "tabs"].contains(kind), !aiConversation.busy, !aiConversation.submitting,
      aiConversation.contextChangeID == nil, aiConversation.pendingReview == nil, let owner = dialogWindow(), owner.isVisible else {
      throw ServiceError("BUSY", "Finish the current request before reviewing pages.")
    }
    let choices = contextTabs.filter { $0.profileID == profile && $0.isReadable }
    aiConversation.pendingReview = NativeAIContextReview(profileID:profile, kind:kind, choices:choices,
      selectedIDs:selectedIDs.intersection(choices.map(\.id)), owner:owner,
      ownerIdentifier:owner.identifier, ownerNumber:owner.windowNumber)
  }
  func confirmAIContextReview(reviewID: UUID, selectedIDs: Set<String>) async throws {
    guard let review = aiConversation.pendingReview, review.id == reviewID,
      let token = aiConversation.beginContextChange() else { throw ServiceError("CANCELLED", "The page review changed.") }
    defer { aiConversation.endContextChange(token) }
    let grants = review.choices.filter { selectedIDs.contains($0.id) }
    func validate() throws {
      try Task.checkCancellation(); try requireAIProfile(review.profileID)
      guard aiConversation.pendingReview?.id == reviewID, aiConversation.contextChangeID == token,
        dialogWindow() === review.owner, review.owner.identifier == review.ownerIdentifier,
        review.owner.windowNumber == review.ownerNumber, review.owner.isVisible,
        !grants.isEmpty, grants.count == selectedIDs.count, grants.count <= (review.kind == "page" ? 1 : 6) else {
        throw ServiceError("CANCELLED", "The page review or its browser window changed.")
      }
      for grant in grants {
        guard let tab = store.tab(grant.id), !tab.isClosed, tab.url == grant.url,
          store.state.spaces.first(where: { $0.id == tab.spaceID })?.profileID == review.profileID else {
          throw ServiceError("CONTEXT_CHANGED", "A selected page changed. Review its new address before sharing.")
        }
      }
    }
    try validate()
    _ = try await aiAction("ai:reset")
    try validate()
    aiConversation.context = review.kind; aiConversation.grants = grants; aiConversation.pendingReview = nil
  }
  func aiAction(_ action: String, payload: ServiceJSON = [:]) async throws -> ServiceJSON {
    let profile = store.activeProfileID
    try requireAIProfile(profile)
    await aiContextReset?.value
    try requireAIProfile(profile)
    if action == "ai:prepare" {
      guard store.state.activeProfile?.isPrivate == false else { throw ServiceError("PRIVATE","AI is unavailable in private profiles.") }
      guard !aiConversation.busy, !aiConversation.submitting, aiConversation.contextChangeID == nil else { throw ServiceError("BUSY","Stop the current response before changing context.") }
      let intent = payload["intent"].string
      let prompts = [
        "summarize":"Summarize this page in five concise points. Highlight the main conclusion, useful details, and any important caveats. Cite the page.",
        "explain":"Explain the main ideas on this page in plain language. Define unfamiliar terms and distinguish what the page says from what it does not establish. Cite the page.",
        "compare":"Compare these pages. Organize the key similarities, differences, tradeoffs, and missing information in a concise table. Cite each page and do not guess.",
        "research":"Research "
      ]
      aiConversation.prepare(payload["question"].string.isEmpty ? prompts[intent] ?? "" : payload["question"].string)
      if ["summarize","explain","compare"].contains(intent) {
        let ids = payload["tabIds"].array.map(\.string)
        let tabs = contextTabs.filter { $0.profileID == profile && $0.isReadable }
        let selected = ids.isEmpty ? Set(tabs.prefix(intent == "compare" ? 0 : 1).map(\.id)) : Set(ids)
        try requestAIContextReview(intent == "compare" ? "tabs" : "page", selectedIDs:selected)
      } else if intent == "research" {
        guard let token = aiConversation.beginContextChange() else { throw ServiceError("BUSY", "Finish changing context first.") }
        defer { aiConversation.endContextChange(token) }
        let reset = try await aiService.handle("ai:reset", expectedProfileID:profile, conversationID:conversationID)
        try requireAIProfile(profile)
        guard aiConversation.contextChangeID == token else { throw ServiceError("CONTEXT_CHANGED", "The browsing context changed.") }
        aiConversation.receive(reset)
        aiConversation.grants = []; aiConversation.context = "research"; aiConversation.pendingReview = nil
      }
      return ["prepared":true]
    }
    if ["ai:open-source", "ai:open-sources"].contains(action), let sourceAction = sourceAction ?? backend.sourceAction {
      return try await sourceAction(action, payload)
    }
    do {
      let result = try await aiService.handle(action, payload: payload, expectedProfileID: profile, conversationID: conversationID)
      try requireAIProfile(profile)
      // Consume the acknowledged reset before a caller can begin its retry.
      // The same event arriving later through AsyncStream is then a duplicate.
      if result["type"] == "ai:reset" { aiConversation.receive(result) }
      if ["ai:login", "ai:install"].contains(action), let url = BrowserAddress.webURL(result["url"].string), !NSWorkspace.shared.open(url) {
        if action == "ai:login" {
          _ = try? await aiService.handle("ai:login-cancel", expectedProfileID: profile, conversationID: conversationID)
        }
        throw ServiceError("OPEN_BROWSER", "Unable to open the provider page in your default browser. Try again after choosing a default browser.")
      }
      applyAI(await aiService.status(for: scope, conversationID: conversationID)); return result
    } catch {
      applyAI(await aiService.status(for: scope, conversationID: conversationID)); throw error
    }
  }
  func syncAction(_ action: String, payload: ServiceJSON = [:]) async throws -> ServiceJSON {
    guard let syncService else { throw ServiceError("STORAGE", syncStartupError ?? "Synchronization is unavailable.") }
    let profile = payload.contains("profileId") ? payload["profileId"].string : store.activeProfileID
    try requireFocusedProfile(profile)
    if action == "sync:export" {
      // Capture the actual owner and displayed account/link before any service
      // await. A delayed task cannot borrow a newer window or account.
      guard let window = dialogWindow(), window.isVisible, !window.isMiniaturized else {
        throw ServiceError("cancelled", "The export's browser window is unavailable.")
      }
      let identifier = window.identifier, number = window.windowNumber
      let identity = syncExportIdentity(sync, profile:profile), token = UUID()
      let task = Task { [weak self] () throws -> ServiceJSON in
        guard let self else { throw CancellationError() }
        return try await self.exportSyncRecovery(payload, profile:profile, window:window,
          identifier:identifier, number:number, identity:identity, service:syncService)
      }
      syncExportTasks[token] = task
      defer { syncExportTasks.removeValue(forKey:token) }
      return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    if action == "sync:finish-profile-cleanup" {
      guard store.state.activeProfile?.isPrivate == false else { throw ServiceError("PRIVATE", "Profile cleanup is unavailable in private browsing.") }
      try await backend.recoverProfileDeletions(); applySync(await syncService.status(profileID: profile)); return ["complete":true]
    }
    if ["sync:native-retry", "sync:native-review", "sync:native-keep-local", "sync:native-use-remote"].contains(action) {
      guard store.state.activeProfile?.isPrivate == false, let nativeSyncAction = backend.nativeSyncAction else {
        throw ServiceError("EXTENSION_SYNC", "Extension synchronization is unavailable in this profile.")
      }
      let token = UUID(), owner = store.owningWindowID
      let task = Task { try await nativeSyncAction(action, profile, payload, owner) }
      nativeSyncTasks[token] = task
      defer { nativeSyncTasks.removeValue(forKey: token) }
      try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
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
    return result
  }
  private func syncExportIdentity(_ status: ServiceJSON, profile: String) -> ServiceJSON {
    let link = status["profiles"].array.first { $0["profileId"].string == profile } ?? .null
    return ["account":status["account"]["id"], "endpoint":status["endpoint"], "link":link["linkId"]]
  }
  private func requireSyncExportOwner(_ window: NSWindow, identifier: NSUserInterfaceItemIdentifier?,
    number: Int, profile: String) throws {
    try Task.checkCancellation()
    try requireFocusedProfile(profile)
    guard dialogWindow() === window, window.isVisible, !window.isMiniaturized,
      window.identifier == identifier, window.windowNumber == number else {
      throw ServiceError("cancelled", "The export's browser window changed.")
    }
  }
  private func exportSyncRecovery(_ payload: ServiceJSON, profile: String, window: NSWindow,
    identifier: NSUserInterfaceItemIdentifier?, number: Int, identity: ServiceJSON,
    service: NativeSyncClient) async throws -> ServiceJSON {
    func validate() async throws {
      try requireSyncExportOwner(window, identifier:identifier, number:number, profile:profile)
      let status = await service.status(profileID:profile)
      try requireSyncExportOwner(window, identifier:identifier, number:number, profile:profile)
      guard syncExportIdentity(status, profile:profile) == identity else {
        throw ServiceError("cancelled", "The synchronization account or profile link changed.")
      }
    }
    try await validate()
    let result = try await service.handle("sync:export", payload:payload, expectedProfileID:profile)
    try await validate()
    let panel = NSSavePanel(); panel.nameFieldStringValue = "Zacro Sync Recovery.json"
    guard await NativeWindowSheet.present(panel, for:window) == .OK, let url = panel.url else {
      return ["saved":false]
    }
    try await validate()
    // The rejected operation itself can be discarded/remapped while the sheet
    // is open. Resolve it again, then recheck every owner before writing.
    let current = try await service.exportRejected(profile, id:payload["id"].string)
    try await validate()
    guard current == result else { throw ServiceError("cancelled", "This unsynced change is no longer available.") }
    try current.encoded().write(to:url,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    return ["saved":true]
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
  func cancelNativeSyncActions() {
    for task in nativeSyncTasks.values { task.cancel() }
    nativeSyncTasks.removeAll()
  }
  private func cancelSyncExports() {
    for task in syncExportTasks.values { task.cancel() }
    syncExportTasks.removeAll()
  }
  /// Invalidate synchronously when detaching a window model. The returned task
  /// is retained and can be passed to its replacement as a startup barrier.
  @discardableResult func beginShutdown() -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    let precedingReset = aiContextReset
    let retiringProfile = profileID ?? store.activeProfileID, retiringConversation = conversationID
    let presentationOnly = sharedBackend != nil
    let shutdown = Task { [self, aiService, syncService] in
      if presentationOnly {
        await precedingReset?.value
        await aiService.clearConversation(profileID:retiringProfile, conversationID:retiringConversation)
        aiContextReset = nil
        started = false; profileID = nil
        aiConversation.activate(profileID:"", isPrivate:true)
        contextTabs = []; ai = [:]; sync = [:]
      } else {
        async let ai: Void = aiService.close()
        async let sync: Void = syncService?.close() ?? ()
        _ = await (ai, sync)
      }
    }
    // No suspension occurs before this assignment, so old controls, repeated
    // close calls and start()/refreshContext() can never revive this model.
    shutdownTask = shutdown
    cancelNativeSyncActions()
    cancelSyncExports()
    aiSubmissionID = nil; aiConversation.submitting = false
    profileTask?.cancel(); profileTask = nil
    tasks.forEach { $0.cancel() }; tasks.removeAll()
    backendSubscription?.cancel(); backendSubscription = nil
    return shutdown
  }
  func shutdown() async { await beginShutdown().value }

  func close() async { await shutdown() }
}

@MainActor private final class NativePortableLibraryReader {
  var reader: ((String) async throws -> [ServiceJSON])?
  func read(_ profileID: String) async throws -> [ServiceJSON] {
    guard let reader else { throw ServiceError("EXTENSION_SYNC", "The extension library is not ready. Try again once the browser has opened.") }
    return try await reader(profileID)
  }
}
