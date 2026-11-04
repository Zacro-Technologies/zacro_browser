import AppKit
import Foundation
import ZacroCore
import ZacroServices

/// Exercises the real model/service pipeline using an in-memory HTTP transport.
/// No provider request, credential lookup, or desktop input is performed.
@MainActor
enum NativeAIModelAcceptance {
  struct Failure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func run(window: NSWindow) async throws -> [String] {
    var checks: [String] = []
    func check(_ condition: Bool, _ name: String) throws {
      guard condition else { throw Failure(message:name) }; checks.append(name)
    }
    let first = try await Fixture(window:window)
    do {
      first.store.updateSettings { $0.openSourcesLimit = 4 }
      let customLimits = NativeLibrary.aiSourceLimitOptions(first.store.state.settings.openSourcesLimit)
      try check(NativeLibrary.aiSourceLimitOptions(3).map { $0.0 } == [1, 2, 3, 5] &&
        customLimits.map { $0.0 } == [1, 2, 3, 5, 4] && customLimits.last?.1 == "4 sources" && first.store.state.settings.openSourcesLimit == 4,
        "AISourceLimitControlRetainsValidImportedValueAlongsideReferenceChoices")
      first.model.aiConversation.draft = "Keep this unfinished question"
      let answer = try await first.model.submitAIQuestion("Explicit palette question", expectedProfileID:first.profile)
      let calls = await first.transport.requests
      try check(calls.count == 1 && answer["answer"] == "Deterministic fixture answer" &&
        first.model.aiConversation.messages.last?.text == "Deterministic fixture answer",
        "explicitAskSubmitsThroughActualModelAndService")
      try check(first.model.aiConversation.draft == "Keep this unfinished question" &&
        calls[0].body?["messages"].array.last?["content"].string == "Explicit palette question",
        "explicitAskPreservesOtherDraftAndSharesNoUnapprovedPages")
      try first.model.requestAIContextReview("page", selectedIDs:[first.tabID])
      guard let proposal = first.model.aiConversation.pendingReview else { throw Failure(message:"Page review proposal") }
      try check(first.model.aiConversation.grants.isEmpty && !first.model.canSubmitAIQuestion,
        "proposedAIContextCannotBeSubmittedBeforeConfirmation")
      first.model.aiConversation.pendingReview = nil // The sheet's real Cancel binding.
      try check(first.model.aiConversation.grants.isEmpty && first.model.aiConversation.messages.count == 2,
        "cancelledAIReviewPreservesPriorConversationAndApprovals")
      try first.model.requestAIContextReview("page", selectedIDs:[first.tabID])
      guard let accepted = first.model.aiConversation.pendingReview else { throw Failure(message:"Accepted review proposal") }
      try await first.model.confirmAIContextReview(reviewID:accepted.id, selectedIDs:[first.tabID])
      let result = try await first.model.submitAIQuestion("Read only the approved page", expectedProfileID:first.profile)
      let grants = await first.context.grants
      try check(result["sharedTabs"].array.first?["id"].string == first.tabID && grants.count == 1 &&
        grants[0].id == first.tabID && grants[0].conversationID == first.store.owningWindowID,
        "confirmedAIReviewSharesExactWindowScopedPageGrant")
      do {
        try await first.model.confirmAIContextReview(reviewID:proposal.id, selectedIDs:[first.tabID])
        throw Failure(message:"Stale review was accepted")
      } catch let error as ServiceError {
        try check(error.code == "CANCELLED", "staleAIReviewCannotReplaceNewerApproval")
      }
      await first.close()
    } catch { await first.close(); throw error }

    let duplicate = try await Fixture(window:window)
    do {
      await duplicate.gate.arm()
      let request = Task { try await duplicate.model.submitAIQuestion("One request", expectedProfileID:duplicate.profile) }
      try await duplicate.gate.waitUntilEntered()
      var rejected = false
      do { _ = try await duplicate.model.submitAIQuestion("Duplicate", expectedProfileID:duplicate.profile) }
      catch let error as ServiceError { rejected = error.code == "BUSY" }
      await duplicate.gate.release()
      _ = try await request.value
      let count = await duplicate.transport.requests.count
      try check(rejected && count == 1 && duplicate.model.aiConversation.messages.count == 2,
        "duplicateAskDuringStatusAwaitCreatesOnlyOneProviderRequest")
      await duplicate.close()
    } catch { await duplicate.close(); throw error }

