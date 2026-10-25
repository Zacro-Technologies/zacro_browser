'use strict';
const { app, BrowserWindow, session, webContents } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(__dirname, '../../..');
const directory = process.env.ZACRO_CONTEXT_ROOT;
app.setPath('userData', path.join(directory, 'userdata'));
app.on('window-all-closed', (event) => event.preventDefault());
app.whenReady().then(async () => {
  let manager, bridge;
  try {
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { NativeServices } = require(path.join(root, 'src/main/extensions/native-services.cjs'));
    const ses = session.fromPartition('persist:offscreen-startup');
    let readyRequested = false;
    bridge = new ExtensionBridge({
      resolveExtension: (profile, id) => manager.resolveExtension(profile, id),
      dispatch: () => true,
    });
    const handle = bridge.handle.bind(bridge);
    bridge.handle = (event, request) => {
      if (request.method === 'zacro.nativeServices.ready') readyRequested = true;
      return handle(event, request);
    };
    manager = new ExtensionManager({
      root: path.join(directory, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (native, profile) => bridge.attachSession(native, profile),
      confirmPermissions: async () => true,
      onDeactivated: async () => ({ requiresPageReload: false }),
    });
    await manager.restore('one');
    const source = path.join(directory, 'source');
    await fs.mkdir(source);
    await fs.writeFile(
      path.join(source, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Startup offscreen',
        version: '1',
        permissions: ['offscreen'],
        background: { service_worker: 'worker.js' },
      }),
    );
    await fs.writeFile(
      path.join(source, 'worker.js'),
      `const created=chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Startup DOM service'}).then(()=> 'created',error=>'error:'+error.message);chrome.runtime.onMessage.addListener((message,sender,reply)=>{if(message==='status'){created.then(async result=>reply({result,has:await chrome.offscreen.hasDocument()}));return true;}});`,
    );
    await fs.writeFile(
      path.join(source, 'offscreen.html'),
      '<!doctype html><title>Startup DOM service</title>',
    );
    await fs.writeFile(path.join(source, 'page.html'), '<!doctype html>');
    const view = async (url) => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await window.loadURL(url);
      return window;
    };
    const initialize = NativeServices.prototype.initialize;
    let before,
      heldBoundary = false;
    NativeServices.prototype.initialize = async function () {
      // Hold only the existing native initialization boundary. A native-only
      // observer bypasses facade reads, while the real worker either attempts
      // gated readiness or completes creation before initialization proceeds.
      for (let attempt = 0; ; attempt++) {
        try {
          await ses.serviceWorkers.startWorkerForScope(`chrome-extension://${this.id}/`);
          break;
        } catch (error) {
          if (attempt === 99) throw error;
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
      }
      const observer = await view(`chrome-extension://${this.id}/zacro-native-services.html`);
      for (let count = 0; count < 100; count++) {
        before = await observer.webContents.executeJavaScript('chrome.offscreen.hasDocument()');
        if (readyRequested || before) {
          heldBoundary = true;
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      observer.destroy();
      return initialize.call(this);
    };
    const installed = await manager.installLocal('one', source);
    NativeServices.prototype.initialize = initialize;
    const observer = await view(`chrome-extension://${installed.id}/page.html`);
    const after = await observer.webContents.executeJavaScript(`chrome.runtime.sendMessage('status')`);
    await manager.disable('one', installed.id);
    const disabledClosed = !webContents
      .getAllWebContents()
      .some(
        (contents) =>
          contents.session === ses &&
          contents.getURL() === `chrome-extension://${installed.id}/offscreen.html`,
      );
    globalThis.contextResult = {
      enabled: installed.enabled,
      heldBoundary,
      readyRequested,
      before,
      after,
      disabledClosed,
    };
  } catch (error) {
    globalThis.contextResult = { error: error.stack };
  } finally {
    await manager?.close();
    bridge?.close();
  }
});
