'use strict';
const { app, BrowserWindow, session, webContents } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const root = path.resolve(__dirname, '../../..');
const directory = process.env.ZACRO_NATIVE_DIRECTORY;
const diagnostics = [];
app.on('web-contents-created', (_event, contents) =>
  contents.on('console-message', (_event, ...details) =>
    diagnostics.push({ url: contents.getURL(), details }),
  ),
);
app.setPath('userData', path.join(directory, 'userdata'));
app.on('window-all-closed', (event) => event.preventDefault());
app.whenReady().then(async () => {
  const sentinel = new BrowserWindow({ show: false });
  await sentinel.loadURL('about:blank');
  try {
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const sessions = {
      one: session.fromPartition('persist:native-one'),
      two: session.fromPartition('persist:native-two'),
    };
    let manager, download;
    const bridge = new ExtensionBridge({
      resolveExtension: (profile, id) => manager.resolveExtension(profile, id),
      dispatch: () => true,
    });
    manager = new ExtensionManager({
      root: path.join(directory, 'managed'),
      getProfile: (id) => ({ id, private: id === 'private' }),
      getSession: (id) => sessions[id],
      prepareSession: (ses, profile) => bridge.attachSession(ses, profile),
      confirmPermissions: async () => true,
      fetchPackage: async () => download,
      onDeactivated: async () => ({ requiresPageReload: false }),
    });
    await manager.restore('one');
    await manager.restore('two');
    const server = http.createServer((request, response) => {
      response.setHeader('Access-Control-Allow-Origin', '*');
      response.setHeader('Access-Control-Expose-Headers', 'x-native');
      response.setHeader('Content-Type', 'text/html');
      response.end(request.url);
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    app.on('will-quit', () => server.close());
    const base = `http://127.0.0.1:${server.address().port}`;
    const view = async (ses, url) => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      await window.loadURL(url);
      return window;
    };
    const target = await view(sessions.one, base + '/allowed');
    const foreign = await view(sessions.two, base + '/allowed');
    const request = (endpoint, window = target) =>
      window.webContents.executeJavaScript(
        `fetch(${JSON.stringify(base + endpoint)}).then(async r=>({body:await r.text(),header:r.headers.get('x-native')}),e=>({error:e.message}))`,
      );
    const blocked = async (endpoint) => !!(await request(endpoint)).error;
    if (process.env.ZACRO_NATIVE_PHASE === 'update') {
      const { zip, crx, keyPair } = require('./packages/builders.cjs');
      const { verifyCrx } = require(path.join(root, 'src/main/extensions/packages.cjs'));
      const keys = [keyPair()];
      const packageFor = (version) => {
        const manifest = {
          manifest_version: 3,
          name: 'Native update',
          version,
          permissions: version === '1' ? ['declarativeNetRequest', 'offscreen'] : ['declarativeNetRequest'],
          host_permissions: ['http://127.0.0.1/*'],
          declarative_net_request: {
            rule_resources: [
              { id: 'old', enabled: true, path: 'old.json' },
              ...(version === '1' ? [] : [{ id: 'new', enabled: true, path: 'new.json' }]),
            ],
          },
        };
        const rule = (id, urlFilter) =>
          JSON.stringify([
            { id, action: { type: 'block' }, condition: { urlFilter, resourceTypes: ['xmlhttprequest'] } },
          ]);
        const signed = crx(
          zip([
            { name: 'manifest.json', data: JSON.stringify(manifest) },
            { name: 'old.json', data: rule(1, '/update-old') },
            { name: 'new.json', data: rule(2, '/update-new') },
            { name: 'page.html', data: '<!doctype html>' },
            { name: 'offscreen.html', data: '<!doctype html><title>Update cleanup</title>' },
          ]),
          { keys },
        );
        return {
          ...verifyCrx(signed.buffer, { expectedId: signed.id, requirePublisher: false }),
          buffer: signed.buffer,
          publisherVerified: true,
          source: { kind: 'chrome-web-store', id: signed.id },
        };
      };
      // Only the verified-download boundary is synthetic. Native load, matching,
      // profile permissions, unload and real manager update remain production.
      download = packageFor('1');
      const installed = await manager.installStore('one', download.id);
      const page = await view(sessions.one, `chrome-extension://${installed.id}/page.html`);
      await page.webContents.executeJavaScript(
        `chrome.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds:['old']})`,
      );
      await page.webContents.executeJavaScript(
        `chrome.declarativeNetRequest.updateDynamicRules({addRules:[{id:9,action:{type:'block'},condition:{urlFilter:'/update-dynamic',resourceTypes:['xmlhttprequest']}}]})`,
      );
      await page.webContents.executeJavaScript(
        `chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Permission reduction cleanup'})`,
      );
      download = packageFor('2');
      const updated = await manager.update('one', installed.id);
      const next = await view(sessions.one, `chrome-extension://${installed.id}/page.html`);
      const attackerPreload = path.join(directory, 'attacker-preload.cjs');
      await fs.writeFile(
        attackerPreload,
        `const {contextBridge,ipcRenderer}=require('electron');contextBridge.exposeInMainWorld('forgeAlarm',()=>ipcRenderer.invoke('zacro:native-extension-alarm:v1',{name:'forged',scheduledTime:Date.now()}));`,
      );
      const attacker = new BrowserWindow({
        show: false,
        webPreferences: {
          session: sessions.one,
          sandbox: true,
          contextIsolation: true,
          nodeIntegration: false,
          preload: attackerPreload,
        },
      });
      await attacker.loadURL(`chrome-extension://${installed.id}/zacro-native-services.html`);
      const forgedAlarmDenied = await attacker.webContents.executeJavaScript(
        `forgeAlarm().then(()=>false,error=>/owned native alarm receiver/.test(error.message))`,
      );
      globalThis.nativeServicesResult = {
        forgedAlarmDenied,
        version: updated.current.manifest.version,
        enabled: updated.enabled,
        choices: await next.webContents.executeJavaScript(
          'chrome.declarativeNetRequest.getEnabledRulesets()',
        ),
        oldAllowed: !(await blocked('/update-old')),
        newBlocked: await blocked('/update-new'),
        dynamicBlocked: await blocked('/update-dynamic'),
        offscreenPermissionAbsent: await next.webContents.executeJavaScript('typeof chrome.offscreen'),
        offscreenClosed: !webContents
          .getAllWebContents()
          .some((w) => w.getURL() === `chrome-extension://${installed.id}/offscreen.html`),
      };
      await manager.close();
      bridge.close();
      return;
    }
    let installed = manager.list('one').find((entry) => entry.current.manifest.name === 'Native services');
    let alarmExtension = manager
      .list('one')
      .find((entry) => entry.current.manifest.name === 'Native alarm wake');
    if (process.env.ZACRO_NATIVE_PHASE === 'install') {
      const source = path.join(directory, 'source');
      await fs.mkdir(source);
      await fs.writeFile(
        path.join(source, 'manifest.json'),
        JSON.stringify({
          manifest_version: 3,
          name: 'Native services',
          version: '1',
          permissions: ['declarativeNetRequest', 'offscreen', 'alarms'],
          host_permissions: ['http://127.0.0.1/*'],
          background: { service_worker: 'worker.js' },
          declarative_net_request: { rule_resources: [{ id: 'static', enabled: true, path: 'rules.json' }] },
        }),
      );
      await fs.writeFile(
        path.join(source, 'rules.json'),
        JSON.stringify([
          {
            id: 1,
            action: { type: 'block' },
            condition: { urlFilter: '/static', resourceTypes: ['xmlhttprequest'] },
          },
        ]),
      );
      await fs.writeFile(path.join(source, 'page.html'), '<!doctype html><title>Native services</title>');
      await fs.writeFile(
        path.join(source, 'worker.js'),
        `chrome.runtime.onMessage.addListener((m,s,reply)=>{ if(m==='worker')reply('native-worker'); });`,
      );
      await fs.writeFile(
        path.join(source, 'offscreen.html'),
        '<!doctype html><title>Native offscreen</title><script src="offscreen.js"></script>',
      );
      await fs.writeFile(
        path.join(source, 'offscreen.js'),
        `chrome.runtime.onMessage.addListener((m,s,reply)=>{if(m==='offscreen')Promise.all([chrome.runtime.sendMessage('worker'),new Promise(resolve=>{const port=chrome.runtime.connect({name:'zacro.extension.transport.v1'});const timer=setTimeout(()=>resolve(false),2000);port.onMessage.addListener(message=>{clearTimeout(timer);resolve(/Offscreen/.test(message.error||''));port.disconnect();});port.postMessage({id:1,method:'probe',args:[]});})]).then(([worker,denied])=>reply({title:document.title,storage:typeof chrome.storage,tabs:typeof chrome.tabs,bridge:typeof zacroExtension,node:typeof require,process:typeof process,worker,denied}));return m==='offscreen';});`,
      );
      const ordinarySource = path.join(directory, 'ordinary-source');
      await fs.mkdir(ordinarySource);
      await fs.writeFile(
        path.join(ordinarySource, 'manifest.json'),
        JSON.stringify({ manifest_version: 3, name: 'No permission page', version: '1' }),
      );
      await fs.writeFile(
        path.join(ordinarySource, 'page.html'),
        '<!doctype html><script src="page.js"></script>',
      );
      await fs.writeFile(
        path.join(ordinarySource, 'page.js'),
        'globalThis.ordinaryFacade=typeof zacroExtension+":"+typeof chrome.tabs+":"+typeof chrome.storage;',
      );
      const ordinary = await manager.installLocal('one', ordinarySource);
      const ordinaryPage = await view(sessions.one, `chrome-extension://${ordinary.id}/page.html`);
      const ordinaryFacade = await ordinaryPage.webContents.executeJavaScript('ordinaryFacade');
      installed = await manager.installLocal('one', source);
      if (!installed.enabled) throw new Error('Managed native services did not enable: ' + installed.status);
      const page = await view(sessions.one, `chrome-extension://${installed.id}/page.html`);
      const execute = (code) => page.webContents.executeJavaScript(code);
      const staticBlocked = await blocked('/static');
      await execute(
        `chrome.declarativeNetRequest.updateDynamicRules({addRules:[{id:2,action:{type:'block'},condition:{urlFilter:'/dynamic',resourceTypes:['xmlhttprequest']}},{id:3,action:{type:'redirect',redirect:{transform:{path:'/landed'}}},condition:{urlFilter:'/redirect',resourceTypes:['xmlhttprequest']}},{id:4,action:{type:'modifyHeaders',responseHeaders:[{header:'x-native',operation:'set',value:'native'}]},condition:{urlFilter:'/headers',resourceTypes:['xmlhttprequest']}}]})`,
      );
      await execute(
        `chrome.declarativeNetRequest.updateSessionRules({addRules:[{id:5,action:{type:'block'},condition:{urlFilter:'/session',resourceTypes:['xmlhttprequest']}}]})`,
      );
      const dynamicBlocked = await blocked('/dynamic'),
        sessionBlocked = await blocked('/session');
      const redirected = (await request('/redirect')).body,
        header = (await request('/headers')).header;
      const otherProfileAllowed = !(await request('/dynamic', foreign)).error;
      const offscreenBadUrlRejected = await execute(
        `chrome.offscreen.createDocument({url:'https://foreign.invalid/offscreen.html',reasons:['DOM_PARSER'],justification:'Invalid URL boundary'}).then(()=>false,()=>true)`,
      );
      await execute(
        `chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Native fixture DOM parse'})`,
      );
      let offscreen;
      for (let i = 0; i < 100 && !offscreen; i++) {
        offscreen = await execute(`chrome.runtime.sendMessage('offscreen').catch(()=>null)`);
        if (!offscreen) await new Promise((r) => setTimeout(r, 20));
      }
      const duplicateRejected = await execute(
        `chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'duplicate'}).then(()=>false,()=>true)`,
      );
      await execute('chrome.offscreen.closeDocument()');
      const offscreenClosed = !(await execute('chrome.offscreen.hasDocument()'));
      await execute(
        `chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Disable cleanup'})`,
      );
      await execute(`chrome.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds:['static']})`);
      await manager.disable('one', installed.id);
      await new Promise((r) => setTimeout(r, 150));
      const disabledAllowed = !(await blocked('/dynamic'));
      const offscreenDisableClosed = !webContents
        .getAllWebContents()
        .some(
          (w) =>
            w.session === sessions.one && w.getURL() === `chrome-extension://${installed.id}/offscreen.html`,
        );
      page.destroy();
      const cacheMarker = path.join(
        manager.versionPath('one', installed.current),
        '_metadata',
        'unverified-cache',
      );
      await fs.mkdir(path.dirname(cacheMarker), { recursive: true });
      await fs.writeFile(cacheMarker, 'corrupt native cache');
      await manager.enable('one', installed.id);
      const cacheDiscarded = !(await fs.access(cacheMarker).then(
        () => true,
        () => false,
      ));
      const renewed = await view(sessions.one, `chrome-extension://${installed.id}/page.html`);
      const reenabledStatic = await renewed.webContents.executeJavaScript(
        'chrome.declarativeNetRequest.getEnabledRulesets()',
      );
      const reenabledDynamicBlocked = await blocked('/dynamic'),
        reenabledSessionAllowed = !(await blocked('/session'));
      await renewed.webContents.executeJavaScript(
        `chrome.declarativeNetRequest.updateSessionRules({addRules:[{id:5,action:{type:'block'},condition:{urlFilter:'/session',resourceTypes:['xmlhttprequest']}}]})`,
      );
      let privateRejected = false;
      try {
        await manager.installLocal('private', source);
      } catch (error) {
        privateRejected = /private/.test(error.message);
      }
      const alarmSource = path.join(directory, 'alarm-source');
      await fs.mkdir(alarmSource);
      await fs.writeFile(
        path.join(alarmSource, 'manifest.json'),
        JSON.stringify({
          manifest_version: 2,
          name: 'Native alarm wake',
          version: '1',
          permissions: ['alarms'],
          background: { scripts: ['background.js'], persistent: false },
        }),
      );
      await fs.writeFile(path.join(alarmSource, 'page.html'), '<!doctype html>');
      await fs.writeFile(
        path.join(alarmSource, 'background.js'),
        `localStorage.starts=String(Number(localStorage.starts||0)+1);chrome.alarms.onAlarm.addListener(alarm=>{localStorage.last=JSON.stringify({name:alarm.name,starts:Number(localStorage.starts)});});chrome.runtime.onMessage.addListener((m,s,reply)=>reply(JSON.parse(localStorage.last||'null')));`,
      );
      alarmExtension = await manager.installLocal('one', alarmSource);
      const alarmPage = await view(sessions.one, `chrome-extension://${alarmExtension.id}/page.html`);
      // Native lazy event pages need an initial event before there is a real
      // background instance to suspend. The later alarm must wake instance 2.
      await alarmPage.webContents.executeJavaScript(`chrome.runtime.sendMessage('initial')`);
      await alarmPage.webContents.executeJavaScript(
        `globalThis.alarmEvents=[];chrome.alarms.onAlarm.addListener(alarm=>alarmEvents.push(alarm));chrome.alarms.create('native-wake',{when:Date.now()+38000})`,
      );
      const alarmCreated = await alarmPage.webContents.executeJavaScript(`chrome.alarms.get('native-wake')`);
      await new Promise((r) => setTimeout(r, 35000));
      const alarmSuspended = !webContents
        .getAllWebContents()
        .some(
          (w) =>
            w.session === sessions.one &&
            w.getType() === 'backgroundPage' &&
            w.getURL().includes(alarmExtension.id),
        );
      await new Promise((r) => setTimeout(r, 5000));
      const alarmWake = await alarmPage.webContents.executeJavaScript(`chrome.runtime.sendMessage('last')`);
      const alarmNativeEvents = await alarmPage.webContents.executeJavaScript('alarmEvents');
      await alarmPage.webContents.executeJavaScript(
        `chrome.alarms.create('clear-me',{when:Date.now()+600000})`,
      );
      const cleared = await alarmPage.webContents.executeJavaScript(`chrome.alarms.clear('clear-me')`);
      const alarmCallbacks = await alarmPage.webContents.executeJavaScript(
        `new Promise(resolve=>chrome.alarms.create('callback-alarm',{when:Date.now()+600000,periodInMinutes:0.5},()=>chrome.alarms.get('callback-alarm',alarm=>chrome.alarms.clear('callback-alarm',cleared=>resolve(!!alarm&&cleared)))))`,
      );
      await alarmPage.webContents.executeJavaScript(
        `chrome.alarms.create('restart',{when:Date.now()+600000})`,
      );
      globalThis.nativeServicesResult = {
        ordinaryFacade,
        offscreenBadUrlRejected,
        cacheDiscarded,
        staticBlocked,
        dynamicBlocked,
        sessionBlocked,
        redirected,
        header,
        otherProfileAllowed,
        disabledAllowed,
        reenabledStatic,
        reenabledDynamicBlocked,
        reenabledSessionAllowed,
        offscreen,
        duplicateRejected,
        offscreenClosed,
        offscreenDisableClosed,
        privateRejected,
        alarmSuspended,
        alarmWake,
        alarmCreated,
        alarmNativeEvents,
        cleared,
        alarmCallbacks,
      };
    } else {
      const page = await view(sessions.one, `chrome-extension://${installed.id}/page.html`);
      const alarmPage = await view(sessions.one, `chrome-extension://${alarmExtension.id}/page.html`);
      const dynamicBlocked = await blocked('/dynamic'),
        sessionAllowed = !(await blocked('/session'));
      const staticChoices = await page.webContents.executeJavaScript(
        'chrome.declarativeNetRequest.getEnabledRulesets()',
      );
      const offscreenAbsent = !(await page.webContents.executeJavaScript('chrome.offscreen.hasDocument()'));
      const alarmRestored = !!(await alarmPage.webContents.executeJavaScript(`chrome.alarms.get('restart')`));
      await manager.remove('one', installed.id);
      await new Promise((r) => setTimeout(r, 150));
      const removedAllowed = !(await blocked('/dynamic'));
      globalThis.nativeServicesResult = {
        dynamicBlocked,
        sessionAllowed,
        staticChoices,
        offscreenAbsent,
        alarmRestored,
        removedAllowed,
      };
    }
    await manager.close();
    bridge.close();
  } catch (error) {
    globalThis.nativeServicesResult = { error: error.stack, diagnostics };
  }
});
