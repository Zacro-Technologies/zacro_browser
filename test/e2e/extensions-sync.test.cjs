'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { BrowserStore } = require('../../src/core/store.cjs');
const { randomBytes } = require('node:crypto');
const { _electron: electron, expect } = require('@playwright/test');
const { createSyncService } = require('../../services/sync/server.cjs');
const { zip, crx, keyPair } = require('../fixtures/extensions/packages/builders.cjs');
const { idFromKey } = require('../../src/main/extensions/packages.cjs');

async function fixture(t, { seed, entry, environment = {} } = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-sync-'));
  const service = await createSyncService({
    directory: path.join(directory, 'service'),
    masterKey: randomBytes(32),
    allowInsecureLoopback: true,
  });
  if (seed) await seed(path.join(directory, 'browser'));
  const env = {
    ...process.env,
    ZACRO_USER_DATA: path.join(directory, 'browser'),
    ZACRO_SYNC_DEV_LOOPBACK: '1',
    ...environment,
  };
  delete env.ELECTRON_RUN_AS_NODE;
  delete env.ZACRO_SYNC_URL;
  const app = await electron.launch({ args: [entry || path.resolve(__dirname, '../..')], env });
  t.after(async () => {
    // Disposal must also finish after a failed unsaved-navigation assertion.
    // The test body still decides and verifies Stay/Leave independently.
    await app
      .evaluate(({ dialog }) => {
        dialog.showMessageBoxSync = () => 1;
      })
      .catch(() => {});
    await app.close().catch(() => app.process().kill());
    await service.close();
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  });
  const page = await app.firstWindow();
  await expect(page.locator('[data-key="address"]')).toBeVisible();
  const invoke = (action, payload = {}) =>
    page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  return { app, page, invoke, service, directory };
}

test(
  'restoring an old browser backup cannot resurrect a removed migrated extension',
  { timeout: 60000 },
  async (t) => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-extension-migration-'));
    let app;
    t.after(async () => {
      if (app) await app.close().catch(() => app.process().kill());
      await fs.rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const folder = path.join(root, 'extensions', 'legacy'),
      key = keyPair().publicKey.export({ format: 'der', type: 'spki' }),
      id = idFromKey(key);
    await fs.mkdir(folder, { recursive: true });
    await fs.writeFile(
      path.join(folder, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Legacy fixture',
        version: '1',
        key: key.toString('base64'),
      }),
    );
    const store = new BrowserStore(root);
    store.state.extensions.push({
      id: 'legacy-record',
      extensionId: id,
      profileId: 'default',
      path: folder,
      enabled: true,
    });
    store.flush();
    const oldBackup = await fs.readFile(path.join(root, 'browser-state.json'));
    const launch = async () => {
      const env = { ...process.env, ZACRO_USER_DATA: root };
      delete env.ELECTRON_RUN_AS_NODE;
      delete env.ZACRO_SYNC_URL;
      app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
      const page = await app.firstWindow();
      await page.waitForFunction(() => !!window.zacro);
      return (action, payload = {}) =>
        page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    };
    let invoke = await launch();
    await expect.poll(async () => (await invoke('state:get')).extensions[0]?.enabled).toBe(true);
    await invoke('extension:remove', { id });
    await app.close();
    app = null;
    await fs.writeFile(path.join(root, 'browser-state.json.bak'), oldBackup);
    await fs.writeFile(path.join(root, 'browser-state.json'), 'broken primary');
    invoke = await launch();
    await expect
      .poll(async () => {
        try {
          return JSON.parse(await fs.readFile(path.join(root, 'browser-state.json'), 'utf8')).extensions
            .length;
        } catch {
          return -1;
        }
      })
      .toBe(0);
    assert.equal((await invoke('state:get')).extensions.length, 0);
  },
);

