'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
const root = path.resolve(__dirname, '../..');
const { inspectManifest } = require('../../src/main/extensions/catalog.cjs');
const { adaptExtension } = require('../../src/main/extensions/adapt.cjs');
const manifest = {
  manifest_version: 3,
  name: 'Native DevTools fixture',
  version: '1',
  devtools_page: 'tools/devtools.html',
};

test('catalog accepts local DevTools documents while retaining unrelated unsupported boundaries', () => {
  assert.equal(inspectManifest(manifest).compatible, true);
  for (const field of ['chrome_url_overrides', 'sandbox'])
    assert.equal(inspectManifest({ ...manifest, [field]: {} }).compatible, false, field);
});

test('DevTools resources reject foreign URLs, traversal and absent documents before adaptation', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-devtools-resources-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  for (const devtools_page of [
    '',
    true,
    [],
    'https://foreign.test/tools.html',
    'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/tools.html',
    '../tools.html',
    'tools/../../tools.html',
    '/tools.html',
    'tools\\devtools.html',
    'tools/%2e%2e/devtools.html',
    'tools/devtools.html?query',
    'tools/devtools.html#fragment',
  ]) {
    assert.throws(() => inspectManifest({ ...manifest, devtools_page }), /Invalid devtools_page/);
  }
  const source = path.join(directory, 'source');
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
  await assert.rejects(
    adaptExtension(source, path.join(directory, 'missing')),
    /Invalid devtools_page resource/,
  );
  await fs.mkdir(path.join(source, 'tools/devtools.html'), { recursive: true });
  await assert.rejects(
    adaptExtension(source, path.join(directory, 'directory')),
    /Invalid devtools_page resource/,
  );
  await fs.rm(path.join(source, 'tools'), { recursive: true });
  await fs.mkdir(path.join(directory, 'outside'));
  await fs.writeFile(path.join(directory, 'outside/devtools.html'), '<!doctype html>');
  await fs.symlink(path.join(directory, 'outside'), path.join(source, 'tools'));
  await assert.rejects(
    adaptExtension(source, path.join(directory, 'escaped')),
    /Invalid devtools_page resource/,
  );
  assert.equal(
    await fs.access(path.join(directory, 'missing')).then(
      () => true,
      () => false,
    ),
    false,
  );
});

