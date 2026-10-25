'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { FontSettingsController } = require('../src/main/extensions/font-settings.cjs');
const { ExtensionAPI } = require('../src/main/extensions/api.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-fonts-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const ids = ['a'.repeat(32), 'b'.repeat(32), 'c'.repeat(32)];
  const records = new Map(
    ['one', 'two'].map((p) => [
      p,
      ids.map((id, i) => ({
        id,
        installedAt: 100 + i,
        enabled: true,
        generation: 1,
        grants: { permissions: ['fontSettings'] },
      })),
    ]),
  );
  const defaults = {
    fonts: [{ script: 'Zyyy', genericFamily: 'serif', fontId: 'Native Serif' }],
    defaultFontSize: 19,
    defaultFixedFontSize: 15,
    minimumFontSize: 2,
  };
  const native = new Map();
  const events = [];
  const sessions = new Map(
    ['one', 'two'].map((p) => {
      native.set(p, structuredClone(defaults));
      return [
        p,
        {
          extensions: {
            getZacroCapabilities: () => ({
              version: 1,
              reviewedPermissions: true,
              activeTab: true,
              userScripts: true,
              fontSettings: true,
            }),
            setZacroReviewedPermissions() {},
            grantZacroActiveTab() {},
            setZacroUserScriptsEnabled() {},
            async resetZacroExtensionState() {},
            getZacroFontPreferences: () => structuredClone(native.get(p)),
            setZacroFontPreferences: (value) => {
              const fonts = new Map(defaults.fonts.map((f) => [f.script + ':' + f.genericFamily, f]));
              for (const f of value.fonts) fonts.set(f.script + ':' + f.genericFamily, structuredClone(f));
              native.set(p, {
                ...structuredClone(defaults),
                ...structuredClone(value),
                fonts: [...fonts.values()],
              });
            },
            getZacroFontList: async () => [
              { fontId: 'Native Serif', displayName: 'Native Serif' },
              { fontId: 'Test Sans', displayName: 'Test Sans' },
            ],
          },
        },
      ];
    }),
  );
  const options = {
    getProfile: (p) => (p === 'private' ? { id: p, private: true } : { id: p }),
    profilePath: (p) => path.join(root, p),
    getSession: (p) => sessions.get(p),
    listExtensions: (p) => records.get(p) || [],
    resolveExtension: (p, id) => records.get(p)?.find((r) => r.id === id && r.enabled),
    emit: (...e) => events.push(e),
  };
  const controller = new FontSettingsController(options);
  const context = (id = ids[0], profileId = 'one') => ({
    profileId,
    extensionId: id,
    generation: 1,
    kind: 'extension-page',
  });
  const call = (method, details, id = ids[0], p = 'one') =>
    controller.call(context(id, p), method, details === undefined ? [] : [details]);
  return { root, ids, records, native, events, sessions, options, controller, context, call, defaults };
}

test('native defaults, all methods, empty font fallback, and profile isolation', async (t) => {
  const f = fixture(t);
  assert.deepEqual(await f.call('getFont', { genericFamily: 'serif' }), {
    fontId: 'Native Serif',
    levelOfControl: 'controllable_by_this_extension',
  });
  assert.deepEqual(await f.call('getDefaultFontSize'), {
    pixelSize: 19,
    levelOfControl: 'controllable_by_this_extension',
  });
  for (const [suffix, key, value] of [
    ['DefaultFontSize', 'defaultFontSize', 25],
    ['DefaultFixedFontSize', 'defaultFixedFontSize', 21],
    ['MinimumFontSize', 'minimumFontSize', 0],
  ]) {
    await f.call('set' + suffix, { pixelSize: value });
    assert.equal((await f.call('get' + suffix)).pixelSize, value);
    assert.equal(f.native.get('two')[key], f.defaults[key]);
    await f.call('clear' + suffix, {});
    assert.equal((await f.call('get' + suffix)).pixelSize, f.defaults[key]);
  }
  await f.call('setFont', { genericFamily: 'sansserif', script: 'Jpan', fontId: '' });
  assert.deepEqual(await f.call('getFont', { genericFamily: 'sansserif', script: 'Jpan' }), {
    fontId: '',
    levelOfControl: 'controlled_by_this_extension',
  });
  await f.call('clearFont', { genericFamily: 'sansserif', script: 'Jpan' });
  assert.equal(
    (await f.call('getFont', { genericFamily: 'sansserif', script: 'Jpan' })).levelOfControl,
    'controllable_by_this_extension',
  );
  assert.equal((await f.call('getFontList')).length, 2);
});

