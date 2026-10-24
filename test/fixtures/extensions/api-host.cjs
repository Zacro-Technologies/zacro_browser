'use strict';
const { app, BrowserWindow, session } = require('electron');
const fs = require('node:fs/promises'),
  path = require('node:path'),
  http = require('node:http');
const root = path.resolve(__dirname, '../../..');
app.setPath('userData', path.join(process.env.ZACRO_CONTEXT_ROOT, 'user'));
app.whenReady().then(async () => {
  const keep = new BrowserWindow({ show: false });
  await keep.loadURL('about:blank');
  try {
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { SyncStorage } = require(path.join(root, 'src/main/sync/storage.cjs'));
    const kind = process.env.ZACRO_CONTEXT_KIND,
      source = path.join(process.env.ZACRO_CONTEXT_ROOT, 'original');
    await fs.mkdir(source);
    const server = http.createServer((req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end('<html><body><input id="draft" value="unsaved"></body></html>');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`;
    const probe = `async function probe(label) { try { const key='value-'+label; await chrome.storage.sync.set({[key]:42}); const got=await chrome.storage.sync.get(key); const callback=await new Promise(resolve=>chrome.storage.sync.get(key,resolve)); let invalid=false;try{await chrome.storage.sync.set({bad:undefined})}catch{invalid=true} let error;await new Promise(resolve=>chrome.storage.sync.set({big:'x'.repeat(9000)},()=>{error=chrome.runtime.lastError?.message;resolve()}));await zacroExtension.invoke('test.report',[label,{got:got[key],callback:callback[key],invalid,error}]); } catch(error) { await zacroExtension.invoke('test.report',[label,{error:error.message}]); }}\n`;
    const manifest = {
      manifest_version: kind === 'mv2' ? 2 : 3,
      name: 'API fixture',
      version: '1',
      permissions: [
        'storage',
        'tabs',
        ...(kind === 'mv2' ? [] : ['scripting']),
        'contextMenus',
        ...(kind === 'mv2' ? ['http://127.0.0.1/*'] : []),
      ],
      ...(kind === 'mv2' ? {} : { host_permissions: ['http://127.0.0.1/*'] }),
      background:
        kind === 'mv2'
          ? { scripts: ['background.js'], persistent: true }
          : { service_worker: 'background.js', ...(kind === 'module' ? { type: 'module' } : {}) },
      action: { default_popup: 'page.html' },
      options_ui: { page: 'page.html' },
      content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'] }],
    };
    await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
    await fs.writeFile(
      path.join(source, 'background.js'),
      probe +
        "chrome.commands.onCommand.addListener(name=>zacroExtension.invoke('test.event',['command',name]));chrome.storage.sync.onChanged.addListener(changes=>{if(changes.wakeKey)zacroExtension.invoke('test.event',['sync',changes.wakeKey.newValue]);});probe('background');chrome.runtime.onMessage.addListener((message,sender,reply)=>{if(message==='native')reply('native-reply')});",
    );
    await fs.writeFile(
      path.join(source, 'content.js'),
      probe +
        "probe('content');globalThis.changes=[];chrome.storage.onChanged.addListener((changes,area)=>globalThis.changes.push(area));",
    );
    await fs.writeFile(
      path.join(source, 'page.html'),
      '<!doctype html><html><head><script src="page.js"></script></head></html>',
    );
    await fs.writeFile(
      path.join(source, 'registered.js'),
      'chrome.storage.sync.set({registeredExecuted:true});',
    );
    await fs.writeFile(
      path.join(source, 'page.js'),
      probe +
        "probe('page');globalThis.changes=[];chrome.storage.onChanged.addListener((changes,area)=>globalThis.changes.push(area));",
    );
    const ses = session.fromPartition('persist:api');
    let manager;
    const reports = {},
      events = [];
    let api;
    const bridge = new ExtensionBridge({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      dispatch: (context, method, args) =>
        method === 'test.report'
          ? (reports[args[0]] = args[1])
          : method === 'test.event'
            ? events.push(args)
            : api.call(context, method, args),
    });
    const store = new SyncStorage({
      directory: path.join(process.env.ZACRO_CONTEXT_ROOT, 'sync'),
      onChanged: (namespace, changes) =>
        bridge.emit('p1', namespace, 'storage.onChanged', [changes, 'sync'], {
          filter: (context) =>
            context.kind !== 'content-script' ||
            store.read().areas[namespace].accessLevel !== 'TRUSTED_CONTEXTS',
        }),
    });
    const page = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await page.loadURL(url);
    api = new ExtensionAPI({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      tabs: {
        get: async (p, id) =>
          id === page.webContents.id
            ? { id, windowId: 1, url: page.webContents.getURL(), title: 'Page', active: true }
            : null,
        query: async () => [
          { id: page.webContents.id, windowId: 1, url: page.webContents.getURL(), active: true },
        ],
      },
      storage: {
        call: (context, method, args) =>
          store.call(context.extensionId, method, args, { trusted: context.kind !== 'content-script' }),
      },
      emit: (...args) => bridge.emit(...args),
    });
    manager = new ExtensionManager({
      root: path.join(process.env.ZACRO_CONTEXT_ROOT, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (session, p) => bridge.attachSession(session, p),
      confirmPermissions: async () => true,
      onDeactivated: async () => ({ requiresPageReload: true }),
    });
    await manager.restore('p1');
    let record = await manager.installLocal('p1', source);
    const frame = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await frame.loadURL(`chrome-extension://${record.id}/page.html`);
    await page.reload();
    const deadline = Date.now() + 10000;
    while ((!reports.page || !reports.background || !reports.content) && Date.now() < deadline)
      await new Promise((resolve) => setTimeout(resolve, 50));
    const tabs = await frame.webContents
      .executeJavaScript('chrome.tabs.query({})')
      .catch((error) => ({ error: error.message }));
    globalThis.apiFixture = { frame, page, manager, bridge, record, api, store, reports, events };
    globalThis.contextResult = { reports, tabs, pageId: page.webContents.id };
  } catch (error) {
    globalThis.contextResult = { error: error.stack };
  }
});
