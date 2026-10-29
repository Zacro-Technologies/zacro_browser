'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { randomBytes, createCipheriv, createDecipheriv } = require('node:crypto');
const { createSyncService } = require('../services/sync/server.cjs');
const { SyncClient } = require('../src/main/sync/client.cjs');
const extensionId = 'a'.repeat(32),
  otherExtensionId = 'b'.repeat(32);
const password = 'Synthetic desktop account password';
function protection() {
  const key = randomBytes(32);
  return {
    protect(text) {
      const iv = randomBytes(12),
        c = createCipheriv('aes-256-gcm', key, iv);
      return Buffer.concat([iv, c.update(text), c.final(), c.getAuthTag()]);
    },
    unprotect(bytes) {
      const c = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
      c.setAuthTag(bytes.subarray(-16));
      return Buffer.concat([c.update(bytes.subarray(12, -16)), c.final()]).toString();
    },
  };
}
async function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-sync-client-'));
  const serviceOptions = {
    directory: path.join(root, 'service'),
    masterKey: randomBytes(32),
    allowInsecureLoopback: true,
  };
  let service = await createSyncService(serviceOptions);
  const clients = [],
    stores = [],
    events = [],
    libraries = [];
  const make = (name) => {
    const options = {
      directory: path.join(root, name),
      ...protection(),
      allowInsecureLoopback: true,
      autoSync: false,
      onStorageChange: (e) => events.push({ name, ...e }),
      onLibraryChange: (e) => libraries.push({ name, ...e }),
    };
    const c = new SyncClient(options);
    clients.push(c);
    stores.push(options);
    return c;
  };
  const a = make('a'),
    b = make('b');
  await a.configure({ endpoint: service.url });
  await b.configure({ endpoint: service.url });
  const registration = await a.register({
    username: 'desktop.test',
    password,
    deviceName: 'Device A',
    platform: 'test',
  });
  await b.login({ username: 'desktop.test', password, deviceName: 'Device B', platform: 'test' });
  const dataset = await a.createDataset('Personal');
  const link = (c, profileId = 'normal', settingsSync = true) =>
    c.linkProfile({
      profileId,
      datasetId: dataset.id,
      libraryChoice: 'remote-only',
      settingsSync,
      settingsChoice: settingsSync ? 'use-remote' : undefined,
      settingsConsent: settingsSync,
    });
  const ctx = (id = extensionId, profileId = 'normal') => ({
    profileId,
    extensionId: id,
    permissions: ['storage'],
    trusted: true,
    enabled: true,
    private: false,
  });
  t.after(async () => {
    for (const c of clients) c.close();
    await service.close();
    fs.rmSync(root, { recursive: true, force: true });
  });
  return {
    root,
    a,
    b,
    registration,
    dataset,
    link,
    ctx,
    stores,
    clients,
    events,
    libraries,
    get service() {
      return service;
    },
    async restartService() {
      const port = new URL(service.url).port;
      await service.close();
      service = await createSyncService({ ...serviceOptions, port: Number(port) });
    },
    async offline() {
      await service.close();
    },
    restartClient(index) {
      clients[index].close();
      clients[index] = new SyncClient(stores[index]);
      return clients[index];
    },
  };
}
test('real clients authenticate with a protected vault and converge library and settings through the real service', async (t) => {
  const f = await fixture(t);
  assert.equal(f.registration.recoveryCodes.length, 10);
  assert.equal(f.registration.accessToken, undefined);
  await f.link(f.a);
  await f.link(f.b);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.syncNow();
  await f.b.syncNow();
  assert.ok(
    f.libraries.some(
      (e) => e.name === 'b' && e.extension.extensionId === extensionId && e.extension.state === 'enabled',
    ),
  );
  await f.a.callStorage(f.ctx(), 'set', [{ theme: 'dark', mine: 1 }]);
  await f.a.syncNow();
  await f.b.syncNow();
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { theme: 'dark', mine: 1 });
  assert.ok(
    f.events.some((e) => e.name === 'b' && e.changes.theme?.newValue === 'dark' && e.area === 'sync'),
  );
  const status = JSON.stringify(f.a.status());
  assert.equal(/accessToken|refreshToken|recoveryCodes|password/.test(status), false);
  for (const name of fs.readdirSync(path.join(f.root, 'a'))) {
    const bytes = fs.readFileSync(path.join(f.root, 'a', name));
    assert.equal(bytes.includes(Buffer.from(password)), false);
    assert.equal(bytes.includes(Buffer.from(f.registration.recoveryCodes[0])), false);
  }
  const resumed = f.restartClient(0);
  await resumed.syncNow();
  assert.equal(resumed.status().account.username, 'desktop.test');
  assert.deepEqual(await resumed.callStorage(f.ctx(), 'get', []), { theme: 'dark', mine: 1 });
});
test('offline writes and duplicate-safe outbox survive client and service restart; independent keys merge', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.syncNow();
  await f.b.syncNow();
  await f.offline();
  await f.a.callStorage(f.ctx(), 'set', [{ fromA: 1 }]);
  await f.b.callStorage(f.ctx(), 'set', [{ fromB: 2 }]);
  await f.a.syncNow();
  assert.equal(f.a.status().state, 'offline');
  const resumed = f.restartClient(0);
  assert.equal(resumed.status().profiles[0].pending, 1);
  await f.restartService();
  await resumed.syncNow();
  await f.b.syncNow();
  await resumed.syncNow();
  assert.deepEqual(await resumed.callStorage(f.ctx(), 'get', []), { fromA: 1, fromB: 2 });
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { fromA: 1, fromB: 2 });
  assert.equal(resumed.status().profiles[0].pending, 0);
});
test('settings consent, unlinked namespaces and device revocation stop sharing while preserving local data', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b, 'normal', false);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.syncNow();
  await f.b.syncNow();
  await f.a.callStorage(f.ctx(), 'set', [{ remote: true }]);
  await f.b.callStorage(f.ctx(), 'set', [{ local: true }]);
  await f.a.syncNow();
  await f.b.syncNow();
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { local: true });
  await assert.rejects(
    f.b.linkProfile({
      profileId: 'normal',
      datasetId: f.dataset.id,
      libraryChoice: 'remote-only',
      settingsSync: true,
      settingsChoice: 'use-remote',
    }),
    /consent/i,
  );
  await f.link(f.b);
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { remote: true });
  await f.b.unlinkProfile('normal');
  await f.b.callStorage(f.ctx(), 'set', [{ independent: true }]);
  await f.b.syncNow();
  await f.a.syncNow();
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { remote: true });
  await f.link(f.b);
  const devices = await f.a.devices();
  await f.a.revokeDevice(devices.find((d) => d.name === 'Device B').id);
  await f.b.syncNow();
  assert.equal(f.b.status().state, 'reconnect-required');
  assert.equal(f.b.status().account, null);
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { remote: true });
});
test('private and unauthorized extension callers cannot access storage or link, and unsafe endpoints fail closed', async (t) => {
  const f = await fixture(t);
  await assert.rejects(f.a.callStorage({ ...f.ctx(), private: true }, 'get', []), /private|denied/i);
  await assert.rejects(f.a.callStorage({ ...f.ctx(), permissions: [] }, 'set', [{ a: 1 }]), /permission/i);
  await assert.rejects(f.a.callStorage({ ...f.ctx(), enabled: false }, 'get', []), /disabled|denied/i);
  for (const endpoint of [
    'http://example.com',
    'https://user:pass@example.com',
    'https://example.com/path',
    'file:///tmp/secret',
  ])
    await assert.rejects(f.a.configure({ endpoint }), /endpoint|HTTPS/i);
  const unavailable = new SyncClient({
    directory: path.join(f.root, 'no-vault'),
    autoSync: false,
    allowInsecureLoopback: true,
  });
  f.clients.push(unavailable);
  await unavailable.configure({ endpoint: f.service.url });
  await assert.rejects(
    unavailable.login({ username: 'desktop.test', password, deviceName: 'Unsafe', platform: 'test' }),
    /protect|credential/i,
  );
});

