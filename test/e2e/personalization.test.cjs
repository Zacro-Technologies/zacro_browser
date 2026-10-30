'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-personalization-'));
  const server = http.createServer((_request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
    response.end(
      '<!doctype html><title>Design alpha</title><style>body{background:#b8d4ca;height:2000px}</style><h1>Design alpha</h1><textarea id="draft"></textarea>',
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/alpha`;
  let app, shell;
  const errors = [];
  const close = async () => {
    if (app) {
      const previous = app;
      app = null;
      const child = previous.process();
      await previous.close().catch(() => child.kill());
    }
  };
  t.after(async () => {
    await close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-personalization-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, []);
  });
  const launch = async () => {
    const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    shell = await app.firstWindow();
    shell.on('pageerror', (error) => errors.push(error.message));
    await expect(shell.locator('[data-key="address"]')).toBeVisible();
    if (await shell.locator('#command-input').count()) await shell.keyboard.press('Escape');
  };
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const emit = (event) =>
    app.evaluate(
      ({ BrowserWindow }, event) => BrowserWindow.getAllWindows()[0].webContents.send('zacro:event', event),
      event,
    );
  const guest = (expression) =>
    app.evaluate(
      ({ webContents }, { url, expression }) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          ?.executeJavaScript(expression),
      { url, expression },
    );
  const resize = async (width, height) => {
    await app.evaluate(
      ({ BrowserWindow }, { width, height }) => {
        BrowserWindow.getAllWindows()[0].setContentSize(width, height);
      },
      { width, height },
    );
    let accepted,
      previous,
      stable = 0;
    // Cocoa may clamp a requested size after the native setter returns. Read
    // current native and DOM dimensions until they agree across several polls.
    await expect
      .poll(
        async () => {
          const native = await app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()[0].getContentSize(),
          );
          const rendered = await shell.evaluate(() => [innerWidth, innerHeight]);
          const signature = native.join(':');
          const agrees = native.every((value, index) => value === rendered[index]);
          stable = agrees && signature === previous ? stable + 1 : agrees ? 1 : 0;
          previous = signature;
          accepted = native;
          return stable >= 3;
        },
        { intervals: [50, 100, 100] },
      )
      .toBe(true);
    return accepted;
  };
  await launch();
  return {
    get app() {
      return app;
    },
    get shell() {
      return shell;
    },
    close,
    launch,
    invoke,
    emit,
    guest,
    resize,
    url,
  };
}

test(
  'Space icons and material preview cancel cleanly, persist after save and honor appearance preferences',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.emit({ type: 'panel', panel: 'settings' });
    await b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    const original = (await b.invoke('state:get')).spaces[0];
    const swatches = await b.shell.locator('.space-theme-dialog .color-option').evaluateAll((nodes) =>
      nodes.map((node) => {
        const rect = node.getBoundingClientRect();
        return { width: rect.width, height: rect.height, radius: getComputedStyle(node).borderRadius };
      }),
    );
    assert(swatches.length > 8);
    assert(
      swatches.every(({ width, height, radius }) => Math.abs(width - height) < 0.1 && radius === '50%'),
      'Every color swatch stays circular',
    );
    await expect(b.shell.locator('input[name="theme-opacity"]')).toHaveAttribute('min', '0');
    await expect(b.shell.locator('input[name="theme-grain"]')).toHaveAttribute('max', '200');
    await expect(b.shell.locator('#window-material-hint')).toHaveCount(0);

    await b.shell.locator('summary').filter({ hasText: 'Name & icon' }).click();
    await b.shell.locator('#space-icon-search').fill('rocket');
    await expect(b.shell.locator('.space-icon-options button:visible')).toHaveCount(1);
    await b.shell.getByRole('button', { name: 'rocket icon', exact: true }).click();
    await b.shell.getByRole('button', { name: 'sky', exact: true }).click();
    await expect
      .poll(() => b.shell.evaluate(() => document.documentElement.style.getPropertyValue('--space-color')))
      .toBe('#6192bd');
    assert.equal((await b.invoke('state:get')).spaces[0].color, original.color, 'Preview must not persist');
    await b.shell.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect
      .poll(() => b.shell.evaluate(() => document.documentElement.style.getPropertyValue('--space-color')))
      .toBe(original.color);
    assert.deepEqual((await b.invoke('state:get')).spaces[0], original);
    await b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    await b.shell.locator('summary').filter({ hasText: 'Name & icon' }).click();
    await b.shell.locator('#space-icon-search').fill('rocket');
    await expect(b.shell.locator('.space-icon-options button:visible')).toHaveCount(1);
    await b.shell.getByRole('button', { name: 'rocket icon', exact: true }).click();
    await b.shell.locator('input[name="name"]').fill('Reading room');
    await b.shell.getByRole('button', { name: 'sky', exact: true }).click();
    await b.shell.locator('summary').filter({ hasText: 'Gradient & texture' }).focus();
    await b.shell.keyboard.press('Tab');
    await expect(b.shell.locator('input[name="theme-vibrancy"]')).toBeFocused();
    await b.shell.locator('input[name="theme-grain"]').evaluate((input) => {
      input.value = '40';
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await b.shell.locator('summary').filter({ hasText: 'Glass & transparency' }).click();
    for (const [name, value] of [['opacity', '60']])
      await b.shell.locator(`input[name="theme-${name}"]`).evaluate((input, value) => {
        input.value = value;
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }, value);
    await b.shell.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect.poll(async () => (await b.invoke('state:get')).spaces[0].name).toBe('Reading room');
    const saved = (await b.invoke('state:get')).spaces[0];
    assert.equal(saved.icon, 'rocket');
    assert.equal(saved.theme.grain, 40);
    assert.equal(saved.theme.opacity, 60);
    assert.equal(
      saved.theme.blur,
      original.theme.blur,
      'Changing other controls retains the chosen blur strength',
    );
    await expect
      .poll(async () => (await b.invoke('state:get')).runtime.windowMaterial.requestedOpacity)
      .toBe(60);
    const material = (await b.invoke('state:get')).runtime.windowMaterial;
    await expect(b.shell.locator('html')).toHaveAttribute('data-window-material', material.type);
    assert.equal(await b.shell.evaluate(() => getComputedStyle(document.body).opacity), '1');
    await expect(b.shell.locator('.space-dot.active svg')).toHaveCount(1);
    await b.close();
    await b.launch();
    const restored = (await b.invoke('state:get')).spaces[0];
    assert.deepEqual(restored.theme, saved.theme);
    assert.equal(restored.icon, 'rocket');
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    await b.emit({ type: 'panel', panel: 'settings' });
    await b.shell.locator('summary').filter({ hasText: 'Layout & motion' }).click();
    await b.shell.locator('#setting-tabDensity').selectOption('compact');
    await b.shell.locator('#setting-pinnedSleepMinutes').selectOption('10');
    await expect.poll(async () => (await b.invoke('state:get')).settings.pinnedSleepMinutes).toBe(10);
    await expect(b.shell.locator('html')).toHaveAttribute('data-tab-density', 'compact');
    await b.shell.screenshot({ path: path.resolve('test-results/personalization-settings.png') });
  },
);

test(
  'theme pucks, precise colors and tactile dials edit independently and cancel or save together',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    const original = (await b.invoke('state:get')).spaces[0];
    await b.emit({ type: 'panel', panel: 'settings' });
    const customize = () => b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    await customize();
    const primary = b.shell.locator('input[name="theme-color"]');
    const secondary = b.shell.locator('input[name="theme-secondaryColor"]');
    const secondaryBefore = await secondary.inputValue();
    const puck = await b.shell.locator('[data-theme-puck="color"]').boundingBox();
    await b.shell.mouse.move(puck.x + puck.width / 2, puck.y + puck.height / 2);
    await b.shell.mouse.down();
    await b.shell.mouse.move(puck.x + puck.width / 2 - 65, puck.y + puck.height / 2 - 30, { steps: 6 });
    await b.shell.mouse.up();
    const dragged = await primary.inputValue();
    assert.notEqual(dragged, original.color, 'Dragging the primary puck changes its actual color');
    assert.equal(await secondary.inputValue(), secondaryBefore, 'Dragging one color leaves the other intact');
    await expect
      .poll(() => b.shell.evaluate(() => document.documentElement.style.getPropertyValue('--space-color')))
      .toBe(dragged);
    await b.shell.locator('[data-theme-puck="color"]').focus();
    await b.shell.keyboard.press('ArrowRight');
    assert.notEqual(
      await primary.inputValue(),
      dragged,
      'Puck hue adjustment is available from the keyboard',
    );
    const primaryBeforePreset = await primary.inputValue();
    await b.shell.getByRole('button', { name: 'Secondary', exact: true }).click();
    await b.shell.getByRole('button', { name: 'sky', exact: true }).click();
    assert.equal(await secondary.inputValue(), '#6192bd');
    assert.equal(await primary.inputValue(), primaryBeforePreset, 'Presets apply only to the selected color');
    const grain = b.shell.locator('input[name="theme-grain"]');
    await grain.focus();
    await b.shell.keyboard.press('ArrowRight');
    await expect(grain).toHaveValue('1');
    const dial = await b.shell.locator('.theme-dial').first().boundingBox();
    await b.shell.mouse.click(dial.x + dial.width - 12, dial.y + dial.height / 2);
    await expect(b.shell.locator('input[name="theme-gradient"]')).toHaveValue('83');
    assert.deepEqual(
      (await b.invoke('state:get')).spaces[0],
      original,
      'Every control stays a preview until Save',
    );
    await b.shell.getByRole('button', { name: 'Cancel', exact: true }).click();
    assert.deepEqual((await b.invoke('state:get')).spaces[0], original);
    await customize();
    const hex = b.shell.getByRole('textbox', { name: 'Secondary hex color', exact: true });
    await hex.fill('24bc8e');
    await hex.press('Tab');
    await expect(hex).toHaveValue('#24BC8E');
    await expect(secondary).toHaveValue('#24bc8e');
    await b.shell.getByRole('textbox', { name: 'Primary hex color', exact: true }).fill('#7254e8');
    const directory = path.resolve('output/playwright');
    await fs.mkdir(directory, { recursive: true });
    await b.shell.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          .filter((animation) => animation.effect?.target?.closest('.space-theme-dialog'))
          .map((animation) => animation.finished.catch(() => {})),
      ),
    );
    await b.shell.screenshot({ path: path.join(directory, 'theme-editor.png') });
    await b.shell.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect.poll(async () => (await b.invoke('state:get')).spaces[0].color).toBe('#7254e8');
    assert.equal((await b.invoke('state:get')).spaces[0].theme.secondaryColor, '#24bc8e');
  },
);

test(
  'page insets and palette clipping match native content; sidebar motion reverses without losing the page',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.invoke('navigate', { url: b.url });
    await expect.poll(() => b.guest('document.readyState')).toBe('complete');
    await b.guest(
      'document.querySelector("textarea").value="Keep my draft"; window.identity=crypto.randomUUID(); undefined',
    );
    const identity = await b.guest('window.identity');
    await b.app.evaluate(({ BrowserWindow }, url) => {
      const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
        (child) => child.webContents?.getURL() === url,
      );
      const original = view.setBorderRadius.bind(view);
      globalThis.radiusCalls = [];
      view.setBorderRadius = (radius) => {
        globalThis.radiusCalls.push(radius);
        return original(radius);
      };
    }, b.url);
    await b.invoke('settings:update', { values: { pageGutter: 12, pageRadius: 16 } });
    await expect
      .poll(() =>
        b.shell.locator('#workspace').evaluate((element) => Math.round(element.getBoundingClientRect().left)),
      )
      .toBe(236);
    await expect.poll(() => b.app.evaluate(() => globalThis.radiusCalls.at(-1))).toBe(16);
    const native = () =>
      b.app.evaluate(
        ({ BrowserWindow }, url) =>
          BrowserWindow.getAllWindows()[0]
            .contentView.children.find((view) => view.webContents?.getURL() === url)
            ?.getBounds(),
        b.url,
      );
    const pageBounds = await native();
    const geometry = await b.shell.locator('#workspace').evaluate((element) => {
      const rect = element.getBoundingClientRect();
      return {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      };
    });
    assert.deepEqual(pageBounds, geometry);
    // Native geometry can settle before a newly resized Mac compositor has
    // produced its first page frame. Wait for actual guest rendering before
    // opening the overlay, then observe the real capture without replacing it.
    const painted = await b.guest(`new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('The resized page did not paint')), 3000);
      requestAnimationFrame(() => requestAnimationFrame(() => {
        clearTimeout(timer);
        resolve({ visibility: document.visibilityState, width: innerWidth, height: innerHeight });
      }));
    })`);
    assert.equal(painted.visibility, 'visible');
    assert.equal(painted.width, pageBounds.width);
    assert.equal(painted.height, pageBounds.height);
    await b.app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      const capture = contents.capturePage.bind(contents);
      globalThis.personalizationCaptures = [];
      contents.capturePage = (...args) => {
        const record = { visibility: contents.mainFrame.visibilityState, startedAt: Date.now() };
        globalThis.personalizationCaptures.push(record);
        return capture(...args).then(
          (image) => {
            record.elapsed = Date.now() - record.startedAt;
            record.empty = image.isEmpty();
            record.scaleFactor = Math.max(...image.getScaleFactors());
            const png = image.toPNG({ scaleFactor: record.scaleFactor });
            record.size = { width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
            return image;
          },
          (error) => {
            record.error = error.message;
            throw error;
          },
        );
      };
    }, b.url);
    await b.invoke('bookmark:toggle');
    await b.emit({ type: 'command', mode: 'newtab', query: 'alpha' });
    try {
      await expect(b.shell.locator('.page-backdrop-frame')).toHaveCount(1);
    } catch (error) {
      t.diagnostic(
        JSON.stringify(
          await b.app.evaluate(({ BrowserWindow }) => ({
            captures: globalThis.personalizationCaptures,
            windowVisible: BrowserWindow.getAllWindows()[0].isVisible(),
            windowFocused: BrowserWindow.getAllWindows()[0].isFocused(),
          })),
        ),
      );
      throw error;
    }
    const captured = await b.app.evaluate(() => globalThis.personalizationCaptures);
    assert.equal(captured.length, 1);
    assert.equal(captured[0].empty, false, 'The backdrop must come from a real nonempty page capture');
    await b.shell.locator('.page-backdrop-frame img').evaluate((image) => image.decode());
    const backdrop = await b.shell.evaluate(() => {
      const clip = document.querySelector('.page-backdrop-frame');
      const rect = clip.getBoundingClientRect();
      return {
        clip: getComputedStyle(clip).borderRadius,
        radius: getComputedStyle(document.querySelector('#workspace')).borderRadius,
        filter: getComputedStyle(document.querySelector('.command-backdrop')).backdropFilter,
        background: getComputedStyle(document.querySelector('.command-backdrop')).backgroundColor,
        imageFilter: getComputedStyle(clip.firstElementChild).filter,
        imageSource: clip.firstElementChild.src.slice(0, 30),
        pixels: { width: clip.firstElementChild.naturalWidth, height: clip.firstElementChild.naturalHeight },
        overlay: getComputedStyle(clip, '::after').content,
        shadow: getComputedStyle(document.querySelector('.command-dialog')).boxShadow,
        bounds: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        },
      };
    });
    assert.equal(backdrop.clip, '16px');
    assert.equal(backdrop.radius, '16px');
    assert.equal(backdrop.filter, 'none');
    assert.equal(backdrop.background, 'rgba(0, 0, 0, 0)');
    assert.equal(backdrop.imageFilter, 'none', 'The palette leaves page pixels sharp');
    assert.match(backdrop.imageSource, /^data:image\/png;base64,iVBORw0K/);
    assert.deepEqual(backdrop.pixels, captured[0].size, 'The decoded backdrop retains every native pixel');
    assert.equal(backdrop.overlay, 'none', 'The palette does not tint the page');
    assert.notEqual(backdrop.shadow, 'none', 'A shadow separates the palette from the unchanged page');
    assert.deepEqual(backdrop.bounds, pageBounds);
    const media = await b.shell.context().newCDPSession(b.shell);
    try {
      await media.send('Emulation.setEmulatedMedia', {
        features: [{ name: 'prefers-reduced-transparency', value: 'reduce' }],
      });
      const reduced = await b.shell.evaluate(() => ({
        clickSurface: getComputedStyle(document.querySelector('.command-backdrop')).backgroundColor,
        pageSnapshot: getComputedStyle(document.querySelector('#page-backdrop')).visibility,
      }));
      assert.deepEqual(reduced, { clickSurface: 'rgba(0, 0, 0, 0)', pageSnapshot: 'visible' });
    } finally {
      await media.detach();
    }
    await b.shell.getByRole('button', { name: 'Bookmarks', exact: true }).click();
    await expect(b.shell.locator('.command-result')).toHaveCount(1);
    await expect(b.shell.locator('.command-result')).toHaveAttribute('data-command-kind', 'bookmark');
    await b.shell.getByRole('button', { name: 'Actions', exact: true }).click();
    await b.shell.locator('#command-input').fill('summarize');
    await expect(b.shell.locator('[data-command-id="action:ai-summarize"]')).toBeVisible();
    await b.shell.keyboard.press('Escape');
    await b.emit({ type: 'panel', panel: 'settings' });
    await expect(b.shell.locator('#side-panel')).toBeVisible();
    await expect(b.shell.locator('#app')).toHaveAttribute('data-panel-animating', 'false');
    const closeButton = b.shell.locator('[data-key="panel-close"]');
    await expect(closeButton).toBeVisible();
    let closePanel;
    // Settings' asynchronous status refresh can replace its header between
    // locator resolution and the native box query. Require a real click target.
    await expect
      .poll(async () => {
        closePanel = await closeButton.boundingBox();
        return Boolean(closePanel && closePanel.width > 0 && closePanel.height > 0);
      })
      .toBe(true);
    await b.emit({ type: 'command', mode: 'newtab', query: 'alpha' });
    await expect(b.shell.locator('#command-input')).toBeFocused();
    const commandAlignment = await b.shell.evaluate(() => {
      const page = document.querySelector('#workspace').getBoundingClientRect();
      const dialog = document.querySelector('.command-dialog').getBoundingClientRect();
      return {
        pageCenter: page.x + page.width / 2,
        dialogCenter: dialog.x + dialog.width / 2,
        panelInert: document.querySelector('#side-panel').inert,
        panelFilter: getComputedStyle(document.querySelector('#side-panel')).filter,
      };
    });
    assert(
      Math.abs(commandAlignment.pageCenter - commandAlignment.dialogCenter) <= 1,
      'The command dialog stays centered in the page canvas',
    );
    assert.equal(commandAlignment.panelInert, true);
    assert.equal(commandAlignment.panelFilter, 'none', 'The palette leaves Library unchanged');
    await b.shell.mouse.click(closePanel.x + closePanel.width / 2, closePanel.y + closePanel.height / 2);
    await expect(b.shell.locator('.command-dialog')).toHaveCount(0);
    await expect(b.shell.locator('#side-panel')).toBeVisible();
    assert.equal(await b.shell.locator('#side-panel').evaluate((panel) => panel.inert), false);
    await b.shell.locator('[data-key="panel-close"]').click();
    await expect(b.shell.locator('#side-panel')).toBeHidden();
    await b.shell.evaluate(() => {
      // A queued frame can report a timestamp older than the input that started
      // the motion. Exercise that edge deterministically without relaxing the
      // bounds or monotonicity checks on the actual sidebar and native page.
      window.sidebarFrameClock = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = (callback) => window.sidebarFrameClock((time) => callback(time - 48));
      window.sidebarSamples = [];
      const start = performance.now();
      const sample = () => {
        window.sidebarSamples.push(document.querySelector('#sidebar').getBoundingClientRect().width);
        if (performance.now() - start < 700) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });
    await b.emit({ type: 'sidebar:toggle', fromPage: true });
    await expect(b.shell.locator('#sidebar')).toBeHidden();
    const samples = await b.shell.evaluate(() => {
      window.requestAnimationFrame = window.sidebarFrameClock;
      delete window.sidebarFrameClock;
      return window.sidebarSamples;
    });
    assert(
      samples.some((width) => width > 0 && width < 220),
      'Closing must have real intermediate geometry',
    );
    assert(
      samples.every((width) => width >= 0 && width <= 224),
      `Sidebar motion never overshoots: ${JSON.stringify(samples)}`,
    );
    assert(
      samples.every((width, index) => !index || width <= samples[index - 1]),
      'Closing motion is monotonic without spring recoil',
    );
    assert.equal((await native()).x, 12);
    await b.app.evaluate(async ({ BrowserWindow }) => {
      const contents = BrowserWindow.getAllWindows()[0].webContents;
      contents.send('zacro:event', { type: 'sidebar:toggle' });
      await new Promise((resolve) => setTimeout(resolve, 45));
      contents.send('zacro:event', { type: 'sidebar:toggle' });
      await new Promise((resolve) => setTimeout(resolve, 45));
      contents.send('zacro:event', { type: 'sidebar:toggle' });
    });
    await expect(b.shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    await expect.poll(async () => (await native())?.x).toBe(236);
    assert.equal(await b.guest('window.identity'), identity);
    assert.equal(await b.guest('document.querySelector("textarea").value'), 'Keep my draft');
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    await b.emit({ type: 'sidebar:toggle' });
    await expect(b.shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    await expect(b.shell.locator('#sidebar')).toBeHidden();
  },
);

test(
  'custom layout values remain selected, expanded theme controls fit and forced colors override Space tones',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    // These values are valid in imported state even though they are not presets.
    await b.invoke('settings:update', { values: { pageGutter: 7, pageRadius: 10, motionScale: 1.1 } });
    await b.emit({ type: 'panel', panel: 'settings' });
    await b.shell.locator('summary').filter({ hasText: 'Layout & motion' }).click();
    for (const [key, value, label] of [
      ['pageGutter', '7', '7px'],
      ['pageRadius', '10', '10px'],
      ['motionScale', '1.1', 'Custom · 1.1×'],
    ]) {
      await expect(b.shell.locator(`#setting-${key}`)).toHaveValue(value);
      await expect(b.shell.locator(`#setting-${key} option:checked`)).toHaveText(label);
    }
    await b.shell.locator('#setting-tabDensity').selectOption('compact');
    await expect(b.shell.locator('#setting-motionScale')).toHaveValue('1.1');
    await b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    await b.shell.locator('summary').filter({ hasText: 'Glass & transparency' }).click();
    for (const [width, height] of [
      [560, 420],
      [960, 640],
      [960, 780],
      [960, 795],
    ]) {
      const accepted = await b.resize(width, height);
      // macOS constrains a window to the runner's available display height;
      // Windows may round a DIP by one pixel at fractional desktop scaling.
      // Verify the size the OS accepted, without claiming the request was met.
      assert.ok(accepted[0] > 0 && accepted[1] > 0);
      if (Math.abs(accepted[1] - height) > 1)
        t.diagnostic(`Requested ${height}px content height; the OS accepted ${accepted[1]}px.`);
      await expect
        .poll(async () => Math.abs((await b.shell.evaluate(() => innerHeight)) - accepted[1]))
        .toBeLessThanOrEqual(1);
      const bounds = await b.shell.locator('.space-theme-dialog').evaluate((dialog) => {
        dialog.scrollTop = 0;
        const rect = dialog.getBoundingClientRect();
        return {
          top: rect.top,
          bottom: rect.bottom,
          height: innerHeight,
          actions: [...dialog.querySelectorAll('.dialog-footer button')].map((button) => {
            const action = button.getBoundingClientRect();
            return { label: button.textContent, top: action.top, bottom: action.bottom };
          }),
        };
      });
      assert(
        bounds.top >= 0 && bounds.bottom <= bounds.height - 23,
        `Theme dialog must preserve its bottom margin at the accepted ${bounds.height}px height`,
      );
      for (const action of bounds.actions)
        assert(
          action.top >= bounds.top && action.bottom <= bounds.bottom,
          `${action.label} must remain fully visible at the accepted ${bounds.height}px height`,
        );
    }
    await b.shell.getByRole('button', { name: 'Cancel', exact: true }).click();
    await b.shell.emulateMedia({ forcedColors: 'active' });
    const systemTokens = await b.shell.evaluate(() => {
      const style = getComputedStyle(document.documentElement);
      return Object.fromEntries(
        ['--chrome', '--hover', '--space-tint-primary', '--space-tint-secondary', '--accent'].map((token) => [
          token,
          style.getPropertyValue(token).trim().toLowerCase(),
        ]),
      );
    });
    assert.deepEqual(systemTokens, {
      '--chrome': 'canvas',
      '--hover': 'buttonface',
      '--space-tint-primary': 'canvas',
      '--space-tint-secondary': 'canvas',
      '--accent': 'highlight',
    });
  },
);

