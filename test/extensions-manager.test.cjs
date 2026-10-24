'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  path = require('node:path'),
  os = require('node:os');
const { zip, crx, keyPair } = require('./fixtures/extensions/packages/builders.cjs');
const { verifyCrx } = require('../src/main/extensions/packages.cjs');
let ExtensionManager;
try {
  ({ ExtensionManager } = require('../src/main/extensions/manager.cjs'));
} catch (e) {
  if (e.code !== 'MODULE_NOT_FOUND') throw e;
}
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
};
const keys = [keyPair()];
function fixture(version = '1', permissions = ['storage']) {
  const manifest = {
    manifest_version: 3,
    name: 'Synthetic',
    version,
    permissions,
    background: { service_worker: 'worker.js' },
  };
  const signed = crx(
    zip([
      { name: 'manifest.json', data: JSON.stringify(manifest) },
      { name: 'worker.js', data: '"use strict";globalThis.fixture=true;' },
    ]),
    { keys },
  );
  // Lifecycle tests substitute the already-verified download boundary. The real
  // production verifier separately rejects this synthetic key as a publisher.
  return {
    ...verifyCrx(signed.buffer, { expectedId: signed.id, requirePublisher: false }),
    buffer: signed.buffer,
    publisherVerified: true,
    source: { kind: 'chrome-web-store', id: signed.id },
  };
}
async function setup(t, overrides = {}) {
  assert.ok(ExtensionManager, 'lifecycle manager must exist');
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-manager-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const profiles = new Map([
      ['p1', { id: 'p1', name: 'First' }],
      ['p2', { id: 'p2', name: 'Second' }],
      ['private', { id: 'private', private: true }],
    ]),
    sessions = new Map(),
    events = [];
  let manager;
  const options = {
    root: path.join(root, 'managed'),
    getProfile: (id) => profiles.get(id),
    getSession: (id) => {
      if (!sessions.has(id))
        sessions.set(id, {
          extensions: {
            async loadExtension(directory, opts) {
              const manifest = JSON.parse(await fs.readFile(path.join(directory, 'manifest.json'), 'utf8'));
              const extensionId = manifest.key
                ? require('../src/main/extensions/packages.cjs').idFromKey(
                    Buffer.from(manifest.key, 'base64'),
                  )
                : overrides.legacyId;
              assert.equal(opts.allowFileAccess, false);
              assert.equal(
                manager.resolveExtension(id, extensionId)?.enabled,
                true,
                'metadata must exist before native load',
              );
              events.push(['load', id, extensionId, manifest.version]);
              if (overrides.load) await overrides.load(directory);
              return { id: extensionId };
            },
            removeExtension(extensionId) {
              events.push(['unload', id, extensionId]);
            },
          },
        });
      return sessions.get(id);
    },
    prepareSession: (session, id) => events.push(['prepare', id]),
    confirmPermissions: async (context) => {
      events.push(['permission', context.profileId, context.kind, context.manifest.version]);
      return true;
    },
    onDeactivated: async () => ({ requiresPageReload: false }),
    fetchPackage: async () => fixture(),
    now: () => 1000000,
    random: () => 0.5,
    ...overrides,
  };
  manager = new ExtensionManager(options);
  t.after(() => manager.close());
  await manager.restore('p1');
  await manager.restore('p2');
  return {
    manager,
    root,
    events,
    profiles,
    sessions,
    options,
    setManager: (value) => {
      manager = value;
    },
  };
}
test('install waits for profile-bound permission and exposes synchronous metadata before load', async (t) => {
  const permission = deferred(),
    started = deferred();
  const h = await setup(t, {
    confirmPermissions: (context) => {
      started.resolve(context);
      return permission.promise;
    },
  });
  const id = fixture().id,
    pending = h.manager.installStore('p1', id),
    context = await started.promise;
  assert.equal(context.profileId, 'p1');
  assert.equal(context.kind, 'install');
  assert.ok(context.generation);
  assert.equal(
    h.events.some((e) => e[0] === 'load'),
    false,
  );
  permission.resolve(true);
  const record = await pending;
  assert.equal(record.enabled, true);
  assert.equal(record.current.manifest.version, '1');
  assert.equal(record.current.verification.publisherVerified, true);
  assert.equal(h.manager.list('p2').length, 0);
  assert.deepEqual(h.manager.resolveExtension('p1', id).grants, { permissions: ['storage'], origins: [] });
  const original = await fs.readFile(h.manager.versionPath('p1', record.current, 'original.crx'));
  assert.deepEqual(original, fixture().buffer);
  const sourceManifest = JSON.parse(
    await fs.readFile(h.manager.versionPath('p1', record.current, 'original/manifest.json'), 'utf8'),
  );
  assert.equal(sourceManifest.key, undefined);
  assert.equal(record.current.transformVersion, 3);
  assert.equal(record.current.derivedSha256.length, 64);
});
test('uninstall wins over late download or late permission and private profiles cannot install', async (t) => {
  const downloaded = deferred(),
    started = deferred();
  const h = await setup(t, {
    fetchPackage: () => {
      started.resolve();
      return downloaded.promise;
    },
  });
  const id = fixture().id;
  const pending = h.manager.installStore('p1', id);
  await started.promise;
  const removed = h.manager.remove('p1', id);
  downloaded.resolve(fixture());
  await assert.rejects(pending, /stale|cancel|abort/i);
  await removed;
  assert.equal(h.manager.list('p1').length, 0);
  assert.equal(
    h.events.some((e) => e[0] === 'load'),
    false,
  );
  await assert.rejects(h.manager.installStore('private', id), /private/i);
  const permission = deferred(),
    asked = deferred();
  const h2 = await setup(t, {
    confirmPermissions: () => {
      asked.resolve();
      return permission.promise;
    },
  });
  const installing = h2.manager.installStore('p1', id);
  await asked.promise;
  const removal = h2.manager.remove('p1', id);
  permission.resolve(true);
  await assert.rejects(installing, /stale|cancel|abort/i);
  await removal;
  assert.equal(h2.manager.list('p1').length, 0);
});
test('profile invalidation rejects delayed native load and unloads it without touching another profile', async (t) => {
  const load = deferred(),
    started = deferred();
  const h = await setup(t, {
    load: () => {
      started.resolve();
      return load.promise;
    },
  });
  const id = fixture().id;
  const installing = h.manager.installStore('p1', id);
  await started.promise;
  const invalidating = h.manager.invalidateProfile('p1');
  load.resolve();
  await assert.rejects(installing, /stale|cancel|abort/i);
  await invalidating;
  assert.equal(h.manager.resolveExtension('p1', id), null);
  assert.ok(h.events.some((e) => e[0] === 'unload' && e[1] === 'p1'));
  assert.equal(h.manager.list('p2').length, 0);
});
test('escalating update stays pending with old native version; approval swaps and rollback restores one version', async (t) => {
  let next = fixture();
  const h = await setup(t, { fetchPackage: async () => next });
  const id = next.id;
  await h.manager.installStore('p1', id);
  next = fixture('2', ['storage', 'tabs']);
  let record = await h.manager.update('p1', id);
  assert.equal(record.current.manifest.version, '1');
  assert.equal(record.pending.manifest.version, '2');
  assert.equal(record.status, 'pending-approval');
  assert.equal(h.events.filter((e) => e[0] === 'load').length, 1);
  record = await h.manager.approve('p1', id);
  assert.equal(record.current.manifest.version, '2');
  assert.equal(record.previous.manifest.version, '1');
  assert.equal(record.pending, null);
  assert.ok(h.events.some((e) => e[0] === 'unload'));
  record = await h.manager.rollback('p1', id);
  assert.equal(record.current.manifest.version, '1');
  assert.equal(record.previous, null);
  assert.equal(record.enabled, true);
  next = fixture('0.5');
  await assert.rejects(h.manager.update('p1', id), /downgrade/i);
  assert.equal(h.manager.list('p1')[0].current.manifest.version, '1');
});
test('restart preserves pending review and rollback while cleaning interrupted staging and orphan versions', async (t) => {
  let next = fixture();
  const h = await setup(t, { fetchPackage: async () => next });
  const id = next.id;
  await h.manager.installStore('p1', id);
  next = fixture('2');
  await h.manager.update('p1', id);
  next = fixture('3', ['storage', 'tabs']);
  await h.manager.update('p1', id);
  const directory = h.manager.profilePath('p1');
  await fs.mkdir(path.join(directory, 'staging', 'crashed'), { recursive: true });
  await fs.mkdir(path.join(directory, 'versions', 'abandoned'), { recursive: true });
  await h.manager.close();
  const restarted = new ExtensionManager(h.options);
  h.setManager(restarted);
  await restarted.restore('p1');
  const record = restarted.list('p1')[0];
  assert.equal(record.current.manifest.version, '2');
  assert.equal(record.previous.manifest.version, '1');
  assert.equal(record.pending.manifest.version, '3');
  assert.equal(record.status, 'pending-approval');
  assert.deepEqual(await fs.readdir(path.join(directory, 'staging')), []);
  assert.equal((await fs.readdir(path.join(directory, 'versions'))).includes('abandoned'), false);
});
test('native replacement failure restores old version, and disable/remove unload and deny old metadata', async (t) => {
  let next = fixture(),
    fail = false;
  const h = await setup(t, {
    fetchPackage: async () => next,
    load: async (directory) => {
      if (
        fail &&
        JSON.parse(await fs.readFile(path.join(directory, 'manifest.json'), 'utf8')).version === '2'
      )
        throw new Error('native failure');
    },
  });
  const id = next.id;
  await h.manager.installStore('p1', id);
  next = fixture('2');
  fail = true;
  await assert.rejects(h.manager.update('p1', id), /native failure/);
  assert.equal(h.manager.list('p1')[0].current.manifest.version, '1');
  assert.equal(h.manager.resolveExtension('p1', id).manifest.version, '1');
  await h.manager.disable('p1', id);
  assert.equal(h.manager.resolveExtension('p1', id), null);
  assert.equal(h.manager.list('p1')[0].enabled, false);
  await h.manager.enable('p1', id);
  await h.manager.remove('p1', id);
  assert.equal(h.manager.resolveExtension('p1', id), null);
  assert.deepEqual(h.manager.list('p1'), []);
});
test('six-hour due scheduling and failure backoff persist across restart; local packages stay local', async (t) => {
  let now = 1000000,
    calls = 0,
    fail = false;
  const h = await setup(t, {
    now: () => now,
    fetchPackage: async () => {
      calls++;
      if (fail) throw new Error('offline');
      return fixture();
    },
  });
  const id = fixture().id;
  await h.manager.installStore('p1', id);
  const count = calls;
  await h.manager.checkUpdates('p1');
  assert.equal(calls, count + 1);
  await h.manager.checkUpdates('p1');
  assert.equal(calls, count + 1);
  let schedule = h.manager.schedule('p1');
  assert.equal(schedule.nextCheck, now + 6 * 60 * 60 * 1000);
  now = schedule.nextCheck;
  fail = true;
  await h.manager.checkUpdates('p1');
  schedule = h.manager.schedule('p1');
  assert.equal(schedule.failures, 1);
  assert.ok(schedule.nextCheck > now && schedule.nextCheck < now + 6 * 60 * 60 * 1000);
  const source = path.join(h.root, 'local');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({ manifest_version: 3, name: 'Local', version: '1' }),
  );
  const local = await h.manager.installLocal('p2', source);
  assert.equal(local.source.kind, 'local-unpacked');
  assert.equal(local.source.portable, false);
  assert.equal(local.enabled, true);
  await assert.rejects(h.manager.update('p2', local.id), /local/i);
  await h.manager.close();
  const restarted = new ExtensionManager(h.options);
  h.setManager(restarted);
  await restarted.restore('p1');
  await restarted.restore('p2');
  assert.deepEqual(restarted.schedule('p1'), schedule);
  assert.equal(restarted.list('p2')[0].id, local.id);
});
test('disable revokes active metadata immediately while an ignored-abort update is still downloading', async (t) => {
  const waiting = deferred(),
    started = deferred();
  let hold = false;
  const h = await setup(t, {
    fetchPackage: () => (hold ? (started.resolve(), waiting.promise) : Promise.resolve(fixture())),
  });
  const id = fixture().id;
  await h.manager.installStore('p1', id);
  hold = true;
  const updating = h.manager.update('p1', id);
  await started.promise;
  const disabling = h.manager.disable('p1', id);
  try {
    assert.equal(h.manager.resolveExtension('p1', id), null);
    assert.ok(h.events.some((e) => e[0] === 'unload'));
  } finally {
    waiting.resolve(fixture('2'));
    await assert.rejects(updating, /stale|cancel|abort/i);
    await disabling;
  }
  assert.equal(h.manager.list('p1')[0].current.manifest.version, '1');
  assert.equal(h.manager.list('p1')[0].enabled, false);
});
test('legacy keyless imports preserve the historical path and native ID without inventing a public key', async (t) => {
  const legacyId = 'abcdefghijklmnopabcdefghijklmnop',
    h = await setup(t, { legacyId });
  const source = path.join(h.options.root, 'old-managed-extension');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({ manifest_version: 2, name: 'Old local', version: '1', permissions: ['storage'] }),
  );
  h.profiles.set('old', { id: 'old' });
  await h.manager.restore('old', {
    legacy: [{ extensionId: legacyId, profileId: 'old', path: source, enabled: true }],
  });
  const record = h.manager.list('old')[0];
  assert.equal(record.id, legacyId);
  assert.equal(record.current.legacyPath, source);
  assert.equal(record.current.publicKey, null);
  assert.equal(record.source.portable, false);
  assert.equal(record.enabled, true);
  assert.equal(h.manager.resolveExtension('old', legacyId).adapted, false);
  await h.manager.disable('old', legacyId);
  await h.manager.enable('old', legacyId);
  assert.equal(h.manager.list('old')[0].id, legacyId);
});
test('unsupported requirements and declined consent remain disabled pending review', async (t) => {
  const h = await setup(t, { fetchPackage: async () => fixture('1', ['nativeMessaging']) });
  const id = fixture().id;
  let record = await h.manager.installStore('p1', id);
  assert.equal(record.enabled, false);
  assert.equal(record.status, 'incompatible');
  assert.equal(
    h.events.some((e) => e[0] === 'load'),
    false,
  );
  await assert.rejects(h.manager.approve('p1', id), /unsupported/);
  const h2 = await setup(t, { confirmPermissions: async () => false });
  record = await h2.manager.installStore('p1', id);
  assert.equal(record.enabled, false);
  assert.equal(record.status, 'pending-approval');
  await assert.rejects(h2.manager.enable('p1', id), /Approve/);
});
test('optional native permissions are stripped before execution and tampered derived code cannot restore', async (t) => {
  const h = await setup(t);
  const source = path.join(h.root, 'local-optional');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({
      manifest_version: 3,
      name: 'Local options',
      version: '1',
      permissions: ['storage'],
      optional_permissions: ['tabs'],
      optional_host_permissions: ['https://example.com/*'],
    }),
  );
  let record = await h.manager.installLocal('p1', source);
  const effective = JSON.parse(
    await fs.readFile(h.manager.versionPath('p1', record.current, 'derived/manifest.json'), 'utf8'),
  );
  assert.deepEqual(effective.optional_permissions, []);
  assert.deepEqual(effective.optional_host_permissions, []);
  assert.deepEqual(record.grants, { permissions: ['storage'], origins: [] });
  await h.manager.close();
  await fs.appendFile(
    h.manager.versionPath('p1', record.current, 'derived/zacro-compat-bootstrap.js'),
    '\n// altered',
  );
  const restarted = new ExtensionManager(h.options);
  h.setManager(restarted);
  await restarted.restore('p1');
  record = restarted.list('p1')[0];
  assert.equal(record.enabled, false);
  assert.equal(record.status, 'load-failed');
  assert.match(record.error, /integrity/);
  assert.equal(restarted.resolveExtension('p1', record.id), null);
});
test('profile teardown and restore within the same manager starts a fresh native generation', async (t) => {
  const h = await setup(t),
    id = fixture().id;
  await h.manager.installStore('p1', id);
  const generation = h.manager.resolveExtension('p1', id).generation;
  await h.manager.invalidateProfile('p1');
  assert.equal(h.manager.resolveExtension('p1', id), null);
  await h.manager.restore('p1');
  assert.ok(h.manager.resolveExtension('p1', id));
  assert.notEqual(h.manager.resolveExtension('p1', id).generation, generation);
});
test('rollback keeps a disabled extension disabled and drops superseded files', async (t) => {
  let next = fixture();
  const h = await setup(t, { fetchPackage: async () => next });
  const id = next.id;
  await h.manager.installStore('p1', id);
  next = fixture('2');
  await h.manager.update('p1', id);
  await h.manager.disable('p1', id);
  const loads = h.events.filter((e) => e[0] === 'load').length;
  const record = await h.manager.rollback('p1', id);
  assert.equal(record.current.manifest.version, '1');
  assert.equal(record.enabled, false);
  assert.equal(h.events.filter((e) => e[0] === 'load').length, loads);
  assert.equal((await fs.readdir(path.join(h.manager.profilePath('p1'), 'versions'))).length, 1);
});
test('uninstall persists removal immediately even when an obsolete native operation has not returned', async (t) => {
  const waiting = deferred(),
    started = deferred();
  let hold = false;
  const h = await setup(t, {
    fetchPackage: () => (hold ? (started.resolve(), waiting.promise) : Promise.resolve(fixture())),
  });
  const id = fixture().id;
  await h.manager.installStore('p1', id);
  hold = true;
  const updating = h.manager.update('p1', id);
  await started.promise;
  const removal = h.manager.remove('p1', id);
  try {
    assert.deepEqual(h.manager.list('p1'), []);
    const disk = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json'), 'utf8'));
    assert.deepEqual(disk.extensions, []);
  } finally {
    waiting.resolve(fixture('2'));
    await assert.rejects(updating, /stale|cancel|abort/i);
    await removal;
  }
});
test('invalidating a profile during restore cannot load stale saved extensions afterwards', async (t) => {
  const h = await setup(t),
    id = fixture().id;
  await h.manager.installStore('p1', id);
  await h.manager.close();
  const waiting = deferred(),
    started = deferred();
  const restarted = new ExtensionManager({
    ...h.options,
    prepareSession: () => {
      started.resolve();
      return waiting.promise;
    },
  });
  h.setManager(restarted);
  const restoring = restarted.restore('p1');
  await started.promise;
  await restarted.invalidateProfile('p1');
  waiting.resolve();
  await assert.rejects(restoring, /stale|cancel|abort/i);
  assert.equal(restarted.resolveExtension('p1', id), null);
});
test('approval of an updated disabled installation preserves its disabled intent', async (t) => {
  let next = fixture();
  const h = await setup(t, { fetchPackage: async () => next });
  const id = next.id;
  await h.manager.installStore('p1', id);
  await h.manager.disable('p1', id);
  next = fixture('2', ['storage', 'tabs']);
  await h.manager.update('p1', id);
  const before = h.events.filter((e) => e[0] === 'load').length;
  const record = await h.manager.approve('p1', id);
  assert.equal(record.current.manifest.version, '2');
  assert.equal(record.enabled, false);
  assert.equal(h.events.filter((e) => e[0] === 'load').length, before);
});
test('uninstall invalidates a local installation still inspecting its manifest', async (t) => {
  const h = await setup(t),
    source = path.join(h.root, 'racing-local'),
    publicKey = keys[0].publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
    id = fixture().id;
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({ manifest_version: 3, name: 'Local', version: '1', key: publicKey }),
  );
  const installing = h.manager.installLocal('p1', source);
  const removing = h.manager.remove('p1', id);
  await assert.rejects(installing, /stale|cancel|abort/i);
  await removing;
  assert.deepEqual(h.manager.list('p1'), []);
});

