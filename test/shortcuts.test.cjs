'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  shortcutCatalog,
  normalizeAccelerator,
  updateShortcut,
  sanitizeOverrides,
  matchShortcut,
  sidebarTabs,
} = require('../src/core/shortcuts.cjs');
const { BrowserStore, hydrate } = require('../src/core/store.cjs');
const key = (value, extras = {}) => ({ type: 'keyDown', key: value, ...extras });

test('numbered and sequential tab shortcuts follow rendered sidebar order without hidden drafts', () => {
  const tab = (id, extra = {}) => ({ id, spaceId: 'work', url: 'https://example.com', ...extra });
  const state = {
    activeSpaceId: 'work',
    folders: [
      { id: 'f2', spaceId: 'work' },
      { id: 'f1', spaceId: 'work' },
    ],
    tabs: [
      tab('loose-a'),
      tab('f1-a', { folderId: 'f1' }),
      tab('other', { spaceId: 'other' }),
      tab('pin', { pinned: true }),
      tab('f2-a', { folderId: 'f2' }),
      tab('pin-blank', { pinned: true, url: 'zacro://newtab' }),
      tab('draft', { url: 'zacro://newtab' }),
      tab('home', { url: 'zacro://newtab', homePage: true }),
      tab('folder-blank', { folderId: 'f2', url: 'zacro://newtab' }),
      tab('loose-b'),
    ],
  };
  const before = structuredClone(state);
  assert.deepEqual(
    sidebarTabs(state).map((item) => item.id),
    ['f2-a', 'folder-blank', 'f1-a', 'pin', 'pin-blank', 'loose-a', 'home', 'loose-b'],
  );
  assert.deepEqual(
    sidebarTabs(state, 'other').map((item) => item.id),
    ['other'],
  );
  assert.deepEqual(state, before);
});

test('sidebar shortcuts include profile favorites once before local pins and pinned folders', () => {
  const state = {
    activeSpaceId: 'work',
    spaces: [
      { id: 'work', profileId: 'personal' },
      { id: 'reading', profileId: 'personal' },
      { id: 'isolated', profileId: 'other' },
    ],
    folders: [{ id: 'research', spaceId: 'work' }],
    tabs: [
      { id: 'today', spaceId: 'work', profileId: 'personal', url: 'https://example.com' },
      { id: 'folder-pin', spaceId: 'work', profileId: 'personal', pinned: true, folderId: 'research' },
      { id: 'shared', spaceId: 'reading', profileId: 'personal', pinned: true, favorite: true },
      { id: 'private-favorite', spaceId: 'isolated', profileId: 'other', pinned: true, favorite: true },
      { id: 'local-pin', spaceId: 'work', profileId: 'personal', pinned: true },
    ],
  };
  assert.deepEqual(
    sidebarTabs(state).map((tab) => tab.id),
    ['shared', 'folder-pin', 'local-pin', 'today'],
  );
  assert.deepEqual(
    sidebarTabs(state, 'reading').map((tab) => tab.id),
    ['shared'],
  );
  assert.deepEqual(
    sidebarTabs(state, 'isolated').map((tab) => tab.id),
    ['private-favorite'],
  );
});

