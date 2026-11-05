"""Prepare a two-launch owned extension UI check; never launches or inspects browsers.

The app alone creates the first-launch marker. Actual install, native action
clicks, normal Quit and process-exit observation belong to the UI driver.
Neither existing browser profiles nor extension worker inspectors are used.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile
import time
from urllib.parse import urlsplit

MARKER = ".zacro-persisted-extension-owner.json"
RESUMED = ".zacro-persisted-extension-resumed"
PREFIX = "zacro-native-acceptance-"
NONCE_ENV = "ZACRO_NATIVE_PERSISTED_EXTENSION_NONCE"


def system_temporary_directory():
    # Public Darwin _CS_DARWIN_USER_TEMP_DIR from unistd.h, independent of TMPDIR.
    return Path(os.confstr(65537)).resolve(strict=True)


def private_json(path, *, require_unlocked=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
                or not 0 < info.st_size <= 32768):
            raise ValueError("Expected a private regular ownership file")
        if require_unlocked:
            # Inspect and lock the same descriptor, so a replaced pathname
            # cannot substitute an unlocked file for a still-running owner.
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with os.fdopen(descriptor, "r") as stream:
            descriptor = -1
            return json.load(stream)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def write_private(path, value, *, replace=False):
    path = Path(path)
    temporary = path.with_name(path.name + "." + secrets.token_hex(8) + ".tmp")
    target = temporary if replace else path
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def owned_directory(path):
    raw = Path(path)
    info = raw.lstat()
    resolved = raw.resolve(strict=True)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700
            or resolved.parent != system_temporary_directory()
            or not resolved.name.startswith(PREFIX) or len(resolved.name) <= len(PREFIX)):
        raise ValueError("Expected the exact owned private direct system-temp profile")
    return resolved, info


def prepare(app, output):
    executable = Path(app).resolve(strict=True) / "Contents/MacOS/Zacro Native"
    if not executable.is_file():
        raise ValueError("The selected app has no Zacro Native executable")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    profile = Path(tempfile.mkdtemp(prefix=PREFIX, dir=system_temporary_directory()))
    session = {"version": 1, "createdAt": time.time(), "profile": str(profile),
               "uid": os.getuid(), "nonce": secrets.token_hex(32),
               "executable": str(executable),
               "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}
    target = output / "persisted-extension-session.json"
    try:
        write_private(target, session)
    except BaseException:
        profile.rmdir()
        raise
    return target


def load_session(path):
    session = private_json(path)
    if (session.get("version") != 1 or session.get("uid") != os.getuid()
            or not re.fullmatch("[0-9a-f]{64}", session.get("nonce", ""))
            or not 0 <= time.time() - session.get("createdAt", 0) < 6 * 3600):
        raise ValueError("Invalid or expired persisted-extension session")
    profile, info = owned_directory(session["profile"])
    executable = Path(session["executable"])
    if hashlib.sha256(executable.read_bytes()).hexdigest() != session["executableSHA256"]:
        raise ValueError("The immutable executable changed between launches")
    return session, profile, info


def validate_marker(session, profile, info):
    marker = private_json(profile / MARKER, require_unlocked=True)
    marker_directory = Path(marker.get("directory", ""))
    if not marker_directory.is_absolute():
        raise ValueError("The app-created marker requires its absolute owned directory")
    # Foundation may retain /var while pathlib resolves the system's /var ->
    # /private/var alias. Admit only the same existing private owned directory,
    # not a second path merely sharing a spelling or copied marker contents.
    resolved_marker_directory, marker_directory_info = owned_directory(marker_directory)
    if (marker.get("version") != 1 or resolved_marker_directory != profile
            or marker_directory_info.st_dev != info.st_dev or marker_directory_info.st_ino != info.st_ino
            or marker.get("device") != info.st_dev or marker.get("inode") != info.st_ino
            or marker.get("uid") != os.getuid()
            or marker.get("nonceSHA256") != hashlib.sha256(session["nonce"].encode()).hexdigest()
            or not 0 <= time.time() - marker.get("createdAt", 0) < 6 * 3600):
        raise ValueError("The app-created marker does not match this session")


def launch_spec(session_path, phase, fixture_url):
    if phase not in ("fresh", "resume"):
        raise ValueError("Expected exactly a fresh or resume phase")
    session, profile, info = load_session(session_path)
    url = urlsplit(fixture_url)
    if url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port or url.username or url.password:
        raise ValueError("The fixture must be a real ephemeral loopback HTTP endpoint")
    arguments = ["--engine-acceptance", "--native-ui-review", "--native-persisted-extension-acceptance",
                 "-ApplePersistenceIgnoreState", "YES"]
    if phase == "fresh":
        if list(profile.iterdir()) or session.get("freshExit") or session.get("freshSpecIssued"):
            raise ValueError("The first launch requires a fresh empty profile and unused session")
    else:
        if not session.get("freshExit") or session.get("resumeSpecIssued") or (profile / RESUMED).exists():
            raise ValueError("Resume requires a verified normal first exit and unused second launch")
        validate_marker(session, profile, info)
        arguments.append("--native-persisted-extension-resume")
    session[phase + "SpecIssued"] = time.time()
    write_private(session_path, session, replace=True)
    result = {"phase": phase, "executable": session["executable"], "arguments": arguments,
              "environment": {"ZACRO_NATIVE_DATA": str(profile), "ZACRO_NATIVE_SMOKE_URL": fixture_url,
                              NONCE_ENV: session["nonce"]},
              "workerInspectorLaunchedByDriver": False, "desktopInputLaunchedByDriver": False}
    target = Path(session_path).parent / ("persisted-extension-" + phase + "-launch.json")
    write_private(target, result)
    return target


def record_exit(session_path, phase, receipt_path):
    if phase not in ("fresh", "resume"):
        raise ValueError("Expected exactly a fresh or resume phase")
    session, profile, info = load_session(session_path)
    if not session.get(phase + "SpecIssued") or session.get(phase + "Exit"):
        raise ValueError("Exit receipt has no corresponding unused launch")
    receipt_bytes = Path(receipt_path).read_bytes()
    receipt = json.loads(receipt_bytes)
    if (receipt.get("method") != "LaunchServices with same-user kqueue exit-status observation"
            or receipt.get("appExitCode") != 0 or receipt.get("rawWaitStatus") != 0
            or receipt.get("openExitCode") != 0 or receipt.get("openWasTerminated") is not False
            or receipt.get("executable") != session["executable"]
            or not isinstance(receipt.get("pid"), int) or receipt["pid"] <= 0):
        raise ValueError("A real normal app/raw/LaunchServices exit is required")
    try:
        started = time.mktime(time.strptime(receipt["started"], "%a %b %d %H:%M:%S %Y"))
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise ValueError("The observed process requires its actual launch identity") from error
    # ps lstart has whole-second precision; the two-second allowance covers
    # that rounding, not an old receipt from an unrelated earlier test run.
    if not session[phase + "SpecIssued"] - 2 <= started <= time.time() + 2:
        raise ValueError("The exit receipt predates this exact launch specification")
    if phase == "resume" and (not session.get("freshExit")
            or receipt["pid"] == session["freshExit"]["pid"]):
        raise ValueError("Cold restart must have a different verified process identity")
    validate_marker(session, profile, info)
    if phase == "resume":
        consumed = (profile / RESUMED).lstat()
        if (not stat.S_ISREG(consumed.st_mode) or consumed.st_uid != os.getuid()
                or stat.S_IMODE(consumed.st_mode) != 0o600 or consumed.st_nlink != 1):
            raise ValueError("The second app did not consume its exact one-use resume lease")
    session[phase + "Exit"] = {"pid": receipt["pid"], "recordedAt": time.time(),
                              "receipt": str(Path(receipt_path).resolve()),
                              "receiptSHA256": hashlib.sha256(receipt_bytes).hexdigest()}
    write_private(session_path, session, replace=True)
    return {"phase": phase, "normalExitVerified": True,
            "coldResumeLifecycleComplete": bool(session.get("freshExit") and session.get("resumeExit")),
            "extensionUIBehaviorVerified": False, "workerInspectorLaunchedByDriver": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("prepare")
    create.add_argument("--app", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    spec = commands.add_parser("launch-spec")
    spec.add_argument("--session", required=True, type=Path)
    spec.add_argument("--phase", required=True, choices=("fresh", "resume"))
    spec.add_argument("--fixture-url", required=True)
    record = commands.add_parser("record-exit")
    record.add_argument("--session", required=True, type=Path)
    record.add_argument("--phase", required=True, choices=("fresh", "resume"))
    record.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        print(prepare(args.app, args.output))
    elif args.command == "launch-spec":
        print(launch_spec(args.session, args.phase, args.fixture_url))
    else:
        print(json.dumps(record_exit(args.session, args.phase, args.receipt), sort_keys=True))


if __name__ == "__main__":
    main()