// The generated Electron entry keeps all fixture behavior in this focused test.
function nativeFixture() {
  const { app, BrowserWindow, session } = require('electron');
  const fs = require('node:fs/promises');
  const path = require('node:path');
  const http = require('node:http');
  const root = process.env.ZACRO_DEVTOOLS_ROOT;
  const directory = process.env.ZACRO_DEVTOOLS_DIRECTORY;
  const diagnostics = [];
  app.on('web-contents-created', (_event, contents) =>
    contents.on('console-message', (_event, ...details) => diagnostics.push(details)),
  );
  app.setPath('userData', path.join(directory, 'userdata'));
  app.whenReady().then(async () => {
    const sentinel = new BrowserWindow({ show: false });
    await sentinel.loadURL('about:blank');
    try {
      const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
      const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
      const source = path.join(directory, 'source');
      await fs.mkdir(path.join(source, 'tools'), { recursive: true });
      const manifest = {
        manifest_version: 3,
        name: 'Native DevTools fixture',
        version: '1',
        devtools_page: 'tools/devtools.html',
        host_permissions: ['http://127.0.0.1/*'],
      };
      await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
      await fs.writeFile(
        path.join(source, 'tools/devtools.html'),
        '<!doctype html><script src="devtools.js"></script>',
      );
      await fs.writeFile(
        path.join(source, 'tools/devtools.js'),
        `globalThis.nativeDevtools = chrome.devtools; chrome.devtools.panels.create('Zacro native fixture', '', 'tools/panel.html', panel => { globalThis.createdPanel = panel; });`,
      );
      await fs.writeFile(
        path.join(source, 'tools/panel.html'),
        '<!doctype html><title>Native panel</title><output id="result">waiting</output><script src="panel.js"></script>',
      );
      await fs.writeFile(
        path.join(source, 'tools/panel.js'),
        `globalThis.nativeDevtools = chrome.devtools; chrome.devtools.inspectedWindow.eval('document.documentElement.dataset.inspectedMarker', (value, error) => { document.querySelector('#result').textContent = JSON.stringify({value, error}); }); globalThis.bridgeProbe = () => zacroExtension.invoke('probe', []); globalThis.nativeProbe = () => new Promise(resolve => { const timer = setTimeout(() => resolve(false), 800); try { chrome.devtools.inspectedWindow.eval('document.documentElement.dataset.inspectedMarker', (value, error) => { clearTimeout(timer); resolve(!error && value === 'native-http-marker'); }); } catch { clearTimeout(timer); resolve(false); } });`,
      );
      const sessions = {
        one: session.fromPartition('persist:devtools-one'),
        two: session.fromPartition('persist:devtools-two'),
        private: session.fromPartition('devtools-private'),
      };
      const profiles = { one: { id: 'one' }, two: { id: 'two' }, private: { id: 'private', private: true } };
      let manager;
      let bridgeCalls = 0;
      const bridge = new ExtensionBridge({
        resolveExtension: (profile, id) => manager.resolveExtension(profile, id),
        dispatch: () => ++bridgeCalls,
      });
      manager = new ExtensionManager({
        root: path.join(directory, 'managed'),
        getProfile: (id) => profiles[id],
        getSession: (id) => sessions[id],
        prepareSession: (ses, profile) => bridge.attachSession(ses, profile),
        confirmPermissions: async () => true,
      });
      await manager.restore('one');
      await manager.restore('two');
      let rejectedDevtoolsResources = 0;
      for (const devtools_page of ['../outside.html', 'https://foreign.test/tools.html', 'absent.html']) {
        const invalid = path.join(directory, 'invalid-' + rejectedDevtoolsResources);
        await fs.mkdir(invalid);
        await fs.writeFile(
          path.join(invalid, 'manifest.json'),
          JSON.stringify({ ...manifest, devtools_page }),
        );
        try {
          await manager.installLocal('one', invalid);
        } catch (error) {
          if (!/Invalid devtools_page/.test(error.message)) throw error;
          rejectedDevtoolsResources++;
        }
      }
      const installed = await manager.installLocal('one', source);
      if (!installed.enabled)
        throw new Error('Managed DevTools extension did not enable: ' + installed.status);
      const id = installed.id;
      const server = http.createServer((_request, response) => {
        response.setHeader('Content-Type', 'text/html');
        response.setHeader('Content-Security-Policy', "default-src 'none'");
        response.end(
          '<!doctype html><html data-inspected-marker="native-http-marker"><title>Inspected HTTP page</title><input id="unsaved"></html>',
        );
      });
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      app.on('will-quit', () => server.close());
      const inspected = new BrowserWindow({
        show: false,
        webPreferences: {
          session: sessions.one,
          sandbox: true,
          contextIsolation: true,
          nodeIntegration: false,
        },
      });
      await inspected.loadURL('http://127.0.0.1:' + server.address().port + '/');
      inspected.webContents.openDevTools({ mode: 'detach', activate: false });
      const allFrames = (frame) => [frame, ...frame.frames.flatMap(allFrames)];
      const panelFrame = () =>
        inspected.webContents.devToolsWebContents &&
        allFrames(inspected.webContents.devToolsWebContents.mainFrame).find(
          (frame) => frame.url === 'chrome-extension://' + id + '/tools/panel.html',
        );
      const wait = async (check) => {
        const deadline = Date.now() + 12000;
        while (Date.now() < deadline) {
          const value = await check();
          if (value) return value;
          await new Promise((resolve) => setTimeout(resolve, 40));
        }
        throw new Error('Native DevTools fixture deadline exceeded');
      };
      const openPanel = async () => {
        const devtoolsFrame = await wait(
          () =>
            inspected.webContents.devToolsWebContents &&
            allFrames(inspected.webContents.devToolsWebContents.mainFrame).find((frame) =>
              frame.url.endsWith('/tools/devtools.html'),
            ),
        );
        await wait(() => devtoolsFrame.executeJavaScript('typeof createdPanel !== "undefined"'));
        await inspected.webContents.devToolsWebContents.executeJavaScript(
          `(async () => { const UI = await import('./ui/legacy/legacy.js'); const inspector = UI.InspectorView.InspectorView.instance(); const panelId = inspector.tabbedPane.tabIds().find(id => id.startsWith('chrome-extension://')); if (!panelId) throw new Error('Native extension panel was not registered'); await inspector.showPanel(panelId); })()`,
        );
        let panel;
        try {
          panel = await wait(panelFrame);
        } catch (error) {
          error.message += JSON.stringify({
            diagnostics,
            frames: allFrames(inspected.webContents.devToolsWebContents.mainFrame).map((frame) => frame.url),
          });
          throw error;
        }
        return panel;
      };
      const panel = await openPanel();
      const panelResult = await wait(async () => {
        const value = await panel.executeJavaScript('document.querySelector("#result").textContent');
        return value !== 'waiting' && JSON.parse(value);
      });
      const panelGlobals = await panel.executeJavaScript(
        '({node:typeof require, process:typeof process, native:chrome.devtools === nativeDevtools, id:chrome.runtime.id})',
      );
      const bridgeLive = await panel.executeJavaScript('bridgeProbe()');
      const pageGlobals = await inspected.webContents.executeJavaScript(
        'typeof zacroExtension + ":" + typeof zacroTransport + ":" + typeof require',
      );
      const derivedManifest = JSON.parse(
        await fs.readFile(path.join(manager.versionPath('one', installed.current), 'manifest.json'), 'utf8'),
      );
      let privateRejected = false;
      try {
        await manager.installLocal('private', source);
      } catch (error) {
        privateRejected = /private/.test(error.message);
      }
      await inspected.webContents.executeJavaScript(
        'document.querySelector("#unsaved").value = "unsaved input"',
      );
      const inspectedId = inspected.webContents.id;
      const foreign = new BrowserWindow({
        show: false,
        webPreferences: {
          session: sessions.two,
          sandbox: true,
          contextIsolation: true,
          nodeIntegration: false,
        },
      });
      await foreign.loadURL(inspected.webContents.getURL());
      foreign.webContents.openDevTools({ mode: 'detach', activate: false });
      await wait(() => foreign.webContents.isDevToolsOpened());
      const unloaded = [];
      sessions.one.extensions.on('extension-unloaded', (_event, extension) => unloaded.push(extension.id));
      await manager.disable('one', id);
      const disabledBridgeRejected = await panel
        .executeJavaScript('bridgeProbe().then(() => false, () => true)')
        .catch(() => true);
      const disabledInspectionDenied = await panel
        .executeJavaScript('nativeProbe().then(value => !value)')
        .catch(() => true);
      const disabledNativeAbsent = !sessions.one.extensions.getExtension(id);
      const callsAfterDisable = bridgeCalls;
      const ownerDevtoolsClosed = !inspected.webContents.isDevToolsOpened();
      const foreignDevtoolsKept = foreign.webContents.isDevToolsOpened();
      const inspectedDocumentKept =
        !inspected.isDestroyed() &&
        inspected.webContents.id === inspectedId &&
        (await inspected.webContents.executeJavaScript('document.querySelector("#unsaved").value')) ===
          'unsaved input';
      await manager.enable('one', id);
      const obsoleteBridgeRejected = await panel
        .executeJavaScript('bridgeProbe().then(() => false, () => true)')
        .catch(() => true);
      const obsoleteInspectionDenied = await panel
        .executeJavaScript('nativeProbe().then(value => !value)')
        .catch(() => true);
      const obsoleteCallsAbsent = bridgeCalls === callsAfterDisable;
      inspected.webContents.openDevTools({ mode: 'detach', activate: false });
      const newPanel = await openPanel();
      await wait(() => newPanel.executeJavaScript('typeof nativeProbe === "function"'));
      const renewedInspection = await newPanel.executeJavaScript('nativeProbe()');
      const renewedBridge = await newPanel.executeJavaScript('bridgeProbe()');
      const callsBeforeRemove = bridgeCalls;
      await manager.remove('one', id);
      const removedBridgeRejected = await newPanel
        .executeJavaScript('bridgeProbe().then(() => false, () => true)')
        .catch(() => true);
      const removedInspectionDenied = await newPanel
        .executeJavaScript('nativeProbe().then(value => !value)')
        .catch(() => true);
      globalThis.devtoolsResult = {
        panelResult,
        panelGlobals,
        ownerDevtoolsClosed,
        foreignDevtoolsKept,
        inspectedDocumentKept,
        bridgeLive,
        renewedInspection,
        renewedBridge,
        removedInspectionDenied,
        rejectedDevtoolsResources,
        pageGlobals,
        derivedDevtoolsPage: derivedManifest.devtools_page,
        originalManifest: JSON.parse(await fs.readFile(path.join(source, 'manifest.json'), 'utf8')),
        profileTwoExtensions: sessions.two.extensions.getAllExtensions().length,
        privateExtensions: sessions.private.extensions.getAllExtensions().length,
        privateRejected,
        disabledNativeAbsent,
        disabledInspectionDenied,
        obsoleteInspectionDenied,
        disabledBridgeRejected,
        obsoleteBridgeRejected,
        removedBridgeRejected,
        removedNativeAbsent: !sessions.one.extensions.getExtension(id),
        removedRecordAbsent: manager.list('one').length === 0,
        unloadCount: unloaded.length,
        staleCallsAbsent: obsoleteCallsAbsent && bridgeCalls === callsBeforeRemove,
        preferences: inspected.webContents.getLastWebPreferences(),
        electron: process.versions.electron,
      };
      await manager.close();
      bridge.close();
    } catch (error) {
      globalThis.devtoolsResult = { error: error.stack };
    }
  });
  app.on('window-all-closed', (event) => event.preventDefault());
}

