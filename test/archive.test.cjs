'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { BrowserStore, createInitialState, hydrate } = require('../src/core/store.cjs');
const { ARCHIVE_HOURS, archiveHours, archiveCandidate } = require('../src/core/archive.cjs');
const hour = 3600000;

test('new installations use 12 hours; migration preserves every explicit legacy cadence including Never', () => {
  assert.equal(createInitialState().settings.archiveAfterHours, 12);
  for (const cadence of ARCHIVE_HOURS) {
    const raw = createInitialState();
    raw.settings.archiveAfterHours = cadence;
    delete raw.profiles[0].archiveAfterHours;
    const state = hydrate(raw);
    assert.equal(archiveHours(state, 'default'), cadence);
    assert.equal(state.profiles[0].archiveAfterHours, null);
  }
  const raw = createInitialState();
  delete raw.settings.archiveAfterHours;
  assert.equal(hydrate(raw).settings.archiveAfterHours, 12);
});

test('profiles inherit the default cadence, can opt out, and retain overrides across hydration', () => {
  const store = new BrowserStore();
  const work = store.dispatch('profile:create', { name: 'Work' });
  assert.equal(archiveHours(store.state, work.id), 12);
  store.dispatch('settings:update', { values: { archiveAfterHours: 24 } });
  assert.equal(archiveHours(store.state, work.id), 24);
  store.dispatch('profile:update', { id: work.id, values: { archiveAfterHours: 0 } });
  assert.equal(archiveHours(hydrate(store.snapshot()), work.id), 0);
  store.dispatch('settings:update', { values: { archiveAfterHours: 0 } });
  store.dispatch('profile:update', { id: work.id, values: { archiveAfterHours: 12 } });
  assert.equal(archiveHours(store.state, work.id), 12);
  assert.equal(archiveHours(store.state, 'default'), 0);
  store.dispatch('profile:update', { id: work.id, values: { archiveAfterHours: null } });
  assert.equal(archiveHours(store.state, work.id), 0);
  for (const value of [undefined, -1, 2, '12', Infinity, {}, []])
    assert.throws(() =>
      store.dispatch('profile:update', { id: work.id, values: { archiveAfterHours: value } }),
    );
});

test('archive eligibility uses time since viewing, not creation, at the full cadence boundary', () => {
  const state = createInitialState();
  const now = Date.now();
  const tab = {
    id: 'idle',
    profileId: 'default',
    createdAt: now - 100 * hour,
    lastActiveAt: now - 11 * hour,
  };
  assert.equal(archiveCandidate(state, tab, now), false);
  assert.equal(archiveCandidate(state, { ...tab, lastActiveAt: now - 12 * hour }, now), true);
  assert.equal(archiveCandidate(state, { ...tab, lastActiveAt: now + hour }, now), false);
  assert.equal(archiveCandidate(state, { ...tab, lastActiveAt: NaN }, now), false);
});

test('default-profile overrides migrate to the visible shared setting and API edits keep one source of truth', () => {
  const raw = createInitialState();
  raw.profiles[0].archiveAfterHours = 72;
  const store = new BrowserStore();
  store.state = hydrate(raw);
  assert.equal(store.state.settings.archiveAfterHours, 72);
  assert.equal(store.state.profiles[0].archiveAfterHours, null);
  const work = store.dispatch('profile:create', { name: 'Work' });
  assert.equal(archiveHours(store.state, work.id), 72);
  store.dispatch('profile:update', { id: 'default', values: { archiveAfterHours: 0 } });
  assert.equal(store.state.settings.archiveAfterHours, 0);
  assert.equal(store.state.profiles[0].archiveAfterHours, null);
  assert.equal(archiveHours(store.state, work.id), 0);
  store.dispatch('profile:update', { id: 'default', values: { archiveAfterHours: null } });
  assert.equal(store.state.settings.archiveAfterHours, 0);
});

test('when the default profile is removed, its replacement preserves its explicit cadence as the new default', () => {
  const store = new BrowserStore();
  const work = store.dispatch('profile:create', { name: 'Work', archiveAfterHours: 48 });
  const extra = store.dispatch('profile:create', { name: 'Other' });
  store.dispatch('profile:delete', { id: 'default' });
  assert.equal(store.state.settings.archiveAfterHours, 48);
  assert.equal(store.state.profiles.find((profile) => profile.id === work.id).archiveAfterHours, null);
  assert.equal(archiveHours(store.state, extra.id), 48);
  store.dispatch('profile:update', { id: work.id, values: { archiveAfterHours: 168 } });
  assert.equal(archiveHours(hydrate(store.snapshot()), extra.id), 168);
});

test('active tabs, Favorites, Space pins and foldered tabs never automatically archive', () => {
  const state = createInitialState();
  const now = Date.now();
  const tab = { id: 'idle', profileId: 'default', lastActiveAt: now - 48 * hour };
  for (const protection of [{ pinned: true }, { favorite: true }, { folderId: 'folder' }])
    assert.equal(archiveCandidate(state, { ...tab, ...protection }, now), false);
  state.activeTabId = tab.id;
  assert.equal(archiveCandidate(state, tab, now), false);
});

