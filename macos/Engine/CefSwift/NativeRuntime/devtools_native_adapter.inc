// Zacro's browser-process adapter, included by CefDevToolsController.
// This channel is reachable only through CEF's native API. It is never exposed
// as a page binding, socket, scheme handler, or extension API.
#include <algorithm>
#include <cmath>
#include <optional>
#include "base/base64.h"
#include "base/containers/flat_set.h"
#include "base/functional/bind.h"
#include "base/pickle.h"
#include "base/scoped_multi_source_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/include/views/cef_browser_view.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/extensions/browser_window_util.h"
#include "chrome/browser/extensions/native_management_operation.h"
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
#include "components/sessions/core/serialized_navigation_driver.h"
#include "content/browser/renderer_host/render_frame_host_impl.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/service_worker_context.h"
#include "content/public/browser/service_worker_running_info.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_process_host_observer.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/visibility.h"
#include "crypto/aead.h"
#include "crypto/random.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_util.h"
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
#include "cef/libcef/browser/devtools/zacro_history_adapter.inc"
#include "cef/libcef/browser/devtools/zacro_downloads_adapter.inc"
#include "cef/libcef/browser/devtools/zacro_management_adapter.inc"

namespace {
constexpr char kZacroBrowserSession[] = "zacro.native.browser.v1";
constexpr size_t kZacroMaximumHistoryBytes = 6 * 1024 * 1024;

// An optional native-only phase receipt separates installing the authenticated
// controller history from waiting for its selected document to commit. The
// caller must install its exact-browser observer before submitting this nonce.
std::optional<std::string> ZacroHistoryInstallationToken(
    const base::DictValue* params, content::WebContents* contents) {
  const auto* value = params ? params->Find("installationToken") : nullptr;
  if (!value) return std::string();
  const auto* token = value->GetIfString();
  if (!token || !base::Uuid::ParseLowercase(*token).is_valid() ||
      !CefBrowserHostBase::GetBrowserForContents(contents)) return std::nullopt;
  return *token;
}

base::DictValue ZacroHistoryInstallationReceipt(
    content::WebContents* contents, const std::string& token) {
  auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
  CHECK(browser);
  return base::DictValue().Set("token", token)
      .Set("browserID", browser->GetIdentifier());
}

std::string ZacroHistoryBinding(content::WebContents* contents) {
  return "zacro.navigation.v2:" +
      contents->GetBrowserContext()->GetPath().AsUTF8Unsafe();
}

bool ZacroRestorableURL(const GURL& url, content::BrowserContext* context) {
  if (!url.is_valid() || url.spec().size() > kZacroMaximumNavigationURLBytes ||
      url.has_username() || url.has_password()) return false;
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

bool ZacroDocumentCanDiscard(content::WebContents* contents) {
  return contents && contents->GetVisibility() == content::Visibility::HIDDEN &&
      !contents->IsLoading() && !contents->IsCurrentlyAudible() &&
      !contents->IsBeingCaptured() &&
      !contents->NeedToFireBeforeUnloadOrUnloadEvents() &&
      !contents->GetController().GetPendingEntry() &&
      !DevToolsWindow::GetInstanceForInspectedWebContents(contents) &&
      !ZacroHasExtensionUI(contents) &&
      contents->GetBrowserContext()->GetDownloadManager()->InProgressCount() == 0;
}

bool ZacroHasSidePanel(content::WebContents* contents) {
  auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*contents);
  auto* panel = browser ? SidePanelUI::From(browser) : nullptr;
  return panel && panel->IsSidePanelShowing();
}

base::DictValue ZacroDocumentBounds(content::WebContents* contents) {
  auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
  auto view = browser ? CefBrowserView::GetForBrowser(browser) : nullptr;
  if (!view) return {};
  const auto viewport = view->GetBoundsInScreen();
  auto bounds = contents->GetContainerBounds();
  bounds.Intersect(gfx::Rect(viewport.x, viewport.y, viewport.width, viewport.height));
  if (bounds.IsEmpty()) return {};
  bounds.Offset(-viewport.x, -viewport.y);
  return base::DictValue().Set("x", bounds.x()).Set("y", bounds.y())
      .Set("width", bounds.width()).Set("height", bounds.height());
}

bool ZacroHistoryApproval(const GURL& url, content::BrowserContext* context,
    std::string& extension, std::string& incarnation, content::WebContents* contents = nullptr) {
  if (ZacroRestorableURL(url, context)) return true;
  auto& approvals = (contents ? ZacroNavigationApprovals::ForDocument(contents) : ZacroNavigationApprovals::Get(context))->destinations;
  const auto found = approvals.find(ZacroNavigationApprovals::Key(url.spec()));
  if (found == approvals.end()) return false;
  extension = found->second.first; incarnation = found->second.second;
  std::string error;
  return ZacroValidateNavigation(context, extension, incarnation, url.spec(), error);
}

bool ZacroWriteNavigationEntry(const sessions::SerializedNavigationEntry& entry,
                               base::Pickle* pickle) {
  // Chromium's session writer silently writes an empty string when its string
  // budget is exceeded. Never claim an encrypted capture succeeded after it
  // dropped a URL, form PageState, title or referrer. Count the same sanitized
  // fields as the pinned writer, then enforce the entire envelope budget too.
  constexpr size_t limit = kZacroMaximumHistoryBytes - 4096;
  if (pickle->size() >= limit) return false;
  size_t bytes = pickle->size();
  const auto fits = [&bytes](size_t count) {
    if (count >= limit - bytes) return false;
    bytes += count; return true;
  };
  if (entry.title().size() >= limit / sizeof(char16_t) ||
      !fits(entry.virtual_url().spec().size()) ||
      !fits(entry.title().size() * sizeof(char16_t)) ||
      !fits(sessions::SerializedNavigationDriver::Get()
          ->GetSanitizedPageStateForPickle(&entry).size()) ||
      !fits(entry.referrer_url().spec().size()) ||
      !fits(entry.original_request_url().is_valid() ? entry.original_request_url().spec().size() : 0)) return false;
  for (const auto& [key, value] : entry.extended_info_map()) {
    if (!fits(key.size()) || !fits(value.size())) return false;
  }
  entry.WriteToPickle(static_cast<int>(limit), pickle);
  return pickle->size() < limit;
}
}

