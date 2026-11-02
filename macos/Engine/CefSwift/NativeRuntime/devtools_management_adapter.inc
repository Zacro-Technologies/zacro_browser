// Native transport for genuine Chromium management consent. The hidden
// chrome://extensions document supplies API authority, never a dialog parent.
#include "chrome/browser/extensions/native_management_operation.h"
#include "chrome/browser/extensions/webstore_install_with_prompt.h"
#include "extensions/browser/install_approval.h"
#include "base/uuid.h"
#include <deque>

namespace {
class ZacroScopedWebstoreInstaller final : public extensions::WebstoreInstallWithPrompt {
 public:
  ZacroScopedWebstoreInstaller(const std::string& id, Profile* profile,
      scoped_refptr<extensions::NativeManagementOperation> operation)
      : extensions::WebstoreInstallWithPrompt(id, profile, operation->parent(),
          base::BindOnce([](scoped_refptr<extensions::NativeManagementOperation> owner,
              bool success, const std::string& error, extensions::webstore_install::Result) {
            owner->Complete(success, error);
          }, operation)), operation_(std::move(operation)) {}
  void Begin() {
    // BeginInstall owns its own reference until one terminal completion.
    // Only a weak installer reference is retained by the operation's cancel
    // closure, avoiding an operation/installer cycle.
    operation_->SetCancellation(base::BindOnce(
        &ZacroScopedWebstoreInstaller::CancelNative, weak_.GetWeakPtr()));
    if (operation_->IsValid()) { began_ = true; BeginInstall(); }
  }
 private:
  ~ZacroScopedWebstoreInstaller() override = default;
  bool CheckRequestorAlive() const override {
    return operation_->IsValid() && WebstoreInstallWithPrompt::CheckRequestorAlive();
  }
  std::unique_ptr<ExtensionInstallPrompt> CreateInstallUI(
      std::unique_ptr<extensions::InstallPromptData> prompt) override {
    auto result = WebstoreInstallWithPrompt::CreateInstallUI(std::move(prompt));
    operation_->ConfigurePrompt(result.get());
    return result;
  }
  std::unique_ptr<extensions::InstallApproval> CreateApproval() const override {
    auto approval = WebstoreInstallWithPrompt::CreateApproval();
    approval->native_install_authorized = operation_->Validator();
    return approval;
  }
  void OnInstallPromptDone(ExtensionInstallPrompt::DoneCallbackPayload payload) override {
    auto keep_alive = base::WrapRefCounted(this);
    // Once the original prompt is gone, cancellation must abort the remaining
    // fetch/install flow; the approval validator still gates final CRX grants.
    operation_->SetCancellation(base::BindOnce(
        &ZacroScopedWebstoreInstaller::CancelNative, weak_.GetWeakPtr()));
    if (!operation_->IsValid()) return;
    WebstoreInstallWithPrompt::OnInstallPromptDone(std::move(payload));
  }
  void CancelNative() {
    auto keep_alive = base::WrapRefCounted(this);
    if (began_) AbortInstall();
  }
  bool began_ = false;
  const scoped_refptr<extensions::NativeManagementOperation> operation_;
  base::WeakPtrFactory<ZacroScopedWebstoreInstaller> weak_{this};
};

class ZacroManagementContext final : public base::SupportsUserData::Data {
 public:
  static constexpr char kKey[] = "zacro.native.extension-management";
  using Reply = base::OnceCallback<void(base::DictValue, std::string)>;
  static ZacroManagementContext* Get(content::BrowserContext* context) {
    auto* found = static_cast<ZacroManagementContext*>(context->GetUserData(kKey));
    if (found) return found;
    auto value = std::make_unique<ZacroManagementContext>();
    auto* result = value.get(); context->SetUserData(kKey, std::move(value)); return result;
  }
  ~ZacroManagementContext() override {
    weak_.InvalidateWeakPtrs();
    auto pending = std::move(pending_);
    for (auto& [id, operation] : pending) operation->Cancel();
  }
  static bool ValidID(const std::string& id) {
    const auto parsed = base::Uuid::ParseLowercase(id);
    return parsed.is_valid() && parsed.AsLowercaseString() == id;
  }
  void Cancel(const std::string& id) {
    if (auto found = pending_.find(id); found != pending_.end()) {
      auto operation = found->second; operation->Cancel();
    } else Remember(id);
  }
  void Start(content::WebContents* contents, const base::DictValue& params, Reply reply) {
    const auto* id = params.FindString("operationID");
    const auto* action = params.FindString("action");
    const auto* extension = params.FindString("id");
    const auto window = params.FindInt("windowNumber");
    const auto logical_window = params.FindInt("windowID");
    if (!id || !ValidID(*id) || !action || !extension || extension->size() != 32 ||
        !std::ranges::all_of(*extension, [](char c) { return c >= 'a' && c <= 'p'; }) ||
        (window && (*window <= 0 || !logical_window || *logical_window <= 0)) ||
        (!window && logical_window)) {
      std::move(reply).Run({}, "The native extension operation is invalid."); return;
    }
    if (completed_.contains(*id)) {
      std::move(reply).Run(base::DictValue().Set("cancelled", true), {}); return;
    }
    if (pending_.contains(*id) || pending_.size() >= 64) {
      std::move(reply).Run({}, "An extension operation with this identity is already pending."); return;
    }
    auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
    const auto* target = extensions::ExtensionRegistry::Get(profile)->GetExtensionById(
        *extension, extensions::ExtensionRegistry::EVERYTHING);
    if (!window && extensions::NativeManagementOperation::RequiresReview(profile, target, *action)) {
      Remember(*id);
      std::move(reply).Run(base::DictValue().Set("reviewRequired", true)
          .Set("message", "Review this extension change in its browser window."), {}); return;
    }
    std::string error;
    auto operation = extensions::NativeManagementOperation::Create(
        contents, *extension, *action, window.value_or(0), logical_window.value_or(0), error);
    if (!operation) { Remember(*id); std::move(reply).Run({}, std::move(error)); return; }
    // Install the same native dispatcher used by the logical browser before
    // invoking an original management function on its trusted WebUI document.
    ZacroBrowserContext::InstallHooks();
    pending_[*id] = operation;
    operation->SetCompletion(base::BindOnce(
        [](base::WeakPtr<ZacroManagementContext> self, std::string id, Reply reply,
            bool success, bool cancelled, std::string error) {
          if (self) { self->pending_.erase(id); self->Remember(id); }
          auto result = base::DictValue().Set("completed", success).Set("cancelled", cancelled);
          std::move(reply).Run(std::move(result), success || cancelled ? "" : std::move(error));
        }, weak_.GetWeakPtr(), *id, std::move(reply)));
    if (*action == "install") {
      auto installer = base::MakeRefCounted<ZacroScopedWebstoreInstaller>(*extension, profile, operation);
      installer->Begin();
    } else if (*action == "uninstall") {
      operation->Dispatch("management.uninstall", base::ListValue().Append(*extension)
          .Append(base::DictValue().Set("showConfirmDialog", true)));
    } else {
      operation->Dispatch("management.setEnabled", base::ListValue().Append(*extension).Append(*action == "enable"));
    }
  }
 private:
  void Remember(const std::string& id) {
    if (!completed_.insert(id).second) return;
    order_.push_back(id);
    while (order_.size() > 256) { completed_.erase(order_.front()); order_.pop_front(); }
  }
  std::map<std::string, scoped_refptr<extensions::NativeManagementOperation>> pending_;
  std::set<std::string> completed_;
  std::deque<std::string> order_;
  base::WeakPtrFactory<ZacroManagementContext> weak_{this};
};
}  // namespace

