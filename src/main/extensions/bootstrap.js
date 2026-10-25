'use strict';
// Original native-runtime-only facade; it has no Electron IPC or host token.
(() => {
  const runtime = globalThis.chrome?.runtime;
  if (!runtime?.id || globalThis.__zacroFacadeInstalled) return;
  // Native offscreen documents deliberately expose runtime only. This heuristic
  // suppresses facade creation; the main process independently verifies native
  // OFFSCREEN_DOCUMENT identity before accepting any privileged invocation.
  if (
    typeof document !== 'undefined' &&
    location.protocol === 'chrome-extension:' &&
    (location.pathname === '/zacro-native-services.html' || (!chrome.storage && !chrome.tabs))
  )
    return;
  Object.defineProperty(globalThis, '__zacroFacadeInstalled', { value: true });
  const namespace = 'zacro.extension.transport.v1';
  let resubscribe = () => {};
  const wakeCheck = (message) => message?.namespace === 'zacro.extension.wake.v1';
  // Native document-targeted messaging is a liveness check, not an identity
  // claim from page data. Chromium selects the recipient by documentId.
  const messageEvent = runtime.onMessage;
  const messageAdd = messageEvent.addListener.bind(messageEvent);
  const messageRemove = messageEvent.removeListener.bind(messageEvent);
  const messageHas = messageEvent.hasListener.bind(messageEvent);
  const documentCheck = (message) => message?.namespace === 'zacro.extension.document.v1';
  messageAdd((message, sender, reply) => {
    if (
      (documentCheck(message) || wakeCheck(message)) &&
      sender.id === runtime.id &&
      sender.url === runtime.getURL('zacro-compat-transport.html')
    ) {
      if (wakeCheck(message)) resubscribe();
      reply(true);
    }
  });
  const messageListeners = new WeakMap();
  messageEvent.addListener = (listener) => {
    let wrapper = messageListeners.get(listener);
    if (!wrapper) {
      wrapper = (...args) => {
        if (!documentCheck(args[0]) && !wakeCheck(args[0])) return listener(...args);
      };
      messageListeners.set(listener, wrapper);
    }
    return messageAdd(wrapper);
  };
  messageEvent.removeListener = (listener) => messageRemove(messageListeners.get(listener) || listener);
  messageEvent.hasListener = (listener) => messageHas(messageListeners.get(listener) || listener);
  const event = runtime.onConnect;
  const add = event.addListener.bind(event),
    remove = event.removeListener.bind(event),
    has = event.hasListener.bind(event);
  const listeners = new WeakMap();
  event.addListener = (listener) => {
    let wrapper = listeners.get(listener);
    if (!wrapper) {
      wrapper = (port) => {
        if (port.name !== namespace) return listener(port);
      };
      listeners.set(listener, wrapper);
    }
    return add(wrapper);
  };
  event.removeListener = (listener) => remove(listeners.get(listener) || listener);
  event.hasListener = (listener) => has(listeners.get(listener) || listener);
  const subscribers = new Set();
  let nativePortCount = 0;
  let settleNativeTransport = () => {};
  let nativeTransportClosed = () => {};
  if (!globalThis.zacroExtension) {
    const connect = runtime.connect.bind(runtime);
    let ready,
      active,
      nextId = 1;
    function open() {
      const port = connect({ name: namespace });
      const pending = new Map();
      let closed = false,
        idle,
        background = false;
      const settle = () => {
        clearTimeout(idle);
        if (background && !nativePortCount && !pending.size && !closed && !connection.retiring)
          idle = setTimeout(() => connection.retire(), 100);
      };
      const fail = () => {
        closed = true;
        clearTimeout(idle);
        if (active === connection) {
          nativeTransportClosed();
          active = null;
          ready = null;
        }
        for (const { reject, timer } of pending.values()) {
          clearTimeout(timer);
          reject(new Error('Extension transport disconnected'));
        }
        pending.clear();
      };
      port.onDisconnect.addListener(() => {
        void runtime.lastError;
        fail();
      });
      port.onMessage.addListener((message) => {
        if (message?.event) {
          for (const listener of subscribers) listener(message.event, message.args);
          return;
        }
        const request = pending.get(message?.id);
        if (!request) return;
        pending.delete(message.id);
        clearTimeout(request.timer);
        message.error ? request.reject(new Error(message.error)) : request.resolve(message.value);
        settle();
      });
      const connection = {
        retiring: null,
        settle,
        retire() {
          if (closed || nativePortCount || pending.size || connection.retiring) return;
          // The host first removes this event destination. Its acknowledgement
          // follows all earlier Port events, so none can be stranded by close.
          connection.retiring = connection.request({ method: 'zacro.events.idle', args: [] }).then(
            () => connection.close(),
            () => connection.close(),
          );
        },
        setKind(kind) {
          background = kind === 'background-page';
          settle();
        },
        close() {
          port.disconnect();
          fail();
        },
        request(payload, timeout = 10000) {
          if (closed) return Promise.reject(new Error('Extension transport disconnected'));
          clearTimeout(idle);
          const id = nextId++;
          return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
              pending.delete(id);
              reject(new Error('Extension transport deadline exceeded'));
              settle();
            }, timeout);
            pending.set(id, { resolve, reject, timer });
            try {
              port.postMessage({ id, ...payload });
            } catch (error) {
              clearTimeout(timer);
              pending.delete(id);
              reject(error);
            }
          });
        },
      };
      return connection;
    }
    async function initialize() {
      const deadline = Date.now() + 3000;
      while (Date.now() < deadline) {
        let connection;
        try {
          connection = open();
          const context = await connection.request({ hello: true }, 150);
          active = connection;
          settleNativeTransport = connection.settle;
          connection.setKind(context.kind);
          setTimeout(() => resubscribe(), 0);
          return connection;
        } catch {
          connection?.close();
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
      }
      throw new Error('Authenticated extension transport unavailable');
    }
    Object.defineProperty(globalThis, 'zacroExtension', {
      value: Object.freeze({
        onEvent(listener) {
          subscribers.add(listener);
          return () => subscribers.delete(listener);
        },
        connectEvents() {
          ready ||= initialize();
          ready.catch(() => {});
        },
        async invoke(method, args, ...extra) {
          if (extra.length) throw new Error('Caller identity is not accepted');
          ready ||= initialize();
          const connection = await ready;
          if (connection.retiring) {
            await connection.retiring;
            return globalThis.zacroExtension.invoke(method, args);
          }
          return connection.request(
            { method, args },
            method === 'identity.launchWebAuthFlow'
              ? 601000
              : method === 'runtime.connectNative'
                ? 300000
                : method === 'runtime.sendNativeMessage'
                  ? 31000
                  : 10000,
          );
        },
      }),
    });
  }
  installFacade();
  function installFacade() {
    const host = globalThis.zacroExtension;
    const chrome = globalThis.chrome;
    let callbackError;
    const nativeError = Object.getOwnPropertyDescriptor(runtime, 'lastError');
    Object.defineProperty(runtime, 'lastError', {
      configurable: true,
      get: () => callbackError || nativeError?.get?.call(runtime),
    });
    const events = new Map();
    const menuCallbacks = new Map();
    let subscriptionTimer;
    resubscribe = () => {
      if (subscriptionTimer) return;
      subscriptionTimer = setTimeout(() => {
        subscriptionTimer = null;
        // MV2 executes the bootstrap and original background scripts in separate
        // document tasks. Wait for their native document load barrier before
        // declaring the listener snapshot ready (including an empty snapshot).
        if (
          typeof document !== 'undefined' &&
          location.protocol === 'chrome-extension:' &&
          document.readyState === 'loading'
        ) {
          document.addEventListener('DOMContentLoaded', resubscribe, { once: true });
          return;
        }
        const names = [...events]
          .filter(([, item]) => item.listeners.size)
          .map(([name]) => (name === 'storage.sync.onChanged' ? 'storage.onChanged' : name));
        if (menuCallbacks.size) names.push('contextMenus.onClicked');
        host.invoke('zacro.events.subscribe', [[...new Set(names)]]).catch(() => {});
      }, 0);
    };
    function event(name, native) {
      if (events.has(name)) return events.get(name).api;
      const listeners = new Set();
      const api = {
        addListener(listener) {
          if (typeof listener !== 'function') throw new TypeError('Listener must be a function');
          if (!listeners.has(listener)) {
            listeners.add(listener);
            native?.addListener(listener);
            resubscribe();
          }
        },
        removeListener(listener) {
          listeners.delete(listener);
          native?.removeListener(listener);
          resubscribe();
        },
        hasListener(listener) {
          return listeners.has(listener) || !!native?.hasListener(listener);
        },
        hasListeners() {
          return listeners.size > 0 || !!native?.hasListeners();
        },
      };
      events.set(name, { api, listeners });
      return api;
    }
    host.onEvent?.((name, args) => {
      if (name === 'contextMenus.onClicked') {
        const saved = menuCallbacks.get(args[0]?.menuItemId);
        if (saved?.token === args[2]) {
          try {
            saved.callback(args[0], args[1]);
          } catch (error) {
            console.error(error);
          }
        }
        args = args.slice(0, 2);
      }
      for (const listener of events.get(name)?.listeners || []) {
        try {
          listener(...args);
        } catch (error) {
          console.error(error);
        }
      }
      if (name === 'storage.onChanged' && args[1] === 'sync')
        for (const listener of events.get('storage.sync.onChanged')?.listeners || []) {
          try {
            listener(args[0]);
          } catch (error) {
            console.error(error);
          }
        }
    });
    function validate(value, seen = new Set()) {
      if (
        value === null ||
        typeof value === 'string' ||
        typeof value === 'boolean' ||
        (typeof value === 'number' && Number.isFinite(value))
      )
        return;
      if (typeof value !== 'object' || seen.has(value))
        throw new TypeError('Unsupported storage serialization');
      if (
        !Array.isArray(value) &&
        Object.getPrototypeOf(value) !== Object.prototype &&
        Object.getPrototypeOf(value) !== null
      )
        throw new TypeError('Unsupported storage serialization');
      seen.add(value);
      if (Array.isArray(value))
        for (let i = 0; i < value.length; i++) {
          if (!Object.hasOwn(value, i)) throw new TypeError('Unsupported storage serialization');
          validate(value[i], seen);
        }
      else
        for (const key of Reflect.ownKeys(value)) {
          if (typeof key !== 'string') throw new TypeError('Unsupported storage serialization');
          const d = Object.getOwnPropertyDescriptor(value, key);
          if (!('value' in d)) throw new TypeError('Unsupported storage serialization');
          validate(d.value, seen);
        }
      seen.delete(value);
    }
    function invoke(name, args) {
      const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
      const promise = Promise.resolve().then(() => {
        if (
          (name === 'action.setIcon' || name === 'browserAction.setIcon') &&
          args[0]?.imageData !== undefined
        )
          args[0] = { ...args[0], imageData: serializeImageData(args[0].imageData) };
        if (
          name === 'storage.sync.set' ||
          (name === 'storage.sync.get' && args[0] && typeof args[0] === 'object')
        )
          validate(args[0]);
        return host.invoke(name, args);
      });
      return complete(promise, callback);
    }
    function complete(promise, callback) {
      if (!callback) return promise;
      promise.then(
        (value) => callback(value),
        (error) => {
          callbackError = { message: error.message };
          try {
            callback();
          } finally {
            callbackError = undefined;
          }
        },
      );
      return undefined;
    }
    function serializeImageData(value) {
      let remaining = 1024 * 1024;
      const one = (image) => {
        const { width, height, data } = image || {};
        if (
          !Number.isInteger(width) ||
          !Number.isInteger(height) ||
          width < 1 ||
          height < 1 ||
          width > 256 ||
          height > 256 ||
          data?.length !== width * height * 4 ||
          data.length > remaining
        )
          throw new Error('Invalid or oversized icon ImageData');
        remaining -= data.length;
        return { width, height, data: Array.from(data) };
      };
      if (!value || typeof value !== 'object') throw new Error('Invalid icon ImageData');
      if ('width' in value) return one(value);
      const entries = Object.entries(value);
      if (!entries.length || entries.length > 16) throw new Error('Invalid icon ImageData sizes');
      return Object.fromEntries(entries.map(([size, image]) => [size, one(image)]));
    }
    // Native setters become durable at their Promise/callback boundary. Reads
    // also wait for host restoration, so a waking worker never sees empty state
    // and overwrites a user's saved rules. Session rules remain session-local.
    for (const [group, reads, mutations] of [
      [
        'declarativeNetRequest',
        // Session mutation waits for restore but intentionally stays volatile.
        [
          'getDynamicRules',
          'getEnabledRulesets',
          'getDisabledRuleIds',
          'getSessionRules',
          'updateSessionRules',
          'getAvailableStaticRuleCount',
        ],
        ['updateDynamicRules', 'updateEnabledRulesets', 'updateStaticRules'],
      ],
      ['alarms', ['get', 'getAll'], ['create', 'clear', 'clearAll']],
      ['offscreen', ['createDocument', 'hasDocument', 'closeDocument'], []],
    ]) {
      const native = chrome[group];
      if (!native) continue;
      for (const name of [...reads, ...mutations]) {
        if (typeof native[name] !== 'function') continue;
        const original = native[name].bind(native);
        native[name] = (...args) => {
          const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
          const promise = host
            .invoke('zacro.nativeServices.ready', [])
            .then(() => original(...args))
            .then(async (result) => {
              if (mutations.includes(name)) await host.invoke('zacro.nativeServices.checkpoint', []);
              return result;
            });
          return complete(promise, callback);
        };
      }
      if (group === 'alarms') native.onAlarm = event('alarms.onAlarm');
    }
    function methods(group, names) {
      chrome[group] ||= {};
      for (const name of names) chrome[group][name] = (...args) => invoke(group + '.' + name, args);
    }
    methods('tabs', [
      'get',
      'getCurrent',
      'query',
      'create',
      'update',
      'remove',
      'reload',
      'duplicate',
      'move',
    ]);
    methods('windows', ['get', 'getCurrent', 'getAll', 'update', 'create', 'remove']);
    methods('permissions', ['contains', 'getAll', 'request', 'remove']);
    methods('commands', ['getAll']);
    methods('fontSettings', [
      'getFont',
      'setFont',
      'clearFont',
      'getFontList',
      'getDefaultFontSize',
      'setDefaultFontSize',
      'clearDefaultFontSize',
      'getDefaultFixedFontSize',
      'setDefaultFixedFontSize',
      'clearDefaultFixedFontSize',
      'getMinimumFontSize',
      'setMinimumFontSize',
      'clearMinimumFontSize',
    ]);
    for (const name of [
      'onFontChanged',
      'onDefaultFontSizeChanged',
      'onDefaultFixedFontSizeChanged',
      'onMinimumFontSizeChanged',
    ])
      chrome.fontSettings[name] = event('fontSettings.' + name);
    methods('identity', [
      'launchWebAuthFlow',
      'getProfileUserInfo',
      'getAuthToken',
      'getAccounts',
      'removeCachedAuthToken',
      'clearAllCachedAuthTokens',
    ]);
    // Synchronous Chrome helper derives only the authenticated native runtime ID.
    chrome.identity.getRedirectURL = (path = '') => {
      if (
        typeof path !== 'string' ||
        path.length > 2048 ||
        /[\\\x00-\x20\x7f]/.test(path) ||
        path.startsWith('//') ||
        /^[a-z][a-z0-9+.-]*:/i.test(path) ||
        path.split(/[/?#]/).some((part) => part === '.' || part === '..')
      )
        throw new Error('Invalid redirect path');
      const base = `https://${runtime.id}.chromiumapp.org/`;
      const result = new URL(path.replace(/^\//, ''), base);
      if (result.origin !== new URL(base).origin) throw new Error('Invalid redirect path');
      return result.href;
    };
    methods('sidePanel', [
      'getOptions',
      'setOptions',
      'getPanelBehavior',
      'setPanelBehavior',
      'open',
      'close',
      'getLayout',
    ]);
    for (const group of ['action', 'browserAction'])
      methods(group, [
        'getTitle',
        'setTitle',
        'getPopup',
        'setPopup',
        'getBadgeText',
        'setBadgeText',
        'getBadgeBackgroundColor',
        'setBadgeBackgroundColor',
        'getBadgeTextColor',
        'setBadgeTextColor',
        'setIcon',
        'enable',
        'disable',
        'openPopup',
      ]);
    chrome.contextMenus ||= {};
    let menuId = 0;
    function menuProperties(properties) {
      const props = { ...properties };
      const callback = props.onclick;
      delete props.onclick;
      if (callback !== undefined && (typeof callback !== 'function' || typeof document === 'undefined'))
        throw new Error(
          'Inline menu callbacks require an extension document; use contextMenus.onClicked in workers',
        );
      return { props, saved: callback ? { token: crypto.randomUUID(), callback } : null };
    }
    chrome.contextMenus.create = (properties, callback) => {
      const id = properties.id ?? 'zacro-generated-' + ++menuId;
      const { props, saved } = menuProperties({ ...properties, id });
      const promise = invoke('contextMenus.create', [props, { callbackId: saved?.token || null }]).then(
        () => {
          if (saved) menuCallbacks.set(id, saved);
          resubscribe();
        },
      );
      if (callback) complete(promise, callback);
      else promise.catch(console.error);
      return id;
    };
    chrome.contextMenus.update = (id, properties, callback) => {
      const { props, saved } = menuProperties(properties);
      const promise = invoke('contextMenus.update', [
        id,
        props,
        saved ? { callbackId: saved.token } : {},
      ]).then(() => {
        if (saved) menuCallbacks.set(id, saved);
        resubscribe();
      });
      return complete(promise, callback);
    };
    for (const name of ['remove', 'removeAll'])
      chrome.contextMenus[name] = (...args) => {
        const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
        return complete(
          invoke('contextMenus.' + name, args).then(() => {
            if (name === 'removeAll') menuCallbacks.clear();
            else menuCallbacks.delete(args[0]);
            resubscribe();
          }),
          callback,
        );
      };
    // These Ports are scoped by the main-process lease, never by their client ID.
    const nativePorts = new Map();
    const portEvent = () => {
      const listeners = new Set();
      return {
        listeners,
        api: {
          addListener(listener) {
            if (typeof listener !== 'function') throw new TypeError('Listener must be a function');
            listeners.add(listener);
          },
          removeListener(listener) {
            listeners.delete(listener);
          },
          hasListener(listener) {
            return listeners.has(listener);
          },
          hasListeners() {
            return listeners.size > 0;
          },
        },
      };
    };
    function nativeDisconnected(saved, error, notify = true) {
      if (saved.closed) return;
      saved.closed = true;
      nativePorts.delete(saved.id);
      nativePortCount--;
      if (error) callbackError = { message: error };
      try {
        for (const listener of notify ? saved.disconnected.listeners : []) {
          try {
            listener(saved.port);
          } catch (error) {
            console.error('Native messaging listener failed');
          }
        }
      } finally {
        callbackError = undefined;
        settleNativeTransport();
      }
    }
    nativeTransportClosed = () => {
      for (const saved of nativePorts.values())
        nativeDisconnected(saved, 'Native messaging transport disconnected');
    };
    host.onEvent?.((name, args) => {
      if (name !== 'runtime.nativePort') return;
      const incoming = args[0];
      const saved = nativePorts.get(incoming?.portId);
      if (!saved || saved.closed) return;
      if (incoming.type === 'disconnect') nativeDisconnected(saved, incoming.error);
      else if (incoming.type === 'message')
        for (const listener of saved.message.listeners) {
          try {
            listener(incoming.message, saved.port);
          } catch (error) {
            console.error('Native messaging listener failed');
          }
        }
    });
    runtime.connectNative = (name) => {
      const id = 'native-' + crypto.randomUUID();
      const saved = { id, closed: false, message: portEvent(), disconnected: portEvent() };
      const port = (saved.port = {
        name,
        onMessage: saved.message.api,
        onDisconnect: saved.disconnected.api,
        postMessage(value) {
          if (saved.closed) throw new Error('Attempting to use a disconnected port object');
          let copy;
          try {
            copy = JSON.parse(JSON.stringify(value));
          } catch {
            throw new Error('Native messaging message is not JSON serializable');
          }
          saved.ready
            .then(() => {
              if (!saved.closed) return host.invoke('runtime.postNativeMessage', [id, copy]);
            })
            .catch((error) => nativeDisconnected(saved, error.message));
        },
        disconnect() {
          if (saved.closed) return;
          nativeDisconnected(saved, undefined, false);
          host.invoke('runtime.disconnectNative', [id]).catch(() => {});
        },
      });
      nativePorts.set(id, saved);
      nativePortCount++;
      saved.ready = host.invoke('runtime.connectNative', [name, id]);
      saved.ready.catch((error) => nativeDisconnected(saved, error.message));
      return port;
    };
    runtime.sendNativeMessage = (...args) => invoke('runtime.sendNativeMessage', args);
    runtime.openOptionsPage = (...args) => invoke('runtime.openOptionsPage', args);
    for (const [group, names] of Object.entries({
      tabs: ['onCreated', 'onUpdated', 'onActivated', 'onRemoved'],
      windows: ['onFocusChanged'],
      permissions: ['onAdded', 'onRemoved'],
      commands: ['onCommand'],
      action: ['onClicked'],
      contextMenus: ['onClicked'],
    }))
      for (const name of names) chrome[group][name] = event(group + '.' + name);
    chrome.browserAction.onClicked = chrome.action.onClicked;
    chrome.storage ||= {};
    const nativeStorageEvent = chrome.storage.onChanged;
    chrome.storage.onChanged = event('storage.onChanged', nativeStorageEvent);
    chrome.storage.sync = {
      QUOTA_BYTES: 102400,
      QUOTA_BYTES_PER_ITEM: 8192,
      MAX_ITEMS: 512,
      MAX_WRITE_OPERATIONS_PER_MINUTE: 120,
      MAX_WRITE_OPERATIONS_PER_HOUR: 1800,
      onChanged: event('storage.sync.onChanged'),
    };
    for (const name of ['get', 'getKeys', 'getBytesInUse', 'set', 'remove', 'clear', 'setAccessLevel'])
      chrome.storage.sync[name] = (...args) => invoke('storage.sync.' + name, args);
    if (typeof document === 'undefined' || chrome.extension?.getBackgroundPage?.() === globalThis)
      resubscribe();
    // The engine still performs scripting, argument serialization, frame targeting,
    // CSS insertion, and permission checks. Only add our isolated-world bootstrap.
    const scripting = chrome.scripting;
    if (scripting?.executeScript) {
      const execute = scripting.executeScript.bind(scripting);
      scripting.executeScript = (details, callback) => {
        const promise = (
          details.world === 'MAIN'
            ? Promise.resolve()
            : execute({
                target: details.target,
                files: ['zacro-compat-bootstrap.js'],
                world: 'ISOLATED',
                injectImmediately: details.injectImmediately,
              })
        ).then(() => execute(details));
        if (!callback) return promise;
        promise.then(callback, (error) => {
          callbackError = { message: error.message };
          try {
            callback();
          } finally {
            callbackError = undefined;
          }
        });
      };
      for (const name of ['registerContentScripts', 'updateContentScripts'])
        if (scripting[name]) {
          const native = scripting[name].bind(scripting);
          scripting[name] = (scripts, ...rest) =>
            native(
              scripts.map((script) => ({
                ...script,
                ...(script.world !== 'MAIN' && script.js?.length
                  ? {
                      js: [
                        'zacro-compat-bootstrap.js',
                        ...script.js.filter((file) => file !== 'zacro-compat-bootstrap.js'),
                      ],
                    }
                  : {}),
              })),
              ...rest,
            );
        }
    }
  }
})();
