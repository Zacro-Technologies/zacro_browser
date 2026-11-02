#!/usr/bin/env python3
"""Add native, causally tagged storage observation to pinned Chromium.

Extension JavaScript keeps Chromium's real storage implementation and access
checks. Only a native caller can set an origin tag; normal extension writes use
the empty default. The tag reaches native observers without entering JS events.
"""
import argparse
import difflib
import hashlib
import json
import re
from pathlib import Path
import subprocess
import storage_atomic_adapter

PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
ROOT = Path(__file__).resolve().parent
HEADER = "extensions/browser/api/storage/storage_frontend.h"
SOURCE = "extensions/browser/api/storage/storage_frontend.cc"
API_SOURCE = "extensions/browser/api/storage/storage_api.cc"
TEST_SOURCE = "extensions/browser/api/storage/storage_frontend_unittest.cc"


def replace(text, old, new, expected=1):
    if text.count(old) != expected:
        raise SystemExit(f"Pinned storage source drift: expected {expected} occurrences of {old[:90]!r}")
    return text.replace(old, new)


def generated(originals):
    header = originals[HEADER]
    header = replace(header, '#include "base/memory/raw_ptr.h"',
                     '#include "base/callback_list.h"\n#include "base/memory/raw_ptr.h"')
    for indent in ("           ", "              ", "             "):
        old = "\n" + indent + "base::OnceCallback<void(ResultStatus)> callback);"
        header = replace(header, old, old[:-2] + ",\n" + indent + "std::string origin = {});")
    header = replace(header, "  // Gets the Settings change callback.", """  // Browser-process observation, independent of extension JS listeners.
  // Native synchronization supplies an origin to avoid echoing remote writes.
  using NativeChangesCallback = base::RepeatingCallback<void(
      const ExtensionId&, StorageAreaNamespace, const base::Value&,
      const std::string&)>;
  base::CallbackListSubscription ObserveNativeChanges(
      NativeChangesCallback callback);

  // Gets the Settings change callback.""")
    header = replace(header, """  void OnWriteFinished(const ExtensionId& extension_id,
                       StorageAreaNamespace storage_area,
                       base::OnceCallback<void(ResultStatus)> callback,""", """  void OnWriteFinished(const ExtensionId& extension_id,
                       StorageAreaNamespace storage_area,
                       std::string origin,
                       base::OnceCallback<void(ResultStatus)> callback,""")
    header = replace(header, "  // The (non-incognito) browser context this Frontend belongs to.", """  void OnSettingsChangedWithOrigin(
      const ExtensionId& extension_id,
      StorageAreaNamespace storage_area,
      std::optional<api::storage::AccessLevel> access_level,
      base::Value changes,
      const std::string& origin);

  base::RepeatingCallbackList<void(
      const ExtensionId&, StorageAreaNamespace, const base::Value&,
      const std::string&)> native_change_observers_;

  // The (non-incognito) browser context this Frontend belongs to.""")

    code = originals[SOURCE]
    code = replace(code, """void StorageFrontend::OnWriteFinished(
    const ExtensionId& extension_id,
    StorageAreaNamespace storage_area,
    base::OnceCallback<void(StorageFrontend::ResultStatus)> callback,""", """void StorageFrontend::OnWriteFinished(
    const ExtensionId& extension_id,
    StorageAreaNamespace storage_area,
    std::string origin,
    base::OnceCallback<void(StorageFrontend::ResultStatus)> callback,""")
    code = replace(code, """    OnSettingsChanged(
        extension_id, storage_area,
        storage_utils::GetAccessLevelForArea(extension_id, *browser_context_,
                                             storage_area),
        value_store::ValueStoreChange::ToValue(result.PassChanges()));""", """    OnSettingsChangedWithOrigin(
        extension_id, storage_area,
        storage_utils::GetAccessLevelForArea(extension_id, *browser_context_,
                                             storage_area),
        value_store::ValueStoreChange::ToValue(result.PassChanges()), origin);""")
    for method, indent, extra in (
        ("Set", "                          ", "base::DictValue values,"),
        ("Remove", "                             ", "const std::vector<std::string>& keys,"),
    ):
        old = (f"void StorageFrontend::{method}(scoped_refptr<const Extension> extension,\n"
               f"{indent}StorageAreaNamespace storage_area,\n{indent}{extra}\n"
               f"{indent}base::OnceCallback<void(ResultStatus)> callback) {{")
        code = replace(code, old, old[:-3] + ",\n" + indent + "std::string origin) {")
    code = replace(code, """void StorageFrontend::Clear(
    scoped_refptr<const Extension> extension,
    StorageAreaNamespace storage_area,
    base::OnceCallback<void(StorageFrontend::ResultStatus)> callback) {""", """void StorageFrontend::Clear(
    scoped_refptr<const Extension> extension,
    StorageAreaNamespace storage_area,
    base::OnceCallback<void(StorageFrontend::ResultStatus)> callback,
    std::string origin) {""")
    code = replace(code, """      OnSettingsChanged(extension->id(), storage_area,
                        storage_utils::GetAccessLevelForArea(
                            extension->id(), *browser_context_, storage_area),
                        storage_utils::ValueChangeToValue(std::move(changes)));""", """      OnSettingsChangedWithOrigin(
          extension->id(), storage_area,
          storage_utils::GetAccessLevelForArea(
              extension->id(), *browser_context_, storage_area),
          storage_utils::ValueChangeToValue(std::move(changes)), origin);""", expected=3)
    # Restrict replacement to mutation methods; GetValues has the same final
    # callback binding but must retain its original API and semantics.
    start = code.index("void StorageFrontend::Set(")
    prefix, mutations = code[:start], code[start:]
    mutations = replace(mutations, "storage_area, std::move(callback))));",
                        "storage_area, std::move(origin),\n                                    std::move(callback))));", expected=3)
    code = prefix + mutations
    code = replace(code, "SettingsChangedCallback StorageFrontend::GetObserver() {", """base::CallbackListSubscription StorageFrontend::ObserveNativeChanges(
    NativeChangesCallback callback) {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  return native_change_observers_.Add(std::move(callback));
}

SettingsChangedCallback StorageFrontend::GetObserver() {""")
    code = replace(code, """    base::Value changes) {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  TRACE_EVENT1("browser", "StorageFrontend::OnSettingsChanged", "extension_id", """.rstrip(), """    base::Value changes) {
  OnSettingsChangedWithOrigin(extension_id, storage_area, access_level,
                              std::move(changes), std::string());
}

void StorageFrontend::OnSettingsChangedWithOrigin(
    const ExtensionId& extension_id,
    StorageAreaNamespace storage_area,
    std::optional<api::storage::AccessLevel> access_level,
    base::Value changes,
    const std::string& origin) {
  DCHECK_CURRENTLY_ON(BrowserThread::UI);
  // Notify before listener filtering: an extension need not listen to its own
  // writes for those changes to synchronize through the native host.
  native_change_observers_.Notify(extension_id, storage_area, changes, origin);
  TRACE_EVENT1("browser", "StorageFrontend::OnSettingsChanged", "extension_id", """.rstrip())
    api = originals[API_SOURCE]
    for method in ("Set", "Clear"):
        old = f"""      base::BindOnce(&StorageStorageArea{method}Function::OnWriteOperationFinished,
                     this));"""
        api = replace(api, old, old[:-2] + ',\n      browser_context()->IsOffTheRecord() ? "zacro.private" : std::string());')
    api = replace(api, """      base::BindOnce(
          &StorageStorageAreaRemoveFunction::OnWriteOperationFinished, this));""", """      base::BindOnce(
          &StorageStorageAreaRemoveFunction::OnWriteOperationFinished, this),
      browser_context()->IsOffTheRecord() ? "zacro.private" : std::string());""")
    tests = replace(originals[TEST_SOURCE], '#include "base/test/metrics/histogram_tester.h"',
                    '#include "base/test/metrics/histogram_tester.h"\n#include "base/test/test_future.h"')
    tests = replace(tests, '#include "components/value_store/value_store.h"',
                    '#include "components/value_store/value_store.h"\n#include "components/value_store/leveldb_value_store.h"\n#include "extensions/browser/api/storage/settings_storage_quota_enforcer.h"\n#include "extensions/browser/extension_registry.h"')
    tests = replace(tests, "}  // namespace extensions", (ROOT / "storage_observer_tests.inc").read_text() + "\n}  // namespace extensions")
    atomic, header, code = storage_atomic_adapter.generate(originals, header, code, replace)
    # Preserve the actual writing Extension instance through asynchronous backend
    # work. Looking up the ID only when the callback returns can otherwise label
    # an old write with a replacement installation's identity.
    header = replace(header, "const std::string&)>", "const std::string&, const Extension*)>", expected=2)
    header = replace(header, "void OnWriteFinished(const ExtensionId& extension_id,",
                     "void OnWriteFinished(scoped_refptr<const Extension> extension,")
    header = replace(header, "      const std::string& origin);",
                     "      const std::string& origin,\n      const Extension* mutation_owner = nullptr);")
    code = replace(code, "void StorageFrontend::OnWriteFinished(\n    const ExtensionId& extension_id,",
                   "void StorageFrontend::OnWriteFinished(\n    scoped_refptr<const Extension> extension,")
    code = replace(code, "    ValueStore::WriteResult result) {\n  bool success = result.status().ok();",
                   "    ValueStore::WriteResult result) {\n  const ExtensionId& extension_id = extension->id();\n  bool success = result.status().ok();")
    code = replace(code, "value_store::ValueStoreChange::ToValue(result.PassChanges()), origin);",
                   "value_store::ValueStoreChange::ToValue(result.PassChanges()), origin,\n        extension.get());")
    code = replace(code, "storage_utils::ValueChangeToValue(std::move(changes)), origin);",
                   "storage_utils::ValueChangeToValue(std::move(changes)), origin,\n          extension.get());", expected=3)
    code = replace(code, "    const std::string& origin) {\n  DCHECK_CURRENTLY_ON(BrowserThread::UI);",
                   "    const std::string& origin,\n    const Extension* mutation_owner) {\n  DCHECK_CURRENTLY_ON(BrowserThread::UI);")
    code = replace(code, "native_change_observers_.Notify(extension_id, storage_area, changes, origin);",
                   "native_change_observers_.Notify(extension_id, storage_area, changes, origin,\n                                  mutation_owner);")
    code, count = re.subn(r"(base::BindOnce\(&StorageFrontend::OnWriteFinished,\s*weak_factory_\.GetWeakPtr\(\), )extension->id\(\)",
                         r"\1extension", code)
    if count != 4:
        raise SystemExit(f"Expected four native mutation-owner bindings, found {count}")
    return {HEADER: header, SOURCE: code, API_SOURCE: api, TEST_SOURCE: tests, **atomic}


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true", help="Validate and produce the patch without changing Chromium")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected Chromium {PIN}, found {revision}; review the storage adapter before upgrading.")
    originals = {path: subprocess.check_output(["git", "show", f"HEAD:{path}"], cwd=source, text=True)
                 for path in (HEADER, SOURCE, API_SOURCE, TEST_SOURCE, *storage_atomic_adapter.PATHS)}
    output = generated(originals)
    # Keep the last applied hashes in ignored build output, not in the source
    # patch. A --check can generate a new patch without losing upgrade safety.
    receipt = source / "out" / "zacro-native-storage-adapter.json"
    previous = json.loads(receipt.read_text()) if receipt.exists() else {}
    if previous.get("revision") != PIN:
        previous = {}
    for path, contents in output.items():
        current = (source / path).read_text()
        if current not in (originals[path], contents) and digest(current) != previous.get("files", {}).get(path):
            raise SystemExit(f"Refusing to overwrite unrelated changes in {source / path}")
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path, contents in output.items())
    (ROOT / "storage-front-end.patch").write_text(patch)
    if not args.check:
        for path, contents in output.items():
            target = source / path
            temporary = target.with_suffix(target.suffix + ".zacro-tmp")
            temporary.write_text(contents)
            temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {p: digest(v) for p, v in output.items()}}, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Applied'} native storage observer for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
