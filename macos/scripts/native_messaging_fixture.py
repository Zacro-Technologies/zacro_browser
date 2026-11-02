"""Build/register only our disposable native host in an explicitly fresh profile."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid

KINDS = ("echo", "fragments", "batch", "oversized", "truncated", "invalidjson", "hold", "denied")


def build_host(output):
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent / "fixtures/native-messaging/host.c"
    subprocess.run(["xcrun", "clang", "-std=c11", "-D_DEFAULT_SOURCE", "-Wall", "-Wextra", "-Werror",
                    "-O1", str(source), "-o", str(output)], check=True)
    output.chmod(0o700)
    return output


def register_hosts(user_data_dir, extension_id, executable):
    root = Path(user_data_dir).resolve()
    executable = Path(executable).resolve()
    # This helper can never register in a user's installed Chrome/Chromium tree.
    if (root.name not in ("profile", "Chromium") or
            not (root.parent.name.startswith("run-") or root.parent.name.startswith("zacro-native-acceptance-"))):
        raise ValueError("Native messaging fixtures require an isolated acceptance profile")
    if not re.fullmatch(r"[a-p]{32}", extension_id) or not executable.is_file():
        raise ValueError("An actual fixture extension identity and built host are required")
    token = uuid.uuid4().hex
    directory = root / ("ZacroNativeMessagingFixture-" + token)
    directory.mkdir(parents=True, mode=0o700)
    manifests = root / "NativeMessagingHosts"
    if manifests.is_symlink():
        raise ValueError("Fixture registration directory must not be a symlink")
    manifests.mkdir(mode=0o700, exist_ok=True)
    names = {}
    for kind in KINDS:
        host = directory / kind
        shutil.copyfile(executable, host); host.chmod(0o700)
        name = "com.zacro.native_fixture_" + token + "." + kind
        origin = extension_id if kind != "denied" else ("a" * 32 if extension_id != "a" * 32 else "b" * 32)
        manifest = {"name":name, "description":"Disposable Zacro acceptance host", "path":str(host),
                    "type":"stdio", "allowed_origins":["chrome-extension://" + origin + "/"]}
        with (manifests / (name + ".json")).open("x") as file:
            os.chmod(file.name,0o600); json.dump(manifest,file)
        names[kind] = name
    names["missing"] = "com.zacro.native_fixture_" + token + ".missing"
    return {"hosts":names, "directory":str(directory), "registrationDirectory":str(manifests)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Built host executable path")
    args = parser.parse_args()
    print(build_host(args.output))


if __name__ == "__main__":
    main()
