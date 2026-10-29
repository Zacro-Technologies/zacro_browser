'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { cleanNavigationHistory } = require('../src/core/navigation-history.cjs');

// Exercise the actual host lifecycle functions with deferred native work.
// This makes otherwise millisecond-sized races deterministic without a
// debugger, real browsing data, or an Electron window.
const main = fs.readFileSync(path.join(__dirname, '../src/main/main.cjs'), 'utf8');
const start = main.indexOf('function requestCloseEntry(');
const end = main.indexOf('async function requestClosePeek(');
assert.ok(start > 0 && end > start, 'The host lifecycle functions must be present');
const lifecycle = new vm.Script(main.slice(start, end), { filename: 'host-pin-lifecycle.cjs' });

function harness() {
  const now = 1800000000000;
  let resolveInspection;
  const state = {
    settings: { pinnedSleepMinutes: 20 },
    tabs: [{ id: 'pin', pinned: true, profileId: 'default', url: 'https://example.test/' }],
    downloads: [],
    activeTabId: null,
  };
  const entry = {
    tabId: 'pin',
    inactiveSince: now - 21 * 60000,
    activityVersion: 0,
    navigationVersion: 1,
    closeCount: 0,
    discardCount: 0,
    clearedHistory: 0,
    documentURL: 'https://example.test/',
    inspectCount: 0,
  };
  entry.contents = {
    id: 17,
    isDestroyed: () => false,
    isLoading: () => false,
    isCurrentlyAudible: () => false,
    isBeingCaptured: () => false,
    isDevToolsOpened: () => false,
    executeJavaScriptInIsolatedWorld: () => {
      entry.inspectCount++;
      return new Promise((resolve) => {
        resolveInspection = resolve;
      });
    },
    getURL: () => entry.documentURL,
    navigationHistory: {
      clear: () => entry.clearedHistory++,
      getAllEntries: () => [{ url: 'https://example.test/' }],
      getActiveIndex: () => 0,
    },
    loadURL: async (url) => {
      entry.discardCount++;
      entry.documentURL = url;
    },
    close: () => {
      entry.closeCount++;
      entry.closeRequest.resolve(true);
    },
  };
  const host = vm.createContext({
    store: { state },
    cleanNavigationHistory,
    views: new Map([['pin', entry]]),
    sleepingPins: false,
    quitting: false,
    closingWindow: false,
    validWindow: () => true,
    splitPair: null,
    peek: null,
    pendingAuth: null,
    liveDownloads: new Map(),
    Date: { now: () => now },
    setTimeout,
    clearTimeout,
    publish: () => {},
    reconcile: () => {},
  });
  new vm.Script(
    main.slice(
      main.indexOf('function rememberNavigationHistory('),
      main.indexOf('function restoreTabNavigation('),
    ),
  ).runInContext(host);
  lifecycle.runInContext(host);
  return { host, state, entry, now, finishInspection: () => resolveInspection(true) };
}

for (const minutes of [0, 60])
  test(`pending idle sleep honors a newly selected ${minutes ? 'longer timeout' : 'Never preference'}`, async () => {
    const b = harness();
    const pending = b.host.sleepIdlePins();
    assert.equal(b.entry.inspectCount, 1);
    b.state.settings.pinnedSleepMinutes = minutes;
    b.finishInspection();
    await pending;
    assert.equal(b.entry.closeCount, 0);
    assert.equal(b.entry.discardCount, 0);
  });

test('a completed inspection cannot sleep a pin that was activated and left again', async () => {
  const b = harness();
  const pending = b.host.sleepPinnedEntry(b.entry, { automatic: true });
  b.entry.activityVersion += 2;
  b.entry.inactiveSince = b.now;
  b.finishInspection();
  assert.equal(await pending, false);
  assert.equal(b.entry.closeCount, 0);
  assert.equal(b.entry.discardCount, 0);
});

for (const automatic of [false, true])
  test(`${automatic ? 'automatic' : 'manual'} sleep rejects an inspection from an older navigation or native page`, async () => {
    for (const replace of [false, true]) {
      const b = harness();
      const pending = b.host.sleepPinnedEntry(b.entry, { automatic });
      if (replace) b.host.views.set('pin', { ...b.entry });
      else b.entry.navigationVersion++;
      b.finishInspection();
      assert.equal(await pending, false);
      assert.equal(b.entry.closeCount, 0);
      assert.equal(b.entry.discardCount, 0);
    }
  });

