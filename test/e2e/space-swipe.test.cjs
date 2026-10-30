'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');
const { buildMacScrollInput } = require('../fixtures/mac-scroll-input.cjs');

async function nativeMacScroll(browser) {
  const helper = buildMacScrollInput();
  assert.equal((await browser.state()).runtime.nativeSpaceScroll, true);
  return async (events, selector = '.tabs-scroll') => {
    const bounds = await browser.shell.locator(selector).boundingBox();
    assert(bounds, selector);
    await browser.app.evaluate(
      ({ BrowserWindow }, { helper, events, x, y }) => {
        const load = process.getBuiltinModule('module').createRequire(helper);
        const { postScroll } = load(helper);
        const handle = BrowserWindow.getAllWindows()[0].getNativeWindowHandle();
        for (const event of events) postScroll(handle, { x, y, ...event });
      },
      { helper, events, x: bounds.x + 20, y: bounds.y + 20 },
    );
  };
}

async function launch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-space-swipe-'));
  const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
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
          for (const property of ['momentum', 'phase'])
            if (event[property] !== undefined)
              Object.defineProperty(wheel, property, { value: event[property] });
          document.querySelector(selector).dispatchEvent(wheel);
          return wheel.defaultPrevented;
        }),
      { events, selector },
    );
  // Keep the two parts of one gesture on the renderer clock. A main-process
  // assertion between them can take longer than the 240ms quiet period on CI,
  // accidentally turning the final sample into a separate gesture.
  const measuredBurst = (before, after, tails = false) =>
    shell.evaluate(
      async ({ before, after, tails }) => {
        const list = document.querySelector('.space-page');
        const dispatch = (events) =>
          events.map((event) => {
            const wheel = new WheelEvent('wheel', { bubbles: true, cancelable: true, ...event });
            list.dispatchEvent(wheel);
            return wheel.defaultPrevented;
          });
        const firstEvents = dispatch(before);
        const intermediate = {
          activeSpace: document.querySelector('.space-dot[aria-current="true"]')?.dataset.id,
          tracking: list.classList.contains('gesture-tracking'),
          transform: list.style.transform,
        };
        const finalEvents = dispatch(after);
        const beforeRelease = document.querySelector('.space-dot[aria-current="true"]')?.dataset.id;
        if (tails) {
          // Schedule the fallback inertia stream on the same clock as release.
          // Round trips to the main process may exceed the stream's quiet gap.
          await new Promise((resolve) => setTimeout(resolve, 200));
          for (let i = 0; i < 5; i++) {
            dispatch([{ deltaX: 100 }]);
            await new Promise((resolve) => setTimeout(resolve, 70));
          }
        }
        return { firstEvents, finalEvents, intermediate, beforeRelease };
      },
      { before, after, tails },
    );
  const idle = () =>
    shell.evaluate(async () => {
      // Drain pending state-paint/automatic-palette work before starting the quiet
      // period, so a late UI update cannot interrupt the next synthetic gesture.
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      await new Promise((resolve) => setTimeout(resolve, 360));
    });
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
    measuredBurst,
    idle,
    changedTo,
  };
}

