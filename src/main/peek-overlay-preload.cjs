'use strict';

const { contextBridge, ipcRenderer } = require('electron');

let current = null;
const listeners = new Set();
ipcRenderer.on('zacro:peek-overlay-state', (_event, state) => {
  current = state;
  for (const listener of listeners) listener(state);
});

contextBridge.exposeInMainWorld('peekOverlay', {
  onState(listener) {
    if (typeof listener !== 'function') return () => {};
    listeners.add(listener);
    if (current) listener(current);
    return () => listeners.delete(listener);
  },
  act(action) {
    const allowed =
      current?.mode === 'sidebar'
        ? ['sidebar-toggle']
        : ['close', 'promote', 'reload', ...(current?.sidebarHidden ? ['sidebar-toggle'] : [])];
    if (!current?.id || !allowed.includes(action)) return;
    ipcRenderer.send('zacro:peek-overlay-action', { id: current.id, action });
  },
});
