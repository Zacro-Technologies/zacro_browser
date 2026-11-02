import AppKit
import Combine
import SwiftUI
import ZacroCore
import ZacroChromium

@MainActor
final class NativeExtensionsModel: ObservableObject {
  @Published private(set) var entries: [ChromeExtension] = []
  @Published private(set) var icons: [String:NSImage] = [:]
  @Published private(set) var loading = false
  @Published private(set) var developerMode = false
  @Published private(set) var canLoadUnpacked = false
  @Published private(set) var developerModeControlled = false
  @Published private(set) var incognitoAvailable = false
  @Published var error: String?
  private let store: BrowserStore
  private let engine: ChromiumEngine
  private let actions: BrowserActions
  private var scope: String?
  private var request: Task<Void,Never>?
  private var generation = 0
  private var refreshPending = false
  private var shortcuts: [ChromeExtensionShortcut] = []
  private var shortcutRequest: Task<Void, Never>?
  private var shortcutGeneration = 0
  private var recordingObservation: AnyCancellable?
  private var recordingFocusObservation: AnyCancellable?
  private var recordingTask: Task<Void, Never>?
  private var recordingGeneration = 0
  private var suspendedProfile: String?
  private let suspensionToken = UUID()
  @Published private(set) var recordingCommand: String?
  private weak var activeDocument: ChromiumPage?
  private var activeAddress: String?
  private var actionRequest: Task<Void, Never>?
  private var actionGeneration = 0
  private var actionStates: [String: ChromeExtensionAction] = [:]
  private var actionIcons: [String: NSImage] = [:]
  // Genuine manifest action capability is installation-scoped. Per-document
  // action state can expire without removing and reflowing every pinned tile.
  private var actionCapabilities: [String: Bool] = [:]
  var invokeAction: ((String, String, NSRect?) async throws -> Void)?
  var invokeOptions: ((String, String) async throws -> Void)?
  var invokeSidePanel: ((String, String) async throws -> Void)?
  init(store: BrowserStore, engine: ChromiumEngine, actions: BrowserActions) {
    self.store = store; self.engine = engine; self.actions = actions
    recordingObservation = actions.$recordingShortcut.removeDuplicates().sink { [weak self] active in
      self?.setRecordingSuspended(active)
    }
  }
  var isPrivate: Bool { store.state.activeProfile?.isPrivate ?? true }
  func profileChanged() {
    NativeShortcutSuspension.noteProfile(engine: engine, owner: suspensionToken,
      profile: isPrivate ? nil : store.activeProfileID)
    guard scope != store.activeProfileID else { return }
    if actions.recordingShortcut { recordShortcut(nil) }
    request?.cancel(); generation += 1; scope = store.activeProfileID
    actionRequest?.cancel(); actionGeneration += 1
    activeDocument = nil; activeAddress = nil; actionStates = [:]; actionIcons = [:]; actionCapabilities = [:]
    shortcutRequest?.cancel(); shortcutGeneration += 1; shortcuts = []
    refreshPending = false
    entries = []; icons = [:]; error = nil; loading = false
    actions.siteControls.extensions = []; actions.siteControls.extensionsReady = isPrivate
    actions.siteControls.extensionError = nil
    if !isPrivate { refresh() }
  }
  func refresh() {
    guard !isPrivate, engine.contexts.values.contains(where: { $0.isOpen && !$0.isClosing && (store.owningWindowID == nil || $0.id == store.owningWindowID) }) else { return }
    guard !loading else { refreshPending = true; return }
    if !actions.recordingShortcut, suspendedProfile != nil { setRecordingSuspended(false) }
    let profile = store.activeProfileID, revision = generation
    scope = profile; loading = true; error = nil
    refreshShortcuts()
    request = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.generation == revision {
          self.loading = false
          if self.refreshPending { self.refreshPending = false; self.refresh() }
        }
      }
      let manager = ChromeExtensionManager(engine: self.engine, profileID: profile)
      do {
        let snapshot = try await manager.snapshot()
        guard self.valid(profile,revision) else { return }
        let previousIcons = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0.version + ":" + $0.iconUrl) })
        let currentIcons = Dictionary(uniqueKeysWithValues: snapshot.extensions.map { ($0.id, $0.version + ":" + $0.iconUrl) })
        self.icons = self.icons.filter { previousIcons[$0.key] == currentIcons[$0.key] && currentIcons[$0.key] != nil }
        self.actionCapabilities = self.actionCapabilities.filter { previousIcons[$0.key] == currentIcons[$0.key] && currentIcons[$0.key] != nil }
        self.entries = snapshot.extensions
        self.developerMode = snapshot.profile.inDeveloperMode
        self.canLoadUnpacked = snapshot.profile.canLoadUnpacked
        self.developerModeControlled = snapshot.profile.isDeveloperModeControlledByPolicy
        // Zacro's private profiles are independent ephemeral contexts, not an
        // off-the-record child of this regular profile's extension registry.
        self.incognitoAvailable = false
        self.publish(profile, revision)
        for item in snapshot.extensions where self.icons[item.id] == nil {
          if let data = try? await manager.iconData(item.id), let image = NSImage(data: data), self.valid(profile,revision) {
            self.icons[item.id] = image; self.publish(profile,revision)
          }
        }
        self.refreshActions()
      } catch {
        guard self.valid(profile,revision) else { return }
        self.shortcutRequest?.cancel(); self.shortcutGeneration += 1; self.shortcuts = []
        self.error = error.localizedDescription
        self.actions.siteControls.extensionsReady = true
        self.actions.siteControls.extensionError = error.localizedDescription
      }
    }
  }
  private func valid(_ profile: String, _ revision: Int) -> Bool {
    generation == revision && store.activeProfileID == profile && !isPrivate && !Task.isCancelled
  }
  private func publish(_ profile: String, _ revision: Int) {
    guard valid(profile,revision) else { return }
    actions.siteControls.extensions = entries.map { entry in
      let state = actionStates[entry.id]
      let usableAction = entry.isEnabled && state?.hasAction == true && state?.enabled == true
      let operation = usableAction ? "action" : entry.isEnabled && state?.hasSidePanel == true ? "side-panel"
        : entry.isEnabled && entry.optionsPage != nil ? "options" : "manage"
      return SiteExtensionItem(id: entry.id, name: state?.title.isEmpty == false ? state!.title : entry.name,
        image: actionIcons[entry.id] ?? icons[entry.id], badgeText: state?.badgeText ?? "",
        badgeColor: state.flatMap { Self.color($0.badgeColor) },
        badgeForeground: state.flatMap { Self.color($0.badgeForeground) },
        enabled: entry.isEnabled, actionEnabled: usableAction,
        pinned: entry.isPinned && actionCapabilities[entry.id] == true, canPin: entry.userMayModify && actionCapabilities[entry.id] == true,
        perform: { [weak self] in self?.perform(operation, id: entry.id, expectedProfile: profile) },
        togglePin: { [weak self] in self?.perform(entry.isPinned ? "unpin" : "pin", id: entry.id, expectedProfile: profile) })
    }
    actions.siteControls.extensionsReady = true; actions.siteControls.extensionError = nil
    if let index = store.state.profiles.firstIndex(where: { $0.id == profile }) {
      let pinned = entries.filter(\.isPinned).map(\.id)
      if store.state.profiles[index].pinnedExtensionIDs != pinned { store.updateProfile(profile) { $0.pinnedExtensionIDs = pinned } }
    }
  }
  func nativeEvent(profileID: String, event: ChromeExtensionEvent) {
    guard scope == profileID, store.activeProfileID == profileID, !isPrivate else { return }
    switch event {
    case .registryChanged, .installationChanged:
      shortcutRequest?.cancel(); shortcutGeneration += 1; shortcuts = []
      actionRequest?.cancel(); actionGeneration += 1
      actionStates = [:]; actionIcons = [:]; actionCapabilities = [:]
      refresh()
    case .actionChanged: refreshActions()
    case .commandsChanged: refreshShortcuts()
    case .storageChanged, .hostRequest, .bookmarksChanged, .downloadChanged, .downloadRemoved: break
    }
  }
  /// Matching is synchronous so the native key monitor can consume precisely
  /// the command it will dispatch. Chromium revalidates the cached incarnation.
  func matchingShortcut(for event: NSEvent) -> ChromeExtensionShortcut? {
    guard scope == store.activeProfileID, !isPrivate, !actions.recordingShortcut,
      !NativeShortcutSuspension.isSuspended(engine: engine),
      let owner = store.owningWindowID, let context = engine.context(id: owner),
      context.isOpen, !context.isClosing else { return nil }
    return shortcuts.first { $0.matches(event) }
  }
  private func refreshShortcuts() {
    shortcutRequest?.cancel(); shortcutGeneration += 1; shortcuts = []
    guard !isPrivate else { return }
    let profile = store.activeProfileID, revision = generation, update = shortcutGeneration
    shortcutRequest = Task { [weak self] in
      guard let self else { return }
      do {
        let values = try await ChromeExtensionManager(engine: self.engine, profileID: profile).shortcuts()
        guard self.valid(profile, revision), update == self.shortcutGeneration else { return }
        self.shortcuts = values
      } catch {
        guard self.valid(profile, revision), update == self.shortcutGeneration else { return }
        self.shortcuts = []
      }
    }
  }
  func activePageChanged(_ page: ChromiumPage?) {
    let address = page?.url?.absoluteString
    guard activeDocument !== page || activeAddress != address else { return }
    activeDocument = page; activeAddress = address
    actionStates = [:]; actionIcons = [:]
    if let scope { publish(scope, generation) }
    refreshActions()
  }
  func canPin(_ identifier: String) -> Bool {
    entries.first(where: { $0.id == identifier })?.userMayModify == true && actionCapabilities[identifier] == true
  }
  private func refreshActions() {
    actionRequest?.cancel(); actionGeneration += 1
    guard !isPrivate, let windowID = store.owningWindowID,
      let context = engine.context(id: windowID), context.isOpen, !context.isClosing else { return }
    let page = activeDocument
    if let page, page.profileID != store.activeProfileID || page.ownerWindowID != windowID { return }
    let profile = store.activeProfileID, revision = generation, actionRevision = actionGeneration
    actionRequest = Task { [weak self, weak page] in
      guard let self else { return }
      let manager = ChromeExtensionManager(engine: self.engine, profileID: profile)
      var states: [String: ChromeExtensionAction] = [:], images: [String: NSImage] = [:]
      for entry in self.entries {
        guard !Task.isCancelled, self.activeDocument === page, self.actionGeneration == actionRevision else { return }
        if let state = try? await manager.action(entry.id, on: page) {
          states[entry.id] = state
          if let encoded = state.iconPNG, encoded.utf8.count <= 1_400_000,
            let data = Data(base64Encoded: encoded), let image = NSImage(data: data) { images[entry.id] = image }
        }
      }
      guard self.valid(profile, revision), self.activeDocument === page,
        page == nil || page?.ownerWindowID == windowID, context.isOpen, !context.isClosing,
        self.actionGeneration == actionRevision else { return }
      self.objectWillChange.send()
      self.actionStates = states; self.actionIcons = images
      for (id, state) in states { self.actionCapabilities[id] = state.hasAction }
      self.publish(profile, revision)
    }
  }
  private static func color(_ rgba: [Int]) -> NSColor? {
    guard rgba.count == 4, rgba.allSatisfy({ (0...255).contains($0) }) else { return nil }
    return NSColor(srgbRed: Double(rgba[0]) / 255, green: Double(rgba[1]) / 255,
      blue: Double(rgba[2]) / 255, alpha: Double(rgba[3]) / 255)
  }
  func perform(_ operation: String, id: String = "", value: String? = nil, expectedProfile: String? = nil) {
    guard !isPrivate, expectedProfile.map({ $0 == store.activeProfileID }) ?? true else { return }
    let profile = store.activeProfileID, revision = generation
    let actionAnchor: NSRect?
    if operation == "action", let event = NSApp.currentEvent,
      [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type),
      let eventWindow = event.window {
      actionAnchor = eventWindow.convertToScreen(NSRect(x: event.locationInWindow.x - 10,
        y: event.locationInWindow.y - 10, width: 20, height: 20))
    } else { actionAnchor = nil }
    Task { [weak self] in
      guard let self, self.valid(profile,revision) else { return }
      let manager = ChromeExtensionManager(engine: self.engine, profileID: profile)
      do {
        switch operation {
        case "pin", "unpin": try await manager.setPinned(id, pinned: operation == "pin")
        case "enable", "disable": try await manager.setEnabled(id, enabled: operation == "enable")
        case "remove": try await manager.uninstall(id)
        case "reload":
          try await manager.reload(id)
          if self.valid(profile, revision) { self.icons.removeValue(forKey: id) }
        case "options":
          guard let invoke = self.invokeOptions else { throw ChromeExtensionError.managementUnavailable }
          try await invoke(profile, id)
        case "side-panel":
          guard let invoke = self.invokeSidePanel else { throw ChromeExtensionError.managementUnavailable }
          try await invoke(profile, id)
        case "manage": self.actions.openExtensions()
        case "file-access": try await manager.setFileAccess(id, allowed: value == "true")
        case "user-scripts": try await manager.setUserScriptsAccess(id, allowed: value == "true")
        case "incognito": try await manager.setIncognitoAccess(id, allowed: value == "true")
        case "host-access":
          guard let value, let access = ChromeExtensionManager.HostAccess(rawValue: value) else { throw ChromeExtensionError.invalidResponse }
          try await manager.setHostAccess(id, access: access)
        case "host-allow", "host-remove":
          guard let value else { throw ChromeExtensionError.invalidResponse }
          try await manager.setHostPermission(id, pattern: value, allowed: operation == "host-allow")
        case "updates": try await manager.checkForUpdates()
        case "developer": try await manager.setDeveloperMode(!self.developerMode)
        case "load":
          self.actions.openExtensions()
          try await manager.chooseUnpackedExtension()
        case "action":
          guard let invoke = self.invokeAction else { throw ChromeExtensionError.managementUnavailable }
          try await invoke(profile, id, actionAnchor)
        default: throw ChromeExtensionError.invalidResponse
        }
        guard self.valid(profile,revision) else { return }
        self.refresh()
      } catch {
        if self.valid(profile,revision) {
          self.error = error.localizedDescription
          self.actions.siteControls.extensionError = error.localizedDescription
        }
      }
    }
  }
  func recordShortcut(_ identifier: String?) {
    recordingCommand = identifier; actions.recordingShortcut = identifier != nil
  }
  var recordingReady: Bool { actions.shortcutCaptureReady }
  var recordingError: String? { actions.shortcutCaptureError }
  func retryRecording() {
    guard actions.recordingShortcut else { return }
    setRecordingSuspended(true)
  }
  private func setRecordingSuspended(_ active: Bool) {
    if !active { recordingCommand = nil }
    recordingGeneration += 1
    let revision = recordingGeneration, previous = suspendedProfile
    recordingFocusObservation = nil
    if active, let window = NSApp.keyWindow {
      // A key window can retain its first responder when it loses focus. End
      // recording even while native suspension is still being prepared.
      recordingFocusObservation = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
        .merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          guard let self, self.recordingGeneration == revision, self.actions.recordingShortcut else { return }
          self.recordShortcut(nil)
        }
    }
    let profile = active ? (isPrivate ? store.state.profiles.first(where: { !$0.isPrivate })?.id : store.activeProfileID) : nil
    suspendedProfile = profile
    actions.shortcutCaptureReady = false; actions.shortcutCaptureError = nil
    objectWillChange.send()
    let prior = recordingTask, token = suspensionToken
    recordingTask = Task { [weak self, engine] in
      await prior?.value
      do {
        if let previous, previous != profile {
          try await NativeShortcutSuspension.set(engine: engine, profile: previous, token: token, active: false)
        }
        if let profile {
          try await NativeShortcutSuspension.set(engine: engine, profile: profile, token: token, active: true)
        }
        guard let self, revision == self.recordingGeneration else { return }
        self.actions.shortcutCaptureReady = active
        self.objectWillChange.send()
      } catch {
        // Even a failed suspend can race a successful native update. Always
        // release this caller's lease, then keep capture disabled on failure.
        if let profile { try? await NativeShortcutSuspension.set(engine: engine, profile: profile, token: token, active: false) }
        guard let self, revision == self.recordingGeneration else { return }
        if !active, let previous { self.suspendedProfile = previous }
        self.actions.shortcutCaptureError = error.localizedDescription
        self.error = error.localizedDescription
        self.objectWillChange.send()
      }
    }
  }
  func updateShortcut(extensionID: String, commandName: String, keybinding: String) async throws {
    let profile = store.activeProfileID, revision = generation
    guard valid(profile, revision), let item = entries.first(where: { $0.id == extensionID }), item.userMayModify,
      let command = item.commands.first(where: { $0.name == commandName }),
      !(item.isCommandRegistrationHandledExternally && command.scope == "GLOBAL") else { throw ChromeExtensionError.managementUnavailable }
    let browserKey = keybinding.replacingOccurrences(of: "Command", with: "Mod").replacingOccurrences(of: "Period", with: ".")
    if !keybinding.isEmpty, let canonical = try? BrowserShortcut.normalized(browserKey),
      let conflict = BrowserShortcut.catalog(overrides: store.state.settings.shortcutOverrides).first(where: {
        ([$0.accelerator] + $0.aliases).contains(canonical)
      }) {
      throw ShortcutError("Already used by \(conflict.title). Change the browser shortcut or choose another combination.")
    }
    let manager = ChromeExtensionManager(engine: engine, profileID: profile)
    try await manager.updateCommand(extensionID, name: commandName, keybinding: keybinding, global: command.scope == "GLOBAL")
    guard valid(profile, revision) else { throw CancellationError() }
    refresh()
  }
  func updateCommandScope(extensionID: String, commandName: String, global: Bool) async throws {
    let profile = store.activeProfileID, revision = generation
    guard valid(profile, revision), let item = entries.first(where: { $0.id == extensionID }), item.userMayModify,
      let command = item.commands.first(where: { $0.name == commandName }), command.isActive,
      !command.isExtensionAction else { throw ChromeExtensionError.managementUnavailable }
    let manager = ChromeExtensionManager(engine: engine, profileID: profile)
    try await manager.setCommandScope(extensionID, name: commandName, global: global)
    guard valid(profile, revision) else { throw CancellationError() }
    refresh()
  }
  func inspectView(extensionID: String, view: ChromeExtension.View) {
    let profile = store.activeProfileID, revision = generation
    Task { [weak self] in
      guard let self, self.valid(profile, revision), self.developerMode,
        self.entries.first(where: { $0.id == extensionID })?.views.contains(where: {
          $0.renderProcessId == view.renderProcessId && $0.renderViewId == view.renderViewId
            && $0.url == view.url && $0.incognito == view.incognito
        }) == true else { return }
      do { try await ChromeExtensionManager(engine: self.engine, profileID: profile).inspectView(extensionID, view: view) }
      catch { if self.valid(profile, revision) { self.error = error.localizedDescription } }
    }
  }
  func close() {
    if actions.recordingShortcut { recordShortcut(nil) }
    request?.cancel(); request = nil; generation += 1
    actionRequest?.cancel(); actionRequest = nil; actionGeneration += 1
    scope = nil; activeDocument = nil; activeAddress = nil; loading = false; refreshPending = false
    actionStates = [:]; actionIcons = [:]; actionCapabilities = [:]
    shortcutRequest?.cancel(); shortcutRequest = nil; shortcutGeneration += 1; shortcuts = []
    NativeShortcutSuspension.noteProfile(engine: engine, owner: suspensionToken, profile: nil)
  }
}