test(
  'opening browser panels or focusing tabs cancels an unsettled Space swipe',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    await b.invoke('tab:create', { homePage: true });
    await b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(560, 420));
    await expect(b.shell.locator('[data-key="library"]')).toBeVisible();
    if (await b.shell.locator('#command-input').count()) await b.shell.keyboard.press('Escape');
    for (const action of ['library', 'focus-sidebar']) {
      await b.idle();
      const tracking = await b.shell.evaluate(async (action) => {
        const list = document.querySelector('.space-page');
        list.dispatchEvent(new WheelEvent('wheel', { deltaX: 100, bubbles: true, cancelable: true }));
        const wasTracking = list.classList.contains('gesture-tracking');
        if (action === 'library') document.querySelector('[data-key="library"]').click();
        else await window.zacro.invoke('shortcut:run', { id: 'focus-sidebar' });
        // Wait beyond the gesture's quiet release deadline. An uncancelled timer
        // would commit the pending Space change after the new browser action.
        await new Promise((resolve) => setTimeout(resolve, 350));
        return wasTracking;
      }, action);
      assert.equal(tracking, true);
      assert.equal(await b.current(), b.first, `${action} takes precedence over the pending swipe`);
      await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
      await expect(b.shell.locator('.space-transition-snapshot')).toHaveCount(0);
      if (action === 'library') {
        await expect(b.shell.getByRole('menu', { name: 'Library', exact: true })).toBeVisible();
        await expect(b.shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'false');
        await b.shell.locator('[data-key="panel-bookmarks"]').click();
        await expect(b.shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'true');
        await expect(b.shell.locator('#panel-title')).toHaveText('Bookmarks');
        await b.shell.locator('[data-key="panel-close"]').click();
        await expect(b.shell.locator('#app')).toHaveAttribute('data-sidebar-hidden', 'false');
        await expect(b.shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
      }
    }
  },
);

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
        if (this.matches('.space-page')) window.spaceMotion.push({ frames, duration: options.duration });
        return animate.call(this, frames, options);
      };
    });
    const sidebar = await b.shell.locator('.tabs-scroll').boundingBox();
    const point = { x: sidebar.x + sidebar.width / 2, y: sidebar.y + 100 };
    const native = (await b.state()).runtime.nativeSpaceScroll ? await nativeMacScroll(b) : null;
    await b.shell.mouse.move(point.x, point.y);
    if (native) await native([{ phase: 1, deltaX: 100 }, { phase: 8 }]);
    else await b.shell.mouse.wheel(100, 0);
    await b.changedTo(b.second);
    assert.equal(await b.shell.locator('.tabs-scroll').evaluate((element) => element.scrollTop), 0);
    await b.idle();
    if (native) await native([{ phase: 1, deltaX: -100 }, { phase: 8 }]);
    else await b.shell.mouse.wheel(-100, 0);
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
    assert(samples.every((sample) => sample.duration >= 140 && sample.duration <= 240));
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
    await guest(`
      window.nativeInput = { moves: [], wheels: [] };
      addEventListener('mousemove', (event) => {
        window.nativeInput.moves.push({ x: event.clientX, y: event.clientY, trusted: event.isTrusted });
      }, { passive: true });
      addEventListener('wheel', (event) => {
        window.nativeInput.wheels.push({
          x: event.clientX, y: event.clientY, deltaX: event.deltaX, deltaY: event.deltaY,
          trusted: event.isTrusted, prevented: event.defaultPrevented,
        });
      }, { passive: true });
      scrollTo(200, 400);
      new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    `);
    await expect.poll(() => guest('scrollX')).toBe(200);
    await b.app.evaluate(({ BrowserWindow, webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      BrowserWindow.getAllWindows()[0].focus();
      contents.focus();
    }, url);
    await expect
      .poll(() =>
        b.app.evaluate(({ BrowserWindow, webContents }, url) => {
          const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
          return (
            BrowserWindow.getAllWindows()[0].isFocused() && webContents.getFocusedWebContents() === contents
          );
        }, url),
      )
      .toBe(true);
    // The previous native pointer target was the sidebar. Confirm that the
    // reattached guest has processed a real move before issuing one wheel;
    // visibility/focus alone does not acknowledge Chromium's input target.
    await b.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.sendInputEvent({ type: 'mouseMove', x: 120, y: 120 });
    }, url);
    await expect
      .poll(() => guest('window.nativeInput.moves.at(-1)'))
      .toEqual({ x: 120, y: 120, trusted: true });
    await b.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.sendInputEvent({
        type: 'mouseWheel',
        x: 120,
        y: 120,
        deltaX: 140,
        deltaY: 0,
        canScroll: true,
      });
    }, url);
    try {
      await expect.poll(() => guest('window.nativeInput.wheels.length')).toBe(1);
      const [wheel] = await guest('window.nativeInput.wheels');
      assert.deepEqual(
        { ...wheel, deltaX: Math.abs(wheel.deltaX), deltaY: Math.abs(wheel.deltaY) },
        { x: 120, y: 120, deltaX: 140, deltaY: 0, trusted: true, prevented: false },
        'One uncancelled native horizontal wheel must reach the page',
      );
      await expect.poll(() => guest('scrollX')).not.toBe(200);
    } catch (error) {
      t.diagnostic(
        JSON.stringify({
          shell: await b.shell.evaluate(() => ({
            focused: document.hasFocus(),
            dialog: document.querySelector('[role="dialog"]')?.getAttribute('aria-label'),
          })),
          page: await guest(
            '({ focused: document.hasFocus(), visibility: document.visibilityState, width: innerWidth, scrollWidth: document.documentElement.scrollWidth, scrollX, input: window.nativeInput })',
          ),
          native: await b.app.evaluate(({ BrowserWindow, webContents }, url) => {
            const win = BrowserWindow.getAllWindows()[0];
            const view = win.contentView.children.find((child) => child.webContents?.getURL() === url);
            return {
              focused: win.isFocused(),
              focusedContentsId: webContents.getFocusedWebContents()?.id,
              pageContentsId: view?.webContents.id,
              visible: view?.getVisible(),
              bounds: view?.getBounds(),
            };
          }, url),
        }),
      );
      throw error;
    }
    assert.equal(await b.current(), b.first);

    await b.idle();
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    await b.shell.mouse.move(point.x, point.y);
    if (native) await native([{ phase: 1, deltaX: 100 }, { phase: 8 }]);
    else await b.shell.mouse.wheel(100, 0);
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
    await b.changedTo(b.first);
    await b.idle();

    const forward = await b.measuredBurst([{ deltaX: 40 }, { deltaX: 40 }], [{ deltaX: 40 }], true);
    assert.deepEqual(forward.firstEvents, [true, true]);
    assert.deepEqual(forward.finalEvents, [true]);
    assert.deepEqual(
      forward.intermediate,
      {
        activeSpace: b.first,
        tracking: true,
        transform: 'translateX(-80px)',
      },
      'Tracking continues beyond the former 64px threshold without navigation',
    );
    assert.equal(forward.beforeRelease, b.first, 'Crossing the release distance cannot switch a live drag');
    await b.changedTo(b.second);
    assert.equal(await b.current(), b.second);
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    await b.changedTo(b.third);
    await b.idle();
    await b.wheel([{ deltaX: 100 }]);
    assert.equal(await b.current(), b.third, 'The last Space must not wrap or cross profiles');

    await b.idle();
    const reverse = await b.measuredBurst(
      [{ deltaX: -40 }, { deltaX: 30 }, { deltaX: -30 }],
      [{ deltaX: -70 }],
    );
    assert.deepEqual(reverse.firstEvents, [true, true, true]);
    assert.deepEqual(reverse.finalEvents, [true]);
    assert.deepEqual(
      reverse.intermediate,
      {
        activeSpace: b.third,
        tracking: true,
        transform: 'translateX(40px)',
      },
      'Reversing direction must unwind displacement without a premature switch',
    );
    await b.changedTo(b.second);

    await b.idle();
    await b.wheel([{ deltaX: -7, deltaMode: 1 }]);
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
    if ((await b.state()).runtime.nativeSpaceScroll) {
      const native = await nativeMacScroll(b);
      await native([{ phase: 1, deltaX: 100 }, { phase: 8 }]);
    } else await b.shell.mouse.wheel(100, 0);
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

    await b.invoke('shortcut:run', { id: 'sidebar-toggle' });
    await b.idle();
    await b.wheel([{ deltaX: 100 }], '#sidebar');
    assert.equal(await b.current(), b.first);
    await b.invoke('shortcut:run', { id: 'sidebar-toggle' });
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
    // Observe the individual samples on one renderer clock. An IPC round trip
    // between samples can exceed the fallback contact-release pause on CI.
    const reversal = await b.shell.evaluate(() => {
      const list = document.querySelector('.space-page');
      const preview = document.querySelector('#space-gesture-preview');
      const samples = [];
      for (const deltaX of [18, 10, -18, -10]) {
        const wheel = new WheelEvent('wheel', { deltaX, bubbles: true, cancelable: true });
        list.dispatchEvent(wheel);
        samples.push({
          prevented: wheel.defaultPrevented,
          offset: new DOMMatrix(list.style.transform).m41,
          tracking: list.classList.contains('gesture-tracking'),
          preview: preview.hidden ? null : preview.querySelector('.space-title').textContent,
          active: document.querySelector('.space-dot[aria-current="true"]').dataset.id,
        });
      }
      return samples;
    });
    assert.deepEqual(
      reversal.map((sample) => sample.offset),
      [-18, -28, -10, 0],
    );
    assert(reversal.every((sample) => sample.prevented && sample.tracking && sample.active === b.second));
    assert.equal(reversal[1].preview, 'Third Space');
    assert.equal(reversal[3].preview, null);
    await b.idle();
    await expect(b.shell.locator('.space-page')).not.toHaveClass(/gesture-tracking/);

    const cancelled = await b.shell.evaluate(() => {
      const list = document.querySelector('.space-page');
      const wheel = (deltaX) =>
        list.dispatchEvent(new WheelEvent('wheel', { deltaX, bubbles: true, cancelable: true }));
      wheel(24);
      const tracked = new DOMMatrix(list.style.transform).m41;
      document.querySelector('#sidebar').dispatchEvent(new PointerEvent('pointerleave'));
      const reset = list.style.transform;
      wheel(100);
      return { tracked, reset, tail: list.style.transform };
    });
    assert.deepEqual(cancelled, { tracked: -24, reset: '', tail: '' });
    await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
    await b.idle();
    assert.equal(await b.current(), b.second, 'A cancelled gesture cannot commit with its remaining tail');

    await b.invoke('space:activate', { id: b.first });
    await b.changedTo(b.first);
    await b.idle();
    const edge = await b.shell.evaluate(() => {
      const list = document.querySelector('.space-page');
      list.dispatchEvent(new WheelEvent('wheel', { deltaX: -180, bubbles: true, cancelable: true }));
      return new DOMMatrix(list.style.transform).m41;
    });
    assert(edge > 0 && edge < 24, 'The first Space resists with a bounded rubber-band displacement');
    assert.equal(await b.current(), b.first);
    await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
    await b.idle();
    assert.equal(
      await b.shell.locator('.space-page').evaluate((element) => element.style.transform),
      '',
      'Uncommitted feedback settles after the gesture ends',
    );
    await expect(b.shell.locator('.space-page')).not.toHaveClass(/gesture-tracking/);
  },
);