test(
  'native account UI registers, displays recovery codes once, links with separate settings consent and manages devices',
  { timeout: 90000 },
  async (t) => {
    const b = await fixture(t);
    await b.page.getByRole('button', { name: 'Library', exact: true }).click();
    await b.page.locator('[data-key="panel-settings"]').click();
    await expect(b.page.getByText('Account & sync', { exact: true })).toBeVisible({ timeout: 3000 });
    await b.page.getByText('Account & sync', { exact: true }).click();
    await expect(b.page.getByText('Set up a synchronization service', { exact: true })).toBeVisible();
    await b.page.getByRole('button', { name: 'Configure service', exact: true }).click();
    await b.page.getByLabel('Service URL', { exact: true }).fill(b.service.url);
    await b.page.getByRole('button', { name: 'Save service', exact: true }).click();
    await b.page.getByRole('button', { name: 'Create account', exact: true }).click();
    await b.page.getByLabel('Username', { exact: true }).fill('native.fixture');
    await b.page.getByLabel('Password', { exact: true }).fill('Synthetic native integration password');
    await b.page.getByLabel('Device name', { exact: true }).fill('Native fixture');
    await b.page.getByRole('dialog').getByRole('button', { name: 'Create account', exact: true }).click();
    await expect(b.page.getByRole('dialog', { name: 'Save your recovery codes' })).toBeVisible();
    await expect(b.page.locator('.recovery-codes code')).toHaveCount(10);
    const code = await b.page.locator('.recovery-codes code').first().textContent();
    assert.equal(JSON.stringify(await b.invoke('state:get')).includes(code), false);
    await b.page.getByRole('button', { name: 'I saved my recovery codes', exact: true }).click();
    await expect(b.page.locator('.recovery-codes')).toHaveCount(0);
    await b.page.getByRole('button', { name: 'Link profile', exact: true }).click();
    await b.page.getByLabel('New sync profile name', { exact: true }).fill('Personal extensions');
    await b.page.getByRole('button', { name: 'Create sync profile', exact: true }).click();
    await expect(b.page.getByRole('dialog', { name: 'Review profile link' })).toBeVisible();
    await expect(b.page.getByLabel('Sync extension settings', { exact: true })).not.toBeChecked();
    if (process.env.ZACRO_CAPTURE_UI) {
      await fs.mkdir(process.env.ZACRO_CAPTURE_UI, { recursive: true });
      await expect(b.page.getByRole('dialog')).toHaveCSS('opacity', '1');
      await b.page.screenshot({ path: path.join(process.env.ZACRO_CAPTURE_UI, 'sync-consent.png') });
    }
    await b.page.getByRole('button', { name: 'Link this profile', exact: true }).click();
    await expect.poll(async () => (await b.invoke('state:get')).sync.profiles[0]?.settingsSync).toBe(false);
    await b.page.getByRole('button', { name: 'Devices', exact: true }).click();
    await expect(b.page.getByRole('dialog', { name: 'Your devices' })).toContainText('Native fixture');
    await b.page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
    await b.page.getByRole('button', { name: 'Sign out', exact: true }).click();
    await expect.poll(async () => (await b.invoke('state:get')).sync.account).toBe(null);
    assert.equal(
      JSON.stringify(await b.invoke('state:get')).includes('Synthetic native integration password'),
      false,
    );
  },
);