    for mutation in ["owner", "profile", "page", "closed-window"] {
      let fixture = try await Fixture(window:window)
      do {
        if mutation == "page" {
          try fixture.model.requestAIContextReview("page", selectedIDs:[fixture.tabID])
          guard let proposal = fixture.model.aiConversation.pendingReview else { throw Failure(message:"Review before mutation") }
          try await fixture.model.confirmAIContextReview(reviewID:proposal.id, selectedIDs:[fixture.tabID])
        }
        await fixture.gate.arm()
        let request = Task { try await fixture.model.submitAIQuestion("Reject changed authority", expectedProfileID:fixture.profile) }
        try await fixture.gate.waitUntilEntered()
        switch mutation {
        case "owner": fixture.model.dialogWindow = { nil }
        case "profile":
          _ = try fixture.store.createProfileDurably(name:"Other fixture profile")
          fixture.model.refreshContext()
        case "page": fixture.store.navigate(tabID:fixture.tabID, address:"https://fixture.invalid/changed")
        default: _ = fixture.repository.closeWindow(fixture.store.owningWindowID!)
        }
        await fixture.gate.release()
        var rejected = false
        do { _ = try await request.value } catch { rejected = true }
        let count = await fixture.transport.requests.count
        try check(rejected && count == 0 && fixture.model.aiConversation.messages.isEmpty,
          "AIRejectsChanged\(mutation)BeforeSending")
        await fixture.close()
      } catch { await fixture.close(); throw error }
    }

    let review = try await Fixture(window:window)
    do {
      try review.model.requestAIContextReview("page", selectedIDs:[review.tabID])
      guard let pending = review.model.aiConversation.pendingReview else { throw Failure(message:"Changing review") }
      review.store.navigate(tabID:review.tabID, address:"https://fixture.invalid/new-address")
      var rejected = false
      do { try await review.model.confirmAIContextReview(reviewID:pending.id, selectedIDs:[review.tabID]) }
      catch let error as ServiceError { rejected = error.code == "CONTEXT_CHANGED" }
      try check(rejected && review.model.aiConversation.grants.isEmpty,
        "AIReviewCannotApprovePageThatNavigatedSincePresentation")
      await review.close()
    } catch { await review.close(); throw error }
    let lifetime = try await Fixture(window:window), previousReset = ScopeGate()
    await previousReset.arm()
    let delayedReset = Task { await previousReset.wait() }
    try await previousReset.waitUntilEntered()
    let old = NativeServicesModel(store:lifetime.store, sharing:lifetime.model, predecessor:delayedReset)
    old.dialogWindow = { [weak window] in window }
    old.start()
    let retirement = old.beginShutdown()
    let replacement = NativeServicesModel(store:lifetime.store, sharing:lifetime.model, predecessor:retirement)
    replacement.dialogWindow = { [weak window] in window }
    replacement.start()
    var pending: Task<ServiceJSON, Error>?
    do {
      var invalidatedImmediately = false
      do { _ = try await old.aiAction("ai:status") }
      catch let error as ServiceError { invalidatedImmediately = error.code == "PROFILE_CHANGED" }
      old.start(); old.refreshContext()
      try check(invalidatedImmediately && !old.canSubmitAIQuestion,
        "retiredAIModelIsImmediatelyInvalidAndCannotRestart")
      await lifetime.transport.holdNextResponse()
      var statusResolved = false
      let request = Task {
        _ = try await replacement.aiAction("ai:status")
        statusResolved = true
        return try await replacement.submitAIQuestion("Reopened window request", expectedProfileID:lifetime.profile)
      }
      pending = request
      // Explicitly let competing actor/main-actor jobs run while the previous
      // reset is held. No sleeps are used to order the retirement itself.
      for _ in 0..<20 { await Task.yield() }
      let blockedCount = await lifetime.transport.requests.count
      try check(!statusResolved && blockedCount == 0 && !replacement.canSubmitAIQuestion,
        "reopenedAIModelWaitsForPreviousConversationRetirement")
      await previousReset.release()
      try await lifetime.transport.waitUntilHeld()
      await old.close(); await old.close()
      await lifetime.transport.releaseResponse()
      let answer = try await request.value
      let retained = await lifetime.model.aiService.status(for:AIProfileScope(id:lifetime.profile),
        conversationID:replacement.conversationID)
      try check(answer["answer"] == "Deterministic fixture answer" &&
        retained["latest"]["question"] == "Reopened window request" &&
        replacement.aiConversation.messages.last?.text == "Deterministic fixture answer",
        "repeatedOldAIModelCloseCannotCancelOrEraseReopenedRequest")
      await replacement.close(); await lifetime.close()
    } catch {
      pending?.cancel(); await previousReset.release(); await lifetime.transport.releaseResponse()
      _ = await pending?.result
      await replacement.close(); await old.close(); await lifetime.close()
      throw error
    }
    checks += try await checkNewConversation(window:window)
    checks += try await checkOrdinarySearch(window:window)
    for (name, passed) in await NativeAIAnswerScrollAcceptance.check() { try check(passed, name) }
    return checks
  }

