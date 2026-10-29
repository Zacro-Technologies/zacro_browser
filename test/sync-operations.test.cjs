'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const syncFS = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { randomBytes, randomUUID, createHash } = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { execFile, spawn } = require('node:child_process');
const { promisify } = require('node:util');
const { createInterface } = require('node:readline');
const { createSyncService, restoreSyncBackup } = require('../services/sync/server.cjs');

const password = 'Synthetic operator test password';
const execute = promisify(execFile);
const cli = path.resolve(__dirname, '../services/sync/cli.cjs');
async function setup(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-operations-'));
  const options = {
    directory: path.join(root, 'live'),
    masterKey: randomBytes(32),
    allowInsecureLoopback: true,
  };
  let service = await createSyncService(options);
  t.after(async () => {
    await service.close();
    await fs.rm(root, { recursive: true, force: true });
  });
  const request = async (route, token, body, method = body ? 'POST' : 'GET') => {
    const res = await fetch(service.url + '/v1' + route, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, data: await res.json() };
  };
  const user = (
    await request('/accounts', null, {
      username: 'operator.test',
      password,
      deviceName: 'Test',
      platform: 'test',
    })
  ).data;
  const restart = async (overrides = {}) => {
    await service.close();
    service = await createSyncService({ ...options, ...overrides });
  };
  return {
    root,
    options,
    user,
    request,
    restart,
    get service() {
      return service;
    },
  };
}

test('one service instance owns a directory and a failed startup releases its ownership', async (t) => {
  const f = await setup(t);
  await assert.rejects(async () => {
    const duplicate = await createSyncService(f.options);
    await duplicate.close();
  }, /in use|locked/i);
  await f.service.close();
  await assert.rejects(createSyncService({ ...f.options, masterKey: randomBytes(32) }), /key|authenticat/i);
  await f.restart();
  assert.equal((await f.request('/account', f.user.accessToken)).status, 200);
});

test('a failed durable security-ledger open makes readiness fail closed', async (t) => {
  const f = await setup(t);
  const ledger = path.join(f.options.directory, 'deletions.jsonl');
  await fs.rename(ledger, ledger + '.retained');
  await fs.mkdir(ledger);
  const result = await f.request('/account/password', f.user.accessToken, {
    password,
    newPassword: 'Different synthetic password',
  });
  assert.equal(result.status, 503);
  assert.equal((await fetch(f.service.url + '/ready')).status, 503);
  assert.equal((await f.request('/account', f.user.accessToken)).status, 503);
});

// Model only the Windows regular-file flush access contract; SQLite, file
// contents, metadata authentication and restore continue through the real code.
function snapshotFlushContract(t, directory, failure) {
  const open = syncFS.openSync,
    close = syncFS.closeSync,
    flush = syncFS.fsyncSync;
  const snapshots = new Map(),
    flushed = [];
  t.mock.method(syncFS, 'openSync', (filename, flags, ...args) => {
    const snapshot =
      typeof filename === 'string' && path.dirname(filename) === directory && filename.endsWith('.sqlite');
    const writable =
      typeof flags === 'number'
        ? Boolean(flags & (syncFS.constants.O_WRONLY | syncFS.constants.O_RDWR))
        : /[wa+]/.test(flags);
    if (snapshot && writable && failure === 'open')
      throw Object.assign(new Error('Snapshot write access denied'), { code: 'EACCES' });
    const fd = open(filename, flags, ...args);
    if (snapshot) snapshots.set(fd, { filename, writable });
    return fd;
  });
  t.mock.method(syncFS, 'closeSync', (fd) => {
    snapshots.delete(fd);
    return close(fd);
  });
  t.mock.method(syncFS, 'fsyncSync', (fd) => {
    const snapshot = snapshots.get(fd);
    if (snapshot) {
      if (!snapshot.writable || failure === 'EPERM')
        throw Object.assign(new Error('Snapshot flush requires write access'), { code: 'EPERM' });
      if (failure === 'EIO') throw Object.assign(new Error('Snapshot flush failed'), { code: 'EIO' });
      // A successful flush still executes the host's real filesystem operation.
      flush(fd);
      flushed.push(snapshot.filename);
      return;
    }
    return flush(fd);
  });
  return flushed;
}

