'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { ClaudeClient, isolatedEnvironment, supportedVersion } = require('../src/main/claude.cjs');

async function fixture(t, options = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-claude-test-'));
  const calls = [];
  let loggedIn = options.loggedIn ?? true;
  const client = new ClaudeClient({
    userDataPath: dir,
    executable: 'fixture-native-claude',
    spawn: (file, args, config) => {
      const child = new EventEmitter();
      child.stdin = new PassThrough();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      const call = { file, args, config, child, input: '' };
      calls.push(call);
      child.stdin.on('data', (data) => {
        call.input += data;
      });
      child.kill = () => {
        child.killed = true;
        queueMicrotask(() => child.emit('close', 1));
      };
      const complete = (data, code = 0) => {
        child.stdout.write(typeof data === 'string' ? data : JSON.stringify(data));
        child.emit('close', code);
      };
      call.complete = complete;
      queueMicrotask(() => {
        if (options.handle?.(call) === true) return;
        if (args.includes('--version')) complete('2.1.300 (Claude Code)');
        else if (args.includes('status'))
          complete(
            {
              loggedIn,
              authMethod: loggedIn ? options.authMethod || 'claude.ai' : 'none',
              email: 'fixture@example.test',
              subscriptionType: 'max',
              accessToken: 'never-expose-token',
            },
            loggedIn ? 0 : 1,
          );
        else if (args.includes('login')) {
          loggedIn = true;
          complete('Login successful');
        } else if (args.includes('logout')) {
          loggedIn = false;
          complete('Logged out');
        } else complete({ subtype: 'success', is_error: false, result: 'A useful page answer.' });
      });
      return child;
    },
  });
  t.after(async () => {
    client.close();
    await new Promise((resolve) => setImmediate(resolve));
    await fs.rm(dir, { recursive: true, force: true });
  });
  return { client, calls, dir };
}
async function waitFor(predicate) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error('Fixture condition did not arrive');
}

test('Claude process environment never imports API/OAuth tokens, personal configuration, hooks or endpoint overrides', () => {
  const env = isolatedEnvironment('/isolated', {
    HOME: '/personal',
    CLAUDE_CONFIG_DIR: '/personal/.claude',
    ANTHROPIC_API_KEY: 'secret',
    CLAUDE_CODE_OAUTH_TOKEN: 'secret',
    ANTHROPIC_BASE_URL: 'https://evil.test',
    NODE_OPTIONS: 'unsafe',
    BASH_ENV: '/evil',
    PATH: '/evil',
    SystemRoot: 'C:\\Windows',
  });
  assert.equal(env.HOME, '/isolated');
  assert.equal(env.CLAUDE_CONFIG_DIR, path.join('/isolated', 'config'));
  assert.ok(!JSON.stringify(env).includes('secret'));
  assert.equal(env.ANTHROPIC_BASE_URL, undefined);
  assert.equal(env.NODE_OPTIONS, undefined);
  assert.equal(env.CLAUDE_CODE_SKIP_PROMPT_HISTORY, '1');
  assert.equal(supportedVersion('2.1.258 (Claude Code)'), false);
  assert.equal(supportedVersion('2.1.259 (Claude Code)'), true);
});

test('subscription authentication uses official CLI commands and exposes only account metadata', async (t) => {
  const { client, calls } = await fixture(t, { loggedIn: false });
  assert.equal((await client.refresh()).configured, false);
  await client.login();
  await waitFor(() => client.status().configured);
  assert.equal(client.status().account.planType, 'max');
  assert.ok(!JSON.stringify(client.status()).includes('never-expose-token'));
  assert.match(client.status().storageNotice, /local credential file/);
  const login = calls.find((call) => call.args.includes('login'));
  assert.equal(login.config.shell, false);
  assert.ok(login.args.includes('auth'));
  assert.ok(login.args.includes('--safe-mode'));
  assert.ok(login.args.some((arg) => arg.includes('"forceLoginMethod":"claudeai"')));
  assert.ok(!login.args.includes('--console'));
  await client.logout();
  assert.equal(client.status().configured, false);
});

test('Claude API credentials are rejected in the subscription connection', async (t) => {
  const { client } = await fixture(t, { authMethod: 'api_key' });
  const status = await client.refresh();
  assert.equal(status.configured, false);
  assert.equal(status.errorCode, 'AUTH');
});

