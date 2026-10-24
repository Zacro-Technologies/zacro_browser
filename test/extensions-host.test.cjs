'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { publicRecord, inputShortcut } = require('../src/main/extensions/host.cjs');

test('extension UI projection exposes provenance and grants without executable paths or package internals', () => {
  const record = {
    id: 'a'.repeat(32),
    profileId: 'default',
    enabled: false,
    status: 'pending-approval',
    generation: 'native-generation',
    source: { kind: 'chrome-web-store', id: 'a'.repeat(32), path: '/secret' },
    grants: { permissions: [], origins: [] },
    pending: {
      token: 'disk-path-token',
      legacyPath: '/secret',
      manifest: { name: 'Fixture', version: '1', description: 'Example' },
      inspection: {
        compatible: true,
        required: { permissions: ['storage'], origins: [] },
        optional: { permissions: [], origins: [] },
        unsupported: [],
      },
      verification: { signatureVerified: true, publisherVerified: true },
      sha256: 'package-hash',
      transformVersion: 3,
    },
  };
  const value = publicRecord(record);
  assert.equal(value.name, 'Fixture');
  assert.equal(value.source, 'chrome-web-store');
  assert.equal(value.publisherVerified, true);
  assert.deepEqual(value.requested.permissions, ['storage']);
  for (const secret of ['/secret', 'disk-path-token', 'legacyPath'])
    assert.equal(JSON.stringify(value).includes(secret), false);
});

test('native shortcut normalization preserves exact modifiers and ignores non-keydown events', () => {
  assert.equal(inputShortcut({ type: 'keyDown', key: 'y', meta: true, shift: true }), 'Command+Shift+Y');
  assert.equal(inputShortcut({ type: 'keyDown', key: 'y', control: true, alt: true }), 'Ctrl+Alt+Y');
  assert.equal(inputShortcut({ type: 'keyUp', key: 'y', meta: true }), null);
});

test('extension controls expose narrower optional grants for revocation even during update review', () => {
  const record = {
    id: 'a'.repeat(32),
    profileId: 'default',
    enabled: true,
    status: 'pending-approval',
    source: { kind: 'chrome-web-store' },
    grants: {
      permissions: ['storage', 'tabs'],
      origins: ['https://required.test/*', 'https://chosen.test/*'],
    },
    current: {
      manifest: {
        manifest_version: 3,
        name: 'Optional host fixture',
        version: '1',
        permissions: ['storage'],
        optional_permissions: ['tabs'],
        host_permissions: ['https://required.test/*'],
        optional_host_permissions: ['https://*/*'],
      },
      verification: {},
    },
    pending: {
      manifest: { manifest_version: 3, name: 'Update fixture', version: '2', permissions: ['storage'] },
      verification: {},
    },
  };
  assert.deepEqual(publicRecord(record).revocable, {
    permissions: ['tabs'],
    origins: ['https://chosen.test/*'],
  });
});

test('approving an update that waits for page reload does not publish a user disable intent', async () => {
  const { ExtensionHost } = require('../src/main/extensions/host.cjs');
  const id = 'a'.repeat(32),
    queued = [];
  let record = {
    id,
    profileId: 'default',
    enabled: true,
    status: 'pending-approval',
    source: { kind: 'chrome-web-store' },
    grants: { permissions: ['storage'], origins: [] },
    current: {
      manifest: { manifest_version: 3, name: 'Fixture', version: '1', permissions: ['storage'] },
      verification: {},
    },
  };
  const host = Object.assign(Object.create(ExtensionHost.prototype), {
    activeProfile: () => ({ id: 'default' }),
    started: Promise.resolve(),
    restore: async () => {},
    intents: () => [],
    publish: () => {},
    syncClient: () => ({ epoch: 1, guard: () => {}, queueExtension: async (value) => queued.push(value) }),
    operation: (_profile, _id, guard, action) => {
      guard();
      return action();
    },
    manager: {
      list: () => [record],
      approve: async () =>
        (record = { ...record, enabled: false, status: 'pending-reload', requiresPageReload: true }),
    },
  });
  const result = await host.handleLocal('extension:approve', { id });
  assert.equal(result.requiresPageReload, true);
  assert.deepEqual(queued, [], 'permission update review is not an explicit library enable/disable');
});