test(
  'external Space and profile switches discard an unfinished theme preview without changing saved themes',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.emit({ type: 'panel', panel: 'settings' });
    for (const [action, name] of [
      ['space:create', 'Independent Space'],
      ['profile:create', 'Independent profile'],
    ]) {
      const before = await b.invoke('state:get');
      await b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
      await b.shell.getByRole('button', { name: 'sky', exact: true }).click();
      await b.shell.locator('summary').filter({ hasText: 'Name & icon' }).click();
      await b.shell.getByRole('button', { name: 'book icon', exact: true }).click();
      await expect
        .poll(() => b.shell.evaluate(() => document.documentElement.style.getPropertyValue('--space-color')))
        .toBe('#6192bd');
      await b.invoke(action, { name, color: '#a56545' });
      await expect(b.shell.locator('.space-theme-dialog')).toHaveCount(0);
      const after = await b.invoke('state:get');
      const active = after.spaces.find((space) => space.id === after.activeSpaceId);
      await expect
        .poll(() => b.shell.evaluate(() => document.documentElement.style.getPropertyValue('--space-color')))
        .toBe(active.color);
      assert.notEqual(after.activeSpaceId, before.activeSpaceId);
      assert.deepEqual(
        after.spaces.filter((space) => before.spaces.some((prior) => prior.id === space.id)),
        before.spaces,
        'A dismissed preview must not modify any previous Space',
      );
    }
  },
);

