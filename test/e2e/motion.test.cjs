'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');
const { browserLayout } = require('../../src/main/layout.cjs');

test(
  'quick repeated actions keep state and focus ahead of presentation motion',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-motion-'));
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    t.after(async () => {
      await app.close();
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-motion-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const shell = await app.firstWindow();
    await shell.emulateMedia({ reducedMotion: 'no-preference' });
    await expect(shell.locator('[data-key="library"]')).toBeVisible();
    await shell.evaluate(() => {
      window.motionSamples = [];
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (frames, options) {
        window.motionSamples.push({ duration: options.duration, delay: options.delay || 0 });
        return animate.call(this, frames, options);
      };
    });
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);

    // Closing releases interaction and restores focus immediately, while the
    // visible chrome slides out using the same non-spring motion as the sidebar.
    await shell.evaluate(() => {
      document.querySelector('[data-key="library"]').focus();
      document.querySelector('[data-key="library"]').click();
      document.querySelector('[data-key="panel-settings"]').click();
    });
    await expect(shell.locator('#app')).toHaveAttribute('data-panel-animating', 'false');
    const close = await shell.evaluate(() => {
      const panel = document.querySelector('#side-panel');
      document.querySelector('[data-key="panel-close"]').click();
      return {
        inert: panel.inert,
        hidden: panel.getAttribute('aria-hidden'),
        layoutOpen: document.querySelector('#app').dataset.panelOpen,
        focus: document.activeElement.dataset.key,
      };
    });
    assert(close.inert);
    assert.equal(close.hidden, 'true');
    assert.equal(close.layoutOpen, 'false');
    assert.equal(close.focus, 'library');
    await expect(shell.locator('#side-panel')).toBeHidden();

    const rapid = await shell.evaluate(() => {
      const open = (panel) => {
        document.querySelector('[data-key="library"]').click();
        document.querySelector(`[data-key="panel-${panel}"]`).click();
      };
      open('settings');
      open('ai');
      document.querySelector('[data-key="panel-close"]').click();
      open('settings');
      return {
        title: document.querySelector('#panel-title').textContent,
        hidden: document.querySelector('#side-panel').hidden,
      };
    });
    assert.equal(rapid.title, 'Settings');
    assert.equal(rapid.hidden, false);
    await expect(shell.locator('#panel-title')).toBeFocused();

    // Settings disclosure is immediately usable even during its short reveal.
    const disclosure = await shell.evaluate(() => {
      const details = document.querySelector('details.setting-section');
      details.querySelector('summary').click();
      return { open: details.open, duration: getComputedStyle(details.children[1]).animationDuration };
    });
    assert(disclosure.open);
    assert(parseFloat(disclosure.duration) <= 0.17);
    await shell.locator('[data-key="panel-close"]').click();

    // Focus chosen before the entrance frame must survive deferred autofocus.
    // Otherwise a fast Enter on Rename can activate the first menu item instead.
    const fixtureTab = await invoke('tab:create', { homePage: true });
    await expect(shell.locator(`[data-key="tab-${fixtureTab.id}"]`)).toBeVisible();
    const earlyFocus = await shell.evaluate(async (id) => {
      document
        .querySelector(`[data-key="tab-${id}"]`)
        .dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
      const rename = document.querySelector('[data-action="ui:tab-rename"]');
      rename.focus();
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return document.activeElement === rename;
    }, fixtureTab.id);
    assert.equal(earlyFocus, true, 'A menu entrance must preserve the user-selected control');
    await shell.keyboard.press('Escape');

    // Folder toggling updates the rows and preserves keyboard position at once.
    const folder = await invoke('folder:create', { name: 'Motion review' });
    const tab = await invoke('tab:create', { url: 'zacro://newtab', active: false });
    await invoke('tab:move', { id: tab.id, folderId: folder.id });
    const heading = shell.locator(`[data-key="folder-${folder.id}"]`);
    await expect(heading).toBeVisible();
    await heading.focus();
    const toggled = await shell.evaluate((id) => {
      document.querySelector(`[data-key="folder-${id}"]`).click();
      const closed = document.querySelector(`[data-key="folder-${id}"]`);
      const first = {
        expanded: closed.getAttribute('aria-expanded'),
        focused: closed === document.activeElement,
      };
      closed.click();
      const opened = document.querySelector(`[data-key="folder-${id}"]`);
      return {
        first,
        expanded: opened.getAttribute('aria-expanded'),
        focused: opened === document.activeElement,
      };
    }, folder.id);
    assert.deepEqual(toggled, {
      first: { expanded: 'false', focused: true },
      expanded: 'true',
      focused: true,
    });

    const space = await invoke('space:create', { name: 'Second Space', color: '#59646e' });
    await expect(shell.locator('#sidebar .tabs-scroll .space-title')).toHaveText('Second Space');
    assert(space.id);

    await shell.locator('[data-key="address"]').click();
    await expect(shell.locator('#command-input')).toBeFocused();
    const dismissed = await shell.evaluate(() => {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      return {
        dialog: Boolean(document.querySelector('.dialog')),
        isolated: document.querySelector('#workspace').inert,
        backdrop: document.querySelector('#page-backdrop').hidden,
      };
    });
    assert.deepEqual(dismissed, { dialog: false, isolated: false, backdrop: true });

    const samples = await shell.evaluate(() => window.motionSamples);
    assert(samples.length >= 2, 'Folder and page affordances retain their lightweight motion');
    assert(samples.every((sample) => sample.duration >= 100 && sample.duration <= 280 && sample.delay === 0));

    await shell.emulateMedia({ reducedMotion: 'reduce' });
    await shell.locator('[data-key="library"]').click();
    await shell.locator('[data-key="panel-settings"]').click();
    await expect(shell.locator('#panel-title')).toBeFocused();
    const reduced = await shell.evaluate(() => ({
      active: document.getAnimations().filter((animation) => animation.playState === 'running').length,
      transition: getComputedStyle(document.querySelector('[data-key="panel-close"]')).transitionDuration,
    }));
    assert.equal(reduced.active, 0);
    assert(reduced.transition.split(',').every((value) => parseFloat(value) === 0));
  },
);

