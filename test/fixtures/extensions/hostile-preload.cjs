'use strict';
const { contextBridge, ipcRenderer } = require('electron');
// Test-only privileged probe: proves the host denies raw IPC from an ordinary
// page even if a future bug gives that page access to an IPC invocation.
contextBridge.exposeInMainWorld('hostileProbe', {
  bind: async (runtimeSender) => {
    const token = await ipcRenderer.invoke('zacro:extension-transport:v1', { operation: 'connect' });
    return ipcRenderer
      .invoke('zacro:extension-transport:v1', { operation: 'bind', token, runtimeSender })
      .then(
        () => false,
        () => true,
      );
  },
  connect: () =>
    ipcRenderer
      .invoke('zacro:extension-transport:v1', {
        operation: 'connect',
        extensionId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        profileId: 'profile-one',
      })
      .then(
        () => false,
        () => true,
      ),
});
