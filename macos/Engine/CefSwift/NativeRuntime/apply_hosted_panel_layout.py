#!/usr/bin/env python3
"""Lay out an existing native extension panel in a CEF-hosted popup Browser."""
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
BASE = "chrome/browser/ui/views/frame/layout/"
FACTORY = BASE + "browser_view_layout.cc"
HEADER = BASE + "browser_view_popup_layout_impl.h"
SOURCE = BASE + "browser_view_popup_layout_impl.cc"
BUILD = "chrome/browser/ui/views/frame/BUILD.gn"
CEF_UTIL_HEADER = "cef/libcef/browser/chrome/views/chrome_views_util.h"
CEF_UTIL_SOURCE = "cef/libcef/browser/chrome/views/chrome_views_util.cc"
PATHS = (FACTORY, HEADER, SOURCE, BUILD, CEF_UTIL_HEADER, CEF_UTIL_SOURCE)


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Pinned hosted panel layout anchor drift: " + old[:100])
    return text.replace(old, new)


def generated(originals):
    out = dict(originals)
    text = out[FACTORY]
    text = replace(text, """      case BrowserWindowInterface::Type::TYPE_POPUP:
      case BrowserWindowInterface::Type::TYPE_DEVTOOLS:""", """      case BrowserWindowInterface::Type::TYPE_POPUP: {
        bool native_side_panel = false;
#if BUILDFLAG(ENABLE_CEF)
        native_side_panel = cef::IsViewsHostedBrowser(browser);
#endif
        return std::make_unique<BrowserViewPopupLayoutImpl>(
            std::move(delegate), std::move(views), native_side_panel);
      }
      case BrowserWindowInterface::Type::TYPE_DEVTOOLS:""")
    out[FACTORY] = text
    text = replace(out[HEADER], "      BrowserViewLayoutViews views);",
        "      BrowserViewLayoutViews views, bool native_side_panel = false);")
    text = replace(text, "                                        bool needs_exclusion) const override;", """                                        bool needs_exclusion) const override;
  void DoPostLayoutVisualAdjustments(
      const BrowserLayoutParams& params) override;

 private:
  void LayoutNativeSidePanel(ProposedLayout& layout,
                            BrowserLayoutParams& params) const;
  const bool native_side_panel_;""")
    out[HEADER] = text
    text = replace(out[SOURCE], '#include "chrome/browser/ui/views/frame/multi_contents_view.h"',
        '#include <algorithm>\n#include <optional>\n'
        '#include "base/i18n/rtl.h"\n#include "base/numerics/safe_conversions.h"\n'
        '#include "chrome/browser/ui/animation/browser_animation_controller.h"\n'
        '#include "chrome/browser/ui/views/animations/side_panel_animations.h"\n'
        '#include "chrome/browser/ui/views/frame/multi_contents_view.h"\n'
        '#include "chrome/browser/ui/views/side_panel/side_panel.h"\n'
        '#include "chrome/browser/ui/views/side_panel/side_panel_animation_content_view.h"\n'
        '#include "ui/compositor/layer.h"')
    text = replace(text, """    BrowserViewLayoutViews views)
    : BrowserViewLayoutImpl(std::move(delegate), std::move(views)) {""", """    BrowserViewLayoutViews views, bool native_side_panel)
    : BrowserViewLayoutImpl(std::move(delegate), std::move(views)),
      native_side_panel_(native_side_panel) {""")
    text = replace(text, "  // Lay out contents container.", """  // A real native extension panel has already passed SidePanelCoordinator's
  // profile/document policy. The ordinary popup layout has no side-panel slot.
  LayoutNativeSidePanel(layout, params);

  // Lay out contents container.""")
    text += "\n" + (ROOT / "native_hosted_panel_layout.inc").read_text()
    out[SOURCE] = text
    text = out[BUILD]
    start = text.index('source_set("browser_view_popup_layout_impl")')
    end = text.index('\nsource_set(', start + 1)
    target = text[start:end]
    target = replace(target, '    "//chrome/browser/ui/views/infobars",',
        '    "//base:i18n",\n'
        '    "//chrome/browser/ui/animation",\n'
        '    "//chrome/browser/ui/views/animations",\n'
        '    "//chrome/browser/ui/views/infobars",\n'
        '    "//chrome/browser/ui/views/side_panel",\n'
        '    "//ui/compositor",')
    out[BUILD] = text[:start] + target + text[end:]
    out[CEF_UTIL_HEADER] = replace(out[CEF_UTIL_HEADER], "#pragma once", "#pragma once\n\nclass BrowserWindowInterface;")
    out[CEF_UTIL_HEADER] = replace(out[CEF_UTIL_HEADER], "bool IsCefView(views::View* view);", """bool IsCefView(views::View* view);

// Query the actual CEF Browser delegate without exposing its implementation
// headers to Chrome layout targets. Null and ordinary Chrome windows are false.
bool IsViewsHostedBrowser(BrowserWindowInterface* browser);""")
    out[CEF_UTIL_SOURCE] = replace(out[CEF_UTIL_SOURCE], '#include "cef/libcef/browser/views/view_util.h"',
        '#include "cef/libcef/browser/chrome/browser_delegate.h"\n'
        '#include "cef/libcef/browser/chrome/browser_util.h"\n'
        '#include "cef/libcef/browser/views/view_util.h"')
    out[CEF_UTIL_SOURCE] = replace(out[CEF_UTIL_SOURCE], "}  // namespace cef", """bool IsViewsHostedBrowser(BrowserWindowInterface* browser) {
  if (!browser) return false;
  auto* delegate = BrowserForBWI(browser)->cef_delegate();
  return delegate && delegate->IsViewsHosted();
}

}  // namespace cef""")
    return out


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def source_baselines(source):
    originals = {}
    for path in PATHS:
        cef = path.startswith("cef/")
        originals[path] = subprocess.check_output(
            ["git", "show", "HEAD:" + (path[4:] if cef else path)],
            cwd=source / "cef" if cef else source, text=True)
    patch = subprocess.check_output(["git", "show", "HEAD:patch/patches/chrome_runtime_views.patch"],
                                    cwd=source / "cef", text=True)
    sections = ["diff --git " + part for part in patch.split("diff --git ")[1:]]
    selected = [part for part in sections
        if part.splitlines()[0] == "diff --git " + FACTORY + " " + FACTORY]
    if len(selected) != 1:
        raise ValueError("Missing pinned CEF browser layout baseline")
    with tempfile.TemporaryDirectory(prefix="zacro-panel-layout-baseline-") as temporary:
        root = Path(temporary)
        target = root / FACTORY
        target.parent.mkdir(parents=True)
        target.write_text(originals[FACTORY])
        subprocess.run(["git", "apply", "-p0", "--unsafe-paths", "-"], input=selected[0],
                       cwd=root, text=True, check=True)
        originals[FACTORY] = target.read_text()
    return originals


