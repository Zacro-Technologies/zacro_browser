'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { inspectManifest } = require('../src/main/extensions/catalog.cjs');
test('offscreen remains unavailable to MV2 packages', () => {
  assert.equal(
    inspectManifest({ manifest_version: 2, name: 'MV2', version: '1', permissions: ['offscreen'] })
      .compatible,
    false,
  );
});
test('native static ruleset reconciliation retains choices and applies defaults only to new IDs', () => {
  const { reconcileRulesets } = require('../src/main/extensions/native-services.cjs');
  const resources = [
    { id: 'kept', enabled: true },
    { id: 'disabled', enabled: true },
    { id: 'new', enabled: true },
    { id: 'new-off', enabled: false },
  ];
  assert.deepEqual(
    reconcileRulesets(resources, {
      knownRulesets: ['kept', 'disabled', 'removed'],
      enabledRulesets: ['kept', 'removed'],
    }),
    ['kept', 'new'],
  );
  assert.deepEqual(reconcileRulesets(resources, null), ['kept', 'disabled', 'new']);
});
test('native ruleset resources accept one extension-root slash without changing the path', () => {
  for (const path of [
    'rules.json',
    'rulesets/main/easylist.json',
    '/rules.json',
    '/rulesets/main/easylist.json',
  ]) {
    const manifest = {
      manifest_version: 3,
      name: 'Native',
      version: '1',
      permissions: ['declarativeNetRequest'],
      declarative_net_request: { rule_resources: [{ id: 'rules', enabled: true, path }] },
    };
    assert.equal(inspectManifest(manifest).compatible, true, path);
    assert.equal(manifest.declarative_net_request.rule_resources[0].path, path);
  }
});
test('native ruleset resources reject ambiguous IDs and paths before installation', () => {
  const manifest = {
    manifest_version: 3,
    name: 'Native',
    version: '1',
    permissions: ['declarativeNetRequest'],
  };
  for (const path of [
    '../rules.json',
    '/../rules.json',
    '/rules/../rules.json',
    '/rules/./rules.json',
    '//rules.json',
    '//foreign/rules.json',
    '/',
    '',
    '/rules//rules.json',
    '/rules/',
    'https://foreign/rules.json',
    'chrome-extension://foreign/rules.json',
    'rules.json?x',
    '/rules.json#fragment',
    '/rules/%2e%2e/rules.json',
    '/rules%2frules.json',
    '/rules\u0000.json',
    '/rules\n.json',
    '/rules .json',
    '/rules\u007f.json',
    'rules\\evil.json',
    '/rules\\evil.json',
  ])
    assert.throws(
      () =>
        inspectManifest({
          ...manifest,
          declarative_net_request: { rule_resources: [{ id: 'rules', enabled: true, path }] },
        }),
      /Invalid declarative_net_request/,
      JSON.stringify(path),
    );
  assert.throws(
    () =>
      inspectManifest({
        ...manifest,
        declarative_net_request: {
          rule_resources: [
            { id: 'rules', enabled: true, path: 'rules.json' },
            { id: 'rules', enabled: false, path: 'second.json' },
          ],
        },
      }),
    /Invalid declarative_net_request/,
  );
});
