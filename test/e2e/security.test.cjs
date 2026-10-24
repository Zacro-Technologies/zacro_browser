'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');
const { makePDF } = require('../fixtures/pdf.cjs');

let server, base;
before(async () => {
  server = http.createServer(async (request, response) => {
    if (request.url === '/document.pdf') {
      response.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Disposition': 'inline' });
      response.end(
        makePDF([
          'The remote PDF cancellation fee is twenty dollars.',
          'The second PDF page describes refunds.',
        ]),
      );
      return;
    }
    if (
      request.url === '/auth' &&
      request.headers.authorization !==
        `Basic ${Buffer.from('test-user:zacro-test-password').toString('base64')}`
    ) {
      response.writeHead(401, {
        'WWW-Authenticate': 'Basic realm="Zacro fixture"',
        'Content-Type': 'text/plain',
      });
      response.end('Authentication required');
      return;
    }
    let submitted = '';
    for await (const chunk of request) submitted += chunk.toString();
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      `<!doctype html><html><head><title>Security fixture</title></head><body><button id="activate">Activate</button><h1>Security fixture</h1><p id="method">${request.method}</p><p id="submitted">${submitted.replace(/[<>&]/g, '')}</p><form id="post" target="_blank" method="post" action="/posted"><input name="value" value="retained-body"><button>Submit</button></form></body></html>`,
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(
  () =>
    new Promise((resolve) => {
      server.closeAllConnections();
      server.close(resolve);
    }),
);

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

async function launch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-e2e-security-'));
  const env = { ...process.env, ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 30000 });
  let stderr = '';
  app.process().stderr?.on('data', (chunk) => {
    stderr = (stderr + chunk.toString()).slice(-16000);
  });
  t.after(async () => {
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
    if (stderr.includes('[test-uncaught]')) t.diagnostic(stderr);
    assert(path.resolve(directory).startsWith(path.resolve(os.tmpdir()) + path.sep));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  });
  const shell = await app.firstWindow();
  await shell.waitForFunction(() => Boolean(window.zacro));
  await app.evaluate(({ app }) => {
    process.on('uncaughtException', (error) => {
      console.error('[test-uncaught]', error.stack || error.message);
      app.exit(1);
    });
  });
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const state = () => invoke('state:get');
  const guest = (expression, url) =>
    app.evaluate(
      ({ webContents }, { expression, url }) => {
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        if (!contents) return null;
        return contents.executeJavaScript(expression);
      },
      { expression, url },
    );
  const navigate = async (url) => {
    await invoke('navigate', { url });
    await expect.poll(async () => (await state()).runtime.page.url, { timeout: 15000 }).toBe(url);
    await expect.poll(() => guest('document.readyState', url), { timeout: 15000 }).toBe('complete');
  };
  return { app, shell, directory, invoke, state, guest, navigate };
}

test(
  'popups preserve profile and POST data while sandbox preferences cannot be weakened by page features',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/opener`);
    const original = (await browser.state()).activeTabId;
    await browser.guest(
      'document.cookie = "popupIdentity=personal; path=/"; window.open("/popup", "_blank", "nodeIntegration=yes,contextIsolation=no,sandbox=no") === null',
      `${base}/opener`,
    );
    await expect
      .poll(async () => (await browser.state()).tabs.some((tab) => tab.url === `${base}/popup`), {
        timeout: 15000,
      })
      .toBe(true);
    await expect.poll(() => browser.guest('document.readyState', `${base}/popup`)).toBe('complete');
    assert.match(await browser.guest('document.cookie', `${base}/popup`), /popupIdentity=personal/);
    assert.equal(
      await browser.guest(
        'typeof require + ":" + typeof process + ":" + typeof window.zacro',
        `${base}/popup`,
      ),
      'undefined:undefined:undefined',
    );
    const preferences = await browser.app.evaluate(
      ({ webContents }, url) =>
        webContents
          .getAllWebContents()
          .find((item) => item.getURL() === url)
          .getLastWebPreferences(),
      `${base}/popup`,
    );
    assert.equal(preferences.sandbox, true);
    assert.equal(preferences.nodeIntegration, false);
    assert.equal(preferences.contextIsolation, true);
    assert.equal(preferences.webSecurity, true);
    const popupTab = (await browser.state()).tabs.find((tab) => tab.url === `${base}/popup`);
    await browser.guest('window.close(); undefined', `${base}/popup`).catch(() => {});
    await expect
      .poll(async () => (await browser.state()).tabs.some((tab) => tab.id === popupTab.id))
      .toBe(false);
    await browser.invoke('tab:activate', { id: original });
    await browser.guest('document.getElementById("post").submit(); undefined', `${base}/opener`);
    await expect
      .poll(() => browser.guest('document.getElementById("method").textContent', `${base}/posted`), {
        timeout: 15000,
      })
      .toBe('POST');
    assert.equal(
      await browser.guest('document.getElementById("submitted").textContent', `${base}/posted`),
      'value=retained-body',
    );
  },
);

test(
  'unsafe address schemes and popups are rejected; a non-shell renderer cannot invoke privileged IPC',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/safety`);
    for (const url of [
      'file:///C:/Windows/win.ini',
      'javascript:alert(1)',
      'data:text/html,test',
      'https://user:secret@example.com/',
    ]) {
      await assert.rejects(browser.invoke('navigate', { url }));
    }
    const initialCount = (await browser.state()).tabs.length;
    await browser.guest(
      'window.open("file:///C:/Windows/win.ini"); window.open("data:text/html,test"); undefined',
      `${base}/safety`,
    );
    assert.equal((await browser.state()).tabs.length, initialCount);
    await browser.guest('location.href = "file:///C:/Windows/win.ini"; undefined', `${base}/safety`);
    assert.equal((await browser.state()).runtime.page.url, `${base}/safety`);

    // Give a test-only hostile renderer an IPC capability to exercise the real
    // main-process sender check. No application hook or production preload changes.
    const preload = path.join(browser.directory, 'ipc-probe.cjs');
    await fs.writeFile(
      preload,
      `const { contextBridge, ipcRenderer } = require('electron'); contextBridge.exposeInMainWorld('probe', () => ipcRenderer.invoke('zacro:invoke', 'tab:create', {url:'https://evil.example/'}));`,
    );
    const rejected = await browser.app.evaluate(
      async ({ BrowserWindow }, { preload, url }) => {
        const hostile = new BrowserWindow({
          show: false,
          webPreferences: { preload, sandbox: true, contextIsolation: true, nodeIntegration: false },
        });
        try {
          await hostile.loadURL(url);
          return await hostile.webContents.executeJavaScript(
            'window.probe().then(() => "UNEXPECTED_ALLOW", error => error.message)',
          );
        } finally {
          hostile.destroy();
        }
      },
      { preload, url: `${base}/hostile` },
    );
    assert.match(rejected, /Untrusted browser action/);
    assert.equal((await browser.state()).tabs.length, initialCount);
  },
);

