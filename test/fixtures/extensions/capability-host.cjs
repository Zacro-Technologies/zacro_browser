'use strict';
const { app, BrowserWindow, session, webContents } = require('electron');
const fs = require('node:fs/promises'),
  path = require('node:path'),
  http = require('node:http');
const root = path.resolve(__dirname, '../../..');
app.setPath('userData', path.join(process.env.ZACRO_CONTEXT_ROOT, 'user'));
app.whenReady().then(async () => {
  const keep = new BrowserWindow({ show: false });
  await keep.loadURL('about:blank');
  try {
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { adaptExtension } = require(path.join(root, 'src/main/extensions/adapt.cjs'));
    const server = http.createServer((_req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end('<!doctype html><title>Capability page</title>');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`;
    if (process.env.ZACRO_CAPABILITY === 'activeTab') {
      const directory = path.join(process.env.ZACRO_CONTEXT_ROOT, 'source');
      await fs.mkdir(directory);
      const manifest = {
        manifest_version: 3,
        name: 'Native activeTab capability probe',
        version: '1',
        permissions: ['activeTab', 'scripting'],
        action: {},
      };
      await fs.writeFile(path.join(directory, 'manifest.json'), JSON.stringify(manifest));
      await fs.writeFile(path.join(directory, 'page.html'), '<!doctype html><title>Probe</title>');
      const ses = session.fromPartition('persist:capability');
      const ext = await ses.extensions.loadExtension(directory);
      const target = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await target.loadURL(url);
      const view = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await view.loadURL(ext.url + 'page.html');
      const metadata = {
        enabled: true,
        generation: 'probe',
        manifest,
        grants: { permissions: manifest.permissions, origins: [] },
      };
      const api = new ExtensionAPI({
        resolveExtension: () => metadata,
        tabs: { get: async (_profile, id) => (id === target.webContents.id ? { id, url } : null) },
      });
      await api.activateAction('probe', ext.id, target.webContents.id);
      const result = await view.webContents.executeJavaScript(
        `chrome.scripting.executeScript({target:{tabId:${target.webContents.id}},func:()=>location.href}).then(result=>({result}),error=>({error:error.message}))`,
        true,
      );
      globalThis.contextResult = {
        nativeOnly: true,
        userGesture: true,
        adapterAllowed:
          (await api.call(api.context('probe', ext.id), 'tabs.get', [target.webContents.id])).url === url,
        result,
      };
      return;
    }
    if (process.env.ZACRO_CAPABILITY === 'brokerFailure') {
      const source = path.join(process.env.ZACRO_CONTEXT_ROOT, 'source');
      await fs.mkdir(source);
      const manifest = {
        manifest_version: 3,
        name: 'Failed broker',
        version: '1',
        host_permissions: ['http://127.0.0.1/*'],
        content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'] }],
      };
      await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
      await fs.writeFile(
        path.join(source, 'content.js'),
        `zacroExtension.invoke('probe',[]).then(()=>document.documentElement.setAttribute('data-error','unexpected'),error=>document.documentElement.setAttribute('data-error',error.message));`,
      );
      const derived = path.join(process.env.ZACRO_CONTEXT_ROOT, 'derived');
      await adaptExtension(source, derived);
      await fs.unlink(path.join(derived, 'zacro-compat-transport.html'));
      const ses = session.fromPartition('persist:failed-broker');
      let calls = 0;
      const bridge = new ExtensionBridge({
        resolveExtension: () => ({
          enabled: true,
          generation: 'failure',
          manifest,
          grants: { permissions: [], origins: ['http://127.0.0.1/*'] },
        }),
        dispatch: () => {
          calls++;
        },
      });
      bridge.attachSession(ses, 'failure');
      const extension = await ses.extensions.loadExtension(derived);
      const page = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await page.loadURL(url);
      let error;
      for (let i = 0; i < 250; i++) {
        error = await page.webContents.executeJavaScript(
          `document.documentElement.getAttribute('data-error')`,
        );
        if (error) break;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      globalThis.contextResult = {
        errorMessage: error,
        calls,
        brokerCount: [...bridge.sessions.values()][0].brokers.size,
        pageCapability: await page.webContents.executeJavaScript(`typeof zacroExtension`),
      };
      bridge.close();
      return;
    }
    const runs = [],
      adapterEvents = [],
      diagnostics = [];
    let bridge;
    for (const adapted of [false, true]) {
      const source = path.join(process.env.ZACRO_CONTEXT_ROOT, adapted ? 'adapted-source' : 'raw-source');
      await fs.mkdir(source);
      const manifest = {
        manifest_version: 2,
        name: adapted ? 'Adapted lazy' : 'Raw lazy',
        version: '1',
        permissions: ['storage', 'http://127.0.0.1/*'],
        background: { scripts: ['background.js'], persistent: false },
        content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'] }],
      };
      await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
      await fs.writeFile(
        path.join(source, 'background.js'),
        `localStorage.starts=String(Number(localStorage.starts||0)+1);chrome.runtime.onMessage.addListener((message,sender,reply)=>{reply({starts:Number(localStorage.starts),suspend:typeof chrome.runtime.onSuspend});});${adapted ? "chrome.commands.onCommand.addListener(name=>zacroExtension.invoke('adapter.event',[name,Number(localStorage.starts)]));zacroExtension.invoke('probe',[]).catch(console.error);" : ''}`,
      );
      await fs.writeFile(
        path.join(source, 'content.js'),
        `const wake=()=>chrome.runtime.sendMessage('wake').then(result=>document.documentElement.setAttribute('data-reply',JSON.stringify(result))).catch(error=>document.documentElement.setAttribute('data-reply',JSON.stringify({error:error.message})));document.addEventListener('test-wake',wake);wake();`,
      );
      const ses = session.fromPartition(adapted ? 'persist:adapted-lazy' : 'persist:raw-lazy');
      let extension;
      if (adapted) {
        bridge = new ExtensionBridge({
          onError: (error, context) => diagnostics.push({ error: error.message, ...context }),
          resolveExtension: () => ({
            enabled: true,
            generation: 'lazy',
            manifest,
            grants: { permissions: ['storage'], origins: ['http://127.0.0.1/*'] },
          }),
          dispatch: (context, method, args) => {
            if (method === 'adapter.event') adapterEvents.push(args);
            return true;
          },
        });
        if (process.env.ZACRO_CAPABILITY === 'idleRace') {
          const handle = bridge.handle.bind(bridge);
          let retired = false;
          bridge.handle = async (event, request) => {
            const value = await handle(event, request);
            if (request.method === 'zacro.events.idle' && !retired) {
              retired = true;
              bridge.emit('lazy', extension.id, 'commands.onCommand', ['idle-race']);
              await new Promise((resolve) => setTimeout(resolve, 20));
            }
            return value;
          };
        }
        bridge.attachSession(ses, 'lazy');
      }
      const directory = adapted ? path.join(process.env.ZACRO_CONTEXT_ROOT, 'derived') : source;
      if (adapted) await adaptExtension(source, directory);
      extension = await ses.extensions.loadExtension(directory);
      const page = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await page.loadURL(url);
      let first;
      for (let i = 0; i < 100; i++) {
        first = await page.webContents.executeJavaScript(
          `document.documentElement.getAttribute('data-reply')`,
        );
        if (first) break;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      runs.push({ adapted, ses, extension, page, first: first ? JSON.parse(first) : null });
    }
    const idleMilliseconds = process.env.ZACRO_CAPABILITY === 'idleRace' ? 1000 : 35000;
    await new Promise((resolve) => setTimeout(resolve, idleMilliseconds));
    const results = [];
    for (const run of runs) {
      const backgrounds = webContents
        .getAllWebContents()
        .filter((w) => w.getType() === 'backgroundPage' && w.session === run.ses);
      if (run.adapted && process.env.ZACRO_CAPABILITY !== 'idleRace') {
        diagnostics.push({
          before: [...bridge.sessions.values()][0].backgrounds.get(run.extension.id)?.events
            ? [...[...bridge.sessions.values()][0].backgrounds.get(run.extension.id).events]
            : null,
        });
        bridge.emit('lazy', run.extension.id, 'commands.onCommand', ['adapter-wake']);
        const deadline = Date.now() + 5000;
        while (!adapterEvents.length && Date.now() < deadline)
          await new Promise((resolve) => setTimeout(resolve, 20));
      }
      await run.page.webContents.executeJavaScript(
        `document.documentElement.removeAttribute('data-reply');document.dispatchEvent(new Event('test-wake'));`,
      );
      let wake;
      for (let i = 0; i < 100; i++) {
        wake = await run.page.webContents.executeJavaScript(
          `document.documentElement.getAttribute('data-reply')`,
        );
        if (wake) break;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      if (run.adapted)
        diagnostics.push({
          after: [...bridge.sessions.values()][0].backgrounds.get(run.extension.id)?.queue.length,
          origins: [...bridge.origins.values()].map((x) => ({
            kind: x.kind,
            subscriptions: [...(x.subscriptions || [])],
          })),
        });
      results.push({
        adapted: run.adapted,
        first: run.first,
        backgroundsAfterIdle: backgrounds.length,
        wake: wake ? JSON.parse(wake) : null,
      });
    }
    globalThis.contextResult = { idleMilliseconds, results, adapterEvents, diagnostics };
  } catch (error) {
    globalThis.contextResult = { error: error.stack };
  }
});
