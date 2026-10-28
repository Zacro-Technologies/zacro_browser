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
      capabilities: () => ({}),
      list: () => [record],
      approve: async () =>
        (record = { ...record, enabled: false, status: 'pending-reload', requiresPageReload: true }),
    },
  });
  const result = await host.handleLocal('extension:approve', { id });
  assert.equal(result.requiresPageReload, true);
  assert.deepEqual(queued, [], 'permission update review is not an explicit library enable/disable');
});

for (const remote of [false, true])
  test(`R8 ${remote ? 'remote' : 'local'} removal warnings survive records and cancelled reloads until document replacement`, async () => {
    const { ExtensionHost } = require('../src/main/extensions/host.cjs');
    const id = 'a'.repeat(32);
    let destroyed = false,
      prompts = 0,
      reloads = 0,
      allowReload = false;
    const entry = {
      profileId: 'p',
      tabId: 'tab',
      documentEpoch: 1,
      contents: { id: 11, isDestroyed: () => destroyed, getTitle: () => 'Draft' },
    };
    const host = Object.assign(Object.create(ExtensionHost.prototype), {
      barriers: new Map(),
      notificationErrors: new Map(),
      remoteRuns: new Map(),
      closeViews: () => {},
      activeProfile: () => ({ id: 'p' }),
      getProfile: () => ({ id: 'p' }),
      getWindow: () => ({}),
      publish: () => {},
      native: {
        dialog: {
          showMessageBox: async () => {
            prompts++;
            return { response: 0 };
          },
        },
      },
      browser: {
        documents: () => [entry],
        reloadDocument: async () => {
          reloads++;
          if (allowReload) entry.documentEpoch++;
        },
      },
    });
    if (remote) host.remoteRuns.set(host.key('p', id), {});
    await host.deactivated({ profileId: 'p', extensionId: id, reason: 'remove' });
    assert.equal(prompts, remote ? 0 : 1);
    assert.equal(host.pendingPageReloads('p').length, 1);
    assert.equal(host.pendingPageReloads('other').length, 0);
    await host.reloadPendingPages('p', { tabId: 'tab' }, () => {});
    assert.equal(reloads, 1);
    assert.equal(host.pendingPageReloads('p').length, 1, 'Stay preserves warning with the old document');
    allowReload = true;
    await host.reloadPendingPages('p', { tabId: 'tab' }, () => {});
    assert.deepEqual(host.pendingPageReloads('p'), []);
    await host.deactivated({ profileId: 'p', extensionId: id, reason: 'remove' });
    destroyed = true;
    assert.deepEqual(host.pendingPageReloads('p'), []);
    assert.equal(host.barriers.size, 0);
  });

for (const successor of [false, true])
  test(`profile change during native activeTab grant revokes only the original generation (successor ${successor})`, async () => {
    const { ExtensionHost } = require('../src/main/extensions/host.cjs');
    let finish, entered;
    const gate = new Promise((resolve) => {
        finish = resolve;
      }),
      start = new Promise((resolve) => {
        entered = resolve;
      });
    let profile = 'p',
      generation = 'original';
    const disabled = [];
    const host = Object.assign(Object.create(ExtensionHost.prototype), {
      activeProfile: () => ({ id: profile }),
      syncClient: () => ({ epoch: 1, guard: () => {} }),
      api: { guard: () => {} },
      manager: {
        capabilities: () => ({ activeTab: true }),
        resolveExtension: () => ({ enabled: true, generation }),
        disable: async (...args) => disabled.push(args),
      },
      getSession: () => ({
        extensions: {
          grantZacroActiveTab: async () => {
            entered();
            await gate;
          },
        },
      }),
      report: () => {},
    });
    const pending = host.grantActiveTab(
      { profileId: 'p', extensionId: 'a'.repeat(32), generation: 'original' },
      7,
    );
    const rejected = assert.rejects(pending, /profile changed/i);
    await start;
    profile = 'other';
    if (successor) generation = 'successor';
    finish();
    await rejected;
    assert.equal(disabled.length, successor ? 0 : 1);
  });