test(
  'Favorite tiles balance complete rows as the count and sidebar width change',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    await b.shell.emulateMedia({ reducedMotion: 'reduce' });
    const rowsByCount = new Map();
    for (let count = 1; count <= 12; count++) {
      const tab = await b.invoke('tab:create', { url: `${b.url}?favorite=${count}`, active: false });
      await b.invoke('tab:favorite', { id: tab.id });
      await expect(b.shell.locator('.space-page .favorite')).toHaveCount(count);
      const geometry = await b.shell.locator('.space-page .favorites').evaluate((grid) => {
        const bounds = grid.getBoundingClientRect();
        return {
          left: bounds.left,
          right: bounds.right,
          tiles: [...grid.querySelectorAll('.favorite')].map((tile) => {
            const rect = tile.getBoundingClientRect();
            return { left: rect.left, right: rect.right, top: rect.top, width: rect.width };
          }),
        };
      });
      const rows = Object.values(Object.groupBy(geometry.tiles, (tile) => Math.round(tile.top)));
      assert.equal(rows.length, Math.ceil(count / 4));
      assert(Math.max(...rows.map((row) => row.length)) - Math.min(...rows.map((row) => row.length)) <= 1);
      for (const row of rows) {
        assert(Math.abs(row[0].left - geometry.left) < 1);
        assert(
          Math.abs(row.at(-1).right - geometry.right) < 1,
          `Each row fills the available width: ${JSON.stringify({ count, geometry })}`,
        );
        assert(
          row.every((tile) => tile.width >= 36),
          'Favorite tiles keep usable pointer targets',
        );
      }
      rowsByCount.set(count, geometry.tiles[0].width);
    }
    assert(rowsByCount.get(1) > rowsByCount.get(2));
    assert(rowsByCount.get(2) > rowsByCount.get(3));
    assert(rowsByCount.get(3) > rowsByCount.get(4));
    assert(rowsByCount.get(5) > rowsByCount.get(4));
    await b.invoke('settings:update', { values: { sidebarWidth: 380 } });
    await expect(b.shell.locator('#sidebar-resizer')).toHaveAttribute('aria-valuenow', '380');
    await expect
      .poll(async () => {
        const expanded = await b.shell.locator('.space-page .favorite').first().boundingBox();
        return expanded?.width ?? 0;
      })
      .toBeGreaterThan(rowsByCount.get(12));
    const other = await b.invoke('space:create', { name: 'Other Space' });
    await expect(b.shell.locator('.space-page .favorite')).toHaveCount(12);
    assert.equal((await b.invoke('state:get')).activeSpaceId, other.id);
    await b.invoke('profile:create', { name: 'Separate profile' });
    await expect(b.shell.locator('.space-page .favorite')).toHaveCount(0);
  },
);

