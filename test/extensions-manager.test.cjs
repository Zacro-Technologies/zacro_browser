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
function fixture(version = '1', permissions = ['storage'], optionalPermissions = [], optionalOrigins = []) {
  const manifest = {
    manifest_version: 3,
    name: 'Synthetic',
    version,
    permissions,
    optional_permissions: optionalPermissions,
    optional_host_permissions: optionalOrigins,
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
            ...overrides.engine,
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
              if (overrides.load) await overrides.load(directory, opts);
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
test('removal deletes native snapshots before asynchronous teardown can be cancelled', async (t) => {
  const teardown = deferred();
  const { manager } = await setup(t, {
    onDeactivated: async () => {
      await teardown.promise;
      return { requiresPageReload: false };
    },
  });
  const record = await manager.installStore('p1', fixture().id);
  const directory = path.join(manager.profilePath('p1'), 'native-services');
  await fs.mkdir(directory);
  const filename = path.join(directory, record.id + '.json');
  await fs.writeFile(filename, '{"schema":1}');
  const removal = manager.remove('p1', record.id);
  const exists = await fs.access(filename).then(
    () => true,
    () => false,
  );
  teardown.resolve();
  await removal;
  assert.equal(exists, false, 'a successor installation must not inherit removed rules');
});
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
  assert.equal(record.current.transformVersion, 4);
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
  const h = await setup(t, { fetchPackage: async () => fixture('1', ['enterprise.platformKeys']) });
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

for (const declaration of [
  { optional_permissions: ['tabs'] },
  { permissions: ['enterprise.platformKeys'] },
]) {
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

test('F2 manager rejects astral paths outside optional declaration without changing granted state', async (t) => {
  const h = await setup(t),
    source = path.join(h.root, 'astral-host');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    JSON.stringify({
      manifest_version: 3,
      name: 'Astral host',
      version: '1',
      permissions: ['scripting'],
      optional_host_permissions: ['https://example.com/private/*', 'https://example.com/a😀'],
    }),
  );
  const record = await h.manager.installLocal('p1', source);
  for (const origin of ['https://example.com/public/😀', 'https://example.com/a😀/suffix']) {
    await assert.rejects(
      h.manager.changePermissions('p1', record.id, { permissions: ['scripting'], origins: [origin] }),
      /undeclared/,
    );
    assert.deepEqual(h.manager.list('p1')[0].grants.origins, []);
  }
  await h.manager.changePermissions('p1', record.id, {
    permissions: ['scripting'],
    origins: ['https://example.com/private/😀'],
  });
  assert.deepEqual(h.manager.resolveExtension('p1', record.id).manifest.host_permissions, [
    'https://example.com/private/😀',
  ]);
});

for (const disabled of [false, true])
  test(`R1 rollback cannot restore revoked optional native authority (${disabled ? 'disabled then enable' : 'enabled'})`, async (t) => {
    const h = await setup(t),
      source = path.join(h.root, 'rollback-optional');
    await fs.mkdir(source);
    await fs.writeFile(
      path.join(source, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Rollback permissions',
        version: '1',
        permissions: ['scripting'],
        optional_host_permissions: ['https://secret.example/*'],
      }),
    );
    let record = await h.manager.installLocal('p1', source);
    record = await h.manager.changePermissions('p1', record.id, {
      permissions: ['scripting'],
      origins: ['https://secret.example/*'],
    });
    record = await h.manager.changePermissions('p1', record.id, { permissions: ['scripting'], origins: [] });
    if (disabled) await h.manager.disable('p1', record.id);
    record = await h.manager.rollback('p1', record.id);
    if (disabled) record = await h.manager.enable('p1', record.id);
    assert.deepEqual(record.grants.origins, []);
    assert.deepEqual(h.manager.resolveExtension('p1', record.id).manifest.host_permissions, []);
    const manifest = JSON.parse(
      await fs.readFile(path.join(h.manager.versionPath('p1', record.current), 'manifest.json'), 'utf8'),
    );
    assert.deepEqual(manifest.host_permissions, []);
  });
test('R5 restored runtime and persisted lifecycle generation agree; failed restore stays disabled', async (t) => {
  const h = await setup(t);
  const record = await h.manager.installStore('p1', fixture().id);
  const oldGeneration = record.generation;
  h.manager.close();
  const restored = new ExtensionManager(h.options);
  h.setManager(restored);
  t.after(() => restored.close());
  await restored.restore('p1');
  const next = restored.list('p1')[0];
  assert.notEqual(next.generation, oldGeneration);
  assert.equal(next.generation, restored.resolveExtension('p1', next.id).generation);
  restored.close();
  const failed = new ExtensionManager({
    ...h.options,
    getSession: () => ({
      extensions: {
        loadExtension: async () => {
          throw new Error('native failure');
        },
        removeExtension: () => {},
      },
    }),
  });
  t.after(() => failed.close());
  await failed.restore('p1');
  assert.equal(failed.list('p1')[0].enabled, false);
  assert.equal(failed.resolveExtension('p1', next.id), null);
});

test('R5 restore unloads native code if committing its new lifecycle generation fails', async (t) => {
  const h = await setup(t),
    record = await h.manager.installStore('p1', fixture().id);
  h.manager.close();
  const restored = new ExtensionManager(h.options);
  h.setManager(restored);
  t.after(() => restored.close());
  restored._save = () => {
    throw new Error('Synthetic failed generation commit');
  };
  h.events.length = 0;
  await restored.restore('p1');
  assert.equal(restored.list('p1')[0].enabled, false);
  assert.equal(restored.resolveExtension('p1', record.id), null);
  assert.ok(h.events.some((e) => e[0] === 'unload' && e[2] === record.id));
});

const nativeEngine = () => ({
  getZacroCapabilities: () => ({
    version: 1,
    activeTab: true,
    reviewedPermissions: true,
    userScripts: true,
    fontSettings: true,
  }),
  async grantZacroActiveTab() {},
  async setZacroReviewedPermissions() {},
  setZacroUserScriptsEnabled() {},
  async resetZacroExtensionState() {},
  setZacroFontPreferences() {},
  getZacroFontPreferences() {
    return {};
  },
  async getZacroFontList() {
    return [];
  },
});
test('custom runtime loads original declarations with exact grants and preserves live generation during native permission updates', async (t) => {
  const gate = deferred(),
    started = deferred(),
    calls = [];
  const engine = nativeEngine();
  engine.setZacroReviewedPermissions = async (...args) => {
    calls.push(args);
    started.resolve();
    await gate.promise;
  };
  let initial;
  const { manager, events } = await setup(t, {
    engine,
    load: async (directory, options) => {
      initial = { manifest: JSON.parse(await fs.readFile(path.join(directory, 'manifest.json'))), options };
    },
  });
  const local = path.join(await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-')), 'extension');
  t.after(() => fs.rm(path.dirname(local), { recursive: true, force: true }));
  await fs.mkdir(local);
  await fs.writeFile(
    path.join(local, 'manifest.json'),
    JSON.stringify({
      name: 'Native',
      version: '1',
      manifest_version: 3,
      permissions: ['storage', 'userScripts'],
      optional_permissions: ['tabs'],
      optional_host_permissions: ['https://example.com/*'],
    }),
  );
  const installed = await manager.installLocal('p1', local);
  assert.equal(installed.enabled, true);
  assert.deepEqual(initial.manifest.optional_permissions, ['tabs']);
  assert.deepEqual(initial.options.zacroReviewedPermissions, installed.grants);
  const before = events.length;
  const pending = manager.changePermissions('p1', installed.id, {
    permissions: ['storage', 'tabs', 'userScripts'],
    origins: [],
  });
  await started.promise;
  assert.equal(manager.resolveExtension('p1', installed.id).generation, installed.generation);
  assert.deepEqual(manager.list('p1')[0].grants, installed.grants);
  gate.resolve();
  const changed = await pending;
  assert.equal(changed.generation, installed.generation);
  assert.equal(events.length, before);
  assert.deepEqual(manager.resolveExtension('p1', installed.id).grants, changed.grants);
  assert.equal(calls.length, 1);
});
test('native user scripts require separate local consent and persist it before restart initialization', async (t) => {
  const calls = [],
    engine = nativeEngine();
  engine.setZacroUserScriptsEnabled = (...args) => calls.push(args);
  const { manager, options, setManager } = await setup(t, { engine });
  const local = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-userscripts-'));
  t.after(() => fs.rm(local, { recursive: true, force: true }));
  await fs.writeFile(
    path.join(local, 'manifest.json'),
    JSON.stringify({ name: 'User scripts', version: '1', manifest_version: 3, permissions: ['userScripts'] }),
  );
  const record = await manager.installLocal('p1', local);
  assert.equal(record.userScriptsEnabled, false);
  assert.deepEqual(calls.at(-1), [record.id, false]);
  await manager.setUserScriptsEnabled('p1', record.id, true);
  assert.equal(manager.list('p1')[0].userScriptsEnabled, true);
  await manager.close();
  const restarted = new ExtensionManager(options);
  setManager(restarted);
  t.after(() => restarted.close());
  await restarted.restore('p1');
  assert.deepEqual(calls.at(-1), [record.id, true]);
  assert.equal(restarted.list('p1')[0].userScriptsEnabled, true);
});

test('disable during native permission completion revokes immediately and a late callback cannot resurrect grants', async (t) => {
  const gate = deferred(),
    started = deferred(),
    engine = nativeEngine();
  engine.setZacroReviewedPermissions = async () => {
    started.resolve();
    await gate.promise;
  };
  const { manager, events } = await setup(t, {
    engine,
    fetchPackage: async () => fixture('1', ['storage'], ['tabs']),
  });
  const record = await manager.installStore('p1', fixture().id);
  const pending = manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'tabs'],
    origins: [],
  });
  const rejected = assert.rejects(pending, /cancel|Stale/i);
  await started.promise;
  const disabled = manager.disable('p1', record.id);
  assert.equal(manager.resolveExtension('p1', record.id), null);
  assert.equal(events.at(-1)[0], 'unload');
  gate.resolve();
  await rejected;
  await disabled;
  assert.equal(manager.list('p1')[0].enabled, false);
  assert.deepEqual(manager.list('p1')[0].grants, record.grants);
});
test('runtime migration rederives verified original declarations and downgrade cannot retain native-only authority', async (t) => {
  const h = await setup(t);
  const record = await h.manager.installStore('p1', fixture().id);
  const originalHash = record.current.originalSha256;
  await h.manager.invalidateProfile('p1');
  Object.assign(h.sessions.get('p1').extensions, nativeEngine());
  await h.manager.restore('p1');
  const migrated = h.manager.list('p1')[0];
  assert.equal(migrated.current.nativeReviewedPermissions, true);
  assert.notEqual(migrated.current.token, record.current.token);
  assert.equal(migrated.current.originalSha256, originalHash);
  assert.deepEqual(migrated.grants, record.grants);
  await h.manager.invalidateProfile('p1');
  delete h.sessions.get('p1').extensions.getZacroCapabilities;
  await h.manager.restore('p1');
  assert.equal(h.manager.list('p1')[0].current.nativeReviewedPermissions, false);
  assert.deepEqual(h.manager.list('p1')[0].grants, record.grants);
});
test('historic copies without a verified original digest cannot migrate into native authority', async (t) => {
  const h = await setup(t),
    record = await h.manager.installStore('p1', fixture().id);
  const filename = path.join(h.manager.profilePath('p1'), 'state.json');
  const state = JSON.parse(await fs.readFile(filename));
  delete state.extensions[0].current.originalSha256;
  await fs.writeFile(filename, JSON.stringify(state));
  await h.manager.invalidateProfile('p1');
  Object.assign(h.sessions.get('p1').extensions, nativeEngine());
  await h.manager.restore('p1');
  assert.equal(h.manager.list('p1')[0].enabled, false);
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
  assert.match(h.manager.list('p1')[0].error, /Reinstall/);
});

