// The Swift shell owns logical tabs and windows. Chromium still owns the
// extension caller, schema, permission grants and real WebContents identities.
#include "base/strings/pattern.h"
#include "base/no_destructor.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/extensions/window_controller.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/extensions/extension_commands_global_registry.h"
#include "chrome/browser/ui/views/extensions/extension_keybinding_registry_views.h"
#include "chrome/browser/ui/extensions/extension_side_panel_manager.h"
#include "chrome/common/extensions/api/tabs.h"
#include "chrome/common/extensions/api/tab_groups.h"
#include "chrome/common/extensions/api/windows.h"
#include "chrome/common/extensions/api/sessions.h"
#include "chrome/common/extensions/api/side_panel.h"
#include "components/tab_groups/tab_group_id.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/api/runtime/runtime_api.h"
#include "extensions/browser/extension_host_registry.h"
#include "extensions/browser/extension_function.h"
#include "extensions/browser/extension_function_dispatcher.h"
#include "extensions/common/url_pattern_set.h"
#include "content/public/browser/weak_document_ptr.h"
#include "url/origin.h"
#include "cef/libcef/browser/devtools/zacro_tab_reservation.h"

namespace {
using ZacroNativeResponse = ExtensionFunction::NativeResponse;
using ZacroTabUtil = extensions::ExtensionTabUtil;

constexpr char kZacroReservedTabID[] = "zacro.native.reserved-session-tab-id";
class ZacroReservedTabID : public base::SupportsUserData::Data {
 public:
  explicit ZacroReservedTabID(SessionID value) : id(value) {}
  const SessionID id;
};

std::optional<extensions::events::HistogramValue> ZacroBrowserEvent(const std::string& name) {
  using namespace extensions::events;
  static const base::NoDestructor<std::map<std::string, HistogramValue>> events({
    {"tabs.onCreated", TABS_ON_CREATED}, {"tabs.onUpdated", TABS_ON_UPDATED},
    {"tabs.onRemoved", TABS_ON_REMOVED}, {"tabs.onActivated", TABS_ON_ACTIVATED},
    {"tabs.onHighlighted", TABS_ON_HIGHLIGHTED},
    {"tabs.onSelectionChanged", TABS_ON_SELECTION_CHANGED}, {"tabs.onActiveChanged", TABS_ON_ACTIVE_CHANGED},
    {"tabs.onHighlightChanged", TABS_ON_HIGHLIGHT_CHANGED}, {"tabs.onMoved", TABS_ON_MOVED},
    {"tabs.onAttached", TABS_ON_ATTACHED}, {"tabs.onDetached", TABS_ON_DETACHED},
    {"tabs.onReplaced", TABS_ON_REPLACED}, {"tabs.onZoomChange", TABS_ON_ZOOM_CHANGE},
    {"sessions.onChanged", SESSIONS_ON_CHANGED},
    {"windows.onCreated", WINDOWS_ON_CREATED}, {"windows.onRemoved", WINDOWS_ON_REMOVED},
    {"windows.onFocusChanged", WINDOWS_ON_FOCUS_CHANGED}, {"windows.onBoundsChanged", WINDOWS_ON_BOUNDS_CHANGED},
    {"tabGroups.onCreated", TAB_GROUPS_ON_CREATED}, {"tabGroups.onUpdated", TAB_GROUPS_ON_UPDATED},
    {"tabGroups.onMoved", TAB_GROUPS_ON_MOVED}, {"tabGroups.onRemoved", TAB_GROUPS_ON_REMOVED},
  });
  auto it = events->find(name);
  return it == events->end() ? std::nullopt : std::make_optional(it->second);
}

// Return nullopt for functions whose implementation remains wholly Chromium.
std::optional<bool> ZacroValidateFunction(const std::string& method, const base::ListValue& args) {
#define ZACRO_TAB(name, type) if (method == "tabs." name) return extensions::api::tabs::type::Params::Create(args).has_value()
  ZACRO_TAB("query", Query); ZACRO_TAB("get", Get); ZACRO_TAB("getSelected", GetSelected);
  ZACRO_TAB("getAllInWindow", GetAllInWindow); ZACRO_TAB("create", Create);
  ZACRO_TAB("update", Update); ZACRO_TAB("remove", Remove); ZACRO_TAB("reload", Reload);
  ZACRO_TAB("duplicate", Duplicate); ZACRO_TAB("move", Move); ZACRO_TAB("highlight", Highlight);
  ZACRO_TAB("discard", Discard); ZACRO_TAB("goBack", GoBack); ZACRO_TAB("goForward", GoForward);
  ZACRO_TAB("getZoom", GetZoom); ZACRO_TAB("setZoom", SetZoom);
  ZACRO_TAB("getZoomSettings", GetZoomSettings); ZACRO_TAB("setZoomSettings", SetZoomSettings);
  ZACRO_TAB("captureVisibleTab", CaptureVisibleTab); ZACRO_TAB("detectLanguage", DetectLanguage);
  ZACRO_TAB("createSplit", CreateSplit); ZACRO_TAB("unsplit", Unsplit);
  ZACRO_TAB("group", Group); ZACRO_TAB("ungroup", Ungroup);
#undef ZACRO_TAB
#define ZACRO_WINDOW(name, type) if (method == "windows." name) return extensions::api::windows::type::Params::Create(args).has_value()
  ZACRO_WINDOW("get", Get); ZACRO_WINDOW("getCurrent", GetCurrent);
  ZACRO_WINDOW("getLastFocused", GetLastFocused); ZACRO_WINDOW("getAll", GetAll);
  ZACRO_WINDOW("create", Create); ZACRO_WINDOW("update", Update); ZACRO_WINDOW("remove", Remove);
#undef ZACRO_WINDOW
#define ZACRO_GROUP(name, type) if (method == "tabGroups." name) return extensions::api::tab_groups::type::Params::Create(args).has_value()
  ZACRO_GROUP("get", Get); ZACRO_GROUP("query", Query); ZACRO_GROUP("update", Update); ZACRO_GROUP("move", Move);
#undef ZACRO_GROUP
  if (method == "sidePanel.open") return extensions::api::side_panel::Open::Params::Create(args).has_value();
  if (method == "sidePanel.close") return extensions::api::side_panel::Close::Params::Create(args).has_value();
  if (method == "sessions.getRecentlyClosed") return extensions::api::sessions::GetRecentlyClosed::Params::Create(args).has_value();
  if (method == "sessions.getDevices") return extensions::api::sessions::GetDevices::Params::Create(args).has_value();
  if (method == "sessions.restore") return extensions::api::sessions::Restore::Params::Create(args).has_value();
  if (method == "tabs.getCurrent") return args.empty();
  if (method == "runtime.openOptionsPage") return args.empty();
  return std::nullopt;
}

bool ZacroPrepareNavigation(ExtensionFunction* function, base::ListValue& args, std::string& error) {
  const std::string method(function->name());
  if (method != "tabs.create" && method != "tabs.update" && method != "windows.create") return true;
  for (auto& argument : args) {
    if (!argument.is_dict()) continue;
    auto* url = argument.GetDict().Find("url");
    if (!url) continue;
    auto prepare = [&](base::Value& value) {
      if (!value.is_string()) { error = "The navigation address is invalid."; return false; }
      auto checked = ZacroTabUtil::PrepareURLForNavigation(value.GetString(), function->extension(), function->browser_context());
      if (!checked.has_value()) { error = checked.error(); return false; }
      value = base::Value(checked->spec()); return true;
    };
    if (url->is_list()) {
      for (auto& value : url->GetList()) if (!prepare(value)) return false;
    } else if (!prepare(*url)) return false;
  }
  return true;
}

// Per-profile approvals are produced only through the native channel. Durable
// Core provenance is a hint: every use rechecks the installed extension and
// Chromium's current navigation/file-access policy.
class ZacroNavigationApprovals : public base::SupportsUserData::Data {
 public:
  static ZacroNavigationApprovals* Get(content::BrowserContext* context) {
    constexpr char key[] = "zacro.native.navigation-approvals";
    if (auto* found = context->GetUserData(key)) return static_cast<ZacroNavigationApprovals*>(found);
    auto value = std::make_unique<ZacroNavigationApprovals>(); auto* result = value.get();
    context->SetUserData(key, std::move(value)); return result;
  }
  static ZacroNavigationApprovals* ForDocument(content::WebContents* contents) {
    constexpr char key[] = "zacro.native.document-navigation-approvals";
    if (auto* found = contents->GetUserData(key)) return static_cast<ZacroNavigationApprovals*>(found);
    auto value = std::make_unique<ZacroNavigationApprovals>(); auto* result = value.get();
    contents->SetUserData(key, std::move(value)); return result;
  }
  std::map<std::string, std::pair<std::string, std::string>> destinations;
};
bool ZacroValidateNavigation(content::BrowserContext* context, const std::string& extension_id,
    const std::string& incarnation, const std::string& url, std::string& error) {
  auto* registry = extensions::ExtensionRegistry::Get(context);
  const auto* extension = registry ? registry->enabled_extensions().GetByID(extension_id) : nullptr;
  if (!extension || incarnation.empty() ||
      ZacroExtensionContext::Get(context)->IncarnationID(*extension) != incarnation) {
    error = "The extension navigation authorization is no longer current."; return false;
  }
  auto checked = ZacroTabUtil::PrepareURLForNavigation(url, extension, context);
  if (!checked.has_value()) { error = checked.error(); return false; }
  if (checked->spec() != url) { error = "The native navigation address changed."; return false; }
  auto& destinations = ZacroNavigationApprovals::Get(context)->destinations;
  if (!destinations.contains(url) && destinations.size() >= 8192) {
    error = "Too many retained native navigation authorizations."; return false;
  }
  destinations[url] = {extension_id, incarnation}; return true;
}

class ZacroBrowserContext : public base::SupportsUserData::Data {
 public:
  static constexpr char kKey[] = "zacro.native.browser-model";
  static ZacroBrowserContext* Find(content::BrowserContext* context) {
    return context ? static_cast<ZacroBrowserContext*>(context->GetUserData(kKey)) : nullptr;
  }
  static ZacroBrowserContext* Get(content::BrowserContext* context) {
    if (auto* found = Find(context)) return found;
    auto value = std::make_unique<ZacroBrowserContext>(context);
    auto* result = value.get(); context->SetUserData(kKey, std::move(value)); return result;
  }
  explicit ZacroBrowserContext(content::BrowserContext* context) : context_(context) {}
  static void InstallHooks() {
    extensions::RuntimeGetContextsFunction::SetNativeContextDecorator(base::BindRepeating(
        [](content::WebContents* contents, extensions::api::runtime::ExtensionContext* value) {
          auto* state = Get(contents->GetBrowserContext());
          const int native_id = sessions::SessionTabHelper::IdForTab(contents).id();
          auto tab = state->tabs_.find(native_id);
          if (tab != state->tabs_.end() && tab->second->web_contents() == contents) {
            value->tab_id = native_id; value->window_id = tab->second->window; return true;
          }
          // Popup/panel documents are extension UI, not logical browser tabs.
          // Ask their real ExtensionViewHost for the browser that owns them.
          const int physical_window = value->window_id;
          value->tab_id = -1; value->window_id = -1;
          if (physical_window >= 0) for (const auto& [id, candidate] : state->tabs_) {
            if (candidate->web_contents() && ZacroTabUtil::GetWindowIdOfTab(candidate->web_contents()) == physical_window) {
              value->window_id = candidate->window; break;
            }
          }
          auto* registry = extensions::ExtensionHostRegistry::Get(contents->GetBrowserContext());
          auto* host = registry ? registry->GetExtensionHostForPrimaryMainFrame(contents->GetPrimaryMainFrame()) : nullptr;
          if (host && (host->extension_host_type() == extensions::mojom::ViewType::kExtensionPopup ||
                       host->extension_host_type() == extensions::mojom::ViewType::kExtensionSidePanel)) {
            auto* controller = static_cast<extensions::ExtensionViewHost*>(host)->GetExtensionWindowController();
            auto* browser = controller ? controller->GetBrowserWindowInterface() : nullptr;
            if (auto window = state->WindowForBrowser(browser)) value->window_id = *window;
          }
          return value->context_type != extensions::api::runtime::ContextType::kTab;
        }));
    sessions::SessionTabHelper::SetNativeInitialIDProvider(base::BindRepeating(
        [](content::WebContents* contents) -> std::optional<SessionID> {
          auto* reserved = static_cast<ZacroReservedTabID*>(contents->GetUserData(kZacroReservedTabID));
          if (!reserved) return std::nullopt;
          const auto id = reserved->id;
          contents->RemoveUserData(kZacroReservedTabID);
          return id;
        }));
    ZacroTabUtil::SetNativeTabDecorator(base::BindRepeating(
        [](content::WebContents* contents, extensions::api::tabs::Tab* value) {
          if (!contents) return false;
          auto* state = Get(contents->GetBrowserContext());
          auto found = state->tabs_.find(sessions::SessionTabHelper::IdForTab(contents).id());
          if (found == state->tabs_.end() || found->second->web_contents() != contents) return false;
          if (value) {
            const auto& tab = *found->second;
            value->window_id = tab.window; value->index = tab.index;
            value->active = tab.active; value->selected = tab.active; value->highlighted = tab.highlighted;
            value->pinned = tab.pinned; value->discarded = tab.discarded;
            value->auto_discardable = tab.auto_discardable;
            value->split_view_id = tab.split_view_id;
            value->group_id = tab.group_id;
            value->opener_tab_id = tab.opener_tab_id;
          }
          return true;
        }));
    ExtensionFunction::SetNativeDispatcher(base::BindRepeating(
        [](ExtensionFunction* function, const base::ListValue& args, ZacroNativeResponse response) {
          if (!function->browser_context()) return false;
          return Get(function->browser_context())->Dispatch(function, args, std::move(response));
        }));
    extensions::EventRouter::SetNativeEventFilter(base::BindRepeating(
        [](content::BrowserContext* context, extensions::Event& event, const std::string& extension_id) {
          if (event.event_name == "sidePanel.onOpened" || event.event_name == "sidePanel.onClosed") {
            auto* state = Get(context);
            if (event.args().size() != 1 || !event.args()[0].is_dict()) return false;
            auto arguments = event.args().Clone(); auto& info = arguments[0].GetDict();
            const auto physical = info.FindInt("windowId");
            if (!physical) return false;
            std::optional<int> logical;
            content::WebContents* owner = nullptr;
            for (const auto& [id, tab] : state->tabs_) {
              if (tab->web_contents() && ZacroTabUtil::GetWindowIdOfTab(tab->web_contents()) == *physical) {
                logical = tab->window; owner = tab->web_contents(); break;
              }
            }
            if (!logical) for (const auto& [window, parked] : state->panel_parking_) {
              if (parked && ZacroTabUtil::GetWindowIdOfTab(parked.get()) == *physical) {
                logical = window; owner = parked.get(); break;
              }
            }
            if (!logical) return false;
            ZacroRefreshSidePanelPresentation(owner);
            if (!info.FindInt("tabId") && !extension_id.empty()) {
              if (event.event_name == "sidePanel.onOpened") {
                state->global_panels_[*logical] = {extension_id, owner->GetWeakPtr()};
              } else {
                auto current = state->global_panels_.find(*logical);
                if (current != state->global_panels_.end() && current->second.extension == extension_id &&
                    current->second.contents.get() == owner) state->global_panels_.erase(current);
              }
            }
            info.Set("windowId", *logical); event.ReplaceNativeArguments(std::move(arguments));
            return true;
          }
          if (event.native_host_topology || !ZacroBrowserEvent(event.event_name)) return true;
          auto* state = Get(context);
          // Zoom events already use true SessionTabIDs and no physical window
          // IDs. Preserve Chromium's native ZoomController attribution.
          if (event.event_name == "tabs.onZoomChange" && !event.args().empty() && event.args()[0].is_dict()) {
            auto tab = event.args()[0].GetDict().FindInt("tabId");
            return tab && state->tabs_.contains(*tab);
          }
          return false;
        }));
  }
  ~ZacroBrowserContext() override {
    weak_.InvalidateWeakPtrs();
    auto pending = std::move(pending_);
    for (auto& [id, request] : pending) {
      std::move(request->response).Run({}, "The browser profile closed.");
    }
  }
  void SetObserved(bool observed) {
    observed_ = observed;
    if (!observed) return;
    // Extension workers can query their browser during profile startup, before
    // the Swift observer is attached. Queue those requests without revealing
    // physical implementation windows or spuriously failing initialization.
    for (auto& [id, request] : pending_) {
      if (!request->dispatched) {
        request->dispatched = true;
        ZacroExtensionContext::Get(context_)->NotifyHost(request->event);
      }
    }
  }
  void SetFocusedWindow(std::optional<int> window, std::optional<int> last_focused) {
    focused_window_ = window;
    last_focused_window_ = last_focused ? last_focused : window;
    ReconcileKeyboardFocus();
  }
  void ReconcileKeyboardFocus() {
    // The Swift shell is not a Views widget, so its activation does not update
    // Chromium's per-profile command target automatically. Keep the genuine
    // registry attached to the active logical document, including global keys.
    ExtensionKeybindingRegistryViews* active = nullptr;
    for (const auto& [id, tab] : tabs_) {
      auto* contents = tab->web_contents();
      auto* browser = contents ? extensions::browser_window_util::GetBrowserForTabContents(*contents) : nullptr;
      auto* registry = browser ? ExtensionKeybindingRegistryViews::From(browser) : nullptr;
      if (!registry) continue;
      registry->OnHostActivationChanged(false);
      if (focused_window_ == tab->window && tab->active && !tab->closing) active = registry;
    }
    if (active) {
      active->OnHostActivationChanged(true);
      if (auto* global = extensions::ExtensionCommandsGlobalRegistry::Get(context_)) {
        auto* listener = ui::GlobalAcceleratorListener::GetInstance();
        active->SetShortcutHandlingSuspended(global->shortcut_handling_suspended() ||
            (listener && listener->IsShortcutHandlingSuspended()));
      }
    }
  }
  bool IsCommandTarget(content::WebContents* contents) const {
    const auto found = tabs_.find(sessions::SessionTabHelper::IdForTab(contents).id());
    return found != tabs_.end() && found->second->web_contents() == contents &&
        found->second->active && !found->second->closing &&
        focused_window_ == found->second->window;
  }
  std::optional<int> WindowForBrowser(BrowserWindowInterface* browser) const {
    if (!browser) return std::nullopt;
    for (const auto& [id, tab] : tabs_) if (auto* contents = tab->web_contents(); contents &&
        extensions::browser_window_util::GetBrowserForTabContents(*contents) == browser) return tab->window;
    for (const auto& [window, parked] : panel_parking_) if (parked &&
        extensions::browser_window_util::GetBrowserForTabContents(*parked) == browser) return window;
    return std::nullopt;
  }
  bool OwnsGlobalPanel(content::WebContents* contents, int window) const {
    const auto found = global_panels_.find(window);
    return found != global_panels_.end() && found->second.contents.get() == contents;
  }
  bool RegisterPanelParking(content::WebContents* contents, int window, std::string& error) {
    if (!contents || contents->GetBrowserContext() != context_ || window <= 0 ||
        tabs_.contains(sessions::SessionTabHelper::IdForTab(contents).id()) ||
        contents->GetVisibleURL() != GURL("about:blank")) {
      error = "The extension panel parking document is invalid."; return false;
    }
    auto found = panel_parking_.find(window);
    if (found != panel_parking_.end() && found->second && found->second.get() != contents) {
      error = "This logical window already has a retained panel owner."; return false;
    }
    panel_parking_[window] = contents->GetWeakPtr();
    ReconcileGlobalPanels();
    return true;
  }
  struct Tab : content::WebContentsObserver {
    explicit Tab(content::WebContents* contents) { Bind(contents); }
    void Bind(content::WebContents* contents) {
      detach_subscription = {}; closing = false; Observe(contents);
      if (contents) if (auto* tab = tabs::TabInterface::MaybeGetFromContents(contents)) {
        detach_subscription = tab->RegisterWillDetach(base::BindRepeating(
            [](Tab* self, tabs::TabInterface* tab, tabs::TabInterface::DetachReason reason) {
              if (reason != tabs::TabInterface::DetachReason::kDelete || !self->web_contents()) return;
              self->closing = true;
              // Chrome invokes WillDetach only once beforeunload has accepted
              // closure. Move a global panel before its containing view dies.
              Get(self->web_contents()->GetBrowserContext())->ReconcileGlobalPanels(self->web_contents());
            }, base::Unretained(this)));
      }
    }
    std::string logical_id;
    int window = 1;
    int index = 0;
    bool active = false;
    bool highlighted = false;
    bool pinned = false;
    bool discarded = false;
    bool auto_discardable = true;
    int split_view_id = -1;
    int group_id = -1;
    std::optional<int> opener_tab_id;
    bool closing = false;
    base::CallbackListSubscription detach_subscription;
  };
  // Snapshot publication reserves identities without allocating WebContents,
  // renderer processes or native windows for dormant restored tabs.
  base::DictValue Synchronize(const base::DictValue& params, std::string& error) {
    const auto revision = params.FindDouble("revision");
    const auto* entries = params.FindList("tabs");
    if (!revision || *revision < revision_ || *revision > 9007199254740991.0 ||
        !entries || entries->size() > 4096) {
      error = "The logical tab snapshot is stale or invalid."; return {};
    }
    std::set<std::string> logical_ids;
    for (const auto& entry : *entries) {
      if (!entry.is_dict() || !ValidMetadata(entry.GetDict(), error)) return {};
      if (!logical_ids.insert(*entry.GetDict().FindString("logicalID")).second) {
        error = "The logical tab snapshot contains duplicate identities."; return {};
      }
    }
    // Validate the whole snapshot before changing existing identities.
    for (const auto& [token, reservation] : reservations_) {
      auto tab = tabs_.find(reservation.tab_id);
      if (reservation.claimed && (tab == tabs_.end() || !logical_ids.contains(tab->second->logical_id))) {
        error = "A native tab creation is in progress; retry the snapshot after it finishes."; return {};
      }
    }
    for (auto it = tabs_.begin(); it != tabs_.end();) {
      if (!logical_ids.contains(it->second->logical_id)) it = tabs_.erase(it); else ++it;
    }
    for (auto it = reservations_.begin(); it != reservations_.end();) {
      if (!tabs_.contains(it->second.tab_id)) it = reservations_.erase(it); else ++it;
    }
    base::ListValue identities;
    for (const auto& entry : *entries) {
      const auto& data = entry.GetDict(); const auto& logical = *data.FindString("logicalID");
      int id = FindLogical(logical);
      if (!id) {
        id = SessionID::NewUnique().id();
        tabs_[id] = std::make_unique<Tab>(nullptr);
      }
      UpdateMetadata(*tabs_.at(id), data);
      identities.Append(base::DictValue().Set("logicalID", logical).Set("tabID", id)
          .Set("materialized", tabs_.at(id)->web_contents() != nullptr));
    }
    for (const auto& entry : *entries) {
      const auto& data = entry.GetDict(); const int id = FindLogical(*data.FindString("logicalID"));
      const auto* opener = data.FindString("openerLogicalID");
      const int opener_id = opener ? FindLogical(*opener) : 0;
      tabs_.at(id)->opener_tab_id = opener_id && opener_id != id ? std::make_optional(opener_id) : std::nullopt;
    }
    revision_ = *revision;
    ReconcileGlobalPanels();
    ReconcileKeyboardFocus();
    return base::DictValue().Set("tabs", std::move(identities));
  }
  base::DictValue SynchronizeGroups(const base::DictValue& params, std::string& error) {
    const auto revision = params.FindDouble("revision");
    const auto* entries = params.FindList("groups");
    if (!revision || *revision < group_revision_ || *revision > 9007199254740991.0 ||
        !entries || entries->size() > 4096) { error = "The logical group snapshot is stale or invalid."; return {}; }
    std::set<std::string> logical_ids;
    for (const auto& entry : *entries) {
      const auto* data = entry.GetIfDict();
      const auto* logical = data ? data->FindString("logicalID") : nullptr;
      const auto window = data ? data->FindInt("windowID") : std::nullopt;
      const auto* title = data ? data->FindString("title") : nullptr;
      const auto* color = data ? data->FindString("color") : nullptr;
      const auto collapsed = data ? data->FindBool("collapsed") : std::nullopt;
      const auto shared = data ? data->FindBool("shared") : std::nullopt;
      if (!logical || logical->empty() || logical->size() > 256 || !logical_ids.insert(*logical).second ||
          !window || *window < 1 || !title || title->size() > 4096 || !color || !collapsed || !shared || *shared) {
        error = "The logical group metadata is invalid."; return {};
      }
      auto value = base::DictValue().Set("id", 0).Set("windowId", *window).Set("title", *title)
          .Set("color", *color).Set("collapsed", *collapsed).Set("shared", false);
      if (!extensions::api::tab_groups::TabGroup::FromValue(value).has_value()) {
        error = "The logical group metadata does not match Chromium's schema."; return {};
      }
    }
    for (auto it = groups_.begin(); it != groups_.end();) {
      if (!logical_ids.contains(it->first)) {
        const int retired = ZacroTabUtil::GetGroupId(it->second.id);
        for (auto& [id, tab] : tabs_) if (tab->group_id == retired) tab->group_id = -1;
        it = groups_.erase(it);
      } else ++it;
    }
    base::ListValue result;
    for (const auto& entry : *entries) {
      const auto& data = entry.GetDict(); const auto& logical = *data.FindString("logicalID");
      if (!groups_.contains(logical)) {
        auto id = tab_groups::TabGroupId::CreateEmpty();
        int native_id;
        do {
          id = tab_groups::TabGroupId::GenerateNew(); native_id = ZacroTabUtil::GetGroupId(id);
        } while (native_id < 0 || std::ranges::any_of(groups_, [&](const auto& group) {
          return ZacroTabUtil::GetGroupId(group.second.id) == native_id;
        }));
        groups_.emplace(logical, Group{id, *data.FindInt("windowID")});
      }
      auto& group = groups_.at(logical); group.window = *data.FindInt("windowID");
      result.Append(base::DictValue().Set("logicalID", logical).Set("groupID", ZacroTabUtil::GetGroupId(group.id)));
    }
    group_revision_ = *revision;
    return base::DictValue().Set("groups", std::move(result));
  }
  base::DictValue Prepare(const std::string& logical, const std::string& opener_request, std::string& error) {
    const int id = FindLogical(logical);
    if (!id) { error = "The logical tab has not been reserved."; return {}; }
    if (tabs_.at(id)->web_contents()) { error = "The logical tab already has a native document."; return {}; }
    if (!opener_request.empty() && !ValidOpenerRequest(opener_request, error)) return {};
    for (const auto& [token, reservation] : reservations_) {
      if (reservation.tab_id == id) {
        if (reservation.claimed) { error = "The logical tab is already being created."; return {}; }
        if (reservation.opener_request != opener_request) { error = "The tab's native opener authorization changed."; return {}; }
        return base::DictValue().Set("tabID", id).Set("token", token);
      }
    }
    const auto token = base::Uuid::GenerateRandomV4().AsLowercaseString();
    reservations_.emplace(token, Reservation{id, false, opener_request});
    return base::DictValue().Set("tabID", id).Set("token", token);
  }
  bool Claim(const std::string& token) {
    auto found = reservations_.find(token);
    if (found == reservations_.end() || found->second.claimed) return false;
    auto tab = tabs_.find(found->second.tab_id);
    if (tab == tabs_.end() || tab->second->web_contents()) return false;
    std::string error;
    if (!found->second.opener_request.empty() && !ValidOpenerRequest(found->second.opener_request, error)) return false;
    found->second.claimed = true; return true;
  }
  bool ResolveOpener(const std::string& token, content::WeakDocumentPtr* opener,
                     std::optional<url::Origin>* initiator) {
    auto found = reservations_.find(token);
    if (found == reservations_.end() || !found->second.claimed || !opener || !initiator) return false;
    *opener = content::WeakDocumentPtr(); initiator->reset();
    const auto& id = found->second.opener_request;
    if (id.empty()) return true;
    std::string error;
    if (!ValidOpenerRequest(id, error)) return false;
    const auto& request = *pending_.at(id);
    *opener = request.source_document;
    *initiator = request.extension->origin();
    return true;
  }
  bool Consume(content::WebContents* contents, const std::string& token) {
    auto found = reservations_.find(token);
    if (found == reservations_.end() || !found->second.claimed || !contents ||
        contents->GetBrowserContext() != context_ || sessions::SessionTabHelper::FromWebContents(contents)) return false;
    auto tab = tabs_.find(found->second.tab_id);
    if (tab == tabs_.end() || tab->second->web_contents()) return false;
    const int id = found->second.tab_id;
    contents->SetUserData(kZacroReservedTabID, std::make_unique<ZacroReservedTabID>(SessionID::FromSerializedValue(id)));
    tab->second->Bind(contents);
    reservations_.erase(found); return true;
  }
  void Abort(const std::string& token) { reservations_.erase(token); }
  int Register(content::WebContents* contents, const base::DictValue& params, std::string& error) {
    const auto* logical = params.FindString("logicalID");
    auto window = params.FindInt("windowID"); auto index = params.FindInt("index");
    auto active = params.FindBool("active"), pinned = params.FindBool("pinned"), discarded = params.FindBool("discarded");
    const int split = params.FindInt("splitViewID").value_or(-1);
    const auto opener = params.FindInt("openerTabID");
    const int native_id = sessions::SessionTabHelper::IdForTab(contents).id();
    if (!logical || logical->empty() || logical->size() > 256 || !window || *window < 1 || !index || *index < 0 ||
        !active || !pinned || !discarded || native_id < 1 || split < -1 ||
        (opener && (*opener <= 0 || *opener == native_id || !tabs_.contains(*opener))) ||
        contents->GetBrowserContext() != context_ || !ValidGroupReference(params.FindInt("groupID").value_or(-1), *window)) {
      error = "The native tab registration is invalid."; return 0;
    }
    const int reserved = FindLogical(*logical);
    if (reserved && reserved != native_id) { error = "The native document does not match its reserved tab identity."; return 0; }
    if (!tabs_.contains(native_id) && tabs_.size() >= 4096) { error = "Too many registered tabs."; return 0; }
    auto& tab = tabs_[native_id]; if (!tab) tab = std::make_unique<Tab>(contents);
    if (tab->web_contents() && tab->web_contents() != contents) { error = "The native tab identity changed."; return 0; }
    if (!tab->web_contents()) tab->Bind(contents);
    tab->logical_id = *logical; tab->window = *window; tab->index = *index;
    tab->active = *active; tab->highlighted = params.FindBool("highlighted").value_or(*active);
    tab->pinned = *pinned; tab->discarded = *discarded;
    tab->auto_discardable = params.FindBool("autoDiscardable").value_or(true);
    tab->split_view_id = split; tab->opener_tab_id = opener;
    tab->group_id = params.FindInt("groupID").value_or(-1);
    ReconcileGlobalPanels();
    ReconcileKeyboardFocus();
    return native_id;
  }
  bool Validate(const std::string& id, std::string& error) {
    auto it = pending_.find(id);
    if (it == pending_.end()) { error = "The native extension request is no longer pending."; return false; }
    auto& request = *it->second;
    auto* registry = extensions::ExtensionRegistry::Get(context_);
    if (request.function->browser_context() != context_ || !registry ||
        registry->enabled_extensions().GetByID(request.extension->id()) != request.extension.get() ||
        !ZacroExtensionContext::Get(context_)->IsCurrent(*request.extension, request.installation) || !request.function->HasPermission()) {
      error = "The extension caller or installation changed."; return false;
    }
    return true;
  }
  base::DictValue AuthorizeNavigation(const std::string& id, const std::string& url, std::string& error) {
    if (!Validate(id, error)) return {};
    auto& request = *pending_.at(id);
    const std::string method(request.function->name());
    bool found = false;
    if (method == "tabs.create" || method == "tabs.update" || method == "windows.create") {
      for (const auto& argument : request.arguments) {
        if (!argument.is_dict()) continue;
        const auto* address = argument.GetDict().Find("url");
        if (!address) continue;
        if (address->is_string()) found |= address->GetString() == url;
        else if (address->is_list()) for (const auto& value : address->GetList())
          found |= value.is_string() && value.GetString() == url;
      }
    }
    if (method == "runtime.openOptionsPage") {
      found = extensions::OptionsPageInfo::HasOptionsPage(request.extension.get()) &&
          extensions::OptionsPageInfo::GetOptionsPage(request.extension.get()).spec() == url;
    }
    if (!found) { error = "The destination does not belong to this native navigation request."; return {}; }
    const auto incarnation = ZacroExtensionContext::Get(context_)->IncarnationID(*request.extension);
    if (!ZacroValidateNavigation(context_, request.extension->id(), incarnation, url, error)) return {};
    return base::DictValue().Set("extensionID", request.extension->id()).Set("incarnationID", incarnation).Set("url", url);
  }
  void Complete(const std::string& id, base::ListValue results, std::string error) {
    auto it = pending_.find(id); if (it == pending_.end()) return;
    std::string validation;
    if (!Validate(id, validation)) error = validation;
    auto request = std::move(it->second); pending_.erase(it);
    request->timer.Stop();
    if (error.empty() && request->prepare_document) {
      auto tab = tabs_.find(*request->prepare_document);
      if (tab == tabs_.end() || !tab->second->web_contents() || tab->second->discarded || !results.empty()) {
        error = "The requested document was not restored.";
      } else {
        auto function = request->function;
        auto arguments = request->arguments.Clone();
        const int target = request->capture_document ? ZacroTabUtil::GetWindowIdOfTab(tab->second->web_contents()) : *request->prepare_document;
        if (request->side_panel_document) {
          if (arguments[0].GetDict().contains("windowId")) arguments[0].GetDict().Set("windowId", ZacroTabUtil::GetWindowIdOfTab(tab->second->web_contents()));
        } else if (arguments.empty()) arguments.Append(target); else arguments[0] = base::Value(target);
        function->ReplaceNativeArguments(std::move(arguments));
        // RunWithValidation was already entered when this request was
        // deferred. Recheck its public validation hook, then enter Run exactly
        // once with the resolved native target and the original caller.
        if (!function->HasPermission() || !function->PreRunValidation(&error)) {
          if (error.empty()) error = "The extension permission changed while restoring the document.";
        } else {
          request->response.Reset();
          function->Run().Execute();
          return;
        }
      }
    }
    if (error.empty()) {
      if (!SanitizeResults(*request, results)) { results.clear(); error = "The native tab response is invalid."; }
    }
    std::move(request->response).Run(std::move(results), std::move(error));
  }
  bool Publish(const std::string& name, const base::ListValue& args, std::string& error) {
    const auto histogram = ZacroBrowserEvent(name);
    if (!histogram || args.size() > 4) { error = "The browser event is invalid."; return false; }
    if ((name == "tabs.onCreated" && (args.size() != 1 || !ValidTab(args[0]))) ||
        (name == "tabs.onUpdated" && (args.size() != 3 || !args[0].is_int() || !args[1].is_dict() || !ValidTab(args[2]))) ||
        ((name == "windows.onCreated" || name == "windows.onBoundsChanged") && (args.size() != 1 || !ValidWindow(args[0]))) ||
        (name.starts_with("tabGroups.") && (args.size() != 1 || !ValidGroup(args[0])))) {
      error = "The native browser event has an invalid schema."; return false;
    }
    auto event = std::make_unique<extensions::Event>(*histogram, name, args.Clone(), context_);
    event->native_host_topology = true;
    event->will_dispatch_callback = base::BindRepeating(
        [](base::WeakPtr<ZacroBrowserContext> self, const std::string& name, const base::ListValue& original,
           content::BrowserContext* context, extensions::mojom::ContextType type,
           const extensions::Extension* extension, const base::DictValue*,
           std::optional<base::ListValue>& output, extensions::mojom::EventFilteringInfoPtr&, bool*) {
          if (!self || !extension || context != self->context_) return false;
          auto result = original.Clone();
          if (!self->ScrubValues(extension, type, result)) return false;
          // changeInfo carries a second copy of privileged fields, separate
          // from the final Tab object in onUpdated.
          if (name == "tabs.onUpdated" && result.size() == 3 && result[1].is_dict() && result[2].is_dict()) {
            auto& change = result[1].GetDict(); const auto& tab = result[2].GetDict();
            for (auto key : {"url", "pendingUrl", "title", "favIconUrl"}) if (!tab.contains(key)) change.Remove(key);
          }
          output = std::move(result); return true;
        }, weak_.GetWeakPtr(), name, args.Clone());
    auto* router = extensions::EventRouter::Get(context_);
    if (!router) { error = "The extension event router is unavailable."; return false; }
    router->BroadcastEvent(std::move(event)); return true;
  }
 private:
  struct Reservation { int tab_id; bool claimed; std::string opener_request; };
  struct Group { tab_groups::TabGroupId id; int window; };
  bool ValidOpenerRequest(const std::string& id, std::string& error) {
    if (!Validate(id, error)) return false;
    const auto& request = *pending_.at(id);
    auto* frame = request.source_document.AsRenderFrameHostIfValid();
    if (std::string(request.function->name()) != "windows.create" || request.arguments.empty() ||
        !request.arguments[0].is_dict() || !request.arguments[0].GetDict().FindBool("setSelfAsOpener").value_or(false) ||
        !frame || frame->GetBrowserContext() != context_ || !frame->IsRenderFrameLive()) {
      error = "The extension's original opener document is no longer available."; return false;
    }
    return true;
  }
  int FindLogical(const std::string& logical) const {
    for (const auto& [id, tab] : tabs_) if (tab->logical_id == logical) return id;
    return 0;
  }
  bool ValidMetadata(const base::DictValue& data, std::string& error) const {
    const auto* logical = data.FindString("logicalID");
    const auto window = data.FindInt("windowID"), index = data.FindInt("index");
    const auto split = data.FindInt("splitViewID").value_or(-1);
    const auto group = data.FindInt("groupID").value_or(-1);
    if (!logical || logical->empty() || logical->size() > 256 || !window || *window < 1 || !index || *index < 0 ||
        !data.FindBool("active") || !data.FindBool("pinned") || !data.FindBool("discarded") || split < -1 ||
        !ValidGroupReference(group, *window)) {
      error = "The logical tab metadata is invalid."; return false;
    }
    return true;
  }
  bool ValidGroupReference(int id, int window) const {
    return id == -1 || (id >= 0 && std::ranges::any_of(groups_, [&](const auto& value) {
      return value.second.window == window && ZacroTabUtil::GetGroupId(value.second.id) == id;
    }));
  }
  static void UpdateMetadata(Tab& tab, const base::DictValue& data) {
    tab.logical_id = *data.FindString("logicalID"); tab.window = *data.FindInt("windowID"); tab.index = *data.FindInt("index");
    tab.active = *data.FindBool("active"); tab.pinned = *data.FindBool("pinned"); tab.discarded = *data.FindBool("discarded");
    tab.highlighted = data.FindBool("highlighted").value_or(tab.active);
    tab.auto_discardable = data.FindBool("autoDiscardable").value_or(true);
    tab.split_view_id = data.FindInt("splitViewID").value_or(-1);
    tab.group_id = data.FindInt("groupID").value_or(-1);
    tab.opener_tab_id = data.FindInt("openerTabID");
  }
  struct Request {
    std::optional<int> prepare_document;
    bool capture_document = false;
    bool side_panel_document = false;
    scoped_refptr<ExtensionFunction> function;
    scoped_refptr<const extensions::Extension> extension;
    std::string installation;
    base::ListValue arguments;
    base::DictValue event;
    content::WeakDocumentPtr source_document;
    bool dispatched = false;
    ZacroNativeResponse response;
    base::OneShotTimer timer;
  };
  bool Dispatch(ExtensionFunction* function, const base::ListValue& args, ZacroNativeResponse response) {
    const std::string method(function->name());
    const auto valid = ZacroValidateFunction(method, args);
    if (!valid) return false;
    if (!*valid) { function->SetBadMessage(); std::move(response).Run({}, "Invalid extension API arguments."); return true; }
    if (method == "windows.create" && !args.empty() && args[0].is_dict() &&
        args[0].GetDict().FindBool("setSelfAsOpener").value_or(false) &&
        (function->is_from_service_worker() || !function->render_frame_host() ||
         !function->render_frame_host()->IsRenderFrameLive())) {
      std::move(response).Run({}, "Cannot specify setSelfAsOpener Service Worker extension."); return true;
    }
    const auto source_window = SourceWindow(function);
    if (method == "runtime.openOptionsPage" &&
        (!function->extension() || !extensions::OptionsPageInfo::HasOptionsPage(function->extension()))) {
      std::move(response).Run({}, "No options page declared."); return true;
    }
    // Document-local APIs retain Chromium's exact implementation. Resolve only
    // their optional logical target, leaving their permissions and mutations to
    // the original ExtensionFunction after this native hook returns false.
    std::optional<int> prepare_document;
    bool capture_document = false;
    bool side_panel_document = false;
    if (method == "sidePanel.open" || method == "sidePanel.close") {
      if (method == "sidePanel.open" && !function->user_gesture()) {
        std::move(response).Run({}, "sidePanel.open() may only be called in response to a user gesture."); return true;
      }
      const auto& options = args[0].GetDict();
      const auto requested_tab = options.FindInt("tabId");
      auto window = options.FindInt("windowId");
      if (!requested_tab && !window) {
        std::move(response).Run({}, "At least one of tabId and windowId must be provided."); return true;
      }
      if (window == -2) window = source_window ? source_window : (focused_window_ ? focused_window_ : last_focused_window_);
      int target = requested_tab.value_or(-1);
      if (!requested_tab && window) for (const auto& [id, tab] : tabs_) {
        if (tab->window == *window && tab->active) { target = id; break; }
      }
      auto tab = tabs_.find(target);
      if (!requested_tab && window && tab == tabs_.end()) {
        auto parking = panel_parking_.find(*window);
        if (parking != panel_parking_.end() && parking->second) {
          auto arguments = args.Clone();
          arguments[0].GetDict().Set("windowId", ZacroTabUtil::GetWindowIdOfTab(parking->second.get()));
          function->ReplaceNativeArguments(std::move(arguments)); return false;
        }
      }
      if (tab == tabs_.end() || (window && tab->second->window != *window)) {
        std::move(response).Run({}, "The side panel target is not in the requested logical window."); return true;
      }
      if (tab->second->web_contents() && !tab->second->discarded) {
        auto arguments = args.Clone();
        if (options.contains("windowId")) arguments[0].GetDict().Set("windowId", ZacroTabUtil::GetWindowIdOfTab(tab->second->web_contents()));
        function->ReplaceNativeArguments(std::move(arguments)); return false;
      }
      prepare_document = target; side_panel_document = true;
    }
    if (method == "tabs.getZoom" || method == "tabs.setZoom" || method == "tabs.getZoomSettings" ||
        method == "tabs.setZoomSettings" || method == "tabs.captureVisibleTab" || method == "tabs.detectLanguage") {
      int target = -1;
      bool capture = method == "tabs.captureVisibleTab";
      if (!args.empty() && args[0].is_int() && !capture) target = args[0].GetInt();
      auto target_window = source_window ? source_window : (focused_window_ ? focused_window_ : last_focused_window_);
      if (capture && !args.empty() && args[0].is_int() && args[0].GetInt() != -2) target_window = args[0].GetInt();
      if (target < 0 && target_window) for (const auto& [id, tab] : tabs_) {
        if (tab->window == *target_window && tab->active) { target = id; break; }
      }
      auto tab = tabs_.find(target);
      if (tab == tabs_.end()) {
        std::move(response).Run({}, "The target tab does not exist in this profile."); return true;
      }
      if (tab->second->web_contents() && !tab->second->discarded) {
        auto native_args = args.Clone();
        const int native_target = capture ? ZacroTabUtil::GetWindowIdOfTab(tab->second->web_contents()) : target;
        if (native_args.empty()) native_args.Append(native_target); else native_args[0] = base::Value(native_target);
        function->ReplaceNativeArguments(std::move(native_args));
        return false;
      }
      prepare_document = target; capture_document = capture;
    }
    if (!function->extension() || pending_.size() >= 256) {
      std::move(response).Run({}, "The native browser host is unavailable."); return true;
    }
    auto arguments = args.Clone(); std::string error;
    if (!ZacroPrepareNavigation(function, arguments, error)) { std::move(response).Run({}, error); return true; }
    // Parse match patterns now, before exposing a request to the host.
    if (method == "tabs.query" && !arguments.empty() && arguments[0].is_dict()) {
      extensions::URLPatternSet patterns;
      if (!QueryPatterns(arguments[0].GetDict(), patterns, error)) { std::move(response).Run({}, error); return true; }
    }
    const std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    auto request = std::make_unique<Request>(); request->function = function; request->extension = function->extension();
    request->installation = ZacroExtensionContext::Get(context_)->InstallationID(*function->extension());
    if (auto* frame = function->render_frame_host()) request->source_document = frame->GetWeakDocumentPtr();
    request->arguments = arguments.Clone(); request->response = std::move(response);
    request->prepare_document = prepare_document; request->capture_document = capture_document;
    request->side_panel_document = side_panel_document;
    // A beforeunload decision has no arbitrary deadline. Do not report failure
    // and then perform a delayed close after the user finally makes a choice.
    if (method != "tabs.remove" && method != "windows.remove") {
      request->timer.Start(FROM_HERE, base::Seconds(60), base::BindOnce(
          &ZacroBrowserContext::Complete, weak_.GetWeakPtr(), id, base::ListValue(), "The native browser request timed out."));
    }
    auto event = base::DictValue().Set("requestID", id).Set("extensionID", function->extension_id())
        .Set("method", method).Set("arguments", std::move(arguments)).Set("userGesture", function->user_gesture())
        .Set("incognito", context_->IsOffTheRecord());
    if (prepare_document) {
      event.Set("method", "native.prepareDocument"); event.Set("arguments", base::ListValue().Append(*prepare_document));
    }
    if (auto* sender = function->GetSenderWebContents()) {
      int source = sessions::SessionTabHelper::IdForTab(sender).id();
      if (tabs_.contains(source)) event.Set("sourceTabID", source);
    }
    if (source_window) event.Set("sourceWindowID", *source_window);
    request->event = event.Clone(); request->dispatched = observed_;
    pending_[id] = std::move(request);
    if (observed_) ZacroExtensionContext::Get(context_)->NotifyHost(event);
    return true;
  }
  std::optional<int> SourceWindow(ExtensionFunction* function) const {
    if (auto* sender = function->GetSenderWebContents()) {
      const int id = sessions::SessionTabHelper::IdForTab(sender).id();
      auto found = tabs_.find(id);
      if (found != tabs_.end() && found->second->web_contents() == sender) return found->second->window;
    }
    // Popup and side-panel WebContents are not logical tabs. Their dispatcher
    // still carries the actual native window controller that created them.
    auto* dispatcher = function->dispatcher();
    auto* controller = dispatcher ? dispatcher->GetExtensionWindowController() : nullptr;
    auto* source = controller ? controller->GetBrowserWindowInterface() : nullptr;
    return WindowForBrowser(source);
  }
  bool ScrubValues(const extensions::Extension* extension, extensions::mojom::ContextType type, base::ListValue& values) {
    for (auto& value : values) if (!ScrubValue(extension, type, value)) return false;
    return true;
  }
  bool ScrubValue(const extensions::Extension* extension, extensions::mojom::ContextType type, base::Value& value) {
    if (value.is_list()) return ScrubValues(extension, type, value.GetList());
    if (!value.is_dict()) return true;
    auto& dict = value.GetDict();
    for (const char* nested : {"tab", "window", "sessions"}) {
      if (auto* entry = dict.Find(nested); entry && !ScrubValue(extension, type, *entry)) return false;
    }
    if (auto* tabs = dict.FindList("tabs")) if (!ScrubValues(extension, type, *tabs)) return false;
    if (!dict.contains("windowId") || !dict.contains("index")) return true;
    const auto id = dict.FindInt("id");
    const bool closed = !id && dict.FindString("sessionId");
    auto found = id ? tabs_.find(*id) : tabs_.end();
    if (!closed && found == tabs_.end()) return false;
    auto* contents = found == tabs_.end() ? nullptr : found->second->web_contents();
    // Real registered documents use their grant-bearing WebContents. Dormant
    // model URLs may differ from its blank document, so grants are also checked
    // for the model address before revealing it.
    const auto* address = dict.FindString("url");
    const auto model = ZacroTabUtil::GetScrubTabBehavior(extension, type, GURL(address ? *address : ""));
    auto behavior = contents ? ZacroTabUtil::GetScrubTabBehavior(extension, type, contents) : model;
    if (!contents || (address && contents->GetLastCommittedURL().spec() != *address)) behavior = model;
    if (const auto* pending = dict.FindString("pendingUrl")) {
      const auto* entry = contents ? contents->GetController().GetPendingEntry() : nullptr;
      if (!entry || entry->GetVirtualURL().spec() != *pending) {
        behavior.pending_info = ZacroTabUtil::GetScrubTabBehavior(extension, type, GURL(*pending)).committed_info;
      }
    }
    auto tab = extensions::api::tabs::Tab::FromValue(dict);
    if (!tab.has_value()) return false;
    ZacroTabUtil::ScrubTabForExtension(extension, contents, &*tab, behavior);
    dict = tab->ToValue(); return true;
  }
  static bool QueryPatterns(const base::DictValue& query, extensions::URLPatternSet& patterns, std::string& error) {
    std::vector<std::string> strings;
    if (auto* value = query.Find("url")) {
      if (value->is_string()) strings.push_back(value->GetString());
      else if (value->is_list()) for (const auto& item : value->GetList()) {
        if (!item.is_string()) { error = "The URL pattern is invalid."; return false; }
        strings.push_back(item.GetString());
      }
    }
    return patterns.Populate(strings, URLPattern::SCHEME_ALL, true, &error);
  }
  bool SanitizeResults(const Request& request, base::ListValue& results) {
    const std::string method(request.function->name());
    if (!ValidResults(method, results)) return false;
    if (!ScrubValues(request.extension.get(), request.function->source_context_type(), results)) return false;
    if (method == "tabGroups.query" && !request.arguments.empty() && request.arguments[0].is_dict()) {
      if (const auto* pattern = request.arguments[0].GetDict().FindString("title")) {
        results[0].GetList().EraseIf([&](const base::Value& value) {
          const auto* title = value.GetDict().FindString("title");
          return !base::MatchPattern(base::UTF8ToUTF16(title ? *title : ""), base::UTF8ToUTF16(*pattern));
        });
      }
      return true;
    }
    if (std::string(request.function->name()) != "tabs.query" || request.arguments.empty() ||
        !request.arguments[0].is_dict() || results.size() != 1 || !results[0].is_list()) return true;
    const auto& query = request.arguments[0].GetDict(); extensions::URLPatternSet patterns; std::string error;
    if (!QueryPatterns(query, patterns, error)) return false;
    auto& list = results[0].GetList();
    list.EraseIf([&](const base::Value& value) {
      if (!value.is_dict()) return true;
      const auto& tab = value.GetDict();
      if (const auto* title = query.FindString("title"); title && !title->empty()) {
        const auto* actual = tab.FindString("title");
        if (!actual || !base::MatchPattern(*actual, *title)) return true;
      }
      if (!patterns.is_empty()) {
        const auto* url = tab.FindString("url"); const auto* pending = tab.FindString("pendingUrl");
        if ((!url || !patterns.MatchesURL(GURL(*url))) && (!pending || !patterns.MatchesURL(GURL(*pending)))) return true;
      }
      return false;
    });
    return true;
  }
  static bool ValidTab(const base::Value& value) {
    return value.is_dict() && extensions::api::tabs::Tab::FromValue(value.GetDict()).has_value();
  }
  static bool ValidWindow(const base::Value& value) {
    return value.is_dict() && extensions::api::windows::Window::FromValue(value.GetDict()).has_value();
  }
  static bool ValidGroup(const base::Value& value) {
    return value.is_dict() && extensions::api::tab_groups::TabGroup::FromValue(value.GetDict()).has_value();
  }
  static bool ValidResults(const std::string& method, const base::ListValue& results) {
    if (method.starts_with("sessions.")) {
      if (results.size() != 1) return false;
      auto session = [](const base::Value& value) {
        return value.is_dict() && extensions::api::sessions::Session::FromValue(value.GetDict()).has_value() &&
            (value.GetDict().contains("tab") != value.GetDict().contains("window"));
      };
      if (method == "sessions.restore") return session(results[0]);
      if (!results[0].is_list()) return false;
      for (const auto& value : results[0].GetList()) {
        if (method == "sessions.getDevices") {
          if (!value.is_dict() || !extensions::api::sessions::Device::FromValue(value.GetDict()).has_value()) return false;
        } else if (!session(value)) return false;
      }
      return true;
    }
    if (method == "tabs.group") return results.size() == 1 && results[0].is_int() && results[0].GetInt() >= 0;
    if (method == "tabs.ungroup") return results.empty();
    if (method.starts_with("tabGroups.")) {
      if (results.size() != 1) return false;
      if (method != "tabGroups.query") return ValidGroup(results[0]);
      if (!results[0].is_list()) return false;
      for (const auto& group : results[0].GetList()) if (!ValidGroup(group)) return false;
      return true;
    }
    const bool window = method.starts_with("windows.") || method == "tabs.highlight";
    if (method == "runtime.openOptionsPage" || method == "tabs.remove" || method == "tabs.reload" || method == "tabs.goBack" || method == "tabs.goForward" ||
        method == "windows.remove" || method == "tabs.unsplit") return results.empty();
    if (method == "tabs.createSplit") return results.size() == 1 && results[0].is_int() && results[0].GetInt() >= 0;
    if (method == "tabs.getCurrent" && results.empty()) return true;
    if (results.size() != 1) return false;
    if (method == "tabs.query" || method == "tabs.getAllInWindow" || method == "windows.getAll" ||
        (method == "tabs.move" && results[0].is_list())) {
      if (!results[0].is_list()) return false;
      for (const auto& value : results[0].GetList()) if (window ? !ValidWindow(value) : !ValidTab(value)) return false;
      return true;
    }
    return window ? ValidWindow(results[0]) : ValidTab(results[0]);
  }
  struct GlobalPanel {
    std::string extension;
    base::WeakPtr<content::WebContents> contents;
  };
  void ReconcileGlobalPanels(content::WebContents* closing_contents = nullptr) {
    // Transfers may dispatch close events for a different destination panel.
    // Iterate a snapshot, then revalidate the original owner before changing it.
    const auto panels = global_panels_;
    for (const auto& [window, panel] : panels) {
      auto current = global_panels_.find(window);
      if (current == global_panels_.end() || current->second.extension != panel.extension ||
          current->second.contents.get() != panel.contents.get()) continue;
      if (!panel.contents) { global_panels_.erase(current); continue; }
      content::WebContents* destination = nullptr;
      content::WebContents* fallback = nullptr;
      for (const auto& [id, tab] : tabs_) {
        if (tab->window == window && !tab->closing && tab->web_contents() && !tab->discarded) {
          if (tab->active) { destination = tab->web_contents(); break; }
          if (!fallback && closing_contents == panel.contents.get()) fallback = tab->web_contents();
        }
      }
      if (!destination) {
        const auto parking = panel_parking_.find(window);
        if (parking != panel_parking_.end() && parking->second && !parking->second->IsBeingDestroyed())
          destination = parking->second.get();
      }
      if (!destination) destination = fallback;
      if (!destination || destination == panel.contents.get()) continue;
      auto* source_browser = extensions::browser_window_util::GetBrowserForTabContents(*panel.contents);
      auto* target_browser = extensions::browser_window_util::GetBrowserForTabContents(*destination);
      if (!source_browser || !target_browser) continue;
      auto* source = extensions::ExtensionSidePanelManager::From(source_browser);
      auto* target = extensions::ExtensionSidePanelManager::From(target_browser);
      if (source && source->TransferNativeGlobalPanel(panel.extension, target)) {
        if (panel.contents) ZacroRefreshSidePanelPresentation(panel.contents.get());
        ZacroRefreshSidePanelPresentation(destination);
        auto unchanged = global_panels_.find(window);
        if (unchanged != global_panels_.end() && unchanged->second.extension == panel.extension &&
            unchanged->second.contents.get() == panel.contents.get()) {
          global_panels_[window] = {panel.extension, destination->GetWeakPtr()};
        }
      }
    }
  }
  raw_ptr<content::BrowserContext> context_;
  bool observed_ = false;
  double revision_ = 0;
  double group_revision_ = 0;
  std::optional<int> focused_window_;
  std::optional<int> last_focused_window_;
  std::map<int, std::unique_ptr<Tab>> tabs_;
  std::map<int, GlobalPanel> global_panels_;
  // These contents own only retained extension UI. They never acquire a
  // logical tab identity, activeTab grant, or visibility in tabs/debugger APIs.
  std::map<int, base::WeakPtr<content::WebContents>> panel_parking_;
  std::map<std::string, Group> groups_;
  std::map<std::string, Reservation> reservations_;
  std::map<std::string, std::unique_ptr<Request>> pending_;
  base::WeakPtrFactory<ZacroBrowserContext> weak_{this};
};
}  // namespace

