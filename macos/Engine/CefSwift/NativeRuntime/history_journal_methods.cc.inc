bool HistoryDatabase::InitializeNativeMirrorJournal(bool create, bool allow_reset) {
  if (!db_.is_open() || native_history_legacy_deletion_failed_) return false;
  if (!NativeHistoryGeneration(create)) {
    // A genuine deleteAll retry may have an interrupted reset marker. Only
    // its pre-deletion scope writer can initialize/validate schema here; normal
    // observers and readers still reject that marker as unavailable.
    if (!allow_reset) return false;
    sql::Statement reset(db_.GetUniqueStatement(
        "SELECT value FROM meta WHERE key='zacro.native.history.generation.v1'"));
    if (!reset.Step()) return false;
    const std::string value = reset.ColumnString(0), prefix = "resetting:";
    if (!value.starts_with(prefix) || !ParseNativeHistoryGeneration(value.substr(prefix.size())) ||
        reset.Step() || !reset.Succeeded()) return false;
  }
  // This is a new, versioned private schema. An existing object with our name
  // must match exactly; IF NOT EXISTS alone accepts malformed tables/views.
  const std::pair<std::string, std::string> schema[] = {
      {"zacro_native_visit_events",
       "CREATE TABLE zacro_native_visit_events("
       "sequence INTEGER PRIMARY KEY AUTOINCREMENT,"
       "event_id TEXT NOT NULL UNIQUE,document_token TEXT NOT NULL,producer_epoch TEXT NOT NULL,"
       "logical_id TEXT NOT NULL,generation TEXT NOT NULL,visit_id INTEGER NOT NULL,"
       "visit_time INTEGER NOT NULL,publish INTEGER NOT NULL,preview INTEGER NOT NULL,library_visit INTEGER NOT NULL)"},
      {"zacro_native_preview_document",
       "CREATE INDEX zacro_native_preview_document ON "
       "zacro_native_visit_events(document_token,publish)"},
      {"zacro_native_publications",
       "CREATE TABLE zacro_native_publications(lease_id TEXT PRIMARY KEY,"
       "document_token TEXT NOT NULL UNIQUE,preview INTEGER NOT NULL,"
       "captured_event_id TEXT NOT NULL,logical_id TEXT NOT NULL,disposition INTEGER NOT NULL)"},
      {"zacro_native_retained_visits",
       "CREATE TABLE zacro_native_retained_visits(generation TEXT NOT NULL,visit_id INTEGER NOT NULL,"
       "visit_time INTEGER NOT NULL,PRIMARY KEY(generation,visit_id))"},
      {"zacro_native_legacy_state",
       "CREATE TABLE zacro_native_legacy_state(singleton INTEGER PRIMARY KEY,initialized INTEGER NOT NULL)"},
      {"zacro_native_legacy_boundaries",
       "CREATE TABLE zacro_native_legacy_boundaries(lease_id TEXT PRIMARY KEY,generation TEXT NOT NULL,sequence INTEGER NOT NULL)"},
      {"zacro_native_legacy_deletions",
       "CREATE TABLE zacro_native_legacy_deletions(sequence INTEGER PRIMARY KEY AUTOINCREMENT,url_hash TEXT NOT NULL,"
       "begin_time INTEGER NOT NULL,end_time INTEGER NOT NULL,inclusive_end INTEGER NOT NULL)"},
      {"zacro_native_legacy_imports",
       "CREATE TABLE zacro_native_legacy_imports(import_id TEXT PRIMARY KEY,"
       "generation TEXT NOT NULL,visit_id INTEGER NOT NULL,visit_time INTEGER NOT NULL,"
       "url_hash TEXT NOT NULL,boundary_id TEXT NOT NULL)"},
  };
  for (const auto& [name, expected] : schema) {
    sql::Statement query(db_.GetUniqueStatement(
        "SELECT sql FROM sqlite_master WHERE name=?"));
    query.BindString(0, name);
    if (query.Step()) {
      if (query.ColumnString(0) != expected || query.Step() || !query.Succeeded()) return false;
    } else {
      if (!query.Succeeded() || !create || !db_.Execute(expected)) return false;
    }
  }
  if (create && !db_.Execute("INSERT OR IGNORE INTO zacro_native_legacy_state(singleton,initialized) VALUES(1,0)")) return false;
  return true;
}

