bool HistoryDatabase::RetainNativeMirrorVisit(const NativeHistoryRetention& identity) {
  if (!HasActiveTransactions() || identity.visit_id <= 0 || identity.time_microseconds <= 0 ||
      !InitializeNativeMirrorJournal()) return false;
  const auto generation = CompareNativeHistoryGeneration(identity.generation);
  if (generation == NativeVisitPresence::kError) return false;
  if (generation == NativeVisitPresence::kAbsent) return true;
  sql::Statement visit(db_.GetUniqueStatement("SELECT visit_time FROM visits WHERE id=?"));
  visit.BindInt64(0, identity.visit_id);
  if (!visit.Step()) return visit.Succeeded();
  if (visit.ColumnInt64(0) != identity.time_microseconds) return true;
  if (visit.Step() || !visit.Succeeded()) return false;
  sql::Statement count(db_.GetUniqueStatement("SELECT COUNT(*) FROM zacro_native_retained_visits"));
  if (!count.Step()) return false;
  if (count.ColumnInt64(0) >= 40000) {
    sql::Statement same(db_.GetUniqueStatement(
        "SELECT 1 FROM zacro_native_retained_visits WHERE generation=? AND visit_id=? AND visit_time=?"));
    same.BindString(0, identity.generation); same.BindInt64(1, identity.visit_id); same.BindInt64(2, identity.time_microseconds);
    if (!same.Step()) return false;
  }
  sql::Statement insert(db_.GetUniqueStatement(
      "INSERT OR REPLACE INTO zacro_native_retained_visits(generation,visit_id,visit_time) VALUES(?,?,?)"));
  insert.BindString(0, identity.generation); insert.BindInt64(1, identity.visit_id); insert.BindInt64(2, identity.time_microseconds);
  return insert.Run();
}

bool HistoryDatabase::ReplaceNativeMirrorRetention(const std::vector<NativeHistoryRetention>& identities) {
  if (!HasActiveTransactions() || identities.size() > 20000 || !InitializeNativeMirrorJournal()) return false;
  for (const auto& identity : identities) {
    if (identity.visit_id <= 0 || identity.time_microseconds <= 0 ||
        CompareNativeHistoryGeneration(identity.generation) == NativeVisitPresence::kError) return false;
  }
  // The owning backend supplies a dedicated atomic transaction. Failed
  // replacement rolls back to the old retention authority, never an empty set.
  if (!db_.Execute("DELETE FROM zacro_native_retained_visits")) return false;
  for (const auto& identity : identities) if (!RetainNativeMirrorVisit(identity)) return false;
  return true;
}

bool HistoryDatabase::ReadNativeExpiringVisits(base::Time begin_time, base::Time end_time,
    int max_visits, std::optional<ui::PageTransition> transition, VisitVector* visits) {
  if (!visits || max_visits <= 0) return false;
  visits->clear();
  if (!transition && native_history_automatic_expiration_reads_ < std::numeric_limits<int64_t>::max())
    ++native_history_automatic_expiration_reads_;
  sql::Statement native(db_.GetUniqueStatement(
      "SELECT value FROM meta WHERE key='zacro.native.history.generation.v1'"));
  if (!native.Step()) {
    if (!native.Succeeded()) return false;
    return transition ? GetVisitsInRangeForTransition(begin_time, end_time, max_visits, *transition, visits)
        : GetAllVisitsInRange(begin_time, end_time, kNoAppIdFilter, max_visits, visits);
  }
  const std::string generation = native.ColumnString(0);
  if (!ParseNativeHistoryGeneration(generation) || native.Step() || !native.Succeeded() ||
      !InitializeNativeMirrorJournal(/*create=*/false)) return false;
  std::string query = "SELECT" HISTORY_VISIT_ROW_FIELDS "FROM visits WHERE visit_time>=? AND visit_time<? ";
  if (transition) query += "AND (transition & ?) == ? ";
  query += "AND NOT EXISTS(SELECT 1 FROM zacro_native_retained_visits r WHERE r.visit_id=visits.id "
      "AND r.visit_time=visits.visit_time AND r.generation=?) "
      "AND NOT EXISTS(SELECT 1 FROM zacro_native_visit_events e WHERE e.visit_id=visits.id "
      "AND e.visit_time=visits.visit_time AND e.generation=? AND e.publish=1 AND e.library_visit=1) "
      "AND NOT EXISTS(SELECT 1 FROM zacro_native_legacy_imports i WHERE i.visit_id=visits.id "
      "AND i.visit_time=visits.visit_time AND i.generation=?) ORDER BY visit_time LIMIT ?";
  sql::Statement rows(db_.GetUniqueStatement(query));
  rows.BindTime(0, begin_time); rows.BindTime(1, end_time);
  int parameter = 2;
  if (transition) {
    rows.BindInt64(parameter++, ui::PAGE_TRANSITION_CORE_MASK); rows.BindInt64(parameter++, *transition);
  }
  rows.BindString(parameter++, generation); rows.BindString(parameter++, generation); rows.BindString(parameter++, generation);
  rows.BindInt(parameter, max_visits);
  return FillVisitVector(rows, visits);
}

std::optional<std::pair<int64_t, int>> HistoryDatabase::NativeHistoryRetentionStatus() {
  if (!InitializeNativeMirrorJournal()) return std::nullopt;
  sql::Statement count(db_.GetUniqueStatement("SELECT COUNT(*) FROM zacro_native_retained_visits"));
  if (!count.Step()) return std::nullopt;
  const int64_t retained = count.ColumnInt64(0);
  if (retained < 0 || retained > 40000 || count.Step() || !count.Succeeded()) return std::nullopt;
  return std::make_pair(native_history_automatic_expiration_reads_, static_cast<int>(retained));
}
