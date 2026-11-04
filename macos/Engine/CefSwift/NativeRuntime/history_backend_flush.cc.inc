bool HistoryBackend::FlushForNativeMirror() {
  // Only the owning backend may end its long-running transaction. A DBTask
  // cannot call HistoryDatabase::CreateTransaction or silently ignore COMMIT.
  if (!db_ || native_history_mirror_failed_)
    return false;
  CancelScheduledCommit();
  bool committed = true;
  if (singleton_transaction_) {
    committed = singleton_transaction_->Commit();
    singleton_transaction_.reset();
  } else if (db_->HasActiveTransactions()) {
    return false;
  }
  // Match the ordinary backend transaction lifecycle even after an I/O error.
  // The caller receives false and must publish neither bindings nor absence.
  BeginSingletonTransaction();
  return committed;
}
