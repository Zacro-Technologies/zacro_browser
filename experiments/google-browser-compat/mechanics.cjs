'use strict';

// AUTOMATED LOCAL FIXTURES ONLY. This launcher is deliberately separate from
// cli.cjs/manual profiles. Never pass an account URL or reuse its profile paths.
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { ensureRoot, resolveRoot, assertContained, toolkitRoot } = require('./lib/paths.cjs');
const { prepareRuntime } = require('./lib/artifacts.cjs');
const { manualEnvironment } = require('./cli.cjs');
const execFileAsync = promisify(execFile);
const EXTENSION_ID = 'fimeokmnmdjlnadhinihgiaimdfinehg';
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const assert = (value, code) => {
  if (!value) throw new Error(code);
};

function options(argv) {
  const result = { engine: 'chromium', workspace: false };
  const seen = new Set();
  for (let index = 0; index < argv.length; index++) {
    const key = argv[index].replace(/^--/, '');
    assert(
      argv[index].startsWith('--') && ['root', 'engine', 'workspace'].includes(key) && !seen.has(key),
      'invalid-options',
    );
    seen.add(key);
    if (key === 'workspace') result.workspace = true;
    else {
      assert(argv[index + 1] && !argv[index + 1].startsWith('--'), 'missing-option');
      result[key] = argv[++index];
    }
  }
  assert(
    ['chromium', 'brave', 'zacro-native'].includes(result.engine) &&
      (!result.workspace || result.engine === 'chromium'),
    'invalid-engine-configuration',
  );
  return result;
}

async function createFixtureDirectory(root, metadata, id = crypto.randomUUID()) {
  const configurations = {
    chromium: ['engine-only', 'workspace'],
    brave: ['reference'],
    'zacro-native': ['native-branded'],
  };
  assert(
    configurations[metadata.engine]?.includes(metadata.configuration) &&
      ['win32-x64', 'darwin-arm64', 'darwin-x64'].includes(metadata.platform) &&
      /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/u.test(id),
    'invalid-fixture-identity',
  );
  await ensureRoot(root, { create: false });
  const parent = await assertContained(root, path.join(root, 'fixtures'));
  await fs.mkdir(parent, { recursive: true });
  assert(!(await fs.lstat(parent)).isSymbolicLink(), 'fixture-parent-must-not-be-link');
  const directory = await assertContained(root, path.join(parent, `${metadata.engine}-${id}`));
  // mkdir without recursive is exclusive. An existing directory, including an
  // improbable random-name collision, can never become an automated profile.
  await fs.mkdir(directory);
  await fs.writeFile(
    path.join(directory, '.fixture-owner.json'),
    JSON.stringify({
      kind: 'local-browser-mechanics',
      automation: true,
      platform: metadata.platform,
      engine: metadata.engine,
      configuration: metadata.configuration,
    }),
    { flag: 'wx' },
  );
  return directory;
}

function fixtureRequestAllowed(value, origins, workspace = false) {
  try {
    const url = new URL(value);
    if (url.username || url.password) return false;
    return (
      (url.protocol === 'http:' && url.hostname === '127.0.0.1' && origins.has(url.origin)) ||
      (workspace && url.protocol === 'chrome-extension:' && url.hostname === EXTENSION_ID)
    );
  } catch {
    return false;
  }
}

async function until(callback, code, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      const value = await callback();
      if (value) return value;
    } catch {}
    await delay(100);
  }
  throw new Error(code);
}

async function waitBounded(promise, milliseconds) {
  let timer;
  try {
    await Promise.race([promise, new Promise((resolve) => (timer = setTimeout(resolve, milliseconds)))]);
  } finally {
    clearTimeout(timer);
  }
}