test(
  'unpacked extension content scripts work only in their installed profile and respect disable/remove',
  { timeout: 90000 },
  async (t) => {
    const browser = await launch(t);
    const extensionDirectory = path.join(browser.directory, 'fixture-extension');
    await fs.mkdir(extensionDirectory);
    await fs.writeFile(
      path.join(extensionDirectory, 'manifest.json'),
      JSON.stringify({
        manifest_version: 3,
        name: 'Zacro integration fixture',
        version: '1.0.0',
        content_scripts: [{ matches: ['http://127.0.0.1/*'], js: ['content.js'], run_at: 'document_end' }],
      }),
    );
    await fs.writeFile(
      path.join(extensionDirectory, 'content.js'),
      'document.documentElement.setAttribute("data-zacro-extension", "active");',
    );
    await browser.app.evaluate(({ dialog }, extensionDirectory) => {
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [extensionDirectory] });
      dialog.showMessageBox = async () => ({ response: 1, checkboxChecked: false });
    }, extensionDirectory);
    const extension = await browser.invoke('extension:install');
    assert.equal(extension.enabled, true);
    await browser.navigate(`${base}/extension-personal`);
    await expect
      .poll(() =>
        browser.guest(
          'document.documentElement.getAttribute("data-zacro-extension")',
          `${base}/extension-personal`,
        ),
      )
      .toBe('active');
    await browser.invoke('profile:create', { name: 'Extension-isolated work' });
    await browser.navigate(`${base}/extension-work`);
    assert.equal(
      await browser.guest(
        'document.documentElement.getAttribute("data-zacro-extension")',
        `${base}/extension-work`,
      ),
      null,
    );
    await browser.invoke('space:activate', { id: 'home' });
    await browser.invoke('extension:toggle', { id: extension.id });
    await browser.navigate(`${base}/extension-disabled`);
    assert.equal(
      await browser.guest(
        'document.documentElement.getAttribute("data-zacro-extension")',
        `${base}/extension-disabled`,
      ),
      null,
    );
    await browser.invoke('extension:toggle', { id: extension.id });
    await browser.navigate(`${base}/extension-enabled`);
    await expect
      .poll(() =>
        browser.guest(
          'document.documentElement.getAttribute("data-zacro-extension")',
          `${base}/extension-enabled`,
        ),
      )
      .toBe('active');
    await browser.invoke('extension:remove', { id: extension.id });
    await browser.navigate(`${base}/extension-removed`);
    assert.equal(
      await browser.guest(
        'document.documentElement.getAttribute("data-zacro-extension")',
        `${base}/extension-removed`,
      ),
      null,
    );
    assert.equal((await browser.state()).extensions.length, 0);
    await browser.invoke('profile:create', { name: 'Private extension check', private: true });
    await assert.rejects(browser.invoke('extension:install'), /private profiles/);
  },
);

