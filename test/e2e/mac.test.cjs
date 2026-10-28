'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { _electron: electron, expect } = require('@playwright/test');

const macOnly = { timeout: 60000, skip: process.platform !== 'darwin' };
const execFileAsync = promisify(execFile);

async function launch(t, { earlyLink = false } = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-mac-'));
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      `<!doctype html><title>Mac fixture ${request.url}</title><style>body{padding:24px;font:20px system-ui;height:1800px}input{font:inherit}</style><h1>Native Mac acceptance</h1><input id="draft" aria-label="Page draft" value="Original draft"><a href="/next">Next page</a>`,
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  let app;
  t.after(async () => {
    if (app && app.process().exitCode === null) await app.close().catch(() => app.process().kill());
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-mac-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  });
  const root = path.resolve(__dirname, '../..');
  let entry = root;
  if (earlyLink) {
    entry = path.join(directory, 'early-open.cjs');
    // Exercise Launch Services' pre-ready delivery without adding a production
    // test hook or registering the developer app as the user's default browser.
    await fs.writeFile(
      entry,
      `const load = require('node:module').createRequire(${JSON.stringify(path.join(root, 'package.json'))});
load('./src/main/main.cjs');
load('electron').app.emit('open-url', { preventDefault() {} }, ${JSON.stringify(`${base}/early-link`)});
`,
    );
  }
  app = await electron.launch({ args: [entry], env });
  let shell = await app.firstWindow();
  // DOM readiness can precede main's loadFile continuation and win.show().
  // Establish the native display precondition before focusing or capturing.
  await expect
    .poll(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isVisible()))
    .toBe(true);
  await app.evaluate(({ app, BrowserWindow }) => {
    app.focus({ steal: true });
    BrowserWindow.getAllWindows()[0].focus();
  });
  await expect
    .poll(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isFocused()))
    .toBe(true);
  await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
  if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = (url, expression) =>
    app.evaluate(
      ({ webContents }, { url, expression }) =>
        webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === url)
          ?.executeJavaScript(expression) ?? null,
      { url, expression },
    );
  const navigate = async (url) => {
    await invoke('navigate', { url });
    await expect.poll(() => guest(url, 'document.readyState')).toBe('complete');
  };
  const menu = (id) =>
    app.evaluate(({ Menu, BrowserWindow }, id) => {
      const item = Menu.getApplicationMenu().getMenuItemById(id);
      if (!item) throw new Error(`Missing native menu item: ${id}`);
      item.click(item, BrowserWindow.getFocusedWindow(), {});
    }, id);
  const reopen = async () => {
    const opened = app.waitForEvent('window');
    await app.evaluate(({ app }) => app.emit('activate', {}, false));
    shell = await opened;
    await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
    return shell;
  };
  return {
    app,
    get shell() {
      return shell;
    },
    invoke,
    state,
    guest,
    navigate,
    menu,
    reopen,
    base,
  };
}

