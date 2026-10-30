'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

let server,
  base,
  fixtureOffline = false;
before(async () => {
  server = http.createServer((req, res) => {
    if (fixtureOffline) {
      res.writeHead(503);
      res.end('Offline fixture');
      return;
    }
    const requestURL = new URL(req.url, 'http://fixture.local');
    // Keep navigation pending so the handoff regression cannot pass merely
    // because did-stop-loading arranged the native views later.
    if (requestURL.pathname === '/pending-overlay-navigation') return;
    if (requestURL.pathname === '/peek-icon.png') {
      res.writeHead(200, { 'Content-Type': 'image/png' });
      res.end(fs.readFileSync(path.resolve(__dirname, '../../assets/icon-256.png')));
      return;
    }
    if (requestURL.pathname === '/login-fixture/set') {
      const identity = requestURL.searchParams.get('identity');
      if (!['personal', 'work', 'private'].includes(identity)) {
        res.writeHead(400);
        res.end('Unknown fixture identity');
        return;
      }
      res.setHeader('Set-Cookie', `siteLogin=${identity}; Max-Age=3600; Path=/; HttpOnly; SameSite=Lax`);
    }
    if (requestURL.pathname === '/login-fixture/whoami') {
      const cookies = new Map(
        (req.headers.cookie || '').split(';').map((cookie) => cookie.trim().split('=')),
      );
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(
        JSON.stringify({ login: cookies.get('siteLogin') || null, session: cookies.get('identity') || null }),
      );
      return;
    }
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
      `<!doctype html><html><head><title>${name}</title>${requestURL.pathname === '/peek' ? '<link rel="icon" href="/peek-icon.png">' : ''}<style>body{font:20px system-ui;padding:48px;background:#f5f7fa;color:#243344}h1{font-size:46px}a{display:block;margin:24px 0}section{height:1800px}</style></head><body><h1>${name}</h1><p id="evidence">The fixture has a verified local source.</p><a id="next" href="/b">Read Page B</a><a id="preview" href="/peek">Peek at another page</a><a id="download" href="/download">Download fixture</a><a id="popup" href="/b" target="_blank">Open a new tab</a><input id="password" type="password" value="must-not-share"><section></section></body></html>`,
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

test(
  'navigation during a seamless overlay handoff hides the native page and discards late pixels',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    await b.app.evaluate(async ({ BrowserWindow }, url) => {
      const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
        (item) => item.webContents?.getURL() === url,
      );
      const contents = view.webContents;
      const pixels = await contents.capturePage();
      const capture = contents.capturePage;
      globalThis.handoffRegression = { view, contents, pixels, capture, pending: false };
      contents.capturePage = () =>
        new Promise((resolve) => {
          globalThis.handoffRegression.pending = true;
          globalThis.handoffRegression.release = () => resolve(pixels);
        });
    }, `${base}/a`);
    try {
      await b.invoke('shortcut:run', { id: 'command-palette' });
      await expect(b.page.locator('#command-input')).toBeFocused();
      await expect.poll(() => b.app.evaluate(() => globalThis.handoffRegression.pending)).toBe(true);
      assert.equal(await b.app.evaluate(() => globalThis.handoffRegression.view.getVisible()), true);
      const visibleAtNavigation = await b.app.evaluate(async (_, url) => {
        const { contents, view } = globalThis.handoffRegression;
        const started = new Promise((resolve) =>
          contents.once('did-start-navigation', () => {
            setImmediate(() => resolve(view.getVisible()));
          }),
        );
        void contents.loadURL(url).catch(() => {});
        return started;
      }, `${base}/pending-overlay-navigation`);
      assert.equal(visibleAtNavigation, false, 'Navigation must retire the live handoff immediately');
      await b.app.evaluate(() => globalThis.handoffRegression.release());
      await b.page.evaluate(
        () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      );
      await expect(b.page.locator('#page-backdrop img')).toHaveCount(0);
      await expect(b.page.locator('#command-input')).toBeFocused();
      assert.equal(await b.app.evaluate(() => globalThis.handoffRegression.contents.isLoading()), true);
    } finally {
      await b.app.evaluate(() => {
        const test = globalThis.handoffRegression;
        if (!test) return;
        test.contents.capturePage = test.capture;
        test.release?.();
        test.contents.stop();
        delete globalThis.handoffRegression;
      });
    }
  },
);

async function launch(t, directory) {
  const dir = directory || (await fsp.mkdtemp(path.join(os.tmpdir(), 'zacro-e2e-')));
  const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: dir };
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
  await expect(page.locator('[data-key="address"]')).toBeVisible();
  if (await page.locator('#command-input').count()) await page.keyboard.press('Escape');
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
  const overlay = (expression) =>
    app.evaluate(({ webContents }, expression) => {
      const contents = webContents
        .getAllWebContents()
        .find((item) => item.getURL().endsWith('/peek-overlay.html'));
      return contents?.executeJavaScript(expression);
    }, expression);
  const clickPeekOverlay = async (action = null) => {
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()[0].contentView.children.some(
            (view) => view.webContents?.getURL().endsWith('/peek-overlay.html') && view.getVisible(),
          ),
        ),
      )
      .toBe(true);
    return app.evaluate(async ({ webContents }, action) => {
      const contents = webContents
        .getAllWebContents()
        .find((item) => item.getURL().endsWith('/peek-overlay.html'));
      if (!contents) throw new Error('The native Peek overlay must exist');
      const point = action
        ? await contents.executeJavaScript(`(() => {
      const button = document.querySelector('button[data-action="${action}"]');
      const r = button.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`)
        : { x: 4, y: 4 };
      contents.focus();
      for (const type of ['mouseDown', 'mouseUp'])
        contents.sendInputEvent({ type, ...point, button: 'left', clickCount: 1 });
    }, action);
  };
  return { app, page, dir, state, invoke, guest, navigate, close, overlay, clickPeekOverlay };
}

