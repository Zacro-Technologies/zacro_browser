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
import sys
import tempfile
import threading
import time
import re
from native_foreground_process import AcceptanceProfile, ForegroundProcess
from native_turn_fixture import LoopbackTURN
from urllib.parse import parse_qs, urlsplit


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if urlsplit(self.path).path != "/native-extension-host/document":
            self.send_error(404)
            return
        self.extension_host_document("POST")

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
        if route == "/native-extension-host/document":
            self.extension_host_document("GET")
            return
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
        body = b'<!doctype html><title>Zacro Native acceptance</title><link rel="icon" type="image/svg+xml" href="/favicon.svg"><p>Local engine check</p>'
        mime = "text/html; charset=utf-8"
        if route == "/native-history-form":
            # Exercise exact form-state bytes and document lifetime without
            # making the multi-megabyte value a separate text-layout/AX stress test.
            body = b'<!doctype html><title>Native retained form</title><form><textarea id="retained" name="retained" style="display:none"></textarea></form>'
        if route == "/native-peek-first-inline":
            # This parser-inline listener runs before the body exists. A
            # post-load Peek injection loses capture priority to it; the actual
            # owned document-start session must register first.
            body = b'''<!doctype html><html><head><title>Native first-inline Peek</title>
<script>
window.__peekFirstInlineCalls = 0;
window.addEventListener('click', event => {
  if (event.isTrusted && (event.shiftKey || event.altKey)) {
    window.__peekFirstInlineCalls++;
    event.preventDefault(); event.stopImmediatePropagation();
  }
}, true);
</script></head><body style="margin:0;min-height:300px;background:white">
<input id="peekSourceDraft" value="first-inline retained draft" style="position:absolute;left:24px;top:14px;width:220px;height:24px">
<a id="peekFixtureLink" href="/native-peek-link-target" style="position:absolute;left:24px;top:64px;display:block;width:180px;height:44px;line-height:44px">Open preview</a>
</body></html>'''
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

    def extension_host_document(self, method):
        token = parse_qs(urlsplit(self.path).query).get("token", [""])[0]
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", token, re.IGNORECASE):
            self.send_error(400)
            return
        posted = ""
        if method == "POST":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 32768:
                    self.send_error(413)
                    return
                self.connection.settimeout(5)
                payload = self.rfile.read(length)
                if len(payload) != length:
                    self.send_error(400)
                    return
                posted = payload.decode("utf-8")
            except (ValueError, UnicodeError, TimeoutError):
                self.send_error(400)
                return
        receipt = json.dumps({"method": method, "body": posted, "token": token}, ensure_ascii=True)
        # Form content is data, including literal script closers. Never turn
        # the echoed body into an additional executable fixture script.
        receipt = receipt.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
        body = ("<!doctype html><meta charset=utf-8><title>Native extension host child</title>"
                "<p>Owned extension host document</p><script>"
                "globalThis.nativeExtensionHostReceipt=" + receipt + ";"
                "nativeExtensionHostReceipt.hasOpener=!!window.opener;"
                "if(window.opener)window.opener.postMessage({zacroExtensionHostToken:"
                "nativeExtensionHostReceipt.token},'*');</script>").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def media_fixture(self, route, head_only=False):
        if route == "/media/ice-config.json":
            configuration = getattr(self.server, "turn_configuration", None)
            if configuration is None:
                self.send_error(503, "The owned TURN fixture is unavailable")
                return
            expected_host = f"127.0.0.1:{self.server.server_port}"
            if self.headers.get("Host") != expected_host or self.headers.get("Origin", f"http://{expected_host}") != f"http://{expected_host}":
                self.send_error(403)
                return
            body = json.dumps(configuration).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head_only:
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return
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


class AcceptanceReportError(ValueError):
    """The report cannot certify the requested acceptance scope."""


