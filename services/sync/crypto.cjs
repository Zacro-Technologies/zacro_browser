'use strict';
const { randomBytes, createCipheriv, createDecipheriv, createHash } = require('node:crypto');

function seal(key, value, context) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from(context));
  const encrypted = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([1]), nonce, cipher.getAuthTag(), encrypted]);
}
function open(key, value, context) {
  try {
    const bytes = Buffer.from(value);
    if (bytes.length < 30 || bytes[0] !== 1) throw new Error('Invalid encrypted value');
    const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(1, 13));
    decipher.setAAD(Buffer.from(context));
    decipher.setAuthTag(bytes.subarray(13, 29));
    return JSON.parse(
      Buffer.concat([decipher.update(bytes.subarray(29)), decipher.final()]).toString('utf8'),
    );
  } catch (cause) {
    throw Object.assign(new Error('Stored data authentication failed', { cause }), {
      code: 'data_integrity',
    });
  }
}
const digest = (value) => createHash('sha256').update(value).digest('hex');
const token = () => randomBytes(32).toString('base64url');
module.exports = { seal, open, digest, token };
