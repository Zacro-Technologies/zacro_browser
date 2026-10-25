'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { setTimeout: delay } = require('node:timers/promises');
const { _electron: electron, expect } = require('@playwright/test');

async function launch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-space-swipe-'));
  const env = { ...process.env, ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
  const errors = [];
  t.after(async () => {
    await app.close();
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-space-swipe-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, []);
  });
  const shell = await app.firstWindow();
  shell.on('pageerror', (error) => errors.push(error.message));
  await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
  if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const current = async () => (await state()).activeSpaceId;
  const first = await current();
  const second = await invoke('space:create', { name: 'Second Space' });
  const third = await invoke('space:create', { name: 'Third Space' });
  await invoke('space:activate', { id: first });
  await expect(shell.locator(`.space-dot[data-id="${first}"]`)).toHaveAttribute('aria-current', 'true');
  const wheel = (events, selector = '.tabs-scroll') =>
    shell.evaluate(
      ({ events, selector }) =>
        events.map((event) => {
          const wheel = new WheelEvent('wheel', { bubbles: true, cancelable: true, ...event });
          document.querySelector(selector).dispatchEvent(wheel);
          return wheel.defaultPrevented;
        }),
      { events, selector },
    );
  const idle = () => delay(260);
  const changedTo = async (id) => {
    await expect.poll(current).toBe(id);
    await expect(shell.locator(`.space-dot[data-id="${id}"]`)).toHaveAttribute('aria-current', 'true');
  };
  await idle();
  return {
    app,
    shell,
    invoke,
    state,
    current,
    first,
    second: second.id,
    third: third.id,
    wheel,
    idle,
    changedTo,
  };
}

test(
  'native horizontal scrolling switches Spaces and preserves the live page',
  { timeout: 45000 },
  async (t) => {
    const server = http.createServer((request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      response.end(
        '<!doctype html><title>Space swipe fixture</title><style>body{width:1800px;height:2600px}</style><textarea id="draft"></textarea>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(async () => {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    });
    const url = `http://127.0.0.1:${server.address().port}/`;
    const b = await launch(t);
    for (let i = 0; i < 32; i++) await b.invoke('tab:create', { homePage: true, active: false });
    await expect(b.shell.locator('#sidebar [data-tab-id]')).toHaveCount(32);
    const sidebarScroll = await b.shell.evaluate(() => {
      const list = document.querySelector('.tabs-scroll');
      list.scrollTop = 260;
      return list.scrollTop;
    });
    assert(sidebarScroll > 100, 'The fixture must exercise a genuinely scrolled tab list');
    const guest = (expression) =>
      b.app.evaluate(
        ({ webContents }, { url, expression }) => {
          const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
          return contents?.executeJavaScript(expression) ?? null;
        },
        { url, expression },
      );
    await b.invoke('navigate', { url });
    await expect.poll(() => guest('document.readyState')).toBe('complete');
    await guest(
      'document.getElementById("draft").value = "Keep this draft"; window.fixtureIdentity = crypto.randomUUID(); scrollTo(0, 400); undefined',
    );
    const retained = await guest(
      '({ draft: document.getElementById("draft").value, identity: window.fixtureIdentity, y: scrollY })',
    );
    const nativeBounds = () =>
      b.app.evaluate(({ BrowserWindow }, url) => {
        const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
          (child) => child.webContents?.getURL() === url,
        );
        return view?.getBounds();
      }, url);
    const originalBounds = await nativeBounds();
    assert(originalBounds?.width > 300 && originalBounds?.height > 300);
    await b.shell.emulateMedia({ reducedMotion: 'no-preference' });
    await b.shell.evaluate(() => {
      window.spaceMotion = [];
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (frames, options) {
        if (this.matches('.tabs-scroll')) window.spaceMotion.push({ frames, duration: options.duration });
        return animate.call(this, frames, options);
      };
    });
    const sidebar = await b.shell.locator('.tabs-scroll').boundingBox();
    const point = { x: sidebar.x + sidebar.width / 2, y: sidebar.y + 100 };
    await b.shell.mouse.move(point.x, point.y);
    await b.shell.mouse.wheel(100, 0);
    await b.changedTo(b.second);
    assert.equal(await b.shell.locator('.tabs-scroll').evaluate((element) => element.scrollTop), 0);
    await b.idle();
    await b.shell.mouse.wheel(-100, 0);
    await b.changedTo(b.first);
    assert.equal(
      await b.shell.locator('.tabs-scroll').evaluate((element) => element.scrollTop),
      sidebarScroll,
    );
    assert.deepEqual(
      await guest(
        '({ draft: document.getElementById("draft").value, identity: window.fixtureIdentity, y: scrollY })',
      ),
      retained,
    );
    assert.deepEqual(await nativeBounds(), originalBounds, 'Returning to a Space restores exact page bounds');
    const samples = await b.shell.evaluate(() => window.spaceMotion);
    assert.equal(samples.length, 2);
    assert(samples.every((sample) => sample.duration > 0 && sample.duration <= 170));
    assert.match(samples[0].frames[0].transform, /translateX\([\d.]+px\)/);
    assert.match(samples[1].frames[0].transform, /translateX\(-[\d.]+px\)/);

    // A horizontal wheel over the native web page keeps ordinary page scrolling.
    // Returning from an empty Space dismisses its automatic palette. Its layout
    // IPC must reveal the page before a targeted native wheel can be delivered.
    await expect(b.shell.getByRole('dialog')).toHaveCount(0);
    await expect
      .poll(() =>
        b.app.evaluate(({ BrowserWindow }, url) => {
          const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
            (child) => child.webContents?.getURL() === url,
          );
          return view?.getVisible();
        }, url),
      )
      .toBe(true);
    await guest('scrollTo(200, 400); undefined');
    await expect.poll(() => guest('scrollX')).toBe(200);
    await b.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.focus();
      contents.sendInputEvent({
        type: 'mouseWheel',
        x: 120,
        y: 120,
        deltaX: 140,
        deltaY: 0,
        canScroll: true,
      });
    }, url);
    await expect
      .poll(() => guest('scrollX'))
      .not.toBe(200)
      .catch(async (error) => {
        t.diagnostic(
          JSON.stringify({
            shell: await b.shell.evaluate(() => ({
              focused: document.hasFocus(),
              dialog: document.querySelector('[role="dialog"]')?.getAttribute('aria-label'),
            })),
            page: await guest(
              '({ focused: document.hasFocus(), visibility: document.visibilityState, width: innerWidth, scrollWidth: document.documentElement.scrollWidth })',
            ),
            native: await b.app.evaluate(({ BrowserWindow }, url) => {
              const win = BrowserWindow.getAllWindows()[0];
              const view = win.contentView.children.find((child) => child.webContents?.getURL() === url);
              return { focused: win.isFocused(), visible: view?.getVisible(), bounds: view?.getBounds() };
            }, url),
          }),
        );
        throw error;
      });
    assert.equal(await b.current(), b.first);

    await b.idle();
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    await b.shell.mouse.move(point.x, point.y);
    await b.shell.mouse.wheel(100, 0);
    await b.changedTo(b.second);
    assert.equal(await b.shell.evaluate(() => window.spaceMotion.length), samples.length);
  },
);

