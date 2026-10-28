'use strict';
// Real native lifecycle checks. A debugger increments Chromium's capturer
// count, which would prevent every sleep and mask the protections under test.
const electron = require('electron');
const { app, BrowserWindow, webContents } = electron;
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const resultPath = process.env.ZACRO_PIN_RESULT;
const base = process.env.ZACRO_PIN_BASE;
if (!resultPath || !base) throw new Error('An isolated lifecycle fixture is required.');
require('../../src/main/main.cjs');
const cases = [];
const test = (name, options, run) => cases.push({ name, run });
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(read, description) {
  const deadline = performance.now() + 8000;
  while (performance.now() < deadline) {
    const value = await read();
    if (value) return value;
    await pause(25);
  }
  throw new Error('Timed out waiting for ' + description);
}
const expect = {
  poll: (read) => ({
    toBe: (value) => until(async () => (await read()) === value, 'expected value ' + value),
  }),
};
async function launch() {
  const window = await until(() => BrowserWindow.getAllWindows()[0], 'browser window');
  const shell = window.webContents;
  await until(
    () => shell.getURL().includes('/renderer/index.html') && !shell.isLoading() && window.isVisible(),
    'visible browser interface',
  );
  window.moveTop();
  window.focus();
  await until(() => shell.executeJavaScript('Boolean(window.zacro)'), 'shell bridge');
  shell.sendInputEvent({ type: 'keyDown', keyCode: 'Escape' });
  shell.sendInputEvent({ type: 'keyUp', keyCode: 'Escape' });
  const directory = path.join(process.env.ZACRO_USER_DATA, 'downloads');
  await fs.mkdir(directory, { recursive: true });
  app.setPath('downloads', directory);
  const invoke = (action, payload = {}) =>
    shell.executeJavaScript(
      'window.zacro.invoke(' + JSON.stringify(action) + ',' + JSON.stringify(payload) + ')',
    );
  const state = () => invoke('state:get');
  const guest = (url, code) =>
    webContents
      .getAllWebContents()
      .find((item) => item.getURL() === url)
      ?.executeJavaScript(code, true) ?? null;
  const pageId = async (url) =>
    webContents.getAllWebContents().find((item) => item.getURL() === url)?.id || null;
  const open = async (route, pinned = false) => {
    const url = base + '/' + route;
    const tab = await invoke('tab:create', { url });
    await expect.poll(() => guest(url, 'document.readyState')).toBe('complete');
    assert.equal(
      webContents
        .getAllWebContents()
        .find((item) => item.getURL() === url)
        .isBeingCaptured(),
      false,
      'The fixture must not capture a page through a debugger',
    );
    if (pinned) await invoke('tab:pin', { id: tab.id });
    return { id: tab.id, url };
  };
  const activate = async (tab) => {
    await invoke('tab:activate', { id: tab.id });
    await expect.poll(() => guest(tab.url, 'document.readyState')).toBe('complete');
  };
  return {
    app: { evaluate: async (fn, argument) => fn(electron, argument) },
    invoke,
    state,
    guest,
    pageId,
    open,
    activate,
  };
}
test(
  'closing a pinned page honors beforeunload, retains its pin/bookmark and wakes a new renderer lazily',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    const favorite = await b.open('close', true);
    const favicon = await until(
      async () => (await b.state()).runtime.pages[favorite.id].favicon,
      'validated favorite icon',
    );
    assert.match(favicon, /^data:image\/png;base64,/);
    await b.invoke('tab:update', { id: favorite.id, title: 'Daily favorite' });
    await b.invoke('bookmark:toggle', { url: favorite.url, title: 'Daily favorite' });
    const original = await b.pageId(favorite.url);
    await b.app.evaluate(({ dialog, webContents }, url) => {
      globalThis.__pinDecision = 0;
      globalThis.__pinPrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.__pinPrompts++;
        return globalThis.__pinDecision;
      };
      const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
      wc.sendInputEvent({ type: 'mouseDown', x: 30, y: 15, button: 'left', clickCount: 1 });
      wc.sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
    }, favorite.url);
    await b.guest(
      favorite.url,
      `document.querySelector('#draft').value='Keep my draft'; window.addEventListener('beforeunload', event => { event.preventDefault(); event.returnValue='Unsaved'; }); undefined`,
    );
    await b.invoke('tab:close', { id: favorite.id });
    assert.equal(await b.pageId(favorite.url), original);
    assert.equal(globalThis.__pinPrompts, 1);
    assert.equal(await b.guest(favorite.url, 'document.querySelector("#draft").value'), 'Keep my draft');
    assert.equal((await b.state()).runtime.pages[favorite.id].loaded, true);
    await b.app.evaluate(() => {
      globalThis.__pinDecision = 1;
    });
    await b.invoke('tab:close', { id: favorite.id });
    const closed = await b.state();
    assert.equal(closed.tabs.find((tab) => tab.id === favorite.id).closed, true);
    assert.equal(closed.tabs.find((tab) => tab.id === favorite.id).customTitle, 'Daily favorite');
    assert.equal(
      closed.runtime.pages[favorite.id].favicon,
      favicon,
      'Closing a page must retain its favorite icon',
    );
    assert.deepEqual(
      [closed.runtime.pages[favorite.id].loaded, closed.runtime.pages[favorite.id].sleeping],
      [false, true],
    );
    assert.equal(closed.archive.length, 0);
    assert.equal(closed.bookmarks.length, 1);
    assert.equal(closed.activeTabId, null);
    const other = await b.open('closed-split-other');
    await b.invoke('split:toggle', { id: favorite.id });
    await expect.poll(() => b.guest(favorite.url, 'document.readyState')).toBe('complete');
    const split = await b.state();
    assert.ok([favorite.id, other.id].includes(split.activeTabId));
    assert.equal(split.runtime.splitTabId, split.activeTabId === favorite.id ? other.id : favorite.id);
    assert.equal(split.runtime.pages[other.id].loaded, true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === favorite.id).closed, undefined);
    assert.equal((await b.state()).runtime.pages[favorite.id].loaded, true);
    await b.invoke('tab:close', { id: favorite.id });
    assert.equal((await b.state()).runtime.splitTabId, null, 'Closing a favorite removes its split pane');
    assert.equal((await b.state()).activeTabId, other.id);
    await b.activate(favorite);
    assert.notEqual(await b.pageId(favorite.url), original);
    assert.equal(await b.guest(favorite.url, 'document.querySelector("#draft").value'), '');
    await b.invoke('tab:pin', { id: favorite.id });
    assert.equal((await b.state()).runtime.pages[favorite.id].loaded, true);
    await b.invoke('tab:close', { id: favorite.id });
    assert.equal(
      (await b.state()).tabs.some((tab) => tab.id === favorite.id),
      false,
    );
  },
);