test('trusted local user script control changes only local consent and rejects stale controls', async () => {
  const { ExtensionHost } = require('../src/main/extensions/host.cjs');
  const id = 'a'.repeat(32);
  let record = {
    id,
    profileId: 'p',
    generation: 'g',
    enabled: true,
    status: 'enabled',
    source: { kind: 'local-unpacked' },
    grants: { permissions: ['userScripts'], origins: [] },
    current: {
      manifest: { name: 'Scripts', version: '1', manifest_version: 3, permissions: ['userScripts'] },
      verification: {},
    },
  };
  let writes = 0;
  const host = Object.assign(Object.create(ExtensionHost.prototype), {
    activeProfile: () => ({ id: 'p' }),
    started: Promise.resolve(),
    restore: async () => {},
    intents: () => [],
    publish: () => {},
    syncClient: () => ({
      epoch: 1,
      guard: () => {},
      queueExtension: async () => {
        throw Error('Local consent must not synchronize');
      },
    }),
    operation: (_profile, _id, guard, action) => {
      guard();
      return action();
    },
    manager: {
      capabilities: () => ({ reviewedPermissions: true, userScripts: true }),
      list: () => [record],
      setUserScriptsEnabled: async (profile, extension, enabled) => {
        assert.equal(profile, 'p');
        assert.equal(extension, id);
        writes++;
        record = { ...record, userScriptsEnabled: enabled };
        return record;
      },
    },
  });
  const result = await host.handleLocal('extension:user-scripts-toggle', {
    id,
    profileId: 'p',
    generation: 'g',
  });
  assert.equal(result.userScriptsAvailable, true);
  assert.equal(result.userScriptsEnabled, true);
  assert.equal(result.enabled, true);
  assert.equal(writes, 1);
  await assert.rejects(
    host.handleLocal('extension:user-scripts-toggle', { id, profileId: 'p', generation: 'stale' }),
    /changed/,
  );
  assert.equal(writes, 1);
});

test('tabless snapshots retain default action and current command assignment', () => {
  const { ExtensionHost } = require('../src/main/extensions/host.cjs');
  const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
  const { createBrowserAdapter } = require('../src/main/extensions/browser.cjs');
  const id = 'a'.repeat(32);
  const manifest = {
    manifest_version: 3,
    name: 'Tabless',
    version: '1',
    action: { default_popup: 'popup.html' },
    commands: { hello: { suggested_key: { default: 'Ctrl+Shift+Y' } } },
  };
  const record = {
    id,
    profileId: 'p',
    enabled: true,
    generation: 'g',
    source: { kind: 'local' },
    grants: { permissions: [], origins: [] },
    current: { manifest, verification: {} },
  };
  const { matchShortcut, updateShortcut } = require('../src/core/shortcuts.cjs');
  let overrides = {};
  const api = new ExtensionAPI({
    resolveExtension: () => ({ ...record, manifest }),
    browserShortcutClaimed: (input) => !!matchShortcut(input, process.platform, overrides),
  });
  const browser = createBrowserAdapter({
    store: { state: { tabs: [], activeTabId: null } },
    views: new Map(),
  });
  const host = Object.assign(Object.create(ExtensionHost.prototype), {
    getProfile: () => ({ id: 'p' }),
    intents: () => [],
    manager: { list: () => [record], capabilities: () => ({}) },
    remoteErrors: new Map(),
    notificationErrors: new Map(),
    icon: () => null,
    api,
    browser,
  });
  const value = host.snapshot('p')[0];
  assert.equal(value.action.popup, 'popup.html');
  assert.equal(value.commands[0].status, 'assigned');
  assert.equal(browser.activeTabId('p'), undefined);
  overrides = updateShortcut({}, process.platform, 'sidebar-toggle', 'Mod+Shift+Y');
  assert.equal(host.snapshot('p')[0].commands[0].status, 'conflict');
  overrides = {};
  assert.equal(host.snapshot('p')[0].commands[0].status, 'assigned', 'reset republishes current assignment');
});
