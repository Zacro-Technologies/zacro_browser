'use strict';

// No bridge is exposed to web pages. Only a trusted user's Alt-click may
// request a preview. The host validates the sender and target independently.
const { ipcRenderer } = require('electron');
window.addEventListener(
  'click',
  (event) => {
    if (!event.isTrusted || !event.altKey || event.button !== 0) return;
    const link = event.composedPath().find((node) => node?.tagName === 'A' && node.href);
    if (!link) return;
    try {
      const url = new URL(link.href);
      if (!['http:', 'https:'].includes(url.protocol)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      ipcRenderer.send('zacro:peek-link', url.href);
    } catch {
      /* malformed web content is ignored */
    }
  },
  true,
);
