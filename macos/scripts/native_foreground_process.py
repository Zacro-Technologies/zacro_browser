"""Launch an owned acceptance app in front without losing its real exit status.

LaunchServices, rather than this process, parents the app. macOS kqueue's
NOTE_EXITSTATUS permits observing its actual wait status for a same-user PID.
The `open -W` exit code is never substituted for the application's exit code.
This module performs no desktop input and signals only a verified new process.
"""

import os
from pathlib import Path
import select
import signal
import shutil
import subprocess
import tempfile
import time


NOTE_EXITSTATUS = 0x04000000  # sys/event.h; valid when allowed to signal the PID.
TEST_ENVIRONMENT = (
    "ZACRO_NATIVE_DATA", "ZACRO_ACCEPTANCE_OUTPUT", "ZACRO_NATIVE_SMOKE_URL",
    "ZACRO_NATIVE_EXTENSION_FIXTURE", "ZACRO_REQUIRE_NATIVE_EXTENSIONS",
    "ZACRO_NATIVE_ACCEPTANCE_SUITE", "ZACRO_RENDER_EVIDENCE",
    "ZACRO_NATIVE_MESSAGING_FIXTURE", "MallocNanoZone",
    "ZACRO_NATIVE_SEARCH_FIXTURE", "ZACRO_NATIVE_AWAIT_FOREGROUND",
    "ZACRO_NATIVE_PERSISTED_EXTENSION_NONCE",
)


class ExitStatusMonitor:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None
        self.raw_status = None
        self.queue = select.kqueue()
        try:
            self.queue.control([select.kevent(
                pid, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT | NOTE_EXITSTATUS,
            )], 0, 0)
        except BaseException:
            self.queue.close()
            raise

    def poll(self):
        if self.returncode is None:
            events = self.queue.control(None, 1, 0)
            if events:
                event = events[0]
                if event.flags & select.KQ_EV_ERROR:
                    raise OSError(event.data, "Cannot observe the owned application's exit")
                if event.ident != self.pid or not event.fflags & select.KQ_NOTE_EXIT:
                    raise RuntimeError("Unexpected process lifecycle notification")
                self.raw_status = int(event.data)
                self.returncode = os.waitstatus_to_exitcode(self.raw_status)
        return self.returncode

    def wait(self, timeout=None):
        deadline = None if timeout is None else time.monotonic() + timeout
        while self.poll() is None:
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(["owned-native-app", str(self.pid)], timeout)
            time.sleep(0.02)
        return self.returncode

    def close(self):
        self.queue.close()


def process_field(pid, field):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", field + "="],
        capture_output=True, text=True, timeout=5,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def matching_processes(executable):
    result = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True, timeout=5)
    matches = set()
    for row in result.splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and os.path.realpath(fields[1]) == str(executable):
            matches.add(int(fields[0]))
    return matches


class ForegroundProcess:
    def __init__(self, executable, arguments, env, log_path):
        self.executable = Path(executable).resolve()
        self.app = self.executable.parents[2]
        if self.executable.parent != self.app / "Contents/MacOS" or self.app.suffix != ".app":
            raise ValueError("Expected an application bundle's exact main executable")
        self.pid = None
        self.started = None
        self.monitor = None
        self.launcher_forced = False
        self.launcher_returncode = None
        previous = matching_processes(self.executable)
        command = ["/usr/bin/open", "-n", "-W",
                   "--stdout", str(log_path.with_suffix(".stdout.log")),
                   "--stderr", str(log_path)]
        for key in TEST_ENVIRONMENT:
            if key in env:
                command.extend(["--env", key + "=" + env[key]])
        command.extend([str(self.app), "--args", *arguments])
        with log_path.with_suffix(".launcher.log").open("w") as log:
            self.launcher = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                added = matching_processes(self.executable) - previous
                if len(added) > 1:
                    raise RuntimeError("More than one new application matched the owned launch")
                if added:
                    self.pid = added.pop()
                    self.started = process_field(self.pid, "lstart")
                    if not self.started:
                        raise RuntimeError("The application exited before ownership was established")
                    self.monitor = ExitStatusMonitor(self.pid)
                    if self.poll() is None and not self.owns_live_process():
                        raise RuntimeError("Application identity changed during exit-monitor registration")
                    break
                if self.launcher.poll() is not None:
                    raise RuntimeError("LaunchServices returned before the exact application was observed")
                time.sleep(0.02)
            else:
                raise RuntimeError("The exact foreground application did not appear")
        except BaseException:
            if self.monitor and self.poll() is None and self.owns_live_process():
                self.terminate()
                try:
                    self.monitor.wait(3)
                except subprocess.TimeoutExpired:
                    self.kill()
                    self.monitor.wait(3)
            self.reap_launcher()
            if self.monitor:
                self.monitor.close()
            raise

    def owns_live_process(self):
        command = process_field(self.pid, "comm") if self.pid else None
        return bool(command and os.path.realpath(command) == str(self.executable)
                    and process_field(self.pid, "lstart") == self.started)

    def poll(self):
        return self.monitor.poll() if self.monitor else None

    def wait(self, timeout=None):
        code = self.monitor.wait(timeout)
        self.reap_launcher()
        return code

    def send_signal(self, chosen_signal):
        if self.poll() is not None:
            return
        if not self.owns_live_process():
            raise RuntimeError("Refusing to signal an application whose identity is no longer verified")
        os.kill(self.pid, chosen_signal)

    def terminate(self):
        self.send_signal(signal.SIGTERM)

    def kill(self):
        self.send_signal(signal.SIGKILL)

    def reap_launcher(self):
        try:
            self.launcher_returncode = self.launcher.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.launcher_forced = True
            self.launcher.terminate()  # Our direct `open` child, never its process group.
            self.launcher_returncode = self.launcher.wait(timeout=5)

    def receipt(self):
        return {"method": "LaunchServices with same-user kqueue exit-status observation",
                "pid": self.pid, "executable": str(self.executable), "started": self.started,
                "appExitCode": self.poll(), "rawWaitStatus": self.monitor.raw_status,
                "openExitCode": self.launcher_returncode, "openWasTerminated": self.launcher_forced,
                "desktopInputUsed": False}

    def close(self):
        self.monitor.close()


class AcceptanceProfile:
    """Preserve diagnostic data if an application's exit cannot be verified."""
    def __init__(self, directory):
        self.directory = tempfile.mkdtemp(prefix="zacro-native-acceptance-", dir=directory)
        self.process = None
        self.launch_attempted = False

    def __enter__(self):
        return self.directory

    def __exit__(self, *_error):
        try:
            exited = self.process is not None and self.process.poll() is not None
        except OSError:
            exited = False
        if exited or not self.launch_attempted:
            shutil.rmtree(self.directory)
        else:
            print("Preserved diagnostic profile because application exit was not verified: " + self.directory)
