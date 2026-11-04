// Appended inside namespace history in the pinned HistoryDatabase test target.
// These tests execute the actual staged methods and SQL, not a mirrored model.
class NativeHistoryMirrorDatabaseTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    path_ = directory_.GetPath().AppendASCII("History");
    Open();
  }
  void Open() {
    database_ = std::make_unique<TestHistoryDatabase>();
    ASSERT_EQ(sql::INIT_OK, database_->Init(path_));
  }
  VisitRow AddVisit() {
    const GURL address("https://example.test/native-history");
    URLRow row(address);
    row.set_title(u"Native visit");
    row.set_visit_count(1);
    row.set_last_visit(time_);
    auto url_id = database_->GetRowForURL(address, &row);
    if (!url_id) url_id = database_->AddURL(row);
    EXPECT_GT(url_id, 0);
    VisitRow visit;
    visit.url_id = url_id;
    visit.visit_time = time_;
    visit.transition = ui::PAGE_TRANSITION_LINK;
    visit.source = SOURCE_BROWSED;
    EXPECT_GT(database_->AddVisit(&visit), 0);
    return visit;
  }
  NativeHistoryDocument Document() {
    NativeHistoryDocument document;
    document.document_token = "892b868a-6690-445b-ae94-580564043224";
    document.producer_epoch = "dd9436b5-6c6e-4492-b613-d0e806f2a035";
    document.event_id = "47ec95e8-e150-4c23-bf54-94581b8c8771";
    document.logical_id = "owned-logical-tab";
    document.publish = true;
    return document;
  }
  base::ScopedTempDir directory_;
  base::FilePath path_;
  std::unique_ptr<TestHistoryDatabase> database_;
  const base::Time time_ = base::Time::FromSecondsSinceUnixEpoch(1700000000);
};

TEST_F(NativeHistoryMirrorDatabaseTest, FailedTransactionCannotPublishVisitHandoff) {
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  const auto visit = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(Document(), visit.visit_id, time_));
  ASSERT_EQ(1u, database_->ReadNativeMirrorEvents(0, 512)->size());
  transaction->Rollback();
  transaction.reset();
  database_.reset(); Open();
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); EXPECT_TRUE(rows->empty());
}

TEST_F(NativeHistoryMirrorDatabaseTest, ExactVisitDeletionAndLostAckReplay) {
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  const auto visit = AddVisit();
  const auto document = Document();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, visit.visit_id, time_));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  database_.reset(); Open();
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(1u, rows->size());
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kPresent, rows->front().presence);
  EXPECT_EQ(document.event_id, rows->front().event_id);
  database_->DeleteVisit(visit);
  rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(1u, rows->size());
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kAbsent, rows->front().presence);
  EXPECT_TRUE(rows->front().url.empty());
  if (!database_->HasActiveTransactions()) { transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin()); }
  ASSERT_TRUE(database_->AcknowledgeNativeMirrorEvents({document.event_id}));
  ASSERT_TRUE(database_->AcknowledgeNativeMirrorEvents({document.event_id}));
  ASSERT_TRUE(database_->ReadNativeMirrorEvents(0, 512)->empty());
}

TEST_F(NativeHistoryMirrorDatabaseTest, DeleteAllEpochRollsBackWithItsVisitTable) {
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  const auto original = database_->NativeHistoryGeneration(false);
  ASSERT_TRUE(original);
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  ASSERT_TRUE(database_->RecreateAllTablesButURL());
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kAbsent,
            database_->CompareNativeHistoryGeneration(*original));
  transaction->Rollback(); transaction.reset();
  database_.reset(); Open();
  EXPECT_EQ(original, database_->NativeHistoryGeneration(false));
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kPresent,
            database_->CompareNativeHistoryGeneration(*original));
}

TEST_F(NativeHistoryMirrorDatabaseTest, InterruptedResetRemainsErrorAfterRestart) {
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  const auto original = database_->NativeHistoryGeneration(false);
  ASSERT_TRUE(original);
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  ASSERT_TRUE(database_->BeginNativeHistoryTableReset());
  // Model a failed table recreation whose enclosing upstream transaction still
  // commits. The durable invalid marker must not certify any VisitID afterward.
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  database_.reset(); Open();
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kError,
            database_->CompareNativeHistoryGeneration(*original));
  EXPECT_FALSE(database_->ReadNativeMirrorEvents(0, 512));
  transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  ASSERT_TRUE(database_->RecreateAllTablesButURL());
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kAbsent,
            database_->CompareNativeHistoryGeneration(*original));
}

