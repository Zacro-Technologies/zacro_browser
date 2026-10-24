'use strict';
const { ipcMain, BrowserWindow, webContents } = require('electron');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const CHANNEL = 'zacro:extension-transport:v1';

function extensionId(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'chrome-extension:' && /^[a-p]{32}$/.test(parsed.hostname)
      ? parsed.hostname
      : null;
  } catch {
    return null;
  }
}

function permitsOrigin(pattern, url) {
  try {
    const target = new URL(url);
    if (!['http:', 'https:'].includes(target.protocol)) return false;
    if (pattern === '<all_urls>') return true;
    const match = /^(\*|https?):\/\/(\*|\*\.[^/]+|[^/]+)(\/.*)$/.exec(pattern);
    if (!match || (match[1] !== '*' && target.protocol !== match[1] + ':')) return false;
    const host = match[2];
    if (
      host !== '*' &&
      target.hostname !== host &&
      !(
        host.startsWith('*.') &&
        (target.hostname === host.slice(2) || target.hostname.endsWith(host.slice(1)))
      )
    )
      return false;
    const expression = match[3]
      .split('*')
      .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
      .join('.*');
    return new RegExp('^' + expression + '$').test(target.pathname + target.search);
  } catch {
    return false;
  }
}

class ExtensionBridge {
  constructor({ resolveExtension, dispatch }) {
    this.resolveExtension = resolveExtension;
    this.dispatch = dispatch;
    this.sessions = new Map();
    this.leases = new Map();
    this.origins = new Map();
    this.closed = false;
    ipcMain.handle(CHANNEL, (event, request) => this.handle(event, request));
  }

  attachSession(session, profileId) {
    if (this.closed || this.sessions.has(session) || typeof profileId !== 'string' || !profileId)
      throw new Error('Invalid session attachment');
    const entry = {
      profileId,
      epochs: new Map(),
      workers: new Set(),
      preloads: [],
      brokers: new Map(),
      revoked: new Set(),
    };
    this.sessions.set(session, entry);
    entry.unloaded = (_event, extension) => {
      entry.revoked.add(extension.id);
      entry.epochs.set(extension.id, (entry.epochs.get(extension.id) || 0) + 1);
      for (const [key, lease] of this.leases)
        if (lease.session === session && lease.extensionId === extension.id) this.leases.delete(key);
      for (const origin of this.origins.values())
        if (origin.session === session && origin.extensionId === extension.id) origin.revoke();
      const broker = entry.brokers.get(extension.id);
      entry.brokers.delete(extension.id);
      if (broker && !broker.isDestroyed()) broker.destroy();
    };
    entry.loaded = (_event, extension) => {
      entry.revoked.delete(extension.id);
      const broker = new BrowserWindow({
        show: false,
        webPreferences: {
          session,
          sandbox: true,
          contextIsolation: true,
          nodeIntegration: false,
          preload: path.join(__dirname, 'transport-preload.cjs'),
        },
      });
      entry.brokers.set(extension.id, broker);
      const contents = broker.webContents;
      const url = `chrome-extension://${extension.id}/zacro-compat-transport.html`;
      let navigating = false;
      contents.on('did-start-navigation', (_event, destination, _inPlace, isMainFrame) => {
        if (!isMainFrame) return;
        if (navigating || destination !== url) {
          if (!broker.isDestroyed()) broker.destroy();
        }
        navigating = true;
      });
      contents.setWindowOpenHandler(() => ({ action: 'deny' }));
      contents.on('will-navigate', (event) => {
        event.preventDefault();
        broker.destroy();
      });
      contents.on('render-process-gone', () => {
        if (!broker.isDestroyed()) broker.destroy();
      });
      contents.on('destroyed', () => {
        if (entry.brokers.get(extension.id) === broker) entry.brokers.delete(extension.id);
        for (const origin of this.origins.values()) if (origin.broker === broker) origin.revoke();
      });
      broker.loadURL(url).catch((error) => {
        console.error('Extension transport initialization failed:', error.message);
        if (!broker.isDestroyed()) broker.destroy();
      });
    };
    entry.started = ({ versionId, runningStatus }) => {
      if (!['starting', 'running'].includes(runningStatus)) return;
      const worker = session.serviceWorkers.getWorkerFromVersionID(versionId);
      if (!worker || entry.workers.has(worker)) return;
      entry.workers.add(worker);
      worker.ipc.handle(CHANNEL, (event, request) => this.handle(event, request));
    };
    session.extensions.on('extension-unloaded', entry.unloaded);
    session.extensions.on('extension-loaded', entry.loaded);
    session.serviceWorkers.on('running-status-changed', entry.started);
    for (const versionId of Object.keys(session.serviceWorkers.getAllRunning()))
      entry.started({ versionId: Number(versionId), runningStatus: 'running' });
    for (const [type, filename] of [
      ['frame', 'frame-preload.cjs'],
      ['service-worker', 'worker-preload.cjs'],
    ])
      entry.preloads.push(session.registerPreloadScript({ type, filePath: path.join(__dirname, filename) }));
  }

