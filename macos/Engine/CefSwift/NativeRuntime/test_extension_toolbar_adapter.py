#!/usr/bin/env python3
"""Pinned transformation/receipt tests; actual action grants require runtime acceptance."""
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
spec = importlib.util.spec_from_file_location("extension_toolbar_adapter", ROOT / "apply_extension_toolbar_adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class ExtensionToolbarAdapterTests(unittest.TestCase):
    def test_generation_preserves_complete_source_except_new_host(self):
        output = adapter.generated(self.originals)
        self.assertEqual(output, adapter.generated(self.originals))
        self.assertEqual(output[adapter.SOURCE].replace(adapter.HOST, adapter.ANCHOR), self.originals[adapter.SOURCE])

    def test_only_cef_hosted_non_guest_location_mode_gets_hidden_parent(self):
        output = adapter.generated(self.originals)[adapter.SOURCE]
        start = output.index(adapter.HOST)
        end = output.index("    initialized_ = true;\n    return;", start)
        location_branch = output[start:end]
        self.assertIn("#if BUILDFLAG(ENABLE_CEF)", location_branch)
        self.assertIn("cef_delegate && cef_delegate->IsViewsHosted() &&", location_branch)
        self.assertIn("!browser_->GetProfile()->IsGuestSession()", location_branch)
        self.assertLess(location_branch.index("native_action_host->SetVisible(false)"),
                        location_branch.index("std::make_unique<ExtensionsToolbarDesktop>"))
        self.assertIn("extensions_container_ = native_action_host->AddChildView(", location_branch)
        self.assertIn("std::make_unique<ExtensionsToolbarCoordinator>(extensions_container_)", location_branch)
        self.assertNotIn("SetVisible(true)", location_branch)
        self.assertNotIn("SetBounds", location_branch)

    def test_normal_toolbar_branch_and_destructor_are_unchanged(self):
        original = self.originals[adapter.SOURCE]
        output = adapter.generated(self.originals)[adapter.SOURCE]
        normal = "  const auto callback = [](BrowserWindowInterface* browser, int command,"
        self.assertEqual(output[output.index(normal):], original[original.index(normal):])
        init = "void ToolbarView::Init() {"
        self.assertEqual(output[:output.index(init)], original[:original.index(init)])

    def test_drift_is_rejected(self):
        original = self.originals[adapter.SOURCE].replace(adapter.ANCHOR, "changed branch")
        with self.assertRaisesRegex(SystemExit, "source drift"):
            adapter.generated({adapter.SOURCE: original})

    def test_baseline_and_generated_source_are_accepted(self):
        output = adapter.generated(self.originals)
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)

    def test_unrelated_edits_and_unpinned_upgrade_are_rejected(self):
        output = adapter.generated(self.originals)
        previous = {adapter.SOURCE: output[adapter.SOURCE] + "// previous generated version\n"}
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous)
        receipt = {"revision": adapter.PIN, "cefRevision": adapter.CEF_PIN,
                   "files": {path: adapter.digest(value) for path, value in previous.items()}}
        adapter.validate_current(self.originals, output, previous, receipt)
        for key in ("revision", "cefRevision"):
            wrong = dict(receipt); wrong[key] = "wrong"
            with self.assertRaisesRegex(SystemExit, "unrelated edits"):
                adapter.validate_current(self.originals, output, previous, wrong)
        previous[adapter.SOURCE] += "// user edit after generated version\n"
        with self.assertRaisesRegex(SystemExit, "unrelated edits"):
            adapter.validate_current(self.originals, output, previous, receipt)

    def test_check_emit_and_idempotent_apply_have_separate_write_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="zacro-toolbar-test-") as temporary:
            root = Path(temporary); source = root / "source"; artifacts = root / "artifacts"
            artifacts.mkdir(); (source / "cef").mkdir(parents=True)
            target = source / adapter.SOURCE
            target.parent.mkdir(parents=True); target.write_text(self.originals[adapter.SOURCE])

            def git(command, *, cwd, text):
                self.assertEqual(command, ["git", "rev-parse", "HEAD"])
                return (adapter.CEF_PIN if Path(cwd).name == "cef" else adapter.PIN) + "\n"

            def run(*args):
                with mock.patch.object(adapter.subprocess, "check_output", side_effect=git), \
                     mock.patch.object(adapter, "source_baselines", return_value=self.originals), \
                     mock.patch.object(adapter, "ROOT", artifacts), \
                     mock.patch("sys.argv", ["adapter", "--chromium-root", str(source), *args]), \
                     contextlib.redirect_stdout(io.StringIO()):
                    adapter.main()

            run("--check")
            self.assertEqual(list(artifacts.iterdir()), [])
            self.assertFalse((source / "out").exists())
            run("--emit-patch")
            self.assertTrue((artifacts / "native-extension-toolbar.patch").is_file())
            self.assertEqual(target.read_text(), self.originals[adapter.SOURCE])
            self.assertFalse((source / "out").exists())
            run()
            self.assertEqual(target.read_text(), adapter.generated(self.originals)[adapter.SOURCE])
            modified = target.stat().st_mtime_ns
            run(); self.assertEqual(target.stat().st_mtime_ns, modified)
            receipt = json.loads((source / "out/zacro-extension-toolbar.json").read_text())
            self.assertEqual(receipt["revision"], adapter.PIN)
            self.assertEqual(receipt["cefRevision"], adapter.CEF_PIN)
            self.assertEqual(receipt["files"], {adapter.SOURCE: adapter.digest(target.read_text())})
            before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in root.rglob("*") if path.is_file()}
            run("--check")
            self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in root.rglob("*") if path.is_file()})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", required=True, type=Path)
    args, rest = parser.parse_known_args()
    for directory, expected in ((args.chromium_root, adapter.PIN), (args.chromium_root / "cef", adapter.CEF_PIN)):
        if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=directory, text=True).strip() != expected:
            raise SystemExit("Pinned Chromium and CEF sources required")
    ExtensionToolbarAdapterTests.originals = adapter.source_baselines(args.chromium_root)
    unittest.main(argv=[__file__] + rest)
