'use strict';
// Chromium owns matching, DOM contexts and alarm delivery. This module owns only
// the load barrier and durable snapshots missing from Electron's unpacked loader.
const fs = require('node:fs');
const path = require('node:path');
const instances = new WeakMap();
const deliveries = new WeakMap();
const ALARM_CHANNEL = 'zacro:native-extension-alarm:v1';
let receiverInstalled = false;
const PAGE = 'zacro-native-services.html';
function reconcileRulesets(resources, state) {
  return resources
    .filter((resource) =>
      state?.knownRulesets?.includes(resource.id)
        ? state.enabledRulesets.includes(resource.id)
        : resource.enabled,
    )
    .map((resource) => resource.id);
}
function required(manifest, grants = manifest) {
  return (grants.permissions || []).some((permission) =>
    ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess', 'alarms', 'offscreen'].includes(
      permission,
    ),
  );
}
class NativeServices {
  constructor({ session, id, manifest, permissions = manifest.permissions || [], filename, persist, guard }) {
    Object.assign(this, { session, id, manifest, filename, persist, guard });
    this.permissions = [...permissions];
    this.closed = false;
    this.authorityRevision = 0;
    this.queue = Promise.resolve();
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.ready.catch(() => {});
    let byId = instances.get(session);
    if (!byId) instances.set(session, (byId = new Map()));
    byId.set(id, this);
    this.unloaded = (_event, extension) => {
      if (extension.id === id) this.close();
    };
    session.extensions.on('extension-unloaded', this.unloaded);
    if (!receiverInstalled) {
      const { ipcMain } = require('electron');
      ipcMain.handle(ALARM_CHANNEL, async (event, value) => {
        const owner = [...(instances.get(event.sender.session)?.values() || [])].find(
          (controller) =>
            !controller.closed &&
            controller.window?.webContents === event.sender &&
            event.sender.mainFrame === event.senderFrame,
        );
        if (!owner || event.senderFrame.url !== `chrome-extension://${owner.id}/${PAGE}`)
          throw new Error('Not the owned native alarm receiver');
        owner.guard();
        if (!owner.permissions.includes('alarms')) throw new Error('Native alarm permission unavailable');
        if (
          !value ||
          typeof value.name !== 'string' ||
          value.name.length > 4096 ||
          !Number.isFinite(value.scheduledTime) ||
          value.scheduledTime < 0 ||
          (value.periodInMinutes !== undefined &&
            (!Number.isFinite(value.periodInMinutes) || value.periodInMinutes <= 0))
        )
          throw new Error('Invalid native alarm event');
        const revision = owner.authorityRevision;
        const alarm = {
          name: value.name,
          scheduledTime: value.scheduledTime,
          ...(value.periodInMinutes !== undefined ? { periodInMinutes: value.periodInMinutes } : {}),
          ...(typeof value.persistAcrossSessions === 'boolean'
            ? { persistAcrossSessions: value.persistAcrossSessions }
            : {}),
        };
        await owner.ready;
        owner.guard();
        owner.assertPermission('alarms');
        if (revision !== owner.authorityRevision) throw new Error('Native alarm authority changed');
        const deliver = deliveries.get(owner.session);
        if (!deliver) throw new Error('Native alarm delivery unavailable');
        deliver(owner.id, 'alarms.onAlarm', [alarm]);
        await owner.checkpoint();
      });
      receiverInstalled = true;
    }
  }
  assertPermission(group) {
    this.guard();
    if (
      this.closed ||
      !(group === 'declarativeNetRequest'
        ? this.permissions.some((permission) =>
            ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess'].includes(permission),
          )
        : ['alarms', 'offscreen'].includes(group) && this.permissions.includes(group))
    )
      throw new Error('Native service permission unavailable');
  }
  async reconfigure(permissions, apply) {
    const serviceGroups = (values) =>
      [
        ...new Set(
          values
            .filter((value) =>
              [
                'alarms',
                'offscreen',
                'declarativeNetRequest',
                'declarativeNetRequestWithHostAccess',
              ].includes(value),
            )
            .map((value) =>
              value === 'declarativeNetRequestWithHostAccess' ? 'declarativeNetRequest' : value,
            ),
        ),
      ].sort();
    const previousGroups = serviceGroups(this.permissions),
      nextGroups = serviceGroups(permissions);
    if (JSON.stringify(previousGroups) === JSON.stringify(nextGroups)) {
      const result = await apply();
      this.permissions = [...permissions];
      return result;
    }
    const previous = [...this.permissions],
      oldReady = this.ready,
      oldQueue = this.queue;
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.ready.catch(() => {});
    // New requests wait at the barrier, and queued native alarm events lose
    // authority immediately. The original extension caller stays alive.
    if (previous.includes('alarms') && !permissions.includes('alarms')) this.authorityRevision++;
    this.permissions = previous.filter((permission) => permissions.includes(permission));
    try {
      await oldReady;
      await oldQueue;
      this.guard();
      await this.execute(
        async ({ previous, next }) => {
          if (previous.includes('alarms') && !next.includes('alarms')) await chrome.alarms.clearAll();
          if (
            previous.includes('offscreen') &&
            !next.includes('offscreen') &&
            (await chrome.offscreen.hasDocument())
          )
            await chrome.offscreen.closeDocument();
          const hasDnr = (values) =>
            values.some((value) =>
              ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess'].includes(value),
            );
          if (hasDnr(previous) && !hasDnr(next)) {
            const dnr = chrome.declarativeNetRequest;
            await dnr.updateDynamicRules({
              removeRuleIds: (await dnr.getDynamicRules()).map((rule) => rule.id),
            });
            await dnr.updateSessionRules({
              removeRuleIds: (await dnr.getSessionRules()).map((rule) => rule.id),
            });
            await dnr.updateEnabledRulesets({ disableRulesetIds: await dnr.getEnabledRulesets() });
          }
        },
        { previous, next: permissions },
      );
      await this.snapshot(previous);
      if (this.window && !this.window.isDestroyed()) this.window.destroy();
      const result = await apply();
      this.permissions = [...permissions];
      this.guard();
      await this.initialize({ added: nextGroups.filter((group) => !previousGroups.includes(group)) });
      return result;
    } catch (error) {
      this.rejectReady(error);
      this.close();
      throw error;
    }
  }
  async initialize({ added = null } = {}) {
    try {
      const { BrowserWindow } = require('electron');
      let state = null;
      try {
        const bytes = fs.readFileSync(this.filename);
        if (bytes.length > 16 * 1024 * 1024) throw new Error('Native extension state is too large');
        state = JSON.parse(bytes);
        if (
          state.schema !== 1 ||
          !Array.isArray(state.knownRulesets) ||
          !Array.isArray(state.enabledRulesets) ||
          !Array.isArray(state.dynamicRules) ||
          !Array.isArray(state.alarms)
        )
          throw new Error('Invalid native extension state');
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      this.guard();
      const window = (this.window = new BrowserWindow({
        show: false,
        webPreferences: {
          session: this.session,
          sandbox: true,
          contextIsolation: true,
          nodeIntegration: false,
          preload: path.join(__dirname, 'native-services-preload.cjs'),
        },
      }));
      const url = `chrome-extension://${this.id}/${PAGE}`;
      window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
      window.webContents.on('will-navigate', (event) => event.preventDefault());
      window.webContents.on('did-navigate', (_event, destination) => {
        if (destination !== url) this.close();
      });
      await window.loadURL(url);
      this.guard();
      const resources = this.manifest.declarative_net_request?.rule_resources || [];
      await this.execute(
        async ({ resources, state, enabled, permissions, added }) => {
          const dnr = permissions.some((permission) =>
            ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess'].includes(permission),
          )
            ? chrome.declarativeNetRequest
            : null;
          if (
            permissions.some(
              (permission) =>
                permission === 'declarativeNetRequest' ||
                permission === 'declarativeNetRequestWithHostAccess',
            ) &&
            !dnr?.updateDynamicRules
          )
            throw new Error('Native declarative network rules unavailable in this runtime');
          if (permissions.includes('alarms') && !chrome.alarms?.create)
            throw new Error('Native alarms unavailable in this runtime');
          if (permissions.includes('offscreen') && !chrome.offscreen?.createDocument)
            throw new Error('Native offscreen documents unavailable in this runtime');
          if (dnr && (!added || added.includes('declarativeNetRequest'))) {
            const sessions = await dnr.getSessionRules();
            if (sessions.length)
              await dnr.updateSessionRules({ removeRuleIds: sessions.map((rule) => rule.id) });
            if (state) {
              const dynamic = await dnr.getDynamicRules();
              await dnr.updateDynamicRules({
                removeRuleIds: dynamic.map((rule) => rule.id),
                addRules: state.dynamicRules,
              });
            }
            if (resources.length)
              await dnr.updateEnabledRulesets({
                enableRulesetIds: enabled,
                disableRulesetIds: resources
                  .map((resource) => resource.id)
                  .filter((id) => !enabled.includes(id)),
              });
            for (const resource of resources) {
              const previous = await dnr.getDisabledRuleIds({ rulesetId: resource.id });
              await dnr.updateStaticRules({
                rulesetId: resource.id,
                enableRuleIds: previous,
                disableRuleIds: state?.disabledStaticRules?.[resource.id] || [],
              });
            }
          }
          if (
            (!added || added.includes('offscreen')) &&
            permissions.includes('offscreen') &&
            chrome.offscreen &&
            (await chrome.offscreen.hasDocument())
          )
            await chrome.offscreen.closeDocument();
          if (
            (!added || added.includes('alarms')) &&
            permissions.includes('alarms') &&
            chrome.alarms &&
            state
          ) {
            await chrome.alarms.clearAll();
            for (const alarm of state.alarms) {
              // Do not replay already elapsed one-shots after restart. Recurring
              // alarms resume natively with at most one immediate event.
              if (!alarm.periodInMinutes && alarm.scheduledTime <= Date.now()) continue;
              await chrome.alarms.create(alarm.name, {
                when: Math.max(Date.now(), alarm.scheduledTime),
                ...(alarm.periodInMinutes ? { periodInMinutes: alarm.periodInMinutes } : {}),
                persistAcrossSessions: true,
              });
            }
          }
        },
        {
          resources,
          state,
          enabled: reconcileRulesets(resources, state),
          permissions: this.permissions,
          added,
        },
      );
      await this.snapshot();
      this.resolveReady();
    } catch (error) {
      this.rejectReady(error);
      this.close();
      throw error;
    }
  }
  execute(fn, args = {}) {
    if (this.closed || this.window?.isDestroyed())
      return Promise.reject(new Error('Native extension lifecycle closed'));
    return this.window.webContents.executeJavaScript(`(${fn.toString()})(${JSON.stringify(args)})`);
  }
  async snapshot(permissions = this.permissions) {
    this.guard();
    const state = await this.execute(
      async ({ resources, permissions }) => ({
        schema: 1,
        enabledRulesets:
          permissions.some((p) => p.startsWith('declarativeNetRequest')) && chrome.declarativeNetRequest
            ? await chrome.declarativeNetRequest.getEnabledRulesets()
            : [],
        dynamicRules:
          permissions.some((p) => p.startsWith('declarativeNetRequest')) && chrome.declarativeNetRequest
            ? await chrome.declarativeNetRequest.getDynamicRules()
            : [],
        alarms:
          permissions.includes('alarms') && chrome.alarms
            ? (await chrome.alarms.getAll()).filter((alarm) => alarm.persistAcrossSessions !== false)
            : [],
        disabledStaticRules:
          permissions.some((p) => p.startsWith('declarativeNetRequest')) && chrome.declarativeNetRequest
            ? Object.fromEntries(
                await Promise.all(
                  resources.map(async (resource) => [
                    resource.id,
                    await chrome.declarativeNetRequest.getDisabledRuleIds({ rulesetId: resource.id }),
                  ]),
                ),
              )
            : {},
      }),
      { resources: this.manifest.declarative_net_request?.rule_resources || [], permissions },
    );
    this.guard();
    state.knownRulesets = permissions.some((permission) => permission.startsWith('declarativeNetRequest'))
      ? (this.manifest.declarative_net_request?.rule_resources || []).map((resource) => resource.id)
      : [];
    this.persist(this.filename, state);
  }
  checkpoint() {
    const ready = this.ready;
    const next = this.queue
      .catch(() => {})
      .then(async () => {
        await ready;
        await this.snapshot();
      });
    this.queue = next;
    return next;
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    this.rejectReady(new Error('Native extension lifecycle closed'));
    this.session.extensions.off('extension-unloaded', this.unloaded);
    if (instances.get(this.session)?.get(this.id) === this) instances.get(this.session).delete(this.id);
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
  }
}
function getNativeServices(session, id) {
  return instances.get(session)?.get(id);
}
function registerNativeEventDelivery(session, deliver) {
  if (deliver) deliveries.set(session, deliver);
  else deliveries.delete(session);
}
module.exports = {
  NativeServices,
  getNativeServices,
  reconcileRulesets,
  needsNativeServices: required,
  NATIVE_SERVICES_PAGE: PAGE,
  registerNativeEventDelivery,
};
