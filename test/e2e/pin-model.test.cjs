'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

let server, base, outside;
const requestCounts = new Map();
before(async () => {
  const favicon = await fs.readFile(path.resolve(__dirname, '../../assets/icon-256.png'));
  server = http.createServer(async (request, response) => {
    requestCounts.set(request.url, (requestCounts.get(request.url) || 0) + 1);
    if (request.url === '/favicon.png') {
      response.writeHead(200, { 'Content-Type': 'image/png' });
      response.end(favicon);
      return;
    }
    if (request.url === '/pin-redirect-home' && requestCounts.get(request.url) > 1) {
      response.writeHead(302, { Location: `${base}/pin-redirect-result` });
      response.end();
      return;
    }
    if (request.url === '/redirect') {
      response.writeHead(302, { Location: `${outside}/redirected` });
      response.end();
      return;
    }
    let body = '';
    for await (const chunk of request) body += chunk;
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(`<!doctype html><title>Saved ${request.url}</title><link rel="icon" href="/favicon.png">
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
  return { app, shell, invoke, state, guest, ready, navigate, click };
}

test(
  'same-document pin navigation keeps its validated icon, saved title and exact home URL until native Close',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    const homeURL = `${base}/hash-saved#original`;
    const awayURL = `${base}/hash-saved?view=detail#section`;
    await browser.navigate(homeURL);
    const tabId = (await browser.state()).activeTabId;
    await browser.invoke('tab:pin', { id: tabId });
    await expect
      .poll(async () => (await browser.state()).runtime.pages[tabId].favicon)
      .toMatch(/^data:image\/png;base64,/);
    const savedIcon = (await browser.state()).runtime.pages[tabId].favicon;
    const savedTitle = (await browser.state()).tabs.find((tab) => tab.id === tabId).pinnedTitle;
    const homeRequests = requestCounts.get('/hash-saved');
    await browser.guest(
      homeURL,
      'window.pinDocumentMarker="retained";history.pushState(null,"","?view=detail#section");undefined',
    );
    await expect
      .poll(async () => (await browser.state()).tabs.find((tab) => tab.id === tabId).url)
      .toBe(awayURL);
    const moved = await browser.state();
    assert.equal(moved.tabs.find((tab) => tab.id === tabId).pinnedUrl, homeURL);
    assert.equal(moved.tabs.find((tab) => tab.id === tabId).pinnedTitle, savedTitle);
    assert.equal(moved.runtime.pages[tabId].favicon, savedIcon);
    assert.equal(await browser.guest(awayURL, 'window.pinDocumentMarker'), 'retained');
    assert.equal(requestCounts.get('/hash-saved'), homeRequests);
    await expect(browser.shell.locator(`[data-tab-id="${tabId}"] .pin-away`)).toHaveText('/');
    await browser.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.focus();
      const modifiers = [process.platform === 'darwin' ? 'meta' : 'control'];
      contents.sendInputEvent({ type: 'keyDown', keyCode: 'W', modifiers });
      contents.sendInputEvent({ type: 'keyUp', keyCode: 'W', modifiers });
    }, awayURL);
    await expect
      .poll(async () => (await browser.state()).tabs.find((tab) => tab.id === tabId).closed)
      .toBe(true);
    const closed = (await browser.state()).tabs.find((tab) => tab.id === tabId);
    assert.equal(closed.url, homeURL);
    assert.equal(closed.pinnedUrl, homeURL);
    assert.equal(closed.pinnedTitle, savedTitle);
    assert.equal((await browser.state()).runtime.pages[tabId].loaded, false);
    await expect(browser.shell.locator(`[data-tab-id="${tabId}"] .pin-away`)).toHaveCount(0);
    await browser.invoke('tab:activate', { id: tabId });
    await browser.ready(homeURL);
    assert.equal(await browser.guest(homeURL, 'window.pinDocumentMarker'), undefined);
  },
);

test(
  'redirects never overwrite a pin home and canceled Close preserves the navigated document',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    const homeURL = `${base}/pin-redirect-home`;
    const targetURL = `${base}/pin-redirect-result`;
    await browser.navigate(homeURL);
    const tabId = (await browser.state()).activeTabId;
    await browser.invoke('tab:pin', { id: tabId });
    await browser.invoke('tab:reset-pin', { id: tabId });
    await browser.ready(targetURL);
    assert.equal((await browser.state()).tabs.find((tab) => tab.id === tabId).pinnedUrl, homeURL);
    await browser.click(targetURL, 'activate');
    await browser.guest(
      targetURL,
      'window.keptDraft="draft";window.addEventListener("beforeunload", event=>{event.preventDefault();event.returnValue="Unsaved"});undefined',
    );
    await browser.app.evaluate(({ dialog }) => {
      dialog.showMessageBoxSync = () => 0;
    });
    assert.equal(await browser.invoke('tab:close', { id: tabId }), false);
    const retained = (await browser.state()).tabs.find((tab) => tab.id === tabId);
    assert.equal(retained.closed, undefined);
    assert.equal(retained.url, targetURL);
    assert.equal(retained.pinnedUrl, homeURL);
    assert.equal(await browser.guest(targetURL, 'window.keptDraft'), 'draft');
    await browser.app.evaluate(({ dialog }) => {
      dialog.showMessageBoxSync = () => 1;
    });
    await browser.invoke('tab:close', { id: tabId });
    assert.equal((await browser.state()).tabs.find((tab) => tab.id === tabId).url, homeURL);
  },
);

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

