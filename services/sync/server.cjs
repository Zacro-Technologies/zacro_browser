'use strict';
const http = require('node:http');
const https = require('node:https');
const { randomUUID } = require('node:crypto');
const { SyncStore, restoreSyncBackup } = require('./store.cjs');
const { Authentication, failure, passwordValue, usernameValue, label } = require('./auth.cjs');
const { digest, token } = require('./crypto.cjs');
const { SyncProtocol } = require('./protocol.cjs');

const denied = () => failure(401, 'unauthorized', 'Authentication required or credentials are invalid.');
const missing = () => failure(404, 'not_found', 'The requested item is not available.');
const accountView = (a) => ({ id: a.id, username: a.username });
const deviceView = (d) => ({
  id: d.id,
  name: d.name,
  platform: d.platform,
  createdAt: d.created,
  lastSeenAt: d.last_seen,
  revoked: Boolean(d.revoked),
});

async function readBody(req) {
  if (!['POST', 'PATCH', 'DELETE'].includes(req.method)) return {};
  if (req.headers['content-length'] && Number(req.headers['content-length']) > 1024 * 1024) {
    req.resume();
    throw failure(413, 'too_large', 'Request is too large.');
  }
  const chunks = [];
  let size = 0;
  await new Promise((resolve, reject) => {
    let exceeded = false;
    req.on('data', (chunk) => {
      if (exceeded) return;
      size += chunk.length;
      if (size > 1024 * 1024) {
        exceeded = true;
        chunks.length = 0;
        reject(failure(413, 'too_large', 'Request is too large.'));
      } else chunks.push(chunk);
    });
    req.once('end', resolve);
    req.once('error', reject);
    req.once('aborted', () => reject(failure(400, 'aborted', 'Request was interrupted.')));
  });
  if (!size) return {};
  if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] || ''))
    throw failure(415, 'content_type', 'Send JSON.');
  let value;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw failure(400, 'invalid_json', 'Invalid JSON.');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw failure(400, 'invalid_json', 'Expected a JSON object.');
  return value;
}

