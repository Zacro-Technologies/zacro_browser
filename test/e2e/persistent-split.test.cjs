'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'saved split groups stay joined across tab and Space changes, restart and explicit unsplit',
  { timeout: 60000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-persistent-split-'));
    const server = http.createServer((req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end(`<title>Split ${req.url}</title><h1>${req.url}</h1><textarea>Keep my split page</textarea>`);
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    let app;
    const errors = [];
    t.after(async () => {
      if (app) await app.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      assert.deepEqual(errors, []);
    });
    const launch = async () => {
      const env = { ...process.env, ZACRO_USER_DATA: directory, ZACRO_SKIP_ONBOARDING: '1' };
      delete env.ELECTRON_RUN_AS_NODE;
      app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
      const shell = await app.firstWindow();
      shell.on('pageerror', (error) => errors.push(error.message));
      await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
      if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
      const invoke = (action, payload = {}) =>
        shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
      return { shell, invoke, state: () => invoke('state:get') };
    };
    let b = await launch();
    const first = await b.invoke('tab:create', { url: `${base}/a` });
    const second = await b.invoke('tab:create', { url: `${base}/b` });
    const third = await b.invoke('tab:create', { url: `${base}/c` });
    await b.invoke('tab:activate', { id: first.id });
    await b.invoke('split:toggle', { id: second.id });
    await expect.poll(async () => (await b.state()).runtime.splitPair).toEqual([first.id, second.id]);
    const groupId = (await b.state()).splitGroups[0].id;
    const group = () => b.shell.locator(`[data-split-id="${groupId}"]`);
    await expect(group()).toBeVisible();
    const panes = () =>
      app.evaluate(
        ({ BrowserWindow }, urls) =>
          BrowserWindow.getAllWindows()[0]
            .contentView.children.filter((view) => urls.includes(view.webContents?.getURL()))
            .map((view) => ({ id: view.webContents.id, url: view.webContents.getURL(), ...view.getBounds() }))
            .sort((a, b) => a.x - b.x),
        [`${base}/a`, `${base}/b`],
      );
    await expect.poll(async () => (await panes()).length).toBe(2);
    const before = await panes();
    await app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((page) => page.getURL() === url)
          .executeJavaScript('window.splitDraft = "kept"'),
      `${base}/a`,
    );
    const divider = b.shell.getByRole('separator', { name: 'Resize split view', exact: true });
    await expect(divider).toBeVisible();
    await expect(b.shell.locator('#workspace')).toHaveCSS('outline-style', 'none');
    await expect(b.shell.locator('#workspace')).toHaveCSS('border-top-width', '0px');
    const handle = await divider.boundingBox();
    await b.shell.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
    await b.shell.mouse.down();
    await b.shell.mouse.move(handle.x + 123, handle.y + handle.height / 2, { steps: 12 });
    await expect.poll(async () => (await panes())[0].width).toBeGreaterThan(before[0].width + 100);
    await b.shell.mouse.up();
    await expect.poll(async () => (await b.state()).splitGroups[0].ratio).toBeGreaterThan(0.55);
    const savedRatio = (await b.state()).splitGroups[0].ratio;
    const originalSize = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      const original = window.getContentSize();
      window.setContentSize(800, original[1]);
      return original;
    });
    await b.invoke('split:resize', { id: groupId, ratio: 0.1 });
    await expect.poll(async () => (await panes())[0].width).toBe(160);
    await expect.poll(async () => Number(await divider.getAttribute('aria-valuemin'))).toBeGreaterThan(10);
    await expect
      .poll(async () => {
        const current = await divider.getAttribute('aria-valuenow');
        return current === (await divider.getAttribute('aria-valuemin'));
      })
      .toBe(true);
    const clamped = await panes();
    const visibleRatio = clamped[0].width / (clamped[0].width + clamped[1].width);
    await divider.press('ArrowRight');
    await expect.poll(async () => (await panes())[0].width).toBeGreaterThan(160);
    const keyboardRatio = (await b.state()).splitGroups[0].ratio;
    assert(
      Math.abs(keyboardRatio - visibleRatio - 0.02) < 0.004,
      `ArrowRight moves from the visible minimum width, not the offscreen saved ratio (${visibleRatio} to ${keyboardRatio})`,
    );
    await app.evaluate(
      ({ BrowserWindow }, size) => BrowserWindow.getAllWindows()[0].setContentSize(...size),
      originalSize,
    );
    await b.invoke('split:resize', { id: groupId, ratio: savedRatio });
    assert.deepEqual(
      (await panes()).map((pane) => pane.id),
      before.map((pane) => pane.id),
    );
    assert.equal(
      await app.evaluate(
        ({ webContents }, url) =>
          webContents
            .getAllWebContents()
            .find((page) => page.getURL() === url)
            .executeJavaScript('window.splitDraft'),
        `${base}/a`,
      ),
      'kept',
    );
    await b.invoke('tab:activate', { id: third.id });
    await expect.poll(async () => (await b.state()).runtime.splitPair).toBeNull();
    await expect(group()).toBeVisible();
    await group().locator(`[data-action="tab:activate"][data-id="${first.id}"]`).click();
    await expect.poll(async () => (await b.state()).runtime.splitPair).toEqual([first.id, second.id]);
    assert.equal((await b.state()).splitGroups[0].ratio, savedRatio);
    const space = await b.invoke('space:create', { name: 'Away' });
    await expect.poll(async () => (await b.state()).activeSpaceId).toBe(space.id);
    await expect.poll(async () => (await b.state()).runtime.splitPair).toBeNull();
    await b.invoke('space:activate', { id: first.spaceId });
    await expect.poll(async () => (await b.state()).runtime.splitPair).toEqual([first.id, second.id]);
    await app.close();
    app = null;
    b = await launch();
    await expect.poll(async () => (await b.state()).runtime.splitPair).toEqual([first.id, second.id]);
    assert.equal((await b.state()).splitGroups[0].ratio, savedRatio);
    await expect(group()).toBeVisible();
    await b.invoke('tab:activate', { id: third.id });
    await group().locator(`[data-action="tab:activate"][data-id="${first.id}"]`).click({ button: 'right' });
    await b.shell.getByRole('button', { name: 'Unsplit tabs', exact: true }).click();
    await expect.poll(async () => (await b.state()).splitGroups.length).toBe(0);
    assert((await b.state()).tabs.some((tab) => tab.id === first.id));
    assert((await b.state()).tabs.some((tab) => tab.id === second.id));
    await expect(group()).toHaveCount(0);
  },
);
