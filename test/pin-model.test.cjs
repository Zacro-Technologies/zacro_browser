'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { BrowserStore, hydrate } = require('../src/core/store.cjs');

test('Favorites share one document identity across Spaces while Space pins stay local', () => {
  const store = new BrowserStore();
  const favorite = store.dispatch('tab:create', { url: 'https://mail.example/inbox' });
  store.dispatch('tab:favorite', { id: favorite.id });
  const pin = store.dispatch('tab:create', { url: 'https://project.example/board' });
  store.dispatch('tab:pin', { id: pin.id });
  const work = store.dispatch('space:create', { name: 'Work' });
  assert.equal(store.state.activeTabId, null, 'a new Space must not automatically load shared Favorites');
  store.dispatch('tab:activate', { id: favorite.id });
  assert.equal(store.state.activeSpaceId, work.id);
  assert.equal(store.state.tabs.filter((tab) => tab.id === favorite.id).length, 1);
  assert.equal(store.state.tabs.find((tab) => tab.id === favorite.id).spaceId, work.id);
  store.dispatch('space:activate', { id: 'home' });
  assert.equal(store.state.activeTabId, pin.id);
  store.dispatch('space:activate', { id: work.id });
  assert.equal(store.state.activeTabId, favorite.id);
  const other = store.dispatch('profile:create', { name: 'Other identity' });
  const otherSpace = store.state.activeSpaceId;
  assert.equal(
    store.state.tabs.some((tab) => tab.favorite && tab.profileId === other.id),
    false,
  );
  store.dispatch('tab:activate', { id: favorite.id });
  assert.equal(store.state.activeSpaceId, work.id, 'explicit cross-profile selection uses its own profile');
  assert.notEqual(store.state.activeSpaceId, otherSpace);
  assert.equal(store.state.tabs.find((tab) => tab.id === pin.id).spaceId, 'home');
});

test('saved pin destinations survive navigation and only Replace changes the saved URL', () => {
  const store = new BrowserStore();
  const pin = store.dispatch('tab:create', { url: 'https://news.example/section' });
  store.dispatch('tab:pin', { id: pin.id });
  store.dispatch('tab:rename', { id: pin.id, title: 'Reading' });
  store.dispatch('tab:update', { id: pin.id, url: 'https://news.example/article' });
  let saved = store.state.tabs.find((tab) => tab.id === pin.id);
  assert.equal(saved.pinnedUrl, 'https://news.example/section');
  store.dispatch('tab:reset-pin', { id: pin.id });
  assert.equal(saved.url, 'https://news.example/section');
  store.dispatch('tab:update', { id: pin.id, url: 'https://news.example/saved' });
  store.dispatch('tab:replace-pin', { id: pin.id });
  store.dispatch('tab:update', { id: pin.id, url: 'https://news.example/another' });
  store.dispatch('tab:close', { id: pin.id });
  assert.equal(saved.url, 'https://news.example/saved');
  assert.equal(saved.closed, true);
  assert.equal(saved.customTitle, 'Reading');
  assert.equal(store.state.archive.length, 0);
  const restored = hydrate(store.persistedState());
  saved = restored.tabs.find((tab) => tab.id === pin.id);
  assert.equal(saved.favorite, false);
  assert.equal(saved.pinnedUrl, 'https://news.example/saved');
  assert.equal(saved.closed, true);
  store.dispatch('tab:activate', { id: pin.id });
  store.dispatch('tab:pin', { id: pin.id });
  assert.equal(store.state.tabs[0].pinned, false);
  assert.equal(store.state.tabs[0].pinnedUrl, undefined);
  assert.throws(() => store.dispatch('tab:reset-pin', { id: pin.id }), /saved destination/);
});

