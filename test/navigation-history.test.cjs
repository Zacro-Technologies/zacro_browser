'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { BrowserStore, hydrate } = require('../src/core/store.cjs');
const { cleanNavigationHistory } = require('../src/core/navigation-history.cjs');
const history = () => ({
  entries: [
    { url: 'https://example.com/a', title: 'A', pageState: 'form-secret' },
    { url: 'https://example.com/b', title: 'B' },
    { url: 'https://example.com/c', title: 'C' },
  ],
  index: 1,
});

test('navigation history keeps both sides of the active entry without opaque form state', () => {
  assert.deepEqual(cleanNavigationHistory(history()), {
    entries: [
      { url: 'https://example.com/a', title: 'A' },
      { url: 'https://example.com/b', title: 'B' },
      { url: 'https://example.com/c', title: 'C' },
    ],
    index: 1,
  });
  assert.equal(cleanNavigationHistory(history(), 'https://example.com/other'), null);
  assert.equal(cleanNavigationHistory({ ...history(), index: -1 }), null);
  const unsafe = {
    entries: [{ url: 'file:///secret' }, ...history().entries, { url: 'https://user:password@example.com/' }],
    index: 2,
  };
  assert.deepEqual(cleanNavigationHistory(unsafe), cleanNavigationHistory(history()));
  assert.equal(cleanNavigationHistory({ entries: [{ url: 'javascript:alert(1)' }], index: 0 }), null);
});

test('long histories retain bounded back and forward destinations around the current page', () => {
  const entries = Array.from({ length: 500 }, (_, i) => ({ url: `https://example.com/${i}` }));
  const saved = cleanNavigationHistory({ entries, index: 250 });
  assert.equal(saved.entries.length, 100);
  assert.equal(saved.index, 49);
  assert.equal(saved.entries[saved.index].url, entries[250].url);
});

test('archive and restart retain history; exports, closed pins and cleared history do not', () => {
  const store = new BrowserStore();
  store.dispatch('tab:create', { url: 'https://example.com/b' });
  const tab = store.state.tabs[0];
  tab.navigationHistory = cleanNavigationHistory(history());
  assert.deepEqual(hydrate(store.persistedState()).tabs[0].navigationHistory, tab.navigationHistory);
  assert.equal(store.exportData().tabs[0].navigationHistory, undefined);
  store.dispatch('tab:close', { id: tab.id });
  assert.equal(hydrate(store.persistedState()).archive[0].navigationHistory.index, 1);
  store.dispatch('tab:restore', { id: tab.id });
  const restored = store.state.tabs[0];
  assert.equal(restored.navigationHistory.index, 1);
  store.dispatch('history:clear');
  assert.equal(restored.navigationHistory, undefined);
  restored.navigationHistory = cleanNavigationHistory(history());
  store.dispatch('tab:pin', { id: restored.id });
  store.dispatch('tab:close', { id: restored.id });
  assert.equal(restored.navigationHistory, undefined);
});

test('private tab history never enters disk state, and imported tabs cannot inject history', () => {
  const store = new BrowserStore();
  store.dispatch('profile:create', { name: 'Private', private: true });
  const tab = store.dispatch('tab:create', { url: 'https://example.com/b' });
  store.state.tabs.find((item) => item.id === tab.id).navigationHistory = cleanNavigationHistory(history());
  assert.equal(
    store.persistedState().tabs.some((item) => item.id === tab.id),
    false,
  );
  const source = new BrowserStore();
  source.dispatch('tab:create', { url: 'https://example.com/b' });
  const data = source.exportData();
  data.tabs[0].navigationHistory = history();
  const target = new BrowserStore();
  target.importData(data);
  assert(target.state.tabs.every((item) => !item.navigationHistory));
});

test('clearing history during a delayed restore cannot repopulate the old stack', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  const source = fs.readFileSync(path.join(__dirname, '../src/main/main.cjs'), 'utf8');
  let finish,
    cleared = 0,
    remembered = 0;
  const pending = new Promise((resolve) => {
    finish = resolve;
  });
  const context = vm.createContext({
    cleanNavigationHistory,
    safeNavigate: () => {
      throw new Error('Expected a history restore');
    },
    rememberNavigationHistory: () => {
      remembered++;
    },
    store: { changed() {} },
    arrangeViews() {},
    publish() {},
  });
  new vm.Script(
    source.slice(source.indexOf('function restoreTabNavigation('), source.indexOf('function navigated(')),
  ).runInContext(context);
  const entry = {
    contents: {
      isDestroyed: () => false,
      navigationHistory: {
        restore: () => pending,
        clear: () => {
          cleared++;
        },
      },
    },
  };
  context.restoreTabNavigation(entry, { url: 'https://example.com/b', navigationHistory: history() });
  entry.historyEpoch = 1;
  finish();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(cleared, 1);
  assert.equal(remembered, 0);
  assert.equal(entry.restoringHistory, false);
});
