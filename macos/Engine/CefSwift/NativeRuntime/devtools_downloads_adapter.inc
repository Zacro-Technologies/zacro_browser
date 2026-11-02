// Profile-wide observation includes extension workers and downloads whose
// originating WebContents has already closed. Chromium retains all file policy.
#include "content/public/browser/download_item_utils.h"

class ZacroDownloadContext : public base::SupportsUserData::Data,
                             public content::DownloadManager::Observer,
                             public download::DownloadItem::Observer {
 public:
  static ZacroDownloadContext* Get(content::BrowserContext* context) {
    constexpr char key[] = "zacro.native.downloads";
    if (auto* value = context->GetUserData(key)) return static_cast<ZacroDownloadContext*>(value);
    auto value = std::make_unique<ZacroDownloadContext>(context);
    auto* result = value.get(); context->SetUserData(key, std::move(value)); return result;
  }
  explicit ZacroDownloadContext(content::BrowserContext* context) : context_(context), manager_(context->GetDownloadManager()) {
    if (!manager_) return;
    manager_->AddObserver(this);
    download::SimpleDownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items); manager_->GetUninitializedActiveDownloadsIfAny(&items);
    for (const auto& item : items) Watch(item);
  }
  ~ZacroDownloadContext() override {
    if (manager_) manager_->RemoveObserver(this);
    for (const auto& item : items_) item->RemoveObserver(this);
  }
  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override {
    Watch(item);
    if (retiring_) CancelForRetirement(item); else Updated(item);
  }
  void OnDownloadUpdated(download::DownloadItem* item) override {
    if (retiring_) CancelForRetirement(item); else Updated(item);
  }
  void OnDownloadRemoved(download::DownloadItem* item) override {
    if (retiring_ || context_->IsOffTheRecord()) return;
    ZacroExtensionContext::Get(context_)->NotifyNative("Zacro.downloadRemoved", base::DictValue().Set("guid", item->GetGuid()));
  }
  void OnDownloadDestroyed(download::DownloadItem* item) override { item->RemoveObserver(this); items_.erase(item); }
  void ManagerGoingDown(content::DownloadManager* manager) override {
    manager->RemoveObserver(this); manager_ = nullptr;
    for (const auto& item : items_) item->RemoveObserver(this);
    items_.clear();
  }
  void OnManagerInitialized() override {
    if (!manager_) return;
    if (retiring_) { std::string error; RetirementStatus(error); return; }
    download::SimpleDownloadManager::DownloadVector items; manager_->GetAllDownloads(&items);
    for (const auto& item : items) { Watch(item); Updated(item); }
  }
  base::DictValue Snapshot() {
    std::vector<download::DownloadItem*> ordered;
    for (const auto& item : items_) ordered.push_back(item);
    std::stable_sort(ordered.begin(), ordered.end(), [](auto* a, auto* b) {
      const bool active_a = a->GetState() == download::DownloadItem::IN_PROGRESS;
      const bool active_b = b->GetState() == download::DownloadItem::IN_PROGRESS;
      return active_a != active_b ? active_a : a->GetStartTime() > b->GetStartTime();
    });
    base::ListValue values;
    const size_t limit = std::min<size_t>(ordered.size(), 20000);
    for (size_t i = 0; i < limit; ++i) values.Append(Describe(ordered[i]));
    return base::DictValue().Set("downloads", std::move(values)).Set("total", static_cast<double>(ordered.size()))
        .Set("complete", limit == ordered.size());
  }
  // Terminal for this native BrowserContext. Call only after authoritative
  // profile deletion/private-owner retirement commits, never before a close
  // veto can still leave the profile active. The fence outlives this transport.
  base::DictValue RetirementStatus(std::string& error) {
    retiring_ = true;
    if (!manager_) { error = "The native download manager closed before retirement settled."; return {}; }
    download::SimpleDownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items);
    manager_->GetUninitializedActiveDownloadsIfAny(&items);
    std::set<std::string> guids;
    for (const auto& item : items) guids.insert(item->GetGuid());
    // Cancel can synchronously notify observers/remove items. Retain identities
    // rather than raw DownloadItem pointers across any such callback.
    for (const auto& guid : guids) {
      if (!manager_) { error = "The native download manager closed during retirement."; return {}; }
      if (auto* item = manager_->GetDownloadByGuid(guid)) { Watch(item); CancelForRetirement(item); }
    }
    if (!manager_) { error = "The native download manager closed during retirement."; return {}; }
    // Cancellation observers may have created another item. Count a fresh
    // snapshot, including restored entries that have not initialized yet.
    items.clear(); manager_->GetAllDownloads(&items);
    manager_->GetUninitializedActiveDownloadsIfAny(&items);
    std::set<std::string> pending;
    for (const auto& item : items) {
      if (item->GetState() != download::DownloadItem::COMPLETE &&
          item->GetState() != download::DownloadItem::CANCELLED) pending.insert(item->GetGuid());
    }
    const bool initialized = manager_->IsManagerInitialized();
    return base::DictValue().Set("retiring", true).Set("initialized", initialized)
        .Set("pending", static_cast<double>(pending.size())).Set("settled", initialized && pending.empty());
  }
  base::DictValue Control(const base::DictValue* params, std::string& error) {
    if (retiring_) { error = "This native profile is being retired."; return {}; }
    const auto* guid = params ? params->FindString("guid") : nullptr;
    const auto* action = params ? params->FindString("action") : nullptr;
    auto* item = manager_ && guid ? manager_->GetDownloadByGuid(*guid) : nullptr;
    if (!item || !action) { error = "The native download is no longer available."; return {}; }
    // Never bypass danger/insecure-download approval or rename destination
    // handling. These operations only control Chromium's existing transfer.
    if (*action == "pause" && item->GetState() == download::DownloadItem::IN_PROGRESS) item->Pause();
    else if (*action == "resume" && item->CanResume() && !item->IsDangerous()) item->Resume(true);
    else if (*action == "cancel" && item->GetState() != download::DownloadItem::COMPLETE &&
             item->GetState() != download::DownloadItem::CANCELLED) item->Cancel(true);
    else { error = "The download cannot perform that action in its current state."; return {}; }
    return base::DictValue().Set("accepted", true);
  }
 private:
  void CancelForRetirement(download::DownloadItem* item) {
    const auto state = item->GetState();
    if (state == download::DownloadItem::COMPLETE || state == download::DownloadItem::CANCELLED) return;
    const std::string guid = item->GetGuid();
    if (!cancelling_.insert(guid).second) return;
    // COMPLETING_INTERNAL may ignore Cancel but still synchronously notify
    // observers. Guard reentrancy and report pending until actual completion.
    item->Cancel(true);
    cancelling_.erase(guid);
  }
  void Watch(download::DownloadItem* item) { if (items_.insert(item).second) item->AddObserver(this); }
  void Updated(download::DownloadItem* item) {
    if (context_->IsOffTheRecord()) return;
    ZacroExtensionContext::Get(context_)->NotifyNative("Zacro.downloadChanged", Describe(item));
  }
  base::DictValue Describe(download::DownloadItem* item) {
    const auto state = item->GetState();
    const char* status = state == download::DownloadItem::COMPLETE ? "complete" :
        state == download::DownloadItem::CANCELLED ? "cancelled" :
        state == download::DownloadItem::INTERRUPTED ? "interrupted" : item->IsPaused() ? "paused" : "downloading";
    auto value = base::DictValue().Set("id", static_cast<double>(item->GetId())).Set("guid", item->GetGuid())
        .Set("url", item->GetURL().spec()).Set("path", item->GetTargetFilePath().AsUTF8Unsafe())
        .Set("receivedBytes", base::NumberToString(item->GetReceivedBytes()))
        .Set("totalBytes", base::NumberToString(item->GetTotalBytes())).Set("status", status)
        .Set("paused", item->IsPaused()).Set("canResume", item->CanResume()).Set("dangerous", item->IsDangerous())
        .Set("dangerType", static_cast<int>(item->GetDangerType())).Set("interruptReason", static_cast<int>(item->GetLastReason()))
        .Set("startedAt", item->GetStartTime().InMillisecondsFSinceUnixEpoch())
        .Set("sourceURL", item->GetTabUrl().spec()).Set("isPrivate", context_->IsOffTheRecord());
    if (auto* contents = content::DownloadItemUtils::GetOriginalWebContents(item);
        contents && extensions::ExtensionTabUtil::IsVisibleToNativeBrowserModel(contents)) {
      value.Set("sourceTabID", sessions::SessionTabHelper::IdForTab(contents).id());
    }
    return value;
  }
  bool retiring_ = false;
  std::set<std::string> cancelling_;
  raw_ptr<content::BrowserContext> context_;
  raw_ptr<content::DownloadManager> manager_ = nullptr;
  std::set<raw_ptr<download::DownloadItem>> items_;
};

