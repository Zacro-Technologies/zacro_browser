#!/usr/bin/env python3
"""Pinned transforms and actual hosted-panel allocation/clipping method checks."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--chromium-root", type=Path, required=True)
parser.add_argument("--compile", action="store_true")
arguments, remaining = parser.parse_known_args()
spec = importlib.util.spec_from_file_location("layout_adapter", ROOT / "apply_hosted_panel_layout.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class HostedPanelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.originals = adapter.source_baselines(arguments.chromium_root)
        cls.output = adapter.generated(cls.originals)

    def test_current_source_is_exact_pinned_baseline(self):
        current = {path: (arguments.chromium_root / path).read_text() for path in adapter.PATHS}
        receipt = arguments.chromium_root / "out/zacro-hosted-panel-layout.json"
        adapter.validate_current(self.originals, self.output, current,
            json.loads(receipt.read_text()) if receipt.exists() else None)

    def test_refuses_unrelated_or_wrong_pin_receipt(self):
        current = dict(self.output)
        current[adapter.SOURCE] += "// unrelated\n"
        with self.assertRaises(ValueError):
            adapter.validate_current(self.originals, self.output, current)
        receipt = {"revision": "wrong", "cefRevision": adapter.CEF_PIN,
                   "files": {p: adapter.digest(t) for p, t in current.items()}}
        with self.assertRaises(ValueError):
            adapter.validate_current(self.originals, self.output, current, receipt)

    def test_exact_previous_generation_upgrade(self):
        current = dict(self.output)
        current[adapter.SOURCE] += "// previous exact generation\n"
        receipt = {"revision": adapter.PIN, "cefRevision": adapter.CEF_PIN,
                   "files": {p: adapter.digest(t) for p, t in current.items()}}
        adapter.validate_current(self.originals, self.output, current, receipt)

    def test_native_opt_in_is_exact_popup_host_and_default_false(self):
        factory = self.output[adapter.FACTORY]
        branch = factory.split("case BrowserWindowInterface::Type::TYPE_POPUP:", 1)[1].split(
            "case BrowserWindowInterface::Type::TYPE_DEVTOOLS:", 1)[0]
        self.assertIn("cef::IsViewsHostedBrowser(browser)", branch)
        self.assertIn("bool native_side_panel = false", self.output[adapter.HEADER])
        self.assertIn("std::move(delegate), std::move(views), native_side_panel", branch)

    def test_native_predicate_stays_behind_existing_cef_utility(self):
        factory = self.output[adapter.FACTORY]
        self.assertNotIn('#include "cef/libcef/browser/chrome/browser_delegate.h"', factory)
        self.assertNotIn('#include "cef/libcef/browser/chrome/browser_util.h"', factory)
        helper = self.output[adapter.CEF_UTIL_SOURCE].split("bool IsViewsHostedBrowser(", 1)[1]
        self.assertIn("if (!browser) return false;", helper)
        self.assertIn("delegate && delegate->IsViewsHosted()", helper)
        self.assertIn("class BrowserWindowInterface;", self.output[adapter.CEF_UTIL_HEADER])

    def test_slot_precedes_actual_document_layout(self):
        source = self.output[adapter.SOURCE]
        self.assertLess(source.index("LayoutNativeSidePanel(layout, params);"),
                        source.index("gfx::Rect contents_bounds = params.visual_client_area;"))
        # The Swift shell owns narrow split-pane bounds; do not raise native
        # window minimums when opening a panel inside that already-owned slot.
        self.assertIn("constexpr gfx::Size kMinContentsSize(1, 1);", source)
        self.assertNotIn("SetWebContents", source)

    def test_actual_native_methods(self):
        if not arguments.compile:
            self.skipTest("Native compiler intentionally withheld until coordinated handoff")
        fixture = (ROOT / "native_hosted_panel_layout_tests.inc").read_text()
        methods = (ROOT / "native_hosted_panel_layout.inc").read_text()
        self.assertIn(methods, self.output[adapter.SOURCE])
        code = fixture.replace("// ACTUAL_GENERATED_METHODS", methods)
        with tempfile.TemporaryDirectory(prefix="zacro-panel-layout-fixture-") as temporary:
            source, binary = Path(temporary) / "fixture.cc", Path(temporary) / "fixture"
            source.write_text(code)
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", str(source), "-o", str(binary)], check=True)
            result = json.loads(subprocess.check_output([str(binary)], text=True))
            self.assertEqual(result, {"checks": 25})


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *remaining])
