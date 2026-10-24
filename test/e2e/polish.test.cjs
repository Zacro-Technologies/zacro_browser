'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

let server, base;
const requests = new Map();
before(async () => {
  const icon = await fs.readFile(path.resolve(__dirname, '../../assets/icon-256.png'));
  server = http.createServer((request, response) => {
    requests.set(request.url, (requests.get(request.url) || 0) + 1);
    if (request.url === '/favicon.ico') {
      response.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      response.end(icon);
      return;
    }
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      `<!doctype html><html><head><link rel="icon" href="/favicon.ico" type="image/png"><title>Polish fixture ${request.url.replace(/[^a-z0-9/-]/gi, '')}</title></head><body><h1>Keyboard fixture</h1><p>Find this phrase twice. Find this phrase twice.</p><button id="target">Page target</button></body></html>`,
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {
  server?.closeAllConnections();
  if (server) await new Promise((resolve) => server.close(resolve));
});

async function bounded(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(false), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function launch(t, existingDirectory) {
  const directory = existingDirectory || (await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-e2e-polish-')));
  const env = { ...process.env, ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 30000 });
  const errors = [];
  let stderr = '';
  app.process().stderr?.on('data', (chunk) => {
    stderr = (stderr + chunk.toString()).slice(-16000);
  });
  let didClose = false;
  const close = async () => {
    if (didClose) return;
    didClose = true;
    const closed = await bounded(
      app
        .close()
        .then(() => true)
        .catch(() => false),
      5000,
    );
    if (!closed) {
      await bounded(
        app.evaluate(({ app }) => app.exit(0)).catch(() => {}),
        1000,
      );
      app.process().kill('SIGKILL');
    }
  };
  t.after(async () => {
    await close();
    if (stderr.includes('[test-uncaught]')) t.diagnostic(stderr);
    assert(path.resolve(directory).startsWith(path.resolve(os.tmpdir()) + path.sep));
    if (!existingDirectory)
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, [], 'The renderer must not throw during keyboard interactions');
  });
  await app.evaluate(({ app }) => {
    process.on('uncaughtException', (error) => {
      console.error('[test-uncaught]', error.stack || error.message);
      app.exit(1);
    });
  });
  const shell = await app.firstWindow();
  shell.on('pageerror', (error) => errors.push(error.message));
  await shell.waitForFunction(() => Boolean(window.zacro));
  await expect(shell.locator('[data-key="address"]')).toBeVisible();
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = (url, expression) =>
    app.evaluate(
      ({ webContents }, { url, expression }) => {
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        return contents?.executeJavaScript(expression) ?? null;
      },
      { url, expression },
    );
  const navigate = async (url) => {
    await invoke('navigate', { url });
    await expect.poll(() => guest(url, 'document.readyState')).toBe('complete');
    await expect.poll(async () => (await state()).runtime.page.loading).toBe(false);
  };
  return { app, shell, invoke, state, guest, navigate, close, directory };
}

test(
  'command bar supports composition, selection, modal focus containment and return after state updates',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const { shell } = browser;
    const address = shell.locator('[data-key="address"]');
    await address.focus();
    await shell.keyboard.press('Enter');
    const input = shell.locator('#command-input');
    await expect(input).toBeFocused();
    await input.fill(`${base}/composition`);
    await input.evaluate((element) => {
      element.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: 'かな' }));
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'Enter',
          code: 'Enter',
          bubbles: true,
          cancelable: true,
          isComposing: true,
        }),
      );
      element.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'かな' }));
    });
    await expect(input).toBeVisible();
    assert.equal(
      (await browser.state()).tabs.some((tab) => tab.url === `${base}/composition`),
      false,
    );
    await input.fill('');
    await shell.keyboard.press('ArrowDown');
    const selected = await input.getAttribute('aria-activedescendant');
    await expect(shell.locator(`#${selected}`)).toHaveAttribute('aria-selected', 'true');
    await expect(input).toBeFocused();
    await shell.keyboard.press('Tab');
    await expect(input).toBeFocused();
    await shell.keyboard.press('Shift+Tab');
    await expect(input).toBeFocused();
    await address.evaluate((element) => element.focus());
    await expect(input).toBeFocused();
    const current = (await browser.state()).activeTabId;
    await browser.invoke('tab:update', { id: current, title: 'Background title update' });
    await shell.keyboard.press('Escape');
    await expect(shell.getByRole('dialog')).toHaveCount(0);
    await expect(address).toBeFocused();
    await shell.keyboard.press('Control+l');
    await expect(input).toBeFocused();
    await input.fill(`${base}/composition`);
    await shell.keyboard.press('Enter');
    await expect.poll(() => browser.guest(`${base}/composition`, 'document.readyState')).toBe('complete');
  },
);