test('backup durably flushes a nontruncated SQLite snapshot with Windows write access', async (t) => {
  const f = await setup(t);
  const directory = path.join(f.root, 'backups');
  const flushed = snapshotFlushContract(t, directory);
  const backup = await f.service.backup(directory);
  assert.deepEqual(flushed, [backup.path]);
  assert.equal(
    createHash('sha256')
      .update(await fs.readFile(backup.path))
      .digest('hex'),
    backup.sha256,
  );
  await f.service.close();
  const restored = path.join(f.root, 'restored-write-access');
  await restoreSyncBackup({
    directory: restored,
    backupPath: backup.path,
    ledgerPath: path.join(f.options.directory, 'deletions.jsonl'),
    masterKey: f.options.masterKey,
  });
  const db = new DatabaseSync(path.join(restored, 'sync.sqlite'), { readOnly: true });
  try {
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    assert.equal(db.prepare('SELECT username FROM accounts').get().username, 'operator.test');
    assert.equal(db.prepare('SELECT count(*) AS n FROM devices WHERE revoked = 0').get().n, 0);
  } finally {
    db.close();
  }
});

for (const [failure, code] of [
  ['open', 'EACCES'],
  ['EPERM', 'EPERM'],
  ['EIO', 'EIO'],
]) {
  test(`backup rejects a genuine snapshot ${failure} failure without publishing metadata`, async (t) => {
    const f = await setup(t);
    const directory = path.join(f.root, 'backups');
    snapshotFlushContract(t, directory, failure);
    await assert.rejects(async () => f.service.backup(directory), { code });
    assert.equal(
      (await fs.readdir(directory)).some((name) => name.endsWith('.json')),
      false,
    );
  });
}