test('switching tabs and Spaces resets the viewed and departing tabs after a long reading session', () => {
  const store = new BrowserStore();
  const first = store.dispatch('tab:create', { url: 'https://example.com/first' });
  const second = store.dispatch('tab:create', { url: 'https://example.com/second' });
  const stale = Date.now() - 48 * hour;
  store.state.tabs.forEach((tab) => (tab.lastActiveAt = stale));
  store.dispatch('tab:activate', { id: first.id });
  assert.ok(store.state.tabs.every((tab) => tab.lastActiveAt > stale));
  store.dispatch('space:create', { name: 'Work' });
  store.state.tabs.find((tab) => tab.id === first.id).lastActiveAt = stale;
  store.dispatch('space:activate', { id: 'home' });
  assert.equal(store.state.activeTabId, first.id);
  assert.ok(store.state.tabs.find((tab) => tab.id === first.id).lastActiveAt > stale);
  assert.ok(store.state.tabs.some((tab) => tab.id === second.id));
});

test('restart keeps elapsed wall-clock idle time; scoped archive preserves exclusions and restores a fresh timer', () => {
  const store = new BrowserStore();
  const old = store.dispatch('tab:create', { url: 'https://example.com/old' });
  const protectedTab = store.dispatch('tab:create', { url: 'https://example.com/protected' });
  store.dispatch('tab:create', { url: 'https://example.com/current' });
  store.state.tabs.forEach((tab) => (tab.lastActiveAt = Date.now() - 48 * hour));
  store.state = hydrate(store.snapshot());
  assert.equal(store.dispatch('tab:archive-stale', { ids: [old.id], excludeIds: [protectedTab.id] }), 1);
  assert.equal(store.state.archive[0].id, old.id);
  assert.ok(store.state.tabs.some((tab) => tab.id === protectedTab.id));
  store.dispatch('tab:restore', { id: old.id });
  const restored = store.state.tabs.find((tab) => tab.id === old.id);
  assert.ok(restored.lastActiveAt > Date.now() - hour);
  assert.equal(store.state.archive.length, 0);
});

test('a profile override still archives when the default is Never, without affecting other profiles', () => {
  const store = new BrowserStore();
  const personal = store.dispatch('tab:create', { url: 'https://example.com/personal' });
  const work = store.dispatch('profile:create', { name: 'Work', archiveAfterHours: 12 });
  const old = store.dispatch('tab:create', { url: 'https://example.com/work' });
  store.dispatch('tab:create', { url: 'https://example.com/current' });
  store.dispatch('settings:update', { values: { archiveAfterHours: 0 } });
  store.state.tabs.forEach((tab) => (tab.lastActiveAt = Date.now() - 24 * hour));
  assert.equal(store.dispatch('tab:archive-stale'), 1);
  assert.ok(store.state.tabs.some((tab) => tab.id === personal.id));
  assert.equal(store.state.archive[0].id, old.id);
  assert.equal(store.state.archive[0].profileId, work.id);
});

for (const [sourceHours, destinationHours, overrideHours] of [
  [0, 12, 48],
  [24, 0, 0],
])
  test(`import preserves source ${sourceHours || 'Never'} cadence, inheritance and explicit overrides without changing destination defaults`, () => {
    const source = new BrowserStore();
    source.dispatch('settings:update', { values: { archiveAfterHours: sourceHours } });
    source.dispatch('profile:create', { name: 'Inherited' });
    source.dispatch('profile:create', { name: 'Explicit', archiveAfterHours: overrideHours });
    const destination = new BrowserStore();
    destination.dispatch('settings:update', { values: { archiveAfterHours: destinationHours } });
    const existing = destination.dispatch('profile:create', { name: 'Existing' });
    destination.importData(source.exportData());
    assert.equal(destination.state.settings.archiveAfterHours, destinationHours);
    assert.equal(archiveHours(destination.state, existing.id), destinationHours);
    for (const [name, expected] of [
      ['Personal', sourceHours],
      ['Inherited', sourceHours],
      ['Explicit', overrideHours],
    ]) {
      const imported = destination.state.profiles.find((profile) => profile.name === `${name} (imported)`);
      assert.ok(imported);
      assert.equal(imported.archiveAfterHours, expected);
      assert.equal(archiveHours(hydrate(destination.snapshot()), imported.id), expected);
    }
    destination.dispatch('settings:update', { values: { archiveAfterHours: 72 } });
    assert.equal(archiveHours(destination.state, existing.id), 72);
    const inheritedImport = destination.state.profiles.find(
      (profile) => profile.name === 'Inherited (imported)',
    );
    assert.equal(
      archiveHours(destination.state, inheritedImport.id),
      sourceHours,
      'A later destination-default change must not silently replace the preserved source choice',
    );
  });
