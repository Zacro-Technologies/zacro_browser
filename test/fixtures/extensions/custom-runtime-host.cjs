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
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const ses = session.fromPartition('persist:custom-runtime');
    const { negotiateEngineCapabilities } = require(
      path.join(root, 'src/main/extensions/engine-capabilities.cjs'),
    );
    const capabilities = negotiateEngineCapabilities(ses);
    const source = path.join(process.env.ZACRO_CONTEXT_ROOT, 'source');
    await fs.mkdir(source);
    const manifest = {
      manifest_version: 3,
      name: 'Custom runtime acceptance',
      version: '1',
      permissions: ['activeTab', 'scripting', 'storage', 'userScripts'],
      optional_host_permissions: ['http://localhost/*'],
      action: {},
    };
    await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
    await fs.writeFile(path.join(source, 'page.html'), '<!doctype html><title>Living caller</title>');
    let manager, api;
    const bridge = new ExtensionBridge({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      dispatch: (context, method, args) => api.call(context, method, args),
    });
    manager = new ExtensionManager({
      root: path.join(process.env.ZACRO_CONTEXT_ROOT, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (session, p) => bridge.attachSession(session, p),
      confirmPermissions: async () => true,
      onDeactivated: async () => ({ requiresPageReload: false }),
    });
    await manager.restore('p');
    let record = await manager.installLocal('p', source);
    if (!capabilities.reviewedPermissions) {
      globalThis.contextResult = {
        capabilities,
        stockDenied: record.enabled === false && record.status === 'incompatible',
        nativeLoaded: !!ses.extensions.getExtension(record.id),
      };
      return;
    }
    const server = http.createServer((req, res) => {
      res.setHeader('Content-Type', req.url === '/data' ? 'text/plain' : 'text/html');
      res.end(req.url === '/data' ? '42' : '<!doctype html><input id="draft" value="unsaved">');
    });
    await new Promise((resolve) => server.listen(0, resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`,
      otherURL = `http://localhost:${server.address().port}/`;
    const window = () =>
      new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
    const target = window(),
      other = window();
    await target.loadURL(url);
    await other.loadURL(url);
    const generation = record.generation;
    const tabs = {
      get: async (_p, id) => {
        const win = [target, other].find((w) => w.webContents.id === id);
        return win ? { id, url: win.webContents.getURL() } : null;
      },
    };
    api = new ExtensionAPI({
      resolveExtension: (p, id) => manager.resolveExtension(p, id),
      tabs,
      grantActiveTab: async (context, tabId) => {
        api.guard(context);
        await ses.extensions.grantZacroActiveTab(context.extensionId, tabId);
        api.guard(context);
      },
      dialogs: { requestPermissions: async () => true },
      changePermissions: (p, id, grants, guard) => {
        guard();
        return manager.changePermissions(p, id, grants);
      },
      emit: (...args) => bridge.emit(...args),
    });
    let view = window();
    await view.loadURL(`chrome-extension://${record.id}/page.html`);
    const probe = (win) =>
      view.webContents.executeJavaScript(
        `chrome.scripting.executeScript({target:{tabId:${win.webContents.id}},func:()=>document.querySelector('#draft').value}).then(result=>({result}),error=>({error:error.message}))`,
      );
    await view.webContents.executeJavaScript(
      `globalThis.originalCallerToken='living';chrome.permissions.getAll()`,
    );
    const before = await probe(target);
    await api.activateAction('p', record.id, target.webContents.id);
    const active = await probe(target),
      sameOriginOther = await probe(other);
    await target.loadURL(otherURL);
    const afterNavigation = await probe(target);
    await target.webContents.executeJavaScript(`document.querySelector('#draft').value='draft remains'`);
    // A genuine host command/action issues this gesture. Extension JS never calls
    // grantZacroActiveTab or manipulates the authenticated host state.
    await api.activateAction('p', record.id, other.webContents.id);
    const permissionRequest = await view.webContents.executeJavaScript(
      `chrome.permissions.request({origins:['http://localhost/*']})`,
    );
    const grantedNetwork = await view.webContents.executeJavaScript(
      `fetch(${JSON.stringify(otherURL + 'data')}).then(r=>r.text())`,
    );
    let userScriptsDisabled = false;
    try {
      await view.webContents.executeJavaScript(
        `chrome.userScripts.register([{id:'denied',matches:['http://localhost/*'],js:[{code:'void 0'}]}])`,
      );
    } catch {
      userScriptsDisabled = true;
    }
    await manager.setUserScriptsEnabled('p', record.id, true);
    await view.webContents.executeJavaScript(
      `chrome.userScripts.register([{id:'world-a',worldId:'a',matches:['http://localhost/*'],runAt:'document_end',js:[{code:"globalThis.privateMarker='first';document.documentElement.setAttribute('data-world-a',privateMarker);document.documentElement.setAttribute('data-node',typeof require+'/'+typeof process);document.documentElement.setAttribute('data-credentials',typeof globalThis.chrome?.storage+'/'+typeof globalThis.zacroExtension);"}]},{id:'world-b',worldId:'b',matches:['http://localhost/*'],runAt:'document_end',js:[{code:"document.documentElement.setAttribute('data-world-b',typeof globalThis.privateMarker);"}]}])`,
    );
    const readWorlds = async () => {
      for (let i = 0; i < 100; i++) {
        const value = await target.webContents.executeJavaScript(
          `({a:document.documentElement.getAttribute('data-world-a'),b:document.documentElement.getAttribute('data-world-b'),node:document.documentElement.getAttribute('data-node'),credentials:document.documentElement.getAttribute('data-credentials')})`,
        );
        if (value.a && value.b) return value;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      throw new Error('Native user script worlds did not execute');
    };
    await new Promise((resolve) => {
      target.webContents.once('did-finish-load', resolve);
      target.reload();
    });
    const worlds = await readWorlds();
    await target.webContents.executeJavaScript(`document.querySelector('#draft').value='draft remains'`);
    const permissionRemoval = await view.webContents.executeJavaScript(
      `chrome.permissions.remove({origins:['http://localhost/*']})`,
    );
    const removedNetwork = await view.webContents.executeJavaScript(
      `fetch(${JSON.stringify(otherURL + 'data')}).then(()=>true,()=>false)`,
    );
    const originalCaller = await view.webContents.executeJavaScript(`originalCallerToken==='living'`);
    const generationStable = manager.resolveExtension('p', record.id).generation === generation;
    const draft = await target.webContents.executeJavaScript(`document.querySelector('#draft').value`);
    // Restore permission then restart all native extension state. The consent and
    // native registered scripts must survive, independently of adapter metadata.
    await manager.changePermissions('p', record.id, {
      permissions: manifest.permissions,
      origins: ['http://localhost/*'],
    });
    await manager.invalidateProfile('p');
    await manager.restore('p');
    record = manager.list('p')[0];
    await target.loadURL(otherURL);
    const restartWorlds = await readWorlds();
    const consentAfterRestart = record.userScriptsEnabled === true;
    await manager.setUserScriptsEnabled('p', record.id, false);
    await target.loadURL(otherURL);
    const afterUserScriptsOff = await target.webContents.executeJavaScript(
      `document.documentElement.getAttribute('data-world-a')`,
    );
    if (!view.isDestroyed()) view.destroy();
    view = window();
    await view.loadURL(`chrome-extension://${record.id}/page.html`);
    await manager.disable('p', record.id);
    let afterDisable;
    try {
      afterDisable = await probe(target);
    } catch (error) {
      afterDisable = { error: error.message };
    }
    globalThis.contextResult = {
      capabilities,
      before,
      active,
      sameOriginOther,
      afterNavigation,
      permissionRequest,
      permissionRemoval,
      originalCaller,
      generationStable,
      grantedNetwork,
      removedNetwork,
      draft,
      userScriptsDisabled,
      worlds,
      restartWorlds,
      consentAfterRestart,
      afterUserScriptsOff,
      afterDisable,
    };
  } catch (error) {
    globalThis.contextResult = { error: error.stack };
  }
});
