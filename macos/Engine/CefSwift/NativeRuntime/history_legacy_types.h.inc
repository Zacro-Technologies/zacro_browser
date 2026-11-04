// Explicit migration of pre-native Library visits. These records are supplied
// only by the browser-process channel; URL/time proximity is not an identity.
struct NativeHistoryLegacyInput {
  std::string import_id;
  GURL url;
  std::string requested_url_hash;
  base::Time time;
  std::u16string title;
  std::string boundary_id;
};
struct NativeHistoryLegacyResult {
  std::string import_id;
  std::string generation;
  std::string boundary_id;
  VisitID visit_id = 0;
  int64_t time_microseconds = 0;
  bool present = false;
  std::string url;
};

// Opaque retention authority follows the bounded Core Library, which retains
// visits by row count rather than Chromium's automatic age threshold.
struct NativeHistoryRetention {
  std::string generation;
  VisitID visit_id = 0;
  int64_t time_microseconds = 0;
};

// Exact requested deletion semantics, captured BEFORE native row mutation.
struct NativeHistoryDeletionScope {
  std::optional<GURL> url;
  base::Time begin;
  base::Time end;
  bool inclusive_end = false;
};
