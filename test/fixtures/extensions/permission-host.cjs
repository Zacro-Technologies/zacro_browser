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
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const server = http.createServer((req, res) => {
      res.setHeader('Content-Type', req.url === '/data' ? 'application/json' : 'text/html');
      res.end(req.url === '/data' ? '42' : '<input id="draft" value="unsaved">');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`,
      source = path.join(process.env.ZACRO_CONTEXT_ROOT, 'source');
    await fs.mkdir(source);
    const manifest = {
      manifest_version: 3,
      name: 'Optional rights',
      version: '1',
      permissions: ['storage', 'scripting'],
      optional_host_permissions: ['http://127.0.0.1/*'],
    };
    await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
    await fs.writeFile(
      path.join(source, 'page.html'),
      '<!doctype html><html><body>Permissions</body></html>',
    );
    let manager;
    const ses = session.fromPartition('persist:permissions');
    const bridge = new ExtensionBridge({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      dispatch: (context, method, args) => api.call(context, method, args),
    });
    const api = new ExtensionAPI({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      tabs: {
        get: async (p, id) => (id === tab.webContents.id ? { id, url: tab.webContents.getURL() } : null),
      },
    });
    let reloadPending = false;
    manager = new ExtensionManager({
      root: path.join(process.env.ZACRO_CONTEXT_ROOT, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (session, p) => bridge.attachSession(session, p),
      confirmPermissions: async () => true,
      onDeactivated: async () => ({ requiresPageReload: reloadPending }),
    });
    await manager.restore('p1');
    let record = await manager.installLocal('p1', source);
    const tab = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await tab.loadURL(url);
    let view;
    const open = async () => {
      if (view && !view.isDestroyed()) view.destroy();
      view = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await view.loadURL(`chrome-extension://${record.id}/page.html`);
    };
    await open();
    const probe = () =>
      view.webContents.executeJavaScript(
        `(async()=>{let injected,network;try{injected=await chrome.scripting.executeScript({target:{tabId:${tab.webContents.id}},func:()=>document.querySelector('#draft').value});}catch(error){injected={error:error.message}}try{network=await(await fetch(${JSON.stringify(url + 'data')})).json()}catch(error){network={error:error.message}}return {injected,network};})()`,
      );
    const before = await probe();
    record = await manager.changePermissions('p1', record.id, {
      permissions: ['storage', 'scripting'],
      origins: ['http://127.0.0.1/*'],
    });
    await open();
    const granted = await probe();
    await view.webContents.executeJavaScript(
      `chrome.scripting.executeScript({target:{tabId:${tab.webContents.id}},func:()=>{document.querySelector('#draft').value='draft remains';globalThis.injectedMarker=true;}})`,
    );
    reloadPending = true;
    record = await manager.changePermissions('p1', record.id, {
      permissions: ['storage', 'scripting'],
      origins: [],
    });
    let enableDenied = false;
    try {
      await manager.enable('p1', record.id);
    } catch {
      enableDenied = true;
    }
    const pending = {
      enabled: record.enabled,
      status: record.status,
      enableDenied,
      draft: await tab.webContents.executeJavaScript(`document.querySelector('#draft').value`),
      nativeLoaded: !!ses.extensions.getExtension(record.id),
    };
    await tab.loadURL(url);
    reloadPending = false;
    record = await manager.enable('p1', record.id);
    await open();
    const removed = await probe();
    globalThis.contextResult = {
      before,
      granted,
      pending,
      removed,
      effective: manager.resolveExtension('p1', record.id).manifest,
    };
  } catch (error) {
    globalThis.contextResult = { error: error.stack };
  }
});
