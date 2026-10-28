'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createBrowserAdapter } = require('../src/main/extensions/browser.cjs');
test('R3 duplicate tab move rejects before mutating the tab permutation or touching another view', () => {
  const a = { id: 'a', profileId: 'p' },
    b = { id: 'b', profileId: 'p' },
    other = { id: 'c', profileId: 'other' };
  const views = new Map([
    ['a', { contents: { id: 11 } }],
    ['b', { contents: { id: 12 }, draft: 'keep me' }],
  ]);
  for (const entry of views.values())
    Object.assign(entry.contents, {
      isLoading: () => false,
      isCurrentlyAudible: () => false,
      isAudioMuted: () => false,
    });
  let changed = 0;
  const store = { state: { tabs: [a, other, b] }, changed: () => changed++ };
  const browser = createBrowserAdapter({
    store,
    views,
    reserveView: (tab) => views.get(tab.id),
    getWindow: () => ({ id: 1, isDestroyed: () => false }),
  });
  const original = [...store.state.tabs],
    draftView = views.get('b');
  assert.throws(() => browser.tabs.move('p', [11, 11], { index: 0 }, () => {}), /duplicate/i);
  assert.deepEqual(store.state.tabs, original);
  assert.equal(store.state.tabs[2], b);
  assert.equal(changed, 0);
  assert.equal(views.get('b'), draftView);
  assert.equal(draftView.draft, 'keep me');
});

test('closed pins have no extension tab authority; dormant reservations keep their native identity', () => {
  const tabs = [
    { id: 'sleeping', profileId: 'p', url: 'https://example.test/', pinned: true },
    { id: 'closed', profileId: 'p', url: 'https://closed.test/', pinned: true, closed: true },
  ];
  const contents = (id) => ({
    id,
    isLoading: () => false,
    isCurrentlyAudible: () => false,
    isAudioMuted: () => false,
  });
  const entry = { contents: contents(21), dormant: true };
  const views = new Map([
    ['sleeping', entry],
    ['closed', { contents: contents(22), dormant: true }],
  ]);
  const browser = createBrowserAdapter({
    store: { state: { tabs, activeTabId: 'sleeping' } },
    views,
    reserveView: (tab) => views.get(tab.id),
    getWindow: () => ({ id: 1, isDestroyed: () => false }),
  });
  const guard = () => {};
  assert.deepEqual(
    browser.tabs.query('p', {}, guard).map((tab) => tab.id),
    [21],
  );
  assert.throws(() => browser.tabs.get('p', 22, guard), /Unknown profile tab/);
  assert.throws(() => browser.tabData(tabs[1]), /Unknown profile tab/);
  entry.dormant = false;
  assert.equal(browser.tabs.get('p', 21, guard).id, 21);
  assert.equal(browser.activeTabId('p'), 21);
});

test('native replacement and closed pins retire old extension grants while sleep keeps its identity', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  const main = fs.readFileSync(path.join(__dirname, '../src/main/main.cjs'), 'utf8');
  const start = main.indexOf('function publishExtensionTabChanges()');
  const end = main.indexOf('function arrangeViews()', start);
  const tab = { id: 'pin', profileId: 'p', pinned: true, url: 'https://example.test/' };
  let nativeId = 31;
  const events = [];
  const host = vm.createContext({
    store: { state: { tabs: [tab], profiles: [{ id: 'p' }] } },
    extensionTabSnapshot: new Map(),
    extensionBrowser: { tabData: () => ({ id: nativeId, windowId: 1, url: tab.url, pinned: true }) },
    extensionHost: { api: { publish: (...args) => events.push(args) } },
    closingWindow: false,
  });
  new vm.Script(main.slice(start, end)).runInContext(host);
  host.publishExtensionTabChanges();
  assert.equal(events.at(-1)[1], 'tabs.onCreated');
  events.length = 0;
  host.publishExtensionTabChanges();
  assert.equal(events.length, 0, 'Dormancy does not replace a native tab ID');
  nativeId = 32;
  host.publishExtensionTabChanges();
  assert.deepEqual(
    events.map((event) => event[1]),
    ['tabs.onRemoved', 'tabs.onCreated'],
  );
  assert.equal(events[0][2][0], 31);
  assert.equal(events[1][2][0].id, 32);
  events.length = 0;
  tab.closed = true;
  host.publishExtensionTabChanges();
  assert.equal(events.length, 1);
  assert.equal(events[0][1], 'tabs.onRemoved');
  assert.equal(events[0][2][0], 32);
});

