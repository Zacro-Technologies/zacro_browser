// Zacro's browser-process adapter, included by CefDevToolsController.
// This channel is reachable only through CEF's native API. It is never exposed
// as a page binding, socket, scheme handler, or extension API.
#include <algorithm>
#include <cmath>
#include "base/base64.h"
#include "base/functional/bind.h"
#include "base/pickle.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/timer/timer.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/extensions/browser_window_util.h"
#include "chrome/browser/extensions/api/side_panel/side_panel_service.h"
#include "chrome/browser/extensions/webstore_install_with_prompt.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/extensions/extensions_container.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/browser/ui/views/extensions/native_extension_popup_anchor.h"
#include "components/os_crypt/async/browser/os_crypt_async.h"
#include "components/os_crypt/async/common/encryptor.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/visibility.h"
#include "crypto/aead.h"
#include "crypto/random.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/background_info.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/geometry/rect_f.h"
void ZacroRefreshSidePanelPresentation(content::WebContents* contents);
#include "cef/libcef/browser/devtools/zacro_extensions_adapter.inc"
#include "cef/libcef/browser/devtools/zacro_topology_adapter.inc"
#include "cef/libcef/browser/devtools/zacro_bookmarks_adapter.inc"
#include "cef/libcef/browser/devtools/zacro_downloads_adapter.inc"

namespace {
constexpr char kZacroBrowserSession[] = "zacro.native.browser.v1";
constexpr size_t kZacroMaximumHistoryBytes = 6 * 1024 * 1024;

std::string ZacroHistoryBinding(content::WebContents* contents) {
  return "zacro.navigation.v2:" +
      contents->GetBrowserContext()->GetPath().AsUTF8Unsafe();
}

bool ZacroRestorableURL(const GURL& url, content::BrowserContext* context) {
  if (!url.is_valid() || url.has_username() || url.has_password()) return false;
  if (url.SchemeIsHTTPOrHTTPS() || url == GURL("about:blank")) return true;
  if (url.SchemeIs("chrome-extension")) {
    auto* registry = extensions::ExtensionRegistry::Get(context);
    return registry && registry->enabled_extensions().Contains(std::string(url.host()));
  }
  return false;
}

bool ZacroHasExtensionUI(content::WebContents* contents) {
  auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*contents);
  if (!browser) return false;
  if (auto* panel = SidePanelUI::From(browser); panel && panel->IsSidePanelShowing()) return true;
  auto* container = ExtensionsContainer::From(*browser);
  auto* registry = extensions::ExtensionRegistry::Get(contents->GetBrowserContext());
  if (container && registry) for (const auto& extension : registry->enabled_extensions()) {
    auto* action = container->GetActionForId(extension->id());
    if (action && action->IsShowingPopup()) return true;
  }
  return false;
}

bool ZacroHasSidePanel(content::WebContents* contents) {
  auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*contents);
  auto* panel = browser ? SidePanelUI::From(browser) : nullptr;
  return panel && panel->IsSidePanelShowing();
}

bool ZacroHistoryApproval(const GURL& url, content::BrowserContext* context,
    std::string& extension, std::string& incarnation, content::WebContents* contents = nullptr) {
  if (ZacroRestorableURL(url, context)) return true;
  auto& approvals = (contents ? ZacroNavigationApprovals::ForDocument(contents) : ZacroNavigationApprovals::Get(context))->destinations;
  const auto found = approvals.find(url.spec());
  if (found == approvals.end()) return false;
  extension = found->second.first; incarnation = found->second.second;
  std::string error;
  return ZacroValidateNavigation(context, extension, incarnation, url.spec(), error);
}
}

void ZacroRefreshSidePanelPresentation(content::WebContents* contents) {
  auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*contents);
  auto* panel = browser ? SidePanelUI::From(browser) : nullptr;
  const bool showing = panel && panel->IsSidePanelShowing();
  // Keep the blank renderer suppressed through the close event. Swift will
  // hide the child window on its next layout turn; restoring it here would
  // expose a white frame between native close and that layout.
  if (panel) panel->SetNativeEmptyContentHidden(contents->GetLastCommittedURL() == GURL("about:blank"));
  ZacroExtensionContext::Get(contents->GetBrowserContext())->NotifyNative("Zacro.extensionPanelPresentation",
      base::DictValue().Set("tabID", sessions::SessionTabHelper::IdForTab(contents).id()).Set("visible", showing));
}

class ZacroDataRemoval : public content::BrowsingDataRemover::Observer {
 public:
  ZacroDataRemoval(content::BrowsingDataRemover* remover,
                   base::OnceCallback<void(uint64_t)> completion)
      : remover_(remover), completion_(std::move(completion)) {
    remover_->AddObserver(this);
  }
  ~ZacroDataRemoval() override { remover_->RemoveObserver(this); }
  void Start(uint64_t mask) {
    remover_->RemoveAndReply(base::Time(), base::Time::Max(), mask,
        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB |
        content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB, this);
  }
  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    std::move(completion_).Run(failed_data_types);
  }
 private:
  raw_ptr<content::BrowsingDataRemover> remover_;
  base::OnceCallback<void(uint64_t)> completion_;
};