test('permission reduction stays disabled until the host confirms affected pages were reloaded', async (t) => {
  let next = fixture('1', ['storage', 'tabs']),
    requiresPageReload = true;
  const h = await setup(t, {
    fetchPackage: async () => next,
    onDeactivated: async () => ({ requiresPageReload }),
  });
  const id = next.id;
  await h.manager.installStore('p1', id);
  next = fixture('2', ['storage']);
  let record = await h.manager.update('p1', id);
  assert.equal(record.current.manifest.version, '2');
  assert.equal(record.enabled, false);
  assert.equal(record.status, 'pending-reload');
  assert.equal(h.manager.resolveExtension('p1', id), null);
  assert.deepEqual(record.grants.permissions, ['storage']);
  await assert.rejects(h.manager.enable('p1', id), /reload/i);
  requiresPageReload = false;
  record = await h.manager.enable('p1', id);
  assert.equal(record.enabled, true);
  assert.equal(record.permissionReloadPending, false);
});

test('a permission-reducing update of a disabled extension cannot bypass unresolved page reloads', async (t) => {
  let next = fixture('1', ['storage', 'tabs']);
  const h = await setup(t, {
    fetchPackage: async () => next,
    onDeactivated: async () => ({ requiresPageReload: true }),
  });
  const id = next.id;
  await h.manager.installStore('p1', id);
  await h.manager.disable('p1', id);
  next = fixture('2', ['storage']);
  const updated = await h.manager.update('p1', id);
  assert.equal(updated.permissionReloadPending, true);
  await assert.rejects(h.manager.enable('p1', id), /reload/i);
  assert.equal(h.manager.resolveExtension('p1', id), null);
});

