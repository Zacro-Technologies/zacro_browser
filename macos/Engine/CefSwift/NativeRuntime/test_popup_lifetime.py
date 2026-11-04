#!/usr/bin/env python3
"""Exercise the exact prepared-popup teardown method under ASan and UBSan."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('popup_anchor', ROOT / 'apply_popup_anchor.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def verify(source_root):
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source_root,
                                       text=True).strip()
    if revision != adapter.PIN:
        raise ValueError('Pinned Chromium sources required')
    originals = {
        path: '' if path in (adapter.HEADER, adapter.SOURCE) else
        subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=source_root, text=True)
        for path in adapter.PATHS
    }
    generated = adapter.generated(originals)
    source = generated[adapter.POPUP_CC]
    if source != (source_root / adapter.POPUP_CC).read_text():
        raise ValueError('Apply the exact current popup generator before testing its method')
    start = source.index('void ExtensionPopup::OnNativeBrowserDidClose(')
    method = source[start:source.index('\n#endif', start)]
    registration = source[source.index('views::BubbleDialogDelegateView::CreateBubble(popup);'):
                          source.index('// Check that the preferred adjustment')]
    guards = [
        registration.index('if (popup->native_anchor_)') < registration.index('browser->RegisterBrowserDidClose('),
        registration.index('IsDeleteScheduled()') < registration.index('browser->RegisterBrowserDidClose('),
        'popup->OnNativeBrowserDidClose(browser);\n      return;' in registration,
        'if (!browser_ || !host_ || !GetWidget()->IsVisible())' in source,
        'void ExtensionPopup::ShowBubble() {\n  if (!browser_ || !host_)' in source,
    ]
    destroy = source[source.index('void ExtensionPopup::OnWidgetDestroying('):
                     source.index('void ExtensionPopup::OnWidgetTreeActivated(')]
    guards.append(destroy.index('native_browser_close_subscription_ = {}') <
                  destroy.index('BubbleDialogDelegateView::OnWidgetDestroying'))
    if not all(guards):
        raise ValueError('Prepared-only registration, accepted-close or callback guard changed')
    fixture = (ROOT / 'popup_lifetime_tests.inc').read_text().replace('// EXACT_PRODUCTION_METHOD', method)
    with tempfile.TemporaryDirectory(prefix='zacro-popup-lifetime-') as temporary:
        source_file = Path(temporary) / 'fixture.cc'
        binary = Path(temporary) / 'fixture'
        source_file.write_text(fixture)
        subprocess.run(['xcrun', 'clang++', '-std=c++20', '-O0', '-g', '-Wall', '-Wextra',
                        '-Werror', '-fsanitize=address,undefined', str(source_file), '-o', str(binary)],
                       check=True, timeout=45)
        result = subprocess.run([str(binary)], capture_output=True, text=True, check=True, timeout=15)
        print(result.stdout, end='')
        print(json.dumps({'sourceGuards': len(guards), 'asanUbsan': 'passed',
                          'actualChromiumCompile': False, 'runtimeAcceptance': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-root', required=True, type=Path)
    args = parser.parse_args()
    verify(args.chromium_root.resolve())