test('unlink and endpoint changes invalidate in-flight link responses before they publish state', async (t) => {
  const f = await fixture(t);
  let release, arrived;
  const gate = new Promise((r) => {
      release = r;
    }),
    seen = new Promise((r) => {
      arrived = r;
    });
  f.a.fetch = async (...args) => {
    const response = await fetch(...args);
    if (args[0].includes('/snapshot')) {
      arrived();
      await gate;
    }
    return response;
  };
  const pending = f.link(f.a);
  await seen;
  await f.a.unlinkProfile('normal');
  release();
  await assert.rejects(pending, /context changed/i);
  assert.equal(f.a.status().profiles.length, 0);
  await f.a.configure({ endpoint: 'https://sync.example.invalid' });
  assert.equal(f.a.status().account, null);
  assert.equal(f.a.status().profiles.length, 0);
});
test('quota rejection preserves unsynced values for export and retry, and stale generations cannot resurrect removals', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b);
  const item = {
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  };
  await f.a.queueExtension(item);
  await f.a.syncNow();
  await f.b.syncNow();
  const a = Object.fromEntries(Array.from({ length: 12 }, (_, i) => ['a' + i, 'a'.repeat(4000)]));
  const b = Object.fromEntries(Array.from({ length: 12 }, (_, i) => ['b' + i, 'b'.repeat(5000)]));
  await f.a.callStorage(f.ctx(), 'set', [a]);
  await f.b.callStorage(f.ctx(), 'set', [b]);
  await f.a.syncNow();
  await f.b.syncNow();
  const rejected = f.b.status().profiles[0].rejected;
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].code, 'storage_quota');
  assert.equal((await f.b.callStorage(f.ctx(), 'get', [])).b0, b.b0);
  assert.equal(f.b.exportRejected('normal', rejected[0].id).payload.set.b0, b.b0);
  await f.a.callStorage(f.ctx(), 'clear', []);
  await f.a.syncNow();
  await f.b.syncNow();
  await f.b.retryRejected('normal', rejected[0].id);
  await f.b.syncNow();
  await f.a.syncNow();
  assert.equal(f.b.status().profiles[0].rejected.length, 0);
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), b);
  await f.b.queueExtension({ ...item, state: 'disabled' });
  await f.a.queueExtension({ ...item, state: 'removed' });
  await f.a.syncNow();
  await f.b.syncNow();
  assert.equal(f.b.status().profiles[0].rejected[0].code, 'removed');
  await f.b.discardRejected('normal', f.b.status().profiles[0].rejected[0].id);
  await f.b.queueExtension(item);
  await f.b.syncNow();
  await f.a.syncNow();
  assert.equal(f.b.status().profiles[0].rejected.length, 0);
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), {});
});

