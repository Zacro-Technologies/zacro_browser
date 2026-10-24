'use strict';

// A private stdio client for the pinned, official Codex runtime. This module never
// reads another application's Codex home, accepts API credentials, or invokes tools.
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');

const VERSION = '0.164.0';
const MAX_MESSAGE = 4 * 1024 * 1024;
const DISABLED_FEATURES = Object.freeze([
  'shell_tool',
  'apply_patch_freeform',
  'view_image',
  'apps',
  'hooks',
  'plugin_hooks',
  'multi_agent',
  'multi_agent_v2',
  'remote_plugin',
  'plugins',
  'memories',
  'memory_tool',
  'js_repl',
  'code_mode',
  'code_mode_host',
  'browser_use',
  'computer_use',
  'in_app_browser',
  'in_app_local_automation',
  'workspace_dependencies',
  'tool_search',
  'search_tool',
  'skill_search',
  'skill_mcp_dependency_install',
  'skill_env_var_dependency_prompt',
  'image_generation',
  'goals',
  'request_permissions',
  'request_permissions_tool',
  'tool_suggest',
  'multi_env_copy_file',
  'remote_control',
  'send_async_message',
  'default_mode_request_user_input',
  'collaboration_modes',
  'shell_snapshot',
  'external_agent_memory_import',
  'external_migration',
  'daemon_auto_start',
]);

class CodexError extends Error {
  constructor(message, code = 'CODEX') {
    super(message);
    this.name = 'CodexError';
    this.code = code;
  }
}

function executablePath(platform = process.platform, arch = process.arch) {
  const triples = {
    'win32-x64': 'x86_64-pc-windows-msvc',
    'win32-arm64': 'aarch64-pc-windows-msvc',
    'darwin-x64': 'x86_64-apple-darwin',
    'darwin-arm64': 'aarch64-apple-darwin',
    'linux-x64': 'x86_64-unknown-linux-musl',
    'linux-arm64': 'aarch64-unknown-linux-musl',
  };
  const target = `${platform}-${arch}`;
  if (!triples[target]) return null;
  try {
    const root = path.dirname(require.resolve(`@openai/codex-${target}/package.json`));
    const executable = path
      .join(root, 'vendor', triples[target], 'bin', platform === 'win32' ? 'codex.exe' : 'codex')
      .replace(/app\.asar([\\/])/, 'app.asar.unpacked$1');
    return fs.existsSync(executable) ? executable : null;
  } catch {
    return null;
  }
}

function isolatedEnvironment(home, cwd, input = process.env) {
  // Allowlist: no OPENAI_API_KEY, provider endpoints, inherited CODEX_HOME,
  // access tokens, NODE_OPTIONS, shell startup hooks, or arbitrary credentials.
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
  ]);
  const env = Object.fromEntries(Object.entries(input).filter(([key]) => allowed.has(key.toLowerCase())));
  env.CODEX_HOME = home;
  env.HOME = home;
  env.USERPROFILE = home;
  env.PWD = cwd;
  env.PATH =
    process.platform === 'win32' && env.SystemRoot ? path.join(env.SystemRoot, 'System32') : '/usr/bin:/bin';
  return env;
}

function lockedConfig() {
  return {
    model_provider: 'openai',
    forced_login_method: 'chatgpt',
    // A separate keyring entry is derived from CODEX_HOME; do not fall back to plaintext.
    cli_auth_credentials_store: 'keyring',
    approval_policy: 'never',
    sandbox_mode: 'read-only',
    project_doc_max_bytes: 0,
    project_doc_fallback_filenames: [],
    include_environment_context: false,
    include_environment_context_time: false,
    allow_login_shell: false,
    web_search: 'disabled',
    mcp_servers: {},
    'shell_environment_policy.inherit': 'none',
    'shell_environment_policy.include_only': [],
    'skills.bundled.enabled': false,
    'skills.include_instructions': false,
    'features.skip_host_skill_discovery': true,
    'plugins._default.enabled': false,
    'tools.update_plan.enabled': false,
    'tools.experimental_request_user_input.enabled': false,
    'history.persistence': 'none',
    'analytics.enabled': false,
    'memories.generate_memories': false,
    'memories.use_memories': false,
    ...Object.fromEntries(DISABLED_FEATURES.map((name) => [`features.${name}`, false])),
  };
}

