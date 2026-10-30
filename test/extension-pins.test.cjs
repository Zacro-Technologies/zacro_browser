'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { BrowserStore, hydrate } = require('../src/core/store.cjs');

test('extension pins retain their order after restart and are isolated to regular profiles', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-extension-pins-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const store = new BrowserStore(directory);
  const first = 'a'.repeat(32),
    second = 'b'.repeat(32);
  const profile = store.state.profiles[0];
  store.dispatch('profile:extension-pins', { id: profile.id, ids: [second, first, second, 'invalid', null] });
  assert.deepEqual(profile.pinnedExtensionIds, [second, first]);
  const separate = store.dispatch('profile:create', { name: 'Separate' });
  assert.deepEqual(separate.pinnedExtensionIds, []);
  const privateProfile = store.dispatch('profile:create', { name: 'Private', private: true });
  assert.throws(
    () => store.dispatch('profile:extension-pins', { id: privateProfile.id, ids: [first] }),
    /private/,
  );
  assert.throws(() => store.dispatch('profile:extension-pins', { id: profile.id, ids: first }), /Choose/);
  store.flush();
  const restarted = new BrowserStore(directory);
  assert.deepEqual(restarted.state.profiles.find((item) => item.id === profile.id).pinnedExtensionIds, [
    second,
    first,
  ]);
  assert.deepEqual(restarted.state.profiles.find((item) => item.id === separate.id).pinnedExtensionIds, []);
  assert.equal(
    restarted.state.profiles.some((item) => item.private),
    false,
  );
});

test('extension pins are bounded, sanitized, and excluded from portable profile imports and exports', () => {
  const store = new BrowserStore();
  const profile = store.state.profiles[0];
  const ids = Array.from({ length: 300 }, (_, index) =>
    index
      .toString(16)
      .replace(/[0-9a-f]/g, (digit) => String.fromCharCode(97 + parseInt(digit, 16)))
      .padStart(32, 'a'),
  );
  store.dispatch('profile:extension-pins', { id: profile.id, ids });
  assert.equal(profile.pinnedExtensionIds.length, 256);
  const raw = structuredClone(store.state);
  raw.profiles[0].pinnedExtensionIds = ['a'.repeat(32), 'q'.repeat(32), 'a'.repeat(32), 3];
  assert.deepEqual(hydrate(raw).profiles[0].pinnedExtensionIds, ['a'.repeat(32)]);
  const portable = store.exportData();
  assert.equal(Object.hasOwn(portable.profiles[0], 'pinnedExtensionIds'), false);
  portable.profiles[0].pinnedExtensionIds = ['b'.repeat(32)];
  const imported = new BrowserStore();
  imported.importData(portable);
  assert(imported.state.profiles.every((item) => item.pinnedExtensionIds.length === 0));
});
