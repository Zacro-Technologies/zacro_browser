'use strict';
const fs = require('node:fs/promises');
const sync = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { parseStoreId, fetchStorePackage, extractArchive, idFromKey, LIMITS } = require('./packages.cjs');
const { inspectManifest, compareVersions, requiresReview } = require('./catalog.cjs');
const { adaptExtension } = require('./adapt.cjs');
const SIX_HOURS = 6 * 60 * 60 * 1000;
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const clone = (value) => structuredClone(value);
const reducedGrants = (before, after) =>
  before.permissions.some((value) => !after.permissions.includes(value)) ||
  before.origins.some((value) => !after.origins.includes(value));
const pendingPermissionReload = (record, grants) =>
  !!(record.permissionReloadPending || (record.requiresPageReload && reducedGrants(record.grants, grants)));
async function readManifest(directory) {
  const buffer = await fs.readFile(path.join(directory, 'manifest.json'));
  if (buffer.length > 1024 * 1024) throw new Error('Extension manifest is too large');
  const manifest = JSON.parse(buffer.toString('utf8'));
  inspectManifest(manifest);
  return manifest;
}
async function treeHash(directory, signal) {
  const digest = crypto.createHash('sha256');
  async function visit(relative) {
    signal?.throwIfAborted();
    const names = (await fs.readdir(path.join(directory, relative))).sort();
    for (const name of names) {
      const child = path.join(relative, name),
        absolute = path.join(directory, child),
        stat = await fs.lstat(absolute);
      if (stat.isDirectory()) await visit(child);
      else if (stat.isFile()) {
        digest.update(child.split(path.sep).join('/') + '\0');
        digest.update(String(stat.size) + '\0');
        digest.update(await fs.readFile(absolute));
      } else throw new Error('Unsupported managed package entry');
    }
  }
  await visit('');
  return digest.digest('hex');
}
async function copyLocal(source, destination, signal) {
  let entries = 0,
    bytes = 0;
  const folded = new Set();
  async function visit(from, to, depth) {
    signal?.throwIfAborted();
    const stat = await fs.lstat(from);
    if (++entries > LIMITS.entries || depth > LIMITS.depth)
      throw new Error('Local extension entry or depth limit');
    if (stat.isDirectory()) {
      await fs.mkdir(to);
      for (const name of await fs.readdir(from)) {
        if (
          name !== name.normalize('NFC') ||
          /[\\\x00-\x1f\x7f:<>"|?*]/.test(name) ||
          /[. ]$/.test(name) ||
          /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)
        )
          throw new Error('Unsafe local extension filename');
        const key = path.relative(destination, path.join(to, name)).toLowerCase();
        if (folded.has(key)) throw new Error('Case-colliding local extension path');
        folded.add(key);
        await visit(path.join(from, name), path.join(to, name), depth + 1);
      }
    } else if (stat.isFile()) {
      bytes += stat.size;
      if (stat.size > LIMITS.file || bytes > LIMITS.expanded) throw new Error('Local extension size limit');
      const handle = await fs.open(from, sync.constants.O_RDONLY | sync.constants.O_NOFOLLOW);
      try {
        const data = await handle.readFile();
        if (data.length !== stat.size) throw new Error('Local extension changed during copy');
        await fs.writeFile(to, data, { flag: 'wx', mode: 0o600 });
      } finally {
        await handle.close();
      }
    } else throw new Error('Local extensions cannot contain symbolic links or special files');
  }
  await visit(source, destination, 0);
}
function atomicJson(filename, value) {
  const temporary = filename + '.' + crypto.randomUUID() + '.tmp';
  try {
    const fd = sync.openSync(temporary, 'wx', 0o600);
    try {
      sync.writeFileSync(fd, JSON.stringify(value, null, 2) + '\n');
      sync.fsyncSync(fd);
    } finally {
      sync.closeSync(fd);
    }
    sync.renameSync(temporary, filename);
    // Directory fsync is supported on POSIX, but not by all Windows filesystems.
    if (process.platform !== 'win32') {
      const dir = sync.openSync(path.dirname(filename), 'r');
      try {
        sync.fsyncSync(dir);
      } finally {
        sync.closeSync(dir);
      }
    }
  } finally {
    sync.rmSync(temporary, { force: true });
  }
}
class ExtensionManager {
  constructor({
    root,
    getProfile,
    getSession,
    prepareSession = () => {},
    confirmPermissions,
    fetchPackage = fetchStorePackage,
    chromiumVersion = process.versions.chrome,
    now = Date.now,
    random = Math.random,
    onChange = () => {},
    onDeactivated = async () => ({ requiresPageReload: true }),
  }) {
    if (
      !root ||
      typeof getProfile !== 'function' ||
      typeof getSession !== 'function' ||
      typeof confirmPermissions !== 'function'
    )
      throw new Error(
        'Extension manager requires root, profile/session resolvers and permission confirmation',
      );
    Object.assign(this, {
      root: path.resolve(root),
      getProfile,
      getSession,
      prepareSession,
      confirmPermissions,
      fetchPackage,
      chromiumVersion,
      now,
      random,
      onChange,
      onDeactivated,
    });
    this.states = new Map();
    this.preparedSessions = new WeakMap();
    this.epochs = new Map();
    this.operations = new Map();
    this.queues = new Map();
    this.runtime = new Map();
    this.timers = new Map();
    this.restored = new Set();
    this.localEpochs = new Map();
    this.closed = false;
  }
  profilePath(profileId) {
    if (typeof profileId !== 'string' || !profileId || profileId.length > 256)
      throw new Error('Invalid profile ID');
    return path.join(this.root, 'profiles', hash(profileId));
  }
  versionPath(profileId, version, relative = 'derived') {
    if (!/^[0-9a-f-]{36}$/.test(version?.token)) throw new Error('Invalid managed version');
    if (
      typeof relative !== 'string' ||
      path.isAbsolute(relative) ||
      relative.split(/[\\/]/).some((part) => !part || part === '..' || part === '.') ||
      relative.includes(':')
    )
      throw new Error('Invalid version path');
    return path.join(this.profilePath(profileId), 'versions', version.token, relative);
  }
  _profile(profileId) {
    if (this.closed) throw new Error('Extension manager is closed');
    const profile = this.getProfile(profileId);
    if (!profile || profile.id !== profileId) throw new Error('Extension profile no longer exists');
    if (profile.private) throw new Error('Extensions are unavailable in private profiles');
    return profile;
  }
  _key(profileId, id) {
    return JSON.stringify([profileId, id]);
  }
  _context(profileId, id) {
    this._profile(profileId);
    if (!this.states.has(profileId)) throw new Error('Restore the profile before extension operations');
    const key = this._key(profileId, id);
    this.operations.get(key)?.controller.abort(new Error('Stale extension operation cancelled'));
    const context = {
      profileId,
      id,
      key,
      epoch: this.epochs.get(profileId),
      generation: crypto.randomUUID(),
      controller: new AbortController(),
    };
    context.signal = context.controller.signal;
    this.operations.set(key, context);
    return context;
  }
  _guard(context) {
    context.signal.throwIfAborted();
    this._profile(context.profileId);
    if (this.epochs.get(context.profileId) !== context.epoch || this.operations.get(context.key) !== context)
      throw new Error('Stale extension lifecycle');
  }
  _run(profileId, id, work, immediate) {
    let context;
    try {
      context = this._context(profileId, id);
    } catch (error) {
      return Promise.reject(error);
    }
    try {
      immediate?.(context);
    } catch (error) {
      if (this.operations.get(context.key) === context) this.operations.delete(context.key);
      return Promise.reject(error);
    }
    const previous = this.queues.get(context.key) || Promise.resolve();
    const promise = previous
      .catch(() => {})
      .then(() => {
        this._guard(context);
        return work(context);
      });
    this.queues.set(context.key, promise);
    return promise.finally(() => {
      if (this.queues.get(context.key) === promise) this.queues.delete(context.key);
      if (this.operations.get(context.key) === context) this.operations.delete(context.key);
    });
  }
  _persist(profileId, change, context) {
    if (context) this._guard(context);
    const state = clone(this.states.get(profileId));
    change(state);
    atomicJson(path.join(this.profilePath(profileId), 'state.json'), state);
    this.states.set(profileId, state);
    try {
      this.onChange(profileId, this.list(profileId));
    } catch {
      /* Notifications cannot roll back a committed state. */
    }
  }
  _record(profileId, id) {
    const record = this.states.get(profileId)?.extensions.find((item) => item.id === id);
    if (!record) throw new Error('Extension not found in profile');
    return clone(record);
  }
  _save(context, record) {
    this._persist(
      context.profileId,
      (state) => {
        state.extensions = state.extensions.filter((item) => item.id !== record.id);
        state.extensions.push(record);
      },
      context,
    );
    return clone(record);
  }
  list(profileId) {
    return clone(this.states.get(profileId)?.extensions || []);
  }
  schedule(profileId) {
    return clone(this.states.get(profileId)?.schedule || { nextCheck: 0, failures: 0, lastCheck: null });
  }
  resolveExtension(profileId, id) {
    if (this.closed || !this.getProfile(profileId) || this.getProfile(profileId).private) return null;
    const value = this.runtime.get(this._key(profileId, id));
    return value ? clone(value) : null;
  }
  async restore(profileId, { legacy = [] } = {}) {
    this._profile(profileId);
    if (this.restored.has(profileId)) return this.list(profileId);
    const directory = this.profilePath(profileId),
      epoch = crypto.randomUUID();
    this.epochs.set(profileId, epoch);
    const guard = () => {
      this._profile(profileId);
      if (this.epochs.get(profileId) !== epoch) throw new Error('Stale profile restore');
    };
    await fs.mkdir(path.join(directory, 'versions'), { recursive: true });
    guard();
    await fs.mkdir(path.join(directory, 'staging'), { recursive: true });
    guard();
    let state;
    try {
      const bytes = await fs.readFile(path.join(directory, 'state.json'));
      if (bytes.length > 16 * 1024 * 1024) throw new Error('Extension state is too large');
      state = JSON.parse(bytes);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      state = {
        schema: 1,
        profileId,
        extensions: [],
        schedule: { nextCheck: 0, failures: 0, lastCheck: null },
      };
    }
    guard();
    if (state.schema !== 1 || state.profileId !== profileId || !Array.isArray(state.extensions))
      throw new Error('Invalid extension state');
    const ids = new Set();
    for (const record of state.extensions) {
      if (!/^[a-p]{32}$/.test(record.id) || record.profileId !== profileId || ids.has(record.id))
        throw new Error('Invalid persisted extension identity');
      ids.add(record.id);
      for (const version of [record.current, record.pending, record.previous].filter(Boolean))
        this.versionPath(profileId, version);
    }
    this.states.set(profileId, state);
    for (const entry of legacy) {
      if (entry.profileId !== profileId || !entry.extensionId || ids.has(entry.extensionId)) continue;
      await this._importLegacy(profileId, entry);
      guard();
      ids.add(entry.extensionId);
    }
    await this._cleanup(profileId);
    guard();
    await this._prepareSession(profileId);
    guard();
    for (const record of this.list(profileId))
      if (record.enabled && record.current) {
        try {
          await this._run(profileId, record.id, async (context) => {
            await this._checkVersion(context, record.current);
            await this._nativeLoad(context, record, record.current, record.grants);
            this._guard(context);
          });
        } catch (error) {
          guard();
          this.runtime.delete(this._key(profileId, record.id));
          this._persist(profileId, (value) => {
            const failed = value.extensions.find((item) => item.id === record.id);
            if (failed) {
              failed.enabled = false;
              failed.status = 'load-failed';
              failed.error = String(error.message).slice(0, 500);
            }
          });
        }
      }
    guard();
    this._persist(profileId, () => {});
    this.restored.add(profileId);
    return this.list(profileId);
  }
  async _importLegacy(profileId, entry) {
    if (
      !/^[a-p]{32}$/.test(entry.extensionId) ||
      typeof entry.path !== 'string' ||
      !path.isAbsolute(entry.path) ||
      !path.resolve(entry.path).startsWith(this.root + path.sep)
    )
      throw new Error('Invalid legacy extension identity or path outside managed root');
    return this._run(profileId, entry.extensionId, async (context) => {
      await this._checkLegacyPath(entry.path);
      const manifest = await readManifest(entry.path),
        inspection = inspectManifest(manifest);
      this._guard(context);
      if (manifest.key && idFromKey(Buffer.from(manifest.key, 'base64')) !== entry.extensionId)
        throw new Error('Legacy public key does not match original native ID');
      // Keyless Electron extensions derive their ID from their exact native path.
      // Retain that path and label the old unadapted context, never forge a key.
      const token = crypto.randomUUID(),
        directory = path.join(this.profilePath(profileId), 'versions', token);
      await fs.mkdir(directory);
      try {
        await copyLocal(entry.path, path.join(directory, 'original'), context.signal);
        this._guard(context);
        const digest = await treeHash(path.join(directory, 'original'), context.signal);
        const source = { kind: 'local-unpacked', portable: false, legacy: true };
        const optional = inspection.optional.permissions.length || inspection.optional.origins.length;
        if (optional)
          inspection.unsupported.push({
            capability: 'legacy-optional-permissions',
            required: true,
            reason: 'Reinstall this local extension to enforce optional grants in an adapted copy.',
          });
        if (optional) inspection.compatible = false;
        const version = {
          token,
          legacyPath: entry.path,
          manifest,
          effectiveManifest: manifest,
          inspection,
          publicKey: manifest.key || null,
          source,
          sha256: digest,
          derivedSha256: digest,
          verification: { signatureVerified: false, publisherVerified: false },
          transformVersion: 0,
          createdAt: this.now(),
        };
        return this._save(context, {
          id: entry.extensionId,
          profileId,
          source,
          current: version,
          pending: null,
          previous: null,
          enabled: entry.enabled === true && inspection.compatible,
          status: !inspection.compatible ? 'incompatible' : entry.enabled ? 'enabled' : 'disabled',
          grants: clone(inspection.required),
          generation: context.generation,
          installedAt: entry.installedAt || this.now(),
        });
      } catch (error) {
        await fs.rm(directory, { recursive: true, force: true });
        throw error;
      }
    });
  }
  async _cleanup(profileId) {
    const directory = this.profilePath(profileId),
      retained = new Set(
        this.list(profileId).flatMap((item) =>
          [item.current, item.pending, item.previous].filter(Boolean).map((v) => v.token),
        ),
      );
    for (const name of await fs.readdir(path.join(directory, 'staging')))
      await fs.rm(path.join(directory, 'staging', name), { recursive: true, force: true });
    for (const name of await fs.readdir(path.join(directory, 'versions')))
      if (!retained.has(name))
        await fs.rm(path.join(directory, 'versions', name), { recursive: true, force: true });
    for (const name of await fs.readdir(directory))
      if (name.endsWith('.tmp')) await fs.rm(path.join(directory, name), { force: true });
  }
  async _stage(context, { download, sourceDirectory, publicKey, source }) {
    this._guard(context);
    const token = crypto.randomUUID(),
      staging = path.join(this.profilePath(context.profileId), 'staging', token),
      final = path.join(this.profilePath(context.profileId), 'versions', token);
    await fs.mkdir(staging);
    let moved = false;
    try {
      if (download) {
        if (
          download.id !== context.id ||
          !download.publisherVerified ||
          idFromKey(Buffer.from(download.publicKey, 'base64')) !== context.id ||
          hash(download.buffer) !== download.sha256
        )
          throw new Error('Unverified package identity or provenance');
        await fs.writeFile(path.join(staging, 'original.crx'), download.buffer, { flag: 'wx', mode: 0o600 });
        await extractArchive(download.zip, path.join(staging, 'original'), { signal: context.signal });
        publicKey = download.publicKey;
        source = download.source;
      } else await copyLocal(sourceDirectory, path.join(staging, 'original'), context.signal);
      this._guard(context);
      const manifest = await readManifest(path.join(staging, 'original')),
        inspection = inspectManifest(manifest);
      if (manifest.key && idFromKey(Buffer.from(manifest.key, 'base64')) !== context.id)
        throw new Error('Manifest key conflicts with verified extension identity');
      const adapted = await adaptExtension(path.join(staging, 'original'), path.join(staging, 'derived'), {
        publicKey,
      });
      this._guard(context);
      // Optional rights start ungranted. Never let native Chrome grant them merely
      // because the original manifest advertised them. A future permission change
      // must rebuild this effective copy and unload/reload natively.
      adapted.manifest.optional_permissions = [];
      adapted.manifest.optional_host_permissions = [];
      await fs.writeFile(
        path.join(staging, 'derived', 'manifest.json'),
        JSON.stringify(adapted.manifest, null, 2) + '\n',
      );
      const version = {
        token,
        manifest,
        inspection,
        effectiveManifest: adapted.manifest,
        publicKey,
        source,
        sha256: download?.sha256 || (await treeHash(path.join(staging, 'original'), context.signal)),
        verification: { signatureVerified: !!download, publisherVerified: !!download?.publisherVerified },
        transformVersion: adapted.transformVersion,
        derivedSha256: await treeHash(path.join(staging, 'derived'), context.signal),
        createdAt: this.now(),
      };
      this._guard(context);
      await fs.rename(staging, final);
      moved = true;
      this._guard(context);
      return version;
    } catch (error) {
      await fs.rm(moved ? final : staging, { recursive: true, force: true });
      throw error;
    }
  }
  async _discard(context, version) {
    if (
      version &&
      !this.list(context.profileId).some((item) =>
        [item.current, item.pending, item.previous].some((v) => v?.token === version.token),
      )
    )
      await fs.rm(path.dirname(this.versionPath(context.profileId, version)), {
        recursive: true,
        force: true,
      });
  }
  async _checkLegacyPath(directory) {
    const root = await fs.realpath(this.root),
      real = await fs.realpath(directory);
    if (!real.startsWith(root + path.sep)) throw new Error('Legacy path is outside managed root');
  }
  async _checkVersion(context, version) {
    this._guard(context);
    if (version.legacyPath) {
      await this._checkLegacyPath(version.legacyPath);
      if ((await treeHash(version.legacyPath, context.signal)) !== version.derivedSha256)
        throw new Error('Legacy local extension changed; reinstall for review');
    } else {
      if (
        (await treeHash(this.versionPath(context.profileId, version), context.signal)) !==
        version.derivedSha256
      )
        throw new Error('Managed extension integrity check failed');
      if (
        version.verification.signatureVerified &&
        hash(await fs.readFile(this.versionPath(context.profileId, version, 'original.crx'))) !==
          version.sha256
      )
        throw new Error('Original package integrity check failed');
    }
    this._guard(context);
  }
  async _prepareSession(profileId) {
    const session = this.getSession(profileId);
    let prepared = this.preparedSessions.get(session);
    if (prepared && prepared.profileId !== profileId)
      throw new Error('Native session belongs to another profile');
    if (!prepared) {
      prepared = {
        profileId,
        promise: Promise.resolve().then(() => this.prepareSession(session, profileId)),
      };
      this.preparedSessions.set(session, prepared);
    }
    try {
      await prepared.promise;
    } catch (error) {
      this.preparedSessions.delete(session);
      throw error;
    }
    return session;
  }
  async _nativeLoad(context, record, version, grants) {
    this._guard(context);
    const session = await this._prepareSession(context.profileId);
    this._guard(context);
    const metadata = {
      enabled: true,
      manifest: version.effectiveManifest || version.manifest,
      grants: clone(grants),
      generation: context.generation,
      adapted: !version.legacyPath,
    };
    this.runtime.set(context.key, metadata);
    try {
      const loaded = await session.extensions.loadExtension(
        version.legacyPath || this.versionPath(context.profileId, version),
        { allowFileAccess: false },
      );
      if (loaded.id !== record.id) {
        session.extensions.removeExtension(loaded.id);
        throw new Error('Native extension identity mismatch');
      }
      this._guard(context);
    } catch (error) {
      this.runtime.delete(context.key);
      session.extensions.removeExtension(record.id);
      throw error;
    }
  }
  async _unload(context, reason) {
    this.runtime.delete(context.key);
    this.getSession(context.profileId).extensions.removeExtension(context.id);
    const result = await this.onDeactivated({
      profileId: context.profileId,
      extensionId: context.id,
      reason,
      generation: context.generation,
    });
    this._guard(context);
    return result?.requiresPageReload !== false;
  }
  async _activate(context, record, version, { grants = version.inspection.required, rollback = false } = {}) {
    this._guard(context);
    if (!version.inspection.compatible) throw new Error('Extension requires unsupported capabilities');
    const old = record.current,
      wasEnabled = !!record.enabled;
    let needsReload = record.requiresPageReload || false;
    await this._checkVersion(context, version);
    if (wasEnabled) needsReload = await this._unload(context, rollback ? 'rollback' : 'update');
    const reduced = reducedGrants(record.grants, grants);
    if (record.permissionReloadPending || (reduced && needsReload)) {
      const next = this._save(context, {
        ...record,
        current: version,
        pending: null,
        previous: rollback ? null : old,
        enabled: false,
        status: 'pending-reload',
        grants: clone(grants),
        generation: context.generation,
        requiresPageReload: true,
        permissionReloadPending: true,
      });
      await this._discard(context, record.previous);
      await this._discard(context, record.pending);
      return next;
    }
    let committed = false;
    try {
      await this._nativeLoad(context, record, version, grants);
      this._guard(context);
      const next = {
        ...record,
        current: version,
        pending: null,
        previous: rollback ? null : old,
        enabled: true,
        status: 'enabled',
        grants: clone(grants),
        generation: context.generation,
        error: null,
        requiresPageReload: needsReload,
      };
      this._save(context, next);
      committed = true;
      if (record.previous && record.previous.token !== next.previous?.token)
        await this._discard(context, record.previous);
      if (record.pending && record.pending.token !== version.token)
        await this._discard(context, record.pending);
      return clone(next);
    } catch (error) {
      if (committed) throw error; // Cleanup cannot undo a durable activation.
      this.runtime.delete(context.key);
      this.getSession(context.profileId).extensions.removeExtension(record.id);
      if (
        wasEnabled &&
        old &&
        !context.signal.aborted &&
        this.epochs.get(context.profileId) === context.epoch
      ) {
        try {
          await this._nativeLoad(context, record, old, record.grants);
        } catch {
          this.runtime.delete(context.key);
          this._save(context, {
            ...record,
            enabled: false,
            status: 'load-failed',
            error: 'Replacement and restoration failed',
          });
        }
      }
      throw error;
    }
  }
  async _permission(context, kind, version, record) {
    const answer = await this.confirmPermissions({
      profileId: context.profileId,
      profile: clone(this._profile(context.profileId)),
      extensionId: context.id,
      generation: context.generation,
      signal: context.signal,
      kind,
      manifest: clone(version.manifest),
      inspection: clone(version.inspection),
      source: clone(version.source),
      previous: record?.current ? clone(record.current.manifest) : null,
    });
    this._guard(context);
    return answer === true;
  }
  async _install(context, version) {
    const record = {
      id: context.id,
      profileId: context.profileId,
      source: version.source,
      current: null,
      pending: version,
      previous: null,
      enabled: false,
      status: version.inspection.compatible ? 'pending-approval' : 'incompatible',
      grants: { permissions: [], origins: [] },
      generation: context.generation,
      installedAt: this.now(),
    };
    if (!version.inspection.compatible || !(await this._permission(context, 'install', version, null)))
      return this._save(context, record);
    return this._activate(context, record, version);
  }
  installStore(profileId, input) {
    let id;
    try {
      id = parseStoreId(input);
    } catch (error) {
      return Promise.reject(error);
    }
    return this._run(profileId, id, async (context) => {
      if (this.list(profileId).some((item) => item.id === id))
        throw new Error('Extension is already installed');
      const download = await this.fetchPackage(id, {
        signal: context.signal,
        chromiumVersion: this.chromiumVersion,
      });
      this._guard(context);
      const version = await this._stage(context, { download });
      try {
        return await this._install(context, version);
      } finally {
        await this._discard(context, version);
      }
    });
  }
  async installLocal(profileId, directory) {
    this._profile(profileId);
    directory = path.resolve(directory);
    if (
      this.root === directory ||
      this.root.startsWith(directory + path.sep) ||
      directory.startsWith(this.root + path.sep)
    )
      throw new Error('Choose a local extension outside the managed root');
    // Capture the profile lifecycle before asynchronous filesystem inspection.
    const epoch = this.epochs.get(profileId),
      localEpoch = this.localEpochs.get(profileId),
      manifest = await readManifest(directory);
    this._profile(profileId);
    if (epoch !== this.epochs.get(profileId) || localEpoch !== this.localEpochs.get(profileId))
      throw new Error('Stale local installation');
    let publicKey = manifest.key;
    if (publicKey)
      crypto.createPublicKey({ key: Buffer.from(publicKey, 'base64'), format: 'der', type: 'spki' });
    else
      publicKey = crypto
        .generateKeyPairSync('rsa', { modulusLength: 2048 })
        .publicKey.export({ format: 'der', type: 'spki' })
        .toString('base64');
    const id = idFromKey(Buffer.from(publicKey, 'base64'));
    return this._run(profileId, id, async (context) => {
      if (this.list(profileId).some((item) => item.id === id))
        throw new Error('Extension is already installed');
      const version = await this._stage(context, {
        sourceDirectory: directory,
        publicKey,
        source: { kind: 'local-unpacked', portable: false },
      });
      try {
        return await this._install(context, version);
      } finally {
        await this._discard(context, version);
      }
    });
  }
  update(profileId, id) {
    return this._run(profileId, id, async (context) => {
      const record = this._record(profileId, id);
      if (record.source.kind !== 'chrome-web-store')
        throw new Error('Local-only extensions must be reinstalled manually');
      const download = await this.fetchPackage(id, {
        signal: context.signal,
        chromiumVersion: this.chromiumVersion,
      });
      this._guard(context);
      const version = await this._stage(context, { download });
      try {
        if (record.current) {
          const order = compareVersions(version.manifest.version, record.current.manifest.version);
          if (order < 0) throw new Error('Automatic extension downgrade rejected');
          if (order === 0) {
            if (version.sha256 !== record.current.sha256) throw new Error('Same-version package changed');
            return record;
          }
        }
        if (
          !record.current ||
          requiresReview(record.current.inspection, version.inspection, record.grants) ||
          !version.inspection.compatible
        ) {
          const result = this._save(context, {
            ...record,
            pending: version,
            status: version.inspection.compatible ? 'pending-approval' : 'incompatible',
          });
          await this._discard(context, record.pending);
          return result;
        }
        if (!record.enabled) {
          const result = this._save(context, {
            ...record,
            current: version,
            pending: null,
            previous: record.current,
            status: 'disabled',
            generation: context.generation,
            grants: clone(version.inspection.required),
            permissionReloadPending: pendingPermissionReload(record, version.inspection.required),
          });
          await this._discard(context, record.previous);
          await this._discard(context, record.pending);
          return result;
        }
        return await this._activate(context, record, version);
      } finally {
        await this._discard(context, version);
      }
    });
  }
  approve(profileId, id) {
    return this._run(profileId, id, async (context) => {
      const record = this._record(profileId, id),
        version = record.pending;
      if (!version) throw new Error('No pending extension version');
      if (!version.inspection.compatible) throw new Error('Extension requires unsupported capabilities');
      if (!(await this._permission(context, record.current ? 'update' : 'install', version, record)))
        return record;
      if (record.current && !record.enabled) {
        await this._checkVersion(context, version);
        const result = this._save(context, {
          ...record,
          current: version,
          previous: record.current,
          pending: null,
          grants: clone(version.inspection.required),
          permissionReloadPending: pendingPermissionReload(record, version.inspection.required),
          generation: context.generation,
          status: 'disabled',
        });
        await this._discard(context, record.previous);
        return result;
      }
      return this._activate(context, record, version);
    });
  }
  enable(profileId, id) {
    return this._run(profileId, id, async (context) => {
      const record = this._record(profileId, id);
      if (record.enabled) return record;
      if (record.permissionReloadPending) {
        const result = await this.onDeactivated({
          profileId,
          extensionId: id,
          reason: 'verify-reload',
          generation: context.generation,
        });
        this._guard(context);
        if (result?.requiresPageReload !== false)
          throw new Error('Reload affected pages before enabling this extension');
        record.permissionReloadPending = false;
        record.requiresPageReload = false;
      }
      if (!record.current) throw new Error('Approve extension permissions before enabling');
      if (requiresReview(record.current.inspection, record.current.inspection, record.grants))
        throw new Error('Extension permissions require approval');
      await this._checkVersion(context, record.current);
      await this._nativeLoad(context, record, record.current, record.grants);
      try {
        return this._save(context, {
          ...record,
          enabled: true,
          status: record.pending ? 'pending-approval' : 'enabled',
          generation: context.generation,
        });
      } catch (error) {
        this.runtime.delete(context.key);
        this.getSession(profileId).extensions.removeExtension(id);
        throw error;
      }
    });
  }
  _revokeNow(profileId, id) {
    this._profile(profileId);
    this.runtime.delete(this._key(profileId, id));
    this.getSession(profileId).extensions.removeExtension(id);
  }
  disable(profileId, id) {
    let record;
    return this._run(
      profileId,
      id,
      async (context) => {
        const requiresPageReload = await this._unload(context, 'disable');
        return this._save(context, { ...record, requiresPageReload });
      },
      (context) => {
        record = this._record(profileId, id);
        this._revokeNow(profileId, id);
        record = {
          ...record,
          enabled: false,
          status: 'disabled',
          generation: context.generation,
          requiresPageReload: true,
        };
        this._save(context, record);
      },
    );
  }
  remove(profileId, id) {
    let record;
    return this._run(
      profileId,
      id,
      async (context) => {
        const requiresPageReload = await this._unload(context, 'remove');
        for (const version of [record?.current, record?.pending, record?.previous])
          await this._discard(context, version);
        return { removed: true, requiresPageReload };
      },
      (context) => {
        this.localEpochs.set(profileId, crypto.randomUUID());
        record = this.list(profileId).find((item) => item.id === id);
        this._revokeNow(profileId, id);
        this._persist(
          profileId,
          (state) => {
            state.extensions = state.extensions.filter((item) => item.id !== id);
          },
          context,
        );
      },
    );
  }
  rollback(profileId, id) {
    return this._run(profileId, id, async (context) => {
      const record = this._record(profileId, id);
      if (!record.previous) throw new Error('No rollback version available');
      const previous = record.previous;
      if (
        requiresReview(record.current.inspection, previous.inspection, record.grants) &&
        !(await this._permission(context, 'rollback', previous, record))
      )
        return record;
      let result;
      if (record.enabled) result = await this._activate(context, record, previous, { rollback: true });
      else {
        await this._checkVersion(context, previous);
        result = this._save(context, {
          ...record,
          current: previous,
          previous: null,
          pending: null,
          grants: clone(previous.inspection.required),
          permissionReloadPending: pendingPermissionReload(record, previous.inspection.required),
          status: 'disabled',
          generation: context.generation,
        });
        await this._discard(context, record.pending);
      }
      await this._discard(context, record.current);
      return result;
    });
  }
  async checkUpdates(profileId, { force = false } = {}) {
    this._profile(profileId);
    const epoch = this.epochs.get(profileId),
      schedule = this.schedule(profileId);
    if (!force && this.now() < schedule.nextCheck) return { checked: 0, errors: [] };
    const errors = [];
    let checked = 0;
    for (const record of this.list(profileId))
      if (record.source.kind === 'chrome-web-store') {
        if (epoch !== this.epochs.get(profileId) || this.closed)
          throw new Error('Stale profile update check');
        try {
          await this.update(profileId, record.id);
          checked++;
        } catch (error) {
          if (epoch !== this.epochs.get(profileId) || this.closed) throw error;
          errors.push({ id: record.id, error: String(error.message).slice(0, 500) });
        }
      }
    if (epoch !== this.epochs.get(profileId) || this.closed) throw new Error('Stale profile update check');
    const failures = errors.length ? Math.min(12, schedule.failures + 1) : 0,
      delay = failures ? Math.min(SIX_HOURS, 60000 * 2 ** (failures - 1)) : SIX_HOURS;
    this._persist(profileId, (state) => {
      state.schedule = {
        lastCheck: this.now(),
        failures,
        nextCheck: this.now() + Math.round(delay * (0.9 + this.random() * 0.2)),
      };
    });
    return { checked, errors };
  }
  startUpdates(profileId) {
    this._profile(profileId);
    this.stopUpdates(profileId);
    const epoch = this.epochs.get(profileId);
    const schedule = () => {
      if (this.closed || epoch !== this.epochs.get(profileId)) return;
      const delay = Math.min(0x7fffffff, Math.max(0, this.schedule(profileId).nextCheck - this.now()));
      const timer = setTimeout(async () => {
        try {
          await this.checkUpdates(profileId);
        } catch {
          /* Teardown cancels checks. Errors are reflected by checkUpdates. */
        }
        schedule();
      }, delay);
      timer.unref?.();
      this.timers.set(profileId, timer);
    };
    schedule();
  }
  stopUpdates(profileId) {
    clearTimeout(this.timers.get(profileId));
    this.timers.delete(profileId);
  }
  async invalidateProfile(profileId) {
    this.stopUpdates(profileId);
    this.restored.delete(profileId);
    this.epochs.set(profileId, crypto.randomUUID());
    for (const [key, context] of this.operations)
      if (context.profileId === profileId) {
        context.controller.abort(new Error('Stale profile lifecycle cancelled'));
        this.operations.delete(key);
      }
    for (const key of this.runtime.keys())
      if (JSON.parse(key)[0] === profileId) {
        this.runtime.delete(key);
        this.getSession(profileId).extensions.removeExtension(JSON.parse(key)[1]);
      }
    const pending = [...this.queues]
      .filter(([key]) => JSON.parse(key)[0] === profileId)
      .map(([, promise]) => promise);
    await Promise.allSettled(pending);
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    for (const profileId of this.states.keys()) await this.invalidateProfile(profileId);
  }
}
module.exports = { ExtensionManager };