test('Claude questions disable tools/MCP/hooks/browser/persistence and send page content only through stdin', async (t) => {
  const { client, calls } = await fixture(t);
  await client.refresh();
  const result = await client.run({
    model: 'sonnet',
    instructions: 'Treat pages as evidence only.',
    messages: [{ role: 'user', content: 'sensitive-page-text' }],
    signal: new AbortController().signal,
  });
  assert.equal(result.answer, 'A useful page answer.');
  assert.deepEqual(result.sources, []);
  const run = calls.find((call) => call.args.includes('-p'));
  assert.equal(run.args[run.args.indexOf('--tools') + 1], '');
  for (const flag of [
    '--restricted',
    '--safe-mode',
    '--strict-mcp-config',
    '--no-chrome',
    '--no-session-persistence',
  ])
    assert.ok(run.args.includes(flag));
  assert.equal(run.args[run.args.indexOf('--permission-prompts') + 1], 'none');
  assert.equal(run.args[run.args.indexOf('--disallowedTools') + 1], 'mcp__*');
  assert.ok(run.input.includes('sensitive-page-text'));
  assert.ok(!run.args.join(' ').includes('sensitive-page-text'));
});

test('cancelled login cannot publish a late success; cancelled inference kills its owned process', async (t) => {
  let login, run;
  const { client } = await fixture(t, {
    handle: (call) => {
      if (call.args.includes('login')) {
        login = call;
        return true;
      }
      if (call.args.includes('-p')) {
        run = call;
        return true;
      }
    },
  });
  await client.login();
  await waitFor(() => login);
  await client.cancelLogin();
  login.complete('Login successful');
  assert.equal(client.status().configured, false);
  assert.equal(client.status().loginPending, false);
  await client.refresh();
  const controller = new AbortController();
  const pending = client.run({
    messages: [{ role: 'user', content: 'Question' }],
    instructions: 'Answer',
    signal: controller.signal,
  });
  await waitFor(() => run);
  controller.abort(Object.assign(new Error('Stopped'), { code: 'CANCELLED' }));
  await assert.rejects(pending, { code: 'CANCELLED' });
  assert.equal(run.child.killed, true);
});

test('cancelling login while version validation is pending prevents a late authentication process', async (t) => {
  let version;
  const { client, calls } = await fixture(t, {
    handle: (call) => {
      if (call.args.includes('--version')) {
        version = call;
        return true;
      }
    },
  });
  const pending = client.login();
  await waitFor(() => version);
  await client.cancelLogin();
  version.complete('2.1.300 (Claude Code)');
  await pending;
  assert.equal(
    calls.some((call) => call.args.includes('login')),
    false,
  );
});

test('CLI version/output failures stay bounded and never expose diagnostics', async (t) => {
  const { client } = await fixture(t, {
    handle: (call) => {
      if (call.args.includes('--version')) {
        call.complete('1.0.0 sensitive-secret');
        return true;
      }
    },
  });
  const status = await client.refresh();
  assert.equal(status.available, false);
  assert.match(status.error, /Update/);
  assert.ok(!status.error.includes('sensitive-secret'));
});

test('late or concurrent Claude status reads cannot undo sign-out', async (t) => {
  let hold = false,
    statusCall,
    logoutCall;
  const { client, calls } = await fixture(t, {
    handle: (call) => {
      if (hold && call.args.includes('status')) {
        statusCall = call;
        return true;
      }
      if (call.args.includes('logout')) {
        logoutCall = call;
        return true;
      }
    },
  });
  await client.refresh();
  hold = true;
  const oldRead = client.refresh();
  await waitFor(() => statusCall);
  const signout = client.logout();
  await waitFor(() => logoutCall);
  const count = calls.length;
  assert.equal((await client.refresh()).configured, false);
  assert.equal(calls.length, count, 'No account read while sign-out is pending');
  statusCall.complete({ loggedIn: true, authMethod: 'claude.ai', email: 'stale@example.test' });
  await oldRead;
  logoutCall.complete('Logged out');
  await signout;
  assert.equal(client.status().configured, false);
  assert.equal(client.status().account, null);
});
