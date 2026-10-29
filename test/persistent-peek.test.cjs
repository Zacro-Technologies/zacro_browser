'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { BrowserStore, hydrate } = require('../src/core/store.cjs');

function preview(store, suffix = '') {
  const source = store.dispatch('tab:create', { url: `https://example.com/source${suffix}` });
  store.dispatch('peek:set', {
    sourceTabId: source.id,
    url: `https://example.com/peek${suffix}`,
    title: `Preview ${suffix}`,
  });
  return source;
}

test('each source keeps its own Peek through Space changes, export/import and restart', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-peek-store-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new BrowserStore(dir);
  const first = preview(store, '1');
  store.dispatch('space:create', { name: 'Second' });
  const second = preview(store, '2');
  store.dispatch('tab:activate', { id: first.id });
  store.flush();
  const reopened = new BrowserStore(dir);
  assert.equal(
    reopened.state.tabs.find((tab) => tab.id === first.id).savedPeek.url,
    'https://example.com/peek1',
  );
  assert.equal(
    reopened.state.tabs.find((tab) => tab.id === second.id).savedPeek.url,
    'https://example.com/peek2',
  );
  const imported = new BrowserStore();
  imported.importData(reopened.exportData());
  assert.equal(imported.state.tabs.filter((tab) => tab.savedPeek).length, 2);
  assert(imported.state.tabs.some((tab) => tab.savedPeek?.title === 'Preview 2'));
  reopened.flush();
});

test('only explicit dismissal or closing the source clears saved Peek', () => {
  const store = new BrowserStore();
  const first = preview(store);
  const second = preview(store, '2');
  store.dispatch('peek:set', { sourceTabId: first.id, url: null });
  assert.equal(store.state.tabs.find((tab) => tab.id === first.id).savedPeek, undefined);
  store.dispatch('tab:close', { id: second.id });
  assert.equal(store.state.archive.find((tab) => tab.id === second.id).savedPeek, undefined);
  const pin = preview(store, 'pin');
  store.dispatch('tab:pin', { id: pin.id });
  store.dispatch('tab:close', { id: pin.id });
  assert.equal(store.state.tabs.find((tab) => tab.id === pin.id).savedPeek, undefined);
});

test('saved Peek sources resist automatic archival and survive restore-session off', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-peek-archive-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new BrowserStore(dir);
  const source = preview(store);
  store.dispatch('tab:create', { url: 'https://example.com/other' });
  for (const tab of store.state.tabs) tab.lastActiveAt = 1;
  store.dispatch('tab:archive-stale', { now: Date.now() });
  assert(store.state.tabs.some((tab) => tab.id === source.id));
  store.dispatch('settings:update', { values: { restoreSession: false } });
  store.flush();
  const reopened = new BrowserStore(dir);
  assert.equal(
    reopened.state.tabs.find((tab) => tab.id === source.id).savedPeek.url,
    'https://example.com/peek',
  );
  reopened.flush();
});

test('Peek hydration sanitizes destinations and never persists private previews', () => {
  const store = new BrowserStore();
  const source = preview(store);
  assert.throws(
    () => store.dispatch('peek:set', { sourceTabId: source.id, url: 'file:///secret' }),
    /web link/,
  );
  const snapshot = store.snapshot();
  snapshot.tabs.find((tab) => tab.id === source.id).savedPeek = {
    url: 'javascript:alert(1)',
    title: 'Unsafe',
  };
  assert.equal(hydrate(snapshot).tabs.find((tab) => tab.id === source.id).savedPeek, undefined);
  store.dispatch('profile:create', { name: 'Private', private: true });
  const secret = preview(store, 'private');
  assert(!JSON.stringify(store.persistedState()).includes('peekprivate'));
  assert(!store.exportData().tabs.some((tab) => tab.id === secret.id));
});