test('downgrade fails closed when a native-only optional permission was previously granted', async (t) => {
  const h = await setup(t, {
    engine: nativeEngine(),
    fetchPackage: async () => fixture('1', ['storage'], ['userScripts']),
  });
  const record = await h.manager.installStore('p1', fixture().id);
  await h.manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'userScripts'],
    origins: [],
  });
  await h.manager.invalidateProfile('p1');
  delete h.sessions.get('p1').extensions.getZacroCapabilities;
  await h.manager.restore('p1');
  assert.equal(h.manager.list('p1')[0].enabled, false);
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
});

test('native post-load initialization must finish before activation and failure unloads the runtime', async (t) => {
  const started = deferred(),
    gate = deferred();
  const h = await setup(t, {
    onNativeLoaded: async () => {
      started.resolve();
      await gate.promise;
      throw Error('preference initialization failed');
    },
  });
  const pending = h.manager.installStore('p1', fixture().id);
  const rejected = assert.rejects(pending, /preference initialization/);
  await Promise.race([started.promise, new Promise((resolve) => setTimeout(resolve, 30))]);
  assert.equal(h.manager.list('p1').length, 0);
  gate.resolve();
  await rejected;
  assert.equal(h.manager.resolveExtension('p1', fixture().id), null);
  assert.equal(h.events.at(-1)[0], 'unload');
});

