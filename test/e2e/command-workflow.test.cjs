'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-command-workflow-'));
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      `<!doctype html><title>Workflow ${request.url}</title><h1>Saved workflow evidence</h1><textarea id="draft"></textarea><p>${request.url}</p>`,
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
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
    assert(path.basename(directory).startsWith('zacro-command-workflow-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, [], 'No renderer errors during the command workflow');
  });
  const launch = async () => {
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    shell = await app.firstWindow();
    shell.on('pageerror', (error) => errors.push(error.message));
    await shell.waitForFunction(() => Boolean(window.zacro));
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
  };
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = (url, expression) =>
    app.evaluate(
      ({ webContents }, { url, expression }) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          ?.executeJavaScript(expression),
      { url, expression },
    );
  const key = (keyCode, modifiers = [], url = null) =>
    app.evaluate(
      ({ BrowserWindow, webContents }, { keyCode, modifiers, url }) => {
        const contents = url
          ? webContents.getAllWebContents().find((item) => item.getURL() === url)
          : BrowserWindow.getAllWindows()[0].webContents;
        if (!contents) throw new Error(`No shortcut target: ${url || 'shell'}`);
        contents.focus();
        contents.sendInputEvent({ type: 'keyDown', keyCode, modifiers });
        contents.sendInputEvent({ type: 'keyUp', keyCode, modifiers });
      },
      { keyCode, modifiers, url },
    );
  const submit = async (url) => {
    await expect(shell.locator('#command-input')).toBeFocused();
    await shell.locator('#command-input').fill(url);
    await shell.locator('#command-input').press('Enter');
    await expect.poll(() => guest(url, 'document.readyState')).toBe('complete');
    await expect(shell.getByRole('dialog')).toHaveCount(0);
  };
  await launch();
  return {
    get app() {
      return app;
    },
    get shell() {
      return shell;
    },
    directory,
    base,
    close,
    launch,
    invoke,
    state,
    guest,
    key,
    submit,
    mod: process.platform === 'darwin' ? 'meta' : 'control',
  };
}

test(
  'command opening is tabless; submission, empty Spaces and restored sessions keep their intended targets',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).tabs.length, 0);
    assert.equal((await b.state()).activeTabId, null);
    await expect(b.shell.locator('#newtab')).toBeHidden();
    await b.submit(`${b.base}/first`);
    const initial = (await b.state()).activeTabId;
    await b.guest(`${b.base}/first`, 'document.querySelector("textarea").value="Keep this draft"');
    await b.key('T', [b.mod], `${b.base}/first`);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).tabs.length, 1);
    assert.equal((await b.state()).activeTabId, initial);
    await b.shell.keyboard.press('Escape');
    assert.equal((await b.state()).tabs.length, 1);
    await b.key('T', [b.mod]);
    await b.submit(`${b.base}/second`);
    const second = (await b.state()).activeTabId;
    assert.notEqual(second, initial);
    assert.equal((await b.state()).tabs.length, 2);
    await b.key('L', [b.mod], `${b.base}/second`);
    await b.submit(`${b.base}/replacement`);
    assert.equal((await b.state()).tabs.length, 2);
    assert.equal((await b.state()).activeTabId, second);
    assert.equal(
      await b.guest(`${b.base}/first`, 'document.querySelector("textarea").value'),
      'Keep this draft',
    );
    const space = await b.invoke('space:create', { name: 'Empty Space' });
    await expect(b.shell.locator('#command-input')).toBeFocused();
    assert.equal((await b.state()).tabs.filter((tab) => tab.spaceId === space.id).length, 0);
    await b.submit(`${b.base}/space-page`);
    assert.equal((await b.state()).tabs.filter((tab) => tab.spaceId === space.id).length, 1);
    const saved = (await b.state()).activeTabId;
    await b.close();
    await b.launch();
    await expect.poll(() => b.guest(`${b.base}/space-page`, 'document.readyState')).toBe('complete');
    await expect(b.shell.getByRole('dialog')).toHaveCount(0);
    assert.equal((await b.state()).activeTabId, saved);
    await expect(b.shell.locator('#newtab')).toBeHidden();
    const home = await b.invoke('tab:create', { homePage: true });
    await expect(b.shell.locator('#newtab')).toBeVisible();
    assert.equal((await b.state()).tabs.find((tab) => tab.id === home.id).homePage, true);
    await expect(b.shell.locator('#command-input')).toHaveCount(0);
  },
);

