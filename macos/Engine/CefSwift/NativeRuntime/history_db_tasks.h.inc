// Staged browser-process DB tasks. Include only after the pinned History hooks.
// Ownership: HistoryService owns the task, its CancelableTaskTracker belongs to
// the exact live profile observer. Done callbacks must still validate that
// observer's lease/revision before replying to the native protocol caller.
#include "base/functional/callback.h"
#include "components/history/core/browser/history_backend.h"
#include "components/history/core/browser/history_database.h"
#include "components/history/core/browser/history_db_task.h"

class ZacroHistoryBarrierTask final : public history::HistoryDBTask {
 public:
  using Completion = base::OnceCallback<void(bool)>;
  explicit ZacroHistoryBarrierTask(Completion completion) : completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* database) override {
    // Ordering only. No rows, deletion result or durability claim is exposed.
    ready_ = backend && database;
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(ready_); }
 private:
  Completion completion_;
  bool ready_ = false;
};

struct ZacroHistoryVerificationInput {
  std::string generation;
  int64_t visit_id = 0;
  int64_t time_microseconds = 0;
  std::string url;
  std::string originator;
};

class ZacroHistoryVerificationTask final : public history::HistoryDBTask {
 public:
  struct Row { history::HistoryDatabase::NativeVisitPresence presence; std::string title; };
  using Result = std::optional<std::vector<Row>>;
  using Completion = base::OnceCallback<void(Result)>;
  ZacroHistoryVerificationTask(std::vector<ZacroHistoryVerificationInput> inputs,
                              Completion completion)
      : inputs_(std::move(inputs)), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend,
                     history::HistoryDatabase* database) override {
    // Bound both record count and native message allocation. A caller with
    // long addresses uses smaller pages, not truncated identities.
    size_t bytes = 0;
    if (!backend || !database || inputs_.size() > 512) return true;
    for (const auto& input : inputs_) {
      if (input.generation.size() > 64 || input.visit_id <= 0 ||
          input.time_microseconds <= 0 || input.url.size() > 8192 ||
          input.originator.size() > 256) return true;
      bytes += input.generation.size() + input.url.size() + input.originator.size() + 64;
      if (bytes > 1024 * 1024) return true;
    }
    if (!database->InitializeNativeMirrorJournal() ||
        !backend->FlushForNativeMirror()) return true;
    std::vector<Row> values;
    values.reserve(inputs_.size());
    for (const auto& input : inputs_) {
      std::string title;
      const auto value = database->CheckNativeHistoryVisit(input.generation,
          input.visit_id, input.time_microseconds, input.url, input.originator, &title);
      if (value == history::HistoryDatabase::NativeVisitPresence::kError)
        return true;  // Entire page fails; never return the successful prefix.
      values.push_back(Row{value, std::move(title)});
    }
    result_ = std::move(values);
    return true;
  }
  void DoneRunOnMainThread() override {
    std::move(completion_).Run(std::move(result_));
  }
 private:
  std::vector<ZacroHistoryVerificationInput> inputs_;
  Completion completion_;
  Result result_;
};

class ZacroHistoryEventPageTask final : public history::HistoryDBTask {
 public:
  struct Page {
    std::vector<history::HistoryDatabase::NativeMirrorEvent> events;
    bool complete = false;
  };
  using Completion = base::OnceCallback<void(std::optional<Page>)>;
  ZacroHistoryEventPageTask(int64_t after_sequence, size_t limit,
      std::string producer_epoch, std::set<std::string> closed_documents, Completion completion)
      : after_sequence_(after_sequence), limit_(limit), producer_epoch_(std::move(producer_epoch)), closed_documents_(std::move(closed_documents)),
        completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend,
                     history::HistoryDatabase* database) override {
    if (!backend || !database || after_sequence_ < 0 || limit_ < 1 || limit_ > 512 ||
        !database->InitializeNativeMirrorJournal() ||
        !database->PruneNativeMirrorOrphans(producer_epoch_, closed_documents_) ||
        !backend->FlushForNativeMirror()) return true;
    auto rows = database->ReadNativeMirrorEvents(after_sequence_, limit_ + 1);
    // Read also validates/initializes the private schema. No future caller may
    // accidentally publish newly created metadata before its checked COMMIT.
    if (!rows || !backend->FlushForNativeMirror()) return true;
    Page page;
    page.complete = rows->size() <= limit_;
    if (!page.complete) rows->resize(limit_);
    page.events = std::move(*rows);
    result_ = std::move(page);
    return true;
  }
  void DoneRunOnMainThread() override {
    std::move(completion_).Run(std::move(result_));
  }
 private:
  int64_t after_sequence_;
  size_t limit_;
  std::string producer_epoch_;
  std::set<std::string> closed_documents_;
  Completion completion_;
  std::optional<Page> result_;
};

