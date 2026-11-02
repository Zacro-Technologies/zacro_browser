#!/usr/bin/env python3
"""Anchor real extension popups in a native macOS shell without showing a page."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PIN = "d0c02bfad08ec92a6ffcf989e53cd995e6381a4c"
BASE = "chrome/browser/ui/views/extensions/"
HEADER = BASE + "native_extension_popup_anchor.h"
SOURCE = BASE + "native_extension_popup_anchor_mac.mm"
POPUP_H = BASE + "extension_popup.h"
POPUP_CC = BASE + "extension_popup.cc"
DELEGATE = BASE + "extension_action_delegate_desktop.cc"
BUILD = BASE + "BUILD.gn"
PATHS = (HEADER, SOURCE, POPUP_H, POPUP_CC, DELEGATE, BUILD)


def replace(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Pinned popup anchor source drift: {old[:100]!r}")
    return text.replace(old, new)


def generated(originals):
    result = dict(originals)
    result[HEADER] = (ROOT / "native_popup_anchor.h.in").read_text()
    result[SOURCE] = (ROOT / "native_popup_anchor_mac.mm.in").read_text()
    result[POPUP_H] = replace(result[POPUP_H], "class BrowserWindowInterface;", "class BrowserWindowInterface;\nclass NativeExtensionPopupAnchor;")
    result[POPUP_H] = replace(result[POPUP_H], "  raw_ptr<BrowserWindowInterface> browser_;", """#if BUILDFLAG(IS_MAC)
  std::unique_ptr<NativeExtensionPopupAnchor> native_anchor_;
#endif
  raw_ptr<BrowserWindowInterface> browser_;""")
    result[POPUP_CC] = replace(result[POPUP_CC], '#include "base/message_loop/message_pump_apple.h"',
                              '#include "base/message_loop/message_pump_apple.h"\n#include "chrome/browser/ui/views/extensions/native_extension_popup_anchor.h"')
    result[POPUP_CC] = replace(result[POPUP_CC], """  auto* popup = new ExtensionPopup(browser, std::move(host), anchor, arrow,
""", """#if BUILDFLAG(IS_MAC)
  auto native_anchor = NativeExtensionPopupAnchor::Take(
      browser->GetTabStripModel()->GetActiveWebContents());
  if (native_anchor) {
    anchor = views::BubbleAnchor(native_anchor->view());
    arrow = views::BubbleBorder::TOP_LEFT;
  }
#endif
  auto* popup = new ExtensionPopup(browser, std::move(host), anchor, arrow,
""")
    result[POPUP_CC] = replace(result[POPUP_CC], "  views::BubbleDialogDelegateView::CreateBubble(popup);", """#if BUILDFLAG(IS_MAC)
  popup->native_anchor_ = std::move(native_anchor);
#endif
  views::BubbleDialogDelegateView::CreateBubble(popup);
#if BUILDFLAG(IS_MAC)
  if (popup->native_anchor_) {
    popup->native_anchor_->Attach(popup->GetWidget(), base::BindRepeating(
        &ExtensionPopup::CloseUnlessBlockedByInspectionOrJSDialog,
        popup->deferred_close_weak_ptr_factory_.GetWeakPtr()));
  }
#endif""")
    result[DELEGATE] = replace(result[DELEGATE], '#include "chrome/browser/ui/views/extensions/extension_popup.h"',
                              '#include "chrome/browser/ui/views/extensions/extension_popup.h"\n#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/ui/views/extensions/native_extension_popup_anchor.h"\n#endif')
    result[DELEGATE] = replace(result[DELEGATE], """  extensions_container_views_->PopOutAction(
""", """#if BUILDFLAG(IS_MAC)
  if (NativeExtensionPopupAnchor::HasPrepared(GetActiveWebContents())) {
    // A hidden Chrome toolbar cannot complete its pop-out layout animation.
    // Keep the same popup owner, ExtensionViewHost and granted user action;
    // only skip the toolbar animation when a native shell supplied an anchor.
    ShowPopup(std::move(host), show_action, by_user, std::move(callback));
    return;
  }
#endif
  extensions_container_views_->PopOutAction(
""")
    result[BUILD] = replace(result[BUILD], '  public = [ "extension_popup.h" ]',
                           '  public = [ "extension_popup.h", "native_extension_popup_anchor.h" ]')
    result[BUILD] = replace(result[BUILD], '  sources = [ "extension_popup.cc" ]', """  sources = [ "extension_popup.cc" ]
  if (is_mac) {
    sources += [ "native_extension_popup_anchor_mac.mm" ]
  }""")
    popup_start = result[BUILD].index('source_set("extension_popup_impl")')
    popup_end = result[BUILD].index('\nsource_set(', popup_start + 1)
    popup_target = result[BUILD][popup_start:popup_end]
    popup_target = replace(popup_target, '    "//ui/gfx/geometry",',
                           '    "//ui/gfx",\n    "//ui/gfx/geometry",')
    result[BUILD] = result[BUILD][:popup_start] + popup_target + result[BUILD][popup_end:]
    toolbar_start = result[BUILD].index('source_set("extensions_toolbar_desktop")')
    toolbar_end = result[BUILD].index('\n}', toolbar_start) + 2
    toolbar_target = result[BUILD][toolbar_start:toolbar_end]
    toolbar_target = replace(toolbar_target, '    ":extension_action_delegate_desktop",',
                             '    ":extension_action_delegate_desktop",\n    ":extension_popup",')
    result[BUILD] = result[BUILD][:toolbar_start] + toolbar_target + result[BUILD][toolbar_end:]
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
    if revision != PIN: raise SystemExit("Unexpected Chromium revision: " + revision)
    originals = {path: "" if path in (HEADER, SOURCE) else subprocess.check_output(
        ["git", "show", "HEAD:" + path], cwd=source, text=True) for path in PATHS}
    output = generated(originals)
    receipt = source / "out/zacro-popup-anchor.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get("revision") != PIN: prior = {}
    for path, contents in output.items():
        target = source / path
        current = target.read_text() if target.exists() else ""
        if current not in (originals[path], contents) and digest(current) != prior.get("files", {}).get(path):
            raise SystemExit("Refusing to overwrite unrelated edits: " + path)
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), contents.splitlines(True),
        fromfile="a/" + path if originals[path] else "/dev/null", tofile="b/" + path)) for path, contents in output.items())
    if not args.check:
        (ROOT / "native-popup-anchor.patch").write_text(patch)
        for path, contents in output.items():
            target = source / path
            if not target.exists() or target.read_text() != contents:
                temporary = target.with_suffix(target.suffix + ".zacro-tmp")
                temporary.write_text(contents); temporary.replace(target)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({"revision": PIN, "files": {p: digest(c) for p, c in output.items()}}, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Applied'} native popup anchor for Chromium {revision[:12]}")


if __name__ == "__main__": main()
