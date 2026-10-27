'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'compact chrome keeps native pages aligned through sidebar, Find, panel, split and Peek changes',
  { timeout: 60000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-compact-layout-'));
    const requests = new Map();
    const server = http.createServer((request, response) => {
      requests.set(request.url, (requests.get(request.url) || 0) + 1);
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      response.end(
        '<!doctype html><title>Compact layout fixture</title><style>body{margin:0;background:#cce3dc;height:1800px}textarea{margin:30px}</style><textarea id="draft"></textarea><p>Find this retained page.</p>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    let app;
    t.after(async () => {
      if (app) await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-compact-layout-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    const shell = await app.firstWindow();
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const state = () => invoke('state:get');
    const guest = (suffix, expression) =>
      app.evaluate(
        ({ webContents }, { url, expression }) =>
          webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === url)
            ?.executeJavaScript(expression) ?? null,
        { url: `${base}${suffix}`, expression },
      );
    const emit = (event) =>
      app.evaluate(
        ({ BrowserWindow }, event) => BrowserWindow.getAllWindows()[0].webContents.send('zacro:event', event),
        event,
      );
    const native = () =>
      app.evaluate(
        ({ BrowserWindow }, base) =>
          BrowserWindow.getAllWindows()[0]
            .contentView.children.filter((view) => view.webContents?.getURL().startsWith(base))
            .map((view) => ({
              id: view.webContents.id,
              url: view.webContents.getURL(),
              bounds: view.getBounds(),
            }))
            .sort((a, b) => a.bounds.x - b.bounds.x),
        base,
      );
    const rectangle = async (selector, { allowMissing = false } = {}) => {
      const box = await shell.locator(selector).boundingBox();
      if (!box && allowMissing) return null;
      assert(box, `${selector} must have a visible rectangle`);
      return Object.fromEntries(['x', 'y', 'width', 'height'].map((key) => [key, Math.round(box[key])]));
    };
    const aligned = async ({ split = false, peek = false } = {}) => {
      await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
      await expect(shell.locator('#app')).toHaveAttribute('data-panel-animating', 'false');
      let box, lastGeometry;
      try {
        await expect
          .poll(async () => {
            // Native window resizing and renderer resize delivery are asynchronous;
            // compare their current rectangles rather than freezing the first frame.
            const selector = peek ? '.peek-body' : '#workspace';
            box = await rectangle(selector, { allowMissing: true });
            if (!box) {
              // A state publication may replace Peek between two observations.
              // The geometry contract still has to match once its node returns.
              lastGeometry = { selector, expected: null, actual: await native() };
              return false;
            }
            const expected = split
              ? [
                  { ...box, width: Math.floor((box.width - 6) / 2) },
                  {
                    ...box,
                    x: box.x + Math.floor((box.width - 6) / 2) + 6,
                    width: box.width - Math.floor((box.width - 6) / 2) - 6,
                  },
                ]
              : [box];
            const actual = (await native()).map((item) => item.bounds);
            lastGeometry = { expected, actual };
            return (
              actual.length === expected.length &&
              actual.every((bounds, index) =>
                Object.keys(expected[index]).every((key) => bounds[key] === expected[index][key]),
              )
            );
          })
          .toBe(true);
      } catch (error) {
        t.diagnostic(JSON.stringify(lastGeometry || { error: 'No layout observation completed' }));
        throw error;
      }
      return box;
    };
    const baselineTop = process.platform === 'darwin' ? 8 : 36;
    await invoke('navigate', { url: `${base}/left` });
    await expect.poll(() => guest('/left', 'document.readyState')).toBe('complete');
    const firstTab = (await state()).activeTabId;
    await guest(
      '/left',
      'document.querySelector("textarea").value="Retained compact-layout draft";window.retainedMarker=17;undefined',
    );
    const firstContents = (await native())[0].id;

    for (const [width, height] of [
      [560, 420],
      [800, 560],
      [960, 640],
      [1001, 701],
      [1440, 900],
    ]) {
      await app.evaluate(
        ({ BrowserWindow }, { width, height }) =>
          BrowserWindow.getAllWindows()[0].setContentSize(width, height),
        { width, height },
      );
      const box = await aligned();
      assert.equal(box.y, baselineTop);
      assert.equal(box.x, 232);
    }
    await emit({ type: 'sidebar:toggle' });
    await expect(shell.locator('#sidebar')).toBeHidden();
    const hidden = await aligned();
    assert.equal(hidden.x, 8);
    assert.equal(hidden.y, 40);
    await emit({ type: 'sidebar:toggle' });
    await expect(shell.locator('#sidebar')).toBeVisible();
    assert.equal((await aligned()).y, baselineTop);

    await emit({ type: 'find' });
    await expect(shell.locator('#find-input')).toBeFocused();
    assert.equal((await aligned()).y, 40);
    const find = await rectangle('#findbar');
    assert(find.y + find.height <= 40, 'Find controls must stay outside the native web page');
    await shell.locator('#find-input').fill('retained');
    await shell.keyboard.press('Escape');
    await expect(shell.locator('#findbar')).toBeHidden();
    assert.equal((await aligned()).y, baselineTop);

    await emit({ type: 'panel', panel: 'settings' });
    await expect(shell.locator('#panel-title')).toHaveText('Settings');
    await aligned();
    await expect
      .poll(async () => {
        // The panel settles independently of the native page's immediate resize.
        const panelPage = await rectangle('#workspace');
        const panel = await rectangle('#side-panel');
        return { topOffset: panel.y - panelPage.y, gap: panel.x - (panelPage.x + panelPage.width) };
      })
      .toEqual({ topOffset: 0, gap: 8 });
    await shell.locator('[data-key="panel-close"]').click();
    await expect(shell.locator('#side-panel')).toBeHidden();

    // An existing wide sidebar preference must leave the same usable page and
    // panel rectangles in both Chromium and the shell at the minimum window.
    const minimumSize = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      window.setContentSize(960, 640);
      return window.getContentSize();
    });
    // Windows fractional scaling can round the requested content size by a
    // pixel. Native/DOM alignment must be exact at the actual window size.
    assert(Math.abs(minimumSize[0] - 960) <= 2 && Math.abs(minimumSize[1] - 640) <= 2);
    await expect.poll(() => shell.evaluate(() => [innerWidth, innerHeight])).toEqual(minimumSize);
    await invoke('settings:update', { values: { sidebarWidth: 380 } });
    await expect.poll(async () => (await rectangle('#sidebar')).width).toBe(380);
    await emit({ type: 'panel', panel: 'settings' });
    await expect(shell.locator('#side-panel')).toBeVisible();
    const narrowPage = await aligned();
    assert.equal(narrowPage.x, 388);
    assert.equal(narrowPage.width, 240);
    await expect
      .poll(() => rectangle('#side-panel'))
      .toEqual({
        x: 636,
        y: baselineTop,
        width: minimumSize[0] - 636,
        height: minimumSize[1] - baselineTop,
      });
    await shell.locator('[data-key="panel-close"]').click();

    // The smallest window temporarily retracts a wide sidebar for its panel,
    // while retaining both the saved preference and at least 240px of live page.
    const compactSize = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      window.setContentSize(560, 420);
      return window.getContentSize();
    });
    await expect.poll(() => shell.evaluate(() => [innerWidth, innerHeight])).toEqual(compactSize);
    await aligned();
    await emit({ type: 'panel', panel: 'settings' });
    await expect(shell.locator('#sidebar')).toBeHidden();
    const compactPage = await aligned();
    assert.equal(compactPage.width, 240);
    assert.equal(compactPage.x, 8);
    assert.equal(compactPage.y, 40);
    await expect
      .poll(() => rectangle('#side-panel'))
      .toEqual({
        x: 256,
        y: 40,
        width: compactSize[0] - 256,
        height: compactSize[1] - 40,
      });
    assert.equal((await state()).settings.sidebarWidth, 380);
    for (const panel of ['bookmarks', 'history', 'downloads', 'archive', 'ai', 'settings']) {
      await shell.locator(`[data-key="panel-${panel}"]`).click();
      const fits = await shell.locator('#side-panel').evaluate((panel) => ({
        horizontal: panel.scrollWidth <= panel.clientWidth,
        bottom: Math.round(panel.getBoundingClientRect().bottom) <= innerHeight,
        buttons: [...panel.querySelectorAll('.panel-tabs button')].every((button) => {
          const rect = button.getBoundingClientRect();
          return rect.left >= 0 && rect.right <= innerWidth;
        }),
      }));
      assert.deepEqual(fits, { horizontal: true, bottom: true, buttons: true });
    }
    await emit({ type: 'command', mode: 'newtab', query: '/' });
    await expect(shell.locator('#command-input')).toBeFocused();
    const compactCommand = await shell.locator('.command-dialog').evaluate((dialog) => {
      const rect = dialog.getBoundingClientRect();
      const footer = dialog.querySelector('.command-footer').getBoundingClientRect();
      return {
        readable: rect.width >= 400,
        footerVisible: Math.round(footer.bottom) <= Math.round(rect.bottom),
        withinWindow: rect.top >= 0 && Math.round(rect.bottom) <= innerHeight,
      };
    });
    assert.deepEqual(compactCommand, { readable: true, footerVisible: true, withinWindow: true });
    await shell.keyboard.press('Escape');
    await shell.locator('[data-key="panel-close"]').click();
    await expect(shell.locator('#sidebar')).toBeVisible();
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    const compactRestored = await aligned();
    assert.equal(compactRestored.width, 240);
    assert.equal(compactRestored.x, compactSize[0] - 248);
    await invoke('settings:update', { values: { sidebarWidth: 224 } });
    const restoredSize = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      window.setContentSize(1440, 900);
      return window.getContentSize();
    });
    await expect.poll(() => shell.evaluate(() => [innerWidth, innerHeight])).toEqual(restoredSize);
    await expect.poll(async () => (await rectangle('#sidebar')).width).toBe(224);
    await aligned();

    const second = await invoke('tab:create', { url: `${base}/right` });
    await expect.poll(() => guest('/right', 'document.readyState')).toBe('complete');
    await invoke('tab:activate', { id: firstTab });
    await invoke('split:toggle', { id: second.id });
    await aligned({ split: true });
    await emit({ type: 'panel', panel: 'settings' });
    await expect(shell.locator('#side-panel')).toBeVisible();
    await aligned({ split: true });
    await shell.locator('[data-key="panel-close"]').click();
    await invoke('split:toggle');

    await invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(() => guest('/peek', 'document.readyState')).toBe('complete');
    await expect(shell.locator('.peek-body')).toBeVisible();
    await aligned({ peek: true });
    await invoke('peek:close');
    await aligned();

    await invoke('window:fullscreen');
    await expect(shell.locator('html')).toHaveAttribute('data-fullscreen', 'true', { timeout: 15000 });
    assert.equal((await aligned()).y, 8);
    await invoke('window:fullscreen');
    await expect(shell.locator('html')).toHaveAttribute('data-fullscreen', 'false', { timeout: 15000 });
    assert.equal((await aligned()).y, baselineTop);

    assert.equal((await native())[0].id, firstContents, 'Chrome changes retain the living native page');
    assert.equal(
      await guest('/left', 'document.querySelector("textarea").value'),
      'Retained compact-layout draft',
    );
    assert.equal(await guest('/left', 'window.retainedMarker'), 17);
    assert.equal(requests.get('/left'), 1, 'No chrome transition reloads the page');
  },
);