bool HistoryDatabase::RecordNativeMirrorVisit(
    const NativeHistoryDocument& document, VisitID visit_id,
    base::Time visit_time) {
  if (!HasActiveTransactions() || visit_id <= 0 || visit_time.is_null() ||
      !base::Uuid::ParseLowercase(document.document_token).is_valid() ||
      !base::Uuid::ParseLowercase(document.producer_epoch).is_valid() ||
      !base::Uuid::ParseLowercase(document.event_id).is_valid() ||
      document.logical_id.empty() || document.logical_id.size() > 1024 ||
      document.logical_id.find('\0') != std::string::npos ||
      !InitializeNativeMirrorJournal()) {
    return false;
  }
  NativeHistoryDocument effective = document;
  if (!ResolveNativeMirrorPublication(&effective)) return false;
  // Only the latest unpromoted document visit can become the current Peek.
  // Removing older preview handoffs does not delete actual Chromium history.
  if (effective.preview && !effective.publish &&
      !ForgetNativePreviewDocument(effective.document_token)) return false;
  // Intermediate SPA identities do not represent Library visits. Keep the
  // newest one without allowing a page's pushState loop to fill the durable
  // handoff queue. A captured pending Peek boundary is retained explicitly.
  sql::Statement superseded(db_.GetUniqueStatement(
      "DELETE FROM zacro_native_visit_events WHERE document_token=? AND library_visit=0 "
      "AND NOT EXISTS(SELECT 1 FROM zacro_native_publications p WHERE p.captured_event_id=event_id)"));
  superseded.BindString(0, effective.document_token);
  if (!superseded.Run()) return false;
  sql::Statement count(db_.GetUniqueStatement(
      "SELECT COUNT(*) FROM zacro_native_visit_events"));
  if (!count.Step() || count.ColumnInt64(0) >= 20000) return false;
  const auto generation = NativeHistoryGeneration(false);
  if (!generation) return false;
  sql::Statement insert(db_.GetUniqueStatement(
      "INSERT INTO zacro_native_visit_events(event_id,document_token,logical_id,"
      "generation,visit_id,visit_time,publish,preview,producer_epoch,library_visit) VALUES(?,?,?,?,?,?,?,?,?,?)"));
  insert.BindString(0, document.event_id);
  insert.BindString(1, effective.document_token);
  insert.BindString(2, effective.logical_id);
  insert.BindString(3, *generation);
  insert.BindInt64(4, visit_id);
  insert.BindInt64(5, visit_time.ToDeltaSinceWindowsEpoch().InMicroseconds());
  insert.BindBool(6, effective.publish);
  insert.BindBool(7, effective.preview);
  insert.BindString(8, document.producer_epoch);
  insert.BindBool(9, effective.library_visit);
  return insert.Run();
}

std::optional<std::vector<HistoryDatabase::NativeMirrorEvent>>
HistoryDatabase::ReadNativeMirrorEvents(int64_t after_sequence, size_t limit) {
  if (after_sequence < 0 || limit == 0 || limit > 513 ||
      !InitializeNativeMirrorJournal()) return std::nullopt;
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT e.sequence,e.event_id,e.document_token,e.logical_id,e.visit_id,"
      "e.visit_time,e.publish,v.visit_time,u.url,v.originator_cache_guid,u.id,e.generation,e.preview,u.title,e.library_visit "
      "FROM zacro_native_visit_events e LEFT JOIN visits v ON v.id=e.visit_id "
      "LEFT JOIN urls u ON u.id=v.url WHERE e.sequence>? "
      "ORDER BY e.sequence LIMIT ?"));
  query.BindInt64(0, after_sequence);
  query.BindInt64(1, static_cast<int64_t>(limit));
  std::vector<NativeMirrorEvent> result;
  while (query.Step()) {
    NativeMirrorEvent row;
    row.sequence = query.ColumnInt64(0);
    row.event_id = query.ColumnString(1);
    row.document_token = query.ColumnString(2);
    row.logical_id = query.ColumnString(3);
    row.visit_id = query.ColumnInt64(4);
    row.time_microseconds = query.ColumnInt64(5);
    row.publish = query.ColumnBool(6);
    row.preview = query.ColumnBool(12);
    row.library_visit = query.ColumnBool(14);
    row.generation = query.ColumnString(11);
    if (row.sequence <= after_sequence || row.visit_id <= 0 ||
        row.time_microseconds <= 0 ||
        !base::Uuid::ParseLowercase(row.event_id).is_valid() ||
        !base::Uuid::ParseLowercase(row.document_token).is_valid() ||
        row.logical_id.empty() || row.logical_id.size() > 1024 ||
        row.logical_id.find('\0') != std::string::npos ||
        (query.ColumnInt(6) != 0 && query.ColumnInt(6) != 1) ||
        (query.ColumnInt(12) != 0 && query.ColumnInt(12) != 1) ||
        (query.ColumnInt(14) != 0 && query.ColumnInt(14) != 1)) return std::nullopt;
    const auto generation_state = CompareNativeHistoryGeneration(row.generation);
    if (generation_state == NativeVisitPresence::kError) return std::nullopt;
    if (generation_state == NativeVisitPresence::kAbsent ||
        query.GetColumnType(7) == sql::ColumnType::kNull ||
        query.ColumnInt64(7) != row.time_microseconds) {
      // deleteAll can reuse numeric VisitIDs. A different native visit time
      // cannot revive this old event, even if it happens to visit the same URL.
      row.presence = NativeVisitPresence::kAbsent;
    } else if (query.GetColumnType(10) == sql::ColumnType::kNull) {
      return std::nullopt;  // Dangling URL is DB corruption, never absence.
    } else {
      row.url = query.ColumnString(8);
      row.originator = query.ColumnString(9);
      // Display text is bounded independently of exact identity. Truncating a
      // title does not weaken URL/VisitID/time verification or erase a visit.
      row.title = std::string(base::TruncateUTF8ToByteSize(query.ColumnString(13), 8192));
      const GURL url(row.url);
      if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() ||
          url.has_username() || url.has_password() || row.url.size() > 8192 ||
          !row.originator.empty()) return std::nullopt;
      row.presence = NativeVisitPresence::kPresent;
    }
    result.push_back(std::move(row));
  }
  if (!query.Succeeded()) return std::nullopt;
  return result;
}

