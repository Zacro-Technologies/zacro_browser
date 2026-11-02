// Chromium owns the tree and its atomic Bookmarks file. Swift projects a flat
// Library without flattening or rewriting the native hierarchy.
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "base/strings/string_util.h"
#include "components/bookmarks/browser/bookmark_client.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_model_observer.h"
#include "components/bookmarks/common/bookmark_metrics.h"

class ZacroBookmarkContext : public base::SupportsUserData::Data,
                             public bookmarks::BookmarkModelObserver {
 public:
  static ZacroBookmarkContext* Get(content::BrowserContext* context) {
    constexpr char key[] = "zacro.native.bookmarks";
    if (auto* value = context->GetUserData(key)) return static_cast<ZacroBookmarkContext*>(value);
    auto value = std::make_unique<ZacroBookmarkContext>(context);
    auto* result = value.get(); context->SetUserData(key, std::move(value)); return result;
  }
  explicit ZacroBookmarkContext(content::BrowserContext* context) : context_(context) {
    if (!context->IsOffTheRecord()) model_ = BookmarkModelFactory::GetForBrowserContext(context);
    if (model_) model_->AddObserver(this);
  }
  ~ZacroBookmarkContext() override { if (model_) model_->RemoveObserver(this); }
  base::DictValue Execute(const std::string& method, const base::DictValue* params, std::string& error) {
    if (!model_ || !model_->loaded()) { error = "The native bookmark model is not ready."; return {}; }
    if (method == "Zacro.bookmarkPage") return Page(params, error);
    if (method == "Zacro.importBookmarks") return Import(params, error);
    if (method == "Zacro.acknowledgeBookmarkImports") return Acknowledge(params, error);
    if (method == "Zacro.removeBookmark") return Remove(params, error);
    error = "Unknown native bookmark operation."; return {};
  }
  void SaveForNative(base::OnceCallback<void(bool)> callback) {
    if (!model_ || !model_->loaded()) { std::move(callback).Run(false); return; }
    model_->SaveForNative(std::move(callback));
  }
  void BookmarkModelLoaded(bool) override { Changed(); }
  void BookmarkModelBeingDeleted() override { model_->RemoveObserver(this); model_ = nullptr; nodes_.clear(); }
  void BookmarkNodeMoved(const bookmarks::BookmarkNode*, size_t, const bookmarks::BookmarkNode*, size_t) override { Changed(); }
  void BookmarkNodeAdded(const bookmarks::BookmarkNode*, size_t, bool) override { Changed(); }
  void BookmarkNodeRemoved(const bookmarks::BookmarkNode*, size_t, const bookmarks::BookmarkNode*, const std::set<GURL>&, const base::Location&) override { Changed(); }
  void BookmarkNodeChanged(const bookmarks::BookmarkNode*) override { Changed(); }
  void BookmarkMetaInfoChanged(const bookmarks::BookmarkNode*) override { Changed(); }
  void BookmarkNodeFaviconChanged(const bookmarks::BookmarkNode*) override {}
  void BookmarkNodeChildrenReordered(const bookmarks::BookmarkNode*) override { Changed(); }
  void BookmarkAllUserNodesRemoved(const std::set<GURL>&, const base::Location&) override { Changed(); }
 private:
  static constexpr char kJournal[] = "zacro.native.bookmark-imports.v1";
  static constexpr char kLogicalID[] = "zacro.native.logical-id";
  using Node = bookmarks::BookmarkNode;
  using Lookup = bookmarks::BookmarkModel::NodeTypeForUuidLookup;
  static bool ValidLogicalID(const std::string& value) {
    return !value.empty() && value.size() <= 128 && std::all_of(value.begin(), value.end(),
        [](char ch) { return base::IsAsciiAlphaNumeric(ch) || ch == '_' || ch == '-'; });
  }
  void Changed() {
    ++revision_; nodes_.clear(); cached_ = false;
    ZacroExtensionContext::Get(context_)->NotifyNative("Zacro.bookmarksChanged", base::DictValue().Set("revision", Revision()));
  }
  std::string Revision() const { return epoch_ + ":" + base::NumberToString(revision_); }
  bool Account(const Node* node) const { return model_->GetNodeByUuid(node->uuid(), Lookup::kAccountNodes) == node; }
  bool Editable(const Node* node) const { return !node->is_permanent_node() && !model_->client()->IsNodeManaged(node); }
  base::DictValue Describe(const Node* node) const {
    auto value = base::DictValue().Set("nodeID", base::NumberToString(node->id()))
        .Set("uuid", node->uuid().AsLowercaseString()).Set("storage", Account(node) ? "account" : "local")
        .Set("title", base::UTF16ToUTF8(node->GetTitle())).Set("dateAdded", node->date_added().InMillisecondsFSinceUnixEpoch())
        .Set("editable", Editable(node)).Set("folder", node->is_folder());
    if (node->parent()) value.Set("parentID", base::NumberToString(node->parent()->id()));
    if (node->is_url()) value.Set("url", node->url().spec());
    std::string logical; if (node->GetMetaInfo(kLogicalID, &logical)) value.Set("logicalID", logical);
    return value;
  }
  void Cache() {
    if (cached_) return;
    nodes_.clear(); std::vector<const Node*> pending{model_->root_node()};
    while (!pending.empty()) {
      const auto* node = pending.back(); pending.pop_back();
      if (node != model_->root_node()) nodes_.push_back(node);
      for (auto it = node->children().rbegin(); it != node->children().rend(); ++it) pending.push_back(it->get());
    }
    cached_ = true;
  }
  base::DictValue Page(const base::DictValue* params, std::string& error) {
    const int offset = params ? params->FindInt("offset").value_or(0) : 0;
    const int limit = params ? params->FindInt("limit").value_or(512) : 512;
    const auto* revision = params ? params->FindString("revision") : nullptr;
    if (offset < 0 || limit < 1 || limit > 512 || (offset && !revision) || (revision && *revision != Revision())) {
      error = "The bookmark snapshot changed; restart pagination."; return {};
    }
    Cache();
    if (static_cast<size_t>(offset) > nodes_.size()) { error = "Invalid bookmark page offset."; return {}; }
    const size_t end = std::min(nodes_.size(), static_cast<size_t>(offset) + limit);
    base::ListValue records;
    for (size_t index = offset; index < end; ++index) records.Append(Describe(nodes_[index]));
    return base::DictValue().Set("revision", Revision()).Set("total", static_cast<double>(nodes_.size()))
        .Set("nextOffset", static_cast<int>(end)).Set("complete", end == nodes_.size()).Set("nodes", std::move(records));
  }
  std::optional<base::DictValue> Journal(std::string& error) {
    std::string encoded;
    if (!model_->other_node()->GetMetaInfo(kJournal, &encoded)) return base::DictValue();
    auto parsed = base::JSONReader::ReadDict(encoded, base::JSON_PARSE_RFC);
    if (!parsed || parsed->size() > 40000) { error = "The native bookmark import journal is invalid."; return std::nullopt; }
    for (const auto [logical, value] : *parsed) {
      if (!ValidLogicalID(logical) || !value.is_string() || !base::Uuid::ParseLowercase(value.GetString()).is_valid()) {
        error = "The native bookmark import journal contains an invalid identity."; return std::nullopt;
      }
    }
    return parsed;
  }
  bool SaveJournal(const base::DictValue& journal, std::string& error) {
    auto encoded = base::WriteJson(journal);
    if (!encoded) { error = "The native bookmark import journal could not be encoded."; return false; }
    model_->SetNodeMetaInfo(model_->other_node(), kJournal, *encoded); return true;
  }
  base::DictValue Import(const base::DictValue* params, std::string& error) {
    const auto* entries = params ? params->FindList("entries") : nullptr;
    if (!entries || entries->size() > 512) { error = "Import at most 512 bookmarks at a time."; return {}; }
    auto journal = Journal(error); if (!journal) return {};
    std::set<std::string> unique;
    for (const auto& value : *entries) {
      const auto* item = value.GetIfDict(); const auto* logical = item ? item->FindString("logicalID") : nullptr;
      const auto* url = item ? item->FindString("url") : nullptr; const auto* title = item ? item->FindString("title") : nullptr;
      const GURL address(url ? *url : "");
      if (!logical || !ValidLogicalID(*logical) || !unique.insert(*logical).second ||
          !url || !address.is_valid() || !address.SchemeIsHTTPOrHTTPS() || address.has_username() || address.has_password() ||
          base::UTF8ToUTF16(*url).size() > 8192 || !title || base::UTF8ToUTF16(*title).size() > 500) {
        error = "A bookmark import entry is invalid."; return {};
      }
    }
    if (journal->size() + entries->size() > 40000) { error = "Acknowledge earlier bookmark imports before continuing."; return {}; }
    // The journal and nodes share Chromium's single atomic Bookmarks file.
    // No posted task can serialize an intermediate mutation in this UI turn.
    Cache();
    std::map<std::string, const Node*> existing;
    for (const auto& node : nodes_) {
      std::string logical;
      if (node->is_url() && node->GetMetaInfo(kLogicalID, &logical)) existing.try_emplace(logical, node.get());
    }
    model_->BeginExtensiveChanges();
    base::ListValue results;
    for (const auto& value : *entries) {
      const auto& item = value.GetDict(); const auto& logical = *item.FindString("logicalID");
      const Node* node = nullptr; std::string uuid;
      if (const auto* imported = journal->FindString(logical)) {
        uuid = *imported;
        node = model_->GetNodeByUuid(base::Uuid::ParseCaseInsensitive(uuid), Lookup::kLocalOrSyncableNodes);
        std::string owner;
        if (!node || !node->GetMetaInfo(kLogicalID, &owner) || owner != logical) {
          node = model_->GetNodeByUuid(base::Uuid::ParseCaseInsensitive(uuid), Lookup::kAccountNodes);
          if (!node || !node->GetMetaInfo(kLogicalID, &owner) || owner != logical) node = nullptr;
        }
      } else if (const auto found = existing.find(logical); found != existing.end()) {
        node = found->second; uuid = node->uuid().AsLowercaseString(); journal->Set(logical, uuid);
      } else {
        const auto identity = base::Uuid::GenerateRandomV4(); uuid = identity.AsLowercaseString();
        Node::MetaInfoMap meta{{kLogicalID, logical}};
        auto date = item.FindDouble("dateAdded");
        node = model_->AddURL(model_->other_node(), model_->other_node()->children().size(),
            base::UTF8ToUTF16(*item.FindString("title")), GURL(*item.FindString("url")), &meta,
            date ? base::Time::FromMillisecondsSinceUnixEpoch(*date) : base::Time::Now(), identity);
        journal->Set(logical, uuid);
      }
      auto result = base::DictValue().Set("logicalID", logical).Set("uuid", uuid).Set("removed", !node);
      if (node) result.Set("node", Describe(node));
      results.Append(std::move(result));
    }
    SaveJournal(*journal, error); model_->EndExtensiveChanges();
    return base::DictValue().Set("results", std::move(results)).Set("revision", Revision());
  }
  base::DictValue Acknowledge(const base::DictValue* params, std::string& error) {
    const auto* entries = params ? params->FindList("entries") : nullptr;
    if (!entries || entries->size() > 512) { error = "Invalid bookmark import acknowledgement."; return {}; }
    auto journal = Journal(error); if (!journal) return {};
    for (const auto& value : *entries) {
      const auto* item = value.GetIfDict(); const auto* logical = item ? item->FindString("logicalID") : nullptr;
      const auto* uuid = item ? item->FindString("uuid") : nullptr;
      if (!logical || !ValidLogicalID(*logical) || !uuid || !base::Uuid::ParseLowercase(*uuid).is_valid()) {
        error = "Invalid bookmark import acknowledgement."; return {};
      }
      if (const auto* current = journal->FindString(*logical); current && *current != *uuid) {
        error = "The bookmark import identity changed."; return {};
      }
    }
    for (const auto& value : *entries) journal->Remove(*value.GetDict().FindString("logicalID"));
    SaveJournal(*journal, error); return base::DictValue().Set("acknowledged", error.empty());
  }
  base::DictValue Remove(const base::DictValue* params, std::string& error) {
    const auto* uuid = params ? params->FindString("uuid") : nullptr;
    const auto* storage = params ? params->FindString("storage") : nullptr;
    const auto* identifier = params ? params->FindString("nodeID") : nullptr;
    if (!uuid || !identifier || !storage || (*storage != "local" && *storage != "account")) {
      error = "The native bookmark identity is invalid."; return {};
    }
    const auto* node = model_->GetNodeByUuid(base::Uuid::ParseCaseInsensitive(*uuid),
        *storage == "account" ? Lookup::kAccountNodes : Lookup::kLocalOrSyncableNodes);
    if (!node) return base::DictValue().Set("removed", true);
    if (base::NumberToString(node->id()) != *identifier || !node->is_url() || !Editable(node)) {
      error = "The bookmark changed or cannot be edited."; return {};
    }
    model_->Remove(node, bookmarks::metrics::BookmarkEditSource::kOther, FROM_HERE);
    return base::DictValue().Set("removed", true);
  }
  raw_ptr<content::BrowserContext> context_;
  raw_ptr<bookmarks::BookmarkModel> model_ = nullptr;
  const std::string epoch_ = base::Uuid::GenerateRandomV4().AsLowercaseString();
  uint64_t revision_ = 0;
  bool cached_ = false;
  std::vector<raw_ptr<const Node>> nodes_;
};

