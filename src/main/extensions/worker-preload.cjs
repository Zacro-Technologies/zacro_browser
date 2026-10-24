'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const protocol = contextBridge.executeInMainWorld({ func: () => globalThis.location.protocol });
if (protocol === 'chrome-extension:') {
  const channel = 'zacro:extension-transport:v1';
  const connected = ipcRenderer.invoke(channel, { operation: 'connect' });
  connected.catch(() => {});
  contextBridge.exposeInMainWorld('zacroExtension', {
    async invoke(method, args, ...extra) {
      if (extra.length) throw new Error('Caller identity is not accepted');
      return ipcRenderer.invoke(channel, { operation: 'invoke', token: await connected, method, args });
    },
  });
}