test(
  'idle sleeping obeys Never/timeout, unloads only clean inactive pins, and preserves dirty documents',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    const clean = await b.open('clean', true);
    const favicon = await until(
      async () => (await b.state()).runtime.pages[clean.id].favicon,
      'validated clean favorite icon',
    );
    const dirty = await b.open('dirty', true);
    await b.guest(dirty.url, 'document.querySelector("#draft").value="An unsaved form"; undefined');
    const active = await b.open('active', true);
    await b.invoke('settings:update', { values: { pinnedSleepMinutes: 0 } });
    await b.app.evaluate(() => {
      globalThis.__realPinNow = Date.now;
      Date.now = () => globalThis.__realPinNow() + 21 * 60000;
    });
    await b.invoke('settings:update', { values: { pinnedSleepMinutes: 0 } });
    assert.equal((await b.state()).runtime.pages[clean.id].loaded, true);
    await b.invoke('settings:update', { values: { pinnedSleepMinutes: 20 } });
    await expect.poll(async () => (await b.state()).runtime.pages[clean.id].sleeping).toBe(true);
    const slept = await b.state();
    assert.equal(
      slept.runtime.pages[clean.id].favicon,
      favicon,
      'Sleeping must retain the validated icon without a live page',
    );
    assert.equal(slept.runtime.pages[dirty.id].loaded, true);
    assert.equal(slept.runtime.pages[active.id].loaded, true);
    assert.equal(
      slept.tabs.find((tab) => tab.id === clean.id).closed,
      undefined,
      'Idle sleep is distinct from explicitly closing a pin',
    );
    assert.equal(await b.guest(dirty.url, 'document.querySelector("#draft").value'), 'An unsaved form');
    await b.app.evaluate(() => {
      Date.now = globalThis.__realPinNow;
    });
    await b.activate(clean);
    assert.equal((await b.state()).runtime.pages[clean.id].loaded, true);
  },
);

