'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { PassThrough, Writable } = require('node:stream');
const {
  CodexClient,
  CodexError,
  executablePath,
  isolatedEnvironment,
  lockedConfig,
  loginUrl,
} = require('../src/main/codex.cjs');

async function fake(t, options = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-codex-test-'));
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.killed = false;
  child.kill = () => {
    child.killed = true;
    queueMicrotask(() => child.emit('exit', 0));
  };
  const messages = [];
  let launch;
  const deliver = (value) => child.stdout.write(JSON.stringify(value) + '\n');
  const notification = (method, params) => deliver({ method, params });
  let account =
    options.account === undefined
      ? { type: 'chatgpt', email: 'fixture@example.test', planType: 'plus' }
      : options.account;
  const respond = (message, result) => deliver({ id: message.id, result });
  child.stdin = new Writable({
    write(chunk, encoding, callback) {
      for (const line of chunk.toString().trim().split('\n')) {
        const message = JSON.parse(line);
        messages.push(message);
        queueMicrotask(() => {
          if (options.handle?.(message, { respond, notification, deliver }) === true) return;
          if (message.id === undefined || !message.method) return;
          const results = {
            initialize: { userAgent: 'fixture' },
            'mcpServerStatus/list': { data: [], nextCursor: null },
            'skills/list': { data: [{ skills: [], errors: [] }] },
            'account/read': { account },
            'model/list': {
              data: [
                { id: 'fixture-model', model: 'fixture-model', displayName: 'Fixture', isDefault: true },
              ],
            },
            'account/login/start': {
              type: 'chatgpt',
              authUrl: 'https://auth.openai.com/authorize?fixture',
              loginId: 'login-one',
            },
            'account/login/cancel': { status: 'canceled' },
            'account/logout': {},
            'thread/start': { thread: { id: 'thread-one' } },
            'turn/start': { turn: { id: 'turn-one', status: 'inProgress' } },
            'thread/unsubscribe': {},
            'turn/interrupt': {},
          };
          if (message.method === 'account/logout') account = null;
          respond(message, results[message.method] || {});
          if (message.method === 'turn/interrupt')
            notification('turn/completed', {
              threadId: 'thread-one',
              turn: { id: 'turn-one', status: 'interrupted', items: [] },
            });
        });
      }
      callback();
    },
  });
  const client = new CodexClient({
    userDataPath: dir,
    executable: 'fixture-codex',
    rpcTimeoutMs: 1000,
    spawn: (executable, args, config) => {
      launch = { executable, args, config };
      return child;
    },
  });
  t.after(async () => {
    client.close();
    await fs.rm(dir, { recursive: true, force: true });
  });
  return {
    client,
    child,
    messages,
    notification,
    deliver,
    get launch() {
      return launch;
    },
  };
}
const request = (signal, research = false) => ({
  messages: [{ role: 'user', content: 'Fixture question' }],
  instructions: 'Only answer.',
  research,
  signal,
});
async function waitFor(predicate) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error('Fixture condition did not arrive');
}

