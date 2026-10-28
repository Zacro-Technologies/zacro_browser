'use strict';

// Use the user's installed, unmodified official CLI. OAuth remains entirely in
// that CLI; Zacro never reads, exports, or replays subscription tokens.
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const { validateModel } = require('./ai-providers.cjs');

const INSTALL_URL = 'https://code.claude.com/docs/en/setup';
const MIN_VERSION = [2, 1, 259];
const MAX_OUTPUT = 2 * 1024 * 1024;
const SETTINGS = Object.freeze({
  forceLoginMethod: 'claudeai',
  disableAllHooks: true,
  autoMemoryEnabled: false,
  enabledPlugins: {},
});

class ClaudeError extends Error {
  constructor(message, code = 'CLAUDE') {
    super(message);
    this.code = code;
  }
}

function executablePath({ platform = process.platform, env = process.env, home = os.homedir() } = {}) {
  const name = platform === 'win32' ? 'claude.exe' : 'claude';
  const directories = [
    path.join(home, '.local', 'bin'),
    ...(env.PATH || env.Path || '').split(path.delimiter),
  ];
  for (const dir of directories) {
    if (!path.isAbsolute(dir) || path.resolve(dir) === process.cwd()) continue;
    const file = path.join(dir, name);
    try {
      if (!fs.statSync(file).isFile()) continue;
      // Native installations only: no .cmd wrappers, shell scripts, or shell invocation.
      const fd = fs.openSync(file, 'r');
      const header = Buffer.alloc(4);
      try {
        fs.readSync(fd, header, 0, 4, 0);
      } finally {
        fs.closeSync(fd);
      }
      if (header.subarray(0, 2).toString() === '#!') continue;
      return file;
    } catch {}
  }
  return null;
}

function isolatedEnvironment(home, input = process.env) {
  const allowed = new Set([
    'systemroot',
    'windir',
    'comspec',
    'pathext',
    'temp',
    'tmp',
    'lang',
    'lc_all',
    'lc_ctype',
    'tz',
    'localappdata',
    'appdata',
    'display',
    'wayland_display',
    'xdg_runtime_dir',
    'dbus_session_bus_address',
  ]);
  const env = Object.fromEntries(Object.entries(input).filter(([key]) => allowed.has(key.toLowerCase())));
  env.HOME = home;
  env.USERPROFILE = home;
  env.CLAUDE_CONFIG_DIR = path.join(home, 'config');
  env.CLAUDE_CODE_SKIP_PROMPT_HISTORY = '1';
  env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1';
  env.PATH =
    process.platform === 'win32' && env.SystemRoot ? path.join(env.SystemRoot, 'System32') : '/usr/bin:/bin';
  return env;
}

function supportedVersion(value) {
  const match = /\b(\d+)\.(\d+)\.(\d+)\b/.exec(value);
  if (!match) return false;
  const parts = match.slice(1).map(Number);
  for (let i = 0; i < 3; i++) {
    if (parts[i] !== MIN_VERSION[i]) return parts[i] > MIN_VERSION[i];
  }
  return true;
}

class ClaudeClient extends EventEmitter {
  constructor({
    userDataPath,
    executable = executablePath(),
    spawn: spawnImpl = spawn,
    timeoutMs = 120000,
  } = {}) {
    super();
    this.home = path.join(userDataPath, 'claude-code');
    this.cwd = path.join(this.home, 'workspace');
    this.executable = executable;
    this.spawn = spawnImpl;
    this.timeoutMs = timeoutMs;
    this.account = null;
    this.loginPending = false;
    this.generation = 0;
    this.readId = 0;
    this.loggingOut = false;
    this.processes = new Set();
    this.closed = false;
  }

  status() {
    return {
      available: Boolean(this.executable) && !this.unsupported,
      configured: Boolean(this.account),
      account: this.account,
      models: [
        { id: 'sonnet', name: 'Sonnet', isDefault: true },
        { id: 'opus', name: 'Opus' },
        { id: 'haiku', name: 'Haiku' },
      ],
      loginPending: this.loginPending,
      credentialStorage: 'provider-managed',
      installUrl: INSTALL_URL,
      storageNotice:
        'The official Claude Code CLI manages this sign-in in a separate Zacro configuration. It uses the macOS Keychain when available; Windows, Linux, and macOS Keychain fallback use a local credential file. Zacro never reads the subscription tokens.',
      ...(!this.executable
        ? {
            error: 'Install the official native Claude Code CLI to connect your Claude subscription.',
            errorCode: 'UNAVAILABLE',
          }
        : {}),
      ...(this.error ? { error: this.error, errorCode: this.errorCode || 'CLAUDE' } : {}),
    };
  }

