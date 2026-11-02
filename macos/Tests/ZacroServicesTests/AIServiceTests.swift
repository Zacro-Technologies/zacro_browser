import XCTest
@testable import ZacroServices

final class AIServiceTests: XCTestCase {
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
