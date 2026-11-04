// Native-only, profile-owned HistoryService projection. SQL completion and an
// unchanged observer revision authorize absence; notifications are hints only.
#include "base/task/cancelable_task_tracker.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/history/native_history_owner.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_service_observer.h"
#include "cef/libcef/browser/devtools/zacro_history_db_tasks.inc"

namespace {
using ZacroHistoryPresence = history::HistoryDatabase::NativeVisitPresence;
using ZacroHistoryPublication = history::HistoryDatabase::NativeMirrorPublication;
using ZacroHistoryReply = base::OnceCallback<void(base::DictValue, std::string)>;

bool ZacroHistoryUUID(const std::string& value) {
  return base::Uuid::ParseLowercase(value).is_valid();
}
bool ZacroHistoryDecimal(const std::string& value, int64_t* parsed, bool zero = false) {
  return base::StringToInt64(value, parsed) && *parsed >= (zero ? 0 : 1) &&
      base::NumberToString(*parsed) == value;
}
std::string ZacroHistoryPresenceName(ZacroHistoryPresence presence) {
  switch (presence) {
    case ZacroHistoryPresence::kPresent: return "present";
    case ZacroHistoryPresence::kAbsent: return "absent";
    case ZacroHistoryPresence::kError: return "error";
  }
}
base::DictValue ZacroHistoryIdentity(const history::HistoryDatabase::NativeMirrorEvent& event) {
  return base::DictValue().Set("generation", event.generation)
      .Set("visitID", base::NumberToString(event.visit_id))
      .Set("timeMicroseconds", base::NumberToString(event.time_microseconds))
      .Set("url", event.url).Set("originator", event.originator);
}
base::DictValue ZacroHistoryEvent(const history::HistoryDatabase::NativeMirrorEvent& event) {
  auto result = base::DictValue().Set("eventID", event.event_id)
      .Set("documentToken", event.document_token).Set("logicalID", event.logical_id)
      .Set("sequence", base::NumberToString(event.sequence)).Set("publish", event.publish)
      .Set("libraryVisit", event.library_visit)
      .Set("presence", ZacroHistoryPresenceName(event.presence)).Set("title", event.title);
  if (event.presence == ZacroHistoryPresence::kPresent) result.Set("identity", ZacroHistoryIdentity(event));
  return result;
}
base::DictValue ZacroHistoryPublicationValue(const ZacroHistoryPublication& lease,
    const std::optional<history::HistoryDatabase::NativeMirrorEvent>& event = std::nullopt) {
  using Disposition = ZacroHistoryPublication::Disposition;
  auto result = base::DictValue().Set("leaseID", lease.lease_id)
      .Set("documentToken", lease.document_token).Set("kind", lease.preview ? "preview" : "popup")
      .Set("disposition", lease.disposition == Disposition::kCommitted ? "committed" :
          lease.disposition == Disposition::kCancelled ? "cancelled" : "prepared");
  if (!lease.captured_event_id.empty()) result.Set("capturedEventID", lease.captured_event_id);
  if (!lease.logical_id.empty()) result.Set("logicalID", lease.logical_id);
  if (event) result.Set("capturedEvent", ZacroHistoryEvent(*event));
  return result;
}

class ZacroHistoryContext final : public base::SupportsUserData::Data,
                                  public history::HistoryServiceObserver {
 public:
  static ZacroHistoryContext* Find(content::BrowserContext* context) {
    return context ? static_cast<ZacroHistoryContext*>(context->GetUserData(kKey)) : nullptr;
  }
  static ZacroHistoryContext* Get(content::BrowserContext* context) {
    if (auto* value = Find(context)) return value;
    auto value = std::make_unique<ZacroHistoryContext>(context);
    auto* result = value.get(); context->SetUserData(kKey, std::move(value)); return result;
  }
  explicit ZacroHistoryContext(content::BrowserContext* context) : context_(context) {
    if (!context->IsOffTheRecord()) service_ = HistoryServiceFactory::GetForProfile(
        Profile::FromBrowserContext(context), ServiceAccessType::EXPLICIT_ACCESS);
    if (service_) service_->AddObserver(this);
  }
  ~ZacroHistoryContext() override {
    Retire();
    if (service_) service_->RemoveObserver(this);
  }
  void Retire() {
    retired_ = true; tracker_.TryCancelAll(); leases_.clear();
    auto pending = std::move(pending_);
    for (auto& [id, reply] : pending) std::move(reply).Run({}, "The native history profile closed.");
    weak_.InvalidateWeakPtrs();
  }
  void OnURLVisitedWithNavigationId(history::HistoryService*, const history::VisitedURLInfo&) override { Changed(); }
  void OnURLsModified(history::HistoryService*, const history::URLRows&) override { Changed(); }
  void OnHistoryDeletions(history::HistoryService*, const history::DeletionInfo&) override { Changed(); }
  void OnHistoryServiceLoaded(history::HistoryService*) override { Changed(); }
  void HistoryServiceBeingDeleted(history::HistoryService* service) override {
    if (service_ != service) return;
    service_->RemoveObserver(this); service_ = nullptr; Retire();
  }
  void Changed() {
    if (retired_) return;
    ++revision_; leases_.clear();
    ZacroExtensionContext::Get(context_)->NotifyNative("Zacro.historyChanged",
        base::DictValue().Set("revision", Revision()));
  }
  void DocumentClosed(const std::string& token) {
    if (retired_ || !ZacroHistoryUUID(token)) return;
    if (closed_documents_.size() >= 20000 && !closed_documents_.contains(token)) {
      Retire(); return;  // Preserve data rather than grow an unbounded proof queue.
    }
    closed_documents_.insert(token); Changed();
  }
  void Execute(content::WebContents* document, const std::string& method,
               const base::DictValue& params, ZacroHistoryReply reply) {
    if (!service_ || retired_ || !document || document->GetBrowserContext() != context_ ||
        context_->IsOffTheRecord() || pending_.size() >= 64) {
      std::move(reply).Run({}, "The native history database is unavailable."); return;
    }
    if (method == "Zacro.replaceHistoryRetention" || method == "Zacro.historyRetentionStatus") {
      Retention(method, params, std::move(reply)); return;
    }
    if (method == "Zacro.historyMirrorBarrier") {
      const auto request = Queue(std::move(reply));
      service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryBarrierTask>(base::BindOnce(
          [](base::WeakPtr<ZacroHistoryContext> self, std::string request, bool ready) {
            if (self) self->MutationComplete(request, ready);
          }, weak_.GetWeakPtr(), request)), &tracker_);
      return;
    }
    if (method == "Zacro.historyDocument") {
      auto* owner = NativeHistoryOwner::FromWebContents(document);
      auto snapshot = owner ? owner->Describe() : std::nullopt;
      if (!snapshot) { std::move(reply).Run({}, "The document has no native history identity."); return; }
      auto result = base::DictValue().Set("documentToken", snapshot->document_token)
          .Set("logicalID", snapshot->logical_id).Set("ownerWindowID", snapshot->owner_window_id)
          .Set("preview", snapshot->preview).Set("provisional", snapshot->provisional);
      if (!snapshot->current_event_id.empty()) result.Set("currentEventID", snapshot->current_event_id);
      std::move(reply).Run(std::move(result), {}); return;
    }
    if (method == "Zacro.releaseHistoryVerification" || method == "Zacro.acknowledgeHistoryVerification") {
      const auto* lease = params.FindString("lease");
      const auto* revision = params.FindString("revision");
      if (!lease || !ZacroHistoryUUID(*lease) ||
          (method == "Zacro.acknowledgeHistoryVerification" && (!revision || revision->empty() || revision->size() > 128))) {
        std::move(reply).Run({}, "Invalid history lease acknowledgement."); return;
      }
      auto found = leases_.find(*lease);
      if (found != leases_.end() && method == "Zacro.acknowledgeHistoryVerification" &&
          (found->second.revision != *revision || !found->second.confirmed)) {
        std::move(reply).Run({}, "The history verification lease was not confirmed."); return;
      }
      leases_.erase(*lease);
      // Release is idempotent and never grants deletion authority or new proof.
      std::move(reply).Run(base::DictValue().Set("acknowledged", true), {}); return;
    }
    if (method == "Zacro.beginHistoryVerification") {
      const auto total = params.FindInt("total");
      if (!total || *total < 0 || *total > 20000 || leases_.size() >= 16) {
        std::move(reply).Run({}, "Invalid or excessive history verification request."); return;
      }
      const auto token = base::Uuid::GenerateRandomV4().AsLowercaseString();
      const auto revision = Revision();
      leases_.emplace(token, Lease{revision, *total, 0, false, false});
      std::move(reply).Run(base::DictValue().Set("lease", token).Set("revision", revision).Set("total", *total), {});
      return;
    }
    if (method == "Zacro.verifyHistoryPage") { Verify(params, std::move(reply)); return; }
    if (method == "Zacro.confirmHistoryVerification") { Confirm(params, std::move(reply)); return; }
    if (method == "Zacro.historyEventPage" || method == "Zacro.observeHistory") {
      const auto* after = params.FindString("afterSequence");
      int64_t sequence = 0; const int limit = params.FindInt("limit").value_or(512);
      if ((after && !ZacroHistoryDecimal(*after, &sequence, true)) || limit < 1 || limit > 512) {
        std::move(reply).Run({}, "Invalid native history event page."); return;
      }
      const auto request = Queue(std::move(reply));
      const auto closed_documents = closed_documents_;
      service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryEventPageTask>(sequence, limit,
          NativeHistoryOwner::ProducerEpoch(), closed_documents, base::BindOnce(
          [](base::WeakPtr<ZacroHistoryContext> self, std::string request, int64_t after,
             bool observation, std::set<std::string> closed_documents,
             std::optional<ZacroHistoryEventPageTask::Page> page) {
            if (!self) return;
            if (!page) { self->Complete(request, {}, "Chromium could not read and commit its history journal."); return; }
            for (const auto& token : closed_documents) self->closed_documents_.erase(token);
            if (observation) {
              self->Complete(request, base::DictValue().Set("ready", true).Set("revision", self->Revision()), {}); return;
            }
            base::ListValue records;
            size_t bytes = 0, emitted = 0;
            for (const auto& event : page->events) {
              auto value = ZacroHistoryEvent(event);
              auto encoded = base::WriteJson(value);
              if (!encoded) { self->Complete(request, {}, "The native history event could not be encoded."); return; }
              if (bytes + encoded->size() > 1536 * 1024) break;
              bytes += encoded->size(); ++emitted; records.Append(std::move(value));
            }
            if (!page->events.empty() && !emitted) {
              self->Complete(request, {}, "A native history record exceeds its response bound."); return;
            }
            const auto next = emitted ? page->events[emitted - 1].sequence : after;
            self->Complete(request, base::DictValue().Set("events", std::move(records))
                .Set("complete", page->complete && emitted == page->events.size())
                .Set("nextSequence", base::NumberToString(next)), {});
          }, weak_.GetWeakPtr(), request, sequence, method == "Zacro.observeHistory", closed_documents)), &tracker_);
      return;
    }
    if (method == "Zacro.acknowledgeHistoryEvents") {
      const auto* entries = params.FindList("eventIDs"); std::vector<std::string> ids;
      if (!entries || entries->size() > 512) { std::move(reply).Run({}, "Invalid history event acknowledgement."); return; }
      std::set<std::string> unique;
      for (const auto& value : *entries) {
        if (!value.is_string() || !ZacroHistoryUUID(value.GetString()) || !unique.insert(value.GetString()).second) {
          std::move(reply).Run({}, "Invalid history event acknowledgement."); return;
        }
        ids.push_back(value.GetString());
      }
      const auto request = Queue(std::move(reply));
      service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryAcknowledgeTask>(std::move(ids),
          base::BindOnce([](base::WeakPtr<ZacroHistoryContext> self, std::string request, bool okay) {
            if (self) self->MutationComplete(request, okay);
          }, weak_.GetWeakPtr(), request)), &tracker_); return;
    }
    if (method == "Zacro.prepareHistoryPublication") { Prepare(document, params, std::move(reply)); return; }
    if (method == "Zacro.historyPublications" || method == "Zacro.commitHistoryPublication" ||
        method == "Zacro.cancelHistoryPublication" || method == "Zacro.finalizeHistoryPublication") {
      Publication(method, params, std::move(reply)); return;
    }
    Legacy(method, params, std::move(reply));
  }
 private:
  static constexpr char kKey[] = "zacro.native.history-mirror.v1";
  struct Lease { std::string revision; int total; int next; bool busy; bool confirmed; };
  struct PreparedOwner { base::WeakPtr<NativeHistoryOwner> owner; NativeHistoryOwner::Publication publication; };
  std::string Revision() const { return epoch_ + ":" + base::NumberToString(revision_); }
  std::string Queue(ZacroHistoryReply reply) {
    const auto id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    pending_.emplace(id, std::move(reply)); return id;
  }
  void Complete(const std::string& id, base::DictValue value, std::string error) {
    auto item = pending_.extract(id); if (item.empty()) return;
    std::move(item.mapped()).Run(std::move(value), std::move(error));
  }
  void MutationComplete(const std::string& id, bool okay) {
    Complete(id, base::DictValue().Set("acknowledged", okay),
        okay ? "" : "Chromium could not commit the native history operation.");
  }
  std::optional<std::pair<std::string, Lease*>> FindLease(const base::DictValue& params) {
    const auto* id = params.FindString("lease"), *revision = params.FindString("revision");
    if (!id || !revision) return std::nullopt;
    auto found = leases_.find(*id);
    if (found == leases_.end() || found->second.revision != *revision || *revision != Revision() || found->second.busy)
      return std::nullopt;
    return std::make_pair(*id, &found->second);
  }
  void Verify(const base::DictValue& params, ZacroHistoryReply reply) {
    auto found = FindLease(params); const auto offset = params.FindInt("offset");
    const auto* values = params.FindList("inputs");
    if (!found || !offset || *offset != found->second->next || !values || values->size() > 512 ||
        values->empty() || *offset + static_cast<int>(values->size()) > found->second->total) {
      std::move(reply).Run({}, "The native history verification snapshot changed."); return;
    }
    std::vector<ZacroHistoryVerificationInput> inputs;
    for (const auto& value : *values) {
      const auto* item = value.GetIfDict();
      const auto* generation = item ? item->FindString("generation") : nullptr;
      const auto* visit = item ? item->FindString("visitID") : nullptr;
      const auto* time = item ? item->FindString("timeMicroseconds") : nullptr;
      const auto* url = item ? item->FindString("url") : nullptr;
      const auto* originator = item ? item->FindString("originator") : nullptr;
      const auto* event = item ? item->FindString("eventID") : nullptr;
      int64_t visit_id = 0, microseconds = 0;
      if (!generation || generation->empty() || generation->size() > 64 || !visit || !time ||
          (event && !ZacroHistoryUUID(*event)) ||
          !ZacroHistoryDecimal(*visit, &visit_id) || !ZacroHistoryDecimal(*time, &microseconds) ||
          !url || url->size() > 8192 || !GURL(*url).SchemeIsHTTPOrHTTPS() ||
          GURL(*url).has_username() || GURL(*url).has_password() || !originator || originator->size() > 256) {
        std::move(reply).Run({}, "A native history verification identity is invalid."); return;
      }
      inputs.push_back({*generation, visit_id, microseconds, *url, *originator});
    }
    auto encoded = base::WriteJson(*values);
    if (!encoded || encoded->size() > 512 * 1024) { std::move(reply).Run({}, "The history page is too large."); return; }
    const auto lease = found->first, revision = found->second->revision;
    const int end = *offset + inputs.size(); found->second->busy = true;
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryVerificationTask>(std::move(inputs),
        base::BindOnce([](base::WeakPtr<ZacroHistoryContext> self, std::string request,
          std::string lease, std::string revision, int offset, int end, base::ListValue inputs,
          ZacroHistoryVerificationTask::Result rows) {
          if (!self) return;
          auto live = self->leases_.find(lease);
          if (!rows || live == self->leases_.end() || self->Revision() != revision ||
              live->second.revision != revision || live->second.next != offset || rows->size() != inputs.size()) {
            self->leases_.erase(lease);
            self->Complete(request, {}, "The native history verification snapshot changed or could not be read."); return;
          }
          live->second.busy = false; live->second.next = end;
          base::ListValue results;
          // Reserve the full request bound for mandatory identities that have
          // not yet been appended. Optional titles cannot crowd out proof rows.
          size_t response_bytes = 512 * 1024;
          for (size_t index = 0; index < rows->size(); ++index) {
            const auto* input = inputs[index].GetIfDict();
            const auto* event = input ? input->FindString("eventID") : nullptr;
            const auto* url = input ? input->FindString("url") : nullptr;
            const auto native_title = event && url ? NativeHistoryOwner::TitleForEvent(self->context_, *event, *url) : std::nullopt;
            auto row = base::DictValue().Set("input", std::move(inputs[index]))
                .Set("presence", ZacroHistoryPresenceName((*rows)[index].presence));
            if ((*rows)[index].presence == ZacroHistoryPresence::kPresent && native_title) {
              auto title = *native_title;
              auto encoded = base::WriteJson(base::Value(title));
              while (encoded && encoded->size() > 2000) {
                title = std::string(base::TruncateUTF8ToByteSize(title, title.size() / 2));
                encoded = base::WriteJson(base::Value(title));
              }
              auto with_title = row.Clone(); with_title.Set("title", title);
              auto encoded_row = base::WriteJson(with_title);
              if (encoded && encoded_row && response_bytes + encoded_row->size() <= 1536 * 1024) {
                row = std::move(with_title);
              }
            }
            auto encoded_row = base::WriteJson(row);
            if (!encoded_row) { self->Complete(request, {}, "A native history proof could not be encoded."); return; }
            response_bytes += encoded_row->size();
            results.Append(std::move(row));
          }
          self->Complete(request, base::DictValue().Set("lease", lease).Set("revision", revision)
              .Set("offset", offset).Set("complete", end == live->second.total).Set("results", std::move(results)), {});
        }, weak_.GetWeakPtr(), request, lease, revision, *offset, end, values->Clone())), &tracker_);
  }
  void Confirm(const base::DictValue& params, ZacroHistoryReply reply) {
    auto found = FindLease(params);
    if (!found || found->second->next != found->second->total) {
      std::move(reply).Run({}, "The history verification is incomplete or stale."); return;
    }
    const auto lease = found->first, revision = found->second->revision;
    found->second->busy = true; const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryVerificationTask>(
        std::vector<ZacroHistoryVerificationInput>(), base::BindOnce(
        [](base::WeakPtr<ZacroHistoryContext> self, std::string request, std::string lease,
           std::string revision, ZacroHistoryVerificationTask::Result result) {
          if (!self) return;
          auto found = self->leases_.find(lease);
          if (!result || found == self->leases_.end() || found->second.revision != revision || self->Revision() != revision) {
            self->leases_.erase(lease); self->Complete(request, {}, "The history changed before confirmation."); return;
          }
          found->second.busy = false; found->second.confirmed = true;
          self->Complete(request, base::DictValue().Set("revision", revision), {});
        }, weak_.GetWeakPtr(), request, lease, revision)), &tracker_);
  }
  void Prepare(content::WebContents* document, const base::DictValue& params, ZacroHistoryReply reply) {
    const auto* id = params.FindString("leaseID"), *token = params.FindString("documentToken"),
        *logical = params.FindString("logicalID");
    const auto window = params.FindInt("ownerWindowID");
    if (owners_.size() >= 1000) {
      std::move(reply).Run({}, "Too many pending native history publications."); return;
    }
    auto* owner = NativeHistoryOwner::FromWebContents(document);
    auto captured = owner && id && token && logical && window
        ? owner->BeginPublication(*id, *token, *logical, *window) : std::nullopt;
    if (!captured) {
      std::move(reply).Run({}, "The history publication document changed."); return;
    }
    ZacroHistoryPublication lease;
    lease.lease_id = captured->lease_id; lease.document_token = captured->captured.document_token;
    lease.preview = captured->captured.preview; lease.captured_event_id = captured->captured.current_event_id;
    owners_.emplace(lease.lease_id, PreparedOwner{owner->GetWeakPtr(), *captured});
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryPreparePublicationTask>(lease,
        base::BindOnce([](base::WeakPtr<ZacroHistoryContext> self, std::string request,
           std::optional<ZacroHistoryPreparePublicationTask::Prepared> result) {
          if (!self) return;
          if (!result) { self->Complete(request, {}, "Chromium could not prepare the history publication."); return; }
          self->Complete(request, ZacroHistoryPublicationValue(result->lease, result->captured), {});
        }, weak_.GetWeakPtr(), request)), &tracker_);
  }
  void Publication(const std::string& method, const base::DictValue& params, ZacroHistoryReply reply) {
    const auto* id = params.FindString("leaseID"), *token = params.FindString("documentToken");
    const auto* logical = params.FindString("logicalID");
    if (method != "Zacro.historyPublications" && (!id || !token || !ZacroHistoryUUID(*id) || !ZacroHistoryUUID(*token) ||
        (logical && (logical->empty() || logical->size() > 1024)))) {
      std::move(reply).Run({}, "The native publication lease is invalid."); return;
    }
    const auto request = Queue(std::move(reply));
    service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryPublicationListTask>(base::BindOnce(
        [](base::WeakPtr<ZacroHistoryContext> self, std::string request, std::string method,
          std::string id, std::string token, std::string logical, ZacroHistoryPublicationListTask::Result values) {
          if (!self) return;
          if (!values) { self->Complete(request, {}, "Chromium could not read its publication journal."); return; }
          if (method == "Zacro.historyPublications") {
            base::ListValue records;
            for (const auto& lease : *values) records.Append(ZacroHistoryPublicationValue(lease));
            self->Complete(request, base::DictValue().Set("publications", std::move(records)), {}); return;
          }
          auto found = std::ranges::find_if(*values, [&](const auto& value) { return value.lease_id == id; });
          if (found == values->end()) {
            // Cancel/finalize cannot grant publication, including a cancelled
            // prepare whose response never arrived. Commit requires evidence.
            const bool okay = method != "Zacro.commitHistoryPublication";
            if (okay) self->FinishOwner(id, token, logical, method);
            self->MutationComplete(request, okay); return;
          }
          if (found->document_token != token) { self->Complete(request, {}, "The history publication token changed."); return; }
          using Action = ZacroHistoryPublicationMutationTask::Action;
          const auto action = method == "Zacro.commitHistoryPublication" ? Action::kCommit :
              method == "Zacro.cancelHistoryPublication" ? Action::kCancel : Action::kFinalize;
          self->service_->ScheduleDBTask(FROM_HERE, std::make_unique<ZacroHistoryPublicationMutationTask>(action, *found,
              logical, base::BindOnce([](base::WeakPtr<ZacroHistoryContext> self, std::string request,
                std::string id, std::string token, std::string logical, std::string method, bool okay) {
                if (!self) return;
                if (okay) okay = self->FinishOwner(id, token, logical, method);
                self->MutationComplete(request, okay);
              }, self->weak_.GetWeakPtr(), request, id, token, logical, method)), &self->tracker_);
        }, weak_.GetWeakPtr(), request, method, id ? *id : "", token ? *token : "", logical ? *logical : "")), &tracker_);
  }
  bool FinishOwner(const std::string& id, const std::string& token, const std::string& logical,
                   const std::string& method) {
    auto found = owners_.find(id);
    if (found == owners_.end()) return true;
    if (found->second.publication.captured.document_token != token) return false;
    auto* owner = found->second.owner.get();
    if (owner) {
      if (method == "Zacro.commitHistoryPublication" && !owner->PublicationCommitted(found->second.publication, logical)) return false;
      if (method == "Zacro.cancelHistoryPublication" && !owner->PublicationCancelled(found->second.publication)) return false;
      if (method == "Zacro.finalizeHistoryPublication" && !owner->FinishPublication(found->second.publication)) return false;
    }
    if (method == "Zacro.finalizeHistoryPublication") owners_.erase(found);
    return true;
  }
  void Retention(const std::string& method, const base::DictValue& params, ZacroHistoryReply reply);
  void Legacy(const std::string& method, const base::DictValue& params, ZacroHistoryReply reply);
  raw_ptr<content::BrowserContext> context_;
  raw_ptr<history::HistoryService> service_ = nullptr;
  bool retired_ = false;
  const std::string epoch_ = base::Uuid::GenerateRandomV4().AsLowercaseString();
  uint64_t revision_ = 0;
  std::map<std::string, Lease> leases_;
  std::map<std::string, PreparedOwner> owners_;
  std::set<std::string> closed_documents_;
  std::map<std::string, ZacroHistoryReply> pending_;
  base::CancelableTaskTracker tracker_;
  base::WeakPtrFactory<ZacroHistoryContext> weak_{this};
};
#include "cef/libcef/browser/devtools/zacro_history_legacy_adapter.inc"
}  // namespace