test('expired original caller during native permission await unloads and durably disables without granting rights', async (t) => {
  let valid = true;
  const gate = deferred(),
    started = deferred(),
    engine = nativeEngine();
  engine.setZacroReviewedPermissions = async () => {
    started.resolve();
    await gate.promise;
  };
  const h = await setup(t, {
    engine,
    fetchPackage: async () => fixture('1', ['storage'], ['tabs']),
    captureOperationGuard: () => () => {
      if (!valid) throw Error('Original caller expired');
    },
  });
  const record = await h.manager.installStore('p1', fixture().id);
  const pending = h.manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'tabs'],
    origins: [],
  });
  const rejected = assert.rejects(pending, /Original caller expired/);
  await started.promise;
  valid = false;
  gate.resolve();
  await rejected;
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
  assert.equal(h.manager.list('p1')[0].enabled, false);
  assert.deepEqual(h.manager.list('p1')[0].grants, record.grants);
  const saved = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json')));
  assert.equal(saved.extensions[0].enabled, false);
});

test('compensating native grant cancellation preserves page documents without asking to reload', async (t) => {
  let reloads = 0;
  const h = await setup(t, {
    onDeactivated: async () => {
      reloads++;
      return { requiresPageReload: false };
    },
  });
  const record = await h.manager.installStore('p1', fixture().id);
  const disabled = await h.manager.disable('p1', record.id, { preservePages: true });
  assert.equal(reloads, 0);
  assert.equal(disabled.enabled, false);
  assert.equal(disabled.requiresPageReload, true);
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
});

