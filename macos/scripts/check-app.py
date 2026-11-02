#!/usr/bin/env python3
"""Verify the packaged Chromium runtime, including clean application shutdown."""

import argparse
import http.server
from native_auth_fixture import handle_native_auth
from native_messaging_fixture import build_host
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import re
from urllib.parse import urlsplit


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        route = urlsplit(self.path).path
        if route.startswith("/media/"):
            self.media_fixture(route, head_only=True)
        else:
            self.send_error(405)

    def do_GET(self):
        if handle_native_auth(self):
            return
        route = urlsplit(self.path).path
        if route == "/native-delayed-commit":
            time.sleep(0.5)
        if route.startswith("/media/"):
            self.media_fixture(route)
            return
        if route.startswith("/native-network/"):
            self.network_fixture(route)
            return
        if route == "/download":
            self.stream_download()
            return
        body = b"<!doctype html><title>Zacro Native acceptance</title><p>Local engine check</p>"
        mime = "text/html; charset=utf-8"
        if self.path == "/favicon.svg":
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="6" fill="#7e5bef"/><circle cx="16" cy="16" r="8" fill="white"/></svg>'
            mime = "image/svg+xml"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def media_fixture(self, route, head_only=False):
        types = {"synthetic-h264.mp4": "video/mp4", "synthetic-aac.m4a": "audio/mp4", "synthetic.pdf": "application/pdf",
                 "acceptance.js": "text/javascript; charset=utf-8"}
        name = route.removeprefix("/media/")
        if name not in types:
            self.send_error(404)
            return
        body = (Path(__file__).resolve().parent / "fixtures" / "media" / name).read_bytes()
        total = len(body)
        start, end = 0, total - 1
        requested = None if head_only else self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested)
            if match and any(match.groups()):
                first, last = match.groups()
                if first:
                    start = int(first)
                    end = min(total - 1, int(last)) if last else total - 1
                else:
                    start = max(0, total - int(last))
            if not match or not any(match.groups()) or start >= total or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", types[name])
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()
        if not head_only:
            try:
                self.wfile.write(body[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

    def network_fixture(self, route):
        mime = "text/html; charset=utf-8"
        if route.startswith("/native-network/echo"):
            mime = "application/json; charset=utf-8"
            body = json.dumps({"path": self.path, "headers": {
                name.lower(): value for name, value in self.headers.items()
            }}).encode("utf-8")
        elif route == "/native-network/document":
            body = b'<!doctype html><title>Native network fixture</title><p id="main">Main document</p><iframe src="/native-network/frame"></iframe>'
        elif route == "/native-network/frame":
            body = b'<!doctype html><title>Native frame fixture</title><p id="frame">Child document</p>'
        elif route == "/native-network/denied":
            body = b'<!doctype html><title>Unpermitted fixture origin</title><p>No extension host permission for localhost.</p>'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def stream_download(self):
        total = 16 * 1024 * 1024
        start, end = 0, total - 1
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
            if not match:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(end, int(match[2])) if match[2] else end
            if start > end:
                self.send_error(416)
                return
        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="zacro-native-acceptance.bin"')
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"zacro-native-download-v1"')
        self.send_header("Content-Length", str(end - start + 1))
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()
        remaining = end - start + 1
        try:
            while remaining:
                chunk = min(64 * 1024, remaining)
                self.wfile.write(b"Z" * chunk)
                self.wfile.flush()
                remaining -= chunk
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Pausing/cancelling a real download closes its HTTP stream.

    def log_message(self, format, *args):
        pass


def main():
    native_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=native_root / "dist/Zacro Native.app")
    parser.add_argument("--output", type=Path, default=native_root / "dist/acceptance")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ui", action="store_true", help="Exercise native mouse and keyboard input (requires Accessibility access)")
    mode.add_argument("--integration", action="store_true", help="Exercise the full Swift application owners in an isolated profile")
    parser.add_argument("--require-extensions", action="store_true", help="Require the custom native extension protocol and real MV3 integration fixture")
    args = parser.parse_args()
    if args.require_extensions and not args.integration:
        parser.error("--require-extensions requires --integration")
    executable = args.app.resolve() / "Contents/MacOS/Zacro Native"
    if not executable.is_file():
        parser.error(f"Build the application first: {executable}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    native_host = build_host(output / "native-messaging-host") if args.integration else None
    name = "application" if args.integration else "ui" if args.ui else "engine"
    report = output / (name + ".json")
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
                ZACRO_NATIVE_EXTENSION_FIXTURE=str(native_root / "scripts/fixtures/native-extension"),
                ZACRO_REQUIRE_NATIVE_EXTENSIONS="1" if args.require_extensions else "0",
                ZACRO_RENDER_EVIDENCE="1" if args.integration else "0",
            )
            if native_host:
                env["ZACRO_NATIVE_MESSAGING_FIXTURE"] = str(native_host)
            with (output / (name + ".log")).open("w") as log:
                arguments = [str(executable), "--engine-acceptance", "-ApplePersistenceIgnoreState", "YES"]
                if args.ui:
                    arguments.append("--native-ui-review")
                elif args.integration:
                    arguments.append("--native-integration-acceptance")
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
                    code = process.wait(timeout=460 if args.integration else 45)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise SystemExit(f"FAIL: application timed out; see {output / (name + '.log')}")
            # The native report is written before quitting. A pass in that file
            # must never hide a shutdown crash or other nonzero process exit.
            if code != 0:
                raise SystemExit(f"FAIL: application exited with {code}; see {output / (name + '.log')}")
            if not report.is_file():
                raise SystemExit("FAIL: application did not produce an acceptance report")
            result = json.loads(report.read_text())
            if result.get("passed") is not True:
                raise SystemExit(f"FAIL: {result.get('error', 'engine acceptance failed')}")
            print("PASS: application ownership, retained documents, and clean shutdown" if args.integration else
                  "PASS: native mouse/keyboard controls and clean shutdown" if args.ui else
                  "PASS: four Chrome documents, profile isolation, retained state, and clean shutdown")
            print(f"Report: {report}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
