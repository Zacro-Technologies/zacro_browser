'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

let server, base;
before(async () => {
  server = http.createServer((req, res) => {
    if (req.url.startsWith('/download')) {
      res.writeHead(200, {
        'Content-Type': 'text/plain',
        'Content-Disposition': 'attachment; filename="zacro-fixture.txt"',
      });
      res.end('A real Chromium download.');
      return;
    }
    if (req.url === '/redirect') {
      res.writeHead(302, { Location: '/b' });
      res.end();
      return;
    }
    const name = req.url.startsWith('/b') ? 'Page B' : req.url.startsWith('/peek') ? 'Peek page' : 'Page A';
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(
      `<!doctype html><html><head><title>${name}</title><style>body{font:20px system-ui;padding:48px;background:#f5f7fa;color:#243344}h1{font-size:46px}a{display:block;margin:24px 0}section{height:1800px}</style></head><body><h1>${name}</h1><p id="evidence">The fixture has a verified local source.</p><a id="next" href="/b">Read Page B</a><a id="preview" href="/peek">Peek at another page</a><a id="download" href="/download">Download fixture</a><a id="popup" href="/b" target="_blank">Open a new tab</a><input id="password" type="password" value="must-not-share"><section></section></body></html>`,
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {
  if (server) {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

async function launch(t, directory) {
  const dir = directory || (await fsp.mkdtemp(path.join(os.tmpdir(), 'zacro-e2e-')));
  const env = { ...process.env, ZACRO_USER_DATA: dir };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 30000 });
  const errors = [];
  let closed = false;
  const close = async () => {
    if (closed) return;
    closed = true;
    let timer;
    try {
      await Promise.race([
        app.close(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('Browser shutdown timed out.')), 5000);
        }),
      ]);
    } catch (error) {
      await app.evaluate(({ app }) => app.exit(0)).catch(() => app.process().kill());
      throw error;
    } finally {
      clearTimeout(timer);
    }
  };
  t.after(async () => {
    await close();
    if (!directory) await fsp.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, [], 'The application renderer should not throw errors');
  });
  const page = await app.firstWindow();
  page.on('pageerror', (error) => errors.push(error.message));
  await page.waitForFunction(() => Boolean(window.zacro));
  const downloadDirectory = path.join(dir, 'downloads');
  await fsp.mkdir(downloadDirectory, { recursive: true });
  await app.evaluate(({ app }, directory) => app.setPath('downloads', directory), downloadDirectory);
  const invoke = (action, payload = {}) =>
    page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = async (expression, target = null) =>
    app.evaluate(
      async ({ webContents }, { expression, target }) => {
        const wc = webContents
          .getAllWebContents()
          .find((w) => w.getURL().startsWith(target || 'http://127.0.0.1:'));
        if (!wc) return null;
        return wc.executeJavaScript(expression);
      },
      { expression, target },
    );
  const navigate = async (url) => {
    await invoke('navigate', { url });
    await expect
      .poll(
        async () => {
          const s = await state();
          return !s.runtime.page.loading && s.tabs.find((tab) => tab.id === s.activeTabId)?.url;
        },
        { timeout: 15000 },
      )
      .toBe(url);
    await expect.poll(() => guest('document.readyState', url), { timeout: 15000 }).toBe('complete');
  };
  return { app, page, dir, state, invoke, guest, navigate, close };
}

test(
  'desktop boots with accessible shell, safe preferences and live navigation',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    await expect(b.page.locator('#sidebar')).toBeVisible();
    await expect(b.page.locator('#newtab')).toBeVisible();
    await expect.poll(async () => (await b.page.locator('#sidebar').innerText()).length).toBeGreaterThan(20);
    await b.navigate(`${base}/a`);
    assert.equal(await b.guest('typeof window.zacro'), 'undefined');
    assert.equal(await b.guest('typeof require'), 'undefined');
    assert.equal(await b.guest('typeof process'), 'undefined');
    const prefs = await b.app.evaluate(({ webContents }) =>
      webContents
        .getAllWebContents()
        .filter((w) => w.getURL().startsWith('http://127.0.0.1'))
        .map((w) => w.getLastWebPreferences()),
    );
    assert(prefs.length);
    for (const p of prefs) {
      assert.equal(p.sandbox, true);
      assert.equal(p.nodeIntegration, false);
      assert.equal(p.contextIsolation, true);
      assert.equal(p.webSecurity, true);
    }
    await b.navigate(`${base}/b`);
    assert.equal((await b.state()).runtime.page.canGoBack, true);
    await b.invoke('back');
    await expect
      .poll(async () => {
        const s = await b.state();
        return s.tabs.find((tab) => tab.id === s.activeTabId)?.url;
      })
      .toBe(`${base}/a`);
    await b.invoke('forward');
    await expect.poll(async () => (await b.state()).runtime.page.url).toBe(`${base}/b`);
    await assert.rejects(() => b.invoke('navigate', { url: 'javascript:alert(1)' }));
    await b.invoke('bookmark:toggle');
    assert.equal((await b.state()).bookmarks.length, 1);
    await b.invoke('zoom', { delta: 0.2 });
    assert(Math.abs((await b.state()).runtime.page.zoom - 1.2) < 0.01);
    await b.invoke('zoom', { reset: true });
    await b.invoke('tab:create');
    await b.page.keyboard.press('Control+l');
    await expect(b.page.locator('[role="dialog"]')).toBeVisible();
    await b.page.keyboard.press('Escape');
    await expect(b.page.locator('[role="dialog"]')).toHaveCount(0);
    await fsp.mkdir('test-results', { recursive: true });
    await b.page.screenshot({ path: 'test-results/newtab-light.png' });
    await b.invoke('settings:update', { values: { theme: 'dark' } });
    await expect.poll(() => b.page.locator('html').getAttribute('data-theme')).toBe('dark');
    await b.page.screenshot({ path: 'test-results/newtab-dark.png' });
  },
);

