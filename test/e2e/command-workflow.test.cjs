'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'pinned extension cubes adapt, preserve actions and badges, and stay local to each profile',
  { timeout: 90000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/extensions`);
    const initial = await b.state();
    const profileId = initial.profiles[0].id;
    const spaceId = initial.activeSpaceId;
    const installed = [];
    const row = () => b.shell.locator('.pinned-extensions');
    const pins = () => b.shell.locator('.pinned-extension');
    const capture = path.resolve(__dirname, '../../test-results/0.10.2');
    await fs.mkdir(capture, { recursive: true });
    await b.shell.evaluate(() => {
      window.zacro.onState((snapshot) => {
        window.__pinSnapshot = snapshot;
      });
    });
    const sizes = {};
    for (let index = 0; index < 7; index++) {
      const folder = path.join(b.directory, `extension-${index}`);
      await fs.mkdir(folder);
      await fs.copyFile(path.resolve(__dirname, '../../assets/icon-256.png'), path.join(folder, 'icon.png'));
      await fs.writeFile(
        path.join(folder, 'manifest.json'),
        JSON.stringify({
          manifest_version: 3,
          name: `Pinned fixture ${index + 1}`,
          version: '1.0',
          icons: { 128: 'icon.png' },
          background: { service_worker: 'worker.js' },
          action: {
            default_title: `Pinned action ${index + 1}`,
            default_popup: 'popup.html',
            default_icon: 'icon.png',
          },
        }),
      );
      await fs.writeFile(
        path.join(folder, 'worker.js'),
        `chrome.action.setBadgeText({text:'${index + 1}'}); chrome.action.setBadgeBackgroundColor({color:'#c42b4c'}); chrome.action.setBadgeTextColor({color:'#ffffff'});`,
      );
      await fs.writeFile(
        path.join(folder, 'popup.html'),
        `<!doctype html><title>Pinned popup ${index + 1}</title><h1>Extension ${index + 1}</h1>`,
      );
      await b.app.evaluate(({ dialog }, folder) => {
        dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [folder] });
        dialog.showMessageBox = async () => ({ response: 1 });
      }, folder);
      const extension = await b.invoke('extension:install');
      installed.push(extension);
      await b.shell.waitForFunction(
        (id) => window.__pinSnapshot?.extensions.some((item) => item.id === id && item.hasAction),
        extension.id,
      );
      if (index === 0) {
        await b.shell.locator('[data-key="extensions-menu"]').click();
        const control = b.shell.locator(`.extension-pin-control[data-id="${extension.id}"]`);
        await control.click();
        await expect(control).toHaveAttribute('aria-pressed', 'true');
        await b.shell.keyboard.press('Escape');
      } else await b.invoke('extension-pin:toggle', { id: extension.id, profileId });
      await expect(pins()).toHaveCount(index + 1);
      if ([1, 2, 5, 7].includes(index + 1)) {
        sizes[index + 1] = await row().evaluate((element) => {
          const bounds = element.getBoundingClientRect();
          const buttons = [...element.querySelectorAll('button')].map((button) => {
            const rect = button.getBoundingClientRect();
            return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
          });
          return {
            columns: Number(element.dataset.columns),
            x: bounds.x,
            right: bounds.right,
            height: bounds.height,
            buttons,
          };
        });
        const measurement = sizes[index + 1];
        assert.equal(measurement.columns, index === 4 ? 5 : 4);
        assert(measurement.height <= 116);
        for (const button of measurement.buttons) {
          assert(Math.abs(button.width - button.height) < 1, 'Pinned actions remain square');
          assert(button.x >= measurement.x && button.x + button.width <= measurement.right + 1);
        }
        if (index === 4) {
          await expect(pins().first().locator('img')).toBeVisible();
          await expect(pins().first().locator('.extension-badge')).toHaveText('1');
          await b.shell.screenshot({ path: path.join(capture, 'pinned-extensions-five.png') });
          await b.shell.locator('[data-key="extensions-menu"]').click();
          await expect(b.shell.getByRole('dialog', { name: 'Site controls', exact: true })).toBeVisible();
          await b.shell.screenshot({ path: path.join(capture, 'site-controls-pinned-extensions.png') });
          await b.shell.keyboard.press('Escape');
        }
      }
    }
    assert(sizes[5].buttons[0].width < sizes[2].buttons[0].width, 'Five actions shrink to fit the row');
    assert(sizes[7].buttons[6].y > sizes[7].buttons[0].y, 'Seven actions wrap into balanced rows');
    await fs.writeFile(path.join(capture, 'pinned-extension-layout.json'), JSON.stringify(sizes, null, 2));
    b.trace('opening pinned action');
    await pins().first().click();
    await expect
      .poll(() =>
        b.app.evaluate(
          ({ BrowserWindow }, id) =>
            BrowserWindow.getAllWindows().some(
              (window) => window.webContents.getURL() === `chrome-extension://${id}/popup.html`,
            ),
          installed[0].id,
        ),
      )
      .toBe(true);
    b.trace('closing pinned popup');
    await b.app.evaluate(
      ({ BrowserWindow }, id) =>
        BrowserWindow.getAllWindows()
          .find((window) => window.webContents.getURL() === `chrome-extension://${id}/popup.html`)
          ?.close(),
      installed[0].id,
    );
    b.trace('disabling extension before restart');
    await b.invoke('extension:toggle', { id: installed[0].id });
    await expect(pins().first()).toBeDisabled();
    await b.close();
    b.trace('restarting pinned profile');
    await b.launch();
    b.trace('pinned profile restarted');
    await expect(pins()).toHaveCount(7);
    await expect(pins().first()).toBeDisabled();
    assert.deepEqual(
      (await b.state()).profiles.find((profile) => profile.id === profileId).pinnedExtensionIds,
      installed.map((item) => item.id),
    );
    await b.invoke('profile:create', { name: 'Other extension profile' });
    await expect(row()).toHaveCount(0);
    await assert.rejects(b.invoke('extension-pin:toggle', { id: installed[0].id }), /installed/);
    await b.invoke('profile:create', { name: 'Private extension profile', private: true });
    await expect(row()).toHaveCount(0);
    await assert.rejects(b.invoke('extension-pin:toggle', { id: installed[0].id }), /regular profile/);
    await b.invoke('space:activate', { id: spaceId });
    await expect(pins()).toHaveCount(7);
    await assert.rejects(b.invoke('extension-pin:toggle', { id: 'a'.repeat(32) }), /installed/);
    await expect.poll(() => b.guest(`${b.base}/extensions`, 'document.readyState')).toBe('complete');
    // Relaunch has a fresh native dialog module. This expected removal prompt
    // keeps the live page open; any different dialog must fail the regression.
    await b.app.evaluate(({ dialog }) => {
      globalThis.__pinRemovalPrompts = 0;
      dialog.showMessageBox = async (_window, options) => {
        if (
          options.title !== 'Reload pages to finish changing extension access' ||
          JSON.stringify(options.buttons) !== JSON.stringify(['Keep pages open', 'Reload pages'])
        )
          throw new Error(`Unexpected extension removal dialog: ${options.title}`);
        globalThis.__pinRemovalPrompts++;
        return { response: 0 };
      };
    });
    await b.invoke('extension:remove', { id: installed[0].id });
    assert.equal(await b.app.evaluate(() => globalThis.__pinRemovalPrompts), 1);
    await expect(pins()).toHaveCount(6);
    assert.equal(
      (await b.state()).profiles
        .find((profile) => profile.id === profileId)
        .pinnedExtensionIds.includes(installed[0].id),
      false,
    );
  },
);

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
  const trace = (message) => {
    if (process.env.ZACRO_WORKFLOW_TRACE === '1')
      process.stderr.write(`[workflow ${new Date().toISOString()}] ${message}\n`);
  };
  const within = async (promise, milliseconds, message) => {
    let timer;
    try {
      return await Promise.race([
        promise,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(message)), milliseconds);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  };
  const close = async () => {
    if (!app) return;
    trace('closing fixture browser');
    const previous = app;
    app = null;
    const child = previous.process();
    try {
      await within(previous.close(), 8000, 'The fixture browser did not finish quitting within 8 seconds.');
    } catch (error) {
      // SIGTERM follows Electron's normal quit handlers, which can themselves
      // be blocked after a startup failure. Kill only this fixture's child.
      if (child.exitCode === null && child.signalCode === null) {
        const exited = new Promise((resolve) => child.once('exit', resolve));
        child.kill('SIGKILL');
        await within(exited, 5000, 'The fixture browser did not exit after SIGKILL.');
      }
      throw error;
    }
    trace('fixture browser closed');
  };
  t.after(async () => {
    let closeError;
    try {
      await close();
    } catch (error) {
      closeError = error;
    }
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-command-workflow-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, [], 'No renderer errors during the command workflow');
    if (closeError) throw closeError;
  });
  const launch = async () => {
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    trace('launching fixture browser');
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 15000 });
    trace(`fixture browser connected, pid ${app.process().pid}`);
    let startupLog = '';
    app.process().stderr.on('data', (chunk) => {
      startupLog = (startupLog + chunk).slice(-12000);
    });
    try {
      await expect
        .poll(
          () => {
            shell = app.windows().find((page) => /\/renderer\/index\.html$/.test(page.url()));
            return Boolean(shell);
          },
          {
            timeout: 10000,
            message: 'The browser shell must load independently of hidden extension broker windows.',
          },
        )
        .toBe(true);
    } catch (error) {
      const native = await within(
        app.evaluate(({ app, BrowserWindow, webContents }) => ({
          ready: app.isReady(),
          windows: BrowserWindow.getAllWindows().map((window) => ({
            id: window.id,
            visible: window.isVisible(),
            url: window.webContents.getURL(),
          })),
          pages: webContents
            .getAllWebContents()
            .map((contents) => ({ id: contents.id, type: contents.getType(), url: contents.getURL() })),
        })),
        2000,
        'Native startup diagnostics timed out.',
      ).catch((failure) => ({ error: failure.message }));
      throw new Error(`${error.message}\nNative startup: ${JSON.stringify(native)}\n${startupLog}`, {
        cause: error,
      });
    }
    trace('fixture shell selected');
    shell.on('pageerror', (error) => errors.push(error.message));
    await shell.waitForFunction(() => Boolean(window.zacro), null, { timeout: 10000 });
    const shellUrl = shell.url();
    await expect
      .poll(() =>
        app.evaluate(
          ({ BrowserWindow }, url) =>
            BrowserWindow.getAllWindows()
              .find((window) => window.webContents.getURL() === url)
              ?.isVisible(),
          shellUrl,
        ),
      )
      .toBe(true);
    await app.evaluate(({ app, BrowserWindow }, url) => {
      app.focus({ steal: true });
      BrowserWindow.getAllWindows()
        .find((window) => window.webContents.getURL() === url)
        .focus();
    }, shellUrl);
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
    trace('fixture shell ready');
  };
  const invoke = async (action, payload = {}) => {
    trace(`invoke ${action}`);
    const result = await within(
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]),
      15000,
      `Browser action ${action} did not finish within 15 seconds.`,
    );
    trace(`completed ${action}`);
    return result;
  };
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
    trace,
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
  'mouse drags through favorites, Space pins and Today preserve live pages and persist across restarts',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const row = (id) => b.shell.locator(`.tab-row[data-tab-id="${id}"]`);
    const pin = (id) => b.shell.locator(`.favorite[data-tab-id="${id}"]`);
    const pinnedOrder = () =>
      b.shell
        .locator('.favorite[data-tab-id]')
        .evaluateAll((elements) => elements.map((element) => element.dataset.tabId));
    let metadataUpdateChecked = false;
    const mouseDrag = async (source, target, { x = 0.5, y = 0.5, feedback = 'drag-over' } = {}) => {
      // Hover waits for a stable, attached row and retries if page metadata
      // replaces the sidebar while a newly restored tab finishes loading.
      await source.hover();
      let start;
      // Metadata can replace the row between hover and measurement. Re-query
      // the semantic locator until its current attached row has actual bounds.
      await expect
        .poll(
          async () => {
            start = await source.boundingBox();
            return !!start && start.width > 0 && start.height > 0;
          },
          { message: 'The dragged tab must be visible' },
        )
        .toBe(true);
      const startX = start.x + start.width * 0.4;
      const startY = start.y + start.height / 2;
      await b.shell.mouse.move(startX, startY);
      await b.shell.mouse.down();
      try {
        await b.shell.mouse.move(startX + 10, startY + 2, { steps: 3 });
        await expect(b.shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
        if (!metadataUpdateChecked) {
          metadataUpdateChecked = true;
          const draggingId = await source.getAttribute('data-tab-id');
          await source.evaluate((node) => {
            window.__dragSource = node;
            window.__dragMetadataPublished = false;
            const unsubscribe = window.zacro.onState((snapshot) => {
              if (snapshot.tabs.some((tab) => tab.title === 'Updated during drag')) {
                window.__dragMetadataPublished = true;
                unsubscribe();
              }
            });
          });
          await b.invoke('tab:update', { id: draggingId, title: 'Updated during drag' });
          await expect.poll(() => b.shell.evaluate(() => window.__dragMetadataPublished)).toBe(true);
          assert.equal(
            await source.evaluate((node) => node === window.__dragSource && node.isConnected),
            true,
            'Metadata updates retain the native drag source and target nodes',
          );
        }
        // The empty pinned area grows after dragstart. Measure the destination
        // afterwards, just as a pointer follows the visible drop target.
        const end = await target.boundingBox();
        assert(end, 'The drop destination must be visible');
        const endX = end.x + end.width * x;
        const endY = end.y + end.height * y;
        const favoriteTarget = await target.evaluate((node) =>
          Boolean(node.closest('[data-drop-favorites]')),
        );
        const originalOrder = (await b.state()).tabs.filter((tab) => tab.favorite).map((tab) => tab.id);
        const originalTabs = (await b.state()).tabs.map((tab) => tab.id);
        await b.shell.mouse.move(endX, endY, { steps: 12 });
        await b.shell.mouse.move(endX + 1, endY, { steps: 2 });
        if (favoriteTarget) {
          const slot = b.shell.locator('.favorite-insertion-slot');
          await expect(slot).toBeVisible();
          await expect(b.shell.locator('.favorites[data-drop-favorites]')).toHaveCSS('outline-style', 'none');
          await expect(slot).toHaveCSS('border-top-width', '0px');
          assert.equal(
            await source.evaluate((node) => node.isConnected),
            true,
            'Reflow keeps the native drag source attached',
          );
          assert.deepEqual(
            (await b.state()).tabs.filter((tab) => tab.favorite).map((tab) => tab.id),
            originalOrder,
            'Preview does not persist before drop',
          );
          if (feedback === 'drop-before') {
            await expect(slot).toHaveAttribute('data-insertion-index', '0');
            await expect.poll(async () => (await target.boundingBox()).x).toBeGreaterThan(end.x + 10);
          }
        } else {
          await expect(b.shell.locator('.tab-insertion-slot')).toBeVisible();
          if (await target.getAttribute('data-drop-tab')) {
            await expect
              .poll(() =>
                target.evaluate((node) =>
                  node.getAnimations().every((animation) => animation.playState !== 'running'),
                ),
              )
              .toBe(true);
            const moved = await target.boundingBox();
            await b.shell.mouse.move(moved.x + moved.width * x, moved.y + moved.height * y, { steps: 5 });
            await b.shell.mouse.move(moved.x + moved.width * x + 1, moved.y + moved.height * y, { steps: 2 });
          }
          assert.equal(await source.evaluate((node) => node.isConnected), true);
          assert.deepEqual(
            (await b.state()).tabs.map((tab) => tab.id),
            originalTabs,
          );
          if (feedback === 'drop-before')
            await expect.poll(async () => (await target.boundingBox()).y).toBeGreaterThan(end.y + 10);
        }
      } finally {
        await b.shell.mouse.up();
      }
      await expect(b.shell.locator('#app')).not.toHaveAttribute('data-dragging', 'true');
    };
    await b.submit(`${b.base}/drag-pin`);
    const id = (await b.state()).activeTabId;
    await b.guest(`${b.base}/drag-pin`, 'document.querySelector("textarea").value="Pinned draft"');
    await mouseDrag(row(id), b.shell.locator('.favorites[data-drop-favorites]'));
    await expect.poll(async () => (await b.state()).tabs.find((tab) => tab.id === id)?.pinned).toBe(true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).favorite, true);
    await expect(pin(id)).toBeVisible();
    assert.equal((await b.state()).tabs.length, 1);
    assert.equal(
      await b.guest(`${b.base}/drag-pin`, 'document.querySelector("textarea").value'),
      'Pinned draft',
    );
    const second = await b.invoke('tab:create', { url: `${b.base}/second-pin` });
    await expect.poll(() => b.guest(`${b.base}/second-pin`, 'document.readyState')).toBe('complete');
    await b.guest(`${b.base}/second-pin`, 'document.querySelector("textarea").value="Second retained draft"');
    await expect(row(second.id)).toBeVisible();
    await mouseDrag(row(second.id), pin(id), { x: 0.75, feedback: 'drop-after' });
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === second.id)?.pinned)
      .toBe(true);
    await expect.poll(pinnedOrder).toEqual([id, second.id]);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).folderId, null);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).favorite, true);

    await mouseDrag(pin(second.id), pin(id), { x: 0.25, feedback: 'drop-before' });
    await expect.poll(pinnedOrder).toEqual([second.id, id]);
    assert.deepEqual(
      (await b.state()).tabs.filter((tab) => tab.favorite).map((tab) => tab.id),
      [second.id, id],
    );
    assert.equal(
      await b.guest(`${b.base}/second-pin`, 'document.querySelector("textarea").value'),
      'Second retained draft',
      'Dragging preserves the existing live page and its draft',
    );
    const loose = await b.invoke('tab:create', { url: `${b.base}/loose-anchor` });
    await b.close();
    await b.launch();
    await expect.poll(pinnedOrder).toEqual([second.id, id]);
    await expect(row(loose.id)).toBeVisible();
    await mouseDrag(pin(second.id), row(loose.id), { y: 0.75, feedback: 'drop-after' });
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === second.id)?.pinned)
      .toBe(false);
    await expect(pin(second.id)).toHaveCount(0);
    await expect(row(second.id)).toBeVisible();
    await expect
      .poll(() =>
        b.shell
          .locator('.loose-tabs .tab-row')
          .evaluateAll((elements) => elements.map((element) => element.dataset.tabId)),
      )
      .toEqual([loose.id, second.id]);
    assert.equal((await b.state()).tabs.length, 3, 'Moving a tab never duplicates or closes it');
    await b.close();
    await b.launch();
    await expect.poll(pinnedOrder).toEqual([id]);
    await expect(row(second.id)).toBeVisible();
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).pinned, true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).pinned, false);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).favorite, false);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).folderId, null);
    await mouseDrag(row(second.id), b.shell.locator('.pinned-tabs[data-drop-pinned]'));
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === second.id)?.pinned)
      .toBe(true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).favorite, false);
    await expect(b.shell.locator(`.pinned-tabs .tab-row[data-tab-id="${second.id}"]`)).toBeVisible();
    await expect(pin(second.id)).toHaveCount(0);
    await expect.poll(pinnedOrder).toEqual([id]);
    await b.close();
    await b.launch();
    await expect(b.shell.locator(`.pinned-tabs .tab-row[data-tab-id="${second.id}"]`)).toBeVisible();
    await expect.poll(pinnedOrder).toEqual([id]);
    assert.equal((await b.state()).tabs.length, 3);

    await b.invoke('tab:pin', { id: loose.id });
    const today = b.shell.locator('.loose-tabs');
    await expect(today.locator('.tab-row')).toHaveCount(0);
    assert((await today.boundingBox()).height > 100, 'Blank Today space is a generous drop destination');
    await mouseDrag(pin(id), today, { y: 0.85 });
    await expect(row(id)).toBeVisible();
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).pinned, false);
    await mouseDrag(row(second.id), b.shell.locator('[data-drop-today]'));
    await expect(today.locator('.tab-row')).toHaveCount(2);
    await expect
      .poll(() => today.locator('.tab-row').evaluateAll((nodes) => nodes.map((node) => node.dataset.tabId)))
      .toEqual([second.id, id]);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).pinned, false);

    const fourth = await b.invoke('tab:create', { url: `${b.base}/fourth-row` });
    await mouseDrag(row(fourth.id), row(second.id), { y: 0.25, feedback: 'drop-before' });
    await expect
      .poll(() => today.locator('.tab-row').evaluateAll((nodes) => nodes.map((node) => node.dataset.tabId)))
      .toEqual([fourth.id, second.id, id]);
    await b.invoke('tab:pin', { id });
    await mouseDrag(row(id), row(loose.id), { y: 0.25, feedback: 'drop-before' });
    await expect
      .poll(() =>
        b.shell
          .locator('.pinned-tabs > .tab-row')
          .evaluateAll((nodes) => nodes.map((node) => node.dataset.tabId)),
      )
      .toEqual([id, loose.id]);
    await b.close();
    await b.launch();
    await expect
      .poll(() =>
        b.shell
          .locator('.pinned-tabs > .tab-row')
          .evaluateAll((nodes) => nodes.map((node) => node.dataset.tabId)),
      )
      .toEqual([id, loose.id]);
    await expect
      .poll(() =>
        b.shell
          .locator('.loose-tabs > .tab-row')
          .evaluateAll((nodes) => nodes.map((node) => node.dataset.tabId)),
      )
      .toEqual([fourth.id, second.id]);
  },
);