test(
  'desktop boots with accessible shell, safe preferences and live navigation',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    await expect(b.page.locator('#sidebar')).toBeVisible();
    await expect(b.page.locator('#newtab')).toBeHidden();
    assert.equal((await b.state()).tabs.length, 0);
    await expect(b.page.locator('[data-key="space-picker"]')).toBeVisible();
    await expect(b.page.getByRole('button', { name: /New tab/, exact: false }).first()).toBeVisible();
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
    await b.page.keyboard.press(process.platform === 'darwin' ? 'Meta+l' : 'Control+l');
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
    await expect.poll(async () => (await b.state()).runtime.peek?.phase).toBe('open');
    await expect(b.page.locator('.peek-site')).toHaveCount(0);
    await expect(b.page.locator(`[data-tab-id="${original}"] .peek-tab-badge`)).toBeVisible();
    await expect(b.page.locator('.peek-url')).toHaveCount(0);
    await b.clickPeekOverlay();
    await expect.poll(async () => (await b.state()).runtime.peek).toBe(null);
    assert.equal((await b.state()).activeTabId, original);
    assert.equal(await b.guest('window.savedMarker', `${base}/a`), 'retained');
    assert.equal(await b.guest('window.scrollY', `${base}/a`), 600);
    await b.invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(() => b.guest('document.readyState', `${base}/peek`)).toBe('complete');
    await b.guest('document.getElementById("next").click()', `${base}/peek`);
    await expect.poll(() => b.guest('document.readyState', `${base}/b`)).toBe('complete');
    await b.guest('window.peekMarker = "promoted"', `${base}/b`);
    assert.equal((await b.state()).history.length, 1, 'Unpromoted previews do not add browsing history');
    const nativeIds = () =>
      b.app.evaluate(({ webContents }) =>
        webContents
          .getAllWebContents()
          .filter((w) => !w.getURL().endsWith('/peek-overlay.html'))
          .map((w) => w.id)
          .sort((a, b) => a - b),
      );
    const beforePromotion = await nativeIds();
    await b.invoke('peek:promote');
    await expect.poll(nativeIds).toEqual(beforePromotion);
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
    await expect(b.page.locator('.split-tab-group')).toHaveCount(1);
    await expect(b.page.locator('.split-tab-group .tab-main')).toHaveCount(2);
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
  'website logins and storage survive restart within their profile; private activity does not',
  { timeout: 60000 },
  async (t) => {
    const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'zacro-isolation-'));
    t.after(() => fsp.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
    const b = await launch(t, dir);
    const websiteIdentity = (browser, target) =>
      browser.guest('fetch("/login-fixture/whoami").then((response) => response.json())', target);
    await b.navigate(`${base}/login-fixture/set?identity=personal`);
    await b.navigate(`${base}/a`);
    await b.guest(
      'document.cookie = "identity=personal; path=/"; localStorage.setItem("identity", "personal");',
    );
    assert.deepEqual(await websiteIdentity(b, `${base}/a`), { login: 'personal', session: 'personal' });
    assert(!/siteLogin=/.test(await b.guest('document.cookie', `${base}/a`)), 'Login cookie stays HttpOnly');
    const work = await b.invoke('profile:create', { name: 'Work' });
    const workSpaceId = (await b.state()).activeSpaceId;
    await b.navigate(`${base}/b`);
    assert.equal(await b.guest('document.cookie', `${base}/b`), '');
    assert.equal(await b.guest('localStorage.getItem("identity")', `${base}/b`), null);
    assert.deepEqual(await websiteIdentity(b, `${base}/b`), { login: null, session: null });
    await b.navigate(`${base}/login-fixture/set?identity=work`);
    await b.navigate(`${base}/b`);
    await b.guest(
      'document.cookie = "identity=work; path=/"; localStorage.setItem("identity", "work");',
      `${base}/b`,
    );
    assert.deepEqual(await websiteIdentity(b, `${base}/b`), { login: 'work', session: 'work' });
    await b.invoke('space:activate', { id: 'home' });
    assert.match(await b.guest('document.cookie', `${base}/a`), /identity=personal/);
    assert.equal(await b.guest('localStorage.getItem("identity")', `${base}/a`), 'personal');
    assert.deepEqual(await websiteIdentity(b, `${base}/a`), { login: 'personal', session: 'personal' });
    const privateProfile = await b.invoke('profile:create', { name: 'Private acceptance', private: true });
    await b.navigate(`${base}/private-secret`);
    assert.deepEqual(await websiteIdentity(b, `${base}/private-secret`), { login: null, session: null });
    assert.equal(await b.guest('localStorage.getItem("identity")', `${base}/private-secret`), null);
    await b.navigate(`${base}/login-fixture/set?identity=private`);
    await b.navigate(`${base}/private-secret`);
    await b.guest('localStorage.setItem("identity", "private");', `${base}/private-secret`);
    assert.deepEqual(await websiteIdentity(b, `${base}/private-secret`), { login: 'private', session: null });
    assert.equal(
      await b.app.evaluate(
        ({ webContents }, url) =>
          webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === url)
            .session.isPersistent(),
        `${base}/private-secret`,
      ),
      false,
      'Private login cookies must remain in an in-memory Chromium session',
    );
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
    await restarted.invoke('space:activate', { id: 'home' });
    await restarted.navigate(`${base}/a`);
    assert.deepEqual(await websiteIdentity(restarted, `${base}/a`), { login: 'personal', session: null });
    assert.equal(await restarted.guest('localStorage.getItem("identity")', `${base}/a`), 'personal');
    assert(
      !/siteLogin=/.test(await restarted.guest('document.cookie', `${base}/a`)),
      'Restored login stays HttpOnly',
    );
    await restarted.invoke('space:activate', { id: workSpaceId });
    await restarted.navigate(`${base}/b`);
    assert.deepEqual(await websiteIdentity(restarted, `${base}/b`), { login: 'work', session: null });
    assert.equal(await restarted.guest('localStorage.getItem("identity")', `${base}/b`), 'work');
    await restarted.invoke('profile:create', { name: 'Private acceptance', private: true });
    await restarted.navigate(`${base}/private-after-restart`);
    assert.deepEqual(await websiteIdentity(restarted, `${base}/private-after-restart`), {
      login: null,
      session: null,
    });
    assert.equal(
      await restarted.guest('localStorage.getItem("identity")', `${base}/private-after-restart`),
      null,
    );
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
    await sidebar.locator('[data-key="add-menu"]').click();
    await b.page
      .getByRole('dialog', { name: 'Add', exact: true })
      .getByRole('button', { name: 'New Space', exact: true })
      .click();
    const createSpace = b.page.getByRole('dialog', { name: 'New Space' });
    await createSpace.getByLabel('Space name', { exact: true }).fill('Research lab');
    await createSpace.getByRole('button', { name: 'Create Space', exact: true }).click();
    await expect
      .poll(async () => {
        const s = await b.state();
        return s.spaces.find((space) => space.id === s.activeSpaceId)?.name;
      })
      .toBe('Research lab');
    await expect(createSpace).toHaveCount(0);
    await expect(b.page.locator('#command-input')).toBeFocused();
    const emptySpace = await b.state();
    assert.equal(emptySpace.tabs.filter((tab) => tab.spaceId === emptySpace.activeSpaceId).length, 0);
    await sidebar.locator('[data-key="add-menu"]').click();
    await b.page
      .getByRole('dialog', { name: 'Add', exact: true })
      .getByRole('button', { name: 'New folder', exact: true })
      .click();
    const createFolder = b.page.getByRole('dialog', { name: 'New folder' });
    await createFolder.getByLabel('Folder name', { exact: true }).fill('Evidence');
    await createFolder.getByRole('button', { name: 'Create folder', exact: true }).click();
    await expect.poll(async () => (await b.state()).folders[0]?.name).toBe('Evidence');
    await expect(createFolder).toHaveCount(0);
    await b.page.locator('[data-key="address"]').click();
    await b.page.locator('#command-input').fill(`${base}/a`);
    await b.page.locator('#command-input').press('Enter');
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
      .getByRole('button', { name: 'Add to Favorites', exact: true })
      .click();
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === tabId)?.favorite)
      .toBe(true);
    await sidebar.getByRole('button', { name: 'Library', exact: true }).click();
    await b.page.locator('#library-menu [data-key="panel-settings"]').click();
    await b.page.locator('select[data-setting="searchEngine"]').selectOption('brave');
    await expect.poll(async () => (await b.state()).settings.searchEngine).toBe('brave');
    await b.page.locator('#side-panel summary').filter({ hasText: 'About Zacro' }).click();
    await b.page.locator('#side-panel').getByRole('button', { name: 'Version details', exact: true }).click();
    await expect(b.page.getByRole('dialog', { name: 'About Zacro' })).toContainText('Chromium');
    await b.page.keyboard.press('Escape');
    await expect(b.page.getByRole('dialog')).toHaveCount(0);
  },
);