test('large offline outboxes use bounded batches and a lost acknowledgement retries the same operation safely', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.syncNow();
  await f.b.syncNow();
  for (let n = 0; n < 14; n++)
    await f.a.callStorage(f.ctx(), 'set', [
      Object.fromEntries(
        Array.from({ length: 12 }, (_, i) => ['k' + i, String.fromCharCode(65 + n).repeat(8000)]),
      ),
    ]);
  const sizes = [];
  f.a.fetch = async (url, options) => {
    if (url.endsWith('/operations')) sizes.push(Buffer.byteLength(options.body));
    return fetch(url, options);
  };
  await f.a.syncNow();
  assert.equal(f.a.status().profiles[0].pending, 0);
  assert.ok(sizes.length > 1);
  assert.ok(sizes.every((size) => size <= 512 * 1024));
  await f.b.syncNow();
  await f.a.callStorage(f.ctx(), 'remove', ['k0']);
  let lost = false;
  f.a.fetch = async (url, options) => {
    const response = await fetch(url, options);
    if (url.endsWith('/operations') && !lost) {
      lost = true;
      await response.arrayBuffer();
      throw new Error('Synthetic lost response after server commit');
    }
    return response;
  };
  await f.a.syncNow();
  assert.equal(f.a.status().profiles[0].pending, 1);
  const resumed = f.restartClient(0);
  await resumed.syncNow();
  await f.b.syncNow();
  assert.equal(resumed.status().profiles[0].pending, 0);
  assert.equal(Object.hasOwn(await f.b.callStorage(f.ctx(), 'get', []), 'k0'), false);
  assert.equal(
    f.events.filter((e) => e.name === 'b' && e.changes.k0 && !Object.hasOwn(e.changes.k0, 'newValue')).length,
    1,
  );
});
test('trusted-only storage access survives linking and unlinking and also filters event eligibility', async (t) => {
  const f = await fixture(t);
  await f.a.callStorage(f.ctx(), 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }]);
  await f.link(f.a);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await assert.rejects(f.a.callStorage({ ...f.ctx(), trusted: false }, 'get', []), /access/i);
  assert.equal(f.a.canAccessStorage({ ...f.ctx(), trusted: false }), false);
  await f.a.unlinkProfile('normal');
  await assert.rejects(f.a.callStorage({ ...f.ctx(), trusted: false }, 'get', []), /access/i);
  assert.equal(f.a.canAccessStorage(f.ctx()), true);
});

test('account switching separates local settings and never replays another account outbox', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.callStorage(f.ctx(), 'set', [{ accountOnly: 'first-account' }]);
  await f.a.register({ username: 'second.desktop', password, deviceName: 'Other account', platform: 'test' });
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), {});
  assert.equal(f.a.status().profiles.length, 0);
  await f.a.callStorage(f.ctx(), 'set', [{ secondOnly: true }]);
  await f.a.login({ username: 'desktop.test', password, deviceName: 'Return', platform: 'test' });
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { accountOnly: 'first-account' });
  assert.equal(f.a.status().profiles.length, 0);
});
test('turning off settings sync keeps library operations queued and preserves local settings offline', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.callStorage(f.ctx(), 'set', [{ localAfterOptOut: true }]);
  await f.offline();
  await f.a.setSettingsSync('normal', false);
  assert.equal(f.a.status().profiles[0].pending, 1);
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { localAfterOptOut: true });
  await f.restartService();
  await f.a.syncNow();
  await f.b.syncNow();
  assert.ok(
    f.libraries.some((e) => e.name === 'b' && e.extension.extensionId === extensionId),
    JSON.stringify({ a: f.a.status(), b: f.b.status() }),
  );
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), {});
});

