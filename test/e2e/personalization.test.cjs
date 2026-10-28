'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
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
    await b.shell.locator('#space-icon-search').fill('rocket');
    await expect(b.shell.locator('.space-icon-options button:visible')).toHaveCount(1);
    await b.shell.getByRole('button', { name: 'rocket icon', exact: true }).click();
    await b.shell.locator('input[name="name"]').fill('Reading room');
    await b.shell.getByRole('button', { name: 'sky', exact: true }).click();
    await b.shell.locator('summary').filter({ hasText: 'Gradient & texture' }).click();
    await b.shell.locator('summary').filter({ hasText: 'Gradient & texture' }).focus();
    await b.shell.keyboard.press('Tab');
    await expect(b.shell.locator('input[name="theme-gradient"]')).toBeFocused();
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
      'Legacy blur is retained; native blur strength is system controlled',
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
    const closePanel = await b.shell.locator('[data-key="panel-close"]').boundingBox();
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
    const samples = await b.shell.evaluate(() => window.sidebarSamples);
    assert(
      samples.some((width) => width > 0 && width < 220),
      'Closing must have real intermediate geometry',
    );
    assert(
      samples.every((width) => width >= 0 && width <= 224),
      'Sidebar motion never overshoots',
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
    await b.shell.locator('summary').filter({ hasText: 'Gradient & texture' }).click();
    await b.shell.locator('summary').filter({ hasText: 'Glass & transparency' }).click();
    for (const [width, height] of [
      [560, 420],
      [960, 640],
      [960, 780],
      [960, 795],
    ]) {
      const accepted = await b.app.evaluate(
        ({ BrowserWindow }, { width, height }) => {
          const window = BrowserWindow.getAllWindows()[0];
          window.setContentSize(width, height);
          return window.getContentSize();
        },
        { width, height },
      );
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
    const expanded = await b.shell.locator('.space-page .favorite').first().boundingBox();
    assert(expanded.width > rowsByCount.get(12));
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