test(
  'Today archive controls use the 12-hour default, inherit per profile and persist overrides',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    assert.equal((await b.invoke('state:get')).settings.archiveAfterHours, 12);
    await b.emit({ type: 'panel', panel: 'settings' });
    await expect(b.shell.locator('[data-profile-archive="default"]')).toHaveValue('12');
    await b.shell.locator('[data-profile-archive="default"]').selectOption('24');
    await expect.poll(async () => (await b.invoke('state:get')).settings.archiveAfterHours).toBe(24);
    const profile = await b.invoke('profile:create', { name: 'Research' });
    const control = b.shell.locator(`[data-profile-archive="${profile.id}"]`);
    await expect(control).toHaveValue('inherit');
    await control.selectOption('72');
    await expect
      .poll(
        async () =>
          (await b.invoke('state:get')).profiles.find((item) => item.id === profile.id).archiveAfterHours,
      )
      .toBe(72);
    await b.close();
    await b.launch();
    await b.emit({ type: 'panel', panel: 'settings' });
    await expect(b.shell.locator(`[data-profile-archive="${profile.id}"]`)).toHaveValue('72');
    await b.shell.getByRole('button', { name: 'Profiles', exact: true }).click();
    await b.shell.locator(`.dialog [data-profile-archive="${profile.id}"]`).selectOption('inherit');
    await expect
      .poll(
        async () =>
          (await b.invoke('state:get')).profiles.find((item) => item.id === profile.id).archiveAfterHours,
      )
      .toBe(null);
  },
);