test(
  'native tab identities survive New Tab while restored background pages stay unloaded',
  { timeout: 60000 },
  async (t) => {
    const requests = [];
    const server = http.createServer((req, res) => {
      requests.push(req.url);
      res.end('<!doctype html><title>Stable identity</title><input id="draft">');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(async () => {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    });
    const base = `http://127.0.0.1:${server.address().port}`;
    let loadedId;
    const b = await fixture(t, {
      seed(directory) {
        const state = new BrowserStore(directory);
        loadedId = state.dispatch('tab:create', { url: base + '/first', active: false }).id;
        state.dispatch('tab:create', { url: base + '/unloaded', active: false });
        state.flush();
      },
    });
    const contents = () =>
      b.app.evaluate(({ webContents }) =>
        webContents
          .getAllWebContents()
          .filter((c) => !c.getURL().startsWith('file:'))
          .map((c) => ({ id: c.id, url: c.getURL() })),
      );
    await expect.poll(async () => (await contents()).length).toBe(3);
    assert.deepEqual(requests, []);
    await b.invoke('tab:activate', { id: loadedId });
    await expect.poll(async () => (await contents()).some((c) => c.url === base + '/first')).toBe(true);
    const id = (await contents()).find((c) => c.url === base + '/first').id;
    await b.invoke('navigate', { url: 'zacro://newtab' });
    await expect.poll(async () => (await contents()).find((c) => c.id === id)?.url).toBe('about:blank');
    assert.equal((await b.invoke('state:get')).activeTabId, loadedId);
    await b.invoke('navigate', { url: base + '/second' });
    await expect.poll(async () => (await contents()).find((c) => c.id === id)?.url).toBe(base + '/second');
    assert.equal(requests.includes('/unloaded'), false);
  },
);

test(
  'browser extension controls open isolated action and options views with genuine tab and sync storage APIs',
  { timeout: 90000 },
  async (t) => {
    const b = await fixture(t),
      folder = path.join(b.directory, 'extension');
    await fs.mkdir(folder);
    await fs.writeFile(
      path.join(folder, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Browser adapter fixture',
        version: '1.0',
        commands: {
          'fixture-command': {
            suggested_key: { default: 'Ctrl+Shift+Y', mac: 'Command+Shift+Y' },
            description: 'Fixture command',
          },
        },
        permissions: ['storage', 'tabs', 'scripting', 'contextMenus'],
        host_permissions: ['http://127.0.0.1/*'],
        background: { service_worker: 'worker.js' },
        action: { default_title: 'Fixture action', default_popup: 'popup.html' },
        options_page: 'options.html',
      }),
    );
    await fs.writeFile(
      path.join(folder, 'worker.js'),
      'chrome.tabs.onCreated.addListener(tab=>chrome.storage.sync.set({lastCreated:tab.id})); chrome.runtime.onMessage.addListener((m,s,reply)=>{if(m.fixture)reply({native:true});});',
    );
    for (const name of ['popup', 'options', 'onboarding'])
      await fs.writeFile(
        path.join(folder, name + '.html'),
        `<!doctype html><title>Fixture ${name}</title><h1>${name}</h1><input id="draft">`,
      );
    await b.app.evaluate(({ dialog }, folder) => {
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [folder] });
      dialog.showMessageBox = async () => ({ response: 1 });
    }, folder);
    const extension = await b.invoke('extension:install');
    assert.equal(extension.enabled, true);
    const native = (page, expression) =>
      b.app.evaluate(
        ({ BrowserWindow }, { url, expression }) => {
          const wc = BrowserWindow.getAllWindows().find(
            (item) => item.webContents.getURL() === url,
          )?.webContents;
          if (!wc) return null;
          return wc.executeJavaScript(expression);
        },
        { url: `chrome-extension://${extension.id}/${page}.html`, expression },
      );
    await b.invoke('extension:options', { id: extension.id });
    await expect.poll(() => native('options', 'typeof chrome.storage.sync?.set')).toBe('function');
    assert.equal(await native('options', 'typeof window.zacro'), 'undefined');
    const tabs = await native('options', 'chrome.tabs.query({})');
    assert.equal(tabs.length, 1, 'internal shell/broker/options frames are excluded');
    const created = await native('options', 'chrome.tabs.create({active:false})');
    assert.equal(typeof created.id, 'number');
    const moved = await native('options', `chrome.tabs.move(${created.id},{index:0})`);
    assert.equal(moved.index, 0);
    await native('options', `chrome.tabs.remove(${created.id})`);
    await native('options', 'chrome.storage.sync.set({throughOptions:42})');
    await b.invoke('extension:action', { id: extension.id });
    await expect.poll(() => native('popup', 'typeof chrome.storage.sync?.get')).toBe('function');
    assert.deepEqual(await native('popup', 'chrome.storage.sync.get("throughOptions")'), {
      throughOptions: 42,
    });
    await native(
      'popup',
      'globalThis.changes=[]; chrome.storage.onChanged.addListener((changes,area)=>globalThis.changes.push({changes,area})); true',
    );
    await native('options', 'chrome.storage.sync.set({throughOptions:43});');
    await expect
      .poll(() =>
        native(
          'popup',
          'globalThis.changes.some(e=>e.area==="sync"&&e.changes.throughOptions?.newValue===43)',
        ),
      )
      .toBe(true);
    await native('popup', 'chrome.action.setBadgeText({text:"7"})');
    await native(
      'popup',
      'chrome.action.setBadgeBackgroundColor({color:[5,10,15,255]}); chrome.action.setBadgeTextColor({color:"#aabbcc"})',
    );
    await expect.poll(async () => (await b.invoke('state:get')).extensions[0]?.action.badgeText).toBe('7');
    await native(
      'options',
      'chrome.commands.onCommand.addListener(command=>chrome.storage.sync.set({command})); globalThis.menuClicks=0; chrome.contextMenus.onClicked.addListener(info=>chrome.storage.sync.set({clickedMenu:info.menuItemId,menuClicks:++globalThis.menuClicks,menuInfo:JSON.parse(JSON.stringify(info))})); chrome.contextMenus.create({id:"fixture-menu",title:"Fixture menu",contexts:["page"]}); chrome.contextMenus.create({id:"fixture-check",title:"Fixture checkbox",type:"checkbox",contexts:["page"]});',
    );
    await b.app.evaluate(({ BrowserWindow }) => {
      const shell = BrowserWindow.getAllWindows().find((window) =>
        window.webContents.getURL().startsWith('file:'),
      );
      shell.focus();
      shell.webContents.sendInputEvent({
        type: 'keyDown',
        keyCode: 'Y',
        modifiers: [process.platform === 'darwin' ? 'meta' : 'control', 'shift'],
      });
      shell.webContents.sendInputEvent({
        type: 'keyUp',
        keyCode: 'Y',
        modifiers: [process.platform === 'darwin' ? 'meta' : 'control', 'shift'],
      });
    });
    await expect
      .poll(async () => (await native('options', 'chrome.storage.sync.get("command")')).command)
      .toBe('fixture-command');
    const clickMenu = (label) =>
      b.app.evaluate(
        ({ Menu, webContents }, { tabId, label }) => {
          let checked;
          const original = Menu.buildFromTemplate;
          Menu.buildFromTemplate = (items) => {
            const item = items
              .find((row) => row.label === 'Browser adapter fixture')
              ?.submenu?.find((row) => row.label === label);
            assertMenu(item);
            checked = item.checked;
            item.click();
            const menu = original(items);
            menu.popup = () => {};
            return menu;
          };
          function assertMenu(item) {
            if (!item) throw new Error('Extension menu missing');
          }
          try {
            webContents
              .fromId(tabId)
              .emit(
                'context-menu',
                {},
                { x: 0, y: 0, selectionText: '', linkURL: '', srcURL: '', isEditable: false },
              );
          } finally {
            Menu.buildFromTemplate = original;
          }
          return checked;
        },
        { tabId: tabs[0].id, label },
      );
    await clickMenu('Fixture menu');
    await expect
      .poll(async () => (await native('options', 'chrome.storage.sync.get("clickedMenu")')).clickedMenu)
      .toBe('fixture-menu');
    assert.equal(await clickMenu('Fixture checkbox'), false);
    await expect
      .poll(async () => (await native('options', 'chrome.storage.sync.get("menuClicks")')).menuClicks)
      .toBe(2);
    let menuInfo = (await native('options', 'chrome.storage.sync.get("menuInfo")')).menuInfo;
    assert.equal(menuInfo.wasChecked, false);
    assert.equal(menuInfo.checked, true);
    assert.equal(
      await clickMenu('Fixture checkbox'),
      true,
      'rebuilt native menu reflects the previous click',
    );
    await expect
      .poll(async () => (await native('options', 'chrome.storage.sync.get("menuClicks")')).menuClicks)
      .toBe(3);
    menuInfo = (await native('options', 'chrome.storage.sync.get("menuInfo")')).menuInfo;
    assert.equal(menuInfo.wasChecked, true);
    assert.equal(menuInfo.checked, false);
    const ownTab = await native('options', `chrome.tabs.create({url:'onboarding.html',active:false})`);
    assert.equal(typeof ownTab.id, 'number');
    assert.equal(ownTab.url, `chrome-extension://${extension.id}/onboarding.html`);
    await b.app.evaluate(async ({ webContents }, id) => {
      const wc = webContents.fromId(id);
      for (let attempt = 0; attempt < 100 && !wc.getURL().startsWith('chrome-extension:'); attempt++)
        await new Promise((r) => setTimeout(r, 10));
    }, ownTab.id);
    assert.equal(
      await b.app.evaluate(
        ({ webContents }, id) =>
          webContents.fromId(id).executeJavaScript('chrome.tabs.getCurrent().then(tab=>tab.id)'),
        ownTab.id,
      ),
      ownTab.id,
    );
    const updated = await native('options', `chrome.tabs.update(${ownTab.id},{url:'options.html'})`);
    assert.equal(updated.url, `chrome-extension://${extension.id}/options.html`);
    await expect
      .poll(() => b.app.evaluate(({ webContents }, id) => webContents.fromId(id).getURL(), ownTab.id))
      .toBe(updated.url);
    await native('options', `chrome.tabs.update(${ownTab.id},{active:true})`);
    await b.app.evaluate(async ({ dialog, webContents }, id) => {
      globalThis.extensionNavigationDecision = 0;
      globalThis.extensionNavigationPrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.extensionNavigationPrompts++;
        return globalThis.extensionNavigationDecision;
      };
      const wc = webContents.fromId(id);
      wc.sendInputEvent({ type: 'mouseDown', x: 30, y: 15, button: 'left', clickCount: 1 });
      wc.sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
      await wc.executeJavaScript(
        'document.querySelector("#draft").value="keep extension draft"; window.addEventListener("beforeunload", e=>{e.preventDefault();e.returnValue="Unsaved";}); undefined',
      );
    }, ownTab.id);
    const ownStoreId = (await b.invoke('state:get')).activeTabId;
    for (const [index, url] of [b.service.url + '/health', 'zacro://newtab'].entries()) {
      await b.invoke('navigate', { url });
      await expect.poll(() => b.app.evaluate(() => globalThis.extensionNavigationPrompts)).toBe(index + 1);
      assert.equal((await b.invoke('state:get')).tabs.find((tab) => tab.id === ownStoreId)?.url, updated.url);
      assert.equal(
        await b.app.evaluate(
          ({ webContents }, id) =>
            webContents.fromId(id).executeJavaScript('document.querySelector("#draft").value'),
          ownTab.id,
        ),
        'keep extension draft',
      );
    }
    await b.app.evaluate(() => {
      globalThis.extensionNavigationDecision = 1;
    });
    await native('options', `chrome.tabs.remove(${ownTab.id})`);
    await b.page.getByRole('button', { name: 'Library', exact: true }).click();
    await b.page.locator('[data-key="panel-settings"]').click();
    await b.page.getByText('Extensions', { exact: true }).click();
    await b.page.getByRole('button', { name: 'Manage extensions', exact: true }).click();
    await expect(b.page.locator('.extension-card')).toContainText('Browser adapter fixture');
    await expect(b.page.locator('.extension-badge')).toHaveCSS('background-color', 'rgb(5, 10, 15)');
    await expect(b.page.locator('.extension-badge')).toHaveCSS('color', 'rgb(170, 187, 204)');
    await expect(
      b.page.getByRole('button', { name: 'Install from Chrome Web Store', exact: true }),
    ).toBeVisible();
    if (process.env.ZACRO_CAPTURE_UI) {
      await fs.mkdir(process.env.ZACRO_CAPTURE_UI, { recursive: true });
      await b.page.screenshot({ path: path.join(process.env.ZACRO_CAPTURE_UI, 'extensions.png') });
    }
    await b.page.getByRole('button', { name: 'Install from Chrome Web Store', exact: true }).click();
    await expect(b.page.getByLabel('Store URL or extension ID')).toBeVisible();
    await expect(b.page.getByRole('dialog')).toHaveCSS('opacity', '1');
    if (process.env.ZACRO_CAPTURE_UI)
      await b.page.screenshot({ path: path.join(process.env.ZACRO_CAPTURE_UI, 'store-review.png') });
    await b.page.getByRole('dialog').getByRole('button', { name: 'Cancel', exact: true }).click();
    await b.invoke('profile:create', { name: 'Separate profile' });
    await expect.poll(() => native('popup', 'true')).toBe(null);
    assert.equal((await b.invoke('state:get')).extensions.length, 0);
  },
);

