import AppKit
import SwiftUI
import ZacroCore

/// Creation and rename drafts stay visible when a durable write fails.
struct NativeNameEditor: View {
  let title: String
  @Binding var name: String
  var limit = 60
  var saveTitle = "Save"
  var fieldLabel = "Name"
  var error: String?
  var canSave = true
  let colors: NativeSpacePalette
  let save: () -> Void
  let cancel: () -> Void
  @FocusState private var focused: Bool
  private var valid: Bool { canSave && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: 17, weight: .semibold))
      TextField(fieldLabel, text: Binding(get: { name }, set: { name = String($0.prefix(limit)) }))
        .textFieldStyle(.plain).padding(10).background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .focused($focused).onSubmit { if valid { save() } }
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      HStack {
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).buttonStyle(.plain)
          .padding(.horizontal, 12).padding(.vertical, 7).background(colors.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        Spacer()
        Button(saveTitle, action: save).keyboardShortcut(.defaultAction).buttonStyle(.plain).disabled(!valid)
          .padding(.horizontal, 12).padding(.vertical, 7)
          .foregroundStyle(colors.dark ? Color(red: 43 / 255, green: 23 / 255, blue: 32 / 255) : .white)
          .background(colors.accent.opacity(valid ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 8))
      }
    }.padding(20).frame(width: 400).font(.system(size: 13)).foregroundStyle(colors.ink).tint(colors.accent)
      .background { NativeControlSurface().overlay(colors.chrome.opacity(0.65)) }
      .onAppear { focused = true }
  }
}

enum NativeInterfaceEditor: String, Identifiable {
  case shortcuts, profiles, onboarding, permissions, spaces
  var id: String { rawValue }
}

