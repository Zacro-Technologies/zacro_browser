import AppKit
import CCefAppKit
import Combine
import ZacroCore

/// The construction lane and real native-input fixture use the same owned
/// event builder. It creates values only; dispatch belongs to the caller.
@MainActor enum NativeSpaceScrollEventFactory {
  struct BuiltEvent {
    let event: NSEvent
    let details: String
  }
  static func make(in window: NSWindow, point: NSPoint, deltaX: Double = 0, deltaY: Double = 0,
    phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
    flags: NSEvent.ModifierFlags = [], timestamp: TimeInterval, eventNumber: Int) throws -> BuiltEvent {
    let pixelsX = deltaX.rounded(), pixelsY = deltaY.rounded()
    guard let primaryScreen = NSScreen.screens.first else {
      throw ShortcutError("Native space input has no primary display coordinate authority.")
    }
    let screenPoint = window.convertPoint(toScreen: point)
    let quartzPoint = CGPoint(x: screenPoint.x, y: primaryScreen.frame.maxY - screenPoint.y)
    // Retain the public NSEvent's native window and local-point association.
    // A proper scroll constructor supplies its documented delta metadata.
    guard let seed = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: flags,
      timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
      eventNumber: eventNumber, clickCount: 0, pressure: 0),
      let cgEvent = seed.cgEvent?.copy(),
      let reference = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
        wheelCount: 2, wheel1: Int32(-pixelsY), wheel2: Int32(-pixelsX), wheel3: 0) else {
      throw ShortcutError("No coherent owned native scroll payload could be constructed.")
    }
    let seedWindow = seed.windowNumber, seedPoint = seed.locationInWindow
    let seedQuartzPoint = cgEvent.location
    cgEvent.type = .scrollWheel
    let integerDeltaFields: [CGEventField] = [
      .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
      .scrollWheelEventIsContinuous,
    ]
    for field in integerDeltaFields {
      cgEvent.setIntegerValueField(field, value: reference.getIntegerValueField(field))
    }
    // Fixed-point fields use double accessors according to the public SDK.
    for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1,
      .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3] {
      cgEvent.setDoubleValueField(field, value: reference.getDoubleValueField(field))
    }
    // The owned copy's location is deliberately untouched. Global-location
    // and sequence/Inkwell semantics do not belong in this delta-only copy.
    reference.location = quartzPoint
    for payload in [cgEvent, reference] {
      payload.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
      payload.timestamp = UInt64(timestamp * 1_000_000_000)
      payload.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
      payload.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
    }
    cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
    cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
    guard let event = NSEvent(cgEvent: cgEvent), let referenceEvent = NSEvent(cgEvent: reference) else {
      throw ShortcutError("No coherent owned/reference native scroll event decoded.")
    }
    let details = "eventWindow=\(event.windowNumber) expectedWindow=\(window.windowNumber) type=\(event.type.rawValue) "
      + "point=\(event.locationInWindow) expectedPoint=\(point) deltas=\(event.scrollingDeltaX),\(event.scrollingDeltaY) "
      + "seedWindow=\(seedWindow) seedPoint=\(seedPoint) seedCGPoint=\(seedQuartzPoint) ownedCGPoint=\(cgEvent.location) "
      + "legacyDeltas=\(event.deltaX),\(event.deltaY) referenceLegacyDeltas=\(referenceEvent.deltaX),\(referenceEvent.deltaY) referencePreciseDeltas=\(referenceEvent.scrollingDeltaX),\(referenceEvent.scrollingDeltaY) "
      + "phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) precise=\(event.hasPreciseScrollingDeltas) "
      + "expectedQuartzPoint=\(quartzPoint) decodedQuartzPoint=\(String(describing: event.cgEvent?.location)) decodedCGWindow=\(event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointer) ?? -1)"
    let contactMatches = phase == nil ? event.phase.isEmpty
      : phase == .began ? event.phase.contains(.began)
      : phase == .changed ? event.phase.contains(.changed)
      : phase == .ended ? event.phase.contains(.ended)
      : phase == .cancelled ? event.phase.contains(.cancelled)
      : phase == .mayBegin ? event.phase.contains(.mayBegin) : false
    let momentumMatches = momentum == .none ? event.momentumPhase.isEmpty
      : momentum == .begin ? event.momentumPhase.contains(.began)
      : momentum.rawValue == 2 ? event.momentumPhase.contains(.changed)
      : momentum == .end ? event.momentumPhase.contains(.ended) : false
    guard event.type == .scrollWheel, event.window === window, event.hasPreciseScrollingDeltas,
      abs(event.locationInWindow.x - point.x) < 0.5, abs(event.locationInWindow.y - point.y) < 0.5,
      abs(Double(event.scrollingDeltaX) + pixelsX) < 0.5, abs(Double(event.scrollingDeltaY) + pixelsY) < 0.5,
      abs(event.deltaX - referenceEvent.deltaX) < 0.000_1, abs(event.deltaY - referenceEvent.deltaY) < 0.000_1,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == flags.intersection(.deviceIndependentFlagsMask),
      contactMatches, momentumMatches else {
      throw ShortcutError("A native scroll event did not preserve its exact owned window, point, deltas, flags or phases: " + details)
    }
    return BuiltEvent(event: event, details: details)
  }
}