test(
  'closing a tab honors its unsaved-form warning and the user can choose to stay or leave',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/unsaved`);
    const tabId = (await browser.state()).activeTabId;
    await browser.app.evaluate(({ dialog, webContents }, url) => {
      globalThis.__zacroCloseDecision = 0;
      globalThis.__zacroClosePrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.__zacroClosePrompts++;
        return globalThis.__zacroCloseDecision;
      };
      const guest = webContents.getAllWebContents().find((item) => item.getURL() === url);
      guest.sendInputEvent({ type: 'mouseDown', x: 30, y: 15, button: 'left', clickCount: 1 });
      guest.sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
    }, `${base}/unsaved`);
    await browser.guest(
      'window.addEventListener("beforeunload", event => { event.preventDefault(); event.returnValue = "Unsaved work"; }); undefined',
      `${base}/unsaved`,
    );
    await browser.invoke('tab:close', { id: tabId });
    assert.equal(
      (await browser.state()).tabs.some((tab) => tab.id === tabId),
      true,
    );
    assert.equal(await browser.app.evaluate(() => globalThis.__zacroClosePrompts), 1);
    await browser.app.evaluate(() => {
      globalThis.__zacroCloseDecision = 1;
    });
    await browser.invoke('tab:close', { id: tabId });
    await expect.poll(async () => (await browser.state()).tabs.some((tab) => tab.id === tabId)).toBe(false);
    assert.equal(await browser.app.evaluate(() => globalThis.__zacroClosePrompts), 2);
  },
);

test(
  'typed navigation and returning to New Tab preserve unsaved documents when cancelled',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.app.evaluate(({ dialog }) => {
      globalThis.__zacroNavigateDecision = 0;
      globalThis.__zacroNavigatePrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.__zacroNavigatePrompts++;
        return globalThis.__zacroNavigateDecision;
      };
    });
    for (const [index, destination] of [`${base}/navigation-destination`, 'zacro://newtab'].entries()) {
      const source = `${base}/navigation-unsaved-${index}`;
      await browser.navigate(source);
      const tabId = (await browser.state()).activeTabId;
      await browser.app.evaluate(({ webContents }, url) => {
        globalThis.__zacroNavigateDecision = 0;
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        contents.sendInputEvent({ type: 'mouseDown', x: 30, y: 15, button: 'left', clickCount: 1 });
        contents.sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
      }, source);
      await browser.guest(
        'window.unsavedNavigationMarker = "draft-retained"; window.addEventListener("beforeunload", event => { event.preventDefault(); event.returnValue = "Unsaved work"; }); undefined',
        source,
      );
      await browser.invoke('navigate', { url: destination });
      await expect
        .poll(() => browser.app.evaluate(() => globalThis.__zacroNavigatePrompts))
        .toBe(index * 2 + 1);
      const stayed = await browser.state();
      assert.equal(stayed.activeTabId, tabId);
      assert.equal(stayed.tabs.find((tab) => tab.id === tabId)?.url, source);
      assert.equal(stayed.runtime.page.url, source);
      assert.equal(await browser.guest('window.unsavedNavigationMarker', source), 'draft-retained');
      await browser.app.evaluate(() => {
        globalThis.__zacroNavigateDecision = 1;
      });
      await browser.invoke('navigate', { url: destination });
      await expect
        .poll(() => browser.app.evaluate(() => globalThis.__zacroNavigatePrompts))
        .toBe(index * 2 + 2);
      await expect
        .poll(async () => (await browser.state()).tabs.find((tab) => tab.id === tabId)?.url)
        .toBe(destination);
      if (destination !== 'zacro://newtab') {
        await expect.poll(async () => (await browser.state()).runtime.page.url).toBe(destination);
      }
      assert.equal((await browser.state()).activeTabId, tabId);
      assert.equal(await browser.guest('window.unsavedNavigationMarker', source), null);
    }
  },
);

test(
  'unsaved Peek previews survive cancelled tab, Space, and preview transitions',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/peek-parent`);
    const parentTab = (await browser.state()).activeTabId;
    const otherSpace = await browser.invoke('space:create', { name: 'Peek transition destination' });
    await browser.invoke('tab:activate', { id: parentTab });
    await browser.app.evaluate(({ dialog }) => {
      globalThis.__zacroPeekDecision = 0;
      globalThis.__zacroPeekPrompts = 0;
      dialog.showMessageBoxSync = () => {
        globalThis.__zacroPeekPrompts++;
        return globalThis.__zacroPeekDecision;
      };
    });

    const transitions = [
      ['tab:create', { url: `${base}/peek-created-tab` }],
      ['space:activate', { id: otherSpace.id }],
      ['peek:open', { url: `${base}/peek-replacement` }],
    ];
    for (const [index, [action, payload]] of transitions.entries()) {
      await browser.invoke('tab:activate', { id: parentTab });
      const previewURL = `${base}/unsaved-preview-${index}`;
      await browser.invoke('peek:open', { url: previewURL });
      await expect.poll(() => browser.guest('document.readyState', previewURL)).toBe('complete');
      await browser.app.evaluate(({ webContents }, url) => {
        globalThis.__zacroPeekDecision = 0;
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        contents.sendInputEvent({ type: 'mouseDown', x: 30, y: 15, button: 'left', clickCount: 1 });
        contents.sendInputEvent({ type: 'mouseUp', x: 30, y: 15, button: 'left', clickCount: 1 });
      }, previewURL);
      await browser.guest(
        'window.unsavedPreviewMarker = "draft-preserved"; window.addEventListener("beforeunload", event => { event.preventDefault(); event.returnValue = "Unsaved preview work"; }); undefined',
        previewURL,
      );
      const before = await browser.state();
      await browser.invoke(action, payload);
      const stayed = await browser.state();
      assert.equal(stayed.runtime.peek?.url, previewURL, `${action}: Stay preserves the preview`);
      assert.equal(stayed.activeSpaceId, before.activeSpaceId, `${action}: Stay preserves the Space`);
      assert.equal(stayed.activeTabId, before.activeTabId, `${action}: Stay preserves the tab`);
      assert.deepEqual(
        stayed.tabs.map((tab) => tab.id),
        before.tabs.map((tab) => tab.id),
      );
      assert.equal(await browser.guest('window.unsavedPreviewMarker', previewURL), 'draft-preserved');
      assert.equal(await browser.app.evaluate(() => globalThis.__zacroPeekPrompts), index * 2 + 1);

      await browser.app.evaluate(() => {
        globalThis.__zacroPeekDecision = 1;
      });
      await browser.invoke(action, payload);
      const left = await browser.state();
      assert.equal(await browser.app.evaluate(() => globalThis.__zacroPeekPrompts), index * 2 + 2);
      assert.equal(await browser.guest('window.unsavedPreviewMarker', previewURL), null);
      if (action === 'tab:create') {
        assert.equal(left.runtime.peek, null);
        assert.equal(left.tabs.length, before.tabs.length + 1);
        assert.equal(left.tabs.find((tab) => tab.id === left.activeTabId)?.url, payload.url);
      } else if (action === 'space:activate') {
        assert.equal(left.runtime.peek, null);
        assert.equal(left.activeSpaceId, otherSpace.id);
      } else {
        await expect.poll(async () => (await browser.state()).runtime.peek?.url).toBe(payload.url);
        assert.deepEqual(
          left.tabs.map((tab) => tab.id),
          before.tabs.map((tab) => tab.id),
        );
      }
    }
  },
);