test(
  'sleep protects split panes, media and downloads; a beforeunload veto stays silent',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    const favorite = await b.open('protected', true);
    const other = await b.open('other');
    await b.invoke('split:toggle', { id: favorite.id });
    assert.equal((await b.invoke('tab:sleep', { id: favorite.id })).slept, false);
    await b.invoke('split:toggle');
    await b.app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((wc) => wc.getURL() === url)
          .emit('media-started-playing'),
      favorite.url,
    );
    assert.equal((await b.invoke('tab:sleep', { id: favorite.id })).slept, false);
    await b.app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((wc) => wc.getURL() === url)
          .emit('media-paused'),
      favorite.url,
    );
    await b.activate(favorite);
    await b.guest(favorite.url, 'document.querySelector("#download").click(); undefined');
    await expect.poll(async () => (await b.state()).downloads.length).toBe(1);
    await b.activate(other);
    assert.equal((await b.invoke('tab:sleep', { id: favorite.id })).slept, false);
    await b.invoke('download:cancel', { id: (await b.state()).downloads[0].id });
    await expect.poll(async () => (await b.state()).downloads[0].state).toBe('cancelled');
    await b.activate(favorite);
    await b.app.evaluate(({ dialog, webContents }, url) => {
      globalThis.__autoSleepPrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.__autoSleepPrompts++;
        return 1;
      };
      const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
      wc.sendInputEvent({ type: 'mouseDown', x: 30, y: 15, button: 'left', clickCount: 1 });
      wc.sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
    }, favorite.url);
    await b.guest(
      favorite.url,
      'window.unsavedMarker="retained";window.addEventListener("beforeunload", event => {event.preventDefault();event.returnValue="Unsaved";});undefined',
    );
    await b.activate(other);
    assert.equal((await b.invoke('tab:sleep', { id: favorite.id })).slept, false);
    assert.equal(await b.guest(favorite.url, 'window.unsavedMarker'), 'retained');
    assert.equal(await b.app.evaluate(() => globalThis.__autoSleepPrompts), 0);
  },
);

test(
  'trusted edits inside a shadow root protect the pin without exposing form values',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    const favorite = await b.open('shadow', true);
    await b.guest(
      favorite.url,
      'const host=document.createElement("div");document.body.append(host);const root=host.attachShadow({mode:"closed"});const input=document.createElement("input");root.append(input);input.focus();undefined',
    );
    await b.app.evaluate(({ webContents }, url) => {
      const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
      wc.focus();
      wc.insertText('private-shadow-draft');
    }, favorite.url);
    await b.open('shadow-other');
    assert.equal((await b.invoke('tab:sleep', { id: favorite.id })).slept, false);
    assert.ok(!JSON.stringify(await b.state()).includes('private-shadow-draft'));
  },
);

test(
  'retained icons are exact-tab/profile/URL scoped and erased by profile data clearing',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    const favorite = await b.open('icon-retention', true);
    await b.invoke('tab:favorite', { id: favorite.id });
    const initial = await b.state();
    const spaceId = initial.activeSpaceId;
    const profileId = initial.spaces.find((space) => space.id === spaceId).profileId;
    const favicon = await until(
      async () => (await b.state()).runtime.pages[favorite.id].favicon,
      'validated retained icon',
    );
    await b.invoke('tab:close', { id: favorite.id });
    assert.equal((await b.state()).runtime.pages[favorite.id].favicon, favicon);

    // A matching URL in another profile must not inherit a retained raster,
    // including an unloaded favorite which has never contacted the fixture.
    await b.invoke('profile:create', { name: 'Isolated favorite icons' });
    const other = await b.invoke('tab:create', { url: favorite.url, active: false });
    await b.invoke('tab:favorite', { id: other.id });
    const isolated = (await b.state()).runtime.pages[other.id];
    assert.equal(isolated.loaded, false);
    assert.equal(isolated.favicon, null);
    await b.invoke('space:activate', { id: spaceId });
    assert.equal((await b.state()).runtime.pages[favorite.id].favicon, favicon);

    await b.activate(favorite);
    await until(async () => (await b.state()).runtime.pages[favorite.id].favicon, 'restored favorite icon');
    const noIconURL = base + '/no-icon';
    await b.invoke('navigate', { url: noIconURL });
    await expect.poll(() => b.guest(noIconURL, 'document.readyState')).toBe('complete');
    assert.equal(
      (await b.state()).runtime.pages[favorite.id].favicon,
      null,
      'A different URL must not reuse the previous page icon',
    );
    await b.invoke('tab:close', { id: favorite.id });
    assert.equal(
      (await b.state()).runtime.pages[favorite.id].favicon,
      null,
      'Closing the newly navigated page must not retain its previous URL icon',
    );
    const unvisited = await b.invoke('tab:create', { url: favorite.url, active: false });
    assert.equal(
      (await b.state()).runtime.pages[unvisited.id].favicon,
      null,
      'Another tab in the same profile must not inherit a retained icon by URL',
    );

    // Closing a Favorite discards its navigated page and reopens the saved
    // destination. That new document must obtain its own validated icon.
    await b.invoke('tab:activate', { id: favorite.id });
    assert.equal((await b.state()).tabs.find((tab) => tab.id === favorite.id).pinnedUrl, favorite.url);
    await expect.poll(() => b.guest(favorite.url, 'document.readyState')).toBe('complete');
    await until(
      async () => (await b.state()).runtime.pages[favorite.id].favicon,
      'freshly loaded favorite icon',
    );
    await b.invoke('tab:close', { id: favorite.id });
    assert.equal((await b.state()).runtime.pages[favorite.id].favicon, favicon);
    await b.app.evaluate(({ dialog }) => {
      dialog.showMessageBox = async () => ({ response: 1 });
    });
    await b.invoke('data:clear', { profileId });
    const cleared = (await b.state()).runtime.pages[favorite.id];
    assert.equal(cleared.loaded, false);
    assert.equal(
      cleared.favicon,
      null,
      'Clearing profile data must remove icons even for already-closed pages',
    );
  },
);

