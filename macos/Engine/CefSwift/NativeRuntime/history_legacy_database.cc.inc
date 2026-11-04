namespace {
bool ValidNativeLegacyHash(const std::string& value) {
  return value.size() == 64 && std::ranges::all_of(value, [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
}  // namespace

bool HistoryDatabase::FindNativeLegacyImport(const NativeHistoryLegacyInput& input,
    std::optional<NativeHistoryLegacyResult>* result) {
  if (!result || !ValidNativeLegacyHash(input.import_id) ||
      !ValidNativeLegacyHash(input.requested_url_hash) ||
      !input.url.SchemeIsHTTPOrHTTPS() || input.url.has_username() || input.url.has_password() ||
      input.url.spec().size() > 8192 || input.time.is_null() || !InitializeNativeMirrorJournal()) return false;
  result->reset();
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT generation,visit_id,visit_time,url_hash,boundary_id FROM zacro_native_legacy_imports WHERE import_id=?"));
  query.BindString(0, input.import_id);
  if (!query.Step()) return query.Succeeded();
  NativeHistoryLegacyResult value;
  value.import_id = input.import_id; value.generation = query.ColumnString(0);
  value.boundary_id = query.ColumnString(4);
  value.visit_id = query.ColumnInt64(1); value.time_microseconds = query.ColumnInt64(2);
  if (query.ColumnString(3) != input.requested_url_hash || value.boundary_id != input.boundary_id || value.visit_id < 0 ||
      value.time_microseconds != input.time.ToDeltaSinceWindowsEpoch().InMicroseconds() ||
      query.Step() || !query.Succeeded()) return false;
  if (!value.visit_id) { *result = std::move(value); return true; }
  const auto presence = CheckNativeHistoryVisit(value.generation, value.visit_id,
      value.time_microseconds, input.url.spec(), "");
  if (presence == NativeVisitPresence::kError) return false;
  value.present = presence == NativeVisitPresence::kPresent;
  if (value.present) value.url = input.url.spec();
  *result = std::move(value); return true;
}

bool HistoryDatabase::RecordNativeLegacyImport(const NativeHistoryLegacyInput& input, VisitID visit) {
  if (!HasActiveTransactions() || !ValidNativeLegacyHash(input.import_id) ||
      !ValidNativeLegacyHash(input.requested_url_hash) || visit < 0 ||
      !base::Uuid::ParseLowercase(input.boundary_id).is_valid() ||
      input.time.ToDeltaSinceWindowsEpoch().InMicroseconds() <= 0 || !InitializeNativeMirrorJournal()) return false;
  const auto generation = NativeHistoryGeneration(false);
  bool allowed = false;
  if (!generation || !NativeLegacyInputAllowed(input, &allowed) ||
      (visit ? (!allowed || CheckNativeHistoryVisit(*generation, visit,
      input.time.ToDeltaSinceWindowsEpoch().InMicroseconds(), input.url.spec(), "") != NativeVisitPresence::kPresent) : allowed)) return false;
  sql::Statement count(db_.GetUniqueStatement("SELECT COUNT(*) FROM zacro_native_legacy_imports"));
  if (!count.Step() || count.ColumnInt64(0) >= 20000) return false;
  sql::Statement insert(db_.GetUniqueStatement(
      "INSERT INTO zacro_native_legacy_imports(import_id,generation,visit_id,visit_time,url_hash,boundary_id) VALUES(?,?,?,?,?,?)"));
  insert.BindString(0, input.import_id); insert.BindString(1, *generation); insert.BindInt64(2, visit);
  insert.BindInt64(3, input.time.ToDeltaSinceWindowsEpoch().InMicroseconds()); insert.BindString(4, input.requested_url_hash);
  insert.BindString(5, input.boundary_id);
  return insert.Run();
}

bool HistoryDatabase::AcknowledgeNativeLegacyImports(
    const std::vector<std::pair<std::string, std::string>>& identities) {
  if (!HasActiveTransactions() || identities.size() > 512 || !InitializeNativeMirrorJournal()) return false;
  // Validate every generation before deleting any prefix. An old Core ack may
  // never erase a same-ID import in an unrelated/recreated database.
  for (const auto& [id, generation] : identities) {
    if (!ValidNativeLegacyHash(id) || !ParseNativeHistoryGeneration(generation)) return false;
    sql::Statement query(db_.GetUniqueStatement(
        "SELECT generation,visit_id,visit_time FROM zacro_native_legacy_imports WHERE import_id=?"));
    query.BindString(0, id);
    if (query.Step()) {
      if (query.ColumnString(0) != generation ||
          (query.ColumnInt64(1) > 0 && !RetainNativeMirrorVisit({generation, query.ColumnInt64(1), query.ColumnInt64(2)})) ||
          query.Step() || !query.Succeeded()) return false;
    } else if (!query.Succeeded()) return false;
  }
  sql::Statement remove(db_.GetUniqueStatement(
      "DELETE FROM zacro_native_legacy_imports WHERE import_id=? AND generation=?"));
  for (const auto& [id, generation] : identities) {
    remove.Reset(true); remove.BindString(0, id); remove.BindString(1, generation);
    if (!remove.Run()) return false;
  }
  return true;
}