test(
  'neighbor previews show real favorites, folders and tabs without activating pages',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    const folder = await b.invoke('folder:create', { spaceId: b.third, name: 'Reading list' });
    const pin = await b.invoke('tab:create', { spaceId: b.third, homePage: true, active: false });
    await b.invoke('tab:update', { id: pin.id, title: 'Favorite reference' });
    await b.invoke('tab:favorite', { id: pin.id });
    const article = await b.invoke('tab:create', { spaceId: b.third, homePage: true, active: false });
    await b.invoke('tab:update', { id: article.id, title: 'Neighbor article' });
    await b.invoke('tab:move', { id: article.id, spaceId: b.third, folderId: folder.id });
    await b.invoke('space:activate', { id: b.second });
    await b.changedTo(b.second);
    if (await b.shell.locator('#command-input').count()) await b.shell.keyboard.press('Escape');
    await b.idle();
    const before = await b.state();
    const preview = await b.shell.evaluate(() => {
      const live = document.querySelector('.space-page');
      const wheel = (deltaX, phase) => {
        const event = new WheelEvent('wheel', { deltaX, bubbles: true, cancelable: true });
        Object.defineProperty(event, 'phase', { value: phase });
        live.dispatchEvent(event);
      };
      wheel(90, 'began');
      const region = document.querySelector('#space-gesture-preview');
      const page = region.firstElementChild;
      const result = {
        hidden: region.hidden,
        inert: region.inert && page.inert,
        accessible: region.getAttribute('aria-hidden'),
        heading: page.querySelector('.space-title').textContent,
        tab: page.querySelector('.tab-row .title').textContent,
        folder: page.querySelector('.folder-heading .truncate').textContent,
        favorite: page.querySelector('.favorite').getAttribute('aria-label'),
        interactiveAttributes: page.querySelectorAll(
          '[id],[data-action],[data-tab-id],[data-key],[draggable]',
        ).length,
        favoriteStatusDots: page.querySelectorAll('.favorite-status').length,
        outgoingOffset: new DOMMatrix(live.style.transform).m41,
        incomingOffset: new DOMMatrix(page.style.transform).m41,
        travel: document.querySelector('#sidebar').clientWidth,
      };
      wheel(-130, 'changed');
      result.reversedHeading = region.querySelector('.space-title').textContent;
      result.reversedOffset = new DOMMatrix(region.firstElementChild.style.transform).m41;
      wheel(0, 'cancelled');
      return result;
    });
    assert.equal(preview.hidden, false);
    assert.equal(preview.inert, true);
    assert.equal(preview.accessible, 'true');
    assert.equal(preview.heading, 'Third Space');
    assert.equal(preview.tab, 'Neighbor article');
    assert.equal(preview.folder, 'Reading list');
    assert.match(preview.favorite, /^Favorite reference — (Loaded|Sleeping|Closed)$/);
    assert.equal(preview.interactiveAttributes, 0);
    assert.equal(preview.favoriteStatusDots, 0);
    assert.equal(preview.outgoingOffset, -90);
    assert.equal(preview.incomingOffset, preview.travel - 90);
    assert.equal(preview.reversedHeading, before.spaces.find((space) => space.id === b.first).name);
    assert.equal(preview.reversedOffset, -preview.travel + 40);
    await b.idle();
    await expect(b.shell.locator('#space-gesture-preview')).toBeHidden();
    const after = await b.state();
    assert.equal(after.activeSpaceId, before.activeSpaceId);
    assert.equal(after.activeTabId, before.activeTabId);
    assert.deepEqual(
      after.runtime.pages,
      before.runtime.pages,
      'Previewing must not load or wake native pages',
    );
  },
);