test(
  'keyword Tab site search supports custom templates, validation, encoded queries and restart',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const input = () => b.shell.locator('#command-input');
    await input().fill('/manage site search');
    await input().press('Enter');
    await expect(input()).toHaveAttribute('placeholder', 'Site Search');
    await input().press('Enter');
    const editor = b.shell.getByRole('dialog', { name: 'Add site search', exact: true });
    await editor.getByRole('textbox', { name: 'Name', exact: true }).fill('Local documentation');
    await editor.getByRole('textbox', { name: 'Keyword', exact: true }).fill('w');
    await editor
      .getByRole('textbox', { name: 'Search URL', exact: true })
      .fill(`${b.base}/search?q=%s&source=docs`);
    await editor.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(editor.getByRole('alert')).toContainText('already assigned');
    await editor.getByRole('textbox', { name: 'Keyword', exact: true }).fill('docs');
    await editor.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(input()).toHaveAttribute('placeholder', 'Site Search');
    const saved = (await b.state()).settings.siteSearches.find((engine) => engine.keyword === 'docs');
    assert(saved, 'Custom site search must persist through the settings validator');
    await input().press('Escape');
    await input().fill('DOCS');
    await input().press('Tab');
    await expect(input()).toHaveAttribute('placeholder', 'Search Local documentation');
    await expect(input()).toHaveAttribute('aria-label', 'Search Local documentation');
    await expect(b.shell.locator('#command-status')).toHaveAttribute('aria-live', 'polite');
    await expect(b.shell.locator('#command-status')).toContainText('Type to search Local documentation');
    await expect(input()).toHaveValue('');
    const query = 'browser & state=other / 日本語';
    await input().fill(query);
    await input().press('Escape');
    await expect(input()).toHaveValue('DOCS');
    await input().press('Tab');
    await input().fill(query);
    await input().press('Enter');
    const url = `${b.base}/search?q=${encodeURIComponent(query)}&source=docs`;
    await expect.poll(() => b.guest(url, 'document.readyState')).toBe('complete');
    assert.equal(new URL((await b.state()).tabs[0].url).searchParams.get('q'), query);
    assert.equal((await b.state()).tabs.length, 1, 'Site search creates only its submitted destination');
    await b.close();
    await b.launch();
    assert.deepEqual(
      (await b.state()).settings.siteSearches.find((engine) => engine.id === saved.id),
      saved,
    );
    await b.key('T', [b.mod]);
    await expect(input()).toBeFocused();
    await b.key('T', [b.mod]);
    await expect(input()).toHaveCount(0);
  },
);