const portable = (state = 'enabled', id = extensionId) => ({
  extensionId: id,
  source: { kind: 'web-store', id },
  state,
});
async function linkedPair(t) {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b);
  await f.a.queueExtension({ profileId: 'normal', ...portable() });
  await f.a.syncNow();
  await f.b.syncNow();
  return f;
}
test('settings-only links never upload or project library intent and survive restart', async (t) => {
  const f = await linkedPair(t);
  await f.b.unlinkProfile('normal');
  f.libraries.length = 0;
  await f.b.linkProfile({
    profileId: 'normal',
    datasetId: f.dataset.id,
    librarySync: false,
    libraryChoice: 'merge-local',
    localLibrary: [portable('enabled', otherExtensionId)],
    settingsSync: true,
    settingsChoice: 'use-remote',
    settingsConsent: true,
  });
  assert.equal(f.b.status().profiles[0].librarySync, false);
  assert.deepEqual(f.b.extensionIntents('normal'), []);
  assert.equal(f.libraries.filter((e) => e.name === 'b').length, 0);
  await f.b.queueExtension({ profileId: 'normal', ...portable('removed') });
  await f.b.callStorage(f.ctx(), 'set', [{ onlySettings: true }]);
  await f.b.syncNow();
  await f.a.syncNow();
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { onlySettings: true });
  assert.equal(f.a.extensionIntents('normal')[0].extension.state, 'enabled');
  assert.equal(f.a.extensionIntents('normal').length, 1);
  await f.a.queueExtension({ profileId: 'normal', ...portable('disabled') });
  await f.a.syncNow();
  const resumed = f.restartClient(1);
  await resumed.syncNow();
  assert.equal(resumed.status().profiles[0].librarySync, false);
  assert.equal(f.libraries.filter((e) => e.name === 'b').length, 0);
  await resumed.setSettingsSync('normal', false);
  await resumed.setSettingsSync('normal', true, { settingsChoice: 'use-remote', settingsConsent: true });
  assert.equal(resumed.status().profiles[0].librarySync, false);
  assert.equal(f.libraries.filter((e) => e.name === 'b').length, 0);
});
test('library pause cancels only library operations; resume retains pending settings and access control', async (t) => {
  const f = await linkedPair(t);
  await f.b.queueExtension({ profileId: 'normal', ...portable('disabled') });
  await f.b.callStorage(f.ctx(), 'set', [{ pending: 'keep' }]);
  await f.b.callStorage(f.ctx(), 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }]);
  const oldIdentity = f.b.extensionIntents('normal')[0];
  await f.b.setLibrarySync('normal', false);
  assert.equal(f.b.isCurrentLink(oldIdentity), false);
  assert.equal(f.b.status().profiles[0].settingsSync, true);
  assert.equal(f.b.status().profiles[0].pending, 1);
  await f.b.setLibrarySync('normal', true, { libraryChoice: 'remote-only' });
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { pending: 'keep' });
  await assert.rejects(f.b.callStorage({ ...f.ctx(), trusted: false }, 'get', []), /access/i);
  await f.b.syncNow();
  await f.a.syncNow();
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { pending: 'keep' });
  assert.equal(f.a.extensionIntents('normal')[0].extension.state, 'enabled');
});
test('library resume merges local intent only after review and preserves rejected settings', async (t) => {
  const f = await linkedPair(t);
  // Real independent writes fit locally, but their merged total exceeds server quota.
  await f.a.callStorage(f.ctx(), 'set', [
    Object.fromEntries(Array.from({ length: 8 }, (_, i) => ['a' + i, 'a'.repeat(7900)])),
  ]);
  await f.b.callStorage(f.ctx(), 'set', [
    Object.fromEntries(Array.from({ length: 8 }, (_, i) => ['b' + i, 'b'.repeat(7900)])),
  ]);
  await f.a.syncNow();
  await f.b.syncNow();
  const rejected = f.b.status().profiles[0].rejected;
  assert.equal(rejected[0].code, 'storage_quota');
  await f.b.setLibrarySync('normal', false);
  await assert.rejects(f.b.setLibrarySync('normal', true), /review|choose/i);
  await f.b.setLibrarySync('normal', true, {
    libraryChoice: 'merge-local',
    localLibrary: [portable('disabled')],
  });
  assert.deepEqual(f.b.status().profiles[0].rejected, rejected);
  assert.equal((await f.b.callStorage(f.ctx(), 'get', ['b0'])).b0, 'b'.repeat(7900));
  await f.b.syncNow();
  await f.a.syncNow();
  assert.equal(f.a.extensionIntents('normal')[0].extension.state, 'disabled');
});
test('library pause retains settings of an addition cancelled before cloud installation', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.a.queueExtension({ profileId: 'normal', ...portable() });
  await f.a.callStorage(f.ctx(), 'set', [{ notLost: true }]);
  await f.a.setLibrarySync('normal', false);
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { notLost: true });
  await f.a.syncNow();
  assert.equal(
    (await f.a.previewLink({ profileId: 'normal', datasetId: f.dataset.id })).extensions.length,
    0,
  );
  await f.a.setLibrarySync('normal', true, { libraryChoice: 'merge-local', localLibrary: [portable()] });
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { notLost: true });
  await f.a.syncNow();
  await f.link(f.b);
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { notLost: true });
});
test('paused library still processes tombstones without installing/removing local extensions', async (t) => {
  const f = await linkedPair(t);
  await f.b.setLibrarySync('normal', false);
  await f.b.callStorage(f.ctx(), 'set', [{ stale: true }]);
  f.libraries.length = 0;
  await f.a.queueExtension({ profileId: 'normal', ...portable('removed') });
  await f.a.syncNow();
  await f.b.syncNow();
  await f.b.callStorage(f.ctx(), 'set', [{ nowLocal: true }]);
  await f.b.syncNow();
  assert.equal(f.libraries.filter((e) => e.name === 'b').length, 0);
  await f.a.queueExtension({ profileId: 'normal', ...portable() });
  await f.a.syncNow();
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), {});
  assert.equal(f.b.status().profiles[0].librarySync, false);
});
for (const replace of [false, true])
  test(`paused cloud ${replace ? 'generation replacement' : 'removal'} retains local settings and trusted-only access`, async (t) => {
    const f = await linkedPair(t);
    await f.b.callStorage(f.ctx(), 'set', [{ secret: 'local installation survives' }]);
    await f.b.callStorage(f.ctx(), 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }]);
    await f.b.syncNow();
    await f.b.setLibrarySync('normal', false);
    await f.a.queueExtension({ profileId: 'normal', ...portable('removed') });
    await f.a.syncNow();
    if (replace) {
      await f.a.queueExtension({ profileId: 'normal', ...portable() });
      await f.a.syncNow();
    }
    await f.b.syncNow();
    assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { secret: 'local installation survives' });
    await f.b.setLibrarySync('normal', false);
    assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { secret: 'local installation survives' });
    assert.equal(f.b.canAccessStorage({ ...f.ctx(), trusted: false }), false);
    await f.b.callStorage(f.ctx(), 'set', [{ secret: 'new local secret' }]);
    await assert.rejects(f.b.callStorage({ ...f.ctx(), trusted: false }, 'get', []), /access/i);
    await f.b.syncNow();
    await f.a.syncNow();
    assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), {});
  });
