TEST_F(NativeHistoryMirrorDatabaseTest, UnsubmittedLegacyURLDeletionHasDurableTombstoneAndLaterUserImportIsNewIntent) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto boundary = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(boundary);
  NativeHistoryLegacyInput input;
  input.import_id = std::string(64, 'c'); input.requested_url_hash = std::string(64, 'd');
  input.url = GURL("https://unsubmitted.example/"); input.time = time_; input.boundary_id = *boundary;
  // There is deliberately no native visit/URL to match at this boundary.
  ASSERT_TRUE(database_->RecordNativeLegacyDeletion(input.url, base::Time(), base::Time::Max(), true));
  bool allowed = true; ASSERT_TRUE(database_->NativeLegacyInputAllowed(input, &allowed)); EXPECT_FALSE(allowed);
  ASSERT_TRUE(database_->RecordNativeLegacyImport(input, 0));
  ASSERT_TRUE(transaction->Commit()); transaction.reset(); database_.reset(); Open();
  std::optional<NativeHistoryLegacyResult> retry;
  ASSERT_TRUE(database_->FindNativeLegacyImport(input, &retry)); ASSERT_TRUE(retry); EXPECT_FALSE(retry->present);
  EXPECT_EQ(*boundary, retry->boundary_id); EXPECT_EQ(0, retry->visit_id);
  transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  ASSERT_FALSE(database_->FinalizeNativeLegacyBoundary(*boundary, true));  // Native import ack still owed.
  ASSERT_TRUE(database_->AcknowledgeNativeLegacyImports({{input.import_id, retry->generation}}));
  ASSERT_TRUE(database_->FinalizeNativeLegacyBoundary(*boundary, true));
  const auto later = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(later);
  input.import_id = std::string(64, 'e'); input.boundary_id = *later;
  ASSERT_TRUE(database_->NativeLegacyInputAllowed(input, &allowed)); EXPECT_TRUE(allowed);
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}

TEST_F(NativeHistoryMirrorDatabaseTest, RangeDeletionProofIsExactAndHalfOpenForUnsubmittedLegacyRows) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto boundary = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(boundary);
  NativeHistoryLegacyInput input;
  input.import_id = std::string(64, 'c'); input.requested_url_hash = std::string(64, 'd');
  input.url = GURL("https://unsubmitted.example/"); input.time = time_; input.boundary_id = *boundary;
  ASSERT_TRUE(database_->RecordNativeLegacyDeletion(std::nullopt, time_ - base::Seconds(1), time_));
  bool allowed = false; ASSERT_TRUE(database_->NativeLegacyInputAllowed(input, &allowed)); EXPECT_TRUE(allowed);
  ASSERT_TRUE(database_->RecordNativeLegacyDeletion(GURL("https://another.example/"), time_, time_ + base::Seconds(1)));
  ASSERT_TRUE(database_->NativeLegacyInputAllowed(input, &allowed)); EXPECT_TRUE(allowed);
  ASSERT_TRUE(database_->RecordNativeLegacyDeletion(input.url, time_, time_ + base::Microseconds(1)));
  ASSERT_TRUE(database_->NativeLegacyInputAllowed(input, &allowed)); EXPECT_FALSE(allowed);
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}

TEST_F(NativeHistoryMirrorDatabaseTest, LostInitialPrepareReplyDoesNotForgetEarlierDeletionWhenLeaseIsDiscarded) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto lost = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(lost);
  ASSERT_TRUE(database_->RecordNativeLegacyDeletion(std::nullopt, base::Time(), base::Time::Max(), true));
  ASSERT_TRUE(database_->FinalizeNativeLegacyBoundary(*lost, false));
  const auto replacement = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(replacement);
  NativeHistoryLegacyInput input;
  input.import_id = std::string(64, 'c'); input.requested_url_hash = std::string(64, 'd');
  input.url = GURL("https://unsubmitted.example/"); input.time = time_; input.boundary_id = *replacement;
  bool allowed = true; ASSERT_TRUE(database_->NativeLegacyInputAllowed(input, &allowed)); EXPECT_FALSE(allowed);
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}

TEST_F(NativeHistoryMirrorDatabaseTest, FailedScopeBatchRollsBackPrefixPreservesVisitsAndRevokesMigrationEvidence) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto visit = AddVisit();
  const auto boundary = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(boundary);
  ASSERT_TRUE(database_->GetDBForTesting().Execute(
      "WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<19999) "
      "INSERT INTO zacro_native_legacy_deletions(url_hash,begin_time,end_time,inclusive_end) "
      "SELECT '',0,0,0 FROM numbers"));
  // First scope reaches the bound; the second fails. Neither the successful
  // prefix nor a still-valid migration lease may survive this aborted request.
  const std::vector<NativeHistoryDeletionScope> scopes = {
      {GURL("https://first.example/"), base::Time(), base::Time::Max(), true},
      {GURL("https://second.example/"), base::Time(), base::Time::Max(), true}};
  EXPECT_FALSE(database_->RecordNativeLegacyDeletions(scopes));
  {
    sql::Statement count(database_->GetDBForTesting().GetUniqueStatement(
        "SELECT COUNT(*) FROM zacro_native_legacy_deletions"));
    ASSERT_TRUE(count.Step()); EXPECT_EQ(19999, count.ColumnInt(0));
    sql::Statement leases(database_->GetDBForTesting().GetUniqueStatement(
        "SELECT COUNT(*) FROM zacro_native_legacy_boundaries"));
    ASSERT_TRUE(leases.Step()); EXPECT_EQ(0, leases.ColumnInt(0));
  }
  VisitRow intact; EXPECT_TRUE(database_->GetRowForVisit(visit.visit_id, &intact));
  EXPECT_FALSE(database_->InitializeNativeMirrorJournal());
  EXPECT_FALSE(database_->ReadNativeMirrorEvents(0, 512));
  ASSERT_TRUE(transaction->Commit()); transaction.reset(); database_.reset(); Open();
  EXPECT_TRUE(database_->GetRowForVisit(visit.visit_id, &intact));
  NativeHistoryLegacyInput input;
  input.import_id = std::string(64, 'a'); input.requested_url_hash = std::string(64, 'b');
  input.url = GURL("https://first.example/"); input.time = time_; input.boundary_id = *boundary;
  bool allowed = true; EXPECT_FALSE(database_->NativeLegacyInputAllowed(input, &allowed));
}

TEST_F(NativeHistoryMirrorDatabaseTest, ResetScopeFailureOccursBeforeVisitTableMutationAndKeepsInvalidMarker) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto visit = AddVisit();
  ASSERT_TRUE(database_->CreateNativeLegacyBoundary());
  ASSERT_TRUE(database_->GetDBForTesting().Execute(
      "WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<20000) "
      "INSERT INTO zacro_native_legacy_deletions(url_hash,begin_time,end_time,inclusive_end) "
      "SELECT '',0,0,0 FROM numbers"));
  EXPECT_FALSE(database_->RecreateAllTablesButURL());
  VisitRow intact; EXPECT_TRUE(database_->GetRowForVisit(visit.visit_id, &intact));
  ASSERT_TRUE(transaction->Commit()); transaction.reset(); database_.reset(); Open();
  EXPECT_TRUE(database_->GetRowForVisit(visit.visit_id, &intact));
  EXPECT_FALSE(database_->NativeHistoryGeneration(false));
  EXPECT_FALSE(database_->ReadNativeMirrorEvents(0, 512));
}
