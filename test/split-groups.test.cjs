'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { BrowserStore, hydrate } = require('../src/core/store.cjs');
const { cleanSplitGroups } = require('../src/core/split-groups.cjs');

function pair(store, suffix = '') {
  const first = store.dispatch('tab:create', { url: `https://example.com/a${suffix}` });
  const second = store.dispatch('tab:create', { url: `https://example.com/b${suffix}` });
  const group = store.dispatch('split:create', { firstId: first.id, secondId: second.id });
  return { first, second, group };
}

test('multiple split groups survive selection, Spaces, restart and explicit unsplit', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-split-store-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new BrowserStore(dir);
  const one = pair(store);
  const ordinary = store.dispatch('tab:create', { url: 'https://example.com/ordinary' });
  store.dispatch('space:create', { name: 'Another Space' });
  const two = pair(store, '2');
  store.dispatch('tab:activate', { id: ordinary.id });
  store.flush();
  const reopened = new BrowserStore(dir);
  assert.deepEqual(
    reopened.state.splitGroups.map((group) => group.id),
    [one.group.id, two.group.id],
  );
  reopened.dispatch('tab:activate', { id: one.first.id });
  reopened.dispatch('split:remove', { tabId: one.first.id });
  assert.deepEqual(
    reopened.state.splitGroups.map((group) => group.id),
    [two.group.id],
  );
  assert(reopened.state.tabs.some((tab) => tab.id === one.first.id));
  assert(reopened.state.tabs.some((tab) => tab.id === one.second.id));
  reopened.flush();
});

test('saved split tabs resist automatic archival and preserve organization with restore-session off', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-split-archive-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new BrowserStore(dir);
  const { group } = pair(store);
  store.dispatch('tab:create', { url: 'https://example.com/ordinary' });
  for (const tab of store.state.tabs) tab.lastActiveAt = 1;
  store.dispatch('tab:archive-stale', { now: Date.now() });
  assert(group.tabIds.every((id) => store.state.tabs.some((tab) => tab.id === id)));
  store.dispatch('settings:update', { values: { restoreSession: false } });
  store.flush();
  const reopened = new BrowserStore(dir);
  assert.deepEqual(reopened.state.splitGroups[0], group);
  assert.equal(reopened.state.activeTabId, null);
  reopened.flush();
});

test('moving a split member carries its group; removing a member clears dangling associations', () => {
  const store = new BrowserStore();
  const { first, second, group } = pair(store);
  const destination = store.dispatch('space:create', { name: 'Destination' });
  store.dispatch('tab:move', { id: first.id, spaceId: destination.id });
  assert.equal(store.state.splitGroups[0].spaceId, destination.id);
  assert.equal(store.state.tabs.find((tab) => tab.id === second.id).spaceId, destination.id);
  store.dispatch('space:delete', { id: destination.id });
  assert.equal(store.state.splitGroups[0].spaceId, 'home');
  assert.equal(store.state.splitGroups[0].id, group.id);
  store.dispatch('tab:close', { id: second.id });
  assert.deepEqual(store.state.splitGroups, []);
});

test('group boundaries reject duplicates, foreign profiles and closed members; private groups stay local', () => {
  const store = new BrowserStore();
  const one = pair(store);
  assert.throws(() => store.dispatch('split:create', { firstId: one.first.id, secondId: one.first.id }));
  const other = store.dispatch('tab:create', { url: 'https://example.com/other' });
  assert.throws(
    () => store.dispatch('split:create', { firstId: one.first.id, secondId: other.id }),
    /Unsplit/,
  );
  store.dispatch('profile:create', { name: 'Private', private: true });
  const two = pair(store, 'private');
  assert.equal(store.persistedState().splitGroups.length, 1);
  assert.throws(() => store.dispatch('split:create', { firstId: one.first.id, secondId: two.first.id }));
  const raw = store.persistedState();
  raw.splitGroups.push({ id: 'bad', spaceId: 'home', tabIds: [one.first.id, 'missing'] });
  raw.splitGroups.push({ id: 'duplicate-member', spaceId: 'home', tabIds: one.group.tabIds });
  assert.equal(hydrate(raw).splitGroups.length, 1);
  assert.deepEqual(
    cleanSplitGroups([{ ...one.group, tabIds: [one.first.id, one.first.id] }], raw.tabs, raw.spaces),
    [],
  );
});

test('portable import remaps split group and member identities together', () => {
  const source = new BrowserStore();
  const { group } = pair(source);
  source.dispatch('split:resize', { id: group.id, ratio: 0.68 });
  const exported = source.exportData();
  const destination = new BrowserStore();
  destination.importData(exported);
  const imported = destination.state.splitGroups[0];
  assert.notEqual(imported.id, group.id);
  assert.equal(imported.ratio, 0.68);
  assert.notEqual(imported.spaceId, group.spaceId);
  assert(
    imported.tabIds.every((id) =>
      destination.state.tabs.some((tab) => tab.id === id && tab.spaceId === imported.spaceId),
    ),
  );
  assert(imported.tabIds.every((id) => !group.tabIds.includes(id)));
});

test('split divider positions persist, clamp extreme values and reject malformed updates', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-split-ratio-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new BrowserStore(dir);
  const { group } = pair(store);
  assert.equal(group.ratio, 0.5);
  store.dispatch('split:resize', { id: group.id, ratio: 0.65 });
  store.flush();
  const reopened = new BrowserStore(dir);
  assert.equal(reopened.state.splitGroups[0].ratio, 0.65);
  assert.throws(() => reopened.dispatch('split:resize', { id: group.id, ratio: NaN }));
  assert.throws(() => reopened.dispatch('split:resize', { id: 'missing', ratio: 0.4 }));
  reopened.dispatch('split:resize', { id: group.id, ratio: 2 });
  assert.equal(reopened.state.splitGroups[0].ratio, 0.9);
  const raw = reopened.persistedState();
  raw.splitGroups[0].ratio = 'invalid';
  assert.equal(hydrate(raw).splitGroups[0].ratio, 0.5);
  reopened.flush();
});

test('moving the inactive split partner keeps the selected tab in its new Space', () => {
  const store = new BrowserStore();
  const { first, second, group } = pair(store);
  const destination = store.dispatch('space:create', { name: 'Destination' });
  store.dispatch('tab:activate', { id: first.id });
  store.dispatch('tab:move', { id: second.id, spaceId: destination.id });
  assert.equal(store.state.activeTabId, first.id);
  assert.equal(store.state.activeSpaceId, destination.id);
  assert.equal(store.state.spaces.find((space) => space.id === destination.id).lastActiveTabId, first.id);
  assert.equal(store.state.splitGroups.find((item) => item.id === group.id).spaceId, destination.id);
  assert(
    group.tabIds.every((id) => store.state.tabs.find((tab) => tab.id === id).spaceId === destination.id),
  );
});