test(
  'Peek motion retains native resolution and documents through promotion, replacement, cancellation and reduced motion',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    const source = `${base}/peek-parent`;
    const previewURL = `${base}/peek-motion`;
    await browser.navigate(source);
    await browser.guest(source, 'window.parentDraft="kept"');
    await browser.shell.evaluate((url) => {
      window.__peekShellFrames = [];
      const sample = (frame, channel) => {
        const element = document.getElementById('peek');
        if (!frame || element.hidden || !['opening', 'open'].includes(frame.phase)) return;
        window.__peekShellFrames.push({
          id: frame.id,
          channel,
          offset: frame.offset,
          paintedOffset: parseFloat(element.style.getPropertyValue('--peek-offset')),
          progress: frame.progress,
          paintedProgress: Number(element.style.getPropertyValue('--peek-progress')),
        });
      };
      window.__stopPeekShellFrames = [
        window.zacro.onState((value) => {
          if (value.runtime?.peek?.url === url) sample(value.runtime.peek, 'state');
        }),
        window.zacro.onEvent((event) => {
          if (event.type === 'peek:motion') sample(event, 'motion');
        }),
      ];
    }, previewURL);
    await browser.app.evaluate(({ systemPreferences, BrowserWindow, webContents }) => {
      systemPreferences.getAnimationSettings = () => ({
        prefersReducedMotion: false,
        shouldRenderRichAnimation: true,
        scrollAnimationsEnabledBySystem: true,
      });
      globalThis.__peekMotionSamples = [];
      const parent = BrowserWindow.getAllWindows()[0].contentView;
      const knownIds = new Set(webContents.getAllWebContents().map((contents) => contents.id));
      const originalAdd = parent.addChildView.bind(parent);
      let restoreBounds;
      parent.addChildView = (view, ...args) => {
        if (view.webContents && !knownIds.has(view.webContents.id) && !restoreBounds) {
          const originalBounds = view.setBounds.bind(view);
          // The entrance begins before its URL commits. Observe the newly
          // attached native surface from its very first real bounds change.
          view.setBounds = (bounds) => {
            originalBounds(bounds);
            globalThis.__peekMotionSamples.push({
              id: view.webContents.id,
              bounds: view.getBounds(),
              zoom: view.webContents.getZoomFactor(),
            });
          };
          restoreBounds = () => {
            view.setBounds = originalBounds;
          };
        }
        return originalAdd(view, ...args);
      };
      globalThis.__stopPeekMotionSamples = () => {
        parent.addChildView = originalAdd;
        restoreBounds?.();
      };
    });
    await browser.invoke('peek:open', { url: previewURL });
    await browser.ready(previewURL);
    await browser.guest(
      previewURL,
      'window.peekDraft="retained";document.querySelector("input[name=draft]").value="Unsaved preview text";undefined',
    );
    await expect.poll(async () => (await browser.state()).runtime.peek?.phase).toBe('open');
    const samples = await browser.app.evaluate(() => {
      globalThis.__stopPeekMotionSamples();
      return globalThis.__peekMotionSamples;
    });
    const shellFrames = await browser.shell.evaluate(() => {
      window.__stopPeekShellFrames.forEach((stop) => stop());
      return window.__peekShellFrames;
    });
    assert(shellFrames.some((frame) => frame.channel === 'state'));
    assert(shellFrames.some((frame) => frame.channel === 'motion' && frame.offset > 0));
    for (const [index, frame] of shellFrames.entries()) {
      assert.equal(frame.paintedOffset, Math.round(frame.offset), 'chrome uses the same native offset');
      assert.equal(frame.paintedProgress, frame.progress);
      if (index) {
        assert.equal(frame.id, shellFrames[index - 1].id);
        assert(frame.progress >= shellFrames[index - 1].progress, 'metadata must not rewind the motion');
      }
    }
    assert(samples.length > 2, 'the native entrance is sampled through multiple frames');
    assert(
      new Set(samples.map((sample) => sample.bounds.y)).size > 1,
      'the live surface translates into place',
    );
    assert.equal(new Set(samples.map((sample) => sample.id)).size, 1);
    assert.equal(
      new Set(samples.map((sample) => `${sample.bounds.width}:${sample.bounds.height}:${sample.zoom}`)).size,
      1,
      'translation must not scale or resize the document',
    );
    const resting = samples.at(-1);
    const peekRectangle = await browser.shell.locator('.peek-body').boundingBox();
    for (const key of ['x', 'y', 'width', 'height'])
      assert.equal(Math.round(peekRectangle[key]), resting.bounds[key]);
    await browser.invoke('peek:promote');
    assert.equal((await browser.state()).runtime.peek, null);
    assert.equal(await browser.guest(previewURL, 'window.peekDraft'), 'retained');
    assert.equal(
      await browser.guest(previewURL, 'document.querySelector("input[name=draft]").value'),
      'Unsaved preview text',
    );
    const promotedId = await browser.app.evaluate(
      ({ webContents }, url) => webContents.getAllWebContents().find((item) => item.getURL() === url).id,
      previewURL,
    );
    assert.equal(promotedId, resting.id);
    const promoted = (await browser.state()).activeTabId;
    await browser.invoke('tab:close', { id: promoted });
    assert.equal(await browser.guest(source, 'window.parentDraft'), 'kept');

    const first = `${base}/peek-race-a`,
      second = `${base}/peek-race-b`;
    await Promise.all([
      browser.invoke('peek:open', { url: first }),
      browser.invoke('peek:open', { url: second }),
    ]);
    await expect.poll(async () => (await browser.state()).runtime.peek?.url).toBe(second);
    await expect.poll(async () => (await browser.state()).runtime.peek?.phase).toBe('open');
    assert.equal(
      await browser.app.evaluate(
        ({ webContents }, url) =>
          webContents.getAllWebContents().filter((item) => item.getURL() === url).length,
        first,
      ),
      0,
      'superseded previews cannot leave orphan native renderers',
    );
    // The entrance can finish before Chromium commits a slow local page.
    // Wait for the living document before dispatching the trusted interaction.
    await browser.ready(second);
    await browser.click(second, 'activate');
    await browser.guest(
      second,
      'window.previewMarker="unsaved";window.addEventListener("beforeunload", event=>{event.preventDefault();event.returnValue="Unsaved"});undefined',
    );
    await browser.app.evaluate(({ dialog }) => {
      dialog.showMessageBoxSync = () => 0;
    });
    assert.equal(await browser.invoke('peek:close'), false);
    assert.equal((await browser.state()).runtime.peek.phase, 'open');
    assert.equal((await browser.state()).runtime.peek.offset, 0);
    assert.equal(await browser.guest(second, 'window.previewMarker'), 'unsaved');
    await browser.app.evaluate(({ dialog }) => {
      dialog.showMessageBoxSync = () => 1;
    });
    await browser.invoke('peek:close');
    assert.equal((await browser.state()).runtime.peek, null);
    assert.equal(await browser.guest(source, 'window.parentDraft'), 'kept');

    await browser.shell.emulateMedia({ reducedMotion: 'reduce' });
    await browser.shell.waitForFunction(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
    await browser.invoke('layout', { reducedMotion: true });
    await browser.invoke('peek:open', { url: `${base}/peek-reduced` });
    const reduced = (await browser.state()).runtime.peek;
    assert.equal(reduced.phase, 'open');
    assert.equal(reduced.offset, 0);
    assert.equal(reduced.progress, 1);
    await browser.invoke('peek:close');
    assert.equal((await browser.state()).runtime.peek, null);
  },
);
