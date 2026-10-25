'use strict';
const { app, BrowserWindow, session } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../../..');
const directory = process.env.ZACRO_NATIVE_MESSAGING_ROOT;
app.setPath('userData', path.join(directory, 'user'));
app.whenReady().then(async () => {
  const keep = new BrowserWindow({ show: false });
  await keep.loadURL('about:blank');
  try {
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const { ExtensionAPI } = require(path.join(root, 'src/main/extensions/api.cjs'));
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { NativeMessagingBroker, createHostResolver } = require(
      path.join(root, 'src/main/extensions/native-messaging.cjs'),
    );
    const source = path.join(directory, 'source');
    await fs.mkdir(source);
    await fs.writeFile(
      path.join(source, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Reviewed synthetic native host client',
        version: '1',
        permissions: ['nativeMessaging'],
      }),
    );
    await fs.writeFile(
      path.join(source, 'page.html'),
      '<!doctype html><title>Synthetic native client</title>',
    );
    const ses = session.fromPartition('persist:native-messaging');
    let manager, api, broker;
    const children = [];
    let approvals = 0;
    const bridge = new ExtensionBridge({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      dispatch: (context, method, args) => api.call(context, method, args),
      onContextRevoked: (context) => broker?.revoke(context),
    });
    const manifestPath = path.join(directory, 'com.zacro.test.json');
    const deniedPath = path.join(directory, 'com.zacro.denied.json');
    broker = new NativeMessagingBroker({
      resolveHost: createHostResolver({
        discoverPaths: (name) => [name === 'com.zacro.denied' ? deniedPath : manifestPath],
      }),
      approveHost: async (review) => {
        approvals++;
        return review.name !== 'com.zacro.denied';
      },
      emit: (context, event) => bridge.emitNative(context, event),
      spawnHost: (...args) => {
        const child = spawn(...args);
        children.push(child);
        return child;
      },
    });
    api = new ExtensionAPI({
      resolveExtension: (p, id) => manager?.resolveExtension(p, id),
      nativeMessaging: broker,
    });
    manager = new ExtensionManager({
      root: path.join(directory, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (session, p) => bridge.attachSession(session, p),
      confirmPermissions: async () => true,
      onDeactivated: async () => ({ requiresPageReload: false }),
    });
    await manager.restore('p1');
    const record = await manager.installLocal('p1', source);
    const executable = path.join(directory, 'synthetic-host');
    await fs.copyFile(path.join(root, 'test/fixtures/native-messaging/host.cjs'), executable);
    await fs.chmod(executable, 0o700);
    const manifest = {
      name: 'com.zacro.test',
      description: 'Synthetic test native host',
      type: 'stdio',
      path: executable,
      allowed_origins: [`chrome-extension://${record.id}/`],
    };
    await fs.writeFile(manifestPath, JSON.stringify(manifest));
    await fs.writeFile(deniedPath, JSON.stringify({ ...manifest, name: 'com.zacro.denied' }));
    const view = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await view.loadURL(`chrome-extension://${record.id}/page.html`);
    const result = await view.webContents.executeJavaScript(`(async()=>{
   const port=globalThis.nativeTestPort=chrome.runtime.connectNative('com.zacro.test');
   const portSynchronous=typeof port?.postMessage==='function'&&typeof port?.then==='undefined';
   globalThis.disableDisconnected=false;port.onDisconnect.addListener(()=>{globalThis.disableDisconnected=!!chrome.runtime.lastError;});
   const messages=[];const received=new Promise(resolve=>port.onMessage.addListener(message=>{messages.push(message);if(messages.length===2)resolve();}));
   port.postMessage({mode:'multiple'});await received;
   const promiseResponse=await chrome.runtime.sendNativeMessage('com.zacro.test',{mode:'fragmented',text:'日本語'});
   const callbackResponse=await new Promise(resolve=>chrome.runtime.sendNativeMessage('com.zacro.test',{callback:true},resolve));
   let callbackError;await new Promise(resolve=>chrome.runtime.sendNativeMessage('com.zacro.denied',{},()=>{callbackError=chrome.runtime.lastError?.message;resolve();}));
   let localDisconnectEvents=0;const local=chrome.runtime.connectNative('com.zacro.test');local.onDisconnect.addListener(()=>localDisconnectEvents++);local.disconnect();local.disconnect();
   await new Promise(resolve=>setTimeout(resolve,100));let postClosed=false;try{local.postMessage({})}catch{postClosed=true;}
   return {localDisconnectEvents,postClosed,portSynchronous,messages,promiseResponse,callbackResponse,callbackError,callbackLastErrorCleared:!chrome.runtime.lastError,sandbox:typeof process+':'+typeof require};
  })()`);
    const other = new BrowserWindow({
      show: false,
      webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await other.loadURL(`chrome-extension://${record.id}/page.html`);
    const port = [...broker.ports.values()].find((value) => !value.first);
    const otherDocumentDenied = await other.webContents.executeJavaScript(
      `zacroExtension.invoke('runtime.postNativeMessage',[${JSON.stringify(port.portId)},{}]).then(()=>false,()=>true)`,
    );
    await manager.disable('p1', record.id);
    await new Promise((resolve) => setTimeout(resolve, 700));
    const disableDisconnected = await view.webContents.executeJavaScript('globalThis.disableDisconnected');
    globalThis.nativeMessagingResult = {
      ...result,
      extensionId: record.id,
      approvals,
      otherDocumentDenied,
      disabledPorts: broker.ports.size,
      disableDisconnected,
      closedChildren: children.every((child) => child.exitCode !== null || child.signalCode !== null),
    };
    broker.dispose();
    bridge.close();
    await manager.close();
  } catch (error) {
    globalThis.nativeMessagingResult = { error: error.stack };
  }
});
