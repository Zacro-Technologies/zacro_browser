'use strict';
// Original MIT implementation of the published CRX3 format, verified with Node crypto.
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const https = require('node:https');
const yauzl = require('yauzl');
const LIMITS = Object.freeze({
  download: 100 * 1024 * 1024,
  expanded: 300 * 1024 * 1024,
  file: 100 * 1024 * 1024,
  entries: 15000,
  depth: 32,
  header: 1024 * 1024,
});
const PUBLISHER_SHA256 = '61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf';
const DISTRIBUTION_HOSTS = Object.freeze(['clients2.google.com', 'clients2.googleusercontent.com']);
const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const idFromKey = (bytes) =>
  [...sha256(bytes).slice(0, 32)].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
function parseStoreId(input) {
  if (typeof input !== 'string' || input.length > 2048) throw new Error('Invalid store ID or URL');
  input = input.trim();
  if (/^[a-p]{32}$/.test(input)) return input;
  let url;
  try {
    url = new URL(input);
  } catch {
    throw new Error('Invalid store ID or URL');
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.port || input.includes('\\'))
    throw new Error('Invalid store URL');
  const expression =
    url.hostname === 'chromewebstore.google.com'
      ? /^\/detail\/[^/%]+\/([a-p]{32})$/
      : url.hostname === 'chrome.google.com'
        ? /^\/webstore\/detail\/[^/%]+\/([a-p]{32})$/
        : null;
  const match = expression?.exec(url.pathname);
  if (!match) throw new Error('Invalid canonical store detail URL');
  return match[1];
}
// A bounded protobuf wire reader: preserve signed bytes; reject ambiguous singleton fields.
function fields(bytes) {
  const result = new Map();
  let position = 0,
    count = 0;
  function integer() {
    let n = 0,
      scale = 1;
    for (let i = 0; i < 8; i++) {
      if (position >= bytes.length) throw new Error('Truncated CRX header');
      const byte = bytes[position++];
      n += (byte & 127) * scale;
      if (!Number.isSafeInteger(n)) throw new Error('Invalid CRX varint');
      if (!(byte & 128)) return n;
      scale *= 128;
    }
    throw new Error('Invalid CRX varint');
  }
  while (position < bytes.length) {
    if (++count > 256) throw new Error('Too many CRX header fields');
    const tag = integer(),
      number = Math.floor(tag / 8),
      wire = tag % 8;
    if (!number || number > 0x1fffffff) throw new Error('Invalid CRX header field');
    let value;
    if (wire === 2) {
      const size = integer();
      if (position + size > bytes.length) throw new Error('Truncated CRX header');
      value = bytes.subarray(position, position + size);
      position += size;
    } else if (wire === 0) {
      integer();
      continue;
    } else if (wire === 1 || wire === 5) {
      position += wire === 1 ? 8 : 4;
      if (position > bytes.length) throw new Error('Truncated CRX header');
      continue;
    } else throw new Error('Unsupported CRX wire type');
    const values = result.get(number) || [];
    values.push(value);
    result.set(number, values);
  }
  return result;
}
function singleton(map, number) {
  if (map.get(number)?.length !== 1) throw new Error('Missing or duplicate CRX header field');
  return map.get(number)[0];
}
function verifyCrx(buffer, { expectedId, requirePublisher = true } = {}) {
  if (
    !Buffer.isBuffer(buffer) ||
    buffer.length < 12 ||
    buffer.length > LIMITS.download ||
    buffer.toString('ascii', 0, 4) !== 'Cr24' ||
    buffer.readUInt32LE(4) !== 3
  )
    throw new Error('Invalid CRX3 package');
  if (!/^[a-p]{32}$/.test(expectedId)) throw new Error('Expected extension ID is required');
  const size = buffer.readUInt32LE(8);
  if (!size || size > LIMITS.header || 12 + size >= buffer.length) throw new Error('Invalid CRX header size');
  const raw = buffer.subarray(12, 12 + size),
    zip = buffer.subarray(12 + size);
  for (const hex of ['504b0506', '504b0607', '504b0606'])
    if (raw.includes(Buffer.from(hex, 'hex'))) throw new Error('Invalid CRX header ZIP token');
  const header = fields(raw),
    signed = singleton(header, 10000),
    idBytes = singleton(fields(signed), 1);
  if (idBytes.length !== 16) throw new Error('Invalid signed CRX ID');
  const id = [...idBytes.toString('hex')].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
  if (id !== expectedId) throw new Error('CRX identity does not match expected ID');
  const signedSize = Buffer.alloc(4);
  signedSize.writeUInt32LE(signed.length);
  let developer,
    publisher = false,
    proofCount = 0;
  for (const [number, type] of [
    [2, 'rsa'],
    [3, 'ec'],
  ])
    for (const proof of header.get(number) || []) {
      if (++proofCount > 32) throw new Error('Too many CRX proofs');
      const parsed = fields(proof),
        der = singleton(parsed, 1),
        signature = singleton(parsed, 2);
      let key;
      try {
        key = crypto.createPublicKey({ key: der, format: 'der', type: 'spki' });
      } catch {
        throw new Error('Invalid CRX proof key');
      }
      if (key.asymmetricKeyType !== type) throw new Error('CRX proof algorithm mismatch');
      const verifier = crypto.createVerify('sha256');
      verifier.update(Buffer.from('CRX3 SignedData\0'));
      verifier.update(signedSize);
      verifier.update(signed);
      verifier.update(zip);
      if (!verifier.verify({ key, padding: crypto.constants.RSA_PKCS1_PADDING }, signature))
        throw new Error('CRX signature verification failed');
      if (idFromKey(der) === id) developer = der;
      if (sha256(der) === PUBLISHER_SHA256) publisher = true;
    }
  if (!developer) throw new Error('Missing CRX developer identity proof');
  if (requirePublisher && !publisher) throw new Error('Missing production Web Store publisher proof');
  return {
    id,
    publicKey: developer.toString('base64'),
    zip,
    sha256: sha256(buffer),
    publisherVerified: publisher,
  };
}
function validatePath(name, seen) {
  if (
    !name ||
    name.length > 1024 ||
    name !== name.normalize('NFC') ||
    /[\\\x00-\x1f\x7f:]/.test(name) ||
    name.startsWith('/')
  )
    throw new Error('Unsafe archive path');
  const directory = name.endsWith('/'),
    parts = (directory ? name.slice(0, -1) : name).split('/');
  if (parts.length > LIMITS.depth) throw new Error('Archive path depth exceeded');
  for (const [index, part] of parts.entries()) {
    if (
      !part ||
      part === '.' ||
      part === '..' ||
      /[. ]$/.test(part) ||
      /[<>"|?*]/.test(part) ||
      /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part)
    )
      throw new Error('Unsafe or reserved archive path');
    const original = parts.slice(0, index + 1).join('/'),
      folded = original.toLowerCase();
    const isDirectory = index < parts.length - 1 || directory,
      previous = seen.get(folded);
    if (
      previous &&
      (previous.original !== original ||
        previous.directory !== isDirectory ||
        !isDirectory ||
        (index === parts.length - 1 && previous.explicit))
    )
      throw new Error('Duplicate or case-colliding archive path');
    seen.set(folded, {
      original,
      directory: isDirectory,
      explicit: previous?.explicit || index === parts.length - 1,
    });
  }
  return directory;
}
const CRC_TABLE = Uint32Array.from({ length: 256 }, (_, n) => {
  for (let i = 0; i < 8; i++) n = (n >>> 1) ^ (n & 1 ? 0xedb88320 : 0);
  return n >>> 0;
});
function crcUpdate(crc, bytes) {
  for (const byte of bytes) crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ byte) & 255];
  return crc;
}
async function extractArchive(buffer, destination, { signal } = {}) {
  signal?.throwIfAborted();
  if (!Buffer.isBuffer(buffer) || buffer.length > LIMITS.download)
    throw new Error('Archive download size exceeded');
  let archive,
    created = false;
  try {
    archive = await new Promise((resolve, reject) =>
      yauzl.fromBuffer(
        buffer,
        { lazyEntries: true, strictFileNames: true, validateEntrySizes: true, autoClose: false },
        (error, value) => (error ? reject(error) : resolve(value)),
      ),
    );
    if (archive.entryCount > LIMITS.entries) throw new Error('Archive entry count exceeded');
    const entries = [],
      seen = new Map(),
      ranges = [];
    let expanded = 0;
    await new Promise((resolve, reject) => {
      archive.on('error', reject);
      archive.on('end', resolve);
      archive.on('entry', (entry) => {
        try {
          signal?.throwIfAborted();
          const directory = validatePath(entry.fileName, seen),
            mode = (entry.externalFileAttributes >>> 16) & 0xf000;
          if (
            (mode && mode !== (directory ? 0x4000 : 0x8000)) ||
            entry.generalPurposeBitFlag & 1 ||
            ![0, 8].includes(entry.compressionMethod)
          )
            throw new Error('Unsupported archive entry type or encryption');
          expanded += entry.uncompressedSize;
          if (
            entry.uncompressedSize > LIMITS.file ||
            expanded > LIMITS.expanded ||
            (directory && entry.uncompressedSize)
          )
            throw new Error('Archive expanded size exceeded');
          if (
            entry.uncompressedSize > 1024 * 1024 &&
            entry.uncompressedSize / Math.max(1, entry.compressedSize) > 1000
          )
            throw new Error('Archive decompression bomb ratio');
          const offset = entry.relativeOffsetOfLocalHeader;
          if (offset + 30 > buffer.length || buffer.readUInt32LE(offset) !== 0x04034b50)
            throw new Error('Invalid archive local header');
          const nameLength = buffer.readUInt16LE(offset + 26),
            extraLength = buffer.readUInt16LE(offset + 28),
            start = offset + 30 + nameLength + extraLength,
            end = start + entry.compressedSize;
          if (
            end > buffer.length ||
            buffer.readUInt16LE(offset + 8) !== entry.compressionMethod ||
            buffer.readUInt16LE(offset + 6) !== entry.generalPurposeBitFlag ||
            !buffer.subarray(offset + 30, offset + 30 + nameLength).equals(Buffer.from(entry.fileName))
          )
            throw new Error('Inconsistent archive local header');
          if (
            !(entry.generalPurposeBitFlag & 8) &&
            (buffer.readUInt32LE(offset + 14) !== entry.crc32 ||
              buffer.readUInt32LE(offset + 18) !== entry.compressedSize ||
              buffer.readUInt32LE(offset + 22) !== entry.uncompressedSize)
          )
            throw new Error('Inconsistent archive local CRC or size header');
          ranges.push([offset, end]);
          entries.push({ entry, directory });
          archive.readEntry();
        } catch (error) {
          reject(error);
        }
      });
      archive.readEntry();
    });
    ranges.sort((a, b) => a[0] - b[0]);
    for (let i = 1; i < ranges.length; i++)
      if (ranges[i][0] < ranges[i - 1][1]) throw new Error('Overlapping archive entries');
    signal?.throwIfAborted();
    await fs.mkdir(destination);
    created = true;
    let actual = 0;
    for (const { entry, directory } of entries) {
      signal?.throwIfAborted();
      const target = path.join(destination, entry.fileName);
      if (directory) {
        await fs.mkdir(target, { recursive: true });
        continue;
      }
      await fs.mkdir(path.dirname(target), { recursive: true });
      const stream = await new Promise((resolve, reject) =>
        archive.openReadStream(entry, (error, value) => (error ? reject(error) : resolve(value))),
      );
      const handle = await fs.open(target, 'wx', 0o600);
      let length = 0,
        crc = 0xffffffff;
      const abort = () => stream.destroy(signal.reason);
      signal?.addEventListener('abort', abort, { once: true });
      try {
        for await (const chunk of stream) {
          signal?.throwIfAborted();
          length += chunk.length;
          actual += chunk.length;
          if (length > entry.uncompressedSize || length > LIMITS.file || actual > LIMITS.expanded)
            throw new Error('Actual archive expansion exceeded');
          crc = crcUpdate(crc, chunk);
          await handle.writeFile(chunk);
        }
        if (length !== entry.uncompressedSize || (crc ^ 0xffffffff) >>> 0 !== entry.crc32)
          throw new Error('Archive CRC or size mismatch');
      } finally {
        signal?.removeEventListener('abort', abort);
        stream.destroy();
        await handle.close();
      }
    }
    return { entries: entries.length, expandedBytes: actual };
  } catch (error) {
    if (created) await fs.rm(destination, { recursive: true, force: true });
    throw error;
  } finally {
    archive?.close();
  }
}
function distributionUrl(input) {
  const url = new URL(input);
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.port ||
    url.hash ||
    !DISTRIBUTION_HOSTS.includes(url.hostname)
  )
    throw new Error('Unsafe package distribution URL');
  return url;
}
async function fetchStorePackage(id, { signal, chromiumVersion, request = https.get } = {}) {
  id = parseStoreId(id);
  if (!/^\d+(?:\.\d+){3}$/.test(chromiumVersion || '')) throw new Error('Chromium version is required');
  const url = new URL('https://clients2.google.com/service/update2/crx');
  url.search = new URLSearchParams({
    response: 'redirect',
    prodversion: chromiumVersion,
    acceptformat: 'crx3',
    x: `id=${id}&installsource=ondemand&uc`,
  }).toString();
  const scopedSignal = signal
    ? AbortSignal.any([signal, AbortSignal.timeout(60000)])
    : AbortSignal.timeout(60000);
  let current = url;
  const redirects = [];
  for (let hop = 0; hop <= 4; hop++) {
    scopedSignal.throwIfAborted();
    current = distributionUrl(current);
    const response = await new Promise((resolve, reject) => {
      const req = request(
        current,
        { signal: scopedSignal, headers: { 'Accept-Encoding': 'identity' }, timeout: 15000 },
        resolve,
      );
      req.on('error', reject);
      req.on('timeout', () => req.destroy(new Error('Package download timeout')));
    });
    if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
      response.destroy();
      if (hop === 4 || !response.headers.location) throw new Error('Package redirect limit exceeded');
      current = distributionUrl(new URL(response.headers.location, current));
      redirects.push(current.href);
      continue;
    }
    if (response.statusCode !== 200) {
      response.destroy();
      throw new Error(`Store package unavailable (HTTP ${response.statusCode})`);
    }
    if (response.headers['content-encoding'] && response.headers['content-encoding'] !== 'identity') {
      response.destroy();
      throw new Error('Unsupported download encoding');
    }
    const declared = response.headers['content-length'];
    if (declared && (!/^\d+$/.test(declared) || Number(declared) > LIMITS.download)) {
      response.destroy();
      throw new Error('Package download size exceeded');
    }
    const chunks = [];
    let length = 0;
    for await (const chunk of response) {
      scopedSignal.throwIfAborted();
      length += chunk.length;
      if (length > LIMITS.download) {
        response.destroy();
        throw new Error('Package download size exceeded');
      }
      chunks.push(chunk);
    }
    if (declared && Number(declared) !== length) throw new Error('Incomplete package download');
    const buffer = Buffer.concat(chunks),
      verified = verifyCrx(buffer, { expectedId: id });
    return {
      ...verified,
      buffer,
      source: {
        kind: 'chrome-web-store',
        id,
        endpoint: url.href,
        finalUrl: current.href,
        redirects,
        publisherSha256: PUBLISHER_SHA256,
      },
    };
  }
  throw new Error('Package download failed');
}
module.exports = {
  parseStoreId,
  verifyCrx,
  extractArchive,
  fetchStorePackage,
  idFromKey,
  LIMITS,
  DISTRIBUTION_HOSTS,
};