test(
  'page AI extraction resists page prototype overrides and excludes forms and hidden text without provider calls',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.navigate(`${base}/page-context`);
    const currentTab = (await browser.state()).activeTabId;
    await browser.guest(
      `document.body.insertAdjacentHTML('beforeend', '<p>Visible policy evidence to share.</p><input type="password" value="secret-password"><textarea>secret-draft</textarea><div contenteditable>secret-edit</div><div style="display:none">secret-hidden</div>'); Element.prototype.cloneNode = function() { const forged = document.createElement('div'); forged.textContent = 'stolen-password'; return forged; }; window.getComputedStyle = () => ({display:'block', visibility:'visible'}); undefined`,
      `${base}/page-context`,
    );
    await browser.app.evaluate(({ app }) => {
      const requireModule = process
        .getBuiltinModule('module')
        .createRequire(app.getAppPath() + '/package.json');
      const { AIService } = requireModule('./src/main/ai.cjs');
      const { CodexClient } = requireModule('./src/main/codex.cjs');
      CodexClient.prototype.status = () => ({
        available: true,
        configured: true,
        account: { email: 'fixture@example.test', planType: 'plus' },
        models: [{ id: 'fixture-model', name: 'Fixture' }],
        loginPending: false,
      });
      CodexClient.prototype.refresh = async function () {
        return this.status();
      };
      CodexClient.prototype.logout = async function () {
        return {};
      };
      AIService.prototype.requestProvider = async function (messages, research) {
        globalThis.__zacroCapturedAI = { messages, research };
        return {
          answer: 'The shared document includes evidence [1:1].',
          citations: [],
          sources: [],
          usage: { inputTokens: 20, outputTokens: 10 },
          historyContent: 'The shared document includes evidence [1:1].',
        };
      };
    });
    await browser.invoke('ai:configure', { model: 'fixture-model' });
    const count = (await browser.state()).tabs.length;
    const answer = await browser.invoke('ai:ask', {
      question: 'Explain the visible evidence.',
      tabIds: [currentTab],
    });
    const captured = await browser.app.evaluate(() => globalThis.__zacroCapturedAI);
    const serialized = JSON.stringify(captured.messages);
    assert.equal(captured.research, false);
    assert.match(serialized, /Visible policy evidence to share/);
    for (const secret of [
      'secret-password',
      'secret-draft',
      'secret-edit',
      'secret-hidden',
      'stolen-password',
    ])
      assert.ok(!serialized.includes(secret), `${secret} must not be shared`);
    assert.equal(answer.mode, 'pages');
    assert.equal(answer.sources.length, 1);
    assert.equal((await browser.state()).tabs.length, count, 'Answering does not open source tabs');
    await browser.invoke('ai:open-sources');
    assert.equal(
      (await browser.state()).tabs.length,
      count,
      'Explicit source opening reuses the existing source tab',
    );
    await browser.invoke('ai:disconnect');
  },
);

