'use strict';
// No debugger connection: capturing a guest would itself exempt it from archive.
const { app, BrowserWindow, webContents, dialog } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const resultPath = process.env.ZACRO_ARCHIVE_RESULT;
const base = process.env.ZACRO_ARCHIVE_BASE;
if (!resultPath || !base) throw new Error('An isolated archive fixture is required.');
require('../../src/main/main.cjs');
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(read, description) {
  const deadline = performance.now() + 10000;
  while (performance.now() < deadline) {
    const value = await read();
    if (value) return value;
    await pause(25);
  }
  throw new Error('Timed out waiting for ' + description);
}
const realNow = Date.now;
const advance = (hours) => (Date.now = () => realNow() + hours * 3600000);
const guestContents = (url) => webContents.getAllWebContents().find((wc) => wc.getURL() === url);
async function launch() {
  const window = await until(() => BrowserWindow.getAllWindows()[0], 'browser window');
  const shell = window.webContents;
  await until(
    () => shell.getURL().includes('/renderer/index.html') && !shell.isLoading() && window.isVisible(),
    'interface',
  );
  window.moveTop();
  window.focus();
  await until(() => shell.executeJavaScript('Boolean(window.zacro)'), 'bridge');
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
  const guest = (url, code) => guestContents(url)?.executeJavaScript(code, true);
  const open = async (route, pinned = false) => {
    const tab = await invoke('tab:create', { url: base + '/' + route });
    await until(async () => (await guest(tab.url, 'document.readyState')) === 'complete', 'page ' + route);
    assert.equal(guestContents(tab.url).isBeingCaptured(), false);
    if (pinned) await invoke('tab:pin', { id: tab.id });
    return tab;
  };
  const sweep = () => invoke('settings:update', { values: { archiveAfterHours: 12 } });
  const archived = (id) =>
    until(async () => (await state()).archive.some((tab) => tab.id === id), 'archived ' + id);
  return { invoke, state, guest, open, sweep, archived };
}

const cases = [
  async () => {
    const b = await launch();
    const clean = await b.open('clean');
    await b.invoke('tab:update', { id: clean.id, title: 'Read later' });
    const dirty = await b.open('dirty');
    await b.guest(dirty.url, 'document.querySelector("#draft").value="Keep my draft"; undefined');
    const pinned = await b.open('pinned', true);
    const active = await b.open('active');
    advance(13);
    await b.sweep();
    await b.archived(clean.id);
    const state = await b.state();
    assert.equal(
      guestContents(clean.url),
      undefined,
      'A clean loaded tab must actually release its native page',
    );
    assert.equal(state.archive.find((tab) => tab.id === clean.id).title, 'Read later');
    for (const tab of [dirty, pinned, active]) assert.ok(state.tabs.some((item) => item.id === tab.id));
    assert.equal(await b.guest(dirty.url, 'document.querySelector("#draft").value'), 'Keep my draft');
    await b.invoke('tab:restore', { id: clean.id });
    await until(
      async () => (await b.guest(clean.url, 'document.readyState')) === 'complete',
      'restored live page',
    );
    await b.invoke('tab:activate', { id: active.id });
    await b.sweep();
    assert.ok(
      (await b.state()).tabs.some((tab) => tab.id === clean.id),
      'Restoring starts a fresh idle period',
    );
  },
  async () => {
    const b = await launch();
    const veto = await b.open('veto');
    guestContents(veto.url).sendInputEvent({
      type: 'mouseDown',
      x: 30,
      y: 15,
      button: 'left',
      clickCount: 1,
    });
    guestContents(veto.url).sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
    await b.guest(
      veto.url,
      'window.marker="Keep me";addEventListener("beforeunload", event=>{event.preventDefault();event.returnValue="Unsaved"});undefined',
    );
    let prompts = 0;
    dialog.showMessageBoxSync = () => {
      prompts++;
      return 1;
    };
    const media = await b.open('media');
    guestContents(media.url).emit('media-started-playing');
    const downloading = await b.open('downloading');
    await b.guest(downloading.url, 'document.querySelector("#download").click();undefined');
    await until(async () => (await b.state()).downloads.length, 'download');
    const opener = await b.open('opener');
    await b.guest(opener.url, 'window.login=window.open(' + JSON.stringify(base + '/login') + ');undefined');
    await until(() => guestContents(base + '/login'), 'login popup');
    const split = await b.open('split');
    const marker = await b.open('marker');
    const active = await b.open('active');
    await b.invoke('split:toggle', { id: split.id });
    advance(13);
    await b.sweep();
    await b.archived(marker.id);
    const state = await b.state();
    for (const tab of [veto, media, downloading, opener, split, active]) {
      assert.ok(
        state.tabs.some((item) => item.id === tab.id),
        tab.url + ' must remain',
      );
      assert.ok(guestContents(tab.url), tab.url + ' must remain live');
    }
    assert.equal(await b.guest(veto.url, 'window.marker'), 'Keep me');
    assert.equal(prompts, 0, 'Automatic archive must never prompt to discard work');
    await b.invoke('download:cancel', { id: state.downloads[0].id });
  },
  async () => {
    const b = await launch();
    const candidate = await b.open('candidate');
    await b.open('active');
    const wc = guestContents(candidate.url);
    const original = wc.executeJavaScriptInIsolatedWorld.bind(wc);
    let release,
      probing = false;
    wc.executeJavaScriptInIsolatedWorld = async (...args) => {
      const result = await original(...args);
      if (args[0] === 1002) {
        probing = true;
        await new Promise((resolve) => (release = resolve));
      }
      return result;
    };
    advance(13);
    await b.sweep();
    await until(() => probing, 'archive draft check');
    await b.invoke('tab:activate', { id: candidate.id });
    release();
    await pause(150);
    assert.equal((await b.state()).activeTabId, candidate.id);
    assert.equal(
      guestContents(candidate.url),
      wc,
      'Revisiting during a probe must retain the exact document',
    );
    assert.equal(
      (await b.state()).archive.some((tab) => tab.id === candidate.id),
      false,
    );
    wc.executeJavaScriptInIsolatedWorld = original;
  },
  async () => {
    const b = await launch();
    await b.archived('expired');
    const state = await b.state();
    assert.equal(state.activeTabId, 'selected');
    assert.deepEqual(state.tabs.map((tab) => tab.id).sort(), ['recent', 'selected']);
    assert.equal(guestContents(base + '/expired'), undefined);
    assert.equal(guestContents(base + '/recent'), undefined, 'Recent restored tabs remain lazy');
    await until(() => guestContents(base + '/selected'), 'selected startup page');
  },
];

(async () => {
  try {
    await cases[Number(process.env.ZACRO_ARCHIVE_CASE)]();
    await fs.writeFile(resultPath, JSON.stringify({ passed: true }));
    app.exit(0);
  } catch (error) {
    await fs.writeFile(resultPath, JSON.stringify({ passed: false, error: error.stack || error.message }));
    app.exit(1);
  }
})();
