'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');

class CredentialError extends Error {
  constructor(message, code = 'AUTH_STORAGE') {
    super(message);
    this.code = code;
  }
}

// Credentials belong to one browser profile, one provider and one exact endpoint.
// A base URL edit can never forward an existing key to a different server.
function credentialId(profileId, provider, endpoint) {
  return (
    profilePrefix(profileId) +
    createHash('sha256')
      .update(JSON.stringify([provider, endpoint]))
      .digest('hex')
  );
}

function profilePrefix(profileId) {
  return createHash('sha256').update(String(profileId)).digest('hex') + ':';
}

class CredentialVault {
  constructor({ userDataPath, safeStorage }) {
    this.file = path.join(userDataPath, 'ai-provider-credentials.enc.json');
    this.safeStorage = safeStorage;
    this.saved = Object.create(null);
    this.session = new Map();
    this.ready = this.load();
  }

  available() {
    try {
      return Boolean(
        this.safeStorage?.isEncryptionAvailable() &&
        this.safeStorage.getSelectedStorageBackend?.() !== 'basic_text',
      );
    } catch {
      return false;
    }
  }

  async load() {
    try {
      const stat = await fs.stat(this.file);
      if (stat.size > 256 * 1024) throw new Error('size');
      const data = JSON.parse(await fs.readFile(this.file, 'utf8'));
      if (data.version !== 1 || !data.records || typeof data.records !== 'object') throw new Error('format');
      for (const [id, value] of Object.entries(data.records)) {
        if (/^[a-f0-9]{64}:[a-f0-9]{64}$/.test(id) && typeof value === 'string' && value.length < 24000)
          this.saved[id] = value;
      }
    } catch (error) {
      if (error.code !== 'ENOENT') this.loadError = true;
    }
  }

  status(id) {
    return {
      configured: this.session.has(id) || Boolean(this.saved[id]),
      credentialStorage: this.session.has(id) ? 'session' : this.saved[id] ? 'encrypted' : 'none',
      storageAvailable: this.available(),
    };
  }

  async get(id) {
    await this.ready;
    if (this.session.has(id)) return this.session.get(id);
    if (!this.saved[id]) return '';
    if (!this.available())
      throw new CredentialError(
        'Unlock your operating system credential store, or save a key explicitly for this session only.',
      );
    try {
      const encrypted = Buffer.from(this.saved[id], 'base64');
      const plain = this.safeStorage.decryptStringAsync
        ? await this.safeStorage.decryptStringAsync(encrypted)
        : this.safeStorage.decryptString(encrypted);
      const data = JSON.parse(plain);
      if (data.id !== id || typeof data.key !== 'string') throw new Error('binding');
      return data.key;
    } catch {
      throw new CredentialError(
        'The saved API key could not be decrypted. Unlock the operating system credential store or replace this provider’s key.',
      );
    }
  }

  async persist(records) {
    if (this.loadError)
      throw new CredentialError(
        'The encrypted credential file is unreadable. Existing credentials were preserved; use session-only storage or restore the file.',
      );
    const serialized = JSON.stringify({ version: 1, records });
    if (Buffer.byteLength(serialized) > 256 * 1024)
      throw new CredentialError(
        'The encrypted credential store is full. Remove unused provider connections or choose session-only storage.',
      );
    await fs.mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const temporary = `${this.file}.${randomUUID()}.tmp`;
    try {
      await fs.writeFile(temporary, serialized, { flag: 'wx', mode: 0o600 });
      await fs.rename(temporary, this.file);
    } catch {
      throw new CredentialError(
        'The encrypted API key could not be saved. Check available disk space and folder permissions.',
      );
    } finally {
      await fs.rm(temporary, { force: true }).catch(() => {});
    }
  }

  async set(id, key, storage) {
    await this.ready;
    if (typeof key !== 'string' || !key || key.length > 8192 || /[\x00-\x20\x7f]/.test(key))
      throw new CredentialError('Enter an API key without spaces or control characters.', 'INPUT');
    if (!['encrypted', 'session'].includes(storage))
      throw new CredentialError('Choose encrypted storage or this session only.', 'INPUT');
    if (storage === 'session') {
      // Remove an older durable key when the user explicitly chooses session-only.
      if (this.saved[id]) {
        const records = { ...this.saved };
        delete records[id];
        await this.persist(records);
        this.saved = records;
      }
      this.session.set(id, key);
      return;
    }
    if (!this.available())
      throw new CredentialError(
        'Secure operating system storage is unavailable. Choose “This session only” explicitly to use this API key without saving it.',
      );
    let encoded;
    try {
      const plain = JSON.stringify({ id, key });
      const encrypted = this.safeStorage.encryptStringAsync
        ? await this.safeStorage.encryptStringAsync(plain)
        : this.safeStorage.encryptString(plain);
      encoded = encrypted.toString('base64');
    } catch {
      throw new CredentialError(
        'The operating system could not encrypt the API key. No plaintext key was saved.',
      );
    }
    const records = { ...this.saved, [id]: encoded };
    await this.persist(records);
    this.saved = records;
    this.session.delete(id);
  }

  async remove(id) {
    await this.ready;
    if (this.saved[id]) {
      const records = { ...this.saved };
      delete records[id];
      await this.persist(records);
      this.saved = records;
    }
    this.session.delete(id);
  }

  async forgetProfile(profileId) {
    await this.ready;
    const prefix = profilePrefix(profileId);
    const records = Object.fromEntries(Object.entries(this.saved).filter(([id]) => !id.startsWith(prefix)));
    if (Object.keys(records).length !== Object.keys(this.saved).length) {
      await this.persist(records);
      this.saved = records;
    }
    for (const id of this.session.keys()) if (id.startsWith(prefix)) this.session.delete(id);
  }

  close() {
    this.session.clear();
  }
}

module.exports = { CredentialVault, CredentialError, credentialId };