test(
  'an explicitly selected remote PDF is parsed locally and cited by physical page without raw-file uploads',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.invoke('navigate', { url: `${base}/document.pdf` });
    await expect
      .poll(async () => (await browser.state()).runtime.page.url, { timeout: 15000 })
      .toBe(`${base}/document.pdf`);
    await browser.app.evaluate(({ app }) => {
      const requireModule = process
        .getBuiltinModule('module')
        .createRequire(app.getAppPath() + '/package.json');
      const { AIService } = requireModule('./src/main/ai.cjs');
      const { CodexClient } = requireModule('./src/main/codex.cjs');
      CodexClient.prototype.status = () => ({
        available: true,
        configured: true,
        account: { email: 'fixture@example.test', planType: 'plus' },
        models: [{ id: 'fixture-model', name: 'Fixture' }],
        loginPending: false,
      });
      CodexClient.prototype.refresh = async function () {
        return this.status();
      };
      CodexClient.prototype.logout = async function () {
        return {};
      };
      AIService.prototype.requestProvider = async function (messages, research) {
        globalThis.__zacroCapturedPDF = { messages, research };
        return {
          answer: 'The cancellation fee is twenty dollars [1:1].',
          citations: [],
          sources: [],
          usage: { inputTokens: 20, outputTokens: 10 },
          historyContent: 'The cancellation fee is twenty dollars [1:1].',
        };
      };
    });
    await browser.invoke('ai:configure', { model: 'fixture-model' });
    const answer = await browser.invoke('ai:ask', {
      question: 'What is the cancellation fee?',
      usePageContext: true,
    });
    const captured = await browser.app.evaluate(() => globalThis.__zacroCapturedPDF);
    assert.match(JSON.stringify(captured.messages), /remote PDF cancellation fee/);
    assert.ok(!JSON.stringify(captured.messages).includes('%PDF-'));
    assert.equal(captured.research, false);
    assert.equal(answer.citations[0].pageNumber, 1);
    assert.equal(answer.citations[0].url, `${base}/document.pdf#page=1`);
    await browser.invoke('ai:disconnect');
  },
);