void ZacroRefreshSidePanelPresentation(content::WebContents* contents) {
  auto* browser = extensions::browser_window_util::GetBrowserForTabContents(*contents);
  auto* panel = browser ? SidePanelUI::From(browser) : nullptr;
  const bool showing = panel && panel->IsSidePanelShowing();
  // Keep the blank renderer suppressed through the close event. Swift will
  // hide the child window on its next layout turn; restoring it here would
  // expose a white frame between native close and that layout.
  const auto* entry = contents->GetController().GetLastCommittedEntry();
  if (panel) panel->SetNativeEmptyContentHidden(contents->GetLastCommittedURL() == GURL("about:blank") ||
      contents->IsCrashed() || (entry && entry->GetPageType() == content::PAGE_TYPE_ERROR));
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
      base::RepeatingCallback<void(bool)> audio, base::RepeatingCallback<void(bool)> panel,
      base::RepeatingCallback<void(base::DictValue)> bounds)
      : content::WebContentsObserver(contents), audio_(std::move(audio)), panel_(std::move(panel)),
        bounds_(std::move(bounds)) {
    subscription_ = ZacroExtensionContext::Get(contents->GetBrowserContext())->Observe(base::BindRepeating(
        [](ZacroDocumentObserver* observer, const std::string& method, const base::DictValue& params) {
          if (method == "Zacro.extensionPanelPresentation" && observer->web_contents() &&
              params.FindInt("tabID") == sessions::SessionTabHelper::IdForTab(observer->web_contents()).id()) {
            const auto alive = observer->weak_.GetWeakPtr();
            observer->panel_.Run(params.FindBool("visible").value_or(false));
            if (alive) alive->ReportBounds();
          }
        }, base::Unretained(this)));
  }
  void OnAudioStateChanged(bool audible) override { audio_.Run(audible); }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() && handle->HasCommitted()) {
      const auto alive = weak_.GetWeakPtr();
      ZacroRefreshSidePanelPresentation(web_contents());
      if (alive) alive->ReportBounds();
    }
  }
  void PrimaryMainFrameWasResized(bool width_changed) override { ReportBounds(); }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    const auto alive = weak_.GetWeakPtr();
    ZacroRefreshSidePanelPresentation(web_contents());
    if (alive) alive->ReportBounds();
  }
 private:
  void ReportBounds() {
    if (web_contents()) bounds_.Run(ZacroDocumentBounds(web_contents()));
  }
  base::RepeatingCallback<void(bool)> audio_;
  base::RepeatingCallback<void(bool)> panel_;
  base::RepeatingCallback<void(base::DictValue)> bounds_;
  base::CallbackListSubscription subscription_;
  base::WeakPtrFactory<ZacroDocumentObserver> weak_{this};
};

