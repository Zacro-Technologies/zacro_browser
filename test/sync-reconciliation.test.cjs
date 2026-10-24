'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { randomBytes, randomUUID, createHash } = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { createSyncService } = require('../services/sync/server.cjs');

const extensionId = 'a'.repeat(32),
  secondId = 'b'.repeat(32);
const password = 'Synthetic reconciliation password';
async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-reconcile-'));
  const options = { directory, masterKey: randomBytes(32), allowInsecureLoopback: true };
  const service = await createSyncService(options);
  t.after(async () => {
    await service.close();
    await fs.rm(directory, { recursive: true, force: true });
  });
  const request = async (route, token, body, method = body ? 'POST' : 'GET') => {
    const response = await fetch(service.url + '/v1' + route, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: response.status, data: await response.json() };
  };
  const a = (
    await request('/accounts', null, {
      username: 'sync.account',
      password,
      deviceName: 'A',
      platform: 'test',
    })
  ).data;
  const b = (
    await request('/sessions', null, {
      username: 'sync.account',
      password,
      deviceName: 'B',
      platform: 'test',
    })
  ).data;
  const created = await request('/datasets', a.accessToken, { name: 'Personal extensions' });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const dataset = created.data;
  const mutate = async (operations, token = a.accessToken, epoch = dataset.epoch) =>
    request(`/datasets/${dataset.id}/operations`, token, { epoch, operations });
  const snapshot = async (token = a.accessToken) => request(`/datasets/${dataset.id}/snapshot`, token);
  const library = (
    state = 'enabled',
    { id = extensionId, generation = 'generation-one', baseRevision = 0 } = {},
  ) => ({
    id: randomUUID(),
    kind: 'extension',
    extensionId: id,
    generation,
    baseRevision,
    payload: { source: { kind: 'web-store', id }, state },
  });
  const settings = (payload, baseRevision = 0, generation = 'generation-one') => ({
    id: randomUUID(),
    kind: 'settings',
    extensionId,
    generation,
    baseRevision,
    payload,
  });
  return { ...options, service, a, b, dataset, request, mutate, snapshot, library, settings };
}

test('two real clients merge independent keys, deduplicate retries and preserve unseen keys during stale clear', async (t) => {
  const f = await fixture(t);
  assert.equal((await f.mutate([f.library()])).data.results[0].status, 'applied');
  const first = f.settings({ set: { theme: 'dark', count: 1 } }, 1);
  const saved = await f.mutate([first]);
  assert.equal(saved.data.results[0].status, 'applied');
  const duplicate = await f.mutate([first]);
  assert.equal(duplicate.data.results[0].status, 'duplicate');
  assert.equal(duplicate.data.revision, saved.data.revision);
  assert.equal(
    (await f.mutate([first], f.b.accessToken)).status,
    409,
    'operation IDs are bound to the originating device',
  );
  await f.mutate([f.settings({ set: { addedOffline: true } }, 1)], f.b.accessToken);
  await f.mutate([f.settings({ clear: true }, 2)]);
  const state = (await f.snapshot()).data;
  assert.deepEqual(state.settings[0].values, { addedOffline: true });
  assert.equal(state.cursor, 4);
  const changes = (await f.request(`/datasets/${f.dataset.id}/changes?after=0&limit=2`, f.a.accessToken))
    .data;
  assert.equal(changes.through, 4);
  assert.equal(changes.hasMore, true);
  await f.mutate([f.library('disabled')]);
  const next = (
    await f.request(
      `/datasets/${f.dataset.id}/changes?after=${changes.cursor}&through=${changes.through}&limit=2`,
      f.a.accessToken,
    )
  ).data;
  assert.equal(next.cursor, 4);
  assert.equal(next.hasMore, false);
  assert.equal(next.changes.at(-1).payload.changes.theme.oldValue, 'dark');
  assert.equal((await f.request(`/datasets/${f.dataset.id}/changes?after=-1`, f.a.accessToken)).status, 400);
});

test('removal wins over stale state and settings; reinstall requires observing removal and a fresh generation', async (t) => {
  const f = await fixture(t);
  await f.mutate([f.library()]);
  await f.mutate([f.settings({ set: { secretSetting: 'private extension value' } }, 1)]);
  await f.mutate([f.library('removed')], f.b.accessToken);
  for (const op of [
    f.library('enabled'),
    f.settings({ set: { resurrect: true } }, 1),
    f.library('enabled', { generation: 'next-generation', baseRevision: 1 }),
  ]) {
    assert.equal((await f.mutate([op])).data.results[0].status, 'conflict');
  }
  assert.equal(
    (await f.mutate([f.library('enabled', { generation: 'next-generation', baseRevision: 3 })])).data
      .results[0].status,
    'applied',
  );
  assert.deepEqual((await f.snapshot()).data.settings, []);
  assert.equal((await f.snapshot()).data.extensions[0].generation, 'next-generation');
  const db = await fs.readFile(path.join(f.directory, 'sync.sqlite-wal'));
  assert.equal(db.includes(Buffer.from('private extension value')), false);
});

