'use strict';
const { randomUUID } = require('node:crypto');
const { failure, label } = require('./auth.cjs');
const invalid = () => failure(400, 'invalid_operation', 'Invalid synchronization request.');
const missing = () => failure(404, 'not_found', 'The dataset is not available.');
const own = (o, k) => Object.hasOwn(o, k);
const object = (o) => o !== null && typeof o === 'object' && !Array.isArray(o);
function boundedJson(value, depth = 0) {
  if (depth > 64) throw invalid();
  if (value && typeof value === 'object')
    for (const child of Object.values(value)) boundedJson(child, depth + 1);
}
function exact(value, names) {
  if (!object(value) || Object.keys(value).some((key) => !names.includes(key))) throw invalid();
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (object(value))
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  return value;
}
function validate(operation) {
  boundedJson(operation);
  exact(operation, ['id', 'kind', 'extensionId', 'generation', 'baseRevision', 'payload']);
  if (
    typeof operation.id !== 'string' ||
    !/^[a-zA-Z0-9_-]{1,128}$/.test(operation.id) ||
    !/^[a-p]{32}$/.test(operation.extensionId) ||
    typeof operation.generation !== 'string' ||
    !/^[a-zA-Z0-9_-]{1,128}$/.test(operation.generation) ||
    !Number.isSafeInteger(operation.baseRevision) ||
    operation.baseRevision < 0
  )
    throw invalid();
  const p = operation.payload;
  if (operation.kind === 'extension') {
    exact(p, ['source', 'state']);
    exact(p.source, ['kind', 'id']);
    if (
      p.source.kind !== 'web-store' ||
      p.source.id !== operation.extensionId ||
      !['enabled', 'disabled', 'removed'].includes(p.state)
    )
      throw invalid();
  } else if (operation.kind === 'settings') {
    exact(p, ['set', 'remove', 'clear']);
    if (own(p, 'set') && !object(p.set)) throw invalid();
    if (
      own(p, 'remove') &&
      (!Array.isArray(p.remove) || p.remove.length > 512 || p.remove.some((k) => typeof k !== 'string'))
    )
      throw invalid();
    if (own(p, 'clear') && p.clear !== true) throw invalid();
    if (!Object.keys(p).length || (p.remove || []).some((k) => own(p.set || {}, k))) throw invalid();
  } else throw invalid();
}
function quota(values) {
  if (values.size > 512) return true;
  let total = 0;
  for (const [key, value] of values) {
    const size = Buffer.byteLength(key) + Buffer.byteLength(JSON.stringify(value));
    if (size > 8192 || (total += size) > 102400) return true;
  }
  return false;
}