test('legacy migration refuses arbitrary paths outside the managed extension root', async (t) => {
  const h = await setup(t, { legacyId: 'abcdefghijklmnopabcdefghijklmnop' });
  const source = path.join(h.root, 'outside');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({ manifest_version: 3, name: 'Unapproved', version: '1' }),
  );
  h.profiles.set('old', { id: 'old' });
  await assert.rejects(
    h.manager.restore('old', {
      legacy: [
        { extensionId: 'abcdefghijklmnopabcdefghijklmnop', profileId: 'old', path: source, enabled: true },
      ],
    }),
    /managed|outside/i,
  );
  assert.equal(
    h.events.some((event) => event[0] === 'load'),
    false,
  );
});

for (const action of ['install', 'enable'])
  test(`failed ${action} metadata persistence unloads a successfully loaded native extension`, async (t) => {
    let fail = false,
      h;
    h = await setup(t, {
      load: async () => {
        if (!fail) return;
        const state = path.join(h.manager.profilePath('p1'), 'state.json');
        await fs.rename(state, state + '.saved');
        await fs.mkdir(state);
      },
    });
    const id = fixture().id;
    if (action === 'enable') {
      await h.manager.installStore('p1', id);
      await h.manager.disable('p1', id);
    }
    fail = true;
    try {
      await assert.rejects(
        action === 'install' ? h.manager.installStore('p1', id) : h.manager.enable('p1', id),
      );
      assert.equal(h.manager.resolveExtension('p1', id), null);
      assert.equal(h.events.at(-1)[0], 'unload');
    } finally {
      const state = path.join(h.manager.profilePath('p1'), 'state.json');
      await fs.rm(state, { recursive: true, force: true });
      await fs.rename(state + '.saved', state);
    }
  });

