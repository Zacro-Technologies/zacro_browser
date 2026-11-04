#!/usr/bin/env python3
"""Exercise CefRuntime's exact close methods against a deterministic host queue.

No CEF process or desktop app is launched. The production method bodies are
extracted verbatim; only browser handles, dispatch queue, and runtime bootstrap
are stand-ins. This checks async lifecycle ownership, not native beforeunload UI.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Engine/CefSwift/Sources/CefKit/CefRuntime.swift"
ENGINE = ROOT / "Sources/ZacroChromium/ChromiumEngine.swift"
PHASE = ROOT / "Sources/ZacroChromium/ChromiumRetirementPhase.swift"


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{": depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0: return source[start:index + 1]
    raise RuntimeError("Unbalanced production method: " + signature)


PRELUDE = r'''
import Foundation
@MainActor final class CefBrowser {
  let id: Int32
  var closingForTermination=false
  var closeCount=0
  init(_ id:Int32){self.id=id}
  func close(force:Bool){closeCount += 1}
}
@MainActor enum CefChromeBrowser {
  static var rootBrowserIDs=Set<Int32>()
  static var hasHostedWindows=false
  static var hasLiveWindows=true
}
@MainActor final class FixtureQueue {
  var jobs:[()->Void]=[]
  func async(execute:@escaping()->Void){jobs.append(execute)}
  func one(){precondition(!jobs.isEmpty);jobs.removeFirst()()}
  func drain(){while !jobs.isEmpty { one() }}
}
@MainActor enum DispatchQueue {static let main=FixtureQueue()}
@MainActor final class FixtureApp {func terminate(_ sender:Any?) {fatalError("Unexpected real termination")}}
@MainActor let NSApp=FixtureApp()
enum AdmissionFailure:Error {case status,release}
@MainActor final class CefAuxiliaryAdmissionLease {
  struct Status {let requests:Int;var isQuiescent:Bool {requests==0}}
  static var next:CefAuxiliaryAdmissionLease?
  var requests=0,waiters=0
  var statusFails=false,releaseFails=false,released=false
  static func acquireProcess() throws->CefAuxiliaryAdmissionLease? {
    defer {next=nil};return next ?? CefAuxiliaryAdmissionLease()
  }
  func status() throws->Status {
    if statusFails || released {throw AdmissionFailure.status}
    return Status(requests:requests)
  }
  func waitForQuiescence() async throws {
    waiters += 1;defer {waiters -= 1}
    while true {
      try Task.checkCancellation()
      if try status().isQuiescent {return}
      await Task.yield()
    }
  }
  func release() throws {
    if releaseFails {throw AdmissionFailure.release}
    released=true
  }
}
@MainActor final class CefRuntime {
  static var shared=CefRuntime()
  var isInitialized=true
  var browsers:[Int32:CefBrowser]=[:]
  var isTerminationRequested=false
  var scheduledTerminationAttemptID:UUID?
  var isPreparingTermination=false
  var terminationAttemptID:UUID?
  var finalTerminationAttemptID:UUID?
  var finalTerminationCompletion:(attempt:UUID,run:()->Void)?
  var onTerminationChanged:((Bool)->Void)?
  var beforeClosingDocuments:(() async->Bool)?
  var onReadyToTerminate:(()->Void)?
  var auxiliaryAdmission:CefAuxiliaryAdmissionLease?
  var auxiliaryDrainTask:Task<Void,Never>?
  var auxiliaryDrainAttemptID:UUID?
  var auxiliaryAdmissionFailureAttemptID:UUID?
  var auxiliaryFinalCleanupStarted=false
  var onAuxiliaryAdmissionFailure:((Error)->Void)?
  // The host boundary is a real native-window lifetime in production. These
  // deterministic signals never stand in for an actual AppKit/window test.
  var hasLiveAuxiliaryWindows=false
  func shutdown(){fatalError("Unexpected shutdown")}
'''

ENGINE_PRELUDE = r'''
}
@MainActor final class FixtureContext {var nativeID=0;var isOpen=false}
@MainActor final class FixtureEngine {
  var isTerminating=false
  var terminationAttemptID:UUID?
  var terminationDrainStarted=false
  var terminationCleanup:Task<Void,Never>?
  var terminationCompletionAttemptID:UUID?
  var beforeTermination:(() async->Void)?
  var retirementPhase=ChromiumRetirementPhase()
  var pages:[Int:CefBrowser]=[:]
  var contexts:[Int:FixtureContext]=[:]
  var closingPreparation:Task<Bool,Never>?
  var closingPreparationID:UUID?
  var profileDownloadRetirements:[String:Task<Void,Error>]=[:]
  var finished=0
  func prepareToCloseDocuments(in context:FixtureContext) async->Bool {true}
  func prepare() async->Bool {await prepareToCloseDocuments()}
  func ready(){finishTerminationAfterCleanup{self.finished += 1}}
  func changed(_ terminating:Bool){
    isTerminating=terminating
    if terminating {
      let attempt=UUID();terminationAttemptID=attempt;retirementPhase.prepare(attempt)
    } else {
      if let attempt=terminationAttemptID {retirementPhase.cancel(attempt)}
      terminationAttemptID=nil;closingPreparationID=nil
      closingPreparation?.cancel();closingPreparation=nil
    }
  }
'''

FIXTURE = r'''
}
@MainActor final class Gate {
  var started=false
  var continuation:CheckedContinuation<Bool,Never>?
  func wait() async->Bool {await withCheckedContinuation {continuation=$0;started=true}}
  func release(_ value:Bool){let pending=continuation;continuation=nil;pending?.resume(returning:value)}
}
@main struct Fixture {
  @MainActor static func main() async throws {
    var checks:[String]=[]
    func require(_ value:Bool,_ name:String){precondition(value,name);checks.append(name)}
    func spin(_ condition:()->Bool) async {
      for _ in 0..<1000 {if condition(){return};await Task.yield()}
      fatalError("Fixture continuation did not drain")
    }
    func reset(){DispatchQueue.main.jobs=[];CefChromeBrowser.rootBrowserIDs=[];CefChromeBrowser.hasHostedWindows=false;CefChromeBrowser.hasLiveWindows=true;CefAuxiliaryAdmissionLease.next=nil}
    for oldResult in [false,true] {
      reset();let runtime=CefRuntime(), browser=CefBrowser(1), a=Gate(), b=Gate()
      runtime.browsers[1]=browser
      var calls=0
      runtime.beforeClosingDocuments={calls += 1;if calls==1{return await a.wait()};return await b.wait()}
      _=runtime.handleTerminationRequest();await spin{a.started}
      runtime.cancelTerminationRequest(for:browser)
      _=runtime.handleTerminationRequest();await spin{b.started}
      let replacement=runtime.terminationAttemptID
      a.release(oldResult)
      for _ in 0..<30 {await Task.yield()}
      require(runtime.isTerminationRequested && runtime.isPreparingTermination && runtime.terminationAttemptID==replacement,
        oldResult ? "oldAcceptedPreparationCannotCommitReplacement" : "oldVetoCannotCancelReplacement")
      require(browser.closeCount==0,"replacementBarrierRetained_"+String(oldResult))
      b.release(false);await spin{!runtime.isTerminationRequested}
      require(!runtime.isPreparingTermination,"replacementOwnVetoDrains_"+String(oldResult))
    }
    do {
      reset();let runtime=CefRuntime(),browser=CefBrowser(2),gate=Gate();runtime.browsers[2]=browser
      runtime.beforeClosingDocuments={await gate.wait()}
      runtime.onTerminationChanged={if $0 {_=runtime.handleTerminationRequest()}}
      _=runtime.handleTerminationRequest();await spin{gate.started}
      require(browser.closeCount==0 && runtime.isPreparingTermination,"reentrantQuitCannotPassUnpublishedBarrier")
      gate.release(false);await spin{!runtime.isTerminationRequested}
    }
    do {
      reset();let runtime=CefRuntime(),root=CefBrowser(3),gate=Gate();runtime.browsers[3]=root
      CefChromeBrowser.rootBrowserIDs=[3];CefChromeBrowser.hasHostedWindows=true
      _=runtime.handleTerminationRequest()
      CefChromeBrowser.hasHostedWindows=false;runtime.chromeWindowDidClose()
      require(DispatchQueue.main.jobs.count==1,"oldRootCloseIsQueued")
      runtime.cancelTerminationRequest(for:root)
      runtime.beforeClosingDocuments={await gate.wait()};_=runtime.handleTerminationRequest();await spin{gate.started}
      DispatchQueue.main.drain()
      require(root.closeCount==0 && runtime.isPreparingTermination,"oldChildClosedCannotCloseRootsDuringReplacementPreparation")
      runtime.chromeWindowDidClose()
      require(DispatchQueue.main.jobs.isEmpty,"childClosedDuringPreparationDoesNotQueueRootClose")
      gate.release(false);await spin{!runtime.isTerminationRequested}
    }
    do {
      reset();let runtime=CefRuntime(),root=CefBrowser(4),late=CefBrowser(5),gate=Gate();runtime.browsers[4]=root
      CefChromeBrowser.rootBrowserIDs=[4];CefChromeBrowser.hasHostedWindows=true
      _=runtime.handleTerminationRequest();runtime.registerBrowser(late)
      runtime.cancelTerminationRequest(for:root);runtime.beforeClosingDocuments={await gate.wait()}
      _=runtime.handleTerminationRequest();await spin{gate.started};DispatchQueue.main.drain()
      require(late.closeCount==0 && runtime.isPreparingTermination,"oldRegistrationCannotResumeReplacementQuit")
      gate.release(false);await spin{!runtime.isTerminationRequested}
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),dummy=CefBrowser(6);var ready=0;runtime.onReadyToTerminate={ready += 1}
      _=runtime.handleTerminationRequest();runtime.cancelTerminationRequest(for:dummy);_=runtime.handleTerminationRequest()
      let replacement=runtime.terminationAttemptID
      require(DispatchQueue.main.jobs.count==2,"cancelledAndReplacementTerminationCallbacksCoexist")
      DispatchQueue.main.one()
      require(ready==0 && runtime.scheduledTerminationAttemptID==replacement,"oldReadyCallbackCannotClearReplacementSchedule")
      DispatchQueue.main.one()
      require(ready==1 && runtime.scheduledTerminationAttemptID==nil,"replacementReadyCallbackCompletesExactlyOnce")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime();var ready=0;runtime.onReadyToTerminate={ready += 1}
      runtime.hasLiveAuxiliaryWindows=true
      _=runtime.handleTerminationRequest()
      require(DispatchQueue.main.jobs.isEmpty && ready==0,"closedAuxiliaryTabDoesNotBypassLiveNativeWindow")
      runtime.hasLiveAuxiliaryWindows=false;runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(ready==1,"actualAuxiliaryWindowClosureReleasesQuitBarrier")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime();var ready=0;runtime.onReadyToTerminate={ready += 1}
      _=runtime.handleTerminationRequest()
      runtime.hasLiveAuxiliaryWindows=true;DispatchQueue.main.drain()
      require(ready==0 && runtime.scheduledTerminationAttemptID==nil,"lateAuxiliaryWindowInvalidatesQueuedShutdown")
      runtime.hasLiveAuxiliaryWindows=false;runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(ready==1,"lateAuxiliaryWindowCloseAllowsFreshShutdownSchedule")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),auth=CefBrowser(7);runtime.browsers[7]=auth
      _=runtime.handleTerminationRequest();runtime.cancelTerminationRequest(for:auth)
      require(!runtime.isTerminationRequested && !auth.closingForTermination && auth.closeCount==1,
        "auxiliaryStayCancelsOuterQuitWithoutRemovingDocument")
      _=runtime.handleTerminationRequest()
      require(auth.closeCount==2 && auth.closingForTermination,"auxiliaryStayAllowsFreshQuitAttempt")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),late=CefBrowser(8);var finish:(()->Void)?,finished=0
      runtime.onReadyToTerminate={finish=runtime.deferredTerminationCompletion{finished += 1}}
      _=runtime.handleTerminationRequest();DispatchQueue.main.drain()
      runtime.registerBrowser(late);runtime.hasLiveAuxiliaryWindows=true
      finish?();DispatchQueue.main.drain()
      require(late.closeCount==1 && finished==0,"postCleanupLateAuxiliaryGetsOrdinaryClose")
      runtime.browsers.removeValue(forKey:late.id);runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(finished==0,"postCleanupTabCloseStillWaitsForNativeWindow")
      runtime.hasLiveAuxiliaryWindows=false;runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(finished==1,"postCleanupActualWindowCloseRunsFinalCompletion")
      finish?();runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(finished==1,"duplicateCleanupCompletionCannotFinishTwice")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),dummy=CefBrowser(9);var finishes:[()->Void]=[],completed:[Int]=[]
      runtime.onReadyToTerminate={let number=finishes.count;finishes.append(runtime.deferredTerminationCompletion{completed.append(number)}!)}
      _=runtime.handleTerminationRequest();DispatchQueue.main.drain()
      runtime.cancelTerminationRequest(for:dummy);_=runtime.handleTerminationRequest();DispatchQueue.main.drain()
      finishes[0]();DispatchQueue.main.drain()
      require(completed.isEmpty && runtime.finalTerminationAttemptID==nil,"cancelledCleanupCannotArmReplacementCompletion")
      finishes[1]();runtime.hasLiveAuxiliaryWindows=true;DispatchQueue.main.drain()
      require(completed.isEmpty,"lateWindowBetweenFinishAndDispatchBlocksExit")
      runtime.hasLiveAuxiliaryWindows=false;runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(completed==[1],"replacementCleanupCompletesAfterItsOwnWindowBarrier")
    }
    for cleanupCompletesBeforeRetry in [false,true] {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),engine=FixtureEngine(),gate=Gate(),late=CefBrowser(10)
      CefRuntime.shared=runtime;var cleanupCalls=0
      engine.beforeTermination={cleanupCalls += 1;_ = await gate.wait()}
      runtime.beforeClosingDocuments={await engine.prepare()}
      runtime.onTerminationChanged={engine.changed($0)}
      runtime.onReadyToTerminate={engine.ready()}
      _=runtime.handleTerminationRequest();await spin{!runtime.isPreparingTermination};DispatchQueue.main.drain();await spin{gate.started}
      runtime.registerBrowser(late);runtime.hasLiveAuxiliaryWindows=true;DispatchQueue.main.drain()
      runtime.cancelTerminationRequest(for:late)
      if cleanupCompletesBeforeRetry {gate.release(true);for _ in 0..<30 {await Task.yield()};DispatchQueue.main.drain()}
      require(engine.finished==0 && !runtime.isTerminationRequested,"lateStayRejectsOldCleanup_"+String(cleanupCompletesBeforeRetry))
      _=runtime.handleTerminationRequest();await spin{!runtime.isPreparingTermination}
      require(runtime.isTerminationRequested && late.closeCount==2,"lateStayAllowsReplacementNativeClose_"+String(cleanupCompletesBeforeRetry))
      runtime.browsers.removeValue(forKey:late.id);runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      require(engine.finished==0,"replacementStillWaitsForExactNativeWindow_"+String(cleanupCompletesBeforeRetry))
      runtime.hasLiveAuxiliaryWindows=false;runtime.chromeWindowDidClose();DispatchQueue.main.drain()
      if !cleanupCompletesBeforeRetry {gate.release(true)}
      await spin{runtime.finalTerminationCompletion != nil};DispatchQueue.main.drain()
      require(engine.finished==1 && cleanupCalls==1 && !engine.retirementPhase.canBeginTask,
        "replacementReusesCleanupAndKeepsAdmissionClosed_"+String(cleanupCompletesBeforeRetry))
    }
    require(checks.count==35,"allPreviousLifecycleChecksRetained")
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),lease=CefAuxiliaryAdmissionLease();lease.requests=1
      CefAuxiliaryAdmissionLease.next=lease;var ready=0
      runtime.onReadyToTerminate={ready += 1}
      _=runtime.handleTerminationRequest();await spin{lease.waiters==1}
      require(ready==0 && DispatchQueue.main.jobs.isEmpty && runtime.auxiliaryAdmission===lease,
        "unpresentedNativeRequestRetainsQuitBarrier")
      lease.requests=0;await spin{!DispatchQueue.main.jobs.isEmpty};DispatchQueue.main.drain()
      require(ready==1,"actualNativeRequestQuiescenceReleasesQuitBarrier")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),lease=CefAuxiliaryAdmissionLease();lease.statusFails=true
      CefAuxiliaryAdmissionLease.next=lease;var ready=0,alerts=0
      runtime.onReadyToTerminate={ready += 1};runtime.onAuxiliaryAdmissionFailure={_ in alerts += 1}
      _=runtime.handleTerminationRequest();runtime.chromeWindowDidClose();runtime.chromeWindowDidClose()
      require(ready==0 && alerts==1 && runtime.auxiliaryTerminationFailure != nil,
        "failedNativeStatusRetainsAttemptAndReportsOnce")
      let failure=runtime.auxiliaryTerminationFailure!;lease.statusFails=false
      require(runtime.retryAuxiliaryTermination(failure),"onlyExactExplicitFailureRetryIsAccepted")
      DispatchQueue.main.drain();require(ready==1,"explicitRetryRechecksActualNativeStatus")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),browser=CefBrowser(11),lease=CefAuxiliaryAdmissionLease()
      runtime.browsers[11]=browser;lease.releaseFails=true;CefAuxiliaryAdmissionLease.next=lease
      var cancelled=0;runtime.onTerminationChanged={if !$0 {cancelled += 1}}
      _=runtime.handleTerminationRequest();let attempt=runtime.terminationAttemptID
      runtime.cancelTerminationRequest(for:browser)
      require(runtime.isTerminationRequested && runtime.terminationAttemptID==attempt && cancelled==0
        && runtime.auxiliaryAdmission===lease && runtime.auxiliaryTerminationFailure != nil,
        "failedStayLeaseReleaseCannotPublishUsableCancellation")
      lease.releaseFails=false;runtime.cancelTerminationRequest(for:browser)
      require(!runtime.isTerminationRequested && cancelled==1 && lease.released,
        "ordinaryStayPublishesCancellationOnlyAfterNativeRelease")
    }
    do {
      reset();CefChromeBrowser.hasLiveWindows=false
      let runtime=CefRuntime(),browser=CefBrowser(12),old=CefAuxiliaryAdmissionLease(),new=CefAuxiliaryAdmissionLease()
      old.requests=1;new.requests=1;CefAuxiliaryAdmissionLease.next=old;var ready=0
      runtime.onReadyToTerminate={ready += 1};_=runtime.handleTerminationRequest();await spin{old.waiters==1}
      runtime.cancelTerminationRequest(for:browser);CefAuxiliaryAdmissionLease.next=new
      _=runtime.handleTerminationRequest();let attempt=runtime.terminationAttemptID;await spin{new.waiters==1}
      old.requests=0;for _ in 0..<30 {await Task.yield()};DispatchQueue.main.drain()
      require(ready==0 && runtime.terminationAttemptID==attempt && runtime.auxiliaryAdmission===new && !new.released,
        "staleNativeDrainCannotReleaseReplacementAdmission")
      new.requests=0;await spin{!DispatchQueue.main.jobs.isEmpty};DispatchQueue.main.drain()
      require(ready==1,"replacementDrainWaitsForItsExactNativeRequests")
    }
    let data=try JSONSerialization.data(withJSONObject:["checks":checks,"count":checks.count,"previousLifecycleChecks":35,"nativeCEFVerified":false],options:[.prettyPrinted,.sortedKeys])
    print(String(decoding:data,as:UTF8.self))
  }
}
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--emit-only", type=Path, help="Write the exact-method fixture without compiling or running it.")
    args=parser.parse_args()
    source=SOURCE.read_text()
    signatures=["    func registerBrowser(_ browser: CefBrowser)",
                "    func chromeWindowDidClose()", "    private func scheduleTerminationIfReady()",
                "    public func deferredTerminationCompletion(_ completion: @escaping () -> Void)",
                "    private func completeTermination(attempt: UUID, completion: @escaping () -> Void)",
                "    private func auxiliaryAdmissionIsQuiescent(attempt: UUID)",
                "    private func reportAuxiliaryAdmissionFailure(_ error: Error, attempt: UUID)",
                "    private func releaseAuxiliaryAdmissionForCancelledAttempt(attempt: UUID)",
                "    public struct AuxiliaryTerminationFailure",
                "    public var auxiliaryTerminationFailure: AuxiliaryTerminationFailure?",
                "    public func retryAuxiliaryTermination(_ failure: AuxiliaryTerminationFailure)",
                "    public func cancelAuxiliaryTermination(_ failure: AuxiliaryTerminationFailure)",
                "    func handleTerminationRequest()", "    func cancelTerminationRequest(for browser: CefBrowser)"]
    engine=ENGINE.read_text()
    fixture=PRELUDE+"\n".join(method(source,signature) for signature in signatures)+ENGINE_PRELUDE
    fixture+="\n".join(method(engine,signature) for signature in [
        "  private func prepareToCloseDocuments()", "  private func finishTerminationAfterCleanup("])
    fixture+=FIXTURE+PHASE.read_text().replace("import Foundation", "")
    if args.emit_only:
        args.emit_only.parent.mkdir(parents=True,exist_ok=True);args.emit_only.write_text(fixture);return
    with tempfile.TemporaryDirectory(prefix="zacro-runtime-lifecycle-") as directory:
        root=Path(directory);swift=root/"fixture.swift";binary=root/"fixture"
        swift.write_text(fixture)
        subprocess.run(["xcrun","swiftc","-parse-as-library",str(swift),"-o",str(binary)],check=True)
        result=subprocess.check_output([str(binary)],text=True)
        parsed=json.loads(result)
        if len(parsed["checks"])!=45 or len(set(parsed["checks"]))!=45:
            raise SystemExit("Incomplete termination lifecycle fixture")
        if args.output:
            args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(result)
        print(result,end="")

if __name__=="__main__":main()
