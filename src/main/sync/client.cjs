'use strict';
const { randomUUID } = require('node:crypto');
const { SyncStorage, storageOperation, emptyArea } = require('./storage.cjs');
const { CredentialVault } = require('./vault.cjs');
const { own, clone, difference, applySettings } = require('../../core/sync/model.cjs');
const idPattern = /^[a-zA-Z0-9_-]{1,128}$/;
const extensionPattern = /^[a-p]{32}$/;
const localKey = (profile, extension) => JSON.stringify(['local', profile, extension]);
const areaKey = (extension, generation) => `${extension}/${generation}`;
const cancelled = () =>
  Object.assign(new Error('The synchronization context changed.'), { code: 'cancelled' });
function endpointURL(input, allowInsecureLoopback) {
  try {
    const u = new URL(input);
    if (u.username || u.password || u.search || u.hash || u.pathname !== '/') throw new Error();
    if (
      u.protocol !== 'https:' &&
      !(allowInsecureLoopback && u.protocol === 'http:' && ['127.0.0.1', '[::1]'].includes(u.hostname))
    )
      throw new Error();
    return u.origin;
  } catch {
    throw new Error(
      'The service endpoint must be an HTTPS origin (explicit loopback development is allowed).',
    );
  }
}
function library(link) {
  const records = new Map(Object.entries(link.library));
  for (const op of link.outbox)
    if (op.kind === 'extension') {
      const current = records.get(op.extensionId);
      if (
        current &&
        (current.generation !== op.generation || current.state === 'removed') &&
        op.baseRevision < current.revision
      )
        continue;
      records.set(op.extensionId, {
        extensionId: op.extensionId,
        generation: op.generation,
        revision: current?.revision || 0,
        ...op.payload,
      });
    }
  return Object.fromEntries(records);
}
function visible(link, extensionId) {
  const entry = library(link)[extensionId];
  if (!entry || entry.state === 'removed') return {};
  const base = link.base[areaKey(extensionId, entry.generation)] || { values: {}, revisions: {} };
  let values = clone(base.values);
  for (const operation of [...link.rejected.map((r) => r.operation), ...link.outbox]) {
    if (
      operation.kind === 'settings' &&
      operation.extensionId === extensionId &&
      operation.generation === entry.generation
    )
      values = applySettings(values, operation.payload, base.revisions, operation.baseRevision);
  }
  return values;
}
function allVisible(link) {
  return Object.fromEntries(Object.keys(library(link)).map((id) => [id, visible(link, id)]));
}
function independentArea(link, extensionId, values, localArea) {
  const entry = library(link)[extensionId];
  return {
    ...clone(link.areas[areaKey(extensionId, entry?.generation)] || localArea || emptyArea()),
    values,
  };
}
function applyChange(link, change) {
  if (change.kind === 'extension') {
    link.library[change.extensionId] = {
      extensionId: change.extensionId,
      generation: change.generation,
      revision: change.revision,
      ...change.payload,
    };
  } else if (link.settingsSync && change.kind === 'settings') {
    const key = areaKey(change.extensionId, change.generation);
    const base = (link.base[key] ||= { values: {}, revisions: {} });
    const values = new Map(Object.entries(base.values)),
      revisions = new Map(Object.entries(base.revisions));
    for (const [name, delta] of Object.entries(change.payload.changes)) {
      if (own(delta, 'newValue')) values.set(name, delta.newValue);
      else values.delete(name);
      revisions.set(name, change.revision);
    }
    base.values = Object.fromEntries(values);
    base.revisions = Object.fromEntries(revisions);
  }
}
class SyncClient {
  constructor({
    directory,
    protect,
    unprotect,
    onLibraryChange = () => {},
    onStorageChange = () => {},
    onChange = () => {},
    allowInsecureLoopback = false,
    autoSync = true,
    getProfile = (id) => ({ id, private: false }),
    fetch: fetcher = globalThis.fetch,
  }) {
    this.store = new SyncStorage({ directory });
    this.retiredProfiles = new Set(this.store.read().retiredProfiles || []);
    this.vault = new CredentialVault({ directory, protect, unprotect });
    this.onLibraryChange = onLibraryChange;
    this.onStorageChange = onStorageChange;
    this.onChange = onChange;
    this.allowInsecureLoopback = allowInsecureLoopback;
    this.autoSync = autoSync;
    this.getProfile = getProfile;
    this.fetch = fetcher;
    this.epoch = 0;
    this.controllers = new Set();
    this.profileIntents = new Map();
    this.closed = false;
    this.failures = 0;
    this.state = 'signed-out';
    try {
      this.credentials = this.vault.load();
      const state = this.store.read();
      if (
        this.credentials &&
        (this.credentials.endpoint !== state.endpoint || this.credentials.account.id !== state.account?.id)
      )
        this.credentials = null;
      if (this.credentials) this.state = 'connected';
      else if (state.account) this.detach('reconnect-required');
    } catch {
      this.credentials = null;
      this.state = 'reconnect-required';
    }
    this.schedule(100);
  }
  status() {
    const s = this.store.read();
    return {
      endpoint: s.endpoint,
      account: this.credentials ? clone(s.account) : null,
      device: this.credentials ? clone(this.credentials.device) : null,
      state: s.endpoint ? this.state : 'setup-required',
      profiles: Object.entries(s.links).map(([profileId, l]) => ({
        profileId,
        datasetId: l.datasetId,
        name: l.name,
        settingsSync: l.settingsSync,
        pending: l.outbox.length,
        rejected: l.rejected.map((r) => ({
          id: r.operation.id,
          extensionId: r.operation.extensionId,
          kind: r.operation.kind,
          code: r.code,
        })),
        lastSync: l.lastSync || null,
      })),
    };
  }
  notify() {
    if (!this.closed) this.onChange(this.status());
  }
  extensionIntents(profileId) {
    this.profile(profileId);
    const link = this.store.read().links[profileId];
    if (!link || !this.credentials) return [];
    return Object.values(library(link)).map((extension) => ({
      ...this.identity(profileId, link),
      extension: clone(extension),
    }));
  }
  guard(epoch = this.epoch) {
    if (this.closed || epoch !== this.epoch) throw cancelled();
  }
  invalidate() {
    this.epoch++;
    this.running = null;
    this.refreshing = null;
    for (const c of this.controllers) c.abort();
    this.controllers.clear();
    clearTimeout(this.timer);
  }
  profile(id) {
    if (typeof id !== 'string' || !idPattern.test(id)) throw new Error('Invalid profile.');
    if (this.retiredProfiles.has(id))
      throw Object.assign(
        new Error(
          "This profile's deletion is incomplete; delete this profile again to finish. Synchronization context changed.",
        ),
        { code: 'cancelled' },
      );
    const profile = this.getProfile(id);
    if (!profile || profile.private) throw new Error('Private or unavailable profiles cannot synchronize.');
    return profile;
  }
  isCurrentLink({ profileId, linkId, endpoint, accountId }) {
    if (this.closed || this.retiredProfiles.has(profileId)) return false;
    const s = this.store.read(),
      l = s.links[profileId];
    return (
      !!l && l.id === linkId && s.endpoint === endpoint && s.account?.id === accountId && !!this.credentials
    );
  }
  identity(profileId, link) {
    return { profileId, linkId: link.id, endpoint: link.endpoint, accountId: link.accountId };
  }
  linkGuard(identity, epoch) {
    this.guard(epoch);
    if (!this.isCurrentLink(identity)) throw cancelled();
  }
  async configure({ endpoint }) {
    const normalized = endpoint ? endpointURL(endpoint, this.allowInsecureLoopback) : '';
    if (normalized === this.store.read().endpoint) return this.status();
    this.detach('signed-out');
    this.store.transaction((s) => {
      s.endpoint = normalized;
    });
    this.notify();
    return this.status();
  }
  cancelProfileRequests(profileId) {
    for (const controller of this.controllers) if (controller.profileId === profileId) controller.abort();
  }
  async raw(
    route,
    { method = 'GET', body, token, epoch = this.epoch, retryRead = true, scopeGuard, profileId } = {},
  ) {
    const guard = () => {
      this.guard(epoch);
      scopeGuard?.();
    };
    guard();
    const endpoint = this.store.read().endpoint;
    if (!endpoint) throw new Error('Set up a synchronization service first.');
    const controller = new AbortController();
    controller.profileId = profileId;
    this.controllers.add(controller);
    const timer = setTimeout(() => controller.abort(), 15000);
    timer.unref?.();
    try {
      guard();
      const response = await this.fetch(endpoint + '/v1' + route, {
        method,
        redirect: 'error',
        signal: controller.signal,
        headers: {
          'content-type': 'application/json',
          ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      guard();
      let size = 0;
      const chunks = [];
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > 64 * 1024 * 1024) {
          controller.abort();
          throw new Error('The service response is too large.');
        }
        chunks.push(chunk);
      }
      guard();
      let data;
      try {
        data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch {
        throw new Error('The synchronization service returned an invalid response.');
      }
      if (!response.ok)
        throw Object.assign(new Error(data.error?.message || 'The synchronization request failed.'), {
          code: data.error?.code || 'service_error',
          status: response.status,
        });
      return data;
    } catch (error) {
      guard();
      if (retryRead && method === 'GET' && ['ECONNRESET', 'UND_ERR_SOCKET'].includes(error.cause?.code))
        return this.raw(route, { method, body, token, epoch, retryRead: false, scopeGuard, profileId });
      throw error;
    } finally {
      clearTimeout(timer);
      this.controllers.delete(controller);
    }
  }
  async refresh(epoch) {
    if (this.refreshing) return this.refreshing;
    const refreshToken = this.credentials?.refreshToken;
    if (!refreshToken) throw new Error('Sign in to synchronize.');
    const promise = (async () => {
      const result = await this.raw('/sessions/refresh', { method: 'POST', body: { refreshToken }, epoch });
      this.guard(epoch);
      const next = { ...this.credentials, ...result };
      this.vault.save(next);
      this.credentials = next;
    })();
    this.refreshing = promise;
    try {
      await promise;
    } finally {
      if (this.refreshing === promise) this.refreshing = null;
    }
  }
  async request(route, options = {}) {
    const epoch = options.epoch ?? this.epoch;
    this.guard(epoch);
    options.scopeGuard?.();
    if (!this.credentials) throw new Error('Sign in to synchronize.');
    try {
      if (this.credentials.expiresAt <= Date.now() + 30000) await this.refresh(epoch);
      return await this.raw(route, { ...options, epoch, token: this.credentials.accessToken });
    } catch (error) {
      if (error.status === 401 && epoch === this.epoch) this.detach('reconnect-required');
      throw error;
    }
  }
  async authenticate(route, fields) {
    this.vault.assertAvailable();
    this.detach('signed-out');
    const epoch = this.epoch;
    const result = await this.raw(route, { method: 'POST', body: fields, epoch });
    this.guard(epoch);
    const { recoveryCodes, ...credentials } = result;
    if (
      !credentials.account?.id ||
      !credentials.device?.id ||
      typeof credentials.accessToken !== 'string' ||
      typeof credentials.refreshToken !== 'string'
    )
      throw new Error('Invalid account response.');
    credentials.endpoint = this.store.read().endpoint;
    this.vault.save(credentials);
    this.credentials = credentials;
    this.store.transaction((s) => {
      const owner = JSON.stringify([s.endpoint, credentials.account.id]);
      if (s.localOwner && s.localOwner !== owner) s.areas = clone(s.localCopies?.[owner] || {});
      s.localOwner = owner;
      s.account = credentials.account;
    });
    this.state = 'connected';
    this.schedule(100);
    this.notify();
    return {
      account: clone(credentials.account),
      device: clone(credentials.device),
      ...(recoveryCodes ? { recoveryCodes } : {}),
    };
  }
  register(fields) {
    return this.authenticate('/accounts', fields);
  }
  login(fields) {
    return this.authenticate('/sessions', fields);
  }
  recover(fields) {
    return this.authenticate('/accounts/recover', fields);
  }
  detach(state = 'signed-out') {
    this.invalidate();
    this.store.transaction((s) => {
      for (const [profile, link] of Object.entries(s.links)) {
        if (link.settingsSync)
          for (const [ext, values] of Object.entries(allVisible(link)))
            s.areas[localKey(profile, ext)] = independentArea(
              link,
              ext,
              values,
              s.areas[localKey(profile, ext)],
            );
      }
      if (s.localOwner) {
        s.localCopies ||= {};
        s.localCopies[s.localOwner] = clone(s.areas);
      }
      s.links = {};
      s.account = null;
    });
    this.credentials = null;
    this.vault.clear();
    this.state = state;
    this.notify();
  }
  async logout() {
    const credentials = this.credentials,
      endpoint = this.store.read().endpoint;
    this.detach('signed-out');
    if (credentials)
      try {
        await this.fetch(endpoint + '/v1/sessions/current', {
          method: 'DELETE',
          redirect: 'error',
          headers: { authorization: `Bearer ${credentials.accessToken}` },
          signal: AbortSignal.timeout(10000),
        });
      } catch {
        /* Local logout is immediate even when the device is offline. */
      }
    return this.status();
  }
  async devices() {
    return (await this.request('/devices')).devices;
  }
  async renameDevice(id, name) {
    const result = await this.request(`/devices/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: { name },
    });
    if (this.credentials?.device.id === id) {
      this.credentials.device.name = name;
      this.vault.save(this.credentials);
    }
    this.notify();
    return result;
  }
  async revokeDevice(id) {
    const result = await this.request(`/devices/${encodeURIComponent(id)}`, { method: 'DELETE' });
    if (this.credentials?.device.id === id) this.detach('reconnect-required');
    return result;
  }
  async changePassword(password, newPassword) {
    await this.request('/account/password', { method: 'POST', body: { password, newPassword } });
    return { changed: true };
  }
  async recoveryCodes(password) {
    return this.request('/account/recovery-codes', { method: 'POST', body: { password } });
  }
  async deleteAccount(password, confirm) {
    if (confirm !== true) throw new Error('Confirm account deletion.');
    await this.request('/account', { method: 'DELETE', body: { password, confirm } });
    this.detach('signed-out');
  }
  async datasets() {
    return (await this.request('/datasets')).datasets;
  }
  async createDataset(name) {
    return this.request('/datasets', { method: 'POST', body: { name } });
  }
  async deleteDataset(datasetId, password, confirm) {
    if (confirm !== true) throw new Error('Confirm dataset deletion.');
    await this.request(`/datasets/${encodeURIComponent(datasetId)}`, {
      method: 'DELETE',
      body: { password, confirm },
    });
    for (const [profile, link] of Object.entries(this.store.read().links))
      if (link.datasetId === datasetId) await this.unlinkProfile(profile);
  }
  async previewLink({ profileId, datasetId, includeSettings = false }) {
    this.profile(profileId);
    const snapshot = await this.request(
      `/datasets/${encodeURIComponent(datasetId)}/snapshot?settings=${includeSettings ? 1 : 0}`,
    );
    return {
      dataset: snapshot.dataset,
      extensions: snapshot.extensions,
      settingsAvailable: snapshot.settings.length > 0,
    };
  }
  async linkProfile({
    profileId,
    datasetId,
    libraryChoice,
    localLibrary = [],
    settingsSync = false,
    settingsChoice,
    settingsConsent = false,
    preserveLibrary = false,
  }) {
    this.profile(profileId);
    if (!['remote-only', 'merge-local'].includes(libraryChoice))
      throw new Error('Review and choose the extension library changes first.');
    if (settingsSync && (!settingsConsent || !['upload-local', 'use-remote'].includes(settingsChoice)))
      throw new Error('Settings synchronization requires explicit consent and a local/remote choice.');
    const intent = (this.profileIntents.get(profileId) || 0) + 1;
    this.profileIntents.set(profileId, intent);
    const epoch = this.epoch,
      before = this.store.read(),
      oldLinkId = before.links[profileId]?.id;
    if (Object.entries(before.links).some(([p, l]) => p !== profileId && l.datasetId === datasetId))
      throw new Error('This dataset is already linked to another local profile.');
    const scopeGuard = () => {
      this.guard(epoch);
      this.profile(profileId);
      if (
        this.profileIntents.get(profileId) !== intent ||
        this.store.read().links[profileId]?.id !== oldLinkId
      )
        throw cancelled();
    };
    const snapshot = await this.request(
      `/datasets/${encodeURIComponent(datasetId)}/snapshot?settings=${settingsSync ? 1 : 0}`,
      { epoch, profileId, scopeGuard },
    );
    this.guard(epoch);
    this.profile(profileId);
    if (this.profileIntents.get(profileId) !== intent || this.store.read().links[profileId]?.id !== oldLinkId)
      throw cancelled();
    const link = {
      id: randomUUID(),
      datasetId,
      name: snapshot.dataset.name,
      epoch: snapshot.dataset.epoch,
      endpoint: before.endpoint,
      accountId: before.account.id,
      settingsSync,
      cursor: snapshot.cursor,
      library: Object.fromEntries(snapshot.extensions.map((e) => [e.extensionId, e])),
      base: Object.fromEntries(
        snapshot.settings.map((s) => [
          areaKey(s.extensionId, s.generation),
          { values: s.values, revisions: s.revisions },
        ]),
      ),
      areas: {},
      outbox: [],
      rejected: [],
    };
    this.store.transaction((s) => {
      const previous = s.links[profileId];
      if (previous?.settingsSync)
        for (const [ext, values] of Object.entries(allVisible(previous)))
          s.areas[localKey(profileId, ext)] = independentArea(
            previous,
            ext,
            values,
            s.areas[localKey(profileId, ext)],
          );
      s.links[profileId] = link;
      if (preserveLibrary && previous?.datasetId === datasetId) {
        link.outbox = previous.outbox.filter((op) => op.kind === 'extension');
        link.rejected = previous.rejected.filter((r) => r.operation.kind === 'extension');
      }
      if (libraryChoice === 'merge-local') for (const item of localLibrary) this.enqueueLibrary(link, item);
      if (settingsSync && settingsChoice === 'upload-local')
        for (const e of Object.values(library(link))) {
          if (e.state === 'removed') continue;
          const values = s.areas[localKey(profileId, e.extensionId)]?.values;
          if (values && Object.keys(values).length)
            link.outbox.push({
              id: randomUUID(),
              kind: 'settings',
              extensionId: e.extensionId,
              generation: e.generation,
              baseRevision: link.cursor,
              payload: { set: values },
            });
        }
    });
    this.cancelProfileRequests(profileId);
    for (const extension of Object.values(library(link))) this.emitLibrary(profileId, link, extension);
    if (settingsSync)
      for (const [ext, values] of Object.entries(allVisible(link))) {
        const changes = difference(before.areas[localKey(profileId, ext)]?.values || {}, values);
        this.emitStorage(profileId, link, ext, changes);
      }
    this.schedule(100);
    this.notify();
    return this.status();
  }
  async unlinkProfile(profileId) {
    this.profile(profileId);
    this.profileIntents.set(profileId, (this.profileIntents.get(profileId) || 0) + 1);
    this.cancelProfileRequests(profileId);
    this.store.transaction((s) => {
      const link = s.links[profileId];
      if (!link) return;
      if (link.settingsSync)
        for (const [ext, values] of Object.entries(allVisible(link)))
          s.areas[localKey(profileId, ext)] = independentArea(
            link,
            ext,
            values,
            s.areas[localKey(profileId, ext)],
          );
      delete s.links[profileId];
    });
    this.notify();
    return this.status();
  }
  async deleteLocalProfile(profileId) {
    // A later teardown failure may require repeating confirmed deletion. The
    // retired profile remains closed to producers, but this operation is idempotent.
    if (!this.retiredProfiles.has(profileId)) this.profile(profileId);
    this.store.transaction((s) => {
      delete s.links[profileId];
      for (const areas of [s.areas, ...Object.values(s.localCopies || {})])
        for (const key of Object.keys(areas)) {
          const namespace = JSON.parse(key);
          if (namespace[0] === 'local' && namespace[1] === profileId) delete areas[key];
        }
      s.retiredProfiles ||= [];
      if (!s.retiredProfiles.includes(profileId)) s.retiredProfiles.push(profileId);
    });
    // No await separates the committed purge/retirement and cancellation. If
    // the transaction failed, neither current work nor profile authority changes.
    this.retiredProfiles.add(profileId);
    this.profileIntents.set(profileId, (this.profileIntents.get(profileId) || 0) + 1);
    this.cancelProfileRequests(profileId);
    this.notify();
    return this.status();
  }
  completeLocalProfileDeletion(profileId) {
    if (!this.retiredProfiles.has(profileId)) return;
    if (this.getProfile(profileId))
      throw new Error('The browser profile still exists; finish removing it first.');
    // The caller must durably remove browser metadata before clearing this
    // marker. An interrupted teardown remains fail-closed across client restart.
    this.store.transaction((s) => {
      s.retiredProfiles = (s.retiredProfiles || []).filter((id) => id !== profileId);
    });
    this.retiredProfiles.delete(profileId);
  }
  async setSettingsSync(profileId, enabled, options = {}) {
    this.profile(profileId);
    const link = this.store.read().links[profileId];
    if (!link) throw new Error('Link this profile before enabling synchronization.');
    if (enabled)
      return this.linkProfile({
        profileId,
        datasetId: link.datasetId,
        libraryChoice: 'remote-only',
        settingsSync: true,
        settingsChoice: options.settingsChoice,
        settingsConsent: options.settingsConsent,
        preserveLibrary: true,
      });
    this.profileIntents.set(profileId, (this.profileIntents.get(profileId) || 0) + 1);
    this.cancelProfileRequests(profileId);
    this.store.transaction((s) => {
      const current = s.links[profileId];
      if (current.settingsSync)
        for (const [ext, values] of Object.entries(allVisible(current)))
          s.areas[localKey(profileId, ext)] = independentArea(
            current,
            ext,
            values,
            s.areas[localKey(profileId, ext)],
          );
      current.id = randomUUID();
      current.settingsSync = false;
      current.outbox = current.outbox.filter((op) => op.kind === 'extension');
      current.rejected = current.rejected.filter((r) => r.operation.kind === 'extension');
      current.base = {};
      current.areas = {};
    });
    this.notify();
    return this.status();
  }
  enqueueLibrary(link, { extensionId, source, state }) {
    if (
      !extensionPattern.test(extensionId) ||
      source?.kind !== 'web-store' ||
      source.id !== extensionId ||
      !['enabled', 'disabled', 'removed'].includes(state)
    )
      throw new Error('Only a verified portable extension source can synchronize.');
    const current = library(link)[extensionId];
    if (current?.state === state) return;
    const generation =
      !current || (current.state === 'removed' && state !== 'removed') ? randomUUID() : current.generation;
    link.outbox.push({
      id: randomUUID(),
      kind: 'extension',
      extensionId,
      generation,
      baseRevision: link.cursor,
      payload: { source: { kind: 'web-store', id: extensionId }, state },
    });
  }
  async queueExtension({ profileId, ...item }) {
    this.profile(profileId);
    this.store.transaction((s) => {
      const link = s.links[profileId];
      if (link) this.enqueueLibrary(link, item);
    });
    this.schedule(250);
    this.notify();
  }
  exportRejected(profileId, operationId) {
    this.profile(profileId);
    const rejected = this.store.read().links[profileId]?.rejected.find((r) => r.operation.id === operationId);
    if (!rejected) throw new Error('This unsynced change is no longer available.');
    return clone(rejected.operation);
  }
  async retryRejected(profileId, operationId) {
    this.profile(profileId);
    this.store.transaction((s) => {
      const link = s.links[profileId],
        rejected = link?.rejected.find((r) => r.operation.id === operationId);
      if (!rejected) throw new Error('This unsynced change is no longer available.');
      const current = library(link)[rejected.operation.extensionId];
      if (!current || current.state === 'removed' || current.generation !== rejected.operation.generation)
        throw new Error('This installation was removed. Reinstall it explicitly.');
      link.outbox.push({ ...rejected.operation, id: randomUUID(), baseRevision: link.cursor });
      link.rejected = link.rejected.filter((r) => r !== rejected);
    });
    this.schedule(100);
    this.notify();
  }
  async discardRejected(profileId, operationId) {
    this.profile(profileId);
    const event = this.store.transaction((s) => {
      const link = s.links[profileId],
        rejected = link?.rejected.find((r) => r.operation.id === operationId);
      if (!rejected) throw new Error('This unsynced change is no longer available.');
      const extensionId = rejected.operation.extensionId,
        old = visible(link, extensionId);
      link.rejected = link.rejected.filter((r) => r !== rejected);
      return { link, extensionId, changes: difference(old, visible(link, extensionId)) };
    });
    this.emitStorage(profileId, event.link, event.extensionId, event.changes);
    this.notify();
  }
  async callStorage(context, method, args) {
    this.profile(context.profileId);
    if (context.private || context.enabled === false || !extensionPattern.test(context.extensionId))
      throw new Error('Extension storage access denied or disabled.');
    if (!context.permissions?.includes('storage')) throw new Error('The storage permission is required.');
    let changed, eventLink;
    const result = this.store.transaction((s) => {
      const link = s.links[context.profileId];
      const ext = link && library(link)[context.extensionId];
      const linked = link?.settingsSync && ext && ext.state !== 'removed';
      const key = linked
        ? areaKey(context.extensionId, ext.generation)
        : localKey(context.profileId, context.extensionId);
      const areas = linked ? link.areas : s.areas;
      const area = (areas[key] ||= linked
        ? clone(s.areas[localKey(context.profileId, context.extensionId)] || emptyArea())
        : emptyArea());
      if (linked) area.values = visible(link, context.extensionId);
      const response = storageOperation(area, method, args, { trusted: context.trusted === true });
      changed = response.changes;
      eventLink = linked ? link : null;
      if (linked && response.mutation && Object.keys(changed).length)
        link.outbox.push({
          id: randomUUID(),
          kind: 'settings',
          extensionId: context.extensionId,
          generation: ext.generation,
          baseRevision: link.cursor,
          payload: response.mutation,
        });
      return response.result;
    });
    if (changed && Object.keys(changed).length)
      this.emitStorage(context.profileId, eventLink, context.extensionId, changed);
    if (eventLink) this.schedule(250);
    this.notify();
    return result;
  }
  canAccessStorage(context) {
    try {
      this.profile(context.profileId);
      if (
        context.private ||
        context.enabled === false ||
        !extensionPattern.test(context.extensionId) ||
        !context.permissions?.includes('storage')
      )
        return false;
      const s = this.store.read(),
        link = s.links[context.profileId],
        ext = link && library(link)[context.extensionId];
      const area =
        link?.settingsSync && ext && ext.state !== 'removed'
          ? link.areas[areaKey(context.extensionId, ext.generation)] ||
            s.areas[localKey(context.profileId, context.extensionId)]
          : s.areas[localKey(context.profileId, context.extensionId)];
      return context.trusted === true || area?.accessLevel !== 'TRUSTED_CONTEXTS';
    } catch {
      return false;
    }
  }
  emitStorage(profileId, link, extensionId, changes) {
    if (!Object.keys(changes).length) return;
    this.onStorageChange({
      profileId,
      extensionId,
      changes,
      area: 'sync',
      ...(link ? this.identity(profileId, link) : {}),
    });
  }
  emitLibrary(profileId, link, extension) {
    const result = this.onLibraryChange({ ...this.identity(profileId, link), extension: clone(extension) });
    result?.catch?.(() => {});
  }
  async pull(profileId, link, identity, epoch, results = []) {
    let after = link.cursor,
      through;
    do {
      const page = await this.request(
        `/datasets/${encodeURIComponent(link.datasetId)}/changes?after=${after}&limit=100&settings=${link.settingsSync ? 1 : 0}${through === undefined ? '' : '&through=' + through}`,
        { epoch, profileId, scopeGuard: () => this.linkGuard(identity, epoch) },
      );
      if (
        !Number.isSafeInteger(page.cursor) ||
        page.cursor < after ||
        (page.hasMore && page.cursor === after)
      )
        throw new Error('Invalid synchronization cursor.');
      this.linkGuard(identity, epoch);
      this.commitRemote(profileId, identity, epoch, page, page.hasMore ? [] : results);
      after = page.cursor;
      through = page.through;
      if (!page.hasMore) break;
    } while (true);
  }
  commitRemote(profileId, identity, epoch, incoming, results = []) {
    this.linkGuard(identity, epoch);
    const events = this.store.transaction((s) => {
      const link = s.links[profileId],
        old = allVisible(link),
        oldLibrary = library(link);
      for (const change of incoming.changes) applyChange(link, change);
      link.cursor = incoming.cursor;
      for (const result of results) {
        const operation = link.outbox.find((o) => o.id === result.id);
        if (!operation) continue;
        link.outbox = link.outbox.filter((o) => o.id !== result.id);
        if (!['applied', 'duplicate'].includes(result.status))
          link.rejected.push({ operation, code: result.code || result.status });
      }
      const next = allVisible(link),
        nextLibrary = library(link);
      return {
        link,
        storage: [...new Set([...Object.keys(old), ...Object.keys(next)])].map((ext) => [
          ext,
          difference(old[ext] || {}, next[ext] || {}),
        ]),
        library: Object.values(nextLibrary).filter(
          (e) => JSON.stringify(oldLibrary[e.extensionId]) !== JSON.stringify(e),
        ),
      };
    });
    for (const [extensionId, changes] of events.storage) {
      this.linkGuard(identity, epoch);
      if (events.link.settingsSync) this.emitStorage(profileId, events.link, extensionId, changes);
    }
    for (const extension of events.library) {
      this.linkGuard(identity, epoch);
      this.emitLibrary(profileId, events.link, extension);
    }
  }
  async syncProfile(profileId, link, epoch) {
    const identity = this.identity(profileId, link);
    await this.pull(profileId, link, identity, epoch);
    this.linkGuard(identity, epoch);
    for (;;) {
      this.linkGuard(identity, epoch);
      const current = this.store.read().links[profileId];
      const operations = [];
      let bytes = Buffer.byteLength(JSON.stringify({ epoch: link.epoch, operations: [] }));
      for (const operation of current.outbox.slice(0, 100)) {
        const size = Buffer.byteLength(JSON.stringify(operation)) + 1;
        if (operations.length && bytes + size > 512 * 1024) break;
        operations.push(operation);
        bytes += size;
      }
      if (!operations.length) break;
      const result = await this.request(`/datasets/${encodeURIComponent(link.datasetId)}/operations`, {
        method: 'POST',
        body: { epoch: link.epoch, operations },
        epoch,
        profileId,
        scopeGuard: () => this.linkGuard(identity, epoch),
      });
      this.linkGuard(identity, epoch);
      if (
        !Array.isArray(result.results) ||
        result.results.length !== operations.length ||
        result.results.some(
          (r, i) =>
            r.id !== operations[i].id || !['applied', 'duplicate', 'conflict', 'quota'].includes(r.status),
        )
      )
        throw new Error('Invalid synchronization acknowledgement.');
      await this.pull(profileId, this.store.read().links[profileId], identity, epoch, result.results);
      this.linkGuard(identity, epoch);
    }
    this.store.transaction((s) => {
      s.links[profileId].lastSync = Date.now();
    });
  }
  async syncNow() {
    if (this.running) return this.running;
    const epoch = this.epoch;
    const running = (async () => {
      if (!this.credentials) return this.status();
      try {
        await this.request('/account', { epoch });
        for (const [profile, link] of Object.entries(this.store.read().links)) {
          try {
            await this.syncProfile(profile, link, epoch);
          } catch (error) {
            if (epoch !== this.epoch || !this.isCurrentLink(this.identity(profile, link))) continue;
            if (error.status === 404 || error.code === 'epoch_changed') {
              await this.unlinkProfile(profile);
              this.state = 'dataset-removed';
            } else if (error.code !== 'cancelled') throw error;
          }
        }
        this.guard(epoch);
        this.failures = 0;
        if (this.state !== 'dataset-removed')
          this.state = this.status().profiles.some((p) => p.rejected.length) ? 'conflict' : 'connected';
      } catch (error) {
        if (error.code !== 'cancelled' && this.credentials && epoch === this.epoch) {
          this.state = 'offline';
          this.failures++;
        }
      }
      if (!this.closed) {
        this.notify();
        this.schedule(
          this.failures
            ? Math.min(300000, 5000 * 2 ** Math.min(this.failures - 1, 6)) * (0.9 + Math.random() * 0.2)
            : 30000,
        );
      }
      return this.closed ? null : this.status();
    })();
    this.running = running;
    try {
      return await running;
    } finally {
      if (this.running === running) this.running = null;
    }
  }
  schedule(delay) {
    clearTimeout(this.timer);
    if (!this.autoSync || this.closed || !this.credentials) return;
    this.timer = setTimeout(() => {
      this.syncNow().catch(() => {});
    }, delay);
    this.timer.unref?.();
  }
  close() {
    if (this.closed) return;
    this.invalidate();
    this.closed = true;
    this.credentials = null;
    this.store.close();
  }
}
module.exports = { SyncClient, endpointURL };