  brokerFor(context, event) {
    const broker = this.sessions.get(context.session)?.brokers.get(context.extensionId);
    if (
      !broker ||
      broker.isDestroyed() ||
      broker.webContents !== event.sender ||
      broker.webContents.mainFrame !== event.senderFrame ||
      context.url !== `chrome-extension://${context.extensionId}/zacro-compat-transport.html`
    )
      throw new Error('Not the registered extension transport');
    return broker;
  }

  bindOrigin(context, event, sender) {
    const broker = this.brokerFor(context, event);
    if (
      !sender ||
      sender.id !== context.extensionId ||
      !sender.url ||
      !sender.origin ||
      sender.origin === 'null' ||
      !Number.isInteger(sender.frameId) ||
      typeof sender.documentId !== 'string' ||
      !sender.documentId
    )
      throw new Error('Invalid native runtime sender');
    const trusted =
      extensionId(sender.url) === context.extensionId &&
      sender.origin === `chrome-extension://${context.extensionId}`;
    let contents;
    if (Number.isInteger(sender.tabId)) contents = webContents.fromId(sender.tabId);
    else if (trusted)
      contents = webContents
        .getAllWebContents()
        .find(
          (item) =>
            item.session === context.session &&
            item.getType() === 'backgroundPage' &&
            item.getURL() === sender.url,
        );
    if (!contents || contents.isDestroyed() || contents.session !== context.session)
      throw new Error('Runtime sender outside profile');
    const frame =
      sender.frameId === 0
        ? contents.mainFrame
        : contents.mainFrame.framesInSubtree.find((item) => item.frameTreeNodeId === sender.frameId);
    if (!frame || frame.detached || frame.url !== sender.url || frame.origin !== sender.origin)
      throw new Error('Runtime sender document mismatch');
    if (
      !trusted &&
      !(context.metadata.grants?.origins || []).some((pattern) => permitsOrigin(pattern, sender.url))
    )
      throw new Error('Content origin not granted');
    const token = randomUUID();
    const origin = {
      ...context,
      broker,
      sender: frame,
      sourceContents: contents,
      runtimeSender: Object.freeze({ ...sender }),
      url: frame.url,
      kind: trusted
        ? contents.getType() === 'backgroundPage'
          ? 'background-page'
          : 'extension-frame'
        : 'content-script',
      transportKind: 'host-frame',
    };
    this.origins.set(token, origin);
    const revoke = () => {
      this.origins.delete(token);
      contents.off('did-start-navigation', revoke);
      contents.off('destroyed', revoke);
    };
    contents.once('did-start-navigation', revoke);
    contents.once('destroyed', revoke);
    origin.revoke = revoke;
    return token;
  }

  validateOrigin(origin, context) {
    if (
      !origin ||
      origin.session !== context.session ||
      origin.extensionId !== context.extensionId ||
      origin.epoch !== context.epoch ||
      origin.sender.detached ||
      origin.sourceContents.isDestroyed() ||
      origin.sender.url !== origin.url
    )
      throw new Error('Expired originating context');
    if (
      origin.kind === 'content-script' &&
      !(context.metadata.grants?.origins || []).some((pattern) => permitsOrigin(pattern, origin.url))
    )
      throw new Error('Content origin not granted');
  }