test('resuming a cancelled reinstall preserves independent settings instead of tombstone emptiness', async (t) => {
  const f = await linkedPair(t);
  await f.a.queueExtension({ profileId: 'normal', ...portable('removed') });
  await f.a.syncNow();
  await f.a.queueExtension({ profileId: 'normal', ...portable() });
  await f.a.callStorage(f.ctx(), 'set', [{ reinstallSettings: 'must survive' }]);
  await f.a.callStorage(f.ctx(), 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }]);
  await f.a.setLibrarySync('normal', false);
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { reinstallSettings: 'must survive' });
  await f.a.setLibrarySync('normal', true, { libraryChoice: 'merge-local', localLibrary: [portable()] });
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { reinstallSettings: 'must survive' });
  assert.equal(f.a.canAccessStorage({ ...f.ctx(), trusted: false }), false);
  await f.a.syncNow();
  await f.b.syncNow();
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { reinstallSettings: 'must survive' });
});
test('legacy links default library on without rewriting unrelated profile state', async (t) => {
  const f = await linkedPair(t);
  f.a.store.transaction((s) => {
    delete s.links.normal.librarySync;
  });
  const resumed = f.restartClient(0);
  assert.equal(resumed.status().profiles[0].librarySync, true);
  assert.equal(resumed.extensionIntents('normal').length, 1);
});
test('library opt-out invalidates a delayed remote library response and host identity', async (t) => {
  const f = await linkedPair(t);
  await f.a.queueExtension({ profileId: 'normal', ...portable('removed') });
  await f.a.syncNow();
  const entered = gate(),
    release = gate();
  f.b.fetch = async (url, options) => {
    const response = await fetch(url, options);
    if (url.includes('/changes?')) {
      entered.resolve();
      await release.promise;
    }
    return response;
  };
  const old = f.b.extensionIntents('normal')[0];
  const pending = f.b.syncNow();
  await entered.promise;
  await f.b.setLibrarySync('normal', false);
  f.libraries.length = 0;
  release.resolve();
  await pending;
  assert.equal(f.b.isCurrentLink(old), false);
  assert.equal(f.libraries.filter((e) => e.name === 'b').length, 0);
  assert.equal(f.b.status().profiles[0].settingsSync, true);
});
test('a delayed library re-enable cannot override a newer settings or library choice', async (t) => {
  const f = await linkedPair(t);
  await f.b.setLibrarySync('normal', false);
  const entered = gate(),
    release = gate();
  f.b.fetch = async (url, options) => {
    const response = await fetch(url, options);
    if (url.includes('/snapshot?')) {
      entered.resolve();
      await release.promise;
    }
    return response;
  };
  const pending = assert.rejects(
    f.b.setLibrarySync('normal', true, { libraryChoice: 'remote-only' }),
    /changed|abort/i,
  );
  await entered.promise;
  await f.b.setSettingsSync('normal', false);
  release.resolve();
  await pending;
  const current = f.b.status().profiles[0];
  assert.equal(current.settingsSync, false);
  assert.equal(current.librarySync, false);
});

