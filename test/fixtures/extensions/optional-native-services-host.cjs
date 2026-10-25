'use strict';
// Positive path requires the actual custom ABI; this fixture never installs hooks.
const { app, BrowserWindow, session } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const directory = process.env.ZACRO_OPTIONAL_ROOT;
const phase = process.env.ZACRO_OPTIONAL_PHASE;
const root = path.resolve(__dirname, '../../..');
app.setPath('userData', path.join(directory, 'user'));
app.on('window-all-closed', (event) => event.preventDefault());
app.whenReady().then(async () => {
  const sentinel = new BrowserWindow({ show: false });
  await sentinel.loadURL('about:blank');
  try {
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const { negotiateEngineCapabilities } = require(
      path.join(root, 'src/main/extensions/engine-capabilities.cjs'),
    );
    const ses = session.fromPartition('persist:optional-services');
    if (!negotiateEngineCapabilities(ses).reviewedPermissions) {
      globalThis.optionalResult = { available: false };
      return;
    }
    let manager, api;
    const alarms = [];
    const bridge = new ExtensionBridge({
      resolveExtension: (p, id) => manager.resolveExtension(p, id),
      dispatch: (context, method, args) =>
        method === 'fixture.alarm' ? alarms.push(args[0]) : api.call(context, method, args),
    });
    manager = new ExtensionManager({
      root: path.join(directory, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (s, p) => bridge.attachSession(s, p),
      confirmPermissions: async () => true,
      onDeactivated: async () => ({ requiresPageReload: false }),
    });
    api = new ExtensionAPI({
      resolveExtension: (p, id) => manager.resolveExtension(p, id),
      dialogs: { requestPermissions: async () => true },
      tabs: { get: async (_p, id) => ({ id, url: 'https://fixture.test/' }) },
      changePermissionDelta: (p, id, details, remove, guard) => {
        guard();
        return manager.changePermissionDelta(p, id, details, remove);
      },
      emit: (...args) => bridge.emit(...args),
    });
    await manager.restore('p');
    let record = manager.list('p')[0];
    if (!record) {
      const source = path.join(directory, 'source');
      await fs.mkdir(source, { recursive: true });
      await fs.writeFile(
        path.join(source, 'manifest.json'),
        JSON.stringify({
          manifest_version: 3,
          name: 'Optional native services',
          version: '1',
          permissions: ['storage'],
          optional_permissions: ['alarms', 'offscreen', 'declarativeNetRequest'],
          background: { service_worker: 'worker.js' },
        }),
      );
      await fs.writeFile(path.join(source, 'page.html'), '<!doctype html>Optional caller');
      await fs.writeFile(path.join(source, 'offscreen.html'), '<!doctype html>Offscreen');
      await fs.writeFile(
        path.join(source, 'worker.js'),
        `
        function listen(){if(chrome.alarms)chrome.alarms.onAlarm.addListener(alarm=>zacroExtension.invoke('fixture.alarm',[alarm.name]));}
        listen();chrome.permissions.onAdded.addListener(listen);
        chrome.storage.onChanged.addListener(()=>{});
      `,
      );
      record = await manager.installLocal('p', source);
    }
    if (!record.enabled) throw new Error('Optional fixture failed to load: ' + record.error);
    const caller = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true },
    });
    await caller.loadURL(`chrome-extension://${record.id}/page.html`);
    const run = (code) => caller.webContents.executeJavaScript(code);
    const generation = record.generation;
    await run('globalThis.originalCaller="alive"');
    const permissions = ['alarms', 'offscreen', 'declarativeNetRequest'];
    const grant = async () => {
      await api.activateAction('p', record.id, caller.webContents.id);
      return run(`chrome.permissions.request({permissions:${JSON.stringify(permissions)}})`);
    };
    if (phase === 'register') {
      if (!(await grant())) throw new Error('Optional permission grant denied');
      await run(`chrome.alarms.create('durable',{when:Date.now()+3600000});`);
      await run(
        `chrome.declarativeNetRequest.updateDynamicRules({addRules:[{id:17,action:{type:'block'},condition:{urlFilter:'optional-block',resourceTypes:['xmlhttprequest']}}]})`,
      );
      await run(
        `chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Fixture optional service lifecycle'})`,
      );
      const offscreen = await run('chrome.offscreen.hasDocument()');
      // Real worker suspension followed by a native alarm forwarded by the owned receiver.
      caller.webContents.debugger.attach('1.3');
      await caller.webContents.debugger.sendCommand('ServiceWorker.enable');
      await caller.webContents.debugger.sendCommand('ServiceWorker.stopAllWorkers');
      const deadline = Date.now() + 5000;
      while (Object.keys(ses.serviceWorkers.getAllRunning()).length && Date.now() < deadline)
        await new Promise((resolve) => setTimeout(resolve, 20));
      const stopped = Object.keys(ses.serviceWorkers.getAllRunning()).length === 0;
      await run(`chrome.alarms.create('wake',{when:Date.now()+500})`);
      const alarmDeadline = Date.now() + 6000;
      while (!alarms.includes('wake') && Date.now() < alarmDeadline)
        await new Promise((resolve) => setTimeout(resolve, 20));
      caller.webContents.debugger.detach();
      globalThis.optionalResult = {
        available: true,
        offscreen,
        stopped,
        alarmDelivered: alarms.includes('wake'),
        originalCaller: (await run('originalCaller')) === 'alive',
        generationStable: manager.resolveExtension('p', record.id).generation === generation,
      };
    } else {
      const durable = await run(`chrome.alarms.get('durable')`);
      const rules = await run('chrome.declarativeNetRequest.getDynamicRules()');
      const offscreenAfterRestart = await run('chrome.offscreen.hasDocument()');
      const removed = await run(`chrome.permissions.remove({permissions:${JSON.stringify(permissions)}})`);
      const denied = await run(`Promise.resolve().then(()=>chrome.alarms.getAll()).then(()=>false,()=>true)`);
      if (!(await grant())) throw new Error('Optional regrant denied');
      const emptyAlarms = (await run('chrome.alarms.getAll()')).length === 0;
      const emptyRules = (await run('chrome.declarativeNetRequest.getDynamicRules()')).length === 0;
      const noOffscreen = !(await run('chrome.offscreen.hasDocument()'));
      globalThis.optionalResult = {
        available: true,
        durable: durable?.name === 'durable',
        durableRules: rules.some((rule) => rule.id === 17),
        offscreenAfterRestart,
        removed,
        denied,
        emptyAlarms,
        emptyRules,
        noOffscreen,
        originalCaller: (await run('originalCaller')) === 'alive',
        generationStable: manager.resolveExtension('p', record.id).generation === generation,
      };
    }
  } catch (error) {
    globalThis.optionalResult = { error: error.stack };
  }
});
