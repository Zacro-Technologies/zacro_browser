'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { SyncStorage } = require('../src/main/sync/storage.cjs');

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-storage-'));
  const events = [];
  let storage = new SyncStorage({ directory, onChanged: (...args) => events.push(args) });
  t.after(() => {
    storage.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return {
    get storage() {
      return storage;
    },
    events,
    restart() {
      storage.close();
      storage = new SyncStorage({ directory });
    },
  };
}
test('sync storage persists distinct namespaces, special keys, defaults and exact change events', (t) => {
  const f = fixture(t);
  const set = JSON.parse('{"__proto__":{"safe":true},"constructor":3,"theme":"dark"}');
  f.storage.call('profile-a/extension', 'set', [set]);
  assert.deepEqual(f.storage.call('profile-a/extension', 'get', [null]), set);
  assert.deepEqual(f.storage.call('profile-b/extension', 'get', [null]), {});
  assert.deepEqual(f.storage.call('profile-a/extension', 'get', [{ theme: 'light', missing: 4 }]), {
    theme: 'dark',
    missing: 4,
  });
  assert.equal({}.safe, undefined);
  f.storage.call('profile-a/extension', 'set', [set]);
  assert.equal(f.events.length, 1);
  assert.equal(f.events[0][1].theme.newValue, 'dark');
  f.restart();
  assert.deepEqual(f.storage.call('profile-a/extension', 'getKeys', []).sort(), [
    '__proto__',
    'constructor',
    'theme',
  ]);
  assert.equal(
    f.storage.call('profile-a/extension', 'getBytesInUse', ['theme']),
    Buffer.byteLength('theme') + Buffer.byteLength('"dark"'),
  );
  f.storage.call('profile-a/extension', 'remove', [['theme', 'missing']]);
  f.storage.call('profile-a/extension', 'clear', []);
  assert.deepEqual(f.storage.call('profile-a/extension', 'get', []), {});
});
test('storage rejects unsupported serialization and validates atomic UTF-8/item/count/total quotas', (t) => {
  const { storage } = fixture(t);
  storage.call('a', 'set', [{ saved: true }]);
  for (const invalid of [undefined, NaN, Infinity, 1n, () => {}, new Date(), new Map(), [, 1]]) {
    assert.throws(() => storage.call('a', 'set', [{ first: 1, invalid }]), /serializ|JSON|value/i);
  }
  const circular = {};
  circular.circular = circular;
  assert.throws(() => storage.call('a', 'set', [circular]), /serializ|JSON|value/i);
  assert.deepEqual(storage.call('a', 'get', []), { saved: true });
  storage.call('boundary', 'set', [{ k: 'x'.repeat(8189) }]);
  assert.equal(storage.call('boundary', 'getBytesInUse', []), 8192);
  assert.throws(() => storage.call('a', 'set', [{ k: 'x'.repeat(8190) }]), /QUOTA_BYTES_PER_ITEM/);
  assert.throws(() => storage.call('a', 'set', [{ k: '界'.repeat(2731) }]), /QUOTA_BYTES_PER_ITEM/);
  const many = Object.fromEntries(Array.from({ length: 513 }, (_, i) => ['key' + i, 1]));
  assert.throws(() => storage.call('a', 'set', [many]), /MAX_ITEMS/);
  const large = Object.fromEntries(Array.from({ length: 13 }, (_, i) => ['key' + i, 'x'.repeat(8000)]));
  assert.throws(() => storage.call('a', 'set', [large]), /QUOTA_BYTES/);
});
test('access level and rolling write rates are enforced on every call and survive restart', (t) => {
  const f = fixture(t),
    now = 1_000_000;
  f.storage.call('a', 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }]);
  assert.throws(() => f.storage.call('a', 'get', [], { trusted: false }), /access/i);
  assert.throws(
    () =>
      f.storage.call('a', 'setAccessLevel', [{ accessLevel: 'TRUSTED_AND_UNTRUSTED_CONTEXTS' }], {
        trusted: false,
      }),
    /access/i,
  );
  f.restart();
  assert.throws(() => f.storage.call('a', 'get', [], { trusted: false }), /access/i);
  for (let i = 0; i < 120; i++) f.storage.call('rate', 'set', [{ i }], { now });
  assert.throws(() => f.storage.call('rate', 'clear', [], { now }), /MAX_WRITE_OPERATIONS_PER_MINUTE/);
  f.storage.call('rate', 'clear', [], { now: now + 60001 });
  for (let minute = 0; minute < 15; minute++)
    for (let i = 0; i < 120; i++) f.storage.call('hour', 'set', [{ i }], { now: now + minute * 60001 });
  assert.throws(
    () => f.storage.call('hour', 'clear', [], { now: now + 15 * 60001 }),
    /MAX_WRITE_OPERATIONS_PER_HOUR/,
  );
});