test(
  'Peek preserves the underlying document and promotion reuses the page; split uses native views',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    const original = (await b.state()).activeTabId;
    await b.guest('window.scrollTo(0, 600); window.savedMarker = "retained";');
    await b.invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(() => b.guest('document.title', `${base}/peek`)).toBe('Peek page');
    await b.guest('window.peekMarker = "retained-preview"', `${base}/peek`);
    assert((await b.state()).runtime.peek);
    await b.invoke('peek:close');
    assert.equal((await b.state()).activeTabId, original);
    assert.equal(await b.guest('window.savedMarker', `${base}/a`), 'retained');
    assert.equal(await b.guest('window.scrollY', `${base}/a`), 600);
    await b.invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(() => b.guest('document.readyState', `${base}/peek`)).toBe('complete');
    await b.guest('document.getElementById("next").click()', `${base}/peek`);
    await expect.poll(() => b.guest('document.readyState', `${base}/b`)).toBe('complete');
    await b.guest('window.peekMarker = "promoted"', `${base}/b`);
    assert.equal((await b.state()).history.length, 1, 'Unpromoted previews do not add browsing history');
    await b.invoke('peek:promote');
    const promoted = await b.state();
    assert.equal(promoted.runtime.peek, null);
    assert.equal(await b.guest('window.peekMarker', `${base}/b`), 'promoted');
    const visits = promoted.history.filter((visit) => visit.url === `${base}/b`);
    assert.equal(visits.length, 1, 'Promotion records the current preview destination once');
    assert.equal(visits[0].title, 'Page B');
    assert.equal(visits[0].profileId, promoted.tabs.find((tab) => tab.id === promoted.activeTabId).profileId);
    assert.equal(
      promoted.history.some((visit) => visit.url === `${base}/peek`),
      false,
    );
    await b.invoke('split:toggle', { id: original });
    assert.equal((await b.state()).runtime.splitTabId, original);
    const bounds = await b.app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()[0]
        .contentView.children.filter((v) => v.webContents?.getURL().startsWith('http'))
        .map((v) => v.getBounds()),
    );
    assert.equal(bounds.length, 2);
    assert(bounds[0].width < 800 && bounds[1].width < 800);
    assert.notEqual(bounds[0].x, bounds[1].x);
    await b.invoke('split:toggle');
    assert.equal((await b.state()).runtime.splitTabId, null);
  },
);

