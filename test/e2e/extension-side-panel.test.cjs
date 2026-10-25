'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path'),
  http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');
const { zip, crx, keyPair } = require('../fixtures/extensions/packages/builders.cjs');
test(
  'real extension side panel shares shell layout, retains page draft and obeys lifecycle boundaries',
  { timeout: 70000 },
  async (t) => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-side-panel-'));
    const server = http.createServer((_q, r) => {
      r.setHeader('Content-Type', 'text/html');
      r.end('<!doctype html><title>Retained page</title><input id="draft">');
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const base = `http://127.0.0.1:${server.address().port}/`;
    const signed = crx(
      zip([
        {
          name: 'manifest.json',
          data: JSON.stringify({
            manifest_version: 3,
            name: 'Side panel fixture',
            version: '1',
            permissions: ['sidePanel', 'storage', 'tabs'],
            side_panel: { default_path: 'panel.html' },
            action: { default_title: 'Panel action' },
            options_page: 'options.html',
          }),
        },
        {
          name: 'panel.html',
          data: '<!doctype html><title>Native side panel</title><input id="panelDraft"><button id="close">Close</button><script src="panel.js"></script>',
        },
        {
          name: 'replacement.html',
          data: '<!doctype html><title>Replacement side panel</title><input id="panelDraft">',
        },
        {
          name: 'panel.js',
          data: "document.querySelector('#close').addEventListener('click',()=>chrome.sidePanel.close({windowId:1}));",
        },
        {
          name: 'options.html',
          data: '<!doctype html><title>Panel options</title><button id="open">Open using API</button><script src="options.js"></script>',
        },
        {
          name: 'options.js',
          data: "document.querySelector('#open').addEventListener('click',()=>chrome.sidePanel.open({windowId:1}).then(()=>document.body.dataset.opened='yes',error=>document.body.dataset.opened=error.message));",
        },
      ]),
      { keys: [keyPair()] },
    );
    const crxPath = path.join(root, 'panel.crx');
    await fs.writeFile(crxPath, signed.buffer);
    const env = { ...process.env, ZACRO_USER_DATA: path.join(root, 'browser'), ZACRO_FIXTURE_CRX: crxPath };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/sync-browser.cjs')],
      env,
    });
    t.after(async () => {
      await app
        .evaluate(({ dialog }) => {
          dialog.showMessageBoxSync = () => 1;
        })
        .catch(() => {});
      await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
      await fs.rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const shell = await app.firstWindow();
    await shell.waitForFunction(() => !!window.zacro);
    await app.evaluate(({ dialog }) => {
      dialog.showMessageBox = async (_window, options) => ({
        response: options?.title === 'Reload pages to finish changing extension access' ? 0 : 1,
      });
    });
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const state = () => invoke('state:get');
    await invoke('navigate', { url: base });
    let pageId;
    await expect
      .poll(
        async () =>
          (pageId = await app.evaluate(
            ({ webContents }, base) => webContents.getAllWebContents().find((w) => w.getURL() === base)?.id,
            base,
          )),
      )
      .toBeTruthy();
    const execute = (id, code) =>
      app.evaluate(({ webContents }, { id, code }) => webContents.fromId(id).executeJavaScript(code), {
        id,
        code,
      });
    await expect.poll(() => execute(pageId, '!!document.querySelector("#draft")')).toBe(true);
    await execute(pageId, 'document.querySelector("#draft").value="keep unsaved page";undefined');
    await invoke('extension:install-store', { url: signed.id });
    await invoke('extension:options', { id: signed.id });
    const optionsId = await app.evaluate(
      ({ webContents }, id) =>
        webContents.getAllWebContents().find((w) => w.getURL() === `chrome-extension://${id}/options.html`)
          ?.id,
      signed.id,
    );
    const denied = await app.evaluate(
      ({ webContents }, id) =>
        webContents
          .fromId(id)
          .executeJavaScript(
            'chrome.sidePanel.open({windowId:1}).then(()=>false,e=>/gesture/.test(e.message))',
            true,
          ),
      optionsId,
    );
    assert.equal(denied, true);
    const optionsPage = app.windows().find((p) => p.url() === `chrome-extension://${signed.id}/options.html`);
    await optionsPage.getByRole('button', { name: 'Open using API' }).click();
    await expect.poll(() => execute(optionsId, 'document.body.dataset.opened')).toBe('yes');
    await expect.poll(async () => !!(await state()).runtime.extensionPanel).toBe(true);
    const normalTab = await execute(
      optionsId,
      'chrome.tabs.create({url:chrome.runtime.getURL("options.html")})',
    );
    await optionsPage.close();
    assert.ok((await state()).runtime.extensionPanel, 'panel outlives its opening extension page');
    await shell.getByRole('button', { name: 'Close panel', exact: true }).click();
    await expect.poll(async () => (await state()).runtime.extensionPanel).toBe(null);
    const baselineWindows = await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length);
    await expect.poll(() => execute(normalTab.id, 'typeof chrome.sidePanel?.open')).toBe('function');
    assert.equal(
      await execute(
        normalTab.id,
        'chrome.sidePanel.open({windowId:1}).then(()=>false,e=>/gesture/.test(e.message))',
      ),
      true,
    );
    await app.evaluate(({ webContents }, id) => {
      const wc = webContents.fromId(id);
      wc.sendInputEvent({ type: 'mouseDown', x: 40, y: 17, button: 'left', clickCount: 1 });
      wc.sendInputEvent({ type: 'mouseUp', x: 40, y: 17, button: 'left', clickCount: 1 });
    }, normalTab.id);
    await expect.poll(() => execute(normalTab.id, 'document.body.dataset.opened')).toBe('yes');
    await shell.getByRole('button', { name: 'Close panel', exact: true }).click();
    await expect.poll(async () => (await state()).runtime.extensionPanel).toBe(null);
    await invoke('tab:close', { id: (await state()).activeTabId });
    // Open the visible manage control through the actual shell event path.
    await shell.keyboard.press(process.platform === 'darwin' ? 'Meta+,' : 'Control+,');
    await shell
      .locator('details.setting-section')
      .filter({ has: shell.locator('summary', { hasText: 'Extensions' }) })
      .locator('summary')
      .click();
    await shell.getByRole('button', { name: 'Manage extensions', exact: true }).click();
    await shell.getByRole('button', { name: 'Open side panel', exact: true }).click();
    await expect(shell.getByRole('heading', { name: 'Side panel fixture', exact: true })).toBeVisible();
    await expect.poll(async () => (await state()).runtime.extensionPanel?.extensionId).toBe(signed.id);
    let panelId = await app.evaluate(
      ({ webContents }, id) =>
        webContents.getAllWebContents().find((w) => w.getURL() === `chrome-extension://${id}/panel.html`)?.id,
      signed.id,
    );
    await expect.poll(() => execute(panelId, 'typeof chrome.sidePanel.getOptions')).toBe('function');
    assert.deepEqual(await execute(panelId, 'chrome.sidePanel.getLayout()'), { side: 'right' });
    assert.equal(
      await execute(panelId, 'typeof process+":"+typeof require+":"+typeof zacro'),
      'undefined:undefined:undefined',
    );
    await execute(panelId, 'document.querySelector("#panelDraft").value="keep panel";undefined');
    const native = () =>
      app.evaluate(
        ({ BrowserWindow }, { panelId, pageId }) => {
          const w = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().startsWith('file:'));
          const views = w.contentView.children;
          return {
            windowCount: BrowserWindow.getAllWindows().length,
            panel: views.find((v) => v.webContents?.id === panelId)?.getBounds(),
            page: views.find((v) => v.webContents?.id === pageId)?.getBounds(),
            size: w.getContentSize(),
            attached: views.some((v) => v.webContents?.id === panelId),
          };
        },
        { panelId, pageId },
      );
    await expect.poll(async () => !!(await native()).panel).toBe(true);
    const geometry = await native();
    assert.equal(
      geometry.windowCount,
      baselineWindows,
      'panel is an attached view, with no new browser window',
    );
    assert.ok(geometry.panel.x > geometry.page.x + geometry.page.width);
    assert.ok(geometry.panel.x + geometry.panel.width <= geometry.size[0]);
    assert.ok(geometry.panel.y + geometry.panel.height <= geometry.size[1]);
    await shell.keyboard.press(process.platform === 'darwin' ? 'Meta+k' : 'Control+k');
    await expect.poll(async () => (await native()).attached).toBe(false);
    await shell.keyboard.press('Escape');
    await expect.poll(async () => (await native()).attached).toBe(true);
    assert.equal(await execute(panelId, 'document.querySelector("#panelDraft").value'), 'keep panel');
    assert.equal(await execute(pageId, 'document.querySelector("#draft").value'), 'keep unsaved page');
    const replacedId = panelId;
    await execute(panelId, 'chrome.sidePanel.setOptions({path:"replacement.html"})').catch((error) => {
      assert.match(error.message, /destroyed|disposed|frame|context/i);
    });
    await expect
      .poll(
        async () =>
          (panelId = await app.evaluate(
            ({ webContents }, id) =>
              webContents
                .getAllWebContents()
                .find((w) => w.getURL() === `chrome-extension://${id}/replacement.html`)?.id,
            signed.id,
          )),
      )
      .toBeTruthy();
    await expect.poll(async () => (await state()).runtime.extensionPanel?.extensionId).toBe(signed.id);
    assert.equal(await app.evaluate(({ webContents }, id) => !!webContents.fromId(id), replacedId), false);
    assert.equal(await execute(panelId, 'typeof chrome.sidePanel.getOptions'), 'function');
    await invoke('tab:create', { url: base + 'second' });
    assert.equal(
      (await state()).runtime.extensionPanel?.extensionId,
      signed.id,
      'global survives same-profile tab switch',
    );
    const activeNative = await execute(panelId, 'chrome.tabs.query({active:true}).then(t=>t[0].id)');
    await execute(
      panelId,
      `chrome.sidePanel.setOptions({tabId:${activeNative},path:'panel.html',enabled:true})`,
    );
    await shell.getByRole('button', { name: 'Close panel', exact: true }).click();
    await expect.poll(async () => (await state()).runtime.extensionPanel).toBe(null);
    await invoke('extension:panel-open', { id: signed.id });
    await expect.poll(async () => (await state()).runtime.extensionPanel?.tabId).toBe(activeNative);
    await invoke('tab:create', { url: base + 'third' });
    await expect.poll(async () => (await state()).runtime.extensionPanel).toBe(null);
    await invoke('extension:panel-open', { id: signed.id });
    const previousState = await state();
    const oldProfile = previousState.spaces.find((s) => s.id === previousState.activeSpaceId).profileId;
    await invoke('profile:create', { name: 'Isolated panel profile' });
    await expect.poll(async () => (await state()).runtime.extensionPanel).toBe(null);
    await assert.rejects(
      invoke('extension:panel-open', { id: signed.id, profileId: oldProfile }),
      /profile changed/,
    );
    await invoke('space:activate', { id: previousState.activeSpaceId });
    await invoke('extension:panel-open', { id: signed.id });
    await invoke('extension:toggle', { id: signed.id });
    await expect.poll(async () => (await state()).runtime.extensionPanel).toBe(null);
    assert.equal(await execute(pageId, 'document.querySelector("#draft").value'), 'keep unsaved page');
  },
);