test(
  'command result actions support reversible keyboard drill-down and pinning directly into a folder',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/target`);
    const target = (await b.state()).activeTabId;
    await b.guest(`${b.base}/target`, 'window.retainedCommandDraft="same document"');
    await b.invoke('tab:create', { url: `${b.base}/current` });
    await expect.poll(() => b.guest(`${b.base}/current`, 'document.readyState')).toBe('complete');
    const folder = await b.invoke('folder:create', { name: 'Research' });
    await b.shell.locator(`[data-key="folder-${folder.id}"]`).click();
    await expect(b.shell.locator(`[data-key="folder-${folder.id}"]`)).toHaveAttribute(
      'aria-expanded',
      'false',
    );
    await b.key('T', [b.mod]);
    const input = () => b.shell.locator('#command-input');
    await b.shell.getByRole('button', { name: 'Tabs', exact: true }).click();
    await input().fill('w');
    await expect(b.shell.locator('.command-footer')).toHaveCount(0);
    const scopedTab = await b.shell.locator('.command-result.selected .command-result-label').innerText();
    await input().press('Tab');
    await expect(input()).toHaveAttribute('aria-label', `Actions for ${scopedTab}`);
    await expect(b.shell.locator('[data-command-id="result:move"]')).toBeVisible();
    await input().press('Escape');
    await b.shell.getByRole('button', { name: 'All', exact: true }).click();
    await input().fill('@target');
    await input().press('Tab');
    await expect(input()).toHaveAttribute('placeholder', 'Workflow /target');
    await expect(input()).toHaveAttribute('aria-label', 'Actions for Workflow /target');
    await input().fill('pin to');
    await input().press('Enter');
    await expect(input()).toHaveAttribute('placeholder', 'Pin to…');
    await expect(input()).toHaveAttribute('aria-label', 'Pin to…');
    await input().press('Escape');
    await expect(input()).toHaveValue('pin to');
    await input().press('Escape');
    await expect(input()).toHaveValue('@target');
    await input().press('Tab');
    await input().fill('pin to');
    await input().press('Enter');
    await input().fill('Research');
    await input().press('Enter');
    await expect(input()).toHaveCount(0);
    const pinned = (await b.state()).tabs.find((tab) => tab.id === target);
    assert.equal(pinned.folderId, folder.id);
    assert.equal(pinned.pinned, true);
    assert.equal(pinned.favorite, false);
    assert.equal(await b.guest(`${b.base}/target`, 'window.retainedCommandDraft'), 'same document');
    await b.key('T', [b.mod]);
    await input().fill('Research');
    await b.shell.getByRole('button', { name: 'Folders', exact: true }).click();
    await expect(b.shell.getByRole('button', { name: 'Folders', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    await expect(b.shell.locator('[data-command-kind="navigation"]')).toHaveCount(0);
    await b.shell.locator(`[data-command-id="folder:${folder.id}"]`).click();
    await expect(b.shell.locator(`[data-key="folder-${folder.id}"]`)).toHaveAttribute(
      'aria-expanded',
      'true',
    );
    await expect(input()).toHaveCount(0);
    await b.key('T', [b.mod]);
    await input().fill('@target');
    await input().press('Tab');
    await b.invoke('profile:create', { name: 'Isolated commands' });
    await expect(input()).toHaveValue('');
    await expect(input()).toHaveAttribute('placeholder', 'Search or enter a URL');
    await expect(b.shell.locator('[data-command-id="result:move"]')).toHaveCount(0);
  },
);

test(
  'rebinding the AI shortcut disables its former palette key and uses the configured binding',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/shortcut-page`);
    await b.invoke('shortcut:set', { id: 'ai', accelerator: 'Mod+Alt+8' });
    await b.key('T', [b.mod]);
    const input = b.shell.locator('#command-input');
    // Keep the query empty so exercising the configured AI key opens its panel
    // without sending a request to any locally connected provider.
    await input.fill('');
    await input.press(`${process.platform === 'darwin' ? 'Meta' : 'Control'}+Enter`);
    await expect(input).toBeFocused();
    await expect(input).toHaveValue('');
    await expect(b.shell.locator('#ai-question')).toHaveCount(0);
    assert.equal((await b.state()).tabs.length, 1);
    await b.key('8', [b.mod, 'alt']);
    await expect(b.shell.locator('#ai-question')).toBeVisible();
    await expect(input).toHaveCount(0);
    await expect(b.shell.locator('#ai-question')).toHaveValue('');
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
    assert.equal((await b.state()).tabs.find((tab) => tab.id === records[1].id).favorite, false);
    await expect(b.shell.locator(`.pinned-tabs .tab-row[data-tab-id="${records[1].id}"]`)).toBeVisible();
    await expect(b.shell.locator(`.favorite[data-tab-id="${records[1].id}"]`)).toHaveCount(0);
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
    const sizes = await b.app.evaluate(({ BrowserWindow, screen }) => {
      const window = BrowserWindow.getAllWindows()[0];
      const outer = window.getBounds();
      const content = window.getContentBounds();
      const frameWidth = outer.width - content.width;
      const frameHeight = outer.height - content.height;
      const [minimumWidth, minimumHeight] = window.getMinimumSize();
      const work = screen.getDisplayMatching(outer).workArea;
      const minimum = {
        width: minimumWidth - frameWidth,
        height: minimumHeight - frameHeight,
      };
      return {
        origin: { x: work.x, y: work.y },
        normal: {
          width: Math.max(minimum.width, Math.min(1440, work.width - frameWidth)),
          height: Math.max(minimum.height, Math.min(900, work.height - frameHeight)),
        },
        minimum,
      };
    });
    for (const [name, { width, height }] of [
      ['normal', sizes.normal],
      ['minimum', sizes.minimum],
    ]) {
      await b.app.evaluate(
        ({ BrowserWindow }, { width, height, origin }) => {
          const window = BrowserWindow.getAllWindows()[0];
          window.setPosition(origin.x, origin.y);
          window.setContentSize(width, height);
        },
        { width, height, origin: sizes.origin },
      );
      let accepted,
        previous,
        stableObservations = 0;
      // A display may clamp Cocoa's initial accepted size asynchronously.
      // Use the settled native/renderer geometry for the layout assertions.
      await expect
        .poll(
          async () => {
            const native = await b.app.evaluate(({ BrowserWindow }) =>
              BrowserWindow.getAllWindows()[0].getContentSize(),
            );
            const rendered = await b.shell.evaluate(() => [innerWidth, innerHeight]);
            const signature = native.join(':');
            const agrees = native.every((value, index) => value === rendered[index]);
            stableObservations = agrees && signature === previous ? stableObservations + 1 : agrees ? 1 : 0;
            previous = signature;
            accepted = native;
            return stableObservations >= 3;
          },
          { intervals: [50, 100, 100] },
        )
        .toBe(true);
      t.diagnostic(
        `${name} shortcut viewport: requested ${width}×${height}, native accepted ${accepted.join('×')}`,
      );
      if (name === 'minimum') {
        assert(
          Math.abs(accepted[0] - width) <= 2 && Math.abs(accepted[1] - height) <= 2,
          'The second geometry check must exercise the real native minimum window',
        );
      }
      await expect
        .poll(() =>
          b.shell
            .locator('.shortcut-dialog')
            .evaluate((element) =>
              element.getAnimations().every((animation) => animation.playState !== 'running'),
            ),
        )
        .toBe(true);
      const geometry = () =>
        b.shell.evaluate(() => {
          const rect = (selector) => {
            const { top, bottom, left, right, height } = document
              .querySelector(selector)
              .getBoundingClientRect();
            return { top, bottom, left, right, height };
          };
          const rows = document.querySelector('#shortcut-rows');
          const reset = document.querySelector('[data-action="ui:shortcut-reset-all"]');
          const resetBox = reset.getBoundingClientRect();
          return {
            viewport: { width: innerWidth, height: innerHeight },
            dialog: rect('.shortcut-dialog'),
            header: rect('.shortcut-dialog .dialog-header'),
            search: rect('.shortcut-search-wrap'),
            rows: rect('#shortcut-rows'),
            footer: rect('.shortcut-footer'),
            scrollHeight: rows.scrollHeight,
            clientHeight: rows.clientHeight,
            scrollTop: rows.scrollTop,
            dialogScrollTop: document.querySelector('.shortcut-dialog').scrollTop,
            resetVisible:
              document
                .elementFromPoint(resetBox.left + resetBox.width / 2, resetBox.top + resetBox.height / 2)
                ?.closest('[data-action="ui:shortcut-reset-all"]') === reset,
          };
        });
      await expect
        .poll(
          async () => {
            const view = await geometry();
            return (
              view.dialog.bottom <= view.viewport.height - 23 &&
              view.dialog.left >= 0 &&
              view.dialog.right <= view.viewport.width &&
              view.resetVisible
            );
          },
          { message: `The entire editor and Reset all remain reachable at ${width}×${height}` },
        )
        .toBe(true);
      const before = await geometry();
      assert(before.dialog.height <= 681, 'The editor stays compact on larger windows');
      assert(before.header.top >= before.dialog.top && before.footer.bottom <= before.dialog.bottom);
      assert(before.rows.top >= before.search.bottom && before.rows.bottom <= before.footer.top);
      assert(before.scrollHeight > before.clientHeight, 'The catalog scrolls within its own list');
      await b.shell.locator('#shortcut-rows').evaluate((element) => {
        element.scrollTop = element.scrollHeight;
      });
      const after = await geometry();
      assert(after.scrollTop > 0, 'The last shortcuts are reachable by scrolling the catalog');
      assert.equal(after.dialogScrollTop, 0, 'The outer dialog never scrolls its controls out of view');
      assert.deepEqual(after.header, before.header);
      assert.deepEqual(after.search, before.search);
      assert.deepEqual(after.footer, before.footer);
      assert(after.resetVisible, 'Reset all remains hit-testable after scrolling to the end');
      await b.shell.locator('#shortcut-rows').evaluate((element) => {
        element.scrollTop = 0;
      });
    }
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