test(
  'a maximized window restores its saved normal size and position after restarting',
  { timeout: 45000 },
  async (t) => {
    const first = await launch(t);
    let second;
    try {
      const normal = await first.app.evaluate(({ BrowserWindow, screen }) => {
        const window = BrowserWindow.getAllWindows()[0];
        window.unmaximize();
        const work = screen.getPrimaryDisplay().workArea;
        const width = Math.min(1100, work.width - 40),
          height = Math.min(760, work.height - 40);
        const x = work.x + 20,
          y = work.y + 20;
        window.setContentSize(width, height);
        window.setPosition(x, y);
        return { x, y, width, height };
      });
      await expect
        .poll(async () => {
          const size = await first.app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()[0].getContentSize(),
          );
          return Math.abs(size[0] - normal.width) <= 2 && Math.abs(size[1] - normal.height) <= 2;
        })
        .toBe(true);
      Object.assign(
        normal,
        await first.app.evaluate(({ BrowserWindow }) => {
          const window = BrowserWindow.getAllWindows()[0];
          const { x, y } = window.getBounds();
          const [width, height] = window.getContentSize();
          return { x, y, width, height };
        }),
      );
      await first.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].maximize());
      await expect
        .poll(() => first.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isMaximized()))
        .toBe(true);
      await first.close();
      const savedBounds = JSON.parse(
        await fs.readFile(path.join(first.directory, 'browser-state.json'), 'utf8'),
      ).windowBounds;
      second = await launch(t, first.directory);
      await expect
        .poll(() =>
          second.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isMaximized()),
        )
        .toBe(true);
      await second.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].unmaximize());
      await expect
        .poll(() =>
          second.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isMaximized()),
        )
        .toBe(false);
      const restored = await second.app.evaluate(({ BrowserWindow }) => {
        const window = BrowserWindow.getAllWindows()[0];
        const { x, y } = window.getBounds();
        const [width, height] = window.getContentSize();
        return { x, y, width, height };
      });
      if (['x', 'y', 'width', 'height'].some((key) => Math.abs(restored[key] - normal[key]) > 2))
        t.diagnostic(JSON.stringify({ normal, savedBounds, restored }));
      for (const key of ['x', 'y', 'width', 'height'])
        assert(
          Math.abs(restored[key] - normal[key]) <= 2,
          `Restored ${key} ${restored[key]} must match ${normal[key]}`,
        );
    } finally {
      await second?.close();
    }
  },
);

test(
  'Space forms and tab context actions are usable with the keyboard and restore focus',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const { shell } = browser;
    const picker = shell.locator('[data-key="space-picker"]');
    await picker.focus();
    await shell.keyboard.press('Enter');
    await shell
      .getByRole('dialog', { name: 'Your Spaces' })
      .getByRole('button', { name: 'New Space', exact: true })
      .focus();
    await shell.keyboard.press('Enter');
    const dialog = shell.getByRole('dialog', { name: 'Create a Space' });
    await expect(dialog.getByRole('textbox', { name: 'Space name' })).toBeFocused();
    await dialog.getByRole('textbox', { name: 'Space name' }).fill('Keyboard Space');
    const close = dialog.getByRole('button', { name: 'Close', exact: true });
    await close.focus();
    await shell.keyboard.press('Shift+Tab');
    await expect(dialog.getByRole('button', { name: 'Create Space', exact: true })).toBeFocused();
    await shell.keyboard.press('Tab');
    await expect(close).toBeFocused();
    await dialog.getByRole('button', { name: 'Create Space', exact: true }).focus();
    await shell.keyboard.press('Enter');
    await expect(dialog).toHaveCount(0);
    await expect
      .poll(async () => (await browser.state()).spaces.some((space) => space.name === 'Keyboard Space'))
      .toBe(true);
    await expect(picker).toBeFocused();
    await shell.keyboard.press('Control+t');
    await expect(shell.locator('#command-input')).toBeFocused();
    await shell.locator('#command-input').fill(`${base}/keyboard-rename`);
    await shell.keyboard.press('Enter');
    await expect.poll(() => browser.guest(`${base}/keyboard-rename`, 'document.readyState')).toBe('complete');
    const tabId = (await browser.state()).activeTabId;
    const tab = shell.locator(`[data-key="tab-${tabId}"]`);
    await tab.focus();
    await shell.keyboard.press('Shift+F10');
    await expect(shell.getByRole('dialog', { name: 'Tab actions' })).toBeVisible();
    await shell.getByRole('button', { name: 'Rename tab', exact: true }).focus();
    await shell.keyboard.press('Enter');
    const rename = shell.getByRole('dialog', { name: 'Rename tab' });
    await rename.getByRole('textbox').fill('Keyboard renamed tab');
    await shell.keyboard.press('Enter');
    await expect(rename).toHaveCount(0);
    await expect(tab).toBeFocused();
    await expect(tab).toContainText('Keyboard renamed tab');
    const loads = requests.get('/keyboard-rename');
    await browser.invoke('reload');
    await expect.poll(() => requests.get('/keyboard-rename')).toBe(loads + 1);
    await expect.poll(() => browser.guest(`${base}/keyboard-rename`, 'document.readyState')).toBe('complete');
    await expect(tab).toContainText('Keyboard renamed tab');
  },
);