test('each native session is prepared exactly once before any load, including profile resume', async (t) => {
  const attached = new WeakSet();
  const h = await setup(t, {
    prepareSession: (session) => {
      assert.equal(attached.has(session), false, 'bridge.attachSession rejects duplicate attachment');
      attached.add(session);
    },
  });
  const id = fixture().id;
  await h.manager.installStore('p1', id);
  await h.manager.disable('p1', id);
  await h.manager.enable('p1', id);
  await h.manager.invalidateProfile('p1');
  await h.manager.restore('p1');
  assert.equal(h.manager.list('p1')[0].enabled, true);
});

for (const declaration of [{ optional_permissions: ['tabs'] }, { permissions: ['nativeMessaging'] }]) {
  test(`incompatible legacy rights cannot activate through enable: ${JSON.stringify(declaration)}`, async (t) => {
    const legacyId = 'abcdefghijklmnopabcdefghijklmnop',
      h = await setup(t, { legacyId });
    const source = path.join(h.options.root, 'legacy-incompatible');
    await fs.mkdir(source);
    await fs.writeFile(
      path.join(source, 'manifest.json'),
      JSON.stringify({ manifest_version: 3, name: 'Legacy incompatible', version: '1', ...declaration }),
    );
    h.profiles.set('old', { id: 'old' });
    await h.manager.restore('old', {
      legacy: [{ profileId: 'old', extensionId: legacyId, path: source, enabled: true }],
    });
    assert.equal(h.manager.list('old')[0].status, 'incompatible');
    await assert.rejects(h.manager.enable('old', legacyId), /unsupported|incompatible/i);
    assert.equal(h.manager.list('old')[0].enabled, false);
    assert.equal(h.manager.resolveExtension('old', legacyId), null);
    assert.equal(
      h.events.some((event) => event[0] === 'load'),
      false,
    );
  });
}

