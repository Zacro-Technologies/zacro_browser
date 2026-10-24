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