for (const backgroundKind of ['module', 'classic', 'mv2-scripts', 'mv2-html', 'mv2-lazy'])
  test(
    `two complete Electron browsers synchronize genuine extension APIs through the real service across consent, offline restart and library lifecycle (${backgroundKind})`,
    { timeout: 180000 },
    async (t) => {
      const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-two-desktops-'));
      const serviceOptions = {
        directory: path.join(root, 'service'),
        masterKey: randomBytes(32),
        allowInsecureLoopback: true,
      };
      let service = await createSyncService(serviceOptions);
      serviceOptions.port = Number(new URL(service.url).port);
      const server = http.createServer((req, res) => {
        res.setHeader('content-type', 'text/html');
        res.end(
          '<!doctype html><title>Content API fixture</title><body data-client="client-a"><h1>Owned fixture</h1></body>',
        );
      });
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const base = `http://127.0.0.1:${server.address().port}`;
      const signed = crx(
        zip([
          {
            name: 'manifest.json',
            data: JSON.stringify({
              manifest_version: backgroundKind.startsWith('mv2') ? 2 : 3,
              name: 'Two desktop synthetic fixture',
              version: '1.0',
              permissions: [
                'storage',
                'tabs',
                ...(backgroundKind.startsWith('mv2') ? ['http://127.0.0.1/*'] : []),
              ],
              ...(backgroundKind.startsWith('mv2') ? {} : { host_permissions: ['http://127.0.0.1/*'] }),
              background:
                backgroundKind === 'mv2-html'
                  ? { page: 'background.html', persistent: true }
                  : ['mv2-scripts', 'mv2-lazy'].includes(backgroundKind)
                    ? { scripts: ['worker.js'], persistent: backgroundKind !== 'mv2-lazy' }
                    : {
                        service_worker: 'worker.js',
                        ...(backgroundKind === 'module' ? { type: 'module' } : {}),
                      },
              [backgroundKind.startsWith('mv2') ? 'browser_action' : 'action']: {
                default_popup: 'popup.html',
              },
              options_page: 'options.html',
              content_scripts: [
                { matches: ['http://127.0.0.1/*'], js: ['content.js'], run_at: 'document_idle' },
              ],
            }),
          },
          { name: 'background.html', data: '<!doctype html><script src="worker.js"></script>' },
          {
            name: 'worker.js',
            data: `chrome.storage.onChanged.addListener((changes,area)=>{if(area==='sync'&&changes.remoteWake)chrome.storage.local.set({remoteWake:changes.remoteWake.newValue});});chrome.runtime.onMessage.addListener((message,sender,reply)=>{if(!message.fixture)return; (async()=>{if(message.set)await chrome.storage.sync.set(message.set);reply(await chrome.storage.sync.get(null));})().catch(error=>reply({error:error.message}));return true;});`,
          },
          {
            name: 'content.js',
            data: `chrome.storage.sync.set({contentClient:document.body.dataset.client}).then(()=>document.documentElement.dataset.syncWritten='yes');chrome.storage.onChanged.addListener((changes,area)=>{if(area==='sync'&&changes.remoteForContent)document.documentElement.dataset.remoteValue=String(changes.remoteForContent.newValue);});`,
          },
          ...['options', 'popup'].map((name) => ({
            name: name + '.html',
            data: `<!doctype html><title>Two desktop ${name}</title><h1>${name}</h1>`,
          })),
        ]),
        { keys: [keyPair()] },
      );
      const packagePath = path.join(root, 'fixture.crx');
      await fs.writeFile(packagePath, signed.buffer);
      const browsers = [];
      t.after(async () => {
        for (const browser of browsers)
          if (browser.app) await browser.app.close().catch(() => browser.app.process().kill());
        if (service) await service.close();
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
        await fs.rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      });
      const launch = async (name, previous) => {
        const env = {
          ...process.env,
          ZACRO_USER_DATA: path.join(root, name),
          ZACRO_SYNC_DEV_LOOPBACK: '1',
          ZACRO_FIXTURE_CRX: packagePath,
        };
        delete env.ELECTRON_RUN_AS_NODE;
        delete env.ZACRO_SYNC_URL;
        const app = await electron.launch({
          args: [path.resolve(__dirname, '../fixtures/extensions/sync-browser.cjs')],
          env,
        });
        const page = await app.firstWindow();
        await expect(page.locator('[data-key="address"]')).toBeVisible();
        await app.evaluate(({ dialog }) => {
          dialog.showMessageBox = async () => ({ response: 1 });
        });
        const browser = previous || {};
        Object.assign(browser, {
          app,
          page,
          invoke: (action, payload = {}) =>
            page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]),
          api: (expression, view = 'options') =>
            app.evaluate(
              ({ BrowserWindow }, { url, expression }) => {
                const wc = BrowserWindow.getAllWindows().find(
                  (window) => window.webContents.getURL() === url,
                )?.webContents;
                if (!wc) throw new Error('Fixture view missing');
                return wc.executeJavaScript(expression);
              },
              { url: `chrome-extension://${signed.id}/${view}.html`, expression },
            ),
        });
        if (!previous) browsers.push(browser);
        return browser;
      };
      const a = await launch('a'),
        b = await launch('b'),
        password = 'Synthetic two-desktop account password';
      for (const browser of [a, b]) await browser.invoke('sync:configure', { endpoint: service.url });
      await a.invoke('sync:register', { username: 'two.desktop', password, deviceName: 'Desktop A' });
      await b.invoke('sync:login', { username: 'two.desktop', password, deviceName: 'Desktop B' });
      await a.invoke('extension:install-store', { url: signed.id });
      const dataset = await a.invoke('sync:create-dataset', { name: 'Shared extensions' });
      await a.invoke('sync:link', {
        datasetId: dataset.id,
        libraryChoice: 'merge-local',
        settingsSync: true,
        settingsConsent: true,
        settingsChoice: 'upload-local',
      });
      await a.invoke('sync:now');
      await b.invoke('sync:link', {
        datasetId: dataset.id,
        libraryChoice: 'remote-only',
        settingsSync: false,
      });
      assert.equal((await b.invoke('state:get')).extensions[0].status, 'remote-pending');
      await b.app.evaluate(({ dialog }) => {
        dialog.showMessageBox = async () => ({ response: 0 });
      });
      assert.equal((await b.invoke('extension:review-remote', { id: signed.id })).status, 'pending-approval');
      assert.equal((await b.invoke('state:get')).extensions[0].enabled, false);
      await b.app.evaluate(({ dialog }) => {
        dialog.showMessageBox = async () => ({ response: 1 });
      });
      await b.invoke('extension:approve', { id: signed.id });
      for (const browser of [a, b]) await browser.invoke('extension:options', { id: signed.id });
      await a.api('chrome.runtime.sendMessage({fixture:true,set:{fromBackground:41}})');
      await a.invoke('sync:now');
      await b.invoke('sync:now');
      assert.deepEqual(
        await b.api('chrome.storage.sync.get("fromBackground")'),
        {},
        'settings stay local before consent',
      );
      await b.api(
        'globalThis.remoteEvents=[];chrome.storage.onChanged.addListener((changes,area)=>remoteEvents.push({changes,area}));true',
      );
      await b.invoke('sync:settings', { enabled: true, settingsConsent: true, settingsChoice: 'use-remote' });
      assert.deepEqual(await b.api('chrome.storage.sync.get("fromBackground")'), { fromBackground: 41 });
      await expect
        .poll(() => b.api('remoteEvents.some(e=>e.area==="sync"&&e.changes.fromBackground?.newValue===41)'))
        .toBe(true);
      if (backgroundKind === 'mv2-lazy') {
        await b.api('chrome.runtime.sendMessage({fixture:true})');
        await expect
          .poll(
            () =>
              b.app.evaluate(
                ({ webContents }, id) =>
                  webContents
                    .getAllWebContents()
                    .filter(
                      (wc) =>
                        wc.getType() === 'backgroundPage' &&
                        wc.getURL().startsWith(`chrome-extension://${id}/`),
                    ).length,
                signed.id,
              ),
            { timeout: 45000, intervals: [500, 1000] },
          )
          .toBe(0);
        await a.api('chrome.storage.sync.set({remoteWake:"real-service-wake"})');
        await a.invoke('sync:now');
        await b.invoke('sync:now');
        await expect
          .poll(async () => (await b.api('chrome.storage.local.get("remoteWake")')).remoteWake)
          .toBe('real-service-wake');
      }
      await b.invoke('extension:action', { id: signed.id });
      await b.api('chrome.storage.sync.set({fromPopup:42})', 'popup');
      await b.invoke('sync:now');
      await a.invoke('sync:now');
      assert.equal((await a.api('chrome.runtime.sendMessage({fixture:true})')).fromPopup, 42);
      await a.invoke('navigate', { url: base + '/content' });
      const content = (expression) =>
        a.app.evaluate(
          ({ webContents }, { url, expression }) => {
            const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
            return wc ? wc.executeJavaScript(expression) : null;
          },
          { url: base + '/content', expression },
        );
      await expect.poll(() => content('document.documentElement.dataset.syncWritten')).toBe('yes');
      await a.invoke('sync:now');
      await b.invoke('sync:now');
      assert.equal((await b.api('chrome.storage.sync.get("contentClient")')).contentClient, 'client-a');
      await b.api('chrome.storage.sync.set({remoteForContent:"delivered"})');
      await b.invoke('sync:now');
      await a.invoke('sync:now');
      await expect.poll(() => content('document.documentElement.dataset.remoteValue')).toBe('delivered');
      await service.close();
      service = null;
      await a.api('chrome.storage.sync.set({offlineA:"retained across browser restart"})');
      await b.api('chrome.storage.sync.set({offlineB:"independent offline edit"})');
      assert.equal((await a.invoke('sync:now')).state, 'offline');
      await a.app.close();
      a.app = null;
      await launch('a', a);
      await expect.poll(async () => (await a.invoke('state:get')).extensions[0]?.enabled).toBe(true);
      await a.invoke('extension:options', { id: signed.id });
      assert.equal(
        (await a.api('chrome.storage.sync.get("offlineA")')).offlineA,
        'retained across browser restart',
      );
      service = await createSyncService(serviceOptions);
      await a.invoke('sync:now');
      await b.invoke('sync:now');
      await a.invoke('sync:now');
      await expect
        .poll(async () => (await a.api('chrome.storage.sync.get("offlineB")')).offlineB)
        .toBe('independent offline edit');
      assert.equal(
        (await b.api('chrome.storage.sync.get("offlineA")')).offlineA,
        'retained across browser restart',
      );
      if (backgroundKind === 'module') {
        await a.api('chrome.storage.sync.clear()');
        await a.invoke('sync:now');
        await b.invoke('sync:now');
        await service.close();
        service = null;
        await a.api(
          'chrome.storage.sync.set(Object.fromEntries(Array.from({length:13},(_,i)=>["quotaA"+i,"a".repeat(7000)])))',
        );
        await b.api('chrome.storage.sync.set({quotaB1:"b".repeat(7000),quotaB2:"b".repeat(7000)})');
        service = await createSyncService(serviceOptions);
        await a.invoke('sync:now');
        await b.invoke('sync:now');
        const rejected = (await b.invoke('state:get')).sync.profiles[0].rejected;
        assert.equal(rejected.length, 1);
        assert.equal(
          (await b.api('chrome.storage.sync.get("quotaB1")')).quotaB1.length,
          7000,
          'rejected changes remain available',
        );
        const destination = path.join(root, 'unsynced-settings.json');
        await b.app.evaluate(({ dialog }, destination) => {
          dialog.showSaveDialog = async () => ({ canceled: false, filePath: destination });
        }, destination);
        assert.equal((await b.invoke('sync:export', { id: rejected[0].id })).saved, true);
        const exported = JSON.parse(await fs.readFile(destination, 'utf8'));
        assert.equal(exported.payload.set.quotaB1.length, 7000);
        assert.equal(JSON.stringify(exported).includes(password), false);
        await b.invoke('sync:discard', { id: rejected[0].id });
        assert.deepEqual(await b.api('chrome.storage.sync.get("quotaB1")'), {});
        assert.equal((await b.invoke('state:get')).sync.profiles[0].rejected.length, 0);
      }
      await a.invoke('extension:toggle', { id: signed.id });
      await a.invoke('sync:now');
      await b.invoke('sync:now');
      await expect.poll(async () => (await b.invoke('state:get')).extensions[0]?.enabled).toBe(false);
      await a.invoke('extension:toggle', { id: signed.id });
      await a.invoke('sync:now');
      await b.invoke('sync:now');
      await expect.poll(async () => (await b.invoke('state:get')).extensions[0]?.enabled).toBe(true);
      await a.invoke('extension:remove', { id: signed.id });
      await a.invoke('sync:now');
      await b.invoke('sync:now');
      await expect.poll(async () => (await b.invoke('state:get')).extensions.length).toBe(0);
      const devices = await a.invoke('sync:devices');
      await a.invoke('sync:revoke-device', { id: devices.find((device) => device.name === 'Desktop B').id });
      await b.invoke('sync:now');
      assert.equal((await b.invoke('state:get')).sync.account, null);
    },
  );