// Correlate a native host operation with its actual primary navigation, not
// loading-state notifications or a URL string which can still describe blank.
class ZacroNavigationCommit : public content::WebContentsObserver {
 public:
  ZacroNavigationCommit(content::WebContents* contents, const GURL& expected,
      base::OnceCallback<void(const std::string&)> completion)
      : content::WebContentsObserver(contents), expected_(expected),
        previous_document_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        completion_(std::move(completion)) {
    timer_.Start(FROM_HERE, base::Seconds(45), base::BindOnce(
        &ZacroNavigationCommit::Finish, base::Unretained(this),
        "The requested document did not commit in time."));
  }
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->IsInPrimaryMainFrame()) return;
    if (navigation_id_ || navigation->GetURL() != expected_) {
      Finish("The requested navigation was replaced before it committed."); return;
    }
    navigation_id_ = navigation->GetNavigationId();
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->IsInPrimaryMainFrame() || navigation->GetNavigationId() != navigation_id_) return;
    if (!navigation->HasCommitted() || navigation->IsErrorPage()) {
      Finish("The requested navigation failed or was cancelled."); return;
    }
    if (!navigation->IsSameDocument() &&
        previous_document_.AsRenderFrameHostIfValid() == web_contents()->GetPrimaryMainFrame()) {
      Finish("The original document is still active."); return;
    }
    Finish({});
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    Finish("The document renderer stopped before navigation committed.");
  }
  void WebContentsDestroyed() override { Finish("The document closed before navigation committed."); }
 private:
  void Finish(const std::string& error) {
    timer_.Stop();
    Observe(nullptr);
    // Completion deletes this observer. Never access members afterwards.
    if (completion_) std::move(completion_).Run(error);
  }
  GURL expected_;
  content::WeakDocumentPtr previous_document_;
  int64_t navigation_id_ = 0;
  base::OnceCallback<void(const std::string&)> completion_;
  base::OneShotTimer timer_;
};

bool CefDevToolsController::StartZacroNavigationCommit(int id, const GURL& expected, base::DictValue result) {
  if (zacro_navigation_commit_) {
    ReplyZacro(id, {}, "A native document restoration is already in progress."); return false;
  }
  zacro_navigation_commit_ = std::make_unique<ZacroNavigationCommit>(inspected_contents_, expected,
      base::BindOnce(&CefDevToolsController::FinishZacroNavigationCommit, weak_ptr_factory_.GetWeakPtr(), id, std::move(result)));
  return true;
}
void CefDevToolsController::FinishZacroNavigationCommit(int id, base::DictValue result, const std::string& error) {
  zacro_navigation_commit_.reset();
  ReplyZacro(id, error.empty() ? std::move(result) : base::DictValue(), error);
}