test('extension pin destinations and labels survive close, hydration and reset without creating a home page', () => {
  const { BrowserStore, hydrate } = require('../src/core/store.cjs');
  const store = new BrowserStore();
  const tab = store.dispatch('tab:create', { homePage: true });
  const destination = 'chrome-extension://' + 'a'.repeat(32) + '/options.html';
  store.dispatch('tab:extension-page', { id: tab.id, url: destination, title: 'Extension options' });
  assert.equal(store.state.tabs.find((item) => item.id === tab.id).homePage, undefined);
  store.dispatch('tab:pin', { id: tab.id });
  store.dispatch('tab:update', { id: tab.id, url: 'https://example.test/' });
  store.dispatch('tab:close', { id: tab.id });
  const restored = hydrate(store.state);
  const saved = restored.tabs.find((item) => item.id === tab.id);
  assert.equal(saved.closed, true);
  assert.equal(saved.url, destination);
  assert.equal(saved.pinnedUrl, destination);
  assert.equal(saved.pinnedTitle, 'Extension options');
  assert.equal(saved.homePage, undefined);
  store.state = restored;
  store.dispatch('tab:activate', { id: tab.id });
  store.dispatch('tab:reset-pin', { id: tab.id });
  assert.equal(saved.url, destination);
  assert.equal(saved.closed, undefined);
});

test('moving an extension tab preserves closed pin records and unrelated profiles', () => {
  const tabs = [
    { id: 'first', profileId: 'p' },
    { id: 'saved', profileId: 'p', closed: true },
    { id: 'foreign', profileId: 'other' },
    { id: 'second', profileId: 'p' },
  ];
  const views = new Map(
    tabs.map((tab, index) => [
      tab.id,
      {
        contents: {
          id: 10 + index,
          isLoading: () => false,
          isCurrentlyAudible: () => false,
          isAudioMuted: () => false,
        },
      },
    ]),
  );
  const store = { state: { tabs }, changed: () => {} };
  const browser = createBrowserAdapter({
    store,
    views,
    reserveView: (tab) => views.get(tab.id),
    getWindow: () => ({ id: 1, isDestroyed: () => false }),
  });
  browser.tabs.move('p', [13], { index: 0 }, () => {});
  assert.deepEqual(
    store.state.tabs.map((tab) => tab.id),
    ['second', 'saved', 'foreign', 'first'],
  );
});

test('browser defaults and custom bindings take priority over extension shortcuts', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  const { matchShortcut, updateShortcut } = require('../src/core/shortcuts.cjs');
  const main = fs.readFileSync(path.join(__dirname, '../src/main/main.cjs'), 'utf8');
  const start = main.indexOf('function handleShortcut(');
  const end = main.indexOf('async function savePage()', start);
  const calls = [];
  const contents = {};
  const host = vm.createContext({
    recentTabModifiers: null,
    recentTabCycle: null,
    recordingShortcut: false,
    validWindow: () => true,
    win: { webContents: contents },
    process: { platform: 'darwin' },
    store: { state: { settings: { shortcutOverrides: {} } } },
    matchShortcut,
    extensionHost: {
      shortcut: () => {
        calls.push('extension');
        return true;
      },
    },
    runMacAction: async (action) => {
      calls.push(action);
    },
    report: (error) => {
      throw error;
    },
  });
  new vm.Script(main.slice(start, end)).runInContext(host);
  const event = { preventDefault: () => {} };
  host.handleShortcut(event, { type: 'keyDown', key: 's', meta: true }, contents);
  assert.deepEqual(calls, ['sidebar-toggle']);
  host.store.state.settings.shortcutOverrides = updateShortcut({}, 'darwin', 'sidebar-toggle', 'Mod+Shift+Y');
  host.handleShortcut(event, { type: 'keyDown', key: 'y', meta: true, shift: true }, contents);
  assert.deepEqual(calls, ['sidebar-toggle', 'sidebar-toggle']);
  host.handleShortcut(event, { type: 'keyDown', key: 'u', meta: true, shift: true }, contents);
  assert.deepEqual(calls, ['sidebar-toggle', 'sidebar-toggle', 'extension']);
});
