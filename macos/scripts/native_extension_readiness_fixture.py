"""Bounded, server-local HTTP header barrier for native extension action checks."""

import ipaddress
import json
import math
import re
import socket
import threading
import time
from urllib.parse import urlsplit


_PREFIX = "/native-extension-action/"
_ROUTE = re.compile(
    r"/native-extension-action/(hold|state|release)/"
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\Z"
)


class NativeExtensionActionFixture:
    def __init__(self, *, hold_seconds=45, state_seconds=120, max_states=256):
        if (not math.isfinite(hold_seconds) or not 0 < hold_seconds <= 45
                or not math.isfinite(state_seconds) or state_seconds <= hold_seconds
                or type(max_states) is not int or not 0 < max_states <= 256):
            raise ValueError("Expected a finite bounded extension action fixture")
        self.hold_seconds = hold_seconds
        self.state_seconds = state_seconds
        self.max_states = max_states
        self.lock = threading.Lock()
        self.states = {}

    def handle(self, handler):
        request = urlsplit(handler.path)
        if not request.path.startswith(_PREFIX):
            return False
        if not self._owns_loopback_request(handler):
            handler.send_error(403, "Expected the actual loopback fixture server")
            return True
        match = _ROUTE.fullmatch(request.path)
        if match is None or request.query or request.fragment:
            handler.send_error(400, "Expected an exact action route and lowercase UUID")
            return True
        operation, token = match.groups()
        if handler.command != ("POST" if operation == "release" else "GET"):
            handler.send_error(405)
            return True
        if operation == "release" and (
            handler.headers.get("Transfer-Encoding") is not None
            or handler.headers.get("Content-Length", "0") != "0"
        ):
            handler.send_error(400, "The exact release request has no body")
            return True

        with self.lock:
            now = time.monotonic()
            self.states = {
                key: state for key, state in self.states.items()
                if state["waiting"] or now - state["created"] < self.state_seconds
            }
            state = self.states.get(token)
            if operation == "hold":
                if state is not None:
                    handler.send_error(409, "This exact request has already been admitted")
                    return True
                if len(self.states) >= self.max_states:
                    handler.send_error(429)
                    return True
                state = {"created": now, "release": threading.Event(), "waiting": True}
                self.states[token] = state
            elif operation == "release":
                if state is None:
                    handler.send_error(404, "No exact pending action request")
                    return True
                if not state["waiting"] and not state["release"].is_set():
                    handler.send_error(410, "The exact request expired without release")
                    return True
                state["release"].set()
            result = {"seen": state is not None, "released": bool(state and state["release"].is_set())}

        if operation == "state":
            self._reply(handler, json.dumps(result).encode(), "application/json")
        elif operation == "release":
            self._reply(handler, b'{"released":true}', "application/json")
        else:
            try:
                if not state["release"].wait(self.hold_seconds):
                    # No success response, redirect, or normal document may
                    # escape this deadline without the exact explicit release.
                    self._close_without_headers(handler)
                    return True
                body = (b"<!doctype html><meta charset=utf-8>"
                        b"<title>Native extension action released</title>"
                        b"<p>Owned extension action document</p>")
                try:
                    self._reply(handler, body, "text/html; charset=utf-8")
                except (BrokenPipeError, ConnectionResetError):
                    # Normal cancellation can retire the exact request first.
                    pass
            finally:
                with self.lock:
                    state["waiting"] = False
        return True

    @staticmethod
    def _owns_loopback_request(handler):
        try:
            remote = ipaddress.ip_address(handler.client_address[0])
            bound_host, bound_port = handler.server.server_address[:2]
            bound = ipaddress.ip_address(bound_host)
            local_host, local_port = handler.connection.getsockname()[:2]
            local = ipaddress.ip_address(local_host)
            host = urlsplit("//" + handler.headers.get("Host", ""))
            return (remote.is_loopback and bound.is_loopback and local == bound
                    and local_port == bound_port and host.hostname is not None
                    and ipaddress.ip_address(host.hostname) == bound and host.port == bound_port
                    and host.username is None and host.password is None
                    and not host.path and not host.query and not host.fragment)
        except (ValueError, TypeError, AttributeError, OSError):
            return False

    @staticmethod
    def _close_without_headers(handler):
        handler.close_connection = True
        try:
            handler.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    @staticmethod
    def _reply(handler, body, content_type):
        handler.send_response(200)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        handler.wfile.write(body)


_server_lock = threading.Lock()


def handle_native_extension_action(handler):
    """Delegate at the beginning of the loopback Fixture GET and POST handlers."""
    if not urlsplit(handler.path).path.startswith(_PREFIX):
        return False
    with _server_lock:
        fixture = getattr(handler.server, "_zacro_native_extension_action", None)
        if fixture is None:
            fixture = NativeExtensionActionFixture()
            handler.server._zacro_native_extension_action = fixture
    return fixture.handle(handler)
