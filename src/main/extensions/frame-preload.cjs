'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const runtimeOnly =
  location.protocol === 'chrome-extension:' &&
  process.contextIsolated &&
  contextBridge.executeInMainWorld({
    func: () => !!globalThis.chrome?.runtime && !chrome.storage && !chrome.tabs,
  });
if (
  location.protocol === 'chrome-extension:' &&
  process.contextIsolated &&
  !runtimeOnly &&
  location.pathname !== '/zacro-native-services.html'
) {
  if (location.pathname !== '/zacro-compat-transport.html')
    contextBridge.executeInMainWorld({
      func: () => {
        const event = chrome.runtime.onConnect;
        const add = event.addListener.bind(event),
          remove = event.removeListener.bind(event),
          has = event.hasListener.bind(event);
        const listeners = new WeakMap();
        event.addListener = (listener) => {
          let wrapper = listeners.get(listener);
          if (!wrapper) {
            wrapper = (port) => {
              if (port.name !== 'zacro.extension.transport.v1') return listener(port);
            };
            listeners.set(listener, wrapper);
          }
          return add(wrapper);
        };
        event.removeListener = (listener) => remove(listeners.get(listener) || listener);
        event.hasListener = (listener) => has(listeners.get(listener) || listener);
      },
    });
  const channel = 'zacro:extension-transport:v1';
  const connected = ipcRenderer.invoke(channel, { operation: 'connect' });
  // A rejection remains observable to consumers without an unhandled rejection.
  connected.catch(() => {});
  contextBridge.exposeInMainWorld('zacroExtension', {
    onEvent(listener) {
      const handler = async (_event, message) => {
        if (message.token === (await connected)) listener(message.event, message.args);
      };
      ipcRenderer.on(channel + ':event', handler);
      return () => ipcRenderer.removeListener(channel + ':event', handler);
    },
    async invoke(method, args, ...extra) {
      if (extra.length) throw new Error('Caller identity is not accepted');
      return ipcRenderer.invoke(channel, { operation: 'invoke', token: await connected, method, args });
    },
  });
}