test(
  'Space gestures accumulate intent, ignore inertia and stay inside the current profile',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    await b.invoke('profile:create', { name: 'Other profile' });
    const other = await b.current();
    await b.invoke('space:activate', { id: b.first });
    await b.idle();

    await b.wheel([{ deltaX: 20 }, { deltaX: 20 }]);
    assert.equal(await b.current(), b.first, 'Small movements must accumulate before navigation');
    await b.wheel([{ deltaX: 30 }]);
    await b.changedTo(b.second);
    // Even continued high-magnitude inertia can switch only one Space per burst.
    for (let i = 0; i < 5; i++) {
      await delay(70);
      await b.wheel([{ deltaX: 100 }]);
    }
    assert.equal(await b.current(), b.second);
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    await b.changedTo(b.third);
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    assert.equal(await b.current(), b.third, 'The last Space must not wrap or cross profiles');

    await b.idle();
    await b.wheel([{ deltaX: -40 }, { deltaX: 30 }, { deltaX: -30 }]);
    assert.equal(
      await b.current(),
      b.third,
      'Reversing direction must unwind the accumulated displacement without a premature switch',
    );
    await b.wheel([{ deltaX: -40 }]);
    await b.changedTo(b.second);

    await b.idle();
    await b.wheel([{ deltaX: -4, deltaMode: 1 }]);
    await b.changedTo(b.first);
    await b.idle();
    await b.wheel([{ deltaX: -100 }]);
    assert.equal(await b.current(), b.first, 'The first Space must not wrap');
    await b.idle();
    await b.wheel([{ deltaX: 1, deltaMode: 2 }]);
    await b.changedTo(b.second);
    await b.idle();
    await b.wheel([{ deltaY: -100, shiftKey: true }]);
    await b.changedTo(b.first);

    await b.invoke('space:activate', { id: other });
    await b.idle();
    await b.wheel([{ deltaX: 100 }, { deltaX: -100 }]);
    assert.equal(await b.current(), other, 'A single-Space profile cannot navigate into another profile');
  },
);