/// Chromium's native registry flags are profile scoped, but its global keyboard
/// listener is process wide. Resume only after every editor releases its lease.
@MainActor private enum NativeShortcutSuspension {
  private final class State {
    var owners: [UUID: String] = [:]
    var leases: [UUID: String] = [:]
    var attempted = Set<String>()
    var suspended = Set<String>()
    var tail: (id: UUID, task: Task<Void, Error>)?
  }
  private static var states: [ObjectIdentifier: State] = [:]
  static func isSuspended(engine: ChromiumEngine) -> Bool {
    guard let state = states[ObjectIdentifier(engine)] else { return false }
    return !state.leases.isEmpty || !state.attempted.isEmpty
  }
  static func noteProfile(engine: ChromiumEngine, owner: UUID, profile: String?) {
    let key = ObjectIdentifier(engine), state = states[ObjectIdentifier(engine)] ?? State()
    states[key] = state
    guard state.owners[owner] != profile else { return }
    state.owners[owner] = profile
    if !state.leases.isEmpty {
      // Newly focused profiles inherit process suspension natively immediately;
      // remember and suspend their registry too so final release resumes it.
      Task { try? await reconcile(engine: engine, state: state) }
    }
  }
  static func set(engine: ChromiumEngine, profile: String, token: UUID, active: Bool) async throws {
    let key = ObjectIdentifier(engine)
    let state = states[key] ?? State(); states[key] = state
    if active { state.leases[token] = profile } else { state.leases.removeValue(forKey: token) }
    try await reconcile(engine: engine, state: state)
  }
  private static func reconcile(engine: ChromiumEngine, state: State) async throws {
    let previous = state.tail?.task, identifier = UUID()
    let task = Task { @MainActor in
      _ = try? await previous?.value
      if !state.leases.isEmpty {
        let profiles = Set(state.leases.values).union(state.owners.values)
        for profile in profiles where !state.suspended.contains(profile) {
          state.attempted.insert(profile)
          try await ChromeExtensionManager(engine: engine, profileID: profile).setShortcutHandlingSuspended(true)
          state.suspended.insert(profile)
        }
      } else {
        var failure: Error?
        for profile in state.attempted {
          guard state.leases.isEmpty else { break }
          do {
            try await ChromeExtensionManager(engine: engine, profileID: profile).setShortcutHandlingSuspended(false)
            state.suspended.remove(profile); state.attempted.remove(profile)
          } catch { failure = error }
        }
        if let failure { throw failure }
      }
    }
    state.tail = (identifier, task)
    try await task.value
  }
}

