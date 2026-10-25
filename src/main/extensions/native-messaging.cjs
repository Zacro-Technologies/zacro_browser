'use strict';
// Only the main process may resolve registrations, approve identities or spawn.
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn, execFile } = require('node:child_process');
const { TextDecoder } = require('node:util');
const MAX_MANIFEST = 64 * 1024;
const MAX_EXECUTABLE = 256 * 1024 * 1024;
const LITTLE = os.endianness() === 'LE';
const fail = (message) => new Error(`Native messaging ${message}`);
function validateName(name) {
  if (typeof name !== 'string' || name.length > 255 || !/^[a-z0-9_]+(?:\.[a-z0-9_]+)*$/.test(name))
    throw fail('host name is invalid');
}
function hostRegistrationPaths(name, { platform = process.platform, home = os.homedir() } = {}) {
  validateName(name);
  if (platform === 'darwin')
    return [
      path.join(home, 'Library/Application Support/Google/Chrome/NativeMessagingHosts', `${name}.json`),
      `/Library/Google/Chrome/NativeMessagingHosts/${name}.json`,
    ];
  if (platform === 'linux')
    return [
      path.join(home, '.config/google-chrome/NativeMessagingHosts', `${name}.json`),
      `/etc/opt/chrome/native-messaging-hosts/${name}.json`,
    ];
  return [];
}
function readWindowsRegistry(hive, view, key) {
  return new Promise((resolve) => {
    const executable = path.win32.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'reg.exe');
    execFile(
      executable,
      ['query', `${hive}\\${key}`, '/ve', `/reg:${view}`],
      { windowsHide: true, timeout: 3000, maxBuffer: 64 * 1024, encoding: 'utf8' },
      (error, stdout) => {
        if (error) return resolve(null);
        const match = stdout.match(/^\s*(?:\(Default\)|<NO NAME>)\s+REG_SZ\s+(.+)\s*$/im);
        resolve(match ? match[1].trim() : null);
      },
    );
  });
}
async function fingerprint(executable) {
  const handle = await fs.open(executable, 'r');
  try {
    const before = await handle.stat({ bigint: true });
    if (!before.isFile() || before.size > BigInt(MAX_EXECUTABLE)) throw fail('host executable is invalid');
    const hash = crypto.createHash('sha256');
    const buffer = Buffer.alloc(64 * 1024);
    let total = 0;
    while (true) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
      if (!bytesRead) break;
      total += bytesRead;
      if (total > MAX_EXECUTABLE) throw fail('host executable is too large');
      hash.update(buffer.subarray(0, bytesRead));
    }
    const after = await handle.stat({ bigint: true });
    const fields = ['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'];
    if (fields.some((key) => before[key] !== after[key])) throw fail('host executable changed');
    return { sha256: hash.digest('hex'), stat: fields.map((key) => String(after[key])).join(':') };
  } finally {
    await handle.close();
  }
}
function createHostResolver({
  platform = process.platform,
  home = os.homedir(),
  readRegistry = readWindowsRegistry,
  discoverPaths,
} = {}) {
  return async (name, context) => {
    validateName(name);
    const origin = `chrome-extension://${context.extensionId}/`;
    let paths;
    if (discoverPaths) paths = await discoverPaths(name);
    else if (platform === 'win32') {
      paths = [];
      registration: for (const view of [32, 64])
        for (const hive of ['HKCU', 'HKLM']) {
          const result = await readRegistry(
            hive,
            view,
            `Software\\Google\\Chrome\\NativeMessagingHosts\\${name}`,
          );
          if (result) {
            paths.push(result);
            break registration;
          }
        }
    } else paths = hostRegistrationPaths(name, { platform, home });
    const pathAPI = platform === 'win32' ? path.win32 : path;
    for (const filename of paths) {
      if (typeof filename !== 'string' || !pathAPI.isAbsolute(filename))
        throw fail('registered manifest path is invalid');
      let bytes;
      try {
        const handle = await fs.open(filename, 'r');
        try {
          const stat = await handle.stat();
          if (!stat.isFile() || stat.size > MAX_MANIFEST) throw fail('host manifest is too large or invalid');
          bytes = Buffer.alloc(MAX_MANIFEST + 1);
          const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0);
          bytes = bytes.subarray(0, bytesRead);
          if (bytes.length > MAX_MANIFEST) throw fail('host manifest is too large');
        } finally {
          await handle.close();
        }
      } catch (error) {
        if (error.code === 'ENOENT') continue;
        throw fail('host manifest cannot be read');
      }
      let manifest;
      try {
        manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      } catch {
        throw fail('host manifest is invalid');
      }
      if (
        !manifest ||
        manifest.name !== name ||
        manifest.type !== 'stdio' ||
        typeof manifest.description !== 'string' ||
        !Array.isArray(manifest.allowed_origins) ||
        !manifest.allowed_origins.length ||
        manifest.allowed_origins.some(
          (value) => typeof value !== 'string' || !/^chrome-extension:\/\/[a-p]{32}\/$/.test(value),
        ) ||
        !manifest.allowed_origins.includes(origin)
      )
        throw fail('host manifest or allowed origin is invalid');
      if (
        typeof manifest.path !== 'string' ||
        !manifest.path ||
        manifest.path.includes('\0') ||
        /^[a-z]+:\/\//i.test(manifest.path) ||
        (platform !== 'win32' && !pathAPI.isAbsolute(manifest.path))
      )
        throw fail('host executable path is invalid');
      const registeredExecutablePath = pathAPI.resolve(pathAPI.dirname(filename), manifest.path);
      try {
        const manifestPath = await fs.realpath(filename);
        const executablePath = await fs.realpath(registeredExecutablePath);
        if (platform !== 'win32') await fs.access(executablePath, 1);
        const executableIdentity = await fingerprint(executablePath);
        const manifestSha256 = crypto.createHash('sha256').update(bytes).digest('hex');
        const review = {
          name,
          origin,
          registeredManifestPath: filename,
          manifestPath,
          registeredExecutablePath,
          executablePath,
          manifestSha256,
          executableSha256: executableIdentity.sha256,
          executableStat: executableIdentity.stat,
        };
        review.identity = crypto.createHash('sha256').update(JSON.stringify(review)).digest('hex');
        return Object.freeze(review);
      } catch {
        throw fail('host executable cannot be verified');
      }
    }
    throw fail('registered host not found');
  };
}
class NativeMessagingBroker {
  constructor({
    resolveHost = createHostResolver(),
    approveHost = async () => false,
    emit = () => {},
    spawnHost = spawn,
    maxPorts = 16,
    maxContextPorts = 8,
    maxOutgoingBytes = 4 * 1024 * 1024,
    maxQueueBytes = 4 * 1024 * 1024,
    sendTimeoutMs = 30000,
    idleTimeoutMs = 300000,
    platform = process.platform,
  } = {}) {
    Object.assign(this, {
      resolveHost,
      approveHost,
      emit,
      spawnHost,
      maxPorts,
      maxContextPorts,
      maxOutgoingBytes,
      maxQueueBytes,
      sendTimeoutMs,
      idleTimeoutMs,
      platform,
    });
    this.ports = new Map();
    this.cancellations = new Map();
    this.approvals = new Set();
    this.closed = false;
  }
  check(context) {
    if (
      this.closed ||
      !context ||
      typeof context.profileId !== 'string' ||
      !context.profileId ||
      !/^[a-p]{32}$/.test(context.extensionId) ||
      !(
        Number.isSafeInteger(context.generation) ||
        (typeof context.generation === 'string' &&
          context.generation.length > 0 &&
          context.generation.length <= 256)
      ) ||
      typeof context.contextId !== 'string' ||
      !context.contextId ||
      typeof context.guard !== 'function' ||
      context.signal?.aborted
    )
      throw fail('context is closed or revoked');
    if (!context.permissions?.includes('nativeMessaging')) throw fail('permission is required');
    try {
      if (context.guard() === false) throw fail('revoked');
    } catch {
      this.revoke(context);
      throw fail('context is revoked');
    }
  }
  scope(context) {
    return [context.profileId, context.extensionId, context.generation, context.contextId];
  }
  key(context, portId) {
    if (typeof portId !== 'string' || !portId || portId.length > 256) throw fail('port ID is invalid');
    return JSON.stringify([...this.scope(context), portId]);
  }
  get(context, portId) {
    this.check(context);
    const record = this.ports.get(this.key(context, portId));
    if (!record || record.closed) throw fail('port is disconnected');
    return record;
  }
  async connect(context, name, portId) {
    this.check(context);
    validateName(name);
    const key = this.key(context, portId);
    const scopeKey = JSON.stringify(this.scope(context));
    const cancellation = this.cancellations.get(scopeKey);
    if (cancellation?.blocked) throw fail('context cancellation limit reached');
    if (cancellation?.portIds.delete(portId)) {
      if (!cancellation.portIds.size) this.cancellations.delete(scopeKey);
      throw fail('port is disconnected');
    }
    if (this.ports.has(key)) throw fail('port already exists');
    if (
      this.ports.size >= this.maxPorts ||
      [...this.ports.values()].filter(
        (record) =>
          record.context.profileId === context.profileId &&
          record.context.extensionId === context.extensionId &&
          record.context.generation === context.generation &&
          record.context.contextId === context.contextId,
      ).length >= this.maxContextPorts
    )
      throw fail('process limit reached');
    const record = {
      key,
      context,
      portId,
      buffer: Buffer.alloc(0),
      queue: [],
      queuedBytes: 0,
      closed: false,
      received: 0,
      epoch: Date.now(),
    };
    record.cancelled = new Promise((_, reject) => {
      record.cancel = reject;
    });
    record.cancelled.catch(() => {});
    this.ports.set(key, record);
    record.abort = () => this.close(record, 'Native messaging context is cancelled');
    context.signal?.addEventListener('abort', record.abort, { once: true });
    this.touch(record);
    try {
      const review = await Promise.race([this.resolveHost(name, context), record.cancelled]);
      this.current(record);
      const approvalKey = JSON.stringify([context.profileId, context.extensionId, review.identity]);
      if (!this.approvals.has(approvalKey)) {
        if (
          (await Promise.race([
            this.approveHost(
              Object.freeze({
                ...review,
                profileId: context.profileId,
                extensionId: context.extensionId,
                generation: context.generation,
              }),
            ),
            record.cancelled,
          ])) !== true
        )
          throw fail('local host approval was withheld');
        this.current(record);
      }
      const verified = await Promise.race([this.resolveHost(name, context), record.cancelled]);
      this.current(record);
      if (verified.identity !== review.identity) throw fail('registered host changed during approval');
      if (this.approvals.size >= 256) this.approvals.delete(this.approvals.values().next().value);
      this.approvals.add(approvalKey);
      const args = [verified.origin];
      if (this.platform === 'win32') args.push('--parent-window=0');
      const child = (record.child = this.spawnHost(verified.executablePath, args, {
        cwd: path.dirname(verified.executablePath),
        shell: false,
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'ignore'],
      }));
      child.on('error', () => this.close(record, 'Native messaging host failed to start'));
      child.stdout.on('data', (chunk) => this.receive(record, chunk));
      child.stdout.on('end', () =>
        this.close(
          record,
          record.buffer.length
            ? 'Native messaging host returned a truncated frame'
            : 'Native messaging host exited',
        ),
      );
      child.stdout.on('error', () => this.close(record, 'Native messaging host output failed'));
      child.stdin.on('error', () => this.close(record, 'Native messaging host input failed'));
      child.on('exit', () => {
        if (record.closed) return;
        record.killTimer = setTimeout(() => this.close(record, 'Native messaging host exited'), 100);
        record.killTimer.unref?.();
      });
      record.ready = true;
      for (const bytes of record.queue.splice(0)) this.write(record, bytes);
      return { portId };
    } catch (error) {
      this.close(
        record,
        error.message?.startsWith('Native messaging') ? error.message : 'Native messaging connection failed',
      );
      throw fail(
        error.message?.startsWith('Native messaging') ? error.message.slice(17) : 'connection failed',
      );
    }
  }
  current(record) {
    this.check(record.context);
    if (record.closed || this.ports.get(record.key) !== record) throw fail('context is closed or revoked');
  }
  touch(record) {
    clearTimeout(record.idleTimer);
    record.idleTimer = setTimeout(
      () => this.close(record, 'Native messaging connection timed out'),
      this.idleTimeoutMs,
    );
    record.idleTimer.unref?.();
  }
  post(context, portId, value) {
    const record = this.get(context, portId);
    let body;
    try {
      body = Buffer.from(JSON.stringify(value), 'utf8');
    } catch {
      throw fail('message is not JSON serializable');
    }
    if (!body.length || body.length > this.maxOutgoingBytes) throw fail('message size limit exceeded');
    if (record.queuedBytes + body.length + 4 > this.maxQueueBytes) {
      this.close(record, 'Native messaging queue limit exceeded');
      throw fail('queue limit exceeded');
    }
    const bytes = Buffer.allocUnsafe(body.length + 4);
    if (LITTLE) bytes.writeUInt32LE(body.length);
    else bytes.writeUInt32BE(body.length);
    body.copy(bytes, 4);
    record.queuedBytes += bytes.length;
    this.touch(record);
    if (record.ready) this.write(record, bytes);
    else record.queue.push(bytes);
  }
  write(record, bytes) {
    if (record.closed) return;
    try {
      record.child.stdin.write(bytes, () => {
        record.queuedBytes = Math.max(0, record.queuedBytes - bytes.length);
      });
    } catch {
      this.close(record, 'Native messaging host input failed');
    }
  }
  receive(record, chunk) {
    if (record.closed) return;
    try {
      this.current(record);
      this.touch(record);
      // Pipe chunks are consumed immediately; retained partial frame <= 1 MiB.
      record.buffer = Buffer.concat([record.buffer, chunk]);
      while (record.buffer.length >= 4) {
        const length = LITTLE ? record.buffer.readUInt32LE(0) : record.buffer.readUInt32BE(0);
        if (!length || length > 1024 * 1024) throw fail('host frame size is invalid');
        if (record.buffer.length < length + 4) break;
        if (Date.now() - record.epoch >= 1000) {
          record.epoch = Date.now();
          record.received = 0;
        }
        if (++record.received > 1024) throw fail('host message rate limit exceeded');
        let value;
        try {
          value = JSON.parse(
            new TextDecoder('utf-8', { fatal: true }).decode(record.buffer.subarray(4, length + 4)),
          );
        } catch {
          throw fail('host returned invalid JSON or UTF-8');
        }
        record.buffer = record.buffer.subarray(length + 4);
        if (record.first) {
          record.first.resolve(value);
          this.close(record);
          return;
        }
        this.emit(record.context, { type: 'message', portId: record.portId, message: value });
        if (record.closed) return;
      }
    } catch (error) {
      this.close(
        record,
        error.message?.startsWith('Native messaging')
          ? error.message
          : 'Native messaging host communication failed',
      );
    }
  }
  async send(context, name, value) {
    const portId = `send-${crypto.randomUUID()}`;
    let resolve, reject;
    const response = new Promise((yes, no) => {
      resolve = yes;
      reject = no;
    });
    response.catch(() => {});
    const connecting = this.connect(context, name, portId);
    const record = this.ports.get(this.key(context, portId));
    if (!record) {
      await connecting;
      throw fail('port is disconnected');
    }
    record.first = { resolve, reject };
    record.sendTimer = setTimeout(
      () => this.close(record, 'Native messaging request timed out'),
      this.sendTimeoutMs,
    );
    try {
      await connecting;
      this.post(context, portId, value);
      return await response;
    } finally {
      this.close(record);
    }
  }
  disconnect(context, portId) {
    this.check(context);
    const record = this.ports.get(this.key(context, portId));
    if (record) return this.close(record);
    // Cancellation may beat connect through the transport. Keep it until that
    // request arrives or its authenticated context dies; expiry could revive it.
    const scopeKey = JSON.stringify(this.scope(context));
    let cancellation = this.cancellations.get(scopeKey);
    if (!cancellation) {
      cancellation = { context, portIds: new Set(), blocked: false };
      this.cancellations.set(scopeKey, cancellation);
    }
    if (cancellation.blocked || cancellation.portIds.has(portId)) return;
    if (cancellation.portIds.size >= 256) {
      cancellation.blocked = true;
      cancellation.portIds.clear();
    } else cancellation.portIds.add(portId);
  }
  close(record, error) {
    if (record.closed) return;
    record.closed = true;
    this.ports.delete(record.key);
    record.cancel(new Error(error || 'Native messaging port disconnected'));
    clearTimeout(record.idleTimer);
    clearTimeout(record.sendTimer);
    clearTimeout(record.killTimer);
    record.context.signal?.removeEventListener('abort', record.abort);
    record.queue = [];
    record.queuedBytes = 0;
    record.buffer = Buffer.alloc(0);
    if (record.child) {
      record.child.stdin.destroy();
      record.child.stdout.destroy();
      if (record.child.exitCode === null && record.child.signalCode === null) {
        record.child.kill();
        const timer = setTimeout(() => {
          if (record.child.exitCode === null && record.child.signalCode === null)
            record.child.kill('SIGKILL');
        }, 500);
        timer.unref?.();
      }
    }
    if (record.first) record.first.reject(new Error(error || 'Native messaging port disconnected'));
    else
      this.emit(record.context, { type: 'disconnect', portId: record.portId, ...(error ? { error } : {}) });
  }
  revoke(selector = {}) {
    for (const [key, cancellation] of this.cancellations)
      if (
        ['profileId', 'extensionId', 'generation', 'contextId'].every(
          (key) => selector[key] === undefined || selector[key] === cancellation.context[key],
        )
      )
        this.cancellations.delete(key);
    for (const record of this.ports.values())
      if (
        ['profileId', 'extensionId', 'generation', 'contextId'].every(
          (key) => selector[key] === undefined || selector[key] === record.context[key],
        )
      )
        this.close(record, 'Native messaging context is revoked');
  }
  dispose() {
    this.closed = true;
    this.revoke();
    this.approvals.clear();
  }
}
module.exports = { NativeMessagingBroker, createHostResolver, hostRegistrationPaths };