  private static func checkNewConversation(window: NSWindow) async throws -> [String] {
    var checks: [String] = []
    func check(_ condition: Bool, _ name: String) throws {
      guard condition else { throw Failure(message:name) }; checks.append(name)
    }
    let fixture = try await Fixture(window:window)
    var pending: Task<ServiceJSON, Error>?
    do {
      let conversation = fixture.model.aiConversation
      try fixture.model.requestAIContextReview("page", selectedIDs:[fixture.tabID])
      guard let review = conversation.pendingReview else { throw Failure(message:"Reset context review") }
      try await fixture.model.confirmAIContextReview(reviewID:review.id, selectedIDs:[fixture.tabID])
      conversation.draft = "Retain my unfinished question"; conversation.savedQuestions = ["Retain the saved question"]
      await fixture.transport.holdNextResponse()
      let answering = Task { try await fixture.model.submitAIQuestion("Old approved page question", expectedProfileID:fixture.profile) }
      pending = answering
      try await fixture.transport.waitUntilHeld()
      try await fixture.model.newAIConversation(expectedProfileID:fixture.profile)
      var stopped = false
      do { _ = try await answering.value } catch { stopped = true }
      try check(stopped && conversation.messages.isEmpty && !conversation.busy && !conversation.submitting &&
        conversation.context == "research" && conversation.grants.isEmpty && conversation.pendingReview == nil &&
        conversation.contextChangeID == nil && conversation.sources.isEmpty,
        "newAIConversationCancelsActualRequestAndClearsOnlyConversationContext")
      try check(conversation.draft == "Retain my unfinished question" && conversation.savedQuestions == ["Retain the saved question"],
        "newAIConversationRetainsDraftAndSavedQuestions")
      _ = try await fixture.model.submitAIQuestion("Fresh research question", expectedProfileID:fixture.profile)
      let requests = await fixture.transport.requests
      let contents = requests.last?.body?["messages"].array.filter { $0["role"] != "system" } ?? []
      try check(contents.count == 1 && contents.first?["content"] == "Fresh research question",
        "newAIConversationDoesNotReuseEarlierPageTextOrTurns")

      // A reset waiting for actor authority must not publish to another owner.
      await fixture.gate.arm()
      let resetting = Task { try await fixture.model.newAIConversation(expectedProfileID:fixture.profile) }
      try await fixture.gate.waitUntilEntered()
      fixture.model.dialogWindow = { nil }
      await fixture.gate.release()
      var ownerRejected = false
      do { try await resetting.value } catch { ownerRejected = true }
      try check(ownerRejected && conversation.contextChangeID == nil,
        "newAIConversationRechecksExactWindowAfterActorAwait")
      await fixture.close()
    } catch {
      pending?.cancel(); await fixture.gate.release(); await fixture.transport.releaseResponse()
      _ = await pending?.result; await fixture.close(); throw error
    }

    let preflight = try await Fixture(window:window)
    await preflight.gate.arm()
    let queuedQuestion = Task { try await preflight.model.submitAIQuestion("Old queued question", expectedProfileID:preflight.profile) }
    do {
      try await preflight.gate.waitUntilEntered()
      try await preflight.model.newAIConversation(expectedProfileID:preflight.profile)
      await preflight.gate.release()
      var cancelled = false
      do { _ = try await queuedQuestion.value } catch { cancelled = true }
      let requests = await preflight.transport.requests
      try check(cancelled && requests.isEmpty && preflight.model.aiConversation.messages.isEmpty,
        "newAIConversationInvalidatesSubmissionStillAwaitingPreflight")
      await preflight.close()
    } catch {
      queuedQuestion.cancel(); await preflight.gate.release(); _ = await queuedQuestion.result
      await preflight.close(); throw error
    }

    // Closing while a reset is awaiting authority must not let that reset run
    // after the replacement model has begun using the same conversation ID.
    let lifetime = try await Fixture(window:window)
    let old = NativeServicesModel(store:lifetime.store, sharing:lifetime.model)
    old.dialogWindow = { [weak window] in window }; old.start()
    var pendingReset: Task<Void, Error>?, pendingSuccessor: Task<ServiceJSON, Error>?
    var replacementModel: NativeServicesModel?
    do {
      _ = try await old.aiAction("ai:status")
      await lifetime.gate.arm()
      let resetting = Task { try await old.newAIConversation(expectedProfileID:lifetime.profile) }
      pendingReset = resetting
      try await lifetime.gate.waitUntilEntered()
      let retirement = old.beginShutdown()
      let replacement = NativeServicesModel(store:lifetime.store, sharing:lifetime.model, predecessor:retirement)
      replacementModel = replacement
      replacement.dialogWindow = { [weak window] in window }; replacement.start()
      var resolved = false
      let successor = Task {
        _ = try await replacement.aiAction("ai:status"); resolved = true
        return try await replacement.submitAIQuestion("Replacement conversation", expectedProfileID:lifetime.profile)
      }
      pendingSuccessor = successor
      for _ in 0..<20 { await Task.yield() }
      try check(!resolved, "replacementAIModelWaitsForInFlightExplicitReset")
      await lifetime.gate.release()
      _ = await resetting.result
      let answer = try await successor.value
      await old.close()
      let retained = await lifetime.model.aiService.status(for:AIProfileScope(id:lifetime.profile), conversationID:replacement.conversationID)
      try check(answer["answer"] == "Deterministic fixture answer" &&
        retained["latest"]["question"] == "Replacement conversation" && replacement.aiConversation.messages.count == 2,
        "retiredExplicitAIResetCannotEraseReopenedConversation")
      await replacement.close(); await lifetime.close()
    } catch {
      pendingReset?.cancel(); pendingSuccessor?.cancel(); await lifetime.gate.release()
      _ = await pendingReset?.result; _ = await pendingSuccessor?.result
      await replacementModel?.close(); await old.close(); await lifetime.close(); throw error
    }
    return checks
  }

