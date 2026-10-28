'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-chrome-resize-'));
  let pageRequests = 0;
  const server = http.createServer((request, response) => {
    if (request.url === '/fixture') pageRequests++;
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      '<!doctype html><title>Resize fixture</title><style>body{margin:0;background:#d4e3dc;min-height:1800px}textarea{margin:24px}</style><textarea id="draft"></textarea><p>Living page</p>',
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/fixture`;
  const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  let app, child;
  const close = async () => {
    if (!app) return;
    let timeout;
    await Promise.race([
      app.close().catch(() => {}),
      new Promise((resolve) => {
        timeout = setTimeout(resolve, 6000);
      }),
    ]);
    clearTimeout(timeout);
    if (child.exitCode === null) child.kill('SIGKILL');
    app = null;
  };
  t.after(async () => {
    await close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(directory).startsWith('zacro-chrome-resize-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  });
  const launch = async () => {
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 30000 });
    child = app.process();
    const shell = await app.firstWindow();
    await shell.waitForFunction(() => Boolean(window.zacro));
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const state = () => invoke('state:get');
    const windowSize = async (width, height) => {
      const size = await app.evaluate(
        ({ BrowserWindow }, { width, height }) => {
          const win = BrowserWindow.getAllWindows()[0];
          win.setContentSize(width, height);
          return win.getContentSize();
        },
        { width, height },
      );
      await expect.poll(() => shell.evaluate(() => [innerWidth, innerHeight])).toEqual(size);
      return size;
    };
    const guest = (expression) =>
      app.evaluate(
        ({ webContents }, { url, expression }) => {
          const page = webContents.getAllWebContents().find((contents) => contents.getURL() === url);
          return page ? page.executeJavaScript(expression) : null;
        },
        { url, expression },
      );
    const native = () =>
      app.evaluate(async ({ BrowserWindow }, url) => {
        const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
          (item) => item.webContents?.getURL() === url,
        );
        if (!view) return null;
        return {
          id: view.webContents.id,
          bounds: view.getBounds(),
          zoom: view.webContents.getZoomFactor(),
          page: await view.webContents.executeJavaScript(
            '({dpr:devicePixelRatio,width:innerWidth,height:innerHeight,marker:window.resizeMarker,draft:document.getElementById("draft").value})',
          ),
        };
      }, url);
    const aligned = async () => {
      await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
      await expect(shell.locator('#app')).toHaveAttribute('data-panel-animating', 'false');
      let result;
      await expect
        .poll(async () => {
          const rectangle = await shell.locator('#workspace').boundingBox();
          result = await native();
          return Boolean(
            rectangle &&
            result &&
            ['x', 'y', 'width', 'height'].every((key) => Math.round(rectangle[key]) === result.bounds[key]),
          );
        })
        .toBe(true);
      return result;
    };
    const openLibrary = async () => {
      await shell.getByRole('button', { name: 'Library', exact: true }).click();
      await shell.locator('#library-menu [data-key="panel-bookmarks"]').click();
      await expect(shell.locator('#side-panel')).toBeVisible();
      await aligned();
    };
    const navigate = async () => {
      await invoke('navigate', { url });
      await expect.poll(() => guest('document.readyState')).toBe('complete');
      await aligned();
    };
    return { shell, invoke, state, windowSize, guest, native, aligned, openLibrary, navigate };
  };
  return { launch, close, pageRequests: () => pageRequests };
}

test(
  'sidebar and Library drags keep native pages sharp and alive while persisting chosen widths across restart',
  { timeout: 60000 },
  async (t) => {
    const session = await fixture(t);
    let browser = await session.launch();
    await browser.windowSize(1320, 850);
    await browser.navigate();
    await browser.guest(
      'window.resizeMarker="live-document";document.getElementById("draft").value="Keep my draft";undefined',
    );
    const original = await browser.native();
    const originalRequests = session.pageRequests();
    const retained = async () => {
      const current = await browser.aligned();
      assert.equal(current.id, original.id, 'a drag must retain the original WebContents');
      assert.equal(current.zoom, original.zoom);
      assert.equal(
        current.page.dpr,
        original.page.dpr,
        'a drag must not resample the page at another resolution',
      );
      assert.equal(current.page.marker, 'live-document');
      assert.equal(current.page.draft, 'Keep my draft');
      assert.equal(current.page.width, current.bounds.width);
      assert.equal(current.page.height, current.bounds.height);
      assert.equal(session.pageRequests(), originalRequests, 'rail changes do not reload the document');
    };
    const drag = async (kind, widths) => {
      const handle = browser.shell.locator(`#${kind}-resizer`);
      await expect(handle).toBeVisible();
      const rectangle = await handle.boundingBox();
      const start = Number(await handle.getAttribute('aria-valuenow'));
      const saved = (await browser.state()).settings[`${kind}Width`];
      const point = { x: rectangle.x + rectangle.width / 2, y: rectangle.y + 90 };
      await browser.shell.mouse.move(point.x, point.y);
      await browser.shell.mouse.down();
      await expect(browser.shell.locator('#app')).toHaveAttribute('data-chrome-resizing', 'true');
      for (const width of widths) {
        await browser.shell.mouse.move(point.x + (width - start) * (kind === 'sidebar' ? 1 : -1), point.y, {
          steps: 3,
        });
        await expect(handle).toHaveAttribute('aria-valuenow', String(width));
        assert.equal(
          (await browser.state()).settings[`${kind}Width`],
          saved,
          'live drag is not committed until release',
        );
        await retained();
      }
      await browser.shell.mouse.up();
      await expect.poll(async () => (await browser.state()).settings[`${kind}Width`]).toBe(widths.at(-1));
      await expect(browser.shell.locator('#app')).not.toHaveAttribute('data-chrome-resizing', 'true');
      await retained();
    };
    await drag('sidebar', [250, 286, 318]);
    await browser.openLibrary();
    await retained();
    await drag('panel', [370, 412, 452]);
    await session.close();
    browser = await session.launch();
    const restarted = await browser.state();
    assert.equal(restarted.settings.sidebarWidth, 318);
    assert.equal(restarted.settings.panelWidth, 452);
    await browser.windowSize(1320, 850);
    await browser.navigate();
    await expect(browser.shell.locator('#sidebar-resizer')).toHaveAttribute('aria-valuenow', '318');
    await browser.openLibrary();
    await expect(browser.shell.locator('#panel-resizer')).toHaveAttribute('aria-valuenow', '452');
  },
);

