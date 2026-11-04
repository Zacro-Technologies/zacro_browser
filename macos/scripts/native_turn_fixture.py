"""A genuine, authenticated TURN relay confined to an owned loopback test run.

Requires coturn (or ZACRO_TURNSERVER pointing to its locally built executable).
This never starts a service, loads a global configuration, or changes browser
privacy flags. The readiness probe performs a real authenticated allocation and
releases it before the browser uses the relay.
"""

import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
import zlib


COOKIE = 0x2112A442
REALM = "zacro-acceptance.invalid"


def attribute(kind, value):
    return struct.pack("!HH", kind, len(value)) + value + bytes((-len(value)) % 4)


def message(kind, transaction, attributes, key=None):
    body = b"".join(attributes)
    if key is not None:
        header = struct.pack("!HHI12s", kind, len(body) + 24, COOKIE, transaction)
        body += attribute(0x0008, hmac.new(key, header + body, hashlib.sha1).digest())
    header = struct.pack("!HHI12s", kind, len(body) + 8, COOKIE, transaction)
    fingerprint = zlib.crc32(header + body) ^ 0x5354554E
    return header + body + attribute(0x8028, struct.pack("!I", fingerprint))


def response(packet, transaction, key=None):
    if len(packet) < 20:
        raise RuntimeError("The owned TURN server returned a short STUN response")
    kind, length, cookie, actual = struct.unpack("!HHI12s", packet[:20])
    if cookie != COOKIE or actual != transaction or length % 4 or length != len(packet) - 20:
        raise RuntimeError("The owned TURN response did not match its exact transaction")
    attributes = {}
    offset = 20
    verified = key is None
    while offset < len(packet):
        if offset + 4 > len(packet):
            raise RuntimeError("Truncated TURN response attribute")
        name, size = struct.unpack("!HH", packet[offset:offset + 4])
        end = offset + 4 + size
        if end > len(packet) or name in attributes:
            raise RuntimeError("Malformed or duplicate TURN response attribute")
        value = packet[offset + 4:end]
        attributes[name] = value
        if name == 0x0008 and key is not None:
            signed = struct.pack("!HHI12s", kind, end - 20, COOKIE, transaction) + packet[20:offset]
            verified = size == 20 and hmac.compare_digest(value, hmac.new(key, signed, hashlib.sha1).digest())
        if name == 0x8028:
            if size != 4 or end != len(packet) or struct.unpack("!I", value)[0] != zlib.crc32(packet[:offset]) ^ 0x5354554E:
                raise RuntimeError("The owned TURN response has an invalid fingerprint")
        offset = end + (-size) % 4
    if not verified:
        raise RuntimeError("The owned TURN response failed authenticated integrity verification")
    return kind, attributes


def relay_address(value):
    if len(value) != 8 or value[:2] != b"\0\1":
        raise RuntimeError("The owned relay did not allocate an IPv4 address")
    port = struct.unpack("!H", value[2:4])[0] ^ (COOKIE >> 16)
    address = ipaddress.IPv4Address(struct.unpack("!I", value[4:])[0] ^ COOKIE)
    return str(address), port