test(
  'Space footer menus target the clicked Space and support keyboard access',
  { timeout: 45000 },
  async (t) => {
    const server = http.createServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
      response.end('<!doctype html><title>Move me</title><h1>Space menu fixture</h1>');
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(async () => {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    });
    const b = await launch(t);
    const tab = await b.invoke('tab:create', { url: `http://127.0.0.1:${server.address().port}/` });
    await b.invoke('tab:favorite', { id: tab.id });
    await expect(b.shell.locator(`.favorite[data-tab-id="${tab.id}"]`)).toHaveAttribute(
      'aria-label',
      / — (Loaded|Sleeping|Closed)$/,
    );
    assert.equal(await b.shell.locator('.favorite-status').count(), 0);
    const second = b.shell.locator(`.space-dot[data-id="${b.second}"]`);
    await second.click({ button: 'right' });
    await expect(b.shell.getByRole('dialog', { name: 'Space actions' })).toBeVisible();
    await expect(b.shell.locator('[data-action="ui:rename-space"]')).toHaveAttribute('data-id', b.second);
    await b.shell.locator('[data-action="ui:rename-space"]').click();
    await b.shell.getByLabel('Space name', { exact: true }).fill('Renamed neighbor');
    await b.shell.getByRole('button', { name: 'Save', exact: true }).click();
    await expect
      .poll(async () => (await b.state()).spaces.find((space) => space.id === b.second).name)
      .toBe('Renamed neighbor');
    assert.equal(await b.current(), b.first, 'Editing an inactive Space must not switch the active Space');
    await expect(second).toBeFocused();
    await second.press('Shift+F10');
    await expect(b.shell.getByRole('dialog', { name: 'Space actions' })).toBeVisible();
    await b.shell.keyboard.press('Escape');
    await expect(second).toBeFocused();
    await second.press('ContextMenu');
    await expect(b.shell.locator('[data-action="ui:space-move-tab"]')).toHaveAttribute(
      'data-source-tab',
      tab.id,
    );
    await b.shell.locator('[data-action="ui:space-move-tab"]').click();
    await b.changedTo(b.second);
    assert.equal((await b.state()).tabs.find((item) => item.id === tab.id).spaceId, b.second);
    assert.equal((await b.state()).tabs.find((item) => item.id === tab.id).pinned, true);
    await b.invoke('space:delete', { id: b.third });
    await b.invoke('space:delete', { id: b.first });
    await expect(b.shell.locator('.space-dot')).toHaveCount(1);
    await second.click({ button: 'right' });
    await expect(b.shell.locator('[data-action="ui:delete-space"]')).toBeDisabled();
    await b.shell.keyboard.press('Escape');
  },
);

