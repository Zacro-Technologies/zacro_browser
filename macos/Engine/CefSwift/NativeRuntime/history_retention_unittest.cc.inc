TEST_F(NativeHistoryMirrorDatabaseTest, AutomaticExpirySkipsExactRetainedBeforeLimitButExplicitDeletionStillWorks) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  const auto protected_visit = AddVisit(), ordinary = AddVisit();
  const auto generation = database_->NativeHistoryGeneration(false); ASSERT_TRUE(generation);
  ASSERT_TRUE(database_->ReplaceNativeMirrorRetention({{*generation, protected_visit.visit_id,
      time_.ToDeltaSinceWindowsEpoch().InMicroseconds()}}));
  VisitVector expiring;
  ASSERT_TRUE(database_->ReadNativeExpiringVisits(base::Time(), base::Time::Now(), 1, std::nullopt, &expiring));
  ASSERT_EQ(1u, expiring.size()); EXPECT_EQ(ordinary.visit_id, expiring.front().visit_id);
  const auto status = database_->NativeHistoryRetentionStatus(); ASSERT_TRUE(status);
  EXPECT_EQ(1, status->first); EXPECT_EQ(1, status->second);
  database_->DeleteVisit(protected_visit);
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kAbsent, database_->CheckNativeHistoryVisit(*generation,
      protected_visit.visit_id, time_.ToDeltaSinceWindowsEpoch().InMicroseconds(), "https://example.test/native-history", ""));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}

TEST_F(NativeHistoryMirrorDatabaseTest, SameDocumentNativeEventsKeepNewIdentityAndNoLibraryVisitUntilExplicitPeekPromotion) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  auto full = Document(); const auto first = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(full, first.visit_id, time_));
  auto spa = full; spa.event_id = "e3591e1f-3305-4772-aa58-d59c25a51ff7"; spa.library_visit = false;
  const auto second = AddVisit(); ASSERT_TRUE(database_->RecordNativeMirrorVisit(spa, second.visit_id, time_));
  auto rows = database_->ReadNativeMirrorEvents(0, 512); ASSERT_TRUE(rows); ASSERT_EQ(2u, rows->size());
  EXPECT_EQ(rows->front().document_token, rows->back().document_token);
  EXPECT_NE(rows->front().event_id, rows->back().event_id); EXPECT_NE(rows->front().visit_id, rows->back().visit_id);
  EXPECT_TRUE(rows->front().library_visit); EXPECT_FALSE(rows->back().library_visit);
  // A Peek follows its current actual same-document event, then full-sizing is
  // an explicit user publication of that captured current location.
  spa.event_id = "b7f5a486-d16e-4e5b-942e-6d22d6f6d463"; spa.document_token = "9be23c4e-b52d-4b53-af06-d6aa442fc0f7";
  spa.logical_id = "peek:source"; spa.preview = true; spa.publish = false;
  const auto preview = AddVisit(); ASSERT_TRUE(database_->RecordNativeMirrorVisit(spa, preview.visit_id, time_));
  HistoryDatabase::NativeMirrorPublication publication;
  publication.lease_id = "18352313-9ef0-4791-8ca1-90857edbc8f6"; publication.document_token = spa.document_token;
  publication.preview = true; publication.captured_event_id = spa.event_id;
  ASSERT_TRUE(database_->PrepareNativeMirrorPublication(publication));
  ASSERT_TRUE(database_->CommitNativeMirrorPublication(publication, "promoted"));
  const auto promoted = database_->ReadNativeMirrorEvent(spa.event_id); ASSERT_TRUE(promoted);
  EXPECT_TRUE(promoted->publish); EXPECT_TRUE(promoted->library_visit);
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}