bool CefDevToolsController::DispatchZacroBookmarks(int id, const std::string& method, const base::DictValue* params) {
  if (method != "Zacro.bookmarkPage" && method != "Zacro.importBookmarks" &&
      method != "Zacro.acknowledgeBookmarkImports" && method != "Zacro.removeBookmark") return false;
  std::string error;
  auto* state = ZacroBookmarkContext::Get(inspected_contents_->GetBrowserContext());
  auto result = state->Execute(method, params, error);
  const bool snapshot_start = method == "Zacro.bookmarkPage" && (!params || params->FindInt("offset").value_or(0) == 0);
  if (!error.empty() || (method == "Zacro.bookmarkPage" && !snapshot_start)) {
    ReplyZacro(id, std::move(result), error); return true;
  }
  // Core may commit its projection only after Chromium's corresponding model
  // snapshot reaches the atomic primary file. The first snapshot page also
  // flushes extension-origin edits before exposing them to another database.
  state->SaveForNative(base::BindOnce(
      [](base::WeakPtr<CefDevToolsController> self, int id, base::DictValue result, bool success) {
        if (self) self->ReplyZacro(id, std::move(result), success ? "" : "Chromium could not save its bookmark database.");
      }, weak_ptr_factory_.GetWeakPtr(), id, std::move(result)));
  return true;
}
