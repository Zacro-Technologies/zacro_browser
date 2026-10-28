'use strict';

// Instrumented, own-application documentation review. This does not automate
// the Windows desktop or generate screenshots. After each ready message, a
// reviewer can capture the actual whole window through a passive native tool.
const fs = require('node:fs/promises');
const path = require('node:path');
const readline = require('node:readline');
const { spawn } = require('node:child_process');
const { createHash } = require('node:crypto');
const { chromium, _electron: electron, expect } = require('@playwright/test');
const { BrowserStore } = require('../src/core/store.cjs');
const { createShowcaseState } = require('../test/fixtures/showcase-state.cjs');
const { createShowcaseSite, populateLocalFavorites } = require('./interactive-qa.cjs');
const { packagedPaths } = require('./platform-build.cjs');

const output = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(fn, label, milliseconds = 20000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    const value = await fn();
    if (value) return value;
    await sleep(80);
  }
  throw new Error(`Timed out: ${label}`);
}

async function main() {
  const root = path.resolve(__dirname, '..');
  const scratch = path.join(root, '.tmp');
  await fs.mkdir(scratch, { recursive: true });
  const directory = await fs.mkdtemp(path.join(scratch, 'review-captures-'));
  const source = process.argv.includes('--source');
  const packageInfo = packagedPaths(root);
  if (!source) await fs.access(packageInfo.executable);
  const server = createShowcaseSite();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const store = new BrowserStore(directory);
  store.state = populateLocalFavorites(createShowcaseState(url), url);
  store.state.windowBounds = {
    width: 1280,
    height: 800,
    x: 20,
    y: 20,
    maximized: false,
    sizeKind: 'content',
  };
  for (const [id, title, suffix] of [
    ['showcase-tab-repo', 'Design handbook', '/reference/handbook'],
    ['showcase-tab-css', 'Release checklist', '/reference/checklist'],
  ]) {
    const tab = store.state.tabs.find((item) => item.id === id);
    Object.assign(tab, {
      title,
      customTitle: title,
      url: new URL(suffix, url).href,
      pinned: true,
      favorite: false,
      folderId: null,
    });
  }
  store.state.folders = store.state.folders.filter((folder) => folder.id !== 'showcase-project');
  if (process.argv.includes('--opaque')) for (const space of store.state.spaces) space.theme.opacity = 100;
  store.save();
  const results = path.join(root, 'test-results');
  await fs.mkdir(results, { recursive: true });
  const recordPath = path.join(
    results,
    `review-captures-${new Date().toISOString().replace(/[:.]/g, '-')}.json`,
  );
  const provenance = {
    createdAt: new Date().toISOString(),
    mode: source ? 'source-electron' : 'packaged-cdp',
    executable: source ? require('electron') : packageInfo.executable,
    isolatedProfile: directory,
    localFixture: url,
    screenshotMethod: 'Separate passive whole-window Computer capture; this script creates no images.',
    limitation:
      'Instrumented application control is not proof of native pointer, keyboard, trackpad, account sign-in or commercial-release acceptance.',
    stages: [],
  };
  if (!source)
    provenance.asarSha256 = createHash('sha256')
      .update(await fs.readFile(path.join(packageInfo.resources, 'app.asar')))
      .digest('hex');
  const saveRecord = () => fs.writeFile(recordPath, `${JSON.stringify(provenance, null, 2)}\n`);
  await saveRecord();
  const env = { ...process.env, ZACRO_USER_DATA: directory, ZACRO_SKIP_ONBOARDING: '1' };
  delete env.ELECTRON_RUN_AS_NODE;
  let child,
    browser,
    electronApp,
    shell,
    exiting = false,
    contentSize = [1280, 800];
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');

  async function launch() {
    if (source) {
      electronApp = await electron.launch({ args: [root], env });
      shell = await electronApp.firstWindow();
      child = electronApp.process();
    } else {
      child = spawn(
        packageInfo.executable,
        ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'],
        {
          cwd: root,
          env,
          windowsHide: false,
          stdio: ['ignore', 'pipe', 'pipe'],
        },
      );
      child.stdout.resume();
      const endpoint = await new Promise((resolve, reject) => {
        let diagnostic = '';
        const timer = setTimeout(
          () => reject(new Error(`Packaged startup timed out: ${diagnostic.slice(-1200)}`)),
          30000,
        );
        child.once('error', (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child.once('exit', (code) => {
          clearTimeout(timer);
          reject(new Error(`Packaged app exited (${code}). ${diagnostic.slice(-1200)}`));
        });
        child.stderr.on('data', (chunk) => {
          diagnostic = (diagnostic + chunk).slice(-10000);
          const match = diagnostic.match(/DevTools listening on (ws:\/\/[^\s]+)/);
          if (match) {
            clearTimeout(timer);
            resolve(match[1]);
          }
        });
      });
      browser = await chromium.connectOverCDP(endpoint);
      shell = await until(
        () =>
          browser
            .contexts()[0]
            .pages()
            .find((page) => page.url().includes('renderer/index.html')),
        'renderer handshake',
      );
    }
    await shell.waitForFunction(() => Boolean(window.zacro));
    await expect(shell.locator('[data-key="library"]')).toBeVisible();
    await shell.bringToFront();
    const about = await invoke('app:about');
    if (!source && !about.packaged) throw new Error('The requested packaged application is not packaged.');
    provenance.runtime = about;
    shell.on('pageerror', (error) => output({ type: 'renderer-error', message: error.message }));
    await preloadIcons();
  }
  async function preloadIcons() {
    const current = await state();
    for (const tab of current.tabs.filter((item) => item.favorite)) {
      await invoke('tab:activate', { id: tab.id });
      await until(
        async () => {
          const page = (await state()).runtime.pages?.[tab.id];
          return page?.loaded && !page.loading && page.favicon;
        },
        `local Favorite icon ${tab.customTitle || tab.title}`,
      );
    }
    await invoke('tab:activate', { id: 'showcase-tab-journal' });
    await settled();
  }
  async function settled() {
    await until(async () => !(await state()).runtime.page?.loading, 'native page loading');
    await expect(shell.locator('#app')).toHaveAttribute('data-panel-animating', 'false');
    await expect(shell.locator('#app')).toHaveAttribute('data-sidebar-animating', 'false');
    await shell.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    );
  }
  async function closeSurfaces() {
    if (await shell.locator('#library-menu').count()) await shell.keyboard.press('Escape');
    if (await shell.locator('.dialog').count()) await shell.keyboard.press('Escape');
    if ((await state()).runtime.peek) await invoke('peek:close');
    if (await shell.locator('#side-panel').isVisible())
      await shell.locator('[data-key="panel-close"]').click();
    if (await shell.locator('#findbar').isVisible()) await shell.keyboard.press('Escape');
    await settled();
  }
  async function stopApp() {
    if (!child || child.exitCode !== null) return;
    await invoke('app:quit').catch(() => {});
    await until(() => child.exitCode !== null, 'application quit', 10000).catch(() => child.kill());
    if (electronApp) await electronApp.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
    electronApp = null;
    browser = null;
    shell = null;
    child = null;
  }
  async function resize(width, height) {
    if (width === contentSize[0] && height === contentSize[1]) return;
    if (source)
      await electronApp.evaluate(
        ({ BrowserWindow }, size) => BrowserWindow.getAllWindows()[0].setContentSize(...size),
        [width, height],
      );
    else {
      // Packaged builds deliberately expose no privileged resizing IPC. Restart
      // the same disposable profile with its real saved native window bounds.
      await stopApp();
      const saved = new BrowserStore(directory);
      saved.state.windowBounds = { width, height, x: 20, y: 20, maximized: false, sizeKind: 'content' };
      saved.save();
      await launch();
    }
    contentSize = [width, height];
  }
  async function stage(command) {
    const name = command.stage;
    if (name === 'exit') {
      await finish();
      return;
    }
    if (name === 'help') {
      output({
        type: 'help',
        commands: [
          'workspace',
          'library-menu',
          'library',
          'palette',
          'space-theme',
          'peek',
          'dark',
          'compact',
          'inspect',
          'exit',
        ],
        options:
          'JSON: {"stage":"library","section":"history"}, {"stage":"palette","query":"move"}, {"stage":"workspace","theme":"light","opacity":55}. Compact restarts the same packaged profile with native 560×420 bounds. --source opts into development Electron; packaged is the default.',
      });
      return;
    }
    if (
      ![
        'workspace',
        'library-menu',
        'library',
        'palette',
        'space-theme',
        'peek',
        'dark',
        'compact',
        'inspect',
      ].includes(name)
    )
      throw new Error('Unknown review stage. Enter help.');
    if (name !== 'inspect') {
      await closeSurfaces();
      await resize(name === 'compact' ? 560 : 1280, name === 'compact' ? 420 : 800);
      await invoke('space:activate', { id: 'showcase-studio' });
      await invoke('tab:activate', { id: 'showcase-tab-journal' });
      if (name === 'dark' || command.theme) {
        const theme = name === 'dark' ? 'dark' : command.theme;
        if (!['light', 'dark', 'system'].includes(theme)) throw new Error('Use light, dark or system.');
        await invoke('settings:update', { values: { theme } });
      }
      if (command.opacity !== undefined) {
        if (!Number.isFinite(command.opacity) || command.opacity < 40 || command.opacity > 100)
          throw new Error('Opacity must be from 40 to 100.');
        await invoke('space:update', { id: 'showcase-studio', theme: { opacity: command.opacity } });
      }
      await settled();
      if (name === 'library-menu' || name === 'library' || name === 'compact') {
        await shell.locator('[data-key="library"]').click();
        await expect(shell.locator('#library-menu')).toBeVisible();
        if (name === 'library' || name === 'compact') {
          const section = command.section || 'bookmarks';
          if (
            !['bookmarks', 'history', 'downloads', 'archive', 'settings', 'extensions', 'ai'].includes(
              section,
            )
          )
            throw new Error('Unknown Library section.');
          await shell.locator(`#library-menu [data-panel="${section}"]`).click();
        }
      } else if (name === 'palette' || name === 'dark') {
        await invoke('shortcut:run', { id: 'command-palette' });
        await shell.locator('#command-input').fill(command.query ?? '/');
      } else if (name === 'space-theme') {
        await shell.locator('.space-dot[data-id="showcase-studio"]').click({ button: 'right' });
        await shell.getByRole('button', { name: 'Customize Space', exact: true }).click();
        await shell.locator('details.theme-material').last().locator('summary').click();
      } else if (name === 'peek') {
        await invoke('peek:open', { url: new URL('/notes', url).href });
        await until(async () => (await state()).runtime.peek?.loading === false, 'Peek content');
      }
      await settled();
    }
    const snapshot = await state();
    const entry = {
      stage: name,
      at: new Date().toISOString(),
      pid: child.pid,
      theme: snapshot.settings.theme,
      material: snapshot.runtime.windowMaterial,
      activeTab: snapshot.activeTabId,
      favoritesLoaded: snapshot.tabs
        .filter((tab) => tab.favorite)
        .filter((tab) => snapshot.runtime.pages?.[tab.id]?.favicon).length,
      geometry: await shell.evaluate(() => ({
        width: innerWidth,
        height: innerHeight,
        dpr: devicePixelRatio,
        panel:
          document.querySelector('#side-panel').getAttribute('aria-hidden') === 'false'
            ? document.querySelector('#panel-title')?.textContent || null
            : null,
        dialog: document.querySelector('.dialog')?.getAttribute('aria-label') || null,
      })),
    };
    provenance.stages.push(entry);
    await saveRecord();
    output({
      type: 'ready',
      ...entry,
      record: recordPath,
      note: 'Ready for a separate passive native whole-window capture. Instrumented control, not native-input acceptance.',
    });
  }
  async function finish() {
    if (exiting) return;
    exiting = true;
    await stopApp();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    const target = path.resolve(directory);
    if (
      path.dirname(target) !== path.resolve(scratch) ||
      !path.basename(target).startsWith('review-captures-')
    )
      throw new Error('Refusing to remove an unexpected profile path.');
    await fs.rm(target, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    provenance.closedAt = new Date().toISOString();
    await saveRecord();
    output({ type: 'closed', record: recordPath });
  }
  process.once('SIGINT', () => finish().finally(() => process.exit()));
  process.once('SIGTERM', () => finish().finally(() => process.exit()));
  try {
    await launch();
    await stage({ stage: 'workspace' });
    const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
    for await (const line of lines) {
      if (!line.trim()) continue;
      try {
        await stage(line.trim().startsWith('{') ? JSON.parse(line) : { stage: line.trim() });
      } catch (error) {
        output({ type: 'error', message: error.message });
      }
      if (exiting) {
        lines.close();
        break;
      }
    }
  } finally {
    await finish();
  }
}

if (require.main === module)
  main().catch((error) => {
    output({ type: 'fatal', message: error.message });
    process.exitCode = 1;
  });
module.exports = { main };
