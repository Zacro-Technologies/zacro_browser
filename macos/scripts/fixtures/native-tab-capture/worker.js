'use strict';
// The harness must grant tabCapture through the real native action on each
// positive target. Script execution and host permission alone must not grant it.
globalThis.zacroTabCaptureFixture = (() => {
  const events = [], actions = [];
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  let consumerTabID;
  chrome.tabCapture.onStatusChanged.addListener(info => {
    events.push({...info}); if (events.length > 100) events.shift();
  });
  chrome.action.onClicked.addListener(tab => {
    actions.push({id: tab.id, windowId: tab.windowId}); if (actions.length > 20) actions.shift();
  });
  async function until(read, description) {
    const end = Date.now() + 10000;
    while (Date.now() < end) { const result = await read(); if (result) return result; await pause(40); }
    throw new Error(description);
  }
  async function message(route, operation, payload = {}) {
    const reply = await chrome.runtime.sendMessage({channel: 'zacro-tab-capture', route, operation, ...payload});
    assert(reply?.ok, reply?.error || 'Owned capture consumer did not respond');
    return reply.value;
  }
  async function setup(windowID) {
    assert(Number.isInteger(windowID) && windowID > 0, 'An existing owned logical window is required');
    const tab = await chrome.tabs.create({windowId: windowID,
      url: chrome.runtime.getURL('consumer.html'), active: false});
    consumerTabID = tab.id;
    await until(async () => {
      try { return (await chrome.runtime.sendMessage({channel: 'zacro-tab-capture', route: 'document', operation: 'ping'}))?.ready; }
      catch { return false; }
    }, 'Owned extension document did not load');
    await chrome.offscreen.createDocument({url: 'offscreen.html', reasons: ['USER_MEDIA'],
      justification: 'Decode a disposable owned tab capture stream to verify its native target'});
    await until(async () => {
      try { return (await chrome.runtime.sendMessage({channel: 'zacro-tab-capture', route: 'offscreen', operation: 'ping'}))?.ready; }
      catch { return false; }
    }, 'Owned offscreen document did not load');
    return {consumerTabID};
  }
  async function paint(tabID, rgb) {
    const tab = await chrome.tabs.get(tabID);
    const url = new URL(tab.url);
    assert(url.protocol === 'http:' && url.hostname === '127.0.0.1', 'Only owned loopback pages may be painted');
    assert(Array.isArray(rgb) && rgb.length === 3 && rgb.every(x => Number.isInteger(x) && x >= 0 && x <= 255), 'Invalid color');
    await chrome.scripting.executeScript({target: {tabId: tabID}, args: [rgb], func: rgb => {
      document.documentElement.style.cssText = 'margin:0;width:100%;height:100%;overflow:hidden';
      document.body.style.cssText = `margin:0;width:100vw;height:100vh;background:rgb(${rgb.join(',')})`;
      document.body.replaceChildren();
      // Animated content gives the real capture track fresh frames; the center
      // remains the exact unique target color throughout the measurement.
      const corner = document.createElement('div');
      corner.style.cssText = 'position:fixed;top:0;left:0;width:4px;height:4px;background:white';
      document.body.append(corner);
      let tick = 0; const animate = () => { corner.style.opacity = (++tick % 2) ? '1' : '0'; requestAnimationFrame(animate); };
      requestAnimationFrame(animate);
    }});
  }
  async function capture({expectedTabID, expectedRGB, explicit = false, legacy = false}) {
    const before = events.length;
    const tab = await chrome.tabs.get(expectedTabID);
    if (!explicit) {
      const active = await chrome.tabs.query({active: true, lastFocusedWindow: true});
      assert(active.length === 1 && active[0].id === expectedTabID, 'Logical default target is not selected');
    }
    try {
      let value;
      if (legacy) value = await message('document', 'legacy', {expectedRGB});
      else {
        const streamID = await chrome.tabCapture.getMediaStreamId(explicit ? {targetTabId: expectedTabID} : {});
        value = await message('offscreen', 'consume', {streamID, expectedRGB});
      }
      const active = await until(() => events.slice(before).find(event => event.status === 'active'),
        'No actual native capture-active event');
      assert(active.tabId === expectedTabID, 'Capture registry attributes the stream to another tab');
      assert(value.frames >= 2 && value.trackState === 'live', 'No actual live captured video frames');
      await until(() => events.slice(before).some(event => event.tabId === expectedTabID && event.status === 'stopped'),
        'Capture stream did not stop after cleanup');
      return {target: tab.id, windowID: tab.windowId, legacy, explicit, ...value, events: events.slice(before)};
    } catch (error) {
      const diagnostic = {expectedTabID, windowID: tab.windowId, legacy, explicit,
        events: events.slice(before)};
      throw new Error(`${String(error.message || error)}; native capture diagnostic=${JSON.stringify(diagnostic)}`);
    }
  }
  async function expectDenied(targetTabID) {
    try { await chrome.tabCapture.getMediaStreamId({targetTabId}); }
    catch (error) { return {denied: true, message: String(error.message || error)}; }
    throw new Error('Capture was granted without a real native action or for an engine-only target');
  }
  async function cleanup() {
    if (await chrome.offscreen.hasDocument()) await chrome.offscreen.closeDocument();
    if (consumerTabID !== undefined) { try { await chrome.tabs.remove(consumerTabID); } finally { consumerTabID = undefined; } }
  }
  return {setup, paint, capture, expectDenied, cleanup, actions, events};
})();