test('macOS uses native window chrome, menu conventions and keyboard navigation', macOnly, async (t) => {
  const b = await launch(t);
  const results = path.resolve(__dirname, '../../test-results');
  await fs.mkdir(results, { recursive: true });
  const captureShell = async (name) => {
    await expect
      .poll(() =>
        b.app.evaluate(({ BrowserWindow }) => {
          const window = BrowserWindow.getAllWindows()[0];
          return window.isVisible() && window.isFocused() && !window.isMinimized();
        }),
      )
      .toBe(true);
    await b.shell.waitForFunction(() => document.visibilityState === 'visible');
    // Cross two visible compositor opportunities, rather than asking CDP for
    // the first surface before the native window has presented it.
    await b.shell.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    );
    await b.shell.screenshot({ path: path.join(results, `mac-${process.arch}-${name}.png`) });
  };
  await b.app.evaluate(({ BrowserWindow, Menu }) => {
    globalThis.macShortcutTrace = [];
    BrowserWindow.getAllWindows()[0].webContents.on('before-input-event', (event, input) => {
      globalThis.macShortcutTrace.push({ source: 'host', ...input, prevented: event.defaultPrevented });
      if (globalThis.macShortcutTrace.length > 80) globalThis.macShortcutTrace.shift();
    });
    for (const id of ['command-palette', 'next-tab', 'previous-tab', 'close-tab', 'reopen-tab']) {
      const item = Menu.getApplicationMenu().getMenuItemById(id);
      const click = item.click;
      item.click = (...args) => {
        globalThis.macShortcutTrace.push({ source: 'menu', id });
        return click.apply(item, args);
      };
    }
  });
  await b.shell.evaluate(() => {
    window.macDOMKeys = [];
    document.addEventListener(
      'keydown',
      (event) => {
        window.macDOMKeys.push({
          key: event.key,
          code: event.code,
          meta: event.metaKey,
          control: event.ctrlKey,
          shift: event.shiftKey,
          focus: document.activeElement?.id,
        });
      },
      true,
    );
  });
  const active = async (id) => {
    await expect.poll(async () => (await b.state()).activeTabId).toBe(id);
    await expect(b.shell.locator(`#sidebar .tab-main[data-id="${id}"]`)).toHaveAttribute(
      'aria-current',
      'page',
    );
  };
  const focusChrome = async () => {
    await b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.focus());
    await b.shell.locator('[data-key="address"]').focus();
    await expect(b.shell.locator('[data-key="address"]')).toBeFocused();
  };
  const nativeShortcut = async (keyCode, modifiers, target = 'host') => {
    // CDP keyboard events reach the DOM but bypass Electron's before-input-event.
    // Exercise the native shortcut owner without changing first-responder focus.
    const offset = await b.app.evaluate(
      ({ BrowserWindow, webContents }, { keyCode, modifiers, target }) => {
        const offset = globalThis.macShortcutTrace.length;
        const contents =
          target === 'focused'
            ? webContents.getFocusedWebContents()
            : BrowserWindow.getAllWindows()[0].webContents;
        if (!contents) throw new Error('The native shortcut has no focused target');
        if (target === 'focused') {
          contents.once('before-input-event', (event, input) => {
            globalThis.macShortcutTrace.push({
              source: 'focused',
              contentsId: contents.id,
              ...input,
              prevented: event.defaultPrevented,
            });
          });
        }
        contents.sendInputEvent({ type: 'keyDown', keyCode, modifiers });
        contents.sendInputEvent({ type: 'keyUp', keyCode, modifiers });
        return offset;
      },
      { keyCode, modifiers, target },
    );
    await expect
      .poll(() =>
        b.app.evaluate(
          (_electron, { offset, keyCode, modifiers, target }) =>
            globalThis.macShortcutTrace
              .slice(offset)
              .some(
                (input) =>
                  input.source === target &&
                  input.type === 'keyDown' &&
                  input.key.toLowerCase() === keyCode.toLowerCase() &&
                  input.meta === modifiers.includes('meta') &&
                  input.control === modifiers.includes('control') &&
                  input.shift === modifiers.includes('shift') &&
                  input.prevented,
              ),
          { offset, keyCode, modifiers, target },
        ),
      )
      .toBe(true);
  };
  try {
    await expect(b.shell.locator('html')).toHaveAttribute('data-platform', 'darwin');
    await expect(b.shell.locator('html')).toHaveAttribute('data-fullscreen', 'false');
    await expect(b.shell.locator('.window-controls')).toHaveCount(0);
    const native = await b.app.evaluate(({ BrowserWindow, Menu }) => {
      const win = BrowserWindow.getAllWindows()[0];
      const flatten = (menu) =>
        menu.items.flatMap((item) => [
          { id: item.id, label: item.label, role: item.role, accelerator: item.accelerator },
          ...(item.submenu ? flatten(item.submenu) : []),
        ]);
      return {
        buttons: win.getWindowButtonPosition(),
        fullscreen: win.isFullScreen(),
        menu: flatten(Menu.getApplicationMenu()),
      };
    });
    assert.deepEqual(native.buttons, { x: 16, y: 12 });
    assert.equal(native.fullscreen, false);
    for (const role of ['services', 'hide', 'hideothers', 'quit', 'minimize', 'zoom', 'front'])
      assert(
        native.menu.some((item) => item.role?.toLowerCase() === role),
        `Native ${role} menu role`,
      );
    assert.equal(native.menu.find((item) => item.id === 'preferences')?.accelerator, 'Command+,');
    assert.equal(native.menu.find((item) => item.id === 'close-window')?.accelerator, 'Command+Shift+W');
    assert((await b.shell.locator('[data-key="back"]').boundingBox()).x >= 88);
    assert((await b.shell.locator('.space-picker').boundingBox()).x < 30);
    await captureShell('shell');
    // Only capture the disposable CI desktop; local developers may have personal
    // windows visible. Native window controls are outside the shell screenshot.
    if (process.env.CI === 'true' && process.env.GITHUB_ACTIONS === 'true') {
      await execFileAsync(
        '/usr/sbin/screencapture',
        ['-x', path.join(results, `mac-${process.arch}-desktop.png`)],
        {
          timeout: 5000,
        },
      ).catch((error) => console.warn(`Optional native desktop capture unavailable: ${error.message}`));
    }

    await nativeShortcut('S', ['meta']);
    assert((await b.shell.locator('[data-key="back"]').boundingBox()).x >= 88);
    await captureShell('sidebar-hidden');
    await nativeShortcut('S', ['meta']);
    await nativeShortcut(',', ['meta']);
    await expect(b.shell.locator('#panel-title')).toHaveText('Settings');
    await captureShell('settings');
    await b.shell.keyboard.press('Escape');
    await nativeShortcut('L', ['meta']);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await b.shell.keyboard.press('Escape');

    await b.navigate(`${b.base}/initial`);
    const initial = (await b.state()).activeTabId;
    await active(initial);
    await focusChrome();
    await nativeShortcut('T', ['meta']);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await b.shell.keyboard.press('Escape');
    assert.equal((await b.state()).activeTabId, initial);
    assert.equal((await b.state()).tabs.length, 1);
    await focusChrome();
    await nativeShortcut('T', ['meta']);
    await b.shell.locator('#command-input').fill(`${b.base}/second`);
    await b.shell.locator('#command-input').press('Enter');
    await expect.poll(async () => (await b.state()).activeTabId).not.toBe(initial);
    const second = (await b.state()).activeTabId;
    assert.notEqual(initial, second);
    await active(second);
    await focusChrome();
    await nativeShortcut('Tab', ['control']);
    await active(initial);
    await focusChrome();
    await nativeShortcut('Tab', ['control', 'shift']);
    await active(second);
    await b.navigate(`${b.base}/restore`);
    await b.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.focus();
      contents.sendInputEvent({ type: 'keyDown', keyCode: 'W', modifiers: ['meta'] });
      contents.sendInputEvent({ type: 'keyUp', keyCode: 'W', modifiers: ['meta'] });
    }, `${b.base}/restore`);
    await expect.poll(async () => (await b.state()).tabs.some((tab) => tab.id === second)).toBe(false);
    await active(initial);
    // Closing the active guest transfers input to the surviving page. Verify the
    // actual first responder and exercise reopen there without a test focus/click
    // override, so both page typing and the native browser shortcut stay usable.
    await expect
      .poll(() =>
        b.app.evaluate(
          ({ webContents }, url) => webContents.getFocusedWebContents()?.getURL() === url,
          `${b.base}/initial`,
        ),
      )
      .toBe(true);
    await nativeShortcut('T', ['meta', 'shift'], 'focused');
    await expect.poll(async () => (await b.state()).tabs.some((tab) => tab.id === second)).toBe(true);

    await b.invoke('window:fullscreen');
    await expect(b.shell.locator('html')).toHaveAttribute('data-fullscreen', 'true', { timeout: 15000 });
    assert.equal(
      await b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isFullScreen()),
      true,
    );
    await b.invoke('window:fullscreen');
    await expect(b.shell.locator('html')).toHaveAttribute('data-fullscreen', 'false', { timeout: 15000 });
    assert((await b.shell.locator('[data-key="back"]').boundingBox()).x >= 88);
  } catch (error) {
    const diagnostics = await b.app
      .evaluate(({ BrowserWindow, webContents }) => ({
        inputs: globalThis.macShortcutTrace,
        shell: BrowserWindow.getAllWindows()[0]?.webContents.id,
        window: BrowserWindow.getAllWindows()[0]
          ? {
              visible: BrowserWindow.getAllWindows()[0].isVisible(),
              focused: BrowserWindow.getAllWindows()[0].isFocused(),
              minimized: BrowserWindow.getAllWindows()[0].isMinimized(),
              bounds: BrowserWindow.getAllWindows()[0].getBounds(),
              contentBounds: BrowserWindow.getAllWindows()[0].getContentBounds(),
            }
          : null,
        focused: webContents.getFocusedWebContents()?.id,
        contents: webContents
          .getAllWebContents()
          .map((contents) => ({ id: contents.id, url: contents.getURL() })),
      }))
      .catch(() => null);
    const state = await b.state().catch(() => null);
    const domKeys = await b.shell.evaluate(() => window.macDOMKeys).catch(() => null);
    const renderer = await b.shell
      .evaluate(() => ({
        visibility: document.visibilityState,
        readyState: document.readyState,
        width: innerWidth,
        height: innerHeight,
      }))
      .catch(() => null);
    console.error(
      'Mac shortcut diagnostics:',
      JSON.stringify({
        diagnostics,
        domKeys,
        renderer,
        activeTab: state?.activeTabId,
        tabs: state?.tabs,
        archive: state?.archive,
      }),
    );
    await b.shell.screenshot({ path: path.join(results, `mac-${process.arch}-failure.png`) }).catch(() => {});
    throw error;
  }
});

