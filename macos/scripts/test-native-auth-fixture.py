#!/usr/bin/env python3
"""Exercise the native auth HTTP handler's header barrier without a browser or socket."""
import importlib.util
import io
import json
from pathlib import Path
import threading
import time
import unittest
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("auth_http", ROOT / "native_auth_fixture.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Handler:
    def __init__(self, path, disconnected=False):
        self.path = path
        self.client_address = ("127.0.0.1", 12345)
        self.status = None
        self.headers_started = threading.Event()
        self.wfile = io.BytesIO()
        if disconnected:
            class ClosedWriter:
                def write(self, _):
                    raise BrokenPipeError("owned fixture request already cancelled")
            self.wfile = ClosedWriter()

    def send_response(self, code):
        self.status = code
        self.headers_started.set()

    def send_header(self, _name, _value):
        pass

    def end_headers(self):
        pass

    def send_error(self, code, _message=None):
        self.send_response(code)


class PendingHeadersTests(unittest.TestCase):
    def setUp(self):
        self.fixture = module.NativeAuthFixture()
        self.threads = []
        self.failures = []

    def tearDown(self):
        with self.fixture.lock:
            for record in self.fixture.pending.values():
                record["release"].set()
        for thread in self.threads:
            thread.join(2)
            self.assertFalse(thread.is_alive())
        self.assertEqual(self.failures, [])

    def call(self, path):
        handler = Handler(path)
        self.assertTrue(self.fixture.handle(handler))
        return handler

    def start(self, token, disconnected=False):
        query = urlencode({"token": token, "callback": "https://" + "a" * 32 + ".chromiumapp.org/owned",
                           "mode": "pending", "hold_ms": "90000"})
        handler = Handler("/native-auth/pending?" + query, disconnected)
        def run():
            try:
                self.fixture.handle(handler)
            except BaseException as error:
                self.failures.append(repr(error))
        thread = threading.Thread(target=run, daemon=True)
        self.threads.append(thread)
        thread.start()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            state = self.call("/native-auth/pending-status?token=" + token)
            if state.status == 200:
                return handler, thread, json.loads(state.wfile.getvalue())
            time.sleep(.005)
        self.fail("Owned pending request did not enter HTTP handler")

    def test_headers_require_exact_release_and_have_separate_provider_release(self):
        handler, thread, before = self.start("first")
        self.assertEqual(before, {"entered": True, "released": False, "completed": False, "expired": False})
        self.assertFalse(handler.headers_started.is_set())
        self.assertEqual(self.call("/native-auth/pending-release?token=foreign").status, 404)
        self.assertFalse(handler.headers_started.is_set())
        self.assertEqual(self.call("/native-auth/pending-release?token=first").status, 200)
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(handler.status, 200)
        self.assertIn(b"Synthetic authorization page", handler.wfile.getvalue())
        result = json.loads(self.call("/native-auth/pending-status?token=first").wfile.getvalue())
        self.assertEqual(result, {"entered": True, "released": True, "completed": True, "expired": False})
        self.assertEqual(json.loads(self.call("/native-auth/status?token=first").wfile.getvalue()), {"released": False})
        self.assertEqual(json.loads(self.call("/native-auth/release?token=first").wfile.getvalue()), {"released": True})

    def test_cancelled_owned_connection_still_finishes_server_barrier(self):
        handler, thread, _ = self.start("cancelled", disconnected=True)
        self.assertFalse(handler.headers_started.is_set())
        self.call("/native-auth/pending-release?token=cancelled")
        thread.join(2)
        state = json.loads(self.call("/native-auth/pending-status?token=cancelled").wfile.getvalue())
        self.assertTrue(state["completed"])
        self.assertFalse(state["expired"])

    def test_duplicate_token_does_not_replace_original_waiter(self):
        original, _, _ = self.start("duplicate")
        duplicate = self.call(original.path)
        self.assertEqual(duplicate.status, 409)
        self.assertFalse(original.headers_started.is_set())

    def test_invalid_callback_never_enters_pending_registry(self):
        handler = self.call("/native-auth/pending?token=bad&callback=https://example.com")
        self.assertEqual(handler.status, 400)
        self.assertEqual(self.fixture.pending, {})


if __name__ == "__main__":
    unittest.main()