TEST_F(NativeHistoryMirrorDatabaseTest, UnrelatedDatabaseIsNeverAbsence) {
  ASSERT_TRUE(database_->InitializeNativeMirrorJournal());
  const auto original = database_->NativeHistoryGeneration(false);
  ASSERT_TRUE(original);
  TestHistoryDatabase unrelated;
  ASSERT_EQ(sql::INIT_OK, unrelated.Init(directory_.GetPath().AppendASCII("OtherHistory")));
  ASSERT_TRUE(unrelated.InitializeNativeMirrorJournal());
  EXPECT_EQ(HistoryDatabase::NativeVisitPresence::kError,
            unrelated.CompareNativeHistoryGeneration(*original));
}

TEST_F(NativeHistoryMirrorDatabaseTest, MalformedExistingJournalIsNotAnEmptyPage) {
  ASSERT_TRUE(database_->GetDBForTesting().Execute(
      "CREATE TABLE zacro_native_visit_events(sequence INTEGER)"));
  EXPECT_FALSE(database_->InitializeNativeMirrorJournal());
  EXPECT_FALSE(database_->ReadNativeMirrorEvents(0, 512));
}

TEST_F(NativeHistoryMirrorDatabaseTest, ProvisionalPopupRetainsEveryCommitUntilAdopted) {
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  auto document = Document();
  document.publish = false;
  const auto first = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, first.visit_id, time_));
  document.event_id = "955c8676-4ed0-439a-bb24-66b058835d28";
  const auto second = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, second.visit_id, time_));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  database_.reset(); Open();
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(2u, rows->size());
  EXPECT_FALSE(rows->at(0).publish); EXPECT_FALSE(rows->at(1).publish);
  transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  HistoryDatabase::NativeMirrorPublication lease;
  lease.lease_id = "9d11b3aa-d9af-4cf9-a7ba-22705d088264";
  lease.document_token = document.document_token;
  ASSERT_TRUE(database_->PrepareNativeMirrorPublication(lease));
  ASSERT_TRUE(database_->CommitNativeMirrorPublication(lease, "adopted-tab"));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(2u, rows->size());
  for (const auto& row : *rows) {
    EXPECT_TRUE(row.publish); EXPECT_EQ("adopted-tab", row.logical_id);
  }
}

TEST_F(NativeHistoryMirrorDatabaseTest, PeekKeepsOnlyCurrentUnpublishedVisit) {
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  auto document = Document();
  document.publish = false; document.preview = true;
  const auto first = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, first.visit_id, time_));
  document.event_id = "955c8676-4ed0-439a-bb24-66b058835d28";
  const auto second = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, second.visit_id, time_));
  HistoryDatabase::NativeMirrorPublication missing_lease;
  missing_lease.lease_id = "9d11b3aa-d9af-4cf9-a7ba-22705d088264";
  missing_lease.document_token = document.document_token;
  missing_lease.preview = true;
  missing_lease.captured_event_id = document.event_id;
  EXPECT_FALSE(database_->CommitNativeMirrorPublication(missing_lease, "must-not-promote-peek"));
  ASSERT_TRUE(transaction->Commit()); transaction.reset();
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(1u, rows->size());
  EXPECT_EQ(second.visit_id, rows->front().visit_id);
  EXPECT_FALSE(rows->front().publish); EXPECT_TRUE(rows->front().preview);
  VisitRow still_native;
  EXPECT_TRUE(database_->GetRowForVisit(first.visit_id, &still_native));
}