async function fixtureTransport(endpoint, { Socket = WebSocket, timeout = 5000, now = Date.now } = {}) {
  const address = new URL(endpoint);
  assert(
    address.protocol === 'ws:' &&
      address.hostname === '127.0.0.1' &&
      Number(address.port) > 0 &&
      !address.username &&
      !address.password &&
      !address.search &&
      !address.hash &&
      /^\/devtools\/browser\/[a-zA-Z0-9-]+$/.test(address.pathname),
    'unexpected-fixture-debug-endpoint',
  );
  const socket = new Socket(address.href);
  const pending = new Map();
  let sent = 0,
    answered = 0,
    opened = false,
    closed = false;
  const failed = [];
  const key = (message) => `${message.sessionId || ''}:${message.id}`;
  const transport = {
    send(message) {
      // Keep only protocol method names and timings. Never retain parameters,
      // results, event payloads, raw errors, page URLs or request bodies.
      const method = /^[A-Z][A-Za-z0-9]+\.[a-z][A-Za-z0-9]+$/.test(message.method || '')
        ? message.method
        : 'Unknown.command';
      pending.set(key(message), { method, started: now() });
      sent++;
      socket.send(JSON.stringify(message));
    },
    close() {
      socket.close();
    },
    summary() {
      const counts = new Map();
      for (const { method, started } of pending.values()) {
        const entry = counts.get(method) || { method, count: 0, oldestMs: 0 };
        entry.count++;
        entry.oldestMs = Math.max(entry.oldestMs, Math.max(0, now() - started));
        counts.set(method, entry);
      }
      return { opened, closed, sent, answered, pending: [...counts.values()], failed: [...failed] };
    },
  };
  socket.addEventListener('message', ({ data }) => {
    let message;
    try {
      message = JSON.parse(data);
    } catch {
      socket.close();
      return;
    }
    if (message.id !== undefined) {
      const entry = pending.get(key(message));
      if (entry) {
        pending.delete(key(message));
        answered++;
        if (message.error && failed.length < 20)
          failed.push({
            method: entry.method,
            code: Number.isInteger(message.error.code) ? message.error.code : null,
          });
      }
    }
    transport.onmessage?.(message);
  });
  socket.addEventListener('close', () => {
    if (!closed) {
      closed = true;
      transport.onclose?.();
    }
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('fixture-websocket-timeout'));
    }, timeout);
    socket.addEventListener(
      'open',
      () => {
        clearTimeout(timer);
        opened = true;
        resolve();
      },
      { once: true },
    );
    socket.addEventListener(
      'error',
      () => {
        clearTimeout(timer);
        reject(new Error('fixture-websocket-failed'));
      },
      { once: true },
    );
  });
  return transport;
}

async function closeFixtureSession(
  current,
  { platform = process.platform, execute = execFileAsync, gracefulMs = 5000, terminateMs = 3000 } = {},
) {
  // CDPSession.send has no timeout. Start graceful shutdown without letting a
  // hung connection prevent the deadline or owned-child termination fallback.
  void Promise.resolve()
    .then(() => current.cdp?.send('Browser.close'))
    .catch(() => {})
    .then(() => current.browser?.close())
    .catch(() => {});
  await waitBounded(current.exited, gracefulMs);
  const child = current.child;
  if (child.exitCode !== null || child.signalCode !== null || !Number.isInteger(child.pid) || child.pid <= 0)
    return;
  // Never enumerate browser processes: this is only the child spawned by this
  // fixture. A failed spawn has no PID and is never passed to taskkill.
  const termination = Promise.resolve()
    .then(() =>
      platform === 'win32'
        ? execute('taskkill', ['/PID', String(child.pid), '/T', '/F'], {
            windowsHide: true,
            timeout: terminateMs,
          })
        : child.kill('SIGKILL'),
    )
    .catch(() => {});
  await waitBounded(Promise.all([termination, current.exited]), terminateMs);
  assert(child.exitCode !== null || child.signalCode !== null, 'fixture-child-did-not-exit');
}

function installFixtureSignals(cleanup, owner = process) {
  let stopping = false;
  let finished;
  const stop = (code) => {
    if (stopping) return;
    stopping = true;
    owner.exitCode = code;
    finished = Promise.resolve()
      .then(cleanup)
      .catch(() => {})
      .then(() => owner.exit(code));
  };
  const interrupt = () => stop(130);
  const terminate = () => stop(143);
  owner.on('SIGINT', interrupt);
  owner.on('SIGTERM', terminate);
  return {
    get stopping() {
      return stopping;
    },
    get finished() {
      return finished;
    },
    dispose() {
      owner.removeListener('SIGINT', interrupt);
      owner.removeListener('SIGTERM', terminate);
    },
  };
}

