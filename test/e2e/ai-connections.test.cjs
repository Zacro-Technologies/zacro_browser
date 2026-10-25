'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

const DUMMY_KEY = 'zacro-e2e-dummy-key-not-a-real-credential';
const UNSAVED_KEY = 'zacro-e2e-unsaved-key-that-must-not-follow-profiles';
const MODEL = 'fixture-chat-model';
const ANSWER = 'The local fixture answered through the real provider transport.';

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-ai-connections-'));
  const requests = [];
  const errors = [];
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString('utf8');
    requests.push({
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization || '',
      body: raw ? JSON.parse(raw) : null,
    });
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('Cache-Control', 'no-store');
    const local = request.url === '/local/v1/models';
    if (!local && request.headers.authorization !== `Bearer ${DUMMY_KEY}`) {
      response.writeHead(401);
      response.end(JSON.stringify({ error: { message: 'Fixture credential required' } }));
    } else if (request.method === 'GET' && (request.url === '/v1/models' || local)) {
      response.end(JSON.stringify({ data: [{ id: MODEL, object: 'model' }] }));
    } else if (request.method === 'POST' && request.url === '/v1/chat/completions') {
      response.end(
        JSON.stringify({
          id: 'fixture-answer',
          choices: [{ message: { role: 'assistant', content: ANSWER }, finish_reason: 'stop' }],
          usage: { prompt_tokens: 12, completion_tokens: 10, total_tokens: 22 },
        }),
      );
    } else {
      response.writeHead(404);
      response.end(JSON.stringify({ error: { message: 'Unexpected fixture route' } }));
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
  const env = { ...process.env, ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  let app;
  t.after(async () => {
    if (app) await app.close().catch(() => app.process().kill());
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-ai-connections-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, [], 'Provider settings and conversations must not throw renderer errors');
  });
  app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env, timeout: 30000 });
  const shell = await app.firstWindow();
  shell.on('pageerror', (error) => errors.push(error.message));
  await shell.waitForFunction(() => Boolean(window.zacro));
  await expect(shell.locator('#command-input')).toBeFocused();
  await shell.locator('#command-input').press('Escape');
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  const openSection = async (section) => {
    await shell.getByRole('button', { name: 'Library', exact: true }).click();
    const menu = shell.getByRole('dialog', { name: 'Library', exact: true });
    await menu.locator(`[data-key="panel-${section}"]`).click();
    await expect(menu).toHaveCount(0);
  };
  const openConnections = async () => {
    await openSection('settings');
    const disclosure = shell.locator('#ai-settings');
    if (!(await disclosure.evaluate((element) => element.open))) await disclosure.locator('summary').click();
    await expect(shell.locator('#ai-provider')).toBeVisible();
  };
  const chooseProvider = async (provider) => {
    await expect(shell.locator(`#ai-provider option[value="${provider}"]`)).toHaveCount(1);
    await shell.locator('#ai-provider').selectOption(provider);
    await expect.poll(async () => (await invoke('ai:status')).provider).toBe(provider);
    await expect(shell.locator('#ai-provider')).toBeEnabled();
    await expect(shell.locator('#ai-provider')).toHaveValue(provider);
  };
  return { app, shell, invoke, openSection, openConnections, chooseProvider, directory, baseUrl, requests };
}