void ZacroSetTopologyObserved(content::BrowserContext* context, bool observed) {
  ZacroBrowserContext::Get(context)->SetObserved(observed);
}

bool ZacroAllowApprovedNavigation(content::WebContents* contents, const GURL& url) {
  auto& approvals = ZacroNavigationApprovals::ForDocument(contents)->destinations;
  auto found = approvals.find(url.spec());
  if (found == approvals.end()) return true; // Existing normal browser policy still applies.
  std::string error;
  return ZacroValidateNavigation(contents->GetBrowserContext(), found->second.first,
      found->second.second, url.spec(), error);
}

void ZacroInstallTopologyHooks() { ZacroBrowserContext::InstallHooks(); }

bool ZacroClaimTabReservation(content::BrowserContext* context, const std::string& token) {
  auto* state = ZacroBrowserContext::Find(context);
  return state && state->Claim(token);
}
bool ZacroResolveTabReservationOpener(content::BrowserContext* context, const std::string& token,
                                    content::WeakDocumentPtr* opener, std::optional<url::Origin>* initiator) {
  auto* state = ZacroBrowserContext::Find(context);
  return state && state->ResolveOpener(token, opener, initiator);
}
bool ZacroConsumeTabReservation(content::WebContents* contents, const std::string& token) {
  auto* state = contents ? ZacroBrowserContext::Find(contents->GetBrowserContext()) : nullptr;
  return state && state->Consume(contents, token);
}
void ZacroAbortTabReservation(content::BrowserContext* context, const std::string& token) {
  if (auto* state = ZacroBrowserContext::Find(context)) state->Abort(token);
}

