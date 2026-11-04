import AppKit
import SwiftUI
import ZacroCore

/// Hosts the actual browser surfaces in an existing owned fixture window.
/// Local AppKit key and mouse delivery exercises their real input handlers.
/// No event is posted outside this process, and no accessibility permission,
/// OS setting change or Chromium page is used.
@MainActor enum NativeControlFocusAcceptance {
  static func check(in window: NSWindow) async -> [String: Bool] {
    let previousContent = window.contentView
    let previousKey = NSApp.keyWindow
    let previouslyVisible = window.isVisible
    let keyboardNavigation = NSApp.isFullKeyboardAccessEnabled
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zacro-control-focus-" + UUID().uuidString, isDirectory: true)
    var result = [String: Bool]()
    var activations = 0
    var pointerEventNumber = 810
    var ownedPopover: NSPopover?
    weak var ownedPopoverWindow: NSWindow?
    defer {
      for name in result.keys.sorted() where name.contains("Mouse") || name.contains("Pointer")
        || name.hasPrefix("themeHexadecimal") || name.hasPrefix("themePopover") {
        fputs("Native control pointer result \(result[name] == true ? "PASS" : "FAIL"): \(name)\n", stderr)
      }
    }
    defer {
      ownedPopover?.close()
      window.contentView = previousContent
      if !previouslyVisible { window.orderOut(nil) }
      if let previousKey, previousKey !== window, previousKey.isVisible { previousKey.makeKeyAndOrderFront(nil) }
      try? FileManager.default.removeItem(at: root)
    }
    func host<Content: View>(_ content: Content, size: CGSize) async {
      window.setContentSize(size)
      let view = NSHostingView(rootView: content)
      view.sizingOptions = []; view.frame = CGRect(origin: .zero, size: size)
      window.contentView = view
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      for _ in 0..<8 {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(12))
      }
    }
    func keyDown() -> Bool {
      guard window.isKeyWindow, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
        charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) else { return false }
      window.sendEvent(event)
      return true
    }
    func waitForElement(_ identifier: String, role: NSAccessibility.Role = .button) async -> Bool {
      let deadline = Date().addingTimeInterval(3)
      while Date() < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        if window.isKeyWindow && focusedElement(in: window, identifier: identifier, role: role) { return true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      fputs("Native control focus diagnostics: target=\(identifier) role=\(role.rawValue) key=\(window.isKeyWindow) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled) responder=\(window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil") AX=\(focusDiagnostics(in: window))\n", stderr)
      return false
    }
    func textFields(in target: NSWindow, includeHidden: Bool = false) -> [NSTextField] {
      var pending = target.contentView.map { [$0] } ?? [], fields = [NSTextField]()
      var visited = 0
      while let view = pending.popLast(), visited < 8_192 {
        visited += 1
        guard view.window === target else { continue }
        if let field = view as? NSTextField, includeHidden || !field.isHiddenOrHasHiddenAncestor {
          fields.append(field)
        }
        pending += view.subviews
      }
      return fields
    }
    func placeholder(_ field: NSTextField) -> String? {
      field.placeholderString ?? field.placeholderAttributedString?.string
    }
    func inputHitEvidence(_ field: NSTextField, in host: NSView, window target: NSWindow) -> [String: Any] {
      guard field.window === target, host.window === target else { return [:] }
      func object(_ value: NSObject, _ name: String) -> Any? {
        guard value.responds(to: NSSelectorFromString(name)) else { return nil }
        return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
      }
      func describe(_ value: NSObject?) -> [String: Any] {
        guard let value else { return ["class": "nil"] }
        if let view = value as? NSView, view.window !== target { return ["class": "outside-owned-window"] }
        var data: [String: Any] = ["class": String(reflecting: type(of: value)),
          "identifier": String((object(value, "accessibilityIdentifier") as? String ?? "").prefix(160)),
          "role": String((object(value, "accessibilityRole") as? String ?? "").prefix(160)),
          "label": String((object(value, "accessibilityLabel") as? String ?? "").prefix(160)),
          "placeholder": String((object(value, "accessibilityPlaceholderValue") as? String ?? "").prefix(160))]
        // Struct returns must be read through typed AppKit/KVC boxing, never
        // NSObject.perform's object-return calling convention.
        if value.responds(to: NSSelectorFromString("accessibilityFrame")),
          let rect = (value.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
          data["frameScreen"] = String(describing: rect)
          data["frameWindow"] = String(describing: target.convertFromScreen(rect))
        }
        return data
      }
      let samples = [0.02, 0.25, 0.5, 0.75, 0.98].map { fraction -> [String: Any] in
        let point = field.convert(NSPoint(x: field.bounds.minX + field.bounds.width * CGFloat(fraction),
          y: field.bounds.midY), to: nil)
        let rootPoint = host.superview?.convert(point, from: nil) ?? point
        let hit = host.hitTest(rootPoint)
        return ["fraction": fraction, "pointWindow": String(describing: point),
          "hitClass": hit.map { String(reflecting: type(of: $0)) } ?? "nil",
          "hitMatchesTarget": hit.map { $0 === field || $0.isDescendant(of: field) } == true,
          "axHit": describe(host.accessibilityHitTest(target.convertPoint(toScreen: point)) as? NSObject)]
      }
      var pending: [NSObject] = [host], visited = Set<ObjectIdentifier>(), semantic = [[String: Any]]()
      while let item = pending.popLast(), visited.count < 8_192, semantic.count < 8 {
        guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
        if item is NSWindow { continue }
        if let view = item as? NSView, view.window !== target { continue }
        if object(item, "accessibilityRole") as? String == NSAccessibility.Role.textField.rawValue,
          item === field || object(item, "accessibilityPlaceholderValue") as? String == placeholder(field)
            || object(item, "accessibilityLabel") as? String == placeholder(field) {
          semantic.append(describe(item))
        }
        pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
      }
      return ["readonlyHitSamples": samples, "semanticTextFields": semantic,
        "nativeTextFieldAX": describe(field)]
    }
    func pointerDiagnostics(_ phase: String, in target: NSWindow, field: NSTextField? = nil,
      extra: [String: Any] = [:]) {
      let ownsTarget = target === window || (target === ownedPopoverWindow
        && ownedPopover?.isShown == true && ownedPopover?.contentViewController?.view.window === target)
      var values: [String: Any] = ["phase": phase, "owned": ownsTarget,
        "window": target.windowNumber, "key": target.isKeyWindow, "visible": target.isVisible,
        "ownerKey": window.isKeyWindow, "appActive": NSApp.isActive,
        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
        "familyKey": NSApp.keyWindow === target ? "target"
          : ownsTarget && target === ownedPopoverWindow && NSApp.keyWindow === window ? "popover-owner" : "outside",
        "responder": target.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil",
        "candidate": field.map { String(reflecting: type(of: $0)) } ?? "nil",
        "fields": ownsTarget ? textFields(in: target, includeHidden: true).prefix(12).map { value -> [String: Any] in
          ["class": String(reflecting: type(of: value)), "identifier": value.identifier?.rawValue ?? "nil",
            "label": value.accessibilityLabel() ?? "nil", "placeholder": value.placeholderString ?? "nil",
            "attributedPlaceholder": value.placeholderAttributedString?.string ?? "nil",
            "frame": String(describing: value.frame), "bounds": String(describing: value.bounds),
            "visibleRect": String(describing: value.visibleRect), "enabled": value.isEnabled,
            "editable": value.isEditable, "hidden": value.isHiddenOrHasHiddenAncestor,
            "owned": value.window === target, "editing": value.currentEditor() != nil]
        } : []]
      values.merge(extra) { _, current in current }
      if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8) { fputs("Native control pointer diagnostics: \(text)\n", stderr) }
    }
    func pointerEdit(_ phase: String, _ field: NSTextField?, in target: NSWindow,
      activationOwner: NSWindow? = nil, startingField: NSTextField? = nil, keepsEditor: Bool = false,
      existingEditorRequired: Bool = false,
      read: () -> String) async -> (focused: Bool, edited: Bool) {
      pointerDiagnostics(phase + ".before", in: target, field: field)
      guard target === window || (target === ownedPopoverWindow && ownedPopover?.isShown == true
        && ownedPopover?.contentViewController?.view.window === target) else { return (false, false) }
      let isOwnedPopover = target === ownedPopoverWindow && ownedPopover?.isShown == true
        && ownedPopover?.contentViewController?.view.window === target
      guard let field else {
        pointerDiagnostics(phase + ".missing-field", in: target); return (false, false)
      }
      if existingEditorRequired && startingField == nil {
        pointerDiagnostics(phase + ".missing-existing-editor", in: target, field: field)
        return (false, false)
      }
      let semanticIdentifier: String?
      if isOwnedPopover && placeholder(field) == "Space name" { semanticIdentifier = "native-space-name" }
      else if isOwnedPopover && placeholder(field) == "Find an icon" { semanticIdentifier = "native-space-icon-search" }
      else { semanticIdentifier = nil }
      func accessibilityObject(_ value: NSObject, _ name: String) -> Any? {
        guard value.responds(to: NSSelectorFromString(name)) else { return nil }
        return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
      }
      func semanticState(_ identifier: String) -> (node: NSObject, frame: CGRect, focused: Bool)? {
        guard let host = target.contentView, target === ownedPopoverWindow, ownedPopover?.isShown == true,
          ownedPopover?.contentViewController?.view.window === target else { return nil }
        var pending: [NSObject] = [host], visited = Set<ObjectIdentifier>(), matches = [NSObject]()
        while let item = pending.popLast(), visited.count < 8_192 {
          guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
          if item is NSWindow { continue }
          if let view = item as? NSView, view.window !== target { continue }
          if accessibilityObject(item, "accessibilityIdentifier") as? String == identifier,
            accessibilityObject(item, "accessibilityRole") as? String == NSAccessibility.Role.textField.rawValue {
            matches.append(item)
          }
          pending += accessibilityObject(item, "accessibilityChildren") as? [NSObject] ?? []
        }
        guard matches.count == 1, let node = matches.first,
          accessibilityObject(node, "accessibilityPlaceholderValue") as? String == placeholder(field)
            || accessibilityObject(node, "accessibilityLabel") as? String == placeholder(field),
          node.responds(to: NSSelectorFromString("accessibilityFrame")),
          let screenFrame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
          node.responds(to: NSSelectorFromString("isAccessibilityFocused")) else { return nil }
        return (node, target.convertFromScreen(screenFrame),
          (node.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue == true)
      }
      func virtualHit(at point: NSPoint) -> Bool {
        guard let identifier = semanticIdentifier, let state = semanticState(identifier), !state.focused,
          let host = target.contentView, let content = ownedPopover?.contentViewController?.view,
          content.window === target else { return false }
        let native = field.convert(field.bounds, to: nil), semantic = state.frame
        let visibleContent = content.convert(content.visibleRect.intersection(content.bounds), to: nil)
        let concentricEnvelope = native.insetBy(dx: -1, dy: -1).contains(semantic)
          || semantic.insetBy(dx: -1, dy: -1).contains(native)
        guard native.width > 0, semantic.width > 0, native.height > 0, semantic.height > 0,
          concentricEnvelope, visibleContent.insetBy(dx: -1, dy: -1).contains(native),
          visibleContent.insetBy(dx: -1, dy: -1).contains(semantic), semantic.contains(point),
          abs(native.midX - semantic.midX) <= 1, abs(native.midY - semantic.midY) <= 1,
          min(native.width, semantic.width) / max(native.width, semantic.width) >= 0.8 else { return false }
        var hit = host.accessibilityHitTest(target.convertPoint(toScreen: point)) as? NSObject
        var seen = Set<ObjectIdentifier>()
        while let value = hit, seen.count < 8, seen.insert(ObjectIdentifier(value)).inserted {
          if value is NSWindow { return false }
          if let view = value as? NSView, view.window !== target { return false }
          if accessibilityObject(value, "accessibilityIdentifier") as? String == identifier,
            accessibilityObject(value, "accessibilityRole") as? String == NSAccessibility.Role.textField.rawValue {
            return true
          }
          hit = accessibilityObject(value, "accessibilityParent") as? NSObject
        }
        return false
      }
      guard let host = target.contentView, field.window === target, field.isEnabled, field.isEditable,
        !field.isHiddenOrHasHiddenAncestor,
        field.bounds.width > 0, field.bounds.height > 0,
        activationOwner == nil ? target.isKeyWindow
          : activationOwner === window && window.isKeyWindow && NSApp.keyWindow === window else {
        pointerDiagnostics(phase + ".admission-or-geometry", in: target, field: field); return (false, false)
      }
      // The real field must acquire focus from the click, not retain the
      // component's initial autofocus. This separate owned native editor is
      // only a starting responder; no action is sent to the target field.
      var other: NSTextField?
      if activationOwner == nil && startingField == nil {
        let responder = NSTextField(frame: NSRect(x: 8, y: host.isFlipped ? host.bounds.maxY - 30 : 8,
          width: 110, height: 22))
        responder.stringValue = "Unchanged responder"
        host.addSubview(responder); other = responder
        guard target.makeFirstResponder(responder) else {
          responder.removeFromSuperview()
          pointerDiagnostics(phase + ".companion-refused", in: target, field: field); return (false, false)
        }
        responder.selectText(nil)
      }
      let startingControl = startingField ?? other
      let startingValue = startingControl?.stringValue
      var completedInput = false
      defer {
        if !completedInput || !keepsEditor {
          if let editor = field.currentEditor(), target.firstResponder === editor {
            _ = target.makeFirstResponder(nil)
          } else if let editor = other?.currentEditor(), target.firstResponder === editor {
            _ = target.makeFirstResponder(nil)
          } else if let identifier = semanticIdentifier, semanticState(identifier)?.focused == true,
            let editor = target.firstResponder as? NSTextView, editor.isFieldEditor, editor.window === target {
            _ = target.makeFirstResponder(nil)
          }
        }
        other?.removeFromSuperview()
      }
      let companionOwnsFocus: Bool
      if let source = startingControl, source !== field, source.window === target,
        let editor = source.currentEditor(), editor.window === target {
        companionOwnsFocus = target.firstResponder === editor
      }
      else { companionOwnsFocus = false }
      guard field.currentEditor() == nil, activationOwner != nil || companionOwnsFocus else {
        pointerDiagnostics(phase + ".target-was-not-defocused", in: target, field: field); return (false, false)
      }
      func startingResponderIsCurrent() -> Bool {
        if activationOwner != nil { return window.isKeyWindow && NSApp.keyWindow === window }
        guard target.isKeyWindow, NSApp.keyWindow === target || (isOwnedPopover && NSApp.keyWindow === window),
          let source = startingControl, source !== field, source.window === target,
          let editor = source.currentEditor(), editor.window === target else { return false }
        return target.firstResponder === editor
      }
      func virtualEditorIsFocused() -> Bool {
        guard let identifier = semanticIdentifier, semanticState(identifier)?.focused == true,
          let editor = target.firstResponder as? NSTextView, editor.isFieldEditor, editor.window === target,
          startingControl?.currentEditor() == nil, target.isKeyWindow,
          NSApp.keyWindow === target || NSApp.keyWindow === window else { return false }
        return true
      }
      func nativeEditorIsFocused() -> Bool {
        guard field.window === target, target.isKeyWindow,
          NSApp.keyWindow === target || (isOwnedPopover && NSApp.keyWindow === window),
          let editor = field.currentEditor(), editor.window === target,
          target.firstResponder === editor, startingControl?.currentEditor() == nil else { return false }
        return true
      }
      // Ending the previous SwiftUI editor may schedule layout. Observe the
      // real target and its hit twice after that work, without clicking again
      // or allowing queued autofocus to satisfy the target-editor assertion.
      let readyEnd = Date().addingTimeInterval(3)
      var previousFrame: CGRect?, previousHit: ObjectIdentifier?, stable = 0
      var prepared: (point: NSPoint, rootPoint: NSPoint, hit: NSView, virtual: Bool)?
      var geometry = [String: Any]()
      while Date() < readyEnd {
        guard target.contentView === host, field.window === target,
          target === window || (target === ownedPopoverWindow && ownedPopover?.isShown == true
            && ownedPopover?.contentViewController?.view.window === target) else { break }
        host.layoutSubtreeIfNeeded()
        let frame = field.convert(field.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let rootPoint = host.superview?.convert(point, from: nil) ?? point
        let hit = host.hitTest(rootPoint)
        let nativeHit = hit.map { $0 === field || $0.isDescendant(of: field) } == true
        let semanticHit = startingField == nil && !nativeHit && isOwnedPopover && virtualHit(at: point)
          && hit.map { $0 === host || $0.isDescendant(of: host) } == true
        let hitsTarget = nativeHit || semanticHit
        let hasStartingEditor = startingResponderIsCurrent()
        geometry = ["fieldInWindow": String(describing: frame), "pointInWindow": String(describing: point),
          "rootPoint": String(describing: rootPoint), "rootBounds": String(describing: host.bounds),
          "rootFlipped": host.isFlipped, "hitClass": hit.map { String(reflecting: type(of: $0)) } ?? "nil",
          "hitIdentifier": hit?.identifier?.rawValue ?? "nil", "hitMatchesTarget": hitsTarget,
          "nativeHitMatchesTarget": nativeHit, "virtualSemanticHitMatchesTarget": semanticHit,
          "semanticIdentifier": semanticIdentifier ?? "nil",
          "hitInWindow": hit.map { String(describing: $0.convert($0.bounds, to: nil)) } ?? "nil",
          "companionOwnsEditor": hasStartingEditor,
          "editorInWindow": (target.firstResponder as? NSView).map { String(describing: $0.convert($0.bounds, to: nil)) } ?? "nil"]
        if let identifier = semanticIdentifier, let semantic = semanticState(identifier)?.frame {
          geometry["styledSemanticFrame"] = String(describing: semantic)
          geometry["semanticEnvelope"] = semantic.insetBy(dx: -1, dy: -1).contains(frame)
            ? "native-inside-styled-AX" : frame.insetBy(dx: -1, dy: -1).contains(semantic)
              ? "styled-AX-inside-native" : "unassociated"
        }
        if field.currentEditor() == nil, hasStartingEditor, hitsTarget, hit?.window === target,
          field.visibleRect.contains(NSPoint(x: field.bounds.midX, y: field.bounds.midY)),
          previousFrame == frame, previousHit == hit.map({ ObjectIdentifier($0) }) {
          stable += 1
          if stable >= 2, let hit { prepared = (point, rootPoint, hit, semanticHit); break }
        } else { stable = 0 }
        previousFrame = frame; previousHit = hit.map { ObjectIdentifier($0) }
        try? await Task.sleep(for: .milliseconds(20))
      }
      geometry.merge(inputHitEvidence(field, in: host, window: target)) { _, value in value }
      guard let prepared, target.contentView === host, field.window === target,
        field.currentEditor() == nil, startingResponderIsCurrent(),
        let currentHit = host.hitTest(prepared.rootPoint), currentHit === prepared.hit,
        prepared.virtual ? virtualHit(at: prepared.point)
          : currentHit === field || currentHit.isDescendant(of: field) else {
        pointerDiagnostics(phase + ".point-or-starting-editor-not-stable", in: target, field: field, extra: geometry)
        return (false, false)
      }
      let point = prepared.point
      pointerDiagnostics(phase + ".point-ready", in: target, field: field, extra: geometry)
      func eventTimestampMatches(_ left: TimeInterval, _ right: TimeInterval) -> Bool {
        // AppKit reconstructs posted events with integer-nanosecond timestamps.
        abs(left - right) <= 0.000_000_001
      }
      var windowDispatches = [NSEvent.EventType]()
      func dispatchOwnEvent(_ event: NSEvent) -> Bool {
        let mask: NSEvent.EventTypeMask
        switch event.type {
        case .leftMouseDown: mask = .leftMouseDown
        case .leftMouseUp: mask = .leftMouseUp
        case .keyDown: mask = .keyDown
        default: return false
        }
        // CEF work and Swift task continuations can run inside the host's
        // run loop. Explicitly retrieve this one locally posted event through
        // AppKit before dispatching it; never drain or send another event.
        NSApp.postEvent(event, atStart: true)
        let next = NSApp.nextEvent(matching: mask, until: Date(), inMode: .default, dequeue: true)
        var mismatches = [String]()
        if let next {
          if next.type != event.type { mismatches.append("type") }
          if next.window !== event.window { mismatches.append("window") }
          if !eventTimestampMatches(next.timestamp, event.timestamp) { mismatches.append("timestamp") }
          if next.locationInWindow != event.locationInWindow { mismatches.append("location") }
          if event.type == .keyDown, next.type == .keyDown {
            if next.keyCode != event.keyCode { mismatches.append("keyCode") }
            if next.characters != event.characters { mismatches.append("characters") }
            if next.charactersIgnoringModifiers != event.charactersIgnoringModifiers { mismatches.append("unmodifiedCharacters") }
            if next.modifierFlags != event.modifierFlags { mismatches.append("modifiers") }
            if next.isARepeat != event.isARepeat { mismatches.append("repeat") }
          } else if next.type == event.type, event.type != .keyDown,
            next.eventNumber != event.eventNumber { mismatches.append("eventNumber") }
        } else { mismatches.append("missing") }
        let metadataMatches = mismatches.isEmpty
        fputs("Native control dequeue receipt: phase=\(phase) expected=\(eventState(event)) retrieved=\(eventState(next)) exact=\(metadataMatches) sameObject=\(next === event) mismatches=\(mismatches) current=\(eventState(NSApp.currentEvent))\n", stderr)
        guard metadataMatches, let next else {
          if let next { NSApp.postEvent(next, atStart: true) }
          return false
        }
        let current = NSApp.currentEvent
        var currentMatches = current?.type == next.type && current?.window === next.window
          && current?.timestamp == next.timestamp && current?.locationInWindow == next.locationInWindow
        if currentMatches, let current {
          currentMatches = next.type == .keyDown
            ? current.keyCode == next.keyCode && current.characters == next.characters
            : current.eventNumber == next.eventNumber
        }
        guard currentMatches, let destination = next.window,
          destination === target || (isOwnedPopover && next.type == .keyDown && destination === window) else {
          fputs("Native control window dispatch rejected: phase=\(phase) currentMatches=\(currentMatches)\n", stderr)
          return false
        }
        // This component fixture exercises the native window's real hit and
        // responder route. NSApplication synthetic-event admission and local
        // monitors are covered by their separate owned application fixtures.
        destination.sendEvent(next)
        windowDispatches.append(next.type)
        fputs("Native control window dispatch receipt: phase=\(phase) type=\(next.type.rawValue) window=\(destination.windowNumber) count=\(windowDispatches.count) current=\(eventState(NSApp.currentEvent))\n", stderr)
        return true
      }
      var events = [NSEvent]()
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        pointerEventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
          context: nil, eventNumber: pointerEventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0),
          event.window === target else {
          pointerDiagnostics(phase + ".event-window-mismatch", in: target, field: field); return (false, false)
        }
        fputs("Native control pointer event: phase=\(phase) type=\(type.rawValue) number=\(event.eventNumber) timestamp=\(event.timestamp) point=\(event.locationInWindow) window=\(target.windowNumber)\n", stderr)
        events.append(event)
      }
      for event in events {
        guard dispatchOwnEvent(event) else {
          pointerDiagnostics(phase + ".own-event-dequeue-failed", in: target, field: field, extra: geometry)
          return (false, false)
        }
      }
      // Snapshot focus immediately after the one window-dispatched mouseUp.
      // Native targets require their exact native editor; semantic
      // accessibility focus cannot substitute for that ownership proof.
      // AppKit popovers can report key status while the application's public
      // keyWindow remains their source window. Admit only this exact owned
      // popover/source family; standalone fields still require the exact key.
      guard windowDispatches == [.leftMouseDown, .leftMouseUp], target.isKeyWindow,
        NSApp.keyWindow === target || (isOwnedPopover && NSApp.keyWindow === window),
        prepared.virtual ? virtualEditorIsFocused() : nativeEditorIsFocused() else {
        pointerDiagnostics(phase + ".mouse-did-not-focus", in: target, field: field, extra: geometry)
        return (false, false)
      }
      let before = read()
      guard let keyboardWindow = NSApp.keyWindow,
        keyboardWindow === target || (isOwnedPopover && keyboardWindow === window), !before.contains("z"),
        let key = NSEvent.keyEvent(with: .keyDown, location: keyboardWindow === target ? point : .zero,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: keyboardWindow.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
        isARepeat: false, keyCode: 6), key.window === keyboardWindow else {
        pointerDiagnostics(phase + ".key-window-mismatch", in: target, field: field); return (true, false)
      }
      pointerDiagnostics(phase + ".typing-through-actual-family-key", in: target, field: field)
      guard dispatchOwnEvent(key) else {
        pointerDiagnostics(phase + ".own-key-dequeue-failed", in: target, field: field)
        return (true, false)
      }
      let editEnd = Date().addingTimeInterval(3)
      while Date() < editEnd {
        let value = read()
        if windowDispatches == [.leftMouseDown, .leftMouseUp, .keyDown],
          value.count == before.count + 1, value.filter({ $0 != "z" }) == before,
          prepared.virtual ? virtualEditorIsFocused() : nativeEditorIsFocused(),
          other == nil || other?.stringValue == "Unchanged responder",
          startingField == nil || startingField?.stringValue == startingValue {
          completedInput = true
          return (true, true)
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      pointerDiagnostics(phase + ".binding-did-not-change", in: target, field: field)
      return (true, false)
    }

    var site = SiteControlActions()
    site.url = URL(string: "https://example.invalid/owned-control-focus")
    site.extensionsReady = true
    site.bookmark = { activations += 1 }
    await host(SiteControls(actions: site, maximumHeight: 640), size: CGSize(width: 304, height: 640))
    result["siteControlsInitialActionHasActualFocusedButtonWithoutSystemKeyboardNavigation"] =
      await waitForElement("native-site-control:copy")
    let siteDown = keyDown()
    let siteStarFocused = await waitForElement("native-site-control:star")
    result["siteControlsArrowMovesActualFocusWithoutActivatingAction"] = siteDown
      && siteStarFocused && activations == 0

    let colors = NativeSpacePalette(theme: SpaceTheme(), dark: false)
    let pointer = PointerModel()
    await host(PointerFields(model: pointer, colors: colors), size: CGSize(width: 340, height: 220))
    let styled = await pointerEdit("styled", textFields(in: window).first { placeholder($0) == "Pointer target" },
      in: window) { pointer.text }
    result["styledTextFieldMousePairAcquiresItsActualNativeFieldEditor"] = styled.focused
    result["styledTextFieldMouseAndKeyboardInputUpdatesOnlyItsActualBinding"] = styled.edited && pointer.other == "Other field"

    pointer.text = ""
    await host(PointerFields(model: pointer, colors: colors), size: CGSize(width: 340, height: 220))
    let emptyStyled = await pointerEdit("styled-empty", textFields(in: window).first { placeholder($0) == "Pointer target" },
      in: window) { pointer.text }
    result["styledEmptyTextFieldMousePairAcquiresItsActualNativeFieldEditor"] = emptyStyled.focused
    result["styledEmptyTextFieldPointerTypingUpdatesItsActualBinding"] = emptyStyled.edited && pointer.other == "Other field"

    await host(ThemeEditor(theme: Binding(get: { pointer.theme }, set: { pointer.theme = $0 })),
      size: CGSize(width: 424, height: 800))
    let hexadecimalFields = textFields(in: window).filter { placeholder($0) == "#RRGGBB" }
    let chosenPrimary = pointer.theme.primaryColor, chosenSecondary = pointer.theme.secondaryColor
    let hexField = hexadecimalFields.sorted {
      $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
    }.first
    let hex = await pointerEdit("hex", hexField, in: window) { hexField?.currentEditor()?.string ?? hexField?.stringValue ?? "" }
    result["themeHexadecimalFieldMousePairAcquiresItsActualNativeEditor"] = hexadecimalFields.count == 2 && hex.focused
    result["themeHexadecimalFieldAcceptsActualTypingWithoutCommittingInvalidColor"] = hex.edited
      && pointer.theme.primaryColor == chosenPrimary && pointer.theme.secondaryColor == chosenSecondary

    var paletteState = BrowserState(); paletteState.settings.motionScale = 0
    let paletteStore = BrowserStore(directory: root.appendingPathComponent("pointer-palette"),
      initialState: paletteState, memoryOnly: true)
    let paletteActions = BrowserActions(); paletteActions.palette = true
    await host(NativeCommandPalette(store: paletteStore, actions: paletteActions), size: CGSize(width: 640, height: 440))
    let paletteFields = textFields(in: window).filter { $0 is NativeCommandSearchControl }
    let palette = await pointerEdit("palette", paletteFields.count == 1 ? paletteFields.first : nil,
      in: window) { paletteActions.query }
    result["commandPaletteMousePairRefocusesItsActualSearchField"] = palette.focused
    result["commandPalettePointerAndKeyboardInputUpdatesActualQuery"] = palette.edited

    let findActions = BrowserActions(); findActions.findQuery = "Find seed"
    await host(VStack(spacing: 0) {
      NativeFindBar(actions: findActions, colors: colors).frame(width: 310, height: 32)
      Spacer(minLength: 0)
    }.padding(8), size: CGSize(width: 340, height: 120))
    let findFields = textFields(in: window).filter { placeholder($0) == "Find on page" }
    let find = await pointerEdit("find", findFields.count == 1 ? findFields.first : nil,
      in: window) { findActions.findQuery }
    result["findBarMousePairRefocusesItsActualNativeTextField"] = find.focused
    result["findBarPointerAndKeyboardInputUpdatesActualQuery"] = find.edited

    // The same editor also runs inside a real AppKit popover. The first name
    // click starts with the source window key, so the popover's normal editor
    // and delegated keyboard route are part of the actual event path.
    await host(Text("Owned theme editor anchor").frame(maxWidth: .infinity, maxHeight: .infinity),
      size: CGSize(width: 340, height: 180))
    window.center()
    let popover = NSPopover()
    popover.behavior = .applicationDefined
    let popoverRoot = NSHostingView(rootView: ThemeEditor(
      theme: Binding(get: { pointer.theme }, set: { pointer.theme = $0 }),
      identity: AnyView(NativeSpaceIdentity(
        name: Binding(get: { pointer.spaceName }, set: { pointer.spaceName = $0 }),
        icon: Binding(get: { pointer.icon }, set: { pointer.icon = $0 }), colors: colors, initiallyExpanded: true)),
      saveTitle: "Create Space"))
    popoverRoot.sizingOptions = []
    popoverRoot.frame = NSRect(x: 0, y: 0, width: 424, height: 800)
    let controller = NSViewController(); controller.view = popoverRoot
    popover.contentViewController = controller; popover.contentSize = NSSize(width: 424, height: 800)
    ownedPopover = popover
    if let anchor = window.contentView {
      popover.show(relativeTo: NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1),
        of: anchor, preferredEdge: .maxY)
    }
    let popoverEnd = Date().addingTimeInterval(3)
    while Date() < popoverEnd {
      popoverRoot.layoutSubtreeIfNeeded()
      if popover.isShown, let target = popoverRoot.window, target !== window, target.isVisible {
        ownedPopoverWindow = target
        if textFields(in: target).contains(where: { placeholder($0) == "Space name" }),
          textFields(in: target).contains(where: { placeholder($0) == "Find an icon" }) { break }
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    if let target = ownedPopoverWindow, popover.isShown, controller.view.window === target {
      let nameFields = textFields(in: target).filter { placeholder($0) == "Space name" }
      let iconFields = textFields(in: target).filter { placeholder($0) == "Find an icon" }
      let originalPrimary = pointer.theme.primaryColor, originalSecondary = pointer.theme.secondaryColor
      let iconLabelsBefore = iconLabels(in: target)
      _ = target.makeFirstResponder(nil)
      window.makeKeyAndOrderFront(nil)
      let name = await pointerEdit("popover.name-first-click", nameFields.count == 1 ? nameFields.first : nil,
        in: target, activationOwner: window, keepsEditor: true) { pointer.spaceName }
      let iconField = iconFields.count == 1 ? iconFields.first : nil
      let icon = await pointerEdit("popover.icon", iconField, in: target,
        startingField: nameFields.count == 1 ? nameFields.first : nil, keepsEditor: true, existingEditorRequired: true) {
        (target.firstResponder as? NSTextView)?.string ?? iconField?.stringValue ?? ""
      }
      let expectedIcons = Set(NativeGlyph.spaceNames.filter { $0.localizedCaseInsensitiveContains("z") }
        .map { $0.capitalized + " icon" })
      let filterEnd = Date().addingTimeInterval(3)
      while Date() < filterEnd, iconLabels(in: target) != expectedIcons {
        popoverRoot.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
      }
      let filteredActualIcons = !iconLabelsBefore.isEmpty && iconLabels(in: target) == expectedIcons
      let popoverHexFields = textFields(in: target).filter { placeholder($0) == "#RRGGBB" }
      let popoverHex = popoverHexFields.sorted {
        $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
      }.first
      let hexadecimal = await pointerEdit("popover.hex", popoverHex, in: target,
        startingField: iconField, existingEditorRequired: true) {
        popoverHex?.currentEditor()?.string ?? popoverHex?.stringValue ?? ""
      }
      result["themePopoverFirstClickActivatesOwnedNameEditorAndOtherFieldsRefocus"] =
        name.focused && icon.focused && hexadecimal.focused && popoverHexFields.count == 2
      result["themePopoverNativeTypingUpdatesNameFiltersIconsAndPreservesInvalidHexColor"] =
        name.edited && icon.edited && filteredActualIcons && hexadecimal.edited
          && pointer.theme.primaryColor == originalPrimary && pointer.theme.secondaryColor == originalSecondary
    } else {
      pointerDiagnostics("popover.owned-presentation-missing", in: window)
      result["themePopoverFirstClickActivatesOwnedNameEditorAndOtherFieldsRefocus"] = false
      result["themePopoverNativeTypingUpdatesNameFiltersIconsAndPreservesInvalidHexColor"] = false
    }
    popover.close()
    let closeEnd = Date().addingTimeInterval(3)
    while Date() < closeEnd, popover.isShown || ownedPopoverWindow?.isVisible == true {
      try? await Task.sleep(for: .milliseconds(20))
    }
    if popover.isShown || ownedPopoverWindow?.isVisible == true {
      result["themePopoverNativeTypingUpdatesNameFiltersIconsAndPreservesInvalidHexColor"] = false
      pointerDiagnostics("popover.normal-close-did-not-complete", in: ownedPopoverWindow ?? window)
      // Retain the exact owned popover for the outer cleanup rather than
      // replacing its host while a failed presentation is still visible.
      return result
    }
    ownedPopoverWindow = nil; ownedPopover = nil

    let items = [
      NativeMenuAction(id: "disabled", title: "Unavailable owned action", glyph: "copy", enabled: false, action: { activations += 1 }),
      NativeMenuAction(id: "first", title: "First owned action", glyph: "copy", action: { activations += 1 }),
      NativeMenuAction(id: "second", title: "Second owned action", glyph: "star", action: { activations += 1 }),
    ]
    await host(NativeActionPopover(title: "Owned browser actions", items: items, colors: colors),
      size: CGSize(width: 242, height: 130))
    result["browserActionMenuSkipsDisabledActionAndFocusesActualButton"] =
      await waitForElement("native-menu-action:first")
    let menuDown = keyDown()
    let secondMenuFocused = await waitForElement("native-menu-action:second")
    result["browserActionMenuArrowMovesActualFocusWithoutActivation"] = menuDown
      && secondMenuFocused && activations == 0

    var state = BrowserState()
    let profile = state.profiles[0], space = state.spaces[0]
    let openID = UUID().uuidString, closedID = UUID().uuidString
    let open = BrowserWindowSession(id: openID, activeSpaceID: space.id)
    var closed = BrowserWindowSession(id: closedID, activeSpaceID: space.id)
    closed.isOpen = false; closed.closedAt = Date()
    var saved = BrowserTab(spaceID: space.id, url: "https://example.invalid/owned-saved-window", title: "Owned saved window")
    saved.windowID = closedID; closed.activeTabID = saved.id
    state.tabs = [saved]; state.activeTabID = nil
    state.windowSessions = [open, closed]; state.focusedWindowID = openID
    let historyID = UUID().uuidString
    state.history = [HistoryEntry(id: historyID, profileID: profile.id,
      url: "https://example.invalid/owned-history", title: "Owned history entry")]
    let repository = BrowserRepository(directory: root, initialState: state)
    guard let store = repository.store(for: openID) else {
      result["libraryFocusFixtureHasExactOwnedCoreWindow"] = false
      return result
    }
    let actions = BrowserActions()
    actions.newTab = { _ in activations += 1 }
    actions.libraryCapabilities = ["window:restore"]
    actions.performLibraryAction = { _, _ in activations += 1 }
    actions.library = "History"
    await host(NativeLibrary(store: store, actions: actions, section: "History"),
      size: CGSize(width: 336, height: 420))
    let historySearchFocused = await waitForElement("native-library-search", role: .textField)
    let historyDown = keyDown()
    let historyFocused = await waitForElement("native-library-row:" + historyID)
    result["librarySearchArrowFocusesActualHistoryActionWithoutOpeningIt"] = historySearchFocused && historyDown
      && historyFocused && activations == 0
    result["libraryFocusFixtureRetainsRealClosedWindowAndItsOwnedTab"] =
      repository.savedWindows.contains { $0.id == closedID && $0.tabCount == 1 }
      && repository.canonicalStore.tab(saved.id)?.windowID == closedID
      && repository.windows.first(where: { $0.id == closedID })?.isOpen == false
    // Switch the actual existing Library through its production observed
    // command. Replacing its host in the middle of this focus transaction
    // would race the retiring text field against the new host's onAppear.
    actions.library = "Windows"
    let windowsSearchFocused = await waitForElement("native-library-search", role: .textField)
    let windowsDown = keyDown()
    let savedWindowFocused = await waitForElement("native-library-window:" + closedID)
    result["librarySearchArrowFocusesActualSavedWindowWithoutReopeningIt"] = windowsSearchFocused && windowsDown
      && savedWindowFocused && activations == 0
      && repository.windows.first(where: { $0.id == closedID })?.isOpen == false
    result["browserControlFocusPreservesSystemKeyboardNavigationPreference"] =
      keyboardNavigation == NSApp.isFullKeyboardAccessEnabled
    return result
  }

  @MainActor private final class PointerModel: ObservableObject {
    @Published var text = "Pointer seed"
    @Published var other = "Other field"
    @Published var theme = SpaceTheme()
    @Published var spaceName = ""
    @Published var icon = "circle"
  }
  private static func eventState(_ event: NSEvent?) -> String {
    guard let event else { return "nil" }
    let mouse = event.type == .leftMouseDown || event.type == .leftMouseUp
      || event.type == .rightMouseDown || event.type == .rightMouseUp
      || event.type == .otherMouseDown || event.type == .otherMouseUp
    return "type=\(event.type.rawValue) number=\(mouse ? event.eventNumber : -1) window=\(event.window?.windowNumber ?? -1) timestamp=\(event.timestamp)"
  }

  private static func iconLabels(in window: NSWindow) -> Set<String> {
    guard let root = window.contentView else { return [] }
    let expected = Set(NativeGlyph.spaceNames.map { $0.capitalized + " icon" })
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), labels = Set<String>()
    func object(_ value: NSObject, _ name: String) -> Any? {
      guard value.responds(to: NSSelectorFromString(name)) else { return nil }
      return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    while let item = pending.popLast(), visited.count <= 8_192 {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      if object(item, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
        let label = object(item, "accessibilityLabel") as? String, expected.contains(label) {
        labels.insert(label)
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return labels
  }
  private struct PointerFields: View {
    @ObservedObject var model: PointerModel
    let colors: NativeSpacePalette
    var body: some View {
      VStack(spacing: 16) {
        TextField("Pointer target", text: $model.text)
          .textFieldStyle(NativeChromeTextFieldStyle(colors: colors))
        TextField("Other field", text: $model.other)
          .textFieldStyle(NativeChromeTextFieldStyle(colors: colors))
      }.padding(24)
    }
  }

  private static func focusedElement(in window: NSWindow, identifier: String, role: NSAccessibility.Role) -> Bool {
    guard let root = window.contentView else { return false }
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
    func object(_ value: NSObject, _ name: String) -> Any? {
      guard value.responds(to: NSSelectorFromString(name)) else { return nil }
      return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    while let item = pending.popLast(), visited.count <= 8_192 {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      if object(item, "accessibilityIdentifier") as? String == identifier,
        object(item, "accessibilityRole") as? String == role.rawValue {
        return item.responds(to: NSSelectorFromString("isAccessibilityFocused"))
          && (item.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue == true
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return false
  }

  private static func focusDiagnostics(in window: NSWindow) -> [[String: String]] {
    guard let root = window.contentView else { return [] }
    var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), result = [[String: String]]()
    func object(_ value: NSObject, _ name: String) -> Any? {
      guard value.responds(to: NSSelectorFromString(name)) else { return nil }
      return value.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    while let item = pending.popLast(), visited.count <= 8_192, result.count < 24 {
      guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
      if item is NSWindow { continue }
      if let view = item as? NSView, view.window !== window { continue }
      let identifier = object(item, "accessibilityIdentifier") as? String
      let focused = item.responds(to: NSSelectorFromString("isAccessibilityFocused"))
        && (item.value(forKey: "accessibilityFocused") as? NSNumber)?.boolValue == true
      if identifier?.hasPrefix("native-") == true || focused {
        result.append(["id": identifier ?? "nil", "role": object(item, "accessibilityRole") as? String ?? "nil",
          "label": object(item, "accessibilityLabel") as? String ?? "nil", "focused": String(focused)])
      }
      pending += object(item, "accessibilityChildren") as? [NSObject] ?? []
    }
    return result
  }
}
