'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { zip, crx, keyPair, field } = require('./fixtures/extensions/packages/builders.cjs');
let packages;
try {
  packages = require('../src/main/extensions/packages.cjs');
} catch (e) {
  if (e.code !== 'MODULE_NOT_FOUND') throw e;
}
const api = () => {
  assert.ok(packages, 'verified package module must exist');
  return packages;
};
const ID = 'eimadpbcbfnmbkopoojfekhnkhdbieeh';
const archive = () =>
  zip([
    { name: 'manifest.json', data: '{"name":"Synthetic","version":"1","manifest_version":3}' },
    { name: 'dir/script.js', data: '42', deflate: true },
  ]);

test('store IDs accept only canonical HTTPS detail paths or exact IDs', () => {
  const { parseStoreId } = api();
  for (const input of [
    ID,
    `https://chromewebstore.google.com/detail/dark-reader/${ID}`,
    `https://chrome.google.com/webstore/detail/dark-reader/${ID}`,
  ])
    assert.equal(parseStoreId(input), ID);
  for (const input of [
    'a'.repeat(31),
    'z'.repeat(32),
    `http://chromewebstore.google.com/detail/x/${ID}`,
    `https://evil.test/detail/x/${ID}`,
    `https://user@chromewebstore.google.com/detail/x/${ID}`,
    `https://chromewebstore.google.com:444/detail/x/${ID}`,
    `https://chromewebstore.google.com/detail/x/${ID}/extra`,
    `https://chromewebstore.google.com/detail/x/%65${ID.slice(1)}`,
  ])
    assert.throws(() => parseStoreId(input));
});
test('CRX3 binds signed ID, developer proof, every signature and exact ZIP bytes', () => {
  const { verifyCrx } = api();
  for (const keys of [[keyPair()], [keyPair('ec')], [keyPair(), keyPair('ec')]]) {
    const fixture = crx(archive(), { keys });
    const verified = verifyCrx(fixture.buffer, { expectedId: fixture.id, requirePublisher: false });
    assert.equal(verified.id, fixture.id);
    assert.equal(verified.publicKey, fixture.publicKey);
    assert.deepEqual(verified.zip, archive());
    assert.equal(verified.sha256.length, 64);
    assert.throws(
      () => verifyCrx(fixture.buffer, { expectedId: ID, requirePublisher: false }),
      /identity|ID/i,
    );
    const damaged = Buffer.from(fixture.buffer);
    damaged[damaged.length - 1] ^= 1;
    assert.throws(
      () => verifyCrx(damaged, { expectedId: fixture.id, requirePublisher: false }),
      /signature/i,
    );
  }
  const wrong = crx(archive(), { declaredId: Buffer.alloc(16) });
  assert.throws(
    () => verifyCrx(wrong.buffer, { expectedId: wrong.id, requirePublisher: false }),
    /proof|identity/i,
  );
});
test('production rejects unsigned store claims, unknown publisher keys and malformed headers', () => {
  const { verifyCrx } = api(),
    fixture = crx(archive(), { keys: [keyPair(), keyPair('ec')] });
  assert.throws(() => verifyCrx(fixture.buffer, { expectedId: fixture.id }), /publisher/i);
  assert.throws(
    () => verifyCrx(fixture.buffer, { expectedId: fixture.id, publisherKeyHashes: ['anything'] }),
    /publisher/i,
  );
  for (const invalid of [
    fixture.buffer.subarray(0, 11),
    Buffer.from('Cr24garbage'),
    crx(archive(), { additionalHeader: field(10000, field(1, Buffer.alloc(16))) }).buffer,
  ])
    assert.throws(() => verifyCrx(invalid, { expectedId: fixture.id, requirePublisher: false }));
  const badVersion = Buffer.from(fixture.buffer);
  badVersion.writeUInt32LE(2, 4);
  assert.throws(() => verifyCrx(badVersion, { expectedId: fixture.id, requirePublisher: false }));
});
test('archive extraction writes exact bytes into an unused destination and does not overwrite', async (t) => {
  const { extractArchive } = api(),
    root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-zip-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const destination = path.join(root, 'original');
  await extractArchive(archive(), destination);
  assert.equal(await fs.readFile(path.join(destination, 'dir/script.js'), 'utf8'), '42');
  await assert.rejects(extractArchive(archive(), destination));
  assert.equal(await fs.readFile(path.join(destination, 'dir/script.js'), 'utf8'), '42');
});
test('hostile archive names, collisions, types, CRC and declared bombs leave no extracted destination', async (t) => {
  const { extractArchive } = api(),
    root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-hostile-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const bad = [
    [{ name: '../outside', data: 'x' }],
    [{ name: '/absolute', data: 'x' }],
    [{ name: 'C:/drive', data: 'x' }],
    [{ name: 'back\\slash', data: 'x' }],
    [{ name: 'dir/../x', data: 'x' }],
    [{ name: 'con.txt', data: 'x' }],
    [{ name: 'x:stream', data: 'x' }],
    [{ name: 'x.', data: 'x' }],
    [
      { name: 'x', data: '1' },
      { name: 'X', data: '2' },
    ],
    [
      { name: 'Dir/x', data: '1' },
      { name: 'dir/y', data: '2' },
    ],
    [
      { name: 'dir', data: '1' },
      { name: 'dir/file', data: '2' },
    ],
    [
      { name: 'same', data: '1' },
      { name: 'same', data: '2' },
    ],
    [{ name: 'link', data: '../outside', mode: 0o120777 }],
    [{ name: 'pipe', mode: 0o010644 }],
    [{ name: 'badcrc', data: 'abc', crc: 1 }],
    [{ name: 'huge', data: 'x', size: 301 * 1024 * 1024, deflate: true }],
    [{ name: 'a/'.repeat(33) + 'x', data: 'x' }],
    [{ name: 'zero\0x', data: 'x' }],
  ];
  for (const [n, entries] of bad.entries()) {
    const destination = path.join(root, String(n));
    await assert.rejects(extractArchive(zip(entries), destination), undefined, JSON.stringify(entries));
    await assert.rejects(fs.stat(destination), { code: 'ENOENT' });
  }
});
test('archive bounds actual expansion and aggregate count; cancellation leaves no partial files', async (t) => {
  const { extractArchive } = api(),
    root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-limits-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await assert.rejects(
    extractArchive(
      zip([{ name: 'bomb', data: Buffer.alloc(2 * 1024 * 1024), deflate: true }]),
      path.join(root, 'bomb'),
    ),
    /ratio|bomb/i,
  );
  await assert.rejects(
    extractArchive(
      zip(Array.from({ length: 15001 }, (_, i) => ({ name: `f${i}` }))),
      path.join(root, 'count'),
    ),
    /count|entries|files/i,
  );
  await assert.rejects(extractArchive(archive(), path.join(root, 'abort'), { signal: AbortSignal.abort() }));
  assert.deepEqual(await fs.readdir(root), []);
});

