'use strict';
const path = require('node:path');
const fs = require('node:fs/promises');
const files = require('node:fs');
const { ExtensionManager } = require('./manager.cjs');
const { ExtensionAPI } = require('./api.cjs');
const { ExtensionBridge } = require('./bridge.cjs');
const { SidePanelController } = require('./side-panel.cjs');
const { IdentityController } = require('./identity.cjs');
const { FontSettingsController } = require('./font-settings.cjs');
const { NativeMessagingBroker } = require('./native-messaging.cjs');
const { parseStoreId } = require('./packages.cjs');
const { matches, covers } = require('./permissions.cjs');
const { inspectManifest } = require('./catalog.cjs');

function publicRecord(record, capabilities = {}) {
  const version = record.pending || record.current,
    manifest = version?.manifest || {};
  let inspection = version?.inspection;
  try {
    inspection = inspectManifest(manifest, capabilities);
  } catch {
    /* Retain the recorded diagnostic for invalid legacy metadata. */
  }
  let grantedInspection = inspection;
  if (record.current) {
    try {
      grantedInspection = inspectManifest(record.current.manifest, capabilities);
    } catch {}
  }
  return {
    id: record.id,
    profileId: record.profileId,
    generation: record.generation,
    name: manifest.name || record.id,
    version: record.current?.manifest.version || manifest.version,
    pendingVersion: record.pending?.manifest.version || null,
    description: manifest.description || '',
    enabled: record.enabled,
    status: record.status,
    error: record.error ? 'This extension could not load. Review its compatibility or reinstall it.' : null,
    source: record.source.kind,
    publisherVerified: version?.verification.publisherVerified === true,
    compatible: inspection?.compatible === true,
    unsupported: inspection?.unsupported || [],
    grants: record.grants,
    requested: inspection?.required || { permissions: [], origins: [] },
    optional: inspection?.optional || { permissions: [], origins: [] },
    revocable: Object.fromEntries(
      ['permissions', 'origins'].map((kind) => [
        kind,
        (record.grants?.[kind] || []).filter(
          (value) =>
            !grantedInspection?.required[kind].includes(value) &&
            covers(grantedInspection?.optional[kind] || [], value, kind),
        ),
      ]),
    ),
    adapted: (version?.transformVersion || 0) > 0,
    requiresPageReload: record.requiresPageReload === true,
    canRollback: !!record.previous,
    userScriptsAvailable:
      capabilities.userScripts === true && record.grants?.permissions?.includes('userScripts'),
    userScriptsEnabled: record.userScriptsEnabled === true,
    hasOptions: !!(manifest.options_ui?.page || manifest.options_page),
    hasAction: !!(manifest.action || manifest.browser_action),
    hasSidePanel: !!manifest.side_panel || record.grants?.permissions?.includes('sidePanel'),
  };
}
function inputShortcut(input) {
  if (input.type !== 'keyDown' || input.isComposing || input.isAutoRepeat) return null;
  const key =
    input.key.length === 1
      ? input.key.toUpperCase()
      : { ' ': 'Space', ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right' }[
          input.key
        ] || input.key;
  return [
    ...(input.meta ? ['Command'] : []),
    ...(input.control ? ['Ctrl'] : []),
    ...(input.alt ? ['Alt'] : []),
    ...(input.shift ? ['Shift'] : []),
    key,
  ].join('+');
}