test(
  'mouse drags through favorites, Space pins and Today preserve live pages and persist across restarts',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const row = (id) => b.shell.locator(`.tab-row[data-tab-id="${id}"]`);
    const pin = (id) => b.shell.locator(`.favorite[data-tab-id="${id}"]`);
    const pinnedOrder = () =>
      b.shell
        .locator('.favorite[data-tab-id]')
        .evaluateAll((elements) => elements.map((element) => element.dataset.tabId));
    const mouseDrag = async (source, target, { x = 0.5, y = 0.5, feedback = 'drag-over' } = {}) => {
      // Hover waits for a stable, attached row and retries if page metadata
      // replaces the sidebar while a newly restored tab finishes loading.
      await source.hover();
      const start = await source.boundingBox();
      assert(start, 'The dragged tab must be visible');
      const startX = start.x + start.width * 0.4;
      const startY = start.y + start.height / 2;
      await b.shell.mouse.move(startX, startY);
      await b.shell.mouse.down();
      try {
        await b.shell.mouse.move(startX + 10, startY + 2, { steps: 3 });
        await expect(b.shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
        // The empty pinned area grows after dragstart. Measure the destination
        // afterwards, just as a pointer follows the visible drop target.
        const end = await target.boundingBox();
        assert(end, 'The drop destination must be visible');
        const endX = end.x + end.width * x;
        const endY = end.y + end.height * y;
        await b.shell.mouse.move(endX, endY, { steps: 12 });
        await b.shell.mouse.move(endX + 1, endY, { steps: 2 });
        await expect(target).toHaveClass(new RegExp(`\\b${feedback}\\b`));
      } finally {
        await b.shell.mouse.up();
      }
      await expect(b.shell.locator('#app')).not.toHaveAttribute('data-dragging', 'true');
    };
    await b.submit(`${b.base}/drag-pin`);
    const id = (await b.state()).activeTabId;
    await b.guest(`${b.base}/drag-pin`, 'document.querySelector("textarea").value="Pinned draft"');
    await mouseDrag(row(id), b.shell.locator('.favorites[data-drop-favorites]'));
    await expect.poll(async () => (await b.state()).tabs.find((tab) => tab.id === id)?.pinned).toBe(true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).favorite, true);
    await expect(pin(id)).toBeVisible();
    assert.equal((await b.state()).tabs.length, 1);
    assert.equal(
      await b.guest(`${b.base}/drag-pin`, 'document.querySelector("textarea").value'),
      'Pinned draft',
    );
    const second = await b.invoke('tab:create', { url: `${b.base}/second-pin` });
    await expect.poll(() => b.guest(`${b.base}/second-pin`, 'document.readyState')).toBe('complete');
    await b.guest(`${b.base}/second-pin`, 'document.querySelector("textarea").value="Second retained draft"');
    await expect(row(second.id)).toBeVisible();
    await mouseDrag(row(second.id), pin(id), { x: 0.75, feedback: 'drop-after' });
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === second.id)?.pinned)
      .toBe(true);
    await expect.poll(pinnedOrder).toEqual([id, second.id]);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).folderId, null);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).favorite, true);

    await mouseDrag(pin(second.id), pin(id), { x: 0.25, feedback: 'drop-before' });
    await expect.poll(pinnedOrder).toEqual([second.id, id]);
    assert.deepEqual(
      (await b.state()).tabs.filter((tab) => tab.favorite).map((tab) => tab.id),
      [second.id, id],
    );
    assert.equal(
      await b.guest(`${b.base}/second-pin`, 'document.querySelector("textarea").value'),
      'Second retained draft',
      'Dragging preserves the existing live page and its draft',
    );
    const loose = await b.invoke('tab:create', { url: `${b.base}/loose-anchor` });
    await b.close();
    await b.launch();
    await expect.poll(pinnedOrder).toEqual([second.id, id]);
    await expect(row(loose.id)).toBeVisible();
    await mouseDrag(pin(second.id), row(loose.id), { y: 0.75, feedback: 'drop-after' });
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === second.id)?.pinned)
      .toBe(false);
    await expect(pin(second.id)).toHaveCount(0);
    await expect(row(second.id)).toBeVisible();
    await expect
      .poll(() =>
        b.shell
          .locator('.loose-tabs .tab-row')
          .evaluateAll((elements) => elements.map((element) => element.dataset.tabId)),
      )
      .toEqual([loose.id, second.id]);
    assert.equal((await b.state()).tabs.length, 3, 'Moving a tab never duplicates or closes it');
    await b.close();
    await b.launch();
    await expect.poll(pinnedOrder).toEqual([id]);
    await expect(row(second.id)).toBeVisible();
    assert.equal((await b.state()).tabs.find((tab) => tab.id === id).pinned, true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).pinned, false);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).favorite, false);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).folderId, null);
    await mouseDrag(row(second.id), b.shell.locator('.pinned-tabs[data-drop-pinned]'));
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === second.id)?.pinned)
      .toBe(true);
    assert.equal((await b.state()).tabs.find((tab) => tab.id === second.id).favorite, false);
    await expect(b.shell.locator(`.pinned-tabs .tab-row[data-tab-id="${second.id}"]`)).toBeVisible();
    await expect(pin(second.id)).toHaveCount(0);
    await expect.poll(pinnedOrder).toEqual([id]);
    await b.close();
    await b.launch();
    await expect(b.shell.locator(`.pinned-tabs .tab-row[data-tab-id="${second.id}"]`)).toBeVisible();
    await expect.poll(pinnedOrder).toEqual([id]);
    assert.equal((await b.state()).tabs.length, 3);
  },
);

