'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'first-run tour edits live shortcuts, persists, and leads into a keyboard-only browser workflow',
  { timeout: 90000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-onboarding-'));
    const server = http.createServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html' });
      response.end(
        '<!doctype html><title>Keyboard workspace</title><input aria-label="Page draft"><h1>Keyboard workspace</h1>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/`;
    let app, shell;
    const errors = [];
    const close = async () => {
      if (!app) return;
      const previous = app;
      app = null;
      await previous.close().catch(() => previous.process().kill());
    };
    t.after(async () => {
      await close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-onboarding-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      assert.deepEqual(errors, []);
    });
    const launch = async () => {
      // This fixture deliberately exercises the real first-run default.
      const env = { ...process.env, ZACRO_USER_DATA: directory };
      delete env.ZACRO_SKIP_ONBOARDING;
      delete env.ELECTRON_RUN_AS_NODE;
      app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
      shell = await app.firstWindow();
      shell.on('pageerror', (error) => errors.push(error.message));
      await expect(shell.locator('[data-key="address"]')).toBeVisible();
    };
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    const state = () => invoke('state:get');
    const key = (keyCode, modifiers = [], guest = false) =>
      app.evaluate(
        ({ BrowserWindow, webContents }, input) => {
          const contents = input.guest
            ? webContents.getAllWebContents().find((item) => item.getURL() === input.url)
            : BrowserWindow.getAllWindows()[0].webContents;
          if (!contents) throw new Error('Missing keyboard target');
          contents.focus();
          contents.sendInputEvent({ type: 'keyDown', keyCode: input.keyCode, modifiers: input.modifiers });
          contents.sendInputEvent({ type: 'keyUp', keyCode: input.keyCode, modifiers: input.modifiers });
        },
        { keyCode, modifiers, guest, url },
      );
    const mod = process.platform === 'darwin' ? 'meta' : 'control';
    const chord = process.platform === 'darwin' ? 'Meta' : 'Control';
    await launch();
    await expect(shell.locator('.onboarding-dialog')).toBeVisible();
    await expect(shell.locator('#command-input')).toHaveCount(0);
    await expect(shell.locator('[data-key="sidebar-toggle"], .brand-button')).toHaveCount(0);
    await shell.locator('[data-action="ui:onboarding-step"][data-id="1"]').click();
    const sidebarBinding = shell.locator('[data-shortcut-record="sidebar-toggle"]');
    await sidebarBinding.click();
    await sidebarBinding.press(`${chord}+T`);
    await expect(shell.locator('#onboarding-status')).toContainText('Already used');
    await expect(shell.locator('.onboarding-dialog')).toBeVisible();
    await sidebarBinding.click();
    await sidebarBinding.press(`${chord}+Shift+X`);
    await expect
      .poll(
        async () =>
          (await state()).runtime.shortcuts.find((item) => item.id === 'sidebar-toggle').accelerator,
      )
      .toBe('Mod+Shift+X');
    await expect(sidebarBinding).toContainText('X');
    const ids = new Set();
    for (let step = 0; step < 5; step++) {
      await shell.locator(`[data-action="ui:onboarding-step"][data-id="${step}"]`).click();
      const bindings = await shell
        .locator('.onboarding-dialog kbd')
        .evaluateAll((keys) =>
          keys.map((item) => item.closest('button[data-shortcut-record]')?.dataset.shortcutRecord),
        );
      assert(bindings.length >= 2);
      for (const id of bindings) {
        assert(id, 'Every displayed shortcut is directly editable');
        ids.add(id);
      }
    }
    for (const id of [
      'command-palette',
      'sidebar-toggle',
      'focus-sidebar',
      'recent-tab',
      'preferences',
      'shortcuts',
    ])
      assert(ids.has(id));
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(560, 420));
    await expect(shell.getByRole('button', { name: 'Start browsing', exact: true })).toBeInViewport();
    const overflow = await shell.evaluate(() => {
      const rect = document.querySelector('.onboarding-dialog').getBoundingClientRect();
      return rect.left < 0 || rect.top < 0 || rect.right > innerWidth || rect.bottom > innerHeight;
    });
    assert.equal(overflow, false);
    await shell.getByRole('button', { name: 'Start browsing', exact: true }).click();
    await expect.poll(async () => (await state()).settings.onboardingCompleted).toBe(true);
    await expect(shell.locator('#command-input')).toBeFocused();
    await shell.locator('#command-input').fill(url);
    await shell.locator('#command-input').press('Enter');
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, target) =>
            webContents
              .getAllWebContents()
              .find((item) => item.getURL() === target)
              ?.isLoading(),
          url,
        ),
      )
      .toBe(false);
    await key('X', [mod, 'shift'], true);
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'true');
    await key('X', [mod, 'shift'], true);
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'false');
    const { id: folder } = await invoke('folder:create', { name: 'Reading' });
    const { id: first } = await invoke('tab:create', { url: `${url}one` });
    await invoke('tab:move', { id: first, folderId: folder });
    const { id: second } = await invoke('tab:create', { url: `${url}two` });
    await invoke('tab:move', { id: second, folderId: folder });
    await key('S', [mod, 'alt']);
    await expect(shell.locator(`[data-key="tab-${second}"]`)).toBeFocused();
    await shell.keyboard.press('ArrowLeft');
    const heading = shell.locator(`[data-key="folder-${folder}"]`);
    await expect(heading).toBeFocused();
    await shell.keyboard.press('ArrowLeft');
    await expect(heading).toHaveAttribute('aria-expanded', 'false');
    await shell.keyboard.press('ArrowRight');
    await expect(heading).toHaveAttribute('aria-expanded', 'true');
    await shell.keyboard.press('Shift+F10');
    await expect(shell.getByRole('dialog')).toHaveAttribute('aria-label', 'Folder actions');
    await shell.keyboard.press('Escape');
    await expect(heading).toBeFocused();
    // Compact panels must not keep a manually hidden sidebar inaccessible.
    await key('X', [mod, 'shift']);
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'true');
    await key(',', [mod]);
    await expect(shell.locator('#panel-title')).toHaveText('Settings');
    await key('S', [mod, 'alt']);
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'false');
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    await expect(shell.locator('#side-panel')).toBeHidden();
    await expect(shell.locator(`[data-key="tab-${second}"]`)).toBeFocused();
    const count = (await state()).tabs.length;
    await key('T', [mod]);
    await expect(shell.locator('#command-input')).toBeFocused();
    assert.equal((await state()).tabs.length, count, 'Opening the command bar creates no draft tab');
    await shell.locator('#command-input').fill('/ welcome tour');
    await shell.locator('#command-input').press('Enter');
    await expect(shell.locator('.onboarding-dialog')).toBeVisible();
    await shell.keyboard.press('Escape');
    await expect(shell.locator('.onboarding-dialog')).toHaveCount(0);
    if (process.platform !== 'darwin') {
      await key('F10');
      await expect(shell.getByRole('dialog')).toHaveAttribute('aria-label', 'Browser menu');
      await shell.keyboard.press('Escape');
    }
    await close();
    await launch();
    await expect(shell.locator('.onboarding-dialog')).toHaveCount(0);
    assert.equal((await state()).settings.onboardingCompleted, true);
    assert.equal(
      (await state()).runtime.shortcuts.find((item) => item.id === 'sidebar-toggle').accelerator,
      'Mod+Shift+X',
    );
  },
);
