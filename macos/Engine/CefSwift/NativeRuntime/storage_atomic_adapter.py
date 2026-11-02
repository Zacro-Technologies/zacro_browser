"""Pinned source additions for one atomic, quota-checked native storage patch."""

VALUE_HEADER = "components/value_store/value_store.h"
LEVEL_HEADER = "components/value_store/leveldb_value_store.h"
LEVEL_SOURCE = "components/value_store/leveldb_value_store.cc"
LEVEL_TEST = "components/value_store/leveldb_value_store_unittest.cc"
QUOTA_HEADER = "extensions/browser/api/storage/settings_storage_quota_enforcer.h"
QUOTA_SOURCE = "extensions/browser/api/storage/settings_storage_quota_enforcer.cc"
SYNC_HEADER = "chrome/browser/extensions/api/storage/syncable_settings_storage.h"
SYNC_SOURCE = "chrome/browser/extensions/api/storage/syncable_settings_storage.cc"
PATHS = (VALUE_HEADER, LEVEL_HEADER, LEVEL_SOURCE, LEVEL_TEST, QUOTA_HEADER,
         QUOTA_SOURCE, SYNC_HEADER, SYNC_SOURCE)


def generate(originals, frontend_header, frontend_source, replace):
    result = {path: originals[path] for path in PATHS}
    declaration = """  // Native compare-and-replace is a single backend transaction. Unsupported
  // stores must fail closed rather than approximate it with Set then Remove.
  virtual WriteResult CompareAndReplace(const base::DictValue& expected,
                                       const base::DictValue& replacement) {
    return WriteResult(Status(OTHER_ERROR,
                             "Atomic native storage changes are unsupported."));
  }

"""
    result[VALUE_HEADER] = replace(result[VALUE_HEADER], "  // Clears the storage.", declaration + "  // Clears the storage.")
    override = """  WriteResult CompareAndReplace(const base::DictValue& expected,
                               const base::DictValue& replacement) override;
"""
    for path in (LEVEL_HEADER, QUOTA_HEADER, SYNC_HEADER):
        result[path] = replace(result[path], "  WriteResult Clear() override;", override + "  WriteResult Clear() override;")
    level = """ValueStore::WriteResult LeveldbValueStore::CompareAndReplace(
    const base::DictValue& expected,
    const base::DictValue& replacement) {
  // Every operation on this store runs on the same backend sequence. No write
  // can interleave between this comparison and the single LevelDB WriteBatch.
  ReadResult current = Get();
  if (!current.status().ok())
    return WriteResult(current.PassStatus());
  if (current.settings() != expected)
    return WriteResult(Status(OTHER_ERROR, "Native storage snapshot changed."));

  leveldb::WriteBatch batch;
  ValueStoreChangeList changes;
  for (const auto [key, value] : current.settings()) {
    if (!replacement.contains(key)) {
      batch.Delete(key);
      changes.emplace_back(key, value.Clone(), std::nullopt);
    }
  }
  for (const auto [key, value] : replacement) {
    const base::Value* old = current.settings().Find(key);
    if (old && *old == value)
      continue;
    std::string json;
    if (!base::JSONWriter::Write(value, &json))
      return WriteResult(Status(OTHER_ERROR, kCannotSerialize));
    batch.Put(key, json);
    changes.emplace_back(key,
                         old ? std::make_optional(old->Clone()) : std::nullopt,
                         value.Clone());
  }
  if (changes.empty())
    return WriteResult(std::move(changes), Status());
  Status status = WriteToDb(&batch);
  return status.ok() ? WriteResult(std::move(changes), std::move(status))
                     : WriteResult(std::move(status));
}

"""
    result[LEVEL_SOURCE] = replace(result[LEVEL_SOURCE], "ValueStore::WriteResult LeveldbValueStore::Remove(const std::string& key) {", level + "ValueStore::WriteResult LeveldbValueStore::Remove(const std::string& key) {")
    quota = """ValueStore::WriteResult SettingsStorageQuotaEnforcer::CompareAndReplace(
    const base::DictValue& expected,
    const base::DictValue& replacement) {
  // Validate the final dictionary, not an intermediate add-before-remove state.
  size_t total = 0;
  std::map<std::string, size_t> per_setting;
  for (const auto [key, value] : replacement) {
    Allocate(key, value, &total, &per_setting);
    if (per_setting[key] > limits_.quota_bytes_per_item)
      return WriteResult(QuotaExceededError(Resource::kQuotaBytesPerItem));
  }
  if (total > limits_.quota_bytes)
    return WriteResult(QuotaExceededError(Resource::kQuotaBytes));
  if (per_setting.size() > limits_.max_items)
    return WriteResult(QuotaExceededError(Resource::kMaxItems));
  WriteResult result =
      HandleResult(delegate_->CompareAndReplace(expected, replacement));
  if (result.status().ok()) {
    used_total_ = total;
    used_per_setting_ = std::move(per_setting);
    usage_calculated_ = true;
  }
  return result;
}

"""
    result[QUOTA_SOURCE] = replace(result[QUOTA_SOURCE], "ValueStore::WriteResult SettingsStorageQuotaEnforcer::Clear() {", quota + "ValueStore::WriteResult SettingsStorageQuotaEnforcer::Clear() {")
    sync = """ValueStore::WriteResult SyncableSettingsStorage::CompareAndReplace(
    const base::DictValue& expected,
    const base::DictValue& replacement) {
  DCHECK(IsOnBackendSequence());
  WriteResult result =
      HandleResult(delegate_->CompareAndReplace(expected, replacement));
  if (result.status().ok())
    SyncResultIfEnabled(result);
  return result;
}

"""
    result[SYNC_SOURCE] = replace(result[SYNC_SOURCE], "ValueStore::WriteResult SyncableSettingsStorage::Clear() {", sync + "ValueStore::WriteResult SyncableSettingsStorage::Clear() {")
    frontend_header = replace(frontend_header, "  // Browser-process observation, independent of extension JS listeners.", """  // Applies one native cloud patch against an exact snapshot. The backend
  // validates final quotas and commits additions/removals in one transaction.
  void ApplyNativeChanges(scoped_refptr<const Extension> extension,
                          StorageAreaNamespace storage_area,
                          base::DictValue expected,
                          base::DictValue changes,
                          base::OnceCallback<void(ResultStatus)> callback,
                          std::string origin);

  // Browser-process observation, independent of extension JS listeners.""")
    helper = """void ApplyNativeChangesWithValueStore(
    base::DictValue expected,
    base::DictValue replacement,
    base::OnceCallback<void(ValueStore::WriteResult)> callback,
    ValueStore* store) {
  ValueStore::WriteResult result =
      store->CompareAndReplace(expected, replacement);
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(std::move(callback), std::move(result)));
}

"""
    frontend_source = replace(frontend_source, "void SetWithValueStore(", helper + "void SetWithValueStore(")
    apply = """void StorageFrontend::ApplyNativeChanges(
    scoped_refptr<const Extension> extension,
    StorageAreaNamespace storage_area,
    base::DictValue expected,
    base::DictValue changes,
    base::OnceCallback<void(ResultStatus)> callback,
    std::string origin) {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  base::DictValue replacement = expected.Clone();
  bool valid = storage_area == StorageAreaNamespace::kSync &&
               !browser_context_->IsOffTheRecord() &&
               origin.starts_with("zacro.remote:") && origin.size() <= 512 &&
               expected.size() <= 512 && changes.size() <= 1024;
  for (const auto [key, value] : changes) {
    const base::DictValue* change = value.GetIfDict();
    if (!change || change->size() > 1 ||
        (!change->empty() && !change->contains("newValue"))) {
      valid = false;
      break;
    }
    if (const base::Value* next = change->Find("newValue"))
      replacement.Set(key, next->Clone());
    else
      replacement.Remove(key);
  }
  if (!valid || !IsStorageEnabled(settings_namespace::SYNC)) {
    ResultStatus status;
    status.success = false;
    status.error = "Invalid native storage patch.";
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(std::move(callback), std::move(status)));
    return;
  }
  RunWithStorage(
      extension, settings_namespace::SYNC,
      base::BindOnce(&ApplyNativeChangesWithValueStore, std::move(expected),
                    std::move(replacement),
                    base::BindOnce(&StorageFrontend::OnWriteFinished,
                                   weak_factory_.GetWeakPtr(), extension->id(),
                                   storage_area, std::move(origin),
                                   std::move(callback))));
}

"""
    frontend_source = replace(frontend_source, "void StorageFrontend::Set(scoped_refptr<const Extension> extension,", apply + "void StorageFrontend::Set(scoped_refptr<const Extension> extension,")
    tests = """TEST_F(LeveldbValueStoreUnitTest, NativeCompareAndReplaceIsAtomicAndDurable) {
  base::DictValue old = base::DictValue().Set("remove", 1).Set("keep", 2);
  base::DictValue next = base::DictValue().Set("keep", 2).Set("added", 3);
  ASSERT_TRUE(store()->Set(ValueStore::DEFAULTS, old).status().ok());
  auto result = store()->CompareAndReplace(old, next);
  ASSERT_TRUE(result.status().ok());
  EXPECT_EQ(result.changes().size(), 2u);
  EXPECT_EQ(store()->Get().settings(), next);
  EXPECT_FALSE(store()->CompareAndReplace(old, base::DictValue()).status().ok());
  EXPECT_EQ(store()->Get().settings(), next);
  CloseStore();
  CreateStore();
  EXPECT_EQ(store()->Get().settings(), next);
  auto no_change = store()->CompareAndReplace(next, next);
  ASSERT_TRUE(no_change.status().ok());
  EXPECT_TRUE(no_change.changes().empty());
}

"""
    result[LEVEL_TEST] = replace(result[LEVEL_TEST], "}  // namespace value_store", tests + "}  // namespace value_store")
    return result, frontend_header, frontend_source
