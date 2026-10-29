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

test('authenticated background accepts mixed font/storage snapshot and replays it after worker wake', async () => {
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/main/extensions/bridge.cjs'), 'utf8'), {
    module,
    exports: module.exports,
    __dirname: path.resolve(__dirname, '../src/main/extensions'),
    require: (name) =>
      name === 'electron'
        ? { ipcMain: { handle() {} } }
        : name.startsWith('./')
          ? require(path.resolve(__dirname, '../src/main/extensions', name))
          : require(name),
    Buffer,
    structuredClone,
    setTimeout,
    clearTimeout,
    console,
  });
  const { ExtensionBridge } = module.exports;
  const id = 'a'.repeat(32),
    metadata = { enabled: true, generation: 'g', grants: { permissions: ['fontSettings', 'storage'] } };
  const delivered = [];
  let wakes = 0,
    dead = false;
  const session = {
    extensions: {
      getExtension: () => ({
        manifest: { manifest_version: 3, background: { service_worker: 'worker.js' } },
      }),
    },
    serviceWorkers: {
      startWorkerForScope: async () => {
        wakes++;
      },
    },
  };
  const bridge = new ExtensionBridge({ resolveExtension: () => metadata, dispatch() {} });
  bridge.sessions.set(session, {
    profileId: 'p',
    epochs: new Map(),
    revoked: new Set(),
    backgrounds: new Map(),
  });
  let context = {
    session,
    profileId: 'p',
    extensionId: id,
    generation: 'g',
    epoch: 0,
    kind: 'service-worker',
    url: `chrome-extension://${id}/worker.js`,
    sender: { isDestroyed: () => dead, send: (_channel, value) => delivered.push(value.event) },
  };
  bridge.authenticate = () => context;
  const events = [
    'storage.onChanged',
    'fontSettings.onFontChanged',
    'fontSettings.onDefaultFontSizeChanged',
    'fontSettings.onDefaultFixedFontSizeChanged',
    'fontSettings.onMinimumFontSizeChanged',
  ];
  const subscribe = async () => {
    const token = await bridge.handle({}, { operation: 'connect' });
    await bridge.handle({}, { operation: 'invoke', token, method: 'zacro.events.subscribe', args: [events] });
    return token;
  };
  let token = await subscribe();
  const filter = (c) => c.metadata.grants.permissions.includes('fontSettings');
  for (const event of events) bridge.emit('p', id, event, [{}], { filter });
  assert.deepEqual(delivered, events);
  dead = true;
  bridge.releaseLease(token);
  bridge.emit('p', id, events[1], [{}], { filter });
  bridge.emit('p', id, events[0], [{}]);
  await new Promise(setImmediate);
  assert.equal(wakes, 1);
  dead = false;
  context = {
    ...context,
    sender: { isDestroyed: () => dead, send: (_channel, value) => delivered.push(value.event) },
  };
  token = await subscribe();
  assert.deepEqual(delivered.slice(-2), [events[1], events[0]]);
  metadata.grants.permissions = ['storage'];
  bridge.emit('p', id, events[1], [{}], { filter });
  assert.equal(delivered.length, 7);
  await assert.rejects(
    bridge.handle(
      {},
      {
        operation: 'invoke',
        token,
        method: 'zacro.events.subscribe',
        args: [['fontSettings.onUnknownChanged']],
      },
    ),
    /Invalid event subscriptions/,
  );
});
