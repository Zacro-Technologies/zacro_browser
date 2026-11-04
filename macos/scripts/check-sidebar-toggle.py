#!/usr/bin/env python3
"""Bounded extracted-method checks; no desktop input or app is launched.

Extracts the accepted production Sources and compiles a bounded Foundation
fixture, never the full application or a desktop input driver.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--production', action='store_true', help='Compatibility option: production sources are always checked')
parser.add_argument('--emit-only', action='store_true')
args = parser.parse_args()
STAGE = Path(__file__).resolve().parent
ROOT = next(p for p in STAGE.parents if (p/'macos/Sources/ZacroApp').is_dir())
source_root = ROOT/'macos/Sources/ZacroApp'

def declaration(source, anchor):
    start = source.index(anchor)
    opening = source.index('{', start)
    depth, cursor = 1, opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

source = (source_root/'NativeSidebarToggle.swift').read_text()
plan = declaration(source, 'enum NativeSidebarTogglePlan:')
handoff = declaration(source, '@MainActor final class NativeSidebarToggleHandoff:')
application = (source_root/'Application.swift').read_text()
command = declaration(application, '  func runCommand(_ id: String, fromPage: Bool = false)')
tracing = command[command.index('    let tracingSidebarFocus ='):command.index('    guard application.permitWindowCommand')]
dispatch = command[command.index('    guard commandAvailable(id) else {'):command.index('    switch id {')]
# Use the actual dispatch prefix, including its early return. Removing that
# return must regress the page-focus case, rather than merely satisfy a regex.
prelude = '''import Foundation
protocol ObservableObject: AnyObject {}
@MainActor final class NSWindow: NSObject {
  static let didEndSheetNotification = Notification.Name("sheet")
  static let didChangeOcclusionStateNotification = Notification.Name("visible")
  static let didResignKeyNotification = Notification.Name("resign")
  static let willCloseNotification = Notification.Name("close")
  static let didBecomeKeyNotification = Notification.Name("key")
  var isVisible = true, isKeyWindow = false
  var attachedSheet: NSWindow?, sheetParent: NSWindow?
  var keyRequests = 0
  func makeKeyAndOrderFront(_ sender: Any?) { keyRequests += 1; isKeyWindow = true }
}
final class NSEvent: NSObject {
  enum Mask { case leftMouseDown, rightMouseDown, otherMouseDown, keyDown }
  nonisolated(unsafe) static var monitors: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]
  static func addLocalMonitorForEvents(matching: [Mask], handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
    let token = NSObject(); monitors[ObjectIdentifier(token)] = handler; return token
  }
  static func removeMonitor(_ token: Any) { monitors.removeValue(forKey: ObjectIdentifier(token as AnyObject)) }
  static func deliver(_ event: NSEvent) { for handler in Array(monitors.values) { _ = handler(event) } }
}
@MainActor final class NSApplication {
  static let didResignActiveNotification = Notification.Name("inactive")
  var keyWindow: NSWindow?, modalWindow: NSWindow?
  var currentEvent: NSEvent?
}
let NSApp = NSApplication()
'''
checks = '''
var count = 0
@MainActor func check(_ value: @autoclosure () -> Bool) { precondition(value()); count += 1 }
check(NativeSidebarTogglePlan.make(visiblePreference:true,effectiveWidth:224,libraryOpen:false,fromPage:false) == .setVisible(false,focus:.page))
check(NativeSidebarTogglePlan.make(visiblePreference:false,effectiveWidth:0,libraryOpen:false,fromPage:false) == .setVisible(true,focus:.address))
check(NativeSidebarTogglePlan.make(visiblePreference:false,effectiveWidth:0,libraryOpen:false,fromPage:true) == .setVisible(true,focus:.page))
check(NativeSidebarTogglePlan.make(visiblePreference:true,effectiveWidth:0,libraryOpen:true,fromPage:false) == .closeLibrary(focus:.library))
check(NativeSidebarTogglePlan.make(visiblePreference:true,effectiveWidth:0,libraryOpen:true,fromPage:true) == .closeLibrary(focus:.page))
check(NativeSidebarTogglePlan.make(visiblePreference:false,effectiveWidth:0,libraryOpen:true,fromPage:false) == .setVisible(true,focus:.address))
let owner = NSWindow(), blocker = NSWindow(), foreign = NSWindow()
let handoff = NativeSidebarToggleHandoff()
handoff.attach(owner)
NSApp.keyWindow = owner
var current = true, received: [Int] = []
@MainActor func begin(_ value: Int, blocking: [NSWindow] = [blocker]) {
  handoff.begin(blockingWindows:blocking,ownsFocus: { $0 == nil || $0 === owner },
    valid:{ current },focus:{ received.append(value) })
}
begin(1)
handoff.retry()
check(received.isEmpty && handoff.hasPending)
handoff.activate()
check(received.isEmpty && handoff.hasPending)
blocker.isVisible = false
NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:blocker)
check(received == [1] && !handoff.hasPending)
handoff.retry()
check(received == [1])
blocker.isVisible = true
begin(2); handoff.activate(); begin(3); handoff.activate()
blocker.isVisible = false
NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:blocker)
check(received == [1,3])
blocker.isVisible = true; begin(4); handoff.activate(); current = false
blocker.isVisible = false; handoff.retry()
check(received == [1,3] && !handoff.hasPending)
current = true; blocker.isVisible = true; begin(5); handoff.activate()
NSApp.keyWindow = foreign
NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:foreign)
NSApp.keyWindow = owner; blocker.isVisible = false; handoff.retry()
check(received == [1,3] && !handoff.hasPending)
owner.attachedSheet = blocker
begin(6,blocking:[blocker]); handoff.activate()
check(received == [1,3] && handoff.hasPending)
owner.attachedSheet = nil
NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:owner)
check(received == [1,3,6] && !handoff.hasPending)
blocker.isVisible = true; begin(7); handoff.activate(); owner.isVisible = false
handoff.retry()
check(received == [1,3,6] && !handoff.hasPending)
owner.isVisible = true; begin(8); handoff.activate(); handoff.attach(nil)
blocker.isVisible = false; handoff.retry()
check(received == [1,3,6] && !handoff.hasPending)
handoff.attach(owner); blocker.isVisible = true; begin(9); handoff.activate()
current = false
NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:nil)
check(!handoff.hasPending && received == [1,3,6])
current = true; blocker.isVisible = true; begin(10); handoff.activate()
owner.attachedSheet = foreign; handoff.retry()
owner.attachedSheet = nil; blocker.isVisible = false; handoff.retry()
check(!handoff.hasPending && received == [1,3,6])
let initiating = NSEvent(); NSApp.currentEvent = initiating
blocker.isVisible = true; begin(11); handoff.activate()
NSEvent.deliver(initiating)
check(handoff.hasPending)
NSEvent.deliver(NSEvent())
blocker.isVisible = false; handoff.retry()
check(!handoff.hasPending && received == [1,3,6] && NSEvent.monitors.isEmpty)
var dismissed = false
handoff.begin(blockingWindows:[],ownsFocus:{ $0 === owner },valid:{true},ready:{dismissed},focus:{received.append(12)})
handoff.activate()
check(received == [1,3,6] && handoff.hasPending)
dismissed = true; handoff.retry(); handoff.retry()
check(received == [1,3,6,12] && !handoff.hasPending)
// A non-main palette can own key while its native document remains main.
// The exact owned origin must survive removal of the palette's parent link.
NSApp.keyWindow = blocker; blocker.isVisible = true
handoff.begin(blockingWindows:[blocker],ownsFocus:{$0 === owner || $0 === blocker},
  valid:{true},focus:{received.append(13)})
handoff.activate()
let waitingForOwnedPalette = handoff.hasPending && received == [1,3,6,12]
blocker.isVisible = false; NSApp.keyWindow = nil; handoff.retry()
check(waitingForOwnedPalette && received == [1,3,6,12,13] && !handoff.hasPending)
// Capturing a foreign window as a blocker is not proof of an owned origin.
NSApp.keyWindow = foreign; foreign.isVisible = true
handoff.begin(blockingWindows:[foreign],ownsFocus:{$0 === owner},valid:{true},focus:{received.append(14)})
handoff.activate(); foreign.isVisible = false; NSApp.keyWindow = nil; handoff.retry()
check(received == [1,3,6,12,13] && !handoff.hasPending)
NSApp.keyWindow = owner
'''
root_fixture = '''
@MainActor final class Actions {
  var palette = false, themeEditor = false
  var toggleSidebar: (Bool) -> Void = { _ in }
  var performInterfaceCommand: (String) -> Bool = { _ in true }
}
@MainActor final class CommandOwner {
  struct WindowContext { let id = "fixture-window" }
  let actions = Actions()
  let window: NSWindow? = NSWindow()
  let windowContext = WindowContext()
  func commandAvailable(_ id: String) -> Bool { true }
  func runCommand(_ id: String, fromPage: Bool = false) {
''' + tracing + dispatch + '''
  }
}
let commandOwner = CommandOwner()
var origins: [Bool] = []
commandOwner.actions.toggleSidebar = { origins.append($0) }
commandOwner.runCommand("sidebar-toggle",fromPage:true)
check(origins == [true] && commandOwner.window?.keyRequests == 0)
commandOwner.runCommand("sidebar-toggle")
check(origins == [true,false] && commandOwner.window?.keyRequests == 0)
var interfaceReceivedKey = false
commandOwner.actions.performInterfaceCommand = { _ in
  interfaceReceivedKey = commandOwner.window?.isKeyWindow == true
  return true
}
commandOwner.runCommand("focus-sidebar")
check(interfaceReceivedKey && commandOwner.window?.isKeyWindow == true)
print("{\\"checks\\":\\(count)}")
'''
code = prelude + plan + '\n' + handoff + '\n' + checks + root_fixture
if args.emit_only:
    output = ROOT/'macos/.build/verification/sidebar-toggle/extracted-sidebar-toggle.swift'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(code)
    print(json.dumps({'authored': True, 'compiled': False, 'expectedChecks': 28}))
else:
    with tempfile.TemporaryDirectory(prefix='zacro-sidebar-toggle-') as temp:
        swift, binary = Path(temp)/'fixture.swift', Path(temp)/'fixture'
        swift.write_text(code)
        subprocess.run(['xcrun','swiftc','-swift-version','6',str(swift),'-o',str(binary)],check=True)
        result = json.loads(subprocess.check_output([str(binary)],text=True))
        if result != {'checks':28}: raise ValueError(result)
        print(json.dumps(result))
