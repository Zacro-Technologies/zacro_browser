'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('zacro', {
  platform: 'darwin',
  invoke: (action, payload = {}) => ipcRenderer.invoke('fixture:invoke', action, payload),
  onState: (callback) => ipcRenderer.on('fixture:state', (_event, state) => callback(state)),
  onEvent: () => {},
});