test(
  'inactive Spaces detach native views while preserving document, form, and scroll state',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    const attached = () =>
      b.app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()[0]
          .contentView.children.filter((view) => view.webContents?.getURL().startsWith('http://127.0.0.1:'))
          .map((view) => ({ id: view.webContents.id, url: view.webContents.getURL() })),
      );
    await b.navigate(`${base}/a`);
    const initial = (await attached())[0];
    await b.guest(
      'window.spaceMarker = "kept alive"; document.getElementById("password").value = "unsaved draft"; window.scrollTo(0, 600);',
      `${base}/a`,
    );
    const second = await b.invoke('space:create', { name: 'Second Space' });
    assert.deepEqual(await attached(), [], 'A new-tab Space exposes no background native page');
    await b.navigate(`${base}/b`);
    assert.deepEqual(
      (await attached()).map((entry) => entry.url),
      [`${base}/b`],
    );
    assert.equal(await b.guest('window.spaceMarker', `${base}/a`), 'kept alive');
    await b.invoke('space:activate', { id: 'home' });
    assert.deepEqual(await attached(), [initial], 'Returning reattaches the same native WebContents');
    assert.equal(await b.guest('document.getElementById("password").value', `${base}/a`), 'unsaved draft');
    assert.equal(await b.guest('window.scrollY', `${base}/a`), 600);
    await b.page.locator('[data-key="address"]').click();
    await expect(b.page.getByRole('dialog')).toBeVisible();
    await expect.poll(async () => (await attached()).length).toBe(0);
    await b.page.keyboard.press('Escape');
    await expect.poll(attached).toEqual([initial]);
    await b.invoke('space:activate', { id: second.id });
    assert.deepEqual(
      (await attached()).map((entry) => entry.url),
      [`${base}/b`],
    );
    const live = await b.app.evaluate(
      ({ webContents }) =>
        webContents
          .getAllWebContents()
          .filter((contents) => contents.getURL().startsWith('http://127.0.0.1:')).length,
    );
    assert.equal(live, 2, 'Detaching must not destroy or duplicate retained pages');
  },
);

test(
  'profiles isolate real cookies and storage; private activity is absent after restart',
  { timeout: 60000 },
  async (t) => {
    const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'zacro-isolation-'));
    t.after(() => fsp.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
    const b = await launch(t, dir);
    await b.navigate(`${base}/a`);
    await b.guest(
      'document.cookie = "identity=personal; path=/"; localStorage.setItem("identity", "personal");',
    );
    const work = await b.invoke('profile:create', { name: 'Work' });
    await b.navigate(`${base}/b`);
    assert.equal(await b.guest('document.cookie', `${base}/b`), '');
    assert.equal(await b.guest('localStorage.getItem("identity")', `${base}/b`), null);
    await b.guest('document.cookie = "identity=work; path=/"', `${base}/b`);
    await b.invoke('space:activate', { id: 'home' });
    assert.match(await b.guest('document.cookie', `${base}/a`), /identity=personal/);
    assert.equal(await b.guest('localStorage.getItem("identity")', `${base}/a`), 'personal');
    const privateProfile = await b.invoke('profile:create', { name: 'Private acceptance', private: true });
    await b.navigate(`${base}/private-secret`);
    assert.equal(
      (await b.state()).history.some((h) => h.profileId === privateProfile.id),
      false,
    );
    await b.close();
    const disk = JSON.parse(await fsp.readFile(path.join(dir, 'browser-state.json'), 'utf8'));
    assert(!JSON.stringify(disk).includes('private-secret'));
    assert(!disk.profiles.some((p) => p.private));
    assert(disk.profiles.some((p) => p.id === work.id));
    const restarted = await launch(t, dir);
    assert.equal((await restarted.state()).profiles.length, 2);
    assert((await restarted.state()).tabs.some((tab) => tab.url === `${base}/a`));
    await restarted.close();
  },
);

