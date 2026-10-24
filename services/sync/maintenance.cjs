'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID, createHash, createHmac, timingSafeEqual } = require('node:crypto');
const retention = 7 * 86400000;
const backupName = /^zacro-sync-\d+-[a-f0-9-]{36}\.sqlite$/;
function authenticate(key, manifest) {
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error('A 32-byte master key is required');
  return createHmac('sha256', key)
    .update('Zacro sync backup manifest v1\0')
    .update(JSON.stringify([manifest.version, manifest.createdAt, manifest.sha256, manifest.schema]))
    .digest('hex');
}
function syncDirectory(directory) {
  let fd;
  try {
    fd = fs.openSync(directory, 'r');
    fs.fsyncSync(fd);
  } catch (error) {
    if (process.platform !== 'win32') throw error;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}
function checksum(filename) {
  const hash = createHash('sha256'),
    fd = fs.openSync(filename, 'r');
  const buffer = Buffer.alloc(64 * 1024);
  try {
    let read;
    while ((read = fs.readSync(fd, buffer, 0, buffer.length, null))) hash.update(buffer.subarray(0, read));
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}
function backup(store, directory) {
  if (typeof directory !== 'string' || !directory)
    throw new Error('An explicit backup directory is required');
  const target = path.resolve(directory);
  fs.mkdirSync(target, { recursive: true, mode: 0o700 });
  // Only this service's recognizable snapshots are pruned; arbitrary files are never removed.
  for (const name of fs.readdirSync(target).filter((name) => backupName.test(name))) {
    const filename = path.join(target, name),
      manifestPath = filename + '.json';
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (!Number.isSafeInteger(manifest.createdAt)) throw new Error('Invalid backup manifest');
    if (Date.now() - manifest.createdAt >= retention) {
      fs.unlinkSync(filename);
      fs.unlinkSync(manifestPath);
    }
  }
  store.validateEncryptedRecords();
  const createdAt = Date.now(),
    filename = path.join(target, `zacro-sync-${createdAt}-${randomUUID()}.sqlite`);
  store.db.prepare('VACUUM INTO ?').run(filename);
  fs.chmodSync(filename, 0o600);
  const fd = fs.openSync(filename, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  const manifest = { version: 1, createdAt, sha256: checksum(filename), schema: 1 };
  manifest.mac = authenticate(store.masterKey, manifest);
  const metadata = fs.openSync(filename + '.json', 'wx', 0o600);
  try {
    fs.writeFileSync(metadata, JSON.stringify(manifest));
    fs.fsyncSync(metadata);
  } finally {
    fs.closeSync(metadata);
  }
  syncDirectory(target);
  return { path: filename, ...manifest };
}
async function restoreSyncBackup({ directory, backupPath, ledgerPath, masterKey }) {
  if (![directory, backupPath, ledgerPath].every((p) => typeof p === 'string' && p))
    throw new Error('Restore requires a destination, backup and current deletion ledger');
  if (fs.existsSync(directory))
    throw new Error('Restore destination must not exist; restore into a new directory');
  if (!fs.existsSync(ledgerPath)) throw new Error('Current deletion ledger is required');
  const manifest = JSON.parse(fs.readFileSync(backupPath + '.json', 'utf8'));
  if (
    typeof manifest.mac !== 'string' ||
    !/^[a-f0-9]{64}$/.test(manifest.mac) ||
    !timingSafeEqual(Buffer.from(manifest.mac, 'hex'), Buffer.from(authenticate(masterKey, manifest), 'hex'))
  )
    throw new Error('Backup manifest authentication failed');
  if (
    manifest.version !== 1 ||
    !Number.isSafeInteger(manifest.createdAt) ||
    manifest.createdAt > Date.now() ||
    Date.now() - manifest.createdAt >= retention
  )
    throw new Error('Backup is expired or exceeds the seven-day retention policy');
  if (checksum(backupPath) !== manifest.sha256) throw new Error('Backup checksum integrity failed');
  const target = path.resolve(directory),
    parent = path.dirname(target);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const stage = fs.mkdtempSync(path.join(parent, '.zacro-restore-'));
  try {
    fs.copyFileSync(backupPath, path.join(stage, 'sync.sqlite'), fs.constants.COPYFILE_EXCL);
    if (checksum(path.join(stage, 'sync.sqlite')) !== manifest.sha256)
      throw new Error('Backup changed during restore; integrity check failed');
    fs.copyFileSync(ledgerPath, path.join(stage, 'deletions.jsonl'), fs.constants.COPYFILE_EXCL);
    fs.chmodSync(path.join(stage, 'deletions.jsonl'), 0o600);
    const { SyncStore } = require('./store.cjs');
    // Constructor applies the current deletion ledger and validates all encrypted data.
    const restored = new SyncStore(stage, masterKey);
    // Backups never reinstate a device authorization, including revocations that
    // happened after the snapshot. Clients explicitly authenticate again.
    restored.run('UPDATE devices SET revoked = 1, access_hash = NULL, refresh_hash = NULL');
    restored.close();
    if (fs.existsSync(target)) throw new Error('Restore destination appeared during validation');
    fs.renameSync(stage, target);
    syncDirectory(parent);
    return { directory: target, schema: 1 };
  } catch (error) {
    fs.rmSync(stage, { recursive: true, force: true });
    throw error;
  }
}
module.exports = { syncDirectory, backup, restoreSyncBackup };
