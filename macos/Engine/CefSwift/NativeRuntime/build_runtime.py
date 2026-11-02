#!/usr/bin/env python3
"""Build the pinned arm64 CEF framework with Zacro's native adapter.

Run after the official automate-git source preparation has completed. No user
data or unrelated build directories are removed. Stop safely before disk fills.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
GIB = 1024 ** 3
CHROMIUM_COMMIT = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_COMMIT = "4fa4ab516dac"
INPUT_SUFFIXES = {".py", ".inc", ".in", ".patch"}


class ResourcePressure(RuntimeError):
    pass


def process_snapshot():
    """Record identities, never command arguments or unrelated process data."""
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,rss=,pcpu=,lstart=,comm="], text=True)
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 10)
        if len(fields) != 11:
            continue
        pid, parent, group, rss = map(int, fields[:4])
        try:
            session = os.getsid(pid)
        except ProcessLookupError:
            continue
        result[pid] = {"parent": parent, "group": group, "rss": rss * 1024,
                       "session": session, "cpu": float(fields[4]), "identity": tuple(fields[5:10]),
                       "compiler": pathlib.Path(fields[10]).name in {"clang", "clang++", "rustc"}}
    return result


def descendants(snapshot, root):
    owned = {root} if root in snapshot else set()
    while True:
        added = {pid for pid, entry in snapshot.items() if entry["parent"] in owned}
        if added.issubset(owned):
            return {pid: snapshot[pid] for pid in owned}
        owned.update(added)


def stop_owned_process(process):
    """Stop and reap our build, including compilers with separate process groups."""
    tracked = descendants(process_snapshot(), process.pid)
    sessions = {process.pid} | {entry["session"] for entry in tracked.values()}

    def refresh():
        current = process_snapshot()
        # Siso gives compilers distinct process groups in our private session.
        # Session membership remains authoritative even after the parent exits.
        # Also retain separately-created sessions of observed descendants.
        while True:
            roots = {pid for pid, entry in tracked.items()
                     if current.get(pid, {}).get("identity") == entry["identity"]}
            added = {pid: entry for pid, entry in current.items()
                     if entry["session"] in sessions or entry["parent"] in roots}
            changed = any(tracked.get(pid) != entry for pid, entry in added.items())
            tracked.update(added)
            sessions.update(entry["session"] for entry in added.values())
            if not changed:
                return {pid: entry for pid, entry in current.items()
                        if tracked.get(pid, {}).get("identity") == entry["identity"]}

    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10
    for sig in (signal.SIGTERM, signal.SIGKILL):
        signaled = {(pid, entry["identity"]) for pid, entry in tracked.items()
                    if sig == signal.SIGTERM and entry["group"] == process.pid}
        while time.monotonic() < deadline:
            process.poll()  # Reap the child before checking its descendants.
            live = refresh()
            if not live:
                process.wait()
                return
            for pid, entry in live.items():
                identity = (pid, entry["identity"])
                if identity not in signaled:
                    try:
                        os.kill(pid, sig)
                    except ProcessLookupError:
                        pass
                    signaled.add(identity)
            time.sleep(0.1)
        deadline = time.monotonic() + 5
    raise RuntimeError("The owned build did not fully terminate; refusing to launch another build.")


def system_resources(snapshot, root):
    pressure = int(subprocess.check_output(
        ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True).strip())
    swap = subprocess.check_output(["sysctl", "-n", "vm.swapusage"], text=True)
    match = re.search(r"used\s*=\s*([\d.]+)([KMG])", swap)
    if not match:
        raise ValueError("Missing swap telemetry")
    swap_bytes = float(match[1]) * {"K": 1024, "M": 1024 ** 2, "G": GIB}[match[2]]
    pages = subprocess.check_output(["vm_stat"], text=True)
    page_size = re.search(r"page size of (\d+) bytes", pages)
    counts = [re.search(r"^Pages " + key + r":\s*(\d+)\.", pages, re.M)
              for key in ("free", "inactive", "speculative")]
    if not page_size or not all(counts):
        raise ValueError("Missing available-memory telemetry")
    owned = descendants(snapshot, root)
    compilers = [entry for entry in owned.values() if entry["compiler"]]
    return {"pressure": pressure, "swapBytes": swap_bytes,
            "availableBytes": sum(int(value[1]) for value in counts) * int(page_size[1]),
            "compilerRSSBytes": sum(entry["rss"] for entry in compilers),
            "compilerCount": len(compilers),
            "buildRSSBytes": sum(entry["rss"] for entry in owned.values()),
            "compilerCPUPercent": sum(entry["cpu"] for entry in compilers)}


def pressure_reason(sample, baseline_swap, jobs):
    accelerated = jobs > 8
    if sample["pressure"] not in (1, 2, 4):
        return "unknown memory pressure state"
    if sample["pressure"] >= (2 if accelerated else 4):
        return "system memory pressure"
    if sample["availableBytes"] < (2 if accelerated else 1) * GIB:
        return "low available memory"
    if sample["compilerRSSBytes"] > 9 * GIB or sample["buildRSSBytes"] > 10 * GIB:
        return "owned compiler/build RSS limit"
    if sample["swapBytes"] - baseline_swap > (256 if accelerated else 512) * 1024 ** 2:
        return "new swap growth"
    return None


class BuildResourceGuard:
    def __init__(self, jobs, path):
        self.jobs = jobs
        self.path = path
        self.baseline_swap = None
        self.started = time.monotonic()

    def check(self, process):
        try:
            sample = system_resources(process_snapshot(), process.pid)
            if self.baseline_swap is None:
                self.baseline_swap = sample["swapBytes"]
            reason = pressure_reason(sample, self.baseline_swap, self.jobs)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            sample, reason = {}, "resource telemetry unavailable: " + type(error).__name__
        record = {"time": time.time(), "elapsed": time.monotonic() - self.started,
                  "jobs": self.jobs, **sample, "stopReason": reason}
        with self.path.open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        if reason:
            raise ResourcePressure(reason)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def native_inputs():
    return {path.name: digest(path) for path in sorted(HERE.iterdir())
            if path.is_file() and path.suffix in INPUT_SUFFIXES}


def source_revision(path):
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip()


def build_inputs(source):
    revision, cef_revision = source_revision(source), source_revision(source / "cef")
    if revision != CHROMIUM_COMMIT or not cef_revision.startswith(CEF_COMMIT):
        raise SystemExit("The Chromium or CEF source revision changed; refusing to certify this build.")
    return {"chromiumCommit": revision, "cefCommit": cef_revision,
            "nativeInputs": native_inputs(),
            "gnArgsSha256": digest(source / "out/Release_GN_arm64/args.gn")}


def framework_manifest(framework):
    files, symlinks = {}, {}
    for path in sorted(framework.rglob("*")):
        relative = path.relative_to(framework)
        if "_CodeSignature" in relative.parts:
            continue
        if path.is_symlink():
            if not path.exists() or not path.resolve().is_relative_to(framework):
                raise SystemExit("Framework contains a broken or external symbolic link: " + str(relative))
            symlinks[relative.as_posix()] = os.readlink(path)
        elif path.is_file():
            files[relative.as_posix()] = digest(path)
        elif not path.is_dir():
            raise SystemExit("Framework contains an unsupported special file: " + str(relative))
    return {"files": files, "symlinks": symlinks}


def apply_inputs(source, environment):
    # Patch generators also emit reviewable .patch files. Capture only after
    # their output is stable, so the receipt covers exactly what was applied.
    for _ in range(8):
        before = native_inputs()
        run([sys.executable, str(HERE / "apply_adapter.py"), "--cef-root", str(source / "cef")], source, environment)
        for name in ["storage_adapter", "bookmark_adapter", "sidepanel_adapter", "popup_anchor", "topology_adapter", "tab_reservation", "native_messaging_adapter"]:
            run([sys.executable, str(HERE / ("apply_" + name + ".py")), "--chromium-root", str(source)], source, environment)
        if before == native_inputs():
            return before
    raise SystemExit("Native inputs kept changing during preparation; retry after edits finish.")


def restart_if_driver_changed(launch_digest, jobs=None, guarded=False):
    if digest(HERE / "build_runtime.py") != launch_digest:
        print("Build driver changed; restarting it before producing build provenance.", flush=True)
        arguments = sys.argv[1:]
        if "--skip-generation" not in arguments:
            arguments = arguments + ["--skip-generation"]
        if jobs is not None:
            arguments = list(arguments)
            if "--jobs" in arguments:
                arguments[arguments.index("--jobs") + 1] = str(jobs)
            else:
                arguments += ["--jobs", str(jobs)]
            if guarded and "--guard-resources" not in arguments:
                arguments.append("--guard-resources")
        os.execv(sys.executable, [sys.executable, str(HERE / "build_runtime.py"), *arguments])


def write_receipt(path, record):
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def run(command, cwd, environment, resource_guard=None):
    print("Running:", " ".join(map(str, command)), flush=True)
    process = subprocess.Popen(command, cwd=cwd, env=environment, start_new_session=True)
    try:
        while process.poll() is None:
            if shutil.disk_usage(cwd).free < 15 * GIB:
                raise SystemExit("Build stopped with less than 15 GiB free; existing source and output were preserved.")
            if resource_guard:
                resource_guard.check(process)
            time.sleep(2)
    except BaseException:
        stop_owned_process(process)
        raise
    if process.returncode:
        raise SystemExit(process.returncode)


def main():
    launch_digest = digest(HERE / "build_runtime.py")
    parser = argparse.ArgumentParser()
    parser.add_argument("--download-dir", required=True, type=pathlib.Path)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--resource-log", type=pathlib.Path,
                        help="JSONL resource evidence for the opt-in guarded 9/10-job build")
    parser.add_argument("--guard-resources", action="store_true",
                        help="Keep resource monitoring enabled when resuming at eight or fewer jobs")
    parser.add_argument("--generate-only", action="store_true")
    parser.add_argument("--skip-generation", action="store_true", help="Resume the already generated pinned Release build")
    parser.add_argument("--adapter-only", action="store_true", help="Compile the changed native adapter and its generated prerequisites")
    args = parser.parse_args()
    source = args.download_dir.resolve() / "chromium" / "src"
    cef = source / "cef"
    if not (cef / "BUILD.gn").is_file():
        raise SystemExit("Complete the pinned automate-git source preparation first.")
    revision = source_revision(source)
    if revision != CHROMIUM_COMMIT:
        raise SystemExit(f"Expected pinned Chromium 156.0.8078.48, found {revision}.")
    version = "156.0.8078.48"
    minimum_free = 25 if args.skip_generation else 65
    if shutil.disk_usage(source).free < minimum_free * GIB:
        raise SystemExit(f"This {'resumed' if args.skip_generation else 'new'} build needs at least {minimum_free} GiB free; nothing was removed.")
    environment = os.environ.copy()
    environment["PATH"] = str(args.download_dir.resolve() / "depot_tools") + os.pathsep + environment["PATH"]
    environment["GN_OUT_CONFIGS"] = "Release_GN_arm64"
    environment["GN_DEFINES"] = " ".join([
        'target_cpu="arm64"', "is_debug=false", "is_component_build=false",
        "is_official_build=false", "symbol_level=0", "blink_symbol_level=0",
        "v8_symbol_level=0", "chrome_pgo_phase=0",
        "proprietary_codecs=true", 'ffmpeg_branding="Chrome"',
    ])
    apply_inputs(source, environment)
    if not args.skip_generation:
        run([sys.executable, str(cef / "tools" / "gclient_hook.py")], cef, environment)
    elif not (source / "out/Release_GN_arm64/build.ninja").is_file():
        raise SystemExit("Generate the pinned Release build before using --skip-generation.")
    else:
        # A resumed build may predate the explicit H.264/AAC parity settings.
        # Preserve every other generated CEF option and let Ninja regenerate
        # only the graph/objects affected by these required media features.
        argument_file = source / "out/Release_GN_arm64/args.gn"
        previous = argument_file.read_text()
        lines = [line for line in previous.splitlines()
                 if line.split("=", 1)[0].strip() not in {"proprietary_codecs", "ffmpeg_branding"}]
        current = "\n".join(lines + ["proprietary_codecs=true", 'ffmpeg_branding="Chrome"']) + "\n"
        if previous != current:
            argument_file.write_text(current)
    if args.generate_only:
        return
    targets = [
        "obj/cef/libcef_static/devtools_controller.o",
        "obj/components/value_store/value_store/leveldb_value_store.o",
        "obj/extensions/browser/api/storage/storage/settings_storage_quota_enforcer.o",
        "obj/extensions/browser/api/storage/storage/storage_frontend.o",
        "obj/chrome/browser/extensions/extensions/syncable_settings_storage.o",
    ] if args.adapter_only else ["cef_framework", "cef_sandbox"]
    framework = source / "out/Release_GN_arm64/Chromium Embedded Framework.framework"
    binary = framework / "Chromium Embedded Framework"
    receipt = source / "out/Release_GN_arm64/zacro-runtime-build.json"
    # A failed/partial rebuild must never leave an apparently current receipt.
    if receipt.exists():
        receipt.unlink()
    effective_jobs = max(1, min(10, args.jobs))
    guarded = effective_jobs > 8 or args.guard_resources
    resource_log = (args.resource_log or source / "out/Release_GN_arm64/zacro-build-resources.jsonl").resolve()
    if guarded:
        resource_log.parent.mkdir(parents=True, exist_ok=True)
    while True:
        restart_if_driver_changed(launch_digest, effective_jobs, guarded)
        applied = apply_inputs(source, environment)
        prepared = build_inputs(source)
        if prepared["nativeInputs"] != applied:
            continue
        try:
            command = ["autoninja", "-C", "out/Release_GN_arm64", *targets, f"-j{effective_jobs}"]
            if guarded:
                run(command, source, environment, resource_guard=BuildResourceGuard(effective_jobs, resource_log))
            else:
                run(command, source, environment)
        except ResourcePressure as error:
            if effective_jobs <= 8:
                raise SystemExit("The guarded fallback also exceeded its resource limit: " + str(error))
            print(f"Resource guard stopped and reaped the {effective_jobs}-job build ({error}); resuming at 8 jobs.", flush=True)
            effective_jobs = 8
            continue
        restart_if_driver_changed(launch_digest, effective_jobs, guarded)
        if build_inputs(source) != prepared:
            print("Native inputs changed while compiling; applying and rebuilding before certification.", flush=True)
            apply_inputs(source, environment)
            continue
        if args.adapter_only:
            print("Native adapter compiled. Full framework and packaged acceptance remain required.", flush=True)
            return
        if not binary.is_file():
            raise SystemExit("The framework build completed without the expected native binary.")
        record = {**prepared, **framework_manifest(framework), "chromium": version,
                  "adapterVersion": 1, "framework": str(framework), "sha256": digest(binary),
                  "validation": "Built; packaged runtime and extension acceptance still required."}
        restart_if_driver_changed(launch_digest, effective_jobs, guarded)
        if build_inputs(source) != prepared:
            print("Native inputs changed while hashing; rebuilding before certification.", flush=True)
            apply_inputs(source, environment)
            continue
        write_receipt(receipt, record)
        print("Built framework receipt:", receipt, flush=True)
        return


if __name__ == "__main__":
    main()
