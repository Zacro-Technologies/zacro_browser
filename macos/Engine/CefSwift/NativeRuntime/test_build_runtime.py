#!/usr/bin/env python3
"""Provenance regressions; no Chromium build or network is performed."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import time
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

    def run_build(self, mutate=None, jobs=4):
        builds = []
        def execute(command, cwd, environment, **kwargs):
            if command[0] == "autoninja":
                builds.append(command)
                if mutate:
                    mutate(len(builds))
        with mock.patch.object(build, "run", side_effect=execute), \
             mock.patch.object(build, "source_revision", side_effect=lambda p: build.CEF_COMMIT + "1234" if p.name == "cef" else build.CHROMIUM_COMMIT), \
             mock.patch.object(build.shutil, "disk_usage", return_value=type("Space", (), {"free": 100 * build.GIB})()), \
             mock.patch.object(build.sys, "argv", ["build_runtime.py", "--download-dir", str(self.root), "--skip-generation", "--jobs", str(jobs)]), \
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

    def test_runtime_preparation_applies_hosted_extension_toolbar(self):
        with mock.patch.object(build, "run") as execute:
            build.apply_inputs(self.source, {})
        commands = [call.args[0] for call in execute.call_args_list]
        self.assertIn([build.sys.executable,
                       str(self.inputs / "apply_extension_toolbar_adapter.py"),
                       "--chromium-root", str(self.source)], commands)

    def test_resumed_release_disables_developer_fieldtrial_matrix(self):
        args = self.out / "args.gn"
        args.write_text('target_cpu="arm64"\ndisable_fieldtrial_testing_config=false\nsymbol_level=0\n')
        builds, receipt = self.run_build()
        self.assertEqual(len(builds), 1)
        self.assertEqual(args.read_text().count("disable_fieldtrial_testing_config="), 1)
        self.assertIn("disable_fieldtrial_testing_config=true\n", args.read_text())
        self.assertIn("symbol_level=0\n", args.read_text())
        self.assertEqual(receipt["gnArgsSha256"], build.digest(args))

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

    def test_pressure_retries_at_eight_before_certifying(self):
        def pressure(count):
            if count == 1:
                raise build.ResourcePressure("test pressure")
        builds, receipt = self.run_build(pressure, jobs=10)
        self.assertEqual([command[-1] for command in builds], ["-j10", "-j8"])
        self.assertEqual(receipt["nativeInputs"], build.native_inputs())

    def test_driver_upgrade_preserves_reduced_parallelism_and_guard(self):
        before = build.digest(self.inputs / "build_runtime.py")
        (self.inputs / "build_runtime.py").write_text("upgrade")
        with mock.patch.object(build.os, "execv", side_effect=RuntimeError("reexec")) as execute, \
             mock.patch.object(build.sys, "argv", ["build_runtime.py", "--jobs", "10"]), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "reexec"):
                build.restart_if_driver_changed(before, 8, True)
        arguments = execute.call_args.args[1]
        self.assertEqual(arguments[arguments.index("--jobs") + 1], "8")
        self.assertIn("--guard-resources", arguments)

    def test_fallback_stays_at_eight_across_changed_source_rebuild(self):
        def change(count):
            if count == 1:
                raise build.ResourcePressure("test pressure")
            if count == 2:
                (self.inputs / "native.inc").write_text("changed")
        builds, _ = self.run_build(change, jobs=10)
        self.assertEqual([command[-1] for command in builds], ["-j10", "-j8", "-j8"])

    def test_compiler_failure_is_not_a_resource_retry(self):
        calls = []
        def fail(count):
            calls.append(count)
            raise SystemExit(7)
        with self.assertRaises(SystemExit) as result:
            self.run_build(fail, jobs=10)
        self.assertEqual(result.exception.code, 7)
        self.assertEqual(calls, [1])

    def test_fallback_pressure_stops_without_receipt_or_loop(self):
        calls = []
        def fail(count):
            calls.append(count)
            raise build.ResourcePressure("test pressure")
        with self.assertRaisesRegex(SystemExit, "fallback"):
            self.run_build(fail, jobs=10)
        self.assertEqual(calls, [1, 2])
        self.assertFalse((self.out / "zacro-runtime-build.json").exists())


class ResourceGuardTests(unittest.TestCase):
    def sample(self, **kwargs):
        return {"pressure": 1, "availableBytes": 4 * build.GIB,
                "compilerRSSBytes": 6 * build.GIB, "buildRSSBytes": 7 * build.GIB,
                "swapBytes": 2 * build.GIB, **kwargs}

    def test_thresholds_use_swap_delta_not_existing_swap(self):
        baseline = 2 * build.GIB
        self.assertIsNone(build.pressure_reason(self.sample(), baseline, 10))
        self.assertEqual(build.pressure_reason(self.sample(swapBytes=baseline + 300 * 1024 ** 2), baseline, 10), "new swap growth")
        for values, message in [({"pressure": 2}, "system memory pressure"),
                                ({"pressure": 4}, "system memory pressure"),
                                ({"pressure": 0}, "unknown memory pressure state"),
                                ({"availableBytes": build.GIB}, "low available memory"),
                                ({"compilerRSSBytes": 9.1 * build.GIB}, "owned compiler/build RSS limit"),
                                ({"buildRSSBytes": 10.1 * build.GIB}, "owned compiler/build RSS limit")]:
            with self.subTest(values=values):
                self.assertEqual(build.pressure_reason(self.sample(**values), baseline, 10), message)
        self.assertIsNone(build.pressure_reason(self.sample(pressure=2), baseline, 8))
        self.assertEqual(build.pressure_reason(self.sample(pressure=4), baseline, 8), "system memory pressure")

    def test_process_scope_excludes_unrelated_compilers(self):
        snapshot = {1: {"parent": 0}, 2: {"parent": 1}, 3: {"parent": 2},
                    4: {"parent": 0}, 5: {"parent": 4}}
        self.assertEqual(set(build.descendants(snapshot, 1)), {1, 2, 3})
        self.assertEqual(build.descendants(snapshot, 99), {})

    def test_missing_telemetry_fails_closed_and_logs_reason(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "resources.jsonl"
            guard = build.BuildResourceGuard(10, path)
            with mock.patch.object(build, "process_snapshot", return_value={}), \
                 mock.patch.object(build, "system_resources", side_effect=ValueError("unavailable")):
                with self.assertRaisesRegex(build.ResourcePressure, "telemetry unavailable"):
                    guard.check(type("Process", (), {"pid": 123})())
            self.assertEqual(json.loads(path.read_text())["jobs"], 10)

    def test_guarded_run_reaps_only_its_process_and_preserves_unrelated_one(self):
        unrelated = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        guard = mock.Mock()
        guard.check.side_effect = build.ResourcePressure("test stop")
        try:
            with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()), \
                 mock.patch.object(build.shutil, "disk_usage", return_value=type("Space", (), {"free": 100 * build.GIB})()):
                with self.assertRaisesRegex(build.ResourcePressure, "test stop"):
                    build.run(["/bin/sleep", "30"], pathlib.Path(folder), dict(os.environ), resource_guard=guard)
            self.assertIsNone(unrelated.poll())
            self.assertEqual(guard.check.call_args.args[0].poll(), -15)
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_cleanup_includes_child_with_separate_process_group(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "child.pid"
            child_id = []
            def stop_when_child_exists(process):
                deadline = time.monotonic() + 3
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                child_id.append(int(path.read_text()))
                raise build.ResourcePressure("detached compiler")
            guard = mock.Mock()
            guard.check.side_effect = stop_when_child_exists
            script = ("import pathlib,subprocess,sys,time; "
                      "p=subprocess.Popen(['/bin/sleep','30'],start_new_session=True); "
                      "pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(30)")
            with contextlib.redirect_stdout(io.StringIO()), \
                 mock.patch.object(build.shutil, "disk_usage", return_value=type("Space", (), {"free": 100 * build.GIB})()):
                with self.assertRaisesRegex(build.ResourcePressure, "detached compiler"):
                    build.run([build.sys.executable, "-c", script, str(path)], pathlib.Path(folder),
                              dict(os.environ), resource_guard=guard)
            self.assertNotIn(child_id[0], build.process_snapshot())

    def test_cleanup_discovers_new_group_spawned_during_termination(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "late-child.pid"
            ready = pathlib.Path(folder) / "ready"
            script = """import os,pathlib,signal,subprocess,sys,time
def terminate(*_):
    child=subprocess.Popen(['/bin/sleep','30'],preexec_fn=os.setpgrp)
    pathlib.Path(sys.argv[1]).write_text(str(child.pid))
    sys.exit(0)
signal.signal(signal.SIGTERM,terminate)
pathlib.Path(sys.argv[2]).touch()
time.sleep(30)
"""
            process = subprocess.Popen([build.sys.executable, "-c", script, str(path), str(ready)], start_new_session=True)
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                build.stop_owned_process(process)
                self.assertNotIn(int(path.read_text()), build.process_snapshot())
                self.assertIsNotNone(process.returncode)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    unittest.main()
