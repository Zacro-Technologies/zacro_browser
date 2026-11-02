// Browser-context-owned registry/storage observation. No renderer bridge.
#include "base/supports_user_data.h"
#include "base/uuid.h"
#include "chrome/browser/extensions/extension_action_dispatcher.h"
#include "extensions/browser/api/storage/storage_frontend.h"
#include "extensions/browser/api/storage/storage_area_namespace.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/install_prefs_helper.h"
#include "extensions/common/permissions/permissions_data.h"

void ZacroObserveProfileDownloads(content::BrowserContext* context);

void ZacroSetTopologyObserved(content::BrowserContext* context, bool observed);

class ZacroExtensionContext : public base::SupportsUserData::Data,
                              public extensions::ExtensionRegistryObserver,
                              public extensions::ExtensionActionDispatcher::Observer {
 public:
  using Events = base::RepeatingCallbackList<void(const std::string&, const base::DictValue&)>;
  static ZacroExtensionContext* Get(content::BrowserContext* context) {
    static const char key[] = "zacro.native.extensions";
    if (auto* value = context->GetUserData(key)) return static_cast<ZacroExtensionContext*>(value);
    auto value = std::make_unique<ZacroExtensionContext>(context);
    auto* result = value.get(); context->SetUserData(key, std::move(value)); return result;
  }
  explicit ZacroExtensionContext(content::BrowserContext* context) : context_(context) {
    registry_ = extensions::ExtensionRegistry::Get(context);
    if (registry_) registry_->AddObserver(this);
    dispatcher_ = extensions::ExtensionActionDispatcher::Get(context);
    if (dispatcher_) dispatcher_->AddObserver(this);
    // Incognito state never participates in a portable storage stream.
    if (!context->IsOffTheRecord()) {
      auto* storage = extensions::StorageFrontend::Get(context);
      if (storage) storage_observer_ = storage->ObserveNativeChanges(base::BindRepeating(
          &ZacroExtensionContext::StorageChanged, base::Unretained(this)));
    }
  }
  ~ZacroExtensionContext() override {
    if (registry_) registry_->RemoveObserver(this);
    if (dispatcher_) dispatcher_->RemoveObserver(this);
  }
  std::string InstallationID(const extensions::Extension& extension) {
    auto& entry = installations_[extension.id()];
    if (entry.first.get() != &extension) {
      entry.first = &extension; entry.second = base::Uuid::GenerateRandomV4().AsLowercaseString();
    }
    return entry.second;
  }
  bool IsCurrent(const extensions::Extension& extension, const std::string& installation) {
    return registry_ && registry_->GetInstalledExtension(extension.id()) == &extension &&
        InstallationID(extension) == installation;
  }
  std::string IncarnationID(const extensions::Extension& extension) {
    auto* prefs = extensions::ExtensionPrefs::Get(context_);
    if (!prefs) return {};
    auto first = extensions::GetFirstInstallTime(prefs, extension.id());
    if (first.is_null()) return {};
    // Chromium preserves first_install_time across updates and deletes it at
    // uninstall. This is an incarnation identifier, separate from the random
    // in-process nonce that invalidates outstanding work on object replacement.
    return extension.id() + ":" + base::NumberToString(first.ToDeltaSinceWindowsEpoch().InMicroseconds());
  }
  base::CallbackListSubscription Observe(Events::CallbackType callback) { return events_.Add(std::move(callback)); }
  void NotifyNative(const std::string& method, const base::DictValue& params) { events_.Notify(method, params); }
  void NotifyHost(const base::DictValue& request) { events_.Notify("Zacro.extensionHostRequest", request); }
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension* extension) override {
    InstallationID(*extension); RegistryChanged();
  }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension*, extensions::UnloadedExtensionReason) override { RegistryChanged(); }
  void OnExtensionWillBeInstalled(content::BrowserContext*, const extensions::Extension* extension,
      bool, const std::string&) override { installations_.erase(extension->id()); }
  void OnExtensionInstalled(content::BrowserContext*, const extensions::Extension* extension, bool is_update) override {
    InstallationID(*extension);
    events_.Notify("Zacro.extensionInstallationChanged", base::DictValue().Set("id", extension->id())
        .Set("kind", is_update ? "updated" : "installed"));
    RegistryChanged();
  }
  void OnExtensionUninstalled(content::BrowserContext*, const extensions::Extension* extension, extensions::UninstallReason) override {
    installations_.erase(extension->id());
    events_.Notify("Zacro.extensionInstallationChanged", base::DictValue().Set("id", extension->id()).Set("kind", "uninstalled"));
    RegistryChanged();
  }
  void OnShutdown(extensions::ExtensionRegistry* registry) override {
    registry->RemoveObserver(this); registry_ = nullptr; installations_.clear();
  }
  void OnShuttingDown() override { dispatcher_->RemoveObserver(this); dispatcher_ = nullptr; }
  void OnExtensionActionUpdated(extensions::ExtensionAction* action, content::WebContents* contents,
      content::BrowserContext* context) override {
    if (!action || context != context_) return;
    base::DictValue params; params.Set("id", action->extension_id());
    if (contents) params.Set("tabID", sessions::SessionTabHelper::IdForTab(contents).id());
    events_.Notify("Zacro.extensionActionChanged", params);
  }
 private:
  void RegistryChanged() { events_.Notify("Zacro.extensionRegistryChanged", base::DictValue()); }
  void StorageChanged(const extensions::ExtensionId& id, extensions::StorageAreaNamespace area,
      const base::Value& changes, const std::string& origin, const extensions::Extension* mutation_owner) {
    if (area != extensions::StorageAreaNamespace::kSync || origin == "zacro.private" ||
        !registry_ || context_->IsOffTheRecord()) return;
    const auto* extension = registry_->GetInstalledExtension(id);
    if (!extension || (mutation_owner && mutation_owner != extension) ||
        !extension->permissions_data()->HasAPIPermission("storage")) return;
    events_.Notify("Zacro.extensionStorageChanged", base::DictValue().Set("id", id)
        .Set("installationID", InstallationID(*extension)).Set("changes", changes.Clone()).Set("origin", origin));
  }
  raw_ptr<content::BrowserContext> context_;
  raw_ptr<extensions::ExtensionRegistry> registry_ = nullptr;
  raw_ptr<extensions::ExtensionActionDispatcher> dispatcher_ = nullptr;
  std::map<std::string, std::pair<scoped_refptr<const extensions::Extension>, std::string>> installations_;
  Events events_;
  base::CallbackListSubscription storage_observer_;
};

