'use strict';
const { ipcMain, BrowserWindow, webContents } = require('electron');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const {
  getNativeServices,
  NATIVE_SERVICES_PAGE,
  registerNativeEventDelivery,
} = require('./native-services.cjs');
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

const { matches: permitsOrigin } = require('./permissions.cjs');

class ExtensionBridge {
  constructor({ resolveExtension, dispatch, onError = () => {} }) {
    this.resolveExtension = resolveExtension;
    this.dispatch = dispatch;
    this.onError = onError;
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
      backgrounds: new Map(),
    };
    this.sessions.set(session, entry);
    registerNativeEventDelivery(session, (id, event, args) => this.emit(profileId, id, event, args));
    entry.unloaded = (_event, extension) => {
      entry.revoked.add(extension.id);
      // Electron removes the extension from its registry but retains open
      // DevTools frames and their native inspectedWindow authority. Destroy
      // those contexts on unload; keep inspected documents and other sessions.
      if (extension.manifest?.devtools_page)
        for (const contents of webContents.getAllWebContents())
          if (!contents.isDestroyed() && contents.session === session && contents.isDevToolsOpened())
            contents.closeDevTools();
      this.clearBackground(entry, extension.id);
      entry.epochs.set(extension.id, (entry.epochs.get(extension.id) || 0) + 1);
      for (const [key, lease] of this.leases)
        if (lease.session === session && lease.extensionId === extension.id) this.releaseLease(key);
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
      if (!['starting', 'running'].includes(runningStatus)) {
        if (['stopping', 'stopped'].includes(runningStatus))
          for (const [token, lease] of this.leases)
            if (
              lease.session === session &&
              lease.kind === 'service-worker' &&
              lease.sender.versionId === versionId
            )
              this.releaseLease(token);
        return;
      }
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

  async bindOrigin(context, event, sender) {
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
    const nativeContexts =
      context.session.extensions.getExtension(context.extensionId)?.manifest?.manifest_version === 3
        ? await broker.webContents.executeJavaScript(
            `chrome.runtime.getContexts({contextTypes:['OFFSCREEN_DOCUMENT'],documentIds:[${JSON.stringify(sender.documentId)}]})`,
          )
        : [];
    if (nativeContexts.length) throw new Error('Offscreen documents expose only native runtime');
    this.brokerFor(context, event);
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
      active: false,
    };
    this.origins.set(token, origin);
    const revoke = () => {
      this.origins.delete(token);
      contents.off('did-start-navigation', navigating);
      contents.off('destroyed', revoke);
    };
    const navigating = (details, _url, _inPlace, isMainFrame, processId, routingId) => {
      if (
        (details.isMainFrame ?? isMainFrame) ||
        ((details.frameProcessId ?? processId) === frame.processId &&
          (details.frameRoutingId ?? routingId) === frame.routingId)
      )
        revoke();
    };
    contents.on('did-start-navigation', navigating);
    contents.once('destroyed', revoke);
    origin.revoke = revoke;
    return { originToken: token, tabId: contents.id, documentId: sender.documentId };
  }

  validateOrigin(origin, context, allowPending = false) {
    if (
      !origin ||
      (!allowPending && !origin.active) ||
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
      sourceContents: worker ? undefined : event.sender,
      session,
      kind,
      url,
      metadata,
      epoch: entry.epochs.get(id) || 0,
      generation: metadata.generation ?? 0,
    };
  }

  releaseLease(token) {
    const lease = this.leases.get(token);
    if (!lease) return;
    this.leases.delete(token);
    lease.cleanup?.();
  }

