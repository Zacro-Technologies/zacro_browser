import XCTest
@testable import ZacroServices

final class AIServiceTests: XCTestCase {
  func testResearchFallbackRetainsOriginalQueryAndDistinguishesSearchFailure() async throws {
    let subscription = FixtureSubscription()
    let ai = NativeAIService(directory:try directory(), currentProfile:{ AIProfileScope(id:"personal") },
      context:{ _ in [] }, secrets:MemorySecrets(), codex:subscription)
    let query = "https://example.invalid/a?x=1 & café"
    for failed in [false, true] {
      await subscription.setAnswer(["answer":"Unverified answer", "historyContent":"Unverified answer",
        "sources":[], "citations":[], "searchError":.bool(failed), "searchQuery":"Provider must not choose this"])
      let result = try await ai.handle("ai:ask", payload:["question":.string(query)], conversationID:"window-a")
      expectEqual(result["searchQuery"], .string(query))
      expectEqual(result["warning"], .string(failed
        ? "Web search did not finish successfully. This answer has no supporting sources."
        : "No supporting web sources were returned. Treat this answer as unverified."))
      expectEqual(result["mode"], "research")
      expectFalse(result.contains("searchError"))
    }
    await ai.close()
  }
  func testOrdinarySearchFallbackIsAbsentForSourcedResearchAndPageAnswers() async throws {
    let subscription = FixtureSubscription()
    let ai = NativeAIService(directory:try directory(), currentProfile:{ AIProfileScope(id:"personal") },
      context:{ grants in grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Evidence",text:"Actual page text") } },
      secrets:MemorySecrets(), codex:subscription)
    await subscription.setAnswer(["answer":"Supported answer", "historyContent":"Supported answer",
      "sources":[["title":"Evidence", "url":"https://example.com/evidence"]], "citations":[], "searchError":true,
      "searchQuery":"Untrusted injected query", "searchUrl":"https://example.invalid/provider-destination"])
    let sourced = try await ai.handle("ai:ask", payload:["question":"Research"], conversationID:"window-a")
    expectFalse(sourced.contains("searchQuery")); expectFalse(sourced.contains("searchUrl")); expectFalse(sourced.contains("warning"))
    await subscription.setAnswer(["answer":"Page evidence [1:1]", "historyContent":"Page evidence [1:1]",
      "sources":[], "citations":[], "searchError":true])
    let page = try await ai.handle("ai:ask", payload:["question":"Read page", "tabIds":["page"],
      "contextTabs":[["id":"page","url":"https://example.com/page"]]], conversationID:"window-b")
    expectEqual(page["mode"], "pages"); expectFalse(page.contains("searchQuery"))
    await ai.close()
  }
  func testGeneralChatNeverOffersOrdinaryResearchFallback() async throws {
    let transport = FixtureTransport(["choices":[["message":["content":"General knowledge"],"finish_reason":"stop"]]])
    let ai = NativeAIService(directory:try directory(), currentProfile:{ AIProfileScope(id:"personal") },
      context:{ _ in [] }, transport:transport, secrets:MemorySecrets(), codex:FixtureSubscription())
    _ = try await ai.handle("ai:configure", payload:["provider":"compatible", "baseUrl":"http://127.0.0.1:1/v1", "model":"fixture"])
    let answer = try await ai.handle("ai:ask", payload:["question":"A general question"], conversationID:"window-a")
    expectEqual(answer["mode"], "general"); expectFalse(answer.contains("searchQuery"))
    await ai.close()
  }
  func testSavedSessionOnlySubscriptionPolicyPrecedesEveryOperationAfterRestart() async throws {
    let root = try directory(), firstConnection = FixtureSubscription(), secrets = MemorySecrets()
    let first = NativeAIService(directory: root, currentProfile: { AIProfileScope(id: "personal") },
      context: { _ in [] }, secrets: secrets, codex: firstConnection)
    _ = try await first.handle("ai:configure", payload: ["authStorage":"session"])
    await first.close()
    let operations: [(String, ServiceJSON, String)] = [
      ("ai:login", [:], "login"), ("ai:test-connection", [:], "refresh"),
      ("ai:ask", ["question":"No undisclosed page context"], "run"),
      ("ai:suggest-name", ["name":"original.pdf"], "run"),
      ("ai:disconnect", [:], "logout"), ("ai:status", ["refresh":true], "refresh")]
    for (action, payload, operation) in operations {
      let connection = FixtureSubscription()
      let reopened = NativeAIService(directory: root, currentProfile: { AIProfileScope(id: "personal") },
        context: { _ in [] }, secrets: secrets, codex: connection)
      // Deliberately do not refresh status before the action: this was the
      // ordering that could start a provider in its default Keychain mode.
      _ = try await reopened.handle(action, payload: payload)
      let calls = await connection.storageOperations
      XCTAssertEqual(calls.map(\.operation), [operation], action)
      XCTAssertTrue(calls.allSatisfy { $0.storage == "session" }, action)
      await reopened.close()
    }
    let actual = NativeAIService(directory: root, currentProfile: { AIProfileScope(id: "personal") },
      context: { _ in [] }, secrets: secrets)
    expectEqual(await actual.status()["credentialStorage"], "session")
    XCTAssertEqual(secrets.reads, 0, "Restoring a storage choice must not inspect credentials")
    await actual.close()
  }

  func testWindowConversationsNeverInheritUndisplayedHistoryAndResetIsScoped() async throws {
    let subscription = FixtureSubscription()
    let ai = NativeAIService(directory: try directory(), currentProfile: { AIProfileScope(id:"personal") },
      context: { _ in [] }, codex: subscription, claude: subscription)
    let first = try await ai.handle("ai:ask", payload:["question":"Window A first"], conversationID:"window-a")
    let second = try await ai.handle("ai:ask", payload:["question":"Window B first"], conversationID:"window-b")
    expectEqual(first["conversationId"], "window-a"); expectEqual(second["conversationId"], "window-b")
    _ = try await ai.handle("ai:reset", conversationID:"window-b")
    _ = try await ai.handle("ai:ask", payload:["question":"Window A followup"], conversationID:"window-a")
    var calls = await subscription.calls
    expectEqual(calls[1].messages.count, 1)
    expectEqual(calls[1].messages[0]["content"], "Window B first")
    expectEqual(calls[2].messages.count, 3)
    expectEqual(calls[2].messages[0]["content"], "Window A first")
    expectFalse(calls[2].messages.contains { $0["content"].string.contains("Window B") })
    expectEqual(await ai.status(for:AIProfileScope(id:"personal"), conversationID:"window-b")["latest"], .null)
    expectEqual(await ai.status(for:AIProfileScope(id:"personal"), conversationID:"window-a")["latest"]["question"], "Window A followup")
    await ai.clearConversation(profileID:"personal", conversationID:"window-a")
    _ = try await ai.handle("ai:ask", payload:["question":"Reopened A"], conversationID:"window-a")
    calls = await subscription.calls
    expectEqual(calls.last?.messages.count, 1)
    await ai.close()
  }
  func testResetOrCancelInAnotherWindowDoesNotInterruptRunningAnswer() async throws {
    let subscription = FixtureSubscription(); await subscription.setDelay(.milliseconds(150))
    let ai = NativeAIService(directory: try directory(), currentProfile: { AIProfileScope(id:"personal") },
      context: { _ in [] }, codex: subscription, claude: subscription)
    let running = Task { try await ai.handle("ai:ask", payload:["question":"A request"], conversationID:"window-a") }
    for _ in 0..<100 { if await subscription.calls.count > 0 { break }; try await Task.sleep(for:.milliseconds(5)) }
    _ = try await ai.handle("ai:cancel", conversationID:"window-b")
    _ = try await ai.handle("ai:reset", conversationID:"window-b")
    expectEqual(try await running.value["conversationId"], "window-a")
    await subscription.setDelay(.seconds(5))
    let cancelled = Task { try await ai.handle("ai:ask", payload:["question":"A cancelled"], conversationID:"window-a") }
    for _ in 0..<100 { if await subscription.calls.count > 1 { break }; try await Task.sleep(for:.milliseconds(5)) }
    _ = try await ai.handle("ai:cancel", conversationID:"window-a")
    do { _ = try await cancelled.value; XCTFail("Own-window cancellation must stop its answer") }
    catch { expectEqual((error as? ServiceError)?.code, "CANCELLED") }
    await ai.close()
  }
  func testVerifiedSourcesAndLifecycleClearStayInTheirWindow() async throws {
    let subscription = FixtureSubscription(), profile = FixtureProfile()
    let ai = NativeAIService(directory:try directory(), currentProfile:{ await profile.current() }, context:{ grants in
      grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Source",text:"Actual evidence") }
    }, codex:subscription, claude:subscription)
    for window in ["a","b"] {
      _ = try await ai.handle("ai:ask", payload:["question":"Read", "tabIds":[.string(window)],
        "contextTabs":[["id":.string(window),"url":.string("https://example.com/" + window)]]], conversationID:window)
    }
    let sources = try await ai.verifiedSources(conversationID:"a")
    expectFalse(sources.isEmpty)
    expectTrue(sources.allSatisfy { $0["url"].string.hasPrefix("https://example.com/a") })
    await profile.change("other")
    await ai.clearConversation(profileID:"personal", conversationID:"a")
    await profile.change("personal")
    expectTrue(try await ai.verifiedSources(conversationID:"a").isEmpty)
    expectFalse(try await ai.verifiedSources(conversationID:"b").isEmpty)
    await ai.close()
  }
  func testBackgroundWindowStatusIsScopedAndStaleActionCannotConfigureFocusedProfile() async throws {
    let root = try directory(), profile = FixtureProfile(), subscription = FixtureSubscription()
    let ai = NativeAIService(directory: root, currentProfile: { await profile.current() }, context: { _ in [] },
      secrets: MemorySecrets(), codex: subscription, claude: subscription)
    _ = try await ai.handle("ai:configure", payload: ["provider":"openai"], expectedProfileID: "personal")
    await profile.change("other")
    _ = try await ai.handle("ai:configure", payload: ["provider":"anthropic"], expectedProfileID: "other")
    expectEqual(await ai.status(for: AIProfileScope(id: "personal"))["provider"], "openai")
    expectEqual(await ai.status()["provider"], "anthropic")
    expectEqual(try await ai.handle("ai:status", expectedProfileID: "other")["provider"], "anthropic")
    do { _ = try await ai.verifiedSources(expectedProfileID: "personal"); XCTFail("Stale source controls must not read another profile") }
    catch { expectEqual((error as? ServiceError)?.code, "PROFILE_CHANGED") }
    do {
      _ = try await ai.handle("ai:configure", payload: ["provider":"compatible"], expectedProfileID: "personal")
      XCTFail("A stale window must not configure another profile")
    } catch { expectEqual((error as? ServiceError)?.code, "PROFILE_CHANGED") }
    expectEqual(await ai.status()["provider"], "anthropic")
    expectTrue(await ai.status(for: AIProfileScope(id: "private", isPrivate: true))["private"].bool)
    await ai.close()
  }
  func testWindowAuthorityPreservesBackgroundAnswerAndUnrelatedProviderHistory() async throws {
    let focused = FixtureProfile(), owners = AIWindowOwners(), subscription = FixtureSubscription()
    await owners.set("a", profile: "personal"); await owners.set("b", profile: "other")
    let ai = NativeAIService(directory: try directory(), currentProfile: { await focused.current() },
      conversationProfile: { await owners.profile($0) }, context: { grants in
        expectEqual(grants.first?.conversationID, "a")
        return grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Evidence",text:"Approved source") }
      }, secrets: MemorySecrets(), codex: subscription, claude: subscription)
    let payload: ServiceJSON = ["question":"Read A", "tabIds":["a-tab"],
      "contextTabs":[["id":"a-tab","url":"https://example.com/a"]]]
    await subscription.setDelay(.milliseconds(120))
    let running = Task { try await ai.handle("ai:ask", payload:payload, expectedProfileID:"personal", conversationID:"a") }
    for _ in 0..<100 { if await subscription.calls.count > 0 { break }; try await Task.sleep(for:.milliseconds(5)) }
    await focused.change("other"); await ai.profileChanged()
    expectEqual(try await running.value["conversationId"], "a")
    expectFalse(try await ai.verifiedSources(expectedProfileID:"personal", conversationID:"a").isEmpty)
    _ = try await ai.handle("ai:configure", payload:["provider":"compatible","baseUrl":"http://127.0.0.1:8080/v1","model":"local"], expectedProfileID:"other", conversationID:"b")
    _ = try await ai.handle("ai:disconnect", expectedProfileID:"other", conversationID:"b")
    _ = try await ai.handle("ai:ask", payload:payload.merging(["question":"A followup"]), expectedProfileID:"personal", conversationID:"a")
    expectEqual(await subscription.calls.last?.messages.count, 3)
    expectEqual(try await ai.handle("ai:status", expectedProfileID:"personal", conversationID:"a")["provider"], "codex")
    expectFalse(try await ai.verifiedSources(expectedProfileID:"personal", conversationID:"a").isEmpty)
    await ai.close()
  }
  func testWindowAuthorityRejectsMissingChangedPrivateAndClosedOwners() async throws {
    let owners = AIWindowOwners(), subscription = FixtureSubscription()
    await owners.set("a", profile:"personal")
    let ai = NativeAIService(directory:try directory(), currentProfile:{ AIProfileScope(id:"personal") },
      conversationProfile:{ await owners.profile($0) }, context:{ grants in
        await owners.set("a", profile:"other")
        return grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Page",text:"Must not transmit") }
      }, codex:subscription, claude:subscription)
    do {
      _ = try await ai.handle("ai:ask", payload:["question":"Guess"], expectedProfileID:"personal", conversationID:"missing")
      XCTFail("A profile string cannot authorize an unknown window")
    } catch { expectEqual((error as? ServiceError)?.code, "PRIVATE") }
    do {
      _ = try await ai.handle("ai:ask", payload:["question":"Read","tabIds":["one"],"contextTabs":[["id":"one","url":"https://example.com/"]]], expectedProfileID:"personal", conversationID:"a")
      XCTFail("The approved owner changed before transmission")
    } catch { expectEqual((error as? ServiceError)?.code, "PROFILE_CHANGED") }
    expectTrue(await subscription.calls.isEmpty)
    await owners.set("a", profile:"private", isPrivate:true)
    do { _ = try await ai.handle("ai:ask", payload:["question":"Private"], conversationID:"a"); XCTFail("Private owner must fail") }
    catch { expectEqual((error as? ServiceError)?.code, "PRIVATE") }
    await owners.set("a", profile:"personal"); await subscription.setDelay(.seconds(5))
    let running = Task { try await ai.handle("ai:ask", payload:["question":"Closing window"], conversationID:"a") }
    for _ in 0..<100 { if await subscription.calls.count > 0 { break }; try await Task.sleep(for:.milliseconds(5)) }
    await owners.remove("a"); await ai.profileChanged()
    do { _ = try await running.value; XCTFail("Closing the actual owner must stop its answer") }
    catch { expectEqual((error as? ServiceError)?.code, "CANCELLED") }
    expectEqual(await ai.status(for:AIProfileScope(id:"personal"), conversationID:"a")["latest"], .null)
    await ai.close()
  }
  func testSubscriptionLogoutResetsEveryAffectedProfileButPreservesAnotherProvider() async throws {
    let owners = AIWindowOwners(), codex = FixtureSubscription(), claude = FixtureSubscription()
    for name in ["a","b","c"] { await owners.set(name, profile:name) }
    let ai = NativeAIService(directory:try directory(), currentProfile:{ AIProfileScope(id:"a") },
      conversationProfile:{ await owners.profile($0) }, context:{ _ in [] }, codex:codex, claude:claude)
    _ = try await ai.handle("ai:configure", payload:["provider":"claude-code"], conversationID:"b")
    for name in ["a","b","c"] { _ = try await ai.handle("ai:ask", payload:["question":.string(name)], conversationID:name) }
    let events = await ai.events(); var reader = events.makeAsyncIterator()
    _ = try await ai.handle("ai:disconnect", conversationID:"a")
    var resetProfiles = Set<String>()
    for _ in 0..<2 { if let event = await reader.next() { expectEqual(event["type"], "ai:reset"); resetProfiles.insert(event["profileId"].string) } }
    expectEqual(resetProfiles, ["a","c"])
    for name in ["a","c"] { expectEqual(await ai.status(for:AIProfileScope(id:name), conversationID:name)["latest"], .null) }
    _ = try await ai.handle("ai:ask", payload:["question":"B followup"], conversationID:"b")
    expectEqual(await claude.calls.last?.messages.count, 3)
    await ai.close()
  }
  func testConnectionChecksOwnCancellationAcrossEveryLifecycleBoundary() async throws {
    for boundary in ["cancel","reset","close","profile","caller"] {
      let transport = CancellableConnectionTransport(), profile = FixtureProfile()
      let ai = NativeAIService(directory:try directory(), currentProfile:{ await profile.current() }, context:{ _ in [] },
        transport:transport, secrets:MemorySecrets(), codex:FixtureSubscription(), claude:FixtureSubscription())
      _ = try await ai.handle("ai:configure", payload:["provider":"compatible","baseUrl":"http://127.0.0.1:8080/v1","model":"local"])
      let running = Task { try await ai.handle("ai:test-connection", conversationID:"a") }
      for _ in 0..<100 { if await transport.calls > 0 { break }; try await Task.sleep(for:.milliseconds(5)) }
      expectEqual(await transport.calls, 1)
      _ = try await ai.handle("ai:cancel", conversationID:"b")
      _ = try await ai.handle("ai:reset", conversationID:"b")
      expectEqual(await transport.cancelled, 0)
      expectTrue(await ai.status()["busy"].bool)
      let started = Date()
      switch boundary {
      case "cancel": _ = try await ai.handle("ai:cancel", conversationID:"a")
      case "reset": await ai.clearConversation(profileID:"personal", conversationID:"a")
      case "close": await ai.close()
      case "profile": await profile.change("private",privateMode:true); await ai.profileChanged()
      default: running.cancel()
      }
      do { _ = try await running.value; XCTFail("Connection check survived \(boundary)") }
      catch { expectEqual((error as? ServiceError)?.code, "CANCELLED") }
      XCTAssertLessThan(Date().timeIntervalSince(started), 1, boundary)
      expectEqual(await transport.cancelled, 1)
      expectFalse(await ai.status()["busy"].bool)
      if ["cancel","reset","caller"].contains(boundary) {
        await transport.setDelay(.zero)
        expectTrue(try await ai.handle("ai:test-connection", conversationID:"a")["ok"].bool)
      }
      await ai.close()
    }
  }
  func testPrivacyResetClearsEveryWindowOfProfileAndCancelsOnlyItsRequest() async throws {
    let owners = AIWindowOwners(), subscription = FixtureSubscription()
    await owners.set("a",profile:"personal"); await owners.set("b",profile:"personal"); await owners.set("c",profile:"other")
    let ai = NativeAIService(directory:try directory(),currentProfile:{ AIProfileScope(id:"personal") },
      conversationProfile:{ await owners.profile($0) },context:{ grants in
        grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Page",text:"Evidence that privacy clearing must forget") }
      },codex:subscription,claude:subscription)
    for window in ["a","b","c"] {
      _ = try await ai.handle("ai:ask",payload:["question":"Read","tabIds":[.string(window)],
        "contextTabs":[["id":.string(window),"url":.string("https://example.com/" + window)]]],conversationID:window)
    }
    await subscription.setDelay(.seconds(5))
    let running = Task { try await ai.handle("ai:ask",payload:["question":"Pending","requestId":"pending"],conversationID:"b") }
    for _ in 0..<100 { if await subscription.calls.count == 4 { break }; try await Task.sleep(for:.milliseconds(5)) }
    let events = await ai.events(); var reader = events.makeAsyncIterator()
    await ai.clearProfileConversations(profileID:"personal")
    let receivedReset = await reader.next()
    let reset = try XCTUnwrap(receivedReset)
    expectEqual(reset["type"], "ai:reset"); expectEqual(reset["profileId"], "personal")
    expectEqual(reset["cancelledRequestId"], "pending"); expectFalse(reset.contains("conversationId"))
    do { _ = try await running.value; XCTFail("Privacy reset must cancel its pending extraction/answer") }
    catch { expectEqual((error as? ServiceError)?.code,"CANCELLED") }
    for window in ["a","b"] {
      expectTrue(try await ai.verifiedSources(expectedProfileID:"personal",conversationID:window).isEmpty)
      expectEqual(await ai.status(for:AIProfileScope(id:"personal"),conversationID:window)["latest"],.null)
    }
    expectFalse(try await ai.verifiedSources(expectedProfileID:"other",conversationID:"c").isEmpty)
    expectEqual(await ai.status(for:AIProfileScope(id:"other"),conversationID:"c")["latest"]["question"],"Read")
    await ai.close()
  }
  func testResetAcknowledgementOrdersQueuedEventsBeforeRetryAnswers() async throws {
    let subscription = FixtureSubscription()
    let ai = NativeAIService(directory:try directory(),currentProfile:{ AIProfileScope(id:"personal") },context:{ _ in [] },
      codex:subscription,claude:subscription)
    let stream = await ai.events(); var reader = stream.makeAsyncIterator()
    let acknowledged = try await ai.handle("ai:reset",conversationID:"a")
    // Delivery may be delayed until after the caller starts its next question.
    let answer = try await ai.handle("ai:ask",payload:["question":"Retry","requestId":"retry"],conversationID:"a")
    let receivedDelayed = await reader.next()
    let delayed = try XCTUnwrap(receivedDelayed)
    expectEqual(delayed, acknowledged)
    expectTrue(acknowledged["resetRevision"].int > 0)
    expectEqual(answer["resetRevision"], acknowledged["resetRevision"])
    expectEqual(await ai.status(for:AIProfileScope(id:"personal"),conversationID:"a")["latestReset"], acknowledged)
    await ai.clearProfileConversations(profileID:"personal")
    let next = await ai.status(for:AIProfileScope(id:"personal"),conversationID:"a")["latestReset"]
    expectGreater(next["resetRevision"].int, acknowledged["resetRevision"].int)
    expectEqual(next["cancelledRequestId"], .null)
    expectEqual(await ai.status(for:AIProfileScope(id:"personal"),conversationID:"b")["latestReset"], next)
    await ai.close()
  }
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroServicesTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
  }
  func testEndpointAndCredentialScope() async throws {
    XCTAssertThrowsError(try AIValidation.endpoint(.openai,"https://evil.example/v1"))
    XCTAssertThrowsError(try AIValidation.endpoint(.compatible,"http://example.com/v1"))
    XCTAssertThrowsError(try AIValidation.endpoint(.compatible,"https://user:password@example.com/v1"))
    expectEqual(try AIValidation.endpoint(.compatible,"http://127.0.0.1:8080/v1/"),"http://127.0.0.1:8080/v1")
    let root = try directory(), secrets = MemorySecrets(), vault = AICredentialVault(directory:root,store:secrets)
    let a = AICredentialVault.id(profile:"a",provider:.compatible,endpoint:"https://one.example/v1")
    let b = AICredentialVault.id(profile:"a",provider:.compatible,endpoint:"https://two.example/v1")
    _ = await vault.status(a); expectEqual(secrets.reads,0)
    try await vault.set(a,key:"secret-one",storage:"encrypted")
    expectEqual(try await vault.get(b),"")
    try await vault.set(b,key:"secret-two",storage:"session")
    let bytes = try Data(contentsOf:root.appendingPathComponent("ai-credentials-index.json"))
    expectFalse(String(decoding:bytes,as:UTF8.self).contains("secret"))
    try await vault.forgetProfile("a")
    expectEqual(try await vault.get(a),""); expectEqual(try await vault.get(b),"")
  }
  func testUnavailableKeychainNeverFallsBackToPlaintext() async throws {
    let root = try directory(), secrets = MemorySecrets(); secrets.unavailable = true
    let vault = AICredentialVault(directory:root,store:secrets), id = AICredentialVault.id(profile:"p",provider:.openai,endpoint:NativeAIProvider.openai.endpoint)
    do { try await vault.set(id,key:"secret",storage:"encrypted"); XCTFail("Expected protected storage failure") } catch { }
    expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("ai-credentials-index.json").path))
    try await vault.set(id,key:"session-secret",storage:"session")
    expectEqual(try await vault.get(id),"session-secret")
  }
  func testCorruptCredentialIndexCannotAcknowledgeProtectedKeyDeletion() async throws {
    let root = try directory(), secrets = MemorySecrets()
    let original = AICredentialVault(directory: root, store: secrets)
    let own = AICredentialVault.id(profile: "removed", provider: .openai, endpoint: NativeAIProvider.openai.endpoint)
    let other = AICredentialVault.id(profile: "retained", provider: .openai, endpoint: NativeAIProvider.openai.endpoint)
    try await original.set(own, key: "fixture-deleted-profile", storage: "encrypted")
    try await original.set(other, key: "fixture-other-profile", storage: "encrypted")
    let file = root.appendingPathComponent("ai-credentials-index.json")
    let valid = try Data(contentsOf: file)
    let key = "ai:" + ServiceFiles.hash(root.standardizedFileURL.path) + ":" + own
    let protected = try secrets.read(key)
    for invalid in ["not JSON", #"{"version":1,"keys":{}}"#, #"{"version":1,"keys":["invalid"]}"#, #"{"version":1,"keys":[false]}"#] {
      let corrupted = Data(invalid.utf8)
      try corrupted.write(to: file)
      let reopened = AICredentialVault(directory: root, store: secrets)
      do { try await reopened.remove(own); XCTFail("An unreadable index cannot confirm disconnect") } catch { }
      do { try await reopened.forgetProfile("removed"); XCTFail("An unreadable index cannot confirm profile cleanup") } catch { }
      do { try await reopened.set(own, key: "replacement", storage: "encrypted"); XCTFail("An unreadable index must not be overwritten") } catch { }
      XCTAssertEqual(try secrets.read(key), protected)
      XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }
    // Recovery makes the same cleanup retry succeed without deleting another
    // profile's protected key. No real Keychain item is involved.
    try valid.write(to: file)
    let recovered = AICredentialVault(directory: root, store: secrets)
    try await recovered.forgetProfile("removed")
    XCTAssertNil(try secrets.read(key))
    expectEqual(try await recovered.get(other), "fixture-other-profile")
  }
  func testCorruptCredentialIndexStillAllowsEphemeralConnectionWithoutStorageAccess() async throws {
    let root = try directory(), secrets = MemorySecrets()
    let file = root.appendingPathComponent("ai-credentials-index.json"), corrupted = Data("unreadable".utf8)
    try corrupted.write(to: file)
    secrets.unavailable = true
    let vault = AICredentialVault(directory: root, store: secrets)
    let id = AICredentialVault.id(profile: "session", provider: .openai, endpoint: NativeAIProvider.openai.endpoint)
    try await vault.set(id, key: "ephemeral-fixture", storage: "session")
    expectEqual(try await vault.get(id), "ephemeral-fixture")
    expectEqual(await vault.status(id)["credentialStorage"], "session")
    XCTAssertEqual(secrets.reads, 0)
    XCTAssertEqual(try Data(contentsOf: file), corrupted)
    await vault.close()
    expectEqual(await vault.status(id)["configured"], false)
  }
  func testOfficialRequestBodiesAndNoFallback() async throws {
    let transport = FixtureTransport(["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"Answer"]]]]])
    let client = NativeAPIClient(transport:transport)
    _ = try await client.run(provider:.openai,baseURL:NativeAIProvider.openai.endpoint,model:"gpt-5-mini",key:"fixture",instructions:"rules",messages:[["role":"user","content":"Question"]],research:true)
    let calls = await transport.calls
    let request = try XCTUnwrap(calls.first)
    expectEqual(request.url.path,"/v1/responses"); expectEqual(request.headers["Authorization"],"Bearer fixture")
    expectEqual(request.body?["store"],false); expectEqual(request.body?["tools"].array.first?["type"],"web_search")
    expectEqual(request.body?["max_output_tokens"],4096)
  }
  func testProviderParsersRejectToolsAndIncompleteAnswers() throws {
    XCTAssertThrowsError(try NativeAPIClient.parse(provider:.openai,data:["status":"incomplete","output":[]]))
    XCTAssertThrowsError(try NativeAPIClient.parse(provider:.openai,data:["output":[["type":"function_call","name":"read_file"]]]))
    XCTAssertThrowsError(try NativeAPIClient.parse(provider:.anthropic,data:["content":[["type":"tool_use"]]]))
    let parsed = try NativeAPIClient.parse(provider:.compatible,data:["choices":[["message":["content":"See https://made-up.example","function_call":.null],"finish_reason":"stop"]],"usage":["total_tokens":"not numeric"]])
    expectTrue(parsed["sources"].array.isEmpty); expectTrue(parsed["usage"].object.isEmpty)
  }
  func testVerifiedCodexLinksOnlyAndActualPDFCitations() throws {
    let parsed = try CodexSubscription.answer([
      ["type":"webSearch","action":["url":"https://evidence.example/page","title":"Evidence"]],
      ["type":"agentMessage","text":"[Real](https://evidence.example/page) [Invented](https://invented.example)"]])
    expectEqual(parsed["sources"].array.count,1); expectEqual(parsed["citations"].array.count,1)
    let citations = NativeAIService.pageCitations("True [1:1] Wrong [2:1]",pages:[["id":"tab","url":"https://example.com/a.pdf","title":"PDF","paragraphs":["Fact"],"paragraphPages":[7]]])
    expectEqual(citations["citations"].array.count,1); expectEqual(citations["citations"].array[0]["page"],7)
  }
  func testExplicitContextDisablesResearchAndNavigationResetsHistory() async throws {
    let root = try directory(), profile = FixtureProfile(), subscription = FixtureSubscription()
    let ai = NativeAIService(directory:root,currentProfile:{ await profile.current() },context:{ grants in
      grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Page",text:"Actual evidence") }
    },codex:subscription,claude:subscription)
    _ = try await ai.handle("ai:ask",payload:["question":"Research","requestId":"research"])
    _ = try await ai.handle("ai:ask",payload:["question":"Read","requestId":"page","tabIds":["one"],"contextTabs":[["id":"one","url":"https://example.com/one"]]])
    _ = try await ai.handle("ai:ask",payload:["question":"Read again","requestId":"changed","tabIds":["one"],"contextTabs":[["id":"one","url":"https://example.com/two"]]])
    let calls = await subscription.calls
    expectEqual(calls.count,3); expectTrue(calls[0].research); expectFalse(calls[1].research)
    expectEqual(calls[1].messages.count,1); expectEqual(calls[2].messages.count,1)
    expectTrue(calls[1].messages[0]["content"].string.contains("Actual evidence"))
    await ai.close()
  }
  func testProviderSwitchCancelsPriorLoginOnlyAfterDurableConfiguration() async throws {
    let root = try directory(), codex = FixtureSubscription(), claude = FixtureSubscription()
    let ai = NativeAIService(directory:root,currentProfile:{ AIProfileScope(id:"personal") },context:{ _ in [] },codex:codex,claude:claude)
    _ = try await ai.handle("ai:login")
    expectTrue(await codex.status()["loginPending"].bool)
    _ = try await ai.handle("ai:configure",payload:["provider":"claude-code"])
    expectFalse(await codex.status()["loginPending"].bool); expectEqual(await codex.cancelLoginCount,1)
    _ = try await ai.handle("ai:login")
    let file = root.appendingPathComponent("ai-preferences.json")
    try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    do { _ = try await ai.handle("ai:configure",payload:["provider":"openai"]); XCTFail("Configuration write must fail") } catch {}
    expectEqual(await ai.status()["provider"],"claude-code")
    expectTrue(await claude.status()["loginPending"].bool); expectEqual(await claude.cancelLoginCount,0)
    await ai.close()
  }
  func testCodexStartupFailureClearsPendingSignInAndCanBeRetried() async throws {
    let connection = CodexSubscription(directory:try directory(),executable:URL(fileURLWithPath:"/usr/bin/false"))
    for _ in 0..<2 {
      do { _ = try await connection.login(); XCTFail("The fixture process cannot initialize a provider") } catch {}
      expectFalse(await connection.status()["loginPending"].bool)
    }
    await connection.close()
  }
  func testContextAndProfileChangesPreventTransmission() async throws {
    let profile = FixtureProfile(), subscription = FixtureSubscription()
    let ai = NativeAIService(directory:try directory(),currentProfile:{ await profile.current() },context:{ grants in
      await profile.change("other")
      return grants.map { AIPageExtract(id:$0.id,url:$0.url,title:"Page",text:"Must not transmit") }
    },codex:subscription,claude:subscription)
    do { _ = try await ai.handle("ai:ask",payload:["question":"Read","tabIds":["one"],"contextTabs":[["id":"one","url":"https://example.com"]]]); XCTFail("Expected changed profile") } catch { }
    expectTrue(await subscription.calls.isEmpty)
    await ai.close()
  }
  func testCancellationDoesNotPublishCompletedAnswer() async throws {
    let subscription = FixtureSubscription(); await subscription.setDelay(.seconds(5))
    let ai = NativeAIService(directory:try directory(),currentProfile:{ AIProfileScope(id:"personal") },context:{ _ in [] },codex:subscription,claude:subscription)
    let task = Task { try await ai.handle("ai:ask",payload:["question":"Question","requestId":"cancelled"]) }
    try await Task.sleep(for:.milliseconds(30)); _ = try await ai.handle("ai:cancel")
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    expectEqual(await ai.status()["latest"],.null); await ai.close()
  }
  func testFilenameAndProcessIsolation() {
    expectEqual(NativeAIService.sanitizedFilename("../../report.txt",original:"download.pdf"),"report.pdf")
    expectEqual(NativeAIService.sanitizedFilename("CON",original:"image.png"),"download.png")
    let environment = ProviderProcessPolicy.environment(home:URL(fileURLWithPath:"/isolated"),provider:.codex)
    expectEqual(environment["HOME"],"/isolated"); XCTAssertNil(environment["OPENAI_API_KEY"]); XCTAssertNil(environment["NODE_OPTIONS"])
    expectEqual(CodexSubscription.configuration(storage:"session")["cli_auth_credentials_store"],"ephemeral")
    expectEqual(CodexSubscription.configuration(storage:"keyring")["features.shell_tool"],false)
  }
  func testProfileLifecycleCancelsAnswerAfterEnteringPrivateAndClearsVerifiedSources() async throws {
    let profile = FixtureProfile(), subscription = FixtureSubscription()
    let ai = NativeAIService(directory: try directory(), currentProfile: { await profile.current() }, context: { grants in
      grants.map { AIPageExtract(id: $0.id, url: $0.url, title: "Evidence", text: "A verified paragraph") }
    }, codex: subscription, claude: subscription)
    let payload: ServiceJSON = ["question":"Read", "requestId":"first", "tabIds":["one"], "contextTabs":[["id":"one","url":"https://example.com/evidence"]]]
    _ = try await ai.handle("ai:ask", payload: payload)
    expectFalse(try await ai.verifiedSources().isEmpty)
    await subscription.setDelay(.seconds(5))
    let running = Task { try await ai.handle("ai:ask", payload: payload.merging(["requestId":"second"])) }
    try await Task.sleep(for: .milliseconds(30))
    await profile.change("private", privateMode: true)
    await ai.profileChanged()
    do { _ = try await running.value; XCTFail("Expected profile lifecycle cancellation") } catch { }
    let status = await ai.status()
    expectEqual(status["private"], true)
    expectEqual(status["configured"], false)
    expectEqual(status["latest"], .null)
    do { _ = try await ai.verifiedSources(); XCTFail("Private profile cannot access sources") } catch { }
    await profile.change("personal")
    await ai.profileChanged()
    expectTrue(try await ai.verifiedSources().isEmpty)
    expectEqual(await ai.status()["latest"], .null)
    await ai.close()
  }

  func testOwnedCommandShutdownWaitsForChildExitWithoutItsNormalTimeout() async throws {
    let command = OwnedProviderCommand(), root = try directory()
    let running = Task { try await command.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], home: root, provider: .codex, timeout: 40) }
    try await Task.sleep(for: .milliseconds(40))
    let start = Date()
    await command.shutdown()
    do { _ = try await running.value; XCTFail("Expected owned process cancellation") }
    catch let error as ServiceError { expectEqual(error.code, "CANCELLED") }
    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    await command.shutdown()
  }

  func testBundledCodexSessionHandshakeAndShutdownWithoutSignInOrInference() async throws {
    guard let path = ProcessInfo.processInfo.environment["ZACRO_TEST_CODEX_EXECUTABLE"], FileManager.default.isExecutableFile(atPath: path) else {
      throw XCTSkip("Set ZACRO_TEST_CODEX_EXECUTABLE to verify the packaged native provider without signing in or making inference requests.")
    }
    let provider = CodexSubscription(directory: try directory(), executable: URL(fileURLWithPath: path))
    do {
      try await provider.setStorage("session")
      let status = try await provider.refresh()
      expectEqual(status["available"], true)
      expectEqual(status["configured"], false)
      expectEqual(status["credentialStorage"], "session")
      expectTrue(status["models"].array.isEmpty)
      let stopping = Date(); await provider.close()
      XCTAssertLessThan(Date().timeIntervalSince(stopping), 3)
    } catch { await provider.close(); throw error }
  }

  func testRPCBackpressureCannotBlockShutdownOrRaiseSIGPIPE() async throws {
    let connection = ProviderRPC { _ in }
    try await connection.start(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], home: try directory())
    let pending = Task { try await connection.call("blocked-input", ["blob":.string(String(repeating: "x", count: 512_000))], timeout: 0.3) }
    try await Task.sleep(for: .milliseconds(60))
    let stopping = Date(); await connection.stop()
    XCTAssertLessThan(Date().timeIntervalSince(stopping), 3)
    do { _ = try await pending.value; XCTFail("Expected connection shutdown to reject pending request") } catch { }
    await connection.stop()
  }

}

private actor AIWindowOwners {
  private var profiles: [String:AIProfileScope] = [:]
  func set(_ window: String, profile: String, isPrivate: Bool = false) { profiles[window] = AIProfileScope(id:profile,isPrivate:isPrivate) }
  func remove(_ window: String) { profiles.removeValue(forKey:window) }
  func profile(_ window: String) -> AIProfileScope? { profiles[window] }
}
private actor CancellableConnectionTransport: ServiceHTTPTransport {
  private(set) var calls = 0, cancelled = 0
  private var delay: Duration = .seconds(5)
  func setDelay(_ value: Duration) { delay = value }
  func send(_ request: ServiceHTTPRequest) async throws -> ServiceHTTPResponse {
    calls += 1
    do { try await Task.sleep(for:delay) }
    catch { if Task.isCancelled { cancelled += 1 }; throw error }
    return ServiceHTTPResponse(status:200,body:["data":[["id":"local"]]])
  }
}
