'use strict';
const { app, BrowserWindow, session } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const directory = process.env.ZACRO_FONT_ROOT;
const root = path.resolve(__dirname, '../../..');
app.setPath('userData', path.join(directory, 'user'));
app.on('window-all-closed', (event) => event.preventDefault());
app.whenReady().then(async () => {
  const windows = [];
  const view = async (ses, url) => {
    const window = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    windows.push(window);
    await window.loadURL(url);
    return window;
  };
  await view(session.defaultSession, 'about:blank');
  try {
    const { negotiateEngineCapabilities } = require(
      path.join(root, 'src/main/extensions/engine-capabilities.cjs'),
    );
    const { FontSettingsController } = require(path.join(root, 'src/main/extensions/font-settings.cjs'));
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const sessions = {
      one: session.fromPartition('persist:font-one'),
      two: session.fromPartition('persist:font-two'),
    };
    let manager, api, fonts;
    const backgroundEvents = [];
    const bridge = new ExtensionBridge({
      resolveExtension: (p, id) => manager.resolveExtension(p, id),
      dispatch: (context, method, args) =>
        method === 'fixture.backgroundEvent'
          ? backgroundEvents.push(args[0])
          : api.call(context, method, args),
    });
    const { SyncStorage } = require(path.join(root, 'src/main/sync/storage.cjs'));
    const store = new SyncStorage({
      directory: path.join(directory, 'sync'),
      onChanged: (id, changes) => bridge.emit('one', id, 'storage.onChanged', [changes, 'sync']),
    });
    manager = new ExtensionManager({
      root: path.join(directory, 'managed'),
      getProfile: (id) => ({ id, private: id === 'private' }),
      getSession: (id) => sessions[id],
      prepareSession: (ses, p) => bridge.attachSession(ses, p),
      confirmPermissions: async () => true,
      onNativeLoaded: (p) => fonts.reconcile(p),
      onDeactivated: async ({ profileId }) => {
        await fonts.reconcile(profileId);
        return { requiresPageReload: false };
      },
    });
    fonts = new FontSettingsController({
      ready: (context) => manager.whenReady(context.profileId, context.extensionId),
      getProfile: (id) => ({ id, private: id === 'private' }),
      getSession: (id) => sessions[id],
      profilePath: (p) => manager.profilePath(p),
      listExtensions: (p) => manager.list(p),
      resolveExtension: (p, id) => manager.resolveExtension(p, id),
      emit: (p, id, event, args) =>
        bridge.emit(p, id, event, args, {
          filter: (c) =>
            c.kind !== 'content-script' && c.metadata.grants.permissions.includes('fontSettings'),
        }),
    });
    api = new ExtensionAPI({
      resolveExtension: (p, id) => manager.resolveExtension(p, id),
      fontSettings: fonts,
    });
    await manager.restore('one');
    await manager.restore('two');
    const source = path.join(directory, 'extension');
    await fs.mkdir(source);
    await fs.writeFile(
      path.join(source, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Native fonts fixture',
        version: '1',
        permissions: ['fontSettings', 'storage'],
        background: { service_worker: 'worker.js' },
        options_ui: { page: 'page.html' },
      }),
    );
    await fs.writeFile(
      path.join(source, 'worker.js'),
      `
      for(const event of ['onFontChanged','onDefaultFontSizeChanged','onDefaultFixedFontSizeChanged','onMinimumFontSizeChanged']) chrome.fontSettings[event].addListener(()=>zacroExtension.invoke('fixture.backgroundEvent',[event]));
      chrome.storage.sync.onChanged.addListener(()=>zacroExtension.invoke('fixture.backgroundEvent',['storage']));
    `,
    );
    await fs.writeFile(path.join(source, 'page.html'), '<!doctype html><script src="page.js"></script>');
    await fs.writeFile(
      path.join(source, 'page.js'),
      'globalThis.fontEvents=[];chrome.fontSettings.onFontChanged.addListener(e=>fontEvents.push(e));',
    );
    if (!negotiateEngineCapabilities(sessions.one).fontSettings) {
      let denied = false;
      try {
        const blocked = await manager.installLocal('one', source);
        denied = blocked.enabled === false && blocked.status === 'incompatible';
      } catch (error) {
        denied = /unsupported|incompatible/i.test(error.message);
      }
      globalThis.fontSettingsResult = { available: false, denied };
      return;
    }
    const server = http.createServer((_req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end(
        '<!doctype html><span id="generic" style="font-family:serif">Wim012345</span><span id="explicit" style="font-size:17px">Wim012345</span><span id="fixed" style="font-family:monospace">fixed</span><span id="tiny" style="font-size:1px">tiny</span>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`;
    const target = await view(sessions.one, url),
      foreign = await view(sessions.two, url);
    const measure = (window, family = 'serif') =>
      window.webContents.executeJavaScript(
        `(()=>{const c=document.createElement('canvas').getContext('2d');c.font=${JSON.stringify('32px ' + family)};return c.measureText('Wim012345 ABC abc 中文').width;})()`,
      );
    const original = await measure(target),
      foreignOriginal = await measure(foreign);
    const tinyBefore = await target.webContents.executeJavaScript(
      'document.querySelector("#tiny").getBoundingClientRect().width',
    );
    const record = await manager.installLocal('one', source);
    if (!record.enabled) throw new Error('Custom native font extension did not activate: ' + record.error);
    const extension = await view(sessions.one, `chrome-extension://${record.id}/page.html`);
    const call = (name, details) =>
      extension.webContents.executeJavaScript(
        `chrome.fontSettings.${name}(${details === undefined ? '' : JSON.stringify(details)})`,
      );
    const list = await call('getFontList');
    let selected, selectedWidth;
    for (const font of list.slice(0, 1024)) {
      const width = await measure(target, JSON.stringify(font.fontId));
      if (Math.abs(width - original) > 1) {
        selected = font.fontId;
        selectedWidth = width;
        break;
      }
    }
    if (!selected)
      throw new Error('Native OS font list has no usable distinct-metric font for rendering acceptance');
    const explicitFamily = JSON.stringify(selected);
    await target.webContents.executeJavaScript(
      `document.querySelector('#explicit').style.fontFamily=${JSON.stringify(explicitFamily)}`,
    );
    const explicitBefore = await target.webContents.executeJavaScript(
      'document.querySelector("#explicit").getBoundingClientRect().width',
    );
    await call('setFont', { genericFamily: 'serif', fontId: selected });
    const changed = await measure(target);
    await call('setDefaultFontSize', { pixelSize: 31 });
    await call('setDefaultFixedFontSize', { pixelSize: 27 });
    await call('setMinimumFontSize', { pixelSize: 12 });
    const created = await view(sessions.one, url);
    const sizes = await target.webContents.executeJavaScript(
      `({defaultSize:parseFloat(getComputedStyle(document.querySelector('#generic')).fontSize),fixedSize:parseFloat(getComputedStyle(document.querySelector('#fixed')).fontSize)})`,
    );
    const min = await call('getMinimumFontSize');
    const explicitAfter = await target.webContents.executeJavaScript(
      'document.querySelector("#explicit").getBoundingClientRect().width',
    );
    const eventReceived = await extension.webContents.executeJavaScript(
      'fontEvents.some(e=>e.levelOfControl==="controlled_by_this_extension")',
    );
    const result = {
      available: true,
      fontListNative:
        list.length > 0 &&
        list.every((f) => typeof f.fontId === 'string' && typeof f.displayName === 'string'),
      genericMatchesSelected: Math.abs(changed - selectedWidth) < 0.05,
      genericChanged: Math.abs(changed - original) > 1,
      newDocumentMatches: Math.abs((await measure(created)) - selectedWidth) < 0.05,
      explicitUnaffected: Math.abs(explicitBefore - explicitAfter) < 0.05,
      ...sizes,
      minimumSize: min.pixelSize,
      minimumRenderingChanged:
        (await target.webContents.executeJavaScript(
          'document.querySelector("#tiny").getBoundingClientRect().width',
        )) >
        tinyBefore + 1,
      foreignUnchanged: Math.abs((await measure(foreign)) - foreignOriginal) < 0.05,
      eventReceived,
    };
    const waitFor = async (predicate) => {
      const deadline = Date.now() + 5000;
      while (!predicate() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
      return predicate();
    };
    await waitFor(() => backgroundEvents.length >= 4);
    result.mixedFontEvents = [
      'onFontChanged',
      'onDefaultFontSizeChanged',
      'onDefaultFixedFontSizeChanged',
      'onMinimumFontSizeChanged',
    ].every((name) => backgroundEvents.includes(name));
    extension.webContents.debugger.attach('1.3');
    await extension.webContents.debugger.sendCommand('ServiceWorker.enable');
    await extension.webContents.debugger.sendCommand('ServiceWorker.stopAllWorkers');
    result.backgroundStopped = await waitFor(
      () => Object.keys(sessions.one.serviceWorkers.getAllRunning()).length === 0,
    );
    backgroundEvents.length = 0;
    await call('setDefaultFontSize', { pixelSize: 32 });
    store.call(record.id, 'set', [{ mixedWake: true }], { trusted: true });
    result.backgroundWakeDelivered = await waitFor(
      () => backgroundEvents.includes('onDefaultFontSizeChanged') && backgroundEvents.includes('storage'),
    );
    extension.webContents.debugger.detach();
    await call('clearFont', { genericFamily: 'serif' });
    await call('clearDefaultFontSize');
    await call('clearDefaultFixedFontSize');
    await call('clearMinimumFontSize');
    result.restored = Math.abs((await measure(target)) - original) < 0.05;
    await call('setFont', { genericFamily: 'serif', fontId: selected });
    await manager.disable('one', record.id);
    result.disabledRestored = Math.abs((await measure(target)) - original) < 0.05;
    let permissionDenied = false;
    try {
      await fonts.call(
        { profileId: 'one', extensionId: record.id, generation: record.generation, kind: 'extension-page' },
        'setDefaultFontSize',
        [{ pixelSize: 45 }],
      );
    } catch {
      permissionDenied = true;
    }
    result.permissionDenied = permissionDenied;
    globalThis.fontSettingsResult = result;
  } catch (error) {
    globalThis.fontSettingsResult = { error: error.stack };
  }
});