test('essential shortcuts share exact modifiers on Mac and Windows without taking over editor or OS keys', () => {
  for (const platform of ['darwin', 'win32']) {
    const mod = platform === 'darwin' ? { meta: true } : { control: true };
    assert.equal(matchShortcut(key('t', mod), platform), 'command-palette');
    assert.equal(matchShortcut(key('s', mod), platform), 'sidebar-toggle');
    assert.equal(matchShortcut(key('s', { ...mod, shift: true }), platform), 'save-page');
    assert.equal(matchShortcut(key('t', { ...mod, shift: true }), platform), 'reopen-tab');
    assert.equal(matchShortcut(key('c', mod), platform), null);
    assert.equal(matchShortcut(key('s'), platform), null);
    assert.equal(matchShortcut(key('s', { ...mod, isComposing: true }), platform), null);
    assert.equal(matchShortcut(key('t', { ...mod, alt: true }), platform), null);
    const catalog = shortcutCatalog(platform);
    assert.ok(catalog.length >= 45);
    assert.equal(
      catalog.find((entry) => entry.id === 'new-tab'),
      undefined,
    );
    assert.deepEqual(sanitizeOverrides({ [platform]: {} }), { [platform]: {} });
  }
  assert.equal(matchShortcut(key('h', { meta: true }), 'darwin'), null);
  assert.equal(matchShortcut(key('ArrowLeft', { meta: true }), 'darwin'), 'history-back');
  assert.equal(matchShortcut(key('ArrowRight', { meta: true }), 'darwin'), 'history-forward');
  assert.equal(matchShortcut(key('[', { meta: true }), 'darwin'), 'history-back');
  assert.equal(matchShortcut(key(']', { meta: true }), 'darwin'), 'history-forward');
  assert.equal(matchShortcut(key('tab', { meta: true }), 'darwin'), null);
  assert.equal(matchShortcut(key('Tab', { control: true }), 'darwin'), 'recent-tab');
  assert.equal(matchShortcut(key('+', { meta: true, shift: true }), 'darwin'), 'zoom-in');
  assert.equal(matchShortcut(key('®', { code: 'KeyR', meta: true, alt: true }), 'darwin'), 'rename-tab');
});

test('restoring defaults cannot steal an alias assigned to another command', () => {
  let overrides = updateShortcut({}, 'darwin', 'command-palette', 'Mod+Alt+T');
  overrides = updateShortcut(overrides, 'darwin', 'sidebar-toggle', 'Mod+K');
  assert.throws(() => updateShortcut(overrides, 'darwin', 'command-palette', 'Mod+T'), /Already used/);
  assert.equal(matchShortcut(key('k', { meta: true }), 'darwin', overrides), 'sidebar-toggle');
  assert.equal(
    matchShortcut(key('k', { meta: true }), 'darwin', sanitizeOverrides(overrides)),
    'sidebar-toggle',
  );
});

test('physical punctuation remains bindable while AltGr typing and system shortcuts stay intact', () => {
  for (const [raw, code, name] of [
    ['<', 'Comma', ','],
    ['?', 'Slash', '/'],
    [':', 'Semicolon', ';'],
  ]) {
    const overrides = updateShortcut({}, 'darwin', 'sidebar-toggle', `Mod+Shift+${name}`);
    assert.equal(
      matchShortcut(key(raw, { code, meta: true, shift: true }), 'darwin', overrides),
      'sidebar-toggle',
    );
  }
  assert.equal(matchShortcut(key('µ', { code: 'KeyM', control: true, alt: true }), 'win32'), null);
  assert.equal(matchShortcut(key('@', { code: 'KeyQ', control: true, alt: true }), 'linux'), null);
  assert.equal(matchShortcut(key('m', { code: 'KeyM', control: true, alt: true }), 'win32'), 'move-tab');
  for (const reserved of ['Mod+Space', 'Mod+Alt+Escape', 'Mod+Shift+3'])
    assert.throws(() => updateShortcut({}, 'darwin', 'sidebar-toggle', reserved), /operating system/);
});

test('Arc organization keys use pinning, directional Spaces, and numbered Spaces', () => {
  assert.equal(matchShortcut(key('d', { meta: true }), 'darwin'), 'pin-tab');
  assert.equal(matchShortcut(key('ArrowRight', { meta: true, alt: true }), 'darwin'), 'next-space');
  assert.equal(matchShortcut(key('ArrowDown', { meta: true, alt: true }), 'darwin'), 'next-tab');
  assert.equal(matchShortcut(key('3', { control: true }), 'darwin'), 'space-3');
  assert.equal(matchShortcut(key('3', { alt: true }), 'win32'), 'space-3');
});

