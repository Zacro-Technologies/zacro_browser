#!/usr/bin/env python3
"""Dispose abandoned GPU cache handles on their originating blocking task runner."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
SOURCE = "components/viz/host/gpu_host_impl.cc"
PATHS = (SOURCE,)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned GPU cache source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    source = replace(originals[SOURCE], '#include "base/no_destructor.h"',
        '#include "base/memory/scoped_refptr.h"\n#include "base/no_destructor.h"')
    source = replace(source, '''              [](base::WeakPtr<GpuHostImpl> gpu_host,
                 gpu::GpuDiskCacheHandle handle,
                 std::optional<persistent_cache::PendingBackend>
                     pending_backend) {
                if (!gpu_host || !pending_backend) {
                  return;
                }

                gpu_host->OnPersistentCacheFilesCreated(
                    handle, std::move(*pending_backend));
              },
              weak_ptr_factory_.GetWeakPtr(), handle),''', '''              [](scoped_refptr<PersistentCacheSandboxedFileFactory> file_factory,
                 base::WeakPtr<GpuHostImpl> gpu_host,
                 gpu::GpuDiskCacheHandle handle,
                 std::optional<persistent_cache::PendingBackend>
                     pending_backend) {
                if (!pending_backend) {
                  return;
                }
                if (!gpu_host) {
                  // The GPU may exit while its cache files are being opened.
                  // Closing these handles may block; use the retained original
                  // factory even if the global instance has since changed.
                  file_factory->DeletePendingBackendAsync(
                      std::move(*pending_backend));
                  return;
                }

                gpu_host->OnPersistentCacheFilesCreated(
                    handle, std::move(*pending_backend));
              },
              base::WrapRefCounted(persistent_cache_file_factory),
              weak_ptr_factory_.GetWeakPtr(), handle),''')
    return {SOURCE: source}


def digest(contents):
    return hashlib.sha256(contents.encode()).hexdigest()


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if prior.get("revision") == PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true", help="Write the reviewable patch without mutating Chromium.")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    output = generated(originals)
    receipt = source / "out/zacro-gpu-cache-cleanup.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-gpu-cache-cleanup.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {
            p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} GPU cache cleanup for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