test(
  'keyword Tab site search supports custom templates, validation, encoded queries and restart',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const input = () => b.shell.locator('#command-input');
    await input().fill('/manage site search');
    await input().press('Enter');
    await expect(input()).toHaveAttribute('placeholder', 'Site Search');
    await input().press('Enter');
    const editor = b.shell.getByRole('dialog', { name: 'Add site search', exact: true });
    await editor.getByRole('textbox', { name: 'Name', exact: true }).fill('Local documentation');
    await editor.getByRole('textbox', { name: 'Keyword', exact: true }).fill('w');
    await editor
      .getByRole('textbox', { name: 'Search URL', exact: true })
      .fill(`${b.base}/search?q=%s&source=docs`);
    await editor.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(editor.getByRole('alert')).toContainText('already assigned');
    await editor.getByRole('textbox', { name: 'Keyword', exact: true }).fill('docs');
    await editor.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(input()).toHaveAttribute('placeholder', 'Site Search');
    const saved = (await b.state()).settings.siteSearches.find((engine) => engine.keyword === 'docs');
    assert(saved, 'Custom site search must persist through the settings validator');
    await input().press('Escape');
    await input().fill('DOCS');
    await input().press('Tab');
    await expect(input()).toHaveAttribute('placeholder', 'Search Local documentation');
    await expect(input()).toHaveAttribute('aria-label', 'Search Local documentation');
    await expect(b.shell.locator('#command-status')).toHaveAttribute('aria-live', 'polite');
    await expect(b.shell.locator('#command-status')).toContainText('Type to search Local documentation');
    await expect(input()).toHaveValue('');
    const query = 'browser & state=other / 日本語';
    await input().fill(query);
    await input().press('Escape');
    await expect(input()).toHaveValue('DOCS');
    await input().press('Tab');
    await input().fill(query);
    await input().press('Enter');
    const url = `${b.base}/search?q=${encodeURIComponent(query)}&source=docs`;
    await expect.poll(() => b.guest(url, 'document.readyState')).toBe('complete');
    assert.equal(new URL((await b.state()).tabs[0].url).searchParams.get('q'), query);
    assert.equal((await b.state()).tabs.length, 1, 'Site search creates only its submitted destination');
    await b.close();
    await b.launch();
    assert.deepEqual(
      (await b.state()).settings.siteSearches.find((engine) => engine.id === saved.id),
      saved,
    );
    await b.key('T', [b.mod]);
    await expect(input()).toBeFocused();
    await b.key('T', [b.mod]);
    await expect(input()).toHaveCount(0);
  },
);

