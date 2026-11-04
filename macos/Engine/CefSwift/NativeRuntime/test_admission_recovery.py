#!/usr/bin/env python3
"""Compile exact production Quit recovery methods with controlled native leases."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT.parent / "Sources/CefKit/CefRuntime.swift"

PRELUDE = r'''
import Foundation
final class CefBrowser { var closingForTermination = true }
final class Lease {
    var releases = 0
    var failRelease = false
    func release() throws { releases += 1; if failRelease { throw Failure.native } }
}
enum Failure: Error { case native }
@MainActor final class Runtime {
    var isInitialized = true
    var isTerminationRequested = true
    var isPreparingTermination = false
    var terminationAttemptID: UUID? = UUID()
    var auxiliaryAdmissionFailureAttemptID: UUID?
    var auxiliaryFinalCleanupStarted = false
    var auxiliaryAdmission: Lease? = Lease()
    var auxiliaryDrainAttemptID: UUID?
    var auxiliaryDrainTask: Task<Void, Never>?
    var finalTerminationAttemptID: UUID?
    var finalTerminationCompletion: (() -> Void)?
    var scheduledTerminationAttemptID: UUID?
    var onTerminationChanged: ((Bool) -> Void)?
    var onAuxiliaryAdmissionFailure: ((Error) -> Void)?
    var readinessRetries = 0
    func handleTerminationRequest() -> Bool { readinessRetries += 1; return false }
    // EXACT_METHODS
}
@MainActor enum Evidence { static var assertions = 0 }
@MainActor func require(_ result: Bool, _ message: String) {
    if !result { fatalError(message) }
    Evidence.assertions += 1
}
@MainActor func run() throws {
    let runtime = Runtime()
    let attempt = runtime.terminationAttemptID!
    var alerts = 0
    runtime.onAuxiliaryAdmissionFailure = { _ in alerts += 1 }
    runtime.reportAuxiliaryAdmissionFailure(Failure.native, attempt: UUID())
    require(alerts == 0 && runtime.auxiliaryTerminationFailure == nil, "stale failure has no current authority")
    runtime.reportAuxiliaryAdmissionFailure(Failure.native, attempt: attempt)
    runtime.reportAuxiliaryAdmissionFailure(Failure.native, attempt: attempt)
    require(alerts == 1, "repeated scheduling reports only once")
    let token = runtime.auxiliaryTerminationFailure!
    require(token.canCancelQuit, "cleanup has not begun; failure is reversible")
    require(runtime.retryAuxiliaryTermination(token), "exact explicit retry accepted")
    require(runtime.readinessRetries == 1 && runtime.auxiliaryAdmissionFailureAttemptID == nil, "retry only clears latch and reevaluates native readiness")
    require(!runtime.retryAuxiliaryTermination(token) && runtime.readinessRetries == 1, "same sheet cannot retry twice")
    runtime.reportAuxiliaryAdmissionFailure(Failure.native, attempt: attempt)
    require(alerts == 2, "new explicit retry may report its actual failure once")
    let secondToken = runtime.auxiliaryTerminationFailure!
    runtime.auxiliaryFinalCleanupStarted = true
    require(!runtime.auxiliaryTerminationFailure!.canCancelQuit, "completed app cleanup forbids promised usable cancellation")
    require(try runtime.cancelAuxiliaryTermination(secondToken) == false, "earlier sheet cannot bypass cleanup boundary")
    require(runtime.auxiliaryAdmission?.releases == 0 && runtime.isTerminationRequested, "denied cancellation preserves lease and termination")
    require(runtime.retryAuxiliaryTermination(secondToken), "post-cleanup retry can still finish original cleanup")

    let cancel = Runtime()
    let cancelAttempt = cancel.terminationAttemptID!
    cancel.reportAuxiliaryAdmissionFailure(Failure.native, attempt: cancelAttempt)
    let cancelToken = cancel.auxiliaryTerminationFailure!
    let lease = cancel.auxiliaryAdmission!
    var cancellations = 0
    cancel.onTerminationChanged = { value in if !value { cancellations += 1 } }
    lease.failRelease = true
    do { _ = try cancel.cancelAuxiliaryTermination(cancelToken); fatalError("release failure was swallowed") }
    catch Failure.native {}
    require(cancel.isTerminationRequested && cancel.terminationAttemptID == cancelAttempt
        && cancel.auxiliaryAdmission === lease && cancel.auxiliaryTerminationFailure != nil && cancellations == 0,
        "failed native release retains exact failed attempt")
    lease.failRelease = false
    require(try cancel.cancelAuxiliaryTermination(cancelToken), "successful release permits cancellation")
    require(lease.releases == 2 && cancel.auxiliaryAdmission == nil && !cancel.isTerminationRequested
        && cancel.terminationAttemptID == nil && cancel.auxiliaryTerminationFailure == nil && cancellations == 1,
        "cancellation resets state after exact release")
    require(try cancel.cancelAuxiliaryTermination(cancelToken) == false && cancellations == 1,
        "consumed cancellation authority cannot run twice")
    cancel.isTerminationRequested = true
    cancel.terminationAttemptID = UUID()
    cancel.auxiliaryAdmissionFailureAttemptID = cancel.terminationAttemptID
    cancel.auxiliaryAdmission = Lease()
    require(!cancel.retryAuxiliaryTermination(cancelToken), "old retry cannot affect replacement Quit")
    require(try cancel.cancelAuxiliaryTermination(cancelToken) == false && cancel.auxiliaryAdmission?.releases == 0,
        "old cancel cannot release replacement lease")
    let ordinary = Runtime()
    let ordinaryAttempt = ordinary.terminationAttemptID!
    let ordinaryLease = ordinary.auxiliaryAdmission!
    ordinaryLease.failRelease = true
    let browser = CefBrowser()
    var ordinaryAlerts = 0, ordinaryCancellations = 0
    ordinary.onAuxiliaryAdmissionFailure = { _ in ordinaryAlerts += 1 }
    ordinary.onTerminationChanged = { if !$0 { ordinaryCancellations += 1 } }
    ordinary.cancelTerminationRequest(for: browser)
    require(!browser.closingForTermination && ordinary.isTerminationRequested
        && ordinary.terminationAttemptID == ordinaryAttempt && ordinary.auxiliaryAdmission === ordinaryLease,
        "Stay with failed native release retains exact Quit and fence")
    require(ordinaryAlerts == 1 && ordinaryCancellations == 0 && ordinary.auxiliaryTerminationFailure != nil,
        "failed ordinary cancellation reports once without promising usable services")
    ordinary.cancelTerminationRequest(for: browser)
    require(ordinaryAlerts == 1 && ordinaryCancellations == 0,
        "repeated native callbacks do not repeat a failed-attempt alert")
    ordinaryLease.failRelease = false
    ordinary.cancelTerminationRequest(for: browser)
    require(!ordinary.isTerminationRequested && ordinary.terminationAttemptID == nil
        && ordinary.auxiliaryAdmission == nil && ordinaryCancellations == 1,
        "ordinary cancellation is published only after native fence release succeeds")
    let replacementLease = Lease()
    ordinary.isTerminationRequested = true; ordinary.terminationAttemptID = UUID()
    ordinary.auxiliaryAdmission = replacementLease
    require(!ordinary.releaseAuxiliaryAdmissionForCancelledAttempt(attempt: ordinaryAttempt)
        && replacementLease.releases == 0 && ordinary.auxiliaryAdmission === replacementLease,
        "stale ordinary cancellation cannot release replacement authority")
    print("PASS \(Evidence.assertions) exact failure-recovery checks")
}
Task { @MainActor in
    do { try run(); exit(0) }
    catch { fatalError("unexpected recovery error: \(error)") }
}
dispatchMain()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-only', action='store_true')
    args = parser.parse_args()
    generated = RUNTIME.read_text()
    recovery_start = generated.index("    /// Opaque authority to act on one failed Quit attempt.")
    recovery = generated[recovery_start:generated.index("    func handleTerminationRequest()", recovery_start)]
    report_start = generated.index("    private func reportAuxiliaryAdmissionFailure(")
    report = generated[report_start:generated.index("    @discardableResult\n    private func releaseAuxiliaryAdmission", report_start)]
    release_start = generated.index("    @discardableResult\n    private func releaseAuxiliaryAdmission")
    ordinary_release = generated[release_start:recovery_start]
    cancel_start = generated.index("    func cancelTerminationRequest(for browser:")
    ordinary_cancel = generated[cancel_start:generated.rfind("\n}")]
    # Access adjustments expose the exact bodies to this same-file fixture.
    report = report.replace('private func reportAuxiliaryAdmissionFailure', 'func reportAuxiliaryAdmissionFailure', 1)
    ordinary_release = ordinary_release.replace('private func releaseAuxiliaryAdmissionForCancelledAttempt', 'func releaseAuxiliaryAdmissionForCancelledAttempt', 1)
    guards = [generated.count('auxiliaryFinalCleanupStarted = true') == 1,
              'auxiliaryFinalCleanupStarted = true\n                onReadyToTerminate()' in generated,
              'guard auxiliaryAdmissionIsQuiescent(attempt: attempt) else { return }' in generated,
              'try auxiliaryAdmission?.release()' in recovery,
              'guard releaseAuxiliaryAdmissionForCancelledAttempt(attempt: attempt) else { return }' in ordinary_cancel,
              'guard self.releaseAuxiliaryAdmissionForCancelledAttempt(attempt: attempt) else { return }' in generated,
              'Drain native authorization operations before shutdown' in generated]
    if not all(guards):
        raise ValueError('Staged runtime and fixture methods differ')
    print(json.dumps({'sourceGuards': len(guards), 'passed': True}))
    if args.source_only:
        print('Swift fixture explicitly uncompiled; source-only check requested')
        return
    with tempfile.TemporaryDirectory(prefix='zacro-admission-recovery-') as temporary:
        source = Path(temporary) / 'fixture.swift'
        executable = Path(temporary) / 'fixture'
        source.write_text(PRELUDE.replace('// EXACT_METHODS', recovery + '\n' + report + '\n' + ordinary_release + '\n' + ordinary_cancel))
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                        str(source), '-o', str(executable)], check=True, timeout=45)
        result = subprocess.run([str(executable)], capture_output=True, text=True, check=True, timeout=15)
        print(result.stdout, end='')
        print(json.dumps({'actualNativeABI': False, 'actualApplication': False}))


if __name__ == '__main__':
    main()
