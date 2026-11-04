TEST_F(NativeHistoryMirrorDatabaseTest, HighestDeletedVisitIDIsNotReusedAtExactHistoricalTimeAfterRestart) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto first = AddVisit(), highest = AddVisit();
  ASSERT_LT(first.visit_id, highest.visit_id);
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  const auto generation = database_->NativeHistoryGeneration(false); ASSERT_TRUE(generation);
  const auto document = Document();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, highest.visit_id, time_));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  database_->DeleteVisit(highest); database_.reset(); Open();
  transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  // This is a real later user import of the identical URL/time, not a different
  // live clock tick or a deleteAll epoch that would hide rowid reuse.
  const auto replacement = AddVisit();
  EXPECT_GT(replacement.visit_id, highest.visit_id);
  EXPECT_EQ(*generation, database_->NativeHistoryGeneration(false));
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kAbsent, database_->CheckNativeHistoryVisit(*generation,
      highest.visit_id, time_.ToDeltaSinceWindowsEpoch().InMicroseconds(), "https://example.test/native-history", ""));
  const auto old_event = database_->ReadNativeMirrorEvent(document.event_id); ASSERT_TRUE(old_event);
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kAbsent, old_event->presence);
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kPresent, database_->CheckNativeHistoryVisit(*generation,
      replacement.visit_id, time_.ToDeltaSinceWindowsEpoch().InMicroseconds(), "https://example.test/native-history", ""));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}

