'use strict';

// No bridge is exposed to web pages. Trusted user links can request a preview;
// the host validates the sender, current document and target independently.
const { ipcRenderer } = require('electron');
let pinNavigation = null;
let documentIdentity = null;
ipcRenderer.on('zacro:pin-state', (_event, state) => {
  documentIdentity = typeof state?.documentId === 'string' ? state.documentId : null;
  pinNavigation =
    state && typeof state.documentId === 'string' && typeof state.pinnedUrl === 'string' ? state : null;
});
// Only report that the user edited something, never the value or field name.
// Capture also covers controls inside shadow roots; synthetic page events do
// not receive this protection signal. The host resets it after navigation.
for (const type of ['input', 'change'])
  window.addEventListener(
    type,
    (event) => {
      if (event.isTrusted) ipcRenderer.send('zacro:page-dirty');
    },
    true,
  );
window.addEventListener(
  'click',
  (event) => {
    const previewModifier = event.shiftKey !== event.altKey;
    if (
      !documentIdentity ||
      !event.isTrusted ||
      !previewModifier ||
      event.ctrlKey ||
      event.metaKey ||
      event.button !== 0
    )
      return;
    const link = event.composedPath().find((node) => node?.tagName === 'A' && node.href);
    if (!link || link.hasAttribute('download')) return;
    try {
      const url = new URL(link.href);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      ipcRenderer.send('zacro:peek-link', {
        documentId: documentIdentity,
        sourceURL: location.href,
        url: url.href,
        origin: { x: event.clientX, y: event.clientY },
      });
    } catch {
      /* malformed web content is ignored */
    }
  },
  true,
);

// Ordinary external-host links from a saved tab open in Peek. Bubble-phase
// handling lets site handlers keep their own preventDefault/popup flows. Forms,
// redirects, named windows, downloads and modified clicks retain Chromium's
// normal behavior. This is a browsing affordance, never a navigation firewall.
window.addEventListener('click', (event) => {
  if (
    !pinNavigation ||
    !event.isTrusted ||
    event.defaultPrevented ||
    event.button !== 0 ||
    event.altKey ||
    event.ctrlKey ||
    event.metaKey ||
    event.shiftKey
  )
    return;
  const link = event.composedPath().find((node) => node?.tagName === 'A' && node.href);
  if (
    !link ||
    link.hasAttribute('download') ||
    (link.target && link.target.toLowerCase() !== '_self') ||
    /(?:^|\s)(?:noopener|noreferrer)(?:\s|$)/i.test(link.rel || '')
  )
    return;
  try {
    const target = new URL(link.href);
    const home = new URL(pinNavigation.pinnedUrl);
    if (
      !['http:', 'https:'].includes(target.protocol) ||
      target.username ||
      target.password ||
      target.hostname.replace(/^www\./, '') === home.hostname.replace(/^www\./, '')
    )
      return;
    event.preventDefault();
    ipcRenderer.send('zacro:pin-peek-link', {
      documentId: pinNavigation.documentId,
      sourceURL: location.href,
      url: target.href,
      origin: { x: event.clientX, y: event.clientY },
    });
  } catch {
    /* malformed web content is ignored */
  }
});
