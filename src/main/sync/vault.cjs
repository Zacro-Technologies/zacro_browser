'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
class CredentialVault {
  constructor({ directory, protect, unprotect }) {
    this.filename = path.join(directory, 'credentials.protected');
    this.protect = protect;
    this.unprotect = unprotect;
  }
  assertAvailable() {
    try {
      if (typeof this.protect !== 'function' || typeof this.unprotect !== 'function') throw new Error();
      const challenge = randomUUID();
      if (this.unprotect(this.protect(challenge)) !== challenge) throw new Error();
    } catch {
      throw new Error('OS credential protection is unavailable. Sign-in is disabled.');
    }
  }
  load() {
    if (!fs.existsSync(this.filename)) return null;
    this.assertAvailable();
    try {
      const data = JSON.parse(this.unprotect(fs.readFileSync(this.filename)));
      if (
        data.version !== 1 ||
        !data.endpoint ||
        !data.account?.id ||
        !data.device?.id ||
        typeof data.accessToken !== 'string' ||
        typeof data.refreshToken !== 'string'
      )
        throw new Error();
      return data;
    } catch {
      throw new Error('Protected credentials cannot be read. Sign in again.');
    }
  }
  save(data) {
    this.assertAvailable();
    const protectedBytes = this.protect(JSON.stringify({ ...data, version: 1 }));
    if (!Buffer.isBuffer(protectedBytes)) throw new Error('OS credential protection failed.');
    const temporary = this.filename + '.' + randomUUID();
    let fd;
    try {
      fd = fs.openSync(temporary, 'wx', 0o600);
      fs.writeFileSync(fd, protectedBytes);
      fs.fsyncSync(fd);
      fs.closeSync(fd);
      fd = undefined;
      fs.renameSync(temporary, this.filename);
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
      fs.rmSync(temporary, { force: true });
    }
  }
  clear() {
    fs.rmSync(this.filename, { force: true });
  }
}
module.exports = { CredentialVault };
