#!/usr/bin/env python3
"""Real loopback HTTP regressions; no browser, UI input, or compiler."""

from concurrent.futures import ThreadPoolExecutor
import http.client
import http.server
import json
import threading
import time
import unittest
import uuid

from native_extension_readiness_fixture import NativeExtensionActionFixture, handle_native_extension_action


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not handle_native_extension_action(self):
            self.send_error(404)

    def do_POST(self):
        if not handle_native_extension_action(self):
            self.send_error(404)

    def log_message(self, *_):
        pass


class NativeExtensionActionHTTPTests(unittest.TestCase):
    def setUp(self):
        self.servers = []
        self.pool = ThreadPoolExecutor(max_workers=4)
        self.server = self.start_server()

    def tearDown(self):
        for server, thread in self.servers:
            fixture = server._zacro_native_extension_action
            with fixture.lock:
                for state in fixture.states.values():
                    state["release"].set()
            server.shutdown()
            server.server_close()
            thread.join(2)
            self.assertFalse(thread.is_alive())
        self.pool.shutdown(wait=True)

    def start_server(self, *, hold_seconds=3, max_states=256):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server._zacro_native_extension_action = NativeExtensionActionFixture(
            hold_seconds=hold_seconds, state_seconds=max(4, hold_seconds + 1), max_states=max_states)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append((server, thread))
        return server

    def request(self, path, *, method="GET", server=None, headers=None, body=None):
        server = server or self.server
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=4)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.read(), dict(response.getheaders())
        finally:
            connection.close()

    @staticmethod
    def route(operation, token):
        return "/native-extension-action/" + operation + "/" + token

    def state(self, token, *, server=None):
        status, body, _ = self.request(self.route("state", token), server=server)
        self.assertEqual(status, 200)
        return json.loads(body)

    def hold(self, token, *, server=None):
        result = self.pool.submit(self.request, self.route("hold", token), server=server)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if self.state(token, server=server)["seen"]:
                return result
            time.sleep(.005)
        self.fail("The exact owned HTTP request never reached the header barrier")

    def release(self, token, *, server=None):
        return self.request(self.route("release", token), method="POST", server=server)

    def test_headers_and_document_require_the_exact_post_release(self):
        token = str(uuid.uuid4())
        held = self.hold(token)
        self.assertEqual(self.state(token), {"seen": True, "released": False})
        time.sleep(.04)
        self.assertFalse(held.done(), "No response headers may arrive before release")
        self.assertEqual(self.release(str(uuid.uuid4()))[0], 404)
        self.assertFalse(held.done())
        status, body, _ = self.release(token)
        self.assertEqual((status, json.loads(body)), (200, {"released": True}))
        status, body, headers = held.result(timeout=2)
        self.assertEqual(status, 200)
        self.assertIn(b"Owned extension action document", body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(self.state(token), {"seen": True, "released": True})

    def test_two_tokens_have_independent_barriers(self):
        first, second = str(uuid.uuid4()), str(uuid.uuid4())
        held_first, held_second = self.hold(first), self.hold(second)
        self.assertEqual(self.release(first)[0], 200)
        self.assertEqual(held_first.result(timeout=2)[0], 200)
        self.assertFalse(held_second.done())
        self.assertEqual(self.state(second), {"seen": True, "released": False})
        self.assertEqual(self.release(second)[0], 200)
        self.assertEqual(held_second.result(timeout=2)[0], 200)

    def test_same_token_is_isolated_between_actual_http_servers(self):
        other = self.start_server()
        token = str(uuid.uuid4())
        held = self.hold(token)
        self.assertEqual(self.state(token, server=other), {"seen": False, "released": False})
        self.assertEqual(self.release(token, server=other)[0], 404)
        self.assertFalse(held.done())
        self.release(token)
        self.assertEqual(held.result(timeout=2)[0], 200)

    def test_deadline_closes_the_actual_connection_without_success_headers(self):
        short = self.start_server(hold_seconds=.12)
        token = str(uuid.uuid4())
        held = self.hold(token, server=short)
        with self.assertRaises(http.client.RemoteDisconnected):
            held.result(timeout=2)
        self.assertEqual(self.state(token, server=short), {"seen": True, "released": False})
        self.assertEqual(self.release(token, server=short)[0], 410)
        self.assertEqual(self.state(token, server=short), {"seen": True, "released": False})

    def test_duplicate_hold_cannot_replace_an_admitted_request(self):
        token = str(uuid.uuid4())
        held = self.hold(token)
        self.assertEqual(self.request(self.route("hold", token))[0], 409)
        self.assertFalse(held.done())
        self.release(token)
        self.assertEqual(held.result(timeout=2)[0], 200)

    def test_capacity_failure_cannot_evict_a_pending_request(self):
        small = self.start_server(max_states=1)
        token, other = str(uuid.uuid4()), str(uuid.uuid4())
        held = self.hold(token, server=small)
        self.assertEqual(self.request(self.route("hold", other), server=small)[0], 429)
        self.assertEqual(self.state(other, server=small), {"seen": False, "released": False})
        self.assertFalse(held.done())
        self.release(token, server=small)
        self.assertEqual(held.result(timeout=2)[0], 200)

    def test_strict_uuid_method_body_and_actual_host_admission(self):
        token = str(uuid.uuid4())
        for path in [self.route("hold", "not-a-uuid"), self.route("hold", token.upper()),
                     self.route("hold", token) + "?release=true", self.route("hold", token) + "/extra"]:
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 400)
        self.assertEqual(self.request(self.route("release", token))[0], 405)
        self.assertEqual(self.request(self.route("state", token), method="POST")[0], 405)
        self.assertEqual(self.request(self.route("release", token), method="POST", body=b"x")[0], 400)
        self.assertEqual(self.request(self.route("state", token), headers={"Host": "example.com"})[0], 403)
        self.assertEqual(self.request(self.route("state", token), headers={"Host": "127.0.0.1:1"})[0], 403)
        self.assertEqual(self.state(token), {"seen": False, "released": False})

    def test_duration_and_state_capacity_are_bounded(self):
        for parameters in [{"hold_seconds": 0}, {"hold_seconds": 46}, {"hold_seconds": float("nan")},
                           {"state_seconds": float("inf")}, {"state_seconds": 1},
                           {"max_states": 0}, {"max_states": 257}]:
            with self.subTest(parameters=parameters), self.assertRaises(ValueError):
                NativeExtensionActionFixture(**parameters)


if __name__ == "__main__":
    unittest.main()
