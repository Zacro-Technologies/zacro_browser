TEST_F(NativeHistoryMirrorDatabaseTest, LegacyImportTombstoneDoesNotReviveDeletedVisit) {
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  const auto visit = AddVisit();
  NativeHistoryLegacyInput input;
  input.import_id = std::string(64, 'a'); input.requested_url_hash = std::string(64, 'b');
  input.url = GURL("https://example.test/native-history"); input.time = time_;
  const auto boundary = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(boundary); input.boundary_id = *boundary; input.title = u"Legacy";
  ASSERT_TRUE(database_->RecordNativeLegacyImport(input, visit.visit_id));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  database_.reset(); Open();
  std::optional<NativeHistoryLegacyResult> result;
  ASSERT_TRUE(database_->FindNativeLegacyImport(input, &result)); ASSERT_TRUE(result); EXPECT_TRUE(result->present);
  database_->DeleteVisit(visit);
  ASSERT_TRUE(database_->FindNativeLegacyImport(input, &result)); ASSERT_TRUE(result); EXPECT_FALSE(result->present);
  EXPECT_EQ(visit.visit_id, result->visit_id);
  const auto generation = result->generation;
  transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  ASSERT_TRUE(database_->AcknowledgeNativeLegacyImports({{input.import_id, generation}}));
  ASSERT_TRUE(database_->AcknowledgeNativeLegacyImports({{input.import_id, generation}}));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
}

TEST_F(NativeHistoryMirrorDatabaseTest, FailedLegacyTransactionLeavesNeitherVisitNorImport) {
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  const auto visit = AddVisit();
  NativeHistoryLegacyInput input;
  input.import_id = std::string(64, 'a'); input.requested_url_hash = std::string(64, 'b');
  input.url = GURL("https://example.test/native-history"); input.time = time_;
  const auto boundary = database_->CreateNativeLegacyBoundary(); ASSERT_TRUE(boundary); input.boundary_id = *boundary;
  ASSERT_TRUE(database_->RecordNativeLegacyImport(input, visit.visit_id));
  transaction->Rollback(); transaction.reset(); database_.reset(); Open();
  std::optional<NativeHistoryLegacyResult> result;
  ASSERT_TRUE(database_->FindNativeLegacyImport(input, &result)); EXPECT_FALSE(result);
  VisitRow removed;
  EXPECT_FALSE(database_->GetRowForVisit(visit.visit_id, &removed));
}
