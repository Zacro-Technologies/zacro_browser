'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');
// Optional AppKit routing probe. macOS dragging sessions may consult the real
// cursor position despite posted NSEvent coordinates, so this is not a CI gate.
// The default test exercises both Chromium renderers' actual drag handlers.
const nativeInput =
  process.platform === 'darwin' && process.env.ZACRO_TEST_APPKIT_DRAG === '1'
    ? require('../fixtures/mac-scroll-input.cjs').buildMacScrollInput()
    : null;

for (const side of ['left', 'right'])
  test(
    `dragging a tab onto the ${side} joins living pages and Unsplit is a searchable command`,
    { timeout: 60000 },
    async (t) => {
      const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-split-drop-'));
      const server = http.createServer((req, res) => {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(
          `<title>Split ${req.url}</title><h1>${req.url}</h1><textarea>Preserve this document</textarea>`,
        );
      });
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const base = `http://127.0.0.1:${server.address().port}`;
      const env = { ...process.env, ZACRO_USER_DATA: directory, ZACRO_SKIP_ONBOARDING: '1' };
      delete env.ELECTRON_RUN_AS_NODE;
      const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
      t.after(async () => {
        await app.close();
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
        await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      });
      const shell = await app.firstWindow();
      await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
      if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
      const invoke = (action, payload = {}) =>
        shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
      const state = () => invoke('state:get');
      const first = await invoke('tab:create', { url: `${base}/a` });
      await expect.poll(async () => (await state()).runtime.page.url).toBe(`${base}/a`);
      await invoke('tab:favorite', { id: first.id, favorite: true });
      const second = await invoke('tab:create', { url: `${base}/b` });
      await expect.poll(async () => (await state()).runtime.page.url).toBe(`${base}/b`);
      const living = () =>
        app.evaluate(
          ({ webContents }, base) =>
            webContents
              .getAllWebContents()
              .filter((page) => page.getURL().startsWith(base))
              .map((page) => ({ id: page.id, url: page.getURL() }))
              .sort((a, b) => a.url.localeCompare(b.url)),
          base,
        );
      const original = await living();
      const postMouse = (type, x, y) =>
        app.evaluate(
          ({ BrowserWindow }, { nativeInput, type, x, y }) =>
            process
              .getBuiltinModule('module')
              .createRequire(nativeInput)(nativeInput)
              .postMouse(BrowserWindow.getAllWindows()[0].getNativeWindowHandle(), { type, x, y }),
          { nativeInput, type, x, y },
        );
      await shell.evaluate(() =>
        document.addEventListener('dragstart', (event) => {
          window.splitTestDragData = {
            items: [...event.dataTransfer.types].map((mimeType) => ({
              mimeType,
              data: event.dataTransfer.getData(mimeType),
            })),
            dragOperationsMask: 16,
          };
        }),
      );
      await invoke('tab:activate', { id: second.id });
      const source = shell.locator(`[data-key="pin-${first.id}"]`);
      await source.hover();
      let box;
      await expect
        .poll(async () => {
          box = await source.boundingBox();
          return box?.width || 0;
        })
        .toBeGreaterThan(0);
      const start = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      let released = false;
      if (nativeInput) {
        await app.evaluate(({ app, BrowserWindow }) => {
          app.focus({ steal: true });
          BrowserWindow.getAllWindows()[0].focus();
        });
        await postMouse(5, start.x, start.y); // NSEventTypeMouseMoved
        await postMouse(1, start.x, start.y); // NSEventTypeLeftMouseDown
      } else {
        await shell.mouse.move(start.x, start.y);
        await shell.mouse.down();
      }
      try {
        if (nativeInput) await postMouse(6, start.x + 12, start.y + 2);
        else await shell.mouse.move(start.x + 12, start.y + 2, { steps: 3 });
        await expect(shell.locator('#app')).toHaveAttribute('data-dragging', 'true');
        await expect
          .poll(() =>
            app.evaluate(({ BrowserWindow }) => {
              const view = BrowserWindow.getAllWindows()[0].contentView.children.find((view) =>
                view.webContents?.getURL().endsWith('/peek-overlay.html'),
              );
              return view?.getVisible() || false;
            }),
          )
          .toBe(true);
        if (nativeInput) {
          const workspace = await shell.locator('#workspace').boundingBox();
          const x = workspace.x + workspace.width * (side === 'left' ? 0.25 : 0.75);
          const y = workspace.y + workspace.height * 0.5;
          for (let step = 1; step <= 20; step++) {
            await postMouse(6, start.x + ((x - start.x) * step) / 20, start.y + ((y - start.y) * step) / 20);
            await new Promise((resolve) => setTimeout(resolve, 15));
          }
          await postMouse(2, x, y); // NSEventTypeLeftMouseUp
          released = true;
        } else {
          const data = await shell.evaluate(() => window.splitTestDragData);
          // CDP mouse coordinates target only the shell WebContents. Route its real
          // drag data into the sibling native renderer's input channel.
          await app.evaluate(
            async ({ BrowserWindow }, { data, side }) => {
              const view = BrowserWindow.getAllWindows()[0].contentView.children.find((view) =>
                view.webContents?.getURL().endsWith('/peek-overlay.html'),
              );
              const bounds = view.getBounds();
              const wc = view.webContents;
              wc.debugger.attach('1.3');
              try {
                for (const type of ['dragEnter', 'dragOver', 'drop'])
                  await wc.debugger.sendCommand('Input.dispatchDragEvent', {
                    type,
                    x: bounds.width * (side === 'left' ? 0.25 : 0.75),
                    y: bounds.height * 0.5,
                    data,
                  });
              } finally {
                wc.debugger.detach();
              }
            },
            { data, side },
          );
        }
      } finally {
        if (nativeInput) {
          if (!released) await postMouse(2, start.x, start.y);
        } else await shell.mouse.up();
      }
      await expect
        .poll(async () => (await state()).runtime.splitPair)
        .toEqual(side === 'left' ? [first.id, second.id] : [second.id, first.id]);
      assert.deepEqual(await living(), original, 'Dragging reuses both Chromium documents');
      await invoke('shortcut:run', { id: 'command-palette' });
      await shell.locator('#command-input').fill('unsplit');
      const command = shell.getByRole('option', { name: /Unsplit tabs/ });
      await expect(command).toBeVisible();
      await command.click();
      await expect.poll(async () => (await state()).splitGroups.length).toBe(0);
      assert.deepEqual(await living(), original, 'Unsplit keeps both pages alive');
    },
  );