test(
  'API settings use the real transport, verify without inference and isolate keys from profiles and exports',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t);
    const { shell } = b;
    const initial = await b.invoke('state:get');
    await b.openConnections();
    await b.chooseProvider('compatible');
    await shell.locator('#ai-base-url').fill(b.baseUrl);
    await expect(shell.locator('#ai-api-key')).not.toHaveAttribute('required', '');
    await shell.locator('#ai-base-url').fill('https://api.example.invalid/v1');
    await expect(shell.locator('#ai-api-key')).toHaveAttribute('required', '');
    await shell.locator('#ai-base-url').fill(b.baseUrl);
    await shell.locator('#ai-api-model').fill(MODEL);
    await shell.locator('#ai-api-key').fill(DUMMY_KEY);
    await shell.locator('#ai-key-storage').selectOption('session');
    await shell.getByRole('button', { name: 'Save connection', exact: true }).click();
    await expect(shell.locator('#ai-connection-status')).toHaveText('Key saved');
    await expect(shell.locator('#ai-api-key')).toHaveValue('');
    assert.equal((await b.invoke('ai:status')).credentialStorage, 'session');
    await expect(shell.locator('#ai-settings')).toContainText('Uses your provider’s API billing.');
    assert.equal(b.requests.length, 0, 'Saving configuration must not make an inference or model request');

    await shell.getByRole('button', { name: 'Test connection', exact: true }).click();
    await expect(shell.locator('#ai-settings')).toContainText('Connected. No inference request was made.');
    assert.deepEqual(
      b.requests.map(({ method, url, authorization }) => ({ method, url, authorization })),
      [{ method: 'GET', url: '/v1/models', authorization: `Bearer ${DUMMY_KEY}` }],
    );
    await b.openSection('ai');
    await expect(shell.locator('#ai-context option:checked')).toHaveText('Chat · no page sharing');
    await shell.locator('#ai-question').fill('Reply with the fixture evidence.');
    await shell.locator('#ai-submit').click();
    await expect(shell.locator('.message.assistant .message-content')).toHaveText(ANSWER);
    await expect(shell.locator('#ai-submit')).toHaveAttribute('aria-label', 'Send question');
    assert.equal(b.requests.length, 2, 'One submitted question makes one inference request');
    const answerRequest = b.requests[1];
    assert.equal(answerRequest.method, 'POST');
    assert.equal(answerRequest.url, '/v1/chat/completions');
    assert.equal(answerRequest.authorization, `Bearer ${DUMMY_KEY}`);
    assert.equal(answerRequest.body.model, MODEL);
    assert.equal(answerRequest.body.stream, false);
    assert.equal(answerRequest.body.tools, undefined, 'Custom APIs must not silently request tools');
    assert.match(JSON.stringify(answerRequest.body.messages), /Reply with the fixture evidence/);

    await b.openConnections();
    await shell.locator('#ai-api-key').fill(UNSAVED_KEY);
    await b.chooseProvider('openai');
    await expect(shell.locator('#ai-api-key')).toHaveValue('');
    await expect(shell.locator('#ai-connection-status')).toHaveText('Not connected');
    await expect(shell.locator('#ai-base-url')).toHaveCount(0);
    await b.chooseProvider('compatible');
    await expect(shell.locator('#ai-api-key')).toHaveValue('');
    await expect(shell.locator('#ai-base-url')).toHaveValue(b.baseUrl);
    await expect(shell.locator('#ai-connection-status')).toHaveText('Key saved');

    // A typed, unsaved replacement must disappear on a profile boundary. The
    // original profile keeps its saved session key without revealing it again.
    await shell.locator('#ai-api-key').fill(UNSAVED_KEY);
    const other = await b.invoke('profile:create', { name: 'Independent AI profile' });
    await expect(shell.locator('.space-title')).toHaveText('Independent AI profile');
    await b.chooseProvider('compatible');
    await expect(shell.locator('#ai-api-key')).toHaveValue('');
    await expect(shell.locator('#ai-base-url')).toHaveValue('');
    await expect(shell.locator('#ai-api-model')).toHaveValue('');
    await expect(shell.locator('#ai-connection-status')).toHaveText('Not connected');
    assert.equal((await b.invoke('ai:status')).credentialStorage, 'none');
    assert.notEqual(other.id, initial.profiles[0].id);
    await shell.getByRole('button', { name: 'Switch Space or profile', exact: true }).click();
    await shell
      .getByRole('dialog', { name: 'Your Spaces', exact: true })
      .locator(`[data-action="ui:switch-space"][data-id="${initial.activeSpaceId}"]`)
      .click();
    await expect(shell.locator('#ai-provider')).toHaveValue('compatible');
    await expect(shell.locator('#ai-connection-status')).toHaveText('Key saved');
    await expect(shell.locator('#ai-api-key')).toHaveValue('');
    await shell.getByRole('button', { name: 'Test connection', exact: true }).click();
    await expect(shell.locator('#ai-settings')).toContainText('Connected. No inference request was made.');
    assert.equal(b.requests.length, 3);
    assert.equal(b.requests[2].authorization, `Bearer ${DUMMY_KEY}`);

    const exportPath = path.join(b.directory, 'browser-export.json');
    await b.app.evaluate(({ dialog }, exportPath) => {
      dialog.showSaveDialog = async () => ({ canceled: false, filePath: exportPath });
    }, exportPath);
    await shell
      .locator('details.setting-section')
      .filter({ has: shell.locator('summary', { hasText: 'Your data' }) })
      .locator('summary')
      .click();
    await shell.getByRole('button', { name: 'Export data', exact: true }).click();
    await expect.poll(() => fs.readFile(exportPath, 'utf8').catch(() => '')).toContain('zacro-export');
    const exported = await fs.readFile(exportPath, 'utf8');
    const preferences = await fs.readFile(path.join(b.directory, 'ai-providers.json'), 'utf8');
    const snapshot = JSON.stringify(await b.invoke('state:get'));
    const status = JSON.stringify(await b.invoke('ai:status'));
    for (const content of [exported, preferences, snapshot, status]) {
      assert(!content.includes(DUMMY_KEY), 'Saved credentials must never enter public state or JSON files');
      assert(!content.includes(UNSAVED_KEY), 'An unsaved password draft must never be persisted');
    }
    const credentialFile = await fs
      .readFile(path.join(b.directory, 'ai-provider-credentials.enc.json'), 'utf8')
      .catch((error) => {
        if (error.code !== 'ENOENT') throw error;
        return '';
      });
    assert(!credentialFile.includes(DUMMY_KEY));
    assert(
      !credentialFile || Object.keys(JSON.parse(credentialFile).records || {}).length === 0,
      'Session-only keys must not be written to the persistent credential vault',
    );

    // Editing the endpoint must never reuse its previously saved key, even
    // when the new local server deliberately accepts unauthenticated requests.
    await shell.locator('#ai-base-url').fill(b.baseUrl.replace('/v1', '/local/v1'));
    await expect(shell.locator('#ai-api-key')).toHaveValue('');
    await expect(shell.locator('#ai-api-key')).not.toHaveAttribute('required', '');
    await shell.getByRole('button', { name: 'Save connection', exact: true }).click();
    await expect(shell.locator('#ai-connection-status')).toHaveText('Local API ready');
    await expect(shell.getByRole('button', { name: 'Remove key', exact: true })).toHaveCount(0);
    await shell.getByRole('button', { name: 'Test connection', exact: true }).click();
    await expect(shell.locator('#ai-settings')).toContainText('Connected. No inference request was made.');
    assert.equal(b.requests.length, 4);
    assert.equal(b.requests[3].url, '/local/v1/models');
    assert.equal(b.requests[3].authorization, '');
  },
);

