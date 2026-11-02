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
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c":
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
    run([sys.executable, str(HERE / "apply_adapter.py"), "--cef-root", str(cef)], source, environment)
    run([sys.executable, str(HERE / "apply_storage_adapter.py"), "--chromium-root", str(source)], source, environment)
    run([sys.executable, str(HERE / "apply_bookmark_adapter.py"), "--chromium-root", str(source)], source, environment)
    run([sys.executable, str(HERE / "apply_sidepanel_adapter.py"), "--chromium-root", str(source)], source, environment)
    run([sys.executable, str(HERE / "apply_popup_anchor.py"), "--chromium-root", str(source)], source, environment)
    run([sys.executable, str(HERE / "apply_topology_adapter.py"), "--chromium-root", str(source)], source, environment)
    run([sys.executable, str(HERE / "apply_tab_reservation.py"), "--chromium-root", str(source)], source, environment)
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
    run(["autoninja", "-C", "out/Release_GN_arm64", *targets, f"-j{max(1, min(6, args.jobs))}"], source, environment)
    if args.adapter_only:
        print("Native adapter compiled. Full framework and packaged acceptance remain required.", flush=True)
        return
    framework = source / "out/Release_GN_arm64/Chromium Embedded Framework.framework"
    binary = framework / "Chromium Embedded Framework"
    if not binary.is_file():
        raise SystemExit("The framework build completed without the expected native binary.")
    record = {
        "chromium": version, "cefCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cef, text=True).strip(),
        "adapterVersion": 1, "framework": str(framework), "sha256": hashlib.file_digest(binary.open("rb"), "sha256").hexdigest(),
        "validation": "Built; packaged runtime and extension acceptance still required.",
    }
    (source / "out/Release_GN_arm64/zacro-runtime-build.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2), flush=True)


if __name__ == "__main__":
    main()