test('keyboard routes replace chrome buttons without conflicting with the Arc-style defaults', () => {
  for (const platform of ['darwin', 'win32']) {
    const mod = platform === 'darwin' ? { meta: true } : { control: true };
    assert.equal(matchShortcut(key('s', { code: 'KeyS', ...mod, alt: true }), platform), 'focus-sidebar');
    assert.equal(matchShortcut(key('s', mod), platform), 'sidebar-toggle');
    const catalog = shortcutCatalog(platform);
    for (const entry of catalog) {
      for (const accelerator of [entry.accelerator, ...entry.aliases].filter(Boolean)) {
        // Assigning each unchanged default validates it against every other route.
        assert.doesNotThrow(
          () => updateShortcut({}, platform, entry.id, entry.accelerator),
          `${entry.id}: ${accelerator}`,
        );
      }
    }
    assert.equal(catalog.find((entry) => entry.id === 'onboarding').editable, true);
    assert.equal(catalog.find((entry) => entry.id === 'reveal-tab').accelerator, '');
  }
  assert.equal(matchShortcut(key('F10'), 'win32'), 'browser-menu');
  assert.equal(matchShortcut(key('F10', { shift: true }), 'win32'), null);
  assert.equal(matchShortcut(key('F10'), 'darwin'), null);
  assert.equal(matchShortcut(key('Escape', { control: true, shift: true }), 'win32'), null);
  assert.equal(matchShortcut(key('.', { control: true, shift: true }), 'win32'), 'peek-close');
});

test('welcome completion survives a restart and older profiles receive the tour once', () => {
  const store = new BrowserStore();
  assert.equal(store.state.settings.onboardingCompleted, false);
  store.dispatch('settings:update', { values: { onboardingCompleted: true } });
  const saved = store.persistedState();
  assert.equal(hydrate(saved).settings.onboardingCompleted, true);
  delete saved.settings.onboardingCompleted;
  assert.equal(hydrate(saved).settings.onboardingCompleted, false);
  store.dispatch('settings:update', { values: { onboardingCompleted: 'false' } });
  assert.equal(store.state.settings.onboardingCompleted, true);
});

test('shortcut rebinding disables old aliases, detects conflicts and protects typing', () => {
  let overrides = updateShortcut({}, 'darwin', 'command-palette', 'Mod+Alt+T');
  assert.equal(matchShortcut(key('t', { meta: true }), 'darwin', overrides), null);
  assert.equal(matchShortcut(key('k', { meta: true }), 'darwin', overrides), null);
  assert.equal(matchShortcut(key('t', { meta: true, alt: true }), 'darwin', overrides), 'command-palette');
  assert.throws(() => updateShortcut(overrides, 'darwin', 'sidebar-toggle', 'Mod+Alt+T'), /Already used/);
  assert.throws(() => updateShortcut({}, 'darwin', 'sidebar-toggle', 'Mod+C'), /text editing/);
  assert.throws(() => updateShortcut({}, 'darwin', 'sidebar-toggle', 'Mod+Q'), /operating system/);
  assert.throws(() => updateShortcut({}, 'win32', 'sidebar-toggle', 'Alt+F4'), /operating system/);
  for (const value of ['A', 'Shift+S', 'Meta+S', 'Mod+Mod+S', 'Mod+💥', null])
    assert.throws(() => normalizeAccelerator(value));
  overrides = updateShortcut(overrides, 'darwin', 'command-palette', 'Mod+T');
  assert.equal(matchShortcut(key('k', { meta: true }), 'darwin', overrides), 'command-palette');
  overrides = updateShortcut(overrides, 'darwin', 'sidebar-toggle', '');
  assert.equal(matchShortcut(key('s', { meta: true }), 'darwin', overrides), null);
  assert.equal(matchShortcut(key('s', { control: true }), 'win32', overrides), 'sidebar-toggle');
});

