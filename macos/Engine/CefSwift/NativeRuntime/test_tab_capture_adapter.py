#!/usr/bin/env python3
"""Pinned transformation boundaries; real capture policy runs in Chromium fixtures."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('adapter', ROOT / 'apply_tab_capture_adapter.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

class TabCaptureAdapterTests(unittest.TestCase):
    def test_generated_target_resolution_preserves_capture_checks(self):
        result = adapter.generated(self.originals)
        before, after = self.originals[adapter.IMPL], result[adapter.IMPL]
        marker = '  if (!target_contents) {'
        # Every original permission, policy, caller restriction, registry grant
        # and subsequent API method is byte-identical after target selection.
        self.assertEqual(before[before.index(marker):], after[after.index(marker):])
        self.assertIn('ExtensionTabUtil::GetTabById(*native_target_tab_id_', after)
        self.assertIn('include_incognito_information()', after)
        self.assertIn('std::optional<int> native_target_tab_id_', result[adapter.HEADER])

    def test_repeatable_and_pristine_or_applied_is_accepted(self):
        output = adapter.generated(self.originals)
        self.assertEqual(output, adapter.generated(self.originals))
        adapter.validate_current(self.originals, output, self.originals)
        adapter.validate_current(self.originals, output, output)

    def test_anchor_drift_rejected(self):
        inputs = dict(self.originals)
        inputs[adapter.IMPL] = inputs[adapter.IMPL].replace('GetActiveWebContents(target_browser);', 'GetOtherContents(target_browser);')
        with self.assertRaisesRegex(SystemExit, 'source drift'):
            adapter.generated(inputs)

    def test_unrelated_edits_rejected_before_mutation(self):
        output = adapter.generated(self.originals)
        current = dict(output); current[adapter.HEADER] += '// unrelated\n'
        with self.assertRaisesRegex(SystemExit, 'unrelated edits'):
            adapter.validate_current(self.originals, output, current)

    def test_upgrade_requires_exact_receipt(self):
        output = adapter.generated(self.originals)
        prior = dict(output); prior[adapter.HEADER] += '// previous generation\n'
        receipt = {'revision': adapter.PIN, 'files': {p: adapter.digest(v) for p, v in prior.items()}}
        adapter.validate_current(self.originals, output, prior, receipt)
        receipt['revision'] = 'wrong'
        with self.assertRaisesRegex(SystemExit, 'unrelated edits'):
            adapter.validate_current(self.originals, output, prior, receipt)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--chromium-root', required=True, type=Path)
    args, remaining = parser.parse_known_args()
    TabCaptureAdapterTests.originals = {p: subprocess.check_output(['git', 'show', 'HEAD:' + p], cwd=args.chromium_root, text=True) for p in adapter.PATHS}
    unittest.main(argv=[__file__, *remaining])
