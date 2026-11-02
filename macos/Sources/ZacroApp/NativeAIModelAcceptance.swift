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
    return checks
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
      return ServiceHTTPResponse(status:200, body:["choices":[["message":["content":"Deterministic fixture answer"],"finish_reason":"stop"]]])
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