test(
  'Chromium downloads are recorded and rename/undo preserve extension and bytes',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    await b.guest('document.getElementById("download").click()');
    await expect
      .poll(async () => (await b.state()).downloads[0]?.state, { timeout: 15000 })
      .toBe('completed');
    const download = (await b.state()).downloads[0];
    assert.equal(await fsp.readFile(download.path, 'utf8'), 'A real Chromium download.');
    const renamed = await b.invoke('download:rename', { id: download.id, name: 'renamed-fixture.txt' });
    assert.equal(path.basename(renamed.path), 'renamed-fixture.txt');
    assert.equal(await fsp.readFile(renamed.path, 'utf8'), 'A real Chromium download.');
    await assert.rejects(() => b.invoke('download:rename', { id: download.id, name: '../escape.txt' }));
    await assert.rejects(() => b.invoke('download:rename', { id: download.id, name: 'renamed.exe' }));
    await b.invoke('download:undo', { id: download.id });
    assert.equal(await fsp.readFile(download.path, 'utf8'), 'A real Chromium download.');
    assert.equal(fs.existsSync(renamed.path), false);
  },
);

test(
  'sidebar and settings controls complete real organization workflows through the UI',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    const sidebar = b.page.locator('#sidebar');
    await sidebar.getByRole('button', { name: 'New Space', exact: true }).click();
    const createSpace = b.page.getByRole('dialog', { name: 'Create a Space' });
    await createSpace.getByLabel('Space name', { exact: true }).fill('Research lab');
    await createSpace.getByRole('button', { name: 'Create Space', exact: true }).click();
    await expect
      .poll(async () => {
        const s = await b.state();
        return s.spaces.find((space) => space.id === s.activeSpaceId)?.name;
      })
      .toBe('Research lab');
    await expect(b.page.getByRole('dialog')).toHaveCount(0);
    await sidebar.getByRole('button', { name: 'New folder', exact: true }).click();
    const createFolder = b.page.getByRole('dialog', { name: 'Give your tabs a home' });
    await createFolder.getByLabel('Folder name', { exact: true }).fill('Evidence');
    await createFolder.getByRole('button', { name: 'Create folder', exact: true }).click();
    await expect.poll(async () => (await b.state()).folders[0]?.name).toBe('Evidence');
    await b.page.locator('#home-query').fill(`${base}/a`);
    await b.page.locator('#home-query').press('Enter');
    await expect.poll(async () => (await b.state()).runtime.page.url).toBe(`${base}/a`);
    await expect
      .poll(async () => {
        const s = await b.state();
        return s.tabs.find((tab) => tab.id === s.activeTabId)?.title;
      })
      .toBe('Page A');
    const tabId = (await b.state()).activeTabId;
    await b.page.locator(`[data-key="tab-${tabId}"]`).click({ button: 'right' });
    await b.page
      .getByRole('dialog', { name: 'Tab actions' })
      .getByRole('button', { name: 'Rename tab', exact: true })
      .click();
    const renameTab = b.page.getByRole('dialog', { name: 'Rename tab' });
    await renameTab.getByLabel('Tab name', { exact: true }).fill('Reference document');
    await renameTab.getByRole('button', { name: 'Rename', exact: true }).click();
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === tabId)?.title)
      .toBe('Reference document');
    await b.page.locator(`[data-key="tab-${tabId}"]`).click({ button: 'right' });
    await b.page
      .getByRole('dialog', { name: 'Tab actions' })
      .getByRole('button', { name: 'Pin to favorites', exact: true })
      .click();
    await expect.poll(async () => (await b.state()).tabs.find((tab) => tab.id === tabId)?.pinned).toBe(true);
    await sidebar.getByRole('button', { name: 'Settings', exact: true }).click();
    await b.page.locator('select[data-setting="searchEngine"]').selectOption('brave');
    await expect.poll(async () => (await b.state()).settings.searchEngine).toBe('brave');
    await b.page.locator('#side-panel').getByRole('button', { name: 'Version details', exact: true }).click();
    await expect(b.page.getByRole('dialog', { name: 'About Zacro' })).toContainText('Chromium');
    await b.page.keyboard.press('Escape');
    await expect(b.page.getByRole('dialog')).toHaveCount(0);
  },
);