async function fixtures() {
  let popupTarget = '',
    postPreserved = false,
    readyDocuments = 0,
    requestedDocuments = 0;
  const primary = http.createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    if (request.url === '/ready') {
      readyDocuments++;
      response.end('ready');
      return;
    }
    if (request.url === '/set') {
      response.setHeader(
        'Set-Cookie',
        'zacro_local_fixture=present; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax',
      );
      response.end('ok');
      return;
    }
    if (request.url === '/signout') {
      response.setHeader('Set-Cookie', 'zacro_local_fixture=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax');
      response.end('ok');
      return;
    }
    if (request.url === '/status') {
      response.setHeader('Content-Type', 'application/json');
      response.end(
        JSON.stringify({
          signedIn: /(?:^|;\s*)zacro_local_fixture=present(?:;|$)/.test(request.headers.cookie || ''),
        }),
      );
      return;
    }
    if (request.url === '/download') {
      response.writeHead(200, {
        'Content-Type': 'text/plain',
        'Content-Disposition': 'attachment; filename="fixture.txt"',
      });
      response.end('Local browser fixture.');
      return;
    }
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    requestedDocuments++;
    response.end(`<!doctype html><title>${request.url === '/second' ? 'Secondary fixture' : 'Engine fixture'}</title>
      <meta name="viewport" content="width=device-width"><style>body{font:16px system-ui;padding:32px;background:#f5f1f2;color:#30252b}button,a,input{margin:8px}</style>
      <h1>Native browser mechanics</h1><p>Local fixture. No Google account or credentials are used.</p>
      <input id="draft" aria-label="Fixture draft"><a id="second" href="/second" target="_blank">Open another tab</a>
      <form id="post" action="${popupTarget}" method="post" target="fixture-popup"><input type="hidden" name="fixture" value="fixed-local-payload"><button id="popup">Open local popup</button></form>
      <a id="download" href="/download">Download fixture</a>
      <script>window.fixtureCallback=false;window.addEventListener('message',event=>{if(event.origin===${JSON.stringify(popupTarget ? new URL(popupTarget).origin : '')}&&event.data==='local-fixture-complete')window.fixtureCallback=true});fetch('/ready',{method:'POST'});</script>`);
  });
  const identity = http.createServer(async (request, response) => {
    // Only a fixed nonsensitive local fixture payload is inspected in memory.
    // Nothing from request headers/body is logged, returned or written to disk.
    let body = '';
    for await (const chunk of request) {
      if (body.length < 1024) body += chunk.toString();
    }
    postPreserved = request.method === 'POST' && body === 'fixture=fixed-local-payload';
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      '<!doctype html><title>Local callback</title><h1>Local callback</h1><button id="return">Return to opener</button>',
    );
  });
  for (const server of [primary, identity])
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${primary.address().port}`;
  const identityOrigin = `http://127.0.0.1:${identity.address().port}`;
  popupTarget = `${identityOrigin}/callback`;
  return {
    origin,
    identityOrigin,
    readyDocuments: () => readyDocuments,
    requestedDocuments: () => requestedDocuments,
    postPreserved: () => postPreserved,
    close: () =>
      Promise.all(
        [primary, identity].map(
          (server) =>
            new Promise((resolve) => {
              server.closeAllConnections();
              server.close(resolve);
            }),
        ),
      ),
  };
}

