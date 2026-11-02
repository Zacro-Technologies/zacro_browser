// Native observation preserves JS dispatch while recording causal write origin.
TEST_F(ExtensionSettingsFrontendTest,
       NativeAtomicPatchValidatesFinalQuotaAndPreservesDataOnFailure) {
  SettingsStorageQuotaEnforcer store(
      {.quota_bytes = 20, .quota_bytes_per_item = 10, .max_items = 2},
      std::make_unique<value_store::LeveldbValueStore>(
          "NativeSyncTest", temp_dir_.GetPath().AppendASCII("native-atomic")));
  base::DictValue old = base::DictValue().Set("old", 1).Set("keep", 2);
  base::DictValue next = base::DictValue().Set("keep", 2).Set("new", 3);
  ASSERT_TRUE(store.Set(ValueStore::DEFAULTS, old).status().ok());
  // Already at max_items: one delete and one add must succeed as one change.
  auto accepted = store.CompareAndReplace(old, next);
  ASSERT_TRUE(accepted.status().ok());
  EXPECT_EQ(accepted.changes().size(), 2u);
  EXPECT_EQ(store.Get().settings(), next);
  EXPECT_EQ(store.GetBytesInUse(), 9u);

  EXPECT_FALSE(store.CompareAndReplace(old, base::DictValue()).status().ok());
  EXPECT_EQ(store.Get().settings(), next);
  auto oversized = next.Clone();
  oversized.Set("new", std::string(20, 'a'));
  EXPECT_EQ(store.CompareAndReplace(next, oversized).status().code,
            ValueStore::QUOTA_EXCEEDED);
  EXPECT_EQ(store.Get().settings(), next);
  EXPECT_EQ(store.GetBytesInUse(), 9u);
  auto too_many = next.Clone();
  too_many.Set("third", 4);
  EXPECT_EQ(store.CompareAndReplace(next, too_many).status().code,
            ValueStore::QUOTA_EXCEEDED);
  EXPECT_EQ(store.Get().settings(), next);
}

TEST_F(ExtensionSettingsFrontendTest,
       NativeObserverReceivesWritesWithoutJavaScriptListeners) {
  const std::string id(32, 'a');
  auto extension = settings_test_util::AddExtensionWithId(
      browser_context(), id, Manifest::Type::kExtension);
  std::vector<std::string> origins;
  std::vector<base::Value> changes;
  auto subscription = frontend_->ObserveNativeChanges(base::BindRepeating(
      [&origins, &changes, &id, &extension](const ExtensionId& extension_id,
                               StorageAreaNamespace area,
                               const base::Value& delta,
                               const std::string& origin,
                               const Extension* owner) {
        EXPECT_EQ(owner, extension.get());
        EXPECT_EQ(extension_id, id);
        EXPECT_EQ(area, StorageAreaNamespace::kLocal);
        origins.push_back(origin);
        changes.push_back(delta.Clone());
      }));
  {
    base::test::TestFuture<StorageFrontend::ResultStatus> completed;
    frontend_->Set(extension, StorageAreaNamespace::kLocal,
                   base::DictValue().Set("first", 1), completed.GetCallback(),
                   "remote:set");
    ASSERT_TRUE(completed.Get().success);
  }
  {
    base::test::TestFuture<StorageFrontend::ResultStatus> completed;
    frontend_->Set(extension, StorageAreaNamespace::kLocal,
                   base::DictValue().Set("second", 2), completed.GetCallback());
    ASSERT_TRUE(completed.Get().success);
  }
  {
    base::test::TestFuture<StorageFrontend::ResultStatus> completed;
    frontend_->Remove(extension, StorageAreaNamespace::kLocal, {"first"},
                      completed.GetCallback(), "remote:remove");
    ASSERT_TRUE(completed.Get().success);
  }
  {
    base::test::TestFuture<StorageFrontend::ResultStatus> completed;
    frontend_->Clear(extension, StorageAreaNamespace::kLocal,
                     completed.GetCallback(), "remote:clear");
    ASSERT_TRUE(completed.Get().success);
  }
  EXPECT_EQ(origins, (std::vector<std::string>{
      "remote:set", "", "remote:remove", "remote:clear"}));
  ASSERT_EQ(changes.size(), 4u);
  ASSERT_TRUE(changes[0].GetDict().FindDict("first"));
  EXPECT_EQ(changes[0].GetDict().FindDict("first")->FindInt("newValue"), 1);
  ASSERT_TRUE(changes[2].GetDict().FindDict("first"));
  EXPECT_FALSE(changes[2].GetDict().FindDict("first")->contains("newValue"));
  ASSERT_TRUE(changes[3].GetDict().FindDict("second"));
  EXPECT_EQ(changes[3].GetDict().FindDict("second")->FindInt("oldValue"), 2);
}

TEST_F(ExtensionSettingsFrontendTest,
       NativeObserverReceivesBackendChangesAndCanUnsubscribe) {
  const std::string id(32, 'b');
  auto extension = settings_test_util::AddExtensionWithId(
      browser_context(), id, Manifest::Type::kExtension);
  int calls = 0;
  auto subscription = frontend_->ObserveNativeChanges(base::BindRepeating(
      [&calls](const ExtensionId&, StorageAreaNamespace area,
               const base::Value& delta, const std::string& origin,
               const Extension* owner) {
        EXPECT_EQ(owner, nullptr);
        ++calls;
        EXPECT_EQ(area, StorageAreaNamespace::kSync);
        EXPECT_TRUE(origin.empty());
        EXPECT_TRUE(delta.GetDict().contains("key"));
      }));
  auto callback = frontend_->GetObserver();
  callback.Run(id, StorageAreaNamespace::kSync, std::nullopt,
               base::Value(base::DictValue().Set(
                   "key", base::DictValue().Set("newValue", "value"))));
  EXPECT_EQ(calls, 1);
  subscription = {};
  callback.Run(id, StorageAreaNamespace::kSync, std::nullopt,
               base::Value(base::DictValue().Set(
                   "key", base::DictValue().Set("newValue", "later"))));
  EXPECT_EQ(calls, 1);
}

TEST_F(ExtensionSettingsFrontendTest,
       NativeObserverRetainsOriginalWriterAcrossRegistryReplacement) {
  const std::string id(32, 'c');
  auto old_extension = settings_test_util::AddExtensionWithId(
      browser_context(), id, Manifest::Type::kExtension);
  const Extension* observed_owner = nullptr;
  auto subscription = frontend_->ObserveNativeChanges(base::BindRepeating(
      [&observed_owner](const ExtensionId&, StorageAreaNamespace,
                        const base::Value&, const std::string&,
                        const Extension* owner) { observed_owner = owner; }));
  base::test::TestFuture<StorageFrontend::ResultStatus> completed;
  frontend_->Set(old_extension, StorageAreaNamespace::kLocal,
                 base::DictValue().Set("old-writer", 1), completed.GetCallback());
  auto* registry = ExtensionRegistry::Get(browser_context());
  ASSERT_TRUE(registry->RemoveEnabled(id));
  auto replacement = settings_test_util::AddExtensionWithId(
      browser_context(), id, Manifest::Type::kExtension);
  ASSERT_NE(old_extension.get(), replacement.get());
  ASSERT_TRUE(completed.Get().success);
  EXPECT_EQ(observed_owner, old_extension.get());
  EXPECT_NE(observed_owner, registry->GetInstalledExtension(id));
}
