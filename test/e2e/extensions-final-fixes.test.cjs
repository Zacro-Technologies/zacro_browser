'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { randomBytes, randomUUID } = require('node:crypto');
const { _electron: electron, expect } = require('@playwright/test');
const { createSyncService } = require('../../services/sync/server.cjs');
const { zip, crx, keyPair } = require('../fixtures/extensions/packages/builders.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-final-native-'));
  const server = http.createServer((_req, res) => {
    res.setHeader('Content-Type', 'text/html');
    res.end('<!doctype html><title>Retained draft</title><input id="draft">');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const signed = crx(
    zip([
      {
        name: 'manifest.json',
        data: JSON.stringify({
          manifest_version: 3,
          name: 'Final lifecycle fixture',
          version: '1',
          permissions: ['storage', 'tabs'],
          host_permissions: ['http://127.0.0.1/*'],
          options_page: 'options.html',
          commands: {
            'fixture-command': {
              suggested_key: { default: 'Ctrl+Shift+Y', mac: 'Command+Shift+Y' },
              description: 'Restored command',
            },
          },
          content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'], run_at: 'document_idle' }],
        }),
      },
      { name: 'options.html', data: '<!doctype html><title>Final fixture options</title>' },
      { name: 'content.js', data: 'document.documentElement.dataset.extensionInjected="yes";' },
    ]),
    { keys: [keyPair()] },
  );
  const crxPath = path.join(root, 'fixture.crx');
  await fs.writeFile(crxPath, signed.buffer);
  let app, page;
  const service = await createSyncService({
    directory: path.join(root, 'service'),
    masterKey: randomBytes(32),
    allowInsecureLoopback: true,
  });
  t.after(async () => {
    if (app) {
      await app
        .evaluate(({ dialog }) => {
          dialog.showMessageBoxSync = () => 1;
        })
        .catch(() => {});
      await app.close().catch(() => app.process().kill());
    }
    await service.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  });
  const f = {
    root,
    url,
    service,
    id: signed.id,
    get app() {
      return app;
    },
    get page() {
      return page;
    },
    invoke: (action, payload = {}) =>
      page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]),
    native: (expression) =>
      app.evaluate(
        ({ webContents }, { id, expression }) =>
          webContents
            .getAllWebContents()
            .find((wc) => wc.getURL() === `chrome-extension://${id}/options.html`)
            .executeJavaScript(expression),
        { id: signed.id, expression },
      ),
    document: (id, expression) =>
      app.evaluate(
        ({ webContents }, { id, expression }) => webContents.fromId(id).executeJavaScript(expression, true),
        { id, expression },
      ),
    async launch() {
      const env = {
        ...process.env,
        ZACRO_USER_DATA: path.join(root, 'browser'),
        ZACRO_SYNC_DEV_LOOPBACK: '1',
        ZACRO_FIXTURE_CRX: crxPath,
      };
      delete env.ELECTRON_RUN_AS_NODE;
      delete env.ZACRO_SYNC_URL;
      app = await electron.launch({
        args: [path.resolve(__dirname, '../fixtures/extensions/sync-browser.cjs')],
        env,
      });
      page = await app.firstWindow();
      await page.waitForFunction(() => !!window.zacro);
      await app.evaluate(({ dialog }) => {
        globalThis.reloadDecisions = 0;
        globalThis.reloadPrompts = 0;
        globalThis.extensionPrompts = 0;
        dialog.showMessageBox = async () => {
          globalThis.extensionPrompts++;
          return { response: 1 };
        };
        dialog.showMessageBoxSync = () => {
          globalThis.reloadPrompts++;
          return globalThis.reloadDecisions;
        };
      });
    },
    async restart() {
      await app.close();
      app = null;
      await f.launch();
    },
    async install() {
      return f.invoke('extension:install-store', { url: signed.id });
    },
    async options() {
      await f.invoke('extension:options', { id: signed.id });
      await expect.poll(() => f.native('typeof chrome.tabs?.query')).toBe('function');
    },
    async draft() {
      await f.invoke('navigate', { url });
      const id = await expect
        .poll(async () => (await f.native('chrome.tabs.query({active:true})'))[0]?.url)
        .toBe(url)
        .then(async () => (await f.native('chrome.tabs.query({active:true})'))[0].id);
      await expect
        .poll(() => f.document(id, 'document.documentElement.dataset.extensionInjected'))
        .toBe('yes');
      await f.document(
        id,
        'document.querySelector("#draft").value="keep my draft"; window.addEventListener("beforeunload", e=>{e.preventDefault();e.returnValue="Unsaved";}); undefined',
      );
      assert.equal(await f.document(id, 'navigator.userActivation.hasBeenActive'), true);
      return id;
    },
  };
  await f.launch();
  return f;
}

