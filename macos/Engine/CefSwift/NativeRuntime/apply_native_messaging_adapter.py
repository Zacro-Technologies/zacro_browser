#!/usr/bin/env python3
"""Resolve existing macOS Chrome host registrations without copying or launching them."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
BASE = "chrome/browser/extensions/api/messaging/"
SOURCE = BASE + "launch_context_posix.cc"
HEADER = BASE + "launch_context.h"
TEST = BASE + "native_message_process_host_unittest.cc"
PATHS = (SOURCE, HEADER, TEST)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned native messaging source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    result = dict(originals)
    source = replace(result[SOURCE], '#include "base/command_line.h"',
                     '#include "base/base_paths.h"\n#include "base/command_line.h"')
    source = replace(source, "}  // namespace\n", """#if BUILDFLAG(IS_MAC)
base::FilePath FindMacUserManifest(const std::string& host_name) {
  base::FilePath home;
  if (!base::PathService::Get(base::DIR_HOME, &home) || home.empty()) {
    return base::FilePath();
  }
  for (const char* directory : {
           "Library/Application Support/Chromium/NativeMessagingHosts",
           "Library/Application Support/Google/Chrome/NativeMessagingHosts"}) {
    base::FilePath path = home.Append(directory).Append(host_name + ".json");
    if (base::PathExists(path)) {
      return path;
    }
  }
  return base::FilePath();
}
#endif

}  // namespace
""")
    source = replace(source, """    result = FindManifestInDir(chrome::DIR_USER_NATIVE_MESSAGING, host_name);
  }
  if (result.empty()) {
    result = FindManifestInDir(chrome::DIR_NATIVE_MESSAGING, host_name);
  }
""", """    result = FindManifestInDir(chrome::DIR_USER_NATIVE_MESSAGING, host_name);
#if BUILDFLAG(IS_MAC)
    // Prefer this browser's explicit registration, then existing vendor
    // registrations. Policy disabling user hosts applies to every user path.
    if (result.empty()) {
      result = FindMacUserManifest(host_name);
    }
#endif
  }
  if (result.empty()) {
    result = FindManifestInDir(chrome::DIR_NATIVE_MESSAGING, host_name);
  }
#if BUILDFLAG(IS_MAC)
  if (result.empty()) {
    base::FilePath chrome_manifest =
        base::FilePath("/Library/Google/Chrome/NativeMessagingHosts")
            .Append(host_name + ".json");
    if (base::PathExists(chrome_manifest)) {
      result = chrome_manifest;
    }
  }
#endif
  // Return the first existing registration, even if malformed. The existing
  // launcher validates its contents, allowed origins, path and launch policy;
  // an invalid higher-priority registration must never select another host.
""")
    result[SOURCE] = source
    result[HEADER] = replace(result[HEADER], " private:\n", " private:\n  friend class NativeMessagingManifestPathsTest;\n\n")
    tests = replace(result[TEST], '#include "base/test/scoped_feature_list.h"',
                    '#include "base/test/scoped_feature_list.h"\n#include "base/test/scoped_path_override.h"')
    tests = replace(tests, '#include "chrome/browser/extensions/api/messaging/native_messaging_launch_from_native.h"',
                    '#include "chrome/browser/extensions/api/messaging/launch_context.h"\n#include "chrome/browser/extensions/api/messaging/native_messaging_launch_from_native.h"')
    tests = replace(tests, '#include "chrome/common/chrome_features.h"',
                    '#include "chrome/common/chrome_features.h"\n#include "chrome/common/chrome_paths.h"')
    result[TEST] = replace(tests, "}  // namespace extensions\n",
        (ROOT / "native_messaging_path_tests.inc").read_text() + "\n}  // namespace extensions\n")
    return result


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    output = generated(originals)
    # Refuse unrelated changes rather than trusting a mutable receipt. Changes
    # to an already applied adapter require restoring only its known patch first.
    for path, contents in output.items():
        current = (source / path).read_text()
        if current not in (originals[path], contents):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path, contents in output.items())
    if not args.check:
        (ROOT / "native-messaging-paths.patch").write_text(patch)
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt = source / "out/zacro-native-messaging-paths.json"
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Applied'} native messaging paths for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
