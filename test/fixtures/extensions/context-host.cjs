'use strict';
const { app, BrowserWindow, session, webContents } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const root = path.resolve(__dirname, '../../..');
const nativeDiagnostics = [];
app.on('web-contents-created', (_event, contents) => {
  contents.on('preload-error', (_event, preload, error) =>
    nativeDiagnostics.push({ type: 'preload-error', preload, error: error.message }),
  );
  contents.on('console-message', (_event, ...args) =>
    nativeDiagnostics.push({ type: 'console', url: contents.getURL(), args }),
  );
});
app.setPath('userData', path.join(process.env.ZACRO_CONTEXT_ROOT, 'userdata'));
app.whenReady().then(async () => {
  // Keep an inspectable native window even when the required implementation is absent.
  const sentinel = new BrowserWindow({ show: false });
  await sentinel.loadURL(
    'data:text/html,<meta http-equiv="Content-Security-Policy" content="default-src %27none%27">',
  );
  try {
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { adaptExtension } = require(path.join(root, 'src/main/extensions/adapt.cjs'));
    const kind = process.env.ZACRO_CONTEXT_KIND;
    const source = path.join(process.env.ZACRO_CONTEXT_ROOT, 'original');
    await fs.mkdir(path.join(source, 'scripts'), { recursive: true });
    const server = http.createServer((req, res) => {
      if (req.url === '/worker.js') {
        res.setHeader('Content-Type', 'application/javascript');
        res.end(
          "self.addEventListener('message', event => event.ports[0].postMessage(typeof zacroExtension + ':' + typeof zacroTransport + ':' + typeof require));",
        );
        return;
      }
      res.setHeader('Content-Type', 'text/html');
      res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; worker-src 'self'");
      res.end('<html><body>Ordinary page</body></html>');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const url = `http://127.0.0.1:${server.address().port}/`;
    const background = kind.startsWith('mv2')
      ? kind.startsWith('mv2-page')
        ? { page: 'background.html', persistent: true }
        : { scripts: ['scripts/background.js'], persistent: true }
      : { service_worker: 'scripts/background.js', ...(kind === 'module' ? { type: 'module' } : {}) };
    const manifest = {
      manifest_version: kind.startsWith('mv2') ? 2 : 3,
      name: `Context ${kind}`,
      version: '1.0',
      background,
      permissions: kind.startsWith('mv2') ? ['http://127.0.0.1/*'] : [],
      ...(!kind.startsWith('mv2') ? { host_permissions: ['http://127.0.0.1/*'] } : {}),
      content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'], run_at: 'document_start' }],
    };
    await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
    await fs.writeFile(
      path.join(source, 'background.html'),
      `<!doctype html><html><head><meta charset="utf-8">${kind === 'mv2-page-rawtext' ? '<style>.x::after {content: "<script>"}</style>' : kind === 'mv2-page-template' ? '<template><script>throw new Error("inert");</script></template>' : ''}<script src="scripts/background.js"></script></head></html>`,
    );
    await fs.writeFile(path.join(source, 'scripts/dependency.js'), 'globalThis.originalImport = true;');
    await fs.writeFile(
      path.join(source, 'scripts/background.js'),
      `${kind === 'classic' ? "'use strict';\n" : ''}${kind === 'module' ? "import './dependency.js';" : kind === 'classic' ? "importScripts('./dependency.js');" : 'globalThis.originalImport = true;'}\nglobalThis.backgroundCount = (globalThis.backgroundCount || 0) + 1;\nchrome.runtime.onMessage.addListener((message, sender, reply) => { reply(message === 'native-probe' ? 'native-reply' : 'catch-all-reply'); });\nchrome.runtime.onConnect.addListener(port => { port.onMessage.addListener(() => port.postMessage({ error: 'catch-all-port' })); });\nglobalThis.zacroExtension?.invoke('probe', ['background', globalThis.originalImport, globalThis.backgroundCount, (function () { return this; })() === undefined]).catch(console.error);`,
    );
    await fs.writeFile(
      path.join(source, 'content.js'),
      "globalThis.zacroExtension.invoke('probe', ['content']).catch(console.error); globalThis.zacroExtension.invoke('trusted', []).then(() => globalThis.zacroExtension.invoke('probe', ['trusted-broken']), () => globalThis.zacroExtension.invoke('probe', ['trusted-rejected'])); const forged = chrome.runtime.connect({name:'zacro.extension.transport.v1'}); forged.onMessage.addListener(message => { if (message.error) globalThis.zacroExtension.invoke('probe', ['forged-content-rejected']); forged.disconnect(); }); forged.postMessage({ id:1, method:'trusted', args:[], runtimeSender:{ id:chrome.runtime.id, url:chrome.runtime.getURL('background.html'), kind:'background-page' } });",
    );
    await fs.writeFile(path.join(source, 'page.html'), '<!doctype html><script src="page.js"></script>');
    await fs.writeFile(
      path.join(source, 'page.js'),
      "chrome.runtime.onConnect.addListener(port => { port.onMessage.addListener(() => port.postMessage({ error: 'page-catch-all' })); }); globalThis.framePromise = globalThis.zacroExtension?.invoke('probe', ['frame']); globalThis.nativeCheck = () => chrome.runtime.sendMessage('native-probe'); globalThis.nativePortCheck = () => new Promise(resolve => { const port = chrome.runtime.connect({ name: 'ordinary-app-port' }); port.onMessage.addListener(message => { resolve(message.error === 'catch-all-port'); port.disconnect(); }); port.postMessage('app-message'); });",
    );
    // Test-only trigger observes the old isolated world's closure after native
    // unload/reload. Production transport never uses DOM events or attributes.
    await fs.appendFile(
      path.join(source, 'content.js'),
      "\ndocument.addEventListener('zacro-test-old-context', () => { const label = document.documentElement.getAttribute('data-test-label'); zacroExtension.invoke('probe', [label]).then(() => document.documentElement.setAttribute('data-test-result', 'success'), () => document.documentElement.setAttribute('data-test-result', 'denied')); });",
    );
    const destination = path.join(process.env.ZACRO_CONTEXT_ROOT, 'derived');
    await adaptExtension(source, destination);
    const ses = session.fromPartition('persist:context-one');
    let enabled = true;
    let extension;
    const calls = {};
    let release;
    const bridge = new ExtensionBridge({
      resolveExtension: (profile, id) =>
        enabled && profile === 'profile-one' && id === extension?.id
          ? { enabled: true, manifest, grants: { origins: ['http://127.0.0.1/*'] } }
          : null,
      dispatch: (context, method, args) => {
        if (method === 'trusted') {
          if (context.kind === 'content-script') throw new Error('Trusted extension contexts only');
          return true;
        }
        if (method === 'deferred')
          return new Promise((resolve) => {
            release = resolve;
          });
        if (method !== 'probe') throw new Error('Method denied');
        calls[args[0]] = {
          profileId: context.profileId,
          extensionId: context.extensionId,
          kind: context.kind,
          nativeSender: Boolean(context.sender),
          originalImport: args[1],
          count: args[2],
          strict: args[3],
          transportKind: context.transportKind,
          originUrl: context.runtimeSender?.url,
          documentId: context.runtimeSender?.documentId,
          sourceContentsId: context.sourceContents?.id,
        };
        return calls[args[0]];
      },
    });
    bridge.attachSession(ses, 'profile-one');
    if (process.env.ZACRO_CONTEXT_LEGACY === '1')
      ses.setPreloads([path.join(root, 'src/main/extensions/frame-preload.cjs')]);
    // Native extension loading can start its background before its Promise resolves.
    ses.extensions.on('extension-loaded', (_event, loaded) => {
      extension = loaded;
    });
    extension = await ses.extensions.loadExtension(destination);
    const frame = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, nodeIntegration: false, contextIsolation: true },
    });
    const page = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, nodeIntegration: false, contextIsolation: true },
    });
    await frame.loadURL(`chrome-extension://${extension.id}/page.html`);
    await page.loadURL(url);
    const deadline = Date.now() + 8000;
    while (
      (!calls.frame ||
        !calls.background ||
        !calls.content ||
        !calls['trusted-rejected'] ||
        !calls['forged-content-rejected']) &&
      Date.now() < deadline
    )
      await new Promise((resolve) => setTimeout(resolve, 50));
    const diagnostics = [];
    for (const contents of webContents.getAllWebContents()) {
      if (contents.getType() === 'backgroundPage')
        diagnostics.push({
          url: contents.getURL(),
          preferences: contents.getLastWebPreferences(),
          preloads: ses.getPreloadScripts(),
          world: await contents.executeJavaScript(
            'JSON.stringify({ bridge: typeof zacroExtension, chrome: typeof chrome, protocol: location.protocol, require: typeof require, process: typeof process })',
          ),
          isolated: await contents.executeJavaScriptInIsolatedWorld(999, [
            { code: 'JSON.stringify({ require: typeof require, process: typeof process })' },
          ]),
        });
    }
    const nativeMessaging = await frame.webContents.executeJavaScript('nativeCheck()');
    const nativePortMessaging = await frame.webContents.executeJavaScript('nativePortCheck()');
    const pageBridge = await page.webContents.executeJavaScript(
      'typeof zacroExtension + ":" + typeof require + ":" + typeof zacro',
    );
    const triggerContent = async (label) => {
      await page.webContents.executeJavaScript(
        `document.documentElement.removeAttribute('data-test-result'); document.documentElement.setAttribute('data-test-label', ${JSON.stringify(label)}); document.dispatchEvent(new Event('zacro-test-old-context'));`,
      );
      const deadline = Date.now() + 1500;
      let result;
      while (Date.now() < deadline) {
        result = await page.webContents.executeJavaScript(
          "document.documentElement.getAttribute('data-test-result')",
        );
        if (result) return result;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      return result;
    };
    if ((await triggerContent('content-live')) !== 'success')
      throw new Error('Old-context fixture did not connect before revocation');
    const ordinaryWorker = await page.webContents.executeJavaScript(
      "new Promise(resolve => { const worker = new Worker('/worker.js'); const channel = new MessageChannel(); channel.port1.onmessage = event => { worker.terminate(); resolve(event.data); }; worker.postMessage({}, [channel.port2]); })",
    );
    const ordinaryServiceWorker = await page.webContents.executeJavaScript(
      "(async () => { const registration = await navigator.serviceWorker.register('/worker.js'); const worker = registration.installing || registration.waiting || registration.active; if (worker.state !== 'activated') await new Promise(resolve => worker.addEventListener('statechange', () => { if (worker.state === 'activated') resolve(); })); const result = await new Promise(resolve => { const channel = new MessageChannel(); channel.port1.onmessage = event => resolve(event.data); worker.postMessage({}, [channel.port2]); }); await registration.unregister(); return result; })()",
    );
    const forgedRejected = await frame.webContents.executeJavaScript(
      "zacroExtension.invoke('probe', [], { extensionId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }).then(() => false, () => true)",
    );
    const broker = webContents
      .getAllWebContents()
      .find(
        (contents) => contents.getURL() === `chrome-extension://${extension.id}/zacro-compat-transport.html`,
      );
    const brokerPreferences = broker?.getLastWebPreferences();
    const brokerGlobal = await broker.executeJavaScript('typeof zacroTransport');
    const backgroundDocProbe =
      kind.startsWith('mv2') && calls.background
        ? await broker.executeJavaScript(
            `chrome.tabs.sendMessage(${calls.background.sourceContentsId}, 'native-probe', { documentId: ${JSON.stringify(calls.background.documentId)} }).catch(error => error.message)`,
          )
        : null;
    const leakedViewCapability = await frame.webContents.executeJavaScript(
      "typeof chrome.extension?.getViews === 'function' && chrome.extension.getViews().some(view => typeof view.zacroTransport !== 'undefined')",
    );
    const duplicate = new BrowserWindow({
      show: false,
      webPreferences: {
        session: ses,
        preload: path.join(__dirname, 'hostile-preload.cjs'),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    await duplicate.loadURL(`chrome-extension://${extension.id}/zacro-compat-transport.html`);
    const duplicateBrokerRejected = await duplicate.webContents.executeJavaScript(
      "hostileProbe.bind({ id: chrome.runtime.id, url: chrome.runtime.getURL('_generated_background_page.html'), origin: 'chrome-extension://' + chrome.runtime.id, frameId: 0, documentId: 'forged' })",
    );
    const attacker = new BrowserWindow({
      show: false,
      webPreferences: {
        session: ses,
        preload: path.join(__dirname, 'hostile-preload.cjs'),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    await attacker.loadURL(url);
    const invalidOriginRejected = await attacker.webContents.executeJavaScript('hostileProbe.connect()');
    const foreignSession = session.fromPartition('persist:unattached');
    await foreignSession.extensions.loadExtension(destination);
    const foreign = new BrowserWindow({
      show: false,
      webPreferences: {
        session: foreignSession,
        preload: path.join(__dirname, 'hostile-preload.cjs'),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    await foreign.loadURL(`chrome-extension://${extension.id}/page.html`);
    const wrongSessionRejected = await foreign.webContents.executeJavaScript('hostileProbe.connect()');
    const late = frame.webContents.executeJavaScript(
      "zacroExtension.invoke('deferred', []).then(() => false, () => true)",
    );
    while (!release) await new Promise((resolve) => setTimeout(resolve, 10));
    enabled = false;
    release('stale-value');
    const lateRejected = await late;
    const disabledRejected = await frame.webContents.executeJavaScript(
      "zacroExtension.invoke('probe', ['disabled']).then(() => false, () => true)",
    );
    enabled = true;
    const disabledReuseRejected = await frame.webContents.executeJavaScript(
      "zacroExtension.invoke('probe', ['reused']).then(() => false, () => true)",
    );
    ses.extensions.removeExtension(extension.id);
    const unloadedRejected = await frame.webContents
      .executeJavaScript("zacroExtension.invoke('probe', ['unloaded']).then(() => false, () => true)")
      .catch(() => true);
    extension = await ses.extensions.loadExtension(destination);
    const staleContentResult = await triggerContent('old-content');
    const staleContentRejected = staleContentResult !== 'success' && !calls['old-content'];
    globalThis.contextResult = {
      calls,
      diagnostics,
      nativeDiagnostics,
      versions: process.versions,
      profileId: 'profile-one',
      extensionId: extension.id,
      pageBridge,
      ordinaryWorker,
      ordinaryServiceWorker,
      nativeMessaging,
      nativePortMessaging,
      forgedRejected,
      disabledRejected,
      disabledReuseRejected,
      unloadedRejected,
      staleContentRejected,
      lateRejected,
      invalidOriginRejected,
      wrongSessionRejected,
      originalImport: calls.background?.originalImport,
      brokerPreferences,
      brokerGlobal,
      backgroundDocProbe,
      leakedViewCapability,
      duplicateBrokerRejected,
      contentTrustedRejected: Boolean(calls['trusted-rejected']) && !calls['trusted-broken'],
      forgedContentRejected: Boolean(calls['forged-content-rejected']),
      backgroundCount: calls.background?.count,
    };
    bridge.close();
  } catch (error) {
    globalThis.contextResult = { error: error.stack, nativeDiagnostics };
  }
});
