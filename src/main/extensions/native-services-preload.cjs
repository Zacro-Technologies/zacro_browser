'use strict';
const { contextBridge, ipcRenderer } = require('electron');
// The callback remains in a private native-listener closure. No extension view
// can borrow a global sender function to impersonate this owned WebContents.
contextBridge.executeInMainWorld({
  func: (send) => {
    chrome.alarms?.onAlarm.addListener((alarm) => send(alarm).catch(console.error));
  },
  args: [(alarm) => ipcRenderer.invoke('zacro:native-extension-alarm:v1', alarm)],
});