test(
  'Space dragging survives title redraws and settles both lists from the actual release position',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    const tab = await b.invoke('tab:create', { homePage: true });
    await expect(b.shell.locator(`.tab-row[data-tab-id="${tab.id}"]`)).toBeVisible();
    await b.shell.emulateMedia({ reducedMotion: 'no-preference' });
    await b.idle();
    const result = await b.shell.evaluate(
      async ({ tabId, nextId }) => {
        const nextFrame = () => new Promise((resolve) => requestAnimationFrame(resolve));
        const until = async (condition) => {
          const deadline = performance.now() + 3000;
          while (!condition()) {
            if (performance.now() >= deadline) throw new Error('Timed out waiting for gesture paint');
            await nextFrame();
          }
        };
        const wheel = (deltaX, phase) => {
          const event = new WheelEvent('wheel', { deltaX, bubbles: true, cancelable: true });
          Object.defineProperty(event, 'phase', { value: phase });
          document.querySelector('.space-page').dispatchEvent(event);
        };
        const frames = [];
        const animate = Element.prototype.animate;
        Element.prototype.animate = function (keyframes, options) {
          if (this.matches('.space-page') || this.parentElement?.matches('.space-transition-snapshot'))
            frames.push({ incoming: this.matches('.space-page'), keyframes, duration: options.duration });
          return animate.call(this, keyframes, options);
        };
        try {
          wheel(80, 'began');
          const oldList = document.querySelector('.space-page');
          await window.zacro.invoke('tab:update', { id: tabId, title: 'Changed while dragging' });
          await until(() => document.querySelector('.space-page') !== oldList);
          const list = document.querySelector('.space-page');
          const afterRedraw = {
            offset: new DOMMatrix(list.style.transform).m41,
            tracking: list.classList.contains('gesture-tracking'),
            title: list.querySelector('.tab-row .title').textContent,
          };
          wheel(40, 'changed');
          const held = {
            offset: new DOMMatrix(list.style.transform).m41,
            active: document.querySelector('.space-dot[aria-current="true"]').dataset.id,
          };
          wheel(0, 'ended');
          const snapshot = document.querySelector('.space-transition-snapshot');
          const outgoing = {
            inert: snapshot.inert,
            hidden: snapshot.getAttribute('aria-hidden'),
            interactiveAttributes: snapshot.querySelectorAll(
              '[id], [data-action], [data-key], [data-tab-id], [draggable]',
            ).length,
            title: snapshot.querySelector('.title').textContent,
            offset: new DOMMatrix(snapshot.firstElementChild.style.transform).m41,
            width: snapshot.clientWidth,
          };
          await until(() => document.querySelector('.space-dot[aria-current="true"]')?.dataset.id === nextId);
          const travel = document.querySelector('#sidebar').clientWidth;
          await until(() => !document.querySelector('.space-transition-snapshot'));
          return { afterRedraw, held, outgoing, frames, travel };
        } finally {
          Element.prototype.animate = animate;
        }
      },
      { tabId: tab.id, nextId: b.second },
    );
    assert.deepEqual(result.afterRedraw, { offset: -80, tracking: true, title: 'Changed while dragging' });
    assert.deepEqual(result.held, { offset: -120, active: b.first });
    assert.deepEqual(
      { ...result.outgoing, width: undefined },
      {
        inert: true,
        hidden: 'true',
        interactiveAttributes: 0,
        title: 'Changed while dragging',
        offset: -120,
        width: undefined,
      },
    );
    assert(result.outgoing.width > 150 && result.outgoing.width < result.travel);
    const incoming = result.frames.find((sample) => sample.incoming);
    const outgoing = result.frames.find((sample) => !sample.incoming);
    assert.equal(incoming.keyframes[0].transform, `translateX(${result.travel - 120}px)`);
    assert.equal(outgoing.keyframes[0].transform, 'translateX(-120px)');
    assert.equal(outgoing.keyframes[1].transform, `translateX(${-result.travel}px)`);
    assert.equal(
      incoming.duration,
      outgoing.duration,
      'The outgoing and incoming lists share one settling clock',
    );
    assert(incoming.duration >= 140 && incoming.duration <= 240);
    await expect(b.shell.locator('.space-page')).not.toHaveClass(/gesture-tracking/);
    await expect(b.shell.locator('.space-transition-snapshot')).toHaveCount(0);
  },
);