struct NativeInterfaceEditors: View {
  @ObservedObject var store: BrowserStore
  @ObservedObject var actions: BrowserActions
  let destination: NativeInterfaceEditor
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.presentedSpaceTheme) private var presentedTheme
  @State private var query = ""
  @State private var recording: String?
  @State private var recordingSession = UUID()
  @State private var error: String?
  @State private var profileName = ""
  @State private var tourStep = 0
  @State private var renameProfile: BrowserProfile?
  private var colors: NativeSpacePalette {
    let theme = presentedTheme ?? store.state.activeSpace?.theme ?? SpaceTheme()
    return NativeSpacePalette(theme: theme, dark: colorScheme == .dark, increasedContrast: contrast == .increased)
  }
  private var shortcuts: [BrowserShortcut] { BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides) }
  private var title: String {
    switch destination { case .shortcuts: "Keyboard shortcuts"; case .profiles: "Browser profiles"; case .onboarding: "Welcome to Zacro"; case .permissions: "Site permissions"; case .spaces: "Your Spaces" }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title).font(.system(size: 17, weight: .semibold))
        Spacer()
        if destination == .shortcuts { Button("Reset all") { apply { try store.resetShortcut() } }.buttonStyle(.plain) }
        Button(action: closeEditor) { NativeGlyph("xmark").frame(width: 24, height: 24) }
          .keyboardShortcut(.cancelAction).buttonStyle(.plain).help("Close").accessibilityLabel("Close \(title)")
      }
      switch destination {
      case .shortcuts: shortcutEditor
      case .profiles: profiles
      case .onboarding: tour
      case .permissions: permissions
      case .spaces: spaces
      }
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently) }
      if recording != nil, let message = actions.shortcutCaptureError {
        Text(message).font(.system(size: 12)).foregroundStyle(colors.ink).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(20).frame(width: 500)
      .font(.system(size: 13)).foregroundStyle(colors.ink).tint(colors.accent)
      .background { NativeControlSurface().overlay(colors.chrome.opacity(0.65)) }
      .onChange(of: recording) { _, value in actions.recordingShortcut = value != nil }
      .onChange(of: actions.recordingShortcut) { _, value in if !value { recording = nil } }
      .onDisappear { actions.recordingShortcut = false }
      .sheet(item: $renameProfile) { profile in
        NativeNameEditor(title: "Rename profile", name: $profileName, error: error, colors: colors, save: {
            let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
              do {
                try store.commit { state in
                  if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[index].name = String(name.prefix(60)) }
                }
                renameProfile = nil; profileName = ""
              } catch { self.error = error.localizedDescription; store.clearError() }
            }
        }, cancel: { renameProfile = nil; profileName = ""; error = nil })
      }
  }
  private func closeEditor() {
    if destination == .onboarding { finishTour() }
    else { dismiss() }
  }
  private var shortcutEditor: some View {
    VStack(spacing: 12) {
      TextField("Search shortcuts", text: $query).textFieldStyle(.plain).padding(10)
        .background(colors.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          ForEach(categories, id: \.self) { category in
            Text(category).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.muted).padding(.top, 12).padding(.bottom, 4)
            ForEach(shortcuts.filter { $0.category == category && matches($0) }) { shortcut in shortcutRow(shortcut) }
          }
        }
      }.scrollIndicators(.hidden).frame(height: 370)
    }
  }
  private var categories: [String] {
    shortcuts.filter(matches).reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
  }
  private func matches(_ shortcut: BrowserShortcut) -> Bool {
    query.isEmpty || "\(shortcut.title) \(shortcut.category) \(shortcut.accelerator)".localizedCaseInsensitiveContains(query)
  }
  private func shortcutRow(_ shortcut: BrowserShortcut) -> some View {
    HStack(spacing: 8) {
      Text(shortcut.title).lineLimit(1)
      Spacer(minLength: 8)
      if recording == shortcut.id {
        if actions.shortcutCaptureReady {
          let session = recordingSession
          ShortcutCapture { result in
            guard recording == shortcut.id, recordingSession == session else { return }
          switch result {
          case .cancel: recording = nil
          case .value(let value):
            do { try store.updateShortcut(id: shortcut.id, accelerator: value); error = nil; recording = nil }
            catch { self.error = error.localizedDescription }
          }
          }.id(session).frame(width: 150, height: 28)
        } else {
          if actions.shortcutCaptureError == nil { ProgressView().controlSize(.mini); Text("Preparing shortcut…").font(.system(size: 11)) }
          Button("Cancel") { recording = nil }.buttonStyle(.plain)
        }
      } else {
        Button { error = nil; recordingSession = UUID(); recording = shortcut.id } label: {
          Text(shortcut.accelerator.isEmpty ? "Not set" : Self.keyLabel(shortcut.accelerator))
            .font(.system(size: 12, weight: .medium, design: .rounded)).frame(minWidth: 74).padding(.horizontal, 7).padding(.vertical, 6)
            .background(colors.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help("Change \(shortcut.title)")
      }
      Menu {
        Button("Change shortcut") { error = nil; recordingSession = UUID(); recording = shortcut.id }
        Button("Disable shortcut") { apply { try store.updateShortcut(id: shortcut.id, accelerator: "") } }
        Button("Reset shortcut") { apply { try store.resetShortcut(id: shortcut.id) } }
      } label: { NativeGlyph("ellipsis").frame(width: 18, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
    }.frame(minHeight: 32).padding(.horizontal, 7)
  }
  static func keyLabel(_ value: String) -> String {
    let glyphs = ["Mod": "⌘", "Alt": "⌥", "Ctrl": "⌃", "Shift": "⇧", "Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Enter": "↩", "Escape": "Esc", "Backspace": "⌫", "Tab": "⇥", "Space": "Space"]
    return value.components(separatedBy: "+").map { glyphs[$0] ?? $0 }.joined()
  }
  private var spaces: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView {
        VStack(spacing: 4) {
          ForEach(store.state.spaces) { space in
            HStack(spacing: 8) {
              Button {
                store.selectSpace(id: space.id); dismiss()
              } label: {
                HStack(spacing: 12) {
                  NativeGlyph(space.icon).frame(width: 30, height: 36).foregroundStyle(colors.accent)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(space.name).fontWeight(.semibold)
                    let profile = store.state.profiles.first { $0.id == space.profileID }
                    Text("\(profile?.name ?? "Profile")\(profile?.isPrivate == true ? " · Private" : "") · \(store.state.tabs.filter { $0.spaceID == space.id }.count) tabs")
                      .font(.system(size: 11)).foregroundStyle(colors.muted)
                  }
                  Spacer()
                  if space.id == store.state.activeSpaceID { NativeGlyph("checkmark").foregroundStyle(colors.accent) }
                }.contentShape(Rectangle())
              }.buttonStyle(.plain)
              Button {
                store.selectSpace(id: space.id); showInterface("space-theme")
              } label: { NativeGlyph("pencil").frame(width: 24, height: 28) }
                .buttonStyle(.plain).help("Customize \(space.name)").accessibilityLabel("Customize \(space.name)")
              Button { deleteSpace(space) } label: { NativeGlyph("trash").frame(width: 24, height: 28) }
                .buttonStyle(.plain).help("Delete \(space.name)").accessibilityLabel("Delete \(space.name)")
                .disabled(store.state.spaces.filter { $0.profileID == space.profileID }.count <= 1)
            }.padding(9).background(colors.card.opacity(space.id == store.state.activeSpaceID ? 0.46 : 0.12), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.scrollIndicators(.hidden).frame(maxHeight: 350)
      HStack {
        Button("New Space") { showInterface("new-space") }
        Button("Manage profiles") { showInterface("profiles") }
        Spacer()
      }
    }
  }
  private func deleteSpace(_ space: BrowserSpace) {
    let alert = NSAlert(); alert.messageText = "Delete Space “\(space.name)”?"
    alert.informativeText = "Tabs will move to another Space in this profile."
    alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel"); alert.alertStyle = .warning
    alert.buttons.first?.hasDestructiveAction = true; alert.buttons.first?.keyEquivalent = ""; alert.buttons.last?.keyEquivalent = "\r"
    if alert.runModal() == .alertFirstButtonReturn { actions.deleteSpace(space.id) }
  }
  private func showInterface(_ command: String) {
    dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { _ = actions.performInterfaceCommand(command) }
  }
  private var profiles: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Each profile keeps its accounts, cookies, history, and extensions separate.").foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(spacing: 10) {
          ForEach(store.state.profiles) { profile in
            let defaultProfileID = store.state.profiles.first(where: { $0.id == "default" && !$0.isPrivate })?.id
              ?? store.state.profiles.first(where: { !$0.isPrivate })?.id
            let isDefault = profile.id == defaultProfileID
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 10) {
                Button {
                  if let space = store.state.spaces.first(where: { $0.profileID == profile.id }) { store.selectSpace(id: space.id); dismiss() }
                } label: {
                  HStack(spacing: 10) {
                    Group { if profile.isPrivate { NativeGlyph("shield") } else { Text(String(profile.name.prefix(1)).uppercased()).fontWeight(.semibold) } }
                      .frame(width: 34, height: 34).background(colors.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                      Text(profile.name).fontWeight(.semibold)
                      Text("\(profile.isPrivate ? "Private · cleared when closed" : "Persistent profile") · \(store.state.spaces.filter { $0.profileID == profile.id }.count) Spaces").font(.system(size: 11)).foregroundStyle(colors.muted)
                    }
                    Spacer()
                    if store.activeProfileID == profile.id { NativeGlyph("checkmark").foregroundStyle(colors.accent) }
                  }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                  Button("Rename profile") { profileName = profile.name; renameProfile = profile }
                  Button("Delete profile", role: .destructive) { deleteProfile(profile) }.disabled(!store.state.profiles.contains { !$0.isPrivate && $0.id != profile.id })
                } label: { NativeGlyph("ellipsis").frame(width: 22, height: 30) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
              }
              Picker("Archive inactive tabs", selection: Binding(get: { isDefault ? store.state.settings.archiveAfterHours : profile.archiveAfterHours ?? -1 }, set: { value in
                store.setArchiveHours(profileID: profile.id, hours: value < 0 ? nil : value)
              })) {
                if !isDefault { Text("Use browser default").tag(-1.0) }
                Text("Never").tag(0.0)
                Text("After 1 hour").tag(1.0)
                Text("After 6 hours").tag(6.0)
                Text("After 12 hours").tag(12.0)
                Text("After 1 day").tag(24.0)
                Text("After 2 days").tag(48.0)
                Text("After 3 days").tag(72.0)
                Text("After 7 days").tag(168.0)
                Text("After 30 days").tag(720.0)
              }.font(.system(size: 12))
            }.padding(12).background(colors.card.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.scrollIndicators(.hidden).frame(maxHeight: 330)
      HStack {
        TextField("New profile name", text: $profileName).textFieldStyle(.roundedBorder)
        Button("Create") {
          do {
            _ = try store.createProfileDurably(name: String(profileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)))
            profileName = ""; error = nil
          } catch { self.error = error.localizedDescription; store.clearError() }
        }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Private session") {
          do { _ = try store.createProfileDurably(name: "Private", isPrivate: true); dismiss() }
          catch { self.error = error.localizedDescription; store.clearError() }
        }
      }
    }
  }
  private func deleteProfile(_ profile: BrowserProfile) {
    let alert = NSAlert(); alert.messageText = "Delete profile “\(profile.name)”?"
    alert.informativeText = "This removes this profile’s Spaces, tabs, bookmarks, history, and browsing data."
    alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel"); alert.alertStyle = .warning
    alert.buttons.first?.hasDestructiveAction = true; alert.buttons.first?.keyEquivalent = ""; alert.buttons.last?.keyEquivalent = "\r"
    if alert.runModal() == .alertFirstButtonReturn { actions.deleteProfile(profile.id) }
  }
  private var permissions: some View {
    let entries = store.state.permissions.filter { $0.profileID == store.activeProfileID }
    return VStack(alignment: .leading, spacing: 14) {
      Text("Permissions saved for \(store.state.activeProfile?.name ?? "this profile"). Clear them to ask again the next time a site requests access.")
        .foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          if entries.isEmpty { Text("No saved permissions.").foregroundStyle(colors.muted).padding(.vertical, 18) }
          ForEach(entries) { entry in
            HStack(spacing: 12) {
              NativeGlyph(entry.allowed ? "checkmark" : "shield").foregroundStyle(colors.accent).frame(width: 24)
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.origin).lineLimit(2).textSelection(.enabled)
                Text("\(entry.permission) · \(entry.allowed ? "Allowed" : "Blocked")").font(.system(size: 12)).foregroundStyle(colors.muted)
              }
              Spacer(minLength: 6)
              Menu {
                Button("Allow") { changePermission(entry, allowed: true) }
                Button("Block") { changePermission(entry, allowed: false) }
                Divider()
                Button("Reset permission") { changePermission(entry, allowed: nil) }
              } label: { NativeGlyph("ellipsis").frame(width: 22, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .accessibilityLabel("Change \(entry.permission) for \(entry.origin)")
            }.padding(10).background(colors.card.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
          }
        }
      }.scrollIndicators(.hidden).frame(maxHeight: 310)
      HStack {
        Spacer()
        Button("Done") { dismiss() }
        if !entries.isEmpty {
          Button("Reset permissions") {
            apply { try store.clearPermissionsDurably() }
          }
        }
      }
    }
  }
  private func changePermission(_ permission: WebsitePermission, allowed: Bool?) {
    apply {
      guard let allowed else { try store.removePermissionDurably(id: permission.id); return }
      try store.commit { state in
        state.permissions.removeAll { $0.id == permission.id }
        var updated = permission; updated.allowed = allowed; state.permissions.append(updated)
      }
    }
  }
  private let tourSteps: [(String, String, String, [String])] = [
    ("A little space to think.", "One command bar for websites, tabs, Spaces and actions.", "magnifyingglass", ["command-palette", "open-location"]),
    ("Make room for the page.", "Hide the sidebar whenever you need room. Bring it back just as easily.", "sidebar.left", ["sidebar-toggle", "focus-sidebar", "focus-chrome"]),
    ("Keep your place.", "Jump between recent tabs, or move to a different Space.", "square.stack", ["recent-tab", "previous-space", "next-space"]),
    ("Keep the good ones close.", "Pins stay in their Space. Favorites follow you between Spaces. Close either to unload its page.", "pin", ["pin-tab", "close-tab", "reopen-tab"]),
    ("Make yourself at home.", "Your themes, your shortcuts. You can revisit this tour from the browser menu.", "slider.horizontal.3", ["preferences", "shortcuts"]),
  ]
  private var tour: some View {
    let step = tourSteps[tourStep]
    return VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 4) {
        VStack(spacing: 8) {
          ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 5).fill(colors.accent.opacity(0.17)).frame(height: 12) }
          Spacer()
        }.padding(12).frame(width: 100)
        VStack(spacing: 16) {
          NativeGlyph(step.2, size: 32).foregroundStyle(colors.accent)
          ForEach(0..<2) { _ in Capsule().fill(colors.ink.opacity(0.08)).frame(width: 140, height: 7) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.card.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
      }.padding(8).frame(height: 160).background(colors.chrome, in: RoundedRectangle(cornerRadius: 14))
      Text(step.0).font(.system(size: 25, weight: .semibold))
      Text(step.1).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
      VStack(spacing: 3) { ForEach(shortcuts.filter { step.3.contains($0.id) }) { shortcut in shortcutRow(shortcut) } }
      HStack {
        Button("Back") { recording = nil; tourStep = max(0, tourStep - 1) }.disabled(tourStep == 0)
        Spacer()
        ForEach(tourSteps.indices, id: \.self) { index in
          Button { recording = nil; tourStep = index } label: { Circle().fill(colors.accent.opacity(index == tourStep ? 1 : 0.25)).frame(width: 6, height: 6).padding(3) }.buttonStyle(.plain).accessibilityLabel("Tour step \(index + 1)")
        }
        Spacer()
        Button(tourStep == tourSteps.count - 1 ? "Start browsing" : "Continue") {
          recording = nil
          if tourStep == tourSteps.count - 1 { finishTour() }
          else { tourStep += 1 }
        }.keyboardShortcut(.defaultAction)
      }
      Button("Skip tour", action: finishTour).buttonStyle(.plain).foregroundStyle(colors.muted)
    }
  }
  private func finishTour() {
    do { try store.commit { $0.settings.onboardingCompleted = true }; dismiss() }
    catch { self.error = error.localizedDescription }
  }
  private func apply(_ action: () throws -> Void) { do { try action(); error = nil; recording = nil } catch { self.error = error.localizedDescription } }
}

