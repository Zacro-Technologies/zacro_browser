#!/usr/bin/env python3
"""Keep Chromium's real action model in CEF's toolbarless hosted windows."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
CEF_PIN = "4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f"
SOURCE = "chrome/browser/ui/views/toolbar/toolbar_view.cc"
PATHS = (SOURCE,)
ANCHOR = """  } else if (display_mode_ == DisplayMode::kLocation) {
    // Add the pinned toolbar actions container so that downloads can be shown"""
HOST = """  } else if (display_mode_ == DisplayMode::kLocation) {
#if BUILDFLAG(ENABLE_CEF)
    // CefBrowserView uses a trusted popup Browser and therefore location mode.
    // Its early return otherwise omits the real extension action model entirely.
    // Keep Chromium's normal model, observers and action/popup delegates owned
    // by this toolbar, without presenting a second toolbar in the native shell.
    auto* cef_delegate = cef::BrowserForBWI(browser_)->cef_delegate();
    if (cef_delegate && cef_delegate->IsViewsHosted() &&
        !browser_->GetProfile()->IsGuestSession()) {
      auto* native_action_host = AddChildView(std::make_unique<views::View>());
      native_action_host->SetVisible(false);
      extensions_container_ = native_action_host->AddChildView(
          std::make_unique<ExtensionsToolbarDesktop>(browser_));
      extensions_toolbar_coordinator_ =
          std::make_unique<ExtensionsToolbarCoordinator>(extensions_container_);
      // ExtensionsToolbarDesktop may change its own visibility as extensions
      // load or a popup opens. Its parent stays hidden, takes no layout space,
      // and prevents toolbar controls from entering paint, hit-test or AX trees.
    }
#endif
    // Add the pinned toolbar actions container so that downloads can be shown"""


def generated(originals):
    original = originals[SOURCE]
    if original.count(ANCHOR) != 1:
        raise SystemExit("Pinned extension toolbar source drift")
    return {SOURCE: original.replace(ANCHOR, HOST)}


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def source_baselines(source):
    original = subprocess.check_output(["git", "show", "HEAD:" + SOURCE], cwd=source, text=True)
    patch = subprocess.check_output(["git", "show", "HEAD:patch/patches/chrome_runtime_views.patch"],
                                   cwd=source / "cef", text=True)
    sections = ["diff --git " + part for part in patch.split("diff --git ")[1:]]
    selected = [part for part in sections if part.splitlines()[0] == "diff --git " + SOURCE + " " + SOURCE]
    if len(selected) != 1:
        raise SystemExit("Pinned CEF toolbar baseline patch is missing or ambiguous")
    with tempfile.TemporaryDirectory(prefix="zacro-toolbar-baseline-") as temporary:
        root = Path(temporary); target = root / SOURCE
        target.parent.mkdir(parents=True); target.write_text(original)
        subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], input=selected[0],
                       cwd=root, text=True, check=True)
        return {SOURCE: target.read_text()}


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
    parser.add_argument("--emit-patch", action="store_true", help="Write the reviewable patch without changing Chromium or its receipt.")
    args = parser.parse_args(); source = args.chromium_root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    cef_revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source / "cef", text=True).strip()
    if revision != PIN or cef_revision != CEF_PIN:
        raise SystemExit(f"Expected Chromium {PIN} / CEF {CEF_PIN}, found {revision} / {cef_revision}")
    originals = source_baselines(source); output = generated(originals)
    receipt = source / "out/zacro-extension-toolbar.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)) for path in PATHS)
    if args.emit_patch or not args.check:
        (ROOT / "native-extension-toolbar.patch").write_text(patch)
    if not args.check and not args.emit_patch:
        for path, contents in output.items():
            target = source / path
            if target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "cefRevision": CEF_PIN,
            "files": {path: digest(contents) for path, contents in output.items()}}, indent=2) + "\n")
    print(f"{'Emitted' if args.emit_patch else 'Checked' if args.check else 'Applied'} real hosted extension toolbar for CEF {cef_revision[:12]}")


if __name__ == "__main__":
    main()
