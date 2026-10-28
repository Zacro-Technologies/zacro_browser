'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

let server, base, outside;
before(async () => {
  server = http.createServer(async (request, response) => {
    if (request.url === '/redirect') {
      response.writeHead(302, { Location: `${outside}/redirected` });
      response.end();
      return;
    }
    let body = '';
    for await (const chunk of request) body += chunk;
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(`<!doctype html><title>Saved ${request.url}</title>
      <style>body{font:18px system-ui}a,button{display:block;margin:12px;padding:8px}</style>
      <button id="activate">Activate</button>
      <a id="same" href="/inside">Same host</a>
      <a id="external" href="${outside}/outside">Other host</a>
      <a id="new-window" href="/shift-window" target="_blank">New window</a>
      <a id="prevented" href="${outside}/prevented" onclick="event.preventDefault();window.prevented=true">Application action</a>
      <a id="rel" href="${outside}/noreferrer" rel="noreferrer">Independent navigation</a>
      <a id="hash" href="#section">Same document</a>
      <a id="redirect" href="/redirect">Redirect</a>
      <form method="post" action="${outside}/posted"><input name="draft" value="retained-body"><button id="post">Submit</button></form>
      <p id="method">${request.method}</p><p id="body">${body.replace(/[<>&]/g, '')}</p>`);
  });
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  outside = `http://localhost:${server.address().port}`;
});
after(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

async function launch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-pin-model-'));
  const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 30000 });
  const child = app.process();
  t.after(async () => {
    await app.evaluate(({ app }) => app.exit(0)).catch(() => {});
    await app.close().catch(() => {});
    if (child.exitCode === null) child.kill('SIGKILL');
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(directory).startsWith('zacro-pin-model-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  });
  const shell = await app.firstWindow();
  await shell.waitForFunction(() => Boolean(window.zacro));
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = (url, expression) =>
    app.evaluate(
      ({ webContents }, { url, expression }) => {
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        return contents ? contents.executeJavaScript(expression) : null;
      },
      { url, expression },
    );
  const ready = async (url) => {
    await expect.poll(() => guest(url, 'document.readyState'), { timeout: 15000 }).toBe('complete');
  };
  const navigate = async (url) => {
    await invoke('navigate', { url });
    await expect.poll(async () => (await state()).runtime.page.url, { timeout: 15000 }).toBe(url);
    await ready(url);
  };
  const click = async (url, id, modifiers = []) => {
    const point = await guest(
      url,
      `(() => { const r = document.getElementById(${JSON.stringify(id)}).getBoundingClientRect(); return {x: Math.round(r.x + 8), y: Math.round(r.y + r.height / 2)}; })()`,
    );
    assert(point, `document exists: ${url}`);
    await app.evaluate(
      ({ webContents }, { url, point, modifiers }) => {
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        contents.focus();
        for (const type of ['mouseDown', 'mouseUp'])
          contents.sendInputEvent({ type, ...point, button: 'left', clickCount: 1, modifiers });
      },
      { url, point, modifiers },
    );
  };
  return { app, invoke, state, guest, ready, navigate, click };
}

test(
  'Favorites share their living document across Spaces and retained pins reopen at their saved destination',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    const homeURL = `${base}/favorite-home`;
    await browser.navigate(homeURL);
    const favorite = (await browser.state()).activeTabId;
    await browser.invoke('tab:favorite', { id: favorite });
    await browser.guest(homeURL, 'window.favoriteDraft = "kept"');
    const beforeId = await browser.app.evaluate(
      ({ webContents }, url) => webContents.getAllWebContents().find((item) => item.getURL() === url).id,
      homeURL,
    );
    const space = await browser.invoke('space:create', { name: 'Work' });
    await browser.invoke('tab:activate', { id: favorite });
    const shared = await browser.state();
    assert.equal(shared.activeSpaceId, space.id);
    assert.equal(shared.activeTabId, favorite);
    assert.equal(await browser.guest(homeURL, 'window.favoriteDraft'), 'kept');
    assert.equal(
      await browser.app.evaluate(
        ({ webContents }, url) => webContents.getAllWebContents().find((item) => item.getURL() === url).id,
        homeURL,
      ),
      beforeId,
    );
    await browser.navigate(`${base}/favorite-detail`);
    assert.equal((await browser.state()).tabs.find((tab) => tab.id === favorite).pinnedUrl, homeURL);
    assert.equal(
      (await browser.state()).tabs.find((tab) => tab.id === favorite).pinnedTitle,
      'Saved /favorite-home',
    );
    await browser.invoke('tab:reset-pin', { id: favorite });
    await browser.ready(homeURL);
    await browser.navigate(`${base}/replacement`);
    await browser.invoke('tab:replace-pin', { id: favorite });
    await browser.navigate(`${base}/unsaved-destination`);
    await browser.invoke('tab:close', { id: favorite });
    const closed = (await browser.state()).tabs.find((tab) => tab.id === favorite);
    assert.equal(closed.closed, true);
    assert.equal(closed.url, `${base}/replacement`);
    assert.equal(closed.favorite, true);
    await browser.invoke('tab:activate', { id: favorite });
    await browser.ready(`${base}/replacement`);
    assert.equal(await browser.guest(`${base}/replacement`, 'window.favoriteDraft'), undefined);
  },
);

test(
  'trusted Shift-click previews ordinary links and saved tabs preview external hosts without intercepting forms or app navigation',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    const source = `${base}/links`;
    await browser.navigate(source);
    const tabId = (await browser.state()).activeTabId;
    const initialCount = (await browser.state()).tabs.length;
    await browser.guest(source, 'window.originalDocument = "preserved"');
    await browser.click(source, 'new-window', ['shift']);
    await expect.poll(async () => (await browser.state()).runtime.peek?.url).toBe(`${base}/shift-window`);
    assert.equal(
      (await browser.state()).tabs.length,
      initialCount,
      'Shift+click overrides _blank without making a tab',
    );
    assert.equal(await browser.guest(source, 'window.originalDocument'), 'preserved');
    await browser.invoke('peek:close');
    await browser.invoke('tab:pin', { id: tabId });
    await browser.click(source, 'external');
    await expect.poll(async () => (await browser.state()).runtime.peek?.url).toBe(`${outside}/outside`);
    assert.equal((await browser.state()).tabs.length, initialCount);
    assert.equal(await browser.guest(source, 'window.originalDocument'), 'preserved');
    await browser.invoke('peek:close');
    await browser.click(source, 'prevented');
    await expect.poll(() => browser.guest(source, 'window.prevented')).toBe(true);
    assert.equal((await browser.state()).runtime.peek, null);
    await browser.click(source, 'same');
    await browser.ready(`${base}/inside`);
    assert.equal((await browser.state()).runtime.peek, null);
    await browser.invoke('tab:reset-pin', { id: tabId });
    await browser.ready(source);
    await browser.click(source, 'post');
    await browser.ready(`${outside}/posted`);
    assert.equal(
      await browser.guest(`${outside}/posted`, 'document.getElementById("method").textContent'),
      'POST',
    );
    assert.equal(
      await browser.guest(`${outside}/posted`, 'document.getElementById("body").textContent'),
      'draft=retained-body',
    );
    assert.equal((await browser.state()).runtime.peek, null);
    await browser.invoke('tab:reset-pin', { id: tabId });
    await browser.ready(source);
    await browser.click(source, 'redirect');
    await browser.ready(`${outside}/redirected`);
    assert.equal((await browser.state()).runtime.peek, null);
    await browser.invoke('tab:reset-pin', { id: tabId });
    await browser.ready(source);
    await browser.click(source, 'rel');
    await browser.ready(`${outside}/noreferrer`);
    assert.equal((await browser.state()).runtime.peek, null);
  },
);