private struct ShortcutCapture: NSViewRepresentable {
  enum Result { case cancel, value(String) }
  let receive: (Result) -> Void
  func makeNSView(context: Context) -> CaptureView {
    let view = CaptureView(); view.receive = receive
    DispatchQueue.main.async { if let window = view.window, window.isKeyWindow { window.makeFirstResponder(view) } }
    return view
  }
  func updateNSView(_ view: CaptureView, context: Context) { view.receive = receive }
  final class CaptureView: NSView {
    var receive: (Result) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
      let callback = receive
      DispatchQueue.main.async { callback(.cancel) }
      return true
    }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
      let text = "Press shortcut…" as NSString
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
      let size = text.size(withAttributes: attributes)
      text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
    override func keyDown(with event: NSEvent) {
      guard !event.isARepeat else { return }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if event.keyCode == 53 && flags.isEmpty { receive(.cancel); return }
      if [51, 117].contains(event.keyCode) && flags.isEmpty { receive(.value("")); return }
      let special: [UInt16: String] = [36: "Enter", 76: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 117: "Delete", 123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
      guard var key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return }
      if key == "+" { key = "=" }
      var parts = [String]()
      if flags.contains(.control) { parts.append("Ctrl") }; if flags.contains(.command) { parts.append("Mod") }
      if flags.contains(.option) { parts.append("Alt") }; if flags.contains(.shift) { parts.append("Shift") }
      parts.append(key); receive(.value(parts.joined(separator: "+")))
    }
  }
}
