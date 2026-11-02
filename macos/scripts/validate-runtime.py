#!/usr/bin/env python3
"""Verify the exact custom framework and native inputs before app assembly.

Build provenance is not a substitute for packaged runtime acceptance. This
preflight prevents an old or stock framework from silently becoming the app.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

NATIVE_ROOT = pathlib.Path(__file__).resolve().parents[1]
INPUT_ROOT = NATIVE_ROOT / "Engine/CefSwift/NativeRuntime"
CEF_COMMIT = "4fa4ab516dac"
CHROMIUM_COMMIT = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
HEX = re.compile(r"[0-9a-f]{64}\Z")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def native_inputs(root=INPUT_ROOT):
    return {path.name: digest(path) for path in sorted(root.iterdir())
            if path.is_file() and path.suffix in {".py", ".inc", ".in", ".patch"}}


def validate(record_path, input_root=INPUT_ROOT, check_architecture=True):
    if not record_path.is_file():
        raise ValueError("Custom Chromium build receipt is missing. Build NativeRuntime/build_runtime.py "
                         "and pass --runtime-build with its zacro-runtime-build.json; "
                         "--stock-runtime is available only for diagnostic builds.")
    record = json.loads(record_path.read_text())
    pin = json.loads((NATIVE_ROOT / "Engine/CefSwift/CEF_VERSION.json").read_text())
    if (record.get("chromium") != pin["chromium"]
            or record.get("chromiumCommit") != CHROMIUM_COMMIT
            or not str(record.get("cefCommit", "")).startswith(CEF_COMMIT)):
        raise ValueError("Runtime revisions do not match Zacro's pinned Chromium and CEF sources.")
    if record.get("nativeInputs") != native_inputs(input_root):
        raise ValueError("Native runtime sources changed after this build. Rebuild Chromium before packaging.")
    if not HEX.fullmatch(str(record.get("gnArgsSha256", ""))):
        raise ValueError("The runtime receipt has no generated build-argument provenance.")
    framework = pathlib.Path(record.get("framework", "")).resolve()
    if framework.name != "Chromium Embedded Framework.framework" or not framework.is_dir():
        raise ValueError("The recorded framework directory is missing or invalid.")
    arguments = framework.parent / "args.gn"
    if not arguments.is_file() or digest(arguments) != record["gnArgsSha256"]:
        raise ValueError("Generated Chromium build arguments changed or are missing.")
    binary = framework / "Chromium Embedded Framework"
    if not binary.is_file() or digest(binary) != record.get("sha256"):
        raise ValueError("The framework binary changed after the recorded build.")
    files = record.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("The runtime receipt has no framework resource manifest.")
    actual, symlinks = {}, {}
    for path in sorted(framework.rglob("*")):
        relative = path.relative_to(framework)
        if "_CodeSignature" in relative.parts:
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(framework) or not path.exists():
                raise ValueError("A framework link is broken or points outside the recorded build.")
            symlinks[relative.as_posix()] = os.readlink(path)
        if path.is_file() and not path.is_symlink():
            actual[relative.as_posix()] = digest(path)
    if actual != files:
        raise ValueError("The framework resources do not match the build receipt.")
    if symlinks != record.get("symlinks", {}):
        raise ValueError("The framework links do not match the build receipt.")
    if not any(name.endswith("libcef_sandbox.dylib") for name in files):
        raise ValueError("The custom framework is missing its native sandbox library.")
    if not any(name.endswith("icudtl.dat") for name in files):
        raise ValueError("The custom framework is missing Chromium's ICU data.")
    if check_architecture:
        architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
        if architecture != ["arm64"]:
            raise ValueError("The pinned custom runtime must be an arm64 Mach-O framework.")
    return framework, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=pathlib.Path)
    parser.add_argument("--write-provenance", type=pathlib.Path)
    args = parser.parse_args()
    try:
        framework, record = validate(args.receipt)
        if args.write_provenance:
            public = {key: value for key, value in record.items() if key != "framework"}
            args.write_provenance.write_text(json.dumps(public, indent=2, sort_keys=True) + "\n")
        print(framework)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Runtime verification failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
