"""Verify real same-user exit observation and fail-closed diagnostic cleanup."""

import contextlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

from native_foreground_process import AcceptanceProfile, ExitStatusMonitor, ForegroundProcess


@unittest.skipUnless(sys.platform == "darwin", "macOS kqueue lifecycle contract")
class NativeForegroundProcessTests(unittest.TestCase):
    def setUp(self):
        self.children = []
        self.monitors = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            if child.stdout:
                child.stdout.close()
        for monitor in self.monitors:
            monitor.close()

    def child(self, source):
        child = subprocess.Popen([sys.executable, "-B", "-c", source], stdout=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def monitor(self, pid):
        monitor = ExitStatusMonitor(pid)
        self.monitors.append(monitor)
        return monitor

    def test_successful_child_exit_is_observed(self):
        child = self.child("import time; time.sleep(.15)")
        self.assertEqual(self.monitor(child.pid).wait(3), 0)

    def test_nonchild_failure_is_not_replaced_by_successful_launcher_exit(self):
        launcher = self.child("import os,time\np=os.fork()\n"
                             "if p==0: time.sleep(.3); os._exit(7)\n"
                             "print(p,flush=True); os._exit(0)")
        pid = int(launcher.stdout.readline())
        monitor = self.monitor(pid)
        self.assertEqual(launcher.wait(timeout=3), 0)
        self.assertEqual(monitor.wait(3), 7)
        self.assertEqual(monitor.raw_status, 7 << 8)

    def test_signal_exit_remains_a_failure(self):
        child = self.child("import time; time.sleep(10)")
        monitor = self.monitor(child.pid)
        child.terminate()
        self.assertEqual(monitor.wait(3), -signal.SIGTERM)

    def test_observation_timeout_does_not_terminate_the_process(self):
        child = self.child("import time; time.sleep(10)")
        monitor = self.monitor(child.pid)
        with self.assertRaises(subprocess.TimeoutExpired):
            monitor.wait(.02)
        self.assertIsNone(child.poll())

    def test_changed_process_identity_is_not_signalled(self):
        child = self.child("import time; time.sleep(10)")
        process = ForegroundProcess.__new__(ForegroundProcess)
        process.pid = child.pid
        process.executable = Path(sys.executable).resolve()
        process.started = "different process incarnation"
        process.monitor = self.monitor(child.pid)
        with self.assertRaisesRegex(RuntimeError, "identity"):
            process.terminate()
        self.assertIsNone(child.poll())

    def test_live_or_unknown_application_keeps_its_disposable_profile(self):
        scope = AcceptanceProfile(tempfile.gettempdir())
        path = Path(scope.directory)
        scope.launch_attempted = True
        child = self.child("import time; time.sleep(10)")
        scope.process = child
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                scope.__exit__(None, None, None)
            self.assertTrue(path.is_dir())
            child.terminate()
            child.wait(timeout=3)
            scope.__exit__(None, None, None)
            self.assertFalse(path.exists())
        finally:
            if path.exists():
                import shutil
                shutil.rmtree(path)


if __name__ == "__main__":
    unittest.main()