  private static func checkOrdinarySearch(window: NSWindow) async throws -> [String] {
    let fixture = try await Fixture(window:window)
    do {
      _ = try await fixture.model.aiAction("ai:configure", payload:["provider":"openai", "model":"fixture", "apiKey":"fixture-session-key", "storage":"session"])
      let query = "https://example.invalid/path?q=1 & café"
      let result = try await fixture.model.submitAIQuestion(query, expectedProfileID:fixture.profile)
      let id = result["requestId"].string
      var opened: [ServiceJSON] = []
      fixture.model.sourceAction = { action, payload in
        guard action == "ai:open-search" else { throw Failure(message:"Ordinary search used the citation action") }
        opened.append(payload); return .null
      }
      guard result["searchQuery"] == .string(query), fixture.model.ordinaryAISearchQuery(requestID:id) == query else {
        throw Failure(message:"Research fallback did not retain exact original query")
      }
      try await fixture.model.openAIOrdinarySearch(requestID:id)
      guard opened.count == 1, opened[0]["query"] == .string(query),
        opened[0]["profileId"].string == fixture.profile, opened[0]["conversationId"].string == fixture.model.conversationID else {
        throw Failure(message:"Ordinary search did not use the exact retained turn and owner")
      }
      var rejected = 0
      do { try await fixture.model.openAIOrdinarySearch(requestID:"invented-turn") } catch { rejected += 1 }
      fixture.model.dialogWindow = { nil }
      do { try await fixture.model.openAIOrdinarySearch(requestID:id) } catch { rejected += 1 }
      fixture.model.dialogWindow = { [weak window] in window }
      try await fixture.model.newAIConversation(expectedProfileID:fixture.profile)
      do { try await fixture.model.openAIOrdinarySearch(requestID:id) } catch { rejected += 1 }
      guard rejected == 3, opened.count == 1 else { throw Failure(message:"Stale ordinary search action was accepted") }
      await fixture.close()
      return ["ordinaryAISearchUsesExactOriginalResearchTurnAndOwner", "ordinaryAISearchRejectsMissingTurnWindowAndResetAnswer"]
    } catch { await fixture.close(); throw error }
  }