  async handle(event, request) {
    const context = this.authenticate(event);
    // Chromium's offscreen API and runtime.getContexts are MV3-only. MV2 event
    // pages cannot create offscreen contexts and do not expose getContexts.
    if (
      context.session.extensions.getExtension(context.extensionId)?.manifest?.manifest_version === 3 &&
      context.kind === 'extension-frame' &&
      !context.url.endsWith('/zacro-compat-transport.html')
    ) {
      const broker = this.sessions.get(context.session)?.brokers.get(context.extensionId);
      if (!broker || broker.isDestroyed()) throw new Error('Extension native context unavailable');
      const contexts = await broker.webContents.executeJavaScript(
        `chrome.runtime.getContexts({contextTypes:['OFFSCREEN_DOCUMENT'],documentUrls:[${JSON.stringify(context.url)}]})`,
      );
      if (contexts.length) throw new Error('Offscreen documents expose only native runtime');
      this.authenticate(event);
    }
    if (!request || typeof request !== 'object') throw new Error('Invalid transport request');
    if (request.operation === 'connect') {
      const token = randomUUID();
      this.leases.set(token, context);
      if (context.sourceContents) {
        const contents = context.sourceContents,
          frame = context.sender;
        const gone = () => this.releaseLease(token);
        const navigation = (details, _url, inPlace, isMainFrame, processId, routingId) => {
          if (details.isSameDocument ?? inPlace) return;
          if (
            (details.isMainFrame ?? isMainFrame) ||
            ((details.frameProcessId ?? processId) === frame.processId &&
              (details.frameRoutingId ?? routingId) === frame.routingId)
          )
            gone();
        };
        contents.on('did-start-navigation', navigation);
        contents.once('destroyed', gone);
        context.cleanup = () => {
          contents.off('did-start-navigation', navigation);
          contents.off('destroyed', gone);
        };
      }
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
    if (request.operation === 'activate') {
      this.brokerFor(context, event);
      const origin = this.origins.get(request.originToken);
      this.validateOrigin(origin, context, true);
      origin.active = true;
      return;
    }
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
    const assertCurrent = () => {
      const current = this.authenticate(event);
      if (
        this.leases.get(request.token) !== lease ||
        current.generation !== lease.generation ||
        current.epoch !== lease.epoch ||
        current.url !== lease.url
      )
        throw new Error('Expired extension context');
      if (origin) {
        if (!this.origins.has(request.originToken)) throw new Error('Expired originating context');
        this.validateOrigin(origin, current);
      }
    };
    assertCurrent();
    const source = origin || lease;
    if (
      request.method === 'zacro.nativeServices.ready' ||
      request.method === 'zacro.nativeServices.checkpoint'
    ) {
      if (
        source.kind === 'content-script' ||
        source.url === `chrome-extension://${context.extensionId}/${NATIVE_SERVICES_PAGE}`
      )
        throw new Error('Native lifecycle requires a trusted extension context');
      const services = getNativeServices(context.session, context.extensionId);
      if (!services) throw new Error('Native extension services unavailable');
      await services.ready;
      assertCurrent();
      if (request.method.endsWith('.checkpoint')) await services.checkpoint();
      assertCurrent();
      return;
    }
    if (request.method === 'zacro.events.context') return { kind: source.kind };
    if (request.method === 'zacro.events.idle') {
      if (source.kind !== 'background-page')
        throw new Error('Only native background pages can retire a Port');
      const background = this.sessions.get(context.session).backgrounds.get(context.extensionId);
      if (background?.target === source) background.target = null;
      return;
    }
    if (request.method === 'zacro.events.subscribe') {
      const names = request.args[0];
      if (
        !Array.isArray(names) ||
        names.length > 32 ||
        names.some(
          (name) =>
            typeof name !== 'string' ||
            !/^(tabs\.(onCreated|onUpdated|onRemoved|onActivated|onMoved)|windows\.onFocusChanged|permissions\.(onAdded|onRemoved)|commands\.onCommand|action\.onClicked|contextMenus\.onClicked|storage\.onChanged|alarms\.onAlarm)$/.test(
              name,
            ),
        )
      )
        throw new Error('Invalid event subscriptions');
      source.subscriptions = new Set(names);
      source.assertCurrent = assertCurrent;
      if (['service-worker', 'background-page'].includes(source.kind)) {
        const entry = this.sessions.get(context.session);
        const background = this.background(entry, context.extensionId, context.generation);
        background.events = source.subscriptions;
        background.target = source;
        background.waking = false;
        this.flush(entry, context.extensionId, background);
      }
      return;
    }
    const result = await this.dispatch(
      Object.freeze({ ...(origin ? { ...origin, metadata: context.metadata } : context), assertCurrent }),
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

  background(entry, id, generation) {
    let state = entry.backgrounds.get(id);
    if (state && state.generation !== generation) this.clearBackground(entry, id);
    state = entry.backgrounds.get(id);
    if (!state) {
      state = { generation, events: null, target: null, queue: [], bytes: 0, waking: false };
      entry.backgrounds.set(id, state);
    }
    return state;
  }

  clearBackground(entry, id) {
    const state = entry.backgrounds.get(id);
    if (state) clearTimeout(state.timer);
    entry.backgrounds.delete(id);
  }

  deliveryError(entry, id, event, message) {
    try {
      this.onError(new Error(message), { profileId: entry.profileId, extensionId: id, event });
    } catch {
      /* Reporting must not break lifecycle cleanup. */
    }
  }

  destination(source, event, filter) {
    source.assertCurrent?.();
    const entry = this.sessions.get(source.session);
    const metadata = this.resolveExtension(source.profileId, source.extensionId);
    // Only backgrounds need a host-side listener snapshot to wake/replay. Live
    // documents already have their local listener map before the async snapshot
    // arrives, and can discard events without a listener themselves.
    const background = ['service-worker', 'background-page'].includes(source.kind);
    if (
      (background && !source.subscriptions?.has(event)) ||
      source.url === `chrome-extension://${source.extensionId}/zacro-compat-transport.html` ||
      !metadata?.enabled ||
      (metadata.generation ?? 0) !== source.generation ||
      !entry ||
      entry.revoked.has(source.extensionId) ||
      (entry.epochs.get(source.extensionId) || 0) !== source.epoch
    )
      return null;
    if (source.kind === 'content-script' && event !== 'storage.onChanged') return null;
    const current = { ...source, metadata };
    if (source.broker) this.validateOrigin(source, current);
    else if (
      source.kind === 'service-worker'
        ? source.sender.isDestroyed()
        : source.sender.detached || source.sender.url !== source.url
    )
      return null;
    if (filter(current) !== true) return null;
    source.assertCurrent?.();
    return current;
  }

  deliver(source, event, args, filter) {
    if (!this.destination(source, event, filter)) return false;
    if (source.broker) {
      const pair = [...this.origins].find(([, item]) => item === source);
      if (!pair) return false;
      source.broker.webContents.mainFrame.send(CHANNEL + ':event', { originToken: pair[0], event, args });
    } else {
      const pair = [...this.leases].find(([, item]) => item === source);
      if (!pair) return false;
      source.sender.send(CHANNEL + ':event', { token: pair[0], event, args });
    }
    return true;
  }

  flush(entry, id, state) {
    if (entry.backgrounds.get(id) !== state || !state.target) return;
    try {
      state.target.assertCurrent();
    } catch {
      state.target = null;
      return;
    }
    // Dequeue only once a fresh authenticated listener snapshot is available.
    // Re-evaluate filters for each delivery, not at enqueue/wake time.
    while (state.queue.length) {
      const item = state.queue.shift();
      state.bytes -= item.bytes;
      try {
        this.deliver(state.target, item.event, item.args, item.filter);
      } catch {
        state.target = null;
      }
      if (!state.target) break;
    }
    if (!state.queue.length) {
      clearTimeout(state.timer);
      state.timer = null;
    }
  }

  wake(session, entry, id, state) {
    if (state.waking || !state.queue.length) return;
    state.waking = true;
    const native = session.extensions.getExtension(id);
    const wake = Promise.resolve().then(() => {
      if (native?.manifest.background?.service_worker)
        return session.serviceWorkers.startWorkerForScope(`chrome-extension://${id}/`);
      const broker = entry.brokers.get(id);
      if (!broker || broker.isDestroyed()) throw new Error('Background transport unavailable');
      broker.webContents.mainFrame.send(CHANNEL + ':wake');
    });
    Promise.resolve(wake).catch(() => {
      if (entry.backgrounds.get(id) !== state) return;
      for (const item of state.queue)
        this.deliveryError(entry, id, item.event, 'Native background wake failed');
      state.queue.length = 0;
      state.bytes = 0;
      state.waking = false;
      clearTimeout(state.timer);
      state.timer = null;
    });
  }

  emit(profileId, id, event, args, { filter = () => true } = {}) {
    if (this.closed || typeof event !== 'string' || !Array.isArray(args)) return;
    for (const source of [...this.leases.values(), ...this.origins.values()]) {
      if (
        source.profileId !== profileId ||
        source.extensionId !== id ||
        ['service-worker', 'background-page'].includes(source.kind)
      )
        continue;
      try {
        this.deliver(source, event, args, filter);
      } catch {
        /* Expired document. */
      }
    }
    for (const [session, entry] of this.sessions) {
      if (entry.profileId !== profileId || entry.revoked.has(id)) continue;
      const metadata = this.resolveExtension(profileId, id);
      const native = session.extensions.getExtension(id);
      if (!metadata?.enabled || !native?.manifest.background) continue;
      const state = this.background(entry, id, metadata.generation ?? 0);
      if (state.events && !state.events.has(event)) continue;
      let copy, bytes;
      try {
        copy = structuredClone(args);
        bytes = Buffer.byteLength(JSON.stringify(copy));
      } catch {
        this.deliveryError(entry, id, event, 'Invalid notification payload');
        continue;
      }
      const all = [...this.sessions.values()].flatMap((item) => [...item.backgrounds.values()]);
      if (
        state.queue.length >= 128 ||
        state.bytes + bytes > 262144 ||
        all.reduce((n, item) => n + item.queue.length, 0) >= 512 ||
        all.reduce((n, item) => n + item.bytes, 0) + bytes > 1048576
      ) {
        this.deliveryError(entry, id, event, 'Notification queue limit exceeded');
        continue;
      }
      state.queue.push({ event, args: copy, filter, bytes });
      state.bytes += bytes;
      if (!state.timer) {
        state.timer = setTimeout(() => {
          for (const item of state.queue)
            this.deliveryError(entry, id, item.event, 'Notification readiness deadline exceeded');
          state.queue.length = 0;
          state.bytes = 0;
          state.waking = false;
          state.timer = null;
        }, 10000);
        state.timer.unref();
      }
      this.flush(entry, id, state);
      this.wake(session, entry, id, state);
    }
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    ipcMain.removeHandler(CHANNEL);
    for (const token of this.leases.keys()) this.releaseLease(token);
    for (const origin of this.origins.values()) origin.revoke();
    this.origins.clear();
    for (const [session, entry] of this.sessions) {
      registerNativeEventDelivery(session, null);
      for (const id of entry.backgrounds.keys()) this.clearBackground(entry, id);
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