class LoopbackTURN:
    def __init__(self, output, executable=None):
        self.output = Path(output).resolve()
        selected = executable or os.environ.get("ZACRO_TURNSERVER") or shutil.which("turnserver")
        if not selected:
            raise RuntimeError("Media acceptance requires coturn; set ZACRO_TURNSERVER to its turnserver executable")
        self.executable = Path(selected).expanduser().resolve(strict=True)
        if not self.executable.is_file() or not os.access(self.executable, os.X_OK):
            raise RuntimeError("The configured TURN fixture executable is not executable")
        self.process = None
        self.temporary = None
        self.log = None
        self.configuration = None
        self.receipt = {"executable": str(self.executable), "loopbackOnly": True,
                        "authenticatedAllocateVerified": False, "probeAllocationReleased": False,
                        "networkListenersVerified": False, "forcedTermination": False}

    def start(self):
        if self.process is not None:
            raise RuntimeError("The owned TURN fixture was already started")
        self.output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="zacro-turn-", dir=self.output)
        directory = Path(self.temporary.name)
        username, password, cli_password = (secrets.token_hex(24) for _ in range(3))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        first_relay = 40000 + secrets.randbelow(20000 - 32)
        config = "\n".join([
            "listening-ip=127.0.0.1", "relay-ip=127.0.0.1", f"listening-port={port}",
            f"min-port={first_relay}", f"max-port={first_relay + 31}",
            "no-tcp", "no-tls", "no-tcp-relay", "relay-threads=1", "fingerprint", "lt-cred-mech",
            f"realm={REALM}", f"user={username}:{password}", f"cli-password={cli_password}",
            "allow-loopback-peers", "no-multicast-peers",
            "denied-peer-ip=0.0.0.0-255.255.255.255", "allowed-peer-ip=127.0.0.1",
            "user-quota=8", "total-quota=8", "max-allocate-lifetime=120",
            f"pidfile={directory / 'turn.pid'}", "log-file=stdout", "simple-log", ""
        ])
        path = directory / "turnserver.conf"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(config)
        self.log = (self.output / "turn-server.log").open("w")
        try:
            # Only the explicit, owned configuration is read. No daemon mode.
            self.process = subprocess.Popen([str(self.executable), "-c", str(path)],
                                            cwd=directory, stdout=self.log, stderr=subprocess.STDOUT)
            self.receipt.update(pid=self.process.pid, controlPort=port,
                                executableSha256=hashlib.sha256(self.executable.read_bytes()).hexdigest())
            self._probe(port, username, password, first_relay, first_relay + 31)
            self._verify_listeners()
            if self.process.poll() is not None:
                raise RuntimeError("The owned TURN fixture exited after its readiness probe")
            self.configuration = {"iceTransportPolicy": "relay", "iceServers": [{
                "urls": f"turn:127.0.0.1:{port}?transport=udp", "username": username, "credential": password
            }]}
            self._write_receipt()
            return self
        except BaseException:
            try:
                self.close()
            except Exception:
                pass  # Preserve the original readiness failure.
            raise

    def _probe(self, port, username, password, first_relay, last_relay):
        destination = ("127.0.0.1", port)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.bind(("127.0.0.1", 0))
            client.settimeout(0.15)

            def exchange(kind, attributes, key=None):
                transaction = secrets.token_bytes(12)
                request = message(kind, transaction, attributes, key)
                for _ in range(3):
                    if self.process.poll() is not None:
                        raise RuntimeError("The owned TURN fixture exited before readiness; see turn-server.log")
                    client.sendto(request, destination)
                    try:
                        packet, source = client.recvfrom(65535)
                    except socket.timeout:
                        continue
                    if source != destination:
                        raise RuntimeError("Readiness received a packet outside the exact owned TURN endpoint")
                    return response(packet, transaction, key)
                raise TimeoutError("The owned TURN endpoint did not answer its STUN transaction")

            end = time.monotonic() + 5
            while True:
                try:
                    kind, _ = exchange(0x0001, [])
                    if kind != 0x0101:
                        raise RuntimeError("The owned endpoint did not answer a genuine STUN binding request")
                    break
                except TimeoutError:
                    if time.monotonic() >= end:
                        raise RuntimeError("The owned TURN fixture did not become ready within five seconds") from None
            kind, challenge = exchange(0x0003, [attribute(0x0019, b"\x11\0\0\0")])
            error = challenge.get(0x0009, b"")
            if kind != 0x0113 or len(error) < 4 or error[2:4] != b"\4\1" or challenge.get(0x0014) != REALM.encode() or not challenge.get(0x0015):
                raise RuntimeError("The TURN fixture did not require its exact long-term credential challenge")
            self.receipt["authenticationChallengeVerified"] = True
            key = hashlib.md5(f"{username}:{REALM}:{password}".encode()).digest()
            authentication = [attribute(0x0006, username.encode()), attribute(0x0014, REALM.encode()),
                              attribute(0x0015, challenge[0x0015])]
            kind, allocation = exchange(0x0003, authentication + [attribute(0x0019, b"\x11\0\0\0"),
                                          attribute(0x000D, struct.pack("!I", 60))], key)
            if kind != 0x0103 or 0x0016 not in allocation:
                raise RuntimeError("Authenticated TURN allocation failed")
            address, relay_port = relay_address(allocation[0x0016])
            if address != "127.0.0.1" or not first_relay <= relay_port <= last_relay:
                raise RuntimeError("The actual TURN allocation escaped the owned loopback relay range")
            self.receipt["authenticatedAllocateVerified"] = True
            kind, refreshed = exchange(0x0004, authentication + [attribute(0x000D, struct.pack("!I", 0))], key)
            if kind != 0x0104 or refreshed.get(0x000D) != bytes(4):
                raise RuntimeError("The TURN probe allocation did not accept genuine zero-lifetime removal")
            self.receipt["probeAllocationReleased"] = True

    def _verify_listeners(self, stage="startup"):
        lsof = shutil.which("lsof") or ("/usr/sbin/lsof" if Path("/usr/sbin/lsof").is_file() else None)
        if lsof is None:
            raise RuntimeError("TURN acceptance requires lsof to verify the owned process has only loopback network sockets")
        result = subprocess.run([lsof, "-nP", "-a", "-p", str(self.process.pid), "-i", "-Fn"],
                                capture_output=True, text=True, timeout=5, check=True)
        names = [line[1:] for line in result.stdout.splitlines() if line.startswith("n")]
        if not names or any(re.fullmatch(r"127\.0\.0\.1:\d+(?:->127\.0\.0\.1:\d+)?", name) is None for name in names):
            raise RuntimeError("The owned TURN process exposed a network socket outside IPv4 loopback")
        self.receipt["networkListenersVerified"] = True
        self.receipt[stage + "NetworkEndpoints"] = names

    def _write_receipt(self):
        (self.output / "turn-server.json").write_text(json.dumps(self.receipt, indent=2) + "\n")

    def close(self):
        self.configuration = None
        problem = None
        if self.process is not None:
            if self.process.poll() is None:
                if self.receipt["networkListenersVerified"]:
                    try:
                        self._verify_listeners(stage="shutdown")
                    except Exception as error:
                        self.receipt["networkListenersVerified"] = False
                        problem = error
                self.receipt["terminationRequested"] = True
                self.process.terminate()  # Only our direct child, never a process group.
            elif not self.receipt.get("terminationRequested"):
                problem = RuntimeError("The owned TURN server exited before its requested shutdown")
            try:
                # Coturn joins periodic workers on shutdown (up to five
                # seconds even when idle). This is fixture teardown only.
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.receipt["forcedTermination"] = True
                self.process.kill()
                self.process.wait(timeout=5)
                problem = RuntimeError("The owned TURN server required forced termination")
            self.receipt["exitCode"] = self.process.returncode
            if self.process.returncode not in (0, -signal.SIGTERM):
                problem = problem or RuntimeError("The owned TURN server exited unexpectedly")
            self._write_receipt()
        if self.log is not None:
            self.log.close(); self.log = None
        if self.temporary is not None:
            self.temporary.cleanup(); self.temporary = None
        if problem is not None:
            raise problem