test('quota rejection is atomic and independent operations continue; replay with changed payload is rejected', async (t) => {
  const f = await fixture(t);
  await f.mutate([f.library()]);
  const initial = Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`key${i}`, 'x'.repeat(8000)]));
  await f.mutate([f.settings({ set: initial }, 1)]);
  const over = f.settings({ set: { extra: 'y'.repeat(8000), doNotPartiallyCommit: 1 } }, 2);
  const result = await f.mutate([over, f.library('enabled', { id: secondId })]);
  assert.equal(result.data.results[0].status, 'quota');
  assert.equal(result.data.results[1].status, 'applied');
  const saved = (await f.snapshot()).data.settings[0].values;
  assert.equal(Object.hasOwn(saved, 'extra'), false);
  assert.equal(Object.hasOwn(saved, 'doNotPartiallyCommit'), false);
  assert.equal(Object.keys(saved).length, 12);
  assert.equal((await f.mutate([{ ...over, payload: { set: { changedReplay: 1 } } }])).status, 409);
  assert.equal(
    (await f.mutate([f.settings({ set: { enormous: 'x'.repeat(8193) } })])).data.results[0].status,
    'quota',
  );
});

test('dataset and account isolation reject foreign, deleted, stale-epoch and malformed operations', async (t) => {
  const f = await fixture(t);
  const other = (
    await f.request('/accounts', null, {
      username: 'other.account',
      password,
      deviceName: 'Other',
      platform: 'test',
    })
  ).data;
  assert.equal((await f.snapshot(other.accessToken)).status, 404);
  assert.equal((await f.mutate([f.library()], other.accessToken)).status, 404);
  assert.equal((await f.mutate([f.library()], f.a.accessToken, 'wrong-epoch')).status, 409);
  assert.equal(
    (
      await f.mutate([
        { ...f.library(), payload: { source: { kind: 'local', path: '/private/path' }, state: 'enabled' } },
      ])
    ).status,
    400,
  );
  assert.equal(
    (await f.request(`/datasets/${f.dataset.id}`, f.a.accessToken, { password, confirm: true }, 'DELETE'))
      .status,
    200,
  );
  assert.equal((await f.mutate([f.library()])).status, 404);
  assert.equal((await f.snapshot()).status, 404);
});

test('database lookup fingerprints cannot expose setting keys by unkeyed dictionary guesses', async (t) => {
  const f = await fixture(t);
  await f.mutate([f.library()]);
  await f.mutate([f.settings({ set: { 'personal-information-key': 'secret setting value' } }, 1)]);
  const db = new DatabaseSync(path.join(f.directory, 'sync.sqlite'), { readOnly: true });
  try {
    const row = db.prepare('SELECT key, value FROM settings LIMIT 1').get();
    assert.notEqual(row.key, createHash('sha256').update('personal-information-key').digest('hex'));
    assert.equal(Buffer.from(row.value).includes(Buffer.from('secret setting value')), false);
  } finally {
    db.close();
  }
});

test('bounded libraries and nested JSON reject excess without blocking independent valid mutations', async (t) => {
  const f = await fixture(t);
  const id = (n) =>
    n
      .toString(16)
      .replace(/[0-9a-f]/g, (c) => String.fromCharCode(97 + parseInt(c, 16)))
      .padStart(32, 'a');
  const first = await f.mutate(Array.from({ length: 100 }, (_, n) => f.library('enabled', { id: id(n) })));
  assert.ok(first.data.results.every((r) => r.status === 'applied'));
  const over = await f.mutate([f.library('enabled', { id: id(100) }), f.library('disabled', { id: id(0) })]);
  assert.equal(over.data.results[0].status, 'quota');
  assert.equal(over.data.results[0].code, 'library_limit');
  assert.equal(over.data.results[1].status, 'applied');
  let nested = 'value';
  for (let n = 0; n < 80; n++) nested = { nested };
  assert.equal((await f.mutate([f.settings({ set: { nested } })])).status, 400);
  assert.equal((await f.snapshot()).status, 200);
});

test('library-only snapshot and changefeed never transmit extension setting values', async (t) => {
  const f = await fixture(t);
  await f.mutate([f.library()]);
  await f.mutate([f.settings({ set: { personal: 'private-setting' } }, 1)]);
  const snapshot = (await f.request(`/datasets/${f.dataset.id}/snapshot?settings=0`, f.a.accessToken)).data;
  assert.deepEqual(snapshot.settings, []);
  assert.equal(JSON.stringify(snapshot).includes('private-setting'), false);
  const changes = (await f.request(`/datasets/${f.dataset.id}/changes?after=0&settings=0`, f.a.accessToken))
    .data;
  assert.equal(changes.cursor, 2);
  assert.equal(changes.hasMore, false);
  assert.deepEqual(
    changes.changes.map((c) => c.kind),
    ['extension'],
  );
});