test(
  'anchored popovers and nested forms preserve the page backdrop without capturing private pages',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-popover-backdrop-'));
    const server = http.createServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      response.end(
        '<!doctype html><title>Popover backdrop fixture</title><style>body{background:#397f74;color:white;padding:24px}</style><h1>A live page behind compact menus</h1><textarea id="draft"></textarea>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    let app;
    t.after(async () => {
      if (app) await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-popover-backdrop-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    const shell = await app.firstWindow();
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const guest = (url, expression) =>
      app.evaluate(
        ({ webContents }, { url, expression }) =>
          webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === url)
            ?.executeJavaScript(expression) ?? null,
        { url, expression },
      );
    const instrument = (url, firstDelayMs = 0) =>
      app.evaluate(
        ({ webContents }, { url, firstDelayMs }) => {
          const contents = webContents.getAllWebContents().find((contents) => contents.getURL() === url);
          const capture = contents.capturePage.bind(contents);
          globalThis.popoverCaptureCount = 0;
          globalThis.popoverCaptures = [];
          contents.capturePage = (...args) => {
            globalThis.popoverCaptureCount++;
            const record = { startedAt: Date.now(), visibility: contents.mainFrame.visibilityState };
            globalThis.popoverCaptures.push(record);
            return capture(...args).then(
              async (image) => {
                const delay = firstDelayMs;
                firstDelayMs = 0;
                if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
                Object.assign(record, {
                  duration: Date.now() - record.startedAt,
                  empty: image.isEmpty(),
                  size: image.getSize(),
                });
                return image;
              },
              (error) => {
                Object.assign(record, { duration: Date.now() - record.startedAt, error: error.message });
                throw error;
              },
            );
          };
        },
        { url, firstDelayMs },
      );
    const expectBackdrop = async (label) => {
      try {
        await expect(shell.locator('#page-backdrop img')).toHaveCount(1);
      } catch (error) {
        const diagnostics = await app.evaluate(({ BrowserWindow }) => {
          const window = BrowserWindow.getAllWindows()[0];
          return {
            captures: globalThis.popoverCaptures,
            windowVisible: window.isVisible(),
            windowFocused: window.isFocused(),
            children: window.contentView.children.map((view) => ({
              visible: view.getVisible(),
              bounds: view.getBounds(),
              url: view.webContents?.getURL(),
              visibility: view.webContents?.mainFrame.visibilityState,
            })),
          };
        });
        t.diagnostic(JSON.stringify({ label, ...diagnostics }));
        const results = path.resolve(__dirname, '../../test-results');
        await fs.mkdir(results, { recursive: true });
        await shell.screenshot({
          path: path.join(results, `popover-backdrop-${process.platform}-${process.arch}.png`),
        });
        throw error;
      }
    };
    const url = `${base}/regular`;
    await invoke('navigate', { url });
    await expect.poll(() => guest(url, 'document.readyState')).toBe('complete');
    await guest(
      url,
      'document.querySelector("textarea").value="A draft retained through menus";new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))',
    );
    // Exercise the cold-compositor path observed in native Mac CI: a successful
    // capture after 200ms must still arrive without delaying dialog interaction.
    await instrument(url, 250);
    const liveBeforeLibrary = await guest(
      url,
      '({ dpr:devicePixelRatio, identity:window.liveIdentity=crypto.randomUUID() })',
    );
    await shell.locator('[data-key="library"]').click();
    await expect(shell.locator('#panel-title')).toHaveText('Bookmarks');
    await expect(shell.locator('#app')).toHaveAttribute('data-panel-animating', 'false');
    await expect(shell.locator('#page-backdrop img')).toHaveCount(0);
    assert.equal(
      await app.evaluate(() => globalThis.popoverCaptureCount),
      0,
      'Library keeps the actual native page rather than a reduced-resolution capture',
    );
    assert.deepEqual(
      await guest(url, '({dpr:devicePixelRatio, identity:window.liveIdentity})'),
      liveBeforeLibrary,
    );
    assert.equal(await guest(url, 'document.visibilityState'), 'visible');
    await shell.locator('[data-key="panel-settings"]').click();
    await shell.locator('[data-key="panel-close"]').click();
    await expect(shell.locator('#side-panel')).toBeHidden();
    await shell.locator('[data-key="library"]').click();
    await expect(shell.locator('#panel-title')).toHaveText('Settings');
    await shell.locator('[data-key="panel-close"]').click();
    await expect(shell.locator('#side-panel')).toBeHidden();
    let expectedCaptures = 0;
    for (const [key, title] of [
      ['page-menu', 'Page actions'],
      ['space-picker', 'Your Spaces'],
      ['add-menu', 'Add'],
    ]) {
      await shell.locator(`[data-key="${key}"]`).click();
      await expect(shell.getByRole('dialog', { name: title, exact: true })).toBeVisible();
      await expectBackdrop(title);
      assert.equal(
        await app.evaluate(() => globalThis.popoverCaptureCount),
        ++expectedCaptures,
        `${title} captures the same bounded native page`,
      );
      await expect
        .poll(() =>
          app.evaluate(
            ({ BrowserWindow }, url) =>
              BrowserWindow.getAllWindows()[0].contentView.children.some(
                (view) => view.webContents?.getURL() === url,
              ),
            url,
          ),
        )
        .toBe(false);
      await shell.keyboard.press('Escape');
      await expect(shell.locator('#page-backdrop img')).toHaveCount(0);
      await expect
        .poll(() =>
          app.evaluate(
            ({ BrowserWindow }, url) =>
              BrowserWindow.getAllWindows()[0].contentView.children.some(
                (view) => view.webContents?.getURL() === url,
              ),
            url,
          ),
        )
        .toBe(true);
    }
    const tabId = (await invoke('state:get')).activeTabId;
    await shell.locator(`[data-key="tab-${tabId}"]`).dispatchEvent('contextmenu');
    await expect(shell.getByRole('dialog', { name: 'Tab actions', exact: true })).toBeVisible();
    await expectBackdrop('Tab actions');
    const beforeNestedForm = await app.evaluate(() => globalThis.popoverCaptureCount);
    await shell.getByRole('button', { name: 'Rename tab', exact: true }).click();
    await expect(shell.getByRole('dialog', { name: 'Rename tab', exact: true })).toBeVisible();
    await expectBackdrop('Rename tab');
    assert.equal(
      await app.evaluate(() => globalThis.popoverCaptureCount),
      beforeNestedForm,
      'A nested form reuses its current frame rather than capturing an already-hidden page',
    );
    await shell.keyboard.press('Escape');
    assert.equal(
      await guest(url, 'document.querySelector("textarea").value'),
      'A draft retained through menus',
    );

    const profile = await invoke('profile:create', { name: 'Private popover', private: true });
    const state = await invoke('state:get');
    await invoke('space:activate', { id: state.spaces.find((space) => space.profileId === profile.id).id });
    const privateURL = `${base}/private`;
    await invoke('navigate', { url: privateURL });
    await expect.poll(() => guest(privateURL, 'document.readyState')).toBe('complete');
    await instrument(privateURL);
    await shell.locator('[data-key="page-menu"]').click();
    await expect(shell.getByRole('dialog', { name: 'Page actions', exact: true })).toBeVisible();
    await expect
      .poll(() =>
        app.evaluate(
          ({ BrowserWindow }, url) =>
            BrowserWindow.getAllWindows()[0].contentView.children.some(
              (view) => view.webContents?.getURL() === url,
            ),
          privateURL,
        ),
      )
      .toBe(false);
    assert.equal(await app.evaluate(() => globalThis.popoverCaptureCount), 0);
    await expect(shell.locator('#page-backdrop img')).toHaveCount(0);
    await shell.keyboard.press('Escape');
  },
);
