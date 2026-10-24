'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'quick repeated actions keep state and focus ahead of presentation motion',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-motion-'));
    const env = { ...process.env, ZACRO_USER_DATA: directory };
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
    await expect(shell.locator('[data-key="panel-settings"]')).toBeVisible();
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

    // Stretch an entrance: closing must still release the layout and focus in
    // the click turn rather than waiting for the visual animation's promise.
    const close = await shell.evaluate(() => {
      document.querySelector('[data-key="panel-settings"]').focus();
      document.querySelector('[data-key="panel-settings"]').click();
      const panel = document.querySelector('#side-panel');
      const entrance = panel.getAnimations();
      for (const animation of entrance) animation.effect.updateTiming({ duration: 10000 });
      document.querySelector('[data-key="panel-close"]').click();
      return {
        entered: entrance.length,
        hidden: panel.hidden,
        layoutOpen: document.querySelector('#app').dataset.panelOpen,
        focus: document.activeElement.dataset.key,
      };
    });
    assert(close.entered > 0);
    assert(close.hidden);
    assert.equal(close.layoutOpen, 'false');
    assert.equal(close.focus, 'panel-settings');

    const rapid = await shell.evaluate(() => {
      document.querySelector('[data-key="panel-settings"]').click();
      document.querySelector('[data-key="panel-ai"]').click();
      document.querySelector('[data-key="panel-close"]').click();
      document.querySelector('[data-key="panel-settings"]').click();
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
    const earlyFocus = await shell.evaluate(async () => {
      document
        .querySelector('[data-key="tab-welcome"]')
        .dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
      const rename = document.querySelector('[data-action="ui:tab-rename"]');
      rename.focus();
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return document.activeElement === rename;
    });
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
    await expect(shell.locator('.space-title')).toHaveText('Second Space');
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
    assert(samples.length >= 6);
    assert(samples.every((sample) => sample.duration >= 100 && sample.duration <= 170 && sample.delay === 0));

    await shell.emulateMedia({ reducedMotion: 'reduce' });
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