async function bounded(promise, label, milliseconds = 10000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(label + ' timed out')), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// Windows child.kill('SIGTERM') forcibly terminates Node rather than delivering
// its registered signal handler. Keep actual POSIX delivery and run the portable
// authenticated-parent transport on every platform, including local POSIX runs.
for (const shutdown of process.platform === 'win32' ? ['parent-ipc'] : ['SIGTERM', 'parent-ipc']) {
  test(`operator CLI gracefully stops via ${shutdown} before offline backup and restore`, async (t) => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-cli-'));
    let child, lines, closed;
    t.after(async () => {
      try {
        if (child && child.exitCode === null && child.signalCode === null) {
          child.kill('SIGKILL');
          await bounded(closed, 'CLI forced cleanup', 5000);
        }
      } finally {
        lines?.close();
        await fs.rm(root, { recursive: true, force: true });
      }
    });
    const run = (args) => execute(process.execPath, [cli, ...args], { timeout: 10000 });
    const keyFile = path.join(root, 'master.key'),
      directory = path.join(root, 'data');
    const generated = await run(['generate-key', '--key-file', keyFile]);
    const key = await fs.readFile(keyFile);
    assert.equal(key.length, 32);
    assert.equal(generated.stdout.includes(key.toString('hex')), false);
    if (process.platform !== 'win32') assert.equal((await fs.stat(keyFile)).mode & 0o077, 0);
    const ipc = shutdown === 'parent-ipc';
    const token = randomBytes(32).toString('hex');
    const preload = path.join(__dirname, 'fixtures/sync-cli-shutdown.cjs');
    child = spawn(
      process.execPath,
      [
        ...(ipc ? ['--require', preload] : []),
        cli,
        'serve',
        '--data',
        directory,
        '--key-file',
        keyFile,
        '--port',
        '0',
        '--dev-loopback',
      ],
      {
        stdio: ['ignore', 'pipe', 'pipe', ...(ipc ? ['ipc'] : [])],
        env: {
          ...process.env,
          ...(ipc
            ? { ZACRO_TEST_SHUTDOWN_TOKEN: token, ZACRO_TEST_SHUTDOWN_PARENT: String(process.pid) }
            : {}),
        },
      },
    );
    closed = new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
    let stderr = '';
    child.stderr.on('data', (c) => {
      stderr = (stderr + c).slice(-8000);
    });
    const records = [];
    lines = createInterface({ input: child.stdout });
    const listening = new Promise((resolve, reject) => {
      const fail = () => reject(new Error('CLI exited before listening: ' + stderr));
      child.once('error', reject);
      child.once('close', fail);
      lines.on('line', (line) => {
        try {
          const record = JSON.parse(line);
          records.push(record);
          if (record.event === 'listening') {
            child.off('close', fail);
            resolve(record.url);
          }
        } catch (error) {
          reject(error);
        }
      });
    });
    const url = await bounded(listening, 'CLI startup');
    const ready = () => fetch(url + '/ready', { signal: AbortSignal.timeout(5000) });
    assert.equal((await ready()).status, 200);
    await fs.access(path.join(directory, '.service.lock'));
    const send = (message) =>
      bounded(
        new Promise((resolve, reject) => {
          child.send(message, (error) => (error ? reject(error) : resolve()));
        }),
        'CLI parent IPC',
      );
    if (ipc) {
      // An unauthenticated message must leave the service ready and owned.
      const rejected = new Promise((resolve) => child.once('message', resolve));
      await send({ type: 'zacro-test-graceful-stop', token: '0'.repeat(64) });
      assert.deepEqual(await bounded(rejected, 'CLI invalid capability rejection'), {
        event: 'test-shutdown-rejected',
      });
      assert.equal((await ready()).status, 200);
      await fs.access(path.join(directory, '.service.lock'));
      assert.equal(
        records.some((record) => record.event === 'stopped'),
        false,
      );
      await send({ type: 'zacro-test-graceful-stop', token });
    } else {
      assert.equal(child.kill('SIGTERM'), true);
    }
    assert.deepEqual(await bounded(closed, 'CLI graceful shutdown'), { code: 0, signal: null }, stderr);
    assert.equal(records.filter((record) => record.event === 'stopped').length, 1);
    await assert.rejects(fs.access(path.join(directory, '.service.lock')), { code: 'ENOENT' });
    assert.equal(JSON.stringify(records).includes(key.toString('hex')), false);
    assert.equal(stderr.includes(token), false);
    assert.equal(stderr.includes(key.toString('hex')), false);
    assert.equal(JSON.stringify(records).includes(token), false);
    const backup = JSON.parse(
      (
        await run([
          'backup',
          '--data',
          directory,
          '--key-file',
          keyFile,
          '--backup-dir',
          path.join(root, 'backups'),
        ])
      ).stdout,
    );
    assert.equal(backup.event, 'backup-created');
    const restored = path.join(root, 'restored');
    const restoration = JSON.parse(
      (
        await run([
          'restore',
          '--data',
          restored,
          '--key-file',
          keyFile,
          '--backup',
          backup.path,
          '--ledger',
          path.join(directory, 'deletions.jsonl'),
        ])
      ).stdout,
    );
    assert.equal(restoration.event, 'restored');
    const db = new DatabaseSync(path.join(restored, 'sync.sqlite'), { readOnly: true });
    try {
      assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    } finally {
      db.close();
    }
    await assert.rejects(
      run(['serve', '--data', restored, '--key-file', keyFile, '--host', '0.0.0.0', '--dev-loopback']),
      (error) => {
        assert.equal(error.code, 1);
        assert.equal(error.killed, false);
        assert.match(error.stderr, /HTTPS|loopback|proxy/i);
        return true;
      },
    );
  });
}

