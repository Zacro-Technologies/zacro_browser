'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const { _electron: electron, expect } = require('@playwright/test');
const { zip, crx, keyPair } = require('../fixtures/extensions/packages/builders.cjs');
test(
  'real identity window uses profile HTTPS cookies, intercepts redirects, isolates provider and tears down revoked callers',
  { timeout: 90000 },
  async (t) => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-identity-'));
    // Public synthetic test key/certificate only. Exact test trust is scoped below.
    const fixture = path.join(__dirname, '../fixtures/extensions/identity-provider');
    const cert = await fs.readFile(path.join(fixture, 'cert.pem'), 'utf8');
    const key = await fs.readFile(path.join(fixture, 'key.pem'));
    let extensionId;
    const cookies = [];
    const server = https.createServer({ key, cert }, (request, response) => {
      const url = new URL(request.url, 'https://fixture.test');
      cookies.push(request.headers.cookie || '');
      if (url.pathname === '/redirect') {
        response.writeHead(302, {
          Location: `https://${extensionId}.chromiumapp.org/cb?code=synthetic#state=kept`,
        });
        response.end();
        return;
      }
      if (url.pathname === '/foreign') {
        response.writeHead(302, { Location: `https://${'b'.repeat(32)}.chromiumapp.org/cb?code=synthetic` });
        response.end();
        return;
      }
      response.setHeader('Content-Type', 'text/html');
      response.end(
        '<!doctype html><title>Synthetic identity provider</title><button id="finish">Finish</button><script>document.querySelector("#finish").onclick=()=>location.href=' +
          JSON.stringify(`https://${extensionId}.chromiumapp.org/interactive?code=synthetic#fragment`) +
          `;if(location.pathname==='/delayed')setTimeout(()=>document.querySelector('#finish').click(),100);</script>`,
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `https://127.0.0.1:${server.address().port}`;
    const signed = crx(
      zip([
        {
          name: 'manifest.json',
          data: JSON.stringify({
            manifest_version: 3,
            name: 'Identity fixture',
            version: '1',
            permissions: ['identity', 'identity.email'],
            options_page: 'options.html',
          }),
        },
        { name: 'options.html', data: '<!doctype html><title>Identity options</title>' },
      ]),
      { keys: [keyPair()] },
    );
    extensionId = signed.id;
    const crxPath = path.join(root, 'identity.crx');
    await fs.writeFile(crxPath, signed.buffer);
    const rawPath = path.join(root, 'raw-runtime-probe');
    await fs.mkdir(rawPath);
    await fs.writeFile(
      path.join(rawPath, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Raw native identity probe',
        version: '1',
        permissions: ['identity'],
        options_page: 'page.html',
      }),
    );
    await fs.writeFile(path.join(rawPath, 'page.html'), '<!doctype html><title>Raw probe</title>');
    const env = { ...process.env, ZACRO_USER_DATA: path.join(root, 'browser'), ZACRO_FIXTURE_CRX: crxPath };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/sync-browser.cjs')],
      env,
    });
    t.after(async () => {
      await app
        .evaluate(({ dialog }) => {
          dialog.showMessageBoxSync = () => 1;
        })
        .catch(() => {});
      await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
      await fs.rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const shell = await app.firstWindow();
    await shell.waitForFunction(() => !!window.zacro);
    await app.evaluate(({ dialog }) => {
      dialog.showMessageBox = async () => ({ response: 1 });
    });
    const raw = await app.evaluate(async ({ session, BrowserWindow }, rawPath) => {
      const ses = session.fromPartition('persist:identity-raw-probe');
      const extension = await ses.extensions.loadExtension(rawPath);
      const win = new BrowserWindow({
        show: false,
        webPreferences: { session: ses, sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
      try {
        await win.loadURL(`chrome-extension://${extension.id}/page.html`);
        return {
          electron: process.versions.electron,
          chromium: process.versions.chrome,
          identity: await win.webContents.executeJavaScript(
            '({namespace:typeof chrome.identity,token:typeof chrome.identity?.getAuthToken,webFlow:typeof chrome.identity?.launchWebAuthFlow})',
          ),
        };
      } finally {
        win.destroy();
        ses.extensions.removeExtension(extension.id);
      }
    }, rawPath);
    t.diagnostic('Unadapted runtime probe: ' + JSON.stringify(raw));
    assert.equal(raw.electron, '45.0.0');
    assert.equal(raw.identity.token, 'undefined');
    const invoke = (action, payload = {}) =>
      shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    await invoke('extension:install-store', { url: signed.id });
    await invoke('extension:options', { id: signed.id });
    const optionsId = await app.evaluate(
      ({ webContents }, id) =>
        webContents.getAllWebContents().find((w) => w.getURL() === `chrome-extension://${id}/options.html`)
          ?.id,
      signed.id,
    );
    assert.ok(optionsId);
    const execute = (id, code) =>
      app.evaluate(({ webContents }, { id, code }) => webContents.fromId(id).executeJavaScript(code), {
        id,
        code,
      });
    const nativeIdentity = await execute(
      optionsId,
      'typeof chrome.identity+":"+typeof chrome.identity?.getAuthToken',
    );
    t.diagnostic(`Pinned runtime identity facade after bootstrap: ${nativeIdentity}`);
    assert.equal(
      await execute(optionsId, 'chrome.identity.getRedirectURL("callback")'),
      `https://${signed.id}.chromiumapp.org/callback`,
    );
    assert.deepEqual(await execute(optionsId, 'chrome.identity.getProfileUserInfo()'), { email: '', id: '' });
    assert.match(
      await execute(optionsId, 'chrome.identity.getAuthToken().catch(e=>e.message)'),
      /unsupported/,
    );
    // Certificate results are cached by Chromium. Exercise default TLS in a
    // distinct disposable session, so its denial cannot contaminate fixture trust.
    const tlsDenied = await app.evaluate(
      async ({ session, BrowserWindow }, { identityPath, base, id }) => {
        const { IdentityController } = process.getBuiltinModule('module').createRequire(identityPath)(
          identityPath,
        );
        const untrusted = session.fromPartition('identity-untrusted-provider');
        const controller = new IdentityController({
          native: { BrowserWindow },
          getSession: () => untrusted,
          getProfile: () => ({ id: 'untrusted' }),
          resolveExtension: () => ({ enabled: true, generation: 'g', grants: { permissions: ['identity'] } }),
        });
        try {
          await controller.call(
            { profileId: 'untrusted', extensionId: id, generation: 'g', kind: 'extension-frame' },
            'launchWebAuthFlow',
            [{ url: base + '/page' }],
          );
          return 'unexpected success';
        } catch (error) {
          return error.message;
        } finally {
          controller.dispose();
        }
      },
      {
        identityPath: path.resolve(__dirname, '../../src/main/extensions/identity.cjs'),
        base,
        id: signed.id,
      },
    );
    assert.match(tlsDenied, /failed to load/);
    // Test-only trust is limited to this disposable profile session, exact host and exact certificate.
    await app.evaluate(
      ({ webContents }, { optionsId, cert, base }) => {
        const ses = webContents.fromId(optionsId).session;
        ses.setCertificateVerifyProc((request, callback) =>
          callback(
            request.hostname === '127.0.0.1' && request.certificate.data.trim() === cert.trim() ? 0 : -3,
          ),
        );
        return ses.cookies.set({
          url: base,
          name: 'synthetic_profile_cookie',
          value: 'present',
          secure: true,
        });
      },
      { optionsId, cert, base },
    );
    const flow = (details) =>
      execute(
        optionsId,
        `chrome.identity.launchWebAuthFlow(${JSON.stringify(details)}).then(url=>({url}),error=>({error:error.message}))`,
      );
    assert.deepEqual(await flow({ url: base + '/redirect' }), {
      url: `https://${signed.id}.chromiumapp.org/cb?code=synthetic#state=kept`,
    });
    assert.match((await flow({ url: base + '/foreign' })).error, /navigation/);
    assert.match((await flow({ url: base + '/page' })).error, /interaction required/);
    assert.deepEqual(
      await flow({
        url: base + '/delayed',
        abortOnLoadForNonInteractive: false,
        timeoutMsForNonInteractive: 3000,
      }),
      { url: `https://${signed.id}.chromiumapp.org/interactive?code=synthetic#fragment` },
    );
    assert.match(
      (
        await flow({
          url: base + '/page',
          abortOnLoadForNonInteractive: false,
          timeoutMsForNonInteractive: 100,
        })
      ).error,
      /timed out/,
    );
    assert.ok(cookies.some((c) => c.includes('synthetic_profile_cookie=present')));
    const interactive = flow({ url: base + '/page', interactive: true });
    let authId;
    await expect
      .poll(
        async () =>
          (authId = await app.evaluate(
            ({ BrowserWindow }, base) =>
              BrowserWindow.getAllWindows().find(
                (w) => w.webContents.getURL() === base + '/page' && w.isVisible(),
              )?.webContents.id,
            base,
          )),
      )
      .toBeTruthy();
    assert.equal(
      await execute(
        authId,
        'typeof process+":"+typeof require+":"+typeof zacro+":"+typeof zacroExtension+":"+typeof chrome?.identity',
      ),
      'undefined:undefined:undefined:undefined:undefined',
    );
    const isolation = await app.evaluate(
      ({ webContents }, { authId, optionsId }) => {
        const w = webContents.fromId(authId),
          preferences = w.getLastWebPreferences();
        return {
          sandbox: preferences.sandbox,
          contextIsolation: preferences.contextIsolation,
          node: preferences.nodeIntegration,
          sameSession: w.session === webContents.fromId(optionsId).session,
        };
      },
      { authId, optionsId },
    );
    assert.deepEqual(isolation, { sandbox: true, contextIsolation: true, node: false, sameSession: true });
    const count = await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length);
    await execute(authId, 'window.open("https://127.0.0.1/escape");undefined');
    assert.equal(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length), count);
    await execute(authId, 'document.querySelector("#finish").click();undefined');
    assert.deepEqual(await interactive, {
      url: `https://${signed.id}.chromiumapp.org/interactive?code=synthetic#fragment`,
    });
    // Actual caller closure must destroy owned work, even without a redirect.
    const pending = flow({ url: base + '/page', interactive: true });
    pending.catch(() => {});
    await expect
      .poll(
        async () =>
          await app.evaluate(
            ({ webContents }, base) =>
              webContents.getAllWebContents().filter((w) => w.getURL() === base + '/page').length,
            base,
          ),
      )
      .toBe(1);
    await app.evaluate(({ webContents }, optionsId) => webContents.fromId(optionsId).close(), optionsId);
    await expect
      .poll(
        async () =>
          await app.evaluate(
            ({ webContents }, base) =>
              webContents.getAllWebContents().filter((w) => w.getURL() === base + '/page').length,
            base,
          ),
      )
      .toBe(0);
    await pending.catch(() => {});
    // Disable tears down owned provider content through the production host path.
    await invoke('extension:options', { id: signed.id });
    const reopened = await app.evaluate(
      ({ webContents }, id) =>
        webContents.getAllWebContents().find((w) => w.getURL() === `chrome-extension://${id}/options.html`)
          ?.id,
      signed.id,
    );
    const disabling = execute(
      reopened,
      `chrome.identity.launchWebAuthFlow({url:${JSON.stringify(base + '/page')},interactive:true}).catch(e=>e.message)`,
    );
    disabling.catch(() => {});
    await expect
      .poll(
        async () =>
          await app.evaluate(
            ({ webContents }, base) =>
              webContents.getAllWebContents().filter((w) => w.getURL() === base + '/page').length,
            base,
          ),
      )
      .toBe(1);
    await invoke('extension:toggle', { id: signed.id });
    await expect
      .poll(
        async () =>
          await app.evaluate(
            ({ webContents }, base) =>
              webContents.getAllWebContents().filter((w) => w.getURL() === base + '/page').length,
            base,
          ),
      )
      .toBe(0);
    await disabling.catch(() => {});
  },
);
