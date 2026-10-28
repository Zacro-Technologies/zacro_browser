'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const syncFs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { createHash } = require('node:crypto');
const { createRequire } = require('node:module');
const { ensureRoot } = require('../lib/paths.cjs');
const filename = path.resolve(__dirname, '../native-branding/fetch-references.cjs');
const nativeRequire = createRequire(filename);
const api = nativeRequire(filename);

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-reference-'));
  t.after(async () => {
    const real = await fs.realpath(directory),
      temporary = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), temporary.toLowerCase());
    assert.match(path.basename(real), /^zacro-native-reference-/);
    await fs.rm(real, { recursive: true });
  });
  return directory;
}

function fixture() {
  const revision = 'a'.repeat(40);
  const payloads = Array.from({ length: 9 }, (_, index) => Buffer.from(`pinned original ${index}\n`));
  return {
    payloads,
    manifest: {
      schemaVersion: 1,
      revision,
      files: payloads.map((bytes, index) => {
        const relative = `source-${index}/original.cc`;
        return {
          path: relative,
          beforeSha256: createHash('sha256').update(bytes).digest('hex'),
          sourceUrl: `https://raw.githubusercontent.com/chromium/chromium/${revision}/${relative}`,
        };
      }),
    },
  };
}
function load(data, fetchOverride) {
  const calls = [];
  const module = { exports: {} };
  vm.runInNewContext(syncFs.readFileSync(filename, 'utf8'), {
    module,
    exports: module.exports,
    require(id) {
      return id === './manifest.json' ? data.manifest : nativeRequire(id);
    },
    Buffer,
    AbortSignal,
    fetch: async (url, options) => {
      calls.push({ url, options });
      if (fetchOverride) return fetchOverride(url, options);
      const index = data.manifest.files.findIndex((file) => file.sourceUrl === url);
      assert.ok(index >= 0);
      return new Response(data.payloads[index]);
    },
  });
  return { ...module.exports, calls };
}

test('reference CLI accepts only an absolute external root and the checked-in manifest is valid', () => {
  api.verifyManifest();
  assert.deepEqual(api.parseOptions(['--root', path.resolve(os.tmpdir(), 'references')]), {
    root: path.resolve(os.tmpdir(), 'references'),
  });
  for (const args of [
    [],
    ['--root', 'relative'],
    ['--url', 'https://example.com'],
    ['--root', os.tmpdir(), '--force'],
  ])
    assert.throws(() => api.parseOptions(args), /absolute_external/i);
  const data = fixture();
  data.manifest.files[0].path = '../escape';
  assert.throws(() => load(data).verifyManifest(), /paths, hashes and upstream URLs/);
  const redirected = fixture();
  redirected.manifest.files[0].sourceUrl = 'https://example.com/arbitrary';
  assert.throws(() => load(redirected).verifyManifest(), /paths, hashes and upstream URLs/);
});

test('reference fetch verifies nine files and reuses originals without network or rewriting', async (t) => {
  const root = path.join(await scratch(t), 'owned');
  const data = fixture(),
    h = load(data);
  const first = await h.fetchReferences(root);
  assert.equal(first.verifiedFiles, 9);
  assert.equal(first.downloadedFiles, 9);
  assert.equal(first.fullCheckout, false);
  assert.equal(first.compiled, false);
  assert.equal(
    first.referenceDirectory,
    path.join(root, 'source-references', `native-${data.manifest.revision}`),
  );
  assert.equal(h.calls.length, 9);
  for (const call of h.calls) {
    assert.equal(call.options.redirect, 'error');
    assert.equal(call.options.credentials, 'omit');
    assert.ok(call.options.signal);
  }
  const before = await fs.stat(path.join(first.referenceDirectory, data.manifest.files[0].path));
  const offline = load(data, () => assert.fail('Cache reuse must not contact the network'));
  const second = await offline.fetchReferences(root);
  assert.equal(second.downloadedFiles, 0);
  assert.equal(
    (await fs.stat(path.join(first.referenceDirectory, data.manifest.files[0].path))).mtimeMs,
    before.mtimeMs,
  );
  assert.equal(offline.calls.length, 0);
});

