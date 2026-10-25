'use strict';
// JS integration tests use real controllers/facades with isolated native API/IPC
// boundaries. They do not claim custom Electron execution.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
const source = path.resolve(__dirname, '../src/main/extensions');
const ID = 'a'.repeat(32);
function event() {
  const listeners = new Set();
  return {
    listeners,
    addListener: (fn) => listeners.add(fn),
    removeListener: (fn) => listeners.delete(fn),
    hasListener: (fn) => listeners.has(fn),
  };
}
function boundary(t, chrome, manifest, permissions) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-service-transition-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const session = { extensions: new EventEmitter() },
    handlers = new Map();
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
  const electron = {
    BrowserWindow,
    ipcMain: { handle: (channel, handler) => handlers.set(channel, handler) },
  };
  function load(filename, overrides = {}) {
    const module = { exports: {} };
    vm.runInNewContext(fs.readFileSync(path.join(source, filename), 'utf8'), {
      module,
      exports: module.exports,
      __dirname: source,
      Buffer,
      structuredClone,
      setTimeout,
      clearTimeout,
      console,
      require: (name) =>
        name === 'electron'
          ? electron
          : overrides[name] || (name.startsWith('./') ? require(path.join(source, name)) : require(name)),
    });
    return module.exports;
  }
  const services = load('native-services.cjs');
  const filename = path.join(root, 'state.json');
  const controller = new services.NativeServices({
    session,
    id: ID,
    manifest,
    permissions,
    filename,
    persist: (file, state) => fs.writeFileSync(file, JSON.stringify(state)),
    guard() {},
  });
  t.after(() => controller.close());
  return { session, handlers, services, controller, filename, load };
}

test('page grant refreshes a living worker without public permission listeners before its message-created durable alarm', async (t) => {
  const alarms = new Map(),
    nativeCalls = [],
    managedEvents = [];
  const alarmAPI = () => ({
    create: async (name, info) => {
      nativeCalls.push(name);
      alarms.set(name, { name, scheduledTime: info.when });
    },
    getAll: async () => [...alarms.values()],
    clearAll: async () => alarms.clear(),
    onAlarm: event(),
  });
  const manifest = {
    manifest_version: 3,
    name: 'Optional',
    version: '1',
    permissions: ['storage'],
    optional_permissions: ['alarms'],
    background: { service_worker: 'worker.js' },
  };
  const nativeChrome = {};
  const f = boundary(t, nativeChrome, manifest, ['storage']);
  await f.controller.initialize();
  f.session.extensions.getExtension = () => ({ manifest });
  const metadata = {
    enabled: true,
    generation: 'living',
    manifest,
    originalManifest: manifest,
    grants: { permissions: ['storage'], origins: [] },
    capabilities: { reviewedPermissions: true },
  };
  const { ExtensionBridge } = f.load('bridge.cjs', { './native-services.cjs': f.services });
  const bridge = new ExtensionBridge({ resolveExtension: () => metadata, dispatch() {} });
  bridge.sessions.set(f.session, {
    profileId: 'p',
    epochs: new Map(),
    revoked: new Set(),
    backgrounds: new Map(),
  });
  const hostEvents = [],
    calls = [];
  const workerContext = {
    session: f.session,
    profileId: 'p',
    extensionId: ID,
    generation: 'living',
    epoch: 0,
    kind: 'service-worker',
    url: `chrome-extension://${ID}/worker.js`,
    metadata,
    sender: {
      isDestroyed: () => false,
      send: (_channel, message) => {
        for (const listener of hostEvents) listener(message.event, message.args);
      },
    },
  };
  bridge.authenticate = () => workerContext;
  const token = await bridge.handle({}, { operation: 'connect' });
  t.after(() => bridge.clearBackground(bridge.sessions.get(f.session), ID));
  f.services.registerNativeEventDelivery(f.session, (id, name, args) => bridge.emit('p', id, name, args));
  const message = event(),
    workerChrome = { runtime: { id: ID, onMessage: message, onConnect: event() }, storage: {}, tabs: {} };
  let subscribed;
  const subscription = new Promise((resolve) => {
    subscribed = resolve;
  });
  const context = vm.createContext({
    chrome: workerChrome,
    crypto: require('node:crypto').webcrypto,
    setTimeout,
    clearTimeout,
    console,
    zacroExtension: {
      onEvent: (listener) => hostEvents.push(listener),
      invoke: async (method, args) => {
        calls.push(method);
        const result = await bridge.handle({}, { operation: 'invoke', token, method, args });
        if (method === 'zacro.events.subscribe') subscribed();
        return result;
      },
    },
  });
  vm.runInContext(fs.readFileSync(path.join(source, 'bootstrap.js'), 'utf8'), context);
  // This is the original worker program, installed before another context grants.
  vm.runInContext(
    `
    chrome.storage.onChanged.addListener(()=>{});
    chrome.runtime.onMessage.addListener((message,sender,reply)=>{
      if(message!=='create')return;
      chrome.alarms.onAlarm.addListener(alarm=>globalThis.onManagedAlarm(alarm.name));
      chrome.alarms.create('worker-durable',{when:Date.now()+3600000}).then(()=>reply(true));
      return true;
    });
  `,
    context,
  );
  context.onManagedAlarm = (name) => managedEvents.push(name);
  await subscription;
  assert.equal(workerChrome.permissions.onAdded.hasListeners(), false);
  assert.equal(workerChrome.permissions.onRemoved.hasListeners(), false);
  const api = new ExtensionAPI({
    resolveExtension: () => metadata,
    tabs: { get: async (_p, id) => ({ id, url: 'https://fixture.test/' }) },
    dialogs: { requestPermissions: async () => true },
    changePermissionDelta: async (_p, _id, _details, remove) => {
      assert.equal(remove, false);
      const before = structuredClone(metadata.grants);
      await f.controller.reconfigure(['storage', 'alarms'], async () => {
        metadata.grants = { permissions: ['alarms', 'storage'], origins: [] };
        nativeChrome.alarms = alarmAPI();
        workerChrome.alarms = alarmAPI();
      });
      return { permissionChange: { before, after: structuredClone(metadata.grants) } };
    },
    emit: (...args) => bridge.emit(...args),
  });
  await api.activateAction('p', ID, 7);
  await api.call(
    { profileId: 'p', extensionId: ID, generation: 'living', kind: 'extension-frame' },
    'permissions.request',
    [{ permissions: ['alarms'] }],
  );
  calls.length = 0;
  const alarmSubscription = new Promise((resolve) => {
    subscribed = resolve;
  });
  const result = new Promise((resolve) => {
    for (const listener of message.listeners) listener('create', { id: ID }, resolve);
  });
  assert.equal(await result, true);
  assert.deepEqual(
    calls.filter((name) => name.startsWith('zacro.nativeServices.')),
    ['zacro.nativeServices.ready', 'zacro.nativeServices.checkpoint'],
  );
  assert.equal(JSON.parse(fs.readFileSync(f.filename)).alarms[0].name, 'worker-durable');
  assert.equal(workerChrome.alarms.onAlarm.listeners, undefined, 'worker must use managed facade event');
  // Await the worker snapshot after it installs the alarm listener, then deliver
  // through the authenticated owned service receiver and real bridge path.
  await alarmSubscription;
  const sender = f.controller.window.webContents;
  await f.handlers.get('zacro:native-extension-alarm:v1')(
    { sender, senderFrame: sender.mainFrame },
    { name: 'worker-durable', scheduledTime: Date.now() },
  );
  assert.deepEqual(managedEvents, ['worker-durable']);
  assert.equal(metadata.generation, 'living');
  f.controller.close();
  alarms.clear();
  const restarted = new f.services.NativeServices({
    session: f.session,
    id: ID,
    manifest,
    permissions: metadata.grants.permissions,
    filename: f.filename,
    persist: (file, state) => fs.writeFileSync(file, JSON.stringify(state)),
    guard() {},
  });
  t.after(() => restarted.close());
  await restarted.initialize();
  assert.equal(
    alarms.has('worker-durable'),
    true,
    'worker checkpoint restores on the next service lifecycle',
  );
});

