#!/usr/bin/env python3
"""Compile the actual pane shadow and verify its transparent bitmap geometry.

This uses AppKit/Core Animation without creating browser windows, profiles or
desktop input. It does not establish WindowServer composition or engine parity.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("The pane shadow render requires macOS AppKit and Swift.")
    source = Path(__file__).resolve().parents[1] / "Sources/ZacroApp"
    names = ["NativePaneShadow.swift", "NativePaneShadowAcceptance.swift", "NativeChromeControls.swift"]
    originals = {name: (source / name).read_bytes() for name in names}
    controls = originals["NativeChromeControls.swift"].decode()
    start = "struct NativePaneShape: Shape {"
    end = "\nstruct NativeChromeProgressStyle:"
    if controls.count(start) != 1 or controls.count(end) != 1:
        raise SystemExit("The exact production pane contour cannot be extracted unambiguously.")
    contour = controls[controls.index(start):controls.index(end)]
    with tempfile.TemporaryDirectory(prefix="zacro-pane-shadow-") as directory:
        root = Path(directory)
        for name in names[:2]:
            (root / name).write_bytes(originals[name])
        (root / "NativePaneContour.swift").write_text("import AppKit\nimport SwiftUI\n\n" + contour)
        (root / "Probe.swift").write_text("""import AppKit
import Foundation
@main struct Probe {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let checks = NativePaneShadowAcceptance.check()
    let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(!checks.isEmpty && checks.values.allSatisfy { $0 } ? 0 : 1)
  }
}
""")
        executable = root / "probe"
        subprocess.run(["swiftc", "-parse-as-library", "-O", str(root / "NativePaneContour.swift"),
            str(root / names[0]), str(root / names[1]), str(root / "Probe.swift"), "-o", str(executable)],
            check=True, timeout=120)
        run = subprocess.run([str(executable)], text=True, capture_output=True, timeout=30)
        if run.stderr:
            sys.stderr.write(run.stderr)
        checks = json.loads(run.stdout)
        passed = run.returncode == 0 and isinstance(checks, dict) and len(checks) >= 9 \
            and "paneShadowActualBitmapHasNoOpaqueCasterFringeOrOutline" in checks \
            and all(type(value) is bool and value for value in checks.values())
        report = {"passed": passed, "checks": checks, "helperExitCode": run.returncode,
            "desktopCompositingVerified": False, "fullApplicationSuitePassed": False,
            "sourceSHA256": {name: hashlib.sha256(data).hexdigest() for name, data in originals.items()}}
        encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded)
        print(encoded, end="")
        if not passed:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