struct NativeExtensionsView: View {
  @ObservedObject var model: NativeExtensionsModel
  let palette: NativeSpacePalette
  var openStore: () -> Void
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Button("Chrome Web Store", action: openStore).disabled(model.isPrivate)
          Spacer()
          Button { model.refresh() } label: { NativeGlyph("refresh").frame(width:14,height:14) }.help("Refresh extensions")
        }
        if model.isPrivate { Text("Extensions are managed in regular profiles.").foregroundStyle(palette.muted) }
        else {
          Toggle("Developer mode", isOn: Binding(get: { model.developerMode }, set: { _ in model.perform("developer") }))
            .disabled(model.developerModeControlled)
          HStack {
            if model.developerMode { Button("Load unpacked…") { model.perform("load") }.disabled(!model.canLoadUnpacked) }
            Spacer(); Button("Check for updates") { model.perform("updates") }
          }.font(.system(size:12))
          if model.loading { ProgressView().controlSize(.small).frame(maxWidth:.infinity) }
          if model.entries.isEmpty && !model.loading && model.error == nil {
            Text("Your installed extensions will appear here.").foregroundStyle(palette.muted).padding(.vertical,20)
          }
          ForEach(model.entries) { item in
            NativeExtensionCard(item: item, model: model, palette: palette)
          }
        }
        if let error = model.error {
          Text(error).font(.system(size:12)).foregroundStyle(palette.ink)
          Button("Try again") { model.refresh() }
        }
      }.padding(14)
    }.foregroundStyle(palette.ink).tint(palette.accent).scrollIndicators(.hidden)
      .task { model.profileChanged(); model.refresh() }
  }

}

