std::optional<std::vector<std::string>> HistoryDatabase::ReadNativeLegacyBoundaries() {
  if (!InitializeNativeMirrorJournal()) return std::nullopt;
  sql::Statement rows(db_.GetUniqueStatement("SELECT lease_id FROM zacro_native_legacy_boundaries ORDER BY lease_id LIMIT 1001"));
  std::vector<std::string> values;
  while (rows.Step()) {
    const auto id = rows.ColumnString(0);
    if (!base::Uuid::ParseLowercase(id).is_valid() || values.size() >= 1000) return std::nullopt;
    values.push_back(id);
  }
  if (!rows.Succeeded()) return std::nullopt;
  return values;
}

std::optional<std::string> HistoryDatabase::CreateNativeLegacyBoundary() {
  if (!HasActiveTransactions() || !InitializeNativeMirrorJournal()) return std::nullopt;
  const auto existing = ReadNativeLegacyBoundaries();
  const auto generation = NativeHistoryGeneration(false);
  if (!existing || !generation || existing->size() >= 1000) return std::nullopt;
  sql::Statement state(db_.GetUniqueStatement("SELECT initialized FROM zacro_native_legacy_state WHERE singleton=1"));
  if (!state.Step() || (state.ColumnInt(0) != 0 && state.ColumnInt(0) != 1)) return std::nullopt;
  const bool initialized = state.ColumnBool(0);
  if (state.Step() || !state.Succeeded()) return std::nullopt;
  int64_t boundary = 0;
  if (initialized) {
    sql::Statement sequence(db_.GetUniqueStatement("SELECT COALESCE(MAX(sequence),0) FROM zacro_native_legacy_deletions"));
    if (!sequence.Step()) return std::nullopt;
    boundary = sequence.ColumnInt64(0);
    if (boundary < 0 || sequence.Step() || !sequence.Succeeded()) return std::nullopt;
  }
  const auto lease = base::Uuid::GenerateRandomV4().AsLowercaseString();
  sql::Statement insert(db_.GetUniqueStatement("INSERT INTO zacro_native_legacy_boundaries(lease_id,generation,sequence) VALUES(?,?,?)"));
  insert.BindString(0, lease); insert.BindString(1, *generation); insert.BindInt64(2, boundary);
  if (!insert.Run()) return std::nullopt;
  return lease;
}

bool HistoryDatabase::FinalizeNativeLegacyBoundary(const std::string& lease, bool completed_initial) {
  if (!HasActiveTransactions() || !base::Uuid::ParseLowercase(lease).is_valid() || !InitializeNativeMirrorJournal()) return false;
  sql::Statement exists(db_.GetUniqueStatement("SELECT 1 FROM zacro_native_legacy_boundaries WHERE lease_id=?"));
  exists.BindString(0, lease);
  const bool found = exists.Step();
  if ((found && (exists.Step() || !exists.Succeeded())) || (!found && !exists.Succeeded())) return false;
  if (!found && completed_initial) {
    sql::Statement state(db_.GetUniqueStatement("SELECT initialized FROM zacro_native_legacy_state WHERE singleton=1"));
    if (!state.Step() || state.ColumnInt(0) != 1 || state.Step() || !state.Succeeded()) return false;
    return true;  // Idempotent completed receipt, never new initial authority.
  }
  sql::Statement pending(db_.GetUniqueStatement("SELECT 1 FROM zacro_native_legacy_imports WHERE boundary_id=? LIMIT 1"));
  pending.BindString(0, lease);
  if (pending.Step() || !pending.Succeeded()) return false;
  sql::Statement remove(db_.GetUniqueStatement("DELETE FROM zacro_native_legacy_boundaries WHERE lease_id=?"));
  remove.BindString(0, lease); if (!remove.Run()) return false;
  if (completed_initial && !db_.Execute("UPDATE zacro_native_legacy_state SET initialized=1 WHERE singleton=1")) return false;
  // No new lease may need scopes before the minimum surviving boundary. Keep
  // initial scopes until Core explicitly confirms its complete initial snapshot.
  return db_.Execute("DELETE FROM zacro_native_legacy_deletions WHERE "
      "(SELECT initialized FROM zacro_native_legacy_state WHERE singleton=1)=1 AND sequence<="
      "COALESCE((SELECT MIN(sequence) FROM zacro_native_legacy_boundaries),9223372036854775807)");
}