def validate_acceptance_report(result, *, integration=False, suite="all",
                               require_extensions=False, accessibility=False):
    if not isinstance(result, dict):
        raise AcceptanceReportError("the acceptance report is not an object")
    if result.get("passed") is not True:
        raise AcceptanceReportError(result.get("error", "engine acceptance failed"))
    if integration:
        # A legacy report without a suite is not evidence that the current full
        # runner executed. Focused success must remain explicitly scoped too.
        if result.get("suite") != suite:
            raise AcceptanceReportError("the executable did not run the requested application suite")
        expected_full = suite == "all"
        if result.get("fullApplicationSuitePassed") is not expected_full:
            raise AcceptanceReportError("the report does not certify the requested full or focused application scope")
        checks = result.get("checks")
        if not isinstance(checks, dict) or not checks:
            raise AcceptanceReportError("the application report contains no valid checks")
        if any(not isinstance(name, str) or not name or passed is not True
               for name, passed in checks.items()):
            raise AcceptanceReportError("the application report contains a failed or nonboolean check")
    if require_extensions:
        if not integration:
            raise AcceptanceReportError("the requested real extension fixture requires application integration")
        if (result.get("nativeExtensionProtocol") is not True
                or result.get("extensionFixturePassed") is not True):
            raise AcceptanceReportError("the requested real extension fixture did not pass")
    if accessibility:
        if result.get("suite") != "accessibility" or result.get("fullEngineSuitePassed") is not False:
            raise AcceptanceReportError("the executable did not run the separate scoped AX causal fixture")