class ZacroDocumentObserver : public content::WebContentsObserver {
 public:
  ZacroDocumentObserver(content::WebContents* contents,
      base::RepeatingCallback<void(bool)> audio, base::RepeatingCallback<void(bool)> panel)
      : content::WebContentsObserver(contents), audio_(std::move(audio)), panel_(std::move(panel)) {
    subscription_ = ZacroExtensionContext::Get(contents->GetBrowserContext())->Observe(base::BindRepeating(
        [](ZacroDocumentObserver* observer, const std::string& method, const base::DictValue& params) {
          if (method == "Zacro.extensionPanelPresentation" && observer->web_contents() &&
              params.FindInt("tabID") == sessions::SessionTabHelper::IdForTab(observer->web_contents()).id()) {
            observer->panel_.Run(params.FindBool("visible").value_or(false));
          }
        }, base::Unretained(this)));
  }
  void OnAudioStateChanged(bool audible) override { audio_.Run(audible); }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() && handle->HasCommitted()) ZacroRefreshSidePanelPresentation(web_contents());
  }
 private:
  base::RepeatingCallback<void(bool)> audio_;
  base::RepeatingCallback<void(bool)> panel_;
  base::CallbackListSubscription subscription_;
};

class ZacroDiscardOperation : public content::WebContentsObserver {
 public:
  ZacroDiscardOperation(content::WebContents* contents,
      base::OnceCallback<void(int, const std::string&)> completion)
      : content::WebContentsObserver(contents), completion_(std::move(completion)) {}
  void Start() {
    timer_.Start(FROM_HERE, base::Seconds(15), base::BindOnce(
        &ZacroDiscardOperation::TimedOut, base::Unretained(this)));
    web_contents()->GetController().LoadURL(GURL("about:blank"), content::Referrer(),
        ui::PAGE_TRANSITION_AUTO_TOPLEVEL, std::string());
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->IsInPrimaryMainFrame() || !navigation->HasCommitted()) return;
    if (navigation->GetURL() != GURL("about:blank") || navigation->IsErrorPage()) {
      Finish(0, "The document changed while sleeping.");
    } else { committed_blank_ = true; }
  }
  void DidStopLoading() override {
    if (!committed_blank_ || !completion_) return;
    auto* contents = web_contents();
    auto& controller = contents->GetController();
    if (contents->GetLastCommittedURL() != GURL("about:blank") ||
        contents->IsCurrentlyAudible() || contents->IsBeingCaptured() ||
        !controller.CanPruneAllButLastCommitted()) {
      Finish(0, "The document could not be discarded safely."); return;
    }
    controller.PruneAllButLastCommitted();
    Finish(controller.GetLastCommittedEntry()->GetUniqueID(), {});
  }
  void WebContentsDestroyed() override { Finish(0, "The document closed while sleeping."); }
 private:
  void TimedOut() {
    // Stop may synchronously invoke observer callbacks. Disable observation
    // first so they cannot delete this operation underneath the timeout.
    auto* contents = web_contents();
    Observe(nullptr);
    timer_.Stop();
    auto completion = std::move(completion_);
    if (contents) contents->Stop();
    // Stop can destroy the owning controller. Do not touch this afterward.
    if (completion) std::move(completion).Run(0, "The document did not finish sleeping in time.");
  }
  void Finish(int entry_id, const std::string& error) {
    timer_.Stop();
    if (completion_) std::move(completion_).Run(entry_id, error);
  }
  base::OneShotTimer timer_;
  bool committed_blank_ = false;
  base::OnceCallback<void(int, const std::string&)> completion_;
};

void CefDevToolsController::ReplyZacro(int id, base::DictValue result,
                                      const std::string& error) {
  base::DictValue response;
  response.Set("id", id);
  if (error.empty()) response.Set("result", std::move(result));
  else response.Set("error", base::DictValue().Set("code", -32000).Set("message", error));
  if (auto json = base::WriteJson(response)) {
    DispatchProtocolMessage(nullptr, base::as_bytes(base::span(*json)));
  }
}

