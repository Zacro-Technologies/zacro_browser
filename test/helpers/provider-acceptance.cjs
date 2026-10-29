'use strict';
// Test-only gates. They never replace production HTTPS/CRX verification or native capabilities.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const https = require('node:https');
const zlib = require('node:zlib');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const PINS = Object.freeze({
  'dark-reader': {
    name: 'Dark Reader',
    id: 'eimadpbcbfnmbkopoojfekhnkhdbieeh',
    version: '4.9.133',
    sha256: 'ee38f20d1d50789f4b482c9a1a5dadab599b8682fd2a7dfb7de21fae8561b918',
  },
  'react-devtools': {
    name: 'React Developer Tools',
    id: 'fmkadmapgofadopljbjfkapdkoienihi',
    version: '8.0.0',
    sha256: 'd92e1122a16362cc5510927068a5b1a8d50b43e1f3be25c3117f7c005807b302',
  },
  'ublock-origin-lite': {
    name: 'uBlock Origin Lite',
    manifestName: '__MSG_extName__',
    id: 'ddkjiahejlhfcafbddmgiahcphecmpfh',
    version: '2026.1021.1354',
    sha256: '0887559eb9e6864e91b52e4a0c660995ade47c084dcc7150ed9ae743c9475a76',
  },
  bitwarden: {
    name: 'Bitwarden',
    manifestName: '__MSG_extName__',
    id: 'nngceckbapebfimnlniiiahkandclblb',
    version: '2026.10.0',
    sha256: 'f2feb7fc46d2550bef9b69af1cc358aea26b90a947645f9de16ec14d9296ef69',
  },
});
function assertPins(pin, version, sha256) {
  assert.equal(version, pin.version, 'Provider changed the explicitly pinned version; review required');
  assert.equal(sha256, pin.sha256, 'Provider changed original SHA-256; review required');
}
function requireNativeCapabilities(capabilities, required) {
  if (!required) return;
  assert.equal(capabilities.version, 1, 'Required custom runtime did not negotiate the v1 native ABI');
  for (const name of ['reviewedPermissions', 'activeTab', 'userScripts', 'fontSettings'])
    assert.equal(capabilities[name], true, `Required custom runtime lacks ${name}`);
}
function installAcquisitionGuard(packages, evidence) {
  const productionFetch = packages.fetchStorePackage;
  packages.fetchStorePackage = async (id, options) => {
    const pin = Object.values(PINS).find((item) => item.id === id);
    assert.ok(pin, 'Unreviewed provider ID');
    // Real production fetch includes bounded HTTPS redirects, developer proof and publisher proof.
    const download = await productionFetch(id, options);
    const digest = crypto.createHash('sha256').update(download.buffer).digest('hex');
    assert.equal(digest, pin.sha256, 'Provider changed original SHA-256; review required');
    assert.equal(download.publisherVerified, true);
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-provider-pin-'));
    try {
      await packages.extractArchive(download.zip, path.join(directory, 'original'), {
        signal: options.signal,
      });
      const manifest = JSON.parse(await fs.readFile(path.join(directory, 'original/manifest.json'), 'utf8'));
      assertPins(pin, manifest.version, digest);
      evidence.push({ id, version: manifest.version, sha256: digest, publisherVerified: true });
      return download;
    } finally {
      await fs.rm(directory, { recursive: true, force: true });
    }
  };
}
function readTarMember(tar, member) {
  let found;
  for (let offset = 0; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((value) => value === 0)) break;
    const name = header.subarray(0, 100).toString().replace(/\0.*$/, '');
    const sizeText = header.subarray(124, 136).toString().replace(/\0.*$/, '').trim();
    if (!/^[0-7]+$/.test(sizeText)) throw new Error('Invalid tar member size');
    const size = parseInt(sizeText, 8);
    const start = offset + 512;
    if (start + size > tar.length) throw new Error('Truncated tar member');
    if (name === member) {
      if (found || ![0, 48].includes(header[156])) throw new Error('Invalid duplicate/non-file tar member');
      found = tar.subarray(start, start + size);
    }
    offset = start + Math.ceil(size / 512) * 512;
  }
  if (!found) throw new Error(`Missing tar member: ${member}`);
  return found;
}
const REACT = Object.freeze({
  react: {
    size: 81751,
    integrity: 'wS+hAgJShR0KhEvPJArfuPVN1+Hz1t0Y6n5jLrGQbkb4urgPE/0Rve+1kMB1v/oWgHgm4WIcV+i7F2pTVj+2iQ==',
  },
  'react-dom': {
    size: 1089001,
    integrity: '5m4nQKp+rZRb09LNH59GM4BxTh9251/ylbKIbpe7TpGxfJ+9kv6BLkLBXIjjspbgbnIBNqlI23tRnTWT0snUIw==',
  },
});
async function acquireReactScripts() {
  const scripts = {};
  for (const [name, pin] of Object.entries(REACT)) {
    const bytes = await new Promise((resolve, reject) => {
      const request = https.get(
        `https://registry.npmjs.org/${name}/-/${name}-18.3.1.tgz`,
        { signal: AbortSignal.timeout(30000), headers: { 'Accept-Encoding': 'identity' } },
        (response) => {
          if (response.statusCode !== 200) {
            response.destroy();
            reject(new Error(`npm HTTP ${response.statusCode}`));
            return;
          }
          const chunks = [];
          let size = 0;
          response.on('data', (chunk) => {
            size += chunk.length;
            if (size > pin.size) response.destroy(new Error('npm archive exceeds pinned bound'));
            else chunks.push(chunk);
          });
          response.on('error', reject);
          response.on('end', () => resolve(Buffer.concat(chunks)));
        },
      );
      request.on('error', reject);
    });
    assert.equal(bytes.length, pin.size, 'npm archive size changed');
    assert.equal(
      crypto.createHash('sha512').update(bytes).digest('base64'),
      pin.integrity,
      'npm integrity changed',
    );
    scripts[name] = readTarMember(
      zlib.gunzipSync(bytes, { maxOutputLength: 6 * 1024 * 1024 }),
      `package/umd/${name}.development.js`,
    );
  }
  return scripts;
}
module.exports = {
  PINS,
  assertPins,
  requireNativeCapabilities,
  installAcquisitionGuard,
  readTarMember,
  acquireReactScripts,
};