/// Delivers scroll NSEvents through NSApplication's local-monitor path over
/// the actual browser rail and its nested native scroll views. These events
/// stay in this disposable process; no desktop/trackpad input is posted.
/// Physical trackpad feel and OS gesture preferences require separate review.
@MainActor enum NativeSpaceGestureAcceptance {
  /// Validates the shared constructor against the real owned shell without
  /// sending an event, creating tabs, changing focus, or mutating the window.
  static func checkConstruction(in window: NSWindow) -> [String: Bool] {
    let authority = "spaceInputConstructionUsesExactOwnedNativeWindow"
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      window.identifier?.rawValue.hasPrefix("ZacroBrowserWindow:") == true,
      let root = window.contentView, root.window === window,
      root.bounds.width > 100, root.bounds.height > 100 else { return [authority: false] }
    let top = NSPoint(x: root.bounds.midX, y: root.isFlipped ? root.bounds.minY + 12 : root.bounds.maxY - 12)
    let center = NSPoint(x: root.bounds.midX, y: root.bounds.midY)
    let bottom = NSPoint(x: root.bounds.midX, y: root.isFlipped ? root.bounds.maxY - 12 : root.bounds.minY + 12)
    typealias Case = (name: String, point: NSPoint, dx: Double, dy: Double,
      phase: CGScrollPhase?, momentum: CGMomentumScrollPhase, flags: NSEvent.ModifierFlags)
    let cases: [Case] = [
      ("TopHorizontalBegan", top, 60, 0, .began, .none, []),
      ("CenterVerticalBegan", center, 0, 60, .began, .none, []),
      ("BottomHorizontalChanged", bottom, -80, 0, .changed, .none, []),
      ("CenterVerticalChanged", center, 0, -80, .changed, .none, []),
      ("TopReleasedContact", top, 0, 0, .ended, .none, []),
      ("BottomCancelledContact", bottom, 0, 0, .cancelled, .none, []),
      ("TopMomentumBegan", top, 2_000, 0, nil, .begin, []),
      ("CenterMomentumChanged", center, 2_000, 0, nil, CGMomentumScrollPhase(rawValue: 2)!, []),
      ("BottomMomentumEnded", bottom, 2_000, 0, nil, .end, []),
      ("CenterCommandModifier", center, 60, 0, .began, .none, .command),
      ("BottomShiftModifier", bottom, 0, 80, .changed, .none, .shift),
    ]
    var checks = [authority: true]
    for (index, item) in cases.enumerated() {
      let name = "spaceInputConstruction" + item.name
      do {
        let built = try NativeSpaceScrollEventFactory.make(in: window,
          point: root.convert(item.point, to: nil), deltaX: item.dx, deltaY: item.dy,
          phase: item.phase, momentum: item.momentum, flags: item.flags,
          timestamp: ProcessInfo.processInfo.systemUptime, eventNumber: 1_000 + index)
        checks[name] = true
        fputs("Native space construction PASS: \(name): \(built.details)\n", stderr)
      } catch {
        checks[name] = false
        fputs("Native space construction FAIL: \(name): \(String(error.localizedDescription.prefix(2_000)))\n", stderr)
      }
    }
    return checks
  }

