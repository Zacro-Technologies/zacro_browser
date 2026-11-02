import AppKit
import Foundation
import ZacroChromium
import ZacroCore
import ZacroServices

/// Gated real MV3 downloads in two disposable native profiles. A's exact worker
/// deliberately survives Core deletion to witness the native cancellation fence;
/// B then follows the ordinary application Delete Profile action. This does not
/// claim physical database removal before Chromium's shutdown/replay barrier.
@MainActor
enum NativeDownloadRetirementAcceptance {
  @MainActor private final class Fixture {
    let profileID: String
    let directory: URL
    let extensionDirectory: URL
    var page: ChromiumPage?
    var manager: ChromeExtensionManager?
    var worker: ChromeExtensionWorkerSession?
    var preparedDeletion = false
    var cleaned = false
    init(profileID: String, directory: URL, extensionDirectory: URL) {
      self.profileID = profileID; self.directory = directory; self.extensionDirectory = extensionDirectory
    }
  }
  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  static func run(application: ApplicationCoordinator, owner: BrowserWindowCoordinator,
    url: URL) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      application.extensionBrowser.enabled, owner.windowContext.isOpen,
      owner.store.state.activeProfile?.isPrivate == false,
      application.deletingProfileID == nil,
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      url.user == nil, url.password == nil,
      let path = ProcessInfo.processInfo.environment["ZACRO_NATIVE_EXTENSION_FIXTURE"] else {
      throw Failure("Download retirement requires the disposable native integration fixture")
    }
    let engine = application.engine, originalSpace = owner.store.state.activeSpaceID
    let originalProfile = owner.store.activeProfileID
    let survivors = engine.pages.values.filter {
      $0.ownerWindowID == owner.windowContext.id && $0.profileID == originalProfile && $0.browser?.isClosed == false
    }.map { ($0, $0.browser!, $0.id) }
    guard !survivors.isEmpty else { throw Failure("Keep an original native document for the profile isolation assertion") }
    var checks: [String] = [], fixtures: [Fixture] = []
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native download retirement check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw Failure(name) }; checks.append(name)
    }
    func worker(_ fixture: Fixture) throws -> ChromeExtensionWorkerSession {
      guard let worker = fixture.worker else { throw Failure("The exact download witness is already closed") }
      return worker
    }
    func make(_ name: String) async throws -> Fixture {
      let profile = try owner.store.createProfileDurably(name: "Download retirement " + name)
      // No suspension separates profile creation from restoring the visible
      // Space, so layout never creates an untracked document in the new profile.
      owner.store.selectSpace(id: originalSpace)
      let fixture = Fixture(profileID: profile.id,
        directory: engine.dataDirectory.appendingPathComponent("AcceptanceDownloads/retirement-" + profile.id),
        extensionDirectory: engine.dataDirectory.appendingPathComponent("AcceptanceDownloadExtension-" + profile.id))
      fixtures.append(fixture) // Partial setup is also eligible for exact cleanup.
      try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: fixture.extensionDirectory)
      let page = engine.page(id: "download-retirement:" + profile.id, profileID: profile.id,
        isPrivate: false, url: URL(string: "about:blank"), ownerWindowID: nil)
      fixture.page = page; page.hide()
      try await page.ready().setDownloadDirectory(fixture.directory)
      let manager = ChromeExtensionManager(engine: engine, profileID: profile.id)
      fixture.manager = manager
      try await manager.setDeveloperMode(true)
      let extensionID = try await manager.loadUnpackedExtension(at: fixture.extensionDirectory)
      fixture.worker = try await manager.workerSession(extensionID)
      return fixture
    }
    func start(_ fixture: Fixture) async throws -> Int {
      guard let value = try await worker(fixture).evaluate(
        "zacroDownloadRetirementFixture.start(\(try literal(url.absoluteString)))") as? [String: Any],
        let id = value["id"] as? Int else { throw Failure("Native worker did not create its owned download") }
      _ = try await worker(fixture).evaluate("zacroDownloadRetirementFixture.verifyStreaming(\(id))", timeout: 12)
      return id
    }
    func item(_ fixture: Fixture, _ id: Int) async throws -> ChromeNativeDownload {
      guard let manager = fixture.manager else { throw Failure("Missing exact native download manager") }
      let snapshot = try await manager.downloadSnapshot()
      guard snapshot.complete, let found = snapshot.downloads.first(where: { Int($0.id) == id }) else {
        throw Failure("The complete native snapshot did not contain the owned item")
      }
      return found
    }
    func detachedWitness(_ fixture: Fixture, erase: Bool) async throws {
      var cleanupError: Error?
      if let value = fixture.worker {
        if erase {
          do { _ = try await value.evaluate("zacroDownloadRetirementFixture.cleanup(\(try literal(fixture.directory.path)))", timeout: 12) }
          catch { cleanupError = error }
        }
        await value.close(); fixture.worker = nil
      }
      await fixture.manager?.close(); fixture.manager = nil
      if let cleanupError { throw cleanupError }
    }
    func clean(_ fixture: Fixture) async throws {
      guard !fixture.cleaned else { return }
      if application.deletingProfileID == fixture.profileID {
        try await until("the ordinary profile deletion completes") { application.deletingProfileID == nil }
      }
      // Even a failed witness command cannot strand its session/context. The
      // actual retirement fence below still owns cancellation and cleanup.
      var cleanupError: Error?
      do { try await detachedWitness(fixture, erase: true) } catch { cleanupError = error }
      for page in Array(engine.pages.values) where page.profileID == fixture.profileID {
        try await close(page, engine: engine)
      }
      fixture.page = nil
      if application.store.state.profiles.contains(where: { $0.id == fixture.profileID }) {
        if !fixture.preparedDeletion {
          try await owner.services.prepareProfileDeletion(fixture.profileID)
          fixture.preparedDeletion = true
        }
        try owner.store.deleteProfileDurably(id: fixture.profileID)
      }
      application.downloads.removeProfile(fixture.profileID)
      try await engine.retireProfileDownloads(profileID: fixture.profileID, isPrivate: false)
      try engine.retireProfile(fixture.profileID)
      try await application.navigation.removeProfile(fixture.profileID)
      await application.extensionSync.removeProfile(fixture.profileID)
      try await owner.services.didDeleteProfile(fixture.profileID)
      try NativeProfileArtifacts.remove(directory: engine.dataDirectory, profileID: fixture.profileID)
      try owner.store.acknowledgeNativeProfileRetirement(fixture.profileID)
      try? FileManager.default.removeItem(at: fixture.directory)
      try? FileManager.default.removeItem(at: fixture.extensionDirectory)
      fixture.cleaned = true
      if let cleanupError { throw cleanupError }
    }
    func durableState() throws -> [String: Any] {
      let file = application.repository.directory.appendingPathComponent("native-state.json")
      guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw Failure("Missing actual durable browser state")
      }
      return value
    }
    do {
      let a = try await make("A"), b = try await make("B")
      let aRunning = try await start(a)
      _ = try await worker(a).evaluate("zacroDownloadRetirementFixture.pauseAndVerify(\(aRunning))")
      let aPaused = try await start(a)
      _ = try await worker(a).evaluate("zacroDownloadRetirementFixture.pauseAndVerify(\(aPaused))")
      let bPaused = try await start(b)
      _ = try await worker(b).evaluate("zacroDownloadRetirementFixture.pauseAndVerify(\(bPaused))")
      let aBefore = try await item(a, aRunning), aSecond = try await item(a, aPaused), bBefore = try await item(b, bPaused)
      let aGUIDs = Set([aBefore.guid, aSecond.guid])
      try require(aGUIDs.count == 2 && !aGUIDs.contains(bBefore.guid)
        && [aBefore, aSecond, bBefore].allSatisfy { !$0.isPrivate && $0.sourceTabID == nil && $0.download.receivedBytes > 0 },
        "retirementFixtureUsesRealBrowserlessProfileScopedItems")
      let aSnapshot = try await a.manager!.downloadSnapshot(), bSnapshot = try await b.manager!.downloadSnapshot()
      try require(!aSnapshot.downloads.contains { $0.guid == bBefore.guid }
        && !bSnapshot.downloads.contains { aGUIDs.contains($0.guid) },
        "downloadSnapshotsDoNotLeakAcrossNativeProfileContexts")
      if let page = a.page { try await close(page, engine: engine); a.page = nil }
      try require(try await item(a, aRunning).status == "paused",
        "workerDownloadSurvivesUnrelatedNativeDocumentClosure")
      // Keep both items paused while provider cleanup may suspend. Resume just
      // before durable deletion so the fence sees one running and one paused.
      try await owner.services.prepareProfileDeletion(a.profileID); a.preparedDeletion = true
      _ = try await worker(a).evaluate("zacroDownloadRetirementFixture.resumeAndVerify(\(aRunning))")
      let running = try await item(a, aRunning)
      try require(running.status == "downloading" && !running.paused,
        "retirementStartsWithActualRunningAndPausedTransfers")
      try owner.store.deleteProfileDurably(id: a.profileID)
      let saved = try durableState()
      try require(application.store.pendingNativeProfileRetirements.contains(a.profileID)
        && (saved["pendingNativeProfileRetirements"] as? [String])?.contains(a.profileID) == true
        && (saved["profiles"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == a.profileID }) == false,
        "downloadFenceFollowsActualDurableCoreDeletionReceipt")
      try await engine.retireProfileDownloads(profileID: a.profileID, isPrivate: false)
      for id in [aRunning, aPaused] {
        _ = try await worker(a).evaluate("zacroDownloadRetirementFixture.verifyRetired(\(id))", timeout: 12)
        let stopped = try await item(a, id)
        try require(stopped.status == "cancelled" && !stopped.canResume,
          id == aRunning ? "profileFenceCancelsRunningWorkerDownload" : "profileFenceCancelsPausedWorkerDownload")
      }
      try require(engine.pages["maintenance:retire:persistent:" + a.profileID] == nil,
        "retirementHelperWaitsForItsActualMaintenanceClose")
      let unaffected = try await item(b, bPaused)
      try require(unaffected.guid == bBefore.guid && unaffected.status == "paused" && unaffected.canResume,
        "profileRetirementPreservesAnotherProfilesPausedNativeItem")
      _ = try await worker(b).evaluate("zacroDownloadRetirementFixture.resumeAndVerify(\(bPaused))")
      try require(true, "anotherProfileResumesActualBytesAfterRetirementFence")
      _ = try await worker(b).evaluate("zacroDownloadRetirementFixture.pauseAndVerify(\(bPaused))")
      let lateURL = URL(string: "/download?fixture=" + UUID().uuidString, relativeTo: url)!.absoluteURL.absoluteString
      let lateName = "zacro-native-retirement-late-" + UUID().uuidString + ".bin"
      let late = try await worker(a).evaluate("""
        (async () => {
          const url=\(try literal(lateURL)), filename=\(try literal(lateName));
          let id, callbackRejected=false;
          try { id=await chrome.downloads.download({url,filename,saveAs:false}); } catch (_) { callbackRejected=true; }
          const deadline=Date.now()+10000;
          while(Date.now()<deadline) {
            const rows=await chrome.downloads.search({url});
            const row=rows.find(x => id===undefined || x.id===id);
            if(row && row.state==='interrupted') {
              if(row.error!=='USER_CANCELED' || row.canResume) throw new Error('Late item escaped retired context fence');
              await chrome.downloads.erase({id:row.id}); return {cancelled:true,callbackRejected};
            }
            if(row?.state==='complete') throw new Error('Retired context completed a late transfer');
            await new Promise(resolve=>setTimeout(resolve,40));
          }
          throw new Error('No cancelled real late DownloadItem appeared');
        })()
        """, timeout: 12) as? [String: Any]
      try require(late?["cancelled"] as? Bool == true, "retiredContextCancelsLateWorkerItemRegardlessOfAPICallbackRace")
      try await clean(a)
      try require(!engine.pages.values.contains { $0.profileID == a.profileID }
        && !application.store.pendingNativeProfileRetirements.contains(a.profileID),
        "retiredWitnessProfileClosesAllExactTransportsBeforeAcknowledgement")

      // Exercise the actual application callback for B. Close inspection first;
      // retaining an inspector through this leg would change its lifecycle.
      try await detachedWitness(b, erase: false)
      owner.actions.deleteProfile(b.profileID)
      try await until("the complete application Delete Profile flow") {
        application.deletingProfileID == nil
          && !application.store.state.profiles.contains { $0.id == b.profileID }
          && !application.store.pendingNativeProfileRetirements.contains(b.profileID)
          && !engine.pages.values.contains { $0.profileID == b.profileID }
      }
      b.page = nil
      let final = try durableState()
      try require((final["profiles"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == b.profileID }) == false
        && (final["pendingNativeProfileRetirements"] as? [String])?.contains(b.profileID) != true
        && !application.store.state.downloads.contains { $0.profileID == b.profileID }
        && engine.auxiliaryBrowsers(profileID: b.profileID, isPrivate: false).isEmpty,
        "applicationProfileDeletionFinishesDurableStateAndExactNativeCleanup")
      b.cleaned = true
      try? FileManager.default.removeItem(at: b.directory)
      try? FileManager.default.removeItem(at: b.extensionDirectory)
      try require(owner.windowContext.isOpen && owner.store.activeProfileID == originalProfile
        && survivors.allSatisfy { page, browser, id in engine.pages[id] === page && page.browser === browser && !browser.isClosed },
        "retirementPreservesOriginalWindowAndUnrelatedLiveNativeDocuments")
      owner.store.selectSpace(id: originalSpace)
      return checks
    } catch {
      for fixture in fixtures where !fixture.cleaned {
        do { try await clean(fixture) }
        catch { fputs("Download retirement fixture cleanup retained its exact receipt: \(error.localizedDescription)\n", stderr) }
      }
      owner.store.selectSpace(id: originalSpace)
      throw error
    }
  }

  private static func close(_ page: ChromiumPage, engine: ChromiumEngine) async throws {
    guard engine.pages[page.id] === page else { return }
    let id = page.id, browser = page.browser
    page.close()
    try await until("the exact fixture native document closes") {
      engine.pages[id] !== page && browser?.isClosed != false
    }
  }
  private static func literal(_ value: String) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
  }
  private static func until(_ phase: String, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      try Task.checkCancellation()
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(40))
    }
    throw Failure("Download retirement timed out: " + phase)
  }
}