class ExtensionHost {
  constructor({
    root,
    getProfile,
    getProfiles,
    activeProfile,
    getSession,
    getWindow,
    browser,
    syncClient,
    publish,
    report,
    panelChanged = publish,
    browserShortcutClaimed,
    native = require('electron'),
  }) {
    Object.assign(this, {
      root,
      getProfile,
      getProfiles,
      activeProfile,
      getSession,
      getWindow,
      browser,
      syncClient,
      publish,
      report,
      native,
    });
    this.windows = new Set();
    this.guards = new Map();
    this.remoteRuns = new Map();
    this.localRuns = new Map();
    this.remoteErrors = new Map();
    this.barriers = new Map();
    this.restores = new Map();
    this.ready = false;
    this.closed = false;
    this.icons = new Map();
    this.migrated = new Set();
    this.notificationErrors = new Map();
    this.started = new Promise((resolve, reject) => {
      this.resolveStarted = resolve;
      this.rejectStarted = reject;
    });
    this.started.catch(() => {});
    const resolveExtension = (profile, id) => this.manager.resolveExtension(profile, id);
    this.bridge = new ExtensionBridge({
      resolveExtension,
      dispatch: (context, method, args) => this.api.call(context, method, args),
      onContextRevoked: (context) => {
        this.nativeMessaging?.revoke(context);
        this.identity?.revoke(context);
      },
      onError: (_error, { profileId, extensionId }) => {
        this.notificationErrors.set(this.key(profileId, extensionId), true);
        publish();
      },
    });
    this.manager = new ExtensionManager({
      root,
      getProfile,
      getSession,
      prepareSession: (session, profile) => this.bridge.attachSession(session, profile),
      captureOperationGuard: (profile, id) =>
        this.guards.get(this.key(profile, id)) || this.guards.get(this.key(profile, '*')) || (() => {}),
      confirmPermissions: (context) => this.confirm(context),
      onDeactivated: (context) => this.deactivated(context),
      onPermissionsChanged: (...args) => this.permissionsChanged(...args),
      onNativeLoaded: (profile) => this.fontSettings?.reconcile(profile),
      onChange: (profile) => {
        publish();
        this.fontSettings?.reconcile(profile).catch(report);
      },
    });
    this.nativeMessaging = new NativeMessagingBroker({
      approveHost: (review) => this.approveNativeHost(review),
      emit: (context, event) => this.bridge.emitNative(context, event),
    });
    this.identity = new IdentityController({ native, getSession, getProfile, resolveExtension });
    this.fontSettings = new FontSettingsController({
      ready: (context) => this.manager.whenReady(context.profileId, context.extensionId),
      getProfile,
      getSession,
      resolveExtension,
      listExtensions: (profile) => this.manager.list(profile),
      profilePath: (profile) => this.manager.profilePath(profile),
      emit: (profile, id, event, args) =>
        this.bridge.emit(profile, id, event, args, {
          filter: (context) =>
            context.kind !== 'content-script' && context.metadata.grants.permissions.includes('fontSettings'),
        }),
    });
    this.sidePanel = new SidePanelController({
      native,
      resolveExtension,
      getProfile,
      activeProfile,
      getSession,
      getWindow,
      getTab: (profile, id) => browser.tabs.get(profile, id, () => {}),
      activeTabId: (profile) => browser.activeTabId(profile),
      profilePath: (profile) => this.manager.profilePath(profile),
      changed: panelChanged,
    });
    this.api = new ExtensionAPI({
      browserShortcutClaimed,
      fontSettings: this.fontSettings,
      identity: this.identity,
      sidePanel: this.sidePanel,
      nativeMessaging: this.nativeMessaging,
      resolveExtension,
      grantActiveTab: (context, tabId) => this.grantActiveTab(context, tabId),
      listExtensions: (profile) => this.manager.list(profile),
      tabs: browser.tabs,
      windows: browser.windows,
      dialogs: {
        openView: (...args) => this.openView(...args),
        requestPermissions: (profile, id, details, guard) =>
          this.permissionDialog(profile, id, details, guard),
      },
      menus: {
        changed: (_profile, _id, _items, guard) => {
          guard();
          publish();
        },
      },
      onActionChanged: (_profile, _id, _tab, _state, guard) => {
        guard();
        publish();
      },
      storage: {
        call: (context, method, args) =>
          this.syncClient().callStorage(this.storageContext(context), method, args),
        canAccessStorage: (context) => this.syncClient().canAccessStorage(this.storageContext(context)),
      },
      changePermissions: (profile, id, grants, guard) => {
        guard();
        const epoch = this.syncClient().epoch;
        const ownership = () => {
          guard();
          if (this.activeProfile()?.id !== profile) throw new Error('The active profile changed.');
          this.syncClient().guard(epoch);
        };
        return this.operation(profile, id, ownership, () =>
          this.manager.changePermissions(profile, id, grants),
        );
      },
      changePermissionDelta: (profile, id, details, remove, guard) => {
        guard();
        const epoch = this.syncClient().epoch;
        const ownership = () => {
          guard();
          if (this.activeProfile()?.id !== profile) throw new Error('The active profile changed.');
          this.syncClient().guard(epoch);
        };
        return this.operation(profile, id, ownership, () =>
          this.manager.changePermissionDelta(profile, id, details, remove),
        );
      },
      emit: (profile, id, event, args) => {
        this.bridge.emit(profile, id, event, args);
        publish();
      },
    });
  }
  async grantActiveTab(context, tabId) {
    const epoch = this.syncClient().epoch;
    const guard = () => {
      this.api.guard(context);
      this.syncClient().guard(epoch);
      if (this.activeProfile()?.id !== context.profileId) throw new Error('The active profile changed.');
    };
    guard();
    if (!this.manager.capabilities(context.profileId).activeTab)
      throw new Error('Native activeTab unavailable');
    await this.getSession(context.profileId).extensions.grantZacroActiveTab(context.extensionId, tabId);
    try {
      guard();
    } catch (error) {
      // No granular native revoke hook exists in ABI v1. Compensate only this
      // still-living generation; never disable a replacement or another profile.
      if (
        this.manager.resolveExtension(context.profileId, context.extensionId)?.generation ===
        context.generation
      ) {
        try {
          await this.manager.disable(context.profileId, context.extensionId, { preservePages: true });
        } catch (failure) {
          this.report?.(failure);
        }
      }
      throw error;
    }
  }
  key(profile, id) {
    return JSON.stringify([profile, id]);
  }
  operation(profile, id, guard, action) {
    guard();
    const key = this.key(profile, id);
    this.guards.set(key, guard);
    try {
      return action();
    } finally {
      this.guards.delete(key);
    }
  }
  async restore(profileId, legacy = []) {
    if (this.getProfile(profileId)?.private) return;
    if (!this.restores.has(profileId))
      this.restores.set(
        profileId,
        this.manager.restore(profileId, { legacy }).then(() => this.manager.startUpdates(profileId)),
      );
    await this.restores.get(profileId);
    await this.fontSettings.reconcile(profileId);
  }
  async start(legacy) {
    try {
      await fs.mkdir(this.root, { recursive: true });
      const receipt = path.join(this.root, 'legacy-imports.json');
      try {
        if ((await fs.stat(receipt)).size > 1024 * 1024)
          throw new Error('Legacy migration records exceed their limit.');
        const data = JSON.parse(await fs.readFile(receipt, 'utf8'));
        if (
          data.version !== 1 ||
          !Array.isArray(data.imported) ||
          data.imported.some(
            (item) =>
              !Array.isArray(item) ||
              item.length !== 2 ||
              typeof item[0] !== 'string' ||
              item[0].length > 256 ||
              !/^[a-p]{32}$/.test(item[1]),
          )
        )
          throw new Error('Invalid legacy migration records.');
        this.migrated = new Set(data.imported.map((item) => JSON.stringify(item)));
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      for (const profile of this.getProfiles())
        if (!profile.private) {
          const candidates = legacy.filter(
            (item) =>
              item.profileId === profile.id && !this.migrated.has(this.key(profile.id, item.extensionId)),
          );
          await this.restore(profile.id, candidates);
          for (const item of candidates)
            if (/^[a-p]{32}$/.test(item.extensionId))
              this.migrated.add(this.key(profile.id, item.extensionId));
        }
      // The receipt survives removal and browser-state backup recovery. Do not
      // erase old recovery files or allow them to reimport a removed extension.
      const data = JSON.stringify({ version: 1, imported: [...this.migrated].map((key) => JSON.parse(key)) });
      if (Buffer.byteLength(data) > 1024 * 1024)
        throw new Error('Legacy migration records exceed their limit.');
      const temporary = receipt + '.tmp',
        handle = await fs.open(temporary, 'w', 0o600);
      try {
        await handle.writeFile(data);
        await handle.sync();
      } finally {
        await handle.close();
      }
      await fs.rename(temporary, receipt);
      if (process.platform !== 'win32') {
        const directory = await fs.open(this.root, 'r');
        try {
          await directory.sync();
        } finally {
          await directory.close();
        }
      }
      this.ready = true;
      this.resolveStarted();
      this.refreshRemote();
    } catch (error) {
      this.rejectStarted(error);
      throw error;
    }
  }
  storageContext(context) {
    const metadata = this.manager.resolveExtension(context.profileId, context.extensionId);
    if (!metadata?.enabled || metadata.generation !== context.generation)
      throw new Error('Extension context expired.');
    return {
      profileId: context.profileId,
      extensionId: context.extensionId,
      enabled: true,
      private: !!this.getProfile(context.profileId)?.private,
      trusted: context.kind !== 'content-script',
      permissions: metadata.grants.permissions,
    };
  }
  storageChanged(event) {
    if (event.linkId && !this.syncClient().isCurrentLink(event)) return;
    const epoch = this.syncClient().epoch;
    this.bridge.emit(event.profileId, event.extensionId, 'storage.onChanged', [event.changes, 'sync'], {
      filter: (context) => {
        try {
          return (
            this.syncClient().epoch === epoch &&
            (!event.linkId || this.syncClient().isCurrentLink(event)) &&
            this.syncClient().canAccessStorage(this.storageContext(context))
          );
        } catch {
          return false;
        }
      },
    });
  }
  portableLibrary(profileId) {
    return this.manager
      .list(profileId)
      .filter((record) => record.source.kind === 'chrome-web-store' && record.current)
      .map((record) => ({
        extensionId: record.id,
        source: { kind: 'web-store', id: record.id },
        state: record.enabled ? 'enabled' : 'disabled',
      }));
  }
  intents(profile) {
    try {
      return this.syncClient()?.extensionIntents(profile) || [];
    } catch {
      return [];
    }
  }
  currentIntent(identity) {
    return (
      this.syncClient().isCurrentLink(identity) &&
      this.intents(identity.profileId).some(
        (item) =>
          item.extension.extensionId === identity.extension.extensionId &&
          item.extension.generation === identity.extension.generation &&
          item.extension.state === identity.extension.state,
      )
    );
  }
  icon(record, action) {
    const version = record.current || record.pending;
    let source = action?.icon || version?.manifest.icons;
    if (source && typeof source === 'object')
      source = Object.entries(source).sort(
        (a, b) => Math.abs(Number(a[0]) - 32) - Math.abs(Number(b[0]) - 32),
      )[0]?.[1];
    if (typeof source !== 'string' || !version) return null;
    if (source.startsWith('data:image/png;base64,') && source.length < 2 * 1024 * 1024) {
      const image = this.native.nativeImage.createFromDataURL(source);
      return image.isEmpty() ? null : image.resize({ width: 32, height: 32 }).toDataURL();
    }
    const key = JSON.stringify([record.id, version.token, source]);
    if (this.icons.has(key)) return this.icons.get(key);
    let value = null;
    try {
      const url = new URL(source, `chrome-extension://${record.id}/`);
      if (url.protocol !== 'chrome-extension:' || url.hostname !== record.id) return null;
      const directory = this.manager.versionPath(record.profileId, version),
        filename = path.resolve(directory, '.' + decodeURIComponent(url.pathname));
      if (
        !filename.startsWith(directory + path.sep) ||
        !/\.(png|ico|jpe?g|webp)$/i.test(filename) ||
        files.statSync(filename).size > 1024 * 1024
      )
        return null;
      const image = this.native.nativeImage.createFromPath(filename);
      if (!image.isEmpty()) value = image.resize({ width: 32, height: 32 }).toDataURL();
    } catch {
      /* Invalid packaged images use the browser's generic icon. */
    }
    if (this.icons.size > 1000) this.icons.clear();
    this.icons.set(key, value);
    return value;
  }
  refreshRemote() {
    if (!this.ready || this.closed) return;
    for (const profile of this.getProfiles())
      if (!profile.private) {
        if (this.localRuns.get(profile.id)) continue;
        for (const intent of this.intents(profile.id)) {
          const { extension } = intent,
            key = this.key(profile.id, extension.extensionId);
          const running = this.remoteRuns.get(key);
          const failed = this.remoteErrors.get(key);
          if (failed && !this.currentIntent(failed.identity)) this.remoteErrors.delete(key);
          if (running || this.remoteErrors.has(key)) continue;
          const record = this.manager.list(profile.id).find((item) => item.id === extension.extensionId);
          // A new installation requires a local review. Its durable cloud intent
          // remains visible even after restarting or temporarily losing the network.
          if (!record || record.source.kind !== 'chrome-web-store') continue;
          const action =
            extension.state === 'removed'
              ? 'remove'
              : extension.state === 'disabled' && record.enabled
                ? 'disable'
                : extension.state === 'enabled' &&
                    record.current &&
                    !record.enabled &&
                    record.status === 'disabled'
                  ? 'enable'
                  : null;
          if (!action) continue;
          const guard = () => {
            if (this.closed || !this.currentIntent(intent))
              throw new Error('The synchronization link or extension intent changed.');
          };
          this.remoteRuns.set(key, true);
          const run = this.operation(profile.id, record.id, guard, () =>
            this.manager[action](profile.id, record.id),
          );
          this.remoteRuns.set(key, run);
          run
            .then(() => this.remoteErrors.delete(key))
            .catch((error) => {
              if (this.currentIntent(intent))
                this.remoteErrors.set(key, {
                  identity: intent,
                  message: String(error.message).slice(0, 500),
                });
            })
            .finally(() => {
              if (this.remoteRuns.get(key) === run) this.remoteRuns.delete(key);
              this.publish();
            });
        }
      }
  }
  snapshot(profileId) {
    if (!profileId || this.getProfile(profileId)?.private) return [];
    const intents = this.intents(profileId),
      records = this.manager.list(profileId);
    const result = records.map((record) => {
      const value = publicRecord(record, this.manager.capabilities(profileId)),
        intent = intents.find((item) => item.extension.extensionId === record.id);
      value.syncState =
        record.source.kind !== 'chrome-web-store'
          ? 'local-only'
          : intent
            ? intent.extension.state
            : 'not-linked';
      value.syncError = this.remoteErrors.has(this.key(profileId, record.id))
        ? 'This device could not apply the library change. Retry after checking the extension permissions.'
        : null;
      value.notificationError = this.notificationErrors.has(this.key(profileId, record.id))
        ? 'Some extension notifications could not be delivered. Reload the extension to reconnect.'
        : null;
      if (record.enabled) {
        try {
          value.action = this.api.actionState(profileId, record.id, this.browser.activeTabId(profileId));
          value.commands = this.api.commandsState(profileId, record.id);
        } catch {}
      }
      value.iconData = this.icon(record, value.action);
      return value;
    });
    for (const intent of intents)
      if (
        intent.extension.state !== 'removed' &&
        !records.some((record) => record.id === intent.extension.extensionId)
      )
        result.push({
          id: intent.extension.extensionId,
          profileId,
          name: intent.extension.extensionId,
          enabled: false,
          status: 'remote-pending',
          source: 'chrome-web-store',
          syncState: intent.extension.state,
          grants: { permissions: [], origins: [] },
          unsupported: [],
          hasAction: false,
          userScriptsAvailable: false,
          userScriptsEnabled: false,
          hasOptions: false,
        });
    return result;
  }
  async confirm(context) {
    if (context.signal.aborted || this.activeProfile()?.id !== context.profileId) return false;
    const { response } = await this.native.dialog.showMessageBox(this.getWindow(), {
      type: 'question',
      title: 'Review extension permissions',
      message: `${context.manifest.name} ${context.manifest.version}`,
      detail: `Profile: ${context.profile.name}\nSource: ${context.source.kind === 'chrome-web-store' ? 'Chrome Web Store · verified publisher proof' : 'Local folder · only on this device'}\n\nRequested access:\n${[...context.inspection.required.permissions, ...context.inspection.required.origins].join('\n') || 'No declared permissions'}\n\nZacro supports the documented subset of extension APIs. A managed copy receives the compatibility adapter.`,
      buttons: ['Cancel', 'Allow and install'],
      defaultId: 0,
      cancelId: 0,
    });
    return response === 1 && !context.signal.aborted && this.activeProfile()?.id === context.profileId;
  }
  permissionsChanged(profileId, extensionId, { before, after }) {
    if (before.permissions.includes('nativeMessaging') && !after.permissions.includes('nativeMessaging'))
      this.nativeMessaging.revoke({ profileId, extensionId });
  }
  async approveNativeHost(review) {
    const current = () => {
      const profile = this.getProfile(review.profileId);
      const metadata = this.manager.resolveExtension(review.profileId, review.extensionId);
      if (
        this.closed ||
        !profile ||
        profile.private ||
        this.activeProfile()?.id !== review.profileId ||
        !metadata?.enabled ||
        metadata.generation !== review.generation ||
        !metadata.grants.permissions.includes('nativeMessaging')
      )
        throw new Error('Native messaging review expired');
      return { profile, metadata };
    };
    try {
      const { profile, metadata } = current();
      const { response } = await this.native.dialog.showMessageBox(this.getWindow(), {
        type: 'warning',
        title: 'Allow native application access?',
        message: `${metadata.manifest.name} wants to connect to ${review.name}`,
        detail: `Profile: ${profile.name || profile.id}\nRegistered manifest: ${review.registeredManifestPath}\nCanonical manifest: ${review.manifestPath}\nManifest SHA-256: ${review.manifestSha256}\nRegistered executable: ${review.registeredExecutablePath}\nCanonical executable: ${review.executablePath}\nExecutable SHA-256: ${review.executableSha256}\n\nThis external application runs under your OS account and can access files and the network. Allow only an application you trust. Approval applies only while these exact host files remain unchanged.`,
        buttons: ['Cancel', 'Allow host'],
        defaultId: 0,
        cancelId: 0,
      });
      current();
      return response === 1;
    } catch {
      return false;
    }
  }
  async permissionDialog(profile, id, details, guard) {
    guard();
    const epoch = this.syncClient().epoch;
    if (this.activeProfile()?.id !== profile) return false;
    const { response } = await this.native.dialog.showMessageBox(this.getWindow(), {
      type: 'question',
      title: 'Additional extension access',
      message: `Allow additional access for ${this.snapshot(profile).find((item) => item.id === id)?.name || id}?`,
      detail: [...details.permissions, ...details.origins].join('\n'),
      buttons: ['Cancel', 'Allow'],
      defaultId: 0,
      cancelId: 0,
    });
    guard();
    this.syncClient().guard(epoch);
    return response === 1 && this.activeProfile()?.id === profile;
  }
  pendingPageReloads(profileId) {
    const warnings = new Map();
    for (const [key, documents] of this.barriers) {
      const pending = documents.filter(
        ({ entry, epoch }) => !entry.contents.isDestroyed() && entry.documentEpoch === epoch,
      );
      if (pending.length) this.barriers.set(key, pending);
      else this.barriers.delete(key);
      if (JSON.parse(key)[0] !== profileId) continue;
      for (const { entry, epoch } of pending)
        warnings.set(entry.contents.id, {
          tabId: entry.tabId || null,
          documentId: entry.contents.id,
          documentEpoch: epoch,
          title: entry.contents.getTitle() || 'Open page',
        });
    }
    return [...warnings.values()];
  }
  async reloadPendingPages(profileId, target, guard) {
    this.pendingPageReloads(profileId);
    const seen = new Set();
    for (const [key, documents] of this.barriers) {
      if (JSON.parse(key)[0] !== profileId) continue;
      for (const { entry, epoch } of documents) {
        guard();
        if (
          seen.has(entry) ||
          entry.contents.isDestroyed() ||
          entry.documentEpoch !== epoch ||
          (target.tabId !== undefined && entry.tabId !== target.tabId) ||
          (target.documentId !== undefined && entry.contents.id !== target.documentId) ||
          (target.documentEpoch !== undefined && epoch !== target.documentEpoch)
        )
          continue;
        seen.add(entry);
        await this.browser.reloadDocument(entry);
      }
    }
    guard();
    const pending = this.pendingPageReloads(profileId);
    this.publish();
    return pending;
  }
  async deactivated({ profileId, extensionId, reason }) {
    this.nativeMessaging?.revoke({ profileId, extensionId });
    this.identity?.revoke({ profileId, extensionId });
    this.sidePanel?.revoke(profileId, extensionId, reason === 'remove');
    this.closeViews(profileId, extensionId);
    await this.fontSettings?.reconcile(profileId);
    const key = this.key(profileId, extensionId);
    this.notificationErrors.delete(key);
    let documents = this.barriers.get(key) || [];
    if (reason !== 'verify-reload')
      for (const entry of this.browser.documents(profileId))
        if (!documents.some((item) => item.entry === entry && item.epoch === entry.documentEpoch))
          documents.push({ entry, epoch: entry.documentEpoch });
    const pending = () =>
      documents.filter(({ entry, epoch }) => !entry.contents.isDestroyed() && entry.documentEpoch === epoch);
    documents = pending();
    this.barriers.set(key, documents);
    if (documents.length && this.activeProfile()?.id === profileId && !this.remoteRuns.has(key)) {
      const answer = await this.native.dialog.showMessageBox(this.getWindow(), {
        type: 'question',
        title: 'Reload pages to finish changing extension access',
        message: 'Scripts already running in open pages may continue until those pages reload.',
        detail:
          'Reload now? Pages with unsaved changes will ask before leaving. If you keep them open, reduced permissions remain pending and the extension stays disabled.',
        buttons: ['Keep pages open', 'Reload pages'],
        defaultId: 0,
        cancelId: 0,
      });
      if (answer.response === 1 && this.activeProfile()?.id === profileId)
        for (const { entry, epoch } of pending()) {
          if (entry.documentEpoch === epoch && !entry.contents.isDestroyed())
            await this.browser.reloadDocument(entry);
        }
    }
    documents = pending();
    this.barriers.set(key, documents);
    return { requiresPageReload: documents.length > 0 };
  }
  async openView(profileId, id, details, guard) {
    guard();
    if (this.activeProfile()?.id !== profileId)
      throw new Error('Activate this profile to open its extension.');
    const url = new URL(details.url);
    if (
      url.protocol !== 'chrome-extension:' ||
      url.hostname !== id ||
      url.pathname === '/zacro-compat-transport.html'
    )
      throw new Error('Invalid extension page.');
    if (details.kind === 'action')
      for (const item of this.windows)
        if (item.profileId === profileId && item.kind === 'action' && !item.window.isDestroyed())
          item.window.destroy();
    const { BrowserWindow } = this.native;
    const view = new BrowserWindow({
      parent: this.getWindow(),
      width: details.kind === 'action' ? 420 : 850,
      height: details.kind === 'action' ? 540 : 650,
      show: false,
      title: this.snapshot(profileId).find((item) => item.id === id)?.name || 'Extension',
      webPreferences: {
        session: this.getSession(profileId),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        webSecurity: true,
      },
    });
    const entry = { window: view, profileId, id, kind: details.kind, generation: details.generation };
    this.windows.add(entry);
    view.on('closed', () => this.windows.delete(entry));
    const validURL = (value) => {
      try {
        const target = new URL(value);
        return (
          target.protocol === 'chrome-extension:' &&
          target.hostname === id &&
          target.pathname !== '/zacro-compat-transport.html'
        );
      } catch {
        return false;
      }
    };
    if (this.manager.resolveExtension(profileId, id)?.grants.permissions.includes('sidePanel'))
      this.sidePanel.trackInput(view.webContents, this.api.context(profileId, id));
    view.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    view.webContents.on('will-navigate', (event, target) => {
      if (!validURL(target)) event.preventDefault();
    });
    view.webContents.on('will-redirect', (event, target) => {
      if (!validURL(target)) event.preventDefault();
    });
    try {
      await view.loadURL(url.href);
      guard();
      if (this.activeProfile()?.id !== profileId) throw new Error('The profile changed.');
      view.show();
    } catch (error) {
      if (!view.isDestroyed()) view.destroy();
      throw error;
    }
  }
  closeViews(profile, id) {
    for (const item of this.windows)
      if ((!profile || item.profileId === profile) && (!id || item.id === id))
        if (!item.window.isDestroyed()) item.window.destroy();
  }
  profileChanged() {
    this.sidePanel?.destroy();
    this.sidePanel?.gestures.clear();
    this.closeViews();
  }
  async handle(action, payload) {
    const profileId = this.activeProfile()?.id;
    this.localRuns.set(profileId, (this.localRuns.get(profileId) || 0) + 1);
    try {
      return await this.handleLocal(action, payload);
    } finally {
      const count = this.localRuns.get(profileId) - 1;
      if (count) this.localRuns.set(profileId, count);
      else this.localRuns.delete(profileId);
      this.refreshRemote();
    }
  }
  async handleLocal(action, payload) {
    const profile = this.activeProfile();
    const epoch = this.syncClient().epoch;
    if (!profile || profile.private) throw new Error('Extensions are unavailable in private profiles.');
    const guard = () => {
      this.syncClient().guard(epoch);
      if (
        this.closed ||
        this.activeProfile()?.id !== profile.id ||
        (payload.profileId && payload.profileId !== profile.id)
      )
        throw new Error('The active profile changed. Open extension controls again.');
    };
    guard();
    await this.started;
    guard();
    await this.restore(profile.id);
    guard();
    if (action === 'extension:panel-close') {
      this.sidePanel.destroy();
      return null;
    }
    if (action === 'extension:reload-pages') return this.reloadPendingPages(profile.id, payload, guard);
    if (action === 'extension:check-updates') {
      await this.manager.checkUpdates(profile.id, { force: true });
      return null;
    }
    if (action === 'extension:retry-sync') {
      this.remoteErrors.delete(this.key(profile.id, payload.id));
      this.refreshRemote();
      return null;
    }
    let id = payload.id,
      result,
      previous;
    if (action === 'extension:install') {
      const chosen = await this.native.dialog.showOpenDialog(this.getWindow(), {
        title: 'Choose an unpacked extension folder',
        properties: ['openDirectory'],
      });
      guard();
      if (chosen.canceled || !chosen.filePaths[0]) return null;
      const folder = await fs.realpath(chosen.filePaths[0]);
      guard();
      const managedRoot = await fs.realpath(this.root);
      guard();
      if (
        folder === managedRoot ||
        folder.startsWith(managedRoot + path.sep) ||
        managedRoot.startsWith(folder + path.sep)
      )
        throw new Error('Choose the extension folder itself, outside the managed extension directory.');
      result = await this.operation(profile.id, '*', guard, () =>
        this.manager.installLocal(profile.id, folder),
      );
      id = result.id;
    } else {
      if (action === 'extension:install-store') id = parseStoreId(payload.url);
      if (!/^[a-p]{32}$/.test(id || '')) throw new Error('Invalid extension ID.');
      previous = this.manager.list(profile.id).find((item) => item.id === id);
      if (payload.generation && previous?.generation !== payload.generation)
        throw new Error('This extension changed. Open its controls again.');
      const intent = this.intents(profile.id).find((item) => item.extension.extensionId === id);
      const operationGuard = () => {
        guard();
        if (
          (action === 'extension:review-remote' ||
            (action === 'extension:approve' && !previous?.current && intent)) &&
          (!intent || !this.currentIntent(intent))
        )
          throw new Error('The remote installation request changed.');
      };
      result = await this.operation(profile.id, id, operationGuard, () => {
        switch (action) {
          case 'extension:install-store':
          case 'extension:review-remote':
            return this.manager.installStore(profile.id, id);
          case 'extension:toggle':
            return previous?.enabled
              ? this.manager.disable(profile.id, id)
              : this.manager.enable(profile.id, id);
          case 'extension:user-scripts-toggle':
            return this.manager.setUserScriptsEnabled(profile.id, id, previous?.userScriptsEnabled !== true);
          case 'extension:remove':
            return this.manager.remove(profile.id, id);
          case 'extension:update':
            return this.manager.update(profile.id, id);
          case 'extension:approve':
            return this.manager.approve(profile.id, id);
          case 'extension:rollback':
            return this.manager.rollback(profile.id, id);
          case 'extension:revoke-permission': {
            if (
              !previous ||
              typeof payload.permission !== 'string' ||
              !['permissions', 'origins'].includes(payload.permissionKind)
            )
              throw new Error('Invalid optional permission.');
            const grants = structuredClone(previous.grants);
            grants[payload.permissionKind] = grants[payload.permissionKind].filter(
              (value) => value !== payload.permission,
            );
            return this.manager.changePermissions(profile.id, id, grants);
          }
          case 'extension:panel-open': {
            const context = this.api.context(profile.id, id);
            this.sidePanel.recordGesture(context);
            const tabId = this.browser.activeTabId(profile.id);
            return this.sidePanel.call(context, 'open', [
              tabId === undefined ? { windowId: this.getWindow().id } : { tabId },
            ]);
          }
          case 'extension:action':
            return this.api.activateAction(profile.id, id, this.browser.activeTabId(profile.id));
          case 'extension:options':
            return this.api.call(this.api.context(profile.id, id), 'runtime.openOptionsPage', []);
          default:
            throw new Error('Unsupported extension action.');
        }
      });
      guard();
      if (
        ['extension:review-remote', 'extension:approve'].includes(action) &&
        !previous?.current &&
        intent?.extension.state === 'disabled' &&
        result?.enabled
      )
        result = await this.operation(profile.id, id, operationGuard, () =>
          this.manager.disable(profile.id, id),
        );
    }
    guard();
    const record = this.manager.list(profile.id).find((item) => item.id === id);
    if (
      (record || previous)?.source.kind === 'chrome-web-store' &&
      ['extension:install-store', 'extension:toggle', 'extension:remove', 'extension:approve'].includes(
        action,
      ) &&
      // Reviewing update permissions does not change the user's cloud intent.
      // A local permission reduction may temporarily disable execution until
      // page reload, without asking every other device to disable the extension.
      !(action === 'extension:approve' && previous?.current)
    ) {
      const state =
        action === 'extension:remove'
          ? 'removed'
          : record?.current
            ? record.enabled
              ? 'enabled'
              : 'disabled'
            : null;
      if (state)
        await this.syncClient().queueExtension({
          profileId: profile.id,
          extensionId: id,
          source: { kind: 'web-store', id },
          state,
        });
    }
    this.publish();
    return record ? publicRecord(record, this.manager.capabilities(profile.id)) : null;
  }
  shortcut(input) {
    const shortcut = inputShortcut(input),
      profile = this.activeProfile();
    if (!shortcut || !profile || profile.private) return false;
    for (const record of this.manager.list(profile.id))
      if (record.enabled) {
        const command = this.api
          .commandsState(profile.id, record.id)
          .find((item) => item.shortcut === shortcut && item.status === 'assigned');
        if (command) {
          const generation = this.manager.resolveExtension(profile.id, record.id)?.generation;
          if (generation !== record.generation) return false;
          this.api
            .dispatchCommand(profile.id, record.id, command.name, this.browser.activeTabId(profile.id))
            .catch(this.report);
          return true;
        }
      }
    return false;
  }
  menu(entry, params) {
    if (this.activeProfile()?.id !== entry.profileId) return [];
    const result = [];
    for (const record of this.manager.list(entry.profileId))
      if (record.enabled) {
        const generation = this.manager.resolveExtension(entry.profileId, record.id)?.generation;
        const items = this.api
          .menuItems(entry.profileId, record.id)
          .filter(
            (item) =>
              item.visible !== false &&
              (!item.documentUrlPatterns ||
                item.documentUrlPatterns.some((pattern) => matches(pattern, entry.contents.getURL()))) &&
              (!item.targetUrlPatterns ||
                item.targetUrlPatterns.some((pattern) =>
                  matches(pattern, params.linkURL || params.srcURL),
                )) &&
              (item.contexts || ['page']).some(
                (context) =>
                  context === 'all' ||
                  context === 'page' ||
                  (context === 'selection' && params.selectionText) ||
                  (context === 'link' && params.linkURL) ||
                  (context === 'editable' && params.isEditable) ||
                  context === params.mediaType,
              ),
          );
        const build = (parentId) =>
          items
            .filter((item) => item.parentId === parentId)
            .map((item) => {
              const children = build(item.id);
              return {
                type: item.type || 'normal',
                label: String(item.title || '').replaceAll('%s', (params.selectionText || '').slice(0, 200)),
                enabled: item.enabled !== false,
                ...(item.type === 'checkbox' || item.type === 'radio'
                  ? { checked: item.checked === true }
                  : {}),
                ...(children.length
                  ? { submenu: children }
                  : {
                      click: () => {
                        if (
                          this.activeProfile()?.id !== entry.profileId ||
                          this.manager.resolveExtension(entry.profileId, record.id)?.generation !==
                            generation ||
                          entry.contents.isDestroyed()
                        )
                          return;
                        this.api
                          .clickMenu(
                            entry.profileId,
                            record.id,
                            item.id,
                            {
                              pageUrl: entry.contents.getURL(),
                              linkUrl: params.linkURL || undefined,
                              selectionText: params.selectionText || undefined,
                              editable: !!params.isEditable,
                              wasChecked: item.checked,
                              checked: !item.checked,
                            },
                            entry.contents.id,
                          )
                          .catch(this.report);
                      },
                    }),
              };
            });
        const submenu = build(undefined);
        if (submenu.length) result.push({ label: (record.current || record.pending).manifest.name, submenu });
      }
    return result;
  }
  async removeProfile(profile) {
    this.fontSettings?.forgetProfile(profile);
    this.sidePanel?.revokeProfile(profile);
    this.nativeMessaging?.revoke({ profileId: profile });
    this.identity?.revoke({ profileId: profile });
    this.closeViews(profile);
    await this.manager.invalidateProfile(profile);
    this.fontSettings?.forgetProfile(profile);
    this.restores.delete(profile);
    for (const key of this.barriers.keys()) if (JSON.parse(key)[0] === profile) this.barriers.delete(key);
    await fs.rm(this.manager.profilePath(profile), { recursive: true, force: true });
  }
  async close() {
    this.closed = true;
    this.fontSettings?.close();
    this.nativeMessaging?.dispose();
    this.identity?.dispose();
    this.sidePanel?.close();
    this.closeViews();
    this.bridge.close();
    await this.manager.close();
  }
}
module.exports = { ExtensionHost, publicRecord, inputShortcut };