test('client stale clear preserves unseen remote keys and cloud deletion detaches without recreating a dataset', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.link(f.b);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.callStorage(f.ctx(), 'set', [{ known: true }]);
  await f.a.syncNow();
  await f.b.syncNow();
  await f.b.callStorage(f.ctx(), 'clear', []);
  await f.a.callStorage(f.ctx(), 'set', [{ unseen: 'keep' }]);
  await f.a.syncNow();
  await f.b.syncNow();
  await f.a.syncNow();
  assert.deepEqual(await f.a.callStorage(f.ctx(), 'get', []), { unseen: 'keep' });
  await f.b.callStorage(f.ctx(), 'set', [{ retainLocally: true }]);
  await f.a.deleteDataset(f.dataset.id, password, true);
  await f.b.syncNow();
  assert.equal(f.b.status().profiles.length, 0);
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { unseen: 'keep', retainLocally: true });
  assert.deepEqual(await f.b.datasets(), []);
});
test('expired access credentials rotate through the real refresh endpoint without entering snapshots', async (t) => {
  const f = await fixture(t);
  const before = f.a.credentials.refreshToken;
  f.a.credentials.expiresAt = Date.now() - 1;
  await f.a.syncNow();
  assert.equal(f.a.status().state, 'connected');
  assert.notEqual(f.a.credentials.refreshToken, before);
  const raw = fs.readFileSync(path.join(f.root, 'a', 'credentials.protected'));
  assert.equal(raw.includes(Buffer.from(f.a.credentials.refreshToken)), false);
  assert.equal(JSON.stringify(f.a.status()).includes(f.a.credentials.accessToken), false);
});