test(
  'panels focus their controls, retain search drafts during updates and return to their opener',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const { shell } = browser;
    const history = shell.locator('[data-key="panel-history"]');
    await history.focus();
    await shell.keyboard.press('Enter');
    const search = shell.locator('#panel-search');
    await expect(search).toBeFocused();
    await search.fill('unmatched search');
    await browser.invoke('tab:update', {
      id: (await browser.state()).activeTabId,
      title: 'Async page metadata',
    });
    await expect(search).toHaveValue('unmatched search');
    await expect(search).toBeFocused();
    await shell.keyboard.press('Escape');
    await expect(shell.locator('#side-panel')).toBeHidden();
    await expect(history).toBeFocused();
    const settings = shell.locator('[data-key="panel-settings"]');
    await settings.focus();
    await shell.keyboard.press('Enter');
    await expect
      .poll(() =>
        shell.evaluate(() => document.querySelector('#side-panel').contains(document.activeElement)),
      )
      .toBe(true);
    await shell.keyboard.press('Escape');
    await expect(settings).toBeFocused();
  },
);

test(
  'light, dark and system appearance retain readable text, reduced motion and usable minimum window geometry',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const { shell } = browser;
    await shell.emulateMedia({ reducedMotion: 'reduce', colorScheme: 'light' });
    await shell.locator('[data-key="panel-settings"]').click();
    const appearance = shell.locator('select[data-setting="theme"]');
    for (const theme of ['light', 'dark']) {
      await appearance.selectOption(theme);
      await expect(shell.locator('html')).toHaveAttribute('data-theme', theme);
      const contrast = await shell.evaluate(() => {
        // Let Chromium resolve color-mix()/color(srgb) and alpha compositing
        // instead of assuming all computed CSS colors use rgb() serialization.
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 1;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        const pixel = () => [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
        const luminance = (color) =>
          color
            .map((channel) => channel / 255)
            .map((channel) => (channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4))
            .reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
        const ratio = (foreground, background) => {
          const a = luminance(foreground),
            b = luminance(background);
          return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
        };
        const background = (element) => {
          const ancestors = [];
          while (element) {
            ancestors.unshift(element);
            element = element.parentElement;
          }
          context.fillStyle = '#fff';
          context.fillRect(0, 0, 1, 1);
          for (const ancestor of ancestors) {
            context.fillStyle = getComputedStyle(ancestor).backgroundColor;
            context.fillRect(0, 0, 1, 1);
          }
          return pixel();
        };
        return ['.profile-caption', '.section-label', '.provider-note', '.setting-section h3'].map(
          (selector) => {
            const element = document.querySelector(selector);
            const behind = background(element);
            context.fillStyle = getComputedStyle(element).color;
            context.fillRect(0, 0, 1, 1);
            return { selector, ratio: ratio(pixel(), behind) };
          },
        );
      });
      for (const sample of contrast)
        assert(sample.ratio >= 4.5, `${theme} ${sample.selector} contrast is ${sample.ratio.toFixed(2)}:1`);
    }
    await appearance.selectOption('system');
    await shell.emulateMedia({ reducedMotion: 'reduce', colorScheme: 'light' });
    await expect(shell.locator('html')).toHaveAttribute('data-theme', 'light');
    await shell.emulateMedia({ reducedMotion: 'reduce', colorScheme: 'dark' });
    await expect(shell.locator('html')).toHaveAttribute('data-theme', 'dark');
    for (const size of [
      [960, 640],
      [1440, 900],
    ]) {
      await browser.app.evaluate(
        ({ BrowserWindow }, size) => BrowserWindow.getAllWindows()[0].setContentSize(...size),
        size,
      );
      await expect
        .poll(async () => Math.abs((await shell.evaluate(() => innerWidth)) - size[0]) <= 2)
        .toBe(true);
      const geometry = await shell.evaluate(() => {
        const selectors = ['#sidebar', '#toolbar', '#side-panel', '[data-key="address"]'];
        return selectors.map((selector) => {
          const rect = document.querySelector(selector).getBoundingClientRect();
          return {
            selector,
            x: rect.x,
            y: rect.y,
            right: rect.right,
            bottom: rect.bottom,
            width: rect.width,
            viewportWidth: innerWidth,
            viewportHeight: innerHeight,
          };
        });
      });
      for (const box of geometry) {
        assert(
          box.x >= 0 &&
            box.y >= 0 &&
            box.right <= box.viewportWidth + 1 &&
            box.bottom <= box.viewportHeight + 1,
          `${box.selector} must remain in the ${size.join('x')} viewport`,
        );
        assert(
          box.width >= (box.selector.includes('address') ? 120 : 200),
          `${box.selector} must retain usable width`,
        );
      }
      assert.equal(await shell.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    }
    await shell.keyboard.press('Escape');
    await shell.locator('[data-key="address"]').click();
    const motion = await shell.evaluate(() =>
      [...document.querySelectorAll('.dialog,.icon-button,.sidebar,.side-panel')]
        .filter((element) => element.getClientRects().length)
        .map((element) => ({
          animation: getComputedStyle(element).animationDuration,
          transition: getComputedStyle(element).transitionDuration,
        })),
    );
    assert(motion.length > 0);
    for (const item of motion) {
      assert(item.animation.split(',').every((value) => parseFloat(value) === 0));
      assert(item.transition.split(',').every((value) => parseFloat(value) === 0));
    }
    assert.equal(
      await shell.evaluate(
        () => document.getAnimations().filter((animation) => animation.playState === 'running').length,
      ),
      0,
    );
  },
);

test(
  'F5 with toolbar focus reloads the web page and preserves browser chrome',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/reload`);
    const initial = requests.get('/reload');
    await browser.shell.evaluate(() => {
      document.documentElement.dataset.reloadSentinel = 'retained';
    });
    await browser.shell.locator('[data-key="address"]').focus();
    // Chromium's DevTools keyboard dispatch does not consistently reach
    // Electron's before-input-event handler. Exercise the native shortcut path.
    await browser.app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      window.focus();
      window.webContents.focus();
      window.webContents.sendInputEvent({ type: 'keyDown', keyCode: 'F5' });
      window.webContents.sendInputEvent({ type: 'keyUp', keyCode: 'F5' });
    });
    await expect.poll(() => requests.get('/reload')).toBe(initial + 1);
    await expect.poll(() => browser.guest(`${base}/reload`, 'document.readyState')).toBe('complete');
    await expect(browser.shell.locator('html')).toHaveAttribute('data-reload-sentinel', 'retained');
  },
);

test(
  'Peek dismissal and Find keyboard navigation return focus to the underlying page',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const parentURL = `${base}/focus-parent`;
    await browser.navigate(parentURL);
    await browser.guest(parentURL, 'document.getElementById("target").focus(); undefined');
    await browser.invoke('peek:open', { url: `${base}/focus-peek` });
    await expect.poll(() => browser.guest(`${base}/focus-peek`, 'document.readyState')).toBe('complete');
    await browser.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.focus();
      contents.sendInputEvent({ type: 'keyDown', keyCode: 'Escape' });
      contents.sendInputEvent({ type: 'keyUp', keyCode: 'Escape' });
    }, `${base}/focus-peek`);
    await expect.poll(async () => (await browser.state()).runtime.peek).toBe(null);
    await expect
      .poll(() => browser.guest(parentURL, 'document.hasFocus() && document.activeElement.id'))
      .toBe('target');
    await browser.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.sendInputEvent({ type: 'keyDown', keyCode: 'F', modifiers: ['control'] });
      contents.sendInputEvent({ type: 'keyUp', keyCode: 'F', modifiers: ['control'] });
    }, parentURL);
    const find = browser.shell.locator('#find-input');
    await expect(find).toBeFocused();
    await find.fill('Find this phrase');
    await expect(browser.shell.locator('#find-count')).toHaveText('1/2');
    await browser.shell.keyboard.press('Enter');
    await expect(browser.shell.locator('#find-count')).toHaveText('2/2');
    await browser.shell.keyboard.press('Shift+Enter');
    await expect(browser.shell.locator('#find-count')).toHaveText('1/2');
    await find.fill('');
    await expect(find).toBeFocused();
    await expect(browser.shell.locator('#find-count')).toHaveText('');
    await expect
      .poll(() =>
        browser.app.evaluate(
          ({ BrowserWindow, webContents }) =>
            webContents.getFocusedWebContents()?.id === BrowserWindow.getAllWindows()[0].webContents.id,
        ),
      )
      .toBe(true);
    await find.fill('Find this phrase');
    await expect(browser.shell.locator('#find-count')).toHaveText('1/2');
    await browser.shell.keyboard.press('Escape');
    await expect(browser.shell.locator('#findbar')).toBeHidden();
    await expect.poll(() => browser.guest(parentURL, 'document.hasFocus()')).toBe(true);
  },
);

test(
  'focusing a split pane updates navigation target without swapping native bounds or visibility churn',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/left`);
    const leftId = (await browser.state()).activeTabId;
    const right = await browser.invoke('tab:create', { url: `${base}/right` });
    await expect.poll(() => browser.guest(`${base}/right`, 'document.readyState')).toBe('complete');
    await browser.invoke('tab:activate', { id: leftId });
    await browser.invoke('split:toggle', { id: right.id });
    const bounds = () =>
      browser.app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()[0]
          .contentView.children.filter((view) => view.webContents?.getURL().startsWith('http://127.0.0.1:'))
          .map((view) => ({ id: view.webContents.id, bounds: view.getBounds() }))
          .sort((a, b) => a.id - b.id),
      );
    const original = await bounds();
    assert.equal(original.length, 2);
    await browser.app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === url)
          .focus(),
      `${base}/right`,
    );
    await expect.poll(async () => (await browser.state()).activeTabId).toBe(right.id);
    assert.equal((await browser.state()).runtime.splitTabId, leftId);
    await expect(browser.shell.locator('[data-key="address"]')).toHaveAttribute('title', `${base}/right`);
    assert.deepEqual(await bounds(), original, 'Pane positions must stay stable when focus moves');
    await browser.app.evaluate(({ BrowserWindow }) => {
      globalThis.__polishVisibilityCalls = [];
      for (const view of BrowserWindow.getAllWindows()[0].contentView.children) {
        const original = view.setVisible.bind(view);
        view.setVisible = (visible) => {
          globalThis.__polishVisibilityCalls.push(visible);
          return original(visible);
        };
      }
    });
    await browser.invoke('tab:update', { id: right.id, title: 'Updated split title' });
    await browser.invoke('settings:update', { values: { openSourcesLimit: 3 } });
    assert.deepEqual(
      await browser.app.evaluate(() => globalThis.__polishVisibilityCalls),
      [],
      'Metadata updates must not hide and re-show native pages',
    );
    await browser.navigate(`${base}/right-next`);
    await expect.poll(() => browser.guest(`${base}/left`, 'document.readyState')).toBe('complete');
    assert.deepEqual(await bounds(), original, 'Navigation must preserve the split pane geometry');
  },
);

