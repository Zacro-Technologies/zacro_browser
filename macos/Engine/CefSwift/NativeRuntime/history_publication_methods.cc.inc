namespace {
bool ValidNativePublication(const HistoryDatabase::NativeMirrorPublication& value) {
  return base::Uuid::ParseLowercase(value.lease_id).is_valid() &&
      base::Uuid::ParseLowercase(value.document_token).is_valid() &&
      (value.captured_event_id.empty() || (value.preview &&
       base::Uuid::ParseLowercase(value.captured_event_id).is_valid()));
}
bool SameNativePublication(const HistoryDatabase::NativeMirrorPublication& a,
                           const HistoryDatabase::NativeMirrorPublication& b) {
  return a.lease_id == b.lease_id && a.document_token == b.document_token &&
      a.preview == b.preview && a.captured_event_id == b.captured_event_id;
}
bool ValidNativeLogicalID(const std::string& id) {
  return !id.empty() && id.size() <= 1024 && id.find('\0') == std::string::npos;
}
}  // namespace

std::optional<std::vector<HistoryDatabase::NativeMirrorPublication>>
HistoryDatabase::ReadNativeMirrorPublications() {
  if (!InitializeNativeMirrorJournal()) return std::nullopt;
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT lease_id,document_token,preview,captured_event_id,logical_id,disposition "
      "FROM zacro_native_publications ORDER BY lease_id LIMIT 1001"));
  std::vector<NativeMirrorPublication> result;
  while (query.Step()) {
    NativeMirrorPublication value;
    value.lease_id = query.ColumnString(0);
    value.document_token = query.ColumnString(1);
    value.preview = query.ColumnBool(2);
    value.captured_event_id = query.ColumnString(3);
    value.logical_id = query.ColumnString(4);
    const int disposition = query.ColumnInt(5);
    if (!ValidNativePublication(value) || result.size() >= 1000 ||
        (query.ColumnInt(2) != 0 && query.ColumnInt(2) != 1) ||
        disposition < 0 || disposition > 2 ||
        (disposition == 1 ? !ValidNativeLogicalID(value.logical_id)
                          : !value.logical_id.empty())) return std::nullopt;
    value.disposition = static_cast<NativeMirrorPublication::Disposition>(disposition);
    result.push_back(std::move(value));
  }
  if (!query.Succeeded()) return std::nullopt;
  return result;
}

bool HistoryDatabase::PrepareNativeMirrorPublication(
    const NativeMirrorPublication& lease) {
  using Disposition = NativeMirrorPublication::Disposition;
  if (!HasActiveTransactions() || !ValidNativePublication(lease) ||
      lease.disposition != Disposition::kPrepared || !lease.logical_id.empty()) return false;
  const auto leases = ReadNativeMirrorPublications();
  if (!leases) return false;
  for (const auto& existing : *leases) {
    if (existing.lease_id == lease.lease_id || existing.document_token == lease.document_token)
      return SameNativePublication(existing, lease) && existing.disposition == Disposition::kPrepared;
  }
  if (leases->size() >= 1000) return false;
  if (!lease.captured_event_id.empty()) {
    sql::Statement captured(db_.GetUniqueStatement(
        "SELECT document_token,publish FROM zacro_native_visit_events WHERE event_id=?"));
    captured.BindString(0, lease.captured_event_id);
    if (!captured.Step() || captured.ColumnString(0) != lease.document_token ||
        captured.ColumnInt(1) != 0 || captured.Step() || !captured.Succeeded()) return false;
  }
  sql::Statement insert(db_.GetUniqueStatement(
      "INSERT INTO zacro_native_publications(lease_id,document_token,preview,"
      "captured_event_id,logical_id,disposition) VALUES(?,?,?,?,'',0)"));
  insert.BindString(0, lease.lease_id);
  insert.BindString(1, lease.document_token);
  insert.BindBool(2, lease.preview);
  insert.BindString(3, lease.captured_event_id);
  if (!insert.Run()) return false;
  if (lease.preview) {
    // Pending producer handoffs carry preview=false. Keep the exact captured
    // event and those later handoffs, never an earlier unpromoted document.
    sql::Statement prune(db_.GetUniqueStatement(
        "DELETE FROM zacro_native_visit_events WHERE document_token=? AND "
        "publish=0 AND preview=1 AND event_id<>?"));
    prune.BindString(0, lease.document_token);
    prune.BindString(1, lease.captured_event_id);
    if (!prune.Run()) return false;
  }
  return true;
}