bool HistoryDatabase::NativeLegacyInputAllowed(const NativeHistoryLegacyInput& input, bool* allowed) {
  if (!allowed || !base::Uuid::ParseLowercase(input.boundary_id).is_valid() || !InitializeNativeMirrorJournal()) return false;
  *allowed = false;
  sql::Statement lease(db_.GetUniqueStatement("SELECT generation,sequence FROM zacro_native_legacy_boundaries WHERE lease_id=?"));
  lease.BindString(0, input.boundary_id);
  if (!lease.Step()) return false;  // Missing proof is unavailable, never a fresh boundary.
  const auto generation = CompareNativeHistoryGeneration(lease.ColumnString(0));
  const int64_t sequence = lease.ColumnInt64(1);
  if (generation == NativeVisitPresence::kError || sequence < 0 || lease.Step() || !lease.Succeeded()) return false;
  if (generation == NativeVisitPresence::kAbsent) return true;
  sql::Statement scopes(db_.GetUniqueStatement(
      "SELECT 1 FROM zacro_native_legacy_deletions WHERE sequence>? AND (url_hash='' OR url_hash=?) "
      "AND begin_time<=? AND (end_time>? OR (inclusive_end=1 AND end_time=?)) LIMIT 1"));
  const auto canonical_hash = base::HexEncodeLower(crypto::hash::Sha256(input.url.spec()));
  const int64_t time = input.time.ToDeltaSinceWindowsEpoch().InMicroseconds();
  scopes.BindInt64(0, sequence); scopes.BindString(1, canonical_hash);
  scopes.BindInt64(2, time); scopes.BindInt64(3, time); scopes.BindInt64(4, time);
  if (scopes.Step()) return true;
  if (!scopes.Succeeded()) return false;
  *allowed = true; return true;
}

bool HistoryDatabase::RecordNativeLegacyDeletion(const std::optional<GURL>& url,
    base::Time begin, base::Time end, bool inclusive_end, bool allow_reset) {
  if (!InitializeNativeMirrorJournal(/*create=*/true, allow_reset)) return false;
  sql::Statement needed(db_.GetUniqueStatement("SELECT initialized=0 OR EXISTS(SELECT 1 FROM zacro_native_legacy_boundaries) "
      "FROM zacro_native_legacy_state WHERE singleton=1"));
  if (!needed.Step()) return false;
  const bool capture = needed.ColumnBool(0);
  if (needed.Step() || !needed.Succeeded()) return false;
  if (!capture) return true;
  sql::Statement count(db_.GetUniqueStatement("SELECT COUNT(*) FROM zacro_native_legacy_deletions"));
  if (!count.Step() || count.ColumnInt64(0) >= 20000) return false;
  const int64_t first = begin.is_null() ? 0 : begin.ToDeltaSinceWindowsEpoch().InMicroseconds();
  const int64_t last = end.is_null() || end.is_max() ? std::numeric_limits<int64_t>::max()
      : end.ToDeltaSinceWindowsEpoch().InMicroseconds();
  sql::Statement insert(db_.GetUniqueStatement("INSERT INTO zacro_native_legacy_deletions(url_hash,begin_time,end_time,inclusive_end) VALUES(?,?,?,?)"));
  insert.BindString(0, url ? base::HexEncodeLower(crypto::hash::Sha256(url->spec())) : "");
  insert.BindInt64(1, first); insert.BindInt64(2, last); insert.BindBool(3, inclusive_end);
  return insert.Run();
}

bool HistoryDatabase::RecordNativeLegacyDeletions(
    const std::vector<NativeHistoryDeletionScope>& scopes, bool allow_reset) {
  const auto fail_closed = [&]() {
    native_history_legacy_deletion_failed_ = true;
    // No caller may mutate actual visits after this failure. Checked native
    // observation/import also stays unavailable for this database lifetime.
    // Revoke old migration evidence durably when SQLite can still write, so a
    // restart cannot retry the incomplete batch under its previous lease.
    if (!db_.Execute("DELETE FROM zacro_native_legacy_boundaries"))
      DLOG(ERROR) << "Could not revoke failed native history migration boundaries";
    return false;
  };
  if (native_history_legacy_deletion_failed_) return false;
  if (scopes.size() > 20000 || !InitializeNativeMirrorJournal(/*create=*/true, allow_reset)) return fail_closed();
  // sql::Transaction nesting is virtual and could roll back unrelated real
  // browsing. This local SQLite savepoint owns ONLY the preflight scope rows.
  // A failed later scope cannot leave a false successful prefix behind.
  if (!db_.Execute("SAVEPOINT zacro_native_legacy_deletion_scope")) return fail_closed();
  bool recorded = true;
  for (const auto& scope : scopes) {
    if (!RecordNativeLegacyDeletion(scope.url, scope.begin, scope.end, scope.inclusive_end, allow_reset)) {
      recorded = false; break;
    }
  }
  if (recorded && db_.Execute("RELEASE zacro_native_legacy_deletion_scope")) return true;
  const bool rolled_back = db_.Execute("ROLLBACK TO zacro_native_legacy_deletion_scope");
  const bool released = db_.Execute("RELEASE zacro_native_legacy_deletion_scope");
  if (!rolled_back || !released) DLOG(ERROR) << "Could not roll back failed native history deletion scope";
  return fail_closed();
}