test(
  'sidebar gestures work beside the command palette and preserve editors, forms and dragging',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    for (const event of [
      { deltaY: 100 },
      { deltaX: 100, deltaY: 100 },
      { deltaX: 100, ctrlKey: true },
      { deltaX: 100, metaKey: true },
      { deltaX: 100, altKey: true },
    ]) {
      await b.idle();
      assert.deepEqual(await b.wheel([event]), [false]);
      assert.equal(await b.current(), b.first);
    }
    await b.idle();
    await b.wheel([{ deltaY: 100 }, { deltaX: 100 }]);
    assert.equal(
      await b.current(),
      b.first,
      'A sideways tail must not turn a vertical gesture into navigation',
    );
    await b.idle();
    assert.deepEqual(await b.wheel([{ deltaX: 100 }], '#toolbar'), [false]);
    assert.equal(await b.current(), b.first);

    await b.shell.locator('[data-key="address"]').click();
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await b.idle();
    await b.shell.locator('#command-input').fill('Keep this address draft');
    assert.deepEqual(await b.wheel([{ deltaX: 100 }], '#command-input'), [false]);
    assert.equal(await b.current(), b.first);
    await expect(b.shell.locator('#command-input')).toHaveValue('Keep this address draft');
    // Actual pointer hit testing matters: the palette must not put an invisible
    // full-window shield over the sidebar's trackpad surface.
    const sidebar = await b.shell.locator('.tabs-scroll').boundingBox();
    await b.shell.mouse.move(sidebar.x + sidebar.width / 2, sidebar.y + 80);
    await b.shell.mouse.wheel(100, 0);
    await b.changedTo(b.second);
    await b.invoke('space:activate', { id: b.first });
    await b.changedTo(b.first);
    if (await b.shell.locator('#command-input').count()) await b.shell.keyboard.press('Escape');

    await b.invoke('shortcut:run', { id: 'new-space' });
    await expect(b.shell.getByRole('dialog', { name: 'New Space', exact: true })).toBeVisible();
    await b.shell.getByRole('textbox', { name: 'Space name' }).fill('Keep this Space draft');
    await b.idle();
    assert.deepEqual(await b.wheel([{ deltaX: 100 }]), [false]);
    assert.equal(await b.current(), b.first);
    await expect(b.shell.getByRole('textbox', { name: 'Space name' })).toHaveValue('Keep this Space draft');
    await b.shell.keyboard.press('Escape');

    await b.invoke('tab:create', { homePage: true });
    await expect(b.shell.locator('#sidebar [data-tab-id]')).toHaveCount(1);

    const row = b.shell.locator('#sidebar [data-tab-id]').first();
    await row.click({ button: 'right' });
    await expect(b.shell.locator('.context-menu')).toBeVisible();
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    assert.equal(await b.current(), b.first);
    await b.shell.keyboard.press('Escape');

    await b.shell.evaluate(() =>
      document
        .querySelector('#sidebar [data-tab-id]')
        .dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() })),
    );
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    assert.equal(await b.current(), b.first);
    await b.shell.evaluate(() => document.dispatchEvent(new DragEvent('dragend', { bubbles: true })));

    await b.shell.locator('[data-key="sidebar-toggle"]').click();
    await b.idle();
    await b.wheel([{ deltaX: 100 }], '#sidebar');
    assert.equal(await b.current(), b.first);
    await b.shell.locator('[data-key="sidebar-toggle"]').click();
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    await b.changedTo(b.second);
  },
);

test(
  'Space feedback follows the fingers, unwinds reversals and rubber-bands at edges',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    await b.invoke('space:activate', { id: b.second });
    await b.changedTo(b.second);
    if (await b.shell.locator('#command-input').count()) await b.shell.keyboard.press('Escape');
    await b.idle();
    const offset = () =>
      b.shell
        .locator('.tabs-scroll')
        .evaluate((element) => (element.style.transform ? new DOMMatrix(element.style.transform).m41 : 0));
    assert.deepEqual(await b.wheel([{ deltaX: 18 }, { deltaX: 10 }]), [true, true]);
    assert.equal(await b.current(), b.second);
    assert.equal(await offset(), -28, 'Feedback is proportional to the accumulated finger displacement');
    await expect(b.shell.locator('.tabs-scroll')).toHaveClass(/gesture-tracking/);
    await expect(b.shell.locator('#space-gesture-preview')).toBeVisible();
    await expect(b.shell.locator('#space-gesture-preview')).toHaveText('Third Space');

    await b.wheel([{ deltaX: -18 }]);
    assert.equal(await offset(), -10, 'A reversal unwinds the current preview instead of jumping sides');
    await b.wheel([{ deltaX: -10 }]);
    assert.equal(await offset(), 0);
    assert.equal(await b.current(), b.second);
    await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
    await b.idle();
    await expect(b.shell.locator('.tabs-scroll')).not.toHaveClass(/gesture-tracking/);

    await b.wheel([{ deltaX: 24 }]);
    assert.equal(await offset(), -24);
    await b.shell.locator('#sidebar').dispatchEvent('pointerleave');
    assert.equal(await offset(), 0, 'Leaving the sidebar cancels a partial preview immediately');
    await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
    await b.wheel([{ deltaX: 100 }]);
    assert.equal(await b.current(), b.second, 'A cancelled gesture cannot commit with its remaining tail');

    await b.invoke('space:activate', { id: b.first });
    await b.changedTo(b.first);
    await b.idle();
    await b.wheel([{ deltaX: -180 }]);
    const edge = await offset();
    assert(edge > 0 && edge < 24, 'The first Space resists with a bounded rubber-band displacement');
    assert.equal(await b.current(), b.first);
    await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
    await b.idle();
    assert.equal(await offset(), 0, 'Uncommitted feedback settles after the gesture ends');
    await expect(b.shell.locator('.tabs-scroll')).not.toHaveClass(/gesture-tracking/);
  },
);