std::optional<HistoryDatabase::NativeMirrorEvent>
HistoryDatabase::ReadNativeMirrorEvent(const std::string& event_id) {
  if (!base::Uuid::ParseLowercase(event_id).is_valid() ||
      !InitializeNativeMirrorJournal()) return std::nullopt;
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT sequence FROM zacro_native_visit_events WHERE event_id=?"));
  query.BindString(0, event_id);
  if (!query.Step()) return std::nullopt;
  const int64_t sequence = query.ColumnInt64(0);
  if (sequence <= 0 || query.Step() || !query.Succeeded()) return std::nullopt;
  auto rows = ReadNativeMirrorEvents(sequence - 1, 1);
  if (!rows || rows->size() != 1 || rows->front().event_id != event_id)
    return std::nullopt;
  return std::move(rows->front());
}

bool HistoryDatabase::AcknowledgeNativeMirrorEvents(
    const std::vector<std::string>& event_ids) {
  if (event_ids.size() > 512 || !InitializeNativeMirrorJournal()) return false;
  // Validate every identity before mutating any row. The owning DBTask must
  // call FlushForNativeMirror and report failure if COMMIT fails.
  for (const auto& id : event_ids)
    if (!base::Uuid::ParseLowercase(id).is_valid()) return false;
  // Core has committed these visits. Protect that exact tuple before dropping
  // its journal from automatic age expiry; explicit user/API deletion bypasses retention.
  for (const auto& id : event_ids) {
    sql::Statement query(db_.GetUniqueStatement(
        "SELECT generation,visit_id,visit_time,publish,library_visit FROM zacro_native_visit_events WHERE event_id=?"));
    query.BindString(0, id);
    if (query.Step()) {
      if (query.ColumnBool(3) && query.ColumnBool(4) && !RetainNativeMirrorVisit({query.ColumnString(0), query.ColumnInt64(1), query.ColumnInt64(2)})) return false;
      if (query.Step() || !query.Succeeded()) return false;
    } else if (!query.Succeeded()) return false;
  }
  sql::Statement remove(db_.GetUniqueStatement(
      "DELETE FROM zacro_native_visit_events WHERE event_id=?"));
  for (const auto& id : event_ids) {
    remove.Reset(true);
    remove.BindString(0, id);
    if (!remove.Run()) return false;
  }
  return true;
}

bool HistoryDatabase::ForgetNativePreviewDocument(
    const std::string& document_token) {
  if (!base::Uuid::ParseLowercase(document_token).is_valid()) return false;
  sql::Statement remove(db_.GetUniqueStatement(
      "DELETE FROM zacro_native_visit_events WHERE document_token=? AND publish=0 AND preview=1"));
  remove.BindString(0, document_token);
  return remove.Run();
}

bool HistoryDatabase::PruneNativeMirrorOrphans(const std::string& producer_epoch,
    const std::set<std::string>& closed_documents) {
  if (!HasActiveTransactions() || closed_documents.size() > 20000 ||
      !base::Uuid::ParseLowercase(producer_epoch).is_valid() ||
      !InitializeNativeMirrorJournal()) return false;
  for (const auto& token : closed_documents)
    if (!base::Uuid::ParseLowercase(token).is_valid()) return false;
  // Never prune a document merely absent from an earlier live-token snapshot:
  // a newly created producer can commit while this DB task is queued. Only a
  // prior process epoch or an exact native destruction notification is proof.
  // Publication leases survive producer closure until durable Core replay.
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT DISTINCT e.document_token,e.producer_epoch FROM zacro_native_visit_events e "
      "WHERE e.publish=0 AND NOT EXISTS(SELECT 1 FROM zacro_native_publications p "
      "WHERE p.document_token=e.document_token) LIMIT 20001"));
  std::vector<std::string> orphans;
  size_t examined = 0;
  while (query.Step()) {
    const auto token = query.ColumnString(0), epoch = query.ColumnString(1);
    if (!base::Uuid::ParseLowercase(token).is_valid() ||
        !base::Uuid::ParseLowercase(epoch).is_valid() || ++examined > 20000) return false;
    if (epoch != producer_epoch || closed_documents.contains(token)) orphans.push_back(token);
  }
  if (!query.Succeeded()) return false;
  sql::Statement remove(db_.GetUniqueStatement(
      "DELETE FROM zacro_native_visit_events WHERE document_token=? AND publish=0 "
      "AND NOT EXISTS(SELECT 1 FROM zacro_native_publications p WHERE p.document_token=?)"));
  for (const auto& token : orphans) {
    remove.Reset(true); remove.BindString(0, token); remove.BindString(1, token);
    if (!remove.Run()) return false;
  }
  return true;
}