test('legacy icon pins migrate to Favorites and foldered tabs migrate to Space pins without data loss', () => {
  const store = new BrowserStore();
  const favorite = store.dispatch('tab:create', { url: 'https://mail.example/' });
  const folder = store.dispatch('folder:create', { name: 'Research' });
  const inside = store.dispatch('tab:create', { url: 'https://paper.example/read' });
  const raw = store.persistedState();
  Object.assign(
    raw.tabs.find((tab) => tab.id === favorite.id),
    {
      pinned: true,
      customTitle: 'Mail',
      pinnedUrl: 'javascript:alert(1)',
    },
  );
  delete raw.tabs.find((tab) => tab.id === favorite.id).favorite;
  Object.assign(
    raw.tabs.find((tab) => tab.id === inside.id),
    { folderId: folder.id, pinned: false },
  );
  const migrated = hydrate(raw);
  const icon = migrated.tabs.find((tab) => tab.id === favorite.id);
  const row = migrated.tabs.find((tab) => tab.id === inside.id);
  assert.equal(icon.favorite, true);
  assert.equal(icon.pinnedUrl, favorite.url);
  assert.equal(icon.title, 'Mail');
  assert.equal(row.pinned, true);
  assert.equal(row.favorite, false);
  assert.equal(row.folderId, folder.id);
  assert.equal(row.pinnedUrl, inside.url);
  const imported = new BrowserStore();
  imported.importData({ ...migrated, format: 'zacro-export', version: 1 });
  const copy = imported.state.tabs.find((tab) => tab.url === inside.url);
  assert.equal(copy.favorite, false);
  assert.equal(copy.pinnedUrl, inside.url);
  assert.equal(imported.state.folders.find((item) => item.id === copy.folderId).name, 'Research');
});

test('moving between Favorites, pinned folders and Today keeps valid Space memories', () => {
  const store = new BrowserStore();
  const favorite = store.dispatch('tab:create', { url: 'https://favorite.example/' });
  store.dispatch('tab:favorite', { id: favorite.id });
  const next = store.dispatch('space:create', { name: 'Next' });
  store.dispatch('tab:activate', { id: favorite.id });
  const folder = store.dispatch('folder:create', { name: 'Saved' });
  store.dispatch('tab:move', { id: favorite.id, folderId: folder.id });
  let tab = store.state.tabs[0];
  assert.equal(tab.favorite, false);
  assert.equal(tab.pinned, true);
  assert.equal(tab.folderId, folder.id);
  assert.equal(store.state.spaces.find((space) => space.id === 'home').lastActiveTabId, undefined);
  store.dispatch('tab:move', { id: tab.id, pinned: false });
  assert.equal(tab.folderId, null);
  assert.equal(tab.pinnedUrl, undefined);
  store.dispatch('tab:favorite', { id: tab.id });
  store.dispatch('space:delete', { id: next.id });
  tab = store.state.tabs[0];
  assert.equal(tab.favorite, true);
  assert.equal(tab.spaceId, 'home');
  assert.equal(
    store.state.spaces.some((space) => space.id === tab.spaceId),
    true,
  );
});

test('saved pin labels stay stable during browsing and Replace adopts the current document title', () => {
  const store = new BrowserStore();
  const tab = store.dispatch('tab:create', { url: 'https://docs.example/' });
  store.dispatch('tab:update', { id: tab.id, title: 'Documentation' });
  store.dispatch('tab:pin', { id: tab.id });
  store.dispatch('tab:update', { id: tab.id, url: 'https://docs.example/guide', title: 'A long guide' });
  assert.equal(store.state.tabs[0].pinnedTitle, 'Documentation');
  assert.equal(hydrate(store.persistedState()).tabs[0].pinnedTitle, 'Documentation');
  store.dispatch('tab:replace-pin', { id: tab.id });
  assert.equal(store.state.tabs[0].pinnedTitle, 'A long guide');
  store.dispatch('tab:rename', { id: tab.id, title: 'My reference' });
  store.dispatch('tab:replace-pin', { id: tab.id });
  assert.equal(store.state.tabs[0].customTitle, 'My reference');
  store.dispatch('tab:pin', { id: tab.id });
  assert.equal(store.state.tabs[0].pinnedTitle, undefined);
});

test('layout widths, additional Space icons and configured site searches persist with bounded values', () => {
  const store = new BrowserStore();
  store.dispatch('space:update', { id: 'home', icon: 'headphones' });
  store.dispatch('settings:update', { values: { panelWidth: 421, sidebarWidth: 251, siteSearches: [] } });
  let restored = hydrate(store.persistedState());
  assert.equal(restored.settings.panelWidth, 421);
  assert.equal(restored.settings.sidebarWidth, 251);
  assert.deepEqual(restored.settings.siteSearches, []);
  assert.equal(restored.spaces[0].icon, 'headphones');
  store.dispatch('settings:update', { values: { panelWidth: 10000, sidebarWidth: 1 } });
  restored = hydrate(store.persistedState());
  assert.equal(restored.settings.panelWidth, 560);
  assert.equal(restored.settings.sidebarWidth, 200);
});
