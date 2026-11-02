import AppKit
import SwiftUI
import ZacroServices

struct NativeSyncSettingsView: View {
  @ObservedObject var model: NativeServicesModel
  let palette: NativeSpacePalette
  @State private var expanded = false
  @State private var presenting = false
  @State private var busy = false
  @State private var mode = ""
  @State private var error = ""
  @State private var modalError = ""
  @State private var formProfile = ""
  @State private var endpoint = ""
  @State private var username = ""
  @State private var password = ""
  @State private var newPassword = ""
  @State private var recoveryCode = ""
  @State private var name = ""
  @State private var selectedID = ""
  @State private var deviceName = Host.current().localizedName ?? "Mac"
  @State private var confirm = false
  @State private var libraryEnabled = true
  @State private var settingsEnabled = false
  @State private var libraryChoice = "remote-only"
  @State private var settingsChoice = "use-remote"
  @State private var records: [ServiceJSON] = []
  @State private var preview: ServiceJSON = [:]
  @State private var recoveryCodes: [String] = []
  init(model: NativeServicesModel, palette: NativeSpacePalette, initiallyExpanded: Bool = false) {
    self.model = model; self.palette = palette; _expanded = State(initialValue:initiallyExpanded)
  }
  private var profileID: String { model.ai["profileId"].string }
  private var current: ServiceJSON { model.sync["profiles"].array.first(where: { $0["profileId"].string == profileID }) ?? .null }
  private var signedIn: Bool { model.sync["account"] != .null && !model.sync["account"].object.isEmpty }
  private var labels: [String:String] { [
    "setup-required":"Set up a synchronization service","signed-out":"Signed out","connected":"Connected",
    "offline":"Offline — changes remain on this device","conflict":"Some changes need attention",
    "reconnect-required":"Sign in again to reconnect this device","dataset-removed":"The sync profile was removed"
  ] }
  var body: some View {
    DisclosureGroup("Account & sync",isExpanded:$expanded) {
      VStack(alignment:.leading,spacing:12) {
        if model.sync["state"] == "private" || model.ai["private"].bool {
          Text("Private profiles do not use extensions or synchronization.").font(.system(size:11)).foregroundStyle(palette.muted)
        } else {
          Text(labels[model.sync["state"].string] ?? model.sync["state"].string).font(.system(size:12,weight:.medium))
          if !model.sync["startupError"].string.isEmpty {
            Text(model.sync["startupError"].string).font(.system(size:11)).foregroundStyle(palette.muted).textSelection(.enabled)
          }
          if !model.sync["endpoint"].string.isEmpty { Text(model.sync["endpoint"].string).font(.system(size:10)).foregroundStyle(palette.muted).textSelection(.enabled) }
          Button("Configure service") { open("configure") }.buttonStyle(NativeServiceButtonStyle(palette:palette))
          if !model.sync["endpoint"].string.isEmpty && !signedIn {
            ViewThatFits(in:.horizontal) {
              HStack(spacing:5) { accountButtons }
              VStack(alignment:.leading,spacing:5) { accountButtons }
            }
          }
          if signedIn { account }
          ForEach(model.sync["native"]["pending"].array, id:\.text) { entry in
            HStack(spacing:8) {
              Image(systemName:"puzzlepiece.extension")
              Text(entry["extensionId"].string).font(.system(size:10)).lineLimit(2)
              Spacer(minLength:0)
              Button("Review & install") { perform("native-install",payload:["id":entry["extensionId"]]) }
                .buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
            }
          }
          ForEach(model.sync["native"]["errors"].array, id:\.text) { issue in
            VStack(alignment:.leading,spacing:6) {
              if !issue["name"].string.isEmpty { Text(issue["name"].string).font(.system(size:11,weight:.semibold)) }
              Text(issue["message"].string).font(.system(size:11)).foregroundStyle(palette.muted).textSelection(.enabled)
              if issue["recovery"].bool {
                HStack(spacing:5) {
                  Button("Keep local settings") { perform("native-keep-local",payload:["id":issue["extensionId"]]) }
                  if signedIn, current["settingsSync"].bool {
                    Button("Use synced settings") { perform("native-use-remote",payload:["id":issue["extensionId"]]) }
                  }
                }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
              }
            }
          }
          if !model.sync["native"]["errors"].array.isEmpty {
            Button("Retry extension synchronization") { perform("native-retry") }
              .buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
          }
          if !model.sync["cleanupError"].string.isEmpty {
            Text("A deleted profile still has local service data to remove. " + model.sync["cleanupError"].string)
              .font(.system(size:11)).foregroundStyle(palette.muted)
            Button("Retry profile cleanup") { perform("finish-profile-cleanup") }
              .buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
          }
          if !error.isEmpty { Text(error).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
        }
      }.padding(.top,12).padding(.bottom,8)
    }.font(.system(size:12,weight:.semibold)).foregroundStyle(palette.ink).tint(palette.accent)
      .sheet(isPresented:$presenting,onDismiss:clearSecrets) { dialog }
      .onChange(of:profileID) { _,_ in presenting = false; clearSecrets(); error = "" }
      .onChange(of:model.sync["state"]) { _,state in if state == "private" { presenting = false; clearSecrets() } }
  }
  @ViewBuilder private var accountButtons: some View {
    Button("Create account") { open("register") }.buttonStyle(NativeServiceButtonStyle(palette:palette,prominent:true))
    Button("Sign in") { open("login") }.buttonStyle(NativeServiceButtonStyle(palette:palette))
    Button("Recover account") { open("recover") }.buttonStyle(NativeServiceButtonStyle(palette:palette))
  }
  private var account: some View {
    VStack(alignment:.leading,spacing:12) {
      Text("Signed in as ") + Text(model.sync["account"]["username"].string).bold()
      HStack(spacing:4) {
        Button("Devices") { loadDevices() }
        Button("Sync now") { perform("now") }
        Button("Sign out") { perform("logout") }
      }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
      if current != .null {
        Text(current["name"].string).fontWeight(.semibold) + Text(" is linked to this profile.")
        Text("Library sync: \(current["librarySync"] == false ? "Off" : "On") · Settings sync: \(current["settingsSync"].bool ? "On" : "Off")").font(.system(size:10)).foregroundStyle(palette.muted)
        Text(current["pending"].int > 0 ? "Changes are waiting to be accepted by the service." : current["lastSync"] == .null ? "Waiting for the first synchronization." : "Last synchronized \(date(current["lastSync"]))")
          .font(.system(size:10)).foregroundStyle(palette.muted)
        VStack(alignment:.leading,spacing:5) {
          Button(current["librarySync"] == false ? "Enable library sync" : "Turn off library sync") {
            if current["librarySync"] == false { review(current["datasetId"].string,libraryOnly:true) }
            else { perform("library",payload:["enabled":false]) }
          }
          Button(current["settingsSync"].bool ? "Turn off settings sync" : "Enable settings sync") {
            if current["settingsSync"].bool { perform("settings",payload:["enabled":false]) } else { open("settings") }
          }
          HStack(spacing:5) {
            Button("Unlink profile") { perform("unlink") }
            Button("Delete cloud profile") { selectedID = current["datasetId"].string; open("delete-dataset") }
          }
        }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
      } else {
        Text("This browser profile is not linked. Local extensions keep working.").font(.system(size:11)).foregroundStyle(palette.muted)
        Button("Link profile") { loadDatasets() }.buttonStyle(NativeServiceButtonStyle(palette:palette,prominent:true)).disabled(busy)
      }
      ForEach(current["rejected"].array,id:\.text) { rejected in
        VStack(alignment:.leading,spacing:7) {
          Text(rejected["code"] == "storage_quota" ? "Settings could not fit in cloud storage. Your local values are retained." : "A change conflicts with the current sync profile.")
            .font(.system(size:11)).foregroundStyle(palette.muted)
          HStack(spacing:4) {
            Button("Retry") { perform("retry",payload:["id":rejected["id"]]) }
            Button("Export") { perform("export",payload:["id":rejected["id"]]) }
            Button("Discard") { selectedID = rejected["id"].string; open("discard") }
          }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
        }.padding(9).background(palette.card.opacity(0.45),in:RoundedRectangle(cornerRadius:8))
      }
      VStack(alignment:.leading,spacing:5) {
        HStack(spacing:4) {
          Button("Change password") { open("password") }
          Button("Recovery codes") { open("codes") }
        }
        Button("Delete account") { open("delete-account") }.foregroundStyle(.red)
      }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
    }.font(.system(size:12,weight:.regular))
  }
  private var dialog: some View {
    VStack(alignment:.leading,spacing:15) {
      HStack {
        Text(title).font(.system(size:16,weight:.semibold))
        Spacer()
        Button { presenting = false } label: { Image(systemName:"xmark").font(.system(size:12)).frame(width:24,height:24) }.buttonStyle(.plain).accessibilityLabel("Close")
      }
      if !description.isEmpty { Text(description).font(.system(size:12)).foregroundStyle(palette.muted).lineSpacing(3) }
      ScrollView {
        VStack(alignment:.leading,spacing:13) { form }
          .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,2)
      }.scrollIndicators(.hidden)
      if !modalError.isEmpty { Text(modalError).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if busy { ProgressView().controlSize(.small) }
        Spacer()
        Button(mode == "recovery" ? "I saved my recovery codes" : mode == "devices" ? "Done" : "Cancel") { presenting = false }
          .buttonStyle(NativeServiceButtonStyle(palette:palette))
        if !["devices","recovery"].contains(mode) {
          Button(submitTitle) { submit() }.buttonStyle(NativeServiceButtonStyle(palette:palette,prominent:true)).disabled(busy || !valid)
        }
      }
    }.padding(20).frame(width:450,height:dialogHeight).background(palette.chrome).foregroundStyle(palette.ink).tint(palette.accent)
      .interactiveDismissDisabled(busy)
  }
  private var dialogHeight: CGFloat { ["review","library","devices","link"].contains(mode) ? 540 : mode == "recover" || mode == "register" ? 480 : mode == "recovery" ? 500 : 350 }
  private var title: String { [
    "configure":"Synchronization service","register":"Create account","login":"Sign in","recover":"Recover account",
    "devices":"Your devices","rename-device":"Rename device","revoke-device":"Revoke device?",
    "link":"Link browser profile","review":"Review profile link","library":"Enable library synchronization",
    "settings":"Enable settings synchronization","password":"Change password","codes":"Replace recovery codes",
    "recovery":"Save your recovery codes","delete-account":"Delete account","delete-dataset":"Delete cloud profile",
    "discard":"Discard unsynced change?"
  ][mode] ?? "" }
  private var description: String { [
    "configure":"Enter the HTTPS address of a service you trust. Changing it signs out this device.",
    "register":"Use a username and a password of at least 12 characters. No email account is required.",
    "login":"Sign in to your configured synchronization service.",
    "recover":"Use one unused recovery code. This replaces your password, recovery codes and previous device sessions.",
    "devices":"Revoking a device stops its future synchronization. Files already downloaded remain on that device.",
    "rename-device":"Choose a name you will recognize.",
    "revoke-device":"This device will need to sign in again. Previously downloaded data cannot be erased remotely.",
    "link":"Create a new sync profile or review one already owned by your account.",
    "review":"Review the extension library before linking. New extensions still require permission on this device.",
    "library":"Choose how to share your extension library. Your settings synchronization choice stays the same.",
    "settings":"Review the privacy notice and choose which settings to use.",
    "password":"Other devices will be signed out.",
    "codes":"Previous recovery codes will stop working. Save the replacement codes.",
    "recovery":"Store these codes somewhere private. Each code can be used once. They will disappear when you close this window.",
    "delete-account":"Remove your account, all cloud profiles and device sessions. Local browser data remains on each device.",
    "delete-dataset":"Remove the cloud extension library and settings from this sync profile. Local installations remain available.",
    "discard":"The accepted cloud settings will replace this rejected local change. Export it first if you want a copy."
  ][mode] ?? "" }
  private var submitTitle: String { [
    "configure":"Save service","register":"Create account","login":"Sign in","recover":"Recover account",
    "rename-device":"Rename device","revoke-device":"Revoke device","link":"Create sync profile",
    "review":"Link this profile","library":"Enable library sync","settings":"Enable settings sync",
    "password":"Change password","codes":"Replace recovery codes","delete-account":"Delete permanently",
    "delete-dataset":"Delete permanently","discard":"Discard change"
  ][mode] ?? "Save" }
  @ViewBuilder private var form: some View {
    switch mode {
    case "configure": field("Service URL") { TextField("https://sync.example.com",text:$endpoint) }
    case "register","login","recover":
      field("Username") { TextField("Username",text:$username) }
      if mode == "recover" {
        field("Recovery code") { SecureField("Recovery code",text:$recoveryCode) }
        field("New password") { SecureField("At least 12 characters",text:$newPassword) }
      } else { field("Password") { SecureField(mode == "register" ? "At least 12 characters" : "Password",text:$password) } }
      field("Device name") { TextField("This Mac",text:$deviceName) }
    case "password","codes":
      field("Current password") { SecureField("Current password",text:$password) }
      if mode == "password" { field("New password") { SecureField("At least 12 characters",text:$newPassword) } }
    case "delete-account","delete-dataset":
      field("Current password") { SecureField("Current password",text:$password) }
      Toggle("I understand this cloud data will be deleted",isOn:$confirm).toggleStyle(.checkbox).font(.system(size:12))
    case "recovery":
      VStack(alignment:.leading,spacing:9) {
        ForEach(recoveryCodes,id:\.self) { code in Text(code).font(.system(size:13,design:.monospaced)).textSelection(.enabled) }
      }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(palette.card.opacity(0.6),in:RoundedRectangle(cornerRadius:10))
    case "devices":
      ForEach(records,id:\.text) { device in deviceRow(device) }
    case "rename-device": field("Name") { TextField("Device name",text:$name) }
    case "link":
      if !records.isEmpty {
        Picker("Existing sync profile",selection:$selectedID) { ForEach(records,id:\.text) { Text($0["name"].string).tag($0["id"].string) } }
        Button("Review selected profile") { review(selectedID) }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy || selectedID.isEmpty)
      }
      field("New sync profile name") { TextField("Name",text:$name) }
    case "review","library":
      Text(preview["dataset"]["name"].string).font(.system(size:14,weight:.semibold))
      Text("\(preview["extensions"].array.filter { $0["state"] != "removed" }.count) extensions in the sync profile; \(preview["localExtensions"].array.count) portable extensions on this device.")
        .font(.system(size:11)).foregroundStyle(palette.muted)
      ForEach(preview["extensions"].array.filter { $0["state"] != "removed" },id:\.text) { entry in
        Label("\(entry["name"].string.isEmpty ? entry["extensionId"].string : entry["name"].string) · \(entry["state"].string)",systemImage:"puzzlepiece.extension").font(.system(size:11)).lineLimit(2)
      }
      if mode == "review" {
        Toggle("Sync extension library",isOn:$libraryEnabled).toggleStyle(.switch).controlSize(.small)
        Text("Share which portable extensions are installed, enabled or removed. With this off, settings can still sync for extensions already in the sync profile.").font(.system(size:10)).foregroundStyle(palette.muted)
      }
      Picker("Extension library",selection:$libraryChoice) {
        Text("Use the sync profile’s library").tag("remote-only")
        Text("Also share this device’s portable extensions").tag("merge-local")
      }
      if mode == "review" { settingsConsent }
    case "settings": settingsConsent
    default: EmptyView()
    }
  }
  private var settingsConsent: some View {
    VStack(alignment:.leading,spacing:10) {
      Toggle("Sync extension settings",isOn:$settingsEnabled).toggleStyle(.switch).controlSize(.small)
      Text("Extensions choose what they save. Settings may contain personal information or credentials. The synchronization service can read these values. Enabling this option means you agree to share them with your configured service.")
        .font(.system(size:11)).foregroundStyle(palette.muted).lineSpacing(3)
      Picker("Choose settings",selection:$settingsChoice) {
        Text("Use settings from the sync profile").tag("use-remote")
        Text("Upload settings from this device").tag("upload-local")
      }.disabled(!settingsEnabled)
    }
  }
  private func deviceRow(_ device: ServiceJSON) -> some View {
    VStack(alignment:.leading,spacing:7) {
      Text(device["name"].string).font(.system(size:13,weight:.semibold))
      Text(device["platform"].string + (device["id"] == model.sync["device"]["id"] ? " · This device" : "") + (device["revoked"].bool ? " · Revoked" : ""))
        .font(.system(size:11)).foregroundStyle(palette.muted)
      Text("Registered \(date(device["createdAt"]))\nLast active \(date(device["lastSeenAt"]))").font(.system(size:10)).foregroundStyle(palette.muted)
      if !device["revoked"].bool {
        HStack {
          Button("Rename") { selectedID = device["id"].string; name = device["name"].string; mode = "rename-device" }
          Button("Revoke") { selectedID = device["id"].string; mode = "revoke-device" }
        }.buttonStyle(NativeServiceButtonStyle(palette:palette))
      }
    }.frame(maxWidth:.infinity,alignment:.leading).padding(11).background(palette.card.opacity(0.45),in:RoundedRectangle(cornerRadius:9))
  }
  private var valid: Bool {
    switch mode {
    case "configure": return !endpoint.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    case "register": return username.count >= 3 && username.count <= 64 && password.count >= 12 && password.count <= 256 && !deviceName.isEmpty
    case "login": return !username.isEmpty && !password.isEmpty && !deviceName.isEmpty
    case "recover": return !username.isEmpty && !recoveryCode.isEmpty && newPassword.count >= 12 && newPassword.count <= 256
    case "password": return !password.isEmpty && newPassword.count >= 12 && newPassword.count <= 256
    case "codes": return !password.isEmpty
    case "delete-account","delete-dataset": return !password.isEmpty && confirm
    case "settings": return settingsEnabled
    case "link","rename-device": return !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count <= 128
    default: return true
    }
  }
  private func field<Content:View>(_ label:String,@ViewBuilder content:()->Content)->some View {
    VStack(alignment:.leading,spacing:5) { Text(label).font(.system(size:11)); content().textFieldStyle(.plain).padding(8).background(palette.card.opacity(0.6),in:RoundedRectangle(cornerRadius:7)) }
  }
  private func date(_ value: ServiceJSON) -> String {
    guard value.number > 0 else { return "Unknown" }
    return Date(timeIntervalSince1970:value.number / 1000).formatted(date:.abbreviated,time:.shortened)
  }
  private func clearSecrets() { password = ""; newPassword = ""; recoveryCode = ""; recoveryCodes = []; confirm = false; modalError = "" }
  private func open(_ mode: String) {
    clearSecrets(); self.mode = mode; formProfile = profileID; modalError = ""; settingsEnabled = false; settingsChoice = "use-remote"; libraryChoice = "remote-only"; libraryEnabled = true
    if mode == "configure" { endpoint = model.sync["endpoint"].string }
    if ["register","login","recover"].contains(mode) { username = "" }
    presenting = true
  }
  private func call(_ action:String,payload:ServiceJSON = [:]) async throws -> ServiceJSON {
    try await model.syncAction("sync:" + action,payload:payload.merging(["profileId":.string(formProfile.isEmpty ? profileID : formProfile)]))
  }
  private func perform(_ action:String,payload:ServiceJSON = [:]) {
    guard !busy else { return }; busy = true; error = ""; formProfile = profileID
    Task {
      defer { busy = false }
      do { _ = try await call(action,payload:payload) } catch { self.error = error.localizedDescription }
    }
  }
  private func loadDevices() {
    guard !busy else { return }; busy = true; formProfile = profileID
    Task {
      defer { busy = false }
      do { let result = try await call("devices"); guard formProfile == profileID else { return }; records = result.array; open("devices") }
      catch { self.error = error.localizedDescription }
    }
  }
  private func loadDatasets() {
    guard !busy else { return }; busy = true; formProfile = profileID
    Task {
      defer { busy = false }
      do { let result = try await call("datasets"); guard formProfile == profileID else { return }; records = result.array; selectedID = records.first?["id"].string ?? ""; name = ""; open("link") }
      catch { self.error = error.localizedDescription }
    }
  }
  private func review(_ id:String,libraryOnly:Bool = false) {
    guard !busy else { return }; busy = true; formProfile = profileID
    Task {
      defer { busy = false }
      do {
        let result = try await call("link-preview",payload:["datasetId":.string(id)])
        guard formProfile == profileID else { return }; preview = result; selectedID = id; open(libraryOnly ? "library" : "review")
      } catch { if presenting { modalError = error.localizedDescription } else { self.error = error.localizedDescription } }
    }
  }
  private func submit() {
    guard !busy, valid, formProfile == profileID else { return }; busy = true; modalError = ""
    let originalMode = mode
    Task {
      defer { busy = false }
      do {
        let result: ServiceJSON
        switch originalMode {
        case "configure": result = try await call("configure",payload:["endpoint":.string(endpoint)])
        case "register","login": result = try await call(originalMode,payload:["username":.string(username),"password":.string(password),"deviceName":.string(deviceName)])
        case "recover": result = try await call("recover",payload:["username":.string(username),"recoveryCode":.string(recoveryCode),"newPassword":.string(newPassword),"deviceName":.string(deviceName)])
        case "password": result = try await call("password",payload:["password":.string(password),"newPassword":.string(newPassword)])
        case "codes": result = try await call("recovery-codes",payload:["password":.string(password)])
        case "delete-account","delete-dataset": result = try await call(originalMode,payload:["id":.string(selectedID),"password":.string(password),"confirm":.bool(confirm)])
        case "rename-device": result = try await call("rename-device",payload:["id":.string(selectedID),"name":.string(name)])
        case "revoke-device": result = try await call("revoke-device",payload:["id":.string(selectedID)])
        case "discard": result = try await call("discard",payload:["id":.string(selectedID)])
        case "settings": result = try await call("settings",payload:["enabled":true,"settingsConsent":.bool(settingsEnabled),"settingsChoice":.string(settingsChoice)])
        case "library": result = try await call("library",payload:["enabled":true,"libraryChoice":.string(libraryChoice)])
        case "review": result = try await call("link",payload:["datasetId":.string(selectedID),"libraryChoice":.string(libraryChoice),"librarySync":.bool(libraryEnabled),"settingsSync":.bool(settingsEnabled),"settingsConsent":.bool(settingsEnabled),"settingsChoice":.string(settingsChoice)])
        case "link":
          let dataset = try await call("create-dataset",payload:["name":.string(name)])
          let reviewed = try await call("link-preview",payload:["datasetId":dataset["id"]])
          guard formProfile == profileID else { return }; preview = reviewed; selectedID = dataset["id"].string; mode = "review"; return
        default: return
        }
        guard formProfile == profileID else { return }
        password = ""; newPassword = ""; recoveryCode = ""
        if !result["recoveryCodes"].array.isEmpty { recoveryCodes = result["recoveryCodes"].array.map(\.string); mode = "recovery" }
        else if ["rename-device","revoke-device"].contains(originalMode), signedIn {
          records = try await call("devices").array; mode = "devices"
        } else { presenting = false }
      } catch { if formProfile == profileID { modalError = error.localizedDescription } }
    }
  }
}
