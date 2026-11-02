#!/usr/bin/env python3
"""Preserve Chrome-owned downloads without inventing a CEF WebContents owner."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_PIN = "4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f"
HEADER = "cef/libcef/browser/download_manager_delegate_impl.h"
IMPL = "cef/libcef/browser/download_manager_delegate_impl.cc"
FACTORY = "cef/libcef/browser/download_manager_delegate.cc"
PATHS = (HEADER, IMPL, FACTORY)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit("Pinned download source drift: " + repr(old[:100]))
    return text.replace(old, new)


def generated(originals):
    header = replace(originals[HEADER],
        '  explicit CefDownloadManagerDelegateImpl(content::DownloadManager* manager);',
        '''  explicit CefDownloadManagerDelegateImpl(
      content::DownloadManager* manager,
      bool chrome_owns_browserless_downloads = false);''')
    header = replace(header, '  raw_ptr<content::DownloadManager> manager_;', '''  // Enabled only by the factory embedded in ChromeDownloadManagerDelegate.
  // A missing CEF callback owner is not a reason to reject a valid MV3 or
  // restored profile download owned by Chromium's original download delegate.
  const bool chrome_owns_browserless_downloads_;
  raw_ptr<content::DownloadManager> manager_;''')
    impl = replace(originals[IMPL], '''CefDownloadManagerDelegateImpl::CefDownloadManagerDelegateImpl(
    DownloadManager* manager)
    : manager_(manager), manager_ptr_factory_(manager) {''', '''CefDownloadManagerDelegateImpl::CefDownloadManagerDelegateImpl(
    DownloadManager* manager,
    bool chrome_owns_browserless_downloads)
    : chrome_owns_browserless_downloads_(chrome_owns_browserless_downloads),
      manager_(manager), manager_ptr_factory_(manager) {''')
    impl = replace(impl, '''  CefRefPtr<CefBrowserHostBase> browser = GetOrAssociateBrowser(item);
  if (!browser) {
    // If the download is rejected''', '''  CefRefPtr<CefBrowserHostBase> browser = GetOrAssociateBrowser(item);
  if (!browser && chrome_owns_browserless_downloads_) {
    // The outer ChromeDownloadManagerDelegate owns target determination,
    // extension permission checks, filename conflicts and danger handling.
    // Service workers and restored downloads legitimately have no WebContents.
    // Do not attach a fake browser or convert those downloads to cancellation.
    return;
  }
  if (!browser) {
    // If the download is rejected''')
    factory = replace(originals[FACTORY],
        '  return std::make_unique<CefDownloadManagerDelegateImpl>(download_manager);',
        '''  // This factory is used only by ChromeDownloadManagerDelegate. Alloy
  // browser callbacks and their existing unhandled-target cancellation remain
  // unchanged; only the Chrome owner can retain a browserless profile item.
  return std::make_unique<CefDownloadManagerDelegateImpl>(
      download_manager, /*chrome_owns_browserless_downloads=*/true);''')
    return {HEADER: header, IMPL: impl, FACTORY: factory}


def digest(contents):
    return hashlib.sha256(contents.encode()).hexdigest()


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if prior.get("revision") == PIN and prior.get("cefRevision") == CEF_PIN else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true", help="Write reviewable patch without mutating Chromium/CEF.")
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    cef_revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source / "cef", text=True).strip()
    if revision != PIN or cef_revision != CEF_PIN:
        raise SystemExit(f"Expected Chromium {PIN} / CEF {CEF_PIN}, found {revision} / {cef_revision}")
    originals = {path: subprocess.check_output(["git", "show", "HEAD:" + path.removeprefix("cef/")],
        cwd=source / "cef", text=True) for path in PATHS}
    output = generated(originals)
    receipt = source / "out/zacro-browserless-downloads.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-browserless-downloads.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "cefRevision": CEF_PIN,
            "files": {path: digest(contents) for path, contents in output.items()}}, indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} browserless Chrome downloads for CEF {cef_revision[:12]}")


if __name__ == "__main__":
    main()