test('restoring an old real SQLite backup applies the current deletion ledger before readiness', async (t) => {
  const f = await setup(t);
  const backup = await f.service.backup(path.join(f.root, 'backups'));
  assert.equal(
    (await f.request('/account', f.user.accessToken, { password, confirm: true }, 'DELETE')).status,
    200,
  );
  await f.service.close();
  const restored = path.join(f.root, 'restored');
  await restoreSyncBackup({
    directory: restored,
    backupPath: backup.path,
    ledgerPath: path.join(f.options.directory, 'deletions.jsonl'),
    masterKey: f.options.masterKey,
  });
  await f.restart({ directory: restored });
  assert.equal((await f.request('/account', f.user.accessToken)).status, 401);
  assert.equal(
    (
      await f.request('/sessions', null, {
        username: 'operator.test',
        password,
        deviceName: 'Resurrection',
        platform: 'test',
      })
    ).status,
    401,
  );
  const db = new DatabaseSync(path.join(restored, 'sync.sqlite'), { readOnly: true });
  assert.equal(db.prepare('SELECT count(*) AS n FROM accounts').get().n, 0);
  db.close();
  await assert.rejects(
    restoreSyncBackup({
      directory: path.join(f.root, 'unsafe'),
      backupPath: backup.path,
      ledgerPath: path.join(f.root, 'missing-ledger'),
      masterKey: f.options.masterKey,
    }),
    /ledger/i,
  );
});

test('master key rotation preserves records and rejects old keys; missing sentinel and tampered values fail startup', async (t) => {
  const f = await setup(t);
  const d = (await f.request('/datasets', f.user.accessToken, { name: 'Private name' })).data;
  const extensionId = 'c'.repeat(32);
  await f.request(`/datasets/${d.id}/operations`, f.user.accessToken, {
    epoch: d.epoch,
    operations: [
      {
        id: randomUUID(),
        kind: 'extension',
        extensionId,
        generation: 'one',
        baseRevision: 0,
        payload: { state: 'enabled', source: { kind: 'web-store', id: extensionId } },
      },
    ],
  });
  await f.request(`/datasets/${d.id}/operations`, f.user.accessToken, {
    epoch: d.epoch,
    operations: [
      {
        id: randomUUID(),
        kind: 'settings',
        extensionId,
        generation: 'one',
        baseRevision: 1,
        payload: { set: { sensitive: 'do not expose this' } },
      },
    ],
  });
  const nextKey = randomBytes(32);
  await f.service.rotateMasterKey(nextKey);
  await f.service.close();
  await assert.rejects(createSyncService(f.options), /key|authenticat/i);
  await f.restart({ masterKey: nextKey });
  assert.equal(
    (await f.request(`/datasets/${d.id}/snapshot`, f.user.accessToken)).data.settings[0].values.sensitive,
    'do not expose this',
  );
  await f.service.close();
  const db = new DatabaseSync(path.join(f.options.directory, 'sync.sqlite'));
  const row = db.prepare('SELECT rowid, value FROM settings LIMIT 1').get();
  const damaged = Buffer.from(row.value);
  damaged[damaged.length - 1] ^= 1;
  db.prepare('UPDATE settings SET value = ? WHERE rowid = ?').run(damaged, row.rowid);
  db.close();
  await assert.rejects(createSyncService({ ...f.options, masterKey: nextKey }), /authenticat|decrypt/i);
  const sentinel = new DatabaseSync(path.join(f.options.directory, 'sync.sqlite'));
  sentinel.prepare("DELETE FROM metadata WHERE key = 'master-check'").run();
  sentinel.close();
  await assert.rejects(createSyncService({ ...f.options, masterKey: nextKey }), /master|key|metadata/i);
});

test('backup creation prunes expired snapshots and restore rejects snapshots older than seven days', async (t) => {
  const f = await setup(t);
  const backups = path.join(f.root, 'backups');
  const past = Date.now() - 8 * 86400000;
  t.mock.method(Date, 'now', () => past);
  const first = await f.service.backup(backups);
  t.mock.reset();
  await assert.rejects(
    restoreSyncBackup({
      directory: path.join(f.root, 'expired'),
      backupPath: first.path,
      ledgerPath: path.join(f.options.directory, 'deletions.jsonl'),
      masterKey: f.options.masterKey,
    }),
    /expired|retention/i,
  );
  const next = await f.service.backup(backups);
  assert.notEqual(first.path, next.path);
  await assert.rejects(fs.access(first.path));
  const bytes = await fs.readFile(next.path);
  bytes[bytes.length - 1] ^= 1;
  await fs.writeFile(next.path, bytes);
  await assert.rejects(
    restoreSyncBackup({
      directory: path.join(f.root, 'damaged'),
      backupPath: next.path,
      ledgerPath: path.join(f.options.directory, 'deletions.jsonl'),
      masterKey: f.options.masterKey,
    }),
    /integrity|checksum/i,
  );
});