test('native callers can await committed manager readiness before reading startup extension state', async (t) => {
  const started = deferred(),
    gate = deferred();
  t.after(() => gate.resolve());
  const h = await setup(t, {
    onNativeLoaded: async () => {
      started.resolve();
      await gate.promise;
    },
  });
  const id = fixture().id,
    pending = h.manager.installStore('p1', id);
  await started.promise;
  let ready = false;
  const readiness = h.manager.whenReady('p1', id).then(() => {
    ready = true;
  });
  await Promise.resolve();
  assert.equal(ready, false);
  assert.equal(h.manager.list('p1').length, 0);
  gate.resolve();
  await pending;
  await readiness;
  assert.equal(h.manager.list('p1')[0].enabled, true);
});

for (const kind of ['permissions', 'origins'])
  test(`native approval rebases only its reviewed ${kind} delta after an unrelated completed removal`, async (t) => {
    const dialog = deferred(),
      entered = deferred();
    t.after(() => dialog.resolve(true));
    const engine = nativeEngine(),
      nativeSets = [];
    engine.setZacroReviewedPermissions = async (_id, grants) => nativeSets.push(structuredClone(grants));
    const h = await setup(t, {
      engine,
      fetchPackage: async () =>
        fixture('1', ['storage'], ['tabs', 'contextMenus'], ['https://a.example/*', 'https://b.example/*']),
    });
    const record = await h.manager.installStore('p1', fixture().id);
    await h.manager.changePermissions('p1', record.id, {
      permissions: ['storage', 'tabs'],
      origins: ['https://a.example/*'],
    });
    const { ExtensionAPI } = require('../src/main/extensions/api.cjs'),
      events = [];
    const api = new ExtensionAPI({
      resolveExtension: (p, id) => h.manager.resolveExtension(p, id),
      tabs: { get: async () => ({ id: 10, url: 'https://target.example/' }) },
      dialogs: {
        requestPermissions: async () => {
          entered.resolve();
          return dialog.promise;
        },
      },
      changePermissions: (p, id, grants) => h.manager.changePermissions(p, id, grants),
      changePermissionDelta: (p, id, details, remove) =>
        h.manager.changePermissionDelta(p, id, details, remove),
      emit: (...args) => events.push(args),
    });
    const context = api.context('p1', record.id);
    await api.activateAction('p1', record.id, 10);
    const requested =
      kind === 'permissions' ? { permissions: ['contextMenus'] } : { origins: ['https://b.example/*'] };
    const removed = kind === 'permissions' ? { permissions: ['tabs'] } : { origins: ['https://a.example/*'] };
    const pending = api.call(context, 'permissions.request', [requested]);
    await entered.promise;
    await api.call(context, 'permissions.remove', [removed]);
    assert.equal(h.manager.resolveExtension('p1', record.id).generation, record.generation);
    dialog.resolve(true);
    assert.equal(await pending, true);
    const saved = h.manager.list('p1')[0],
      revoked = removed[kind][0],
      approved = requested[kind][0];
    assert.equal(saved.grants[kind].includes(revoked), false);
    assert.equal(saved.grants[kind].includes(approved), true);
    assert.deepEqual(nativeSets.at(-1), saved.grants);
    const durable = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json')));
    assert.deepEqual(durable.extensions[0].grants, saved.grants);
    assert.equal(durable.extensions[0].grants[kind].includes(revoked), false);
    assert.deepEqual(events.filter((event) => event[2] === 'permissions.onAdded').at(-1)[3], [
      {
        permissions: kind === 'permissions' ? [approved] : [],
        origins: kind === 'origins' ? [approved] : [],
      },
    ]);
  });
