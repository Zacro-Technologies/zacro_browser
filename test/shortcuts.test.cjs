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
    ['pin', 'pin-blank', 'f2-a', 'folder-blank', 'f1-a', 'loose-a', 'home', 'loose-b'],
  );
  assert.deepEqual(
    sidebarTabs(state, 'other').map((item) => item.id),
    ['other'],
  );
  assert.deepEqual(state, before);
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
  assert.equal(store.state.tabs[0].folderId, null);
  store.dispatch('tab:move', { id: home.id, pinned: false, folderId: folder.id });
  assert.equal(store.state.tabs[0].pinned, false);
  assert.equal(store.state.tabs[0].folderId, folder.id);
});
