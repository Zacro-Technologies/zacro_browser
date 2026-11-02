#!/usr/bin/env python3
"""Exercise native Swift sync against the real server using disposable local data.

Requires macOS 14+, Swift 6, and Node 24+ (node:sqlite). No Keychain, production
account, model inference, or existing browser state is used.
"""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "macos/scripts/fixtures"

def run(command, *, timeout=240, **kwargs):
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        code = process.wait(timeout=timeout)
        if code:
            raise subprocess.CalledProcessError(code, command)
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        raise

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be between 1 and 8")
    node = shutil.which("node")
    swift = shutil.which("swift")
    if not node or not swift:
        parser.error("Node and Swift are required")
    major = int(subprocess.check_output([node, "--version"], text=True, timeout=15).strip().lstrip("v").split(".")[0])
    if major < 24:
        parser.error("Node 24 or later is required for node:sqlite")
    with tempfile.TemporaryDirectory(prefix="zacro-native-sync-integration-") as temporary:
        root = Path(temporary)
        package = root / "package"
        source = package / "Sources"
        probe = source / "ZacroSyncProbe"
        probe.mkdir(parents=True)
        (source / "ZacroServices").symlink_to(ROOT / "macos/Sources/ZacroServices", target_is_directory=True)
        shutil.copyfile(FIXTURES / "live-sync-probe.swift", probe / "main.swift")
        (package / "Package.swift").write_text(
            '// swift-tools-version: 6.0\nimport PackageDescription\n'
            'let package = Package(name:"ZacroSyncIntegration",platforms:[.macOS(.v14)],'
            'targets:[.target(name:"ZacroServices"),.executableTarget(name:"ZacroSyncProbe",'
            'dependencies:["ZacroServices"])],swiftLanguageModes:[.v5])\n')
        run([swift, "build", "--package-path", str(package), "--jobs", str(args.jobs), "--product", "ZacroSyncProbe"], timeout=900)
        binary = Path(subprocess.check_output([swift, "build", "--package-path", str(package), "--show-bin-path"], text=True, timeout=30).strip()) / "ZacroSyncProbe"
        run([node, str(FIXTURES / "live-sync-runner.cjs"), str(binary), str(root / "data")], cwd=ROOT)

if __name__ == "__main__":
    main()