// PageState updates are delayed in hidden renderers, and the outgoing RFH's
// update can arrive after a new primary document commits. Gather explicit
// associated-channel acknowledgements from active and BFCache documents before
// reading NavigationEntries. Renderer/document loss fails rather than saving a
// snapshot which is merely assumed current.
class ZacroNavigationCaptureOperation : public content::WebContentsObserver,
    public content::RenderProcessHostObserver {
 public:
  ZacroNavigationCaptureOperation(content::WebContents* contents,
      base::OnceCallback<void(bool, std::string)> completion)
      : content::WebContentsObserver(contents), completion_(std::move(completion)),
        primary_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()) {}
  void Start() {
    auto& controller = web_contents()->GetController();
    if (controller.GetPendingEntry()) {
      Finish(false, "Navigation is still committing; retry history capture."); return;
    }
    selected_ = controller.GetLastCommittedEntryIndex();
    for (int index = 0; index < controller.GetEntryCount(); ++index)
      entries_.push_back(controller.GetEntryAtIndex(index)->GetUniqueID());
    std::vector<content::WeakDocumentPtr> documents;
    bool too_many = false;
    bool dead = false;
    // WebContents' traversal omits pending-deletion RFHs. Include them only to
    // await an outgoing document's final UpdateState/unload ACK. Chromium sends
    // state before the associated unload acknowledgement removes that frame.
    auto gather = [&](content::RenderFrameHost* frame) {
      if (content::WebContents::FromRenderFrameHost(frame) != web_contents()) return;
      auto* host = static_cast<content::RenderFrameHostImpl*>(frame);
      if (std::ranges::find(entries_, host->nav_entry_id()) == entries_.end()) return;
      if (!frame->IsRenderFrameLive()) { dead = true; return; }
      if (!host->IsPendingDeletion() && !frame->IsActive() && !frame->IsInLifecycleState(
          content::RenderFrameHost::LifecycleState::kInBackForwardCache)) return;
      if (!processes_.IsObservingSource(frame->GetProcess()))
        processes_.AddObservation(frame->GetProcess());
      if (pending_.size() >= 4096) { too_many = true; return; }
      if (host->IsPendingDeletion()) {
        pending_.insert(frame->GetGlobalId());
        unloading_.insert(frame->GetGlobalId());
        return;
      }
      if (documents.size() >= 4096) { too_many = true; return; }
      documents.push_back(frame->GetWeakDocumentPtr());
      pending_.insert(frame->GetGlobalId());
    };
    for (auto processes = content::RenderProcessHost::AllHostsIterator();
         !processes.IsAtEnd(); processes.Advance()) {
      auto* process = processes.GetCurrentValue();
      if (process->GetBrowserContext() == web_contents()->GetBrowserContext())
        process->ForEachRenderFrameHost(gather);
    }
    if (dead) {
      Finish(false, "A history renderer stopped before confirming its state."); return;
    }
    if (too_many) { Finish(false, "Navigation history exceeds the supported frame count."); return; }
    if (pending_.empty()) {
      Finish(false, "No live document can confirm the current navigation state."); return;
    }
    timer_.Start(FROM_HERE, base::Seconds(10), base::BindOnce(
        &ZacroNavigationCaptureOperation::Finish, weak_.GetWeakPtr(), false,
        "The document did not confirm its current navigation state in time."));
    for (const auto& document : documents) {
      auto* frame = document.AsRenderFrameHostIfValid();
      if (!frame) { Finish(false, "A history document changed before capture."); return; }
      const auto alive = weak_.GetWeakPtr();
      static_cast<content::RenderFrameHostImpl*>(frame)->FlushStateForNativeNavigation(
          base::BindOnce(&ZacroNavigationCaptureOperation::Flushed, alive, frame->GetGlobalId()));
      // An already-frozen frame can acknowledge synchronously. The final ACK
      // deletes this operation through its completion callback.
      if (!alive) return;
    }
  }
  void DidStartNavigation(content::NavigationHandle*) override {
    Finish(false, "The document navigated during history capture.");
  }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (unloading_.erase(frame->GetGlobalId())) {
      RemovePending(frame->GetGlobalId());
      MaybeFinish();
    } else if (pending_.contains(frame->GetGlobalId())) {
      Finish(false, "A history document closed before confirming its state.");
    }
  }
  void RenderProcessExited(content::RenderProcessHost*,
      const content::ChildProcessTerminationInfo&) override {
    Finish(false, "A history renderer stopped before confirming its state.");
  }
  void InProcessRendererExiting(content::RenderProcessHost*) override {
    Finish(false, "A history renderer stopped before confirming its state.");
  }
  void RenderProcessHostDestroyed(content::RenderProcessHost* host) override {
    processes_.RemoveObservation(host);
    Finish(false, "A history renderer closed before confirming its state.");
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    Finish(false, "The document renderer stopped during history capture.");
  }
  void WebContentsDestroyed() override { Finish(false, "The document closed during history capture."); }
 private:
  void Flushed(content::GlobalRenderFrameHostId frame, bool captured) {
    if (!captured) { Finish(false, "A history document changed before confirming its state."); return; }
    RemovePending(frame);
    MaybeFinish();
  }
  void RemovePending(content::GlobalRenderFrameHostId frame) {
    pending_.erase(frame);
    if (std::ranges::any_of(pending_, [&](const auto& id) { return id.child_id == frame.child_id; })) return;
    if (auto* process = content::RenderProcessHost::FromID(frame.child_id);
        process && processes_.IsObservingSource(process)) {
      // The last ordered ACK from this process is durable in the controller.
      // Its later normal exit cannot invalidate other renderers' pending ACKs.
      processes_.RemoveObservation(process);
    }
  }
  void MaybeFinish() {
    if (!pending_.empty()) return;
    auto& controller = web_contents()->GetController();
    bool unchanged = !controller.GetPendingEntry() &&
        primary_.AsRenderFrameHostIfValid() == web_contents()->GetPrimaryMainFrame() &&
        selected_ == controller.GetLastCommittedEntryIndex() &&
        entries_.size() == static_cast<size_t>(controller.GetEntryCount());
    for (int index = 0; unchanged && index < controller.GetEntryCount(); ++index)
      unchanged = entries_[index] == controller.GetEntryAtIndex(index)->GetUniqueID();
    Finish(unchanged, unchanged ? std::string() : "Navigation history changed during capture.");
  }
  void Finish(bool captured, std::string error) {
    timer_.Stop(); Observe(nullptr); processes_.RemoveAllObservations(); weak_.InvalidateWeakPtrs();
    // Completion deletes this observer. Never access members afterwards.
    if (completion_) std::move(completion_).Run(captured, std::move(error));
  }
  base::OnceCallback<void(bool, std::string)> completion_;
  content::WeakDocumentPtr primary_;
  std::vector<int> entries_;
  base::flat_set<content::GlobalRenderFrameHostId> pending_;
  base::flat_set<content::GlobalRenderFrameHostId> unloading_;
  base::ScopedMultiSourceObservation<content::RenderProcessHost,
      content::RenderProcessHostObserver> processes_{this};
  int selected_ = -1;
  base::OneShotTimer timer_;
  base::WeakPtrFactory<ZacroNavigationCaptureOperation> weak_{this};
};