test(
  'R5 actual browser restart restores assigned command dispatch through the host input route',
  { timeout: 60000 },
  async (t) => {
    const f = await fixture(t);
    await f.install();
    for (const restarted of [false, true]) {
      if (restarted) await f.restart();
      await expect.poll(async () => (await f.invoke('state:get')).extensions[0]?.enabled).toBe(true);
      await f.options();
      await f.native(
        'globalThis.receivedCommands=[]; chrome.commands.onCommand.addListener(name=>receivedCommands.push(name)); true',
      );
      assert.equal((await f.invoke('state:get')).extensions[0].commands[0].status, 'assigned');
      // Exercise the registered browser input handler without claiming physical OS focus.
      const consumed = await f.app.evaluate(({ BrowserWindow }) => {
        let consumed = false;
        const shell = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().startsWith('file:'));
        shell.webContents.emit(
          'before-input-event',
          {
            preventDefault: () => {
              consumed = true;
            },
          },
          {
            type: 'keyDown',
            key: 'Y',
            shift: true,
            meta: process.platform === 'darwin',
            control: process.platform !== 'darwin',
          },
        );
        return consumed;
      });
      assert.equal(consumed, true, `command after restart=${restarted} must be consumed`);
      await expect.poll(() => f.native('receivedCommands')).toEqual(['fixture-command']);
    }
  },
);

test(
  'R3 duplicate native tabs.move preserves every tab and the unrelated draft view',
  { timeout: 45000 },
  async (t) => {
    const f = await fixture(t);
    await f.install();
    await f.options();
    const draftId = await f.draft();
    const extra = await f.native('chrome.tabs.create({active:false})');
    const before = (await f.invoke('state:get')).tabs;
    const result = await f.native(
      `chrome.tabs.move([${extra.id},${extra.id}],{index:0}).then(()=>({}),error=>({error:error.message}))`,
    );
    assert.match(result.error || '', /duplicate/i);
    assert.deepEqual((await f.invoke('state:get')).tabs, before);
    assert.equal(await f.document(draftId, 'document.querySelector("#draft").value'), 'keep my draft');
    assert.equal(await f.app.evaluate(() => globalThis.reloadPrompts), 0);
  },
);