test('manual Sleep remains available with Never while valid automatic sleep unloads', async () => {
  for (const automatic of [false, true]) {
    const b = harness();
    if (!automatic) b.state.settings.pinnedSleepMinutes = 0;
    const pending = b.host.sleepPinnedEntry(b.entry, { automatic });
    b.finishInspection();
    assert.equal(await pending, true);
    assert.equal(b.entry.closeCount, 0);
    assert.equal(b.entry.discardCount, 1);
    assert.equal(b.entry.dormant, true);
    assert.equal(b.entry.clearedHistory, 1);
    assert.equal(b.entry.documentURL, 'about:blank');
    assert.equal(b.state.tabs[0].navigationHistory.entries[0].url, 'https://example.test/');
    assert.equal(b.entry.contents.id, 17);
    assert.equal(b.host.views.get('pin'), b.entry);
    assert.equal(b.entry.sleepRequest, false);
  }
});

test('explicit Close upgrades pending discard and closes its retained native identity exactly once', async () => {
  const b = harness();
  let finishDiscard;
  b.entry.contents.loadURL = (url) => {
    b.entry.discardCount++;
    return new Promise((resolve) => {
      finishDiscard = () => {
        b.entry.documentURL = url;
        resolve();
      };
    });
  };
  const asleep = b.host.requestCloseEntry(b.entry, { sleep: true });
  assert.equal(b.entry.sleepRequest, true);
  const explicit = b.host.requestCloseEntry(b.entry);
  assert.equal(explicit, asleep);
  assert.equal(b.entry.sleepRequest, false);
  assert.equal(b.entry.closeCount, 0);
  finishDiscard();
  assert.equal(await explicit, true);
  assert.equal(b.entry.closeCount, 1);
  assert.equal(b.entry.discardCount, 1);
  assert.equal(b.entry.dormant, undefined);
});

test('a cancelled discard retains the document and allows a later explicit Close', async () => {
  const b = harness();
  b.entry.userEdited = true;
  b.entry.contents.loadURL = async () => {
    throw new Error('ERR_ABORTED');
  };
  assert.equal(await b.host.requestCloseEntry(b.entry, { sleep: true }), false);
  assert.equal(b.entry.documentURL, 'https://example.test/');
  assert.equal(b.entry.clearedHistory, 0);
  assert.equal(b.entry.userEdited, true);
  assert.equal(b.entry.dormant, undefined);
  assert.equal(b.entry.closeRequest, null);
  assert.equal(await b.host.requestCloseEntry(b.entry), true);
  assert.equal(b.entry.closeCount, 1);
});

test('dormant reservations are not inspected or discarded again', async () => {
  const b = harness();
  b.entry.dormant = true;
  assert.equal(await b.host.sleepPinnedEntry(b.entry), false);
  assert.equal(b.entry.inspectCount, 0);
  assert.equal(b.entry.discardCount, 0);
});

test('a page under DevTools inspection stays live without starting the automatic unload probe', async () => {
  const b = harness();
  b.entry.contents.isDevToolsOpened = () => true;
  assert.equal(await b.host.sleepPinnedEntry(b.entry, { automatic: true }), false);
  assert.equal(b.entry.inspectCount, 0);
  assert.equal(b.entry.closeCount, 0);
  assert.equal(b.entry.discardCount, 0);
});

test('startup auto-archive expires dormant reservations without treating them as loaded pages', async () => {
  const { BrowserStore } = require('../src/core/store.cjs');
  const { archiveCandidate } = require('../src/core/archive.cjs');
  const b = harness();
  const store = new BrowserStore();
  const created = store.dispatch('tab:create', { url: 'https://stale.test/', active: false });
  const stale = store.state.tabs.find((tab) => tab.id === created.id);
  stale.lastActiveAt = Date.now() - 13 * 3600000;
  b.entry.tabId = stale.id;
  b.entry.dormant = true;
  b.host.views = new Map([[stale.id, b.entry]]);
  b.host.store = store;
  b.host.archiveCandidate = archiveCandidate;
  b.host.archivingTabs = false;
  await b.host.archiveIdleTabs();
  assert.equal(
    store.state.tabs.some((tab) => tab.id === stale.id),
    false,
  );
  assert.equal(
    store.state.archive.some((tab) => tab.id === stale.id),
    true,
  );
  assert.equal(b.entry.inspectCount, 0);
  assert.equal(b.entry.discardCount, 0);
});
