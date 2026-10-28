'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'Library menus keep the live page sharp and preserve keyboard and download workflows',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-library-'));
    const downloads = path.join(directory, 'downloads');
    await fs.mkdir(downloads);
    const server = http.createServer((request, response) => {
      if (request.url === '/notes.txt') {
        response.writeHead(200, {
          'Content-Type': 'text/plain',
          'Content-Disposition': 'attachment; filename="notes.txt"',
        });
        response.end('Keep this downloaded file.');
        return;
      }
      response.writeHead(200, { 'Content-Type': 'text/html' });
      response.end(
        '<!doctype html><title>Library fixture</title><style>body{background:#fff}</style><textarea id="draft"></textarea>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const url = `${base}/page`;
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    t.after(async () => {
      await app.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-library-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const shell = await app.firstWindow();
    const errors = [];
    shell.on('pageerror', (error) => errors.push(error.message));
    await expect(shell.locator('[data-key="library"]')).toBeVisible();
    await shell.emulateMedia({ reducedMotion: 'reduce' });
    await app.evaluate(({ app }, directory) => app.setPath('downloads', directory), downloads);
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const guest = (expression) =>
      app.evaluate(
        ({ webContents }, { url, expression }) =>
          webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === url)
            ?.executeJavaScript(expression),
        { url, expression },
      );
    await invoke('navigate', { url });
    await expect.poll(() => guest('document.readyState')).toBe('complete');
    await guest('document.querySelector("textarea").value="Retained draft"');
    await invoke('bookmark:toggle', { url, title: 'Library reference' });
    const original = await app.evaluate(({ BrowserWindow }, url) => {
      const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
        (item) => item.webContents?.getURL() === url,
      );
      globalThis.libraryCaptures = 0;
      const capture = view.webContents.capturePage.bind(view.webContents);
      view.webContents.capturePage = (...args) => {
        globalThis.libraryCaptures++;
        return capture(...args);
      };
      return { id: view.webContents.id, bounds: view.getBounds() };
    }, url);
    const dpr = await guest('devicePixelRatio');
    const library = shell.locator('[data-key="library"]');
    await library.click();
    const menu = shell.getByRole('menu', { name: 'Library', exact: true });
    await expect(menu.getByRole('menuitemradio')).toHaveCount(7);
    await expect(library).toHaveAttribute('aria-expanded', 'true');
    await invoke('tab:update', {
      id: (await invoke('state:get')).activeTabId,
      title: 'Updated while Library is open',
    });
    await expect(shell.locator('#sidebar .tab-main .title')).toContainText('Updated while Library is open');
    await expect(menu).toBeVisible();
    await expect(library).toHaveAttribute('aria-expanded', 'true');
    await expect(shell.locator('#side-panel')).toBeHidden();
    await expect(shell.locator('#page-backdrop img')).toHaveCount(0);
    const menuBounds = await menu.boundingBox();
    const sidebarBounds = await shell.locator('#sidebar').boundingBox();
    assert(
      menuBounds.x >= sidebarBounds.x &&
        menuBounds.x + menuBounds.width <= sidebarBounds.x + sidebarBounds.width,
    );
    assert.equal(await app.evaluate(() => globalThis.libraryCaptures), 0);
    assert.deepEqual(
      await app.evaluate(({ BrowserWindow }, url) => {
        const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
          (item) => item.webContents?.getURL() === url,
        );
        return { id: view.webContents.id, bounds: view.getBounds() };
      }, url),
      original,
    );
    assert.deepEqual(
      await guest(
        '({ dpr:devicePixelRatio, visible:document.visibilityState, draft:document.querySelector("textarea").value })',
      ),
      { dpr, visible: 'visible', draft: 'Retained draft' },
    );
    await shell.keyboard.press('h');
    await expect(menu.locator('[data-key="panel-history"]')).toBeFocused();
    await shell.keyboard.press('Enter');
    await expect(shell.locator('#panel-title')).toHaveText('History');
    await expect(shell.locator('#panel-search')).toBeFocused();
    await expect(shell.locator('.library-group').first()).toHaveAttribute('aria-label', 'Today');
    await shell.keyboard.press('ArrowDown');
    await expect(shell.locator('.resource-main').first()).toBeFocused();
    await shell.keyboard.press('ArrowUp');
    await expect(shell.locator('#panel-search')).toBeFocused();
    await shell.locator('#panel-chooser').click();
    await expect(menu.locator('[data-key="panel-history"]')).toHaveAttribute('aria-checked', 'true');
    await invoke('history:clear');
    await expect(shell.locator('.empty-state h3')).toHaveText('No history yet');
    await expect(shell.locator('#panel-chooser')).toHaveAttribute('aria-expanded', 'true');
    await expect(menu.locator('[data-key="panel-history"]')).toBeFocused();
    await shell.keyboard.press('Escape');
    await expect(menu).toHaveCount(0);
    await expect(shell.locator('#panel-chooser')).toBeFocused();
    await expect(shell.locator('#side-panel')).toBeVisible();
    await shell.keyboard.press('Escape');
    await expect(shell.locator('#side-panel')).toBeHidden();
    await expect(library).toBeFocused();
    // DOM automation does not change the OS first responder. Establish the
    // same native shell focus as a user's click before focusing the page.
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.focus());
    await library.click();
    await app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          .focus(),
      url,
    );
    await expect(menu).toHaveCount(0);
    await library.click();
    await menu.locator('[data-key="panel-bookmarks"]').click();
    await expect(shell.locator('#side-panel')).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
    await expect(shell.locator('#side-panel')).toHaveCSS('backdrop-filter', 'none');
    await expect(shell.locator('.resource-title')).toHaveText('Library reference');
    assert.equal(await app.evaluate(() => globalThis.libraryCaptures), 0);

    await app.evaluate(
      ({ webContents }, { url, download }) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          .downloadURL(download),
      { url, download: `${base}/notes.txt` },
    );
    await expect.poll(async () => (await invoke('state:get')).downloads[0]?.state).toBe('completed');
    await expect(shell.locator('#panel-title')).toHaveText('Downloads');
    await expect(shell.locator('.download-resource .resource-title')).toHaveText('notes.txt');
    await shell.locator('[data-download-menu]').click();
    await expect(shell.getByRole('menuitem', { name: 'Suggest name', exact: true })).toBeVisible();
    await shell.getByRole('menuitem', { name: 'Rename', exact: true }).click();
    await shell.getByLabel('Filename', { exact: true }).fill('organized-notes.txt');
    await shell.locator('#modal-form button[type="submit"]').click();
    await expect(shell.locator('.download-resource .resource-title')).toHaveText('organized-notes.txt');
    assert.equal(
      await fs.readFile(path.join(downloads, 'organized-notes.txt'), 'utf8'),
      'Keep this downloaded file.',
    );
    await shell.locator('[data-download-menu]').click();
    await shell.getByRole('menuitem', { name: 'Undo rename', exact: true }).click();
    await expect(shell.locator('.download-resource .resource-title')).toHaveText('notes.txt');
    assert.equal(await fs.readFile(path.join(downloads, 'notes.txt'), 'utf8'), 'Keep this downloaded file.');
    await shell.locator('#panel-search').fill('missing file');
    await expect(shell.locator('.empty-state h3')).toHaveText('No matches');
    assert.deepEqual(errors, []);
  },
);