test('overlapping native permission reductions serialize without unloading or reviving either removed grant after restore', async (t) => {
  const gate = deferred(),
    entered = deferred();
  t.after(() => gate.resolve());
  let deferredUpdate = false;
  const nativeSets = [],
    engine = nativeEngine();
  engine.setZacroReviewedPermissions = async (_id, grants) => {
    nativeSets.push(structuredClone(grants));
    if (deferredUpdate) {
      deferredUpdate = false;
      entered.resolve();
      await gate.promise;
    }
  };
  const h = await setup(t, {
    engine,
    fetchPackage: async () => fixture('1', ['storage'], ['tabs', 'contextMenus']),
  });
  const record = await h.manager.installStore('p1', fixture().id);
  await h.manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'tabs', 'contextMenus'],
    origins: [],
  });
  const unloads = h.events.filter((event) => event[0] === 'unload').length;
  deferredUpdate = true;
  const first = h.manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'contextMenus'],
    origins: [],
  });
  const results = Promise.allSettled([first]);
  await entered.promise;
  const second = h.manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'tabs'],
    origins: [],
  });
  const secondResult = Promise.allSettled([second]);
  gate.resolve();
  const settled = [...(await results), ...(await secondResult)];
  assert.deepEqual(
    settled.map((value) => value.status),
    ['fulfilled', 'fulfilled'],
  );
  const saved = h.manager.list('p1')[0];
  assert.equal(saved.enabled, true);
  assert.equal(saved.generation, record.generation);
  assert.deepEqual(saved.grants, { permissions: ['storage'], origins: [] });
  assert.deepEqual(h.manager.resolveExtension('p1', record.id).grants, saved.grants);
  assert.equal(h.events.filter((event) => event[0] === 'unload').length, unloads);
  assert.deepEqual(nativeSets.at(-1), saved.grants);
  await h.manager.invalidateProfile('p1');
  await h.manager.restore('p1');
  assert.equal(h.manager.list('p1')[0].enabled, true);
  assert.deepEqual(h.manager.resolveExtension('p1', record.id).grants, saved.grants);
});