test(
  'compact menus stay beside their controls and keep bookmark and split workflows accessible',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    const pageActions = b.page.locator('[data-key="address"]');
    const menuAtControl = async (control, title, placement) => {
      let anchor;
      // Host state can arrive before the sidebar's replacement node is ready.
      // Wait for the actual opener rectangle before testing menu placement.
      await expect
        .poll(async () => {
          anchor = await control.boundingBox();
          return Boolean(anchor);
        })
        .toBe(true);
      assert(anchor, `${title} must have a visible opener`);
      await control.click({ button: title === 'Page actions' ? 'right' : 'left' });
      const dialog = b.page.getByRole('dialog', { name: title, exact: true });
      await expect(dialog).toBeVisible();
      await expect
        .poll(async () => {
          const box = await dialog.boundingBox();
          if (!box) return false;
          const gap =
            placement === 'above' ? anchor.y - box.y - box.height : box.y - anchor.y - anchor.height;
          return gap >= 0 && gap <= 8;
        })
        .toBe(true);
      const box = await dialog.boundingBox();
      const viewport = await b.page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
      assert(box.x >= 8 && box.y >= 8, `${title} must stay inside the window`);
      assert(box.x + box.width <= viewport.width - 8 && box.y + box.height <= viewport.height - 8);
      assert(Math.abs(box.x - anchor.x) <= 8, `${title} must align to its sidebar opener`);
      return dialog;
    };

    let menu = await menuAtControl(pageActions, 'Page actions', 'below');
    await expect(menu.locator('[data-key="bookmark"]')).toBeDisabled();
    await menu.focus();
    await b.page.keyboard.press('ArrowDown');
    await expect(menu.getByRole('button', { name: 'Split view', exact: true })).toBeFocused();
    await b.page.keyboard.press('End');
    await expect(menu.getByRole('button', { name: /^Browser menu/ })).toBeFocused();
    await b.page.keyboard.press('Home');
    await expect(menu.getByRole('button', { name: 'Split view', exact: true })).toBeFocused();
    await b.page.keyboard.press('ArrowUp');
    await expect(menu.getByRole('button', { name: /^Browser menu/ })).toBeFocused();
    await b.page.keyboard.press('Escape');
    await expect(pageActions).toBeFocused();

    await b.navigate(`${base}/a`);
    const first = (await b.state()).activeTabId;
    await b.guest('window.menuMarker = "retained while menus open"', `${base}/a`);
    menu = await menuAtControl(pageActions, 'Page actions', 'below');
    const bookmark = menu.locator('[data-key="bookmark"]');
    await bookmark.focus();
    const focusedBookmark = await bookmark.elementHandle();
    for (const saved of [true, false]) {
      // Host changes can arrive after the menu opens. Reconcile this existing
      // control without replacing it or stealing keyboard focus.
      await b.invoke('bookmark:toggle');
      await expect(bookmark).toHaveAttribute('aria-pressed', String(saved));
      await expect(bookmark).toHaveText(saved ? /^Remove bookmark/ : /^Bookmark this page/);
      await expect(bookmark).toBeFocused();
      assert.equal(
        await bookmark.evaluate((element, original) => element === original, focusedBookmark),
        true,
      );
    }
    await focusedBookmark.dispose();
    await menu.getByRole('button', { name: /^Bookmark this page/ }).click();
    await expect(b.page.getByRole('dialog')).toHaveCount(0);
    await expect.poll(async () => (await b.state()).bookmarks.map((item) => item.url)).toEqual([`${base}/a`]);
    menu = await menuAtControl(pageActions, 'Page actions', 'below');
    await expect(menu.locator('[data-key="bookmark"]')).toHaveAttribute('aria-pressed', 'true');
    await menu.getByRole('button', { name: /^Remove bookmark/ }).click();
    await expect.poll(async () => (await b.state()).bookmarks.length).toBe(0);

    menu = await menuAtControl(b.page.locator('[data-key="add-menu"]'), 'Add', 'above');
    await menu.getByRole('button', { name: /^New tab(?:\s|$)/ }).click();
    await expect(b.page.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).activeTabId, first, 'Opening the palette does not create a tab');
    await b.page.locator('#command-input').fill(`${base}/b`);
    await b.page.locator('#command-input').press('Enter');
    await expect.poll(async () => (await b.state()).activeTabId).not.toBe(first);
    await expect.poll(async () => (await b.state()).runtime.page.url).toBe(`${base}/b`);
    menu = await menuAtControl(pageActions, 'Page actions', 'below');
    await menu.getByRole('button', { name: 'Split view', exact: true }).click();
    await b.page
      .getByRole('dialog', { name: 'Choose split view tab', exact: true })
      .getByRole('button', { name: 'Page A', exact: true })
      .click();
    await expect.poll(async () => (await b.state()).runtime.splitTabId).toBe(first);
    await expect(b.page.getByRole('dialog')).toHaveCount(0);
    assert.equal(await b.guest('window.menuMarker', `${base}/a`), 'retained while menus open');

    menu = await menuAtControl(pageActions, 'Page actions', 'below');
    await menu.getByRole('button', { name: 'Unsplit tabs', exact: true }).click();
    await expect.poll(async () => (await b.state()).runtime.splitTabId).toBe(null);

    await b.page.locator('[data-key="library"]').click();
    await expect(b.page.getByRole('menu', { name: 'Library', exact: true })).toBeVisible();
    await b.page.locator('#library-menu [data-key="panel-bookmarks"]').click();
    await expect(b.page.locator('#panel-title')).toHaveText('Bookmarks');
    await expect(b.page.getByRole('dialog')).toHaveCount(0);
    await b.page.keyboard.press('Escape');
    await expect(b.page.locator('[data-key="library"]')).toBeFocused();
  },
);

