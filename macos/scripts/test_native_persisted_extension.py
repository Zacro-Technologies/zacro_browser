"""Filesystem/receipt protocol checks only: no application, UI or CEF launch."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import native_persisted_extension as workflow


class PersistedExtensionWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zacro-lease-driver-test-")
        self.root = Path(self.temporary.name).resolve()
        self.patch = patch.object(workflow, "system_temporary_directory", return_value=self.root)
        self.patch.start()
        self.app = self.root / "Fixture.app"
        self.executable = self.app / "Contents/MacOS/Zacro Native"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"inert test executable; never launched")
        self.output = self.root / "evidence"
        self.session_path = workflow.prepare(self.app, self.output)
        self.session, self.profile, self.info = workflow.load_session(self.session_path)
        self.fixture_url = "http://127.0.0.1:37645/fixture"

    def tearDown(self):
        self.patch.stop()
        self.temporary.cleanup()

    def marker(self, **updates):
        # This synthetic marker is confined to this inert unit-test directory.
        # Real workflow prepare/launch-spec never create the app's owner marker.
        value = {"version": 1, "directory": str(self.profile), "device": self.info.st_dev,
                 "inode": self.info.st_ino, "uid": os.getuid(),
                 "nonceSHA256": hashlib.sha256(self.session["nonce"].encode()).hexdigest(),
                 "createdAt": time.time()}
        value.update(updates)
        workflow.write_private(self.profile / workflow.MARKER, value)

    def receipt(self, name="first", pid=12345, **updates):
        value = {"method": "LaunchServices with same-user kqueue exit-status observation",
                 "pid": pid, "executable": str(self.executable),
                 "started": time.strftime("%a %b %d %H:%M:%S %Y"),
                 "appExitCode": 0, "rawWaitStatus": 0,
                 "openExitCode": 0, "openWasTerminated": False}
        value.update(updates)
        path = self.output / (name + "-receipt.json")
        path.write_text(json.dumps(value))
        return path

    def fresh_spec(self):
        return workflow.launch_spec(self.session_path, "fresh", self.fixture_url)

    def finish_first(self):
        self.fresh_spec()
        self.marker()
        workflow.record_exit(self.session_path, "fresh", self.receipt())

    def test_prepare_private_empty_profile_without_app_marker(self):
        self.assertEqual(self.profile.parent, self.root)
        self.assertEqual(self.info.st_mode & 0o777, 0o700)
        self.assertEqual(self.session_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertRegex(self.session["nonce"], r"^[0-9a-f]{64}$")
        self.assertEqual(self.session["executableSHA256"], hashlib.sha256(self.executable.read_bytes()).hexdigest())

    def test_launch_spec_never_launches_or_claims_extension_success(self):
        path = self.fresh_spec()
        spec = workflow.private_json(path)
        self.assertIn("--engine-acceptance", spec["arguments"])
        self.assertIn("--native-ui-review", spec["arguments"])
        self.assertNotIn("--native-persisted-extension-resume", spec["arguments"])
        self.assertEqual(spec["environment"][workflow.NONCE_ENV], self.session["nonce"])
        self.assertFalse(spec["workerInspectorLaunchedByDriver"])
        self.assertFalse(spec["desktopInputLaunchedByDriver"])
        self.assertEqual(list(self.profile.iterdir()), [])
        with self.assertRaises(ValueError):
            self.fresh_spec()

    def test_resume_requires_app_marker_and_observed_normal_first_exit(self):
        with self.assertRaises(ValueError):
            workflow.launch_spec(self.session_path, "resume", self.fixture_url)
        self.fresh_spec()
        with self.assertRaises(FileNotFoundError):
            workflow.record_exit(self.session_path, "fresh", self.receipt())
        self.marker()
        result = workflow.record_exit(self.session_path, "fresh", self.receipt("verified"))
        self.assertTrue(result["normalExitVerified"])
        self.assertFalse(result["extensionUIBehaviorVerified"])
        resume = workflow.private_json(workflow.launch_spec(self.session_path, "resume", self.fixture_url))
        self.assertIn("--native-persisted-extension-resume", resume["arguments"])
        self.assertEqual(resume["environment"]["ZACRO_NATIVE_DATA"], str(self.profile))
        with self.assertRaises(ValueError):
            workflow.launch_spec(self.session_path, "resume", self.fixture_url)

    def test_second_exit_requires_distinct_pid_and_consumed_lease(self):
        self.finish_first()
        workflow.launch_spec(self.session_path, "resume", self.fixture_url)
        with self.assertRaises(ValueError):
            workflow.record_exit(self.session_path, "resume", self.receipt("same-pid"))
        with self.assertRaises(FileNotFoundError):
            workflow.record_exit(self.session_path, "resume", self.receipt("missing-consumption", 23456))
        descriptor = os.open(self.profile / workflow.RESUMED, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        result = workflow.record_exit(self.session_path, "resume", self.receipt("second", 23456))
        self.assertTrue(result["coldResumeLifecycleComplete"])
        self.assertFalse(result["extensionUIBehaviorVerified"])
        with self.assertRaises(ValueError):
            workflow.record_exit(self.session_path, "resume", self.receipt("duplicate", 34567))

    def test_actual_marker_lock_blocks_progress_until_owner_exits(self):
        self.fresh_spec()
        self.marker()
        descriptor = os.open(self.profile / workflow.MARKER, os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                workflow.record_exit(self.session_path, "fresh", self.receipt("locked"))
        finally:
            os.close(descriptor)
        self.assertTrue(workflow.record_exit(self.session_path, "fresh", self.receipt("unlocked"))["normalExitVerified"])

    def test_bad_marker_binding_and_exposed_session_fail_closed(self):
        self.marker(nonceSHA256="0" * 64)
        with self.assertRaises(ValueError):
            workflow.validate_marker(self.session, self.profile, self.info)
        self.session_path.chmod(0o644)
        with self.assertRaises(ValueError):
            workflow.load_session(self.session_path)

    def test_system_var_parent_alias_resolves_to_same_owned_directory(self):
        # Model the public macOS /var -> /private/var parent alias without
        # touching system directories. The profile leaf itself is not linked.
        alias = self.root / "var-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.marker(directory=str(alias / self.profile.name))
        workflow.validate_marker(self.session, self.profile, self.info)
        marker = workflow.private_json(self.profile / workflow.MARKER)
        self.assertNotEqual(marker["directory"], str(self.profile))
        self.assertEqual(Path(marker["directory"]).resolve(strict=True), self.profile)

    def test_marker_parent_alias_cannot_authorize_another_directory(self):
        other = self.root / (workflow.PREFIX + "other")
        other.mkdir(mode=0o700)
        self.marker(directory=str(other))
        with self.assertRaises(ValueError):
            workflow.validate_marker(self.session, self.profile, self.info)

    def test_immutable_executable_and_linked_profile_fail_closed(self):
        self.executable.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            workflow.load_session(self.session_path)
        linked = self.root / (workflow.PREFIX + "linked")
        linked.symlink_to(self.profile, target_is_directory=True)
        with self.assertRaises(ValueError):
            workflow.owned_directory(linked)

    def test_remote_or_credential_fixture_cannot_produce_launch_spec(self):
        for url in ("https://127.0.0.1:37645/", "http://example.com:37645/", "http://u:p@127.0.0.1:37645/"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                workflow.launch_spec(self.session_path, "fresh", url)

    def test_old_forced_or_incomplete_receipts_cannot_authorize_restart(self):
        self.fresh_spec()
        self.marker()
        invalid = ({"started": time.strftime("%a %b %d %H:%M:%S %Y", time.localtime(time.time() - 60))},
                   {"appExitCode": 1}, {"rawWaitStatus": 9}, {"openExitCode": None},
                   {"openWasTerminated": True}, {"method": "unobserved"}, {"started": None})
        for index, updates in enumerate(invalid):
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                workflow.record_exit(self.session_path, "fresh", self.receipt("invalid-" + str(index), **updates))
        self.assertNotIn("freshExit", workflow.private_json(self.session_path))


if __name__ == "__main__":
    unittest.main()
