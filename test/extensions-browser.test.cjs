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