test(
  'restored tabs retain both back and forward history after close and browser restart',
  { timeout: 60000 },
  async (t) => {
    const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'zacro-nav-restore-'));
    t.after(() => fsp.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
    const b = await launch(t, dir);
    await b.navigate(`${base}/a`);
    const id = (await b.state()).activeTabId;
    await b.navigate(`${base}/b`);
    await b.navigate(`${base}/c`);
    await b.invoke('back');
    await expect.poll(async () => (await b.state()).tabs.find((tab) => tab.id === id)?.url).toBe(`${base}/b`);
    await expect.poll(async () => (await b.state()).runtime.page.canGoForward).toBe(true);
    await b.invoke('tab:close', { id });
    await b.invoke('tab:restore', { id });
    await expect
      .poll(async () => {
        const s = await b.state();
        return !s.runtime.page.loading && s.runtime.page.canGoBack && s.runtime.page.canGoForward;
      })
      .toBe(true);
    await b.close();
    const restarted = await launch(t, dir);
    await expect
      .poll(async () => {
        const s = await restarted.state();
        return !s.runtime.page.loading && s.runtime.page.canGoBack && s.runtime.page.canGoForward;
      })
      .toBe(true);
    await restarted.invoke('forward');
    await expect
      .poll(async () => (await restarted.state()).tabs.find((tab) => tab.id === id)?.url)
      .toBe(`${base}/c`);
    await restarted.invoke('back');
    await expect
      .poll(async () => (await restarted.state()).tabs.find((tab) => tab.id === id)?.url)
      .toBe(`${base}/b`);
    await restarted.invoke('back');
    await expect
      .poll(async () => (await restarted.state()).tabs.find((tab) => tab.id === id)?.url)
      .toBe(`${base}/a`);
    await restarted.close();
  },
);