void ZacroRetireProfileHistory(content::BrowserContext* context) {
  if (auto* state = ZacroHistoryContext::Find(context)) state->Retire();
}
void ZacroNativeHistoryDocumentChanged(content::BrowserContext* context) {
  if (auto* state = ZacroHistoryContext::Find(context)) state->Changed();
}
void ZacroNativeHistoryDocumentClosed(content::BrowserContext* context, const std::string& token) {
  if (auto* state = ZacroHistoryContext::Find(context)) state->DocumentClosed(token);
}
void ZacroObserveProfileHistory(content::BrowserContext* context) {
  if (context && !context->IsOffTheRecord()) ZacroHistoryContext::Get(context);
}

bool CefDevToolsController::DispatchZacroHistory(int id, const std::string& method,
                                               const base::DictValue* params) {
  static const base::NoDestructor<std::set<std::string>> methods({
      "Zacro.observeHistory", "Zacro.historyMirrorBarrier", "Zacro.historyDocument", "Zacro.historyEventPage", "Zacro.acknowledgeHistoryEvents",
      "Zacro.beginHistoryVerification", "Zacro.verifyHistoryPage", "Zacro.confirmHistoryVerification",
      "Zacro.acknowledgeHistoryVerification", "Zacro.releaseHistoryVerification", "Zacro.prepareHistoryPublication",
      "Zacro.historyPublications", "Zacro.commitHistoryPublication", "Zacro.cancelHistoryPublication",
      "Zacro.finalizeHistoryPublication", "Zacro.createLegacyHistoryBoundary", "Zacro.legacyHistoryBoundaries",
      "Zacro.finalizeLegacyHistoryBoundary", "Zacro.replaceHistoryRetention", "Zacro.historyRetentionStatus", "Zacro.importLegacyHistory", "Zacro.acknowledgeLegacyHistoryImports"});
  if (!methods->contains(method)) return false;
  auto* context = inspected_contents_->GetBrowserContext();
  if (context->IsOffTheRecord()) { ReplyZacro(id, {}, "Private history cannot be mirrored."); return true; }
  const base::DictValue empty;
  ZacroHistoryContext::Get(context)->Execute(inspected_contents_, method, params ? *params : empty,
      base::BindOnce([](base::WeakPtr<CefDevToolsController> self, int id, base::DictValue result, std::string error) {
        if (self) self->ReplyZacro(id, std::move(result), error);
      }, weak_ptr_factory_.GetWeakPtr(), id));
  return true;
}