async function run(argv) {
  const args = options(argv);
  // Raw Playwright protocol logging would bypass the bounded metadata-only
  // transport summary. Refuse it before loading Playwright's logger.
  assert(!process.env.DEBUG && !process.env.PWDEBUG, 'fixture-debug-logging-disallowed');
  const { chromium } = require('@playwright/test');
  const platform = `${process.platform}-${process.arch}`;
  assert(
    ['win32-x64', 'darwin-arm64', ...(args.engine === 'zacro-native' ? ['darwin-x64'] : [])].includes(
      platform,
    ),
    'unsupported-native-platform',
  );
  const root = await ensureRoot(resolveRoot(args.root));
  let runtime;
  if (args.engine === 'zacro-native') {
    const native = await require('./build/native-build.cjs').verifiedBuild({ root, platform });
    runtime = {
      executable: native.executable,
      artifact: {
        sourceRevision: native.receipt.sourceRevision,
        sha256: null,
        runtimeSha256: native.receipt.runtimeSha256,
      },
      nativeReceipt: native.receipt,
    };
  } else runtime = await prepareRuntime({ root, engine: args.engine, platform, fetch: false });
  const configuration =
    args.engine === 'zacro-native'
      ? 'native-branded'
      : args.engine === 'brave'
        ? 'reference'
        : args.workspace
          ? 'workspace'
          : 'engine-only';
  const directory = await createFixtureDirectory(root, { platform, engine: args.engine, configuration });
  const fixture = await fixtures();
  const checks = [];
  let session,
    stage = 'launch',
    version,
    protocolDiagnostics,
    fixtureRendering,
    nativeStartup;
  const record = (name) => checks.push({ name, result: 'passed' });

  let closing;
  async function close() {
    if (!session) return closing;
    const current = session;
    session = null;
    const operation = closeFixtureSession(current);
    closing = operation;
    try {
      await operation;
    } finally {
      if (closing === operation) closing = null;
    }
  }
  let cleanupPromise;
  const cleanup = () =>
    (cleanupPromise ||= (async () => {
      try {
        await close();
      } finally {
        await fixture.close();
      }
    })());
  const signals = installFixtureSignals(cleanup);

  async function launch(role, incognito = false) {
    await close();
    stage = 'native-fixture-launch';
    const profile = await assertContained(directory, path.join(directory, role));
    await fs.mkdir(profile, { recursive: true });
    const portFile = path.join(profile, 'DevToolsActivePort');
    await fs.unlink(portFile).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    });
    const env = manualEnvironment();
    const flags = [
      `--user-data-dir=${profile}`,
      '--remote-debugging-port=0',
      '--no-first-run',
      '--no-default-browser-check',
      '--profile-directory=Default',
    ];
    if (incognito) flags.push('--incognito');
    if (args.workspace && !incognito) flags.push(`--load-extension=${path.join(toolkitRoot, 'extension')}`);
    flags.push(`${fixture.origin}/`);
    assert(!signals.stopping, 'fixture-interrupted');
    const readyBeforeLaunch = fixture.readyDocuments();
    const requestedBeforeLaunch = fixture.requestedDocuments();
    const child = spawn(runtime.executable, flags, { env, stdio: 'ignore', windowsHide: false });
    const exited = new Promise((resolve) => {
      child.once('exit', resolve);
      child.once('error', resolve);
    });
    session = { child, exited };
    const port = await until(
      async () => {
        if (child.exitCode !== null) throw new Error('browser-exited');
        const raw = await fs.readFile(portFile, 'utf8');
        const candidate = Number(raw.split(/\r?\n/)[0]);
        return Number.isInteger(candidate) && candidate > 0 && candidate < 65536 ? candidate : null;
      },
      'fixture-debug-endpoint-unavailable',
      30000,
    );
    stage = 'fixture-debug-protocol';
    const metadata = await fetch(`http://127.0.0.1:${port}/json/version`, {
      signal: AbortSignal.timeout(5000),
    }).then((response) => response.json());
    version = { product: metadata.Browser };
    const endpoint = new URL(metadata.webSocketDebuggerUrl);
    assert(
      endpoint.protocol === 'ws:' && endpoint.hostname === '127.0.0.1' && endpoint.port === String(port),
      'unexpected-fixture-debug-endpoint',
    );
    // Let this known local document commit before CDP attaches to its startup
    // target. This readiness probe observes only our fixture's fixed signal.
    stage = 'native-fixture-document-ready';
    await until(
      () => {
        nativeStartup = {
          documentRequested: fixture.requestedDocuments() > requestedBeforeLaunch,
          scriptReady: fixture.readyDocuments() > readyBeforeLaunch,
        };
        return nativeStartup.scriptReady;
      },
      'fixture-document-did-not-start',
      15000,
    );
    stage = 'connect-fixture-cdp';
    const transport = await fixtureTransport(endpoint.href);
    session.transport = transport;
    // Standard Playwright focus emulation keeps fixture RAF/actionability alive
    // when the OS occludes this automated window. Manual launches never use it.
    const browser = await chromium.connectOverCDP(transport, { timeout: 30000 });
    session.browser = browser;
    session.cdp = await browser.newBrowserCDPSession();
    version = await session.cdp.send('Browser.getVersion');
    stage = 'native-fixture-page';
    const context = browser.contexts()[0];
    const allowed = new Set([fixture.origin, fixture.identityOrigin]);
    await context.route('**/*', (route) => {
      return fixtureRequestAllowed(route.request().url(), allowed, args.workspace && !incognito)
        ? route.continue()
        : route.abort();
    });
    // Use the real startup target, especially in --incognito mode. Creating a
    // new CDP default-context tab could accidentally test a regular window.
    const page = await until(
      () => context.pages().find((candidate) => candidate.url().startsWith(fixture.origin)),
      'native-startup-target-unavailable',
    );
    await page.waitForSelector('#draft');
    await page.bringToFront();
    fixtureRendering = await page.evaluate(async () => ({
      visibility: document.visibilityState,
      focused: document.hasFocus(),
      animationFrame: await Promise.race([
        new Promise((resolve) => requestAnimationFrame(() => resolve(true))),
        new Promise((resolve) => setTimeout(() => resolve(false), 1500)),
      ]),
    }));
    session.context = context;
    session.page = page;
    return session;
  }
  const signedIn = (page) =>
    page.evaluate(() =>
      fetch('/status')
        .then((response) => response.json())
        .then((status) => status.signedIn),
    );
  const setSession = (page) => page.evaluate(() => fetch('/set').then(() => true));
  let succeeded = false;
  try {
    let current = await launch('regular-a');
    record('native-full-browser-launch');
    if (args.engine === 'zacro-native') {
      stage = 'native-zacro-identity';
      const identity = await current.page.evaluate(() => ({
        ua: navigator.userAgent,
        brands: navigator.userAgentData?.brands?.map((item) => item.brand) || [],
      }));
      assert(identity.ua.includes('ZacroPrototype/156.'), 'zacro-user-agent-product-missing');
      assert(identity.brands.includes('Zacro Prototype'), 'zacro-client-hints-product-missing');
      record('native-zacro-user-agent-and-client-hints');
    }
    stage = 'regular-fixture-session';
    assert(!(await signedIn(current.page)), 'new-profile-not-empty');
    await setSession(current.page);
    assert(await signedIn(current.page), 'fixture-session-not-established');
    assert(
      await current.page.evaluate(() => !document.cookie.includes('zacro_local_fixture')),
      'httponly-boundary',
    );
    record('local-http-only-session');

    stage = 'native-tabs';
    const [secondary] = await Promise.all([
      current.context.waitForEvent('page', { timeout: 15000 }),
      current.page.locator('#second').click({ timeout: 10000 }),
    ]);
    await secondary.waitForURL(`${fixture.origin}/second`);
    assert(
      current.context.pages().filter((page) => page.url().startsWith(fixture.origin)).length === 2,
      'native-tab-count',
    );
    record('native-tab-navigation');

    stage = 'popup-opener-post';
    await current.page.locator('#draft').fill('Local fixture draft');
    const [popup] = await Promise.all([
      current.page.waitForEvent('popup'),
      current.page.locator('#popup').click(),
    ]);
    await popup.waitForSelector('#return');
    assert(fixture.postPreserved(), 'fixture-post-not-preserved');
    assert(await popup.evaluate(() => Boolean(window.opener)), 'opener-not-preserved');
    await popup.evaluate((origin) => {
      window.opener.postMessage('local-fixture-complete', origin);
      window.close();
    }, fixture.origin);
    await current.page.waitForFunction(() => window.fixtureCallback === true);
    assert(
      (await current.page.locator('#draft').inputValue()) === 'Local fixture draft',
      'opener-document-replaced',
    );
    record('cross-origin-popup-post-and-opener');

    stage = 'native-download';
    const downloadPath = await assertContained(directory, path.join(directory, 'downloads'));
    await fs.mkdir(downloadPath, { recursive: true });
    await current.cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath });
    await current.page.locator('#download').click();
    assert(
      await until(
        async () =>
          (await fs.readFile(path.join(downloadPath, 'fixture.txt'), 'utf8')) === 'Local browser fixture.',
        'fixture-download-unavailable',
      ),
      'download-content-mismatch',
    );
    record('native-download-to-owned-fixture-directory');

    if (args.workspace) {
      stage = 'workspace-native-integration';
      const panel = await current.context.newPage();
      await panel.goto(`chrome-extension://${EXTENSION_ID}/panel.html`);
      await panel.locator('#tab-list[aria-busy="false"]').waitFor();
      await panel.getByRole('button', { name: 'Pin Engine fixture', exact: true }).click();
      await panel.getByRole('button', { name: 'Unpin Engine fixture', exact: true }).waitFor();
      assert(
        await panel.evaluate(
          async (origin) =>
            (await chrome.tabs.query({ currentWindow: true })).some(
              (tab) => tab.url === `${origin}/` && tab.pinned,
            ),
          fixture.origin,
        ),
        'workspace-native-pin',
      );
      await panel.locator('#new-workspace').click();
      await panel.locator('#workspace-name').fill('Fixture workspace');
      await panel.locator('#starting-tab').selectOption({ label: 'Secondary fixture' });
      await panel.locator('#save-workspace').click();
      await panel.locator('#workspace-dialog').waitFor({ state: 'hidden' });
      assert(
        await panel.evaluate(async () =>
          (await chrome.tabGroups.query({ windowId: (await chrome.windows.getCurrent()).id })).some(
            (group) => group.title === 'Fixture workspace',
          ),
        ),
        'workspace-native-group',
      );
      await panel.locator('#appearance').click();
      const stored = await panel.evaluate(() => chrome.storage.local.get(null));
      assert(
        Object.keys(stored).length === 1 &&
          Object.keys(stored)[0] === 'zacroWorkspacePreferences' &&
          Object.keys(stored.zacroWorkspacePreferences).join() === 'appearance',
        'workspace-unexpected-persistence',
      );
      record('workspace-native-pins-groups-and-preference-only-storage');
    }

    stage = 'regular-restart-and-signout';
    current = await launch('regular-a');
    assert(await signedIn(current.page), 'regular-restart-lost-session');
    record('regular-profile-session-restart');
    await current.page.evaluate(() => fetch('/signout'));
    assert(!(await signedIn(current.page)), 'local-signout-failed');
    current = await launch('regular-a');
    assert(!(await signedIn(current.page)), 'local-signout-reversed-after-restart');
    record('local-signout-persists-after-restart');

    stage = 'two-regular-profiles';
    current = await launch('regular-b');
    assert(!(await signedIn(current.page)), 'regular-profiles-shared-session');
    await setSession(current.page);
    current = await launch('regular-a');
    assert(!(await signedIn(current.page)), 'second-profile-modified-first');
    record('two-regular-profile-isolation');

    stage = 'private-session-cleanup';
    current = await launch('private', true);
    assert(!(await signedIn(current.page)), 'private-profile-inherited-session');
    await setSession(current.page);
    assert(await signedIn(current.page), 'private-fixture-session-failed');
    current = await launch('private', true);
    assert(!(await signedIn(current.page)), 'private-session-survived-close');
    record('native-incognito-session-cleanup');
    succeeded = true;
  } catch (error) {
    protocolDiagnostics = session?.transport?.summary();
    checks.push({
      name: stage,
      result: 'failed',
      errorClass: ['Error', 'TimeoutError'].includes(error.name) ? error.name : 'FixtureError',
      code: /^[a-z][a-z0-9-]{1,80}$/.test(error.message || '') ? error.message : 'native-operation-failed',
      ...((error.message || '').includes('waiting for element to be visible, enabled and stable') &&
      !(error.message || '').includes('element is visible, enabled and stable')
        ? { phase: 'waiting-for-actionability' }
        : {}),
    });
  } finally {
    try {
      await cleanup();
    } finally {
      signals.dispose();
    }
  }
  const report = {
    schemaVersion: 1,
    time: new Date().toISOString(),
    platform,
    osRelease: os.release(),
    engine: args.engine,
    configuration,
    sourceRevision: runtime.artifact.sourceRevision,
    archiveSha256: runtime.artifact.sha256,
    ...(runtime.nativeReceipt
      ? {
          sourceBuilt: true,
          runtimeSha256: runtime.artifact.runtimeSha256,
          brandingPatchSha256: runtime.nativeReceipt.brandingPatchSha256,
        }
      : {}),
    observedBrowserProduct: version?.product || null,
    purpose: 'automated local browser mechanics, with CDP; never a live Google test',
    googleAcceptance: 'untested',
    credentialsUsed: false,
    ...(nativeStartup ? { nativeStartup } : {}),
    ...(fixtureRendering ? { fixtureRendering } : {}),
    ...(protocolDiagnostics ? { protocolDiagnostics } : {}),
    passed: succeeded,
    checks,
  };
  const results = await assertContained(root, path.join(root, 'results'));
  await fs.mkdir(results, { recursive: true });
  await fs.writeFile(
    path.join(results, `mechanics-${args.engine}-${platform}-${configuration}.json`),
    `${JSON.stringify(report, null, 2)}\n`,
  );
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!succeeded) process.exitCode = 1;
}

if (require.main === module)
  run(process.argv.slice(2)).catch(() => {
    process.stderr.write('Local mechanics setup failed; no live Google check was performed.\n');
    process.exitCode = 1;
  });
module.exports = {
  options,
  closeFixtureSession,
  installFixtureSignals,
  fixtureTransport,
  createFixtureDirectory,
  fixtureRequestAllowed,
};