bool HistoryDatabase::ResolveNativeMirrorPublication(NativeHistoryDocument* document) {
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT preview,logical_id,disposition FROM zacro_native_publications WHERE document_token=?"));
  query.BindString(0, document->document_token);
  if (!query.Step()) return query.Succeeded();  // No lease is an ordinary visit.
  const int preview = query.ColumnInt(0), disposition = query.ColumnInt(2);
  const std::string logical_id = query.ColumnString(1);
  if ((preview != 0 && preview != 1) || disposition < 0 || disposition > 2 ||
      (disposition == 1 ? !ValidNativeLogicalID(logical_id) : !logical_id.empty()) ||
      query.Step() || !query.Succeeded()) return false;
  if (disposition == 1) {
    document->logical_id = logical_id;
    document->publish = true;
    document->preview = false;
  } else {
    document->publish = false;
    // Prepared preserves every handoff; cancelled restores original Peek vs
    // provisional-popup semantics even for old flags still queued on the DB.
    document->preview = disposition == 2 && preview == 1;
  }
  return true;
}

bool HistoryDatabase::CommitNativeMirrorPublication(
    const NativeMirrorPublication& lease, const std::string& logical_id) {
  using Disposition = NativeMirrorPublication::Disposition;
  if (!HasActiveTransactions() || !ValidNativePublication(lease) ||
      !ValidNativeLogicalID(logical_id)) return false;
  const auto leases = ReadNativeMirrorPublications();
  if (!leases) return false;
  const NativeMirrorPublication* found = nullptr;
  for (const auto& value : *leases) if (value.lease_id == lease.lease_id) found = &value;
  if (!found || !SameNativePublication(*found, lease) ||
      found->disposition == Disposition::kCancelled ||
      (found->disposition == Disposition::kCommitted && found->logical_id != logical_id)) return false;
  sql::Statement update(db_.GetUniqueStatement(
      "UPDATE zacro_native_publications SET logical_id=?,disposition=1 WHERE lease_id=?"));
  update.BindString(0, logical_id); update.BindString(1, lease.lease_id);
  if (!update.Run()) return false;
  sql::Statement publish(db_.GetUniqueStatement(
      "UPDATE zacro_native_visit_events SET logical_id=?,publish=1,preview=0,"
      "library_visit=CASE WHEN event_id=? THEN 1 ELSE library_visit END "
      "WHERE document_token=? AND publish=0"));
  publish.BindString(0, logical_id); publish.BindString(1, lease.captured_event_id);
  publish.BindString(2, lease.document_token);
  return publish.Run();
}

bool HistoryDatabase::CancelNativeMirrorPublication(const NativeMirrorPublication& lease) {
  using Disposition = NativeMirrorPublication::Disposition;
  if (!HasActiveTransactions() || !ValidNativePublication(lease)) return false;
  const auto leases = ReadNativeMirrorPublications();
  if (!leases) return false;
  const NativeMirrorPublication* found = nullptr;
  for (const auto& value : *leases) if (value.lease_id == lease.lease_id) found = &value;
  if (!found || !SameNativePublication(*found, lease) ||
      found->disposition == Disposition::kCommitted) return false;
  sql::Statement update(db_.GetUniqueStatement(
      "UPDATE zacro_native_publications SET disposition=2 WHERE lease_id=?"));
  update.BindString(0, lease.lease_id);
  if (!update.Run()) return false;
  if (lease.preview) {
    sql::Statement prune(db_.GetUniqueStatement(
        "DELETE FROM zacro_native_visit_events WHERE document_token=? AND publish=0 AND sequence<>"
        "(SELECT MAX(sequence) FROM zacro_native_visit_events WHERE document_token=? AND publish=0)"));
    prune.BindString(0, lease.document_token); prune.BindString(1, lease.document_token);
    if (!prune.Run()) return false;
    sql::Statement latest(db_.GetUniqueStatement(
        "UPDATE zacro_native_visit_events SET preview=1 WHERE document_token=? AND publish=0"));
    latest.BindString(0, lease.document_token);
    if (!latest.Run()) return false;
  }
  return true;
}

bool HistoryDatabase::FinalizeNativeMirrorPublication(
    const NativeMirrorPublication& lease, const std::string& logical_id) {
  using Disposition = NativeMirrorPublication::Disposition;
  if (!HasActiveTransactions() || !ValidNativePublication(lease)) return false;
  const auto leases = ReadNativeMirrorPublications();
  if (!leases) return false;
  for (const auto& value : *leases) if (value.lease_id == lease.lease_id) {
    if (!SameNativePublication(value, lease) || value.logical_id != logical_id ||
        value.disposition == Disposition::kPrepared) return false;
    sql::Statement remove(db_.GetUniqueStatement(
        "DELETE FROM zacro_native_publications WHERE lease_id=?"));
    remove.BindString(0, lease.lease_id);
    return remove.Run();
  }
  // Finalization cannot authorize publication, so a repeated delete is safe.
  return true;
}