test('restore rejects an incompatible saved current version at the common native-load boundary', async (t) => {
  const legacyId = 'abcdefghijklmnopabcdefghijklmnop',
    h = await setup(t, { legacyId });
  const source = path.join(h.options.root, 'legacy-restore-incompatible');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({
      manifest_version: 3,
      name: 'Legacy incompatible',
      version: '1',
      optional_permissions: ['tabs'],
    }),
  );
  h.profiles.set('old', { id: 'old' });
  await h.manager.restore('old', {
    legacy: [{ profileId: 'old', extensionId: legacyId, path: source, enabled: true }],
  });
  const file = path.join(h.manager.profilePath('old'), 'state.json');
  await h.manager.close();
  const state = JSON.parse(await fs.readFile(file, 'utf8'));
  state.extensions[0].enabled = true; // A previously persisted incompatible activation must not recur.
  await fs.writeFile(file, JSON.stringify(state));
  const restarted = new ExtensionManager(h.options);
  h.setManager(restarted);
  await restarted.restore('old');
  assert.equal(restarted.list('old')[0].enabled, false);
  assert.match(restarted.list('old')[0].error, /unsupported|incompatible/i);
  assert.equal(restarted.resolveExtension('old', legacyId), null);
  assert.equal(
    h.events.some((event) => event[0] === 'load'),
    false,
  );
});