def main():
    native_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=native_root / "dist/Zacro Native.app")
    parser.add_argument("--output", type=Path, default=native_root / "dist/acceptance")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ui", action="store_true", help="Exercise native mouse and keyboard input (requires Accessibility access)")
    mode.add_argument("--integration", action="store_true", help="Exercise the full Swift application owners in an isolated profile")
    mode.add_argument("--accessibility", action="store_true", help="Run the separate passive scoped AX causal check without the global renderer AX fallback")
    parser.add_argument("--foreground", action="store_true",
                        help="Launch through macOS LaunchServices and verify the actual app exit status with kqueue")
    parser.add_argument("--await-foreground", action="store_true",
                        help="Wait for actual foreground ownership before integration fixtures (activate the owned window with Computer input)")
    parser.add_argument("--suite", choices=("all", "extensions", "extension-actions", "extension-services", "extension-admission", "extension-search", "extension-management", "extension-uninstall", "extension-ui-owner", "extension-host", "history-mirror", "history-spa", "history-veto", "history-publication", "popup-close", "popup-adoption", "download-retirement", "windows", "hosted-selection", "resize", "peek", "navigation", "capture", "media", "sidebar", "space-input-construction", "space-swipe", "space-swipe-prelude", "application-reopening", "focus-family", "recovery", "interface", "interface-prelude"), default="all",
                        help="Run one application fixture group; focused reports do not establish full-app acceptance")
    parser.add_argument("--require-extensions", action="store_true", help="Require the custom native extension protocol and real MV3 integration fixture")
    args = parser.parse_args()
    if args.foreground and args.ui:
        parser.error("Use Computer input for foreground desktop UI checks; --foreground supports engine/application/AX fixtures")
    if args.await_foreground and not (args.foreground and args.integration):
        parser.error("--await-foreground requires --foreground --integration")
    if args.require_extensions and not args.integration:
        parser.error("--require-extensions requires --integration")
    if args.suite != "all" and not args.integration:
        parser.error("--suite requires --integration")
    if args.require_extensions and args.suite not in ("all", "extensions"):
        parser.error("--require-extensions requires the all or extensions suite")
    executable = args.app.resolve() / "Contents/MacOS/Zacro Native"
    if not executable.is_file():
        parser.error(f"Build the application first: {executable}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    native_host = build_host(output / "native-messaging-host") if args.integration else None
    name = "application" if args.integration else "ui" if args.ui else "accessibility" if args.accessibility else "engine"
    report = output / (name + ".json")
    report.unlink(missing_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    turn = None
    try:
        if args.integration and args.suite in ("all", "media"):
            turn = LoopbackTURN(output)
            turn.start()
            server.turn_configuration = turn.configuration
        thread.start()
        # The application's test gate requires a fresh, direct child of the
        # system temporary directory. Real profiles keep normal Keychain storage.
        profile_scope = AcceptanceProfile(directory=os.environ["TMPDIR"])
        with profile_scope as profile:
            env = dict(
                os.environ,
                ZACRO_NATIVE_DATA=profile,
                ZACRO_ACCEPTANCE_OUTPUT=str(report),
                ZACRO_NATIVE_SMOKE_URL=f"http://127.0.0.1:{server.server_port}/",
                MallocNanoZone="0",
                ZACRO_NATIVE_EXTENSION_FIXTURE=str(native_root / "scripts/fixtures/native-extension"),
                ZACRO_REQUIRE_NATIVE_EXTENSIONS="1" if args.require_extensions else "0",
                ZACRO_NATIVE_ACCEPTANCE_SUITE=args.suite,
                ZACRO_NATIVE_AWAIT_FOREGROUND="1" if args.await_foreground else "0",
                ZACRO_RENDER_EVIDENCE="1" if args.integration else "0",
                ZACRO_NATIVE_SEARCH_FIXTURE="1" if args.integration and args.suite in ("all", "extensions", "extension-search") else "0",
            )
            if native_host:
                env["ZACRO_NATIVE_MESSAGING_FIXTURE"] = str(native_host)
            with (output / (name + ".log")).open("w") as log:
                arguments = [str(executable), "--engine-acceptance", "-ApplePersistenceIgnoreState", "YES"]
                if args.ui:
                    arguments.append("--native-ui-review")
                elif args.integration:
                    arguments.append("--native-integration-acceptance")
                elif args.accessibility:
                    arguments.append("--native-accessibility-acceptance")
                profile_scope.launch_attempted = True
                if args.foreground:
                    process = ForegroundProcess(executable, arguments[1:], env, output / (name + ".log"))
                else:
                    process = subprocess.Popen(arguments, env=env, stdout=log,
                                               stderr=subprocess.STDOUT, start_new_session=True)
                profile_scope.process = process
                def stop_owned(hard=False):
                    if isinstance(process, ForegroundProcess):
                        process.kill() if hard else process.terminate()
                    else:
                        os.killpg(process.pid, signal.SIGKILL if hard else signal.SIGTERM)
                try:
                    if args.ui:
                        driver = subprocess.run(
                            ["swift", str(native_root / "scripts/check-ui.swift"), str(process.pid),
                             env["ZACRO_NATIVE_SMOKE_URL"], profile, str(report)],
                            timeout=90, stdout=log, stderr=subprocess.STDOUT,
                        )
                        if driver.returncode != 0:
                            stop_owned()
                            process.wait(timeout=5)
                            raise SystemExit(f"FAIL: native UI input check; see {output / 'ui.log'}")
                    driver_timeout = (940 if args.suite == "all" else 460) if args.integration else 45
                    code = process.wait(timeout=driver_timeout)
                except subprocess.TimeoutExpired:
                    stop_owned()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        stop_owned(hard=True)
                        process.wait()
                    raise SystemExit(f"FAIL: application timed out; see {output / (name + '.log')}")
                finally:
                    if isinstance(process, ForegroundProcess):
                        try:
                            if process.poll() is None:
                                stop_owned()
                                try:
                                    process.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    stop_owned(hard=True)
                                    process.wait(timeout=5)
                        finally:
                            receipt = process.receipt()
                            if args.await_foreground:
                                # This launcher never sends input. Computer activation
                                # has its own receipt; do not report that external input
                                # was absent merely because the launcher did not send it.
                                receipt["launcherDesktopInputUsed"] = receipt.pop("desktopInputUsed")
                                receipt["externalComputerActivationRequested"] = True
                            (output / (name + "-launch.json")).write_text(json.dumps(receipt, indent=2))
                            if process.poll() is not None:
                                process.close()
            # The native report is written before quitting. A pass in that file
            # must never hide a shutdown crash or other nonzero process exit.
            if code != 0:
                raise SystemExit(f"FAIL: application exited with {code}; see {output / (name + '.log')}")
            if not report.is_file():
                raise SystemExit("FAIL: application did not produce an acceptance report")
            result = json.loads(report.read_text())
            try:
                validate_acceptance_report(result, integration=args.integration, suite=args.suite,
                                          require_extensions=args.require_extensions,
                                          accessibility=args.accessibility)
            except AcceptanceReportError as error:
                raise SystemExit(f"FAIL: {error}") from None
            if args.accessibility:
                print("PASS: scoped native AX positive/control retention and clean shutdown (no desktop input or full engine suite)")
                print(f"Report: {report}")
                return
            if args.integration and args.suite != "all":
                print(f"PASS: focused {args.suite} fixture and clean shutdown (full application suite not run)")
                return
            print("PASS: application ownership, retained documents, and clean shutdown" if args.integration else
                  "PASS: native mouse/keyboard controls and clean shutdown" if args.ui else
                  "PASS: four Chrome documents, profile isolation, retained state, and clean shutdown")
            print(f"Report: {report}")
    finally:
        failing = sys.exc_info()[0] is not None
        if thread.is_alive():
            server.shutdown()
            thread.join()
        server.server_close()
        if turn is not None:
            try:
                turn.close()
            except Exception as error:
                if not failing:
                    raise
                print(f"Owned TURN fixture cleanup also failed: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