test(
  'login popups protect the original pinned callback document even after switching away',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    const favorite = await b.open('popup-opener', true);
    const openerContentsId = await b.pageId(favorite.url);
    const other = await b.open('popup-unrelated');
    await b.activate(favorite);
    const popupURL = `${base}/popup-identity`;
    await b.guest(
      favorite.url,
      `window.popupMessages = [];
       window.addEventListener('message', event => {
         if (event.origin === ${JSON.stringify(base)} && event.source === window.popupReference)
           window.popupMessages.push(event.data);
       }); undefined`,
    );
    const popup = async () => {
      await b.guest(
        favorite.url,
        `window.popupReference = window.open(${JSON.stringify(popupURL)}, 'pin-login'); undefined`,
      );
      await expect.poll(() => b.guest(popupURL, 'document.readyState')).toBe('complete');
      const tab = await until(
        async () => (await b.state()).tabs.find((item) => item.url === popupURL),
        'popup tab',
      );
      await expect.poll(async () => (await b.state()).activeTabId).toBe(tab.id);
      const opener = webContents.fromId(openerContentsId);
      assert(opener && !opener.isDestroyed());
      assert.equal(opener.isBeingCaptured(), false, 'No debugger/capture may mask opener sleep eligibility');
      assert.equal(opener.isLoading(), false, 'The opener must be clean and fully loaded');
      return tab;
    };
    const complete = (message) =>
      b
        .guest(
          popupURL,
          `window.opener.postMessage(${JSON.stringify(message)}, ${JSON.stringify(base)}); window.close(); undefined`,
        )
        .catch(() => {});

    await popup();
    assert.equal((await b.invoke('tab:sleep', { id: favorite.id })).slept, false);
    assert.equal(await b.pageId(favorite.url), openerContentsId);
    await complete('foreground callback');
    await expect.poll(async () => (await b.state()).activeTabId).toBe(favorite.id);
    await expect.poll(() => b.guest(favorite.url, 'window.popupMessages[0]')).toBe('foreground callback');
    await expect.poll(() => webContents.getFocusedWebContents()?.id).toBe(openerContentsId);

    const backgroundPopup = await popup();
    await b.activate(other);
    await b.invoke('page:focus');
    const otherContentsId = await b.pageId(other.url);
    await expect.poll(() => webContents.getFocusedWebContents()?.id).toBe(otherContentsId);
    assert.equal(
      (await b.invoke('tab:sleep', { id: favorite.id })).slept,
      false,
      'An open login popup still needs its callback listener while another tab is active',
    );
    assert.equal(await b.pageId(favorite.url), openerContentsId);
    await complete('background callback');
    await expect
      .poll(async () => (await b.state()).tabs.some((item) => item.id === backgroundPopup.id))
      .toBe(false);
    await expect.poll(() => b.guest(favorite.url, 'window.popupMessages[1]')).toBe('background callback');
    assert.equal((await b.state()).activeTabId, other.id, 'A closing background popup must not switch tabs');
    assert.equal(
      webContents.getFocusedWebContents()?.id,
      otherContentsId,
      'A background callback must not steal focus',
    );
    assert.equal(
      (await b.invoke('tab:sleep', { id: favorite.id })).slept,
      true,
      'After its last popup closes, the same clean inactive favorite must become eligible for sleep',
    );
    assert.equal(await b.pageId(favorite.url), null);
    assert.equal((await b.state()).runtime.pages[favorite.id].sleeping, true);
  },
);

(async () => {
  const selected = cases[Number(process.env.ZACRO_PIN_CASE)];
  try {
    if (!selected) throw new Error('Unknown lifecycle case');
    await selected.run({});
    await fs.writeFile(resultPath, JSON.stringify({ passed: true, name: selected.name }));
    app.exit(0);
  } catch (error) {
    await fs.writeFile(
      resultPath,
      JSON.stringify({ passed: false, name: selected?.name, error: error.stack || error.message }),
    );
    app.exit(1);
  }
})();