void CefDevToolsController::FinishZacroNavigationCapture(int id, bool captured, std::string error) {
  zacro_navigation_capture_.reset();
  if (!captured) { ReplyZacro(id, {}, error); return; }
  SerializeZacroNavigation(id);
}

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

void CefDevToolsController::FinishZacroDiscardCapture(int id, bool captured, std::string error) {
  zacro_navigation_capture_.reset();
  if (!captured) {
    ReplyZacro(id, {}, error.empty() ? "The document did not confirm its current navigation state." : error);
    return;
  }
  // Visibility, media, beforeunload, authentication-related loads, extension
  // UI and downloads can change while renderer acknowledgements are pending.
  // A failed preflight must leave the live page and older retained buffer alone.
  if (zacro_navigation_commit_ || zacro_discard_ ||
      !ZacroDocumentCanDiscard(inspected_contents_)) {
    ReplyZacro(id, {}, "The document became active and cannot be put to sleep."); return;
  }
  auto& controller = inspected_contents_->GetController();
  const int count = controller.GetEntryCount();
  const int selected = controller.GetLastCommittedEntryIndex();
  if (count < 1 || count > 500 || selected < 0 || selected >= count) {
    ReplyZacro(id, {}, "The document history cannot be retained safely."); return;
  }
  std::vector<sessions::SerializedNavigationEntry> retained;
  retained.reserve(count);
  size_t retained_bytes = 0;
  for (int index = 0; index < count; ++index) {
    auto* entry = controller.GetEntryAtIndex(index);
    std::string extension, incarnation;
    if (!ZacroHistoryApproval(entry->GetVirtualURL(), inspected_contents_->GetBrowserContext(),
                              extension, incarnation, inspected_contents_)) {
      ReplyZacro(id, {}, "The document history contains an unsupported address."); return;
    }
    auto saved = sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(index, entry);
    const size_t bytes = sizeof(saved) + saved.EstimateMemoryUsage();
    if (bytes > kZacroMaximumHistoryBytes - retained_bytes) {
      ReplyZacro(id, {}, "The retained navigation state exceeds the supported size."); return;
    }
    retained_bytes += bytes;
    retained.push_back(std::move(saved));
  }
  // No await or user callback separates this assignment from native discard.
  // Nothing is exported or written to disk, including for private profiles.
  zacro_dormant_history_ = std::move(retained);
  zacro_dormant_selected_ = selected;
  zacro_discard_ = std::make_unique<ZacroDiscardOperation>(inspected_contents_,
      base::BindOnce(&CefDevToolsController::FinishZacroDiscard,
                     weak_ptr_factory_.GetWeakPtr(), id));
  zacro_discard_->Start();
}

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
          }, weak_ptr_factory_.GetWeakPtr()), base::BindRepeating(
          [](base::WeakPtr<CefDevToolsController> self, base::DictValue bounds) {
            if (self) self->EmitZacro("Zacro.documentBoundsChanged", base::DictValue().Set("bounds", std::move(bounds)));
          }, weak_ptr_factory_.GetWeakPtr()));
    }
    ReplyZacro(*id, base::DictValue().Set("audible", inspected_contents_->IsCurrentlyAudible())
        .Set("sidePanelVisible", ZacroHasSidePanel(inspected_contents_))
        .Set("bounds", ZacroDocumentBounds(inspected_contents_))); return true;
  }
  if (DispatchZacroTopology(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroExtensions(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroBookmarks(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroHistory(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroDownloads(*id, *method, request->FindDict("params"))) return true;
  if (DispatchZacroManagement(*id, *method, request->FindDict("params"))) return true;
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
        .Set("encryptedNavigation", true).Set("retainedDiscard", true).Set("historyInstallation", true)
        .Set("extensionActions", true).Set("legacyNavigation", true).Set("extensionStorage", true).Set("extensionBrowser", true)
        .Set("volatileDiscard", true).Set("bookmarks", true).Set("historyRemoval", true)
        .Set("historyMirror", true).Set("downloads", true));
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
    std::string target, worker_token;
    // A DevTools target/context exists before ServiceWorkerGlobalScope has a
    // URL. Evaluating then can fail inside Blink's promise rejection handler.
    // OnStarted (and this running table) follows real script evaluation; do not
    // infer readiness from target URL, Runtime.enable, or JavaScript probes.
    auto* workers = extensions::util::GetServiceWorkerContextForExtensionId(
        extension->id(), context);
    if (workers) for (const auto& [version, info] : workers->GetRunningServiceWorkerInfos()) {
      if (info.script_url != script || !workers->IsLiveRunningServiceWorker(version) ||
          !workers->IsLiveServiceWorkerWithToken(version, info.token)) continue;
      auto host = content::DevToolsAgentHost::GetForServiceWorker(workers, version);
      if (!host || host->GetBrowserContext() != context ||
          host->GetType() != content::DevToolsAgentHost::kTypeServiceWorker || host->GetURL() != script) continue;
      if (!target.empty()) { ReplyZacro(*id, {}, "The extension worker is changing; retry after it settles."); return true; }
      target = host->GetId(); worker_token = info.token.ToString();
    }
    auto result = base::DictValue().Set("installationID", ZacroExtensionContext::Get(context)->InstallationID(*extension));
    if (!target.empty()) { result.Set("targetID", target); result.Set("workerToken", worker_token); }
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
  if (*method == "Zacro.loadAndWaitForNavigationCommit") {
    const auto* params = request->FindDict("params");
    const auto* address = params ? params->FindString("url") : nullptr;
    const GURL url(address ? *address : "");
    auto browser = CefBrowserHostBase::GetBrowserForContents(inspected_contents_);
    if (!address || address->size() > kZacroMaximumNavigationURLBytes || !ZacroRestorableURL(url, inspected_contents_->GetBrowserContext()) || !browser) {
      ReplyZacro(*id, {}, "This document destination is invalid or unavailable."); return true;
    }
    auto& controller = inspected_contents_->GetController();
    if (zacro_navigation_commit_) {
      ReplyZacro(*id, {}, "A native document restoration is already in progress."); return true;
    }
    if (url == GURL("about:blank") && controller.GetLastCommittedEntry()->IsInitialEntry() &&
        !controller.GetPendingEntry() && !inspected_contents_->IsLoading() &&
        inspected_contents_->GetPrimaryMainFrame()->IsRenderFrameLive() &&
        inspected_contents_->GetLastCommittedURL() == url) {
      ReplyZacro(*id, base::DictValue().Set("committed", true)); return true;
    }
    if (StartZacroNavigationCommit(*id, url, base::DictValue().Set("committed", true)))
      browser->GetMainFrame()->LoadURL(url.spec());
    return true;
  }
  if (*method == "Zacro.restoreNavigationEntries") {
    const auto* params = request->FindDict("params");
    const auto installation_token = ZacroHistoryInstallationToken(params, inspected_contents_);
    if (!installation_token) { ReplyZacro(*id, {}, "Invalid native history installation token."); return true; }
    const auto* items = params ? params->FindList("entries") : nullptr;
    const auto selected = params ? params->FindInt("selectedIndex") : std::nullopt;
    auto& controller = inspected_contents_->GetController();
    if (zacro_navigation_commit_ || !items || items->empty() || items->size() > 500 || !selected || *selected < 0 ||
        static_cast<size_t>(*selected) >= items->size() || !controller.GetLastCommittedEntry()->IsInitialEntry() || controller.GetPendingEntry()) {
      ReplyZacro(*id, {}, "Legacy history can only restore a fresh initial document."); return true;
    }
    std::vector<sessions::SerializedNavigationEntry> serialized;
    for (const auto& value : *items) {
      const auto* item = value.GetIfDict();
      const auto* url = item ? item->FindString("url") : nullptr;
      const auto* title = item ? item->FindString("title") : nullptr;
      std::string extension, incarnation;
      if (!url || url->size() > kZacroMaximumNavigationURLBytes || !title || title->size() > 8192 ||
          !ZacroHistoryApproval(GURL(*url), inspected_contents_->GetBrowserContext(), extension, incarnation)) {
        ReplyZacro(*id, {}, "Legacy navigation contains an invalid entry."); return true;
      }
      if (!extension.empty()) ZacroNavigationApprovals::ForDocument(inspected_contents_)->destinations[ZacroNavigationApprovals::Key(*url)] = {extension, incarnation};
      sessions::SerializedNavigationEntry entry;
      entry.set_index(serialized.size()); entry.set_virtual_url(GURL(*url)); entry.set_title(base::UTF8ToUTF16(*title));
      serialized.push_back(std::move(entry));
    }
    auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(serialized, inspected_contents_->GetBrowserContext());
    controller.Restore(*selected, content::RestoreType::kRestored, &entries);
    if (StartZacroNavigationCommit(*id, controller.GetLastCommittedEntry()->GetURL(),
        base::DictValue().Set("restored", true))) {
      if (!installation_token->empty()) EmitZacro("Zacro.navigationHistoryInstalled",
          ZacroHistoryInstallationReceipt(inspected_contents_, *installation_token));
      controller.LoadIfNecessary();
    }
    return true;
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
        .Set("navigationPending", zacro_navigation_commit_ != nullptr)
        .Set("bounds", ZacroDocumentBounds(inspected_contents_))
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
    if (zacro_navigation_capture_ || zacro_navigation_commit_ || zacro_discard_ ||
        !ZacroDocumentCanDiscard(inspected_contents_)) {
      ReplyZacro(*id, {}, "The document is in use and cannot be put to sleep."); return true;
    }
    const int count = inspected_contents_->GetController().GetEntryCount();
    if (count < 1 || count > 500) {
      ReplyZacro(*id, {}, "The document history cannot be retained safely."); return true;
    }
    // Private documents cannot use encrypted capture, but their in-memory
    // back/forward history requires the same ordered renderer state barrier.
    // Reuse the capture lane so concurrent capture/discard cannot overlap.
    zacro_navigation_capture_ = std::make_unique<ZacroNavigationCaptureOperation>(inspected_contents_,
        base::BindOnce(&CefDevToolsController::FinishZacroDiscardCapture,
                       weak_ptr_factory_.GetWeakPtr(), *id));
    zacro_navigation_capture_->Start();
    return true;
  }
  if (*method == "Zacro.restoreDiscardedDocument") {
    const auto installation_token = ZacroHistoryInstallationToken(request->FindDict("params"), inspected_contents_);
    if (!installation_token) { ReplyZacro(*id, {}, "Invalid native history installation token."); return true; }
    auto& controller = inspected_contents_->GetController();
    if (zacro_navigation_commit_ || zacro_dormant_history_.empty() || zacro_discard_ || controller.GetEntryCount() != 1 ||
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
    if (StartZacroNavigationCommit(*id, controller.GetLastCommittedEntry()->GetURL(),
        base::DictValue().Set("restored", true))) {
      if (!installation_token->empty()) EmitZacro("Zacro.navigationHistoryInstalled",
          ZacroHistoryInstallationReceipt(inspected_contents_, *installation_token));
      controller.LoadIfNecessary();
    }
    return true;
  }
  if (*method == "Zacro.serializeNavigation") {
    if (inspected_contents_->GetBrowserContext()->IsOffTheRecord()) {
      ReplyZacro(*id, {}, "Private navigation state cannot be persisted."); return true;
    }
    if (zacro_navigation_capture_ || zacro_navigation_commit_ || zacro_discard_) {
      ReplyZacro(*id, {}, "A native navigation operation is already in progress."); return true;
    }
    const int count = inspected_contents_->GetController().GetEntryCount();
    if (count < 1 || count > 500) {
      ReplyZacro(*id, {}, "Navigation history exceeds the supported entry count."); return true;
    }
    zacro_navigation_capture_ = std::make_unique<ZacroNavigationCaptureOperation>(inspected_contents_,
        base::BindOnce(&CefDevToolsController::FinishZacroNavigationCapture, weak_ptr_factory_.GetWeakPtr(), *id));
    zacro_navigation_capture_->Start();
    return true;
  }
  if (*method == "Zacro.restoreNavigation") {
    const auto* params = request->FindDict("params");
    const auto installation_token = ZacroHistoryInstallationToken(params, inspected_contents_);
    if (!installation_token) { ReplyZacro(*id, {}, "Invalid native history installation token."); return true; }
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
           std::string installation_token, std::string wrapped_key, std::string nonce, std::string ciphertext,
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
            if (!extension.empty()) ZacroNavigationApprovals::ForDocument(self->inspected_contents_)->destinations[ZacroNavigationApprovals::Key(entry.virtual_url().spec())] = {extension, incarnation};
            saved.push_back(std::move(entry));
          }
          auto& controller = self->inspected_contents_->GetController();
          const bool initial = controller.GetLastCommittedEntry()->IsInitialEntry();
          const bool dormant = self->zacro_dormant_entry_ > 0 && controller.GetEntryCount() == 1 &&
              controller.GetLastCommittedEntry()->GetUniqueID() == self->zacro_dormant_entry_ &&
              self->inspected_contents_->GetLastCommittedURL() == GURL("about:blank") &&
              !self->inspected_contents_->IsLoading();
          if (self->zacro_navigation_commit_ || !iterator.ReachedEnd() || controller.GetPendingEntry() || (!initial && !dormant)) {
            self->ReplyZacro(id, {}, "Restore requires a fresh document with no navigation in progress."); return;
          }
          auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(saved, context);
          controller.Restore(selected + (dormant ? 1 : 0), content::RestoreType::kRestored, &entries);
          if (dormant) {
            CHECK(controller.RemoveEntryAtIndex(0));
            self->zacro_dormant_entry_ = 0;
            self->zacro_dormant_history_.clear();
          }
          if (self->StartZacroNavigationCommit(id, controller.GetLastCommittedEntry()->GetURL(),
              base::DictValue().Set("restored", true))) {
            if (!installation_token.empty()) self->EmitZacro("Zacro.navigationHistoryInstalled",
                ZacroHistoryInstallationReceipt(self->inspected_contents_, installation_token));
            controller.LoadIfNecessary();
          }
        }, weak_ptr_factory_.GetWeakPtr(), *id, *installation_token, std::move(wrapped_key), std::move(nonce), std::move(ciphertext)));
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

void CefDevToolsController::SerializeZacroNavigation(int id) {
    if (inspected_contents_->GetBrowserContext()->IsOffTheRecord()) {
      ReplyZacro(id, {}, "Private navigation state cannot be persisted."); return;
    }
    auto& controller = inspected_contents_->GetController();
    const int count = controller.GetEntryCount();
    if (count < 1 || count > 500) {
      ReplyZacro(id, {}, "Navigation history exceeds the supported entry count."); return;
    }
    base::Pickle pickle;
    pickle.WriteInt(2);
    pickle.WriteInt(controller.GetLastCommittedEntryIndex());
    pickle.WriteInt(count);
    for (int index = 0; index < count; ++index) {
      std::string extension, incarnation;
      if (!ZacroHistoryApproval(controller.GetEntryAtIndex(index)->GetVirtualURL(),
                             inspected_contents_->GetBrowserContext(), extension, incarnation, inspected_contents_)) {
        ReplyZacro(id, {}, "This navigation contains a non-restorable browser URL."); return;
      }
      auto entry = sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(
          index, controller.GetEntryAtIndex(index));
      if (!ZacroWriteNavigationEntry(entry, &pickle)) {
        ReplyZacro(id, {}, "Navigation state exceeds the supported size; no partial history was saved."); return;
      }
      pickle.WriteString(extension); pickle.WriteString(incarnation);
      if (pickle.size() > kZacroMaximumHistoryBytes - 4096) {
        ReplyZacro(id, {}, "Navigation state exceeds the supported size."); return;
      }
    }
    auto* crypt = g_browser_process ? g_browser_process->os_crypt_async() : nullptr;
    if (!crypt) { ReplyZacro(id, {}, "Native navigation encryption is unavailable."); return; }
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
        }, weak_ptr_factory_.GetWeakPtr(), id,
        std::string(pickle.AsStringView()), ZacroHistoryBinding(inspected_contents_)));
}
