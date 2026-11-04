std::optional<std::vector<NativeHistoryLegacyResult>> HistoryBackend::ImportNativeLegacyHistory(
    const std::vector<NativeHistoryLegacyInput>& inputs) {
  if (!db_ || native_history_mirror_failed_ || inputs.empty() || inputs.size() > 512) return std::nullopt;
  size_t bytes = 0; std::set<std::string> unique;
  for (const auto& input : inputs) {
    bytes += input.url.spec().size() + input.title.size() * sizeof(char16_t) + 128;
    if (!unique.insert(input.import_id).second || input.import_id.size() != 64 ||
        input.requested_url_hash.size() != 64 || !input.url.is_valid() ||
        !input.url.SchemeIsHTTPOrHTTPS() || input.url.has_username() || input.url.has_password() ||
        input.url.spec().size() > 8192 || input.title.size() > 8192 ||
        input.time.ToDeltaSinceWindowsEpoch().InMicroseconds() <= 0 || bytes > 1024 * 1024) return std::nullopt;
  }
  // Preserve unrelated real browsing first, then own a separate atomic SQL
  // transaction for this bounded batch. Never nest virtual sql::Transactions
  // in the backend's singleton: its rollback would affect real browsing too.
  CancelScheduledCommit();
  bool prior_committed = true;
  if (singleton_transaction_) {
    prior_committed = singleton_transaction_->Commit(); singleton_transaction_.reset();
  } else if (db_->HasActiveTransactions()) return std::nullopt;
  base::ScopedClosureRunner resume(base::BindOnce(&HistoryBackend::BeginSingletonTransaction, base::Unretained(this)));
  if (!prior_committed) return std::nullopt;
  auto transaction = db_->CreateTransaction();
  if (!transaction->Begin() || !db_->InitializeNativeMirrorJournal()) return std::nullopt;
  base::AutoReset<bool> importing(&native_history_importing_, true);
  std::vector<NativeHistoryLegacyResult> results;
  for (const auto& input : inputs) {
    std::optional<NativeHistoryLegacyResult> existing;
    if (!db_->FindNativeLegacyImport(input, &existing)) return std::nullopt;
    if (!existing) {
      bool allowed = false;
      if (!db_->NativeLegacyInputAllowed(input, &allowed)) return std::nullopt;
      if (!allowed) {
        if (!db_->RecordNativeLegacyImport(input, 0) || !db_->FindNativeLegacyImport(input, &existing) || !existing) return std::nullopt;
        results.push_back(std::move(*existing)); continue;
      }
      const auto [url_id, visit_id] = AddPageVisit(input.url, input.time, 0, GURL(),
          ui::PageTransitionFromInt(ui::PAGE_TRANSITION_LINK | ui::PAGE_TRANSITION_CHAIN_START | ui::PAGE_TRANSITION_CHAIN_END),
          false, SOURCE_OS_MIGRATION_IMPORTED, VisitResponseCodeCategory::kNot404,
          false, 0, false, VisitContextEphemerality::kNotEphemeral, std::nullopt, std::nullopt);
      if (url_id <= 0 || visit_id <= 0) return std::nullopt;
      // Importing an older visit must not replace a newer native page title.
      // A newly introduced URL can acquire the legacy title when still empty.
      URLRow row;
      if (!db_->GetURLRow(url_id, &row)) return std::nullopt;
      if (row.title().empty() && !input.title.empty()) {
        row.set_title(input.title);
        if (!db_->UpdateURLRow(url_id, row)) return std::nullopt;
      }
      NotifyURLsModified(URLRows{row}, /*is_from_expiration=*/false);
      if (!db_->RecordNativeLegacyImport(input, visit_id) ||
          !db_->FindNativeLegacyImport(input, &existing) || !existing) return std::nullopt;
    }
    results.push_back(std::move(*existing));
  }
  if (!transaction->Commit()) return std::nullopt;
  transaction.reset();
  return results;
}
