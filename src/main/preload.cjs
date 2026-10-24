'use strict';

const { contextBridge, ipcRenderer } = require('electron');

// A deliberately small capability surface, exposed only to Zacro's own UI.
const subscribe = (channel, callback) => {
  if (typeof callback !== 'function') throw new TypeError('A callback is required.');
  const listener = (_event, value) => callback(value);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};
contextBridge.exposeInMainWorld(
  'zacro',
  Object.freeze({
    platform: process.platform,
    invoke: (action, payload = {}) => ipcRenderer.invoke('zacro:invoke', action, payload),
    onState: (callback) => subscribe('zacro:state', callback),
    onEvent: (callback) => subscribe('zacro:event', callback),
  }),
);
