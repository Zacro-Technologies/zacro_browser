#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { parseArgs } = require('node:util');
const { randomBytes } = require('node:crypto');
const { createSyncService, restoreSyncBackup } = require('./server.cjs');
const { SyncStore } = require('./store.cjs');
const { syncDirectory } = require('./maintenance.cjs');

function keyFile(filename, directory) {
  if (!filename) throw new Error('Configure an explicit master key file outside the data directory');
  const resolved = path.resolve(filename),
    relative = path.relative(path.resolve(directory), resolved);
  if (!relative || (!relative.startsWith('..' + path.sep) && !path.isAbsolute(relative)))
    throw new Error('Master keys must be outside the database directory');
  const stat = fs.statSync(resolved);
  if (!stat.isFile() || (process.platform !== 'win32' && stat.mode & 0o077))
    throw new Error('Master key file must be a private regular file (mode 0600 or 0400)');
  const key = fs.readFileSync(resolved);
  if (key.length !== 32) throw new Error('Master key file must contain exactly 32 raw bytes');
  return key;
}
function output(value) {
  process.stdout.write(JSON.stringify(value) + '\n');
}
async function main() {
  let parsed;
  try {
    parsed = parseArgs({
      allowPositionals: true,
      options: Object.fromEntries([
        ...[
          'data',
          'key-file',
          'new-key-file',
          'host',
          'port',
          'public-url',
          'tls-key',
          'tls-cert',
          'backup-dir',
          'backup',
          'ledger',
        ].map((k) => [k, { type: 'string' }]),
        ...['dev-loopback', 'trusted-proxy', 'help'].map((k) => [k, { type: 'boolean' }]),
      ]),
    });
  } catch {
    throw new Error('Invalid command options. Use --help.');
  }
  const args = parsed.values,
    command = parsed.positionals[0] || 'serve';
  if (args.help) {
    process.stdout.write(
      'Zacro sync: generate-key | serve | migrate | backup | restore | rotate-key | unlock\nSee services/sync/README.md. Keys are raw 32-byte private files outside --data.\n',
    );
    return;
  }
  if (parsed.positionals.length > 1) throw new Error('Specify one command only');
  const directory = args.data || process.env.ZACRO_SYNC_DATA;
  const filename = args['key-file'] || process.env.ZACRO_SYNC_MASTER_KEY_FILE;
  if (command === 'generate-key') {
    if (!filename) throw new Error('Specify --key-file');
    const resolved = path.resolve(filename);
    fs.mkdirSync(path.dirname(resolved), { recursive: true, mode: 0o700 });
    const fd = fs.openSync(resolved, 'wx', 0o600),
      key = randomBytes(32);
    try {
      fs.writeFileSync(fd, key);
      fs.fsyncSync(fd);
    } finally {
      key.fill(0);
      fs.closeSync(fd);
    }
    syncDirectory(path.dirname(resolved));
    output({ event: 'key-created', path: resolved });
    return;
  }
  if (!directory) throw new Error('Specify an explicit --data directory');
  if (command === 'unlock') {
    const lock = path.join(path.resolve(directory), '.service.lock');
    const state = JSON.parse(fs.readFileSync(lock, 'utf8'));
    if (!Number.isSafeInteger(state.pid) || state.pid <= 1)
      throw new Error('Invalid lock; inspect it manually');
    let alive = true;
    try {
      process.kill(state.pid, 0);
    } catch (error) {
      if (error.code === 'ESRCH') alive = false;
      else throw new Error('Cannot establish that the lock owner has exited');
    }
    if (alive) throw new Error('Lock owner is still running; stop it before unlocking');
    fs.unlinkSync(lock);
    syncDirectory(path.resolve(directory));
    output({ event: 'unlocked' });
    return;
  }
  const masterKey = keyFile(filename, directory);
  try {
    if (command === 'serve') {
      const rawPort = args.port || process.env.ZACRO_SYNC_PORT || '4040';
      if (!/^\d{1,5}$/.test(rawPort) || Number(rawPort) > 65535) throw new Error('Invalid port');
      const tlsKey = args['tls-key'] || process.env.ZACRO_SYNC_TLS_KEY_FILE;
      const tlsCert = args['tls-cert'] || process.env.ZACRO_SYNC_TLS_CERT_FILE;
      if (Boolean(tlsKey) !== Boolean(tlsCert)) throw new Error('Supply both TLS key and certificate');
      const service = await createSyncService({
        directory,
        masterKey,
        host: args.host || process.env.ZACRO_SYNC_HOST || '127.0.0.1',
        port: Number(rawPort),
        allowInsecureLoopback: args['dev-loopback'] === true || process.env.ZACRO_SYNC_DEV_LOOPBACK === '1',
        trustedProxy: args['trusted-proxy'] === true || process.env.ZACRO_SYNC_TRUSTED_PROXY === '1',
        publicURL: args['public-url'] || process.env.ZACRO_SYNC_PUBLIC_URL,
        tls: tlsKey ? { key: fs.readFileSync(tlsKey), cert: fs.readFileSync(tlsCert) } : undefined,
        log: output,
      });
      output({ event: 'listening', url: service.url });
      let stopping = false;
      const stop = async () => {
        if (stopping) return;
        stopping = true;
        await service.close();
        output({ event: 'stopped' });
      };
      process.once('SIGINT', () => {
        void stop().catch(() => process.exit(1));
      });
      process.once('SIGTERM', () => {
        void stop().catch(() => process.exit(1));
      });
      return;
    }
    if (command === 'restore') {
      output({
        event: 'restored',
        ...(await restoreSyncBackup({
          directory,
          masterKey,
          backupPath: args.backup,
          ledgerPath: args.ledger,
        })),
      });
      return;
    }
    if (!['backup', 'migrate', 'rotate-key'].includes(command))
      throw new Error('Unknown command. Use --help.');
    if (!fs.existsSync(path.join(directory, 'sync.sqlite')))
      throw new Error('Existing database is required for maintenance');
    const store = new SyncStore(directory, masterKey);
    try {
      if (command === 'backup') output({ event: 'backup-created', ...store.backup(args['backup-dir']) });
      else if (command === 'migrate')
        output({ event: 'migrated', schema: store.get('PRAGMA user_version').user_version });
      else {
        const next = keyFile(args['new-key-file'], directory);
        try {
          store.rotateMasterKey(next);
        } finally {
          next.fill(0);
        }
        output({
          event: 'key-rotated',
          message: 'Configure the service to use the new key file before restarting.',
        });
      }
    } finally {
      store.close();
    }
  } finally {
    masterKey.fill(0);
  }
}
if (require.main === module)
  main().catch((error) => {
    process.stderr.write(JSON.stringify({ event: 'error', message: error.message }) + '\n');
    process.exitCode = 1;
  });
module.exports = { main };