test(
  'resizing a palette clears pending and settled backdrops and its next opening captures the resized page',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.invoke('navigate', { url: b.url });
    await expect.poll(() => b.guest('document.readyState')).toBe('complete');
    await b.guest(
      'window.resizeDraft="Keep the page";document.querySelector("textarea").value="Unsaved draft";undefined',
    );
    await b.guest('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    await b.shell.evaluate(() => {
      window.__resizeBackdropEvents = [];
      window.zacro.onEvent((event) => {
        if (event.type === 'page:backdrop') window.__resizeBackdropEvents.push(event.frames);
      });
    });
    const before = await b.app.evaluate(({ BrowserWindow }, url) => {
      const view = BrowserWindow.getAllWindows()[0].contentView.children.find(
        (item) => item.webContents?.getURL() === url,
      );
      const contents = view.webContents;
      const originalCapture = contents.capturePage.bind(contents);
      const originalVisible = view.setVisible.bind(view);
      const originalRadius = view.setBorderRadius.bind(view);
      globalThis.__resizeBackdropView = view;
      globalThis.__resizeBackdropCaptures = [];
      globalThis.__resizeBackdropVisibility = [];
      globalThis.__resizeBackdropRadii = [];
      view.setVisible = (visible) => {
        globalThis.__resizeBackdropVisibility.push(visible);
        originalVisible(visible);
      };
      view.setBorderRadius = (radius) => {
        globalThis.__resizeBackdropRadii.push(radius);
        originalRadius(radius);
      };
      contents.capturePage = (...args) => {
        const record = { id: contents.id, bounds: view.getBounds(), visible: view.getVisible() };
        globalThis.__resizeBackdropCaptures.push(record);
        const result = originalCapture(...args).then((image) => {
          const bytes = image.toPNG({ scaleFactor: Math.max(...image.getScaleFactors()) });
          record.pixels = { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
          return image;
        });
        if (globalThis.__resizeBackdropCaptures.length === 1)
          return new Promise((resolve) => {
            globalThis.__releaseResizeBackdrop = async () => resolve(await result);
          });
        return result;
      };
      return { id: contents.id, zoom: contents.getZoomFactor(), bounds: view.getBounds() };
    }, b.url);
    await b.emit({ type: 'command', mode: 'newtab', query: 'Keep this unfinished search' });
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await expect
      .poll(() => b.app.evaluate(() => Boolean(globalThis.__resizeBackdropCaptures[0]?.pixels)))
      .toBe(true);
    await b.resize(980, 720);
    await b.invoke('settings:update', { values: { pageRadius: 16 } });
    await expect(b.shell.locator('#page-backdrop img')).toHaveCount(0);
    await b.app.evaluate(async () => {
      await globalThis.__releaseResizeBackdrop();
    });
    await b.invoke('state:get');
    const published = await b.shell.evaluate(() =>
      window.__resizeBackdropEvents.flat().map((frame) => frame.bounds),
    );
    assert.deepEqual(published, [], 'The pre-resize copy never publishes at its former bounds');
    assert.equal(await b.app.evaluate(() => globalThis.__resizeBackdropCaptures.length), 1);
    assert(
      (await b.app.evaluate(() => globalThis.__resizeBackdropVisibility)).every(
        (visible) => visible === false,
      ),
    );
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await expect(b.shell.locator('#command-input')).toHaveValue('Keep this unfinished search');

    // Native hidden views can defer resizing. Dismissal resumes the unchanged
    // document; the next ordinary opening takes its actual newly painted frame.
    await b.shell.keyboard.press('Escape');
    await expect(b.shell.locator('#command-input')).toHaveCount(0);
    let resized;
    await expect
      .poll(async () => {
        const rectangle = await b.shell.locator('#workspace').boundingBox();
        const native = await b.app.evaluate(() => ({
          visible: globalThis.__resizeBackdropView.getVisible(),
          bounds: globalThis.__resizeBackdropView.getBounds(),
        }));
        resized = native.bounds;
        return (
          native.visible &&
          Boolean(rectangle) &&
          ['x', 'y', 'width', 'height'].every((key) => Math.round(rectangle[key]) === native.bounds[key])
        );
      })
      .toBe(true);
    assert.notDeepEqual(resized, before.bounds);
    await expect
      .poll(() => b.guest('({width:innerWidth,height:innerHeight})'))
      .toEqual({ width: resized.width, height: resized.height });
    await b.guest('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    await b.app.evaluate(() => {
      globalThis.__resizeBackdropVisibility = [];
    });
    await b.emit({ type: 'command', mode: 'newtab', query: 'Keep this unfinished search' });
    await expect(b.shell.locator('#page-backdrop img')).toHaveCount(1);
    await b.shell.locator('#page-backdrop img').evaluate((image) => image.decode());
    await expect.poll(() => b.app.evaluate(() => globalThis.__resizeBackdropView.getVisible())).toBe(false);
    const after = await b.app.evaluate(({ BrowserWindow, webContents, screen }) => ({
      id: globalThis.__resizeBackdropView.webContents.id,
      zoom: globalThis.__resizeBackdropView.webContents.getZoomFactor(),
      bounds: globalThis.__resizeBackdropView.getBounds(),
      capture: globalThis.__resizeBackdropCaptures.at(-1),
      visible: globalThis.__resizeBackdropView.getVisible(),
      visibleCalls: globalThis.__resizeBackdropVisibility,
      radii: globalThis.__resizeBackdropRadii,
      firstPixels: globalThis.__resizeBackdropCaptures[0].pixels,
      displayScale: screen.getDisplayMatching(BrowserWindow.getAllWindows()[0].getBounds()).scaleFactor,
      shellFocused:
        webContents.getFocusedWebContents()?.id === BrowserWindow.getAllWindows()[0].webContents.id,
    }));
    const rendered = await b.shell.locator('.page-backdrop-frame').evaluate((clip) => {
      const rect = clip.getBoundingClientRect();
      const image = clip.querySelector('img');
      return {
        bounds: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        },
        pixels: { width: image.naturalWidth, height: image.naturalHeight },
        radius: getComputedStyle(clip).borderRadius,
      };
    });
    assert.deepEqual(rendered.bounds, after.bounds);
    assert.deepEqual(rendered.pixels, after.capture.pixels);
    assert.notDeepEqual(rendered.pixels, after.firstPixels);
    assert.deepEqual(rendered.pixels, {
      width: Math.ceil(after.bounds.width * after.displayScale),
      height: Math.ceil(after.bounds.height * after.displayScale),
    });
    assert.equal(rendered.radius, '16px');
    assert(after.radii.includes(16));
    assert(
      after.visibleCalls.every((visible) => visible === false),
      'No live surface flashes over the palette',
    );
    assert.equal(after.visible, false);
    assert.equal(after.id, before.id);
    assert.equal(after.zoom, before.zoom);
    assert.equal(after.shellFocused, true);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await expect(b.shell.locator('#command-input')).toHaveValue('Keep this unfinished search');

    // A settled snapshot is also removed immediately when its geometry changes.
    await b.shell.evaluate(() => {
      window.__resizeBackdropEvents = [];
    });
    await b.resize(1120, 780);
    await expect(b.shell.locator('#page-backdrop img')).toHaveCount(0);
    await expect.poll(() => b.shell.evaluate(() => window.__resizeBackdropEvents.at(-1)?.length)).toBe(0);
    await expect(b.shell.locator('#command-input')).toBeFocused();
    await expect(b.shell.locator('#command-input')).toHaveValue('Keep this unfinished search');
    await b.shell.keyboard.press('Escape');
    assert.deepEqual(await b.guest('[window.resizeDraft,document.querySelector("textarea").value]'), [
      'Keep the page',
      'Unsaved draft',
    ]);
  },
);

