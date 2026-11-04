  // Pending native/Core handoff rows live in this same History database. They
  // contain identifiers only, never a duplicate URL/title after native deletion.
  struct NativeMirrorEvent {
    int64_t sequence = 0;
    std::string event_id;
    std::string document_token;
    std::string logical_id;
    std::string generation;
    VisitID visit_id = 0;
    int64_t time_microseconds = 0;
    bool library_visit = true;
    bool publish = false;
    bool preview = false;
    NativeVisitPresence presence = NativeVisitPresence::kError;
    std::string url;
    std::string originator;
    std::string title;
  };
  bool InitializeNativeMirrorJournal(bool create = true, bool allow_reset = false);
  bool RecordNativeMirrorVisit(const NativeHistoryDocument& document,
      VisitID visit_id, base::Time visit_time);
  std::optional<std::vector<NativeMirrorEvent>> ReadNativeMirrorEvents(
      int64_t after_sequence, size_t limit);
  // Missing requested event is an error here: unpublished captured events are
  // never acknowledged before their publication lease has resolved.
  std::optional<NativeMirrorEvent> ReadNativeMirrorEvent(const std::string& event_id);
  bool AcknowledgeNativeMirrorEvents(const std::vector<std::string>& event_ids);
  bool ForgetNativePreviewDocument(const std::string& document_token);
  bool PruneNativeMirrorOrphans(const std::string& producer_epoch,
      const std::set<std::string>& closed_documents);
  struct NativeMirrorPublication {
    std::string lease_id;
    std::string document_token;
    bool preview = false;
    std::string captured_event_id;
    std::string logical_id;
    enum class Disposition { kPrepared = 0, kCommitted = 1, kCancelled = 2 };
    Disposition disposition = Disposition::kPrepared;
  };
  // Preparation records the boundary in the same History transaction. While
  // pending, subsequent Peek events are retained without publishing them.
  bool PrepareNativeMirrorPublication(const NativeMirrorPublication& lease);
  std::optional<std::vector<NativeMirrorPublication>> ReadNativeMirrorPublications();
  bool CommitNativeMirrorPublication(const NativeMirrorPublication& lease,
                                    const std::string& logical_id);
  bool CancelNativeMirrorPublication(const NativeMirrorPublication& lease);
  // Only after Core durably removes its receipt AND purges recovery copies.
  bool FinalizeNativeMirrorPublication(const NativeMirrorPublication& lease,
                                      const std::string& logical_id);
  bool ResolveNativeMirrorPublication(NativeHistoryDocument* document);

