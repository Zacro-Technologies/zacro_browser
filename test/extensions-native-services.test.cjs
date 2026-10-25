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
test('native ruleset resources reject ambiguous IDs and paths before installation', () => {
  const manifest = {
    manifest_version: 3,
    name: 'Native',
    version: '1',
    permissions: ['declarativeNetRequest'],
  };
  for (const path of [
    '../rules.json',
    '/rules.json',
    'https://foreign/rules.json',
    'rules.json?x',
    'rules\\evil.json',
  ])
    assert.throws(
      () =>
        inspectManifest({
          ...manifest,
          declarative_net_request: { rule_resources: [{ id: 'rules', enabled: true, path }] },
        }),
      /Invalid declarative_net_request/,
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