test('native setter failure with another queued mutation durably disables the original record and cannot revive on restore', async (t) => {
  const gate = deferred(),
    entered = deferred();
  t.after(() => gate.resolve());
  let fail = false;
  const engine = nativeEngine();
  engine.setZacroReviewedPermissions = async () => {
    if (fail) {
      entered.resolve();
      await gate.promise;
      throw Error('Native dispatch failed');
    }
  };
  const h = await setup(t, {
    engine,
    fetchPackage: async () => fixture('1', ['storage'], ['tabs', 'contextMenus']),
  });
  const record = await h.manager.installStore('p1', fixture().id);
  await h.manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'tabs', 'contextMenus'],
    origins: [],
  });
  fail = true;
  const first = h.manager.changePermissionDelta('p1', record.id, { permissions: ['tabs'] }, true);
  const caughtFirst = first.catch((error) => error);
  await entered.promise;
  const second = h.manager.changePermissionDelta('p1', record.id, { permissions: ['contextMenus'] }, true);
  const caughtSecond = second.catch((error) => error);
  gate.resolve();
  assert.match((await caughtFirst).message, /Native dispatch failed/);
  assert.match((await caughtSecond).message, /enabled adapted/);
  assert.equal(h.manager.list('p1')[0].enabled, false);
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
  const disk = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json')));
  assert.equal(disk.extensions[0].enabled, false);
  await h.manager.invalidateProfile('p1');
  await h.manager.restore('p1');
  assert.equal(h.manager.list('p1')[0].enabled, false);
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
});
test('lifecycle cancellation followed by a failed queued update still records the exact original native generation as disabled', async (t) => {
  const gate = deferred(),
    entered = deferred();
  t.after(() => gate.resolve());
  let hold = false,
    offline = false;
  const engine = nativeEngine();
  engine.setZacroReviewedPermissions = async () => {
    if (hold) {
      entered.resolve();
      await gate.promise;
    }
  };
  const h = await setup(t, {
    engine,
    fetchPackage: async () => {
      if (offline) throw Error('Offline update');
      return fixture('1', ['storage'], ['tabs']);
    },
  });
  const record = await h.manager.installStore('p1', fixture().id);
  hold = true;
  const mutation = h.manager.changePermissionDelta('p1', record.id, { permissions: ['tabs'] });
  const caught = mutation.catch((error) => error);
  await entered.promise;
  offline = true;
  const update = h.manager.update('p1', record.id);
  const caughtUpdate = update.catch((error) => error);
  gate.resolve();
  assert.match((await caught).message, /cancel|Stale/);
  assert.match((await caughtUpdate).message, /Offline/);
  assert.equal(h.manager.list('p1')[0].enabled, false);
  assert.equal(h.manager.resolveExtension('p1', record.id), null);
  assert.deepEqual(h.manager.list('p1')[0].grants, record.grants);
});

