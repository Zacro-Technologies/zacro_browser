'use strict';
// Explicit online acceptance only: npm test and test:e2e never acquire these packages.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');
const {
  PINS,
  assertPins,
  requireNativeCapabilities,
  acquireReactScripts,
} = require('../helpers/provider-acceptance.cjs');

for (const [key, pin] of Object.entries(PINS)) {
  test(`production provider: ${pin.name} ${pin.version}`, { timeout: 150000 }, async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-provider-'));
    let hits = 0;
    const scripts =
      key === 'react-devtools'
        ? await acquireReactScripts().catch(async (error) => {
            await fs.rm(directory, { recursive: true, force: true });
            throw error;
          })
        : {};
    const server = http.createServer((request, response) => {
      const resource = request.url.split('?')[0];
      if (resource === '/react.js' || resource === '/react-dom.js') {
        response.setHeader('content-type', 'application/javascript');
        response.end(scripts[resource === '/react.js' ? 'react' : 'react-dom']);
      } else if (resource === '/xpopup/xpopup.js') {
        hits++;
        response.setHeader('content-type', 'application/javascript');
        response.setHeader('cache-control', 'no-store');
        response.end('/* disposable loopback rule target */');
      } else {
        response.setHeader('content-type', 'text/html');
        response.end(
          `<!doctype html><html><head><style>html,body{background:#fff;color:#111}body{padding:32px}</style></head><body><h1>Representative local page</h1><div id="root"></div>${key === 'react-devtools' ? `<script src="/react.js"></script><script src="/react-dom.js"></script><script>function RepresentativeCounter(){const [count,setCount]=React.useState(0);return React.createElement('button',{id:'counter',onClick:()=>setCount(count+1)},'Genuine React count '+count)};ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(RepresentativeCounter));</script>` : ''}</body></html>`,
        );
      }
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/`;
    const env = { ...process.env, ZACRO_USER_DATA: directory, ZACRO_SKIP_ONBOARDING: '1' };
    delete env.ELECTRON_RUN_AS_NODE;
    delete env.ZACRO_SYNC_URL;
    let app;
    t.after(async () => {
      if (app) await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    app = await electron.launch({
      ...(process.env.ZACRO_CUSTOM_ELECTRON ? { executablePath: process.env.ZACRO_CUSTOM_ELECTRON } : {}),
      args: [path.resolve(__dirname, '../fixtures/extensions/provider-main.cjs')],
      env,
    });
    const page = await app.firstWindow();
    await page.waitForFunction(() => !!window.zacro);
    await expect(page.locator('#command-input')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#command-input')).toHaveCount(0);
    const invoke = (action, payload = {}) =>
      page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    await invoke('navigate', { url });
    const read = (expression) =>
      app.evaluate(
        ({ webContents }, { url, expression }) => {
          const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
          return wc ? wc.executeJavaScript(expression) : null;
        },
        { url, expression },
      );
    await expect.poll(() => read('document.readyState')).toBe('complete');
    const runtime = await app.evaluate(
      ({ webContents }, { url }) => {
        const ses = webContents.getAllWebContents().find((item) => item.getURL() === url).session;
        return {
          capabilities: globalThis.providerCapabilities(ses),
          versions: process.versions,
          executable: process.execPath,
        };
      },
      { url },
    );
    t.diagnostic(JSON.stringify({ runtime }));
    requireNativeCapabilities(runtime.capabilities, process.env.ZACRO_REQUIRE_CUSTOM_ELECTRON === '1');
    await app.evaluate(({ dialog }, pin) => {
      dialog.showMessageBox = async (_window, options) => ({
        response:
          options.title === 'Review extension permissions' &&
          options.message === `${pin.manifestName || pin.name} ${pin.version}`
            ? 1
            : 0,
      });
    }, pin);
    const before = await read('getComputedStyle(document.body).backgroundColor');
    const extension = await invoke('extension:install-store', { url: pin.id });
    assert.equal(extension.version, pin.version);
    assert.equal(extension.publisherVerified, true);
    assert.equal(extension.source, 'chrome-web-store');
    const acquisitions = await app.evaluate(() => globalThis.providerAcquisitions);
    assert.equal(acquisitions.length, 1);
    assertPins(pin, acquisitions[0].version, acquisitions[0].sha256);
    t.diagnostic(JSON.stringify({ acquisition: acquisitions[0] }));
    const profileRoot = path.join(
      directory,
      'extensions/profiles',
      crypto.createHash('sha256').update(extension.profileId).digest('hex'),
    );
    const saved = JSON.parse(await fs.readFile(path.join(profileRoot, 'state.json'), 'utf8')).extensions.find(
      (item) => item.id === pin.id,
    );
    const version = saved.pending || saved.current;
    const original = path.join(profileRoot, 'versions', version.token, 'original');
    const archive = await fs.readFile(path.join(profileRoot, 'versions', version.token, 'original.crx'));
    assertPins(
      pin,
      JSON.parse(await fs.readFile(path.join(original, 'manifest.json'), 'utf8')).version,
      crypto.createHash('sha256').update(archive).digest('hex'),
    );
    const nativeLoaded = () =>
      app.evaluate(
        ({ webContents }, { url, id }) =>
          webContents
            .getAllWebContents()
            .find((item) => item.getURL() === url)
            .session.extensions.getAllExtensions()
            .some((item) => item.id === id),
        { url, id: pin.id },
      );
    const denied =
      key === 'bitwarden' ||
      (key === 'dark-reader' && !runtime.capabilities.fontSettings) ||
      (key === 'ublock-origin-lite' && !(runtime.capabilities.activeTab && runtime.capabilities.userScripts));
    await page.getByRole('button', { name: 'Library', exact: true }).click();
    await page.locator('[data-key="panel-settings"]').click();
    await page.getByText('Extensions', { exact: true }).click();
    await page.getByRole('button', { name: 'Manage extensions', exact: true }).click();
    const card = page.locator('.extension-card');
    await expect(card).toHaveCount(1);
    await expect(card).toContainText(pin.version);
    if (denied) {
      assert.equal(extension.status, 'incompatible');
      assert.equal(extension.enabled, false);
      assert.equal(await nativeLoaded(), false);
      await expect(card).toContainText('Unsupported requirements');
      const expected =
        key === 'dark-reader'
          ? ['fontSettings']
          : key === 'ublock-origin-lite'
            ? ['activeTab', 'userScripts']
            : [
                'clipboardRead',
                'clipboardWrite',
                'idle',
                'notifications',
                'webNavigation',
                'webRequestAuthProvider',
                'file:///*',
                'sandbox',
              ];
      for (const capability of expected) {
        assert.ok(
          extension.unsupported.some((item) => item.required && item.capability === capability),
          capability,
        );
        await expect(card).toContainText(capability);
      }
      if (key !== 'bitwarden')
        assert.equal(
          runtime.capabilities.version,
          0,
          'Incomplete custom runtime must not count as stock denial acceptance',
        );
      t.diagnostic(
        `${pin.name}: verified original retained, visible required-API incompatibility, native activation absent; core positive behavior not claimed.`,
      );
      return;
    }
    assert.equal(extension.enabled, true);
    assert.equal(await nativeLoaded(), true);
    // Revisit to exercise real content scripts at document_start after installation.
    await invoke('navigate', { url: url + '?installed' });
    await invoke('navigate', { url });
    if (key === 'dark-reader') {
      await expect
        .poll(() => read('document.querySelectorAll("style.darkreader").length'), { timeout: 20000 })
        .toBeGreaterThan(0);
      await expect
        .poll(() => read('getComputedStyle(document.body).backgroundColor'), { timeout: 20000 })
        .not.toBe(before);
      const dark = await read(
        '({background:getComputedStyle(document.body).backgroundColor,color:getComputedStyle(document.body).color})',
      );
      assert.match(dark.background, /^rgb/);
      assert.notEqual(dark.background, before);
      await invoke('extension:toggle', { id: pin.id });
      await invoke('navigate', { url: url + '?disabled' });
      await invoke('navigate', { url });
      await expect.poll(() => read('getComputedStyle(document.body).backgroundColor')).toBe(before);
      t.diagnostic(
        JSON.stringify({
          behavior:
            'Original Dark Reader injected styling changes page colors; disable+reload restores appearance',
          before,
          dark,
        }),
      );
    } else if (key === 'ublock-origin-lite') {
      const manifest = JSON.parse(await fs.readFile(path.join(original, 'manifest.json'), 'utf8'));
      const resource = manifest.declarative_net_request.rule_resources.find((item) => item.id === 'easylist');
      assert.equal(resource.enabled, true);
      const rule = JSON.parse(
        await fs.readFile(path.join(original, resource.path.replace(/^\//, '')), 'utf8'),
      ).find((item) => item.id === 19);
      assert.deepEqual(rule, {
        action: { type: 'block' },
        condition: { urlFilter: '/xpopup/xpopup.js' },
        id: 19,
        priority: 10,
      });
      const request = () =>
        read(
          `fetch('/xpopup/xpopup.js?nonce='+Math.random(),{cache:'no-store'}).then(r=>r.status).catch(()=> 'blocked')`,
        );
      await expect.poll(request, { timeout: 20000 }).toBe('blocked');
      assert.equal(hits, 0, 'Native rule must prevent a loopback server hit');
      await invoke('extension:toggle', { id: pin.id });
      await expect.poll(request, { timeout: 10000 }).toBe(200);
      assert.ok(hits > 0);
      assert.equal(await nativeLoaded(), false);
      t.diagnostic(
        'Original enabled easylist rule19 blocks loopback /xpopup/xpopup.js with zero server hits; disable removes native block. No public ad request or replacement rule.',
      );
    } else if (key === 'react-devtools') {
      assert.deepEqual(
        extension.unsupported.map(({ capability, required }) => ({ capability, required })),
        [{ capability: 'clipboardWrite', required: false }],
      );
      await expect(card).toContainText('clipboardWrite');
      await expect
        .poll(() => read('document.querySelector("#counter")?.textContent'))
        .toBe('Genuine React count 0');
      await read('document.querySelector("#counter").click()');
      await expect
        .poll(() => read('document.querySelector("#counter").textContent'))
        .toBe('Genuine React count 1');
      await app.evaluate(
        ({ webContents }, url) =>
          webContents
            .getAllWebContents()
            .find((item) => item.getURL() === url)
            .openDevTools({ mode: 'detach', activate: false }),
        url,
      );
      const inspectTools = (expression) =>
        app.evaluate(
          ({ webContents }, { url, expression }) =>
            webContents
              .getAllWebContents()
              .find((item) => item.getURL() === url)
              .devToolsWebContents?.executeJavaScript(expression),
          { url, expression },
        );
      await expect
        .poll(
          () =>
            inspectTools(
              `(async()=>{const UI=await import('./ui/legacy/legacy.js'); const view=UI.InspectorView.InspectorView.instance();return view.tabbedPane.tabIds().filter(id=>id.startsWith('chrome-extension://'));})()`,
            ),
          { timeout: 20000 },
        )
        .toHaveLength(3);
      await inspectTools(
        `(async()=>{const UI=await import('./ui/legacy/legacy.js');const view=UI.InspectorView.InspectorView.instance();await view.showPanel(view.tabbedPane.tabIds().find(id=>id.startsWith('chrome-extension://')));})()`,
      );
      const panelText = () =>
        app.evaluate(
          ({ webContents }, { url, id }) => {
            const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
            const frames = (frame) => [frame, ...frame.frames.flatMap(frames)];
            const panel = frames(wc.devToolsWebContents.mainFrame).find(
              (frame) => frame.url === `chrome-extension://${id}/panel.html`,
            );
            return panel?.executeJavaScript('document.body.innerText');
          },
          { url, id: pin.id },
        );
      await expect.poll(panelText, { timeout: 25000 }).toContain('RepresentativeCounter');
      assert.equal(await read('React.version'), '18.3.1');
      const rendererVersions = await read(
        'Array.from(window.__REACT_DEVTOOLS_GLOBAL_HOOK__.renderers.values()).map(renderer=>renderer.version)',
      );
      assert.ok(rendererVersions.includes('18.3.1'));
      t.diagnostic(
        JSON.stringify({
          behavior:
            'Original React DevTools creates real panels and renders genuine component tree after state update',
          rendererVersions,
          component: 'RepresentativeCounter',
          optionalUnsupported: 'clipboardWrite',
        }),
      );
    }
    assert.equal(await read('typeof window.zacro'), 'undefined');
    assert.equal(await read('typeof window.zacroExtension'), 'undefined');
  });
}