class ZacroHistoryAcknowledgeTask final : public history::HistoryDBTask {
 public:
  using Completion = base::OnceCallback<void(bool)>;
  ZacroHistoryAcknowledgeTask(std::vector<std::string> event_ids, Completion completion)
      : event_ids_(std::move(event_ids)), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend,
                     history::HistoryDatabase* database) override {
    // Ack is deliberately idempotent. A previously removed event is successful
    // only after this same native DB's checked transaction commit succeeds.
    result_ = backend && database &&
        database->AcknowledgeNativeMirrorEvents(event_ids_) && backend->FlushForNativeMirror();
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(result_); }
 private:
  std::vector<std::string> event_ids_;
  Completion completion_;
  bool result_ = false;
};

// Preparation is two-phase: its UI producer already retains unpublished
// handoffs before this task is posted. A DBTask may be rescheduled behind a
// newer AddPage, so the SQL disposition also overrides stale producer flags.
class ZacroHistoryPreparePublicationTask final : public history::HistoryDBTask {
 public:
  struct Prepared {
    history::HistoryDatabase::NativeMirrorPublication lease;
    std::optional<history::HistoryDatabase::NativeMirrorEvent> captured;
  };
  using Completion = base::OnceCallback<void(std::optional<Prepared>)>;
  ZacroHistoryPreparePublicationTask(
      history::HistoryDatabase::NativeMirrorPublication lease, Completion completion)
      : lease_(std::move(lease)), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend,
                     history::HistoryDatabase* database) override {
    if (!backend || !database || !database->InitializeNativeMirrorJournal() ||
        !backend->FlushForNativeMirror() ||
        !database->PrepareNativeMirrorPublication(lease_)) return true;
    Prepared result;
    result.lease = lease_;
    if (!lease_.captured_event_id.empty()) {
      result.captured = database->ReadNativeMirrorEvent(lease_.captured_event_id);
      if (!result.captured || result.captured->document_token != lease_.document_token ||
          result.captured->publish) return true;
    }
    if (backend->FlushForNativeMirror()) result_ = std::move(result);
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(std::move(result_)); }
 private:
  history::HistoryDatabase::NativeMirrorPublication lease_;
  Completion completion_;
  std::optional<Prepared> result_;
};

class ZacroHistoryPublicationMutationTask final : public history::HistoryDBTask {
 public:
  enum class Action { kCommit, kCancel, kFinalize };
  using Completion = base::OnceCallback<void(bool)>;
  ZacroHistoryPublicationMutationTask(Action action,
      history::HistoryDatabase::NativeMirrorPublication lease,
      std::string logical_id, Completion completion)
      : action_(action), lease_(std::move(lease)), logical_id_(std::move(logical_id)),
        completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend,
                     history::HistoryDatabase* database) override {
    if (!backend || !database || !database->InitializeNativeMirrorJournal() ||
        !backend->FlushForNativeMirror()) return true;
    bool changed = false;
    switch (action_) {
      case Action::kCommit:
        changed = database->CommitNativeMirrorPublication(lease_, logical_id_); break;
      case Action::kCancel:
        changed = logical_id_.empty() && database->CancelNativeMirrorPublication(lease_); break;
      case Action::kFinalize:
        changed = database->FinalizeNativeMirrorPublication(lease_, logical_id_); break;
    }
    result_ = changed && backend->FlushForNativeMirror();
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(result_); }
 private:
  Action action_;
  history::HistoryDatabase::NativeMirrorPublication lease_;
  std::string logical_id_;
  Completion completion_;
  bool result_ = false;
};

