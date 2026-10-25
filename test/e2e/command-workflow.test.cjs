'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-command-workflow-'));
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      `<!doctype html><title>Workflow ${request.url}</title><h1>Saved workflow evidence</h1><textarea id="draft"></textarea><p>${request.url}</p>`,
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let app, shell;
  const errors = [];
  const close = async () => {
    if (!app) return;
    const previous = app;
    app = null;
    await previous.close().catch(() => previous.process().kill());
  };
  t.after(async () => {
    await close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-command-workflow-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, [], 'No renderer errors during the command workflow');
  });
  const launch = async () => {
    const env = { ...process.env, ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    shell = await app.firstWindow();
    shell.on('pageerror', (error) => errors.push(error.message));
    await shell.waitForFunction(() => Boolean(window.zacro));
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
  };
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = (url, expression) =>
    app.evaluate(
      ({ webContents }, { url, expression }) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          ?.executeJavaScript(expression),
      { url, expression },
    );
  const key = (keyCode, modifiers = [], url = null) =>
    app.evaluate(
      ({ BrowserWindow, webContents }, { keyCode, modifiers, url }) => {
        const contents = url
          ? webContents.getAllWebContents().find((item) => item.getURL() === url)
          : BrowserWindow.getAllWindows()[0].webContents;
        if (!contents) throw new Error(`No shortcut target: ${url || 'shell'}`);
        contents.focus();
        contents.sendInputEvent({ type: 'keyDown', keyCode, modifiers });
        contents.sendInputEvent({ type: 'keyUp', keyCode, modifiers });
      },
      { keyCode, modifiers, url },
    );
  const submit = async (url) => {
    await expect(shell.locator('#command-input')).toBeFocused();
    await shell.locator('#command-input').fill(url);
    await shell.locator('#command-input').press('Enter');
    await expect.poll(() => guest(url, 'document.readyState')).toBe('complete');
    await expect(shell.getByRole('dialog')).toHaveCount(0);
  };
  await launch();
  return {
    get app() {
      return app;
    },
    get shell() {
      return shell;
    },
    directory,
    base,
    close,
    launch,
    invoke,
    state,
    guest,
    key,
    submit,
    mod: process.platform === 'darwin' ? 'meta' : 'control',
  };
}

test(
  'command opening is tabless; submission, empty Spaces and restored sessions keep their intended targets',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).tabs.length, 0);
    assert.equal((await b.state()).activeTabId, null);
    await expect(b.shell.locator('#newtab')).toBeHidden();
    await b.submit(`${b.base}/first`);
    const initial = (await b.state()).activeTabId;
    await b.guest(`${b.base}/first`, 'document.querySelector("textarea").value="Keep this draft"');
    await b.key('T', [b.mod], `${b.base}/first`);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).tabs.length, 1);
    assert.equal((await b.state()).activeTabId, initial);
    await b.shell.keyboard.press('Escape');
    assert.equal((await b.state()).tabs.length, 1);
    await b.key('T', [b.mod]);
    await b.submit(`${b.base}/second`);
    const second = (await b.state()).activeTabId;
    assert.notEqual(second, initial);
    assert.equal((await b.state()).tabs.length, 2);
    await b.key('L', [b.mod], `${b.base}/second`);
    await b.submit(`${b.base}/replacement`);
    assert.equal((await b.state()).tabs.length, 2);
    assert.equal((await b.state()).activeTabId, second);
    assert.equal(
      await b.guest(`${b.base}/first`, 'document.querySelector("textarea").value'),
      'Keep this draft',
    );
    const space = await b.invoke('space:create', { name: 'Empty Space' });
    await expect(b.shell.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).tabs.filter((tab) => tab.spaceId === space.id).length, 0);
    await b.submit(`${b.base}/space-page`);
    assert.equal((await b.state()).tabs.filter((tab) => tab.spaceId === space.id).length, 1);
    const saved = (await b.state()).activeTabId;
    await b.close();
    await b.launch();
    await expect.poll(() => b.guest(`${b.base}/space-page`, 'document.readyState')).toBe('complete');
    await expect(b.shell.getByRole('dialog')).toHaveCount(0);
    assert.equal((await b.state()).activeTabId, saved);
    await expect(b.shell.locator('#newtab')).toBeHidden();
    const home = await b.invoke('tab:create', { homePage: true });
    await expect(b.shell.locator('#newtab')).toBeVisible();
    assert.equal((await b.state()).tabs.find((tab) => tab.id === home.id).homePage, true);
    await expect(b.shell.locator('#command-input')).toHaveCount(0);
  },
);

