'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'native window glass preserves opaque live pages and restores Space material after preview',
  { timeout: 60000, skip: !['win32', 'darwin'].includes(process.platform) },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-window-material-'));
    let requests = 0;
    const server = http.createServer((_request, response) => {
      requests++;
      response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
      response.end(
        '<!doctype html><title>Window material fixture</title><style>body{background:white;color:black}</style><textarea id="draft"></textarea>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/`;
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    let app;
    t.after(async () => {
      if (app) await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-window-material-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    const shell = await app.firstWindow();
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const state = () => invoke('state:get');
    await invoke('navigate', { url });
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, url) =>
            webContents.getAllWebContents().find((contents) => contents.getURL() === url)?.id,
          url,
        ),
      )
      .toBeTruthy();
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, url) =>
            webContents
              .getAllWebContents()
              .find((contents) => contents.getURL() === url)
              ?.executeJavaScript('document.readyState'),
          url,
        ),
      )
      .toBe('complete');
    const original = await app.evaluate(async ({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      await contents.executeJavaScript('document.getElementById("draft").value="Retained material draft"');
      return { id: contents.id, dpr: await contents.executeJavaScript('devicePixelRatio') };
    }, url);
    const firstState = await state();
    const spaceId = firstState.activeSpaceId;
    assert.equal(firstState.runtime.windowMaterial.enabled, false);
    await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      globalThis.materialCalls = [];
      const name = process.platform === 'darwin' ? 'setVibrancy' : 'setBackgroundMaterial';
      const original = window[name].bind(window);
      window[name] = (...args) => {
        globalThis.materialCalls.push(args[0]);
        return original(...args);
      };
    });
    const preview = await invoke('window:material-preview', { spaceId, opacity: 40 });
    const afterPreview = await state();
    assert.equal(preview.requestedOpacity, 40);
    assert.equal(afterPreview.spaces.find((space) => space.id === spaceId).theme.opacity, 100);
    if (preview.enabled) {
      assert.equal(preview.type, process.platform === 'darwin' ? 'vibrancy' : 'acrylic');
      assert.equal(preview.opacity, 40);
      assert.deepEqual(await app.evaluate(() => globalThis.materialCalls), [
        process.platform === 'darwin' ? 'under-window' : 'acrylic',
      ]);
    } else t.diagnostic(`Native material stayed opaque: ${preview.reason}`);
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].getOpacity()),
      1,
      'Window opacity must not fade text or webpages',
    );
    await invoke('window:material-preview', { clear: true });
    assert.equal((await state()).runtime.windowMaterial.enabled, false);
    const transparent = await invoke('window:material-preview', { spaceId, opacity: 0 });
    assert.equal(transparent.requestedOpacity, 0);
    if (transparent.enabled) assert.equal(transparent.opacity, 0);
    assert.equal(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].getOpacity()), 1);
    await invoke('window:material-preview', { clear: true });
    await invoke('space:update', { id: spaceId, theme: { opacity: 55 } });
    assert.equal((await state()).runtime.windowMaterial.requestedOpacity, 55);
    await invoke('window:material-preview', { spaceId, opacity: 40 });
    const nextSpace = await invoke('space:create', { name: 'Opaque neighbor', theme: { opacity: 100 } });
    await expect.poll(async () => (await state()).runtime.windowMaterial.enabled).toBe(false);
    await assert.rejects(invoke('window:material-preview', { spaceId, opacity: 40 }), /Space changed/);
    await invoke('space:activate', { id: spaceId });
    assert.equal(
      (await state()).runtime.windowMaterial.requestedOpacity,
      55,
      'Space switches cancel previews',
    );
    assert.notEqual(nextSpace.id, spaceId);
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(820, 620));
    const retained = await app.evaluate(async ({ webContents }, original) => {
      const contents = webContents.fromId(original.id);
      return {
        id: contents.id,
        draft: await contents.executeJavaScript('document.getElementById("draft").value'),
        dpr: await contents.executeJavaScript('devicePixelRatio'),
        background: await contents.executeJavaScript('getComputedStyle(document.body).backgroundColor'),
      };
    }, original);
    assert.deepEqual(retained, {
      id: original.id,
      draft: 'Retained material draft',
      dpr: original.dpr,
      background: 'rgb(255, 255, 255)',
    });
    assert(requests <= 2, 'Changing material never reloads the page (one optional favicon request)');

    await shell.locator(`.space-dot[data-id="${spaceId}"]`).click({ button: 'right' });
    await shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    await shell.locator('input[name="theme-opacity"]').evaluate((input) => {
      input.value = '40';
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await expect.poll(async () => (await state()).runtime.windowMaterial.requestedOpacity).toBe(40);
    await shell.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    );
    // Exercise renderer opaque fallback with host status fixtures. These do
    // not pretend to change the user's real operating-system preferences.
    const previewState = await state();
    for (const reason of ['reduced-transparency', 'high-contrast', 'native-error', 'unsupported-platform']) {
      const status = structuredClone(previewState);
      status.runtime.windowMaterial = {
        ...status.runtime.windowMaterial,
        supported: reason !== 'unsupported-platform',
        enabled: false,
        type: 'opaque',
        opacity: 100,
        reason,
      };
      await app.evaluate(
        ({ BrowserWindow }, state) => BrowserWindow.getAllWindows()[0].webContents.send('zacro:state', state),
        status,
      );
      await expect(shell.locator('html')).toHaveAttribute('data-window-material', 'opaque');
      assert.equal(
        await shell.evaluate(() => document.documentElement.style.getPropertyValue('--space-opacity')),
        '100%',
      );
    }
    await shell.keyboard.press('Escape');
    await expect.poll(async () => (await state()).runtime.windowMaterial.requestedOpacity).toBe(55);
    assert.equal(
      (await state()).spaces.find((space) => space.id === spaceId).theme.opacity,
      55,
      'Cancelling the renderer preview restores the saved material',
    );
    await invoke('space:update', { id: spaceId, theme: { opacity: 100 } });
    await expect.poll(async () => (await state()).runtime.windowMaterial.requestedOpacity).toBe(100);
    const lease = { token: 'material-test-first', fromId: spaceId, toId: nextSpace.id, opacity: 0 };
    await invoke('window:space-material-transition', lease);
    assert.equal((await state()).runtime.windowMaterial.requestedOpacity, 0);
    await invoke('space:activate', { id: nextSpace.id });
    assert.equal(
      (await state()).runtime.windowMaterial.requestedOpacity,
      0,
      'Native material remains available across activation until the visual transition releases it',
    );
    await invoke('window:space-material-transition', { ...lease, token: 'material-test-next', opacity: 30 });
    await invoke('window:space-material-transition', { clear: true, token: lease.token });
    assert.equal(
      (await state()).runtime.windowMaterial.requestedOpacity,
      30,
      'Stale completion cannot end a newer lease',
    );
    await invoke('window:space-material-transition', { clear: true, token: 'material-test-next' });
    assert.equal((await state()).runtime.windowMaterial.requestedOpacity, 100);
    await invoke('window:space-material-transition', lease);
    const third = await invoke('space:create', { name: 'Outside transition', theme: { opacity: 100 } });
    await expect.poll(async () => (await state()).runtime.windowMaterial.requestedOpacity).toBe(100);
    await assert.rejects(invoke('window:space-material-transition', lease), /no longer current/);
    assert.equal((await state()).activeSpaceId, third.id);
    assert.equal(
      await app.evaluate(({ webContents }, id) => webContents.fromId(id)?.id, original.id),
      original.id,
      'The material lease never replaces website contents',
    );
    for (const space of (await state()).spaces)
      assert.equal(space.theme.opacity, 100, 'Leases never persist');
  },
);
