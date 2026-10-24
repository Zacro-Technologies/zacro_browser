'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomBytes, randomUUID, createHmac } = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { seal, open } = require('./crypto.cjs');
const { syncDirectory, backup, restoreSyncBackup } = require('./maintenance.cjs');

class SyncStore {
  constructor(directory, masterKey) {
    if (!Buffer.isBuffer(masterKey) || masterKey.length !== 32)
      throw new Error('A 32-byte master key is required');
    if (typeof directory !== 'string' || !directory)
      throw new Error('An explicit data directory is required');
    this.directory = path.resolve(directory);
    this.masterKey = Buffer.from(masterKey);
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    this.ledgerPath = path.join(this.directory, 'deletions.jsonl');
    this.lockPath = path.join(this.directory, '.service.lock');
    let lock;
    try {
      lock = fs.openSync(this.lockPath, 'wx', 0o600);
    } catch (cause) {
      this.masterKey.fill(0);
      throw new Error(
        'Sync directory is already in use or locked. Verify the owner before removing a stale lock.',
        { cause },
      );
    }
    fs.writeFileSync(lock, JSON.stringify({ pid: process.pid, createdAt: Date.now() }));
    fs.closeSync(lock);
    const existing = fs.existsSync(path.join(this.directory, 'sync.sqlite'));
    try {
      this.db = new DatabaseSync(path.join(this.directory, 'sync.sqlite'));
      fs.chmodSync(path.join(this.directory, 'sync.sqlite'), 0o600);
      this.db.exec(
        'PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA busy_timeout = 5000;',
      );
      this.db.exec('CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL)');
      const check = this.get('SELECT value FROM metadata WHERE key = ?', 'master-check');
      if (check) {
        if (open(this.masterKey, check.value, 'zacro-sync/master-check') !== 'zacro-sync-v1')
          throw new Error('Invalid master key');
      } else {
        if (existing) throw new Error('Existing database has no master-key metadata; recovery is required');
        this.run(
          'INSERT INTO metadata VALUES (?,?)',
          'master-check',
          seal(this.masterKey, 'zacro-sync-v1', 'zacro-sync/master-check'),
        );
      }
      const version = this.get('PRAGMA user_version').user_version;
      if (version > 1) throw new Error('Database version is newer than this service');
      if (!version)
        this.transaction(() => {
          this.db.exec(`
          CREATE TABLE accounts (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password TEXT NOT NULL, wrapped_key BLOB NOT NULL, created INTEGER NOT NULL, credential_version INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE devices (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL, platform TEXT NOT NULL, created INTEGER NOT NULL, last_seen INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, access_hash TEXT UNIQUE, access_expires INTEGER, refresh_hash TEXT UNIQUE, refresh_expires INTEGER, authenticated INTEGER NOT NULL);
          CREATE TABLE used_refresh (hash TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE, expires INTEGER NOT NULL);
          CREATE TABLE recovery (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, hash TEXT NOT NULL, PRIMARY KEY(account_id,hash));
          CREATE TABLE datasets (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL, epoch TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE extensions (dataset_id TEXT NOT NULL REFERENCES datasets(id) ON DELETE CASCADE, extension_id TEXT NOT NULL, generation TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(dataset_id,extension_id));
          CREATE TABLE generations (dataset_id TEXT NOT NULL REFERENCES datasets(id) ON DELETE CASCADE, extension_id TEXT NOT NULL, generation TEXT NOT NULL, PRIMARY KEY(dataset_id,extension_id,generation));
          CREATE TABLE settings (dataset_id TEXT NOT NULL REFERENCES datasets(id) ON DELETE CASCADE, extension_id TEXT NOT NULL, generation TEXT NOT NULL, key TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL, value BLOB, PRIMARY KEY(dataset_id,extension_id,generation,key));
          CREATE TABLE changes (dataset_id TEXT NOT NULL REFERENCES datasets(id) ON DELETE CASCADE, revision INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(dataset_id,revision));
          CREATE TABLE operations (dataset_id TEXT NOT NULL REFERENCES datasets(id) ON DELETE CASCADE, id TEXT NOT NULL, device_id TEXT NOT NULL, digest TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(dataset_id,id));
          CREATE INDEX devices_account ON devices(account_id);
          CREATE INDEX datasets_account ON datasets(account_id);
          PRAGMA user_version = 1;
        `);
        });
      if (!fs.existsSync(this.ledgerPath)) {
        if (existing) throw new Error('Deletion ledger is missing; recovery is required');
        const ledger = fs.openSync(this.ledgerPath, 'wx', 0o600);
        fs.fsyncSync(ledger);
        fs.closeSync(ledger);
        syncDirectory(this.directory);
      }
      this.applyDeletionLedger();
      this.validateEncryptedRecords();
    } catch (error) {
      this.db?.close();
      this.masterKey.fill(0);
      fs.unlinkSync(this.lockPath);
      throw error;
    }
  }
  get(sql, ...values) {
    return this.db.prepare(sql).get(...values);
  }
  all(sql, ...values) {
    return this.db.prepare(sql).all(...values);
  }
  run(sql, ...values) {
    return this.db.prepare(sql).run(...values);
  }
  transaction(work) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = work();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
  accountKey(account) {
    const key = Buffer.from(open(this.masterKey, account.wrapped_key, `account-key/${account.id}`), 'base64');
    if (key.length !== 32) throw new Error('Invalid account data key');
    return key;
  }
  validateEncryptedRecords() {
    for (const account of this.db.prepare('SELECT id, wrapped_key FROM accounts').iterate()) {
      const key = this.accountKey(account);
      try {
        const verify = (context, value) => open(key, value, `${account.id}/${context}`);
        for (const d of this.db.prepare('SELECT * FROM datasets WHERE account_id = ?').iterate(account.id)) {
          verify(`dataset/${d.id}/name`, d.name);
          for (const e of this.db.prepare('SELECT * FROM extensions WHERE dataset_id = ?').iterate(d.id))
            verify(`extension/${d.id}/${e.extension_id}`, e.payload);
          for (const s of this.db.prepare('SELECT * FROM settings WHERE dataset_id = ?').iterate(d.id))
            verify(`setting/${d.id}/${s.extension_id}/${s.generation}/${s.key}`, s.value);
          for (const c of this.db.prepare('SELECT * FROM changes WHERE dataset_id = ?').iterate(d.id))
            verify(`change/${d.id}/${c.revision}`, c.payload);
        }
      } finally {
        key.fill(0);
      }
    }
  }
  backup(directory) {
    return backup(this, directory);
  }
  rotateMasterKey(nextKey) {
    if (!Buffer.isBuffer(nextKey) || nextKey.length !== 32)
      throw new Error('A 32-byte master key is required');
    this.transaction(() => {
      for (const account of this.all('SELECT id, wrapped_key FROM accounts')) {
        const key = this.accountKey(account);
        try {
          this.run(
            'UPDATE accounts SET wrapped_key = ? WHERE id = ?',
            seal(nextKey, key.toString('base64'), `account-key/${account.id}`),
            account.id,
          );
        } finally {
          key.fill(0);
        }
      }
      this.run(
        'UPDATE metadata SET value = ? WHERE key = ?',
        seal(nextKey, 'zacro-sync-v1', 'zacro-sync/master-check'),
        'master-check',
      );
    });
    this.masterKey.fill(0);
    this.masterKey = Buffer.from(nextKey);
  }
  createAccount(username, password) {
    const id = randomUUID();
    const key = randomBytes(32);
    this.run(
      'INSERT INTO accounts (id,username,password,wrapped_key,created) VALUES (?,?,?,?,?)',
      id,
      username,
      password,
      seal(this.masterKey, key.toString('base64'), `account-key/${id}`),
      Date.now(),
    );
    key.fill(0);
    return this.get('SELECT * FROM accounts WHERE id = ?', id);
  }
  encode(account, context, value) {
    const key = this.accountKey(account);
    try {
      return seal(key, value, `${account.id}/${context}`);
    } finally {
      key.fill(0);
    }
  }
  decode(account, context, value) {
    const key = this.accountKey(account);
    try {
      return open(key, value, `${account.id}/${context}`);
    } finally {
      key.fill(0);
    }
  }
  fingerprint(account, context, value) {
    const key = this.accountKey(account);
    try {
      return createHmac('sha256', key).update(context).update('\0').update(value).digest('hex');
    } finally {
      key.fill(0);
    }
  }
  applyDeletionLedger() {
    if (!fs.existsSync(this.ledgerPath)) return;
    const text = fs.readFileSync(this.ledgerPath, 'utf8');
    if (text && !text.endsWith('\n')) throw new Error('Incomplete deletion ledger; repair required');
    const deleted = new Set(),
      credentials = new Map(),
      datasets = [];
    for (const line of text.split('\n').filter(Boolean)) {
      const record = JSON.parse(line);
      if (!/^[a-f0-9-]{36}$/.test(record.accountId)) throw new Error('Invalid security ledger account');
      if (record.v === 1 && Number.isSafeInteger(record.deletedAt)) deleted.add(record.accountId);
      else if (
        record.v === 2 &&
        record.kind === 'credentials' &&
        Number.isSafeInteger(record.version) &&
        record.version > 0 &&
        typeof record.payload === 'string'
      ) {
        const previous = credentials.get(record.accountId);
        if (previous?.version === record.version && previous.payload !== record.payload)
          throw new Error('Conflicting credential ledger records');
        if (!previous || record.version > previous.version) credentials.set(record.accountId, record);
      } else if (
        record.v === 3 &&
        record.kind === 'dataset-deletion' &&
        /^[a-f0-9-]{36}$/.test(record.datasetId) &&
        /^[a-f0-9-]{36}$/.test(record.epoch) &&
        Number.isSafeInteger(record.deletedAt)
      )
        datasets.push(record);
      else throw new Error('Invalid security ledger');
    }
    this.transaction(() => {
      for (const id of deleted) this.run('DELETE FROM accounts WHERE id = ?', id);
      // Dataset IDs are never reused. Delete every retained epoch for the same
      // account-owned identity, including an already marked live tombstone.
      for (const record of datasets)
        this.run('DELETE FROM datasets WHERE account_id = ? AND id = ?', record.accountId, record.datasetId);
      for (const account of this.all('SELECT * FROM accounts')) {
        const record = credentials.get(account.id);
        if (!record || account.credential_version > record.version)
          throw new Error('Current credential ledger is required; supplied ledger is stale');
        const data = this.decode(
          account,
          `credential-ledger/${record.version}`,
          Buffer.from(record.payload, 'base64'),
        );
        if (
          data.version !== record.version ||
          typeof data.password !== 'string' ||
          !Array.isArray(data.recovery) ||
          data.recovery.length !== 10 ||
          data.recovery.some((h) => !/^[a-f0-9]{64}$/.test(h))
        )
          throw new Error('Invalid authenticated credential ledger');
        const existing = this.all(
          'SELECT hash FROM recovery WHERE account_id = ? ORDER BY hash',
          account.id,
        ).map((r) => r.hash);
        if (
          account.credential_version !== record.version ||
          account.password !== data.password ||
          JSON.stringify(existing) !== JSON.stringify([...data.recovery].sort())
        ) {
          this.run(
            'UPDATE accounts SET password = ?, credential_version = ? WHERE id = ?',
            data.password,
            record.version,
            account.id,
          );
          this.run('DELETE FROM recovery WHERE account_id = ?', account.id);
          for (const hash of data.recovery) this.run('INSERT INTO recovery VALUES (?,?)', account.id, hash);
          this.run(
            'UPDATE devices SET revoked = 1, access_hash = NULL, refresh_hash = NULL WHERE account_id = ?',
            account.id,
          );
        }
      }
    });
  }
  appendLedger(record) {
    let fd;
    try {
      fd = fs.openSync(this.ledgerPath, 'a', 0o600);
      fs.writeSync(fd, JSON.stringify(record) + '\n');
      fs.fsyncSync(fd);
    } catch (cause) {
      throw Object.assign(new Error('Durable security ledger write failed', { cause }), {
        code: 'storage_unavailable',
      });
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
  }
  recordCredentials(id) {
    const account = this.get('SELECT * FROM accounts WHERE id = ?', id);
    const version = account.credential_version + 1;
    const data = {
      version,
      password: account.password,
      recovery: this.all('SELECT hash FROM recovery WHERE account_id = ? ORDER BY hash', id).map(
        (r) => r.hash,
      ),
    };
    this.appendLedger({
      v: 2,
      kind: 'credentials',
      accountId: id,
      version,
      payload: this.encode(account, `credential-ledger/${version}`, data).toString('base64'),
    });
    this.run('UPDATE accounts SET credential_version = ? WHERE id = ?', version, id);
  }
  recordDatasetDeletion(accountId, dataset) {
    this.appendLedger({
      v: 3,
      kind: 'dataset-deletion',
      accountId,
      datasetId: dataset.id,
      epoch: dataset.epoch,
      deletedAt: Date.now(),
    });
  }
  deleteAccount(id) {
    this.appendLedger({ v: 1, accountId: id, deletedAt: Date.now() });
    this.transaction(() => this.run('DELETE FROM accounts WHERE id = ?', id));
  }
  close() {
    if (!this.db) return;
    this.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    this.db.close();
    this.db = null;
    this.masterKey.fill(0);
    fs.unlinkSync(this.lockPath);
  }
}
module.exports = { SyncStore, restoreSyncBackup };