test('macOS native edit actions and browser shortcuts target the focused web page', macOnly, async (t) => {
  const b = await launch(t);
  const url = `${b.base}/editing`;
  await b.navigate(`${b.base}/before-editing`);
  await b.navigate(url);
  await b.app.evaluate(({ webContents }, url) => {
    const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
    contents.focus();
  }, url);
  await b.guest(url, 'document.getElementById("draft").focus(); undefined');
  await b.menu('edit-select-all');
  await expect
    .poll(() =>
      b.guest(
        url,
        '({ start: document.getElementById("draft").selectionStart, end: document.getElementById("draft").selectionEnd })',
      ),
    )
    .toEqual({ start: 0, end: 14 });
  await b.app.evaluate(async ({ webContents }, url) => {
    const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
    await contents.insertText('Edited on a Mac');
  }, url);
  assert.equal(await b.guest(url, 'document.getElementById("draft").value'), 'Edited on a Mac');
  await b.menu('edit-undo');
  await expect.poll(() => b.guest(url, 'document.getElementById("draft").value')).toBe('Original draft');
  await b.menu('edit-redo');
  await expect.poll(() => b.guest(url, 'document.getElementById("draft").value')).toBe('Edited on a Mac');
  await b.guest(
    url,
    'const input = document.getElementById("draft"); input.focus(); input.setSelectionRange(input.value.length, input.value.length); undefined',
  );
  await b.app.evaluate(({ webContents }, url) => {
    const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
    contents.sendInputEvent({ type: 'keyDown', keyCode: 'Left', modifiers: ['alt'] });
    contents.sendInputEvent({ type: 'keyUp', keyCode: 'Left', modifiers: ['alt'] });
  }, url);
  await expect.poll(() => b.guest(url, 'document.getElementById("draft").selectionStart')).toBe(12);
  assert.equal((await b.state()).runtime.page.url, url, 'Option-Left edits words rather than browsing back');
  // Send real Chromium input to the native sibling, not to the shell's CDP page.
  await b.app.evaluate(({ webContents }, url) => {
    const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
    contents.sendInputEvent({ type: 'keyDown', keyCode: 'L', modifiers: ['meta'] });
    contents.sendInputEvent({ type: 'keyUp', keyCode: 'L', modifiers: ['meta'] });
  }, url);
  await expect(b.shell.locator('#command-input')).toBeFocused();
  await b.shell.keyboard.press('Escape');
  assert.equal(await b.guest(url, 'document.getElementById("draft").value'), 'Edited on a Mac');
});