test('installation precedence survives older writes, restart, disable, reenable, revoke and uninstall', async (t) => {
  const f = fixture(t),
    [older, newer] = f.ids;
  await f.call('setFont', { genericFamily: 'serif', fontId: 'New' }, newer);
  await f.call('setFont', { genericFamily: 'serif', fontId: 'Old' }, older);
  assert.deepEqual(await f.call('getFont', { genericFamily: 'serif' }, older), {
    fontId: 'New',
    levelOfControl: 'controlled_by_other_extensions',
  });
  const restarted = new FontSettingsController(f.options);
  await restarted.reconcile('one');
  assert.equal(f.native.get('one').fonts[0].fontId, 'New');
  f.records.get('one')[1].enabled = false;
  await restarted.reconcile('one');
  assert.equal(f.native.get('one').fonts[0].fontId, 'Old');
  f.records.get('one')[1].enabled = true;
  await restarted.reconcile('one');
  assert.equal(f.native.get('one').fonts[0].fontId, 'New');
  f.records.get('one')[1].grants.permissions = [];
  await restarted.reconcile('one');
  assert.equal(f.native.get('one').fonts[0].fontId, 'Old');
  f.records.get('one').splice(0, 2);
  await restarted.reconcile('one');
  assert.equal(f.native.get('one').fonts[0].fontId, 'Native Serif');
  const disk = JSON.parse(fs.readFileSync(path.join(f.root, 'one', 'font-settings.json'), 'utf8'));
  assert.deepEqual(disk.owners, {});
});

test('clear removes own setting only and control transitions are per receiver with no redundant events', async (t) => {
  const f = fixture(t),
    [older, newer, latest] = f.ids;
  await f.call('setDefaultFontSize', { pixelSize: 28 }, newer);
  assert.deepEqual(
    f.events.map((e) => [e[0], e[1], e[2], e[3][0].levelOfControl]),
    [
      ['one', older, 'fontSettings.onDefaultFontSizeChanged', 'controlled_by_other_extensions'],
      ['one', newer, 'fontSettings.onDefaultFontSizeChanged', 'controlled_by_this_extension'],
      ['one', latest, 'fontSettings.onDefaultFontSizeChanged', 'controllable_by_this_extension'],
    ],
  );
  f.events.length = 0;
  await f.call('setDefaultFontSize', { pixelSize: 22 }, older);
  assert.equal(f.events.length, 0);
  await f.call('clearDefaultFontSize', {}, older);
  assert.equal(f.native.get('one').defaultFontSize, 28);
  assert.equal(f.events.length, 0);
  f.records.get('one')[0].grants.permissions = [];
  f.events.length = 0;
  await f.call('clearDefaultFontSize', {}, newer);
  assert.equal(f.events.length, 2);
  assert(f.events.every((e) => e[1] !== older));
  await f.call('setDefaultFontSize', { pixelSize: 28 }, newer);
  f.events.length = 0;
  await f.call('setDefaultFontSize', { pixelSize: 28 }, latest);
  assert.equal(
    f.events.length,
    2,
    'equal effective values still report changed control for affected receivers',
  );
});

test('reject invalid shapes, scripts, sizes, untrusted, private, revoked and stock capabilities', async (t) => {
  const f = fixture(t);
  for (const [method, args] of [
    ['setFont', [{ genericFamily: 'sans-serif', fontId: 'A' }]],
    ['setFont', [{ genericFamily: 'serif', script: 'Fake', fontId: 'A' }]],
    ['setFont', [{ genericFamily: 'serif', fontId: 'a\0b' }]],
    ['setFont', [{ genericFamily: 'serif', fontId: 'a'.repeat(257) }]],
    ['setDefaultFontSize', [{ pixelSize: 0 }]],
    ['setMinimumFontSize', [{ pixelSize: 513 }]],
    ['setDefaultFontSize', [{ pixelSize: 20.1 }]],
    ['getFont', [{ genericFamily: 'serif', extra: true }]],
    ['getFont', []],
    ['getFontList', [{}]],
    ['getDefaultFontSize', [null]],
    ['getDefaultFontSize', [{}, {}]],
  ]) {
    await assert.rejects(f.controller.call(f.context(), method, args), /Invalid|Unsupported/);
  }
  await assert.rejects(
    f.controller.call({ ...f.context(), kind: 'content-script' }, 'getFontList', []),
    /Trusted/,
  );
  await assert.rejects(
    f.controller.call(f.context(f.ids[0], 'private'), 'getFontList', []),
    /profile|private/,
  );
  await assert.rejects(f.controller.call({ ...f.context(), generation: 0 }, 'getFontList', []), /Expired/);
  f.sessions.get('one').extensions.getZacroCapabilities = () => ({ version: 0 });
  await assert.rejects(f.call('getDefaultFontSize'), /Native font settings unavailable/);
});

