'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
test('font facade exposes Promise/callback methods, lastError and four independent events', async () => {
  const calls = [],
    listeners = [];
  const event = () => ({
    addListener() {},
    removeListener() {},
    hasListener() {
      return false;
    },
  });
  const chrome = {
    runtime: { id: 'a'.repeat(32), onMessage: event(), onConnect: event() },
    tabs: {},
    storage: {},
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/main/extensions/bootstrap.js'), 'utf8'), {
    chrome,
    document: { readyState: 'complete' },
    location: { protocol: 'chrome-extension:', pathname: '/page.html' },
    crypto: require('node:crypto').webcrypto,
    setTimeout,
    clearTimeout,
    console,
    zacroExtension: {
      onEvent: (listener) => listeners.push(listener),
      invoke: async (method, args) => {
        calls.push([method, args]);
        if (method === 'fontSettings.setDefaultFontSize') throw new Error('Native denied');
        return { pixelSize: 23, levelOfControl: 'controllable_by_this_extension' };
      },
    },
  });
  assert.equal(typeof chrome.fontSettings?.getFont, 'function');
  assert.equal((await chrome.fontSettings.getDefaultFontSize()).pixelSize, 23);
  const result = await new Promise((resolve) =>
    chrome.fontSettings.setDefaultFontSize({ pixelSize: 24 }, () =>
      resolve(chrome.runtime.lastError?.message),
    ),
  );
  assert.equal(result, 'Native denied');
  assert.equal(chrome.runtime.lastError, undefined);
  const received = [];
  for (const suffix of ['Font', 'DefaultFontSize', 'DefaultFixedFontSize', 'MinimumFontSize']) {
    chrome.fontSettings['on' + suffix + 'Changed'].addListener((value) =>
      received.push([suffix, value.pixelSize]),
    );
    for (const listener of listeners) listener('fontSettings.on' + suffix + 'Changed', [{ pixelSize: 29 }]);
  }
  assert.deepEqual(received, [
    ['Font', 29],
    ['DefaultFontSize', 29],
    ['DefaultFixedFontSize', 29],
    ['MinimumFontSize', 29],
  ]);
  assert.equal(calls.filter((c) => c[0].startsWith('fontSettings.')).length, 2);
});
