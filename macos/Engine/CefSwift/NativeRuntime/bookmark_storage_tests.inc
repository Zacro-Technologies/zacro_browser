// Native migration must not acknowledge an in-memory-only BookmarkModel write.
TEST_P(BookmarkStorageWithSingleFileTest, NativeSaveAcknowledgesPrimaryFile) {
  base::test::TaskEnvironment environment{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME,
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED};
  auto model = CreateModelWithOneBookmark();
  BookmarkStorage storage(model.get(), BookmarkStorage::kSelectLocalOrSyncableNodes,
                          encryptor_, clear_text_file_path_, encrypted_file_path_);
  base::test::TestFuture<bool> result;
  storage.SaveForNative(result.GetCallback());
  EXPECT_FALSE(result.IsReady());
  EXPECT_FALSE(storage.HasScheduledSaveForTesting());
  environment.RunUntilIdle();
  ASSERT_TRUE(result.Get());
  ASSERT_TRUE(GetPrimaryFileContent());
}

TEST_P(BookmarkStorageWithSingleFileTest, NativeBackToBackSavesKeepBothCallbacks) {
  base::test::TaskEnvironment environment{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME,
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED};
  auto model = CreateModelWithOneBookmark();
  BookmarkStorage storage(model.get(), BookmarkStorage::kSelectLocalOrSyncableNodes,
                          encryptor_, clear_text_file_path_, encrypted_file_path_);
  base::test::TestFuture<bool> first, second;
  storage.SaveForNative(first.GetCallback());
  model->AddURL(model->other_node(), 0, u"Second", GURL("https://second.example/"));
  storage.SaveForNative(second.GetCallback());
  EXPECT_FALSE(first.IsReady()); EXPECT_FALSE(second.IsReady());
  environment.RunUntilIdle();
  EXPECT_TRUE(first.Get()); EXPECT_TRUE(second.Get());
  auto content = GetPrimaryFileContent();
  ASSERT_TRUE(content);
  EXPECT_NE(DictValueToJsonString(*content).find("https://second.example/"), std::string::npos);
}

TEST_P(BookmarkStorageWithSingleFileTest, NativeSaveReportsFailedAtomicWrite) {
  base::test::TaskEnvironment environment{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME,
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED};
  auto model = CreateModelWithOneBookmark();
  ASSERT_TRUE(base::CreateDirectory(GetPrimaryFilepath()));
  BookmarkStorage storage(model.get(), BookmarkStorage::kSelectLocalOrSyncableNodes,
                          encryptor_, clear_text_file_path_, encrypted_file_path_);
  base::test::TestFuture<bool> result;
  storage.SaveForNative(result.GetCallback());
  environment.RunUntilIdle();
  EXPECT_FALSE(result.Get());
  EXPECT_TRUE(base::DirectoryExists(GetPrimaryFilepath()));
}

TEST_P(BookmarkStorageWithSingleFileTest, NativeSaveReportsSerializationFailure) {
  class FailingStorage : public BookmarkStorage {
   public:
    using BookmarkStorage::BookmarkStorage;
    base::ImportantFileWriter::BackgroundDataProducerCallback
    GetSerializedDataProducerForBackgroundSequence() override {
      return base::BindOnce([]() -> std::optional<std::string> { return std::nullopt; });
    }
  };
  base::test::TaskEnvironment environment{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME,
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED};
  auto model = CreateModelWithOneBookmark();
  FailingStorage storage(model.get(), BookmarkStorage::kSelectLocalOrSyncableNodes,
                         encryptor_, clear_text_file_path_, encrypted_file_path_);
  base::test::TestFuture<bool> result;
  storage.SaveForNative(result.GetCallback());
  environment.RunUntilIdle();
  EXPECT_FALSE(result.Get());
  EXPECT_FALSE(base::PathExists(GetPrimaryFilepath()));
}

TEST_P(BookmarkStorageWithSingleFileTest, NativeCallbackSurvivesStorageDestruction) {
  base::test::TaskEnvironment environment{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME,
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED};
  auto model = CreateModelWithOneBookmark();
  base::test::TestFuture<bool> result;
  {
    BookmarkStorage storage(model.get(), BookmarkStorage::kSelectLocalOrSyncableNodes,
                            encryptor_, clear_text_file_path_, encrypted_file_path_);
    storage.SaveForNative(result.GetCallback());
  }
  model.reset();
  environment.RunUntilIdle();
  EXPECT_TRUE(result.Get());
  ASSERT_TRUE(GetPrimaryFileContent());
}
