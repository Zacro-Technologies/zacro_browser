#!/usr/bin/env python3
"""Verify the packaged Chromium runtime, including clean application shutdown."""

import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Zacro Native acceptance</title><p>Local engine check</p>"
        mime = "text/html; charset=utf-8"
        if self.path == "/favicon.svg":
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="6" fill="#7e5bef"/><circle cx="16" cy="16" r="8" fill="white"/></svg>'
            mime = "image/svg+xml"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    native_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=native_root / "dist/Zacro Native.app")
    parser.add_argument("--output", type=Path, default=native_root / "dist/acceptance")
    parser.add_argument("--ui", action="store_true", help="Exercise native mouse and keyboard input (requires Accessibility access)")
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Zacro Native"
    if not executable.is_file():
        parser.error(f"Build the application first: {executable}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = output / ("ui.json" if args.ui else "engine.json")
    report.unlink(missing_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        # The application's test gate requires a fresh, direct child of the
        # system temporary directory. Real profiles keep normal Keychain storage.
        with tempfile.TemporaryDirectory(
            prefix="zacro-native-acceptance-", dir=os.environ["TMPDIR"]
        ) as profile:
            env = dict(
                os.environ,
                ZACRO_NATIVE_DATA=profile,
                ZACRO_ACCEPTANCE_OUTPUT=str(report),
                ZACRO_NATIVE_SMOKE_URL=f"http://127.0.0.1:{server.server_port}/",
                MallocNanoZone="0",
            )
            with (output / ("ui.log" if args.ui else "engine.log")).open("w") as log:
                arguments = [str(executable), "--engine-acceptance", "-ApplePersistenceIgnoreState", "YES"]
                if args.ui:
                    arguments.append("--native-ui-review")
                process = subprocess.Popen(
                    arguments,
                    env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                )
                try:
                    if args.ui:
                        driver = subprocess.run(
                            ["swift", str(native_root / "scripts/check-ui.swift"), str(process.pid),
                             env["ZACRO_NATIVE_SMOKE_URL"], profile, str(report)],
                            timeout=90, stdout=log, stderr=subprocess.STDOUT,
                        )
                        if driver.returncode != 0:
                            os.killpg(process.pid, signal.SIGTERM)
                            process.wait(timeout=5)
                            raise SystemExit(f"FAIL: native UI input check; see {output / 'ui.log'}")
                    code = process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise SystemExit(f"FAIL: application timed out; see {output / 'engine.log'}")
            # The native report is written before quitting. A pass in that file
            # must never hide a shutdown crash or other nonzero process exit.
            if code != 0:
                raise SystemExit(f"FAIL: application exited with {code}; see {output / 'engine.log'}")
            if not report.is_file():
                raise SystemExit("FAIL: application did not produce an acceptance report")
            result = json.loads(report.read_text())
            if result.get("passed") is not True:
                raise SystemExit(f"FAIL: {result.get('error', 'engine acceptance failed')}")
            print("PASS: native mouse/keyboard controls and clean shutdown" if args.ui else
                  "PASS: four Chrome documents, profile isolation, retained state, and clean shutdown")
            print(f"Report: {report}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
