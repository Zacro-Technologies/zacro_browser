'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
const { inspectManifest } = require('../src/main/extensions/catalog.cjs');
test('sidePanel facade routes through guarded trusted extension ownership', async () => {
  const metadata = { enabled: true, generation: 'g', manifest: {}, grants: { permissions: ['sidePanel'] } };
  const calls = [];
  const api = new ExtensionAPI({
    resolveExtension: () => metadata,
    sidePanel: {
      call: async (context, name, args) => {
        calls.push([context.extensionId, name, args]);
        return { side: 'right' };
      },
    },
  });
  const context = api.context('one', 'a'.repeat(32));
  assert.deepEqual(await api.call(context, 'sidePanel.getLayout', []), { side: 'right' });
  assert.equal(calls.length, 1);
  await assert.rejects(
    api.call({ ...context, kind: 'content-script' }, 'sidePanel.open', [{ windowId: 1 }]),
    /Trusted/,
  );
  metadata.grants.permissions = [];
  await assert.rejects(api.call(context, 'sidePanel.getOptions', [{}]), /sidePanel permission/);
});
test('side_panel manifest validates packaged paths and sidePanel permission is supported', () => {
  const manifest = {
    manifest_version: 3,
    name: 'Panel',
    version: '1',
    permissions: ['sidePanel'],
    side_panel: { default_path: 'panel.html' },
  };
  assert.equal(inspectManifest(manifest).compatible, true);
  for (const value of ['../bad', 'https://bad/x', 'zacro-compat-transport.html'])
    assert.throws(
      () => inspectManifest({ ...manifest, side_panel: { default_path: value } }),
      /side panel resource/,
    );
});
test('action behavior opens the side panel through a real host gesture without activeTab access', async () => {
  const metadata = {
    enabled: true,
    generation: 'g',
    manifest: { action: {} },
    grants: { permissions: ['sidePanel'], origins: [] },
  };
  const calls = [],
    panels = {
      recordGesture: (c) => calls.push(['gesture', c.extensionId]),
      call: async (_c, name, args) => {
        calls.push([name, args]);
        if (name === 'getPanelBehavior') return { openPanelOnActionClick: true };
      },
    };
  const api = new ExtensionAPI({
    resolveExtension: () => metadata,
    sidePanel: panels,
    tabs: { get: (_p, id) => ({ id, windowId: 1, url: 'https://example.test/' }) },
    emit: () => {
      throw Error('Action onClicked should not also fire');
    },
  });
  await api.activateAction('one', 'a'.repeat(32), 10);
  assert.deepEqual(
    calls.map((c) => c[0]),
    ['gesture', 'getPanelBehavior', 'open'],
  );
  assert.equal(api.state(api.context('one', 'a'.repeat(32))).active.size, 0);
});