bool CefDevToolsController::DispatchZacro(const std::string_view& message) {
  auto request = base::JSONReader::ReadDict(message, base::JSON_PARSE_RFC);
  if (!request) return false;
  const auto* method = request->FindString("method");
  const auto id = request->FindInt("id");
  if (!method || !id) return false;
  if (*method == "Zacro.observeDocument") {
    const auto* params = request->FindDict("params");
    zacro_document_observer_.reset();
    if (params && params->FindBool("enabled").value_or(false)) {
      zacro_document_observer_ = std::make_unique<ZacroDocumentObserver>(inspected_contents_, base::BindRepeating(
          [](base::WeakPtr<CefDevToolsController> self, bool audible) {
            if (self) self->EmitZacro("Zacro.documentAudioChanged", base::DictValue().Set("audible", audible));
          }, weak_ptr_factory_.GetWeakPtr()), base::BindRepeating(
          [](base::WeakPtr<CefDevToolsController> self, bool visible) {
            if (self) self->EmitZacro("Zacro.documentSidePanelChanged", base::DictValue().Set("visible", visible));
          }, weak_ptr_factory_.GetWeakPtr()));
    }
    ReplyZacro(*id, base::DictValue().Set("audible", inspected_contents_->IsCurrentlyAudible())
        .Set("sidePanelVisible", ZacroHasSidePanel(inspected_contents_))); return true;
  }
  if (DispatchZacroTopology(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroExtensions(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroBookmarks(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroDownloads(*id, *method, request->FindDict("params"))) return true;
  if (*method == "Zacro.getExtensionOptions") {
    const auto* params = request->FindDict("params");
    const auto* extension_id = params ? params->FindString("id") : nullptr;
    auto* context = inspected_contents_->GetBrowserContext();
    auto* registry = extensions::ExtensionRegistry::Get(context);
    const auto* extension = extension_id && registry ? registry->enabled_extensions().GetByID(*extension_id) : nullptr;
    if (!extension || !extensions::OptionsPageInfo::HasOptionsPage(extension)) {
      ReplyZacro(*id, {}, "This enabled extension has no options page."); return true;
    }
    const auto url = extensions::OptionsPageInfo::GetOptionsPage(extension);
    const auto incarnation = ZacroExtensionContext::Get(context)->IncarnationID(*extension);
    std::string error;
    if (!ZacroValidateNavigation(context, extension->id(), incarnation, url.spec(), error)) {
      ReplyZacro(*id, {}, error); return true;
    }
    ReplyZacro(*id, base::DictValue().Set("extensionID", extension->id()).Set("incarnationID", incarnation)
        .Set("url", url.spec()).Set("name", extension->name())
        .Set("openInTab", extensions::OptionsPageInfo::ShouldOpenInTab(extension)));
    return true;
  }
  const auto* session = request->FindString("sessionId");
  if (session && (*session == kZacroBrowserSession || zacro_browser_sessions_.contains(*session))) {
    if (!zacro_browser_agent_) {
      ReplyZacro(*id, {}, "The native browser session has closed."); return true;
    }
    if (*session == kZacroBrowserSession) request->Remove("sessionId");
    if (auto json = base::WriteJson(*request)) {
      zacro_browser_agent_->DispatchProtocolMessage(this, base::as_bytes(base::span(*json)));
    }
    return true;
  }
  if (*method == "Target.attachToBrowserTarget") {
    if (!zacro_browser_agent_) {
      zacro_browser_agent_ = content::DevToolsAgentHost::CreateForBrowser(
          nullptr, content::DevToolsAgentHost::CreateServerSocketCallback());
      if (!zacro_browser_agent_ || !zacro_browser_agent_->AttachClient(this)) {
        zacro_browser_agent_ = nullptr;
        ReplyZacro(*id, {}, "The native browser protocol session could not attach.");
        return true;
      }
    }
    ReplyZacro(*id, base::DictValue().Set("sessionId", kZacroBrowserSession));
    return true;
  }
  if (*method == "Zacro.getCapabilities") {
    ReplyZacro(*id, base::DictValue().Set("version", 1).Set("browserProtocol", true)
        .Set("documentState", true).Set("browsingData", true).Set("navigationState", true)
        .Set("encryptedNavigation", true).Set("retainedDiscard", true)
        .Set("extensionActions", true).Set("legacyNavigation", true).Set("extensionStorage", true).Set("extensionBrowser", true)
        .Set("volatileDiscard", true).Set("bookmarks", true).Set("historyRemoval", true).Set("downloads", true));
    return true;
  }
  if (*method == "Zacro.extensionWorkerTarget") {
    const auto* params = request->FindDict("params");
    const auto* identifier = params ? params->FindString("id") : nullptr;
    auto* context = inspected_contents_->GetBrowserContext();
    auto* registry = extensions::ExtensionRegistry::Get(context);
    const auto* extension = identifier && registry ? registry->enabled_extensions().GetByID(*identifier) : nullptr;
    if (!extension || context->IsOffTheRecord()) {
      ReplyZacro(*id, {}, "The extension is unavailable in this profile."); return true;
    }
    const auto script = extensions::BackgroundInfo::GetBackgroundServiceWorkerScriptURL(extension);
    if (script.is_empty()) { ReplyZacro(*id, {}, "This extension does not have a service worker."); return true; }
    std::string target;
    for (const auto& host : content::DevToolsAgentHost::GetOrCreateAll()) {
      if (host->GetBrowserContext() != context || host->GetType() != content::DevToolsAgentHost::kTypeServiceWorker ||
          host->GetURL() != script) continue;
      if (!target.empty()) { ReplyZacro(*id, {}, "The extension worker is changing; retry after it settles."); return true; }
      target = host->GetId();
    }
    auto result = base::DictValue().Set("installationID", ZacroExtensionContext::Get(context)->InstallationID(*extension));
    if (!target.empty()) result.Set("targetID", target);
    ReplyZacro(*id, std::move(result)); return true;
  }
  if (*method == "Zacro.loadUnpackedExtension") {
    const auto* params = request->FindDict("params");
    const auto* path = params ? params->FindString("path") : nullptr;
    auto* context = inspected_contents_->GetBrowserContext();
    const auto directory = path ? base::FilePath::FromUTF8Unsafe(*path) : base::FilePath();
    if (context->IsOffTheRecord() || !path || path->empty() || path->size() > 4096 ||
        !directory.IsAbsolute() || directory.ReferencesParent()) {
      ReplyZacro(*id, {}, "Choose an absolute extension directory in a persistent profile."); return true;
    }
    // Native caller only. Chromium still applies manifest validation, managed
    // install policy and permissions. Never use CDP's default-profile installer.
    auto installer = extensions::UnpackedInstaller::Create(context);
    installer->set_be_noisy_on_failure(false);
    installer->set_completion_callback(base::BindOnce(
        [](base::WeakPtr<CefDevToolsController> self, int id, const extensions::Extension* extension,
           const base::FilePath&, const std::u16string& error) {
          if (!self) return;
          self->ReplyZacro(id, extension ? base::DictValue().Set("id", extension->id()) : base::DictValue(),
              extension && error.empty() ? "" : (error.empty() ? "Chromium rejected the unpacked extension." : base::UTF16ToUTF8(error)));
        }, weak_ptr_factory_.GetWeakPtr(), *id));
    installer->Load(directory); return true;
  }
  if (*method == "Zacro.installWebStoreExtension") {
    const auto* params = request->FindDict("params");
    const auto* extension_id = params ? params->FindString("id") : nullptr;
    auto* context = inspected_contents_->GetBrowserContext();
    if (context->IsOffTheRecord() || !extension_id || extension_id->size() != 32 ||
        !std::ranges::all_of(*extension_id, [](char ch) { return ch >= 'a' && ch <= 'p'; })) {
      ReplyZacro(*id, {}, "Choose a valid Web Store extension in a persistent profile."); return true;
    }
    // This native installer verifies the store response, CRX signature, item
    // identity and permissions. Its dialog is centered rather than attached to
    // the deliberately hidden management document's native child window.
    auto installer = base::MakeRefCounted<extensions::WebstoreInstallWithPrompt>(
        *extension_id, Profile::FromBrowserContext(context), gfx::NativeWindow(),
        base::BindOnce([](base::WeakPtr<CefDevToolsController> self, int id,
            bool success, const std::string& error, extensions::webstore_install::Result) {
          if (self) self->ReplyZacro(id, base::DictValue().Set("installed", success),
              success ? "" : (error.empty() ? "The Web Store installation was cancelled." : error));
        }, weak_ptr_factory_.GetWeakPtr(), *id));
    installer->BeginInstall();
    return true;
  }
  if (*method == "Zacro.getExtensionShortcuts") {
    auto* context = inspected_contents_->GetBrowserContext();
    auto* registry = extensions::ExtensionRegistry::Get(context);
    auto* commands = extensions::CommandService::Get(context);
    base::ListValue shortcuts;
    if (registry && commands) for (const auto& extension : registry->enabled_extensions()) {
      const auto incarnation = ZacroExtensionContext::Get(context)->IncarnationID(*extension);
      if (incarnation.empty()) continue;
      auto append = [&](const ui::Command& command, bool action) {
        const auto& accelerator = command.accelerator();
        if (accelerator.key_code() == ui::VKEY_UNKNOWN || command.global()) return;
        shortcuts.Append(base::DictValue().Set("extensionID", extension->id()).Set("incarnationID", incarnation)
            .Set("name", command.command_name()).Set("keybinding", ui::Command::AcceleratorToString(accelerator))
            .Set("keyCode", static_cast<int>(accelerator.key_code())).Set("shift", accelerator.IsShiftDown())
            .Set("control", accelerator.IsCtrlDown()).Set("alt", accelerator.IsAltDown())
            .Set("command", accelerator.IsCmdDown()).Set("isAction", action));
      };
      ui::CommandMap named;
      commands->GetNamedCommands(extension->id(), extensions::CommandService::ACTIVE,
          extensions::CommandService::REGULAR, &named);
      if (extensions::EventRouter::Get(context)->ExtensionHasEventListener(extension->id(), "commands.onCommand"))
        for (const auto& [name, command] : named) append(command, false);
      const auto* info = extensions::ActionInfo::GetExtensionActionInfo(extension.get());
      extensions::Command action;
      if (info && commands->GetExtensionActionCommand(extension->id(), info->type,
          extensions::CommandService::ACTIVE, &action, nullptr)) append(action, true);
    }
    ReplyZacro(*id, base::DictValue().Set("shortcuts", std::move(shortcuts))); return true;
  }
  if (*method == "Zacro.performExtensionAction" || *method == "Zacro.getExtensionAction" ||
      *method == "Zacro.openExtensionSidePanel" ||
      *method == "Zacro.performExtensionShortcut") {
    const auto* params = request->FindDict("params");
    const auto* extension_id = params ? params->FindString("id") : nullptr;
    auto* context = inspected_contents_->GetBrowserContext();
    auto* registry = extensions::ExtensionRegistry::Get(context);
    const auto* extension = extension_id && registry ? registry->enabled_extensions().GetByID(*extension_id) : nullptr;
    if (*method == "Zacro.getExtensionAction" && extension_id && registry)
      extension = registry->GetInstalledExtension(*extension_id);
    if (*method == "Zacro.performExtensionShortcut") {
      const auto* name = params ? params->FindString("name") : nullptr;
      const auto* binding = params ? params->FindString("keybinding") : nullptr;
      const auto* incarnation = params ? params->FindString("incarnationID") : nullptr;
      auto* commands = extensions::CommandService::Get(context);
      auto* global = extensions::ExtensionCommandsGlobalRegistry::Get(context);
      auto* listener = ui::GlobalAcceleratorListener::GetInstance();
      ZacroBrowserContext::Get(context)->ReconcileKeyboardFocus();
      if (!extension || !commands || !name || !binding || !incarnation ||
          *incarnation != ZacroExtensionContext::Get(context)->IncarnationID(*extension) ||
          !extensions::ExtensionTabUtil::IsVisibleToNativeBrowserModel(inspected_contents_) ||
          !ZacroBrowserContext::Get(context)->IsCommandTarget(inspected_contents_) ||
          !global || global->shortcut_handling_suspended() ||
          (listener && listener->IsShortcutHandlingSuspended())) {
        ReplyZacro(*id, base::DictValue().Set("performed", false)); return true;
      }
      ui::CommandMap named;
      commands->GetNamedCommands(*extension_id, extensions::CommandService::ACTIVE,
          extensions::CommandService::REGULAR, &named);
      auto found = named.find(*name);
      if (found != named.end()) {
        const auto& accelerator = found->second.accelerator();
        auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*inspected_contents_);
        auto* keys = browser ? ExtensionKeybindingRegistryViews::From(browser) : nullptr;
        if (*binding != ui::Command::AcceleratorToString(accelerator) || !keys ||
            keys->shortcut_handling_suspended() || !keys->IsAcceleratorRegistered(accelerator) ||
            !keys->AcceleratorPressed(accelerator)) {
          ReplyZacro(*id, base::DictValue().Set("performed", false)); return true;
        }
        ReplyZacro(*id, base::DictValue().Set("performed", true)); return true;
      }
      extensions::Command action_command;
      const auto* info = extensions::ActionInfo::GetExtensionActionInfo(extension);
      if (!info || !commands->GetExtensionActionCommand(*extension_id, info->type,
          extensions::CommandService::ACTIVE, &action_command, nullptr) || action_command.global() ||
          action_command.command_name() != *name ||
          ui::Command::AcceleratorToString(action_command.accelerator()) != *binding) {
        ReplyZacro(*id, base::DictValue().Set("performed", false)); return true;
      }
      // Action commands use the actual action host below, retaining activeTab
      // grants and a native popup anchored to the owning Swift window.
    }
    auto* manager = extensions::ExtensionActionManager::Get(context);
    auto* action = extension && manager ? manager->GetExtensionAction(*extension) : nullptr;
    const auto* info = extension ? extensions::ActionInfo::GetExtensionActionInfo(extension) : nullptr;
    const bool has_action = info && !info->synthesized;
    const int tab_id = sessions::SessionTabHelper::IdForTab(inspected_contents_).id();
    auto* panels = extensions::SidePanelService::Get(context);
    const bool logical_document = extensions::ExtensionTabUtil::IsVisibleToNativeBrowserModel(inspected_contents_);
    if (*method == "Zacro.getExtensionAction") {
      if (!extension) { ReplyZacro(*id, {}, "The extension is no longer installed."); return true; }
      auto color = [](SkColor value) { return base::ListValue().Append(static_cast<int>(SkColorGetR(value))).Append(static_cast<int>(SkColorGetG(value))).Append(static_cast<int>(SkColorGetB(value))).Append(static_cast<int>(SkColorGetA(value))); };
      auto options = panels ? panels->GetOptions(*extension, logical_document ? std::optional<int>(tab_id) : std::nullopt)
          : extensions::api::side_panel::PanelOptions();
      base::DictValue result;
      result.Set("title", has_action && action ? action->GetTitle(tab_id) : extension->name());
      result.Set("badgeText", has_action && action ? action->GetDisplayBadgeText(tab_id) : "");
      result.Set("badgeColor", color(has_action && action ? action->GetBadgeBackgroundColor(tab_id) : SK_ColorTRANSPARENT));
      result.Set("badgeForeground", color(has_action && action ? action->GetBadgeTextColor(tab_id) : SK_ColorTRANSPARENT));
      result.Set("hasAction", has_action);
      result.Set("hasSidePanel", options.enabled.value_or(false) && options.path.has_value());
      result.Set("enabled", has_action && action && action->GetIsVisible(tab_id));
      auto icon = has_action && action ? action->GetExplicitlySetIcon(tab_id) : gfx::Image();
      if (!icon.IsEmpty()) {
        auto png = icon.As1xPNGBytes();
        if (png && png->size() <= 512 * 1024) result.Set("iconPNG", base::Base64Encode(base::span(*png)));
      }
      ReplyZacro(*id, std::move(result)); return true;
    }
    if (*method == "Zacro.openExtensionSidePanel") {
      if (!extension || !panels || !logical_document || !ZacroBrowserContext::Get(context)->IsCommandTarget(inspected_contents_)) {
        ReplyZacro(*id, {}, "An enabled extension and the selected logical tab are required."); return true;
      }
      auto opened = panels->OpenSidePanelForTab(*extension, context, tab_id, std::nullopt, false);
      if (!opened.has_value()) { ReplyZacro(*id, {}, opened.error()); return true; }
      ZacroRefreshSidePanelPresentation(inspected_contents_);
      ReplyZacro(*id, base::DictValue().Set("opened", opened.value())); return true;
    }
    if (!has_action || !action || !action->GetIsVisible(tab_id)) {
      if (*method == "Zacro.performExtensionShortcut") ReplyZacro(*id, base::DictValue().Set("performed", false));
      else ReplyZacro(*id, {}, "This extension has no enabled toolbar action for the selected tab.");
      return true;
    }
    auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*inspected_contents_);
    auto* container = browser ? ExtensionsContainer::From(*browser) : nullptr;
    auto* model = container ? container->GetActionForId(*extension_id) : nullptr;
    if (!model) {
      if (*method == "Zacro.performExtensionShortcut") ReplyZacro(*id, base::DictValue().Set("performed", false));
      else ReplyZacro(*id, {}, "The native extension action container is unavailable.");
      return true;
    }
    if (const auto* anchor = params->FindDict("anchor")) {
      const auto number = anchor->FindInt("windowNumber");
      const auto x = anchor->FindDouble("x"), y = anchor->FindDouble("y");
      const auto width = anchor->FindDouble("width"), height = anchor->FindDouble("height");
      if (!extensions::ExtensionTabUtil::IsVisibleToNativeBrowserModel(inspected_contents_) ||
          !number || *number <= 0 || !x || !y || !width || !height ||
          !std::isfinite(*x) || !std::isfinite(*y) || !std::isfinite(*width) || !std::isfinite(*height) ||
          std::abs(*x) > 1000000 || std::abs(*y) > 1000000 || *width <= 0 || *height <= 0 ||
          *width > 4096 || *height > 4096 ||
          !NativeExtensionPopupAnchor::Prepare(inspected_contents_, *number, gfx::RectF(*x, *y, *width, *height))) {
        ReplyZacro(*id, {}, "The native extension popup anchor is unavailable."); return true;
      }
    }
    model->ExecuteUserAction(*method == "Zacro.performExtensionShortcut"
        ? ExtensionActionViewModel::InvocationSource::kCommand
        : ExtensionActionViewModel::InvocationSource::kCdp);
    NativeExtensionPopupAnchor::CancelPrepared(inspected_contents_);
    ReplyZacro(*id, base::DictValue().Set("performed", true)); return true;
  }
  if (*method == "Zacro.restoreNavigationEntries") {
    const auto* params = request->FindDict("params");
    const auto* items = params ? params->FindList("entries") : nullptr;
    const auto selected = params ? params->FindInt("selectedIndex") : std::nullopt;
    auto& controller = inspected_contents_->GetController();
    if (!items || items->empty() || items->size() > 500 || !selected || *selected < 0 ||
        static_cast<size_t>(*selected) >= items->size() || !controller.GetLastCommittedEntry()->IsInitialEntry() || controller.GetPendingEntry()) {
      ReplyZacro(*id, {}, "Legacy history can only restore a fresh initial document."); return true;
    }
    std::vector<sessions::SerializedNavigationEntry> serialized;
    for (const auto& value : *items) {
      const auto* item = value.GetIfDict();
      const auto* url = item ? item->FindString("url") : nullptr;
      const auto* title = item ? item->FindString("title") : nullptr;
      std::string extension, incarnation;
      if (!url || url->size() > 32768 || !title || title->size() > 8192 ||
          !ZacroHistoryApproval(GURL(*url), inspected_contents_->GetBrowserContext(), extension, incarnation)) {
        ReplyZacro(*id, {}, "Legacy navigation contains an invalid entry."); return true;
      }
      if (!extension.empty()) ZacroNavigationApprovals::ForDocument(inspected_contents_)->destinations[*url] = {extension, incarnation};
      sessions::SerializedNavigationEntry entry;
      entry.set_index(serialized.size()); entry.set_virtual_url(GURL(*url)); entry.set_title(base::UTF8ToUTF16(*title));
      serialized.push_back(std::move(entry));
    }
    auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(serialized, inspected_contents_->GetBrowserContext());
    controller.Restore(*selected, content::RestoreType::kRestored, &entries);
    controller.LoadIfNecessary();
    ReplyZacro(*id, base::DictValue().Set("restored", true)); return true;
  }
  if (*method == "Zacro.getDocumentState") {
    auto* context = inspected_contents_->GetBrowserContext();
    ReplyZacro(*id, base::DictValue()
        .Set("audible", inspected_contents_->IsCurrentlyAudible())
        .Set("capturing", inspected_contents_->IsBeingCaptured())
        .Set("beforeUnload", inspected_contents_->NeedToFireBeforeUnloadOrUnloadEvents())
        .Set("devToolsOpen", DevToolsWindow::GetInstanceForInspectedWebContents(inspected_contents_) != nullptr)
        .Set("profileDownloads", context->GetDownloadManager()->InProgressCount())
        .Set("extensionUI", ZacroHasExtensionUI(inspected_contents_))
        .Set("crashed", inspected_contents_->IsCrashed())
        .Set("loading", inspected_contents_->IsLoading()));
    return true;
  }
  if (*method == "Zacro.clearBrowsingData") {
    const auto* params = request->FindDict("params");
    const bool site = params && params->FindBool("siteData").value_or(false);
    const bool cache = params && params->FindBool("cache").value_or(false);
    const bool history = params && params->FindBool("history").value_or(false);
    uint64_t mask = 0;
    if (site) mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
    if (cache) mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
    if (history) mask |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;
    if (!mask || zacro_data_removals_.contains(*id)) {
      ReplyZacro(*id, {}, "Choose history, site data or cache to clear."); return true;
    }
    auto removal = std::make_unique<ZacroDataRemoval>(
        inspected_contents_->GetBrowserContext()->GetBrowsingDataRemover(),
        base::BindOnce(&CefDevToolsController::FinishZacroDataRemoval,
                       weak_ptr_factory_.GetWeakPtr(), *id));
    auto* operation = removal.get();
    zacro_data_removals_[*id] = std::move(removal);
    operation->Start(mask);
    return true;
  }
  if (*method == "Zacro.discardDocument") {
    if (zacro_discard_ || inspected_contents_->GetVisibility() != content::Visibility::HIDDEN || inspected_contents_->IsLoading() ||
        inspected_contents_->IsCurrentlyAudible() || inspected_contents_->IsBeingCaptured() ||
        inspected_contents_->NeedToFireBeforeUnloadOrUnloadEvents() ||
        DevToolsWindow::GetInstanceForInspectedWebContents(inspected_contents_) || ZacroHasExtensionUI(inspected_contents_) ||
        inspected_contents_->GetBrowserContext()->GetDownloadManager()->InProgressCount() > 0) {
      ReplyZacro(*id, {}, "The document is in use and cannot be put to sleep."); return true;
    }
    // Private documents keep their history only in this native controller's
    // memory. Nothing is exported, encrypted for storage, or written to disk.
    auto& controller = inspected_contents_->GetController();
    if (controller.GetEntryCount() < 1 || controller.GetEntryCount() > 500) {
      ReplyZacro(*id, {}, "The document history cannot be retained safely."); return true;
    }
    zacro_dormant_history_.clear();
    size_t retained_bytes = 0;
    for (int index = 0; index < controller.GetEntryCount(); ++index) {
      auto* entry = controller.GetEntryAtIndex(index);
      std::string extension, incarnation;
      if (!ZacroHistoryApproval(entry->GetVirtualURL(), inspected_contents_->GetBrowserContext(), extension, incarnation, inspected_contents_)) {
        zacro_dormant_history_.clear(); ReplyZacro(*id, {}, "The document history contains an unsupported address."); return true;
      }
      auto saved = sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(index, entry);
      retained_bytes += sizeof(saved) + saved.EstimateMemoryUsage();
      if (retained_bytes > kZacroMaximumHistoryBytes) {
        zacro_dormant_history_.clear();
        ReplyZacro(*id, {}, "The retained navigation state exceeds the supported size."); return true;
      }
      zacro_dormant_history_.push_back(std::move(saved));
    }
    zacro_dormant_selected_ = controller.GetLastCommittedEntryIndex();
    zacro_discard_ = std::make_unique<ZacroDiscardOperation>(inspected_contents_,
        base::BindOnce(&CefDevToolsController::FinishZacroDiscard,
                       weak_ptr_factory_.GetWeakPtr(), *id));
    zacro_discard_->Start();
    return true;
  }
  if (*method == "Zacro.restoreDiscardedDocument") {
    auto& controller = inspected_contents_->GetController();
    if (zacro_dormant_history_.empty() || zacro_discard_ || controller.GetEntryCount() != 1 ||
        !zacro_dormant_entry_ || controller.GetLastCommittedEntry()->GetUniqueID() != zacro_dormant_entry_ ||
        controller.GetPendingEntry() || inspected_contents_->IsLoading() ||
        inspected_contents_->GetLastCommittedURL() != GURL("about:blank")) {
      ReplyZacro(*id, {}, "This document does not have a retained sleeping session."); return true;
    }
    auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(
        zacro_dormant_history_, inspected_contents_->GetBrowserContext());
    controller.Restore(zacro_dormant_selected_ + 1, content::RestoreType::kRestored, &entries);
    CHECK(controller.RemoveEntryAtIndex(0));
    zacro_dormant_entry_ = 0; zacro_dormant_history_.clear();
    controller.LoadIfNecessary(); ReplyZacro(*id, base::DictValue().Set("restored", true)); return true;
  }
  if (*method == "Zacro.serializeNavigation") {
    if (inspected_contents_->GetBrowserContext()->IsOffTheRecord()) {
      ReplyZacro(*id, {}, "Private navigation state cannot be persisted."); return true;
    }
    auto& controller = inspected_contents_->GetController();
    const int count = controller.GetEntryCount();
    if (count < 1 || count > 500) {
      ReplyZacro(*id, {}, "Navigation history exceeds the supported entry count."); return true;
    }
    base::Pickle pickle;
    pickle.WriteInt(2);
    pickle.WriteInt(controller.GetLastCommittedEntryIndex());
    pickle.WriteInt(count);
    for (int index = 0; index < count; ++index) {
      std::string extension, incarnation;
      if (!ZacroHistoryApproval(controller.GetEntryAtIndex(index)->GetVirtualURL(),
                             inspected_contents_->GetBrowserContext(), extension, incarnation, inspected_contents_)) {
        ReplyZacro(*id, {}, "This navigation contains a non-restorable browser URL."); return true;
      }
      auto entry = sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(
          index, controller.GetEntryAtIndex(index));
      entry.WriteToPickle(512 * 1024, &pickle);
      pickle.WriteString(extension); pickle.WriteString(incarnation);
      if (pickle.size() > kZacroMaximumHistoryBytes - 4096) {
        ReplyZacro(*id, {}, "Navigation state exceeds the supported size."); return true;
      }
    }
    auto* crypt = g_browser_process ? g_browser_process->os_crypt_async() : nullptr;
    if (!crypt) { ReplyZacro(*id, {}, "Native navigation encryption is unavailable."); return true; }
    crypt->GetInstance(base::BindOnce(
        [](base::WeakPtr<CefDevToolsController> self, int id,
           std::string plain, std::string binding,
           scoped_refptr<os_crypt_async::Encryptor> encryptor) {
          if (!self) return;
          const auto key = crypto::RandBytesAsArray<32>();
          const auto nonce = crypto::RandBytesAsArray<12>();
          const auto wrapped_key = encryptor->EncryptString(
              std::string(base::as_string_view(key)));
          if (!wrapped_key) { self->ReplyZacro(id, {}, "Navigation encryption failed."); return; }
          const auto sealed = crypto::aead::Seal(crypto::aead::AES_256_GCM, key,
              base::as_bytes(base::span(plain)), nonce, base::as_bytes(base::span(binding)));
          if (sealed.empty()) { self->ReplyZacro(id, {}, "Navigation encryption failed."); return; }
          // OSCrypt wraps a fresh random AEAD key using the already configured
          // Chromium OS/keychain provider. AES-GCM authenticates the entire
          // history and profile binding even when the OS provider is legacy.
          base::Pickle envelope;
          envelope.WriteInt(2);
          envelope.WriteString(base::as_string_view(*wrapped_key));
          envelope.WriteString(base::as_string_view(nonce));
          envelope.WriteString(base::as_string_view(sealed));
          if (envelope.size() > kZacroMaximumHistoryBytes) {
            self->ReplyZacro(id, {}, "Encrypted navigation state exceeds the supported size."); return;
          }
          self->ReplyZacro(id, base::DictValue().Set("version", 2)
              .Set("state", base::Base64Encode(envelope.AsBytes())));
        }, weak_ptr_factory_.GetWeakPtr(), *id,
        std::string(pickle.AsStringView()), ZacroHistoryBinding(inspected_contents_)));
    return true;
  }
  if (*method == "Zacro.restoreNavigation") {
    const auto* params = request->FindDict("params");
    const auto* encoded = params ? params->FindString("state") : nullptr;
    std::string bytes;
    if (!encoded || encoded->size() > 8 * 1024 * 1024 ||
        !base::Base64Decode(*encoded, &bytes) || bytes.size() > kZacroMaximumHistoryBytes) {
      ReplyZacro(*id, {}, "Invalid navigation state."); return true;
    }
    auto envelope = base::Pickle::WithData(base::as_bytes(base::span(bytes)));
    base::PickleIterator envelope_iterator(envelope);
    int envelope_version = 0;
    std::string wrapped_key, nonce, ciphertext;
    if (!envelope_iterator.ReadInt(&envelope_version) || envelope_version != 2 ||
        !envelope_iterator.ReadString(&wrapped_key) || wrapped_key.size() > 1024 ||
        !envelope_iterator.ReadString(&nonce) || nonce.size() != 12 ||
        !envelope_iterator.ReadString(&ciphertext) || !envelope_iterator.ReachedEnd() ||
        inspected_contents_->GetBrowserContext()->IsOffTheRecord()) {
      ReplyZacro(*id, {}, "Invalid encrypted navigation state."); return true;
    }
    auto* crypt = g_browser_process ? g_browser_process->os_crypt_async() : nullptr;
    if (!crypt) { ReplyZacro(*id, {}, "Native navigation encryption is unavailable."); return true; }
    crypt->GetInstance(base::BindOnce(
        [](base::WeakPtr<CefDevToolsController> self, int id,
           std::string wrapped_key, std::string nonce, std::string ciphertext,
           scoped_refptr<os_crypt_async::Encryptor> encryptor) {
          if (!self) return;
          auto key = encryptor->DecryptData(base::as_bytes(base::span(wrapped_key)));
          if (!key || key->size() != 32) { self->ReplyZacro(id, {}, "Navigation decryption failed."); return; }
          const auto binding = ZacroHistoryBinding(self->inspected_contents_);
          auto plain = crypto::aead::Open(crypto::aead::AES_256_GCM,
              base::as_bytes(base::span(*key)), base::as_bytes(base::span(ciphertext)),
              base::as_bytes(base::span(nonce)), base::as_bytes(base::span(binding)));
          if (!plain) { self->ReplyZacro(id, {}, "Navigation state is damaged or belongs to another profile."); return; }
          auto pickle = base::Pickle::WithData(*plain);
          base::PickleIterator iterator(pickle);
          int version = 0, selected = -1, count = 0;
          if (!iterator.ReadInt(&version) || (version != 1 && version != 2) || !iterator.ReadInt(&selected) ||
              !iterator.ReadInt(&count) || count < 1 || count > 500 || selected < 0 || selected >= count) {
            self->ReplyZacro(id, {}, "Unsupported navigation state."); return;
          }
          auto* context = self->inspected_contents_->GetBrowserContext();
          std::vector<sessions::SerializedNavigationEntry> saved;
          for (int index = 0; index < count; ++index) {
            sessions::SerializedNavigationEntry entry;
            std::string extension, incarnation, error;
            if (!entry.ReadFromPickle(&iterator) ||
                (version == 2 && (!iterator.ReadString(&extension) || !iterator.ReadString(&incarnation))) ||
                (extension.empty() ? !ZacroRestorableURL(entry.virtual_url(), context) :
                 !ZacroValidateNavigation(context, extension, incarnation, entry.virtual_url().spec(), error))) {
              self->ReplyZacro(id, {}, error.empty() ? "Invalid navigation entry." : error); return;
            }
            if (!extension.empty()) ZacroNavigationApprovals::ForDocument(self->inspected_contents_)->destinations[entry.virtual_url().spec()] = {extension, incarnation};
            saved.push_back(std::move(entry));
          }
          auto& controller = self->inspected_contents_->GetController();
          const bool initial = controller.GetLastCommittedEntry()->IsInitialEntry();
          const bool dormant = self->zacro_dormant_entry_ > 0 && controller.GetEntryCount() == 1 &&
              controller.GetLastCommittedEntry()->GetUniqueID() == self->zacro_dormant_entry_ &&
              self->inspected_contents_->GetLastCommittedURL() == GURL("about:blank") &&
              !self->inspected_contents_->IsLoading();
          if (!iterator.ReachedEnd() || controller.GetPendingEntry() || (!initial && !dormant)) {
            self->ReplyZacro(id, {}, "Restore requires a fresh document with no navigation in progress."); return;
          }
          auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(saved, context);
          controller.Restore(selected + (dormant ? 1 : 0), content::RestoreType::kRestored, &entries);
          if (dormant) {
            CHECK(controller.RemoveEntryAtIndex(0));
            self->zacro_dormant_entry_ = 0;
            self->zacro_dormant_history_.clear();
          }
          controller.LoadIfNecessary();
          self->ReplyZacro(id, base::DictValue().Set("restored", true));
        }, weak_ptr_factory_.GetWeakPtr(), *id, std::move(wrapped_key), std::move(nonce), std::move(ciphertext)));
    return true;
  }
  return false;
}

void CefDevToolsController::FinishZacroDataRemoval(int id, uint64_t failed_types) {
  ReplyZacro(id, base::DictValue().Set("cleared", failed_types == 0),
      failed_types ? "Some browsing data could not be cleared (mask " +
          base::NumberToString(failed_types) + ")." : "");
  zacro_data_removals_.erase(id);
}

void CefDevToolsController::FinishZacroDiscard(int id, int entry_id, const std::string& error) {
  zacro_dormant_entry_ = entry_id;
  if (!entry_id) zacro_dormant_history_.clear();
  ReplyZacro(id, base::DictValue().Set("discarded", entry_id > 0), error);
  zacro_discard_.reset();
}