test(
  'trusted link Peek grows from the click and promotion animates to the full page',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    await b.page.evaluate(() => {
      window.peekFrames = [];
      window.zacro.onEvent((event) => {
        if (event.type === 'peek:motion') window.peekFrames.push(event);
      });
    });
    await b.app.evaluate(async ({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      const point = await contents.executeJavaScript(`(() => {
      const rect = document.querySelector('#preview').getBoundingClientRect();
      return { x: Math.round(rect.x + 15), y: Math.round(rect.y + 15) };
    })()`);
      for (const type of ['mouseDown', 'mouseUp'])
        contents.sendInputEvent({ type, ...point, button: 'left', clickCount: 1, modifiers: ['shift'] });
    }, `${base}/a`);
    await expect.poll(async () => (await b.state()).runtime.peek?.phase).toBe('open');
    const opening = await b.page.evaluate(() => window.peekFrames);
    assert(opening[0].bounds.width < opening.at(-1).bounds.width);
    assert(opening[0].bounds.height < opening.at(-1).bounds.height);
    await expect.poll(() => b.guest('document.readyState', `${base}/peek`)).toBe('complete');
    await b.guest('window.keptDocument = 42', `${base}/peek`);
    await b.invoke('peek:promote');
    const expanding = await b.page.evaluate(() =>
      window.peekFrames.filter((event) => event.phase === 'expanding'),
    );
    assert(expanding.length >= 2);
    assert(expanding.at(-1).bounds.width > expanding[0].bounds.width);
    assert.equal(await b.guest('window.keptDocument', `${base}/peek`), 42);
  },
);