test(
  'paste and search opens the clipboard directly and website search uses its saved engine without palette instructions',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/start`);
    await b.app.evaluate(({ clipboard }, url) => clipboard.writeText(url), `${b.base}/pasted`);
    await b.key(
      'V',
      process.platform === 'darwin' ? ['control', 'meta'] : ['control', 'alt'],
      `${b.base}/start`,
    );
    await expect.poll(() => b.guest(`${b.base}/pasted`, 'document.readyState')).toBe('complete');
    assert.equal((await b.state()).tabs.length, 2);
    await b.invoke('settings:update', {
      values: {
        siteSearches: [{ id: 'local', name: 'Local site', keyword: 'local', url: `${b.base}/search?q=%s` }],
      },
    });
    await b.key('T', [b.mod]);
    await expect(b.shell.locator('.command-footer')).toHaveCount(0);
    await b.shell.locator('[data-command-id="search-current-website"]').click();
    await expect(b.shell.locator('#command-input')).toHaveAttribute('placeholder', 'Search Local site');
    await b.shell.locator('#command-input').fill('two words');
    await b.shell.locator('#command-input').press('Enter');
    await expect
      .poll(() => b.guest(`${b.base}/search?q=two%20words`, 'document.readyState'))
      .toBe('complete');
  },
);

test(
  'palette and browser menus keep the native page visible until replacement pixels are ready',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    const url = `${b.base}/handoff`;
    await b.submit(url);
    await b.app.evaluate(({ BrowserWindow, webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      const capture = contents.capturePage.bind(contents);
      globalThis.paletteHandoff = {};
      contents.capturePage = async (...args) => {
        await new Promise((resolve) => setTimeout(resolve, 120));
        const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
          (view) => view.webContents === contents,
        );
        globalThis.paletteHandoff.visibleDuringCapture = view?.getVisible();
        return capture(...args);
      };
    }, url);
    for (const opener of ['command', 'space-picker', 'add-menu']) {
      if (opener === 'command') await b.key('T', [b.mod]);
      else await b.shell.locator(`[data-key="${opener}"]`).click();
      await expect(b.shell.locator('#page-backdrop img')).toHaveCount(1);
      await b.shell.locator('#page-backdrop img').evaluate((image) => image.decode());
      assert.equal(await b.app.evaluate(() => globalThis.paletteHandoff.visibleDuringCapture), true);
      await expect
        .poll(() =>
          b.app.evaluate(({ BrowserWindow, webContents }, url) => {
            const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
            return BrowserWindow.getAllWindows()[0].contentView.children.some(
              (view) => view.webContents === contents && view.getVisible(),
            );
          }, url),
        )
        .toBe(false);
      await b.shell.keyboard.press('Escape');
      await expect(b.shell.locator('#page-backdrop img')).toHaveCount(0);
      assert.equal(await b.guest(url, 'document.readyState'), 'complete');
    }
  },
);

test(
  'canceling a Favorite drag restores the live grid without persisting the preview slot',
  { timeout: 30000 },
  async (t) => {
    const b = await fixture(t);
    const ids = [];
    for (let i = 0; i < 4; i++) {
      const tab = await b.invoke('tab:create', { url: `${b.base}/favorite-${i}`, active: false });
      await b.invoke('tab:favorite', { id: tab.id });
      ids.push(tab.id);
    }
    const tiles = b.shell.locator('.favorite[data-tab-id]');
    await expect(tiles).toHaveCount(4);
    const source = b.shell.locator(`.favorite[data-tab-id="${ids[3]}"]`);
    const target = b.shell.locator(`.favorite[data-tab-id="${ids[0]}"]`);
    await target.hover();
    const initial = await target.boundingBox();
    await source.hover();
    const start = await source.boundingBox();
    await b.shell.mouse.down();
    try {
      await b.shell.mouse.move(start.x + 5, start.y + 5, { steps: 3 });
      await expect(b.shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
      await b.shell.mouse.move(initial.x + 3, initial.y + 20, { steps: 12 });
      await b.shell.mouse.move(initial.x + 4, initial.y + 20, { steps: 2 });
      await expect(b.shell.locator('.favorite-insertion-slot')).toHaveAttribute('data-insertion-index', '0');
      await expect.poll(async () => (await target.boundingBox()).x).toBeGreaterThan(initial.x + 10);
      await b.shell.keyboard.press('Escape');
    } finally {
      await b.shell.mouse.up();
    }
    await expect(b.shell.locator('.favorite-insertion-slot')).toHaveCount(0);
    await expect(b.shell.locator('#app')).not.toHaveAttribute('data-dragging', 'true');
    assert.deepEqual(
      (await b.state()).tabs.filter((tab) => tab.favorite).map((tab) => tab.id),
      ids,
    );
    await expect.poll(async () => (await target.boundingBox()).x).toBe(initial.x);
  },
);

test(
  'ordinary, pinned and folder rows reflow during drag and cancellation restores their order',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/row-0`);
    const ids = [(await b.state()).activeTabId];
    for (let i = 1; i < 3; i++) ids.push((await b.invoke('tab:create', { url: `${b.base}/row-${i}` })).id);
    for (const section of ['today', 'pinned', 'folder']) {
      if (section === 'pinned') for (const id of ids) await b.invoke('tab:pin', { id });
      if (section === 'folder') {
        const folder = await b.invoke('folder:create', { name: 'Reading' });
        for (const id of ids) await b.invoke('tab:move', { id, folderId: folder.id });
      }
      await expect(
        b.shell.locator(
          `${section === 'today' ? '.loose-tabs' : section === 'pinned' ? '.pinned-tabs' : '.folder-tabs'} > .tab-row`,
        ),
      ).toHaveCount(3);
      const source = b.shell.locator(`.tab-row[data-tab-id="${ids[2]}"]`);
      const target = b.shell.locator(`.tab-row[data-tab-id="${ids[0]}"]`);
      await target.hover();
      const initial = await target.boundingBox();
      await source.hover();
      const start = await source.boundingBox();
      const original = (await b.state()).tabs.map((tab) => tab.id);
      await b.shell.mouse.down();
      try {
        await b.shell.mouse.move(start.x + 5, start.y + 5, { steps: 3 });
        await expect(b.shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
        const drop = await target.boundingBox();
        await b.shell.mouse.move(drop.x + 20, drop.y + 5, { steps: 12 });
        await b.shell.mouse.move(drop.x + 21, drop.y + 5, { steps: 2 });
        await expect(b.shell.locator('.tab-insertion-slot')).toBeVisible();
        await expect.poll(async () => (await target.boundingBox()).y).toBeGreaterThan(drop.y + 10);
        assert.deepEqual(
          (await b.state()).tabs.map((tab) => tab.id),
          original,
        );
        assert.equal(await source.evaluate((node) => node.isConnected), true);
        await b.shell.keyboard.press('Escape');
      } finally {
        await b.shell.mouse.up();
      }
      await expect(b.shell.locator('.tab-insertion-slot')).toHaveCount(0);
      await expect(b.shell.locator('#app')).not.toHaveAttribute('data-dragging', 'true');
      assert.deepEqual(
        (await b.state()).tabs.map((tab) => tab.id),
        original,
      );
      await expect
        .poll(async () => (await target.boundingBox()).y, {
          message: `${section} restores its original row position after cancel`,
        })
        .toBe(initial.y);
    }
  },
);