test('environment allowlist excludes credentials, API endpoints, inherited homes and runtime injection', () => {
  const env = isolatedEnvironment('/isolated', '/isolated/workspace', {
    OPENAI_API_KEY: 'secret',
    ANTHROPIC_API_KEY: 'secret',
    CODEX_HOME: '/personal',
    OPENAI_BASE_URL: 'https://evil.test',
    NODE_OPTIONS: '--require bad',
    PATH: '/user-path',
    SystemRoot: 'C:\\Windows',
    TEMP: '/tmp',
  });
  assert.equal(env.CODEX_HOME, '/isolated');
  assert.equal(env.USERPROFILE, '/isolated');
  assert.ok(!JSON.stringify(env).includes('secret'));
  assert.ok(!JSON.stringify(env).includes('evil'));
  assert.equal(env.NODE_OPTIONS, undefined);
  assert.equal(env.TEMP, '/tmp');
  const config = lockedConfig();
  assert.equal(config.forced_login_method, 'chatgpt');
  assert.equal(config.cli_auth_credentials_store, 'keyring');
  assert.equal(config['features.shell_tool'], false);
  assert.equal(config['features.view_image'], false);
  assert.equal(config['skills.bundled.enabled'], false);
  assert.equal(config['features.skip_host_skill_discovery'], true);
});
test('login URLs allow only the official HTTPS identity host', () => {
  assert.equal(loginUrl('https://auth.openai.com/authorize?x=1'), 'https://auth.openai.com/authorize?x=1');
  for (const url of [
    'http://auth.openai.com/',
    'https://auth.openai.com.evil.test/',
    'https://user@auth.openai.com/',
    'file:///secret',
    'https://auth.openai.com:999/',
  ])
    assert.throws(() => loginUrl(url));
});
test('initialization is isolated and subscription account/model status contains no credentials', async (t) => {
  const f = await fake(t);
  const status = await f.client.refresh();
  assert.equal(status.configured, true);
  assert.equal(status.account.planType, 'plus');
  assert.equal(status.models[0].id, 'fixture-model');
  assert.equal(f.launch.config.windowsHide, true);
  assert.equal(f.launch.config.env.CODEX_HOME, f.client.home);
  assert.ok(f.launch.args.includes('--strict-config'));
  assert.deepEqual(f.messages[0].params.capabilities, { experimentalApi: true });
  assert.equal(f.messages[1].method, 'initialized');
});
test('ChatGPT login lifecycle and logout never require API keys', async (t) => {
  const f = await fake(t, { account: null });
  assert.match(await f.client.login(), /^https:\/\/auth.openai.com/);
  assert.equal(f.client.status().loginPending, true);
  assert.deepEqual(f.messages.find((m) => m.method === 'account/login/start').params, { type: 'chatgpt' });
  await f.client.cancelLogin();
  assert.equal(f.client.status().loginPending, false);
  await f.client.logout();
  assert.equal(f.client.status().configured, false);
});
test('MCP configuration fails closed before any thread can be started', async (t) => {
  const f = await fake(t, {
    handle: (m, { respond }) => {
      if (m.method !== 'mcpServerStatus/list') return;
      respond(m, { data: [{ name: 'external' }] });
      return true;
    },
  });
  await assert.rejects(f.client.refresh(), { code: 'TOOL_POLICY' });
  assert.equal(f.child.killed, true);
  assert.ok(!f.messages.some((m) => m.method === 'thread/start'));
});
test('turns disable execution environments, persist no thread, stream text and accept only completed answers', async (t) => {
  const f = await fake(t);
  await f.client.refresh();
  const deltas = [];
  const result = f.client.run({
    ...request(new AbortController().signal, true),
    onDelta: (text) => deltas.push(text),
  });
  await waitFor(() => f.messages.some((m) => m.method === 'turn/start'));
  const thread = f.messages.find((m) => m.method === 'thread/start').params;
  const turn = f.messages.find((m) => m.method === 'turn/start').params;
  assert.deepEqual(thread.environments, []);
  assert.deepEqual(turn.environments, []);
  assert.equal(thread.ephemeral, true);
  assert.equal(thread.allowProviderModelFallback, false);
  assert.equal(thread.config.web_search, 'live');
  assert.equal(thread.modelProvider, 'openai');
  assert.deepEqual(turn.sandboxPolicy, { type: 'readOnly', networkAccess: false });
  f.notification('item/agentMessage/delta', { threadId: 'thread-one', itemId: 'answer', delta: 'Hello' });
  f.notification('item/completed', {
    threadId: 'thread-one',
    item: { id: 'answer', type: 'agentMessage', text: 'Hello' },
  });
  f.notification('turn/completed', {
    threadId: 'thread-one',
    turn: { id: 'turn-one', status: 'completed', items: [] },
  });
  assert.equal((await result)[0].text, 'Hello');
  assert.deepEqual(deltas, ['Hello']);
  assert.ok(f.messages.some((m) => m.method === 'thread/unsubscribe'));
});
test('known-turn cancellation interrupts and never resolves an answer', async (t) => {
  const f = await fake(t);
  await f.client.refresh();
  const controller = new AbortController();
  const result = f.client.run(request(controller.signal));
  const failed = assert.rejects(result, { code: 'CANCELLED' });
  await waitFor(() => Boolean(f.client.turn?.turnId));
  controller.abort(new CodexError('Answer stopped.', 'CANCELLED'));
  await failed;
  assert.ok(f.messages.some((m) => m.method === 'turn/interrupt'));
  assert.equal(f.child.killed, false);
});
test('cancellation before a turn ID kills only the owned process and clears stale account state', async (t) => {
  const f = await fake(t, { handle: (m) => m.method === 'turn/start' });
  await f.client.refresh();
  const controller = new AbortController();
  const result = f.client.run(request(controller.signal));
  const failed = assert.rejects(result, { code: 'CANCELLED' });
  await waitFor(() => f.messages.some((m) => m.method === 'turn/start'));
  controller.abort(new CodexError('Answer stopped.', 'CANCELLED'));
  await failed;
  assert.equal(f.child.killed, true);
  assert.equal(f.client.status().configured, false);
});
test('unapproved tool requests terminate the owned process even before a turn ID exists', async (t) => {
  const f = await fake(t, { handle: (m) => m.method === 'turn/start' });
  await f.client.refresh();
  const result = f.client.run(request(new AbortController().signal));
  const failed = assert.rejects(result);
  await waitFor(() => f.messages.some((m) => m.method === 'turn/start'));
  f.deliver({
    id: 'approval',
    method: 'item/commandExecution/requestApproval',
    params: { command: 'do not run' },
  });
  await failed;
  assert.equal(f.child.killed, true);
  assert.equal(f.messages.find((m) => m.id === 'approval').error.code, -32601);
});
test('failed/limited turns sanitize upstream errors and never return partial content', async (t) => {
  const f = await fake(t);
  await f.client.refresh();
  const result = f.client.run(request(new AbortController().signal));
  const failed = assert.rejects(
    result,
    (error) => error.code === 'LIMIT' && !error.message.includes('sensitive'),
  );
  await waitFor(() => Boolean(f.client.turn?.turnId));
  f.notification('turn/completed', {
    threadId: 'thread-one',
    turn: { status: 'failed', error: { message: 'usage_limit reached sensitive prompt' } },
  });
  await failed;
});
test('process death and a non-subscription account cannot leave configured status behind', async (t) => {
  const f = await fake(t);
  await f.client.refresh();
  f.child.emit('exit', 1);
  assert.equal(f.client.status().configured, false);
  const other = await fake(t, { account: { type: 'apiKey' } });
  await assert.rejects(other.client.refresh(), { code: 'AUTH' });
  assert.equal(other.client.status().configured, false);
});
test('cancelling a pending login RPC invalidates its late URL and cancels the returned login ID', async (t) => {
  let completeLogin;
  const f = await fake(t, {
    account: null,
    handle: (m, { respond }) => {
      if (m.method !== 'account/login/start') return;
      completeLogin = () =>
        respond(m, { loginId: 'late-login', authUrl: 'https://auth.openai.com/authorize?late' });
      return true;
    },
  });
  const pending = f.client.login();
  await waitFor(() => Boolean(completeLogin));
  assert.equal(f.client.status().loginPending, true);
  await f.client.cancelLogin();
  completeLogin();
  assert.equal(await pending, null, 'A cancelled login must never open an external browser');
  assert.equal(f.client.status().loginPending, false);
  assert.deepEqual(f.messages.find((m) => m.method === 'account/login/cancel').params, {
    loginId: 'late-login',
  });
});