test(
  'modal page backdrops are bounded, cleared on dismissal and never captured in private profiles',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const url = `${base}/backdrop`;
    await browser.navigate(url);
    await browser.guest(
      url,
      'new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))',
    );
    await browser.shell.evaluate(() => {
      window.__backdropEvents = [];
      window.zacro.onEvent((event) => {
        if (event.type === 'page:backdrop') window.__backdropEvents.push(event.frames);
      });
    });
    await browser.app.evaluate(({ BrowserWindow, webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      const original = contents.capturePage.bind(contents);
      globalThis.__backdropCaptures = [];
      contents.capturePage = async (...args) => {
        const start = Date.now();
        // Submit the real native copy on the next event-loop turn, after the
        // modal's synchronous hide. This reproduces deferred GPU submission.
        await new Promise(setImmediate);
        const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
          (view) => view.webContents === contents,
        );
        const submission = { attached: Boolean(view), visible: view?.getVisible() ?? false };
        const result = await original(...args);
        globalThis.__backdropCaptures.push({
          elapsed: Date.now() - start,
          empty: result.isEmpty(),
          ...submission,
        });
        return result;
      };
    }, url);
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    try {
      await expect.poll(() => browser.shell.evaluate(() => window.__backdropEvents.at(-1)?.length)).toBe(1);
    } catch (error) {
      t.diagnostic(
        JSON.stringify({
          captures: await browser.app.evaluate(() => globalThis.__backdropCaptures),
          events: await browser.shell.evaluate(() => window.__backdropEvents.map((frames) => frames.length)),
        }),
      );
      throw error;
    }
    const capture = await browser.app.evaluate(() => globalThis.__backdropCaptures[0]);
    assert.equal(capture.attached, true, 'The native surface stays attached until the compositor copies it');
    assert.equal(capture.visible, false, 'The modal must hide the native page immediately');
    assert.equal(capture.empty, false);
    await expect(browser.shell.locator('#page-backdrop img')).toHaveCount(1);
    const attachedCount = () =>
      browser.app.evaluate(
        ({ BrowserWindow }, url) =>
          BrowserWindow.getAllWindows()[0].contentView.children.filter(
            (view) => view.webContents?.getURL() === url,
          ).length,
        url,
      );
    await expect.poll(attachedCount).toBe(0);
    const frame = await browser.shell.evaluate(() => {
      const frame = window.__backdropEvents.at(-1)[0];
      return { bounds: frame.bounds, prefix: frame.dataUrl.slice(0, 30), size: frame.dataUrl.length };
    });
    assert.match(frame.prefix, /^data:image\/jpeg;base64,\/9j\//);
    assert(frame.size < 1.4 * 1024 * 1024);
    assert(frame.bounds.width > 0 && frame.bounds.height > 0);
    await browser.shell.keyboard.press('Escape');
    await expect.poll(() => browser.shell.evaluate(() => window.__backdropEvents.at(-1)?.length)).toBe(0);

    // Hold capture completion to reproduce dismissal while a native capture is in
    // flight. The real captured frame must not be delivered after the modal closes.
    await browser.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      const original = contents.capturePage.bind(contents);
      globalThis.__polishCapturePending = null;
      contents.capturePage = (...args) =>
        new Promise((resolve) => {
          globalThis.__polishCapturePending = async () => resolve(await original(...args));
        });
    }, url);
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    assert.equal(await browser.app.evaluate(() => typeof globalThis.__polishCapturePending), 'function');
    await browser.shell.keyboard.press('Escape');
    await browser.app.evaluate(async () => {
      await globalThis.__polishCapturePending();
    });
    await expect.poll(() => browser.shell.evaluate(() => window.__backdropEvents.at(-1)?.length)).toBe(0);

    // A stalled compositor cannot keep an invisible native child attached or
    // stop the command field from working. The capture deadline releases it.
    await browser.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.capturePage = () => new Promise(() => {});
    }, url);
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    await browser.shell.locator('#command-input').fill('The modal remains interactive');
    await expect.poll(attachedCount, { timeout: 2000 }).toBe(0);
    await expect(browser.shell.locator('#command-input')).toHaveValue('The modal remains interactive');
    await expect(browser.shell.locator('#page-backdrop img')).toHaveCount(0);
    await browser.shell.keyboard.press('Escape');

    const profile = await browser.invoke('profile:create', { name: 'Private backdrop', private: true });
    const privateSpace = (await browser.state()).spaces.find((space) => space.profileId === profile.id);
    await browser.invoke('space:activate', { id: privateSpace.id });
    await browser.navigate(`${base}/private-backdrop`);
    await browser.app.evaluate(({ webContents }, url) => {
      globalThis.__polishPrivateCaptureCount = 0;
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      const original = contents.capturePage.bind(contents);
      contents.capturePage = (...args) => {
        globalThis.__polishPrivateCaptureCount++;
        return original(...args);
      };
    }, `${base}/private-backdrop`);
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    await expect.poll(() => browser.shell.evaluate(() => window.__backdropEvents.at(-1)?.length)).toBe(0);
    assert.equal(await browser.app.evaluate(() => globalThis.__polishPrivateCaptureCount), 0);
  },
);

