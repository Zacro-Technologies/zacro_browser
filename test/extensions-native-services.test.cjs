'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { inspectManifest } = require('../src/main/extensions/catalog.cjs');
test('offscreen remains unavailable to MV2 packages', () => {
  assert.equal(
    inspectManifest({ manifest_version: 2, name: 'MV2', version: '1', permissions: ['offscreen'] })
      .compatible,
    false,
  );
});
test('native static ruleset reconciliation retains choices and applies defaults only to new IDs', () => {
  const { reconcileRulesets } = require('../src/main/extensions/native-services.cjs');
  const resources = [
    { id: 'kept', enabled: true },
    { id: 'disabled', enabled: true },
    { id: 'new', enabled: true },
    { id: 'new-off', enabled: false },
  ];
  assert.deepEqual(
    reconcileRulesets(resources, {
      knownRulesets: ['kept', 'disabled', 'removed'],
      enabledRulesets: ['kept', 'removed'],
    }),
    ['kept', 'new'],
  );
  assert.deepEqual(reconcileRulesets(resources, null), ['kept', 'disabled', 'new']);
});
test('native ruleset resources accept one extension-root slash without changing the path', () => {
  for (const path of [
    'rules.json',
    'rulesets/main/easylist.json',
    '/rules.json',
    '/rulesets/main/easylist.json',
  ]) {
    const manifest = {
      manifest_version: 3,
      name: 'Native',
      version: '1',
      permissions: ['declarativeNetRequest'],
      declarative_net_request: { rule_resources: [{ id: 'rules', enabled: true, path }] },
    };
    assert.equal(inspectManifest(manifest).compatible, true, path);
    assert.equal(manifest.declarative_net_request.rule_resources[0].path, path);
  }
});
test('native ruleset resources reject ambiguous IDs and paths before installation', () => {
  const manifest = {
    manifest_version: 3,
    name: 'Native',
    version: '1',
    permissions: ['declarativeNetRequest'],
  };
  for (const path of [
    '../rules.json',
    '/../rules.json',
    '/rules/../rules.json',
    '/rules/./rules.json',
    '//rules.json',
    '//foreign/rules.json',
    '/',
    '',
    '/rules//rules.json',
    '/rules/',
    'https://foreign/rules.json',
    'chrome-extension://foreign/rules.json',
    'rules.json?x',
    '/rules.json#fragment',
    '/rules/%2e%2e/rules.json',
    '/rules%2frules.json',
    '/rules\u0000.json',
    '/rules\n.json',
    '/rules .json',
    '/rules\u007f.json',
    'rules\\evil.json',
    '/rules\\evil.json',
  ])
    assert.throws(
      () =>
        inspectManifest({
          ...manifest,
          declarative_net_request: { rule_resources: [{ id: 'rules', enabled: true, path }] },
        }),
      /Invalid declarative_net_request/,
      JSON.stringify(path),
    );
  assert.throws(
    () =>
      inspectManifest({
        ...manifest,
        declarative_net_request: {
          rule_resources: [
            { id: 'rules', enabled: true, path: 'rules.json' },
            { id: 'rules', enabled: false, path: 'second.json' },
          ],
        },
      }),
    /Invalid declarative_net_request/,
  );
});

test('native service authority uses effective optional grants, not original declarations', () => {
  const { needsNativeServices } = require('../src/main/extensions/native-services.cjs');
  for (const permission of [
    'alarms',
    'offscreen',
    'declarativeNetRequest',
    'declarativeNetRequestWithHostAccess',
  ]) {
    const manifest = { permissions: [], optional_permissions: [permission] };
    assert.equal(needsNativeServices(manifest, { permissions: [permission] }), true, permission);
    assert.equal(needsNativeServices(manifest, { permissions: [] }), false, permission);
  }
});

