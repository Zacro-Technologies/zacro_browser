"""Loopback-only synthetic extension authorization pages; no accounts or tokens."""
import json
import re
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit


class NativeAuthFixture:
    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}

    def handle(self, handler):
        request = urlsplit(handler.path)
        if not request.path.startswith("/native-auth/"):
            return False
        if handler.client_address[0] not in ("127.0.0.1", "::1"):
            handler.send_error(403)
            return True
        query = parse_qs(request.query)
        token = query.get("token", [""])[0]
        callback = query.get("callback", [""])[0]
        mode = query.get("mode", ["load"])[0]
        with self.lock:
            now = time.monotonic()
            self.sessions = {key: value for key, value in self.sessions.items() if now - value[0] < 120}
        if request.path in ("/native-auth/redirect", "/native-auth/document"):
            try:
                destination = urlsplit(callback)
                valid = (destination.scheme == "https" and destination.port is None
                         and destination.username is None and destination.password is None
                         and re.fullmatch(r"[a-p]{32}\.chromiumapp\.org", destination.hostname or "")
                         and all(32 < ord(char) < 127 for char in callback))
            except ValueError:
                valid = False
            if not valid:
                handler.send_error(400, "Expected this synthetic extension's callback URL")
                return True
        if request.path == "/native-auth/redirect":
            handler.send_response(302)
            handler.send_header("Location", callback)
            handler.send_header("Cache-Control", "no-store")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return True
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,96}", token):
            handler.send_error(400, "Invalid fixture identity")
            return True
        if request.path == "/native-auth/document":
            if mode not in ("load", "async", "hold", "timeout"):
                handler.send_error(400, "Invalid fixture mode")
                return True
            hold_ms = query.get("hold_ms", ["20000"])[0]
            if (not re.fullmatch(r"[0-9]{5}", hold_ms)
                    or not 20000 <= int(hold_ms) <= 90000
                    or ("hold_ms" in query and mode != "hold")):
                handler.send_error(400, "Invalid bounded fixture hold duration")
                return True
            hold_ms = int(hold_ms)
            with self.lock:
                if len(self.sessions) >= 256 and token not in self.sessions:
                    handler.send_error(429)
                    return True
                self.sessions[token] = (time.monotonic(), False)
            encoded_callback = json.dumps(callback).replace("<", "\\u003c")
            status_url = json.dumps("/native-auth/status?" + urlencode({"token": token}))
            script = ""
            if mode == "async":
                script = f"setTimeout(() => location.replace({encoded_callback}), 300);"
            elif mode == "hold":
                script = f"""
const callback = {encoded_callback};
const interval = setInterval(async () => {{
  try {{
    const response = await fetch({status_url}, {{cache:'no-store'}});
    if (response.ok && (await response.json()).released) {{
      clearInterval(interval); location.replace(callback);
    }}
  }} catch {{}}
}}, 50);
// Failure cleanup is finite even if an acceptance process disappears. The
// altered callback makes a timeout distinguishable from successful release.
setTimeout(() => {{
  clearInterval(interval);
  const failure = new URL(callback); failure.searchParams.set('fixture_timeout','1');
  location.replace(failure.href);
}}, {hold_ms});
"""
            body = (f"<!doctype html><meta charset=utf-8><title>Zacro auth fixture {token}</title>"
                    "<h1>Synthetic authorization page</h1><p>No account or credentials are used.</p>"
                    f"<script>{script}</script>").encode()
            self.reply(handler, body, "text/html; charset=utf-8")
            return True
        if request.path in ("/native-auth/status", "/native-auth/release"):
            with self.lock:
                entry = self.sessions.get(token)
                if entry is None:
                    handler.send_error(404)
                    return True
                if request.path.endswith("/release"):
                    entry = (entry[0], True)
                    self.sessions[token] = entry
            self.reply(handler, json.dumps({"released": entry[1]}).encode(), "application/json")
            return True
        handler.send_error(404)
        return True

    @staticmethod
    def reply(handler, body, content_type):
        handler.send_response(200)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        handler.wfile.write(body)


_server_lock = threading.Lock()


def handle_native_auth(handler):
    """Return true when handled. Call at the start of Fixture.do_GET()."""
    if not urlsplit(handler.path).path.startswith("/native-auth/"):
        return False
    with _server_lock:
        fixture = getattr(handler.server, "_zacro_native_auth", None)
        if fixture is None:
            fixture = NativeAuthFixture()
            handler.server._zacro_native_auth = fixture
    return fixture.handle(handler)