test('restoration authenticates backup metadata even when an attacker recomputes its checksum', async (t) => {
  const f = await setup(t);
  const backup = await f.service.backup(path.join(f.root, 'backups'));
  const db = new DatabaseSync(backup.path);
  db.prepare('UPDATE accounts SET username = ?').run('forged.account');
  db.close();
  const manifest = JSON.parse(await fs.readFile(backup.path + '.json', 'utf8'));
  manifest.sha256 = createHash('sha256')
    .update(await fs.readFile(backup.path))
    .digest('hex');
  await fs.writeFile(backup.path + '.json', JSON.stringify(manifest));
  await assert.rejects(
    restoreSyncBackup({
      directory: path.join(f.root, 'forged'),
      backupPath: backup.path,
      ledgerPath: path.join(f.options.directory, 'deletions.jsonl'),
      masterKey: f.options.masterKey,
    }),
    /authenticat|integrity/i,
  );
});

test('restoring a backup cannot revive revoked sessions, old passwords or already consumed recovery codes', async (t) => {
  const f = await setup(t);
  const backup = await f.service.backup(path.join(f.root, 'backups'));
  // The old backup key must still open that snapshot; the current encrypted
  // security ledger remains usable because account data keys are preserved.
  await f.service.rotateMasterKey(randomBytes(32));
  const changed = 'New synthetic password after backup';
  assert.equal(
    (await f.request('/account/password', f.user.accessToken, { password, newPassword: changed })).status,
    200,
  );
  const recoveredPassword = 'Recovered synthetic password after backup';
  const recovered = await f.request('/accounts/recover', null, {
    username: 'operator.test',
    recoveryCode: f.user.recoveryCodes[0],
    newPassword: recoveredPassword,
    deviceName: 'Recovered',
    platform: 'test',
  });
  assert.equal(recovered.status, 200);
  assert.equal(
    (await f.request(`/devices/${recovered.data.device.id}`, recovered.data.accessToken, undefined, 'DELETE'))
      .status,
    200,
  );
  await f.service.close();
  const directory = path.join(f.root, 'restored');
  await restoreSyncBackup({
    directory,
    backupPath: backup.path,
    ledgerPath: path.join(f.options.directory, 'deletions.jsonl'),
    masterKey: f.options.masterKey,
  });
  await f.restart({ directory });
  assert.equal((await f.request('/account', f.user.accessToken)).status, 401);
  assert.equal(
    (
      await f.request('/sessions', null, {
        username: 'operator.test',
        password,
        deviceName: 'Old password',
        platform: 'test',
      })
    ).status,
    401,
  );
  assert.equal(
    (
      await f.request('/sessions', null, {
        username: 'operator.test',
        password: recoveredPassword,
        deviceName: 'Current password',
        platform: 'test',
      })
    ).status,
    200,
  );
  assert.equal(
    (
      await f.request('/accounts/recover', null, {
        username: 'operator.test',
        recoveryCode: f.user.recoveryCodes[0],
        newPassword: password,
        deviceName: 'Used code',
        platform: 'test',
      })
    ).status,
    401,
  );
  assert.equal(
    (
      await f.request('/accounts/recover', null, {
        username: 'operator.test',
        recoveryCode: recovered.data.recoveryCodes[0],
        newPassword: password,
        deviceName: 'Current code',
        platform: 'test',
      })
    ).status,
    200,
  );
});