test(
  '4K HiDPI backdrop representations retain backing pixels and oversized captures are omitted',
  { timeout: 45000 },
  async (t) => {
    const browser = await fixture(t);
    const url = browser.url;
    await browser.invoke('navigate', { url });
    await expect.poll(() => browser.guest('document.readyState')).toBe('complete');
    await browser.guest('window.backdropDraft="Keep this document"');
    await browser.shell.evaluate(() => {
      window.__qualityFrames = [];
      window.zacro.onEvent((event) => {
        if (event.type === 'page:backdrop') window.__qualityFrames.push(event.frames);
      });
    });
    const expected = await browser.app.evaluate(({ nativeImage, webContents }, url) => {
      // A genuine NativeImage with only a 2x representation reproduces Retina
      // encoding semantics independently of the display attached to the runner.
      const bitmap = Buffer.alloc(3840 * 2160 * 4, 255);
      bitmap.fill(0, 0, 3840 * 4);
      const image = nativeImage.createFromBitmap(bitmap, { width: 3840, height: 2160, scaleFactor: 2 });
      const bytes = image.toPNG({ scaleFactor: 2 });
      globalThis.__qualityMode = 'full';
      globalThis.__qualityEncodes = 0;
      let roundingBoundary;
      const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
      contents.capturePage = async () => {
        if (globalThis.__qualityMode === 'rounding' && !roundingBoundary)
          roundingBoundary = nativeImage.createFromBitmap(Buffer.alloc(4097 * 4096 * 4, 255), {
            width: 4097,
            height: 4096,
            scaleFactor: 2,
          });
        const frame = globalThis.__qualityMode === 'rounding' ? roundingBoundary : image;
        return {
          isEmpty: () => frame.isEmpty(),
          getScaleFactors: () => frame.getScaleFactors(),
          getSize: (scale) =>
            globalThis.__qualityMode === 'pixels' ? { width: 2048, height: 2049 } : frame.getSize(scale),
          toPNG: (options) => {
            globalThis.__qualityEncodes++;
            return globalThis.__qualityMode === 'bytes'
              ? Buffer.alloc(20 * 1024 * 1024 + 1)
              : frame.toPNG(options);
          },
        };
      };
      return {
        scales: image.getScaleFactors(),
        size: image.getSize(2),
        pngSize: { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) },
        png: bytes.toString('base64'),
      };
    }, url);
    assert.deepEqual(expected.scales, [2]);
    assert.deepEqual(expected.size, { width: 1920, height: 1080 });
    assert.deepEqual(
      expected.pngSize,
      { width: 3840, height: 2160 },
      'PNG retains the actual backing pixels of a 2x representation',
    );
    await browser.shell.locator('[data-key="address"]').click();
    await expect(browser.shell.locator('#page-backdrop img')).toHaveCount(1);
    await browser.shell.locator('#page-backdrop img').evaluate((image) => image.decode());
    const rendered = await browser.shell.locator('#page-backdrop img').evaluate((image) => ({
      width: image.naturalWidth,
      height: image.naturalHeight,
      src: image.src,
    }));
    assert.deepEqual({ width: rendered.width, height: rendered.height }, expected.pngSize);
    const bytes = Buffer.from(rendered.src.slice('data:image/png;base64,'.length), 'base64');
    assert.equal(
      createHash('sha256').update(bytes).digest('hex'),
      createHash('sha256').update(Buffer.from(expected.png, 'base64')).digest('hex'),
    );
    await browser.shell.keyboard.press('Escape');
    await expect(browser.shell.locator('#command-input')).toHaveCount(0);

    // The odd-pixel 2x image rounds down to 2048×2048 logical pixels. Only
    // checking the encoded IHDR catches its one-column-over-16M bitmap.
    for (const mode of ['pixels', 'rounding', 'bytes']) {
      await browser.app.evaluate((_electron, mode) => {
        globalThis.__qualityMode = mode;
        globalThis.__qualityEncodes = 0;
      }, mode);
      await browser.shell.evaluate(() => {
        window.__qualityFrames = [];
      });
      await browser.shell.locator('[data-key="address"]').click();
      await expect(browser.shell.locator('#command-input')).toBeFocused();
      await expect.poll(() => browser.shell.evaluate(() => window.__qualityFrames.at(-1)?.length)).toBe(0);
      assert.equal(await browser.app.evaluate(() => globalThis.__qualityEncodes), mode === 'pixels' ? 0 : 1);
      await expect(browser.shell.locator('#page-backdrop img')).toHaveCount(0);
      await browser.shell.locator('#command-input').fill('The palette stays interactive');
      await browser.shell.keyboard.press('Escape');
      await expect(browser.shell.locator('#command-input')).toHaveCount(0);
      assert.equal(await browser.guest('window.backdropDraft'), 'Keep this document');
    }
  },
);

