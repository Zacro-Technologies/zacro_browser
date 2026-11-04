bool HistoryBackend::ReplaceNativeHistoryRetention(const std::vector<NativeHistoryRetention>& identities) {
  if (!db_ || native_history_mirror_failed_ || identities.size() > 20000) return false;
  CancelScheduledCommit();
  bool prior_committed = true;
  if (singleton_transaction_) {
    prior_committed = singleton_transaction_->Commit(); singleton_transaction_.reset();
  } else if (db_->HasActiveTransactions()) return false;
  base::ScopedClosureRunner resume(base::BindOnce(&HistoryBackend::BeginSingletonTransaction, base::Unretained(this)));
  if (!prior_committed) return false;
  auto transaction = db_->CreateTransaction();
  if (!transaction->Begin() || !db_->ReplaceNativeMirrorRetention(identities)) return false;
  const bool committed = transaction->Commit(); transaction.reset();
  return committed;
}
