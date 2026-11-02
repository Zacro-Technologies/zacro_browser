#!/usr/bin/env python3
"""Add an acknowledged durable bookmark save to the pinned Chromium model."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
STORAGE_H = "components/bookmarks/browser/bookmark_storage.h"
STORAGE_CC = "components/bookmarks/browser/bookmark_storage.cc"
MODEL_H = "components/bookmarks/browser/bookmark_model.h"
MODEL_CC = "components/bookmarks/browser/bookmark_model.cc"
TEST = "components/bookmarks/browser/bookmark_storage_unittest.cc"
PATHS = (STORAGE_H, STORAGE_CC, MODEL_H, MODEL_CC, TEST)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned bookmark source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    result = dict(originals)
    result[STORAGE_H] = replace(result[STORAGE_H], "  void ScheduleSave();", """  void ScheduleSave();

  // Captures the current model and immediately queues its primary-file write.
  // Completes on the calling sequence after the atomic write, including false
  // for serialization/encryption failures. Repeated calls keep distinct results.
  void SaveForNative(base::OnceCallback<void(bool)> callback);""")
    result[STORAGE_CC] = replace(result[STORAGE_CC], '#include "base/task/sequenced_task_runner.h"',
                                '#include "base/task/bind_post_task.h"\n#include "base/task/sequenced_task_runner.h"')
    result[STORAGE_CC] = replace(result[STORAGE_CC], '#include <unordered_map>', '#include <tuple>\n#include <unordered_map>')
    result[STORAGE_CC] = replace(result[STORAGE_CC], "void BookmarkStorage::ScheduleSave() {", """void BookmarkStorage::SaveForNative(base::OnceCallback<void(bool)> callback) {
  // The normal serializer preserves the selected primary encryption format,
  // secondary writes, backup sequencing and sync metadata. Always capture a
  // fresh snapshot: an already queued write may predate this caller's mutation.
  auto completion = base::SplitOnceCallback(
      base::BindPostTaskToCurrentDefault(std::move(callback)));
  writer_.RegisterOnNextWriteCallbacks(
      base::OnceClosure(),
      base::BindOnce(
          [](base::OnceCallback<void(bool)> complete,
             base::ScopedClosureRunner failure, bool success) {
            // ImportantFileWriter drops its callback if background production
            // fails. The runner reports that failure instead of hanging a host
            // request. On a real write result, consume only the success branch.
            std::ignore = failure.Release();
            std::move(complete).Run(success);
          },
          std::move(completion.first),
          base::ScopedClosureRunner(
              base::BindOnce(std::move(completion.second), false))));
  ScheduleSave();
  // Consume these callbacks in this UI turn, so another caller cannot replace
  // them before this specific snapshot is posted to the sequenced writer.
  writer_.DoScheduledWrite();
}

void BookmarkStorage::ScheduleSave() {""")
    result[MODEL_H] = replace(result[MODEL_H], '#include "base/containers/flat_map.h"',
                              '#include "base/containers/flat_map.h"\n#include "base/functional/callback_forward.h"')
    result[MODEL_H] = replace(result[MODEL_H], "  // Similar to Load() but allows unit-tests", """  // Captures both bookmark stores and completes on this sequence only after
  // their primary files have been written atomically. False means the caller
  // must retain its migration/retry state; mutations remain in the live model.
  // The model must be loaded with real storage, not an in-memory test model.
  void SaveForNative(base::OnceCallback<void(bool)> callback);

  // Similar to Load() but allows unit-tests""")
    result[MODEL_CC] = replace(result[MODEL_CC], '#include "base/check.h"',
                               '#include "base/barrier_callback.h"\n#include "base/check.h"')
    result[MODEL_CC] = replace(result[MODEL_CC], '#include "base/task/thread_pool.h"',
                               '#include "base/task/sequenced_task_runner.h"\n#include "base/task/thread_pool.h"')
    result[MODEL_CC] = replace(result[MODEL_CC], "void BookmarkModel::CommitPendingWriteForTest() {", """void BookmarkModel::SaveForNative(base::OnceCallback<void(bool)> callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!loaded_ || !local_or_syncable_store_) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(callback), false));
    return;
  }
  auto barrier = base::BarrierCallback<bool>(
      account_store_ ? 2 : 1,
      base::BindOnce(
          [](base::OnceCallback<void(bool)> complete, std::vector<bool> results) {
            std::move(complete).Run(
                std::all_of(results.begin(), results.end(), [](bool ok) { return ok; }));
          }, std::move(callback)));
  local_or_syncable_store_->SaveForNative(base::BindOnce(barrier));
  if (account_store_) account_store_->SaveForNative(base::BindOnce(barrier));
}

void BookmarkModel::CommitPendingWriteForTest() {""")
    result[TEST] = replace(result[TEST], '#include "base/test/task_environment.h"',
                          '#include "base/test/task_environment.h"\n#include "base/test/test_future.h"\n#include "base/functional/bind.h"')
    result[TEST] = replace(result[TEST], "}  // namespace bookmarks\n",
                          (ROOT / "bookmark_storage_tests.inc").read_text() + "\n}  // namespace bookmarks\n")
    return result


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    output = generated(originals)
    receipt = source / "out/zacro-bookmark-storage.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get("revision") != PIN:
        prior = {}
    for path, contents in output.items():
        target = source / path
        current = target.read_text() if target.exists() else ""
        if current not in (originals[path], contents) and digest(current) != prior.get("files", {}).get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path, contents in output.items())
    if not args.check:
        (ROOT / "native-bookmark-storage.patch").write_text(patch)
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Applied'} native durable bookmark storage for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