test(
  'vivid opaque grain stays visible and saving transparency preserves the preview',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    await b.invoke('folder:create', { name: 'Color review' });
    await b.emit({ type: 'panel', panel: 'settings' });
    await b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    const set = (name, value) =>
      b.shell.locator(`[name="theme-${name}"]`).evaluate((input, value) => {
        input.value = value;
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }, String(value));
    await set('color', '#ee3388');
    await set('secondaryColor', '#5733ff');
    await set('vibrancy', 100);
    await set('grain', 200);
    await set('opacity', 100);
    const readPreview = () =>
      b.shell.evaluate(() => {
        const app = document.querySelector('.app');
        const tile = document.querySelector('.theme-preview-tile');
        const properties = (element, pseudo) => {
          const style = getComputedStyle(element, pseudo);
          return { image: style.backgroundImage, opacity: style.opacity };
        };
        return {
          window: properties(app, '::after'),
          preview: properties(tile, '::before'),
          windowGrain: properties(app, '::before'),
          previewGrain: properties(tile, '::after'),
          canvas: getComputedStyle(tile).backgroundColor,
          blank: properties(document.querySelector('.workspace[data-empty="true"]')),
          workspace: getComputedStyle(document.querySelector('.workspace')).backgroundColor,
          backdrop: getComputedStyle(document.querySelector('.dialog-backdrop')).backgroundColor,
          backdropFilter: getComputedStyle(document.querySelector('.dialog-backdrop')).backdropFilter,
        };
      });
    const opaquePreview = await readPreview();
    assert.deepEqual(
      opaquePreview.preview,
      opaquePreview.window,
      'Preview and live window use the same fitted gradient and opacity',
    );
    assert.deepEqual(opaquePreview.previewGrain, opaquePreview.windowGrain);
    assert.notEqual(opaquePreview.canvas, 'rgba(0, 0, 0, 0)');
    assert.equal(
      opaquePreview.backdrop,
      'rgba(0, 0, 0, 0)',
      'Customization leaves the live theme visible without dimming it',
    );
    assert.equal(opaquePreview.backdropFilter, 'none');
    assert.equal(
      opaquePreview.blank.image,
      opaquePreview.window.image,
      'The opaque empty pane uses the same Space gradient',
    );
    assert.equal(opaquePreview.blank.opacity, '1');
    const directory = path.resolve(__dirname, '../../test-results/theme-review');
    await fs.mkdir(directory, { recursive: true });
    await b.shell.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect(b.shell.locator('.space-theme-dialog')).toHaveCount(0);
    await b.emit({ type: 'panel', panel: 'settings' });
    const read = () =>
      b.shell.evaluate(() => ({
        grain: getComputedStyle(document.querySelector('.app'), '::before').opacity,
        opacity: getComputedStyle(document.querySelector('.app'), '::after').opacity,
        material: document.documentElement.dataset.windowMaterial,
      }));
    await expect.poll(async () => (await read()).grain).toBe('0.18');
    assert.equal((await read()).opacity, '1');
    for (const theme of ['light', 'dark']) {
      await b.invoke('settings:update', { values: { theme } });
      await expect(b.shell.locator('html')).toHaveAttribute('data-theme', theme);
      const foreground = await b.shell.evaluate(() => ({
        picker: getComputedStyle(document.querySelector('.space-picker')).color,
        title: getComputedStyle(document.querySelector('#panel-title')).color,
      }));
      const accents = await b.shell.evaluate(() =>
        ['.folder-icon', '.space-picker > svg:first-child'].map(
          (selector) => getComputedStyle(document.querySelector(selector)).color,
        ),
      );
      assert.equal(new Set(accents).size, 1, 'Folder outlines and Space icons share the chosen Space accent');
      assert.deepEqual(
        foreground,
        theme === 'dark'
          ? { picker: 'rgb(245, 240, 250)', title: 'rgb(255, 255, 255)' }
          : { picker: 'rgb(33, 28, 35)', title: 'rgb(21, 18, 25)' },
      );
      await b.shell.screenshot({ path: path.join(directory, `${theme}-vivid-grain.png`) });
    }
    await b.shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
    await set('opacity', 35);
    await expect
      .poll(async () => (await b.invoke('state:get')).runtime.windowMaterial.requestedOpacity)
      .toBe(35);
    const translucentPreview = await readPreview();
    assert.deepEqual(translucentPreview.preview, translucentPreview.window);
    assert.deepEqual(translucentPreview.previewGrain, translucentPreview.windowGrain);
    const before = await read();
    await b.shell.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect(b.shell.locator('.space-theme-dialog')).toHaveCount(0);
    await expect.poll(read).toEqual(before);
    const saved = await b.invoke('state:get');
    assert.equal(saved.spaces.find((s) => s.id === saved.activeSpaceId).theme.vibrancy, 100);
    assert.equal(saved.runtime.windowMaterial.requestedOpacity, 35);
  },
);
