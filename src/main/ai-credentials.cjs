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
  constructor({ userDataPath, safeStorage, platform = process.platform, storageTimeoutMs = 20000 }) {
    this.file = path.join(userDataPath, 'ai-provider-credentials.enc.json');
    this.safeStorage = safeStorage;
    this.platform = platform;
    this.storageTimeoutMs = storageTimeoutMs;
    // Reading browser state must never initialize or prompt the OS key store.
    // Electron's Linux async API can fall back to an unprotected POSIX key and
    // does not expose its selected provider. The sync backend name cannot prove
    // that async encryption is secure, so durable storage fails closed there.
    this.storageAvailable = ['win32', 'darwin'].includes(platform) ? null : false;
    this.closed = false;
    this.closing = new AbortController();
    this.revisions = new Map();
    this.mutations = Promise.resolve();
    this.saved = Object.create(null);
    this.session = new Map();
    this.ready = this.load();
  }

  operation(id, replace = false) {
    if (replace) this.revisions.set(id, (this.revisions.get(id) || 0) + 1);
    const revision = this.revisions.get(id) || 0;
    return {
      deadline: Date.now() + this.storageTimeoutMs,
      current: () => !this.closed && (this.revisions.get(id) || 0) === revision,
    };
  }

  assertCurrent(operation) {
    if (!operation.current())
      throw new CredentialError('The provider connection changed. Retry the credential operation.');
    if (operation.deadline !== undefined && Date.now() > operation.deadline) throw this.storageTimeout();
  }

  async storageCall(operation, call) {
    this.assertCurrent(operation);
    const remaining = operation.deadline - Date.now();
    if (remaining <= 0) throw this.storageTimeout();
    let timer, onClose;
    try {
      const result = await Promise.race([
        Promise.resolve().then(call),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(this.storageTimeout()), remaining);
          onClose = () => reject(new CredentialError('The credential store has closed.'));
          this.closing.signal.addEventListener('abort', onClose, { once: true });
        }),
      ]);
      this.assertCurrent(operation);
      return result;
    } finally {
      clearTimeout(timer);
      this.closing.signal.removeEventListener('abort', onClose);
    }
  }

  storageTimeout() {
    this.storageAvailable = null;
    return new CredentialError(
      'The operating system credential store did not respond in time. Unlock it and try again, or explicitly choose this session only.',
    );
  }

  async requireEncryption(operation) {
    if (!['win32', 'darwin'].includes(this.platform))
      throw new CredentialError(
        'Secure persistent API key storage is supported on Windows and macOS. Choose “This session only” explicitly on this platform.',
      );
    const storage = this.safeStorage;
    if (
      !['isAsyncEncryptionAvailable', 'encryptStringAsync', 'decryptStringAsync'].every(
        (name) => typeof storage?.[name] === 'function',
      )
    ) {
      this.storageAvailable = false;
      throw new CredentialError(
        'Secure asynchronous storage is unavailable. Choose “This session only” explicitly.',
      );
    }
    let available;
    try {
      available = await this.storageCall(operation, () => storage.isAsyncEncryptionAvailable());
    } catch (error) {
      if (error instanceof CredentialError) throw error;
      this.storageAvailable = null;
      throw new CredentialError(
        'The operating system credential store could not be opened. Unlock it and try again.',
      );
    }
    this.storageAvailable = available === true;
    if (!this.storageAvailable)
      throw new CredentialError(
        'Secure operating system storage is unavailable. Choose “This session only” explicitly to use this API key without saving it.',
      );
  }

  mutate(callback) {
    const result = this.mutations.then(callback);
    this.mutations = result.catch(() => {});
    return result;
  }

  async encrypt(operation, plain) {
    const encrypted = await this.storageCall(operation, () => this.safeStorage.encryptStringAsync(plain));
    if (!Buffer.isBuffer(encrypted) || !encrypted.length) throw new Error('Invalid encrypted result');
    return encrypted.toString('base64');
  }

  async load() {
    try {
      const stat = await fs.stat(this.file);
      if (stat.size > 256 * 1024) throw new Error('size');
      const data = JSON.parse(await fs.readFile(this.file, 'utf8'));
      if (data.version !== 1 || !data.records || typeof data.records !== 'object') throw new Error('format');
      if (this.closed) return;
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
      storageAvailable: this.storageAvailable,
      ...(!['win32', 'darwin'].includes(this.platform)
        ? {
            storageNotice:
              'Persistent API key storage is supported on Windows and macOS; choose session-only storage on this platform.',
          }
        : {}),
    };
  }

  async get(id) {
    await this.ready;
    if (this.session.has(id)) return this.session.get(id);
    if (!this.saved[id]) return '';
    const operation = this.operation(id);
    this.assertCurrent(operation);
    const original = this.saved[id];
    await this.requireEncryption(operation);
    try {
      const decrypted = await this.storageCall(operation, () =>
        this.safeStorage.decryptStringAsync(Buffer.from(original, 'base64')),
      );
      if (typeof decrypted?.result !== 'string' || typeof decrypted.shouldReEncrypt !== 'boolean')
        throw new Error('Invalid decrypted result');
      const data = JSON.parse(decrypted.result);
      if (data.id !== id || typeof data.key !== 'string') throw new Error('binding');
      if (decrypted.shouldReEncrypt) {
        const encoded = await this.encrypt(operation, decrypted.result);
        await this.mutate(async () => {
          this.assertCurrent(operation);
          if (this.saved[id] !== original)
            throw new CredentialError('The saved credential changed. Retry the request.');
          const records = { ...this.saved, [id]: encoded };
          await this.persist(records, operation);
          this.assertCurrent(operation);
          this.saved = records;
        });
      }
      this.assertCurrent(operation);
      return data.key;
    } catch (error) {
      if (error instanceof CredentialError) throw error;
      throw new CredentialError(
        'The saved API key could not be decrypted. Unlock the operating system credential store or replace this provider’s key.',
      );
    }
  }

  async persist(records, operation) {
    this.assertCurrent(operation);
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
      this.assertCurrent(operation);
      await fs.writeFile(temporary, serialized, { flag: 'wx', mode: 0o600 });
      this.assertCurrent(operation);
      await fs.rename(temporary, this.file);
    } catch (error) {
      if (error instanceof CredentialError) throw error;
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
    const operation = this.operation(id, true);
    this.assertCurrent(operation);
    if (storage === 'session') {
      await this.mutate(async () => {
        this.assertCurrent(operation);
        // Remove an older durable key when the user explicitly chooses session-only.
        if (this.saved[id]) {
          const records = { ...this.saved };
          delete records[id];
          await this.persist(records, operation);
          this.assertCurrent(operation);
          this.saved = records;
        }
        this.assertCurrent(operation);
        this.session.set(id, key);
      });
      return;
    }
    await this.requireEncryption(operation);
    let encoded;
    try {
      const plain = JSON.stringify({ id, key });
      encoded = await this.encrypt(operation, plain);
    } catch (error) {
      if (error instanceof CredentialError) throw error;
      throw new CredentialError(
        'The operating system could not encrypt the API key. No plaintext key was saved.',
      );
    }
    await this.mutate(async () => {
      this.assertCurrent(operation);
      const records = { ...this.saved, [id]: encoded };
      await this.persist(records, operation);
      this.assertCurrent(operation);
      this.saved = records;
      this.session.delete(id);
    });
  }

  async remove(id) {
    await this.ready;
    const operation = this.operation(id, true);
    await this.mutate(async () => {
      this.assertCurrent(operation);
      if (this.saved[id]) {
        const records = { ...this.saved };
        delete records[id];
        await this.persist(records, operation);
        this.assertCurrent(operation);
        this.saved = records;
      }
      this.session.delete(id);
    });
  }

  async forgetProfile(profileId) {
    await this.ready;
    const prefix = profilePrefix(profileId);
    for (const id of new Set([...this.revisions.keys(), ...Object.keys(this.saved), ...this.session.keys()]))
      if (id.startsWith(prefix)) this.operation(id, true);
    const operation = { current: () => !this.closed };
    await this.mutate(async () => {
      this.assertCurrent(operation);
      const records = Object.fromEntries(Object.entries(this.saved).filter(([id]) => !id.startsWith(prefix)));
      if (Object.keys(records).length !== Object.keys(this.saved).length) {
        await this.persist(records, operation);
        this.assertCurrent(operation);
        this.saved = records;
      }
      for (const id of this.session.keys()) if (id.startsWith(prefix)) this.session.delete(id);
    });
  }

  close() {
    this.closed = true;
    this.closing.abort();
    this.session.clear();
  }
}

module.exports = { CredentialVault, CredentialError, credentialId };
