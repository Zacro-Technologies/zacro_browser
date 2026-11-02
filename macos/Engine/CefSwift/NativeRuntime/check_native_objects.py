#!/usr/bin/env python3
"""Compile changed objects early using GN's exact commands and real headers.

The full Chrome link target has broad order-only dependencies. This check only
generates missing official header targets; it never invents build flags or
headers. Success is an object check, not a framework or runtime acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

DEFAULT = "obj/cef/libcef_static/devtools_controller.o"


def command_for(source, out, target, evidence):
    suffix = target + ": "
    for path in (out / "obj").rglob("*.ninja"):
        text = path.read_text(errors="replace")
        marker = "build " + suffix
        if marker not in text:
            continue
        prefix = text[:text.index("build ")]
        block = text[text.index(marker):].split("\nbuild ", 1)[0]
        lines = block.splitlines()
        lines[0] = re.split(r" \|\|? ", lines[0], maxsplit=1)[0]
        rule = lines[0].split(": ", 1)[1].split()[0]
        toolchain = (out / "toolchain.ninja").read_text()
        rule_match = re.search(r"^rule " + re.escape(rule) + r"\n(?:  .*\n)+", toolchain, re.M)
        if not rule_match:
            raise SystemExit("Missing compiler rule: " + rule)
        minimal = evidence / (Path(target).stem + ".ninja")
        minimal.write_text(rule_match[0] + "\n" + prefix + "\n" + "\n".join(lines) + "\n")
        result = subprocess.check_output([str(source / "third_party/ninja/ninja"), "-f", str(minimal),
                                          "-t", "commands", target], cwd=out, text=True)
        command = shlex.split(result.strip())
        # Leave GN's real object/dependency files for Ninja to own.
        for option, replacement in (("-o", evidence / (Path(target).stem + ".o")),
                                    ("-MF", evidence / (Path(target).stem + ".d"))):
            command[command.index(option) + 1] = str(replacement)
        (evidence / (Path(target).stem + "-command.json")).write_text(json.dumps(command, indent=2) + "\n")
        return command
    raise SystemExit("No pinned generated target: " + target)


def generated_outputs(out):
    result = set()
    for path in out.rglob("*.ninja"):
        for line in path.read_text(errors="replace").splitlines():
            if line.startswith("build "):
                result.update(v for v in line[6:].split(": ", 1)[0].split() if v.startswith("gen/"))
    return result


def missing_generated(command, source, out, evidence, known):
    deps = evidence / "missing-headers.d"
    scan = list(command)
    scan.remove("-c")
    scan.extend(["-M", "-MG", "-MF", str(deps), "-Wno-unused-command-line-argument"])
    with (evidence / "dependency-scan.log").open("w") as log:
        subprocess.run(scan, cwd=out, stdout=log, stderr=subprocess.STDOUT)
    if not deps.is_file():
        return []
    words = shlex.split(deps.read_text().replace("\\\n", ""))[1:]
    targets = {"gen/" + value for value in words
               if not (out / value).exists() and not (source / value).exists()
               and "gen/" + value in known}
    return sorted(targets)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--verification-dir", required=True, type=Path)
    parser.add_argument("--target", action="append")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--generate-prerequisites", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    out = source / "out/Release_GN_arm64"
    evidence = args.verification_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["PATH"] = str(source.parents[1] / "depot_tools") + os.pathsep + environment["PATH"]
    known = None
    results = {}
    for target in args.target or [DEFAULT]:
        command = command_for(source, out, target, evidence)
        if args.prepare_only:
            continue
        for attempt in range(100):
            if shutil.disk_usage(source).free < 15 * 1024 ** 3:
                raise SystemExit("Stopped below 15 GiB free; existing files were preserved.")
            log_path = evidence / (Path(target).stem + ".log")
            print("Compiling", target, "attempt", attempt + 1, flush=True)
            with log_path.open("w") as log:
                result = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode == 0:
                results[target] = True
                break
            if not args.generate_prerequisites or "file not found" not in log_path.read_text():
                raise SystemExit(f"Compiler rejected {target}; see {log_path}")
            if known is None:
                known = generated_outputs(out)
            missing = missing_generated(command, source, out, evidence, known)
            if not missing:
                raise SystemExit(f"No missing official generated target found; see {log_path}")
            (evidence / "generated-targets.json").write_text(json.dumps(missing, indent=2) + "\n")
            print("Generating", len(missing), "official header targets", flush=True)
            with (evidence / "prerequisites.log").open("w") as log:
                result = subprocess.run(["autoninja", "-C", str(out), *missing, "-j4"], env=environment,
                                        stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise SystemExit("Official prerequisite generation failed; see prerequisites.log")
        else:
            raise SystemExit("Reached bounded generation rounds; rerun to continue")
    (evidence / "object-check.json").write_text(json.dumps({"compiledObjects": results,
        "frameworkBuilt": False, "runtimeVerified": False}, indent=2) + "\n")


if __name__ == "__main__":
    main()
