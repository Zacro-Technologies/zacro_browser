'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'Mac shell reserves native controls, uses Mac conventions and leaves system shortcuts alone',
  { timeout: 30000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-platform-shell-'));
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/platform-shell.cjs')],
      env,
    });
    const errors = [];
    t.after(async () => {
      await app.close();
      assert.equal(path.dirname(directory), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-platform-shell-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      assert.deepEqual(errors, []);
    });
    const shell = await app.firstWindow();
    shell.on('pageerror', (error) => errors.push(error.message));
    await expect(shell.locator('.space-picker')).toBeVisible();
    if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
    const emit = (event) => app.evaluate(({ app }, event) => app.emit('fixture:event', null, event), event);
    await expect(shell.locator('html')).toHaveAttribute('data-platform', 'darwin');
    assert.equal(await shell.locator('.window-controls').count(), 0);
    assert((await shell.locator('[data-key="back"]').boundingBox()).x >= 88);
    assert((await shell.locator('.space-picker').boundingBox()).x < 30);
    await expect(shell.locator('[data-key="sidebar-toggle"]')).toHaveCount(0);
    await expect(shell.locator('[data-key="back"]')).toHaveAttribute('title', 'Back (⌘[)');
    await emit({ type: 'sidebar:toggle' });
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'true');
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    assert((await shell.locator('[data-key="back"]').boundingBox()).x >= 88);
    await app.evaluate(({ app }) => app.emit('fixture:runtime', null, { fullScreen: true }));
    await expect(shell.locator('html')).toHaveAttribute('data-fullscreen', 'true');
    await expect
      .poll(async () => (await shell.locator('[data-key="back"]').boundingBox()).x)
      .toBeLessThan(30);
    await emit({ type: 'sidebar:toggle' });
    // Padding is already zero in full screen while the toolbar is still in
    // the main pane. Wait for the toggle and its width animation, not just CSS.
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'false');
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    await expect
      .poll(() => shell.locator('.navigation').evaluate((element) => getComputedStyle(element).paddingLeft))
      .toBe('0px');
    await app.evaluate(({ app }) => app.emit('fixture:runtime', null, { fullScreen: false }));
    await expect(shell.locator('html')).toHaveAttribute('data-fullscreen', 'false');
    await expect
      .poll(() => shell.locator('.navigation').evaluate((element) => getComputedStyle(element).paddingLeft))
      .toBe('80px');
    assert((await shell.locator('[data-key="back"]').boundingBox()).x >= 88);

    const key = (options) =>
      shell.evaluate((options) => {
        const event = new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...options });
        document.dispatchEvent(event);
        return event.defaultPrevented;
      }, options);
    assert.equal(await key({ key: 'h', metaKey: true }), false, 'Cmd-H belongs to macOS Hide');
    assert.equal(await key({ key: 'Tab', metaKey: true }), false, 'Cmd-Tab belongs to the app switcher');
    assert.equal(await key({ key: 'l', ctrlKey: true }), false, 'Control must not alias Command on Mac');
    assert.equal(await key({ key: 't', metaKey: true, altKey: true }), false);
    assert.equal(await key({ key: 'f', metaKey: true, shiftKey: true }), false);
    assert.equal(await key({ key: 'ArrowLeft', altKey: true }), false, 'Option arrows belong to the editor');
    await emit({ type: 'panel', panel: 'settings' });
    await expect(shell.locator('#panel-title')).toHaveText('Settings');
    await shell.getByRole('button', { name: 'Make default', exact: true }).click();
    await expect(shell.getByRole('button', { name: 'Make default', exact: true })).toHaveCount(0);
    assert(
      (await app.evaluate(({ app }) => app.fixtureCalls)).some(
        (call) => call.action === 'app:set-default-browser',
      ),
    );
    await shell.locator('[data-key="panel-close"]').click();
    await emit({ type: 'panel', panel: 'history' });
    await expect(shell.locator('#panel-title')).toHaveText('History');
    await shell.locator('[data-key="panel-close"]').click();
    await app.evaluate(({ app }) => app.emit('fixture:downloads'));
    await emit({ type: 'panel', panel: 'downloads' });
    await expect(shell.getByRole('button', { name: 'Show in Finder', exact: true })).toBeVisible();
    await shell.locator('[data-key="panel-close"]').click();
    await emit({ type: 'command', mode: 'navigate' });
    await expect(shell.locator('#command-input')).toBeFocused();
    const cdp = await shell.context().newCDPSession(shell);
    await cdp.send('Emulation.setEmulatedMedia', {
      features: [
        { name: 'prefers-contrast', value: 'more' },
        { name: 'prefers-reduced-transparency', value: 'reduce' },
      ],
    });
    const accessibility = await shell.evaluate(() => ({
      blur: getComputedStyle(document.querySelector('.dialog-backdrop')).backdropFilter,
      backdrop: getComputedStyle(document.querySelector('#page-backdrop')).visibility,
      outline: getComputedStyle(document.querySelector('.space-dot.active')).outlineStyle,
    }));
    assert.deepEqual(accessibility, { blur: 'none', backdrop: 'hidden', outline: 'solid' });
    await cdp.detach();
    await shell.keyboard.press('Escape');

    assert.equal(await key({ key: 'Tab', ctrlKey: true }), false, 'The host owns tab shortcuts');
  },
);
