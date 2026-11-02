'use strict';

// Acceptance assertions against Chromium's real API surface. The app harness
// creates the source and Peek documents and supplies their actual SessionTabIDs.
globalThis.zacroPeekFixture = (() => {
  const assert = (condition, message) => {
    if (!condition) throw new Error(`Peek acceptance: ${message}`);
  };
  async function waitFor(read, accept, message) {
    const deadline = Date.now() + 10000;
    let last;
    while (Date.now() < deadline) {
      last = await read();
      if (accept(last)) return last;
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    throw new Error(`Peek acceptance: ${message}`);
  }
  async function inspect(sourceID, peekID) {
    assert(Number.isInteger(sourceID) && Number.isInteger(peekID) && sourceID !== peekID,
      'source and preview need distinct native identities');
    const [source, preview] = await Promise.all([chrome.tabs.get(sourceID), chrome.tabs.get(peekID)]);
    assert(source.windowId === preview.windowId, 'preview belongs to source window');
    assert(preview.openerTabId === sourceID, 'preview retains source opener metadata');
    const tabs = await chrome.tabs.query({ windowId: source.windowId });
    assert(tabs.filter((tab) => tab.id === sourceID).length === 1, 'source appears once');
    assert(tabs.filter((tab) => tab.id === peekID).length === 1, 'preview appears once');
    assert(tabs.filter((tab) => tab.active).length === 1, 'window has one active document');
    assert(preview.active && preview.highlighted && !source.active,
      'presented preview is active without granting active status to source');
    return { source, preview, ids: tabs.map((tab) => tab.id) };
  }
  async function activateSourceThenPeek(sourceID, peekID) {
    const initial = await inspect(sourceID, peekID);
    await chrome.tabs.update(sourceID, { active: true });
    const hidden = await chrome.tabs.get(peekID);
    const activeSource = await chrome.tabs.query({ active: true, windowId: initial.source.windowId });
    assert(activeSource.length === 1 && activeSource[0].id === sourceID && !hidden.active,
      'source activation hides, rather than closes, preview');
    assert(hidden.url === initial.preview.url, 'hidden preview retains its destination');
    await chrome.tabs.update(peekID, { active: true });
    return inspect(sourceID, peekID);
  }
  async function documentAccess(sourceID, peekID, expectedURL) {
    const { source, preview } = await inspect(sourceID, peekID);
    const frames = await waitFor(
      () => chrome.scripting.executeScript({ target: { tabId: peekID }, func: () => ({ url: location.href, title: document.title }) }),
      (values) => values[0]?.result?.url === expectedURL,
      'scripting targets the real preview document');
    assert(frames[0].frameId === 0, 'scripting returns preview main frame');
    const sourceZoom = await chrome.tabs.getZoom(sourceID);
    const oldZoom = await chrome.tabs.getZoom(peekID);
    const oldSettings = await chrome.tabs.getZoomSettings(peekID);
    try {
      await chrome.tabs.setZoomSettings(peekID, { mode: 'automatic', scope: 'per-tab' });
      await chrome.tabs.setZoom(peekID, 1.25);
      assert(Math.abs((await chrome.tabs.getZoom(peekID)) - 1.25) < 0.001,
        'native zoom resolves the preview identity');
      assert(Math.abs((await chrome.tabs.getZoom(sourceID)) - sourceZoom) < 0.001,
        'per-tab preview zoom preserves source zoom');
    } finally {
      await chrome.tabs.setZoom(peekID, oldZoom);
      await chrome.tabs.setZoomSettings(peekID, { mode: oldSettings.mode, scope: oldSettings.scope });
    }
    const capture = await chrome.tabs.captureVisibleTab(preview.windowId, { format: 'png' });
    assert(typeof capture === 'string' && capture.startsWith('data:image/png;base64,') && capture.length > 100,
      'visible-window capture resolves the active preview');
    return { sourceID: source.id, peekID: preview.id, frame: frames[0], capture };
  }
  async function promoteByPinning(sourceID, peekID) {
    const initial = await inspect(sourceID, peekID);
    const events = [];
    const created = (tab) => events.push({ kind: 'created', id: tab.id });
    const removed = (id) => events.push({ kind: 'removed', id });
    const updated = (id, change) => events.push({ kind: 'updated', id, pinned: change.pinned });
    chrome.tabs.onCreated.addListener(created);
    chrome.tabs.onRemoved.addListener(removed);
    chrome.tabs.onUpdated.addListener(updated);
    try {
      const result = await chrome.tabs.update(peekID, { pinned: true });
      assert(result.id === peekID && result.pinned && result.url === initial.preview.url,
        'structural promotion preserves native identity and destination');
      await waitFor(() => Promise.resolve(events),
        (values) => values.some((event) => event.kind === 'updated' && event.id === peekID && event.pinned === true),
        'promotion publishes an update on the original native identity');
      assert(!events.some((event) => event.id === peekID && ['created', 'removed'].includes(event.kind)),
        'promotion must not fabricate removal or recreation');
      const retained = await chrome.tabs.get(sourceID);
      assert(retained.url === initial.source.url, 'promotion retains underlying source document');
      return { result, events };
    } finally {
      chrome.tabs.onCreated.removeListener(created);
      chrome.tabs.onRemoved.removeListener(removed);
      chrome.tabs.onUpdated.removeListener(updated);
    }
  }
  async function closePreview(sourceID, peekID) {
    const initial = await inspect(sourceID, peekID);
    await chrome.tabs.remove(peekID);
    let missing = false;
    try { await chrome.tabs.get(peekID); } catch { missing = true; }
    assert(missing, 'accepted preview close retires only its own identity');
    const source = await chrome.tabs.get(sourceID);
    assert(source.active && source.url === initial.source.url, 'source survives preview close and becomes active');
    return source;
  }
  return { inspect, activateSourceThenPeek, documentAccess, promoteByPinning, closePreview };
})();