test(
  'macOS keeps the app alive after closing a window and reopens safely from Dock or web links',
  macOnly,
  async (t) => {
    const b = await launch(t);
    const url = `${b.base}/session`;
    await b.navigate(url);
    const tab = (await b.state()).activeTabId;
    const firstId = await b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].id);
    await b.menu('close-window');
    await expect
      .poll(() => b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length))
      .toBe(0);
    assert.equal(b.app.process().exitCode, null, 'Closing the last window must not quit macOS');
    await b.reopen();
    const secondId = await b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].id);
    assert.notEqual(firstId, secondId);
    await expect.poll(async () => (await b.state()).activeTabId).toBe(tab);
    await expect.poll(() => b.guest(url, 'document.readyState')).toBe('complete');

    const openedURL = `${b.base}/from-other-app`;
    const before = (await b.state()).tabs.length;
    await b.app.evaluate(({ app }, url) => app.emit('open-url', { preventDefault() {} }, url), openedURL);
    await expect
      .poll(async () => (await b.state()).tabs.find((item) => item.url === openedURL)?.title)
      .toBe('Mac fixture /from-other-app');
    assert.equal((await b.state()).tabs.length, before + 1);
    await b.app.evaluate(({ app }) => {
      for (const url of ['file:///etc/passwd', 'javascript:alert(1)', 'https://user:password@example.com/'])
        app.emit('open-url', { preventDefault() {} }, url);
    });
    assert.equal((await b.state()).tabs.length, before + 1);
    await b.menu('close-window');
    await expect
      .poll(() => b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length))
      .toBe(0);
    const opened = b.app.waitForEvent('window');
    await b.app.evaluate(
      ({ app }, url) => app.emit('open-url', { preventDefault() {} }, url),
      `${b.base}/reopened-by-link`,
    );
    const shell = await opened;
    await expect(shell.locator('[data-key="space-picker"]')).toBeVisible();
    await expect
      .poll(() =>
        shell.evaluate(() => window.zacro.invoke('state:get')).then((state) => state.runtime.page.url),
      )
      .toBe(`${b.base}/reopened-by-link`);
  },
);