test(
  'Space colors track displacement, reverse and settle with the same clock as the rows',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    const first = {
      color: '#b34f68',
      theme: { secondaryColor: '#d4a772', gradient: 10, grain: 20, opacity: 100 },
    };
    const second = {
      color: '#4f79c6',
      theme: { secondaryColor: '#85bcb1', gradient: 90, grain: 180, opacity: 0 },
    };
    await b.invoke('space:update', { id: b.first, ...first });
    await b.invoke('space:update', { id: b.second, ...second });
    const tab = await b.invoke('tab:create', { homePage: true });
    await expect(b.shell.locator(`.tab-row[data-tab-id="${tab.id}"]`)).toBeVisible();
    await b.shell.emulateMedia({ reducedMotion: 'no-preference' });
    await b.idle();
    const samples = await b.shell.evaluate(async (tabId) => {
      const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
      const wheel = (fraction, phase) => {
        const event = new WheelEvent('wheel', {
          deltaX: document.querySelector('#sidebar').clientWidth * fraction,
          bubbles: true,
          cancelable: true,
        });
        Object.defineProperty(event, 'phase', { value: phase });
        document.querySelector('.space-page').dispatchEvent(event);
      };
      const appearance = () => ({
        color: document.documentElement.style.getPropertyValue('--space-color'),
        gradient: parseFloat(document.documentElement.style.getPropertyValue('--space-gradient')),
        grain: parseFloat(document.documentElement.style.getPropertyValue('--space-grain')),
      });
      wheel(0.25, 'began');
      const quarter = appearance();
      wheel(0.25, 'changed');
      const half = appearance();
      await window.zacro.invoke('tab:update', { id: tabId, title: 'Metadata during theme gesture' });
      await frame();
      await frame();
      const afterMetadata = appearance();
      const nativeEnabled = (await window.zacro.invoke('state:get')).runtime.windowMaterial.enabled;
      const tintOpacity = parseFloat(document.documentElement.style.getPropertyValue('--space-opacity'));
      wheel(-0.25, 'changed');
      const reversed = appearance();
      wheel(0, 'cancelled');
      const cancelled = [appearance()];
      const deadline = performance.now() + 1000;
      while (appearance().gradient !== 10 && performance.now() < deadline) {
        await frame();
        cancelled.push(appearance());
      }
      return { quarter, half, afterMetadata, nativeEnabled, tintOpacity, reversed, cancelled };
    }, tab.id);
    const { blendSpaceAppearance } = await import('../../src/renderer/theme.js');
    assert.equal(samples.quarter.color, blendSpaceAppearance(first, second, 0.25).color);
    assert.equal(samples.quarter.gradient, 30);
    assert.equal(samples.half.color, blendSpaceAppearance(first, second, 0.5).color);
    assert.equal(samples.half.gradient, 50);
    assert.deepEqual(samples.afterMetadata, samples.half, 'Metadata refresh cannot replace presented colors');
    assert.equal(
      samples.tintOpacity,
      samples.nativeEnabled ? 50 : 100,
      'Tint follows gesture progress or the native accessibility fallback',
    );
    assert.deepEqual(samples.reversed, samples.quarter, 'Reverse movement retraces the color blend');
    assert.equal(samples.cancelled[0].gradient, 30, 'Cancellation starts from the presented blend');
    assert.equal(samples.cancelled.at(-1).gradient, 10);
    assert(samples.cancelled.some((sample) => sample.gradient > 10 && sample.gradient < 30));
    for (let index = 1; index < samples.cancelled.length; index++)
      assert(samples.cancelled[index].gradient <= samples.cancelled[index - 1].gradient + 0.001);
    assert.equal(await b.current(), b.first);
    await b.idle();
    const committed = await b.shell.evaluate(async (nextId) => {
      const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
      const wheel = (fraction, phase) => {
        const event = new WheelEvent('wheel', {
          deltaX: document.querySelector('#sidebar').clientWidth * fraction,
          bubbles: true,
          cancelable: true,
        });
        Object.defineProperty(event, 'phase', { value: phase });
        document.querySelector('.space-page').dispatchEvent(event);
      };
      const read = () => parseFloat(document.documentElement.style.getPropertyValue('--space-gradient'));
      wheel(0.5, 'began');
      wheel(0, 'ended');
      const values = [read()];
      const deadline = performance.now() + 3000;
      while (
        (document.querySelector('.space-dot[aria-current="true"]')?.dataset.id !== nextId ||
          document.querySelector('.space-transition-snapshot') ||
          read() !== 90) &&
        performance.now() < deadline
      ) {
        await frame();
        values.push(read());
      }
      return values;
    }, b.second);
    assert.equal(committed[0], 50, 'Release must not jump directly to the destination theme');
    assert.equal(committed.at(-1), 90);
    assert(committed.some((value) => value > 50 && value < 90));
    for (let index = 1; index < committed.length; index++)
      assert(committed[index] + 0.001 >= committed[index - 1]);
    await b.changedTo(b.second);
    for (const [id, expected] of [
      [b.first, first],
      [b.second, second],
    ]) {
      const saved = (await b.state()).spaces.find((space) => space.id === id);
      assert.equal(saved.color, expected.color);
      for (const [key, value] of Object.entries(expected.theme)) assert.equal(saved.theme[key], value);
    }
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    await b.invoke('space:activate', { id: b.first });
    await b.idle();
    const reduced = await b.shell.evaluate(() => {
      const dispatch = (deltaX, phase) => {
        const event = new WheelEvent('wheel', { deltaX, bubbles: true, cancelable: true });
        Object.defineProperty(event, 'phase', { value: phase });
        document.querySelector('.space-page').dispatchEvent(event);
      };
      dispatch(document.querySelector('#sidebar').clientWidth / 4, 'began');
      dispatch(0, 'cancelled');
      return {
        color: document.documentElement.style.getPropertyValue('--space-color'),
        animations: document.getAnimations().filter((animation) => animation.playState === 'running').length,
      };
    });
    assert.equal(reduced.color, first.color);
    assert.equal(reduced.animations, 0);
  },
);