def validate_current(originals, output, current, prior=None):
    prior = prior or {}
    previous = prior.get("files", {}) if (
        prior.get("revision") == PIN and prior.get("cefRevision") == CEF_PIN) else {}
    for path in PATHS:
        if current[path] not in (originals[path], output[path]) and digest(current[path]) != previous.get(path):
            raise ValueError("Refusing unrelated source edits: " + path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-patch", action="store_true")
    parser.add_argument("--output-tree", type=Path)
    args = parser.parse_args()
    source = args.chromium_root.resolve()
    for repo, pin in [(source, PIN), (source / "cef", CEF_PIN)]:
        if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip() != pin:
            raise ValueError("Wrong source revision")
    originals = source_baselines(source)
    output = generated(originals)
    receipt = source / "out/zacro-hosted-panel-layout.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else None
    validate_current(originals, output, {path: (source / path).read_text() for path in PATHS}, prior)
    if args.emit_patch or not (args.check or args.output_tree):
        (ROOT / "native-hosted-panel-layout.patch").write_text("".join(
            "".join(difflib.unified_diff(originals[path].splitlines(True), output[path].splitlines(True),
                fromfile="a/" + path, tofile="b/" + path)) for path in PATHS))
    if args.output_tree:
        for path, text in output.items():
            target = args.output_tree / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
    if not (args.check or args.emit_patch or args.output_tree):
        for path, text in output.items():
            target = source / path
            if target.read_text() != text:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(text)
                temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "cefRevision": CEF_PIN,
            "files": {path: digest(text) for path, text in output.items()}}, indent=2) + "\n")
    print("Validated hosted side-panel layout" if args.check or args.emit_patch or args.output_tree
          else "Applied hosted side-panel layout")


if __name__ == "__main__":
    main()
