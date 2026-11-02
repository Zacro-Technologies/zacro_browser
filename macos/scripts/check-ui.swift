#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation
import Darwin

// Run only against the disposable --engine-acceptance --native-ui-review app
// launched by check-app.py. All accessibility and input calls target that PID.
struct CheckFailure: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

guard CommandLine.arguments.count == 5,
  let pid = pid_t(CommandLine.arguments[1]), pid > 0,
  let fixture = URL(string: CommandLine.arguments[2]), fixture.scheme == "http",
  fixture.host == "127.0.0.1", fixture.user == nil, fixture.password == nil
else {
  fputs("Usage: check-ui.swift PID LOOPBACK_URL DISPOSABLE_PROFILE OUTPUT_JSON\n", stderr)
  exit(2)
}
let profile = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
let output = URL(fileURLWithPath: CommandLine.arguments[4])
let app = AXUIElementCreateApplication(pid)
var completed = [String]()
var stage = "guard"

func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func windows() -> [AXUIElement] { read(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
func text(_ element: AXUIElement, _ attribute: String) -> String {
  read(element, attribute) as? String ?? ""
}
func findButton(_ label: String) -> AXUIElement? {
  func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 28 else { return nil }
    if text(element, kAXRoleAttribute) == kAXButtonRole,
      [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains(where: {
        text(element, $0).caseInsensitiveCompare(label) == .orderedSame
      }) { return element }
    for child in read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
      if let match = search(child, depth: depth + 1) { return match }
    }
    return nil
  }
  return windows().compactMap { search($0, depth: 0) }.first
}
func paletteVisible() -> Bool {
  windows().contains { window in
    [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
      text(window, attribute) == "Command palette"
    }
  }
}
func waitFor(_ message: String, seconds: TimeInterval = 8, _ condition: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if condition() { return }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }
  throw CheckFailure(message)
}
func state() -> [String: Any] {
  guard let data = try? Data(contentsOf: profile.appendingPathComponent("native-state.json")),
    let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return [:] }
  return value
}
func processExited() -> Bool {
  // check-app.py is the app's parent and intentionally waits until this driver
  // finishes before reaping it. A successfully exited app can therefore remain
  // a zombie; NSRunningApplication.isTerminated alone misses that state.
  var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0 else { return false }
  return size == 0 || info.kp_proc.p_stat == SZOMB
}
func key(_ code: CGKeyCode, command: Bool = false, throughWindowServer: Bool = false) {
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    event?.flags = command ? .maskCommand : []
    if throughWindowServer { event?.post(tap: .cghidEventTap) }
    else { event?.postToPid(pid) }
  }
}
func typeText(_ value: String) {
  let units = Array(value.utf16)
  for start in stride(from: 0, to: units.count, by: 16) {
    let chunk = Array(units[start..<min(start + 16, units.count)])
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
      chunk.withUnsafeBufferPointer {
        event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
      }
      event?.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.03)
  }
}
func click(_ element: AXUIElement) throws {
  guard let rawPosition = read(element, kAXPositionAttribute),
    let rawSize = read(element, kAXSizeAttribute),
    CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
  else { throw CheckFailure("Native button has no accessible bounds") }
  var position = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
    AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0
  else { throw CheckFailure("Native button has invalid bounds") }
  let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    throw CheckFailure("The disposable browser must be foreground before pointer verification")
  }
  let visibleWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  let targetWindow = visibleWindows.first { info in
    guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds),
      (info[kCGWindowAlpha as String] as? Double ?? 0) > 0 else { return false }
    return frame.contains(point)
  }
  guard (targetWindow?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
    throw CheckFailure("Another application's window covers the native button")
  }
  // A directly posted mouse event can lack AppKit's WindowServer target and
  // never reach NSWindow hit testing. Use ordinary pointer routing only after
  // verifying the disposable browser owns the foreground application.
  CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.1)
  let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
  down?.setIntegerValueField(.mouseEventClickState, value: 1)
  down?.post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.06)
  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
  up?.setIntegerValueField(.mouseEventClickState, value: 1)
  up?.post(tap: .cghidEventTap)
}
func report(passed: Bool, error: String = "") {
  let result: [String: Any] = ["passed": passed, "stage": stage, "checks": completed, "error": error]
  if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: output, options: .atomic)
  }
}

do {
  guard profile.deletingLastPathComponent() == temporary,
    profile.lastPathComponent.hasPrefix("zacro-native-acceptance-")
  else { throw CheckFailure("UI checks require a disposable profile directly inside the system temporary directory") }
  var launchedApp: NSRunningApplication?
  try waitFor("The requested PID did not register as com.zacro.browser.native", seconds: 10) {
    guard let candidate = NSRunningApplication(processIdentifier: pid),
      candidate.bundleIdentifier == "com.zacro.browser.native" else { return false }
    launchedApp = candidate
    return true
  }
  guard let running = launchedApp else { throw CheckFailure("The disposable application exited before UI validation") }
  guard AXIsProcessTrusted() else {
    throw CheckFailure("Accessibility access is required for native input verification")
  }
  AXUIElementSetMessagingTimeout(app, 2)
  running.activate(options: [])
  try waitFor("Could not foreground the disposable browser") {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }
  stage = "new-tab-click"
  try waitFor("New Tab is missing from the native accessibility tree") { findButton("New Tab") != nil }
  try click(findButton("New Tab")!)
  try waitFor("Clicking New Tab did not open the command palette") { paletteVisible() }
  completed.append("Sidebar New Tab responds to a native mouse click")
  stage = "palette-input"
  try waitFor("Command palette did not focus its text field") {
    guard let focused = read(app, kAXFocusedUIElementAttribute),
      CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
    return text(focused as! AXUIElement, kAXRoleAttribute) == kAXTextFieldRole
  }
  let destination = fixture.appendingPathComponent("second.html").absoluteString
  typeText(destination)
  key(36)
  try waitFor("Typing a URL into the palette did not create a tab") {
    (state()["tabs"] as? [[String: Any]] ?? []).contains { ($0["url"] as? String) == destination }
  }
  try waitFor("Command palette stayed open after submission") { !paletteVisible() }
  completed.append("Palette accepts keyboard input and creates a tab")
  stage = "sidebar-shortcut"
  key(1, command: true)
  try waitFor("Command-S did not hide the sidebar") {
    (state()["settings"] as? [String: Any])?["sidebarVisible"] as? Bool == false
  }
  key(1, command: true)
  try waitFor("Command-S did not restore the sidebar") {
    (state()["settings"] as? [String: Any])?["sidebarVisible"] as? Bool == true
  }
  completed.append("Sidebar shortcut hides and restores the sidebar")
  stage = "quit"
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    throw CheckFailure("The disposable browser lost foreground before Command-Q")
  }
  key(12, command: true, throughWindowServer: true)
  try waitFor("Command-Q did not quit the application", seconds: 12) {
    running.isTerminated || processExited()
  }
  guard (state()["tabs"] as? [[String: Any]] ?? []).contains(where: {
    ($0["url"] as? String) == destination && ($0["isClosed"] as? Bool) == false
  }) else { throw CheckFailure("Quit discarded the open tab from the saved session") }
  completed.append("Native quit exits and retains the open session")
  stage = "complete"
  report(passed: true)
  print("PASS: native sidebar click, palette input, sidebar shortcut, and saved session on quit")
} catch {
  report(passed: false, error: String(describing: error))
  fputs("FAIL (\(stage)): \(error)\n", stderr)
  exit(1)
}