test('optional native namespaces exposed after grant receive readiness, checkpoint and event wrappers', async () => {
  const vm = require('node:vm'),
    fs = require('node:fs'),
    path = require('node:path');
  const event = () => ({
    addListener() {},
    removeListener() {},
    hasListener() {
      return false;
    },
  });
  const calls = [],
    listeners = [];
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
        calls.push([method, ...args]);
        if (method === 'permissions.request') {
          chrome.alarms = { create: async () => calls.push(['native.create']), onAlarm: event() };
          chrome.offscreen = { hasDocument: async () => false };
          chrome.declarativeNetRequest = { updateDynamicRules: async () => calls.push(['native.dnr']) };
          return true;
        }
      },
    },
  });
  await chrome.permissions.request({ permissions: ['alarms', 'offscreen', 'declarativeNetRequest'] });
  calls.length = 0;
  await chrome.alarms.create('optional', { when: 500 });
  assert.deepEqual(
    calls.map((call) => call[0]),
    ['zacro.nativeServices.ready', 'native.create', 'zacro.nativeServices.checkpoint'],
  );
  assert.equal(calls[0][1], 'alarms');
  calls.length = 0;
  await chrome.offscreen.hasDocument();
  await chrome.declarativeNetRequest.updateDynamicRules({ addRules: [] });
  assert.deepEqual(
    calls.map((call) => call[0]),
    [
      'zacro.nativeServices.ready',
      'zacro.nativeServices.ready',
      'native.dnr',
      'zacro.nativeServices.checkpoint',
    ],
  );
  const delivered = [];
  chrome.alarms.onAlarm.addListener((alarm) => delivered.push(alarm.name));
  for (const listener of listeners) listener('alarms.onAlarm', [{ name: 'optional' }]);
  assert.deepEqual(delivered, ['optional']);
});

test('optional service controller blocks transitions, delivers effective alarms and revokes removed service state', async (t) => {
  const vm = require('node:vm'),
    fs = require('node:fs'),
    path = require('node:path'),
    os = require('node:os');
  const { EventEmitter } = require('node:events');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-service-controller-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const session = { extensions: new EventEmitter() },
    handlers = new Map();
  const alarms = new Map(),
    events = [];
  let offscreen = false;
  const chrome = {
    alarms: {
      getAll: async () => [...alarms.values()],
      create: async (name, info) => alarms.set(name, { name, scheduledTime: info.when }),
      clearAll: async () => alarms.clear(),
    },
    offscreen: {
      hasDocument: async () => offscreen,
      createDocument: async () => {
        offscreen = true;
      },
      closeDocument: async () => {
        offscreen = false;
      },
    },
  };
  class BrowserWindow {
    constructor() {
      this.webContents = new EventEmitter();
      Object.assign(this.webContents, {
        session,
        mainFrame: { url: '' },
        setWindowOpenHandler() {},
        executeJavaScript: (script) => vm.runInNewContext(script, { chrome }),
      });
    }
    async loadURL(url) {
      this.webContents.mainFrame.url = url;
    }
    isDestroyed() {
      return !!this.destroyed;
    }
    destroy() {
      this.destroyed = true;
    }
  }
  const module = { exports: {} };
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, '../src/main/extensions/native-services.cjs'), 'utf8'),
    {
      module,
      exports: module.exports,
      __dirname: path.resolve(__dirname, '../src/main/extensions'),
      require: (name) =>
        name === 'electron'
          ? { BrowserWindow, ipcMain: { handle: (channel, handler) => handlers.set(channel, handler) } }
          : require(name),
    },
  );
  const { NativeServices, registerNativeEventDelivery } = module.exports;
  const filename = path.join(root, 'state.json');
  const controller = new NativeServices({
    session,
    id: 'a'.repeat(32),
    manifest: { permissions: [], optional_permissions: ['alarms', 'offscreen'] },
    permissions: [],
    filename,
    persist: (file, state) => fs.writeFileSync(file, JSON.stringify(state)),
    guard() {},
  });
  t.after(() => controller.close());
  registerNativeEventDelivery(session, (_id, _event, args) => events.push(args[0].name));
  await controller.initialize();
  let release;
  const held = new Promise((resolve) => {
    release = resolve;
  });
  const grant = controller.reconfigure(['alarms', 'offscreen'], () => held);
  let ready = false;
  controller.ready.then(() => {
    ready = true;
  });
  await new Promise(setImmediate);
  assert.equal(ready, false);
  release();
  await grant;
  await chrome.alarms.create('durable', { when: Date.now() + 60000 });
  await chrome.offscreen.createDocument();
  await controller.checkpoint();
  const handler = handlers.get('zacro:native-extension-alarm:v1');
  const event = () => ({
    sender: controller.window.webContents,
    senderFrame: controller.window.webContents.mainFrame,
  });
  await handler(event(), { name: 'durable', scheduledTime: Date.now() });
  assert.deepEqual(events, ['durable']);
  await controller.reconfigure([], async () => {});
  assert.equal(alarms.size, 0);
  assert.equal(offscreen, false);
  await assert.rejects(handler(event(), { name: 'revoked', scheduledTime: Date.now() }), /permission/);
  // A native mutation already dispatched before revocation may finish late.
  await chrome.alarms.create('late-revoked', { when: Date.now() + 60000 });
  await controller.reconfigure(['alarms'], async () => {});
  assert.equal(alarms.size, 0, 'removed alarms must not resurrect on regrant');
});