  changed() {
    this.emit('status', this.status());
  }

  async command(args, { input, signal, timeoutMs = this.timeoutMs, allowFailure = false } = {}) {
    if (this.closed) throw new ClaudeError('The Claude connection has closed.', 'CLOSED');
    if (!this.executable)
      throw new ClaudeError('Install the official native Claude Code CLI first.', 'UNAVAILABLE');
    if (signal?.aborted) throw signal.reason;
    await fsp.mkdir(this.cwd, { recursive: true, mode: 0o700 });
    if (this.closed) throw new ClaudeError('The Claude connection has closed.', 'CLOSED');
    if (signal?.aborted) throw signal.reason;
    return new Promise((resolve, reject) => {
      let child,
        timer,
        completed = false,
        output = '',
        bytes = 0;
      const finish = (error, result) => {
        if (completed) return;
        completed = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        this.processes.delete(child);
        if (error) {
          child?.kill();
          reject(error);
        } else resolve(result);
      };
      const abort = () => finish(signal.reason || new ClaudeError('Request stopped.', 'CANCELLED'));
      try {
        child = this.spawn(this.executable, args, {
          cwd: this.cwd,
          env: isolatedEnvironment(this.home),
          windowsHide: true,
          stdio: ['pipe', 'pipe', 'pipe'],
          shell: false,
        });
        this.processes.add(child);
        child.stdout.setEncoding('utf8');
        child.stdout.on('data', (chunk) => {
          bytes += Buffer.byteLength(chunk);
          if (bytes > MAX_OUTPUT)
            return finish(new ClaudeError('Claude returned an oversized response.', 'RESPONSE_SIZE'));
          output += chunk;
        });
        // Diagnostics can contain prompts or login material and never enter UI/logs.
        child.stderr.resume();
        child.on('error', () =>
          finish(
            new ClaudeError(
              'The official Claude Code CLI could not start. Reinstall or update it.',
              'UNAVAILABLE',
            ),
          ),
        );
        child.stdin.on('error', () =>
          finish(new ClaudeError('The Claude connection closed unexpectedly.', 'UNAVAILABLE')),
        );
        child.on('close', (code) => {
          if (code && !allowFailure)
            return finish(
              new ClaudeError(
                'Claude Code could not complete the request. Check your subscription sign-in and CLI version; no API billing fallback was used.',
                'CLAUDE',
              ),
            );
          finish(null, { code, output });
        });
        signal?.addEventListener('abort', abort, { once: true });
        timer = setTimeout(
          () => finish(new ClaudeError('Claude Code took too long. Try again.', 'TIMEOUT')),
          timeoutMs,
        );
        timer.unref?.();
        if (signal?.aborted) return abort();
        if (input !== undefined) child.stdin.end(input);
        // Login keeps stdin open for the official browser callback flow.
        else if (!args.includes('login')) child.stdin.end();
      } catch {
        finish(new ClaudeError('Unable to start the official Claude Code CLI.', 'UNAVAILABLE'));
      }
    });
  }

  async ensureVersion() {
    if (this.versionChecked) return;
    if (!this.executable) this.executable = executablePath();
    const result = await this.command(['--version'], { timeoutMs: 15000 });
    if (!supportedVersion(result.output)) {
      this.unsupported = true;
      throw new ClaudeError(
        'Update the official Claude Code CLI to version 2.1.259 or later for isolated, tool-free browser questions.',
        'UNAVAILABLE',
      );
    }
    this.versionChecked = true;
    this.unsupported = false;
  }

  authArgs(command) {
    return ['--safe-mode', '--setting-sources', '', '--settings', JSON.stringify(SETTINGS), 'auth', command];
  }

  async refresh() {
    if (this.loginPending || this.loggingOut) return this.status();
    const generation = this.generation;
    const readId = ++this.readId;
    const current = () =>
      generation === this.generation && readId === this.readId && !this.closed && !this.loggingOut;
    try {
      await this.ensureVersion();
      const result = await this.command(this.authArgs('status'), { timeoutMs: 15000, allowFailure: true });
      if (!current()) return this.status();
      let auth;
      try {
        auth = JSON.parse(result.output);
      } catch {
        throw new ClaudeError(
          'Claude Code returned an unsupported sign-in status. Update the official CLI.',
          'PROTOCOL',
        );
      }
      this.account =
        result.code === 0 && auth.loggedIn === true && auth.authMethod === 'claude.ai'
          ? {
              email: typeof auth.email === 'string' ? auth.email.slice(0, 300) : null,
              planType:
                typeof auth.subscriptionType === 'string'
                  ? auth.subscriptionType.slice(0, 100)
                  : 'Claude subscription',
            }
          : null;
      if (auth.loggedIn && auth.authMethod !== 'claude.ai')
        throw new ClaudeError(
          'This connection requires your own Claude subscription sign-in. API credentials belong in the Claude API provider.',
          'AUTH',
        );
      this.error = null;
      this.errorCode = null;
    } catch (error) {
      if (current()) {
        this.account = null;
        this.error = error.message;
        this.errorCode = error.code;
      }
    }
    this.changed();
    return this.status();
  }