test('R6 dataset-only deletion survives a real disk backup restored with the current ledger', async (t) => {
  const f = await setup(t),
    token = f.user.accessToken;
  const removed = (await f.request('/datasets', token, { name: 'Delete only this' })).data;
  const kept = (await f.request('/datasets', token, { name: 'Keep this' })).data;
  const other = (
    await f.request('/accounts', null, {
      username: 'other.operator',
      password,
      deviceName: 'Other',
      platform: 'test',
    })
  ).data;
  const otherDataset = (await f.request('/datasets', other.accessToken, { name: 'Other account' })).data;
  const extensionId = 'a'.repeat(32);
  for (const dataset of [removed, kept]) {
    const result = await f.request(`/datasets/${dataset.id}/operations`, token, {
      epoch: dataset.epoch,
      operations: [
        {
          id: randomUUID(),
          kind: 'extension',
          extensionId,
          generation: 'one',
          baseRevision: 0,
          payload: { state: 'enabled', source: { kind: 'web-store', id: extensionId } },
        },
        {
          id: randomUUID(),
          kind: 'settings',
          extensionId,
          generation: 'one',
          baseRevision: 0,
          payload: { set: { sensitive: dataset.id } },
        },
      ],
    });
    assert.equal(result.status, 200);
  }
  const backup = await f.service.backup(path.join(f.root, 'backups'));
  assert.equal(
    (await f.request(`/datasets/${removed.id}`, token, { password, confirm: true }, 'DELETE')).status,
    200,
  );
  const ledgerPath = path.join(f.options.directory, 'deletions.jsonl');
  const records = (await fs.readFile(ledgerPath, 'utf8')).trim().split('\n').map(JSON.parse);
  const restored = path.join(f.root, 'restored-dataset');
  await f.service.close();
  await restoreSyncBackup({
    directory: restored,
    backupPath: backup.path,
    ledgerPath,
    masterKey: f.options.masterKey,
  });
  await f.restart({ directory: restored });
  const login = async (username) =>
    (
      await f.request('/sessions', null, {
        username,
        password,
        deviceName: 'After restore',
        platform: 'test',
      })
    ).data.accessToken;
  const current = await login('operator.test');
  assert.deepEqual(
    (await f.request('/datasets', current)).data.datasets.map((d) => d.id),
    [kept.id],
  );
  assert.equal((await f.request(`/datasets/${removed.id}/snapshot?settings=1`, current)).status, 404);
  assert.ok(
    records.some(
      (r) =>
        r.kind === 'dataset-deletion' &&
        r.accountId === f.user.account.id &&
        r.datasetId === removed.id &&
        r.epoch === removed.epoch,
    ),
  );

  assert.equal(
    (await f.request(`/datasets/${kept.id}/snapshot?settings=1`, current)).data.settings[0].values.sensitive,
    kept.id,
  );
  assert.deepEqual(
    (await f.request('/datasets', await login('other.operator'))).data.datasets.map((d) => d.id),
    [otherDataset.id],
  );
  const db = new DatabaseSync(path.join(restored, 'sync.sqlite'), { readOnly: true });
  for (const table of ['settings', 'extensions', 'changes', 'operations', 'generations'])
    assert.equal(db.prepare(`SELECT count(*) AS n FROM ${table} WHERE dataset_id = ?`).get(removed.id).n, 0);
  db.close();
});
test('R6 dataset deletion fails closed when the durable ledger cannot be written', async (t) => {
  const f = await setup(t);
  const dataset = (await f.request('/datasets', f.user.accessToken, { name: 'Do not acknowledge' })).data;
  const ledger = path.join(f.options.directory, 'deletions.jsonl');
  await fs.rename(ledger, ledger + '.retained');
  await fs.mkdir(ledger);
  const response = await f.request(
    `/datasets/${dataset.id}`,
    f.user.accessToken,
    { password, confirm: true },
    'DELETE',
  );
  assert.equal(response.status, 503);
  assert.equal((await fetch(f.service.url + '/ready')).status, 503);
  const db = new DatabaseSync(path.join(f.options.directory, 'sync.sqlite'), { readOnly: true });
  assert.equal(db.prepare('SELECT deleted FROM datasets WHERE id = ?').get(dataset.id).deleted, 0);
  db.close();
});
