#!/usr/bin/env python3
"""Strict pinned history driver tests; no source mutation or runtime launch."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

history = module('apply_history_mirror')
flush = module('apply_history_flush_adapter')

class HistoryMirrorDriverTests(unittest.TestCase):
    def test_renderer_flush_and_native_mirror_own_disjoint_paths(self):
        self.assertFalse(set(history.PATHS).intersection(flush.PATHS))
        self.assertIn('content/common/frame.mojom', flush.PATHS)
        self.assertIn('components/history/core/browser/history_database.cc', history.PATHS)

    def test_raw_pinned_adoption_and_repeat_output_are_allowed(self):
        original = {p: 'pinned ' + p for p in history.PATHS}
        changed = {p: 'generated ' + p for p in history.PATHS}
        history.validate_current(original, changed, original)
        history.validate_current(original, changed, changed)

    def test_exact_previous_receipt_allows_only_known_owned_upgrade(self):
        original = {p: 'pinned ' + p for p in history.PATHS}
        changed = {p: 'generated ' + p for p in history.PATHS}
        previous = {p: 'previous ' + p for p in history.PATHS}
        receipt = {'revision': history.PIN, 'files': {p: history.digest(v) for p, v in previous.items()}}
        history.validate_current(original, changed, previous, receipt)
        unknown = dict(previous); unknown[history.PATHS[0]] += ' unrelated'
        with self.assertRaisesRegex(ValueError, 'Refusing unrelated'):
            history.validate_current(original, changed, unknown, receipt)

    def test_foreign_pin_receipt_and_unreceipted_edits_are_rejected(self):
        original = {p: 'pinned' for p in history.PATHS}
        changed = {p: 'generated' for p in history.PATHS}
        unknown = {p: 'unrelated' for p in history.PATHS}
        receipt = {'revision': 'different', 'files': {p: history.digest(v) for p, v in unknown.items()}}
        for prior in [None, receipt]:
            with self.assertRaisesRegex(ValueError, 'Refusing unrelated'):
                history.validate_current(original, changed, unknown, prior)

    def test_ambiguous_source_anchor_is_not_silently_applied(self):
        for source in ['none', 'anchor anchor']:
            with self.assertRaisesRegex(ValueError, 'Missing/ambiguous'):
                history.once(source, 'anchor', 'replacement')

    def test_live_pinned_transform_composes_without_touching_checkout(self):
        source = Path('/Users/takamimarsh/Developer/zacro-chromium/chromium/src')
        if not (source / '.git').exists():
            self.skipTest('Pinned checkout unavailable')
        baseline = history.source_baselines(source)
        generated = history.generated(baseline)
        self.assertEqual(generated, history.generated(baseline))
        current = {p: (source / p).read_text() if (source / p).exists() else '' for p in history.PATHS}
        receipt = source / 'out/zacro-native-history-mirror.json'
        import json
        prior = json.loads(receipt.read_text()) if receipt.exists() else None
        history.validate_current(baseline, generated, current, prior)
        self.assertEqual(set(generated), set(history.PATHS))
        self.assertIn('FlushStateForNativeNavigation', flush.generated(flush.originals(source))['content/common/frame.mojom']
            if hasattr(flush, 'originals') else (ROOT / 'apply_history_flush_adapter.py').read_text())
        # Production transforms preserve separate native SPA identity while
        # retaining Electron's no-extra-Library-visit policy.
        helper = generated['chrome/browser/history/history_tab_helper.cc']
        owner = generated[history.OWNER_CC]
        self.assertNotIn('!navigation_handle->IsSameDocument() &&', helper)
        self.assertIn('result.library_visit = !navigation->IsSameDocument()', owner)
        self.assertIn('ReadNativeExpiringVisits', generated['components/history/core/browser/expire_history_backend.cc'])
        self.assertIn('RecordNativeLegacyDeletion', generated['components/history/core/browser/expire_history_backend.cc'])

if __name__ == '__main__':
    unittest.main()