test(
  'a dialog interrupting chrome motion captures the settled native page bounds',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-motion-capture-'));
    const server = http.createServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html' });
      response.end(
        '<!doctype html><title>Motion capture</title><style>body{background:linear-gradient(90deg,#e9d6df,#c1d7df);font:20px system-ui}h1{padding:10vw}</style><h1>Keep this page in place.</h1>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/`;
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    t.after(async () => {
      await app.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-motion-capture-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const shell = await app.firstWindow();
    await shell.emulateMedia({ reducedMotion: 'no-preference' });
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
    await shell.evaluate((url) => window.zacro.invoke('navigate', { url }), url);
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, url) =>
            webContents
              .getAllWebContents()
              .find((item) => item.getURL() === url)
              ?.isLoading(),
          url,
        ),
      )
      .toBe(false);
    await expect(shell.locator('.dialog')).toHaveCount(0);
    await app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          .executeJavaScript(
            'new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))',
          ),
      url,
    );
    await app.evaluate(({ BrowserWindow }, url) => {
      const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
        (item) => item.webContents?.getURL() === url,
      );
      const capture = view.webContents.capturePage.bind(view.webContents);
      globalThis.motionCaptureBounds = [];
      globalThis.motionCaptureResults = [];
      view.webContents.capturePage = (...args) => {
        globalThis.motionCaptureBounds.push(view.getBounds());
        return capture(...args).then((image) => {
          globalThis.motionCaptureResults.push({ size: image.getSize(), empty: image.isEmpty() });
          return image;
        });
      };
    }, url);
    const opening = await shell.evaluate(() => {
      document.querySelector('[data-key="library"]').click();
      const moving = document.querySelector('#app').dataset.panelAnimating;
      // The next action occurs before any animation frame can settle the panel.
      document.querySelector('[data-key="address"]').click();
      return { moving, settled: document.querySelector('#app').dataset.panelAnimating };
    });
    assert.deepEqual(opening, { moving: 'true', settled: 'false' });
    await expect(shell.locator('#command-input')).toBeFocused();
    try {
      await expect(shell.locator('#page-backdrop img')).toHaveCount(1);
    } catch (error) {
      t.diagnostic(
        JSON.stringify(
          await app.evaluate(() => ({
            bounds: globalThis.motionCaptureBounds,
            results: globalThis.motionCaptureResults,
          })),
        ),
      );
      throw error;
    }
    const geometry = await shell.evaluate(() => {
      const css = getComputedStyle(document.documentElement);
      return {
        width: innerWidth,
        height: innerHeight,
        sidebarWidth: parseFloat(css.getPropertyValue('--sidebar')),
        panelWidth: parseFloat(css.getPropertyValue('--panel')),
        contentTop: parseFloat(css.getPropertyValue('--page-top')),
        pageGutter: parseFloat(css.getPropertyValue('--page-gutter')),
      };
    });
    const expected = browserLayout(geometry).primary;
    assert.deepEqual(
      await app.evaluate(() => globalThis.motionCaptureBounds),
      [expected],
      'Capture starts after the native view receives final bounds',
    );
    const backdrop = await shell.locator('.page-backdrop-frame').evaluate((element) => ({
      x: parseFloat(element.style.left),
      y: parseFloat(element.style.top),
      width: parseFloat(element.style.width),
      height: parseFloat(element.style.height),
    }));
    assert.deepEqual(backdrop, expected, 'Backdrop is placed at the same bounds as the settled canvas');
  },
);