void CefDevToolsController::EmitZacro(const std::string& method, const base::DictValue& params) {
  if (auto json = base::WriteJson(base::DictValue().Set("method", method).Set("params", params.Clone()))) {
    DispatchProtocolMessage(nullptr, base::as_bytes(base::span(*json)));
  }
}

bool CefDevToolsController::DispatchZacroExtensions(int id, const std::string& method,
                                                   const base::DictValue* params) {
  if (!method.starts_with("Zacro.")) return false;
  if (method != "Zacro.observeExtensions" && method != "Zacro.getExtensionStorage" &&
      method != "Zacro.applyExtensionStorage") return false;
  auto* context = inspected_contents_->GetBrowserContext();
  auto* state = ZacroExtensionContext::Get(context);
  if (method == "Zacro.observeExtensions") {
    zacro_extension_subscription_ = {};
    bool enabled = params && params->FindBool("enabled").value_or(false);
    if (enabled) {
      zacro_extension_subscription_ = state->Observe(base::BindRepeating(
          &CefDevToolsController::EmitZacro, weak_ptr_factory_.GetWeakPtr()));
    }
    if (enabled) ZacroObserveProfileDownloads(context);
    ZacroSetTopologyObserved(context, enabled);
    ReplyZacro(id, {}); return true;
  }
  if (context->IsOffTheRecord()) { ReplyZacro(id, {}, "Private extension storage cannot be synchronized."); return true; }
  const auto* extension_id = params ? params->FindString("id") : nullptr;
  auto* registry = extensions::ExtensionRegistry::Get(context);
  scoped_refptr<const extensions::Extension> extension = extension_id && registry ? registry->GetInstalledExtension(*extension_id) : nullptr;
  auto* frontend = extensions::StorageFrontend::Get(context);
  if (!extension || !frontend || !extension->permissions_data()->HasAPIPermission("storage")) {
    ReplyZacro(id, {}, "This installed extension does not have storage permission."); return true;
  }
  const std::string installation = state->InstallationID(*extension);
  if (method == "Zacro.getExtensionStorage") {
    frontend->GetValues(extension, extensions::StorageAreaNamespace::kSync, std::nullopt,
        base::BindOnce([](base::WeakPtr<CefDevToolsController> self, int id,
            scoped_refptr<const extensions::Extension> extension, std::string installation,
            extensions::StorageFrontend::GetResult result) {
          if (!self) return;
          auto* state = ZacroExtensionContext::Get(self->inspected_contents_->GetBrowserContext());
          if (!state->IsCurrent(*extension, installation)) { self->ReplyZacro(id, {}, "The extension installation changed."); return; }
          if (!result.status.success || !result.data) { self->ReplyZacro(id, {}, result.status.error.value_or("Extension storage could not be read.")); return; }
          self->ReplyZacro(id, base::DictValue().Set("installationID", installation)
              .Set("incarnationID", state->IncarnationID(*extension)).Set("values", std::move(*result.data)));
        }, weak_ptr_factory_.GetWeakPtr(), id, extension, installation));
    return true;
  }
  const auto* expected = params->FindString("installationID");
  const auto* changes = params->FindDict("changes");
  const auto* origin = params->FindString("origin");
  if (!expected || *expected != installation || !changes || changes->size() > 1024 ||
      !origin || !origin->starts_with("zacro.remote:") || origin->size() > 512) {
    ReplyZacro(id, {}, "The remote storage operation is stale or invalid."); return true;
  }
  const auto* expected_values = params->FindDict("expectedValues");
  if (!expected_values) { ReplyZacro(id, {}, "The native storage baseline is required."); return true; }
  frontend->ApplyNativeChanges(extension, extensions::StorageAreaNamespace::kSync,
      expected_values->Clone(), changes->Clone(),
      base::BindOnce([](base::WeakPtr<CefDevToolsController> self, int id,
          scoped_refptr<const extensions::Extension> extension, std::string installation,
          extensions::StorageFrontend::ResultStatus status) {
        if (!self) return;
        if (!ZacroExtensionContext::Get(self->inspected_contents_->GetBrowserContext())->IsCurrent(*extension, installation)) {
          self->ReplyZacro(id, {}, "The extension installation changed."); return;
        }
        self->ReplyZacro(id, base::DictValue().Set("applied", status.success),
            status.success ? "" : status.error.value_or("Extension storage could not be written."));
      }, weak_ptr_factory_.GetWeakPtr(), id, extension, installation), *origin);
  return true;
}
