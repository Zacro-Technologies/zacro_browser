#!/usr/bin/env python3
"""Execute the production Peek refresh/click methods with gated native replies.

This bounded Foundation fixture launches no application and sends no desktop
input. Its browser transport is a controlled stand-in; frame/context/nonce,
snapshot validation, refresh scheduling and click admission execute the exact
methods extracted from NativePeekLinkBridge.swift.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--emit-only', action='store_true')
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT/'macos/Sources/ZacroApp'

def declaration(source, anchor):
    start = source.index(anchor)
    opening = source.index('{', start)
    depth, cursor = 1, opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

bridge = (SOURCE/'NativePeekLinkBridge.swift').read_text()
members = '\n'.join(declaration(bridge, anchor) for anchor in [
    '  private struct Frame:', '  private struct Context {', '  private struct Armed {',
    '  func refresh() {', '  private var hasCurrentObservation:',
    '  private func valid(', '  private func invalidate()', '  private func receiveClick(',
])
policy = (SOURCE/'NativePeekLinkPolicy.swift').read_text().replace('import ZacroCore', '')
prelude = r'''
import Foundation
@MainActor final class CefBrowser { var isClosed = false; var zoomLevel = 0.0 }
@MainActor final class ChromiumPage {
  var id = "page", profileID = "profile", ownerWindowID: String? = "owner"
  var documentError: String?, url = URL(string: "https://source.example/current")
  var browser: CefBrowser?
}
enum BrowserAddress {
  static func webURL(_ value: String) -> URL? {
    guard let url = URL(string:value), ["http","https"].contains(url.scheme ?? ""),
      url.host != nil, url.user == nil, url.password == nil else { return nil }
    return url
  }
}
@MainActor final class Gate {
  var isOpen = false
  var waiters: [CheckedContinuation<Void,Never>] = []
  func wait() async { if !isOpen { await withCheckedContinuation { waiters.append($0) } } }
  func open() { isOpen = true; let captured = waiters; waiters = []; captured.forEach { $0.resume() } }
}
@MainActor final class Fixture {
'''
fixture = r'''
  private let retainedPage: ChromiumPage
  private weak var page: ChromiumPage?
  private var browser: CefBrowser?
  private var contexts: [Int:Context] = [:]
  private var armed: Armed?
  private var generation: UInt64 = 0, desiredRevision: UInt64 = 0
  private var handledRevision: UInt64 = 0, requestGeneration: UInt64 = 0
  private var lastSequence = 0
  private var started = true, stopped = false
  private var refreshTask: Task<Void,Never>?
  private let bindingName = "fixtureBinding"
  private var observation: NativePeekLinkSnapshot
  private var nativeFrame = Frame(id:"main-frame",loaderID:"document-one",url:"https://source.example/current")
  private var armCalls = 0, frameReads = 0, dispatches = 0
  private let firstArm = Gate(), secondArm = Gate(), frameReply = Gate()
  private var logs: [String] = []
  init() {
    let browser = CefBrowser(), page = ChromiumPage()
    page.browser = browser; self.browser = browser; self.page = page; retainedPage = page
    observation = NativePeekLinkSnapshot(pageID:page.id,profileID:page.profileID,
      ownerWindowID:page.ownerWindowID!,sourceURL:page.url!.absoluteString,pinnedURL:nil,visible:true)
    contexts[2] = Context(id:2,uniqueID:"isolated-document-one",frameID:"main-frame")
  }
  private func snapshot() -> NativePeekLinkSnapshot? { observation }
  private func trace(_ value: String) { logs.append(value) }
  private func frame(in browser: CefBrowser) async throws -> Frame {
    frameReads += 1; await frameReply.wait(); return nativeFrame
  }
  private func armCurrentDocument() async throws {
    armCalls += 1
    await (armCalls == 1 ? firstArm : secondArm).wait()
    guard !stopped, let context = contexts[2] else { throw CancellationError() }
    armed = Armed(frame:nativeFrame,context:context,nonce:UUID().uuidString,
      observedSnapshot:observation,snapshot:observation)
    lastSequence = 0
  }
  private func didRequest(_ url: URL, _ point: CGPoint) { dispatches += 1 }
  private func click() throws -> [String:Any] {
    let payload: [String:Any] = ["nonce":armed!.nonce,"sequence":1,"kind":"modified",
      "sourceURL":"https://source.example/current","url":"https://destination.example/next",
      "trusted":true,"button":0,"shift":true,"alt":false,"control":false,"meta":false,
      "download":false,"defaultPrevented":false,"target":"","rel":"","x":23,"y":45]
    return ["name":bindingName,"executionContextId":2,
      "payload":String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)]
  }
  private func replaceObservation(profileID:String? = nil, ownerWindowID:String? = nil,
    sourceURL:String? = nil, visible:Bool? = nil) {
    observation = NativePeekLinkSnapshot(pageID:observation.pageID,
      profileID:profileID ?? observation.profileID,
      ownerWindowID:ownerWindowID ?? observation.ownerWindowID,
      sourceURL:sourceURL ?? observation.sourceURL,pinnedURL:nil,visible:visible ?? observation.visible)
  }
  private static func wait(_ name: String, _ condition: () -> Bool) async throws {
    for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
    throw Failure(message:"Timed out: " + name)
  }
  private struct Failure: Error { let message: String }
  private static func check(_ condition: Bool, _ name:String, _ checks:inout[String]) throws {
    guard condition else { throw Failure(message:name) }; checks.append(name)
  }
  static func run() async throws -> [String] {
    var checks: [String] = []
    // Deliberately queue refreshes while the first native installation waits.
    // In the old implementation a redundant second arm starts next. Keep its
    // reply held until a click's real validation method awaits its frame reply.
    let race = Fixture()
    race.refresh()
    try await wait("first installation") { race.armCalls == 1 }
    race.refresh(); race.refresh()
    race.firstArm.open()
    try await wait("first armed document") { race.armed != nil }
    try await wait("queued revision settles or begins redundant installation") {
      race.refreshTask == nil || race.armCalls == 2
    }
    let payload = try race.click()
    race.receiveClick(payload)
    try await wait("click awaits native frame") { race.frameReads == 1 }
    race.secondArm.open()
    await race.refreshTask?.value
    race.frameReply.open()
    try await wait("click validated") {
      race.dispatches == 1 || race.logs.contains(where:{$0.hasPrefix("click.retired")})
    }
    try check(race.armCalls == 1,"pendingRefreshesDoNotReinstallIdenticalDocument",&checks)
    try check(race.dispatches == 1,"acceptedClickSurvivesRedundantRefreshDuringFrameReply",&checks)
    race.receiveClick(payload)
    for _ in 0..<30 { await Task.yield() }
    try check(race.frameReads == 1 && race.dispatches == 1,"sameTrustedSequenceDispatchesExactlyOnce",&checks)
    let mutations: [(String,(Fixture)->Void)] = [
      ("newDocumentRejectsAcceptedOldClick", { $0.invalidate() }),
      ("changedProfileRejectsAcceptedOldClick", { $0.retainedPage.profileID = "other"; $0.replaceObservation(profileID:"other") }),
      ("changedOwnerRejectsAcceptedOldClick", { $0.retainedPage.ownerWindowID = "other"; $0.replaceObservation(ownerWindowID:"other") }),
      ("replacedIsolatedContextRejectsAcceptedOldClick", { $0.contexts[2] = Context(id:2,uniqueID:"new-context",frameID:"main-frame") }),
      ("changedNativeLoaderRejectsAcceptedOldClick", { $0.nativeFrame = Frame(id:"main-frame",loaderID:"new-loader",url:$0.nativeFrame.url) }),
      ("hiddenSnapshotRejectsAcceptedOldClick", { $0.replaceObservation(visible:false) }),
      ("changedNativeBrowserRejectsAcceptedOldClick", { $0.retainedPage.browser = CefBrowser() }),
      ("stoppedOwnerRejectsAcceptedOldClick", { $0.stopped = true; $0.invalidate() }),
    ]
    for (name, mutate) in mutations {
      let item = Fixture(); item.firstArm.open(); item.refresh(); await item.refreshTask?.value
      item.receiveClick(try item.click())
      try await wait("native frame before " + name) { item.frameReads == 1 }
      mutate(item); item.frameReply.open()
      try await wait("rejection " + name) { item.logs.contains(where:{$0.hasPrefix("click.retired")}) }
      try check(item.dispatches == 0,name,&checks)
    }
    return checks
  }
}
@main struct Main {
  @MainActor static func main() async throws {
    let checks = try await Fixture.run()
    let encoded = try JSONSerialization.data(withJSONObject:["checks":checks.count,"passed":checks],options:[.sortedKeys])
    print(String(decoding:encoded,as:UTF8.self))
  }
}
'''
code = prelude + members + fixture + policy
if args.emit_only:
    output = ROOT/'macos/.build/verification/peek-link-refresh/extracted-peek-link-refresh.swift'
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(code)
    print(json.dumps({'authored':True,'compiled':False,'expectedChecks':11,'source':str(output)}))
else:
    with tempfile.TemporaryDirectory(prefix='zacro-peek-refresh-') as temp:
        swift, binary = Path(temp)/'fixture.swift', Path(temp)/'fixture'
        swift.write_text(code)
        subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(swift),'-o',str(binary)],check=True)
        result = json.loads(subprocess.check_output([str(binary)],text=True,timeout=10))
        if result['checks'] != 11: raise ValueError(result)
        print(json.dumps(result))