function configArgs(config) {
  return Object.entries(config).flatMap(([key, value]) => ['-c', `${key}=${JSON.stringify(value)}`]);
}

function loginUrl(value) {
  try {
    const url = new URL(value);
    if (
      url.protocol === 'https:' &&
      url.hostname === 'auth.openai.com' &&
      !url.username &&
      !url.password &&
      !url.port
    )
      return url.href;
  } catch {}
  throw new CodexError('Codex returned an unsupported sign-in address.', 'AUTH_URL');
}

function safeError(error) {
  const detail = JSON.stringify(error || {}).toLowerCase();
  if (/eaddrinuse|address already in use/.test(detail))
    return new CodexError(
      'Another Codex sign-in is using the local callback. Finish or close it and try again.',
      'AUTH_BUSY',
    );
  if (/usage_limit|rate.limit|quota|limit.reached/.test(detail))
    return new CodexError(
      'Your Codex allowance is currently unavailable. Check your ChatGPT plan or try after the limit resets. Zacro never switches to API billing.',
      'LIMIT',
    );
  if (/auth|unauthor|token.expir|not.logged|login/.test(detail))
    return new CodexError('Sign in with ChatGPT again to use your Codex subscription.', 'AUTH');
  return new CodexError(
    'Codex could not complete the request. Check your connection and try again.',
    'CODEX',
  );
}

class CodexClient extends EventEmitter {
  constructor({
    userDataPath,
    spawn: spawnImpl = spawn,
    executable = executablePath(),
    rpcTimeoutMs = 20000,
  } = {}) {
    super();
    this.home = path.join(userDataPath, 'codex');
    this.cwd = path.join(this.home, 'workspace');
    this.spawn = spawnImpl;
    this.executable = executable;
    this.rpcTimeoutMs = rpcTimeoutMs;
    this.available = Boolean(executable);
    this.account = null;
    this.models = [];
    this.loginId = null;
    this.loginStarting = false;
    this.loginGeneration = 0;
    this.accountGeneration = 0;
    this.accountReadId = 0;
    this.loggingOut = false;
    this.error = null;
    this.pending = new Map();
    this.nextId = 1;
    this.child = null;
    this.starting = null;
    this.closed = false;
    this.turn = null;
  }

  status() {
    return {
      available: this.available,
      configured: Boolean(this.account),
      account: this.account,
      models: this.models,
      loginPending: Boolean(this.loginId || this.loginStarting),
      ...(this.error ? { error: this.error } : {}),
    };
  }

  changed() {
    this.emit('status', this.status());
  }

  async start() {
    if (this.closed) throw new CodexError('The Codex connection has closed.', 'CLOSED');
    if (this.starting) return this.starting;
    if (this.child) return;
    if (!this.executable)
      throw new CodexError('The bundled Codex runtime is missing. Reinstall Zacro to use AI.', 'UNAVAILABLE');
    this.starting = this.startProcess();
    try {
      await this.starting;
    } catch (error) {
      this.error = error instanceof CodexError ? error.message : 'Unable to start the bundled Codex runtime.';
      this.stopProcess();
      this.changed();
      throw new CodexError(this.error, error.code || 'UNAVAILABLE');
    } finally {
      this.starting = null;
    }
  }

