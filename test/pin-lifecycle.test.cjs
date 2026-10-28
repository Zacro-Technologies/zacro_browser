'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

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
    tabs: [{ id: 'pin', pinned: true, profileId: 'default' }],
    downloads: [],
    activeTabId: null,
  };
  const entry = {
    tabId: 'pin',
    inactiveSince: now - 21 * 60000,
    activityVersion: 0,
    navigationVersion: 1,
    closeCount: 0,
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
    close: () => {
      entry.closeCount++;
      entry.closeRequest.resolve(true);
    },
  };
  const host = vm.createContext({
    store: { state },
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
  });

test('a completed inspection cannot sleep a pin that was activated and left again', async () => {
  const b = harness();
  const pending = b.host.sleepPinnedEntry(b.entry, { automatic: true });
  b.entry.activityVersion += 2;
  b.entry.inactiveSince = b.now;
  b.finishInspection();
  assert.equal(await pending, false);
  assert.equal(b.entry.closeCount, 0);
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
    }
  });

test('manual Sleep remains available with Never while valid automatic sleep unloads', async () => {
  for (const automatic of [false, true]) {
    const b = harness();
    if (!automatic) b.state.settings.pinnedSleepMinutes = 0;
    const pending = b.host.sleepPinnedEntry(b.entry, { automatic });
    b.finishInspection();
    assert.equal(await pending, true);
    assert.equal(b.entry.closeCount, 1);
    assert.equal(b.entry.sleepRequest, true);
  }
});

test('explicit Close upgrades a pending sleep close without issuing a second native close', async () => {
  const b = harness();
  b.entry.contents.close = () => {
    b.entry.closeCount++;
  };
  const asleep = b.host.requestCloseEntry(b.entry, { sleep: true });
  assert.equal(b.entry.sleepRequest, true);
  const explicit = b.host.requestCloseEntry(b.entry);
  assert.equal(explicit, asleep);
  assert.equal(b.entry.sleepRequest, false);
  assert.equal(b.entry.closeCount, 1);
  b.entry.closeRequest.resolve(true);
  assert.equal(await explicit, true);
});

test('a page under DevTools inspection stays live without starting the automatic unload probe', async () => {
  const b = harness();
  b.entry.contents.isDevToolsOpened = () => true;
  assert.equal(await b.host.sleepPinnedEntry(b.entry, { automatic: true }), false);
  assert.equal(b.entry.inspectCount, 0);
  assert.equal(b.entry.closeCount, 0);
});