test(
  'command result actions support reversible keyboard drill-down and pinning directly into a folder',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/target`);
    const target = (await b.state()).activeTabId;
    await b.guest(`${b.base}/target`, 'window.retainedCommandDraft="same document"');
    await b.invoke('tab:create', { url: `${b.base}/current` });
    await expect.poll(() => b.guest(`${b.base}/current`, 'document.readyState')).toBe('complete');
    const folder = await b.invoke('folder:create', { name: 'Research' });
    await b.shell.locator(`[data-key="folder-${folder.id}"]`).click();
    await expect(b.shell.locator(`[data-key="folder-${folder.id}"]`)).toHaveAttribute(
      'aria-expanded',
      'false',
    );
    await b.key('T', [b.mod]);
    const input = () => b.shell.locator('#command-input');
    await b.shell.getByRole('button', { name: 'Tabs', exact: true }).click();
    await input().fill('w');
    await expect(b.shell.locator('.command-context-hint')).not.toContainText('Search site');
    const scopedTab = await b.shell.locator('.command-result.selected .command-result-label').innerText();
    await input().press('Tab');
    await expect(input()).toHaveAttribute('aria-label', `Actions for ${scopedTab}`);
    await expect(b.shell.locator('[data-command-id="result:move"]')).toBeVisible();
    await input().press('Escape');
    await b.shell.getByRole('button', { name: 'All', exact: true }).click();
    await input().fill('@target');
    await input().press('Tab');
    await expect(input()).toHaveAttribute('placeholder', 'Workflow /target');
    await expect(input()).toHaveAttribute('aria-label', 'Actions for Workflow /target');
    await input().fill('pin to');
    await input().press('Enter');
    await expect(input()).toHaveAttribute('placeholder', 'Pin to…');
    await expect(input()).toHaveAttribute('aria-label', 'Pin to…');
    await input().press('Escape');
    await expect(input()).toHaveValue('pin to');
    await input().press('Escape');
    await expect(input()).toHaveValue('@target');
    await input().press('Tab');
    await input().fill('pin to');
    await input().press('Enter');
    await input().fill('Research');
    await input().press('Enter');
    await expect(input()).toHaveCount(0);
    const pinned = (await b.state()).tabs.find((tab) => tab.id === target);
    assert.equal(pinned.folderId, folder.id);
    assert.equal(pinned.pinned, true);
    assert.equal(pinned.favorite, false);
    assert.equal(await b.guest(`${b.base}/target`, 'window.retainedCommandDraft'), 'same document');
    await b.key('T', [b.mod]);
    await input().fill('Research');
    await b.shell.getByRole('button', { name: 'Folders', exact: true }).click();
    await expect(b.shell.getByRole('button', { name: 'Folders', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    await expect(b.shell.locator('[data-command-kind="navigation"]')).toHaveCount(0);
    await b.shell.locator(`[data-command-id="folder:${folder.id}"]`).click();
    await expect(b.shell.locator(`[data-key="folder-${folder.id}"]`)).toHaveAttribute(
      'aria-expanded',
      'true',
    );
    await expect(input()).toHaveCount(0);
    await b.key('T', [b.mod]);
    await input().fill('@target');
    await input().press('Tab');
    await b.invoke('profile:create', { name: 'Isolated commands' });
    await expect(input()).toHaveValue('');
    await expect(input()).toHaveAttribute('placeholder', 'Search or enter a URL');
    await expect(b.shell.locator('[data-command-id="result:move"]')).toHaveCount(0);
  },
);

test(
  'rebinding the AI shortcut disables its former palette key and uses the configured binding',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/shortcut-page`);
    await b.invoke('shortcut:set', { id: 'ai', accelerator: 'Mod+Alt+8' });
    await b.key('T', [b.mod]);
    const input = b.shell.locator('#command-input');
    // Keep the query empty so exercising the configured AI key opens its panel
    // without sending a request to any locally connected provider.
    await input.fill('');
    await input.press(`${process.platform === 'darwin' ? 'Meta' : 'Control'}+Enter`);
    await expect(input).toBeFocused();
    await expect(input).toHaveValue('');
    await expect(b.shell.locator('#ai-question')).toHaveCount(0);
    assert.equal((await b.state()).tabs.length, 1);
    await b.key('8', [b.mod, 'alt']);
    await expect(b.shell.locator('#ai-question')).toBeVisible();
    await expect(input).toHaveCount(0);
    await expect(b.shell.locator('#ai-question')).toHaveValue('');
  },
);