const gate = () => {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
};
for (const change of ['opt-out', 'unlink', 'relink']) {
  for (const direction of ['upload', 'download']) {
    test(`R2 refresh-gated ${direction} cannot cross ${change} consent/link boundary`, async (t) => {
      const f = await fixture(t);
      await f.link(f.a);
      await f.link(f.b);
      await f.a.queueExtension({
        profileId: 'normal',
        extensionId,
        source: { kind: 'web-store', id: extensionId },
        state: 'enabled',
      });
      await f.a.syncNow();
      await f.b.syncNow();
      const second = await f.b.createDataset('Replacement');
      await f.a.callStorage(f.ctx(), 'set', [{ privatePending: true }]);
      const entered = gate(),
        release = gate();
      const refresh = f.a.refresh.bind(f.a);
      let armed = false;
      f.a.fetch = async (url, options) => {
        const response = await fetch(url, options);
        // Expire after the account check (download) or the initial pull (upload).
        if (!armed && url.includes(direction === 'upload' ? '/changes?' : '/account')) {
          armed = true;
          f.a.credentials.expiresAt = 0;
        }
        return response;
      };
      f.a.refresh = async (epoch) => {
        entered.resolve();
        await release.promise;
        return refresh(epoch);
      };
      const requests = [];
      const fetcher = f.a.fetch;
      f.a.fetch = (url, options) => {
        requests.push({ url, body: options.body });
        return fetcher(url, options);
      };
      const pending = f.a.syncNow();
      await entered.promise;
      if (change === 'opt-out') await f.a.setSettingsSync('normal', false);
      else {
        await f.a.unlinkProfile('normal');
        if (change === 'relink') {
          // The replacement link uses valid current credentials; the old refresh remains suspended.
          f.a.credentials.expiresAt = Date.now() + 600000;
          await f.a.linkProfile({ profileId: 'normal', datasetId: second.id, libraryChoice: 'remote-only' });
        }
      }
      const start = requests.length;
      release.resolve();
      await pending;
      assert.equal(
        requests
          .slice(start)
          .some(
            (r) =>
              r.url.includes(`/datasets/${f.dataset.id}/`) &&
              (r.url.includes('settings=1') || r.body?.includes('privatePending')),
          ),
        false,
      );
      await f.b.syncNow();
      assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), {});
      if (change === 'relink') assert.equal(f.a.status().profiles[0].datasetId, second.id);
    });
  }
}
for (const code of ['not_found', 'epoch_changed']) {
  for (const change of ['relink', 'opt-out']) {
    test(`R4 stale ${code} cannot detach ${change} generation or discard queued intent`, async (t) => {
      const f = await fixture(t);
      await f.link(f.a);
      const second = await f.a.createDataset('Replacement');
      const entered = gate(),
        release = gate();
      const original = f.a.syncProfile.bind(f.a);
      f.a.syncProfile = async (...args) => {
        entered.resolve();
        await release.promise;
        throw Object.assign(new Error('old request'), { code, status: code === 'not_found' ? 404 : 409 });
      };
      const pending = f.a.syncNow();
      await entered.promise;
      if (change === 'relink') {
        await f.a.unlinkProfile('normal');
        await f.a.linkProfile({ profileId: 'normal', datasetId: second.id, libraryChoice: 'remote-only' });
      } else await f.a.setSettingsSync('normal', false);
      await f.a.queueExtension({
        profileId: 'normal',
        extensionId,
        source: { kind: 'web-store', id: extensionId },
        state: 'enabled',
      });
      const before = f.a.store.read().links.normal;
      release.resolve();
      await pending;
      assert.deepEqual(f.a.store.read().links.normal, before);
      f.a.syncProfile = original;
    });
  }
}
test('R7 explicit local profile deletion purges live and archived database state without deleting other profiles or cloud data', async (t) => {
  const f = await fixture(t);
  await f.a.callStorage(f.ctx(extensionId, 'other'), 'set', [{ keep: true }]);
  await f.a.callStorage(f.ctx(), 'set', [{ archived: 'first-account' }]);
  await f.a.register({ username: 'delete.profile', password, deviceName: 'Second', platform: 'test' });
  await f.a.callStorage(f.ctx(), 'set', [{ archived: 'second-account' }]);
  await f.a.login({ username: 'desktop.test', password, deviceName: 'Return', platform: 'test' });
  await f.link(f.a);
  await f.a.queueExtension({
    profileId: 'normal',
    extensionId,
    source: { kind: 'web-store', id: extensionId },
    state: 'enabled',
  });
  await f.a.callStorage(f.ctx(), 'set', [{ cloud: true }]);
  await f.a.syncNow();
  await f.link(f.b);
  const entered = gate(),
    release = gate();
  const fetcher = f.a.fetch;
  f.a.fetch = async (...args) => {
    const r = await fetcher(...args);
    if (args[0].includes('/snapshot')) {
      entered.resolve();
      await release.promise;
    }
    return r;
  };
  const linking = f.link(f.a);
  await entered.promise;
  try {
    await f.a.deleteLocalProfile('normal');
  } finally {
    release.resolve();
  }
  await assert.rejects(linking, /context changed/i);
  const resumed = f.restartClient(0),
    state = resumed.store.read();
  assert.equal(state.links.normal, undefined);
  for (const areas of [state.areas, ...Object.values(state.localCopies)])
    assert.equal(
      Object.keys(areas).some((k) => JSON.parse(k)[1] === 'normal'),
      false,
    );
  assert.deepEqual(await resumed.callStorage(f.ctx(extensionId, 'other'), 'get', []), { keep: true });
  assert.deepEqual(await f.b.callStorage(f.ctx(), 'get', []), { cloud: true });
  assert.equal((await f.b.datasets()).length, 1);
});