test(
  'dragging a tab into empty favorites pins the same tab and survives restart',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/drag-pin`);
    const id = (await b.state()).activeTabId;
    await b.guest(`${b.base}/drag-pin`, 'document.querySelector("textarea").value="Pinned draft"');
    await b.shell
      .locator(`.tab-row[data-tab-id="${id}"]`)
      .dragTo(b.shell.locator('.favorites[data-drop-pinned]'));
    await expect.poll(async () => (await b.state()).tabs.find((tab) => tab.id === id)?.pinned).toBe(true);
    await expect(b.shell.locator(`.favorite[data-tab-id="${id}"]`)).toBeVisible();
    assert.equal((await b.state()).tabs.length, 1);
    assert.equal(
      await b.guest(`${b.base}/drag-pin`, 'document.querySelector("textarea").value'),
      'Pinned draft',
    );
    await b.close();
    await b.launch();
    await expect(b.shell.locator(`.favorite[data-tab-id="${id}"]`)).toBeVisible();
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).pinned, true);
  },
);

test(
  'Arc pin and Space keys, sidebar order and held recent-tab cycling use distinct navigation targets',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/one`);
    const first = (await b.state()).activeTabId;
    const records = [{ id: first }];
    for (const name of ['two', 'three', 'four']) {
      await new Promise((resolve) => setTimeout(resolve, 15));
      records.push(await b.invoke('tab:create', { url: `${b.base}/${name}` }));
    }
    const current = async () => (await b.state()).activeTabId;
    const release = (keyCode, modifiers = []) =>
      b.app.evaluate(
        ({ BrowserWindow, webContents }, { keyCode, modifiers }) => {
          (
            webContents.getFocusedWebContents() || BrowserWindow.getAllWindows()[0].webContents
          ).sendInputEvent({ type: 'keyUp', keyCode, modifiers });
        },
        { keyCode, modifiers },
      );
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[2].id);
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[1].id);
    await b.key('Tab', ['control', 'shift']);
    await expect.poll(current).toBe(records[2].id);
    await release('Shift', ['control']);
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[1].id);
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(first);
    await release('Control');
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[1].id);
    await release('Control');
    await b.key('D', [b.mod]);
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === records[1].id).pinned)
      .toBe(true);
    assert.equal((await b.state()).bookmarks.length, 0, 'Arc pin shortcut pins instead of bookmarking');
    await b.key('1', [b.mod]);
    await expect.poll(current).toBe(records[1].id);
    await b.key('Down', [b.mod, 'alt']);
    await expect.poll(current).toBe(first);
    const originalSpace = (await b.state()).activeSpaceId;
    const nextSpace = await b.invoke('space:create', { name: 'Second workflow' });
    await b.key('1', [process.platform === 'darwin' ? 'control' : 'alt']);
    await expect.poll(async () => (await b.state()).activeSpaceId).toBe(originalSpace);
    await b.key('Right', [b.mod, 'alt']);
    await expect.poll(async () => (await b.state()).activeSpaceId).toBe(nextSpace.id);
    await expect(b.shell.locator('#command-input')).toBeVisible();
    await b.shell.locator('#command-input').fill('/ short');
    await b.shell.locator('#command-input').press('Enter');
    await expect(b.shell.getByRole('dialog', { name: 'Keyboard shortcuts' })).toBeVisible();
  },
);

test(
  'shortcut rebinds persist, reject conflicts and work in shell and guest; Save Page writes real HTML',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const url = `${b.base}/save-evidence`;
    await b.submit(url);
    const catalog = (await b.state()).runtime.shortcuts;
    const sidebar = catalog.find((item) => item.defaultAccelerator === 'Mod+S');
    const command = catalog.find((item) => item.defaultAccelerator === 'Mod+T');
    assert(sidebar && command, 'Runtime exposes the editable shortcut catalog');
    await assert.rejects(
      () => b.invoke('shortcut:set', { id: sidebar.id, accelerator: command.accelerator }),
      /conflict|already|assigned|use/i,
    );
    assert.equal(
      (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      'Mod+S',
    );
    await b.invoke('shortcut:run', { id: 'shortcuts' });
    await expect(b.shell.getByRole('dialog', { name: 'Keyboard shortcuts' })).toBeVisible();
    await b.shell.locator(`[data-shortcut-record="${sidebar.id}"]`).click();
    await b.key('9', [b.mod, 'alt']);
    await expect
      .poll(
        async () => (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      )
      .toBe('Mod+Alt+9');
    await b.shell.keyboard.press('Escape');
    await b.key('9', [b.mod, 'alt']);
    await expect(b.shell.locator('#sidebar')).toBeHidden();
    await b.guest(
      url,
      'document.querySelector("textarea").value="Shortcut draft";document.querySelector("textarea").focus()',
    );
    await b.key('9', [b.mod, 'alt'], url);
    await expect(b.shell.locator('#sidebar')).toBeVisible();
    assert.equal(await b.guest(url, 'document.querySelector("textarea").value'), 'Shortcut draft');
    await b.close();
    await b.launch();
    await expect.poll(() => b.guest(url, 'document.readyState')).toBe('complete');
    assert.equal(
      (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      'Mod+Alt+9',
    );
    await b.invoke('shortcut:run', { id: 'shortcuts' });
    await b.shell.locator(`[data-shortcut-reset="${sidebar.id}"]`).click();
    await expect
      .poll(
        async () => (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      )
      .toBe('Mod+S');
    await b.shell.keyboard.press('Escape');
    await b.key('S', [b.mod], url);
    await expect(b.shell.locator('#sidebar')).toBeHidden();
    await b.key('S', [b.mod]);
    await expect(b.shell.locator('#sidebar')).toBeVisible();
    const savedPath = path.join(b.directory, 'saved-page.html');
    await b.app.evaluate(({ dialog }, savedPath) => {
      globalThis.saveDialogCalls = 0;
      dialog.showSaveDialog = async () => {
        globalThis.saveDialogCalls++;
        return { canceled: false, filePath: savedPath };
      };
    }, savedPath);
    await b.key('S', [b.mod, 'shift'], url);
    await expect
      .poll(async () => fs.readFile(savedPath, 'utf8').catch(() => ''))
      .toContain('Saved workflow evidence');
    assert.equal(await b.app.evaluate(() => globalThis.saveDialogCalls), 1);
    assert.equal((await b.state()).tabs.length, 1);
    const savedBytes = await fs.readFile(savedPath);
    await b.app.evaluate(({ dialog }) => {
      dialog.showSaveDialog = async () => ({ canceled: true });
    });
    await b.invoke('save-page');
    assert.deepEqual(
      await fs.readFile(savedPath),
      savedBytes,
      'Cancelling Save Page preserves the existing file',
    );
  },
);