test('changed cached files and foreign directories are retained and rejected before network', async (t) => {
  const directory = await scratch(t),
    root = path.join(directory, 'owned');
  const data = fixture(),
    h = load(data);
  const result = await h.fetchReferences(root);
  const changed = path.join(result.referenceDirectory, data.manifest.files[8].path);
  await fs.writeFile(changed, 'user changes');
  const offline = load(data, () => assert.fail('Changed files must be checked before network'));
  await assert.rejects(offline.fetchReferences(root), /Existing reference differs/);
  assert.equal(await fs.readFile(changed, 'utf8'), 'user changes');
  const foreignRoot = await ensureRoot(path.join(directory, 'other-owned'));
  const foreign = path.join(foreignRoot, 'source-references', `native-${data.manifest.revision}`);
  await fs.mkdir(foreign, { recursive: true });
  await fs.writeFile(path.join(foreign, 'keep.txt'), 'retained');
  await assert.rejects(offline.fetchReferences(foreignRoot), /Refusing to adopt/);
  assert.equal(await fs.readFile(path.join(foreign, 'keep.txt'), 'utf8'), 'retained');
  assert.equal(offline.calls.length, 0);
});

test('bad downloads fail closed without publishing reference files', async (t) => {
  const directory = await scratch(t);
  for (const [label, payload] of [
    ['wrong-hash', 'not upstream'],
    ['oversized', Buffer.alloc(2 * 1024 ** 2 + 1)],
  ]) {
    const data = fixture(),
      h = load(data, async () => new Response(payload));
    const root = path.join(directory, label);
    await assert.rejects(h.fetchReferences(root), /pinned SHA-256|download limit/);
    const leaf = path.join(root, 'source-references', `native-${data.manifest.revision}`);
    assert.deepEqual(await fs.readdir(leaf), ['.zacro-native-references.json']);
  }
});

test('atomic publication never overwrites a concurrently created destination', async (t) => {
  const root = path.join(await scratch(t), 'owned'),
    data = fixture();
  const target = path.join(
    root,
    'source-references',
    `native-${data.manifest.revision}`,
    data.manifest.files[0].path,
  );
  const h = load(data, async () => {
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, 'concurrent data', { flag: 'wx' });
    return new Response(data.payloads[0]);
  });
  await assert.rejects(h.fetchReferences(root), { code: 'EEXIST' });
  assert.equal(await fs.readFile(target, 'utf8'), 'concurrent data');
  assert.deepEqual(await fs.readdir(path.dirname(target)), ['original.cc']);
});

test('reference junctions and changed owner markers cannot redirect writes or authorize adoption', async (t) => {
  const directory = await scratch(t),
    root = path.join(directory, 'owned'),
    outside = path.join(directory, 'outside');
  await fs.mkdir(outside);
  await ensureRoot(root);
  await fs.symlink(
    outside,
    path.join(root, 'source-references'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  const data = fixture(),
    h = load(data, () => assert.fail('Redirected paths must not contact the network'));
  await assert.rejects(h.fetchReferences(root), /link redirects|symbolic links or junctions/);
  assert.deepEqual(await fs.readdir(outside), []);
  const next = path.join(directory, 'different-owned'),
    good = load(data);
  const result = await good.fetchReferences(next);
  const marker = path.join(result.referenceDirectory, '.zacro-native-references.json');
  await fs.writeFile(marker, JSON.stringify({ kind: 'foreign' }));
  await assert.rejects(h.fetchReferences(next), /owner marker/);
  assert.deepEqual(JSON.parse(await fs.readFile(marker, 'utf8')), { kind: 'foreign' });
});
