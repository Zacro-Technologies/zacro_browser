'use strict';
// Original native-runtime-only facade; it has no Electron IPC or host token.
(() => {
  const runtime = globalThis.chrome?.runtime;
  if (!runtime?.id || globalThis.__zacroFacadeInstalled) return;
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
        if (background && !pending.size && !closed && !connection.retiring)
          idle = setTimeout(() => connection.retire(), 100);
      };
      const fail = () => {
        closed = true;
        clearTimeout(idle);
        if (active === connection) {
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
        retire() {
          if (closed || pending.size || connection.retiring) return;
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
          return connection.request({ method, args });
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
          name === 'storage.sync.set' ||
          (name === 'storage.sync.get' && args[0] && typeof args[0] === 'object')
        )
          validate(args[0]);
        return host.invoke(name, args);
      });
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
    methods('contextMenus', ['update', 'remove', 'removeAll']);
    let menuId = 0;
    chrome.contextMenus.create = (properties, callback) => {
      const id = properties.id ?? 'zacro-generated-' + ++menuId;
      const props = { ...properties, id };
      if (props.onclick) throw new Error('Use contextMenus.onClicked');
      const promise = invoke('contextMenus.create', [props, ...(callback ? [callback] : [])]);
      promise?.catch(console.error);
      return id;
    };
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