test('late account reads and model catalogs cannot undo logout', async (t) => {
  for (const heldMethod of ['account/read', 'model/list']) {
    let hold = false,
      release;
    const f = await fake(t, {
      handle: (m, { respond }) => {
        if (!hold || m.method !== heldMethod) return;
        release = () =>
          respond(
            m,
            heldMethod === 'account/read'
              ? { account: { type: 'chatgpt', email: 'stale@example.test', planType: 'plus' } }
              : { data: [{ id: 'stale-model', displayName: 'Stale' }] },
          );
        return true;
      },
    });
    await f.client.refresh();
    hold = true;
    const pending = f.client.readAccount(true);
    await waitFor(() => Boolean(release));
    await f.client.logout();
    release();
    await pending;
    assert.equal(f.client.status().configured, false);
    assert.deepEqual(f.client.status().models, []);
  }
});

test('only the latest account read may replace account state', async (t) => {
  let hold = false;
  const releases = [];
  const f = await fake(t, {
    handle: (m, { respond }) => {
      if (!hold || m.method !== 'account/read') return;
      releases.push((account) => respond(m, { account }));
      return true;
    },
  });
  await f.client.refresh();
  hold = true;
  const older = f.client.readAccount(false),
    newer = f.client.readAccount(false);
  await waitFor(() => releases.length === 2);
  releases[1](null);
  await newer;
  releases[0]({ type: 'chatgpt', email: 'stale@example.test', planType: 'plus' });
  await older;
  assert.equal(f.client.status().configured, false);
});

