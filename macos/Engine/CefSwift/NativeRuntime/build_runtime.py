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


def restart_if_driver_changed(launch_digest):
    if digest(HERE / "build_runtime.py") != launch_digest:
        print("Build driver changed; restarting it before producing build provenance.", flush=True)
        arguments = sys.argv[1:]
        if "--skip-generation" not in arguments:
            arguments = arguments + ["--skip-generation"]
        os.execv(sys.executable, [sys.executable, str(HERE / "build_runtime.py"), *arguments])


def write_receipt(path, record):
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def run(command, cwd, environment):
    print("Running:", " ".join(map(str, command)), flush=True)
    process = subprocess.Popen(command, cwd=cwd, env=environment, start_new_session=True)
    try:
        while process.poll() is None:
            if shutil.disk_usage(cwd).free < 15 * GIB:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=30)
                raise SystemExit("Build stopped with less than 15 GiB free; existing source and output were preserved.")
            time.sleep(2)
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
        raise
    if process.returncode:
        raise SystemExit(process.returncode)


def main():
    launch_digest = digest(HERE / "build_runtime.py")
    parser = argparse.ArgumentParser()
    parser.add_argument("--download-dir", required=True, type=pathlib.Path)
    parser.add_argument("--jobs", type=int, default=4)
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
    while True:
        restart_if_driver_changed(launch_digest)
        applied = apply_inputs(source, environment)
        prepared = build_inputs(source)
        if prepared["nativeInputs"] != applied:
            continue
        run(["autoninja", "-C", "out/Release_GN_arm64", *targets, f"-j{max(1, min(8, args.jobs))}"], source, environment)
        restart_if_driver_changed(launch_digest)
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
        restart_if_driver_changed(launch_digest)
        if build_inputs(source) != prepared:
            print("Native inputs changed while hashing; rebuilding before certification.", flush=True)
            apply_inputs(source, environment)
            continue
        write_receipt(receipt, record)
        print("Built framework receipt:", receipt, flush=True)
        return


if __name__ == "__main__":
    main()