test('permanent native cleanup fences rapid reinstall and survives restart after reset failure', async (t) => {
  const engine = nativeEngine(),
    entered = deferred(),
    release = deferred();
  let resets = 0;
  engine.resetZacroExtensionState = async () => {
    resets++;
    entered.resolve();
    await release.promise;
  };
  const h = await setup(t, { engine });
  const first = await h.manager.installStore('p1', fixture().id);
  const removed = h.manager.remove('p1', first.id);
  removed.catch(() => {});
  const reinstalled = h.manager.installStore('p1', first.id);
  reinstalled.catch(() => {});
  await new Promise(setImmediate);
  assert.equal(resets, 1, 'permanent removal must begin native cleanup before queued teardown');
  await entered.promise;
  const loadsBefore = h.events.filter((e) => e[0] === 'load').length;
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(h.events.filter((e) => e[0] === 'load').length, loadsBefore);
  release.resolve();
  await Promise.allSettled([removed]);
  const next = await reinstalled;
  assert.equal(next.enabled, true);
  assert.equal(resets, 1);
  await h.manager.disable('p1', next.id);
  await h.manager.enable('p1', next.id);
  assert.equal(resets, 1, 'ordinary disable/enable preserves registrations');
  h.sessions.get('p1').extensions.resetZacroExtensionState = async () => {
    throw Error('disk unavailable');
  };
  await assert.rejects(h.manager.remove('p1', next.id), /disk unavailable/);
  const state = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json')));
  assert.deepEqual(state.pendingNativeRemovals, [next.id]);
  h.sessions.get('p1').extensions.resetZacroExtensionState = async () => {
    resets++;
  };
  await h.manager.close();
  const restarted = new ExtensionManager(h.options);
  h.setManager(restarted);
  t.after(() => restarted.close());
  await restarted.restore('p1');
  assert.equal(resets, 2, 'restart completes persisted cleanup even without an installed record');
  assert.equal((await restarted.installStore('p1', next.id)).enabled, true);
});

test('native optional nativeMessaging removal publishes revocation before same-generation regrant', async (t) => {
  const notifications = [];
  const h = await setup(t, {
    engine: nativeEngine(),
    fetchPackage: async () => fixture('1', ['storage'], ['nativeMessaging']),
    onPermissionsChanged: (profileId, extensionId, change) =>
      notifications.push({ profileId, extensionId, change }),
  });
  const installed = await h.manager.installStore('p1', fixture().id);
  await h.manager.changePermissionDelta('p1', installed.id, { permissions: ['nativeMessaging'] }, false);
  const generation = h.manager.resolveExtension('p1', installed.id).generation;
  await h.manager.changePermissionDelta('p1', installed.id, { permissions: ['nativeMessaging'] }, true);
  await h.manager.changePermissionDelta('p1', installed.id, { permissions: ['nativeMessaging'] }, false);
  assert.equal(h.manager.resolveExtension('p1', installed.id).generation, generation);
  assert.equal(notifications.length, 3);
  assert.deepEqual(notifications[1], {
    profileId: 'p1',
    extensionId: installed.id,
    change: {
      before: { permissions: ['nativeMessaging', 'storage'], origins: [] },
      after: { permissions: ['storage'], origins: [] },
    },
  });
});

test('removal after runtime downgrade retains a permanent native cleanup tombstone', async (t) => {
  const h = await setup(t, { engine: nativeEngine() });
  const installed = await h.manager.installStore('p1', fixture().id);
  await h.manager.disable('p1', installed.id);
  h.sessions.get('p1').extensions.resetZacroExtensionState = undefined;
  await h.manager.enable('p1', installed.id);
  assert.equal(h.manager.list('p1')[0].current.nativeReviewedPermissions, false);
  await h.manager.disable('p1', installed.id);
  await assert.rejects(h.manager.remove('p1', installed.id), /complete custom runtime/);
  const state = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json')));
  assert.deepEqual(state.pendingNativeRemovals, [installed.id]);
  assert.equal(state.extensions.length, 0);
  Object.assign(h.sessions.get('p1').extensions, nativeEngine());
  assert.equal((await h.manager.installStore('p1', installed.id)).enabled, true);
  const cleaned = JSON.parse(await fs.readFile(path.join(h.manager.profilePath('p1'), 'state.json')));
  assert.deepEqual(cleaned.pendingNativeRemovals, []);
});
