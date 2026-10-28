'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { BrowserStore, normalizeAddress, hydrate } = require('../src/core/store.cjs');
const { parseBookmarksHtml } = require('../src/core/import.cjs');

function memory() {
  return new BrowserStore();
}
function temp(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-store-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function invariant(s) {
  assert(s.profiles.some((p) => !p.private));
  assert(s.spaces.some((sp) => sp.id === s.activeSpaceId));
  const all = [...s.profiles, ...s.spaces, ...s.tabs, ...s.folders, ...s.archive];
  assert.equal(new Set(all.map((r) => r.id)).size, all.length);
  for (const profile of s.profiles) assert(s.spaces.some((sp) => sp.profileId === profile.id));
  for (const tab of [...s.tabs, ...s.archive]) {
    const space = s.spaces.find((sp) => sp.id === tab.spaceId);
    assert(space);
    assert.equal(tab.profileId, space.profileId);
    if (tab.folderId) assert(s.folders.some((f) => f.id === tab.folderId && f.spaceId === tab.spaceId));
  }
  if (s.activeTabId)
    assert(s.tabs.some((tab) => tab.id === s.activeTabId && tab.spaceId === s.activeSpaceId));
}

test('user tab names survive document updates, archive, restart, and portable import', (t) => {
  const directory = temp(t);
  const store = new BrowserStore(directory);
  const tab = store.dispatch('tab:create', { url: 'https://example.com/project' });
  store.dispatch('tab:rename', { id: tab.id, title: 'My project' });
  store.dispatch('tab:update', {
    id: tab.id,
    title: 'A website changed its title',
    url: 'https://example.com/next',
  });
  assert.equal(store.state.tabs.find((item) => item.id === tab.id).title, 'My project');
  store.dispatch('tab:close', { id: tab.id });
  store.dispatch('tab:restore', { id: tab.id });
  store.flush();
  const restarted = new BrowserStore(directory);
  restarted.dispatch('tab:update', { id: tab.id, title: 'Loaded document title' });
  assert.equal(restarted.state.tabs.find((item) => item.id === tab.id).title, 'My project');
  const imported = memory();
  imported.importData(restarted.exportData());
  const copy = imported.state.tabs.find((item) => item.customTitle === 'My project');
  assert(copy);
  imported.dispatch('tab:update', { id: copy.id, title: 'Document title after migration' });
  assert.equal(imported.state.tabs.find((item) => item.id === copy.id).title, 'My project');
  assert.throws(() => store.dispatch('tab:rename', { id: tab.id, title: '   ' }));
});

test('closing a favorite retains its destination, title and bookmark until explicitly unpinned', () => {
  const store = memory();
  const ordinary = store.dispatch('tab:create', { url: 'https://ordinary.example' });
  let favorite = store.dispatch('tab:create', { url: 'https://favorite.example/path' });
  store.dispatch('tab:rename', { id: favorite.id, title: 'Daily reading' });
  store.dispatch('tab:favorite', { id: favorite.id });
  favorite = store.state.tabs.find((tab) => tab.id === favorite.id);
  store.dispatch('bookmark:toggle', { url: favorite.url, title: favorite.title });
  store.dispatch('tab:close', { id: favorite.id });
  assert.equal(store.state.tabs.find((tab) => tab.id === favorite.id).closed, true);
  assert.equal(store.state.activeTabId, ordinary.id);
  assert.equal(store.state.spaces[0].lastActiveTabId, ordinary.id);
  assert.equal(store.state.archive.length, 0);
  assert.equal(store.state.bookmarks.length, 1);
  store.dispatch('tab:wake', { id: favorite.id });
  assert.equal(favorite.closed, undefined);
  assert.equal(store.state.activeTabId, ordinary.id, 'Opening a second pane preserves the selected tab');
  store.dispatch('tab:activate', { id: favorite.id });
  assert.equal(favorite.closed, undefined);
  assert.equal(favorite.title, 'Daily reading');
  assert.equal(favorite.url, 'https://favorite.example/path');
  store.dispatch('tab:pin', { id: favorite.id });
  assert.equal(favorite.pinned, false);
  assert.equal(store.state.tabs.length, 2, 'Removing an open pin keeps its ordinary tab');
  store.dispatch('tab:favorite', { id: favorite.id });
  store.dispatch('tab:close', { id: favorite.id });
  store.dispatch('tab:pin', { id: favorite.id });
  assert.equal(
    store.state.tabs.some((tab) => tab.id === favorite.id),
    false,
  );
  assert.equal(store.state.archive.length, 0);
  assert.equal(store.state.bookmarks.length, 1);
});

test('closed and restored favorites remain lazy across restart and retain portable metadata', (t) => {
  const directory = temp(t);
  const store = new BrowserStore(directory);
  const favorite = store.dispatch('tab:create', { url: 'https://favorite.example' });
  store.dispatch('tab:favorite', { id: favorite.id });
  store.flush();
  const reopened = new BrowserStore(directory);
  assert.equal(reopened.state.activeTabId, null);
  assert.equal(reopened.state.tabs[0].pinned, true);
  reopened.dispatch('tab:close', { id: favorite.id });
  reopened.flush();
  const closed = new BrowserStore(directory);
  assert.equal(closed.state.tabs[0].closed, true);
  assert.equal(closed.state.activeTabId, null);
  const imported = memory();
  imported.importData(closed.exportData());
  const copy = imported.state.tabs.find((tab) => tab.url === favorite.url);
  assert.equal(copy.closed, true);
  assert.equal(copy.pinned, true);
  assert.equal(copy.favorite, true);
  imported.dispatch('tab:activate', { id: copy.id });
  assert.equal(copy.closed, undefined);
});

test('Space appearance and layout preferences round-trip with bounded untrusted imports', (t) => {
  const directory = temp(t);
  const store = new BrowserStore(directory);
  store.dispatch('space:update', {
    id: 'home',
    icon: 'leaf',
    color: '#123456',
    theme: { secondaryColor: '#abcdef', gradient: 82, grain: 9, opacity: 62, blur: 18 },
  });
  store.dispatch('settings:update', {
    values: { pinnedSleepMinutes: 0, pageGutter: 14, pageRadius: 7, motionScale: 0.8, tabDensity: 'compact' },
  });
  store.flush();
  const reopened = new BrowserStore(directory);
  assert.equal(reopened.state.spaces[0].icon, 'leaf');
  assert.deepEqual(reopened.state.spaces[0].theme, {
    secondaryColor: '#abcdef',
    gradient: 82,
    grain: 9,
    opacity: 62,
    blur: 18,
  });
  assert.equal(reopened.state.settings.pinnedSleepMinutes, 0);
  assert.equal(reopened.state.settings.pageGutter, 14);
  const exported = reopened.exportData();
  exported.spaces[0].icon = '<svg onload=evil>';
  exported.spaces[0].theme = {
    secondaryColor: 'url(javascript:evil)',
    gradient: -9,
    grain: 999,
    opacity: 2,
    blur: 999,
    arbitrary: 'discard',
  };
  exported.settings = {
    pinnedSleepMinutes: -1,
    pageGutter: 999,
    pageRadius: -5,
    motionScale: Infinity,
    tabDensity: 'evil',
  };
  const clean = hydrate(exported);
  assert.equal(clean.spaces[0].color, '#123456');
  assert.equal(clean.spaces[0].icon, 'circle');
  assert.deepEqual(clean.spaces[0].theme, {
    secondaryColor: '#b695b8',
    gradient: 0,
    grain: 200,
    opacity: 2,
    blur: 32,
  });
  assert.equal(clean.settings.pinnedSleepMinutes, 20);
  assert.equal(clean.settings.pageGutter, 20);
  assert.equal(clean.settings.pageRadius, 0);
  assert.equal(clean.settings.motionScale, 1);
  assert.equal(clean.settings.tabDensity, 'comfortable');
  const imported = memory();
  imported.importData(exported);
  assert.deepEqual(imported.state.spaces[1].theme, clean.spaces[0].theme);
  assert.equal(imported.state.settings.pageGutter, 8, 'Collection import never replaces local preferences');
});

test('address parsing preserves web addresses, encodes queries and supports localhost', () => {
  assert.equal(normalizeAddress('example.com/a?q=hello'), 'https://example.com/a?q=hello');
  assert.equal(normalizeAddress('localhost:3300/test'), 'http://localhost:3300/test');
  assert.equal(normalizeAddress('127.0.0.1:8080'), 'http://127.0.0.1:8080/');
  assert.equal(normalizeAddress('[::1]:8080'), 'http://[::1]:8080/');
  assert.equal(normalizeAddress('café with a view'), 'https://duckduckgo.com/?q=caf%C3%A9%20with%20a%20view');
  assert.equal(normalizeAddress('two words', 'google'), 'https://www.google.com/search?q=two%20words');
  assert.equal(normalizeAddress(''), 'zacro://newtab');
  assert.equal(normalizeAddress('https://例え.テスト'), 'https://xn--r8jz45g.xn--zckzah/');
});

test('unsafe schemes, embedded credentials and control characters are blocked', () => {
  for (const value of [
    'javascript:alert(1)',
    'data:text/html,hi',
    'file:///C:/secret',
    'vbscript:hello',
    'zacro://settings',
    'https://user:password@example.com',
    'https://exa\nmple.com',
  ])
    assert.throws(() => normalizeAddress(value));
});

test('profile boundaries prevent cookie-context transfers through tab moves', () => {
  const store = memory();
  const tab = store.dispatch('tab:create', { url: 'https://example.com' });
  const profile = store.dispatch('profile:create', { name: 'Work' });
  const space = store.state.spaces.find((s) => s.profileId === profile.id);
  assert.throws(() => store.dispatch('tab:move', { id: tab.id, spaceId: space.id }), /between profiles/);
  assert.equal(store.state.tabs.find((t) => t.id === tab.id).spaceId, 'home');
  invariant(store.state);
});

test('archive cleanup excludes active and pinned tabs and restores archived metadata', () => {
  const store = memory();
  const pinned = store.dispatch('tab:create', { url: 'https://pin.example' });
  store.dispatch('tab:pin', { id: pinned.id });
  const old = store.dispatch('tab:create', { url: 'https://old.example' });
  const active = store.dispatch('tab:create', { url: 'https://active.example' });
  for (const t of store.state.tabs) t.lastActiveAt = Date.now() - 100 * 3600000;
  store.dispatch('tab:archive-stale');
  assert(store.state.tabs.some((t) => t.id === pinned.id));
  assert(store.state.tabs.some((t) => t.id === active.id));
  assert(store.state.archive.some((t) => t.id === old.id));
  const restored = store.dispatch('tab:restore', { id: old.id });
  assert.equal(restored.url, old.url);
  assert.equal(store.state.activeTabId, old.id);
  invariant(store.state);
});

test('closing tabs activates a neighbor and never leaves a dangling active id', () => {
  const store = memory();
  const a = store.dispatch('tab:create', { url: 'https://a.example' });
  const b = store.dispatch('tab:create', { url: 'https://b.example' });
  store.dispatch('tab:close', { id: b.id });
  assert.equal(store.state.activeTabId, a.id);
  for (const tab of [...store.state.tabs]) store.dispatch('tab:close', { id: tab.id });
  assert.equal(store.state.activeTabId, null);
  invariant(store.state);
});

test('archive excludes live pages so background forms cannot be discarded', () => {
  const store = memory();
  const live = store.dispatch('tab:create', { url: 'https://editor.example' });
  store.dispatch('tab:create');
  store.state.tabs.find((tab) => tab.id === live.id).lastActiveAt = Date.now() - 200 * 3600000;
  store.dispatch('tab:archive-stale', { excludeIds: [live.id] });
  assert(store.state.tabs.some((tab) => tab.id === live.id));
});

test('spaces remember their last active tab and deleting spaces preserves their tabs', () => {
  const store = memory();
  const tab = store.dispatch('tab:create', { url: 'https://a.example' });
  const space = store.dispatch('space:create', { name: 'Research' });
  const other = store.dispatch('tab:create', { url: 'https://b.example' });
  store.dispatch('space:activate', { id: 'home' });
  assert.equal(store.state.activeTabId, tab.id);
  store.dispatch('space:activate', { id: space.id });
  assert.equal(store.state.activeTabId, other.id);
  store.dispatch('space:delete', { id: space.id });
  assert.equal(store.state.tabs.find((t) => t.id === other.id).spaceId, 'home');
  assert.throws(() => store.dispatch('space:delete', { id: 'home' }));
  invariant(store.state);
});

test('folder deletion releases retained pins and legacy archived tabs', () => {
  const store = memory();
  const folder = store.dispatch('folder:create', { name: 'Ideas' });
  const tab = store.dispatch('tab:create', { url: 'https://example.com' });
  store.dispatch('tab:move', { id: tab.id, folderId: folder.id });
  store.dispatch('tab:close', { id: tab.id });
  store.state.archive.push({
    ...store.state.tabs.find((item) => item.id === tab.id),
    id: 'legacy-archive',
    pinned: false,
    favorite: false,
    archivedAt: Date.now(),
  });
  store.dispatch('folder:delete', { id: folder.id });
  assert.equal(store.state.tabs[0].folderId, null);
  assert.equal(store.state.tabs[0].pinned, true);
  assert.equal(store.state.tabs[0].closed, true);
  assert.equal(store.state.archive[0].folderId, null);
  invariant(store.state);
});

test('private activity never survives persistence, history or portable export', (t) => {
  const dir = temp(t),
    store = new BrowserStore(dir);
  const privateProfile = store.dispatch('profile:create', { name: 'Secret', private: true });
  const tab = store.dispatch('tab:create', { url: 'https://secret.example' });
  store.dispatch('history:add', { url: tab.url, title: 'Private', profileId: privateProfile.id });
  store.dispatch('bookmark:toggle', { url: tab.url });
  store.dispatch('permission:set', { origin: tab.url, permission: 'geolocation', allowed: true });
  store.dispatch('tab:close', { id: tab.id });
  assert.equal(store.state.history.length, 0);
  assert.equal(store.state.archive.length, 0);
  store.flush();
  assert(!fs.readFileSync(store.file, 'utf8').includes('secret.example'));
  assert(!JSON.stringify(store.exportData()).includes('Secret'));
  const restored = new BrowserStore(dir);
  assert.equal(restored.state.profiles.length, 1);
  invariant(restored.state);
});

test('session persistence repairs corrupted primary using the previous atomic backup', (t) => {
  const dir = temp(t),
    store = new BrowserStore(dir);
  store.dispatch('tab:create', { url: 'https://saved.example' });
  store.flush();
  store.dispatch('tab:create', { url: 'https://new.example' });
  store.flush();
  fs.writeFileSync(store.file, '{truncated');
  const recovered = new BrowserStore(dir);
  assert.match(recovered.recoveryWarning, /backup/);
  assert(recovered.state.tabs.some((tab) => tab.url === 'https://saved.example/'));
  assert(fs.readdirSync(dir).some((file) => file.includes('.damaged-')));
  recovered.flush();
  invariant(new BrowserStore(dir).state);
});

test('invalid first session preserves damaged data and starts safely', (t) => {
  const dir = temp(t);
  fs.writeFileSync(path.join(dir, 'browser-state.json'), 'null');
  const store = new BrowserStore(dir);
  assert.match(store.recoveryWarning, /preserved/);
  invariant(store.state);
});

test('clearing history sanitizes recovery immediately and retains other profiles after primary corruption', (t) => {
  const directory = temp(t);
  const store = new BrowserStore(directory);
  store.dispatch('history:add', {
    profileId: 'default',
    url: 'https://delete-history.example/secret',
    title: 'Deleted history',
  });
  const work = store.dispatch('profile:create', { name: 'Work' });
  store.dispatch('history:add', {
    profileId: work.id,
    url: 'https://keep-history.example/',
    title: 'Retained work history',
  });
  store.flush();
  store.flush();
  const damaged = `${store.file}.damaged-1792806000000`;
  fs.copyFileSync(store.file, damaged);
  const unrelated = `${store.file}.damaged-notes`;
  fs.writeFileSync(unrelated, 'User-created notes');
  const reservedDirectory = `${store.file}.damaged-1792806000001`;
  fs.mkdirSync(reservedDirectory);
  store.dispatch('history:clear', { profileId: 'default' });
  const backup = JSON.parse(fs.readFileSync(`${store.file}.bak`, 'utf8'));
  assert.equal(
    backup.history.some((item) => item.profileId === 'default'),
    false,
  );
  assert.equal(backup.history.filter((item) => item.profileId === work.id).length, 1);
  assert.equal(fs.existsSync(damaged), false);
  assert.equal(fs.readFileSync(unrelated, 'utf8'), 'User-created notes');
  assert(fs.statSync(reservedDirectory).isDirectory());
  fs.writeFileSync(store.file, '{corrupt');
  const recovered = new BrowserStore(directory);
  assert.match(recovered.recoveryWarning, /backup/);
  assert.equal(recovered.state.history.length, 1);
  assert.equal(recovered.state.history[0].profileId, work.id);
  assert(!JSON.stringify(recovered.state).includes('delete-history.example'));
});

test('deleted profiles cannot reappear from backup and surviving profile data is preserved', (t) => {
  const directory = temp(t);
  const store = new BrowserStore(directory);
  const keep = store.dispatch('tab:create', { url: 'https://keep-profile.example/' });
  store.dispatch('bookmark:toggle');
  const removed = store.dispatch('profile:create', { name: 'Profile to erase' });
  const tab = store.dispatch('tab:create', { url: 'https://delete-profile.example/secret' });
  store.dispatch('bookmark:toggle');
  store.dispatch('history:add', { profileId: removed.id, url: tab.url, title: tab.title });
  store.dispatch('permission:set', {
    profileId: removed.id,
    origin: 'https://delete-profile.example',
    permission: 'media',
    allowed: true,
  });
  store.flush();
  store.flush();
  fs.copyFileSync(store.file, `${store.file}.damaged-1792806000002`);
  store.dispatch('profile:delete', { id: removed.id });
  assert(!fs.readFileSync(`${store.file}.bak`, 'utf8').includes('delete-profile.example'));
  assert.equal(fs.existsSync(`${store.file}.damaged-1792806000002`), false);
  fs.writeFileSync(store.file, '{corrupt');
  const recovered = new BrowserStore(directory);
  assert.equal(recovered.state.profiles.length, 1);
  assert.equal(recovered.state.profiles[0].id, 'default');
  assert(recovered.state.tabs.some((item) => item.id === keep.id));
  assert(recovered.state.bookmarks.some((item) => item.url === keep.url));
  assert(!JSON.stringify(recovered.state).includes(removed.id));
});

test('failed backup sanitization is reported and a later save retries the pending deletion', (t) => {
  const directory = temp(t);
  const store = new BrowserStore(directory);
  store.dispatch('history:add', { url: 'https://delete-on-retry.example/', title: 'Remove' });
  store.flush();
  const invalidBackup = `${store.file}.bak`;
  fs.mkdirSync(invalidBackup);
  assert.throws(() => store.dispatch('history:clear', { profileId: 'default' }));
  assert.equal(store.recoveryPurgePending, true);
  fs.rmdirSync(invalidBackup);
  store.flush();
  assert.equal(store.recoveryPurgePending, false);
  assert.equal(JSON.parse(fs.readFileSync(invalidBackup, 'utf8')).history.length, 0);
});

test('import merges and remaps identities, ignores executable paths and does not overwrite settings', () => {
  const source = memory();
  source.dispatch('tab:create', { url: 'https://import.example' });
  source.dispatch('bookmark:toggle');
  const data = source.exportData();
  data.settings.theme = 'dark';
  data.extensions = [{ id: 'malicious', path: 'C:\\bad', profileId: 'default' }];
  const target = memory();
  const result = target.importData(data);
  assert.equal(result.bookmarks, 1);
  assert.equal(target.state.settings.theme, 'system');
  assert.equal(target.state.extensions.length, 0);
  assert.equal(target.state.profiles.length, 2);
  invariant(target.state);
  target.importData(data);
  invariant(target.state);
});

test('untrusted hydration drops dangerous URLs, malformed IDs, private records and orphan folders', () => {
  const source = memory();
  source.state.tabs.push({
    id: 'malicious',
    spaceId: 'home',
    profileId: 'wrong',
    url: 'javascript:alert(1)',
    folderId: 'none',
  });
  source.state.profiles.push({ id: '../private', name: 'Bad' });
  source.state.bookmarks.push({ id: 'unsafe-bookmark', profileId: 'default', url: 'file:///etc/passwd' });
  const cleaned = hydrate(source.state);
  assert.equal(cleaned.profiles.length, 1);
  assert.equal(cleaned.bookmarks.length, 0);
  assert.equal(cleaned.tabs.at(-1).url, 'zacro://newtab');
  assert.equal(cleaned.tabs.at(-1).profileId, 'default');
  invariant(cleaned);
});

test('settings validate types and bounds and cannot introduce secrets or unknown keys', () => {
  const store = memory();
  store.dispatch('settings:update', {
    values: {
      theme: 'nonsense',
      sidebarWidth: 900,
      openSourcesLimit: -8,
      apiKey: 'secret',
      archiveAfterHours: -1,
      restoreSession: 'yes',
      searchEngine: '__proto__',
    },
  });
  assert.equal(store.state.settings.theme, 'system');
  assert.equal(store.state.settings.sidebarWidth, 380);
  assert.equal(store.state.settings.openSourcesLimit, 1);
  assert.equal(store.state.settings.apiKey, undefined);
  assert.equal(store.state.settings.archiveAfterHours, 12);
  assert.equal(store.state.settings.restoreSession, true);
});

test('browser bookmarks HTML safely imports encoded titles and rejects executable URLs', () => {
  const records = parseBookmarksHtml(
    '<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF="https://example.com/?a=1&amp;b=2">A &amp; B &#x1f353;</A><A HREF="javascript:alert(1)">Bad</A><a href=\'https://second.example\'>Second</a></DL>',
  );
  assert.equal(records.length, 2);
  assert.equal(records[0].title, 'A & B 🍓');
  assert.match(records[0].url, /a=1&b=2/);
  const store = memory();
  assert.equal(store.importBookmarks(records).bookmarks, 2);
  assert.equal(store.importBookmarks(records).bookmarks, 0);
  assert.throws(() => parseBookmarksHtml('<a href="file:///secret">No</a>'));
});

test('permissions and history are scoped to the selected profile', () => {
  const store = memory();
  store.dispatch('history:add', { url: 'https://home.example', title: 'Home' });
  store.dispatch('permission:set', {
    origin: 'https://home.example/path',
    permission: 'notifications',
    allowed: false,
  });
  const work = store.dispatch('profile:create', { name: 'Work' });
  store.dispatch('history:add', { url: 'https://work.example', title: 'Work' });
  store.dispatch('history:clear');
  assert.equal(store.state.history.length, 1);
  assert.equal(store.state.history[0].profileId, 'default');
  store.dispatch('permission:clear');
  assert.equal(store.state.permissions.length, 1);
  store.dispatch('profile:delete', { id: work.id });
  invariant(store.state);
  assert.throws(() => store.dispatch('profile:delete', { id: 'default' }));
});

test('random lifecycle operations preserve graph integrity across save/restore', () => {
  const store = memory();
  let seed = 271828;
  const rnd = (n) => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed % n;
  };
  for (let i = 0; i < 600; i++) {
    const s = store.state;
    switch (rnd(8)) {
      case 0:
        store.dispatch('tab:create', { url: `https://page-${i}.example` });
        break;
      case 1:
        if (s.tabs.length) store.dispatch('tab:close', { id: s.tabs[rnd(s.tabs.length)].id });
        break;
      case 2:
        if (s.tabs.length) store.dispatch('tab:activate', { id: s.tabs[rnd(s.tabs.length)].id });
        break;
      case 3:
        if (s.tabs.length) store.dispatch('tab:pin', { id: s.tabs[rnd(s.tabs.length)].id });
        break;
      case 4:
        store.dispatch('space:create', { name: `Space ${i}` });
        break;
      case 5:
        if (s.spaces.length > 1) store.dispatch('space:delete', { id: s.spaces[rnd(s.spaces.length)].id });
        break;
      case 6:
        if (s.archive.length) store.dispatch('tab:restore', { id: s.archive[rnd(s.archive.length)].id });
        break;
      case 7:
        if (s.tabs.length)
          store.dispatch('tab:move', {
            id: s.tabs[rnd(s.tabs.length)].id,
            spaceId: s.spaces[rnd(s.spaces.length)].id,
            index: rnd(s.tabs.length),
          });
        break;
    }
    invariant(s);
  }
  invariant(hydrate(store.persistedState()));
});