test(
  'subscription storage failures require explicit session recovery and unavailable Claude exposes its storage policy and installer',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t);
    const { shell } = b;
    // Substitute only the external subscription clients. The service, IPC,
    // settings persistence, renderer and explicit recovery flow remain real.
    await b.app.evaluate(({ app, shell }) => {
      const require = process.getBuiltinModule('module').createRequire(app.getAppPath() + '/package.json');
      const { CodexClient, CodexError } = require('./src/main/codex.cjs');
      const { ClaudeClient } = require('./src/main/claude.cjs');
      globalThis.__aiLoginStorage = [];
      globalThis.__aiExternalLinks = [];
      shell.openExternal = async (url) => globalThis.__aiExternalLinks.push(url);
      const codexStatus = CodexClient.prototype.status;
      CodexClient.prototype.status = function () {
        return {
          ...codexStatus.call(this),
          ...(globalThis.__aiCodexUnavailable ? { available: false } : {}),
        };
      };
      CodexClient.prototype.refresh = async function () {
        return this.status();
      };
      CodexClient.prototype.login = async function () {
        globalThis.__aiCodexClient = this;
        globalThis.__aiLoginStorage.push(this.authStorage);
        this.account = null;
        if (this.authStorage !== 'session') {
          this.error =
            'The operating system credential store is unavailable. Choose session-only sign-in to continue.';
          this.errorCode = 'AUTH_STORAGE';
          this.changed();
          throw new CodexError(this.error, this.errorCode);
        }
        this.loginId = 'fixture-session-login';
        this.changed();
        return null;
      };
      CodexClient.prototype.cancelLogin = async function () {
        this.loginId = null;
        this.loginStarting = false;
        this.changed();
        return this.status();
      };
      const claudeStatus = ClaudeClient.prototype.status;
      ClaudeClient.prototype.status = function () {
        return {
          ...claudeStatus.call(this),
          available: false,
          configured: false,
          account: null,
          error: 'Install the official native Claude Code CLI to connect your Claude subscription.',
          errorCode: 'UNAVAILABLE',
        };
      };
      ClaudeClient.prototype.refresh = async function () {
        return this.status();
      };
    });
    await b.openConnections();
    await expect(shell.getByRole('button', { name: 'Sign in with ChatGPT', exact: true })).toBeVisible();
    await shell.getByRole('button', { name: 'Sign in with ChatGPT', exact: true }).click();
    await expect(shell.locator('#ai-settings [role="alert"]')).toContainText(
      'credential store is unavailable',
    );
    await expect(shell.locator('#ai-connection-status')).toHaveText('Not connected');
    await expect(shell.getByRole('button', { name: 'Sign out', exact: true })).toHaveCount(0);
    assert.equal((await b.invoke('ai:status')).errorCode, 'AUTH_STORAGE');
    assert.deepEqual(await b.app.evaluate(() => globalThis.__aiLoginStorage), ['keyring']);
    assert.equal((await b.invoke('ai:status')).credentialStorage, 'keyring');
    assert.equal((await b.invoke('ai:status')).configured, false);

    await shell.getByRole('button', { name: 'Use only for this session', exact: true }).click();
    await expect(shell.getByRole('button', { name: 'Cancel sign-in', exact: true })).toBeVisible();
    await expect(shell.locator('#ai-connection-status')).toHaveText('Waiting for sign-in…');
    const pending = await b.invoke('ai:status');
    assert.equal(pending.credentialStorage, 'session');
    assert.equal(pending.configured, false, 'Starting OAuth must never be presented as connected');
    assert.equal(pending.loginPending, true);
    assert.deepEqual(await b.app.evaluate(() => globalThis.__aiLoginStorage), ['keyring', 'session']);
    await expect(shell.locator('#ai-settings')).toContainText('Sign-in is cleared when Zacro quits.');
    await shell.getByRole('button', { name: 'Cancel sign-in', exact: true }).click();
    await expect(shell.locator('#ai-connection-status')).toHaveText('Not connected');
    assert.equal((await b.invoke('ai:status')).loginPending, false);

    // Simulate a completed OAuth exchange without contacting a real account.
    // Session mode remains reversible even while signed in.
    await b.app.evaluate(() => {
      const client = globalThis.__aiCodexClient;
      client.account = { type: 'chatgpt', email: 'fixture@example.invalid', planType: 'plus' };
      client.changed();
    });
    await expect(shell.locator('#ai-connection-status')).toHaveText('fixture@example.invalid');
    await expect(shell.locator('#ai-auth-storage')).toBeEnabled();
    await shell.locator('#ai-auth-storage').selectOption('keyring');
    await expect(shell.locator('#ai-auth-storage')).toBeEnabled();
    await expect(shell.locator('#ai-auth-storage')).toHaveValue('keyring');
    await expect(shell.locator('#ai-connection-status')).toHaveText('Not connected');
    assert.equal((await b.invoke('ai:status')).credentialStorage, 'keyring');
    assert.equal((await b.invoke('ai:status')).configured, false);
    assert.deepEqual(await b.app.evaluate(() => globalThis.__aiLoginStorage), ['keyring', 'session']);

    await b.chooseProvider('claude-code');
    await expect(shell.getByRole('button', { name: 'Install Claude Code', exact: true })).toBeVisible();
    await expect(shell.getByRole('button', { name: 'Sign in with Claude', exact: true })).toHaveCount(0);
    await expect(shell.locator('#ai-connection-status')).toHaveText('Not connected');
    await expect(shell.locator('#ai-settings')).toContainText('macOS Keychain');
    await expect(shell.locator('#ai-settings')).toContainText('local credential file');
    assert.equal((await b.invoke('ai:status')).credentialStorage, 'provider-managed');
    assert.deepEqual(await b.app.evaluate(() => globalThis.__aiExternalLinks), []);
    await shell.getByRole('button', { name: 'Install Claude Code', exact: true }).click();
    await expect
      .poll(() => b.app.evaluate(() => globalThis.__aiExternalLinks))
      .toEqual(['https://code.claude.com/docs/en/setup']);
    await b.app.evaluate(() => {
      globalThis.__aiCodexUnavailable = true;
    });
    await b.chooseProvider('codex');
    await expect(shell.locator('#ai-settings')).toContainText(
      'Reinstall Zacro to restore its bundled Codex runtime.',
    );
    await expect(shell.getByRole('button', { name: 'Install Claude Code', exact: true })).toHaveCount(0);
    await expect(shell.getByRole('button', { name: 'Sign in with ChatGPT', exact: true })).toHaveCount(0);
    assert.equal(b.requests.length, 0, 'Subscription setup must not issue API inference requests');
  },
);