test(
  'dragging across Space dots and held sidebar edges keeps the source until a drop commits',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/traveling-tab`);
    const first = (await b.state()).activeSpaceId;
    const id = (await b.state()).activeTabId;
    await b.guest(`${b.base}/traveling-tab`, 'document.querySelector("textarea").value="Across Spaces"');
    const second = await b.invoke('space:create', { name: 'Reading' });
    await b.invoke('tab:create', { url: `${b.base}/reading-anchor` });
    const third = await b.invoke('space:create', { name: 'Research' });
    await b.invoke('tab:create', { url: `${b.base}/research-anchor` });
    const activePage = () => b.shell.locator('#sidebar-content > .space-page:not(.drag-origin-page)');
    const startDrag = async () => {
      const source = activePage().locator(`.tab-row[data-tab-id="${id}"]`);
      await source.hover();
      await source.evaluate((node) => {
        window.__travelingDragSource = node;
      });
      const box = await source.boundingBox();
      await b.shell.mouse.down();
      await b.shell.mouse.move(box.x + 8, box.y + 5, { steps: 3 });
      await expect(b.shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
    };
    const hoverSpace = async (spaceId) => {
      const dot = await b.shell.locator(`.sidebar-footer .space-dot[data-id="${spaceId}"]`).boundingBox();
      await b.shell.mouse.move(dot.x + dot.width / 2, dot.y + dot.height / 2, { steps: 12 });
      await expect.poll(async () => (await b.state()).activeSpaceId).toBe(spaceId);
      assert.equal(await b.shell.evaluate(() => window.__travelingDragSource.isConnected), true);
      await expect(b.shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
    };
    await b.invoke('space:activate', { id: first });
    await startDrag();
    try {
      await hoverSpace(second.id);
      assert.equal((await b.state()).tabs.find((tab) => tab.id === id).spaceId, first);
      const today = await activePage().locator('.loose-tabs').boundingBox();
      await b.shell.mouse.move(today.x + today.width / 2, today.y + today.height * 0.8, { steps: 10 });
      await b.shell.mouse.move(today.x + today.width / 2 + 1, today.y + today.height * 0.8, { steps: 2 });
      await expect(activePage().locator('.tab-insertion-slot')).toBeVisible();
    } finally {
      await b.shell.mouse.up();
    }
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === id).spaceId)
      .toBe(second.id);
    await expect(b.shell.locator('.drag-origin-page')).toHaveCount(0);
    assert.equal(
      await b.guest(`${b.base}/traveling-tab`, 'document.querySelector("textarea").value'),
      'Across Spaces',
    );

    await startDrag();
    try {
      await hoverSpace(third.id);
      await b.shell.keyboard.press('Escape');
    } finally {
      await b.shell.mouse.up();
    }
    await expect(b.shell.locator('#app')).not.toHaveAttribute('data-dragging', 'true');
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).spaceId, second.id);
    await expect(b.shell.locator('.drag-origin-page')).toHaveCount(0);

    await b.invoke('space:activate', { id: second.id });
    await startDrag();
    try {
      const rail = await b.shell.locator('#sidebar').boundingBox();
      const page = await activePage().boundingBox();
      await b.shell.mouse.move(rail.x + 2, page.y + 80, { steps: 12 });
      await expect.poll(async () => (await b.state()).activeSpaceId).toBe(first);
      await b.shell.mouse.move(rail.x + rail.width - 2, page.y + 80, { steps: 12 });
      await expect.poll(async () => (await b.state()).activeSpaceId).toBe(third.id);
      assert.equal(await b.shell.evaluate(() => window.__travelingDragSource.isConnected), true);
      assert.equal((await b.state()).tabs.find((tab) => tab.id === id).spaceId, second.id);
      await b.shell.keyboard.press('Escape');
    } finally {
      await b.shell.mouse.up();
    }
    await expect(b.shell.locator('#app')).not.toHaveAttribute('data-dragging', 'true');
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).spaceId, second.id);
  },
);
