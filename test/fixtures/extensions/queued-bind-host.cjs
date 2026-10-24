'use strict';
const { app, BrowserWindow, session, webContents } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const root = path.resolve(__dirname, '../../..');
app.setPath('userData', path.join(process.env.ZACRO_CONTEXT_ROOT, 'userdata'));
app.whenReady().then(async () => {
  try {
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { adaptExtension } = require(path.join(root, 'src/main/extensions/adapt.cjs'));
    const source = path.join(process.env.ZACRO_CONTEXT_ROOT, 'source');
    await fs.mkdir(source);
    await fs.writeFile(
      path.join(source, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Queued bind',
        version: '1',
        host_permissions: ['http://127.0.0.1/*'],
        content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'] }],
      }),
    );
    await fs.writeFile(
      path.join(source, 'content.js'),
      "chrome.runtime.onMessage.addListener((_message, _sender, reply) => reply('native-doc-live')); if (!sessionStorage.connected) { sessionStorage.connected = 'yes'; const port = chrome.runtime.connect({ name: 'zacro.extension.transport.v1' }); port.postMessage({ id: 1, method: 'probe', args: [] }); }",
    );
    const derived = path.join(process.env.ZACRO_CONTEXT_ROOT, 'derived');
    await adaptExtension(source, derived);
    const server = http.createServer((_req, res) => {
      res.setHeader('Content-Security-Policy', "default-src 'none'");
      res.end('<!doctype html><title>Same URL</title>');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`;
    const calls = [];
    const bridge = new ExtensionBridge({
      resolveExtension: () => ({ enabled: true, grants: { origins: ['http://127.0.0.1/*'] } }),
      dispatch: (context) => {
        calls.push({ kind: context.kind, documentId: context.runtimeSender?.documentId });
        return true;
      },
    });
    let release, seen;
    const received = new Promise((resolve) => {
      seen = resolve;
    });
    let finished;
    const released = new Promise((resolve) => {
      finished = resolve;
    });
    // Control only native IPC scheduling; preserve Chromium's real Port sender.
    const originalHandle = bridge.handle.bind(bridge);
    let nativeSender;
    bridge.handle = async (event, request) => {
      if (request.operation === 'bind') nativeSender = request.runtimeSender;
      if (request.operation === (process.env.ZACRO_QUEUE_STAGE || 'bind') && !release)
        await new Promise((resolve) => {
          release = resolve;
          seen(nativeSender);
        });
      const result = await originalHandle(event, request);
      if (request.operation === 'release') finished();
      return result;
    };
    const ses = session.fromPartition('persist:queued');
    bridge.attachSession(ses, 'profile-one');
    const extension = await ses.extensions.loadExtension(derived);
    const page = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await page.loadURL(url);
    const oldSender = await received;
    const oldFrame = page.webContents.mainFrame;
    await page.loadURL(url);
    release();
    let timer;
    await Promise.race([
      released,
      new Promise((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('Queued native bind did not finish releasing')), 3000);
      }),
    ]).finally(() => clearTimeout(timer));
    const broker = webContents
      .getAllWebContents()
      .find((item) => item.getURL() === extension.url + 'zacro-compat-transport.html');
    const capabilities = await broker.executeJavaScript(
      '(async () => ({ getContexts: typeof chrome.runtime.getContexts, contexts: chrome.runtime.getContexts ? await chrome.runtime.getContexts({}) : [], sendMessage: typeof chrome.tabs?.sendMessage, webNavigation: typeof chrome.webNavigation }))()',
    );
    capabilities.currentDocument = await broker.executeJavaScript(
      `chrome.tabs.sendMessage(${oldSender.tabId}, {}, { frameId: 0 }).catch(error => error.message)`,
    );
    capabilities.oldDocument = await broker.executeJavaScript(
      `chrome.tabs.sendMessage(${oldSender.tabId}, {}, { documentId: ${JSON.stringify(oldSender.documentId)} }).catch(error => error.message)`,
    );
    globalThis.contextResult = {
      calls,
      oldSender,
      frameSame: oldFrame === page.webContents.mainFrame,
      oldDetached: oldFrame.detached,
      capabilities,
    };
    bridge.close();
  } catch (error) {
    globalThis.contextResult = { error: error.stack };
  }
});
