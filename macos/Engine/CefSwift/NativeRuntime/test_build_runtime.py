#!/usr/bin/env python3
"""Provenance regressions; no Chromium build or network is performed."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("build_runtime", pathlib.Path(__file__).with_name("build_runtime.py"))
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class RuntimeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.inputs = self.root / "native"
        self.inputs.mkdir()
        (self.inputs / "build_runtime.py").write_text("driver")
        (self.inputs / "native.inc").write_text("first")
        self.source = self.root / "chromium/src"
        (self.source / "cef").mkdir(parents=True)
        (self.source / "cef/BUILD.gn").write_text("pinned")
        self.out = self.source / "out/Release_GN_arm64"
        self.out.mkdir(parents=True)
        (self.out / "args.gn").write_text('target_cpu="arm64"\n')
        (self.out / "build.ninja").write_text("generated")
        self.framework = self.out / "Chromium Embedded Framework.framework"
        self.framework.mkdir()
        (self.framework / "Chromium Embedded Framework").write_bytes(b"test Mach-O")
        (self.framework / "Resources").mkdir()
        (self.framework / "Resources/icudtl.dat").write_bytes(b"test ICU")
        (self.framework / "Resources/link").symlink_to("icudtl.dat")
        self.here = mock.patch.object(build, "HERE", self.inputs)
        self.here.start()
        self.addCleanup(self.here.stop)

    def run_build(self, mutate=None):
        builds = []
        def execute(command, cwd, environment):
            if command[0] == "autoninja":
                builds.append(command)
                if mutate:
                    mutate(len(builds))
        with mock.patch.object(build, "run", side_effect=execute), \
             mock.patch.object(build, "source_revision", side_effect=lambda p: build.CEF_COMMIT + "1234" if p.name == "cef" else build.CHROMIUM_COMMIT), \
             mock.patch.object(build.shutil, "disk_usage", return_value=type("Space", (), {"free": 100 * build.GIB})()), \
             mock.patch.object(build.sys, "argv", ["build_runtime.py", "--download-dir", str(self.root), "--skip-generation"]), \
             contextlib.redirect_stdout(io.StringIO()):
            build.main()
        return builds, json.loads((self.out / "zacro-runtime-build.json").read_text())

    def test_complete_manifest_includes_resources_links_and_input_hashes(self):
        builds, receipt = self.run_build()
        self.assertEqual(len(builds), 1)
        self.assertEqual(receipt["nativeInputs"], build.native_inputs())
        self.assertEqual(receipt["gnArgsSha256"], build.digest(self.out / "args.gn"))
        self.assertEqual(receipt["files"]["Resources/icudtl.dat"], build.digest(self.framework / "Resources/icudtl.dat"))
        self.assertEqual(receipt["symlinks"], {"Resources/link": "icudtl.dat"})
        self.assertEqual(receipt["chromiumCommit"], build.CHROMIUM_COMMIT)

    def test_changed_native_inputs_require_another_successful_build(self):
        def change(count):
            if count == 1:
                (self.inputs / "native.inc").write_text("second")
        builds, receipt = self.run_build(change)
        self.assertEqual(len(builds), 2)
        self.assertEqual(receipt["nativeInputs"]["native.inc"], build.digest(self.inputs / "native.inc"))

    def test_changed_gn_arguments_require_another_successful_build(self):
        def change(count):
            if count == 1:
                with (self.out / "args.gn").open("a") as handle:
                    handle.write("symbol_level=0\n")
        builds, receipt = self.run_build(change)
        self.assertEqual(len(builds), 2)
        self.assertEqual(receipt["gnArgsSha256"], build.digest(self.out / "args.gn"))

    def test_changed_input_during_framework_hashing_requires_rebuild(self):
        original = build.framework_manifest
        count = 0
        def manifest(path):
            nonlocal count
            result = original(path)
            count += 1
            if count == 1:
                (self.inputs / "native.inc").write_text("during hash")
            return result
        with mock.patch.object(build, "framework_manifest", side_effect=manifest):
            builds, _ = self.run_build()
        self.assertEqual(len(builds), 2)

    def test_failed_rebuild_cannot_leave_old_receipt(self):
        receipt = self.out / "zacro-runtime-build.json"
        receipt.write_text('{"old":true}')
        def fail(_):
            raise SystemExit(1)
        with self.assertRaises(SystemExit):
            self.run_build(fail)
        self.assertFalse(receipt.exists())

    def test_framework_external_links_and_broken_links_rejected(self):
        outside = self.root / "outside"
        outside.write_text("not part of framework")
        for destination in (str(outside), "missing"):
            with self.subTest(destination=destination):
                link = self.framework / "invalid"
                link.symlink_to(destination)
                with self.assertRaises(SystemExit):
                    build.framework_manifest(self.framework)
                link.unlink()

    def test_code_signature_is_excluded_but_other_resources_are_not(self):
        signature = self.framework / "_CodeSignature"
        signature.mkdir()
        (signature / "CodeResources").write_text("ad hoc signing occurs after build")
        self.assertFalse(any("_CodeSignature" in name for name in build.framework_manifest(self.framework)["files"]))

    def test_changed_driver_reexecs_current_code_before_certification(self):
        before = build.digest(self.inputs / "build_runtime.py")
        (self.inputs / "build_runtime.py").write_text("updated driver")
        with mock.patch.object(build.os, "execv", side_effect=RuntimeError("reexec")) as execute, \
             mock.patch.object(build.sys, "argv", ["build_runtime.py", "--download-dir", str(self.root)]), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "reexec"):
                build.restart_if_driver_changed(before)
        self.assertIn("--skip-generation", execute.call_args.args[1])


if __name__ == "__main__":
    unittest.main()
