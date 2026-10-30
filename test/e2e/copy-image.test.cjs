'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'Copy image copies raster pixels from pages, split panes and Peek without navigating',
  { timeout: 60000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-copy-image-'));
    const images = new Map();
    let requests = 0;
    const server = http.createServer((request, response) => {
      if (images.has(request.url)) {
        response.writeHead(200, { 'Content-Type': 'image/png' });
        response.end(images.get(request.url));
      } else if (/^\/(red|blue|peek)$/.test(request.url)) {
        requests++;
        response.writeHead(200, { 'Content-Type': 'text/html' });
        response.end(
          `<title>Copy ${request.url}</title><link rel="icon" href="${request.url}.png"><style>body{margin:20px}img{width:120px;height:120px}</style><img src="${request.url}.png"><p>Keep this document</p>`,
        );
      } else {
        response.writeHead(404);
        response.end();
      }
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const env = { ...process.env, ZACRO_USER_DATA: directory, ZACRO_SKIP_ONBOARDING: '1' };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    t.after(async () => {
      await app
        .evaluate(async ({ clipboard }) => {
          if (!globalThis.savedCopyClipboard) return;
          if (globalThis.savedCopyClipboard?.length) await clipboard.write(globalThis.savedCopyClipboard);
          else clipboard.clear();
        })
        .catch(() => {});
      await app.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const generated = await app.evaluate(async ({ nativeImage, clipboard, ClipboardItem, Menu }) => {
      globalThis.savedCopyClipboard = await Promise.all(
        (await clipboard.read()).map(
          async (item) =>
            new ClipboardItem(
              Object.fromEntries(
                await Promise.all(item.types.map(async (type) => [type, await item.getType(type)])),
              ),
            ),
        ),
      );
      const build = Menu.buildFromTemplate;
      Menu.buildFromTemplate = (items) => {
        const menu = build(items);
        if (items.some((item) => item.label === 'Copy image')) globalThis.imageContextItems = items;
        menu.popup = () => {};
        return menu;
      };
      return Object.fromEntries(
        Object.entries({ red: [0, 0, 255, 255], blue: [255, 0, 0, 255], peek: [0, 255, 0, 255] }).map(
          ([name, color]) => {
            const bitmap = Buffer.alloc(8 * 8 * 4);
            for (let i = 0; i < bitmap.length; i += 4) Buffer.from(color).copy(bitmap, i);
            return [
              name,
              nativeImage.createFromBitmap(bitmap, { width: 8, height: 8 }).toPNG().toString('base64'),
            ];
          },
        ),
      );
    });
    for (const [name, png] of Object.entries(generated))
      images.set(`/${name}.png`, Buffer.from(png, 'base64'));
    const shell = await app.firstWindow();
    await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
    if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const copy = async (name, expected) => {
      const url = `${base}/${name}`;
      await expect
        .poll(() =>
          app.evaluate(
            ({ webContents }, url) =>
              webContents
                .getAllWebContents()
                .find((wc) => wc.getURL() === url)
                ?.executeJavaScript('document.querySelector("img")?.naturalWidth'),
            url,
          ),
        )
        .toBe(8);
      const before = requests;
      const id = await app.evaluate(async ({ webContents, clipboard }, url) => {
        const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
        globalThis.imageContextItems = null;
        await clipboard.writeText('Zacro image-copy acceptance');
        wc.focus();
        for (const type of ['mouseDown', 'mouseUp'])
          wc.sendInputEvent({ type, x: 40, y: 40, button: 'right', clickCount: 1 });
        return wc.id;
      }, url);
      await expect
        .poll(() =>
          app.evaluate(() => globalThis.imageContextItems?.some((item) => item.label === 'Copy image')),
        )
        .toBe(true);
      const labels = await app.evaluate(() => globalThis.imageContextItems.map((item) => item.label));
      assert(labels.includes('Save image as…'));
      assert(labels.includes('Copy image address'));
      await app.evaluate(() =>
        globalThis.imageContextItems.find((item) => item.label === 'Copy image').click(),
      );
      await expect.poll(() => app.evaluate(({ clipboard }) => clipboard.has('image/png'))).toBe(true);
      assert.deepEqual(
        await app.evaluate(async ({ clipboard, nativeImage }) => {
          const items = await clipboard.read();
          const item = items.find((entry) => entry.types.includes('image/png'));
          const blob = await item.getType('image/png');
          const image = nativeImage.createFromBuffer(Buffer.from(await blob.arrayBuffer()));
          return { size: image.getSize(), pixel: [...image.toBitmap().subarray(0, 4)] };
        }),
        { size: { width: 8, height: 8 }, pixel: expected },
      );
      assert.equal(requests, before);
      assert.equal(
        await app.evaluate(
          ({ webContents }, url) => webContents.getAllWebContents().find((wc) => wc.getURL() === url)?.id,
          url,
        ),
        id,
      );
    };
    const first = await invoke('tab:create', { url: `${base}/red` });
    await invoke('tab:favorite', { id: first.id, favorite: true });
    await copy('red', [0, 0, 255, 255]);
    const favorite = shell.locator(`[data-key="pin-${first.id}"]`);
    await expect
      .poll(() => favorite.evaluate((tile) => tile.style.getPropertyValue('--favorite-logo-color')))
      .toBe('#ff0000');
    const results = path.resolve(__dirname, '../../test-results/0.10.2');
    await fs.mkdir(results, { recursive: true });
    await favorite.screenshot({ path: path.join(results, 'favorite-logo-accent.png') });
    const second = await invoke('tab:create', { url: `${base}/blue` });
    await invoke('tab:activate', { id: first.id });
    await invoke('split:toggle', { id: second.id });
    await copy('blue', [255, 0, 0, 255]);
    await invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(async () => (await invoke('state:get')).runtime.peek?.phase).toBe('open');
    await copy('peek', [0, 255, 0, 255]);
    await invoke('peek:close');
    await invoke('split:unsplit');
    await invoke('tab:create', { url: 'zacro://newtab', homePage: true });
    if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
    const workspace = shell.locator('#workspace');
    await expect(workspace).toHaveAttribute('data-empty', 'true');
    await expect(workspace).toHaveCSS('outline-style', 'none');
    await expect(workspace).toHaveCSS('border-top-width', '0px');
    await expect(workspace).not.toHaveCSS('box-shadow', 'none');
    const background = await workspace.evaluate((pane) => getComputedStyle(pane).backgroundImage);
    assert(background.includes('linear-gradient'), 'Empty pages paint the opaque Space gradient');
    const current = await invoke('state:get');
    const space = current.spaces.find((item) => item.id === current.activeSpaceId);
    await invoke('space:create', { name: 'Empty Space', color: space.color, theme: space.theme });
    await expect.poll(async () => (await invoke('state:get')).activeTabId).toBe(null);
    await expect(shell.locator('[data-key="space-picker"]')).toHaveAttribute('title', /^Empty Space/);
    await expect(shell.locator('#command-input')).toBeVisible();
    await shell.keyboard.press('Escape');
    await expect(shell.locator('#command-input')).toHaveCount(0);
    // Capture settled geometry after the Space crossfade, including the saved
    // Favorite which remains available in an otherwise empty Space.
    await shell.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          .filter((animation) => animation.effect?.getTiming().iterations !== Infinity)
          .map((animation) => animation.finished.catch(() => {})),
      ),
    );
    const geometry = await favorite.evaluate((tile) => {
      const parent = tile.closest('.favorites');
      const rect = (node) => {
        const { top, bottom, height } = node.getBoundingClientRect();
        return { top, bottom, height };
      };
      return {
        tile: rect(tile),
        scroller: rect(parent),
        scrollTop: parent.scrollTop,
        scrollHeight: parent.scrollHeight,
      };
    });
    await fs.writeFile(path.join(results, 'empty-favorite-geometry.json'), JSON.stringify(geometry, null, 2));
    await shell.screenshot({ path: path.join(results, 'opaque-empty-pane.png') });
    assert(
      geometry.tile.bottom <= geometry.scroller.bottom,
      'A settled Favorite must not be clipped by its scroller',
    );
  },
);