test('download boundary refuses redirects outside observed HTTPS Google distribution hosts', async () => {
  const { fetchStorePackage } = api();
  const { Readable } = require('node:stream'),
    { EventEmitter } = require('node:events');
  for (const location of [
    'http://clients2.google.com/x',
    'https://evil.test/x',
    'https://clients2.google.com.evil.test/x',
    'https://user@clients2.google.com/x',
    'https://clients2.google.com:444/x',
    'https://clients2.google.com/x#fragment',
  ]) {
    let calls = 0;
    const request = (url, options, callback) => {
      calls++;
      assert.equal(url.hostname, 'clients2.google.com');
      const request = new EventEmitter();
      queueMicrotask(() => {
        const response = Readable.from([]);
        response.statusCode = 302;
        response.headers = { location };
        callback(response);
      });
      return request;
    };
    await assert.rejects(fetchStorePackage(ID, { chromiumVersion: '156.0.8078.48', request }), /Unsafe/);
    assert.equal(calls, 1);
  }
});
test('download limits redirect cycles, declared sizes, encoding and rejects synthetic publisher before returning', async () => {
  const { fetchStorePackage } = api();
  const { Readable } = require('node:stream'),
    { EventEmitter } = require('node:events');
  const fixture = crx(archive());
  for (const item of [
    {
      code: 302,
      headers: { location: 'https://clients2.googleusercontent.com/x' },
      data: [],
      error: /redirect/,
    },
    { code: 200, headers: { 'content-length': String(101 * 1024 * 1024) }, data: [], error: /size/ },
    { code: 200, headers: { 'content-encoding': 'gzip' }, data: [], error: /encoding/ },
    { code: 200, headers: {}, data: [fixture.buffer], error: /publisher/ },
    { code: 404, headers: {}, data: [], error: /unavailable/ },
  ]) {
    let calls = 0;
    const request = (url, options, callback) => {
      calls++;
      const req = new EventEmitter();
      queueMicrotask(() => {
        const res = Readable.from(item.data);
        res.statusCode = item.code;
        res.headers = item.headers;
        callback(res);
      });
      return req;
    };
    await assert.rejects(
      fetchStorePackage(fixture.id, { chromiumVersion: '156.0.8078.48', request }),
      item.error,
    );
    assert.ok(calls <= 5);
  }
});
test('manifest inspection lists required and optional access and blocks missing engine capabilities', () => {
  let catalog;
  try {
    catalog = require('../src/main/extensions/catalog.cjs');
  } catch (e) {
    if (e.code !== 'MODULE_NOT_FOUND') throw e;
  }
  assert.ok(catalog, 'manifest catalog must exist');
  const result = catalog.inspectManifest({
    manifest_version: 3,
    name: 'Fixture',
    version: '1.2',
    permissions: ['storage', 'tabs'],
    host_permissions: ['https://example.com/*'],
    optional_permissions: ['activeTab'],
    optional_host_permissions: ['https://other.test/*'],
    content_scripts: [{ matches: ['https://content.test/*'], js: ['a.js'] }],
  });
  assert.deepEqual(result.required, {
    permissions: ['storage', 'tabs'],
    origins: ['https://content.test/*', 'https://example.com/*'],
  });
  assert.deepEqual(result.optional, { permissions: ['activeTab'], origins: ['https://other.test/*'] });
  assert.equal(result.compatible, true);
  const blocked = catalog.inspectManifest({
    manifest_version: 3,
    name: 'Blocked',
    version: '1',
    permissions: ['enterprise.platformKeys', 'enterprise.networkingAttributes', 'declarativeNetRequest'],
  });
  assert.equal(blocked.compatible, false);
  assert.equal(blocked.unsupported.length, 2);
  assert.equal(
    catalog.inspectManifest({
      manifest_version: 3,
      name: 'File',
      version: '1',
      host_permissions: ['file:///*'],
    }).compatible,
    false,
  );
  for (const manifest of [
    { manifest_version: 1, name: 'x', version: '1' },
    { manifest_version: 3, name: 'x', version: 'no' },
    { manifest_version: 3, name: 'x', version: '1', permissions: 'tabs' },
  ])
    assert.throws(() => catalog.inspectManifest(manifest));
});