test('native failure and cancellation never commit a false persisted selection', async (t) => {
  const f = fixture(t),
    api = f.sessions.get('one').extensions;
  await f.call('setDefaultFontSize', { pixelSize: 26 });
  const disk = fs.readFileSync(path.join(f.root, 'one', 'font-settings.json'), 'utf8');
  const real = api.setZacroFontPreferences;
  let fail = true;
  api.setZacroFontPreferences = (v) => {
    if (fail) {
      fail = false;
      throw new Error('native failed');
    }
    return real(v);
  };
  await assert.rejects(f.call('setDefaultFontSize', { pixelSize: 33 }), /native failed/);
  assert.equal(f.native.get('one').defaultFontSize, 26);
  assert.equal(fs.readFileSync(path.join(f.root, 'one', 'font-settings.json'), 'utf8'), disk);
  let release, entered;
  const arrived = new Promise((r) => (entered = r));
  api.setZacroFontPreferences = async (v) => {
    real(v);
    entered();
    await new Promise((r) => (release = r));
  };
  const pending = f.call('setDefaultFontSize', { pixelSize: 35 });
  await arrived;
  f.records.get('one')[0].enabled = false;
  api.setZacroFontPreferences = real;
  release();
  await assert.rejects(pending, /Expired/);
  assert.equal(f.native.get('one').defaultFontSize, 19, 'cancelled disabled owner must not remain native');
  assert.equal(fs.readFileSync(path.join(f.root, 'one', 'font-settings.json'), 'utf8'), disk);
});

test('facade requires permission and checks generation after native async work', async (t) => {
  const f = fixture(t),
    metadata = f.records.get('one')[0];
  const api = new ExtensionAPI({ resolveExtension: f.options.resolveExtension, fontSettings: f.controller });
  const context = api.context('one', f.ids[0]);
  assert.equal((await api.call(context, 'fontSettings.getDefaultFontSize', [])).pixelSize, 19);
  metadata.grants.permissions = [];
  await assert.rejects(api.call(context, 'fontSettings.getDefaultFontSize', []), /fontSettings permission/);
});

test('native defaults tolerate modern ICU script maps and preserve platform font names', async (t) => {
  const f = fixture(t);
  f.native.get('one').fonts.push({ script: 'Adlm', genericFamily: 'serif', fontId: 'Modern Script Default' });
  f.native.get('one').fonts[0].fontId = 'Native'.repeat(50);
  assert.equal((await f.call('getFont', { genericFamily: 'serif' })).fontId, 'Native'.repeat(50));
  await assert.rejects(
    f.call('setFont', { genericFamily: 'serif', fontId: 'あ'.repeat(100) }),
    /Invalid font ID/,
  );
});

test('uninstall ownership cannot revive when the same ID is immediately reinstalled', async (t) => {
  const f = fixture(t),
    id = f.ids[0],
    record = f.records.get('one')[0];
  await f.call('setDefaultFontSize', { pixelSize: 44 });
  f.records.get('one').shift();
  const removing = f.controller.reconcile('one');
  f.records.get('one').push({ ...record, generation: 2, installedAt: 900 });
  await removing;
  await f.controller.reconcile('one');
  assert.equal(f.native.get('one').defaultFontSize, 19);
});

test('equal install timestamps use ID precedence and disabled/revoked owners notify authorized peers', async (t) => {
  const f = fixture(t),
    [older, newer, latest] = f.ids;
  for (const record of f.records.get('one')) record.installedAt = 100;
  await f.call('setDefaultFixedFontSize', { pixelSize: 23 }, newer);
  await f.call('setDefaultFixedFontSize', { pixelSize: 21 }, older);
  assert.equal(f.native.get('one').defaultFixedFontSize, 23);
  f.events.length = 0;
  f.records.get('one')[1].enabled = false;
  await f.controller.reconcile('one');
  assert.deepEqual(
    f.events.map((e) => [e[1], e[2], e[3][0]]),
    [
      [
        older,
        'fontSettings.onDefaultFixedFontSizeChanged',
        { pixelSize: 21, levelOfControl: 'controlled_by_this_extension' },
      ],
      [
        latest,
        'fontSettings.onDefaultFixedFontSizeChanged',
        { pixelSize: 21, levelOfControl: 'controllable_by_this_extension' },
      ],
    ],
  );
  f.events.length = 0;
  f.records.get('one')[0].grants.permissions = [];
  await f.controller.reconcile('one');
  assert.deepEqual(
    f.events.map((e) => [e[1], e[3][0].pixelSize]),
    [[latest, 15]],
  );
});