async function createSyncService({
  directory,
  masterKey,
  host = '127.0.0.1',
  port = 0,
  allowInsecureLoopback = false,
  tls,
  trustedProxy = false,
  publicURL,
  log,
} = {}) {
  if (publicURL) {
    let url;
    try {
      url = new URL(publicURL);
    } catch {
      throw new Error('Invalid public HTTPS URL');
    }
    if (
      url.protocol !== 'https:' ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      url.pathname !== '/'
    )
      throw new Error('Public URL must be an HTTPS origin without credentials');
  }
  const loopback = ['127.0.0.1', '::1'].includes(host);
  if (!tls && !(loopback && (allowInsecureLoopback || (trustedProxy && /^https:\/\//.test(publicURL || '')))))
    throw new Error('HTTPS or explicitly configured loopback development/trusted proxy is required');
  const store = new SyncStore(directory, masterKey);
  const auth = new Authentication();
  const protocol = new SyncProtocol(store);
  let closed = false;
  let unhealthy = false;

  function authorize(value) {
    if (typeof value !== 'string' || !/^Bearer [A-Za-z0-9_-]{43}$/.test(value)) throw denied();
    const d = store.get('SELECT * FROM devices WHERE access_hash = ?', digest(value.slice(7)));
    if (!d || d.revoked || d.access_expires <= Date.now()) throw denied();
    const a = store.get('SELECT * FROM accounts WHERE id = ?', d.account_id);
    if (!a) throw denied();
    store.run('UPDATE devices SET last_seen = ? WHERE id = ?', Date.now(), d.id);
    return { account: a, device: d };
  }
  function recheck(state) {
    const d = store.get('SELECT * FROM devices WHERE id = ?', state.device.id);
    const a = store.get('SELECT * FROM accounts WHERE id = ?', state.account.id);
    if (
      !d ||
      d.revoked ||
      d.access_hash !== state.device.access_hash ||
      !a ||
      a.password !== state.account.password
    )
      throw denied();
    return a;
  }
  function revoke(id) {
    store.run('UPDATE devices SET revoked = 1, access_hash = NULL, refresh_hash = NULL WHERE id = ?', id);
  }
  function credentials(account, device) {
    const accessToken = token(),
      refreshToken = token(),
      now = Date.now();
    store.run(
      'UPDATE devices SET access_hash = ?, access_expires = ?, refresh_hash = ?, refresh_expires = ?, last_seen = ? WHERE id = ?',
      digest(accessToken),
      now + 15 * 60000,
      digest(refreshToken),
      now + 30 * 86400000,
      now,
      device.id,
    );
    return {
      account: accountView(account),
      device: deviceView(device),
      accessToken,
      refreshToken,
      expiresAt: now + 15 * 60000,
    };
  }
  function enroll(account, body) {
    const id = randomUUID(),
      now = Date.now();
    const name = label(body.deviceName),
      platform = label(body.platform, 32);
    if (
      store.get('SELECT count(*) AS n FROM devices WHERE account_id = ? AND revoked = 0', account.id).n >= 100
    )
      throw failure(409, 'device_limit', 'Remove a device before adding another.');
    store.run(
      'INSERT INTO devices (id,account_id,name,platform,created,last_seen,authenticated) VALUES (?,?,?,?,?,?,?)',
      id,
      account.id,
      name,
      platform,
      now,
      now,
      now,
    );
    return credentials(account, store.get('SELECT * FROM devices WHERE id = ?', id));
  }
  function recoveryCodes(accountId) {
    const codes = Array.from({ length: 10 }, () => token());
    store.run('DELETE FROM recovery WHERE account_id = ?', accountId);
    for (const code of codes) store.run('INSERT INTO recovery VALUES (?,?)', accountId, digest(code));
    store.recordCredentials(accountId);
    return codes;
  }
  async function confirmPassword(state, body) {
    auth.rate(`confirm/${state.account.id}`, 12, 15 * 60000);
    if (!(await auth.verify(body.password, state.account.password))) throw denied();
    return recheck(state);
  }
  async function route(req, body, url) {
    const method = req.method,
      route = url.pathname;
    if (method === 'GET' && ['/health', '/ready'].includes(route))
      return {
        status: unhealthy && route === '/ready' ? 503 : 200,
        body: { status: unhealthy ? 'storage_unavailable' : closed ? 'stopping' : 'ok', schema: 1 },
      };
    if (unhealthy) throw failure(503, 'storage_unavailable', 'Storage needs operator attention.');
    if (!route.startsWith('/v1/')) throw missing();
    auth.rate(`network/${req.socket.remoteAddress}`, 600, 60000);
    const path = route.slice(3);
    if (method === 'POST' && ['/accounts', '/sessions', '/accounts/recover'].includes(path)) {
      auth.rate(`auth-ip/${req.socket.remoteAddress}`, 60, 60000);
      const username = usernameValue(body.username);
      auth.rate(`auth-account/${username}`, 12, 15 * 60000);
      label(body.deviceName);
      label(body.platform, 32);
      const account = store.get('SELECT * FROM accounts WHERE username = ?', username);
      if (path === '/accounts') {
        const hashed = await auth.hash(body.password);
        if (account || store.get('SELECT id FROM accounts WHERE username = ?', username))
          throw failure(409, 'unavailable', 'This username is unavailable.');
        return {
          status: 201,
          body: store.transaction(() => {
            const a = store.createAccount(username, hashed);
            return { ...enroll(a, body), recoveryCodes: recoveryCodes(a.id) };
          }),
        };
      }
      if (path === '/sessions') {
        const valid = await auth.verify(body.password, account?.password);
        const current = account && store.get('SELECT * FROM accounts WHERE id = ?', account.id);
        if (!valid || !current || current.password !== account.password) throw denied();
        return { status: 200, body: store.transaction(() => enroll(current, body)) };
      }
      passwordValue(body.newPassword);
      if (typeof body.recoveryCode !== 'string' || body.recoveryCode.length > 128) throw denied();
      const codeHash = digest(body.recoveryCode);
      if (
        !account ||
        !store.get('SELECT hash FROM recovery WHERE account_id = ? AND hash = ?', account.id, codeHash)
      )
        throw denied();
      const hashed = await auth.hash(body.newPassword);
      return {
        status: 200,
        body: store.transaction(() => {
          const current = store.get('SELECT * FROM accounts WHERE id = ?', account.id);
          if (
            !current ||
            current.password !== account.password ||
            !store.get('SELECT hash FROM recovery WHERE account_id = ? AND hash = ?', account.id, codeHash)
          )
            throw denied();
          store.run('UPDATE accounts SET password = ? WHERE id = ?', hashed, account.id);
          store.run(
            'UPDATE devices SET revoked = 1, access_hash = NULL, refresh_hash = NULL WHERE account_id = ?',
            account.id,
          );
          return { ...enroll(account, body), recoveryCodes: recoveryCodes(account.id) };
        }),
      };
    }
    if (method === 'POST' && path === '/sessions/refresh') {
      auth.rate(`refresh/${req.socket.remoteAddress}`, 60, 60000);
      if (typeof body.refreshToken !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.refreshToken))
        throw denied();
      const hash = digest(body.refreshToken),
        now = Date.now();
      store.run('DELETE FROM used_refresh WHERE expires <= ?', now);
      const old = store.get('SELECT * FROM used_refresh WHERE hash = ?', hash);
      if (old) {
        revoke(old.device_id);
        throw denied();
      }
      const d = store.get('SELECT * FROM devices WHERE refresh_hash = ?', hash);
      if (!d || d.revoked || d.refresh_expires <= now) throw denied();
      const a = store.get('SELECT * FROM accounts WHERE id = ?', d.account_id);
      if (!a) throw denied();
      return {
        status: 200,
        body: store.transaction(() => {
          store.run('INSERT INTO used_refresh VALUES (?,?,?)', hash, d.id, d.refresh_expires);
          return credentials(a, d);
        }),
      };
    }
    const state = authorize(req.headers.authorization),
      a = state.account,
      d = state.device;
    if (method === 'GET' && path === '/datasets')
      return { status: 200, body: { datasets: protocol.list(a) } };
    if (method === 'POST' && path === '/datasets') return { status: 201, body: protocol.create(a, body) };
    const datasetMatch = /^\/datasets\/([a-f0-9-]{36})(?:\/(snapshot|changes|operations))?$/.exec(path);
    if (datasetMatch) {
      const [, id, action] = datasetMatch;
      if (method === 'GET' && action === 'snapshot')
        return { status: 200, body: protocol.snapshot(a, id, url.searchParams.get('settings') !== '0') };
      if (method === 'GET' && action === 'changes')
        return { status: 200, body: protocol.changes(a, id, url.searchParams) };
      if (method === 'POST' && action === 'operations')
        return { status: 200, body: protocol.mutate(a, d, id, body) };
      if (method === 'DELETE' && !action) {
        if (body.confirm !== true)
          throw failure(400, 'confirmation_required', 'Confirm cloud dataset deletion.');
        await confirmPassword(state, body);
        protocol.remove(a, id);
        return { status: 200, body: { ok: true } };
      }
    }
    if (method === 'GET' && path === '/account')
      return { status: 200, body: { account: accountView(a), device: deviceView(d) } };
    if (method === 'GET' && path === '/devices')
      return {
        status: 200,
        body: {
          devices: store
            .all('SELECT * FROM devices WHERE account_id = ? ORDER BY created,id', a.id)
            .map(deviceView),
        },
      };
    if (method === 'POST' && path === '/devices') {
      await confirmPassword(state, body);
      return { status: 201, body: store.transaction(() => enroll(a, body)) };
    }
    const deviceMatch = /^\/devices\/([a-f0-9-]{36})$/.exec(path);
    if (deviceMatch && ['PATCH', 'DELETE'].includes(method)) {
      if (!store.get('SELECT id FROM devices WHERE id = ? AND account_id = ?', deviceMatch[1], a.id))
        throw missing();
      if (method === 'DELETE') revoke(deviceMatch[1]);
      else
        store.run(
          'UPDATE devices SET name = ? WHERE id = ? AND account_id = ?',
          label(body.name),
          deviceMatch[1],
          a.id,
        );
      return { status: 200, body: { ok: true } };
    }
    if (method === 'DELETE' && path === '/sessions/current') {
      revoke(d.id);
      return { status: 200, body: { ok: true } };
    }
    if (method === 'POST' && path === '/account/password') {
      await confirmPassword(state, body);
      const hashed = await auth.hash(body.newPassword);
      recheck(state);
      store.transaction(() => {
        store.run('UPDATE accounts SET password = ? WHERE id = ?', hashed, a.id);
        store.run(
          'UPDATE devices SET revoked = 1, access_hash = NULL, refresh_hash = NULL WHERE account_id = ? AND id != ?',
          a.id,
          d.id,
        );
        store.run('UPDATE devices SET authenticated = ? WHERE id = ?', Date.now(), d.id);
        store.recordCredentials(a.id);
      });
      return { status: 200, body: { ok: true } };
    }
    if (method === 'POST' && path === '/account/recovery-codes') {
      await confirmPassword(state, body);
      return { status: 200, body: { recoveryCodes: store.transaction(() => recoveryCodes(a.id)) } };
    }
    if (method === 'DELETE' && path === '/account') {
      if (body.confirm !== true) throw failure(400, 'confirmation_required', 'Confirm account deletion.');
      await confirmPassword(state, body);
      store.deleteAccount(a.id);
      return { status: 200, body: { ok: true } };
    }
    throw missing();
  }

  const listener = async (req, res) => {
    const requestId = randomUUID();
    const began = Date.now();
    res.once('finish', () => {
      if (typeof log === 'function') {
        // Fixed categories avoid retaining user-controlled paths, queries or payloads.
        const category = /^\/v1\/datasets(?:\/|$)/.test(req.url)
          ? 'sync'
          : /^\/v1\//.test(req.url)
            ? 'account'
            : 'health';
        try {
          log({
            event: 'request',
            requestId,
            category,
            status: res.statusCode,
            elapsedMs: Date.now() - began,
          });
        } catch {
          process.stderr.write('Sync request logger failed\n');
        }
      }
    });
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-content-type-options', 'nosniff');
    res.setHeader('x-request-id', requestId);
    res.setHeader('content-type', 'application/json; charset=utf-8');
    try {
      if (closed) throw failure(503, 'stopping', 'Service is stopping.');
      if (req.headers.origin)
        throw failure(403, 'browser_origin', 'Browser-origin requests are not supported.');
      const body = await readBody(req);
      const result = await route(req, body, new URL(req.url, 'http://localhost'));
      res.writeHead(result.status);
      res.end(JSON.stringify(result.body));
    } catch (error) {
      if (['data_integrity', 'storage_unavailable'].includes(error.code)) {
        unhealthy = true;
        error.status = 503;
      }
      res.writeHead(error.status || 500, {
        ...(error.status === 429 ? { 'retry-after': '60' } : {}),
      });
      res.end(
        JSON.stringify({
          error: {
            code: error.code || 'internal_error',
            message: error.status ? error.message : 'The request could not be completed.',
          },
        }),
      );
    }
  };
  const server = tls ? https.createServer(tls, listener) : http.createServer(listener);
  server.maxConnections = 128;
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.maxHeadersCount = 40;
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, host, resolve);
    });
  } catch (error) {
    store.close();
    throw error;
  }
  return {
    url: `${tls ? 'https' : 'http'}://${host.includes(':') ? `[${host}]` : host}:${server.address().port}`,
    backup(directory) {
      return store.backup(directory);
    },
    rotateMasterKey(key) {
      return store.rotateMasterKey(key);
    },
    async close() {
      if (closed) return;
      closed = true;
      await new Promise((resolve) => {
        server.close(resolve);
        server.closeIdleConnections();
      });
      store.close();
    },
  };
}
module.exports = { createSyncService, restoreSyncBackup };