test('macOS cancelled Quit preserves unsaved work and clears pending quit intent', macOnly, async (t) => {
  const b = await launch(t);
  const url = `${b.base}/unsaved`;
  await b.navigate(url);
  await b.app.evaluate(({ dialog, webContents }, url) => {
    globalThis.macQuitPrompts = 0;
    dialog.showMessageBoxSync = () => {
      globalThis.macQuitPrompts++;
      return 0;
    };
    const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
    contents.sendInputEvent({ type: 'mouseDown', x: 30, y: 30, button: 'left', clickCount: 1 });
    contents.sendInputEvent({ type: 'mouseUp', x: 30, y: 30, button: 'left', clickCount: 1 });
  }, url);
  await b.guest(
    url,
    'window.onbeforeunload = event => { event.preventDefault(); event.returnValue = "Unsaved work"; }; document.getElementById("draft").value = "Keep this work"; undefined',
  );
  await b.app.evaluate(({ app }) => app.quit());
  await expect.poll(() => b.app.evaluate(() => globalThis.macQuitPrompts)).toBe(1);
  assert.equal(b.app.process().exitCode, null);
  assert.equal(await b.guest(url, 'document.getElementById("draft").value'), 'Keep this work');
  // Cancelling Quit must not make a subsequent ordinary close exit the app.
  await b.guest(url, 'window.onbeforeunload = null; undefined');
  await b.menu('close-window');
  await expect
    .poll(() => b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length))
    .toBe(0);
  assert.equal(b.app.process().exitCode, null);
  await b.reopen();
  await expect.poll(() => b.guest(url, 'document.readyState')).toBe('complete');
});

test('macOS queues web links delivered before the app is ready', macOnly, async (t) => {
  const b = await launch(t, { earlyLink: true });
  await expect.poll(async () => (await b.state()).runtime.page.url).toBe(`${b.base}/early-link`);
  await expect.poll(() => b.guest(`${b.base}/early-link`, 'document.readyState')).toBe('complete');
  assert.equal((await b.state()).tabs.filter((tab) => tab.url === `${b.base}/early-link`).length, 1);
});

test(
  'macOS closing the last window ends private sessions while retaining the regular profile',
  macOnly,
  async (t) => {
    const b = await launch(t);
    const regularURL = `${b.base}/regular-cookie`;
    await b.navigate(regularURL);
    const regularProfile = (await b.state()).profiles.find((profile) => !profile.private).id;
    await b.guest(regularURL, 'document.cookie = "session=regular; path=/"; undefined');
    const privateProfile = await b.invoke('profile:create', { name: 'Private close test', private: true });
    const privateURL = `${b.base}/private-cookie`;
    await b.navigate(privateURL);
    assert.equal(await b.guest(privateURL, 'document.cookie'), '');
    await b.guest(privateURL, 'document.cookie = "session=private; path=/"; undefined');
    assert.equal(await b.guest(privateURL, 'document.cookie'), 'session=private');
    await b.menu('close-window');
    await expect
      .poll(() => b.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length))
      .toBe(0);
    await b.reopen();
    const restored = await b.state();
    assert(restored.profiles.some((profile) => profile.id === regularProfile));
    assert(!restored.profiles.some((profile) => profile.private || profile.id === privateProfile.id));
    assert(!restored.tabs.some((tab) => tab.profileId === privateProfile.id));
    assert.deepEqual(
      await b.app.evaluate(
        async ({ session }, id) => session.fromPartition(`zacro-${id}`).cookies.get({}),
        privateProfile.id,
      ),
      [],
    );
    await b.navigate(regularURL);
    assert.equal(await b.guest(regularURL, 'document.cookie'), 'session=regular');
  },
);