TEST_F(NativeHistoryMirrorDatabaseTest, PendingPublicationRetainsCapturedAndSubsequentPeekVisits) {
  auto transaction = database_->CreateTransaction();
  ASSERT_TRUE(transaction->Begin());
  auto document = Document(); document.publish = false; document.preview = true;
  const auto first = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, first.visit_id, time_));
  HistoryDatabase::NativeMirrorPublication lease;
  lease.lease_id = "9d11b3aa-d9af-4cf9-a7ba-22705d088264";
  lease.document_token = document.document_token; lease.preview = true;
  lease.captured_event_id = document.event_id;
  ASSERT_TRUE(database_->PrepareNativeMirrorPublication(lease));
  // A visit queued with the old preview flag must obey the durable boundary.
  document.event_id = "955c8676-4ed0-439a-bb24-66b058835d28";
  const auto second = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, second.visit_id, time_));
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(2u, rows->size());
  EXPECT_FALSE(rows->at(0).publish); EXPECT_FALSE(rows->at(1).publish);
  ASSERT_TRUE(transaction->Commit()); transaction.reset(); database_.reset(); Open();
  transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  ASSERT_TRUE(database_->CommitNativeMirrorPublication(lease, "promoted-native-tab"));
  ASSERT_TRUE(database_->CommitNativeMirrorPublication(lease, "promoted-native-tab"));
  EXPECT_FALSE(database_->CommitNativeMirrorPublication(lease, "foreign-tab"));
  EXPECT_FALSE(database_->CancelNativeMirrorPublication(lease));
  document.event_id = "495e8401-d85c-4cd7-817c-0847b8b4cb17";
  const auto third = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, third.visit_id, time_));
  rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(3u, rows->size());
  for (const auto& row : *rows) {
    EXPECT_TRUE(row.publish); EXPECT_FALSE(row.preview);
    EXPECT_EQ("promoted-native-tab", row.logical_id);
  }
  ASSERT_TRUE(database_->FinalizeNativeMirrorPublication(lease, "promoted-native-tab"));
  ASSERT_TRUE(database_->FinalizeNativeMirrorPublication(lease, "promoted-native-tab"));
  EXPECT_TRUE(database_->ReadNativeMirrorPublications()->empty());
  ASSERT_TRUE(transaction->Commit());
}

TEST_F(NativeHistoryMirrorDatabaseTest, CancelledPublicationRestoresLatestOnlyDespiteQueuedOldFlags) {
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  auto document = Document(); document.publish = false; document.preview = true;
  const auto first = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, first.visit_id, time_));
  HistoryDatabase::NativeMirrorPublication lease;
  lease.lease_id = "9d11b3aa-d9af-4cf9-a7ba-22705d088264";
  lease.document_token = document.document_token; lease.preview = true;
  lease.captured_event_id = document.event_id;
  ASSERT_TRUE(database_->PrepareNativeMirrorPublication(lease));
  document.preview = false;
  document.event_id = "955c8676-4ed0-439a-bb24-66b058835d28";
  const auto second = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, second.visit_id, time_));
  ASSERT_TRUE(database_->CancelNativeMirrorPublication(lease));
  EXPECT_FALSE(database_->CommitNativeMirrorPublication(lease, "cancelled-tab"));
  document.event_id = "495e8401-d85c-4cd7-817c-0847b8b4cb17";
  const auto third = AddVisit();
  ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, third.visit_id, time_));
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(1u, rows->size());
  EXPECT_EQ(third.visit_id, rows->front().visit_id);
  EXPECT_FALSE(rows->front().publish); EXPECT_TRUE(rows->front().preview);
  VisitRow original;
  EXPECT_TRUE(database_->GetRowForVisit(first.visit_id, &original));
  EXPECT_TRUE(database_->GetRowForVisit(second.visit_id, &original));
  ASSERT_TRUE(database_->FinalizeNativeMirrorPublication(lease, ""));
  ASSERT_TRUE(transaction->Commit());
}

TEST_F(NativeHistoryMirrorDatabaseTest, RolledBackPublicationCannotAuthorizeEventsAfterRestart) {
  {
    auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
    auto document = Document(); document.publish = false; document.preview = true;
    const auto visit = AddVisit();
    ASSERT_TRUE(database_->RecordNativeMirrorVisit(document, visit.visit_id, time_));
    ASSERT_TRUE(transaction->Commit());
  }
  HistoryDatabase::NativeMirrorPublication lease;
  lease.lease_id = "9d11b3aa-d9af-4cf9-a7ba-22705d088264";
  lease.document_token = Document().document_token; lease.preview = true;
  lease.captured_event_id = Document().event_id;
  {
    auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
    ASSERT_TRUE(database_->PrepareNativeMirrorPublication(lease));
    transaction->Rollback();
  }
  database_.reset(); Open();
  auto transaction = database_->CreateTransaction(); ASSERT_TRUE(transaction->Begin());
  EXPECT_FALSE(database_->CommitNativeMirrorPublication(lease, "never-committed"));
  auto rows = database_->ReadNativeMirrorEvents(0, 512);
  ASSERT_TRUE(rows); ASSERT_EQ(1u, rows->size()); EXPECT_FALSE(rows->front().publish);
  ASSERT_TRUE(transaction->Commit());
}
