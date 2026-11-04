import AppKit
import SwiftUI

/// Own-view layout and pure command-policy checks; no desktop input or provider request.
@MainActor
enum NativeCommandInterfaceAcceptance {
  static func check() async -> [String: Bool] {
    var result: [String: Bool] = [:]
    func ask(_ value: String = "question", scope: String = "all", configured: Bool = true,
      isPrivate: Bool = false, busy: Bool = false) -> String? {
      NativePalettePolicy.askQuery(value, scope: scope, configured: configured, isPrivate: isPrivate, busy: busy)
    }
    result["paletteAskRetainsExactTrimmedQuestion"] = ask("  Explain this page\n") == "Explain this page"
    result["paletteAskRequiresPublicConfiguredIdleContext"] = ask(configured: false) == nil
      && ask(isPrivate: true) == nil && ask(busy: true) == nil
    result["paletteAskRespectsScopeAndEmptyInput"] = ask(" \n") == nil && ask(scope: "action") == nil
      && ask(scope: "tab") == nil
    result["paletteAskBoundsUTF16Input"] = ask(String(repeating: "a", count: 8_000)) != nil
      && ask(String(repeating: "a", count: 8_001)) == nil
      && ask(String(repeating: "😀", count: 4_001)) == nil
    result["paletteSplitUsesExplicitUnsplitPresentation"] = NativePalettePolicy.showsCommand("split", hasVisibleSplit: false)
      && !NativePalettePolicy.showsCommand("split", hasVisibleSplit: true)
      && NativePalettePolicy.showsCommand("unsplit", hasVisibleSplit: true)
      && NativePalettePolicy.showsCommand("find", hasVisibleSplit: true)
    result["paletteCommandAliasesRetainReferenceSearchVocabulary"] = [
      ("preferences", "theme search engine sidebar width"), ("shortcuts", "keybindings hotkeys"),
      ("new-private-space", "incognito private browsing"), ("ai", "assistant codex chatgpt"),
      ("split", "compare side by side"), ("archive", "closed tabs restore"),
      ("save-page", "save as html"), ("copy-url", "copy link address")
    ].allSatisfy { NativePalettePolicy.commandKeywords(id: $0.0).contains($0.1) }
    result["paletteAliasesKeepRuntimeSpecificKeywords"] = NativePalettePolicy.commandKeywords(id: "custom-action", additional: "Custom category")
      == "custom action Custom category"
    result.merge(shortcutChecks()) { _, new in new }
    result.merge(NativeCommandSearchAcceptance.check()) { _, new in new }
    result.merge(NativeSidebarSplitAcceptance.check()) { _, new in new }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    var actions = SiteControlActions()
    actions.url = URL(string: "https://example.com/"); actions.extensionsReady = true
    actions.extensions = (0..<60).map { SiteExtensionItem(id: "extension-\($0)", name: "Extension \($0)") }
    let host = NSHostingView(rootView: SiteControls(actions: actions, maximumHeight: 240))
    host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 304, height: 240)
    window.contentView = host
    await settle(host)
    func scrollView(in view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap(scrollView).first
    }
    guard let scroll = scrollView(in: host), let document = scroll.documentView else {
      result["siteControlsHasBoundedScrollableNativeViewport"] = false
      return result
    }
    result["siteControlsHasBoundedScrollableNativeViewport"] = scroll.bounds.height > 0
      && scroll.bounds.height <= 240.5 && document.bounds.height > scroll.bounds.height + 300
      && abs(host.bounds.width - 304) < 0.5
    let end = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
    scroll.contentView.scroll(to: NSPoint(x: 0, y: end)); scroll.reflectScrolledClipView(scroll.contentView)
    await settle(host)
    let distance = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.maxY : scroll.contentView.bounds.minY
    result["siteControlsCanReachLowerControlsWithManyExtensions"] = abs(distance) < 2

