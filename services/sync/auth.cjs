'use strict';
const { scrypt, randomBytes, timingSafeEqual } = require('node:crypto');
const { promisify } = require('node:util');
const derive = promisify(scrypt);
const parameters = Object.freeze({ N: 131072, r: 8, p: 1, maxmem: 256 * 1024 * 1024 });

function failure(status, code, message) {
  return Object.assign(new Error(message), { status, code });
}
function passwordValue(value) {
  if (
    typeof value !== 'string' ||
    [...value].length < 12 ||
    [...value].length > 256 ||
    Buffer.byteLength(value) > 1024
  )
    throw failure(400, 'invalid_password', 'Use a password of 12–256 characters.');
  return value;
}
function usernameValue(value) {
  if (typeof value !== 'string' || !/^[a-z0-9][a-z0-9_.-]{2,63}$/.test(value))
    throw failure(
      400,
      'invalid_username',
      'Use 3–64 lowercase letters, numbers, periods, hyphens or underscores, starting with a letter or number.',
    );
  return value;
}
function label(value, max = 80) {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    [...value].length > max ||
    /[\u0000-\u001f\u007f]/.test(value)
  )
    throw failure(400, 'invalid_name', 'Enter a valid name.');
  return value.trim();
}

class Authentication {
  constructor() {
    this.active = 0;
    this.queue = [];
    this.rates = new Map();
    this.dummy = JSON.stringify({
      v: 1,
      salt: randomBytes(16).toString('base64'),
      hash: randomBytes(32).toString('base64'),
    });
  }
  rate(key, limit, milliseconds) {
    const now = Date.now();
    for (const [name, state] of this.rates) if (state.until <= now) this.rates.delete(name);
    let state = this.rates.get(key);
    if (!state) {
      if (this.rates.size >= 10000) throw failure(429, 'rate_limited', 'Try again later.');
      state = { count: 0, until: now + milliseconds };
      this.rates.set(key, state);
    }
    if (++state.count > limit) throw failure(429, 'rate_limited', 'Try again later.');
  }
  async bounded(work) {
    if (this.active >= 2) {
      if (this.queue.length >= 8) throw failure(429, 'busy', 'Authentication is busy. Try again later.');
      await new Promise((resolve) => this.queue.push(resolve));
    } else this.active++;
    try {
      return await work();
    } finally {
      const next = this.queue.shift();
      if (next) next();
      else this.active--;
    }
  }
  async hash(password) {
    passwordValue(password);
    return this.bounded(async () => {
      const salt = randomBytes(16);
      const hash = await derive(password, salt, 32, parameters);
      return JSON.stringify({ v: 1, salt: salt.toString('base64'), hash: hash.toString('base64') });
    });
  }
  async verify(password, encoded) {
    passwordValue(password);
    return this.bounded(async () => {
      const saved = JSON.parse(encoded || this.dummy);
      if (saved.v !== 1) throw new Error('Unsupported password hash version');
      const hash = await derive(password, Buffer.from(saved.salt, 'base64'), 32, parameters);
      const expected = Buffer.from(saved.hash, 'base64');
      return expected.length === hash.length && timingSafeEqual(hash, expected);
    });
  }
}
module.exports = { Authentication, failure, passwordValue, usernameValue, label };
