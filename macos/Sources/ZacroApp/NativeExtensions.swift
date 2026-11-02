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
  private weak var activeDocument: ChromiumPage?
  private var activeAddress: String?
  private var actionRequest: Task<Void, Never>?
  private var actionGeneration = 0
  private var actionStates: [String: ChromeExtensionAction] = [:]
  private var actionIcons: [String: NSImage] = [:]
  var invokeAction: ((String, String, NSRect?) async throws -> Void)?
  init(store: BrowserStore, engine: ChromiumEngine, actions: BrowserActions) {
    self.store = store; self.engine = engine; self.actions = actions
  }
  var isPrivate: Bool { store.state.activeProfile?.isPrivate ?? true }
  func profileChanged() {
    guard scope != store.activeProfileID else { return }
    request?.cancel(); generation += 1; scope = store.activeProfileID
    actionRequest?.cancel(); actionGeneration += 1
    activeDocument = nil; activeAddress = nil; actionStates = [:]; actionIcons = [:]
    refreshPending = false
    entries = []; icons = [:]; error = nil; loading = false
    actions.siteControls.extensions = []; actions.siteControls.extensionsReady = isPrivate
    actions.siteControls.extensionError = nil
    if !isPrivate { refresh() }
  }
  func refresh() {
    guard !isPrivate, engine.contexts.values.contains(where: { $0.isOpen && !$0.isClosing && (store.owningWindowID == nil || $0.id == store.owningWindowID) }) else { return }
    guard !loading else { refreshPending = true; return }
    let profile = store.activeProfileID, revision = generation
    scope = profile; loading = true; error = nil
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
      return SiteExtensionItem(id: entry.id, name: state?.title.isEmpty == false ? state!.title : entry.name,
        image: actionIcons[entry.id] ?? icons[entry.id], badgeText: state?.badgeText ?? "",
        badgeColor: state.flatMap { Self.color($0.badgeColor) },
        badgeForeground: state.flatMap { Self.color($0.badgeForeground) },
        enabled: entry.isEnabled && (state?.enabled ?? true),
        pinned: entry.isPinned, canPin: entry.userMayModify,
        perform: { [weak self] in self?.perform("action", id: entry.id, expectedProfile: profile) },
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
    case .registryChanged, .installationChanged: refresh()
    case .actionChanged: refreshActions()
    case .storageChanged, .hostRequest, .bookmarksChanged, .downloadChanged, .downloadRemoved: break
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
  private func refreshActions() {
    actionRequest?.cancel(); actionGeneration += 1
    guard let page = activeDocument, page.profileID == store.activeProfileID,
      !isPrivate, let windowID = page.ownerWindowID, windowID == store.owningWindowID,
      let context = engine.context(id: windowID), context.isOpen, !context.isClosing else { return }
    let profile = store.activeProfileID, revision = generation, actionRevision = actionGeneration
    actionRequest = Task { [weak self, weak page] in
      do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
      guard let self, let page, self.valid(profile, revision) else { return }
      let manager = ChromeExtensionManager(engine: self.engine, profileID: profile)
      var states: [String: ChromeExtensionAction] = [:], images: [String: NSImage] = [:]
      for entry in self.entries where entry.isEnabled {
        guard !Task.isCancelled, self.activeDocument === page, self.actionGeneration == actionRevision else { return }
        if let state = try? await manager.action(entry.id, on: page) {
          states[entry.id] = state
          if let encoded = state.iconPNG, encoded.utf8.count <= 1_400_000,
            let data = Data(base64Encoded: encoded), let image = NSImage(data: data) { images[entry.id] = image }
        }
      }
      guard self.valid(profile, revision), self.activeDocument === page,
        page.ownerWindowID == windowID, context.isOpen, !context.isClosing,
        self.actionGeneration == actionRevision else { return }
      self.actionStates = states; self.actionIcons = images
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
        case "reload": try await manager.reload(id)
        case "options": try await manager.showOptions(id)
        case "file-access": try await manager.setFileAccess(id, allowed: value == "true")
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
  func close() {
    request?.cancel(); request = nil; generation += 1
    actionRequest?.cancel(); actionRequest = nil; actionGeneration += 1
    scope = nil; activeDocument = nil; activeAddress = nil; loading = false; refreshPending = false
    actionStates = [:]; actionIcons = [:]
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
          Button("Chrome Web Store", action: openStore)
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
            VStack(alignment:.leading,spacing:10) {
              HStack(spacing:10) {
                if let image = model.icons[item.id] { Image(nsImage:image).resizable().scaledToFit().frame(width:30,height:30) }
                else { NativeGlyph("extension").frame(width:26,height:26).foregroundStyle(palette.accent) }
                VStack(alignment:.leading,spacing:3) {
                  Text(item.name).font(.system(size:13,weight:.semibold))
                  Text(item.version).font(.system(size:11)).foregroundStyle(palette.muted)
                }
                Spacer()
                Toggle("Enabled",isOn:Binding(get:{item.isEnabled},set:{model.perform($0 ? "enable":"disable",id:item.id)})).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!item.userMayModify)
              }
              Text(item.description).font(.system(size:12)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
              if !item.runtimeWarnings.isEmpty || !item.installWarnings.isEmpty {
                Text((item.installWarnings+item.runtimeWarnings).joined(separator:"\n")).font(.system(size:11)).foregroundStyle(palette.ink)
              }
              HStack {
                Button(item.isPinned ? "Unpin":"Pin") { model.perform(item.isPinned ? "unpin":"pin",id:item.id) }.disabled(!item.userMayModify)
                if item.optionsPage != nil { Button("Options") { model.perform("options",id:item.id) } }
                Spacer()
                Menu {
                  Button("Reload") { model.perform("reload",id:item.id) }
                  Button("Remove…",role:.destructive) { model.perform("remove",id:item.id) }.disabled(item.mustRemainInstalled || !item.userMayModify)
                } label: { NativeGlyph("more").frame(width:16,height:16) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
              }.font(.system(size:12))
              NativeExtensionPermissions(item: item, model: model, palette: palette)
            }.padding(12).background(palette.ink.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
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