test(
  'a held swipe spans multiple pages without compressing Favorites or timing out',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    for (let i = 0; i < 6; i++) {
      const tab = await b.invoke('tab:create', { homePage: true });
      await b.invoke('tab:favorite', { id: tab.id });
    }
    await b.idle();
    const sample = await b.shell.evaluate(async () => {
      const list = document.querySelector('.space-page');
      const dispatch = (dx, phase) => {
        const event = new WheelEvent('wheel', { deltaX: dx, bubbles: true, cancelable: true });
        Object.defineProperty(event, 'phase', { value: phase });
        list.dispatchEvent(event);
      };
      const width = document.querySelector('#sidebar').clientWidth;
      const original = [...list.querySelectorAll('.favorite')].map(
        (node) => node.getBoundingClientRect().width,
      );
      dispatch(width * 0.3, 'began');
      const preview = [
        ...document.querySelector('#space-gesture-preview').firstElementChild.querySelectorAll('.favorite'),
      ].map((node) => node.getBoundingClientRect().width);
      await new Promise((resolve) => setTimeout(resolve, 1000));
      const held = list.classList.contains('gesture-tracking');
      dispatch(width * 2, 'changed');
      const farEdgeVisible = !document.querySelector('#space-gesture-preview').hidden;
      const offset = new DOMMatrix(list.style.transform).m41;
      dispatch(0, 'ended');
      return { original, preview, held, offset, width, farEdgeVisible };
    });
    assert.equal(sample.preview.length, sample.original.length);
    assert(sample.preview.every((width, index) => Math.abs(width - sample.original[index]) < 0.01));
    assert(sample.original.every((width) => width > 50));
    assert.equal(sample.held, true);
    assert.equal(sample.farEdgeVisible, true);
    assert(sample.offset < -sample.width * 2 && sample.offset > -sample.width * 2 - 24);
    await b.changedTo(b.third);
  },
);