test(
  'HTTP authentication is scoped to its pending request and credentials stay out of browser state',
  { timeout: 60000 },
  async (t) => {
    const browser = await launch(t);
    await browser.shell.evaluate(() =>
      window.zacro.onEvent((event) => {
        if (event.type === 'auth:request') window.__zacroTestAuth = event;
      }),
    );
    await browser.invoke('navigate', { url: `${base}/auth` });
    await expect
      .poll(() => browser.shell.evaluate(() => Boolean(window.__zacroTestAuth?.id)), { timeout: 15000 })
      .toBe(true);
    const request = await browser.shell.evaluate(() => window.__zacroTestAuth);
    await browser.invoke('auth:respond', {
      id: request.id,
      username: 'test-user',
      password: 'zacro-test-password',
    });
    await expect
      .poll(() => browser.guest('document.title', `${base}/auth`), { timeout: 15000 })
      .toBe('Security fixture');
    assert.ok(!JSON.stringify(await browser.state()).includes('zacro-test-password'));
    await assert.rejects(
      browser.invoke('auth:respond', {
        id: request.id,
        username: 'test-user',
        password: 'zacro-test-password',
      }),
    );
    const disk = await fs
      .readFile(path.join(browser.directory, 'browser-state.json'), 'utf8')
      .catch(() => '');
    assert.ok(!disk.includes('zacro-test-password'));
  },
);

for (const transition of ['tab', 'profile']) {
  test(
    `a pending site permission is denied after its active ${transition} changes`,
    { timeout: 45000 },
    async (t) => {
      const browser = await launch(t);
      const url = `${base}/permission-${transition}`;
      await browser.navigate(url);
      await browser.app.evaluate(({ dialog }) => {
        globalThis.__permissionDecision = null;
        dialog.showMessageBox = () =>
          new Promise((resolve) => {
            globalThis.__permissionDecision = resolve;
          });
      });
      await browser.app.evaluate(({ webContents }, url) => {
        const contents = webContents.getAllWebContents().find((item) => item.getURL() === url);
        return contents.executeJavaScript(
          'Notification.requestPermission().then(value => { window.__permissionResult = value; }, error => { window.__permissionResult = "ERROR:" + error.name; }); undefined',
          true,
        );
      }, url);
      await expect
        .poll(() => browser.app.evaluate(() => typeof globalThis.__permissionDecision))
        .toBe('function');
      if (transition === 'tab') {
        await browser.invoke('tab:create', { url: `${base}/permission-destination` });
      } else {
        const profile = await browser.invoke('profile:create', { name: 'Permission destination' });
        const space = (await browser.state()).spaces.find((item) => item.profileId === profile.id);
        await browser.invoke('space:activate', { id: space.id });
      }
      await browser.app.evaluate(() => {
        globalThis.__permissionDecision({ response: 1, checkboxChecked: true });
      });
      await expect.poll(() => browser.guest('window.__permissionResult', url)).toBe('denied');
      assert.deepEqual(
        (await browser.state()).permissions,
        [],
        'A stale Allow choice must not persist a permission',
      );
    },
  );
}
