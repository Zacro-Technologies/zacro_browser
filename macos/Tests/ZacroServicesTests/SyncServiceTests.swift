import XCTest
@testable import ZacroServices

final class SyncServiceTests: XCTestCase {
  func testWindowStatusDoesNotChangeFocusAndStaleControlsCannotMutateAccount() async throws {
    let root = try directory(), current = FixtureProfile(), server = FixtureSyncServer()
    let client = try NativeSyncClient(directory: root,
      getProfile: { id in id == "missing" ? nil : AIProfileScope(id: id, isPrivate: id == "private") },
      activeProfile: { await current.current() }, transport: server, secrets: MemorySecrets(), autoSync: false)
    _ = try await client.handle("sync:configure", payload: ["endpoint":"https://sync.example"], expectedProfileID: "personal")
    await current.change("other")
    expectEqual(await client.status(profileID: "personal")["endpoint"], "https://sync.example")
    expectEqual(await current.current().id, "other")
    expectEqual(await client.status(profileID: "private")["state"], "private")
    expectEqual(await client.status(profileID: "missing")["state"], "private")
    do {
      _ = try await client.handle("sync:configure", payload: ["endpoint":"https://wrong.example"], expectedProfileID: "personal")
      XCTFail("A stale window must not change shared account configuration")
    } catch { expectEqual((error as? ServiceError)?.code, "cancelled") }
    expectEqual(await client.status()["endpoint"], "https://sync.example")
    await client.close()
  }
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZacroSyncTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return root
  }
  private func client(_ root: URL, server: FixtureSyncServer, secrets: MemorySecrets = MemorySecrets()) throws -> NativeSyncClient {
    try NativeSyncClient(directory:root,getProfile:{ id in AIProfileScope(id:id,isPrivate:id == "private") },activeProfile:{ AIProfileScope(id:"personal") },transport:server,secrets:secrets,autoSync:false)
  }
  private let context = ExtensionStorageContext(profileID:"personal",extensionID:FixtureSyncServer.extensionID,permissions:["storage"],trusted:true)
  private var item: ServiceJSON { ["extensionId":.string(FixtureSyncServer.extensionID),"source":["kind":"web-store","id":.string(FixtureSyncServer.extensionID)],"state":"enabled"] }
  private func signIn(_ client: NativeSyncClient, name: String = "account") async throws {
    _ = try await client.configure(endpoint:"https://sync.example")
    _ = try await client.authenticate("login",fields:["username":.string(name),"password":"fixture-only-password","deviceName":"Fixture"])
  }
  private func link(_ client: NativeSyncClient, settings: Bool = true) async throws {
    _ = try await client.linkProfile("personal",options:["datasetId":"dataset","libraryChoice":"merge-local","localLibrary":[item],"settingsSync":.bool(settings),"settingsConsent":.bool(settings),"settingsChoice":"upload-local"])
  }
  func testNativeBaselineRecoversLocalCommitLostDuringDiskFailureAndProcessDeath() async throws {
    let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
    let first = try client(root,server:server,secrets:secrets)
    try await signIn(first); try await first.seedNativeStorage(context,values:["choice":"before"])
    try await link(first); _ = await first.syncNow()
    let file = root.appendingPathComponent("sync-client.json"), saved = try Data(contentsOf:file)
    try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    do { try await first.observeNativeStorageChanges(context,changes:["choice":["newValue":"accepted by Chromium"]]); XCTFail("Expected disk failure") } catch {}
    await first.close(); try FileManager.default.removeItem(at:file); try saved.write(to:file)
    let reopened = try client(root,server:server,secrets:secrets); await reopened.start()
    expectTrue(try await reopened.reconcileNativeSnapshot(context,values:["choice":"accepted by Chromium"]))
    expectEqual(try await reopened.nativeStorageValues(context),["choice":"accepted by Chromium"])
    expectEqual(await reopened.status()["profiles"].array[0]["pending"],1)
    expectFalse(try await reopened.reconcileNativeSnapshot(context,values:["choice":"accepted by Chromium"]))
    expectEqual(await reopened.status()["profiles"].array[0]["pending"],1)
    await reopened.close()
  }
  func testNativeRemoteMarkerRecoversBothSidesOfCommitWithoutEcho() async throws {
    for didApply in [false,true] {
      let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
      let first = try client(root,server:server,secrets:secrets)
      try await signIn(first); try await first.seedNativeStorage(context,values:["choice":"local"])
      try await link(first); _ = await first.syncNow()
      _ = try await first.callStorage(context,method:"set",args:[["choice":"remote"]])
      let projections = try await first.nativeStorageProjections(profileID:"personal"), projection = try XCTUnwrap(projections.first)
      let token = try await first.beginNativeStorageApply(context,projection:projection,expectedValues:["choice":"local"])
      if didApply {
        // Acknowledgement cannot be saved, although Chromium committed target.
        let file = root.appendingPathComponent("sync-client.json"), saved = try Data(contentsOf:file)
        try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        do { try await first.completeNativeStorageApply(context,token:token); XCTFail("Expected failed acknowledgement") } catch {}
        try FileManager.default.removeItem(at:file); try saved.write(to:file)
      }
      await first.close()
      let reopened = try client(root,server:server,secrets:secrets); await reopened.start()
      let actual: ServiceJSON = ["choice":didApply ? "remote" : "local"]
      expectTrue(try await reopened.reconcileNativeSnapshot(context,values:actual))
      expectEqual(try await reopened.nativeStorageValues(context),["choice":"remote"])
      expectEqual(await reopened.status()["profiles"].array[0]["pending"],1)
      do { try await reopened.completeNativeStorageApply(context,token:token); XCTFail("Recovered token must be retired") } catch {}
      expectFalse(try await reopened.reconcileNativeSnapshot(context,values:actual))
      await reopened.close()
    }
  }
  func testNativeAmbiguousCrashPreservesLocalDataUntilReviewedChoice() async throws {
    for useLocal in [true,false] {
      let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
      let first = try client(root,server:server,secrets:secrets)
      try await signIn(first); try await first.seedNativeStorage(context,values:["choice":"local"])
      try await link(first); _ = await first.syncNow()
      _ = try await first.callStorage(context,method:"set",args:[["choice":"remote"]])
      let projections = try await first.nativeStorageProjections(profileID:"personal")
      _ = try await first.beginNativeStorageApply(context,projection:try XCTUnwrap(projections.first),expectedValues:["choice":"local"])
      await first.close()
      let reopened = try client(root,server:server,secrets:secrets); await reopened.start()
      let actual: ServiceJSON = ["choice":"remote","local-after-crash":true]
      do { _ = try await reopened.reconcileNativeSnapshot(context,values:actual); XCTFail("Mixed state must require review") }
      catch { expectEqual((error as? ServiceError)?.code,"NATIVE_RECOVERY") }
      expectEqual(await reopened.status()["profiles"].array[0]["pending"],1)
      try await reopened.resolveNativeStorageRecovery(context,values:actual,useLocal:useLocal)
      expectEqual(try await reopened.nativeStorageValues(context),useLocal ? actual : ["choice":"remote"])
      expectEqual(await reopened.status()["profiles"].array[0]["pending"],useLocal ? 2 : 1)
      expectFalse(try await reopened.reconcileNativeSnapshot(context,values:actual))
      await reopened.close()
      let last = try client(root,server:server,secrets:secrets); await last.start()
      expectFalse(try await last.reconcileNativeSnapshot(context,values:actual))
      expectEqual(try await last.nativeStorageValues(context),useLocal ? actual : ["choice":"remote"])
      await last.close()
    }
  }
  func testNativeRecoveryMarkerCannotStartWhenItsFileCannotBeSaved() async throws {
    let root = try directory(), client = try client(root,server:FixtureSyncServer())
    try await signIn(client); try await client.seedNativeStorage(context,values:["choice":"local"])
    try await link(client); _ = await client.syncNow()
    _ = try await client.callStorage(context,method:"set",args:[["choice":"remote"]])
    let projections = try await client.nativeStorageProjections(profileID:"personal"), projection = try XCTUnwrap(projections.first)
    let file = root.appendingPathComponent("sync-client.json"), saved = try Data(contentsOf:file)
    try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    do { _ = try await client.beginNativeStorageApply(context,projection:projection,expectedValues:["choice":"local"]); XCTFail("No native write may begin") } catch {}
    try FileManager.default.removeItem(at:file); try saved.write(to:file)
    expectFalse(try await client.reconcileNativeSnapshot(context,values:["choice":"local"]))
    let token = try await client.beginNativeStorageApply(context,projection:projection,expectedValues:["choice":"local"])
    try await client.completeNativeStorageApply(context,token:token)
    expectFalse(try await client.reconcileNativeSnapshot(context,values:["choice":"remote"]))
    await client.close()
  }
  func testNativeUninstallPrunesOldBaselineAndFreshInstallDoesNotUploadOrEraseCloudSettings() async throws {
    let client = try client(directory(),server:FixtureSyncServer())
    try await signIn(client); try await client.seedNativeStorage(context,values:["existing":"cloud"])
    try await link(client); _ = await client.syncNow()
    try await client.pruneNativeStorage(profileID:"personal",installedIDs:[])
    try await client.adoptNativeInstallation(context,values:[:])
    expectFalse(try await client.reconcileNativeSnapshot(context,values:[:]))
    expectEqual(try await client.nativeStorageValues(context),["existing":"cloud"])
    expectEqual(await client.status()["profiles"].array[0]["pending"],0)
    let projections = try await client.nativeStorageProjections(profileID:"personal")
    let token = try await client.beginNativeStorageApply(context,projection:try XCTUnwrap(projections.first),expectedValues:[:])
    try await client.completeNativeStorageApply(context,token:token)
    expectFalse(try await client.reconcileNativeSnapshot(context,values:["existing":"cloud"]))
    await client.close()
  }
  func testNativeIncarnationSurvivesUpdatesAndRecognizesReinstallAcrossRestart() async throws {
    let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
    let first = try client(root,server:server,secrets:secrets)
    let incarnation = context.extensionID + ":100", replacement = context.extensionID + ":200"
    try await signIn(first)
    try await first.adoptNativeInstallation(context,values:["choice":"initial"],incarnationID:incarnation)
    try await first.seedNativeStorage(context,values:["choice":"initial"])
    try await link(first); _ = await first.syncNow()
    try await first.observeNativeStorageChanges(context,changes:["choice":["newValue":"local"]])
    expectFalse(try await first.reconcileNativeSnapshot(context,values:["choice":"local"],incarnationID:incarnation))
    _ = try await first.callStorage(context,method:"set",args:[["choice":"remote"]])
    let projections = try await first.nativeStorageProjections(profileID:"personal")
    let projection = try XCTUnwrap(projections.first)
    let token = try await first.beginNativeStorageApply(context,projection:projection,expectedValues:["choice":"local"],incarnationID:incarnation)
    try await first.completeNativeStorageApply(context,token:token)
    expectFalse(try await first.reconcileNativeSnapshot(context,values:["choice":"remote"],incarnationID:incarnation))
    _ = await first.syncNow(); await first.close()
    let reopened = try client(root,server:server,secrets:secrets); await reopened.start()
    expectFalse(try await reopened.reconcileNativeSnapshot(context,values:["choice":"remote"],incarnationID:incarnation))
    expectTrue(try await reopened.reconcileNativeSnapshot(context,values:["fresh-default":true],incarnationID:replacement))
    expectEqual(try await reopened.nativeStorageValues(context),["choice":"remote"])
    expectEqual(await reopened.status()["profiles"].array[0]["pending"],0)
    let fresh = try await reopened.nativeStorageProjections(profileID:"personal")
    _ = try await reopened.beginNativeStorageApply(context,projection:try XCTUnwrap(fresh.first),expectedValues:["fresh-default":true],incarnationID:replacement)
    await reopened.close()
  }
  func testNativeIncarnationReplacementIsDurableBeforeDiscardingAnOldPendingWrite() async throws {
    let root = try directory(), client = try client(root,server:FixtureSyncServer())
    let old = context.extensionID + ":100", new = context.extensionID + ":200"
    try await signIn(client)
    try await client.adoptNativeInstallation(context,values:["choice":"local"],incarnationID:old)
    try await client.seedNativeStorage(context,values:["choice":"local"])
    try await link(client); _ = await client.syncNow()
    _ = try await client.callStorage(context,method:"set",args:[["choice":"remote"]])
    let projections = try await client.nativeStorageProjections(profileID:"personal"), projection = try XCTUnwrap(projections.first)
    let token = try await client.beginNativeStorageApply(context,projection:projection,expectedValues:["choice":"local"],incarnationID:old)
    let file = root.appendingPathComponent("sync-client.json"), bytes = try Data(contentsOf:file)
    try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    do { _ = try await client.reconcileNativeSnapshot(context,values:[:],incarnationID:new); XCTFail("Expected failed durable replacement") } catch {}
    try FileManager.default.removeItem(at:file); try bytes.write(to:file)
    try await client.completeNativeStorageApply(context,token:token) // old marker survived failed write
    do { _ = try await client.beginNativeStorageApply(context,projection:projection,expectedValues:["choice":"remote"],incarnationID:new); XCTFail("Stale incarnation must reject") }
    catch { expectEqual((error as? ServiceError)?.code,"NATIVE_BASELINE") }
    expectTrue(try await client.reconcileNativeSnapshot(context,values:[:],incarnationID:new))
    for invalid in ["wrong:1",context.extensionID + ":",context.extensionID + ":-1",context.extensionID + ":18446744073709551616"] {
      do { _ = try await client.reconcileNativeSnapshot(context,values:[:],incarnationID:invalid); XCTFail("Invalid identity accepted") } catch {}
    }
    await client.close()
  }
  func testNativeInstallationForgetIsScopedAndRollsBackOnFailedWrite() async throws {
    let root = try directory(), client = try client(root,server:FixtureSyncServer())
    var other = context; other.profileID = "other"
    try await client.adoptNativeInstallation(context,values:["personal":true])
    try await client.adoptNativeInstallation(other,values:["other":true])
    let file = root.appendingPathComponent("sync-client.json"), bytes = try Data(contentsOf:file)
    try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    do { try await client.forgetNativeInstallation(profileID:context.profileID,extensionID:context.extensionID); XCTFail("Expected failed cleanup") } catch {}
    try FileManager.default.removeItem(at:file); try bytes.write(to:file)
    expectFalse(try await client.reconcileNativeSnapshot(context,values:["personal":true]))
    try await client.forgetNativeInstallation(profileID:context.profileID,extensionID:context.extensionID)
    let saved = try String(contentsOf:file,encoding:.utf8)
    expectFalse(saved.contains("personal")); expectTrue(saved.contains("other"))
    do { try await client.forgetNativeInstallation(profileID:"private",extensionID:context.extensionID); XCTFail("Private cleanup must reject") } catch {}
    await client.close()
  }
  func testNativeUnchangedAndLinkedSeedsDoNotRequireAnotherDiskWrite() async throws {
    for linked in [false,true] {
      let root = try directory(), client = try client(root,server:FixtureSyncServer())
      try await client.seedNativeStorage(context,values:["saved":true])
      if linked { try await signIn(client); try await link(client); _ = await client.syncNow() }
      let file = root.appendingPathComponent("sync-client.json"), bytes = try Data(contentsOf:file)
      try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
      expectFalse(try await client.seedNativeStorage(context,values:["saved":true]))
      if linked { expectFalse(try await client.seedNativeStorage(context,values:["different":true])) }
      else {
        do { _ = try await client.seedNativeStorage(context,values:["different":true]); XCTFail("Changed local seed must still persist") } catch {}
      }
      expectEqual(try await client.nativeStorageValues(context),["saved":true])
      try FileManager.default.removeItem(at:file); try bytes.write(to:file)
      await client.close()
    }
  }
  func testLinkedNativeMigrationRequiresReviewWhenThereIsNoAcknowledgedBaseline() async throws {
    let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
    let first = try client(root,server:server,secrets:secrets)
    try await signIn(first); try await first.seedNativeStorage(context,values:["choice":"synced"])
    try await link(first); _ = await first.syncNow(); await first.close()
    let file = root.appendingPathComponent("sync-client.json")
    var legacy = try ServiceJSON.decode(Data(contentsOf:file)); legacy = legacy.removing("nativeStorage")
    try legacy.encoded().write(to:file,options:.atomic)
    let reopened = try client(root,server:server,secrets:secrets); await reopened.start()
    do { _ = try await reopened.reconcileNativeSnapshot(context,values:["choice":"local migration"]); XCTFail("Migration must preserve differing local values") }
    catch { expectEqual((error as? ServiceError)?.code,"NATIVE_RECOVERY") }
    expectEqual(await reopened.status()["profiles"].array[0]["pending"],0)
    try await reopened.resolveNativeStorageRecovery(context,values:["choice":"local migration"],useLocal:true)
    expectEqual(try await reopened.nativeStorageValues(context),["choice":"local migration"])
    expectEqual(await reopened.status()["profiles"].array[0]["pending"],1)
    await reopened.close()
  }
  func testNativeRecoveryMigrationAndProfileDeletionKeepPrivateDataOut() async throws {
    let root = try directory(), client = try client(root,server:FixtureSyncServer())
    expectFalse(try await client.reconcileNativeSnapshot(context,values:["native-only":"preserved"]))
    expectEqual(try await client.nativeStorageValues(context),[:]) // migration never uploads automatically
    var secret = context; secret.isPrivate = true
    do { _ = try await client.reconcileNativeSnapshot(secret,values:["private-secret":true]); XCTFail("Private snapshot must reject") } catch {}
    try await client.deleteLocalProfile("personal")
    let saved = try String(contentsOf:root.appendingPathComponent("sync-client.json"),encoding:.utf8)
    expectFalse(saved.contains("native-only")); expectFalse(saved.contains("private-secret"))
    await client.close()
  }
  func testNativeStorageIntakeFailureKeepsMirrorReadableAndRetriesExactlyOnce() async throws {
    let root = try directory(), client = try client(root,server:FixtureSyncServer())
    try await signIn(client); try await client.seedNativeStorage(context,values:["old":1])
    try await link(client); _ = await client.syncNow()
    let file = root.appendingPathComponent("sync-client.json"), saved = try Data(contentsOf:file)
    try FileManager.default.removeItem(at:file)
    try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    let change: ServiceJSON = ["old":["oldValue":1],"new":["newValue":2]]
    do { try await client.observeNativeStorageChanges(context,changes:change); XCTFail("Write should fail") } catch {}
    expectEqual(try await client.nativeStorageValues(context),["old":1])
    expectEqual(await client.status()["profiles"].array[0]["pending"],0)
    try FileManager.default.removeItem(at:file); try saved.write(to:file)
    try await client.observeNativeStorageChanges(context,changes:change)
    try await client.observeNativeStorageChanges(context,changes:change)
    expectEqual(try await client.nativeStorageValues(context),["new":2])
    expectEqual(await client.status()["profiles"].array[0]["pending"],1)
    await client.close()
  }
  func testNativeAtomicReplacementAllowsDisjointFullQuotaDictionaries() async throws {
    let client = try client(directory(),server:FixtureSyncServer())
    let before = ServiceJSON.object(Dictionary(uniqueKeysWithValues:(0..<512).map { ("old-\($0)",.number(Double($0))) }))
    let after = ServiceJSON.object(Dictionary(uniqueKeysWithValues:(0..<512).map { ("new-\($0)",.number(Double($0))) }))
    try await client.seedNativeStorage(context,values:before)
    let changes = SyncModel.difference(before,after)
    expectEqual(changes.object.count,1024)
    try await client.observeNativeStorageChanges(context,changes:changes)
    expectEqual(try await client.nativeStorageValues(context),after)
    await client.close()
  }
  func testNativeProjectionRemainsAvailableWithLibraryPausedAndRejectsStaleValues() async throws {
    let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
    let client = try client(root, server:server, secrets:secrets)
    try await signIn(client)
    expectTrue(try await client.seedNativeStorage(context, values:["theme":"green"]))
    try await link(client); _ = await client.syncNow()
    _ = try await client.setLibrarySync("personal", enabled:false, options:[:])
    expectTrue(try await client.extensionIntents(profileID:"personal").isEmpty)
    let available = try await client.nativeStorageProjections(profileID:"personal")
    let projection = try XCTUnwrap(available.first)
    expectEqual(projection["values"], ["theme":"green"])
    expectTrue(await client.isCurrentNativeStorageProjection(projection))
    expectFalse(try await client.seedNativeStorage(context, values:["theme":"stale"]))
    try await client.observeNativeStorageChanges(context, changes:["theme":["oldValue":"green","newValue":"blue"]])
    expectFalse(await client.isCurrentNativeStorageProjection(projection))
    await client.close()
    let reopened = try self.client(root,server:server,secrets:secrets); await reopened.start()
    let restored = try await reopened.nativeStorageProjections(profileID:"personal")
    let current = try XCTUnwrap(restored.first)
    expectEqual(current["values"],["theme":"blue"])
    expectTrue(await reopened.isCurrentNativeStorageProjection(current))
    _ = try await reopened.unlinkProfile("personal")
    expectFalse(await reopened.isCurrentNativeStorageProjection(current))
    expectTrue(try await reopened.nativeStorageProjections(profileID:"personal").isEmpty)
    await reopened.close()
  }
  func testNativeProjectionRejectsReplacedGenerationAndDisabledSettings() async throws {
    let client = try client(directory(),server:FixtureSyncServer()); try await signIn(client); try await link(client)
    let projections = try await client.nativeStorageProjections(profileID:"personal")
    let projection = try XCTUnwrap(projections.first)
    try await client.queueExtension(profileID:"personal",item:item.merging(["state":"removed"]))
    expectFalse(await client.isCurrentNativeStorageProjection(projection))
    try await client.queueExtension(profileID:"personal",item:item)
    expectFalse(await client.isCurrentNativeStorageProjection(projection))
    _ = try await client.setSettingsSync("personal",enabled:false,options:[:])
    expectTrue(try await client.nativeStorageProjections(profileID:"personal").isEmpty)
    do { _ = try await client.nativeStorageProjections(profileID:"private"); XCTFail("Private projection must reject") } catch {}
    await client.close()
  }
  func testFailedNativeLibraryReadCannotApproveAnEmptyLibraryOrLink() async throws {
    let client = try NativeSyncClient(directory:directory(),getProfile:{ AIProfileScope(id:$0) },activeProfile:{ AIProfileScope(id:"personal") },
      localLibrary:{ _ in throw ServiceError("FIXTURE","Native registry unavailable") },transport:FixtureSyncServer(),secrets:MemorySecrets(),autoSync:false)
    try await signIn(client)
    for action in ["sync:link-preview","sync:link"] {
      do {
        _ = try await client.handle(action,payload:["datasetId":"dataset","libraryChoice":"merge-local","settingsSync":false])
        XCTFail("Missing native state must abort review")
      } catch { expectEqual((error as? ServiceError)?.code,"FIXTURE") }
    }
    expectTrue(await client.status()["profiles"].array.isEmpty)
    await client.close()
  }
  func testNativeStoragePatchQueuesOneAtomicOperationWithoutEcho() async throws {
    let server = FixtureSyncServer(), client = try client(directory(), server: server)
    try await signIn(client)
    try await client.seedNativeStorage(context, values: ["keep": 1, "remove": 2])
    try await link(client); _ = await client.syncNow()
    let stream = await client.events()
    try await client.observeNativeStorageChanges(context, changes: ["new": ["newValue": 3], "remove": ["oldValue": 2]])
    var events = stream.makeAsyncIterator()
    expectEqual(await events.next()?["type"], "sync:status")
    expectEqual(await client.status()["profiles"].array[0]["pending"], 1)
    expectEqual(try await client.callStorage(context, method: "get"), ["keep": 1, "new": 3])
    _ = await client.syncNow()
    let last = await server.calls.last(where: { $0.url.path.hasSuffix("/operations") })?.body
    expectEqual(last?["operations"].array.count, 1)
    expectEqual(last?["operations"].array.first?["payload"], ["set": ["new": 3], "remove": ["remove"]])
    await client.close()
  }
  func testNativeSnapshotCannotReplaceLinkedDataAndPrivateRemoteChangesNeverRequeue() async throws {
    let client = try client(directory(), server: FixtureSyncServer())
    try await signIn(client); try await client.seedNativeStorage(context, values: ["choice": "local"])
    try await link(client); _ = await client.syncNow()
    try await client.seedNativeStorage(context, values: ["choice": "stale"])
    try await client.observeNativeStorageChanges(context, changes: ["choice": ["newValue": "remote"]], origin: "zacro.remote:12")
    try await client.observeNativeStorageChanges(context, changes: ["secret": ["newValue": true]], origin: "zacro.private")
    expectEqual(await client.status()["profiles"].array[0]["pending"], 0)
    expectEqual(try await client.callStorage(context, method: "get"), ["choice": "local"])
    var privateContext = context; privateContext.isPrivate = true
    do { try await client.seedNativeStorage(privateContext, values: ["private": true]); XCTFail("Private data must be rejected") } catch {}
    await client.close()
  }
  func testNativeAcceptedWritesDoNotSpendSecondRateQuotaAndMalformedPatchIsAtomic() async throws {
    let client = try client(directory(), server: FixtureSyncServer())
    for index in 0..<121 {
      try await client.observeNativeStorageChanges(context, changes: ["counter": ["newValue": .number(Double(index))]])
    }
    expectEqual(try await client.callStorage(context, method: "get"), ["counter": 120])
    do { try await client.observeNativeStorageChanges(context, changes: ["counter": [:]]); XCTFail("Empty delta must be rejected") } catch {}
    do { try await client.observeNativeStorageChanges(context, changes: ["big": ["newValue": .string(String(repeating: "a", count: 9_000))]]); XCTFail("Oversized native data must be rejected") } catch {}
    expectEqual(try await client.callStorage(context, method: "get"), ["counter": 120])
    await client.close()
  }
  func testStorageDefaultsSpecialKeysAndExactChangeSemantics() throws {
    var area = SyncModel.emptyArea
    let set = try SyncModel.storage(&area,method:"set",args:[["__proto__":"safe","emoji":"fox","null":.null]],trusted:true,now:100)
    expectEqual(set.changes["__proto__"]["newValue"],"safe")
    expectEqual(try SyncModel.storage(&area,method:"get",args:[["missing":"default","null":"fallback"]],trusted:true,now:101).result,["missing":"default","null":.null])
    expectEqual(try SyncModel.storage(&area,method:"getBytesInUse",args:["emoji"],trusted:true,now:101).result,10)
    let removed = try SyncModel.storage(&area,method:"remove",args:["emoji"],trusted:true,now:102)
    expectEqual(removed.changes["emoji"]["oldValue"],"fox"); expectFalse(removed.changes["emoji"].contains("newValue"))
  }
  func testStorageQuotaAndTrustPolicyAreAtomic() throws {
    var area = SyncModel.emptyArea
    _ = try SyncModel.storage(&area,method:"set",args:[["keep":true]],trusted:true,now:0)
    let old = area
    XCTAssertThrowsError(try SyncModel.storage(&area,method:"set",args:[["huge":.string(String(repeating:"a",count:9000))]],trusted:true,now:0))
    expectEqual(area,old)
    _ = try SyncModel.storage(&area,method:"setAccessLevel",args:[["accessLevel":"TRUSTED_CONTEXTS"]],trusted:true,now:0)
    XCTAssertThrowsError(try SyncModel.storage(&area,method:"get",args:[],trusted:false,now:0))
    for index in 1..<120 { _ = try SyncModel.storage(&area,method:"set",args:[["index":.number(Double(index))]],trusted:true,now:0) }
    XCTAssertThrowsError(try SyncModel.storage(&area,method:"clear",args:[],trusted:true,now:1))
    _ = try SyncModel.storage(&area,method:"clear",args:[],trusted:true,now:60_001)
  }
  func testStaleClearPreservesUnobservedRemoteKeys() {
    let result = SyncModel.apply(["old":1,"unseen":2],["clear":true],revisions:["old":2,"unseen":8],base:3)
    expectEqual(result,["unseen":2])
  }
  func testOfflineOutboxSurvivesRestartAndLostAcknowledgement() async throws {
    let root = try directory(), server = FixtureSyncServer(), secrets = MemorySecrets()
    let first = try client(root,server:server,secrets:secrets); try await signIn(first); try await link(first)
    _ = try await first.callStorage(context,method:"set",args:[["theme":"green"]])
    await server.setLostAcknowledgement(true); _ = await first.syncNow()
    expectGreater(await first.status()["profiles"].array[0]["pending"].int,0)
    await first.close()
    let second = try client(root,server:server,secrets:secrets); await second.start(); _ = await second.syncNow()
    expectEqual(await second.status()["profiles"].array[0]["pending"],0)
    expectEqual(try await second.callStorage(context,method:"get"),["theme":"green"])
    let bodies = await server.calls.filter { $0.url.path.hasSuffix("/operations") }.compactMap(\.body)
    expectEqual(bodies.count,2); expectEqual(bodies[0]["operations"],bodies[1]["operations"])
    let saved = try String(contentsOf:root.appendingPathComponent("sync-client.json"),encoding:.utf8)
    expectFalse(saved.contains("fixture-access")); expectFalse(saved.contains("fixture-refresh")); await second.close()
  }
  func testDisablingSettingsPreservesLocalValuesAndLibraryQueue() async throws {
    let client = try client(directory(),server:FixtureSyncServer()); try await signIn(client); try await link(client)
    _ = try await client.callStorage(context,method:"set",args:[["local":"keep"]])
    _ = try await client.setSettingsSync("personal",enabled:false,options:[:])
    expectEqual(await client.status()["profiles"].array[0]["pending"],1)
    expectEqual(try await client.callStorage(context,method:"get"),["local":"keep"]); await client.close()
  }
  func testPausedLibraryRetainsUnuploadedAdditionAndTrustedPolicy() async throws {
    let client = try client(directory(),server:FixtureSyncServer()); try await signIn(client); try await link(client)
    _ = try await client.callStorage(context,method:"set",args:[["local":"keep"]])
    _ = try await client.callStorage(context,method:"setAccessLevel",args:[["accessLevel":"TRUSTED_CONTEXTS"]])
    _ = try await client.setLibrarySync("personal",enabled:false,options:[:])
    expectEqual(try await client.callStorage(context,method:"get"),["local":"keep"])
    var untrusted = context; untrusted.trusted = false
    expectFalse(await client.canAccessStorage(untrusted))
    expectEqual(await client.status()["profiles"].array[0]["pending"],0); await client.close()
  }
  func testConsentPrivateProfilesAndInvalidEndpointsFailClosed() async throws {
    let client = try client(directory(),server:FixtureSyncServer())
    do { _ = try await client.configure(endpoint:"http://sync.example"); XCTFail("Expected endpoint rejection") } catch { }
    try await signIn(client)
    do { _ = try await client.linkProfile("personal",options:["datasetId":"dataset","libraryChoice":"remote-only","settingsSync":true]); XCTFail("Expected consent rejection") } catch { }
    let privateContext = ExtensionStorageContext(profileID:"private",extensionID:FixtureSyncServer.extensionID,permissions:["storage"],trusted:true)
    expectFalse(await client.canAccessStorage(privateContext)); await client.close()
  }
  func testAccountSwitchSeparatesLocalCopies() async throws {
    let client = try client(directory(),server:FixtureSyncServer()); try await signIn(client,name:"one")
    _ = try await client.callStorage(context,method:"set",args:[["owner":"one"]]); _ = try await client.logout()
    try await signIn(client,name:"two"); expectEqual(try await client.callStorage(context,method:"get"),[:])
    _ = try await client.callStorage(context,method:"set",args:[["owner":"two"]]); _ = try await client.logout()
    try await signIn(client,name:"one"); expectEqual(try await client.callStorage(context,method:"get"),["owner":"one"]); await client.close()
  }
  func testLateLinkResponseCannotUndoUnlink() async throws {
    let server = FixtureSyncServer(), client = try client(directory(),server:server); try await signIn(client)
    await server.setSnapshotDelay(.milliseconds(100))
    let pending = Task { try await self.link(client) }; try await Task.sleep(for:.milliseconds(20))
    _ = try await client.unlinkProfile("personal")
    do { try await pending.value; XCTFail("Expected stale link rejection") } catch { }
    expectTrue(await client.status()["profiles"].array.isEmpty); await client.close()
  }
  func testRejectedValuesRetainExportRetryAndDiscard() async throws {
    let server = FixtureSyncServer(), client = try client(directory(),server:server); try await signIn(client); try await link(client)
    _ = await client.syncNow(); await server.setRejectSettings(true)
    _ = try await client.callStorage(context,method:"set",args:[["unsynced":true]]); _ = await client.syncNow()
    let rejected = await client.status()["profiles"].array[0]["rejected"].array[0]
    let exported = try await client.exportRejected("personal",id:rejected["id"].string)
    expectEqual(exported["payload"]["set"],["unsynced":true])
    expectEqual(try await client.callStorage(context,method:"get"),["unsynced":true])
    try await client.discardRejected("personal",id:rejected["id"].string)
    expectEqual(try await client.callStorage(context,method:"get"),[:]); await client.close()
  }
  func testProfileRetirementSurvivesRestartAndBlocksStorage() async throws {
    let root = try directory(), server = FixtureSyncServer(), client = try client(root,server:server)
    _ = try await client.callStorage(context,method:"set",args:[["secret":"delete"]])
    try await client.deleteLocalProfile("personal"); expectFalse(await client.canAccessStorage(context)); await client.close()
    let reopened = try self.client(root,server:server)
    expectFalse(await reopened.canAccessStorage(context))
    let saved = try String(contentsOf:root.appendingPathComponent("sync-client.json"),encoding:.utf8)
    expectFalse(saved.contains("secret")); await reopened.close()
  }
  func testPreparedProfileDeletionRollsBackWithoutLosingSettingsAndFinalizesAfterBrowserRemoval() async throws {
    let root = try directory(), profile = FixtureProfile(), server = FixtureSyncServer()
    let client = try NativeSyncClient(directory: root, getProfile: { id in
      let current = await profile.current(); return current.id == id ? current : nil
    }, activeProfile: { await profile.current() }, transport: server, secrets: MemorySecrets(), autoSync: false)
    _ = try await client.callStorage(context, method: "set", args: [["privateSetting":"retain until browser commit"]])
    try await client.prepareLocalProfileDeletion("personal")
    expectFalse(await client.canAccessStorage(context))
    try await client.cancelLocalProfileDeletion("personal")
    expectEqual(try await client.callStorage(context, method: "get"), ["privateSetting":"retain until browser commit"])
    try await client.prepareLocalProfileDeletion("personal")
    do { try await client.completeLocalProfileDeletion("personal"); XCTFail("Browser still has profile") } catch { }
    await profile.change("other")
    try await client.completeLocalProfileDeletion("personal")
    let saved = try String(contentsOf: root.appendingPathComponent("sync-client.json"), encoding: .utf8)
    expectFalse(saved.contains("privateSetting"))
    expectFalse(await client.canAccessStorage(context))
    await client.close()
  }

}
