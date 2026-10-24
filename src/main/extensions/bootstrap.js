'use strict';
// Original native-runtime-only facade; it has no Electron IPC or host token.
(() => {
  const runtime = globalThis.chrome?.runtime;
  if (!runtime?.id) return;
  const namespace = 'zacro.extension.transport.v1';
  // Native document-targeted messaging is a liveness check, not an identity
  // claim from page data. Chromium selects the recipient by documentId.
  const messageEvent = runtime.onMessage;
  const messageAdd = messageEvent.addListener.bind(messageEvent);
  const messageRemove = messageEvent.removeListener.bind(messageEvent);
  const messageHas = messageEvent.hasListener.bind(messageEvent);
  const documentCheck = (message) => message?.namespace === 'zacro.extension.document.v1';
  messageAdd((message, sender, reply) => {
    if (
      documentCheck(message) &&
      sender.id === runtime.id &&
      sender.url === runtime.getURL('zacro-compat-transport.html')
    )
      reply(true);
  });
  const messageListeners = new WeakMap();
  messageEvent.addListener = (listener) => {
    let wrapper = messageListeners.get(listener);
    if (!wrapper) {
      wrapper = (...args) => {
        if (!documentCheck(args[0])) return listener(...args);
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
  if (globalThis.zacroExtension) return;
  const connect = runtime.connect.bind(runtime);
  let ready,
    nextId = 1;
  function open() {
    const port = connect({ name: namespace });
    const pending = new Map();
    let closed = false;
    const fail = () => {
      closed = true;
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
      const request = pending.get(message?.id);
      if (!request) return;
      pending.delete(message.id);
      clearTimeout(request.timer);
      message.error ? request.reject(new Error(message.error)) : request.resolve(message.value);
    });
    return {
      close() {
        port.disconnect();
        fail();
      },
      request(payload, timeout = 10000) {
        if (closed) return Promise.reject(new Error('Extension transport disconnected'));
        const id = nextId++;
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error('Extension transport deadline exceeded'));
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
  }
  async function initialize() {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      let connection;
      try {
        connection = open();
        await connection.request({ hello: true }, 150);
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
      async invoke(method, args, ...extra) {
        if (extra.length) throw new Error('Caller identity is not accepted');
        ready ||= initialize();
        return (await ready).request({ method, args });
      },
    }),
  });
})();