for (const remote of [false, true])
  test(
    `R8 ${remote ? 'remote' : 'local'} uninstall retains a visible document warning and respects draft cancellation`,
    { timeout: 60000 },
    async (t) => {
      const f = await fixture(t);
      await f.install();
      await f.options();
      const draftId = await f.draft(),
        tabId = (await f.invoke('state:get')).activeTabId;
      await f.app.evaluate(({ dialog }) => {
        globalThis.extensionPrompts = 0;
        dialog.showMessageBox = async () => {
          globalThis.extensionPrompts++;
          return { response: 0 };
        };
      });
      if (remote) {
        const password = 'Synthetic final fix account password';
        await f.invoke('sync:configure', { endpoint: f.service.url });
        await f.invoke('sync:register', { username: 'final.native', password, deviceName: 'Browser' });
        const dataset = await f.invoke('sync:create-dataset', { name: 'Removal test' });
        await f.invoke('sync:link', {
          datasetId: dataset.id,
          libraryChoice: 'merge-local',
          settingsSync: false,
        });
        await f.invoke('sync:now');
        const request = async (route, body, token) => {
          const r = await fetch(f.service.url + '/v1' + route, {
            method: body ? 'POST' : 'GET',
            headers: {
              'content-type': 'application/json',
              ...(token ? { authorization: `Bearer ${token}` } : {}),
            },
            body: body ? JSON.stringify(body) : undefined,
          });
          assert.equal(r.status, 200);
          return r.json();
        };
        const session = await request('/sessions', {
          username: 'final.native',
          password,
          deviceName: 'Other device',
          platform: 'test',
        });
        const snapshot = await request(
          `/datasets/${dataset.id}/snapshot?settings=0`,
          null,
          session.accessToken,
        );
        await request(
          `/datasets/${dataset.id}/operations`,
          {
            epoch: dataset.epoch,
            operations: [
              {
                id: randomUUID(),
                kind: 'extension',
                extensionId: f.id,
                generation: snapshot.extensions[0].generation,
                baseRevision: snapshot.cursor,
                payload: { state: 'removed', source: { kind: 'web-store', id: f.id } },
              },
            ],
          },
          session.accessToken,
        );
        await f.invoke('sync:now');
      } else await f.invoke('extension:remove', { id: f.id });
      await expect.poll(async () => (await f.invoke('state:get')).extensions.length).toBe(0);
      assert.equal(await f.app.evaluate(() => globalThis.extensionPrompts), remote ? 0 : 1);
      let state = await f.invoke('state:get');
      assert.equal(
        state.extensionPageWarnings?.some((w) => w.tabId === tabId),
        true,
      );
      await expect(f.page.locator('[data-action="extension:reload-pages"]')).toBeVisible();
      await f.page.locator('[data-action="extension:reload-pages"]').evaluate((button) => button.click());
      await expect.poll(() => f.app.evaluate(() => globalThis.reloadPrompts)).toBe(1);
      assert.equal(await f.document(draftId, 'document.querySelector("#draft").value'), 'keep my draft');
      assert.equal((await f.invoke('state:get')).extensionPageWarnings.length, 1);
      await f.page.locator('[data-key="library"]').evaluate((button) => button.click());
      await f.page.locator('[data-key="panel-settings"]').evaluate((button) => button.click());
      await f.page
        .locator('summary')
        .filter({ hasText: 'Extensions' })
        .evaluate((summary) => summary.click());
      await f.page.locator('[data-panel="extensions"]').evaluate((button) => button.click());
      await expect(f.page.locator('#side-panel [data-action="extension:reload-pages"]')).toBeVisible();
      if (process.env.ZACRO_FINAL_WARNING_SCREENSHOT && !remote) {
        const image = await f.app.evaluate(async ({ BrowserWindow }) => {
          const shell = BrowserWindow.getAllWindows().find((window) =>
            window.webContents.getURL().startsWith('file:'),
          );
          return (await shell.capturePage()).toPNG().toString('base64');
        });
        await fs.writeFile(process.env.ZACRO_FINAL_WARNING_SCREENSHOT, Buffer.from(image, 'base64'));
      }
      await f.app.evaluate(() => {
        globalThis.reloadDecisions = 1;
      });
      await f.page
        .locator('#side-panel [data-action="extension:reload-pages"]')
        .evaluate((button) => button.click());
      await expect.poll(async () => (await f.invoke('state:get')).extensionPageWarnings.length).toBe(0);
      assert.equal(
        await f.document(draftId, 'document.documentElement.dataset.extensionInjected'),
        undefined,
      );
      await expect(f.page.locator('[data-action="extension:reload-pages"]')).toHaveCount(0);
    },
  );

test(
  'R7 real profile deletion purges the live client database while preserving the other profile',
  { timeout: 45000 },
  async (t) => {
    const f = await fixture(t);
    await f.install();
    await f.options();
    await f.native('chrome.storage.sync.set({deletedProfileSecret:"remove me"})');
    const other = await f.invoke('profile:create', { name: 'Keep local profile' });
    await f.install();
    await f.options();
    await f.native('chrome.storage.sync.set({keepOtherProfile:true})');
    await f.invoke('profile:delete', { id: 'default' });
    assert.equal(
      (await f.invoke('state:get')).profiles.some((p) => p.id === 'default'),
      false,
    );
    assert.deepEqual(await f.native('chrome.storage.sync.get(null)'), { keepOtherProfile: true });
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(path.join(f.root, 'browser', 'sync', 'client.sqlite'), { readOnly: true });
    const state = JSON.parse(db.prepare('SELECT value FROM state WHERE id=1').get().value);
    db.close();
    for (const areas of [state.areas, ...Object.values(state.localCopies || {})])
      assert.equal(
        Object.keys(areas).some((k) => JSON.parse(k)[1] === 'default'),
        false,
      );
    assert.equal(state.areas[JSON.stringify(['local', other.id, f.id])].values.keepOtherProfile, true);
  },
);
