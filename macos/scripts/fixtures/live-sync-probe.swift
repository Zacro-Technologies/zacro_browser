import Foundation
import ZacroServices

final class ProbeSecrets: NativeSecretStore, @unchecked Sendable {
  let lock = NSLock(); var values:[String:Data] = [:]
  func read(_ key:String) throws -> Data? { lock.withLock { values[key] } }
  func write(_ data:Data,key:String) throws { lock.withLock { values[key] = data } }
  func remove(_ key:String) throws { _ = lock.withLock { values.removeValue(forKey:key) } }
}
func verify(_ value:Bool,_ label:String) throws {
  guard value else { throw ServiceError("PROBE",label) }
  print("PASS " + label)
}
func run() async throws {
  let endpoint=CommandLine.arguments[1], root=URL(fileURLWithPath:CommandLine.arguments[2])
  let password="temporary-fixture-" + UUID().uuidString, username="native_" + UUID().uuidString.prefix(12).lowercased()
  let secretA=ProbeSecrets(), secretB=ProbeSecrets(), id=String(repeating:"a",count:32)
  let item:ServiceJSON=["extensionId":.string(id),"source":["kind":"web-store","id":.string(id)],"state":"enabled"]
  let context=ExtensionStorageContext(profileID:"personal",extensionID:id,permissions:["storage"],trusted:true)
  func client(_ name:String,_ secrets:ProbeSecrets) throws -> NativeSyncClient {
    try NativeSyncClient(directory:root.appendingPathComponent(name),getProfile:{ AIProfileScope(id:$0) },activeProfile:{AIProfileScope(id:"personal")},localLibrary:{_ in [item]},secrets:secrets,allowInsecureLoopback:true,autoSync:false)
  }
  let a=try client("a",secretA), b=try client("b",secretB)
  _ = try await a.configure(endpoint:endpoint); _ = try await b.configure(endpoint:endpoint)
  let registered=try await a.handle("sync:register",payload:["username":.string(username),"password":.string(password),"deviceName":"Native A"])
  try verify(!registered["account"]["id"].string.isEmpty && !registered["recoveryCodes"].array.isEmpty,"native registration and recovery codes")
  let dataset=try await a.handle("sync:create-dataset",payload:["name":"Native integration"])
  let datasetID=dataset["id"].string.isEmpty ? dataset["dataset"]["id"].string : dataset["id"].string
  try verify(!datasetID.isEmpty,"dataset creation")
  try await a.seedNativeStorage(context,values:["fromA":1])
  _ = try await a.handle("sync:link",payload:["datasetId":.string(datasetID),"libraryChoice":"merge-local","settingsSync":true,"settingsConsent":true,"settingsChoice":"upload-local"])
  _ = await a.syncNow()
  try verify(await a.status()["profiles"].array.first?["pending"] == 0,"atomic library and settings upload")
  _ = try await b.handle("sync:login",payload:["username":.string(username),"password":.string(password),"deviceName":"Native B"])
  let preview=try await b.handle("sync:link-preview",payload:["datasetId":.string(datasetID)])
  try verify(preview["extensions"].array.count == 1,"library preview over URLSession")
  _ = try await b.handle("sync:link",payload:["datasetId":.string(datasetID),"libraryChoice":"remote-only","settingsSync":true,"settingsConsent":true,"settingsChoice":"use-remote"])
  try verify(try await b.nativeStorageValues(context) == ["fromA":1],"second client downloads selected settings")
  try await b.adoptNativeInstallation(context,values:["fromA":1],incarnationID:id+":1")
  try await b.observeNativeStorageChanges(context,changes:["fromB":["newValue":2]])
  _ = await b.syncNow(); _ = await a.syncNow()
  try verify(try await a.nativeStorageValues(context) == ["fromA":1,"fromB":2],"native storage mutation reaches peer")
  await a.close()
  let restored=try client("a",secretA); await restored.start(); _ = await restored.syncNow()
  try verify(try await restored.nativeStorageValues(context) == ["fromA":1,"fromB":2],"durable client restart retains link and values")
  let devices=try await restored.handle("sync:devices")
  try verify(devices.array.count == 2,"device inventory")
  let deviceID=await restored.status()["device"]["id"]
  _ = try await restored.handle("sync:rename-device",payload:["id":deviceID,"name":"Native renamed"])
  try verify(await restored.status()["device"]["name"] == "Native renamed","current device rename")
  _ = try await restored.handle("sync:delete-dataset",payload:["id":.string(datasetID),"password":.string(password),"confirm":true])
  try verify(await restored.status()["profiles"].array.isEmpty,"dataset deletion unlinks local profile")
  _ = try await restored.handle("sync:delete-account",payload:["password":.string(password),"confirm":true])
  try verify(await restored.status()["account"] == .null,"account deletion detaches credentials")
  await restored.close(); await b.close()
}
do { try await run() } catch {
  fputs("FAIL native live sync probe: \(error.localizedDescription)\n",stderr)
  exit(1)
}