test('profile cancellation and malformed saved data never replace native preferences', async (t) => {
  const f = fixture(t);
  const pending = f.call('setMinimumFontSize', { pixelSize: 20 });
  f.controller.forgetProfile('one');
  // call() guards at its asynchronous dispatch boundary; invalidate after entry
  // into the per-profile queue to exercise cancellation of already queued work.
  await Promise.resolve();
  f.controller.forgetProfile('one');
  await assert.rejects(pending, /Expired/);
  assert.equal(f.native.get('one').minimumFontSize, 2);
  fs.mkdirSync(path.join(f.root, 'one'), { recursive: true });
  fs.writeFileSync(
    path.join(f.root, 'one', 'font-settings.json'),
    JSON.stringify({ schema: 1, owners: { [f.ids[0]]: { defaultFontSize: 999 } } }),
  );
  const restarted = new FontSettingsController(f.options);
  await assert.rejects(restarted.reconcile('one'), /Invalid font pixel size/);
  assert.equal(f.native.get('one').defaultFontSize, 19);
});

test('startup calls wait for managed native activation readiness before changing preferences', async (t) => {
  const f = fixture(t);
  let release;
  const ready = new Promise((resolve) => (release = resolve));
  const starting = new FontSettingsController({ ...f.options, ready: () => ready });
  let settled = false;
  const pending = starting
    .call(f.context(), 'setDefaultFontSize', [{ pixelSize: 39 }])
    .then(() => (settled = true));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(settled, false);
  assert.equal(f.native.get('one').defaultFontSize, 19);
  release();
  await pending;
  assert.equal(f.native.get('one').defaultFontSize, 39);
});

test('stock uninstall discards durable ownership before same-ID reinstall and custom restart', async (t) => {
  const f = fixture(t),
    id = f.ids[0],
    record = f.records.get('one')[0];
  await f.call('setDefaultFontSize', { pixelSize: 44 });
  const api = f.sessions.get('one').extensions,
    nativeCapabilities = api.getZacroCapabilities;
  api.getZacroCapabilities = () => ({ version: 0 });
  const stock = new FontSettingsController(f.options);
  let nativeWrites = 0;
  const nativeSetter = api.setZacroFontPreferences;
  api.setZacroFontPreferences = () => {
    nativeWrites++;
    throw new Error('Stock must not write native preferences');
  };
  f.records.get('one').shift();
  const removal = stock.reconcile('one');
  f.records.get('one').push({ ...record, generation: 2, installedAt: 900 });
  await removal;
  const saved = JSON.parse(fs.readFileSync(path.join(f.root, 'one', 'font-settings.json'), 'utf8'));
  assert.equal(saved.owners[id], undefined);
  assert.equal(nativeWrites, 0);
  api.setZacroFontPreferences = nativeSetter;
  api.getZacroCapabilities = nativeCapabilities;
  const custom = new FontSettingsController(f.options);
  await custom.reconcile('one');
  assert.equal(f.native.get('one').defaultFontSize, 19);
});

test('stock disable retains durable owner for explicit enable on custom restart', async (t) => {
  const f = fixture(t),
    id = f.ids[0],
    record = f.records.get('one')[0];
  await f.call('setDefaultFontSize', { pixelSize: 44 });
  const api = f.sessions.get('one').extensions,
    nativeCapabilities = api.getZacroCapabilities;
  api.getZacroCapabilities = () => ({ version: 0 });
  const stock = new FontSettingsController(f.options);
  record.enabled = false;
  await stock.reconcile('one');
  const saved = JSON.parse(fs.readFileSync(path.join(f.root, 'one', 'font-settings.json'), 'utf8'));
  assert.equal(saved.owners[id].defaultFontSize, 44);
  api.getZacroCapabilities = nativeCapabilities;
  const custom = new FontSettingsController(f.options);
  await custom.reconcile('one');
  assert.equal(f.native.get('one').defaultFontSize, 19);
  record.enabled = true;
  await custom.reconcile('one');
  assert.equal(f.native.get('one').defaultFontSize, 44);
});