test('every CRX proof must verify even when a valid developer signature precedes it', () => {
  const { verifyCrx } = api();
  const fixture = crx(archive(), { keys: [keyPair(), keyPair('ec')] });
  const damaged = Buffer.from(fixture.buffer);
  // The EC proof occurs after the RSA proof. Flip its DER signature tail while
  // keeping the signed header, developer proof and archive untouched.
  const signedHeaderTag = Buffer.from([0x82, 0xf1, 0x04]);
  const signedOffset = damaged.indexOf(signedHeaderTag, 12);
  assert.ok(signedOffset > 12);
  damaged[signedOffset - 1] ^= 1;
  assert.throws(() => verifyCrx(damaged, { expectedId: fixture.id, requirePublisher: false }), /signature/);
});
test('archive rejects inconsistent local CRC headers and aggregate expanded-size bombs', async (t) => {
  const { extractArchive } = api();
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-zip-more-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const wrong = archive();
  wrong.writeUInt32LE(1, 14);
  await assert.rejects(extractArchive(wrong, path.join(root, 'wrong')), /header|CRC/);
  const crypto = require('node:crypto');
  const many = zip(
    Array.from({ length: 4 }, (_, index) => ({
      name: `large${index}`,
      data: crypto.randomBytes(100 * 1024),
      deflate: true,
      size: 80 * 1024 * 1024,
    })),
  );
  await assert.rejects(extractArchive(many, path.join(root, 'many')), /expanded/);
  assert.deepEqual(await fs.readdir(root), []);
});