test('superseded replacement unload followed by an offline update leaves a recoverable coherent record', async (t) => {
  const deactivated = deferred(),
    release = deferred();
  let downloads = 0;
  const h = await setup(t, {
    fetchPackage: async () => {
      downloads++;
      if (downloads > 2) throw new Error('offline replacement');
      return fixture(downloads === 1 ? '1' : '2');
    },
    onDeactivated: async (context) => {
      if (context.reason === 'update') {
        deactivated.resolve();
        await release.promise;
      }
      return { requiresPageReload: false };
    },
  });
  const id = fixture().id;
  await h.manager.installStore('p1', id);
  const first = h.manager.update('p1', id);
  await deactivated.promise;
  const second = h.manager.update('p1', id);
  const firstRejected = assert.rejects(first, /stale|cancel|abort/i),
    secondRejected = assert.rejects(second, /offline/);
  release.resolve();
  await Promise.all([firstRejected, secondRejected]);
  const record = h.manager.list('p1')[0];
  const disk = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json'), 'utf8'))
    .extensions[0];
  assert.equal(record.current.manifest.version, '1');
  assert.equal(record.enabled, Boolean(h.manager.resolveExtension('p1', id)));
  assert.equal(disk.enabled, record.enabled);
  await h.manager.enable('p1', id);
  assert.equal(h.manager.resolveExtension('p1', id)?.enabled, true);
  assert.equal(h.manager.list('p1')[0].enabled, true);
});