test(
  'Peek marks its source tab with the preview favicon and places round controls beside the card',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    const original = (await b.state()).activeTabId;
    await b.invoke('tab:favorite', { id: original });
    await b.invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(async () => (await b.state()).runtime.peek?.phase).toBe('open');
    await expect.poll(async () => (await b.state()).runtime.peek?.favicon).toMatch(/^data:image\//);
    const previewIcon = (await b.state()).runtime.peek.favicon;
    const badge = b.page.locator(`.favorite[data-tab-id="${original}"] .peek-tab-badge`);
    await expect(badge).toBeVisible();
    await expect(badge.locator('img')).toHaveAttribute('src', previewIcon);
    await expect(badge).toHaveAttribute('aria-label', 'Previewing 127.0.0.1');
    await expect(b.page.locator('.peek-site,.peek-url')).toHaveCount(0);
    const geometry = await b.page.evaluate(() => {
      const rect = (element) => {
        const b = element.getBoundingClientRect();
        return { x: b.x, y: b.y, right: b.right, bottom: b.bottom, width: b.width, height: b.height };
      };
      return {
        card: rect(document.querySelector('.peek-surface')),
        buttons: [...document.querySelectorAll('.peek-controls button')].map(rect),
        workspace: rect(document.querySelector('#workspace')),
      };
    });
    assert.equal(geometry.buttons.length, 2);
    assert(
      geometry.buttons.every(
        (button) => button.x >= geometry.card.right + 4 && button.right <= geometry.workspace.right,
      ),
    );
    assert.equal(geometry.buttons[0].x, geometry.buttons[1].x);
    assert(geometry.buttons[1].y >= geometry.buttons[0].bottom + 4);
    assert(geometry.buttons.every((button) => button.width === button.height));
    const nativeGeometry = await b.overlay(`(() => {
      const rect = element => { const r = element.getBoundingClientRect(); return { x:r.x, y:r.y, right:r.right, bottom:r.bottom, width:r.width, height:r.height }; };
      return { card:rect(document.querySelector('#surface')), buttons:[...document.querySelectorAll('#controls button')].map(rect), width:innerWidth };
    })()`);
    assert.equal(nativeGeometry.buttons.length, 2);
    assert(
      nativeGeometry.buttons.every(
        (button) =>
          button.x >= nativeGeometry.card.right + 4 &&
          button.right <= nativeGeometry.width &&
          button.width === button.height,
      ),
    );
    assert.equal(nativeGeometry.buttons[0].x, nativeGeometry.buttons[1].x);
    assert(nativeGeometry.buttons[1].y >= nativeGeometry.buttons[0].bottom + 4);
    await b.clickPeekOverlay('close');
    await expect.poll(async () => (await b.state()).runtime.peek).toBe(null);
    await expect(b.page.locator('.peek-tab-badge')).toHaveCount(0);
    await b.invoke('tab:pin', { id: original });
    await b.invoke('peek:open', { url: `${base}/peek` });
    await expect(b.page.locator(`.tab-row[data-tab-id="${original}"] .peek-tab-badge`)).toBeVisible();
    await expect.poll(async () => (await b.state()).runtime.peek?.phase).toBe('open');
    await b.clickPeekOverlay('promote');
    await expect.poll(async () => (await b.state()).runtime.peek).toBe(null);
    await expect(b.page.locator('.peek-tab-badge')).toHaveCount(0);
  },
);

