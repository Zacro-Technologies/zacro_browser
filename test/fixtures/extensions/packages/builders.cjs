'use strict';
// Synthetic fixtures only. No store keys or third-party extension source.
const crypto = require('node:crypto');
const zlib = require('node:zlib');
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let n = 0; n < 8; n++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function zip(entries) {
  const locals = [],
    central = [];
  let offset = 0;
  for (const item of entries) {
    const name = Buffer.from(item.name),
      data = Buffer.from(item.data || '');
    const compressed = item.deflate ? zlib.deflateRawSync(data) : data;
    const crc = item.crc ?? crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(item.deflate ? 8 : 0, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(item.size ?? data.length, 22);
    local.writeUInt16LE(name.length, 26);
    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(0x0314, 4);
    cd.writeUInt16LE(20, 6);
    cd.writeUInt16LE(0x800, 8);
    cd.writeUInt16LE(item.deflate ? 8 : 0, 10);
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(compressed.length, 20);
    cd.writeUInt32LE(item.size ?? data.length, 24);
    cd.writeUInt16LE(name.length, 28);
    cd.writeUInt32LE(((item.mode ?? (item.name.endsWith('/') ? 0o40755 : 0o100644)) << 16) >>> 0, 38);
    cd.writeUInt32LE(offset, 42);
    locals.push(local, name, compressed);
    central.push(cd, name);
    offset += local.length + name.length + compressed.length;
  }
  const directory = Buffer.concat(central),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
function varint(value) {
  const out = [];
  do {
    out.push((value & 127) | (value > 127 ? 128 : 0));
    value = Math.floor(value / 128);
  } while (value);
  return Buffer.from(out);
}
function field(number, data) {
  return Buffer.concat([varint(number * 8 + 2), varint(data.length), data]);
}
function keyPair(type = 'rsa') {
  return crypto.generateKeyPairSync(
    type,
    type === 'rsa' ? { modulusLength: 2048 } : { namedCurve: 'prime256v1' },
  );
}
function crx(
  archive,
  { keys = [keyPair()], declaredId, additionalHeader = Buffer.alloc(0), signedHeader } = {},
) {
  const der = keys[0].publicKey.export({ format: 'der', type: 'spki' });
  const idBytes = declaredId || crypto.createHash('sha256').update(der).digest().subarray(0, 16);
  const signed = signedHeader || field(1, idBytes),
    size = Buffer.alloc(4);
  size.writeUInt32LE(signed.length);
  const payload = Buffer.concat([Buffer.from('CRX3 SignedData\0'), size, signed, archive]);
  const proofs = keys.map((key) =>
    field(
      key.publicKey.asymmetricKeyType === 'rsa' ? 2 : 3,
      Buffer.concat([
        field(1, key.publicKey.export({ format: 'der', type: 'spki' })),
        field(2, crypto.sign('sha256', payload, key.privateKey)),
      ]),
    ),
  );
  const header = Buffer.concat([...proofs, field(10000, signed), additionalHeader]);
  const prefix = Buffer.alloc(12);
  prefix.write('Cr24');
  prefix.writeUInt32LE(3, 4);
  prefix.writeUInt32LE(header.length, 8);
  const id = [...idBytes.toString('hex')].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
  return { buffer: Buffer.concat([prefix, header, archive]), id, publicKey: der.toString('base64') };
}
module.exports = { zip, crx, keyPair, field, crc32 };