    actions.extensions = []
    host.rootView = SiteControls(actions: actions, maximumHeight: 700)
    host.frame = NSRect(x: 0, y: 0, width: 304, height: 700)
    await settle(host)
    let compactScroll = scrollView(in: host)
    let compactHeight = compactScroll?.bounds.height ?? 0
    result["siteControlsCompactContentDoesNotFillMaximumHeight"] = compactHeight < 600
      && compactHeight > 200 && abs(compactHeight - (compactScroll?.documentView?.bounds.height ?? 0)) < 2
    result["siteControlsViewportClampsShortAndChangedOwnerBounds"] = NativeSiteControlsLayout.height(content: 900, maximum: 240) == 240
      && NativeSiteControlsLayout.height(content: 900, maximum: 380) == 380
      && NativeSiteControlsLayout.height(content: 310, maximum: 700) == 310
    result.merge(await NativeControlFocusAcceptance.check(in: window), uniquingKeysWith: { _, new in new })
    return result
  }

  private static func shortcutChecks() -> [String: Bool] {
    func event(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [],
      ignoring: String? = nil, repeating: Bool = false) -> NSEvent {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
        isARepeat: repeating, keyCode: keyCode)!
    }
    func paired(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags,
      expected: String, ignoring: String? = nil) -> Bool {
      let input = event(keyCode, characters, flags: flags, ignoring: ignoring)
      return NativeShortcutEvent.recordedAccelerator(input) == expected
        && NativeKeyBinding.candidates(input) == [expected]
    }
    let functionKeys: [(UInt16, Int)] = [(105,13), (107,14), (113,15), (106,16), (64,17), (79,18), (80,19), (90,20)]
    var result: [String: Bool] = [:]
    result["browserShortcutExtendedFunctionKeysRecordAndMatch"] = functionKeys.allSatisfy { code, number in
      paired(code, String(UnicodeScalar(0xF704 + number - 1)!), flags: [], expected: "F\(number)")
    } && (21...24).allSatisfy { number in
      paired(0, String(UnicodeScalar(0xF704 + number - 1)!), flags: [.control], expected: "Ctrl+F\(number)")
    }
    result["browserShortcutPhysicalLettersSurviveAlternateLayouts"] = paired(12, "a", flags: [.command], expected: "Mod+Q")
      && paired(1, "ы", flags: [.command], expected: "Mod+S")
      && paired(14, "€", flags: [.control, .option], expected: "Ctrl+Alt+E", ignoring: "e")
    result["browserShortcutPhysicalNumbersAndPunctuationMatchReference"] = paired(18, "&", flags: [.command], expected: "Mod+1")
      && paired(24, "+", flags: [.control, .shift], expected: "Ctrl+Shift+=")
      && paired(33, "{", flags: [.command, .shift], expected: "Mod+Shift+[")
      && paired(42, "|", flags: [.option, .shift], expected: "Alt+Shift+\\")
    result["browserShortcutUnmodifiedTextKeepsLayoutIdentity"] = NativeKeyBinding.candidates(event(12, "a")) == ["A"]
      && NativeKeyBinding.candidates(event(12, "A", flags: [.shift])) == ["Shift+A"]
      && NativeKeyBinding.candidates(event(10, "§", flags: [.option])) == ["Alt+§"]
    result["browserShortcutRecordingIgnoresDeadUnknownAndRepeatedEvents"] = NativeShortcutEvent.recordedAccelerator(event(14, "", flags: [.option])) == nil
      && NativeShortcutEvent.recordedAccelerator(event(14, "Dead", flags: [.option])) == nil
      && NativeShortcutEvent.recordedAccelerator(event(0, "Unidentified")) == nil
      && NativeShortcutEvent.recordedAccelerator(event(0, "a", flags: [.command], repeating: true)) == nil
    result["browserShortcutNamedKeysRetainExactModifiers"] = paired(123, "\u{F702}", flags: [.command], expected: "Mod+Left")
      && paired(117, "\u{F728}", flags: [.control, .option], expected: "Ctrl+Alt+Delete")
      && paired(49, " ", flags: [.command, .shift], expected: "Mod+Shift+Space")
    result["browserShortcutMenuShowsExtendedFunctionsAndNavigation"] = NativeShortcutEvent.menuKeyEquivalent("F1") == "\u{F704}"
      && NativeShortcutEvent.menuKeyEquivalent("F13") == "\u{F710}"
      && NativeShortcutEvent.menuKeyEquivalent("F24") == "\u{F71B}"
      && NativeShortcutEvent.menuKeyEquivalent("Home") == "\u{F729}"
      && NativeShortcutEvent.menuKeyEquivalent("PageDown") == "\u{F72D}"
      && NativeShortcutEvent.menuKeyEquivalent("Delete") == "\u{F728}"
      && NativeShortcutEvent.menuKeyEquivalent("Backspace") == "\u{08}"
    result["browserShortcutMenuPreservesCharactersAndRejectsUnknownNames"] = NativeShortcutEvent.menuKeyEquivalent("Q") == "q"
      && NativeShortcutEvent.menuKeyEquivalent("=") == "=" && NativeShortcutEvent.menuKeyEquivalent("Space") == " "
      && NativeShortcutEvent.menuKeyEquivalent("F25") == nil && NativeShortcutEvent.menuKeyEquivalent("Unknown") == nil
    return result
  }

  private static func settle(_ view: NSView) async {
    for _ in 0..<8 {
      view.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(12))
    }
    view.layoutSubtreeIfNeeded()
  }
}