test('a throwing replacement deactivation callback leaves coherent old state and normal enable recovery', async (t) => {
  let next = fixture();
  const h = await setup(t, {
    fetchPackage: async () => next,
    onDeactivated: async () => {
      throw new Error('page inspection failed');
    },
  });
  const id = next.id;
  await h.manager.installStore('p1', id);
  next = fixture('2');
  await assert.rejects(h.manager.update('p1', id), /page inspection failed/);
  const record = h.manager.list('p1')[0];
  const disk = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json'), 'utf8'))
    .extensions[0];
  assert.equal(record.current.manifest.version, '1');
  assert.equal(record.enabled, Boolean(h.manager.resolveExtension('p1', id)));
  assert.equal(disk.enabled, record.enabled);
  await h.manager.enable('p1', id);
  assert.equal(h.manager.resolveExtension('p1', id)?.enabled, true);
});

for (const action of ['disable', 'remove'])
  test(`newer ${action} wins while replacement is awaiting page deactivation`, async (t) => {
    const deactivated = deferred(),
      release = deferred();
    let next = fixture();
    const h = await setup(t, {
      fetchPackage: async () => next,
      onDeactivated: async (context) => {
        if (context.reason === 'update') {
          deactivated.resolve();
          await release.promise;
        }
        return { requiresPageReload: false };
      },
    });
    const id = next.id;
    await h.manager.installStore('p1', id);
    next = fixture('2');
    const updating = h.manager.update('p1', id);
    await deactivated.promise;
    const newer = h.manager[action]('p1', id),
      rejected = assert.rejects(updating, /stale|cancel|abort/i);
    release.resolve();
    await Promise.all([newer, rejected]);
    const records = h.manager.list('p1');
    const disk = JSON.parse(
      await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json'), 'utf8'),
    ).extensions;
    assert.equal(h.manager.resolveExtension('p1', id), null);
    assert.equal(h.events.filter((event) => event[0] === 'load').length, 1);
    if (action === 'remove') {
      assert.deepEqual(records, []);
      assert.deepEqual(disk, []);
    } else {
      assert.equal(records[0].enabled, false);
      assert.equal(disk[0].enabled, false);
      assert.equal(records[0].current.manifest.version, '1');
    }
  });

test('stopping a schedule during its check prevents late timer rearming', async (t) => {
  const started = deferred(),
    release = deferred(),
    completed = deferred();
  let h,
    hold = false;
  h = await setup(t, {
    fetchPackage: async () => {
      if (hold) {
        started.resolve();
        return release.promise;
      }
      return fixture();
    },
    onChange: (profileId) => {
      if (h?.manager.schedule(profileId).nextCheck > 0) completed.resolve();
    },
  });
  await h.manager.installStore('p1', fixture().id);
  hold = true;
  h.manager.startUpdates('p1');
  await new Promise((resolve) => setTimeout(resolve, 0));
  await started.promise;
  h.manager.stopUpdates('p1');
  release.resolve(fixture());
  await completed.promise;
  await new Promise(setImmediate);
  assert.equal(h.manager.timers.has('p1'), false);
});