private struct NativeExtensionCard: View {
  let item: ChromeExtension
  @ObservedObject var model: NativeExtensionsModel
  let palette: NativeSpacePalette
  var body: some View {
    VStack(alignment:.leading,spacing:10) {
      HStack(spacing:10) {
        if let image = model.icons[item.id] { Image(nsImage:image).resizable().scaledToFit().frame(width:30,height:30) }
        else { NativeGlyph("extension").frame(width:26,height:26).foregroundStyle(palette.accent) }
        VStack(alignment:.leading,spacing:3) {
          Text(item.name).font(.system(size:13,weight:.semibold))
          Text(item.version + " · " + extensionStatus(item)).font(.system(size:11)).foregroundStyle(palette.muted)
        }
        Spacer()
        Toggle("Enabled",isOn:Binding(get:{item.isUserEnabled},set:{model.perform($0 ? "enable":"disable",id:item.id)})).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!item.userMayModify)
      }
      Text(item.description).font(.system(size:12)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
      let notices = extensionNotices(item)
      if !notices.isEmpty {
        Text(notices.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(palette.ink)
          .fixedSize(horizontal: false, vertical: true).accessibilityLabel(notices.joined(separator: ". "))
      }
      HStack {
        Button(item.isPinned ? "Unpin":"Pin") { model.perform(item.isPinned ? "unpin":"pin",id:item.id) }.disabled(!model.canPin(item.id))
        if item.optionsPage != nil { Button("Options") { model.perform("options",id:item.id) }.disabled(!item.isEnabled) }
        Spacer()
        Menu {
          Button("Reload") { model.perform("reload",id:item.id) }
          Button("Remove…",role:.destructive) { model.perform("remove",id:item.id) }.disabled(item.mustRemainInstalled || !item.userMayModify)
        } label: { NativeGlyph.menuImage("more").frame(width:16,height:16) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      }.font(.system(size:12))
      NativeExtensionPermissions(item: item, model: model, palette: palette)
      if !item.commands.isEmpty { NativeExtensionCommands(item: item, model: model, palette: palette) }
      if model.developerMode && !item.views.isEmpty {
        DisclosureGroup("Inspect views") {
          VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(item.views.enumerated()), id: \.offset) { _, view in
              Button { model.inspectView(extensionID: item.id, view: view) } label: {
                HStack(spacing: 6) {
                  NativeGlyph("terminal").frame(width: 12, height: 12)
                  Text(view.type == "EXTENSION_SERVICE_WORKER_BACKGROUND" ? "Service worker" : NativePageIdentity.label(view.url))
                    .lineLimit(1)
                  Spacer(minLength: 0)
                  NativeGlyph("external").frame(width: 11, height: 11)
                }
              }.buttonStyle(.plain).help(view.url).accessibilityLabel("Inspect " + view.url)
            }
          }.padding(.top, 6)
        }.font(.system(size: 11))
      }
    }.padding(12).background(palette.ink.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
  }
  private func extensionStatus(_ item: ChromeExtension) -> String {
    switch item.state {
    case "ENABLED": return "Enabled"
    case "DISABLED": return "Disabled"
    case "TERMINATED": return "Stopped"
    case "BLOCKLISTED": return "Blocked"
    default: return item.state.capitalized
    }
  }
  private func extensionNotices(_ item: ChromeExtension) -> [String] {
    var values = [item.controlledInfo?.text, item.blocklistText,
      item.safetyCheckText?.detailString ?? item.safetyCheckText?.panelString].compactMap { $0 }
    let reasons = item.disableReasons
    let flags: [(Bool, String)] = [
      (reasons.corruptInstall, "The extension installation is damaged."),
      (reasons.suspiciousInstall, "Chromium disabled this installation for review."),
      (reasons.updateRequired, "Update this extension to enable it."),
      (reasons.publishedInStoreRequired, "This extension must be published in the Chrome Web Store."),
      (reasons.blockedByPolicy, "Disabled by your administrator."),
      (reasons.reloading, "Reloading extension…"),
      (reasons.custodianApprovalRequired, "Parental approval is required."),
      (reasons.parentDisabledPermissions, "Disabled by parental controls."),
      (reasons.unsupportedManifestVersion, "This extension's manifest version is unsupported by Chromium."),
      (reasons.unsupportedDeveloperExtension, "This developer extension is unsupported by Chromium."),
      (reasons.disabledByAnotherExtension, "Disabled by " + (reasons.disabledByExtensionName ?? "another extension") + ".")
    ]
    values += flags.filter { $0.0 }.map { $0.1 } + item.installWarnings + item.runtimeWarnings
    var seen = Set<String>()
    return values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
  }
}

private struct NativeExtensionPermissions: View {
  let item: ChromeExtension
  @ObservedObject var model: NativeExtensionsModel
  let palette: NativeSpacePalette
  @State private var sitePattern = ""
  var body: some View {
    DisclosureGroup("Permissions and site access") {
      VStack(alignment:.leading,spacing:10) {
        ForEach(item.permissions.simplePermissions.indices,id:\.self) { index in
          VStack(alignment:.leading,spacing:3) {
            Text(item.permissions.simplePermissions[index].message)
            ForEach(item.permissions.simplePermissions[index].submessages,id:\.self) { Text($0).foregroundStyle(palette.muted) }
          }
        }
        if item.userScriptsAccess.isEnabled {
          Toggle("Allow user scripts", isOn: Binding(get: { item.userScriptsAccess.isActive }, set: {
            model.perform("user-scripts", id: item.id, value: String($0))
          }))
        }
        if item.fileAccess.isEnabled {
          Toggle("Allow access to file URLs",isOn:Binding(get:{item.fileAccess.isActive},set:{model.perform("file-access",id:item.id,value:String($0))}))
        }
        if model.incognitoAvailable && item.incognitoAccess.isEnabled {
          Toggle("Allow in private sessions",isOn:Binding(get:{item.incognitoAccess.isActive},set:{model.perform("incognito",id:item.id,value:String($0))}))
        }
        if let hosts = item.permissions.runtimeHostPermissions {
          Picker("Site access",selection:Binding(get:{hosts.hostAccess},set:{model.perform("host-access",id:item.id,value:$0)})) {
            Text("When selected").tag("ON_CLICK")
            Text("On specific sites").tag("ON_SPECIFIC_SITES")
            if hosts.hasAllHosts { Text("On all sites").tag("ON_ALL_SITES") }
          }
          if hosts.hostAccess == "ON_SPECIFIC_SITES" {
            ForEach(hosts.hosts,id:\.host) { host in
              Toggle(host.host,isOn:Binding(get:{host.granted},set:{model.perform($0 ? "host-allow":"host-remove",id:item.id,value:host.host)}))
            }
            HStack {
              TextField("https://example.com/*",text:$sitePattern).textFieldStyle(.roundedBorder)
              Button("Add") { model.perform("host-allow",id:item.id,value:sitePattern); sitePattern = "" }.disabled(sitePattern.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
          }
        }
      }.padding(.top,8).font(.system(size:11)).toggleStyle(.switch).controlSize(.small)
        .disabled(!item.userMayModify)
    }.font(.system(size:12))
  }
}

private struct NativeExtensionCommands: View {
  let item: ChromeExtension
  @ObservedObject var model: NativeExtensionsModel
  let palette: NativeSpacePalette
  @State private var recording: String?
  @State private var recordingSession = UUID()
  @State private var saving: String?
  @State private var error: String?

  var body: some View {
    DisclosureGroup("Keyboard shortcuts") {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(item.commands, id: \.name) { command in
          VStack(alignment: .leading, spacing: 6) {
            Text(command.description.isEmpty ? command.name : command.description).font(.system(size: 11, weight: .medium))
            HStack(spacing: 6) {
              if recording == command.name && model.recordingCommand == item.id + ":" + command.name {
                if model.recordingReady {
                  let session = recordingSession
                  NativeExtensionShortcutCapture(ink: NSColor(palette.ink), surface: NSColor(palette.card.opacity(0.35))) { result in
                    guard recording == command.name, recordingSession == session else { return }
                  switch result {
                  case .cancel: stopRecording()
                  case .invalid(let message): error = message
                  case .value(let value):
                    stopRecording()
                    save(command.name) { try await model.updateShortcut(extensionID: item.id, commandName: command.name, keybinding: value) }
                  }
                  }.id(session).frame(minWidth: 95, maxWidth: .infinity).frame(height: 28)
                } else {
                  if let message = model.recordingError {
                    Text(message).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { model.retryRecording() }.buttonStyle(.plain)
                  } else { ProgressView().controlSize(.mini); Text("Preparing shortcut…").font(.system(size: 11)) }
                  Button("Cancel") { stopRecording() }.buttonStyle(.plain)
                }
              } else {
                Button {
                  error = nil; recordingSession = UUID(); recording = command.name; model.recordShortcut(item.id + ":" + command.name)
                } label: {
                  Text(command.keybinding.isEmpty ? "Not set" : command.keybinding)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(palette.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(!canEdit(command) || saving != nil)
                  .accessibilityLabel("Change shortcut for " + command.description)
              }
              if saving == command.name { ProgressView().controlSize(.mini).frame(width: 20) }
              else {
                Menu {
                  Button("Remove shortcut") {
                    stopRecording()
                    save(command.name) { try await model.updateShortcut(extensionID: item.id, commandName: command.name, keybinding: "") }
                  }.disabled(command.keybinding.isEmpty)
                  Menu("Media key") {
                    ForEach(mediaKeys, id: \.key) { choice in
                      Button(choice.title) {
                        stopRecording()
                        save(command.name) { try await model.updateShortcut(extensionID: item.id, commandName: command.name, keybinding: choice.key) }
                      }
                    }
                  }
                } label: { NativeGlyph.menuImage("more").frame(width: 16, height: 16) }
                  .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                  .accessibilityLabel("Shortcut actions for " + command.description)
                  .disabled(!canEdit(command) || saving != nil)
              }
            }
            HStack(spacing: 6) {
              Picker("Scope", selection: Binding(get: { command.scope == "GLOBAL" }, set: { global in
                stopRecording()
                save(command.name) { try await model.updateCommandScope(extensionID: item.id, commandName: command.name, global: global) }
              })) {
                Text("In Zacro").tag(false)
                Text("Global").tag(true)
              }.labelsHidden().fixedSize().controlSize(.small)
                .disabled(!item.userMayModify || command.isExtensionAction || !command.isActive || saving != nil)
                .accessibilityLabel("Shortcut scope for " + command.description)
              if item.isEnabled && !command.isActive && !command.keybinding.isEmpty {
                Text("Not active").foregroundStyle(palette.muted).font(.system(size: 10))
              }
            }
          }
        }
        if let error { Text(error).font(.system(size: 11)).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Shortcut error: " + error) }
      }.padding(.top, 8)
    }.font(.system(size: 12)).onDisappear { stopRecording() }
  }
  private let mediaKeys = [(key: "MediaPlayPause", title: "Play or pause"), (key: "MediaNextTrack", title: "Next track"),
    (key: "MediaPrevTrack", title: "Previous track"), (key: "MediaStop", title: "Stop playback")]
  private func canEdit(_ command: ChromeExtension.Command) -> Bool {
    item.userMayModify && !(item.isCommandRegistrationHandledExternally && command.scope == "GLOBAL")
  }
  private func stopRecording() {
    if let recording {
      if model.recordingCommand == item.id + ":" + recording { model.recordShortcut(nil) }
      self.recording = nil
    }
  }
  private func save(_ name: String, action: @escaping @MainActor () async throws -> Void) {
    saving = name; error = nil
    Task { @MainActor in
      defer { saving = nil }
      do { try await action() }
      catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }
}

/// Matches Chrome's extension shortcut input, which accepts a narrower key set
/// than the browser's own shortcuts. Display strings remain Chromium-owned.
private struct NativeExtensionShortcutCapture: NSViewRepresentable {
  enum Result { case cancel, invalid(String), value(String) }
  let ink: NSColor
  let surface: NSColor
  let receive: (Result) -> Void
  func makeNSView(context: Context) -> CaptureView {
    let view = CaptureView(); view.receive = receive; view.ink = ink; view.surface = surface
    view.setAccessibilityElement(true); view.setAccessibilityRole(.textField)
    view.setAccessibilityLabel("Press an extension shortcut")
    DispatchQueue.main.async { if let window = view.window, window.isKeyWindow { window.makeFirstResponder(view) } }
    return view
  }
  func updateNSView(_ view: CaptureView, context: Context) {
    view.receive = receive; view.ink = ink; view.surface = surface; view.needsDisplay = true
  }
  final class CaptureView: NSView {
    var receive: (Result) -> Void = { _ in }
    var ink: NSColor = .labelColor
    var surface: NSColor = .controlBackgroundColor
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
      let callback = receive
      DispatchQueue.main.async { callback(.cancel) }
      return true
    }
    override func draw(_ dirtyRect: NSRect) {
      surface.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
      let text = "Press shortcut…" as NSString
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink]
      let size = text.size(withAttributes: attributes)
      text.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
    override func keyDown(with event: NSEvent) {
      guard !event.isARepeat else { return }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if event.keyCode == 53 && flags.isEmpty { receive(.cancel); return }
      if [51, 117].contains(event.keyCode) && flags.isEmpty { receive(.value("")); return }
      guard !flags.intersection([.command, .control, .option]).isEmpty else {
        receive(.invalid("Include Command, Control, or Option.")); return
      }
      guard !(flags.contains(.option) && !flags.intersection([.command, .control]).isEmpty) else {
        receive(.invalid("Use Option separately from Command or Control.")); return
      }
      let special: [UInt16: String] = [43: "Comma", 47: "Period", 48: "Tab", 49: "Space", 117: "Delete",
        123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 114: "Insert"]
      let character = event.charactersIgnoringModifiers?.uppercased() ?? ""
      let key = special[event.keyCode] ?? (character.count == 1 && character.range(of: "^[A-Z0-9]$", options: .regularExpression) != nil ? character : "")
      guard !key.isEmpty else { receive(.invalid("Choose a letter, number, arrow, or navigation key.")); return }
      var parts: [String] = []
      if flags.contains(.command) { parts.append("Command") }
      if flags.contains(.control) { parts.append("Ctrl") }
      if flags.contains(.option) { parts.append("Alt") }
      if flags.contains(.shift) { parts.append("Shift") }
      parts.append(key); receive(.value(parts.joined(separator: "+")))
    }
  }
}
