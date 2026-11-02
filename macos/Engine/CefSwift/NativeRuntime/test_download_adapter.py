#!/usr/bin/env python3
"""Verify pinned download transformation and safe application boundaries.

These tests do not execute Chromium. The real MV3 download/pause/resume/rename
fixture remains the runtime acceptance gate for the changed Chrome behavior.
"""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("download_adapter", ROOT / "apply_download_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class DownloadAdapterTests(unittest.TestCase):
    def test_repeatable_generation(self):
        self.assertEqual(adapter.generated(self.originals), adapter.generated(self.originals))

    def test_chrome_factory_opts_in_alloy_constructor_stays_default_false(self):
        output = adapter.generated(self.originals)
        self.assertIn("bool chrome_owns_browserless_downloads = false", output[adapter.HEADER])
        self.assertIn("/*chrome_owns_browserless_downloads=*/true", output[adapter.FACTORY])
        self.assertIn("if (!browser && chrome_owns_browserless_downloads_)", output[adapter.IMPL])
        self.assertIn("item->Cancel(true);", output[adapter.IMPL])

    def test_original_target_permission_and_danger_paths_unchanged(self):
        output = adapter.generated(self.originals)[adapter.IMPL]
        original = self.originals[adapter.IMPL]
        for marker in ["bool CefDownloadManagerDelegateImpl::DetermineDownloadTarget(",
                       "void CefDownloadManagerDelegateImpl::OnBrowserDestroyed(",
                       "void CefDownloadManagerDelegateImpl::OnDownloadUpdated("]:
            # Compare the complete method, not a string-presence approximation.
            self.assertEqual(method(original, marker), method(output, marker))

    def test_changed_source_anchor_rejects(self):
        originals = dict(self.originals)
        originals[adapter.FACTORY] = originals[adapter.FACTORY].replace(
            "CefDownloadManagerDelegateImpl>(download_manager)", "CefDownloadManagerDelegateImpl>(other_manager)")
        with self.assertRaisesRegex(SystemExit, "source drift"):
            adapter.generated(originals)

    def test_pristine_and_applied_inputs_are_accepted(self):
        output = adapter.generated(self.originals)
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)

    def test_unrelated_edit_rejected_even_with_other_files_applied(self):
        output = adapter.generated(self.originals)
        current = dict(output)
        current[adapter.IMPL] += "// unrelated user edit\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, current)

    def test_upgrade_requires_exact_file_hash_and_both_pins(self):
        output = adapter.generated(self.originals)
        previous = dict(output)
        previous[adapter.IMPL] += "// prior generated version\n"
        receipt = {"revision": adapter.PIN, "cefRevision": adapter.CEF_PIN,
                   "files": {p: adapter.digest(c) for p, c in previous.items()}}
        adapter.validate_current(self.originals, output, previous, receipt)
        for key in ("revision", "cefRevision"):
            invalid = dict(receipt); invalid[key] = "wrong"
            with self.assertRaisesRegex(SystemExit, "unrelated edits"):
                adapter.validate_current(self.originals, output, previous, invalid)
        previous[adapter.IMPL] += "// later user change\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous, receipt)

    def test_check_is_read_only_emit_only_writes_patch_apply_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="zacro-download-adapter-") as temporary:
            root = Path(temporary)
            source = root / "source"; artifacts = root / "artifacts"; artifacts.mkdir()
            for path, contents in self.originals.items():
                target = source / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(contents)
            def git(command, *, cwd, text):
                self.assertEqual(command[:1], ["git"])
                if command[1:] == ["rev-parse", "HEAD"]:
                    return (adapter.CEF_PIN if Path(cwd).name == "cef" else adapter.PIN) + "\n"
                return self.originals["cef/" + command[2].removeprefix("HEAD:")]
            def run(*args):
                with mock.patch.object(adapter.subprocess, "check_output", side_effect=git), \
                     mock.patch.object(adapter, "ROOT", artifacts), \
                     mock.patch("sys.argv", ["adapter", "--chromium-root", str(source), *args]), \
                     contextlib.redirect_stdout(io.StringIO()):
                    adapter.main()
            run("--check")
            self.assertEqual(list(artifacts.iterdir()), [])
            self.assertFalse((source / "out").exists())
            run("--emit-patch")
            self.assertTrue((artifacts / "native-browserless-downloads.patch").is_file())
            self.assertFalse((source / "out").exists())
            self.assertEqual({p: (source / p).read_text() for p in adapter.PATHS}, self.originals)
            run()
            output = adapter.generated(self.originals)
            self.assertEqual({p: (source / p).read_text() for p in adapter.PATHS}, output)
            times = {p: (source / p).stat().st_mtime_ns for p in adapter.PATHS}
            run()
            self.assertEqual({p: (source / p).stat().st_mtime_ns for p in adapter.PATHS}, times)
            receipt = json.loads((source / "out/zacro-browserless-downloads.json").read_text())
            self.assertEqual(receipt["cefRevision"], adapter.CEF_PIN)
            self.assertEqual(receipt["files"], {p: adapter.digest(c) for p, c in output.items()})
            patch_time = (artifacts / "native-browserless-downloads.patch").stat().st_mtime_ns
            run("--check")
            self.assertEqual((artifacts / "native-browserless-downloads.patch").stat().st_mtime_ns, patch_time)


def method(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    level = 1; cursor = brace + 1
    while level:
        if source[cursor] == "{": level += 1
        elif source[cursor] == "}": level -= 1
        cursor += 1
    return source[start:cursor]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", required=True, type=Path)
    args, rest = parser.parse_known_args()
    for directory, expected in ((args.chromium_root, adapter.PIN), (args.chromium_root / "cef", adapter.CEF_PIN)):
        if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=directory, text=True).strip() != expected:
            raise SystemExit("Pinned Chromium and CEF source required")
    DownloadAdapterTests.originals = {p: subprocess.check_output(["git", "show", "HEAD:" + p.removeprefix("cef/")],
        cwd=args.chromium_root / "cef", text=True) for p in adapter.PATHS}
    unittest.main(argv=[__file__] + rest)
