#!/usr/bin/env python3
"""Check the pinned patch and run its exact callback with native FD/thread stand-ins.

The isolated C++ fixture verifies ownership, routing, and actual descriptor close
threads; it is not a full Chromium GPU-process integration test.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("adapter", ROOT / "apply_gpu_cache_cleanup.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def callback(source):
    start = source.index("[](scoped_refptr<PersistentCacheSandboxedFileFactory>")
    end = source.index("\n              },", start) + len("\n              }")
    return source[start:end]


class CacheCleanupTests(unittest.TestCase):
    def test_transformation_is_repeatable(self):
        self.assertEqual(adapter.generated(self.originals), adapter.generated(self.originals))

    def test_source_drift_is_rejected(self):
        altered = {adapter.SOURCE: self.originals[adapter.SOURCE].replace(
            "if (!gpu_host || !pending_backend)", "if (!pending_backend)")}
        with self.assertRaisesRegex(SystemExit, "source drift"):
            adapter.generated(altered)

    def test_unrelated_edits_are_never_overwritten(self):
        output = adapter.generated(self.originals)
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)
        altered = {adapter.SOURCE: output[adapter.SOURCE] + "// user edit\n"}
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, altered)

    def test_upgrade_requires_exact_receipt_and_revision(self):
        output = adapter.generated(self.originals)
        previous = {adapter.SOURCE: output[adapter.SOURCE] + "// prior generated version\n"}
        receipt = {"revision": adapter.PIN, "files": {adapter.SOURCE: adapter.digest(previous[adapter.SOURCE])}}
        adapter.validate_current(self.originals, output, previous, receipt)
        receipt["revision"] = "wrong"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous, receipt)

    def test_success_and_factory_retention_contract(self):
        output = adapter.generated(self.originals)[adapter.SOURCE]
        body = callback(output)
        self.assertIn("base::WrapRefCounted(persistent_cache_file_factory)", output)
        self.assertNotIn("GetInstance", body)
        self.assertNotIn("AllowBlocking", body)
        self.assertEqual(body.count("OnPersistentCacheFilesCreated("), 1)
        self.assertIn("handle, std::move(*pending_backend)", body)
        # This patch does not change startup cache choice, retry policy, or the
        # normal channel/cache cleanup paths.
        for marker in ["void GpuHostImpl::SetChannelPersistentCachePendingBackend(",
                       "void GpuHostImpl::ClearPersistentCaches("]:
            original = self.originals[adapter.SOURCE]
            self.assertEqual(original[original.index(marker):], output[output.index(marker):])

    def test_exact_callback_preserves_fds_and_disposes_only_on_worker(self):
        if self.source_only:
            self.skipTest("Source-only run; native callback fixture is authored but not compiled.")
        output = adapter.generated(self.originals)[adapter.SOURCE]
        with tempfile.TemporaryDirectory(prefix="zacro-cache-cleanup-") as directory:
            root = Path(directory)
            source = root / "callback.cc"
            source.write_text(PRELUDE + "\nauto cleanup = " + callback(output) + ";\n" + FIXTURE)
            binary = root / "callback"
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-pthread", str(source), "-o", str(binary)], check=True)
            result = subprocess.check_output([str(binary)], text=True)
            self.assertEqual(result.strip(), "9 native GPU cache callback checks passed")


PRELUDE = r'''
#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>
const auto ui_thread = std::this_thread::get_id();
std::atomic<int> ui_closes = 0, worker_closes = 0;
template<class T> using scoped_refptr = std::shared_ptr<T>;
namespace base {
template<class T> struct WeakPtr {
  std::weak_ptr<T> value;
  explicit operator bool() const { return !value.expired(); }
  T* operator->() const { return value.lock().get(); }
};
}
namespace gpu { using GpuDiskCacheHandle = int; }
namespace persistent_cache {
struct PendingBackend {
  int fd;
  explicit PendingBackend(int value): fd(value) {}
  PendingBackend(PendingBackend&& value): fd(std::exchange(value.fd, -1)) {}
  PendingBackend(const PendingBackend&) = delete;
  ~PendingBackend() {
    if (fd < 0) return;
    if (std::this_thread::get_id() == ui_thread) ++ui_closes;
    else ++worker_closes;
    close(fd);
  }
};
}
struct PersistentCacheSandboxedFileFactory {
  int deletes = 0;
  std::vector<std::thread> workers;
  void DeletePendingBackendAsync(persistent_cache::PendingBackend value) {
    ++deletes;
    workers.emplace_back([value = std::move(value)]() {});
  }
  void Drain() { for (auto& worker: workers) if (worker.joinable()) worker.join(); }
  ~PersistentCacheSandboxedFileFactory() { Drain(); }
};
struct GpuHostImpl {
  int handle = -1;
  std::optional<persistent_cache::PendingBackend> received;
  void OnPersistentCacheFilesCreated(int value, persistent_cache::PendingBackend backend) {
    handle = value; received.emplace(std::move(backend));
  }
};
'''

FIXTURE = r'''
int main() {
  int checks = 0;
  auto expect = [&](bool value) { if (!value) throw std::runtime_error("Cache cleanup invariant"); ++checks; };
  auto factory = std::make_shared<PersistentCacheSandboxedFileFactory>();
  auto live = std::make_shared<GpuHostImpl>();
  base::WeakPtr<GpuHostImpl> weak{live};
  cleanup(factory, weak, 7, std::nullopt);
  expect(factory->deletes == 0 && !live->received && ui_closes == 0);
  int fd = open("/dev/null", O_RDONLY);
  expect(fd >= 0);
  cleanup(factory, weak, 7, persistent_cache::PendingBackend(fd));
  expect(live->handle == 7 && live->received && live->received->fd == fd && fcntl(fd, F_GETFD) >= 0);
  expect(factory->deletes == 0 && ui_closes == 0 && worker_closes == 0);
  factory->DeletePendingBackendAsync(std::move(*live->received));
  live->received.reset(); factory->Drain(); live.reset();
  expect(ui_closes == 0 && worker_closes == 1 && fcntl(fd, F_GETFD) == -1 && errno == EBADF);
  std::weak_ptr<PersistentCacheSandboxedFileFactory> original = factory;
  std::function<void(std::optional<persistent_cache::PendingBackend>)> reply =
    [retained = factory, weak](auto backend) { cleanup(retained, weak, 9, std::move(backend)); };
  factory = std::make_shared<PersistentCacheSandboxedFileFactory>();
  expect(!original.expired()); // The global/current factory can be replaced.
  fd = open("/dev/null", O_RDONLY);
  if (fd < 0) return 2;
  reply(persistent_cache::PendingBackend(fd));
  auto retained = original.lock(); retained->Drain();
  expect(retained->deletes == 2 && factory->deletes == 0);
  expect(ui_closes == 0 && worker_closes == 2 && fcntl(fd, F_GETFD) == -1 && errno == EBADF);
  retained.reset(); reply = {};
  expect(original.expired());
  std::cout << checks << " native GPU cache callback checks passed\n";
}
'''

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--source-only", action="store_true")
    args, rest = parser.parse_known_args()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.chromium_root, text=True).strip()
    if revision != adapter.PIN:
        raise SystemExit("Pinned Chromium revision required")
    CacheCleanupTests.originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path],
        cwd=args.chromium_root, text=True) for path in adapter.PATHS}
    CacheCleanupTests.source_only = args.source_only
    unittest.main(argv=[__file__] + rest)