void ZacroObserveProfileDownloads(content::BrowserContext* context) { ZacroDownloadContext::Get(context); }

bool CefDevToolsController::DispatchZacroDownloads(int id, const std::string& method, const base::DictValue* params) {
  if (method != "Zacro.downloadSnapshot" && method != "Zacro.controlDownload" &&
      method != "Zacro.renameDownload" && method != "Zacro.retireProfileDownloads") return false;
  if (method == "Zacro.retireProfileDownloads") {
    // This is a browser-process transport command, not an extension API. It
    // requires no extension registry/sync observer and works for OTR contexts.
    std::string error;
    auto result = ZacroDownloadContext::Get(inspected_contents_->GetBrowserContext())->RetirementStatus(error);
    ReplyZacro(id, std::move(result), error); return true;
  }
  if (method == "Zacro.renameDownload") {
    const auto* guid = params ? params->FindString("guid") : nullptr;
    const auto* name = params ? params->FindString("name") : nullptr;
    const base::FilePath basename = name ? base::FilePath::FromUTF8Unsafe(*name) : base::FilePath();
    auto* manager = inspected_contents_->GetBrowserContext()->GetDownloadManager();
    auto* item = manager && guid ? manager->GetDownloadByGuid(*guid) : nullptr;
    if (!item || !name || name->empty() || name->size() > 1024 || basename.IsAbsolute() ||
        basename.BaseName() != basename || basename.ReferencesParent() || *name == "." ||
        name->find_first_of("/\\\0", 0, 3) != std::string::npos ||
        item->GetState() != download::DownloadItem::COMPLETE || item->IsDangerous() || item->GetFullPath().empty()) {
      ReplyZacro(id, {}, "Choose a valid filename for a completed download."); return true;
    }
    if (item->GetFullPath().BaseName() == basename) {
      ReplyZacro(id, base::DictValue().Set("renamed", true)); return true;
    }
    item->Rename(basename, base::BindOnce(
        [](base::WeakPtr<CefDevToolsController> self, int id, download::DownloadItem::DownloadRenameResult result) {
          if (!self) return;
          const char* error = result == download::DownloadItem::SUCCESS ? "" :
              result == download::DownloadItem::FAILURE_NAME_CONFLICT ? "A file with that name already exists." :
              result == download::DownloadItem::FAILURE_NAME_TOO_LONG ? "The new filename is too long." :
              result == download::DownloadItem::FAILURE_UNAVAILABLE ? "The downloaded file is no longer available." :
              "The downloaded file could not be renamed.";
          self->ReplyZacro(id, base::DictValue().Set("renamed", result == download::DownloadItem::SUCCESS), error);
        }, weak_ptr_factory_.GetWeakPtr(), id));
    return true;
  }
  auto* state = ZacroDownloadContext::Get(inspected_contents_->GetBrowserContext());
  std::string error;
  auto result = method == "Zacro.downloadSnapshot" ? state->Snapshot() : state->Control(params, error);
  ReplyZacro(id, std::move(result), error); return true;
}