  async login() {
    if (this.loggingOut) throw new ClaudeError('Wait for sign-out to finish before signing in.', 'BUSY');
    if (this.loginPending) return null;
    const generation = ++this.generation;
    this.account = null;
    this.error = null;
    this.errorCode = null;
    this.loginPending = true;
    this.changed();
    try {
      await this.ensureVersion();
    } catch (error) {
      if (generation === this.generation) {
        this.loginPending = false;
        this.error = error.message;
        this.errorCode = error.code;
        this.changed();
      }
      throw error;
    }
    if (generation !== this.generation || this.closed) return null;
    const controller = new AbortController();
    this.loginController = controller;
    this.changed();
    this.command(this.authArgs('login'), { signal: controller.signal, timeoutMs: 180000 })
      .then(async () => {
        if (generation !== this.generation || this.closed) return;
        this.loginPending = false;
        await this.refresh();
        if (!this.account && !this.error) {
          this.error = 'Claude sign-in did not complete. Try again.';
          this.errorCode = 'AUTH';
          this.changed();
        }
      })
      .catch((error) => {
        if (generation !== this.generation || this.closed) return;
        this.loginPending = false;
        this.error = error.message;
        this.errorCode = error.code;
        this.changed();
      });
    return null;
  }

  async cancelLogin() {
    ++this.generation;
    this.loginController?.abort(new ClaudeError('Sign-in cancelled.', 'CANCELLED'));
    this.loginController = null;
    this.loginPending = false;
    this.changed();
    return this.status();
  }

  async logout() {
    this.loggingOut = true;
    try {
      await this.cancelLogin();
      this.account = null;
      this.changed();
      await this.ensureVersion();
      await this.command(this.authArgs('logout'), { timeoutMs: 15000 });
      this.error = null;
      this.errorCode = null;
      return this.status();
    } finally {
      this.loggingOut = false;
      this.changed();
    }
  }

  async run({ model = 'sonnet', instructions, messages, signal }) {
    if (!this.account)
      throw new ClaudeError('Sign in with your Claude subscription first.', 'NOT_CONFIGURED');
    await this.ensureVersion();
    const args = [
      '--safe-mode',
      '--restricted',
      '--setting-sources',
      '',
      '--settings',
      JSON.stringify(SETTINGS),
      '--strict-mcp-config',
      '--mcp-config',
      '{"mcpServers":{}}',
      '--disallowedTools',
      'mcp__*',
      '--tools',
      '',
      '--permission-mode',
      'dontAsk',
      '--permission-prompts',
      'none',
      '--no-chrome',
      '--no-session-persistence',
      '--max-turns',
      '1',
      '--model',
      validateModel(model),
      '--system-prompt',
      instructions,
      '-p',
      '--output-format',
      'json',
    ];
    const result = await this.command(args, { input: JSON.stringify(messages), signal });
    let data;
    try {
      data = JSON.parse(result.output);
    } catch {
      throw new ClaudeError('Claude Code returned an invalid response.', 'PROTOCOL');
    }
    if (data.is_error || data.subtype !== 'success')
      throw new ClaudeError(
        'Claude Code did not complete this answer. Check your subscription allowance or try a narrower question.',
        'CLAUDE',
      );
    if (typeof data.result !== 'string' || !data.result.trim())
      throw new ClaudeError('Claude returned no answer.', 'EMPTY');
    return { answer: data.result, sources: [], citations: [], usage: {}, historyContent: data.result };
  }

  close() {
    this.closed = true;
    ++this.generation;
    this.loginController?.abort(new ClaudeError('Sign-in cancelled.', 'CANCELLED'));
    for (const child of this.processes) child.kill();
    this.processes.clear();
    this.account = null;
  }
}

module.exports = {
  ClaudeClient,
  ClaudeError,
  executablePath,
  isolatedEnvironment,
  supportedVersion,
  INSTALL_URL,
};