test(
  'Arc pin and Space keys, sidebar order and held recent-tab cycling use distinct navigation targets',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.submit(`${b.base}/one`);
    const first = (await b.state()).activeTabId;
    const records = [{ id: first }];
    for (const name of ['two', 'three', 'four']) {
      await new Promise((resolve) => setTimeout(resolve, 15));
      records.push(await b.invoke('tab:create', { url: `${b.base}/${name}` }));
    }
    const current = async () => (await b.state()).activeTabId;
    const release = (keyCode, modifiers = []) =>
      b.app.evaluate(
        ({ BrowserWindow, webContents }, { keyCode, modifiers }) => {
          (
            webContents.getFocusedWebContents() || BrowserWindow.getAllWindows()[0].webContents
          ).sendInputEvent({ type: 'keyUp', keyCode, modifiers });
        },
        { keyCode, modifiers },
      );
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[2].id);
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[1].id);
    await b.key('Tab', ['control', 'shift']);
    await expect.poll(current).toBe(records[2].id);
    await release('Shift', ['control']);
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[1].id);
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(first);
    await release('Control');
    await b.key('Tab', ['control']);
    await expect.poll(current).toBe(records[1].id);
    await release('Control');
    await b.key('D', [b.mod]);
    await expect
      .poll(async () => (await b.state()).tabs.find((tab) => tab.id === records[1].id).pinned)
      .toBe(true);
    assert.equal((await b.state()).bookmarks.length, 0, 'Arc pin shortcut pins instead of bookmarking');
    assert.equal((await b.state()).tabs.find((tab) => tab.id === records[1].id).favorite, false);
    await expect(b.shell.locator(`.pinned-tabs .tab-row[data-tab-id="${records[1].id}"]`)).toBeVisible();
    await expect(b.shell.locator(`.favorite[data-tab-id="${records[1].id}"]`)).toHaveCount(0);
    await b.key('1', [b.mod]);
    await expect.poll(current).toBe(records[1].id);
    await b.key('Down', [b.mod, 'alt']);
    await expect.poll(current).toBe(first);
    const originalSpace = (await b.state()).activeSpaceId;
    const nextSpace = await b.invoke('space:create', { name: 'Second workflow' });
    await b.key('1', [process.platform === 'darwin' ? 'control' : 'alt']);
    await expect.poll(async () => (await b.state()).activeSpaceId).toBe(originalSpace);
    await b.key('Right', [b.mod, 'alt']);
    await expect.poll(async () => (await b.state()).activeSpaceId).toBe(nextSpace.id);
    await expect(b.shell.locator('#command-input')).toBeVisible();
    await b.shell.locator('#command-input').fill('/ short');
    await b.shell.locator('#command-input').press('Enter');
    await expect(b.shell.getByRole('dialog', { name: 'Keyboard shortcuts' })).toBeVisible();
  },
);