for (const code of ['not_found', 'epoch_changed'])
  test(`R4 delayed real-service ${code} response cannot remove the replacement link`, async (t) => {
    const f = await fixture(t);
    await f.link(f.a);
    const second = await f.a.createDataset('Keep replacement');
    if (code === 'not_found') await f.b.deleteDataset(f.dataset.id, password, true);
    else {
      await f.a.queueExtension({
        profileId: 'normal',
        extensionId,
        source: { kind: 'web-store', id: extensionId },
        state: 'enabled',
      });
      f.a.store.transaction((s) => {
        s.links.normal.epoch = 'obsolete-epoch';
      });
    }
    const entered = gate(),
      release = gate();
    f.a.fetch = async (...args) => {
      const response = await fetch(...args);
      if (args[0].includes(`/datasets/${f.dataset.id}/`) && !response.ok) {
        assert.equal(response.status, code === 'not_found' ? 404 : 409);
        entered.resolve();
        await release.promise;
      }
      return response;
    };
    const pending = f.a.syncNow();
    await entered.promise;
    await f.a.unlinkProfile('normal');
    await f.a.linkProfile({ profileId: 'normal', datasetId: second.id, libraryChoice: 'remote-only' });
    await f.a.queueExtension({
      profileId: 'normal',
      extensionId,
      source: { kind: 'web-store', id: extensionId },
      state: 'enabled',
    });
    const before = f.a.store.read().links.normal;
    release.resolve();
    await pending;
    assert.deepEqual(f.a.store.read().links.normal, before);
  });

test('R7 deleting profile rejects still-live ExtensionAPI storage and fresh links until durable completion', async (t) => {
  const f = await fixture(t);
  const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
  const { ExtensionHost } = require('../src/main/extensions/host.cjs');
  const metadata = {
    enabled: true,
    generation: 'still-native',
    manifest: { manifest_version: 3 },
    grants: { permissions: ['storage'], origins: [] },
  };
  let client = f.a;
  const host = { manager: { resolveExtension: () => metadata }, getProfile: () => ({ id: 'normal' }) };
  const api = new ExtensionAPI({
    resolveExtension: () => metadata,
    storage: {
      call: (context, method, args) =>
        client.callStorage(ExtensionHost.prototype.storageContext.call(host, context), method, args),
    },
  });
  const context = api.context('normal', extensionId);
  await api.call(context, 'storage.sync.set', [{ before: 'purge me' }]);
  await client.deleteLocalProfile('normal');
  // Main-process AI/session teardown is still awaiting; native metadata and getProfile remain live.
  await assert.rejects(
    api.call(context, 'storage.sync.set', [{ personal: 'written during deletion' }]),
    /delet/i,
  );
  await assert.rejects(api.call(context, 'storage.sync.get', []), /delet/i);
  assert.equal(client.canAccessStorage(f.ctx()), false);
  let requests = 0;
  client.fetch = (...args) => {
    requests++;
    return fetch(...args);
  };
  await assert.rejects(f.link(client), /delet/i);
  assert.equal(requests, 0, 'retired profiles must reject before refresh or dataset fetch');
  assert.equal(Object.keys(client.store.read().areas).length, 0);
  client = f.restartClient(0);
  await assert.rejects(api.call(context, 'storage.sync.set', [{ afterRestart: true }]), /delet/i);
  await assert.rejects(f.link(client), /delet/i);
  await client.deleteLocalProfile('normal'); // Retry after an interrupted teardown is allowed.
  assert.throws(() => client.completeLocalProfileDeletion('normal'), /still|exist|remov/i);
  client.getProfile = () => null; // Browser deletion and durable flush have completed.
  client.completeLocalProfileDeletion('normal');
  assert.deepEqual(client.store.read().retiredProfiles, []);
  client.getProfile = (id) => ({ id }); // An explicitly restored profile begins with empty settings.
  assert.deepEqual(await api.call(context, 'storage.sync.get', []), {});
});

test('R7 failed purge transaction leaves profile data, pending link intent and request authority intact', async (t) => {
  const f = await fixture(t);
  await f.link(f.a);
  await f.a.callStorage(f.ctx(extensionId, 'other'), 'set', [{ keep: true }]);
  await f.a.callStorage(f.ctx(), 'set', [{ before: 'must survive failure' }]);
  const before = f.a.store.read(),
    intent = f.a.profileIntents.get('normal');
  const controller = new AbortController();
  controller.profileId = 'normal';
  f.a.controllers.add(controller);
  f.a.store.db.exec(
    "CREATE TEMP TRIGGER fail_purge BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT, 'Synthetic purge commit failure'); END",
  );
  await assert.rejects(f.a.deleteLocalProfile('normal'), /Synthetic purge commit failure/);
  f.a.store.db.exec('DROP TRIGGER fail_purge');
  assert.deepEqual(f.a.store.read(), before);
  assert.equal(f.a.profileIntents.get('normal'), intent);
  assert.equal(controller.signal.aborted, false);
  assert.equal(f.a.canAccessStorage(f.ctx()), true);
  await f.a.callStorage(f.ctx(), 'set', [{ afterFailure: true }]);
  assert.equal((await f.a.callStorage(f.ctx(), 'get', [])).afterFailure, true);
  assert.deepEqual(await f.a.callStorage(f.ctx(extensionId, 'other'), 'get', []), { keep: true });
});