test(
  'native shell contact phases hold ordinary wheels through pauses and release once',
  { timeout: 45000 },
  async (t) => {
    const b = await launch(t);
    await b.invoke('tab:create', { homePage: true });
    await b.idle();
    if ((await b.state()).runtime.nativeSpaceScroll) {
      const native = await nativeMacScroll(b);
      await native([{ phase: 1, deltaX: 100 }]);
      await expect(b.shell.locator('.space-page')).toHaveClass(/gesture-tracking/);
      await b.shell.evaluate(() => new Promise((resolve) => setTimeout(resolve, 1000)));
      assert.equal(await b.current(), b.first);
      await expect(b.shell.locator('.space-page')).toHaveClass(/gesture-tracking/);
      await native([{ phase: 4, deltaX: 310 }, { phase: 8 }]);
      await b.changedTo(b.third);
      await b.idle();
      await native([{ phase: 1, deltaX: -120 }, { phase: 8 }]);
      await b.changedTo(b.second);
      await native([
        { momentumPhase: 1, deltaX: -500 },
        { momentumPhase: 4, deltaX: -300 },
        { momentumPhase: 8 },
      ]);
      await b.idle();
      assert.equal(await b.current(), b.second, 'Cocoa inertia never changes the released Space');
      await native([{ phase: 1, deltaX: 140 }, { phase: 8 }], '#toolbar');
      await b.idle();
      assert.equal(await b.current(), b.second, 'Toolbar scrolls do not claim Space navigation');
      return;
    }
    await b.shell.evaluate(() => {
      window.__nativeSpacePhase = null;
      window.zacro.onEvent((event) => {
        if (event.type === 'space:gesture-phase') window.__nativeSpacePhase = event.phase;
      });
    });
    const native = async (type, expected) => {
      await b.shell.evaluate(() => {
        window.__nativeSpacePhase = null;
      });
      await b.app.evaluate(({ BrowserWindow }, type) => {
        BrowserWindow.getAllWindows()[0].webContents.emit('input-event', {}, { type });
      }, type);
      await expect.poll(() => b.shell.evaluate(() => window.__nativeSpacePhase)).toBe(expected);
    };
    await native('gestureScrollBegin', 'began');
    // These WheelEvents deliberately have no nonstandard phase/momentum fields.
    await b.wheel([{ deltaX: 100 }]);
    await b.shell.evaluate(() => new Promise((resolve) => setTimeout(resolve, 1000)));
    assert.equal(await b.current(), b.first);
    await expect(b.shell.locator('.space-page')).toHaveClass(/gesture-tracking/);
    await b.wheel([{ deltaX: 310 }]);
    await native('gestureScrollEnd', 'ended');
    await b.changedTo(b.third);
    await b.idle();

    await native('gestureScrollBegin', 'began');
    await b.wheel([{ deltaX: -120 }]);
    await native('gestureFlingStart', 'momentum');
    await b.changedTo(b.second);
    await b.wheel([{ deltaX: -500 }, { deltaX: -300 }]);
    assert.equal(await b.current(), b.second, 'Inertia after native release cannot cross another Space');
    await native('gestureFlingCancel', 'momentum-ended');
    await b.idle();
    assert.equal(await b.current(), b.second);

    await b.wheel([{ deltaX: -100 }]);
    await native('gestureScrollBegin', 'began');
    await b.shell.evaluate(() => new Promise((resolve) => setTimeout(resolve, 900)));
    await expect(b.shell.locator('.space-page')).toHaveClass(/gesture-tracking/);
    assert.equal(await b.current(), b.second);
    await native('gestureScrollEnd', 'ended');
    await b.changedTo(b.first);
    await b.invoke('space:activate', { id: b.second });
    await b.changedTo(b.second);
    await b.idle();

    await native('gestureScrollBegin', 'began');
    await b.wheel([{ deltaX: 140 }], '#toolbar');
    await native('gestureScrollEnd', 'ended');
    assert.equal(
      await b.current(),
      b.second,
      'A shell gesture outside the sidebar navigation region is not claimed',
    );
  },
);

test(
  'a quick swipe selects one neighbor and ignores all momentum while a long swipe crosses pages',
  { timeout: 30000 },
  async (t) => {
    const b = await launch(t);
    await b.idle();
    await b.wheel([
      { deltaX: 650, phase: 'began' },
      { deltaX: 0, phase: 'ended' },
    ]);
    await b.changedTo(b.second);
    await b.wheel([
      { deltaX: 900, momentum: true },
      { deltaX: 400, momentum: true },
    ]);
    assert.equal(await b.current(), b.second);
    await b.idle();
    await b.invoke('space:activate', { id: b.first });
    await b.changedTo(b.first);
    await b.idle();
    await b.wheel([{ deltaX: 100, phase: 'began' }]);
    await b.shell.evaluate(() => new Promise((resolve) => setTimeout(resolve, 280)));
    await b.wheel([
      { deltaX: 310, phase: 'changed' },
      { deltaX: 0, phase: 'ended' },
    ]);
    await b.changedTo(b.third);
    await b.wheel([{ deltaX: -900, momentum: true }]);
    assert.equal(await b.current(), b.third);
  },
);

test(
  'Cocoa rapid flicks stop at one Space even when a long inertial tail follows',
  { timeout: 45000, skip: process.platform !== 'darwin' },
  async (t) => {
    const b = await launch(t);
    await b.invoke('space:create', { name: 'Fourth Space' });
    await b.invoke('space:create', { name: 'Fifth Space' });
    await b.invoke('space:activate', { id: b.first });
    await b.invoke('tab:create', { homePage: true });
    await b.idle();
    const native = await nativeMacScroll(b);
    await native([{ phase: 1, deltaX: 160 }, { phase: 4, deltaX: 540 }, { phase: 8 }]);
    await b.changedTo(b.second);
    for (let index = 0; index < 8; index++) {
      await native([{ momentumPhase: index ? 4 : 1, deltaX: 800 - index * 60 }]);
      await b.shell.evaluate(() => new Promise((resolve) => setTimeout(resolve, 90)));
      assert.equal(await b.current(), b.second);
    }
    await native([{ momentumPhase: 8 }]);
    await b.idle();
    await native([{ phase: 1, deltaX: -140 }, { phase: 4, deltaX: -700 }, { phase: 8 }]);
    await b.changedTo(b.first);
  },
);