test(
  'shortcut rebinds persist, reject conflicts and work in shell and guest; Save Page writes real HTML',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const url = `${b.base}/save-evidence`;
    await b.submit(url);
    const catalog = (await b.state()).runtime.shortcuts;
    const sidebar = catalog.find((item) => item.defaultAccelerator === 'Mod+S');
    const command = catalog.find((item) => item.defaultAccelerator === 'Mod+T');
    assert(sidebar && command, 'Runtime exposes the editable shortcut catalog');
    await assert.rejects(
      () => b.invoke('shortcut:set', { id: sidebar.id, accelerator: command.accelerator }),
      /conflict|already|assigned|use/i,
    );
    assert.equal(
      (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      'Mod+S',
    );
    await b.invoke('shortcut:run', { id: 'shortcuts' });
    await expect(b.shell.getByRole('dialog', { name: 'Keyboard shortcuts' })).toBeVisible();
    const sizes = await b.app.evaluate(({ BrowserWindow, screen }) => {
      const window = BrowserWindow.getAllWindows()[0];
      const outer = window.getBounds();
      const content = window.getContentBounds();
      const frameWidth = outer.width - content.width;
      const frameHeight = outer.height - content.height;
      const [minimumWidth, minimumHeight] = window.getMinimumSize();
      const work = screen.getDisplayMatching(outer).workArea;
      const minimum = {
        width: minimumWidth - frameWidth,
        height: minimumHeight - frameHeight,
      };
      return {
        origin: { x: work.x, y: work.y },
        normal: {
          width: Math.max(minimum.width, Math.min(1440, work.width - frameWidth)),
          height: Math.max(minimum.height, Math.min(900, work.height - frameHeight)),
        },
        minimum,
      };
    });
    for (const [name, { width, height }] of [
      ['normal', sizes.normal],
      ['minimum', sizes.minimum],
    ]) {
      await b.app.evaluate(
        ({ BrowserWindow }, { width, height, origin }) => {
          const window = BrowserWindow.getAllWindows()[0];
          window.setPosition(origin.x, origin.y);
          window.setContentSize(width, height);
        },
        { width, height, origin: sizes.origin },
      );
      let accepted,
        previous,
        stableObservations = 0;
      // A display may clamp Cocoa's initial accepted size asynchronously.
      // Use the settled native/renderer geometry for the layout assertions.
      await expect
        .poll(
          async () => {
            const native = await b.app.evaluate(({ BrowserWindow }) =>
              BrowserWindow.getAllWindows()[0].getContentSize(),
            );
            const rendered = await b.shell.evaluate(() => [innerWidth, innerHeight]);
            const signature = native.join(':');
            const agrees = native.every((value, index) => value === rendered[index]);
            stableObservations = agrees && signature === previous ? stableObservations + 1 : agrees ? 1 : 0;
            previous = signature;
            accepted = native;
            return stableObservations >= 3;
          },
          { intervals: [50, 100, 100] },
        )
        .toBe(true);
      t.diagnostic(
        `${name} shortcut viewport: requested ${width}×${height}, native accepted ${accepted.join('×')}`,
      );
      if (name === 'minimum') {
        assert(
          Math.abs(accepted[0] - width) <= 2 && Math.abs(accepted[1] - height) <= 2,
          'The second geometry check must exercise the real native minimum window',
        );
      }
      await expect
        .poll(() =>
          b.shell
            .locator('.shortcut-dialog')
            .evaluate((element) =>
              element.getAnimations().every((animation) => animation.playState !== 'running'),
            ),
        )
        .toBe(true);
      const geometry = () =>
        b.shell.evaluate(() => {
          const rect = (selector) => {
            const { top, bottom, left, right, height } = document
              .querySelector(selector)
              .getBoundingClientRect();
            return { top, bottom, left, right, height };
          };
          const rows = document.querySelector('#shortcut-rows');
          const reset = document.querySelector('[data-action="ui:shortcut-reset-all"]');
          const resetBox = reset.getBoundingClientRect();
          return {
            viewport: { width: innerWidth, height: innerHeight },
            dialog: rect('.shortcut-dialog'),
            header: rect('.shortcut-dialog .dialog-header'),
            search: rect('.shortcut-search-wrap'),
            rows: rect('#shortcut-rows'),
            footer: rect('.shortcut-footer'),
            scrollHeight: rows.scrollHeight,
            clientHeight: rows.clientHeight,
            scrollTop: rows.scrollTop,
            dialogScrollTop: document.querySelector('.shortcut-dialog').scrollTop,
            resetVisible:
              document
                .elementFromPoint(resetBox.left + resetBox.width / 2, resetBox.top + resetBox.height / 2)
                ?.closest('[data-action="ui:shortcut-reset-all"]') === reset,
          };
        });
      await expect
        .poll(
          async () => {
            const view = await geometry();
            return (
              view.dialog.bottom <= view.viewport.height - 23 &&
              view.dialog.left >= 0 &&
              view.dialog.right <= view.viewport.width &&
              view.resetVisible
            );
          },
          { message: `The entire editor and Reset all remain reachable at ${width}×${height}` },
        )
        .toBe(true);
      const before = await geometry();
      assert(before.dialog.height <= 681, 'The editor stays compact on larger windows');
      assert(before.header.top >= before.dialog.top && before.footer.bottom <= before.dialog.bottom);
      assert(before.rows.top >= before.search.bottom && before.rows.bottom <= before.footer.top);
      assert(before.scrollHeight > before.clientHeight, 'The catalog scrolls within its own list');
      await b.shell.locator('#shortcut-rows').evaluate((element) => {
        element.scrollTop = element.scrollHeight;
      });
      const after = await geometry();
      assert(after.scrollTop > 0, 'The last shortcuts are reachable by scrolling the catalog');
      assert.equal(after.dialogScrollTop, 0, 'The outer dialog never scrolls its controls out of view');
      assert.deepEqual(after.header, before.header);
      assert.deepEqual(after.search, before.search);
      assert.deepEqual(after.footer, before.footer);
      assert(after.resetVisible, 'Reset all remains hit-testable after scrolling to the end');
      await b.shell.locator('#shortcut-rows').evaluate((element) => {
        element.scrollTop = 0;
      });
    }
    await b.shell.locator(`[data-shortcut-record="${sidebar.id}"]`).click();
    await b.key('9', [b.mod, 'alt']);
    await expect
      .poll(
        async () => (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      )
      .toBe('Mod+Alt+9');
    await b.shell.keyboard.press('Escape');
    await b.key('9', [b.mod, 'alt']);
    await expect(b.shell.locator('#sidebar')).toBeHidden();
    await b.guest(
      url,
      'document.querySelector("textarea").value="Shortcut draft";document.querySelector("textarea").focus()',
    );
    await b.key('9', [b.mod, 'alt'], url);
    await expect(b.shell.locator('#sidebar')).toBeVisible();
    assert.equal(await b.guest(url, 'document.querySelector("textarea").value'), 'Shortcut draft');
    await b.close();
    await b.launch();
    await expect.poll(() => b.guest(url, 'document.readyState')).toBe('complete');
    assert.equal(
      (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      'Mod+Alt+9',
    );
    await b.invoke('shortcut:run', { id: 'shortcuts' });
    await b.shell.locator(`[data-shortcut-reset="${sidebar.id}"]`).click();
    await expect
      .poll(
        async () => (await b.state()).runtime.shortcuts.find((item) => item.id === sidebar.id).accelerator,
      )
      .toBe('Mod+S');
    await b.shell.keyboard.press('Escape');
    await b.key('S', [b.mod], url);
    await expect(b.shell.locator('#sidebar')).toBeHidden();
    await b.key('S', [b.mod]);
    await expect(b.shell.locator('#sidebar')).toBeVisible();
    const savedPath = path.join(b.directory, 'saved-page.html');
    await b.app.evaluate(({ dialog }, savedPath) => {
      globalThis.saveDialogCalls = 0;
      dialog.showSaveDialog = async () => {
        globalThis.saveDialogCalls++;
        return { canceled: false, filePath: savedPath };
      };
    }, savedPath);
    await b.key('S', [b.mod, 'shift'], url);
    await expect
      .poll(async () => fs.readFile(savedPath, 'utf8').catch(() => ''))
      .toContain('Saved workflow evidence');
    assert.equal(await b.app.evaluate(() => globalThis.saveDialogCalls), 1);
    assert.equal((await b.state()).tabs.length, 1);
    const savedBytes = await fs.readFile(savedPath);
    await b.app.evaluate(({ dialog }) => {
      dialog.showSaveDialog = async () => ({ canceled: true });
    });
    await b.invoke('save-page');
    assert.deepEqual(
      await fs.readFile(savedPath),
      savedBytes,
      'Cancelling Save Page preserves the existing file',
    );
  },
);