  authenticate(event) {
    if (this.closed) throw new Error('Extension bridge closed');
    const worker = event.type === 'service-worker' ? event.serviceWorker : null;
    const session = worker ? event.session : event.sender?.session;
    const entry = this.sessions.get(session);
    const sender = worker || event.senderFrame;
    if (!entry || !sender || (worker ? worker.isDestroyed() : event.sender.isDestroyed() || sender.detached))
      throw new Error('Invalid native extension sender');
    const url = worker ? worker.scriptURL : sender.url;
    const id = extensionId(url);
    if (!id || !session.extensions.getExtension(id)) throw new Error('Not a loaded extension origin');
    const metadata = this.resolveExtension(entry.profileId, id);
    if (!metadata || metadata.enabled !== true) {
      if (!entry.revoked.has(id)) entry.unloaded(null, { id });
      throw new Error('Extension disabled');
    }
    if (entry.revoked.has(id)) throw new Error('Extension context revoked until native reload');
    const kind = worker
      ? 'service-worker'
      : event.sender.getType() === 'backgroundPage'
        ? 'background-page'
        : 'extension-frame';
    return {
      profileId: entry.profileId,
      extensionId: id,
      sender,
      session,
      kind,
      url,
      metadata,
      epoch: entry.epochs.get(id) || 0,
      generation: metadata.generation ?? 0,
    };
  }

  async handle(event, request) {
    const context = this.authenticate(event);
    if (!request || typeof request !== 'object') throw new Error('Invalid transport request');
    if (request.operation === 'connect') {
      const token = randomUUID();
      this.leases.set(token, context);
      return token;
    }
    const lease = this.leases.get(request.token);
    if (
      !lease ||
      lease.sender !== context.sender ||
      lease.session !== context.session ||
      lease.extensionId !== context.extensionId ||
      lease.epoch !== context.epoch ||
      lease.generation !== context.generation ||
      lease.url !== context.url
    )
      throw new Error('Expired extension context');
    if (request.operation === 'bind') return this.bindOrigin(context, event, request.runtimeSender);
    if (request.operation === 'release') {
      this.brokerFor(context, event);
      const origin = this.origins.get(request.originToken);
      if (origin && origin.session === context.session && origin.extensionId === context.extensionId)
        origin.revoke();
      return;
    }
    if (
      typeof request.method !== 'string' ||
      !/^[a-zA-Z][\w.:-]{0,127}$/.test(request.method) ||
      !Array.isArray(request.args)
    )
      throw new Error('Invalid extension call');
    let origin;
    if (request.operation === 'relay') {
      this.brokerFor(context, event);
      origin = this.origins.get(request.originToken);
      this.validateOrigin(origin, context);
    } else if (request.operation !== 'invoke') throw new Error('Invalid transport operation');
    const result = await this.dispatch(
      Object.freeze(origin ? { ...origin, metadata: context.metadata } : context),
      request.method,
      request.args,
    );
    const current = this.authenticate(event);
    if (
      current.epoch !== lease.epoch ||
      current.generation !== lease.generation ||
      current.url !== lease.url ||
      !this.leases.has(request.token)
    )
      throw new Error('Expired extension context');
    if (origin) {
      if (!this.origins.has(request.originToken)) throw new Error('Expired originating context');
      this.validateOrigin(origin, current);
    }
    return result;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    ipcMain.removeHandler(CHANNEL);
    this.leases.clear();
    for (const origin of this.origins.values()) origin.revoke();
    this.origins.clear();
    for (const [session, entry] of this.sessions) {
      const registered = new Set(session.getPreloadScripts().map((script) => script.id));
      for (const id of entry.preloads) if (registered.has(id)) session.unregisterPreloadScript(id);
      session.extensions.off('extension-unloaded', entry.unloaded);
      session.extensions.off('extension-loaded', entry.loaded);
      for (const broker of entry.brokers.values()) if (!broker.isDestroyed()) broker.destroy();
      session.serviceWorkers.off('running-status-changed', entry.started);
      for (const worker of entry.workers) if (!worker.isDestroyed()) worker.ipc.removeHandler(CHANNEL);
    }
    this.sessions.clear();
  }
}
module.exports = { ExtensionBridge };