  async startProcess() {
    await fsp.mkdir(this.cwd, { recursive: true, mode: 0o700 });
    if (this.closed) throw new CodexError('The Codex connection has closed.', 'CLOSED');
    const child = this.spawn(
      this.executable,
      ['app-server', '--strict-config', '--listen', 'stdio://', ...configArgs(lockedConfig())],
      {
        cwd: this.cwd,
        env: isolatedEnvironment(this.home, this.cwd),
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    );
    this.child = child;
    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      if (this.child !== child) return;
      buffer += chunk;
      if (Buffer.byteLength(buffer) > MAX_MESSAGE) return this.protocolFailure();
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        if (!line.trim()) continue;
        try {
          this.receive(JSON.parse(line));
        } catch {
          this.protocolFailure();
        }
      }
    });
    // Never echo diagnostics: upstream errors can contain account and prompt data.
    child.stderr.resume();
    child.stdin.on('error', () => this.processEnded(child));
    child.on('error', () => this.processEnded(child));
    child.on('exit', () => this.processEnded(child));
    await this.rpc('initialize', {
      clientInfo: { name: 'zacro_browser', title: 'Zacro', version: '0.3.0' },
      capabilities: { experimentalApi: true },
    });
    this.notify('initialized', {});
    // Reject managed/system-injected MCP integrations before creating any thread.
    const inventory = await this.rpc('mcpServerStatus/list', { limit: 100 });
    if (inventory.data?.length || inventory.nextCursor)
      throw new CodexError(
        'This Codex installation has external tools enabled. Zacro requires an isolated connection.',
        'TOOL_POLICY',
      );
    const skills = await this.rpc('skills/list', { cwds: [this.cwd], forceReload: true });
    for (const entry of skills.data || []) {
      if (entry.errors?.length)
        throw new CodexError('Codex could not verify its isolated skills configuration.', 'TOOL_POLICY');
      for (const skill of entry.skills || []) {
        if (skill.enabled !== false)
          await this.rpc('skills/config/write', { path: skill.path, enabled: false });
      }
    }
    this.error = null;
    await this.readAccount(false);
  }

  processEnded(child) {
    if (this.child !== child) return;
    this.child = null;
    this.loginId = null;
    this.loginStarting = false;
    this.loginGeneration++;
    this.accountGeneration++;
    this.account = null;
    this.models = [];
    const error = new CodexError('The Codex connection stopped. Please try again.', 'UNAVAILABLE');
    this.rejectPending(error);
    this.turn?.reject(error);
    this.error = error.message;
    child.kill();
    this.changed();
  }

  rejectPending(error) {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    this.pending.clear();
  }

  protocolFailure() {
    const error = new CodexError('The Codex connection returned an invalid response.', 'PROTOCOL');
    this.rejectPending(error);
    this.turn?.reject(error);
    this.stopProcess();
  }

  forbidTool() {
    const error = new CodexError('Codex requested a tool that Zacro does not permit.', 'TOOL_POLICY');
    this.turn?.reject(error);
    this.error = error.message;
    // Stop our own child, including when the server has not returned a turn ID.
    this.stopProcess();
  }

  invalidateAuth(error) {
    if (error.code !== 'AUTH') return;
    this.accountGeneration++;
    this.account = null;
    this.models = [];
    this.error = error.message;
    this.changed();
  }

  send(message) {
    if (!this.child?.stdin.writable)
      throw new CodexError('Codex is unavailable. Please reconnect.', 'UNAVAILABLE');
    this.child.stdin.write(JSON.stringify(message) + '\n');
  }
  notify(method, params) {
    this.send({ method, params });
  }
  rpc(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new CodexError('Codex took too long to respond. Please try again.', 'TIMEOUT'));
      }, this.rpcTimeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.send({ id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  receive(message) {
    if (message.method && message.id !== undefined) {
      // No approval or server-initiated tool request can be granted by this client.
      this.send({
        id: message.id,
        error: { code: -32601, message: 'Zacro does not permit local tools or approval requests.' },
      });
      if (this.turn) {
        this.forbidTool();
      }
      return;
    }
    if (message.id !== undefined) {
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) {
        const error = safeError(message.error);
        this.invalidateAuth(error);
        entry.reject(error);
      } else entry.resolve(message.result);
      return;
    }
    const p = message.params || {};
    if (message.method === 'account/login/completed') {
      if (p.loginId !== this.loginId) return;
      this.loginId = null;
      if (!p.success) this.error = 'ChatGPT sign-in did not complete. Please try again.';
      this.readAccount(p.success).catch(() => {
        this.error = 'Unable to read the ChatGPT connection.';
        this.changed();
      });
      this.changed();
    } else if (message.method === 'account/updated') {
      this.readAccount(true).catch(() => {});
    }
    const turn = this.turn;
    if (!turn || p.threadId !== turn.threadId) return;
    if (message.method === 'item/agentMessage/delta') {
      if (typeof p.delta !== 'string') return;
      turn.bytes += Buffer.byteLength(p.delta);
      if (turn.bytes > MAX_MESSAGE) {
        turn.reject(new CodexError('The answer was too large.', 'RESPONSE_SIZE'));
        this.stopProcess();
        return;
      }
      turn.deltas.set(p.itemId, (turn.deltas.get(p.itemId) || '') + p.delta);
      turn.onDelta?.(p.delta);
    } else if (message.method === 'item/completed') {
      turn.items.set(p.item.id, p.item);
    } else if (
      message.method === 'item/started' &&
      p.item?.type &&
      !['userMessage', 'agentMessage', 'reasoning', 'webSearch', 'plan', 'contextCompaction'].includes(
        p.item.type,
      )
    ) {
      this.forbidTool();
    } else if (message.method === 'turn/completed') {
      for (const item of p.turn?.items || []) turn.items.set(item.id, item);
      if (p.turn?.status === 'completed') turn.resolve([...turn.items.values()]);
      else if (p.turn?.status === 'interrupted') turn.reject(new CodexError('Answer stopped.', 'CANCELLED'));
      else {
        const error = safeError(p.turn?.error);
        this.invalidateAuth(error);
        turn.reject(error);
      }
    }
  }

  async readAccount(withModels = true) {
    if (this.loggingOut) return this.status();
    const generation = this.accountGeneration;
    const readId = ++this.accountReadId;
    const child = this.child;
    const current = () =>
      generation === this.accountGeneration &&
      readId === this.accountReadId &&
      child === this.child &&
      !this.loggingOut;
    const result = await this.rpc('account/read', { refreshToken: false });
    if (!current()) return this.status();
    if (result.account && result.account.type !== 'chatgpt') {
      this.account = null;
      this.models = [];
      this.changed();
      throw new CodexError('Zacro supports ChatGPT subscription sign-in only.', 'AUTH');
    }
    const account = result.account
      ? { email: result.account.email || null, planType: result.account.planType || null }
      : null;
    let models = account && account.email === this.account?.email ? this.models : [];
    if (account && withModels) {
      const catalog = await this.rpc('model/list', { includeHidden: false, limit: 100 });
      if (!current()) return this.status();
      models = (catalog.data || [])
        .map((model) => ({
          id: model.model || model.id,
          name: model.displayName || model.model || model.id,
          isDefault: Boolean(model.isDefault),
        }))
        .filter((model) => typeof model.id === 'string' && /^[a-zA-Z0-9._:-]{1,120}$/.test(model.id));
    }
    this.account = account;
    this.models = account ? models : [];
    this.changed();
    return this.status();
  }
  async refresh() {
    await this.start();
    return this.readAccount(true);
  }
  async login() {
    if (this.loginId || this.loginStarting || this.loggingOut) return null;
    const generation = ++this.loginGeneration;
    this.loginStarting = true;
    this.changed();
    try {
      await this.start();
      if (generation !== this.loginGeneration) return null;
      const result = await this.rpc('account/login/start', { type: 'chatgpt' });
      if (generation !== this.loginGeneration) {
        if (this.child && result.loginId)
          await this.rpc('account/login/cancel', { loginId: result.loginId }).catch(() => this.stopProcess());
        return null;
      }
      let authUrl;
      try {
        authUrl = loginUrl(result.authUrl);
      } catch (error) {
        if (result.loginId)
          await this.rpc('account/login/cancel', { loginId: result.loginId }).catch(() => this.stopProcess());
        throw error;
      }
      this.loginId = result.loginId;
      this.error = null;
      return authUrl;
    } finally {
      if (generation === this.loginGeneration) this.loginStarting = false;
      this.changed();
    }
  }
  async cancelLogin() {
    this.loginGeneration++;
    const loginId = this.loginId;
    this.loginId = null;
    this.loginStarting = false;
    this.changed();
    if (loginId) await this.rpc('account/login/cancel', { loginId });
    return this.status();
  }
  async logout() {
    this.loggingOut = true;
    this.accountGeneration++;
    this.account = null;
    this.models = [];
    this.changed();
    try {
      await this.start();
      await this.cancelLogin();
      await this.rpc('account/logout');
      this.error = null;
      return this.status();
    } finally {
      this.loggingOut = false;
      this.changed();
    }
  }
  async interrupt() {
    if (this.turn?.threadId && this.turn?.turnId)
      await this.rpc('turn/interrupt', { threadId: this.turn.threadId, turnId: this.turn.turnId });
  }

  async run({ model, instructions, messages, research, signal, onDelta }) {
    await this.start();
    if (!this.account)
      throw new CodexError(
        'Sign in with ChatGPT in Settings to use your Codex subscription.',
        'NOT_CONFIGURED',
      );
    if (this.turn) throw new CodexError('An answer is already running.', 'BUSY');
    if (signal?.aborted) throw signal.reason;
    const cancelStarting = () => this.stopProcess();
    signal?.addEventListener('abort', cancelStarting, { once: true });
    let started;
    try {
      started = await this.rpc('thread/start', {
        model: model || undefined,
        modelProvider: 'openai',
        cwd: this.cwd,
        approvalPolicy: 'never',
        sandbox: 'read-only',
        ephemeral: true,
        baseInstructions: instructions,
        environments: [],
        allowProviderModelFallback: false,
        config: { ...lockedConfig(), web_search: research ? 'live' : 'disabled' },
      });
    } catch (error) {
      if (signal?.aborted) throw signal.reason;
      if (error.code === 'TIMEOUT') this.stopProcess();
      throw error;
    } finally {
      signal?.removeEventListener('abort', cancelStarting);
    }
    const threadId = started.thread.id;
    let resolve, reject;
    const finished = new Promise((yes, no) => {
      resolve = yes;
      reject = no;
    });
    // Attach immediately so an abort while turn/start is pending cannot be unhandled.
    finished.catch(() => {});
    const turn = {
      threadId,
      turnId: null,
      resolve,
      reject,
      onDelta,
      bytes: 0,
      items: new Map(),
      deltas: new Map(),
    };
    this.turn = turn;
    let interruptTimer;
    const abort = () => {
      const error = signal.reason || new CodexError('Answer stopped.', 'CANCELLED');
      if (!turn.turnId) {
        reject(error);
        this.stopProcess();
        return;
      }
      this.interrupt().catch(() => {
        if (this.turn !== turn) return;
        reject(error);
        this.stopProcess();
      });
      interruptTimer = setTimeout(() => {
        if (this.turn !== turn) return;
        reject(error);
        this.stopProcess();
      }, 1500);
    };
    signal?.addEventListener('abort', abort, { once: true });
    try {
      if (signal?.aborted) throw signal.reason;
      const result = await this.rpc('turn/start', {
        threadId,
        input: [{ type: 'text', text: JSON.stringify(messages), text_elements: [] }],
        environments: [],
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'readOnly', networkAccess: false },
      });
      turn.turnId = result.turn.id;
      if (signal?.aborted) throw signal.reason;
      return await finished;
    } catch (error) {
      if (error.code === 'TIMEOUT') this.stopProcess();
      if (signal?.aborted) throw signal.reason;
      throw error;
    } finally {
      clearTimeout(interruptTimer);
      signal?.removeEventListener('abort', abort);
      if (this.turn === turn) this.turn = null;
      // Ephemeral threads are never written to history. Release the live subscription.
      if (this.child) this.rpc('thread/unsubscribe', { threadId }).catch(() => {});
    }
  }

  stopProcess() {
    const child = this.child;
    this.child = null;
    this.account = null;
    this.models = [];
    this.loginId = null;
    this.loginStarting = false;
    this.loginGeneration++;
    this.accountGeneration++;
    this.rejectPending(new CodexError('The Codex connection closed.', 'CLOSED'));
    child?.stdin.end();
    child?.kill();
    this.changed();
  }
  close() {
    this.closed = true;
    this.turn?.reject(new CodexError('Answer stopped.', 'CANCELLED'));
    this.stopProcess();
  }
}

module.exports = {
  CodexClient,
  CodexError,
  VERSION,
  DISABLED_FEATURES,
  executablePath,
  isolatedEnvironment,
  lockedConfig,
  loginUrl,
};