test(
  'rail separators support keyboard sizing, reset and cancellation while compact windows retain a usable native page',
  { timeout: 60000 },
  async (t) => {
    const session = await fixture(t);
    const browser = await session.launch();
    await browser.windowSize(1320, 850);
    await browser.navigate();
    await browser.openLibrary();
    const sidebar = browser.shell.getByRole('separator', { name: 'Resize sidebar', exact: true });
    const panel = browser.shell.getByRole('separator', { name: 'Resize Library panel', exact: true });
    const key = async (handle, kind, stroke, expected) => {
      await handle.focus();
      await handle.press(stroke);
      await expect.poll(async () => (await browser.state()).settings[`${kind}Width`]).toBe(expected);
      await expect(handle).toHaveAttribute('aria-valuenow', String(expected));
      await browser.aligned();
    };
    await key(sidebar, 'sidebar', 'ArrowRight', 240);
    await key(sidebar, 'sidebar', 'Shift+ArrowRight', 272);
    await key(sidebar, 'sidebar', 'Alt+ArrowLeft', 271);
    await key(sidebar, 'sidebar', 'Home', 200);
    await key(sidebar, 'sidebar', 'End', 380);
    await sidebar.dblclick();
    await expect.poll(async () => (await browser.state()).settings.sidebarWidth).toBe(224);
    await key(panel, 'panel', 'ArrowLeft', 352);
    await key(panel, 'panel', 'ArrowRight', 336);
    await key(panel, 'panel', 'Home', 260);
    await key(panel, 'panel', 'End', 560);
    await panel.dblclick();
    await expect.poll(async () => (await browser.state()).settings.panelWidth).toBe(336);

    const rectangle = await sidebar.boundingBox();
    await browser.shell.mouse.move(rectangle.x + 4, rectangle.y + 80);
    await browser.shell.mouse.down();
    await browser.shell.mouse.move(rectangle.x + 64, rectangle.y + 80);
    await expect(sidebar).toHaveAttribute('aria-valuenow', '284');
    await sidebar.press('Escape');
    await browser.shell.mouse.up();
    await expect(sidebar).toHaveAttribute('aria-valuenow', '224');
    assert.equal((await browser.state()).settings.sidebarWidth, 224);

    const mediumSize = await browser.windowSize(800, 560);
    const sidebarMaximumWithPanel = mediumSize[0] - 260 - 240 - 16;
    await key(sidebar, 'sidebar', 'End', sidebarMaximumWithPanel);
    await expect(sidebar).toBeVisible();
    await expect(sidebar).toHaveAttribute('aria-valuemax', String(sidebarMaximumWithPanel));
    await expect(panel).toBeVisible();
    assert.equal((await browser.aligned()).bounds.width, 240);

    const size = await browser.windowSize(560, 420);
    await expect(sidebar).toBeHidden();
    await expect(panel).toBeVisible();
    const compactMaximum = size[0] - 240 - 16;
    await key(panel, 'panel', 'Home', 260);
    await key(panel, 'panel', 'End', compactMaximum);
    let current = await browser.aligned();
    assert.equal(current.bounds.width, 240);
    assert(current.bounds.x >= 0 && current.bounds.x + current.bounds.width <= size[0]);
    await browser.shell.locator('[data-key="panel-close"]').click();
    await expect(sidebar).toBeVisible();
    await key(sidebar, 'sidebar', 'End', compactMaximum);
    current = await browser.aligned();
    assert.equal(current.bounds.width, 240);
    assert.equal(current.page.width, current.bounds.width);
  },
);