test(
  'site favicons render from bounded host-provided images without remote image privileges in browser chrome',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/favicon-page`);
    const id = (await browser.state()).activeTabId;
    await expect
      .poll(async () =>
        (await browser.state()).runtime.pages[id]?.favicon?.startsWith('data:image/png;base64,'),
      )
      .toBe(true);
    const image = browser.shell.locator(`[data-key="tab-${id}"] img`);
    await expect(image).toBeVisible();
    await expect
      .poll(() => image.evaluate((element) => element.complete && element.naturalWidth > 0))
      .toBe(true);
    assert.match(await image.getAttribute('src'), /^data:image\/png;base64,/);
    const policy = await browser.shell
      .locator('meta[http-equiv="Content-Security-Policy"]')
      .getAttribute('content');
    assert.match(policy, /img-src 'self' data:/);
    assert.equal(await browser.shell.locator('img[src^="http:"] ,img[src^="https:"]').count(), 0);
    await browser.invoke('navigate', { url: 'zacro://newtab' });
    await expect(browser.shell.locator(`[data-key="tab-${id}"] img`)).toHaveCount(0);
  },
);

test(
  'Windows contrast colors preserve focus, selected controls, empty and error states, and live motion changes',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const { shell } = browser;
    await shell.emulateMedia({ forcedColors: 'active', reducedMotion: 'reduce' });
    assert.equal(await shell.evaluate(() => matchMedia('(forced-colors: active)').matches), true);
    const visibleOutline = (locator) =>
      locator.evaluate((element) => {
        const style = getComputedStyle(element);
        return style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 2;
      });
    await shell.locator('#home-query').focus();
    assert.equal(await visibleOutline(shell.locator('#home-query')), true);
    await shell.locator('[data-key="panel-history"]').click();
    await expect(shell.locator('.empty-state h3')).toBeVisible();
    assert.equal(
      await shell.locator('.empty-state p').evaluate((element) => {
        const style = getComputedStyle(element);
        const panel = getComputedStyle(document.querySelector('#side-panel'));
        return style.color !== panel.backgroundColor && style.opacity === '1';
      }),
      true,
    );
    await shell.keyboard.press('Escape');
    await shell.locator('[data-key="panel-settings"]').click();
    const toggle = shell.locator('input[data-setting="restoreSession"]');
    assert.equal(await toggle.evaluate((element) => getComputedStyle(element).appearance), 'auto');
    await shell.keyboard.press('Tab');
    await toggle.focus();
    assert.equal(await visibleOutline(toggle), true);
    const checked = await toggle.isChecked();
    await shell.keyboard.press('Space');
    await expect.poll(async () => (await browser.state()).settings.restoreSession).toBe(!checked);
    await shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    const swatch = shell.getByRole('button', { name: 'forest', exact: true });
    assert.equal(
      await swatch.evaluate((element) => getComputedStyle(element, '::before').content),
      '"forest"',
    );
    await swatch.click();
    await expect(swatch).toHaveAttribute('aria-pressed', 'true');
    assert.equal(await visibleOutline(swatch), true);
    await shell.keyboard.press('Escape');
    await shell.keyboard.press('Escape');
    await shell.locator('[data-key="address"]').click();
    await shell.locator('#command-input').fill('contrast test');
    assert.equal(await visibleOutline(shell.locator('.command-result.selected')), true);
    assert.equal(await visibleOutline(shell.locator('#command-input')), true);
    await shell.keyboard.press('Escape');

    // Chromium rejects this unsafe port locally, without making a network request.
    await browser.invoke('navigate', { url: 'http://127.0.0.1:1/' });
    await expect(shell.locator('#page-status')).toBeVisible();
    await expect(shell.getByRole('button', { name: 'Try again', exact: true })).toBeVisible();
    await shell.getByRole('button', { name: 'Edit address', exact: true }).focus();
    assert.equal(
      await visibleOutline(shell.getByRole('button', { name: 'Edit address', exact: true })),
      true,
    );
    const errorBorder = await shell.locator('.error-card').evaluate((element) => {
      const style = getComputedStyle(element);
      return {
        style: style.borderTopStyle,
        width: style.borderTopWidth,
        forced: matchMedia('(forced-colors: active)').matches,
      };
    });
    assert(errorBorder.style !== 'none' && parseFloat(errorBorder.width) > 0, JSON.stringify(errorBorder));
    await browser.invoke('navigate', { url: 'zacro://newtab' });
    await shell.emulateMedia({ forcedColors: 'none', reducedMotion: 'no-preference' });
    await shell.locator('[data-key="panel-history"]').click();
    await expect(shell.locator('#panel-search')).toBeFocused();
    const closing = await shell.evaluate(() => {
      const panel = document.querySelector('#side-panel');
      for (const animation of panel.getAnimations()) animation.finish();
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      const animations = panel.getAnimations();
      // Hold this real transition so the OS preference switches while it runs.
      for (const animation of animations) animation.effect.updateTiming({ duration: 10000 });
      return animations.length;
    });
    assert(closing > 0, 'A panel close transition must be in flight before changing the preference');
    await shell.emulateMedia({ reducedMotion: 'reduce' });
    await expect(shell.locator('#side-panel')).toBeHidden({ timeout: 2000 });
    await expect(shell.locator('[data-key="panel-history"]')).toBeFocused();
    assert.equal(
      await shell.evaluate(
        () => document.getAnimations().filter((animation) => animation.playState === 'running').length,
      ),
      0,
    );
  },
);

test(
  'F6 moves keyboard focus between browser controls and the page without escaping a modal',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const url = `${base}/f6-focus`;
    await browser.navigate(url);
    await browser.guest(url, 'document.getElementById("target").focus(); undefined');
    const sendF6 = (guest) =>
      browser.app.evaluate(
        ({ BrowserWindow, webContents }, { guest, url }) => {
          const contents = guest
            ? webContents.getAllWebContents().find((item) => item.getURL() === url)
            : BrowserWindow.getAllWindows()[0].webContents;
          contents.sendInputEvent({ type: 'keyDown', keyCode: 'F6' });
          contents.sendInputEvent({ type: 'keyUp', keyCode: 'F6' });
        },
        { guest, url },
      );
    await sendF6(true);
    await expect(browser.shell.locator('[data-key="address"]')).toBeFocused();
    await sendF6(false);
    await expect
      .poll(() => browser.guest(url, 'document.hasFocus() && document.activeElement.id'))
      .toBe('target');
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    await sendF6(false);
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    await expect
      .poll(() =>
        browser.app.evaluate(
          ({ BrowserWindow, webContents }) =>
            webContents.getFocusedWebContents()?.id === BrowserWindow.getAllWindows()[0].webContents.id,
        ),
      )
      .toBe(true);
  },
);

test(
  'closing a preview during a modal capture clears the preview and discards the stale frame',
  { timeout: 45000 },
  async (t) => {
    const browser = await launch(t);
    const parent = `${base}/closed-preview-parent`,
      preview = `${base}/closed-preview`;
    await browser.navigate(parent);
    await browser.invoke('peek:open', { url: preview });
    await expect.poll(() => browser.guest(preview, 'document.readyState')).toBe('complete');
    await browser.shell.evaluate(() => {
      window.__backdropEvents = [];
      window.zacro.onEvent((event) => {
        if (event.type === 'page:backdrop') window.__backdropEvents.push(event.frames);
      });
    });
    await browser.app.evaluate(
      ({ webContents, nativeImage }, { preview, icon }) => {
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === preview);
        const image = nativeImage.createFromPath(icon);
        contents.capturePage = () =>
          new Promise((resolve) => {
            globalThis.__finishClosedPreviewCapture = () => resolve(image);
          });
      },
      { preview, icon: path.resolve(__dirname, '../../assets/icon-256.png') },
    );
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    assert.equal(
      await browser.app.evaluate(() => typeof globalThis.__finishClosedPreviewCapture),
      'function',
    );
    await browser.app.evaluate(({ webContents }, preview) => {
      webContents
        .getAllWebContents()
        .find((item) => item.getURL() === preview)
        .close({ waitForBeforeUnload: false });
    }, preview);
    await expect.poll(async () => (await browser.state()).runtime.peek).toBe(null);
    await browser.app.evaluate(() => {
      globalThis.__finishClosedPreviewCapture();
    });
    await expect.poll(() => browser.shell.evaluate(() => window.__backdropEvents.at(-1)?.length)).toBe(0);
    await expect(browser.shell.locator('#command-input')).toBeFocused();
    await expect
      .poll(() =>
        browser.app.evaluate(
          ({ BrowserWindow, webContents }) =>
            webContents.getFocusedWebContents()?.id === BrowserWindow.getAllWindows()[0].webContents.id,
        ),
      )
      .toBe(true);
    await browser.shell.keyboard.press('Escape');
    assert.equal((await browser.state()).runtime.page.url, parent);
  },
);