test('saved binding swaps survive validation and malformed imported bindings are bounded', () => {
  let overrides = updateShortcut({}, 'darwin', 'sidebar-toggle', '');
  overrides = updateShortcut(overrides, 'darwin', 'save-page', 'Mod+S');
  overrides = updateShortcut(overrides, 'darwin', 'sidebar-toggle', 'Mod+Shift+S');
  const store = new BrowserStore();
  store.dispatch('settings:update', { values: { shortcutOverrides: overrides } });
  const restored = hydrate(store.persistedState());
  assert.equal(
    matchShortcut(key('s', { meta: true }), 'darwin', restored.settings.shortcutOverrides),
    'save-page',
  );
  assert.equal(
    matchShortcut(key('s', { meta: true, shift: true }), 'darwin', restored.settings.shortcutOverrides),
    'sidebar-toggle',
  );
  const cleaned = sanitizeOverrides({
    darwin: { unknown: 'Mod+S', 'save-page': 'Mod+Q', 'sidebar-toggle': 'not a key' },
    weirdOS: { x: 'Mod+S' },
  });
  assert.equal(cleaned.weirdOS, undefined);
  assert.equal(cleaned.darwin.unknown, undefined);
  assert.equal(matchShortcut(key('q', { meta: true }), 'darwin', cleaned), null);
});

test('fresh browser is empty; explicit home pages and drag pin transitions persist', () => {
  const store = new BrowserStore();
  assert.equal(store.state.activeTabId, null);
  assert.equal(store.state.tabs.length, 0);
  const home = store.dispatch('tab:create', { homePage: true });
  assert.equal(hydrate(store.persistedState()).tabs[0].homePage, true);
  store.dispatch('tab:update', { id: home.id, url: 'https://example.com' });
  assert.equal(store.state.tabs[0].homePage, undefined);
  const folder = store.dispatch('folder:create', { name: 'Research' });
  store.dispatch('tab:move', { id: home.id, folderId: folder.id });
  store.dispatch('tab:move', { id: home.id, pinned: true });
  assert.equal(store.state.tabs[0].pinned, true);
  assert.equal(store.state.tabs[0].folderId, folder.id);
  assert.equal(store.state.tabs[0].favorite, false);
  store.dispatch('tab:move', { id: home.id, favorite: true });
  assert.equal(store.state.tabs[0].favorite, true);
  assert.equal(store.state.tabs[0].folderId, null);
  store.dispatch('tab:move', { id: home.id, pinned: false, folderId: folder.id });
  assert.equal(store.state.tabs[0].pinned, false);
  assert.equal(store.state.tabs[0].folderId, null);
});

test('paste and search uses exact modifiers while ordinary paste stays with the editor', () => {
  assert.equal(matchShortcut(key('v', { meta: true, control: true }), 'darwin'), 'paste-search');
  assert.equal(matchShortcut(key('v', { code: 'KeyV', control: true, alt: true }), 'win32'), 'paste-search');
  assert.equal(matchShortcut(key('v', { meta: true }), 'darwin'), null);
  assert.equal(matchShortcut(key('v', { control: true }), 'win32'), null);
});

test('split groups occupy their rendered Today positions once, including grouped Favorites', () => {
  const store = new BrowserStore();
  const tab = (name) => store.dispatch('tab:create', { url: `https://example.com/${name}` });
  const loose = tab('loose');
  const favorite = tab('favorite');
  store.dispatch('tab:favorite', { id: favorite.id });
  const folder = store.dispatch('folder:create', { name: 'Folder' });
  const folderTab = tab('folder-tab');
  store.dispatch('tab:move', { id: folderTab.id, folderId: folder.id });
  const pinned = tab('pinned');
  store.dispatch('tab:pin', { id: pinned.id });
  const first = tab('first');
  const second = tab('second');
  const third = tab('third');
  store.dispatch('split:create', { firstId: first.id, secondId: second.id });
  store.dispatch('split:create', { firstId: favorite.id, secondId: third.id });
  const before = store.snapshot();
  assert.deepEqual(
    sidebarTabs(store.state).map((tab) => tab.id),
    [folderTab.id, pinned.id, first.id, second.id, favorite.id, third.id, loose.id],
  );
  assert.deepEqual(store.snapshot(), before, 'Computing shortcut order must not change session order');
  const other = store.dispatch('space:create', { name: 'Other' });
  assert.deepEqual(
    sidebarTabs(store.state, other.id).map((tab) => tab.id),
    [favorite.id],
  );
});