test('authentication failures clear account state and expose a recoverable sign-in message', async (t) => {
  const f = await fake(t);
  await f.client.refresh();
  const result = f.client.run(request(new AbortController().signal));
  const failed = assert.rejects(result, { code: 'AUTH' });
  await waitFor(() => Boolean(f.client.turn?.turnId));
  f.notification('turn/completed', {
    threadId: 'thread-one',
    turn: { status: 'failed', error: { message: 'unauthorized sensitive raw message' } },
  });
  await failed;
  assert.equal(f.client.status().configured, false);
  assert.deepEqual(f.client.status().models, []);
  assert.match(f.client.status().error, /Sign in with ChatGPT again/);
  assert.ok(!f.client.status().error.includes('sensitive'));
});

test('closing during startup does not spawn a process after the client has closed', async (t) => {
  const f = await fake(t);
  const starting = f.client.start();
  f.client.close();
  await assert.rejects(starting, { code: 'CLOSED' });
  assert.equal(f.launch, undefined);
});

test('a late interrupt RPC failure cannot terminate a subsequent turn', async (t) => {
  let lateInterrupt;
  const f = await fake(t, {
    handle: (m, { deliver }) => {
      if (m.method !== 'turn/interrupt') return;
      lateInterrupt = () => deliver({ id: m.id, error: { message: 'old interruption failed' } });
      return true;
    },
  });
  await f.client.refresh();
  const controller = new AbortController();
  const first = f.client.run(request(controller.signal));
  const stopped = assert.rejects(first, { code: 'CANCELLED' });
  await waitFor(() => Boolean(f.client.turn?.turnId));
  controller.abort(new CodexError('Answer stopped.', 'CANCELLED'));
  await waitFor(() => Boolean(lateInterrupt));
  f.notification('turn/completed', { threadId: 'thread-one', turn: { status: 'interrupted', items: [] } });
  await stopped;
  const next = f.client.run(request(new AbortController().signal));
  await waitFor(() => Boolean(f.client.turn?.turnId));
  lateInterrupt();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.child.killed, false);
  f.notification('turn/completed', {
    threadId: 'thread-one',
    turn: { status: 'completed', items: [{ type: 'agentMessage', id: 'new-answer', text: 'New answer' }] },
  });
  assert.equal((await next)[0].text, 'New answer');
});

test('broken pipes are handled as owned-process failures without an uncaught exception', async (t) => {
  const f = await fake(t);
  await f.client.refresh();
  f.child.stdin.emit('error', Object.assign(new Error('write EPIPE'), { code: 'EPIPE' }));
  assert.equal(f.client.status().configured, false);
  assert.equal(f.child.killed, true);
  f.notification('account/updated', { authMode: 'chatgpt' });
  assert.equal(f.client.status().configured, false);
});

test(
  'bundled official runtime completes an unsigned isolated handshake without a model request',
  { timeout: 15000 },
  async (t) => {
    assert.ok(executablePath(), 'The official pinned platform runtime must be installed');
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-codex-native-test-'));
    const client = new CodexClient({ userDataPath: dir, rpcTimeoutMs: 5000 });
    t.after(async () => {
      client.close();
      await new Promise((resolve) => setTimeout(resolve, 100));
      await fs.rm(dir, { recursive: true, force: true });
    });
    const status = await client.refresh();
    assert.equal(status.configured, false);
    assert.equal(status.account, null);
    assert.equal(status.available, true);
    assert.equal(status.loginPending, false);
    assert.deepEqual(status.models, []);
    await assert.rejects(client.run(request(new AbortController().signal)), { code: 'NOT_CONFIGURED' });
  },
);
