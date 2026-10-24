'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const {
  own,
  object,
  clone,
  jsonValue,
  bytes,
  checkQuota,
  difference,
  applySettings,
} = require('../../core/sync/model.cjs');
const emptyArea = () => ({ values: {}, accessLevel: 'TRUSTED_AND_UNTRUSTED_CONTEXTS', writes: [] });
function keys(value) {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value) && value.every((k) => typeof k === 'string')) return value;
  throw new Error('Expected a storage key or an array of keys.');
}
function storageOperation(area, method, args = [], { trusted = true, now = Date.now() } = {}) {
  if (!trusted && area.accessLevel === 'TRUSTED_CONTEXTS')
    throw new Error('Access to sync storage is restricted to trusted extension contexts.');
  const values = area.values;
  if (method === 'get') {
    const query = args[0];
    if (query === undefined || query === null) return { result: clone(values) };
    if (object(query)) {
      const defaults = jsonValue(query);
      return {
        result: Object.fromEntries(
          Object.entries(defaults).map(([k, v]) => [k, own(values, k) ? clone(values[k]) : v]),
        ),
      };
    }
    return {
      result: Object.fromEntries(
        keys(query)
          .filter((k) => own(values, k))
          .map((k) => [k, clone(values[k])]),
      ),
    };
  }
  if (method === 'getKeys') return { result: Object.keys(values) };
  if (method === 'getBytesInUse')
    return {
      result: (args[0] == null ? Object.keys(values) : keys(args[0]))
        .filter((k) => own(values, k))
        .reduce((sum, k) => sum + bytes(k, values[k]), 0),
    };
  if (method === 'setAccessLevel') {
    if (!trusted || !['TRUSTED_CONTEXTS', 'TRUSTED_AND_UNTRUSTED_CONTEXTS'].includes(args[0]?.accessLevel))
      throw new Error('Invalid storage access level.');
    area.accessLevel = args[0].accessLevel;
    return { result: undefined };
  }
  let mutation;
  if (method === 'set') {
    if (!object(args[0])) throw new Error('Expected a JSON value object.');
    mutation = { set: jsonValue(args[0]) };
  } else if (method === 'remove') mutation = { remove: [...new Set(keys(args[0]))] };
  else if (method === 'clear') mutation = { clear: true };
  else throw new Error('Unsupported sync storage method.');
  const next = applySettings(values, mutation);
  checkQuota(next);
  const writes = area.writes.filter((time) => now - time < 3600000 && time <= now);
  if (writes.filter((time) => now - time < 60000).length >= 120)
    throw new Error('MAX_WRITE_OPERATIONS_PER_MINUTE quota exceeded.');
  if (writes.length >= 1800) throw new Error('MAX_WRITE_OPERATIONS_PER_HOUR quota exceeded.');
  area.writes = [...writes, now];
  area.values = next;
  return { result: undefined, changes: difference(values, next), mutation };
}
class SyncStorage {
  constructor({ directory, onChanged = () => {} }) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const filename = path.join(directory, 'client.sqlite');
    this.db = new DatabaseSync(filename);
    fs.chmodSync(filename, 0o600);
    this.db.exec(
      'PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL)',
    );
    if (!this.db.prepare('SELECT 1 FROM state WHERE id=1').get())
      this.db
        .prepare('INSERT INTO state VALUES (1,?)')
        .run(JSON.stringify({ version: 1, areas: {}, links: {}, endpoint: '', account: null }));
    if (this.read().version !== 1) {
      this.db.close();
      throw new Error('Unsupported sync client data version.');
    }
    this.onChanged = onChanged;
  }
  read() {
    return JSON.parse(this.db.prepare('SELECT value FROM state WHERE id=1').get().value);
  }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const state = this.read(),
        result = action(state);
      this.db.prepare('UPDATE state SET value=? WHERE id=1').run(JSON.stringify(state));
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
  call(namespace, method, args, options) {
    const response = this.transaction((state) => {
      if (!own(state.areas, namespace))
        Object.defineProperty(state.areas, namespace, {
          value: emptyArea(),
          enumerable: true,
          writable: true,
        });
      return storageOperation(state.areas[namespace], method, args, options);
    });
    if (response.changes && Object.keys(response.changes).length)
      this.onChanged(namespace, response.changes, 'sync');
    return response.result;
  }
  close() {
    if (!this.closed) {
      this.closed = true;
      this.db.close();
    }
  }
}
module.exports = { SyncStorage, emptyArea, storageOperation };