test(
  'Reset Pin honors unsaved-document cancellation and keeps Peek available after a cancelled navigation',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    const homeURL = `${base}/saved`;
    const editedURL = `${base}/edited`;
    await browser.navigate(homeURL);
    const tabId = (await browser.state()).activeTabId;
    await browser.invoke('tab:pin', { id: tabId });
    await browser.navigate(editedURL);
    await browser.click(editedURL, 'activate');
    await browser.guest(
      editedURL,
      'window.draft="unsaved";window.addEventListener("beforeunload", event=>{event.preventDefault();event.returnValue="Unsaved"});undefined',
    );
    await browser.app.evaluate(({ dialog }) => {
      globalThis.__pinResetDecision = 0;
      globalThis.__pinResetPrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.__pinResetPrompts++;
        return globalThis.__pinResetDecision;
      };
    });
    await browser.invoke('tab:reset-pin', { id: tabId });
    await expect.poll(() => browser.app.evaluate(() => globalThis.__pinResetPrompts)).toBe(1);
    await expect
      .poll(async () => (await browser.state()).tabs.find((tab) => tab.id === tabId).url)
      .toBe(editedURL);
    assert.equal(await browser.guest(editedURL, 'window.draft'), 'unsaved');
    await browser.click(editedURL, 'same', ['shift']);
    await expect.poll(async () => (await browser.state()).runtime.peek?.url).toBe(`${base}/inside`);
    await browser.invoke('peek:close');
    await browser.app.evaluate(() => {
      globalThis.__pinResetDecision = 1;
    });
    await browser.invoke('tab:reset-pin', { id: tabId });
    await browser.ready(homeURL);
    assert.equal((await browser.state()).tabs.find((tab) => tab.id === tabId).pinnedUrl, homeURL);
  },
);
