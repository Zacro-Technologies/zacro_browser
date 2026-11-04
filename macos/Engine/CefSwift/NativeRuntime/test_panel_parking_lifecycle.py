#!/usr/bin/env python3
"""Check reserved-tab lifecycle ordering and execute its actual observer methods."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PIN = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'


def verify(source_root, topology, source_only=False):
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source_root, text=True).strip()
    if revision != PIN:
        raise ValueError('Exact pinned Chromium source required')
    source = topology.read_text()
    start = source.index('    void Bind(content::WebContents* contents) {', source.index('  struct Tab :'))
    methods = source[start:source.index('    std::string logical_id;', start)]
    consume = source[source.index('  bool Consume('):source.index('  void Abort(')]
    register = source[source.index('  int Register('):source.index('  bool Validate(')]
    model = (source_root / 'chrome/browser/ui/tabs/tab_model.cc').read_text()
    navigator = (source_root / 'chrome/browser/ui/navigator/browser_navigator.cc').read_text()
    guards = [
        consume.index('sessions::SessionTabHelper::FromWebContents(contents)') < consume.index('tab->second->Bind(contents)'),
        model.index('TabLookupFromWebContents::CreateForWebContents(contents_, this)') < model.index('TabHelpers::AttachTabHelpers(contents_)'),
        navigator.index('WebContents::Create(create_params)') < navigator.index('GetFeatures().OnWebContentsCreated(params.browser,'),
        register.index('tab->web_contents() != contents') < register.index('tab->ObserveTabLifecycle()'),
        register.index('tab->ObserveTabLifecycle()') < register.index('ReconcileGlobalPanels()'),
        'base::WeakPtr<tabs::TabInterface> observed_tab;' in source,
    ]
    if not all(guards):
        raise ValueError('Native creation order or exact materialized-document registration guard changed')
    print(json.dumps({'sourceGuards': len(guards), 'passed': True}))
    if source_only:
        print('Native method fixture explicitly skipped; no compile was requested')
        return
    fixture = (ROOT / 'panel_parking_lifecycle_tests.inc').read_text().replace('// EXACT_PRODUCTION_METHODS', methods)
    with tempfile.TemporaryDirectory(prefix='zacro-panel-parking-') as temporary:
        source_file = Path(temporary) / 'fixture.cc'
        binary = Path(temporary) / 'fixture'
        source_file.write_text(fixture)
        subprocess.run(['xcrun', 'clang++', '-std=c++20', '-O0', '-g', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', str(source_file), '-o', str(binary)], check=True, timeout=45)
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=15)
        print(result.stdout, end='')
        print(json.dumps({'asanUbsan': 'passed', 'actualChromiumCompile': False, 'runtimeAcceptance': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-root', required=True, type=Path)
    parser.add_argument('--topology-source', type=Path, default=ROOT / 'devtools_topology_adapter.inc')
    parser.add_argument('--source-only', action='store_true')
    args = parser.parse_args()
    verify(args.chromium_root.resolve(), args.topology_source.resolve(), args.source_only)