for (const first of ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess'])
  test(`equivalent DNR authority preserves session/dynamic/static state when starting with ${first}`, async (t) => {
    const second =
      first === 'declarativeNetRequest' ? 'declarativeNetRequestWithHostAccess' : 'declarativeNetRequest';
    let sessionRules = [],
      dynamicRules = [],
      enabled = [];
    const dnr = {
      getSessionRules: async () => sessionRules,
      updateSessionRules: async ({ removeRuleIds = [], addRules = [] }) => {
        sessionRules = sessionRules.filter((rule) => !removeRuleIds.includes(rule.id)).concat(addRules);
      },
      getDynamicRules: async () => dynamicRules,
      updateDynamicRules: async ({ removeRuleIds = [], addRules = [] }) => {
        dynamicRules = dynamicRules.filter((rule) => !removeRuleIds.includes(rule.id)).concat(addRules);
      },
      getEnabledRulesets: async () => enabled,
      updateEnabledRulesets: async ({ disableRulesetIds = [], enableRulesetIds = [] }) => {
        enabled = [
          ...new Set(enabled.filter((id) => !disableRulesetIds.includes(id)).concat(enableRulesetIds)),
        ];
      },
      getDisabledRuleIds: async () => [],
      updateStaticRules: async () => {},
    };
    const manifest = {
      permissions: [first],
      optional_permissions: [second, 'alarms'],
      declarative_net_request: {
        rule_resources: [
          { id: 'default', enabled: true },
          { id: 'chosen', enabled: false },
        ],
      },
    };
    const f = boundary(
      t,
      {
        declarativeNetRequest: dnr,
        alarms: { create: async () => {}, getAll: async () => [], clearAll: async () => {} },
      },
      manifest,
      [first],
    );
    await f.controller.initialize();
    sessionRules = [{ id: 17 }];
    dynamicRules = [{ id: 23 }];
    enabled = ['chosen'];
    const assertLive = () => {
      assert.deepEqual(sessionRules, [{ id: 17 }]);
      assert.deepEqual(dynamicRules, [{ id: 23 }]);
      assert.deepEqual(enabled, ['chosen']);
    };
    await f.controller.reconfigure([first, second], async () => {});
    assertLive();
    await f.controller.reconfigure([first], async () => {});
    assertLive();
    // Adding the alternate spelling alongside a genuinely new service must
    // initialize only the new group, without resetting DNR in that branch.
    await f.controller.reconfigure([first, second, 'alarms'], async () => {});
    assertLive();
    await f.controller.reconfigure([second], async () => {});
    assertLive();
    assert.deepEqual([...f.controller.permissions], [second]);
    await f.controller.reconfigure([], async () => {});
    assert.deepEqual(sessionRules, []);
    assert.deepEqual(dynamicRules, []);
    assert.deepEqual(enabled, []);
    await f.controller.reconfigure([first], async () => {});
    assert.deepEqual(sessionRules, []);
    assert.deepEqual(dynamicRules, []);
    assert.deepEqual(enabled, ['default'], 'full regrant reapplies declared default static rules');
  });