test('restarting during an old scheduled check leaves exactly one future checking loop', async (t) => {
  const started = deferred(),
    release = deferred();
  let now = 1000000,
    downloads = 0,
    checks = 0;
  const h = await setup(t, {
    now: () => now,
    fetchPackage: async () => {
      downloads++;
      if (downloads === 2) {
        started.resolve();
        return release.promise;
      }
      return fixture();
    },
  });
  const id = fixture().id;
  await h.manager.installStore('p1', id);
  const originalCheck = h.manager.checkUpdates.bind(h.manager);
  h.manager.checkUpdates = (...args) => {
    checks++;
    return originalCheck(...args);
  };
  t.mock.timers.enable({ apis: ['setTimeout'] });
  h.manager.startUpdates('p1');
  t.mock.timers.tick(1);
  await started.promise;
  h.manager.startUpdates('p1');
  t.mock.timers.tick(1);
  assert.equal(checks, 2);
  const current = h.manager.queues.get(JSON.stringify(['p1', id]));
  release.resolve(fixture());
  await current;
  await new Promise(setImmediate);
  now = h.manager.schedule('p1').nextCheck;
  try {
    t.mock.timers.tick(6 * 60 * 60 * 1000 + 1);
    assert.equal(checks, 3, 'only the restarted schedule should check at the next interval');
  } finally {
    h.manager.stopUpdates('p1');
    await h.manager.invalidateProfile('p1');
  }
});
test('captured external lifecycle guard cancels a deferred install before native activation', async (t) => {
  let current = true;
  const download = deferred(),
    started = deferred();
  const h = await setup(t, {
    captureOperationGuard: () => () => {
      if (!current) throw new Error('Stale external sync context');
    },
    fetchPackage: async () => {
      started.resolve();
      return download.promise;
    },
  });
  const id = fixture().id;
  const installing = h.manager.installStore('p1', id);
  await started.promise;
  current = false;
  download.resolve(fixture());
  await assert.rejects(installing, /Stale external sync context/);
  assert.equal(h.manager.resolveExtension('p1', id), null);
  assert.equal(h.manager.list('p1').length, 0);
  assert.equal(
    h.events.some((event) => event[0] === 'load'),
    false,
  );
});
test('local install captures external owner before asynchronous manifest inspection', async (t) => {
  let valid = true,
    owner = () => {
      if (!valid) throw new Error('Stale local owner');
    };
  const h = await setup(t, { captureOperationGuard: () => owner });
  const source = path.join(h.root, 'source');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({ manifest_version: 3, name: 'Local', version: '1' }),
  );
  const installing = h.manager.installLocal('p1', source);
  owner = () => {};
  valid = false;
  await assert.rejects(installing, /Stale local owner/);
  assert.equal(h.manager.list('p1').length, 0);
});
test('restore rechecks current capability policy instead of trusting a historic compatible flag', async (t) => {
  const h = await setup(t, { fetchPackage: async () => fixture('1', ['activeTab']) });
  const record = await h.manager.installStore('p1', fixture().id);
  const file = path.join(h.manager.profilePath('p1'), 'state.json');
  await h.manager.close();
  const state = JSON.parse(await fs.readFile(file, 'utf8'));
  const old = state.extensions[0];
  old.current = old.pending;
  old.pending = null;
  old.enabled = true;
  old.status = 'enabled';
  old.grants = { permissions: ['activeTab'], origins: [] };
  old.current.inspection.compatible = true;
  old.current.inspection.unsupported = [];
  await fs.writeFile(file, JSON.stringify(state));
  const restarted = new ExtensionManager(h.options);
  h.setManager(restarted);
  await restarted.restore('p1');
  assert.equal(restarted.resolveExtension('p1', record.id), null);
  assert.equal(restarted.list('p1')[0].enabled, false);
  assert.match(restarted.list('p1')[0].error, /temporary|activeTab/i);
});
test('R3 narrower optional host survives native manifest rebuild and restore without wildcard escalation', async (t) => {
  const h = await setup(t);
  const source = path.join(h.root, 'narrow-host');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({
      manifest_version: 3,
      name: 'Narrow host',
      version: '1',
      permissions: ['scripting'],
      optional_host_permissions: ['https://*/*'],
    }),
  );
  let record = await h.manager.installLocal('p1', source);
  record = await h.manager.changePermissions('p1', record.id, {
    permissions: ['scripting'],
    origins: ['https://example.com/*'],
  });
  assert.deepEqual(record.grants.origins, ['https://example.com/*']);
  assert.deepEqual(h.manager.resolveExtension('p1', record.id).manifest.host_permissions, [
    'https://example.com/*',
  ]);
  await h.manager.invalidateProfile('p1');
  await h.manager.restore('p1');
  assert.deepEqual(h.manager.resolveExtension('p1', record.id).manifest.host_permissions, [
    'https://example.com/*',
  ]);
  await assert.rejects(
    h.manager.changePermissions('p1', record.id, {
      permissions: ['scripting'],
      origins: ['http://example.com/*'],
    }),
    /undeclared/,
  );
  await assert.rejects(
    h.manager.changePermissions('p1', record.id, { permissions: ['scripting'], origins: ['*://*/*'] }),
    /undeclared/,
  );
  await h.manager.changePermissions('p1', record.id, { permissions: ['scripting'], origins: [] });
  assert.deepEqual(h.manager.resolveExtension('p1', record.id).manifest.host_permissions, []);
});
test('metadata writes reject unreadable size before replacing the durable profile state', async (t) => {
  const h = await setup(t);
  const filename = path.join(h.manager.profilePath('p1'), 'state.json');
  const before = await fs.readFile(filename, 'utf8');
  assert.throws(
    () =>
      h.manager._persist('p1', (state) => {
        state.oversized = 'x'.repeat(16 * 1024 * 1024);
      }),
    /too large/,
  );
  assert.equal(await fs.readFile(filename, 'utf8'), before);
  assert.equal(h.manager.states.get('p1').oversized, undefined);
  await h.manager.invalidateProfile('p1');
  await h.manager.restore('p1');
  assert.deepEqual(h.manager.list('p1'), []);
});
