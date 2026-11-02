#!/usr/bin/env python3
"""Resolve native tab capture through the trusted logical topology target."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
HEADER = "chrome/browser/extensions/api/tab_capture/tab_capture_api.h"
IMPL = "chrome/browser/extensions/api/tab_capture/tab_capture_api.cc"
PATHS = (HEADER, IMPL)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned tab capture source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    header = replace(originals[HEADER], '#include "chrome/browser/extensions/api/tab_capture/tab_capture_registry.h"',
        '#include <optional>\n\n#include "chrome/browser/extensions/api/tab_capture/tab_capture_registry.h"')
    header = replace(header, '  DECLARE_EXTENSION_FUNCTION("tabCapture.capture", TABCAPTURE_CAPTURE)', '''  DECLARE_EXTENSION_FUNCTION("tabCapture.capture", TABCAPTURE_CAPTURE)

  // Trusted browser-process topology dispatcher only. No public API argument
  // or renderer binding can set this target; Run retains all capture grants,
  // origin/consumer restrictions and TabCaptureRegistry policy.
  void SetNativeTargetTabID(int tab_id) { native_target_tab_id_ = tab_id; }''')
    header = replace(header, '  ~TabCaptureCaptureFunction() final {}', '''  ~TabCaptureCaptureFunction() final {}
  std::optional<int> native_target_tab_id_;''')
    impl = replace(originals[IMPL], '''  Profile* profile = Profile::FromBrowserContext(browser_context());
  const bool match_incognito_profile = include_incognito_information();
  BrowserWindowInterface* target_browser =
      browser_window_util::GetLastActiveBrowserWithProfile(
          *profile, match_incognito_profile);
  if (!target_browser) {
    return RespondNow(Error(tab_capture_errors::kFindingTabError));
  }

  content::WebContents* target_contents = GetActiveWebContents(target_browser);''', '''  content::WebContents* target_contents = nullptr;
  if (native_target_tab_id_) {
    // Resolve the immutable session identity again at execution time. This
    // does not grant capture; the unchanged checks below remain authoritative.
    if (!ExtensionTabUtil::GetTabById(*native_target_tab_id_, browser_context(),
                                    include_incognito_information(),
                                    &target_contents)) {
      return RespondNow(Error(tab_capture_errors::kFindingTabError));
    }
  } else {
    Profile* profile = Profile::FromBrowserContext(browser_context());
    const bool match_incognito_profile = include_incognito_information();
    BrowserWindowInterface* target_browser =
        browser_window_util::GetLastActiveBrowserWithProfile(
            *profile, match_incognito_profile);
    if (!target_browser) {
      return RespondNow(Error(tab_capture_errors::kFindingTabError));
    }
    target_contents = GetActiveWebContents(target_browser);
  }''')
    return {HEADER: header, IMPL: impl}



def digest(contents):
    return hashlib.sha256(contents.encode()).hexdigest()


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if prior.get("revision") == PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true", help="Write the reviewable patch without mutating Chromium.")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected pinned Chromium {PIN}, found {revision}")
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    output = generated(originals)
    receipt = source / "out/zacro-tab-capture.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-tab-capture.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {
            p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} native tab capture for Chromium {revision[:12]}")


if __name__ == "__main__":
    main()
