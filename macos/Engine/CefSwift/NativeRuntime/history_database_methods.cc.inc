namespace {
std::optional<std::pair<std::string, int64_t>> ParseNativeHistoryGeneration(
    const std::string& value) {
  const auto colon = value.find(':');
  if (colon == std::string::npos) return std::nullopt;
  const std::string database = value.substr(0, colon);
  const std::string counter = value.substr(colon + 1);
  int64_t epoch = 0;
  if (!base::Uuid::ParseLowercase(database).is_valid() ||
      !base::StringToInt64(counter, &epoch) || epoch < 1 ||
      base::NumberToString(epoch) != counter) return std::nullopt;
  return std::make_pair(database, epoch);
}
}  // namespace

std::optional<std::string> HistoryDatabase::NativeHistoryGeneration(bool create) {
  if (!db_.is_open()) return std::nullopt;
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT value FROM meta WHERE key='zacro.native.history.generation.v1'"));
  if (query.Step()) {
    std::string value = query.ColumnString(0);
    return ParseNativeHistoryGeneration(value) ? std::make_optional(value) : std::nullopt;
  }
  // No row is only trustworthy after successful SQL exhaustion. A missing or
  // corrupt database must never masquerade as an empty history snapshot.
  if (!query.Succeeded() || !create) return std::nullopt;
  const std::string value = base::Uuid::GenerateRandomV4().AsLowercaseString() + ":1";
  sql::Statement insert(db_.GetUniqueStatement(
      "INSERT INTO meta(key,value) VALUES('zacro.native.history.generation.v1',?)"));
  insert.BindString(0, value);
  if (!insert.Run()) return std::nullopt;
  return value;
}

bool HistoryDatabase::BeginNativeHistoryTableReset() {
  // Untouched Chrome profiles and ordinary HistoryDatabase callers have no
  // native mirror authority to advance. Preserve their original behavior.
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT value FROM meta WHERE key='zacro.native.history.generation.v1'"));
  if (!query.Step()) {
    if (!query.Succeeded() || !HasActiveTransactions() || !NativeHistoryGeneration(true)) return false;
    return BeginNativeHistoryTableReset();
  }
  if (!HasActiveTransactions()) return false;
  const std::string current = query.ColumnString(0);
  const std::string prefix = "resetting:";
  // An interrupted partial reset remains unavailable after restart. A later
  // genuine deleteAll can complete it; no read silently certifies the old IDs.
  const auto generation = current.starts_with(prefix) ? current.substr(prefix.size()) : current;
  auto parsed = ParseNativeHistoryGeneration(generation);
  if (!parsed || parsed->second == std::numeric_limits<int64_t>::max()) return false;
  sql::Statement update(db_.GetUniqueStatement(
      "UPDATE meta SET value=? WHERE key='zacro.native.history.generation.v1'"));
  update.BindString(0, prefix + generation);
  return update.Run();
}

bool HistoryDatabase::AdvanceNativeHistoryGeneration() {
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT value FROM meta WHERE key='zacro.native.history.generation.v1'"));
  if (!query.Step()) return query.Succeeded();
  if (!HasActiveTransactions()) return false;
  const std::string current = query.ColumnString(0), prefix = "resetting:";
  if (!current.starts_with(prefix)) return false;
  auto parsed = ParseNativeHistoryGeneration(current.substr(prefix.size()));
  if (!parsed || parsed->second == std::numeric_limits<int64_t>::max()) return false;
  sql::Statement update(db_.GetUniqueStatement(
      "UPDATE meta SET value=? WHERE key='zacro.native.history.generation.v1'"));
  update.BindString(0, parsed->first + ":" + base::NumberToString(parsed->second + 1));
  return update.Run();
}

HistoryDatabase::NativeVisitPresence HistoryDatabase::CompareNativeHistoryGeneration(
    const std::string& expected) {
  auto current = NativeHistoryGeneration(false);
  auto want = ParseNativeHistoryGeneration(expected);
  auto have = current ? ParseNativeHistoryGeneration(*current) : std::nullopt;
  // A replaced/corrupt DB is not authority to delete independent Core history.
  if (!want || !have || want->first != have->first || want->second > have->second)
    return NativeVisitPresence::kError;
  // Only this same native DB's committed table recreation proves the old epoch
  // gone. Numeric VisitIDs, times and even identical URLs may then be reused.
  return want->second == have->second ? NativeVisitPresence::kPresent
                                     : NativeVisitPresence::kAbsent;
}

HistoryDatabase::NativeVisitPresence HistoryDatabase::CheckNativeHistoryVisit(
    const std::string& generation, VisitID id, int64_t time_microseconds,
    const std::string& url, const std::string& originator, std::string* title) {
  if (id <= 0 || time_microseconds <= 0 || url.empty() || url.size() > 8192 ||
      originator.size() > 256) return NativeVisitPresence::kError;
  const auto generation_state = CompareNativeHistoryGeneration(generation);
  if (generation_state != NativeVisitPresence::kPresent) return generation_state;
  sql::Statement query(db_.GetUniqueStatement(
      "SELECT v.visit_time,u.url,v.originator_cache_guid,u.id,u.title "
      "FROM visits v LEFT JOIN urls u ON u.id=v.url WHERE v.id=?"));
  query.BindInt64(0, id);
  if (!query.Step()) {
    return query.Succeeded() ? NativeVisitPresence::kAbsent
                             : NativeVisitPresence::kError;
  }
  if (query.GetColumnType(3) == sql::ColumnType::kNull)
    return NativeVisitPresence::kError;
  const bool same = query.ColumnInt64(0) == time_microseconds &&
      query.ColumnString(1) == url && query.ColumnString(2) == originator;
  if (same && title) *title = std::string(base::TruncateUTF8ToByteSize(query.ColumnString(4), 2000));
  return same ? NativeVisitPresence::kPresent : NativeVisitPresence::kAbsent;
}