class SyncProtocol {
  constructor(store) {
    this.store = store;
  }
  dataset(account, id) {
    const row = this.store.get(
      'SELECT * FROM datasets WHERE id = ? AND account_id = ? AND deleted = 0',
      id,
      account.id,
    );
    if (!row) throw missing();
    return row;
  }
  view(account, row) {
    return {
      id: row.id,
      name: this.store.decode(account, `dataset/${row.id}/name`, row.name),
      epoch: row.epoch,
      revision: row.revision,
    };
  }
  list(account) {
    return this.store
      .all('SELECT * FROM datasets WHERE account_id = ? AND deleted = 0 ORDER BY id', account.id)
      .map((d) => this.view(account, d));
  }
  create(account, body) {
    exact(body, ['name']);
    const name = label(body.name);
    if (this.list(account).length >= 100)
      throw failure(409, 'dataset_limit', 'Remove a dataset before creating another.');
    const id = randomUUID();
    this.store.run(
      'INSERT INTO datasets (id,account_id,name,epoch) VALUES (?,?,?,?)',
      id,
      account.id,
      this.store.encode(account, `dataset/${id}/name`, name),
      randomUUID(),
    );
    return this.view(account, this.dataset(account, id));
  }
  remove(account, id) {
    this.dataset(account, id);
    this.store.transaction(() => {
      for (const table of ['settings', 'extensions', 'generations', 'changes', 'operations'])
        this.store.run(`DELETE FROM ${table} WHERE dataset_id = ?`, id);
      this.store.run(
        'UPDATE datasets SET deleted = 1, epoch = ?, name = ? WHERE id = ?',
        randomUUID(),
        this.store.encode(account, `dataset/${id}/name`, 'Deleted dataset'),
        id,
      );
    });
  }
  settingRows(account, datasetId, extensionId, generation) {
    return this.store
      .all(
        'SELECT * FROM settings WHERE dataset_id = ? AND extension_id = ? AND generation = ? AND deleted = 0',
        datasetId,
        extensionId,
        generation,
      )
      .map((row) => ({
        ...row,
        data: this.store.decode(
          account,
          `setting/${datasetId}/${extensionId}/${generation}/${row.key}`,
          row.value,
        ),
      }));
  }
  snapshot(account, id, includeSettings = true) {
    const row = this.dataset(account, id);
    const extensions = this.store
      .all('SELECT * FROM extensions WHERE dataset_id = ? ORDER BY extension_id', id)
      .map((e) => ({
        extensionId: e.extension_id,
        generation: e.generation,
        revision: e.revision,
        ...this.store.decode(account, `extension/${id}/${e.extension_id}`, e.payload),
      }));
    const settings = [];
    for (const e of extensions.filter((e) => includeSettings && e.state !== 'removed')) {
      const rows = this.settingRows(account, id, e.extensionId, e.generation).filter((r) => !r.deleted);
      if (rows.length)
        settings.push({
          extensionId: e.extensionId,
          generation: e.generation,
          values: Object.fromEntries(rows.map((r) => [r.data.key, r.data.value])),
          revisions: Object.fromEntries(rows.map((r) => [r.data.key, r.revision])),
        });
    }
    return { dataset: this.view(account, row), extensions, settings, cursor: row.revision };
  }
  changes(account, id, query) {
    const dataset = this.dataset(account, id);
    const integer = (name, fallback) => {
      const value = query.get(name);
      if (value === null) return fallback;
      if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) throw invalid();
      return Number(value);
    };
    const after = integer('after', 0),
      through = integer('through', dataset.revision),
      limit = integer('limit', 100);
    if (after > through || through > dataset.revision || limit < 1 || limit > 200) throw invalid();
    const rows = this.store.all(
      'SELECT * FROM changes WHERE dataset_id = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?',
      id,
      after,
      through,
      limit,
    );
    const changes = rows
      .map((row) => this.store.decode(account, `change/${id}/${row.revision}`, row.payload))
      .filter((change) => query.get('settings') !== '0' || change.kind !== 'settings');
    const cursor = rows.at(-1)?.revision || after;
    return { changes, cursor, through, hasMore: cursor < through };
  }
  mutate(account, device, id, body) {
    exact(body, ['epoch', 'operations']);
    const dataset = this.dataset(account, id);
    if (body.epoch !== dataset.epoch)
      throw failure(409, 'epoch_changed', 'The dataset has changed. Link it again.');
    if (!Array.isArray(body.operations) || !body.operations.length || body.operations.length > 100)
      throw invalid();
    body.operations.forEach(validate);
    if (
      new Set(body.operations.map((o) => o.id)).size !== body.operations.length ||
      body.operations.some((o) => o.baseRevision > dataset.revision)
    )
      throw invalid();
    return this.store.transaction(() => {
      const results = [];
      for (const operation of body.operations) {
        const hash = this.store.fingerprint(account, `operation/${id}`, JSON.stringify(canonical(operation)));
        const previous = this.store.get(
          'SELECT * FROM operations WHERE dataset_id = ? AND id = ?',
          id,
          operation.id,
        );
        if (previous) {
          if (previous.device_id !== device.id || previous.digest !== hash)
            throw failure(409, 'operation_reused', 'An operation ID cannot be reused.');
          const result = JSON.parse(previous.result);
          results.push({ ...result, status: result.status === 'applied' ? 'duplicate' : result.status });
          continue;
        }
        const result = this.apply(account, dataset, operation);
        this.store.run(
          'INSERT INTO operations VALUES (?,?,?,?,?)',
          id,
          operation.id,
          device.id,
          hash,
          JSON.stringify(result),
        );
        results.push(result);
      }
      return { results, revision: dataset.revision };
    });
  }
  apply(account, dataset, operation) {
    const { extensionId, generation, payload } = operation,
      id = dataset.id;
    const current = this.store.get(
      'SELECT * FROM extensions WHERE dataset_id = ? AND extension_id = ?',
      id,
      extensionId,
    );
    const conflict = (code) => ({ id: operation.id, status: 'conflict', code });
    let changedPayload;
    if (operation.kind === 'extension') {
      const limit = () => ({ id: operation.id, status: 'quota', code: 'library_limit' });
      if (
        !current &&
        this.store.get('SELECT count(*) AS count FROM extensions WHERE dataset_id = ?', id).count >= 1000
      )
        return limit();
      if (
        payload.state !== 'removed' &&
        (!current || current.state === 'removed') &&
        this.store.get(
          "SELECT count(*) AS count FROM extensions WHERE dataset_id = ? AND state != 'removed'",
          id,
        ).count >= 100
      )
        return limit();
      if (current) {
        if (current.generation !== generation) {
          if (
            current.state !== 'removed' ||
            operation.baseRevision < current.revision ||
            this.store.get(
              'SELECT 1 FROM generations WHERE dataset_id = ? AND extension_id = ? AND generation = ?',
              id,
              extensionId,
              generation,
            )
          )
            return conflict('stale_generation');
        } else if (current.state === 'removed' && payload.state !== 'removed') return conflict('removed');
        else if (current.state === payload.state)
          return { id: operation.id, status: 'applied', revision: current.revision };
      }
      this.store.run('INSERT OR IGNORE INTO generations VALUES (?,?,?)', id, extensionId, generation);
      this.store.run(
        'INSERT INTO extensions VALUES (?,?,?,?,?,?) ON CONFLICT(dataset_id,extension_id) DO UPDATE SET generation=excluded.generation,revision=excluded.revision,state=excluded.state,payload=excluded.payload',
        id,
        extensionId,
        generation,
        dataset.revision + 1,
        payload.state,
        this.store.encode(account, `extension/${id}/${extensionId}`, payload),
      );
      changedPayload = payload;
    } else {
      if (!current || current.generation !== generation || current.state === 'removed')
        return conflict('stale_generation');
      const rows = this.settingRows(account, id, extensionId, generation);
      const old = new Map(rows.filter((r) => !r.deleted).map((r) => [r.data.key, r.data.value]));
      const values = new Map(old);
      if (payload.clear)
        for (const row of rows) if (row.revision <= operation.baseRevision) values.delete(row.data.key);
      for (const key of payload.remove || []) values.delete(key);
      for (const [key, value] of Object.entries(payload.set || {})) values.set(key, value);
      if (quota(values)) return { id: operation.id, status: 'quota', code: 'storage_quota' };
      const changes = [];
      for (const key of new Set([...old.keys(), ...values.keys()])) {
        if (
          old.has(key) === values.has(key) &&
          JSON.stringify(canonical(old.get(key))) === JSON.stringify(canonical(values.get(key)))
        )
          continue;
        const change = {
          ...(old.has(key) ? { oldValue: old.get(key) } : {}),
          ...(values.has(key) ? { newValue: values.get(key) } : {}),
        };
        changes.push([key, change]);
        const hash = this.store.fingerprint(account, `setting-key/${id}/${extensionId}/${generation}`, key),
          data = { key, ...(values.has(key) ? { value: values.get(key) } : {}) };
        this.store.run(
          'INSERT INTO settings VALUES (?,?,?,?,?,?,?) ON CONFLICT(dataset_id,extension_id,generation,key) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,value=excluded.value',
          id,
          extensionId,
          generation,
          hash,
          dataset.revision + 1,
          values.has(key) ? 0 : 1,
          this.store.encode(account, `setting/${id}/${extensionId}/${generation}/${hash}`, data),
        );
      }
      if (!changes.length) return { id: operation.id, status: 'applied', revision: dataset.revision };
      changedPayload = { changes: Object.fromEntries(changes) };
    }
    const revision = ++dataset.revision;
    this.store.run('UPDATE datasets SET revision = ? WHERE id = ?', revision, id);
    this.store.run(
      'INSERT INTO changes VALUES (?,?,?)',
      id,
      revision,
      this.store.encode(account, `change/${id}/${revision}`, {
        revision,
        kind: operation.kind,
        extensionId,
        generation,
        payload: changedPayload,
      }),
    );
    return { id: operation.id, status: 'applied', revision };
  }
}
module.exports = { SyncProtocol };