  @MainActor private final class Fixture {
    let directory: URL
    let repository: BrowserRepository
    let store: BrowserStore
    let model: NativeServicesModel
    let transport = Transport()
    let gate = ScopeGate()
    let context = Context()
    let profile: String
    let tabID: String
    init(window: NSWindow) async throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroAIModel-" + UUID().uuidString)
      try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
      repository = BrowserRepository(directory:directory.appendingPathComponent("browser"))
      store = repository.focusedStore; profile = store.activeProfileID
      guard let tab = store.createTab(address:"https://fixture.invalid/approved") else { throw Failure(message:"AI fixture tab") }
      tabID = tab.id
      let store = store, gate = gate, context = context
      model = NativeServicesModel(store:store, directory:directory.appendingPathComponent("services"),
        conversationProfile:{ _ in
          await gate.wait()
          return await MainActor.run {
            guard store.state.windowSessions?.contains(where:{ $0.id == store.owningWindowID && $0.isOpen }) == true else { return nil }
            return AIProfileScope(id:store.activeProfileID, isPrivate:store.state.activeProfile?.isPrivate ?? true)
          }
        }, aiTransport:transport, context:{ grants in await context.read(grants) })
      model.dialogWindow = { [weak window] in window }
      model.refreshContext()
      // Loopback-compatible mode requires no key; the injected transport never
      // opens this URL. The model still validates the real provider protocol.
      _ = try await model.aiAction("ai:configure", payload:["provider":"compatible", "baseUrl":"http://127.0.0.1:1/v1", "model":"fixture"])
      _ = try await model.aiAction("ai:status")
    }
    func close() async {
      await gate.release(); await model.close()
      try? FileManager.default.removeItem(at:directory)
    }
  }

  private actor Context {
    private(set) var grants: [AIContextGrant] = []
    func read(_ value: [AIContextGrant]) -> [AIPageExtract] {
      grants = value
      return value.map { AIPageExtract(id:$0.id,url:$0.url,title:"Fixture",text:"Only explicitly approved fixture text.") }
    }
  }
  private actor Transport: ServiceHTTPTransport {
    private(set) var requests: [ServiceHTTPRequest] = []
    private var holdResponse = false, heldResponse = false
    private var response: CheckedContinuation<Void, Never>?
    func holdNextResponse() { holdResponse = true; heldResponse = false }
    func releaseResponse() { response?.resume(); response = nil; holdResponse = false }
    func waitUntilHeld() async throws {
      for _ in 0..<1_000 {
        if heldResponse { return }
        try await Task.sleep(for:.milliseconds(5))
      }
      throw Failure(message:"Reopened AI request did not reach its fixture response gate")
    }
    func send(_ request: ServiceHTTPRequest) async throws -> ServiceHTTPResponse {
      requests.append(request)
      if holdResponse {
        holdResponse = false; heldResponse = true
        await withTaskCancellationHandler {
          await withCheckedContinuation { response = $0 }
        } onCancel: { Task { await self.releaseResponse() } }
        try Task.checkCancellation()
      }
      return ServiceHTTPResponse(status:200, body:["choices":[["message":["content":"Deterministic fixture answer"],"finish_reason":"stop"]],
        "output":[["type":"message", "content":[["type":"output_text", "text":"Deterministic fixture answer", "annotations":[]]]]]])
    }
  }
  private actor ScopeGate {
    private var armed = false, entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm() { armed = true; entered = false }
    func wait() async {
      guard armed else { return }; armed = false; entered = true
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation = $0 }
      } onCancel: { Task { await self.release() } }
    }
    func waitUntilEntered() async throws {
      for _ in 0..<1_000 {
        if entered { return }
        try await Task.sleep(for:.milliseconds(5))
      }
      throw Failure(message:"AI preflight did not reach its fixture gate")
    }
    func release() { continuation?.resume(); continuation = nil; armed = false }
  }
}
