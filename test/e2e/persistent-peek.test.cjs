'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'Peek stays with each source across tabs, Spaces and restart until dismissed or expanded',
  { timeout: 60000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-persistent-peek-'));
    const server = http.createServer((req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end(
        `<title>Page ${req.url}</title><button id="activate">Interact</button><textarea id="draft"></textarea><a href="/destination">Next</a>`,
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    let app;
    const errors = [];
    t.after(async () => {
      if (app) {
        await app.evaluate(({ dialog }) => {
          dialog.showMessageBoxSync = () => 1;
        });
        await app.close();
      }
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
      const guest = (url, code) =>
        app.evaluate(
          ({ webContents }, { url, code }) => {
            const page = webContents.getAllWebContents().find((item) => item.getURL() === url);
            return page ? page.executeJavaScript(code, true) : null;
          },
          { url, code },
        );
      return { shell, invoke, guest, state: () => invoke('state:get') };
    };
    let b = await launch();
    const first = await b.invoke('tab:create', { url: `${base}/source-one` });
    await b.invoke('peek:open', { url: `${base}/preview-one` });
    await expect.poll(() => b.guest(`${base}/preview-one`, 'document.readyState')).toBe('complete');
    await expect.poll(async () => (await b.state()).runtime.peek?.phase).toBe('open');
    const firstPreviewId = (await b.state()).runtime.peek.id;
    await b.guest(
      `${base}/preview-one`,
      'window.liveMarker="kept";document.querySelector("#draft").value="Do not discard my draft";history.pushState({},"","/preview-one#read");undefined',
    );
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === first.id).savedPeek?.url)
      .toBe(`${base}/preview-one#read`);
    await b.guest(
      `${base}/preview-one#read`,
      'window.onbeforeunload=event=>{event.preventDefault();event.returnValue="unsaved"};undefined',
    );
    await app.evaluate(({ dialog }) => {
      globalThis.peekUnloadPrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.peekUnloadPrompts++;
        return 0;
      };
    });
    const second = await b.invoke('tab:create', { url: `${base}/source-two` });
    assert.equal((await b.state()).runtime.peek, null);
    assert.equal(await app.evaluate(() => globalThis.peekUnloadPrompts), 0);
    assert.equal(await b.guest(`${base}/preview-one#read`, 'window.liveMarker'), 'kept');
    const detached = await app.evaluate(
      ({ BrowserWindow }, url) =>
        !BrowserWindow.getAllWindows()[0].contentView.children.some(
          (view) => view.webContents?.getURL() === url,
        ),
      `${base}/preview-one#read`,
    );
    assert(detached, 'A parked preview must not intercept the new tab');
    await b.invoke('peek:open', { url: `${base}/preview-two` });
    await expect.poll(() => b.guest(`${base}/preview-two`, 'document.readyState')).toBe('complete');
    await b.invoke('tab:activate', { id: first.id });
    await expect.poll(async () => (await b.state()).runtime.peek?.id).toBe(firstPreviewId);
    assert.equal(
      await b.guest(`${base}/preview-one#read`, 'document.querySelector("#draft").value'),
      'Do not discard my draft',
    );
    const away = await b.invoke('space:create', { name: 'Away' });
    assert.equal((await b.state()).activeSpaceId, away.id);
    assert.equal((await b.state()).runtime.peek, null);
    await b.invoke('space:activate', { id: first.spaceId });
    await expect.poll(async () => (await b.state()).runtime.peek?.id).toBe(firstPreviewId);
    assert.equal(await app.evaluate(() => globalThis.peekUnloadPrompts), 0);
    // Explicit dismissal still respects the preview document's unload decision.
    assert.equal(await b.invoke('peek:close'), false);
    assert.equal(await app.evaluate(() => globalThis.peekUnloadPrompts), 1);
    assert.equal(
      (await b.state()).tabs.find((tab) => tab.id === first.id).savedPeek.url,
      `${base}/preview-one#read`,
    );
    await b.guest(`${base}/preview-one#read`, 'window.onbeforeunload=null;undefined');
    await app.close();
    app = null;
    b = await launch();
    await expect.poll(async () => (await b.state()).runtime.peek?.url).toBe(`${base}/preview-one#read`);
    await b.invoke('tab:activate', { id: second.id });
    await expect.poll(async () => (await b.state()).runtime.peek?.url).toBe(`${base}/preview-two`);
    await b.invoke('peek:promote');
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).savedPeek, undefined);
    await b.invoke('tab:activate', { id: first.id });
    await b.invoke('peek:close');
    assert.equal((await b.state()).tabs.find((tab) => tab.id === first.id).savedPeek, undefined);
    await b.invoke('peek:open', { url: `${base}/preview-close` });
    await b.invoke('tab:activate', { id: second.id });
    await b.invoke('tab:close', { id: first.id });
    assert(!(await b.state()).tabs.some((tab) => tab.id === first.id));
    assert.equal((await b.state()).archive.find((tab) => tab.id === first.id).savedPeek, undefined);
    await expect.poll(() => b.guest(`${base}/preview-close`, 'true')).toBe(null);
  },
);
