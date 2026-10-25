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
function required(manifest) {
  return (manifest.permissions || []).some((permission) =>
    ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess', 'alarms', 'offscreen'].includes(
      permission,
    ),
  );
}
class NativeServices {
  constructor({ session, id, manifest, filename, persist, guard }) {
    Object.assign(this, { session, id, manifest, filename, persist, guard });
    this.closed = false;
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
        if (!(owner.manifest.permissions || []).includes('alarms'))
          throw new Error('Native alarm permission unavailable');
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
        const deliver = deliveries.get(owner.session);
        if (!deliver) throw new Error('Native alarm delivery unavailable');
        deliver(owner.id, 'alarms.onAlarm', [alarm]);
        await owner.checkpoint();
      });
      receiverInstalled = true;
    }
  }
  async initialize() {
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
        async ({ resources, state, enabled, permissions }) => {
          const dnr = chrome.declarativeNetRequest;
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
          if (dnr) {
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
          if (chrome.offscreen && (await chrome.offscreen.hasDocument()))
            await chrome.offscreen.closeDocument();
          if (chrome.alarms && state) {
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
          permissions: this.manifest.permissions || [],
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
  async snapshot() {
    this.guard();
    const state = await this.execute(
      async ({ resources }) => ({
        schema: 1,
        enabledRulesets: chrome.declarativeNetRequest
          ? await chrome.declarativeNetRequest.getEnabledRulesets()
          : [],
        dynamicRules: chrome.declarativeNetRequest
          ? await chrome.declarativeNetRequest.getDynamicRules()
          : [],
        alarms: chrome.alarms
          ? (await chrome.alarms.getAll()).filter((alarm) => alarm.persistAcrossSessions !== false)
          : [],
        disabledStaticRules: chrome.declarativeNetRequest
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
      { resources: this.manifest.declarative_net_request?.rule_resources || [] },
    );
    this.guard();
    state.knownRulesets = (this.manifest.declarative_net_request?.rule_resources || []).map(
      (resource) => resource.id,
    );
    this.persist(this.filename, state);
  }
  checkpoint() {
    const next = this.queue
      .catch(() => {})
      .then(async () => {
        await this.ready;
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