test(
  'managed native DevTools panel inspects HTTP and loses access on disable/remove without crossing profiles',
  { timeout: 60000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-devtools-'));
    const fixture = path.join(directory, 'host.cjs');
    await fs.writeFile(fixture, '(' + nativeFixture.toString() + ')();');
    const env = { ...process.env, ZACRO_DEVTOOLS_ROOT: root, ZACRO_DEVTOOLS_DIRECTORY: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ args: [fixture], env });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect.poll(() => app.evaluate(() => globalThis.devtoolsResult), { timeout: 45000 }).toBeTruthy();
    const result = await app.evaluate(() => globalThis.devtoolsResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    assert.deepEqual(result.panelResult, { value: 'native-http-marker' });
    assert.equal(result.panelGlobals.native, true);
    assert.equal(result.panelGlobals.node, 'undefined');
    assert.equal(result.panelGlobals.process, 'undefined');
    assert.match(result.panelGlobals.id, /^[a-p]{32}$/);
    assert.equal(result.bridgeLive, 1);
    assert.equal(result.renewedBridge, 2);
    assert.equal(result.rejectedDevtoolsResources, 3);
    assert.equal(result.pageGlobals, 'undefined:undefined:undefined');
    assert.equal(result.derivedDevtoolsPage, 'tools/devtools.html');
    assert.equal(result.originalManifest.devtools_page, 'tools/devtools.html');
    assert.equal(result.originalManifest.key, undefined);
    assert.equal(result.profileTwoExtensions, 0);
    assert.equal(result.privateExtensions, 0);
    for (const key of [
      'ownerDevtoolsClosed',
      'renewedInspection',
      'removedInspectionDenied',
      'foreignDevtoolsKept',
      'inspectedDocumentKept',
      'privateRejected',
      'disabledNativeAbsent',
      'disabledInspectionDenied',
      'obsoleteInspectionDenied',
      'disabledBridgeRejected',
      'obsoleteBridgeRejected',
      'removedBridgeRejected',
      'removedNativeAbsent',
      'removedRecordAbsent',
      'staleCallsAbsent',
    ])
      assert.equal(result[key], true, key);
    assert.equal(result.unloadCount, 2);
    assert.equal(result.preferences.sandbox, true);
    assert.equal(result.preferences.contextIsolation, true);
    assert.equal(result.preferences.nodeIntegration, false);
  },
);