test(
  'Peek keeps the source view live under a native tinted overlay and blocks source clicks',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    await b.guest(
      'window.underlayFrames=0; window.underlayClicks=0; document.body.addEventListener("click",()=>window.underlayClicks++); function tick(){window.underlayFrames++;requestAnimationFrame(tick)} tick();',
      `${base}/a`,
    );
    await b.invoke('peek:open', { url: `${base}/peek` });
    await expect.poll(async () => (await b.state()).runtime.peek?.phase).toBe('open');
    const stack = await b.app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()[0].contentView.children.map((view) => ({
        url: view.webContents?.getURL(),
        visible: view.getVisible(),
      })),
    );
    const sourceIndex = stack.findIndex((view) => view.url === `${base}/a`);
    const overlayIndex = stack.findIndex((view) => view.url?.endsWith('/peek-overlay.html'));
    const peekIndex = stack.findIndex((view) => view.url === `${base}/peek`);
    assert(sourceIndex >= 0 && sourceIndex < overlayIndex && overlayIndex < peekIndex, JSON.stringify(stack));
    assert.equal(stack[sourceIndex].visible, true);
    assert.equal(stack[overlayIndex].visible, true);
    const before = await b.guest('window.underlayFrames', `${base}/a`);
    await expect.poll(() => b.guest('window.underlayFrames', `${base}/a`)).toBeGreaterThan(before);
    const surfaces = await b.overlay(`({
      root: getComputedStyle(document.documentElement).backgroundColor,
      body: getComputedStyle(document.body).backgroundColor,
      tint: getComputedStyle(document.querySelector('#veil')).backgroundColor,
      opacity: getComputedStyle(document.querySelector('#veil')).opacity,
    })`);
    assert.equal(surfaces.root, 'rgba(0, 0, 0, 0)');
    assert.equal(surfaces.body, 'rgba(0, 0, 0, 0)');
    assert.notEqual(surfaces.tint, 'rgba(0, 0, 0, 0)');
    assert.equal(surfaces.opacity, '1');
    const previewId = (await b.state()).runtime.peek.id;
    await b.page.locator('[data-key="sidebar-toggle"]').click();
    await expect(b.page.locator('#sidebar')).toBeHidden();
    await expect.poll(() => b.overlay(`!document.querySelector('#sidebar-toggle').hidden`)).toBe(true);
    await b.clickPeekOverlay('sidebar-toggle');
    await expect(b.page.locator('#sidebar')).toBeVisible();
    assert.equal(
      (await b.state()).runtime.peek.id,
      previewId,
      'The reveal control keeps the same live preview',
    );
    await b.app.evaluate(({ webContents }, url) => {
      const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
      wc.focus();
      const modifiers = [process.platform === 'darwin' ? 'meta' : 'control'];
      wc.sendInputEvent({ type: 'keyDown', keyCode: 'L', modifiers });
      wc.sendInputEvent({ type: 'keyUp', keyCode: 'L', modifiers });
    }, `${base}/peek`);
    await expect(b.page.locator('#command-input')).toBeFocused();
    await expect(b.page.locator('#page-backdrop img')).toHaveCount(3);
    await expect
      .poll(() =>
        b.app.evaluate(({ BrowserWindow }, base) => {
          const children = BrowserWindow.getAllWindows()[0].contentView.children;
          return children.every(
            (view) =>
              !view.webContents ||
              !view.getVisible() ||
              (!view.webContents.getURL().startsWith(base) &&
                !view.webContents.getURL().endsWith('/peek-overlay.html')),
          );
        }, base),
      )
      .toBe(true);
    assert.equal(typeof (await b.guest('window.underlayFrames', `${base}/a`)), 'number');
    await b.page.keyboard.press('Escape');
    await expect(b.page.locator('#command-input')).toHaveCount(0);
    await b.clickPeekOverlay();
    await expect.poll(async () => (await b.state()).runtime.peek).toBe(null);
    assert.equal(await b.guest('window.underlayClicks', `${base}/a`), 0);
    const after = await b.app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()[0].contentView.children.map((view) => view.webContents?.getURL()),
    );
    assert.equal(after[0], undefined);
    await b.guest('document.getElementById("next").click()', `${base}/a`);
    await expect.poll(async () => (await b.state()).runtime.page.url).toBe(`${base}/b`);
  },
);

test(
  'Command arrows navigate page history and Command S leaves content-only chrome',
  { timeout: 30000, skip: process.platform !== 'darwin' },
  async (t) => {
    const b = await launch(t);
    await b.navigate(`${base}/a`);
    await b.navigate(`${base}/b`);
    const press = (keyCode) =>
      b.app.evaluate(
        ({ webContents }, { base, keyCode }) => {
          const page = webContents.getAllWebContents().find((wc) => wc.getURL().startsWith(base));
          page.focus();
          page.sendInputEvent({ type: 'keyDown', keyCode, modifiers: ['meta'] });
          page.sendInputEvent({ type: 'keyUp', keyCode, modifiers: ['meta'] });
        },
        { base, keyCode },
      );
    const activeURL = async () => {
      const state = await b.state();
      return state.tabs.find((tab) => tab.id === state.activeTabId)?.url;
    };
    await press('Left');
    await expect.poll(activeURL).toBe(`${base}/a`);
    await press('Right');
    await expect.poll(activeURL).toBe(`${base}/b`);
    await press('S');
    await expect(b.page.locator('#sidebar')).toBeHidden();
    await expect(b.page.locator('#toolbar')).toBeHidden();
    await expect
      .poll(() =>
        b.app.evaluate(({ BrowserWindow }, base) => {
          const win = BrowserWindow.getAllWindows()[0];
          const page = win.contentView.children.find((v) => v.webContents?.getURL().startsWith(base));
          return { x: page?.getBounds().x, y: page?.getBounds().y };
        }, base),
      )
      .toEqual({ x: 8, y: 8 });
    await press('L');
    await expect(b.page.locator('#command-input')).toBeFocused();
    await expect(b.page.locator('#command-input')).toHaveValue(`${base}/b`);
    await b.page.keyboard.press('Escape');
    await press('S');
    await expect(b.page.locator('#sidebar')).toBeVisible();
    await expect(b.page.locator('#toolbar')).toBeVisible();
    const sidebarToggle = b.page.locator('[data-key="sidebar-toggle"]');
    await expect(sidebarToggle).toHaveAccessibleName('Hide sidebar (⌘S)');
    await sidebarToggle.click();
    await expect(b.page.locator('#sidebar')).toBeHidden();
    await expect(b.page.locator('#toolbar')).toBeHidden();
    await expect.poll(() => b.overlay(`document.documentElement.dataset.mode`)).toBe('sidebar');
    assert.deepEqual(
      await b.overlay(
        `({label:document.querySelector('#sidebar-toggle').getAttribute('aria-label'),modal:document.body.getAttribute('aria-modal'),peekControls:!document.querySelector('#controls').hidden})`,
      ),
      { label: 'Show sidebar', modal: null, peekControls: false },
    );
    const reveal = await b.app.evaluate(({ BrowserWindow }, base) => {
      const children = BrowserWindow.getAllWindows()[0].contentView.children;
      const page = children.find((view) => view.webContents?.getURL().startsWith(base));
      const button = children.find((view) => view.webContents?.getURL().endsWith('/peek-overlay.html'));
      return { page: page.getBounds(), button: button.getBounds() };
    }, base);
    assert.equal(reveal.page.y, 8, 'The reveal button does not add an address or caption strip');
    assert.deepEqual(reveal.button, { x: 12, y: 12, width: 32, height: 32 });
    await b.clickPeekOverlay('sidebar-toggle');
    await expect(b.page.locator('#sidebar')).toBeVisible();
    await expect(sidebarToggle).toBeVisible();
  },
);