class ZacroHistoryPublicationListTask final : public history::HistoryDBTask {
 public:
  using Result = std::optional<std::vector<history::HistoryDatabase::NativeMirrorPublication>>;
  using Completion = base::OnceCallback<void(Result)>;
  explicit ZacroHistoryPublicationListTask(Completion completion)
      : completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend,
                     history::HistoryDatabase* database) override {
    if (!backend || !database || !database->InitializeNativeMirrorJournal() ||
        !backend->FlushForNativeMirror()) return true;
    auto result = database->ReadNativeMirrorPublications();
    // The schema/generation reader can mutate. Its post-read commit is part of
    // the proof even when a preceding checked flush succeeded.
    if (result && backend->FlushForNativeMirror()) result_ = std::move(result);
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(std::move(result_)); }
 private:
  Completion completion_;
  Result result_;
};

class ZacroHistoryLegacyImportTask final : public history::HistoryDBTask {
 public:
  using Result = std::optional<std::vector<history::NativeHistoryLegacyResult>>;
  using Completion = base::OnceCallback<void(Result)>;
  ZacroHistoryLegacyImportTask(std::vector<history::NativeHistoryLegacyInput> inputs, Completion completion)
      : inputs_(std::move(inputs)), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* database) override {
    if (backend && database) result_ = backend->ImportNativeLegacyHistory(inputs_);
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(std::move(result_)); }
 private:
  std::vector<history::NativeHistoryLegacyInput> inputs_;
  Completion completion_;
  Result result_;
};

class ZacroHistoryLegacyAcknowledgeTask final : public history::HistoryDBTask {
 public:
  using Completion = base::OnceCallback<void(bool)>;
  ZacroHistoryLegacyAcknowledgeTask(std::vector<std::pair<std::string, std::string>> entries, Completion completion)
      : entries_(std::move(entries)), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* database) override {
    result_ = backend && database && database->InitializeNativeMirrorJournal() &&
        backend->FlushForNativeMirror() && database->AcknowledgeNativeLegacyImports(entries_) &&
        backend->FlushForNativeMirror();
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(result_); }
 private:
  std::vector<std::pair<std::string, std::string>> entries_;
  Completion completion_;
  bool result_ = false;
};

class ZacroHistoryRetentionTask final : public history::HistoryDBTask {
 public:
  using Completion = base::OnceCallback<void(bool)>;
  ZacroHistoryRetentionTask(std::vector<history::NativeHistoryRetention> identities, Completion completion)
      : identities_(std::move(identities)), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* database) override {
    result_ = backend && database && backend->ReplaceNativeHistoryRetention(identities_);
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(result_); }
 private:
  std::vector<history::NativeHistoryRetention> identities_;
  Completion completion_;
  bool result_ = false;
};

class ZacroHistoryRetentionStatusTask final : public history::HistoryDBTask {
 public:
  using Result = std::optional<std::pair<int64_t, int>>;
  using Completion = base::OnceCallback<void(Result)>;
  explicit ZacroHistoryRetentionStatusTask(Completion completion) : completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* database) override {
    if (backend && database && database->InitializeNativeMirrorJournal() && backend->FlushForNativeMirror())
      result_ = database->NativeHistoryRetentionStatus();
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(std::move(result_)); }
 private:
  Completion completion_;
  Result result_;
};

class ZacroHistoryLegacyBoundaryTask final : public history::HistoryDBTask {
 public:
  enum class Action { kCreate, kList, kFinalize };
  using Result = std::optional<std::vector<std::string>>;
  using Completion = base::OnceCallback<void(Result)>;
  ZacroHistoryLegacyBoundaryTask(Action action, std::string lease, bool completed_initial, Completion completion)
      : action_(action), lease_(std::move(lease)), completed_initial_(completed_initial), completion_(std::move(completion)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* database) override {
    if (!backend || !database || !database->InitializeNativeMirrorJournal() || !backend->FlushForNativeMirror()) return true;
    if (action_ == Action::kCreate) {
      const auto lease = database->CreateNativeLegacyBoundary();
      if (lease && backend->FlushForNativeMirror()) result_ = std::vector<std::string>{*lease};
    } else if (action_ == Action::kList) {
      result_ = database->ReadNativeLegacyBoundaries();
      if (!backend->FlushForNativeMirror()) result_.reset();
    } else if (database->FinalizeNativeLegacyBoundary(lease_, completed_initial_) && backend->FlushForNativeMirror()) {
      result_ = std::vector<std::string>{};
    }
    return true;
  }
  void DoneRunOnMainThread() override { std::move(completion_).Run(std::move(result_)); }
 private:
  Action action_;
  std::string lease_;
  bool completed_initial_;
  Completion completion_;
  Result result_;
};