bool CefDevToolsController::DispatchZacroTopology(int id, const std::string& method, const base::DictValue* params) {
  if (method != "Zacro.registerExtensionTab" && method != "Zacro.validateExtensionHostRequest" &&
      method != "Zacro.completeExtensionHostRequest" && method != "Zacro.publishBrowserEvent" &&
      method != "Zacro.synchronizeTabs" && method != "Zacro.prepareTabMaterialization" &&
      method != "Zacro.setFocusedWindow" && method != "Zacro.synchronizeGroups" &&
      method != "Zacro.authorizeHostNavigation" && method != "Zacro.validateNavigation" &&
      method != "Zacro.hasOwnedGlobalPanel" && method != "Zacro.registerPanelParking" &&
      method != "Zacro.navigateApproved") return false;
  if (!params) { ReplyZacro(id, {}, "The native browser parameters are missing."); return true; }
  auto* state = ZacroBrowserContext::Get(inspected_contents_->GetBrowserContext());
  std::string error;
  if (method == "Zacro.hasOwnedGlobalPanel" || method == "Zacro.registerPanelParking") {
    const auto window = params->FindInt("windowID");
    if (!window || *window <= 0) { ReplyZacro(id, {}, "The logical window is invalid."); return true; }
    if (method == "Zacro.hasOwnedGlobalPanel") {
      ReplyZacro(id, base::DictValue().Set("owned", state->OwnsGlobalPanel(inspected_contents_, *window)));
    } else {
      const bool registered = state->RegisterPanelParking(inspected_contents_, *window, error);
      ReplyZacro(id, base::DictValue().Set("registered", registered), error);
    }
    return true;
  }
  if (method == "Zacro.authorizeHostNavigation") {
    const auto* request = params->FindString("requestID"); const auto* url = params->FindString("url");
    auto result = request && url ? state->AuthorizeNavigation(*request, *url, error) : base::DictValue();
    if (!request || !url) error = "The navigation request or destination is missing.";
    ReplyZacro(id, std::move(result), error); return true;
  }
  if (method == "Zacro.validateNavigation" || method == "Zacro.navigateApproved") {
    const auto* extension = params->FindString("extensionID"); const auto* incarnation = params->FindString("incarnationID");
    const auto* url = params->FindString("url");
    if (!extension || !incarnation || !url || !ZacroValidateNavigation(
        inspected_contents_->GetBrowserContext(), *extension, *incarnation, *url, error)) {
      ReplyZacro(id, {}, error.empty() ? "The native navigation authorization is incomplete." : error); return true;
    }
    if (method == "Zacro.navigateApproved") {
      ZacroNavigationApprovals::ForDocument(inspected_contents_)->destinations[*url] = {*extension, *incarnation};
      inspected_contents_->GetController().LoadURL(
          GURL(*url), content::Referrer(), ui::PAGE_TRANSITION_AUTO_TOPLEVEL, std::string());
    }
    ReplyZacro(id, base::DictValue().Set("extensionID", *extension).Set("incarnationID", *incarnation).Set("url", *url)); return true;
  }
  if (method == "Zacro.synchronizeGroups") {
    auto result = state->SynchronizeGroups(*params, error);
    ReplyZacro(id, std::move(result), error); return true;
  }
  if (method == "Zacro.setFocusedWindow") {
    const auto* value = params->Find("windowID");
    const auto* last = params->Find("lastFocusedWindowID");
    if (!value || (!value->is_none() && (!value->is_int() || value->GetInt() < 1)) ||
        (last && !last->is_none() && (!last->is_int() || last->GetInt() < 1))) {
      ReplyZacro(id, {}, "The focused logical window is invalid."); return true;
    }
    state->SetFocusedWindow(value->is_int() ? std::make_optional(value->GetInt()) : std::nullopt,
        last && last->is_int() ? std::make_optional(last->GetInt()) : std::nullopt);
    ReplyZacro(id, {}); return true;
  }
  if (method == "Zacro.synchronizeTabs") {
    auto result = state->Synchronize(*params, error);
    ReplyZacro(id, std::move(result), error); return true;
  }
  if (method == "Zacro.prepareTabMaterialization") {
    const auto* logical = params->FindString("logicalID");
    const auto* opener = params->FindString("openerRequestID");
    auto result = logical ? state->Prepare(*logical, opener ? *opener : "", error) : base::DictValue();
    if (!logical) error = "The logical tab identity is missing.";
    ReplyZacro(id, std::move(result), error); return true;
  }
  if (method == "Zacro.registerExtensionTab") {
    int tab = state->Register(inspected_contents_, *params, error);
    ReplyZacro(id, base::DictValue().Set("tabID", tab), error); return true;
  }
  if (method == "Zacro.publishBrowserEvent") {
    const auto* name = params->FindString("name"); const auto* arguments = params->FindList("arguments");
    if (!name || !arguments) error = "The native browser event is invalid.";
    else state->Publish(*name, *arguments, error);
    ReplyZacro(id, {}, error); return true;
  }
  const auto* request = params->FindString("requestID");
  if (!request || !state->Validate(*request, error)) { ReplyZacro(id, {}, error.empty() ? "The native request is missing." : error); return true; }
  if (method == "Zacro.completeExtensionHostRequest") {
    const auto* results = params->FindList("results"); const auto* failure = params->FindString("error");
    if (!results) { ReplyZacro(id, {}, "The native result arguments are missing."); return true; }
    state->Complete(*request, results->Clone(), failure ? *failure : "");
  }
  ReplyZacro(id, {}); return true;
}