  static func run(application: ApplicationCoordinator, url: URL,
    originalOwner: BrowserWindowCoordinator) async throws -> [String] {
    guard CommandLine.arguments.contains("--engine-acceptance"),
      CommandLine.arguments.contains("--native-integration-acceptance"),
      url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
      throw ShortcutError("Native space input requires the disposable loopback browser.")
    }
    originalOwner.windowContext.show()
    application.repository.focusWindow(originalOwner.windowContext.id)
    let existing = Set(application.windows.keys)
    application.newWindow()
    let added = application.windows.values.filter {
      !existing.contains($0.windowContext.id) && $0.windowContext.isOpen && !$0.windowContext.isClosing
    }
    guard added.count == 1, let owner = added.first else {
      throw ShortcutError("No exact native space-input fixture owner.")
    }
    let window = owner.windowContext.window
    let previousSidebar = owner.store.state.settings.sidebarVisible
    var checks = [String](), fixtureSpaces = [String](), selectionChanges = [String]()
    var eventNumber = 0
    let tracesInput = ProcessInfo.processInfo.environment["ZACRO_NATIVE_SPACE_INPUT_TRACE"] == "1"
    let observesSecondaryInput = tracesInput
      && ProcessInfo.processInfo.environment["ZACRO_NATIVE_SPACE_SECONDARY_MONITOR"] == "1"
    var details = ""
    let selection = owner.store.$state.map(\.activeSpaceID).removeDuplicates().dropFirst().sink {
      selectionChanges.append($0)
    }
    defer { selection.cancel() }
    func require(_ value: Bool, _ name: String) throws {
      fputs("Native space input check \(value ? "PASS" : "FAIL"): \(name)\n", stderr)
      guard value else { throw ShortcutError("Native space input failed: " + name + ": " + details) }
      checks.append(name)
    }
    func wait(_ name: String, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try Task.checkCancellation()
        guard owner.windowContext.isOpen, !owner.windowContext.isClosing else { throw CancellationError() }
        if condition() { return }
        try await Task.sleep(for: .milliseconds(25))
      }
      throw ShortcutError("Native space input timed out: " + name + ": " + details)
    }
    func cleanup() async {
      if owner.windowContext.isOpen { _ = await owner.requestCloseWindow() }
      if originalOwner.windowContext.isOpen {
        for id in fixtureSpaces { originalOwner.store.deleteSpace(id: id) }
        originalOwner.store.updateSettings { $0.sidebarVisible = previousSidebar }
        originalOwner.windowContext.show()
      }
    }
    func descendants(_ root: NSView) -> [NSView] {
      var pending = [root], result = [NSView]()
      while let view = pending.popLast(), result.count < 8_192 {
        guard view.window === window else { continue }
        result.append(view); pending += view.subviews
      }
      return result
    }
    func rail() throws -> NSView {
      guard let root = window.contentView else { throw ShortcutError("No owned native space root.") }
      let matches = descendants(root).filter {
        $0.identifier?.rawValue == "NativeSpaceGestureSurface" && !$0.isHiddenOrHasHiddenAncestor
          && $0.visibleRect.width > 100 && $0.visibleRect.height > 100
      }
      guard matches.count == 1, let host = matches.first else {
        throw ShortcutError("No unique visible native space rail: \(matches.count).")
      }
      return host
    }
    func rowTarget() throws -> (NSScrollView, NSPoint) {
      let host = try rail()
      let scrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter {
        !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.height > 80 && $0.visibleRect.width > 100
      }.sorted { $0.visibleRect.height > $1.visibleRect.height }
      for scroll in scrolls {
        let rect = scroll.contentView.visibleRect
        let point = scroll.contentView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let root = window.contentView else { continue }
        let rootPoint = root.superview?.convert(point, from: nil) ?? point
        guard let hit = root.hitTest(rootPoint), hit === scroll || hit.isDescendant(of: scroll),
          hit.isDescendant(of: host) else { continue }
        details = "rail=\(host.frame) scroll=\(scroll.frame) hit=\(String(reflecting: type(of: hit))) point=\(point)"
        return (scroll, point)
      }
      throw ShortcutError("The visible rail has no actually hit nested native scroll view: " + details)
    }
    @discardableResult func send(point: NSPoint, dx: Double = 0, dy: Double = 0,
      phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
      flags: NSEvent.ModifierFlags = [], after: TimeInterval = 0.02) async throws -> TimeInterval {
      // AppKit receives real monotonic event times. A clock captured before
      // fixture creation becomes stale in a busy full run; invented future
      // timestamps also make held-contact timing differ from native input.
      if after > 0 { try await Task.sleep(for: .seconds(after)) }
      guard let nativeDispatch = NSApp as? any CrAppProtocol else {
        throw ShortcutError("Native space input requires the public CEF application event-dispatch protocol.")
      }
      // A task continuation can run inside a nested AppKit/CEF sendEvent call.
      // Wait for that public scope to unwind before dispatching our own event;
      // never clear or otherwise mutate the application's native input flag.
      let dispatchDeadline = ProcessInfo.processInfo.systemUptime + 3
      while nativeDispatch.isHandlingSendEvent() {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < dispatchDeadline else {
          throw ShortcutError("Native space fixture did not leave its existing native sendEvent scope within three seconds.")
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      // Recheck admission after the bounded wait. No suspension follows this
      // guard until the exact owned event has been synchronously dispatched.
      guard owner.windowContext.isOpen, window.isVisible, NSApp.isActive,
        NSEvent.pressedMouseButtons == 0, NSApp.modalWindow == nil, window.attachedSheet == nil else {
        throw ShortcutError("Native space fixture lost actual foreground/admission before input.")
      }
      let eventTime = ProcessInfo.processInfo.systemUptime
      eventNumber += 1
      let built = try NativeSpaceScrollEventFactory.make(in: window, point: point,
        deltaX: dx, deltaY: dy, phase: phase, momentum: momentum, flags: flags,
        timestamp: eventTime, eventNumber: eventNumber)
      let event = built.event
      details = built.details
      let handlingBefore = nativeDispatch.isHandlingSendEvent()
      guard !handlingBefore else {
        throw ShortcutError("Native space fixture unexpectedly reentered a native sendEvent scope before dispatch.")
      }
      func eventState(_ candidate: NSEvent?) -> String {
        guard let candidate else { return "nil" }
        let base = "type=\(candidate.type.rawValue) window=\(candidate.windowNumber) timestamp=\(candidate.timestamp) "
          + "point=\(candidate.locationInWindow) modifiers=\(candidate.modifierFlags.rawValue)"
        guard candidate.type == .scrollWheel else { return base }
        return base + " phase=\(candidate.phase.rawValue) momentum=\(candidate.momentumPhase.rawValue) "
          + "precise=\(candidate.hasPreciseScrollingDeltas) inverted=\(candidate.isDirectionInvertedFromDevice) preciseDeltas=\(candidate.scrollingDeltaX),\(candidate.scrollingDeltaY) "
          + "legacyDeltas=\(candidate.deltaX),\(candidate.deltaY),\(candidate.deltaZ)"
      }
      func mismatches(_ candidate: NSEvent?) -> [String] {
        guard let candidate else { return ["missing"] }
        var result = [String]()
        guard candidate.type == event.type else { return ["type"] }
        if candidate.window !== event.window { result.append("window") }
        // Posted AppKit events reconstruct their timestamps in nanoseconds.
        if abs(candidate.timestamp - event.timestamp) > 0.000_000_001 { result.append("timestamp") }
        if candidate.locationInWindow != event.locationInWindow { result.append("location") }
        if candidate.phase != event.phase { result.append("contactPhase") }
        if candidate.momentumPhase != event.momentumPhase { result.append("momentumPhase") }
        if candidate.hasPreciseScrollingDeltas != event.hasPreciseScrollingDeltas { result.append("precise") }
        if candidate.isDirectionInvertedFromDevice != event.isDirectionInvertedFromDevice { result.append("directionInversion") }
        if candidate.scrollingDeltaX != event.scrollingDeltaX || candidate.scrollingDeltaY != event.scrollingDeltaY {
          result.append("preciseDeltas")
        }
        if candidate.deltaX != event.deltaX || candidate.deltaY != event.deltaY || candidate.deltaZ != event.deltaZ {
          result.append("legacyDeltas")
        }
        if candidate.modifierFlags != event.modifierFlags { result.append("modifiers") }
        return result
      }
      // Establish AppKit's actual current-event context through this process's
      // own queue. Retrieve only this exact posted scroll, never drain input,
      // and keep dispatch through NSApplication's production local monitors.
      // This does not post to WindowServer or invoke a recognizer/window path.
      NSApp.postEvent(event, atStart: true)
      let retrieved = NSApp.nextEvent(matching: .scrollWheel, until: Date(), inMode: .default, dequeue: true)
      let dequeueMismatches = mismatches(retrieved)
      let currentMismatches = mismatches(NSApp.currentEvent)
      fputs("Native space dequeue receipt: expected={\(eventState(event))} retrieved={\(eventState(retrieved))} current={\(eventState(NSApp.currentEvent))} exact=\(dequeueMismatches.isEmpty) currentExact=\(currentMismatches.isEmpty) sameObject=\(retrieved === event) mismatches=\(dequeueMismatches) currentMismatches=\(currentMismatches)\n", stderr)
      guard dequeueMismatches.isEmpty, let retrieved else {
        if let retrieved { NSApp.postEvent(retrieved, atStart: true) }
        throw ShortcutError("Native space input did not dequeue its exact owned scroll event: \(dequeueMismatches): " + details)
      }
      guard currentMismatches.isEmpty else {
        throw ShortcutError("Native space input did not establish its exact native current-event context: \(currentMismatches): " + details)
      }
      guard !nativeDispatch.isHandlingSendEvent(), owner.windowContext.isOpen,
        window.isVisible, NSApp.isActive, NSEvent.pressedMouseButtons == 0,
        NSApp.modalWindow == nil, window.attachedSheet == nil else {
        throw ShortcutError("Native space fixture lost actual foreground/admission after dequeuing its owned input.")
      }
      var secondaryMonitor: Any?
      var secondaryReceipts = 0
      defer { if let secondaryMonitor { NSEvent.removeMonitor(secondaryMonitor) } }
      if observesSecondaryInput {
        let pendingTime = event.timestamp
        let pendingPhase = event.phase.rawValue, pendingMomentum = event.momentumPhase.rawValue
        let pendingX = event.scrollingDeltaX, pendingY = event.scrollingDeltaY
        // Observe this exact pending input without assuming that AppKit keeps
        // its decoded NSWindow identity unchanged during application dispatch.
        // This monitor never consumes, replaces, posts, or retargets an event.
        secondaryMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { candidate in
          MainActor.assumeIsolated {
            guard abs(candidate.timestamp - pendingTime) < 0.000_001,
              candidate.phase.rawValue == pendingPhase, candidate.momentumPhase.rawValue == pendingMomentum,
              abs(candidate.scrollingDeltaX - pendingX) < 0.5,
              abs(candidate.scrollingDeltaY - pendingY) < 0.5 else { return }
            secondaryReceipts += 1
            let observedCG = candidate.cgEvent
            fputs("Native space secondary receipt: expectedWindow=\(window.windowNumber) observedWindow=\(candidate.windowNumber) windowClass=\(candidate.window.map { String(reflecting: type(of: $0)) } ?? "nil") sameEvent=\(candidate === event) timestamp=\(candidate.timestamp) phase=\(candidate.phase.rawValue) momentum=\(candidate.momentumPhase.rawValue) dx=\(candidate.scrollingDeltaX) dy=\(candidate.scrollingDeltaY) cgWindow=\(observedCG?.getIntegerValueField(.mouseEventWindowUnderMousePointer) ?? -1) cgHandlingWindow=\(observedCG?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? -1)\n", stderr)
          }
          return candidate
        }
      }
      if tracesInput {
        fputs("Native space input dispatch before: \(details) handlingSendEvent=\(handlingBefore) runLoopMode=\(RunLoop.main.currentMode?.rawValue ?? "nil") windowKey=\(window.isKeyWindow) appKeyWindow=\(NSApp.keyWindow?.windowNumber ?? -1) appRunning=\(NSApp.isRunning) secondaryMonitor=\(secondaryMonitor != nil) cgWindow=\(event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointer) ?? -1) cgHandlingWindow=\(event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? -1) palette=\(owner.actions.palette) paletteWindow=\(owner.actions.paletteWindow != nil) paletteVisible=\(owner.actions.paletteWindow?.isVisible == true) presentation=\(owner.actions.interfacePresentationState().sorted()) responder=\(window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil")\n", stderr)
      }
      func logRailLiveness(_ stage: String) {
        guard tracesInput else { return }
        do {
          let actualRail = try rail()
          let snapshot = NativeSpaceGestureDiagnostics.snapshot(of: actualRail) ?? "unsupported-actual-rail"
          fputs("Native space rail liveness: stage=\(stage) eventWindow=\(retrieved.windowNumber) phase=\(retrieved.phase.rawValue) momentum=\(retrieved.momentumPhase.rawValue) actualRail=\(ObjectIdentifier(actualRail)) state={\(snapshot)}\n", stderr)
        } catch {
          fputs("Native space rail liveness: stage=\(stage) lookupFailed=\(String(error.localizedDescription.prefix(1_000)))\n", stderr)
        }
      }
      logRailLiveness("before-send")
      NSApp.sendEvent(retrieved)
      logRailLiveness("after-send")
      if tracesInput {
        fputs("Native space input dispatch after: window=\(window.windowNumber) phase=\(event.phase.rawValue) handlingSendEvent=\(nativeDispatch.isHandlingSendEvent()) runLoopMode=\(RunLoop.main.currentMode?.rawValue ?? "nil") windowKey=\(window.isKeyWindow) appKeyWindow=\(NSApp.keyWindow?.windowNumber ?? -1) appRunning=\(NSApp.isRunning) secondaryReceipts=\(secondaryReceipts) selections=\(selectionChanges.count) palette=\(owner.actions.palette)\n", stderr)
      }
      return event.timestamp
    }
    func settle(_ id: String) async throws {
      try await wait("selected fixture space") {
        owner.store.state.activeSpaceID == id && !owner.actions.palette && owner.actions.paletteWindow == nil
          && owner.actions.contentFrame.minX > 180
      }
      try await Task.sleep(for: .milliseconds(280))
    }
    func select(_ id: String) async throws {
      owner.store.selectSpace(id: id)
      try await settle(id)
      _ = try rowTarget()
      selectionChanges.removeAll()
    }
    do {
      owner.actions.palette = false; owner.actions.library = nil
      owner.store.updateSettings { $0.sidebarVisible = true }
      // Nonblank tabs keep the production empty-space palette from correctly
      // blocking gestures while this fixture is checking the visible rail.
      for index in 0..<6 {
        let space = owner.store.createSpace(name: "Native swipe fixture \(index)")
        fixtureSpaces.append(space.id)
        guard owner.store.createTab(address: url.appendingPathComponent("native-space-\(index)").absoluteString) != nil else {
          throw ShortcutError("No exact native swipe fixture tab.")
        }
      }
      owner.store.selectSpace(id: fixtureSpaces[1])
      for index in 0..<24 {
        guard owner.store.createTab(address: url.appendingPathComponent("native-space-overflow-\(index)").absoluteString,
          activate: false) != nil else { throw ShortcutError("No native vertical scroll fixture row.") }
      }
      owner.actions.palette = false
      try await select(fixtureSpaces[1])
      let (scroll, point) = try rowTarget()
      let nativeOffset = scroll.contentView.bounds.origin
      try require(try rail().bounds.height > 400 && scroll.window === window,
        "spaceSwipeUsesActualWholeRailAndNestedNativeScrollHit")
      let quickBegan = try await send(point: point, dx: 60, phase: .began)
      // Dispatch one real native burst without yielding into expensive initial
      // page/layout work between phases. Timestamps remain actual uptime.
      try await send(point: point, dx: 190, phase: .changed, after: 0)
      let quickEnded = try await send(point: point, phase: .ended, after: 0)
      guard quickEnded - quickBegan <= 0.220 else {
        throw ShortcutError("Native space fixture could not deliver an actual quick flick within 220 ms: \((quickEnded - quickBegan) * 1_000) ms.")
      }
      try await settle(fixtureSpaces[2])
      let quickEventDetails = details
      var currentTargetDetails = "unavailable"
      do {
        let (currentScroll, currentPoint) = try rowTarget()
        currentTargetDetails = "identity=\(ObjectIdentifier(currentScroll)) sameAsOriginal=\(currentScroll === scroll) window=\(currentScroll.window?.windowNumber ?? -1) point=\(currentPoint) clipOrigin=\(currentScroll.contentView.bounds.origin) clipBounds=\(currentScroll.contentView.bounds) documentBounds=\(String(describing: currentScroll.documentView?.bounds)) contentInsets=\(currentScroll.contentInsets) autoAdjustInsets=\(currentScroll.automaticallyAdjustsContentInsets)"
      } catch {
        currentTargetDetails = "lookupFailed=\(String(error.localizedDescription.prefix(1_000)))"
      }
      details = quickEventDetails + " quickActualSpace=\(owner.store.state.activeSpaceID) quickExpectedSpace=\(fixtureSpaces[2]) selectionChanges=\(selectionChanges) "
        + "originalScroll=\(ObjectIdentifier(scroll)) capturedOrigin=\(nativeOffset) observedOrigin=\(scroll.contentView.bounds.origin) oldScrollWindow=\(scroll.window?.windowNumber ?? -1) oldScrollStillOwned=\(scroll.window === window) oldScrollAttached=\(scroll.superview != nil) "
        + "oldDocumentBounds=\(String(describing: scroll.documentView?.bounds)) oldClipBounds=\(scroll.contentView.bounds) oldClipVisibleRect=\(scroll.contentView.visibleRect) oldContentInsets=\(scroll.contentInsets) oldAutoAdjustInsets=\(scroll.automaticallyAdjustsContentInsets) currentTarget={\(currentTargetDetails)}"
      let originDeltaX = scroll.contentView.bounds.origin.x - nativeOffset.x
      let originDeltaY = scroll.contentView.bounds.origin.y - nativeOffset.y
      let backingScale = max(1, window.backingScaleFactor)
      // Native host motion can round the horizontal clip origin by a pixel;
      // vertical content must remain within half a backing pixel.
      let horizontalTolerance = 1 / backingScale, verticalTolerance = 0.5 / backingScale
      details += " nativeOriginDelta=(\(originDeltaX),\(originDeltaY)) nativeOriginTolerance=(\(horizontalTolerance),\(verticalTolerance)) backingScale=\(backingScale)"
      fputs("Native space quick selection receipt: \(details)\n", stderr)
      try require(selectionChanges == [fixtureSpaces[2]]
        && abs(originDeltaX) <= horizontalTolerance && abs(originDeltaY) <= verticalTolerance,
        "nativeScrollMonitorBypassesNestedScrollViewAndQuickFlickSelectsOneNeighborOnce")

      let (_, momentumPoint) = try rowTarget()
      // CoreGraphics' continuation phase is value 2; its C name ends in the
      // Swift keyword `Continue`, which is not imported as a named member.
      for phase: CGMomentumScrollPhase in [.begin, CGMomentumScrollPhase(rawValue: 2)!, .end] {
        try await send(point: momentumPoint, dx: 2_000, momentum: phase, after: 0.16)
      }
      try await Task.sleep(for: .milliseconds(360))
      try require(owner.store.state.activeSpaceID == fixtureSpaces[2] && selectionChanges == [fixtureSpaces[2]],
        "nativeMomentumTailNeverChangesSpaceOrAddsFingerTravel")

      try await select(fixtureSpaces[0])
      let (_, longPoint) = try rowTarget(), width = Double(try rail().bounds.width)
      try await send(point: longPoint, dx: width * 0.4, phase: .began)
      // Native contact remains held across this pause; no quiet timer is
      // permitted to release or revert a real phase-bearing gesture.
      try await Task.sleep(for: .milliseconds(400))
      try require(owner.store.state.activeSpaceID == fixtureSpaces[0] && selectionChanges.isEmpty,
        "nativeHeldContactDoesNotReleaseOnAnIdleTimeout")
      try await send(point: longPoint, dx: width * 2.6, phase: .changed, after: 0.1)
      // Let the actual strip put an inactive, noninteractive preview under
      // the pointer. The terminal NSEvent must retain its admitted stream,
      // rather than relying on a descendant that moved out from under it. The
      // gated adapter trace records when this actual capture path is used.
      try await send(point: longPoint, phase: .ended, after: 0.05)
      try await settle(fixtureSpaces[3])
      try require(selectionChanges == [fixtureSpaces[3]],
        "nativeLongContactCrossesMultipleSpacesAndSnapsToOneFinalSpace")

      try await select(fixtureSpaces[1])
      let (verticalScroll, guardPoint) = try rowTarget()
      try require((verticalScroll.documentView?.bounds.height ?? 0) > verticalScroll.contentView.bounds.height + 100,
        "nativeVerticalScrollFixtureHasActualOverflowingTabRows")
      func verticalOffset() -> CGFloat? {
        guard let document = verticalScroll.documentView else { return nil }
        let clip = verticalScroll.contentView.bounds
        return document.isFlipped ? clip.minY - document.bounds.minY : document.bounds.maxY - clip.maxY
      }
      guard let verticalDocument = verticalScroll.documentView, let startingOffset = verticalOffset() else {
        throw ShortcutError("Native vertical input lost its actual overflowing document.")
      }
      let clip = verticalScroll.contentView
      let maximumOffset = max(0, verticalDocument.bounds.height - clip.bounds.height)
      // The active row's restored position can already be at either edge.
      // Choose actual available content instead of assuming downward room.
      let boundedOffset = min(maximumOffset, max(0, startingOffset))
      let availableUp = boundedOffset, availableDown = maximumOffset - boundedOffset
      let verticalDirection: CGFloat = availableDown >= availableUp ? 1 : -1
      let chosenRoom = verticalDirection > 0 ? availableDown : availableUp
      guard chosenRoom > 1 else {
        throw ShortcutError("Native vertical input has no available content in its selected scroll direction.")
      }
      func verticalSnapshot(_ stage: String) {
        let savedDetails = details
        defer { details = savedDetails }
        func describe(_ nativeScroll: NSScrollView) -> String {
          let nativeClip = nativeScroll.contentView, document = nativeScroll.documentView
          let normalizedOffset = document.map {
            $0.isFlipped ? nativeClip.bounds.minY - $0.bounds.minY : $0.bounds.maxY - nativeClip.bounds.maxY
          }
          return "scroll=\(ObjectIdentifier(nativeScroll)) clip=\(ObjectIdentifier(nativeClip)) document=\(document.map { String(describing: ObjectIdentifier($0)) } ?? "nil") "
            + "window=\(nativeScroll.window?.windowNumber ?? -1) attached=\(nativeScroll.superview != nil) hidden=\(nativeScroll.isHiddenOrHasHiddenAncestor) "
            + "scrollVisibleRect=\(nativeScroll.visibleRect) clipBounds=\(nativeClip.bounds) clipVisibleRect=\(nativeClip.visibleRect) "
            + "documentBounds=\(String(describing: document?.bounds)) documentFlipped=\(String(describing: document?.isFlipped)) normalizedOffset=\(String(describing: normalizedOffset))"
        }
        var current = "unavailable"
        do {
          let (nativeScroll, nativePoint) = try rowTarget()
          current = "sameAsOriginal=\(nativeScroll === verticalScroll) point=\(nativePoint) " + describe(nativeScroll)
        } catch { current = "lookupFailed=\(String(error.localizedDescription.prefix(1_000)))" }
        var hitChain = [String]()
        if let root = window.contentView {
          let rootPoint = root.superview?.convert(guardPoint, from: nil) ?? guardPoint
          var hit = root.hitTest(rootPoint)
          while let view = hit, hitChain.count < 8, view.window === window {
            hitChain.append("\(String(reflecting: type(of: view))):\(view.identifier?.rawValue ?? "nil")")
            hit = view.superview
          }
        }
        fputs("Native space vertical identity: stage=\(stage) owner=\(window.windowNumber) activeSpace=\(owner.store.state.activeSpaceID) original={\(describe(verticalScroll))} current={\(current)} inputPoint=\(guardPoint) hitChain=\(hitChain) directedMovement=\(verticalOffset().map { verticalDirection * ($0 - startingOffset) } ?? 0)\n", stderr)
      }
      if tracesInput {
        fputs("Native space vertical geometry: window=\(window.windowNumber) nativeOrigin=\(clip.bounds.origin) documentBounds=\(verticalDocument.bounds) documentIsFlipped=\(verticalDocument.isFlipped) clipBounds=\(clip.bounds) clipVisibleRect=\(clip.visibleRect) normalizedOffset=\(startingOffset) maximumOffset=\(maximumOffset) availableUp=\(availableUp) availableDown=\(availableDown) direction=\(verticalDirection) chosenRoom=\(chosenRoom)\n", stderr)
      }
      do {
        verticalSnapshot("before-began")
        try await send(point: guardPoint, dy: Double(verticalDirection) * 60, phase: .began)
        verticalSnapshot("after-began")
        try await send(point: guardPoint, dy: Double(verticalDirection) * 80, phase: .changed)
        verticalSnapshot("after-changed")
        try await send(point: guardPoint, phase: .ended)
        verticalSnapshot("after-ended")
        try await wait("actual nested vertical scrolling toward available content") {
          verticalOffset().map { verticalDirection * ($0 - startingOffset) > 0.5 } ?? false
        }
      } catch {
        verticalSnapshot("failure")
        throw error
      }
      let verticalMovement = verticalOffset().map { verticalDirection * ($0 - startingOffset) } ?? 0
      if tracesInput {
        fputs("Native space vertical movement: window=\(window.windowNumber) normalizedOffset=\(String(describing: verticalOffset())) directedMovement=\(verticalMovement) spaceUnchanged=\(owner.store.state.activeSpaceID == fixtureSpaces[1] && selectionChanges.isEmpty)\n", stderr)
      }
      try require(verticalMovement > 0.5 && owner.store.state.activeSpaceID == fixtureSpaces[1] && selectionChanges.isEmpty,
        "nativeVerticalInputReachesNestedScrollViewWithoutSelectingAnotherSpace")
      try await send(point: guardPoint, dx: 190, phase: .began, flags: .command)
      try await send(point: guardPoint, phase: .ended, flags: .command)
      guard let root = window.contentView else { throw ShortcutError("Native space root disappeared.") }
      let outside = root.convert(NSPoint(x: root.bounds.maxX - 16, y: root.bounds.midY), to: nil)
      try await send(point: outside, dx: 190, phase: .began)
      try await send(point: outside, phase: .ended)
      try await Task.sleep(for: .milliseconds(300))
      try require(owner.store.state.activeSpaceID == fixtureSpaces[1] && selectionChanges.isEmpty,
        "nativeVerticalModifiedAndOutsideRailScrollLeaveSpaceSelectionUntouched")

      owner.actions.openPalette()
      try await wait("actual palette blocks rail input") { owner.actions.paletteWindow?.isVisible == true }
      try await send(point: guardPoint, dx: 190, phase: .began)
      try await send(point: guardPoint, phase: .ended)
      try await Task.sleep(for: .milliseconds(240))
      try require(owner.actions.palette && owner.store.state.activeSpaceID == fixtureSpaces[1] && selectionChanges.isEmpty,
        "nativePresentedPaletteBlocksBackgroundRailSwipes")
      owner.actions.palette = false
      try await wait("palette retired") { owner.actions.paletteWindow == nil }

      let host = try rail()
      let footer = host.convert(NSPoint(x: host.bounds.midX,
        y: host.isFlipped ? host.bounds.maxY - 14 : host.bounds.minY + 14), to: nil)
      try await send(point: footer, dx: -140, phase: .began)
      try await send(point: footer, phase: .ended, after: 0.04)
      try await settle(fixtureSpaces[0])
      try require(selectionChanges == [fixtureSpaces[0]],
        "nativeRailFooterUsesSameSpaceGestureRouteAsTabRows")
      await cleanup()
      return checks
    } catch {
      await cleanup()
      throw error
    }
  }
}