bool CefDevToolsController::DispatchZacroManagement(int id, const std::string& method,
                                                   const base::DictValue* params) {
  if (method != "Zacro.extensionManagement" && method != "Zacro.cancelExtensionManagement") return false;
  if (!params || !inspected_contents_ || inspected_contents_->GetBrowserContext()->IsOffTheRecord() ||
      inspected_contents_->GetLastCommittedURL() != GURL("chrome://extensions/")) {
    ReplyZacro(id, {}, "The trusted extension management document is unavailable."); return true;
  }
  auto* state = ZacroManagementContext::Get(inspected_contents_->GetBrowserContext());
  if (method == "Zacro.cancelExtensionManagement") {
    const auto* operation = params->FindString("operationID");
    if (!operation || !ZacroManagementContext::ValidID(*operation)) {
      ReplyZacro(id, {}, "The extension operation identity is invalid."); return true;
    }
    state->Cancel(*operation);
    ReplyZacro(id, base::DictValue().Set("cancelled", true)); return true;
  }
  state->Start(inspected_contents_, *params, base::BindOnce(
      [](base::WeakPtr<CefDevToolsController> self, int id, base::DictValue result, std::string error) {
        if (self) self->ReplyZacro(id, std::move(result), error);
      }, weak_ptr_factory_.GetWeakPtr(), id));
  return true;
}
