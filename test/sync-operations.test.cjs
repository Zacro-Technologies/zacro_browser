'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
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

test('operator CLI generates protected keys, serves a real database and performs an offline backup and restore', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-cli-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const keyFile = path.join(root, 'master.key'),
    directory = path.join(root, 'data');
  const generated = await execute(process.execPath, [cli, 'generate-key', '--key-file', keyFile]);
  assert.equal((await fs.readFile(keyFile)).length, 32);
  assert.equal(generated.stdout.includes((await fs.readFile(keyFile)).toString('hex')), false);
  if (process.platform !== 'win32') assert.equal((await fs.stat(keyFile)).mode & 0o077, 0);
  const child = spawn(
    process.execPath,
    [cli, 'serve', '--data', directory, '--key-file', keyFile, '--port', '0', '--dev-loopback'],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let stderr = '';
  child.stderr.on('data', (c) => {
    stderr = (stderr + c).slice(-8000);
  });
  t.after(async () => {
    if (child.exitCode === null && !child.killed) {
      const exited = new Promise((resolve) => child.once('exit', resolve));
      child.kill('SIGTERM');
      await exited;
    }
  });
  const lines = createInterface({ input: child.stdout });
  const url = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('CLI startup timed out: ' + stderr)), 10000);
    const fail = () => {
      clearTimeout(timer);
      reject(new Error('CLI exited: ' + stderr));
    };
    child.once('exit', fail);
    lines.on('line', (line) => {
      const record = JSON.parse(line);
      if (record.event === 'listening') {
        clearTimeout(timer);
        child.off('exit', fail);
        resolve(record.url);
      }
    });
  });
  assert.equal((await fetch(url + '/ready')).status, 200);
  const exited = new Promise((resolve) => child.once('exit', resolve));
  child.kill('SIGTERM');
  await exited;
  lines.close();
  assert.equal(child.exitCode, 0, stderr);
  const backed = await execute(process.execPath, [
    cli,
    'backup',
    '--data',
    directory,
    '--key-file',
    keyFile,
    '--backup-dir',
    path.join(root, 'backups'),
  ]);
  const backup = JSON.parse(backed.stdout);
  const restored = path.join(root, 'restored');
  await execute(process.execPath, [
    cli,
    'restore',
    '--data',
    restored,
    '--key-file',
    keyFile,
    '--backup',
    backup.path,
    '--ledger',
    path.join(directory, 'deletions.jsonl'),
  ]);
  await fs.access(path.join(restored, 'sync.sqlite'));
  await assert.rejects(
    execute(process.execPath, [
      cli,
      'serve',
      '--data',
      restored,
      '--key-file',
      keyFile,
      '--host',
      '0.0.0.0',
      '--dev-loopback',
    ]),
    /HTTPS|loopback|proxy/i,
  );
});

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