test(
  'saved Favorite, pin and parked Peek icons survive an offline restart',
  { timeout: 60000 },
  async (t) => {
    const b = await launch(t);
    const favoriteURL = `${base}/peek?favorite`;
    await b.navigate(favoriteURL);
    const favoriteId = (await b.state()).activeTabId;
    await b.invoke('tab:favorite', { id: favoriteId });
    await expect
      .poll(async () => (await b.state()).runtime.pages[favoriteId].favicon)
      .toMatch(/^data:image\//);
    const icon = (await b.state()).runtime.pages[favoriteId].favicon;
    await b.invoke('tab:close', { id: favoriteId });

    await b.navigate(`${base}/peek?pin`);
    const pinId = (await b.state()).activeTabId;
    await b.invoke('tab:pin', { id: pinId });
    await expect.poll(async () => (await b.state()).runtime.pages[pinId].savedFavicon).toBe(icon);
    await b.invoke('tab:close', { id: pinId });

    await b.navigate(`${base}/a`);
    const sourceId = (await b.state()).activeTabId;
    await b.invoke('peek:open', { url: `${base}/peek?parked` });
    await expect.poll(async () => (await b.state()).runtime.peek?.favicon).toBe(icon);
    await b.invoke('tab:create', { url: `${base}/b` });
    await expect(b.page.locator(`.tab-row[data-tab-id="${sourceId}"] .peek-tab-badge img`)).toHaveAttribute(
      'src',
      icon,
    );
    await b.close();
    assert.equal(
      fs.readFileSync(path.join(b.dir, 'browser-state.json'), 'utf8').includes('data:image'),
      false,
    );
    fixtureOffline = true;
    t.after(() => {
      fixtureOffline = false;
    });
    const resumed = await launch(t, b.dir);
    const restored = await resumed.state();
    assert.equal(restored.runtime.pages[favoriteId].loaded, false);
    assert.equal(restored.runtime.pages[pinId].loaded, false);
    assert.equal(restored.runtime.pages[favoriteId].savedFavicon, icon);
    assert.equal(restored.runtime.pages[pinId].savedFavicon, icon);
    assert.equal(restored.runtime.savedPeeks[sourceId].favicon, icon);
    await expect(
      resumed.page.locator(`.favorite[data-tab-id="${favoriteId}"] > .favicon img`),
    ).toHaveAttribute('src', icon);
    await expect(resumed.page.locator(`.tab-row[data-tab-id="${pinId}"] .favicon img`)).toHaveAttribute(
      'src',
      icon,
    );
    await expect(
      resumed.page.locator(`.tab-row[data-tab-id="${sourceId}"] .peek-tab-badge img`),
    ).toHaveAttribute('src', icon);
    await resumed.invoke('tab:activate', { id: favoriteId });
    await expect.poll(async () => (await resumed.state()).runtime.pages[favoriteId].loading).toBe(false);
    assert.equal(
      (await resumed.state()).runtime.pages[favoriteId].savedFavicon,
      icon,
      'A failed online refresh retains the saved icon',
    );
    await resumed.invoke('tab:activate', { id: sourceId });
    await expect.poll(async () => (await resumed.state()).runtime.peek?.sourceTabId).toBe(sourceId);
    await expect(
      resumed.page.locator(`.tab-row[data-tab-id="${sourceId}"] .peek-tab-badge img`),
    ).toHaveAttribute('src', icon);
    await resumed.close();
  },
);
