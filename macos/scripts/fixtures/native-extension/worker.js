/* Real MV3 APIs only. Loaded solely into a fresh disposable acceptance profile. */
importScripts('peek.js');
importScripts('network.js');
importScripts('identity.js');
importScripts('native-messaging.js');
importScripts('download-retirement.js');
const events = [];
const record = (name, ...args) => {
  events.push({ name, args });
  if (events.length > 512) events.shift();
};
for (const name of ["onCreated", "onUpdated", "onRemoved", "onActivated", "onMoved", "onAttached", "onDetached", "onHighlighted"]) {
  chrome.tabs[name].addListener((...args) => record(`tabs.${name}`, ...args));
}
for (const name of ["onCreated", "onRemoved", "onFocusChanged", "onBoundsChanged"]) {
  chrome.windows[name].addListener((...args) => record(`windows.${name}`, ...args));
}
for (const name of ["onCreated", "onUpdated", "onMoved", "onRemoved"]) {
  chrome.tabGroups[name].addListener((...args) => record(`tabGroups.${name}`, ...args));
}
chrome.storage.onChanged.addListener((changes, area) => record("storage.onChanged", changes, area));
let commandWrite = Promise.resolve();
chrome.commands.onCommand.addListener((name, tab) => {
  record("commands.onCommand", name, tab);
  // Serialize storage updates so repeated actual shortcuts cannot lose counts.
  commandWrite = commandWrite.then(async () => {
    const { nativeCommandCount = 0 } = await chrome.storage.local.get("nativeCommandCount");
    await chrome.storage.local.set({ nativeCommandCount: nativeCommandCount + 1,
      lastNativeCommand: { name, tab } });
  });
});
let nativeActionMode = "record";
let nativePanelAttempt = null;
const panelEventObservers = Object.fromEntries(["onOpened", "onClosed"].map(name =>
  [name, info => record(`sidePanel.${name}`, info)]));
for (const [name, listener] of Object.entries(panelEventObservers)) chrome.sidePanel[name].addListener(listener);
chrome.action.onClicked.addListener(async tab => {
  const attempt = { mode: nativeActionMode, tab, receivedAt: Date.now(), open: "not-requested" };
  nativePanelAttempt = attempt;
  // Invoke in the real action event's user-gesture scope before awaiting work.
  if (nativeActionMode === "panel") {
    attempt.open = "pending";
    chrome.sidePanel.open({ windowId: tab.windowId }).then(() => {
      attempt.open = "resolved";
    }).catch(error => {
      attempt.open = "rejected"; attempt.error = String(error);
      chrome.storage.local.set({ nativePanelError: String(error) });
    });
  }
  await chrome.storage.local.set({ lastNativeAction: tab });
  await chrome.action.setBadgeText({ text: "OK", tabId: tab.id });
  await chrome.action.setBadgeBackgroundColor({ color: "#635BFF", tabId: tab.id });
});
chrome.runtime.onInstalled.addListener(async () => {
  await chrome.storage.sync.set({ nativeFixtureInstalled: true });
});

const assert = (value, message) => { if (!value) throw new Error(message); };
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function loaded(tabId) {
  const end = Date.now() + 15000;
  while (Date.now() < end) {
    const tab = await chrome.tabs.get(tabId);
    if (tab.status === "complete") return tab;
    await wait(40);
  }
  throw new Error(`Tab ${tabId} did not finish loading`);
}

globalThis.zacroAcceptance = {
  events,
  setPanelEventObservation(enabled) {
    for (const [name, listener] of Object.entries(panelEventObservers)) {
      chrome.sidePanel[name][enabled ? "addListener" : "removeListener"](listener);
      assert(chrome.sidePanel[name].hasListener(listener) === enabled, "Panel listener state did not change");
    }
    return true;
  },
  async commandResult() {
    await commandWrite;
    return await chrome.storage.local.get(["nativeCommandCount", "lastNativeCommand"]);
  },
  async optionsResult() {
    const end = Date.now() + 10000;
    while (Date.now() < end) {
      try {
        const result = await chrome.runtime.sendMessage({ type: "zacro-native-options" });
        if (result?.instance && result?.tab && result?.window) return result;
        await wait(40);
      }
      catch { await wait(40); }
    }
    throw new Error("The managed native options document did not become ready");
  },
  async configureAction(mode = "record") {
    assert(["record", "popup", "panel"].includes(mode), "Unknown action fixture mode");
    nativeActionMode = mode;
    nativePanelAttempt = null;
    await chrome.storage.local.remove(["nativePopupResult", "nativePanelError"]);
    await chrome.action.setPopup({ popup: mode === "popup" ? "popup.html" : "" });
    await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: false });
    return true;
  },
  async popupResult() {
    const end = Date.now() + 10000;
    while (Date.now() < end) {
      const { nativePopupResult } = await chrome.storage.local.get("nativePopupResult");
      if (nativePopupResult) {
        assert(nativePopupResult.contexts.length === 1 && nativePopupResult.contexts[0].contextType === "POPUP",
          "Action did not create an actual Chrome popup context");
        return nativePopupResult;
      }
      await wait(40);
    }
    throw new Error("Native action popup did not load");
  },
  async openPopup(windowID, deniedTabID = null) {
    await this.configureAction("popup");
    if (windowID == null) await chrome.action.openPopup();
    else await chrome.action.openPopup({ windowId: windowID });
    const result = await this.popupResult();
    if (deniedTabID != null) {
      let granted = false;
      try {
        await chrome.scripting.executeScript({ target: { tabId: deniedTabID }, func: () => location.href });
        granted = true;
      } catch { /* A public openPopup call is not a toolbar user action. */ }
      assert(!granted, "action.openPopup incorrectly granted activeTab on an unauthorized origin");
    }
    return result;
  },
  async closePopup() {
    const result = await chrome.runtime.sendMessage({ type: "zacro-native-close-popup" });
    assert(result?.closing === true, "The real popup did not acknowledge closing");
    const end = Date.now() + 5000;
    while (Date.now() < end) {
      if (!(await chrome.runtime.getContexts({ contextTypes: ["POPUP"] })).length) return true;
      await wait(30);
    }
    throw new Error("The real action popup did not close");
  },
  async panelState(draft) {
    const end = Date.now() + 10000;
    let lastContexts = [], lastMessageError = null, lastResponse = null;
    while (Date.now() < end) {
      const { nativePanelError } = await chrome.storage.local.get("nativePanelError");
      assert(!nativePanelError, nativePanelError);
      const contexts = await chrome.runtime.getContexts({ contextTypes: ["SIDE_PANEL"] });
      lastContexts = contexts;
      if (contexts.length) {
        assert(contexts.length === 1, "Global panel was recreated in another physical window");
        try {
          const response = await chrome.runtime.sendMessage({ type: "zacro-native-panel", draft });
          lastResponse = response ?? null;
          // The native context exists before its document installs the message
          // listener. No response can resolve as undefined instead of throwing.
          if (typeof response?.instance === "string" && typeof response?.draft === "string"
              && Number.isInteger(response?.windowID)) return { ...response, contexts };
        } catch (error) {
          // The first load may not have installed the listener yet. Retain
          // the real error for a causal failure report if it never does.
          lastMessageError = String(error);
        }
      }
      await wait(40);
    }
    throw new Error("Native side panel did not load: " + JSON.stringify({
      configuredMode: nativeActionMode, action: nativePanelAttempt, contexts: lastContexts, lastMessageError, lastResponse,
      events: events.filter(event => event.name.startsWith("sidePanel.")).slice(-8),
    }));
  },
  async closePanel(windowID) { await chrome.sidePanel.close({ windowId: windowID }); return true; },
  async seedDownload(baseURL) {
    const url = new URL("download", baseURL);
    assert(url.protocol === "http:" && url.hostname === "127.0.0.1", "Download fixture requires loopback");
    const filename = `zacro-native-acceptance-${crypto.randomUUID()}.bin`;
    const id = await chrome.downloads.download({ url: url.href, filename, conflictAction: "uniquify", saveAs: false });
    return { id, filename, url: url.href };
  },
  async downloadState(id) {
    const values = await chrome.downloads.search({ id });
    assert(values.length === 1, "Native worker download disappeared");
    return values[0];
  },
  async cleanupDownload(id) {
    const values = await chrome.downloads.search({ id });
    if (!values.length) return true;
    assert(/(?:^|[\\/])zacro-native-acceptance-[a-f0-9-]+(?: \(\d+\))?\.bin$/.test(values[0].filename),
      "Refusing to remove a nonfixture download");
    if (values[0].state === "in_progress") await chrome.downloads.cancel(id);
    if (values[0].state === "complete" && values[0].exists) await chrome.downloads.removeFile(id);
    await chrome.downloads.erase({ id });
    return true;
  },
  async seedHistory(baseURL) {
    const url = new URL("native-history-marker", baseURL).href;
    await chrome.history.addUrl({ url });
    assert((await chrome.history.getVisits({ url })).length > 0, "Native history visit was not created");
    return url;
  },
  async verifyHistoryCleared(url) {
    assert((await chrome.history.getVisits({ url })).length === 0, "Native history survived the browser history clear");
    assert((await chrome.history.search({ text: "native-history-marker", startTime: 0 })).length === 0,
      "Native history search retained the cleared visit");
    return true;
  },
  async run({ baseURL, sourceWindowID, groups = true }) {
    const origin = new URL(baseURL);
    assert(origin.protocol === "http:" && origin.hostname === "127.0.0.1", "Fixture requires a loopback server");
    const checks = {};
    const errors = {};
    const created = [];
    const windows = [];
    const check = async (name, body) => {
      try { await body(); checks[name] = true; }
      catch (error) { checks[name] = false; errors[name] = String(error?.message || error); }
    };
    let first, second, other, group;
    await check("logicalTabsAndSelection", async () => {
      first = await chrome.tabs.create({ windowId: sourceWindowID, url: new URL("native-one", origin).href, active: true });
      created.push(first.id);
      second = await chrome.tabs.create({ windowId: sourceWindowID, url: new URL("native-two", origin).href, active: false });
      created.push(second.id);
      assert(first.id !== second.id && first.windowId === sourceWindowID, "Wrong native logical identities");
      const tabs = await chrome.tabs.query({ windowId: sourceWindowID });
      assert(tabs.some(tab => tab.id === first.id) && tabs.some(tab => tab.id === second.id), "Query lost logical tabs");
      assert((await chrome.tabs.get(first.id)).active, "Foreground tab is not selected");
    });
    await check("retainedDocumentAndScripting", async () => {
      assert(first, "Creation prerequisite failed");
      await loaded(first.id);
      const result = await chrome.scripting.executeScript({ target: { tabId: first.id }, func: () => {
        const input = document.createElement("input"); input.id = "native-extension-draft";
        input.value = "retained-extension-form"; document.body.append(input);
        return location.href;
      }});
      assert(result[0].result === first.url, "Script ran in the wrong document");
    });
    await check("logicalWindowCreationAndTransfer", async () => {
      assert(first && second, "Creation prerequisite failed");
      other = await chrome.windows.create({ type: "normal", url: new URL("native-window", origin).href, focused: false });
      windows.push(other.id);
      assert(other.id !== sourceWindowID && other.tabs?.length === 1, "Wrong window or initial tab model");
      const moved = await chrome.tabs.move(first.id, { windowId: other.id, index: -1 });
      assert(moved.id === first.id && moved.windowId === other.id, "Window transfer changed native tab identity");
      const result = await chrome.scripting.executeScript({ target: { tabId: first.id }, func: () =>
        document.querySelector("#native-extension-draft")?.value });
      assert(result[0].result === "retained-extension-form", "Moving a tab replaced its live document");
      await chrome.tabs.move(second.id, { windowId: other.id, index: -1 });
    });
    await check("multipleHighlightedTabs", async () => {
      assert(other && first && second, "Window prerequisite failed");
      const a = await chrome.tabs.get(first.id), b = await chrome.tabs.get(second.id);
      await chrome.tabs.highlight({ windowId: other.id, tabs: [a.index, b.index] });
      const selected = await chrome.tabs.query({ windowId: other.id, highlighted: true });
      assert(selected.some(tab => tab.id === first.id) && selected.some(tab => tab.id === second.id), "Highlight selection was collapsed");
    });
    if (groups) await check("nativeTabGroups", async () => {
      assert(first && second && other, "Tab prerequisite failed");
      try {
        // Without createProperties Chrome moves members into the current window,
        // which need not be the window that currently owns these two tabs.
        group = await chrome.tabs.group({ tabIds: [first.id, second.id], createProperties: { windowId: other.id } });
        await chrome.tabGroups.update(group, { title: "Zacro α group", color: "purple", collapsed: true });
        const matching = await chrome.tabGroups.query({ windowId: other.id, title: "Zacro ? group", color: "purple", collapsed: true });
        assert(matching.length === 1 && matching[0].id === group && matching[0].shared === false,
          `Group identity/filter mismatch: ${JSON.stringify({ group, windowID: other.id, matching })}`);
        assert((await chrome.tabs.get(first.id)).groupId === group, "Tab group decoration missing");
        const moved = await chrome.tabGroups.move(group, { windowId: sourceWindowID, index: -1 });
        assert(moved.id === group && moved.windowId === sourceWindowID, "Group transfer changed identity");
        assert((await chrome.tabs.get(second.id)).windowId === sourceWindowID, "Group member did not transfer");
        await chrome.tabs.ungroup([first.id, second.id]);
        assert((await chrome.tabs.get(first.id)).groupId === -1, "Ungroup left stale metadata");
        const current = await chrome.windows.getCurrent();
        const defaultGroup = await chrome.tabs.group({ tabIds: [first.id, second.id] });
        assert((await chrome.tabGroups.get(defaultGroup)).windowId === current.id,
          "A new group without a window override ignored the current window");
      } finally {
        // A failed group assertion must not leave a collapsed group affecting
        // later document/discard tests in this aggregate fixture.
        await chrome.tabs.ungroup([first.id, second.id]);
        await chrome.tabs.move([first.id, second.id], { windowId: sourceWindowID, index: -1 });
      }
    });
    await check("nativeZoomController", async () => {
      assert(first, "Tab prerequisite failed");
      await chrome.tabs.update(first.id, { active: true });
      await chrome.tabs.setZoom(first.id, 1.25);
      assert(Math.abs(await chrome.tabs.getZoom(first.id) - 1.25) < 0.01, "Zoom did not reach Chromium");
      const settings = await chrome.tabs.getZoomSettings(first.id);
      assert(settings.mode === "automatic", "Missing native zoom settings");
      await chrome.tabs.setZoom(first.id, 0);
    });
    await check("siteUnloadHandlersStillProtectDiscard", async () => {
      assert(first, "Tab prerequisite failed");
      const tab = await chrome.tabs.create({ windowId: sourceWindowID,
        url: new URL("native-protected-sleeper", origin).href, active: true });
      created.push(tab.id); await loaded(tab.id);
      await chrome.tabs.update(first.id, { active: true });
      for (const event of ["pagehide", "beforeunload"]) {
        await chrome.scripting.executeScript({ target: { tabId: tab.id }, args: [event], func: kind => {
          globalThis.__ownedDiscardHandler = () => {};
          window.addEventListener(kind, globalThis.__ownedDiscardHandler);
        }});
        try {
          let refused = false;
          try { await chrome.tabs.discard(tab.id); } catch (_) { refused = true; }
          assert(refused, `A site's ${event} handler was ignored`);
          const retained = await chrome.tabs.get(tab.id);
          assert(retained.id === tab.id && !retained.discarded && retained.url === tab.url,
            `Rejected ${event} discard changed the retained document`);
        } finally {
          await chrome.scripting.executeScript({ target: { tabId: tab.id }, args: [event], func: kind => {
            window.removeEventListener(kind, globalThis.__ownedDiscardHandler);
            delete globalThis.__ownedDiscardHandler;
          }});
        }
      }
      const sleeping = await chrome.tabs.discard(tab.id);
      assert(sleeping.id === tab.id && sleeping.discarded,
        "Clean retry remained blocked by the restored browser-owned adapter");
      const restored = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => location.href });
      assert(restored[0].result === tab.url, "Protected discard retry did not restore the original document");
    });
    await check("dormantNativeDocumentAPI", async () => {
      assert(first, "Tab prerequisite failed");
      const sleeper = await chrome.tabs.create({ windowId: sourceWindowID, url: new URL("native-sleeper", origin).href, active: true });
      created.push(sleeper.id); await loaded(sleeper.id);
      await chrome.tabs.update(first.id, { active: true });
      const sleeping = await chrome.tabs.discard(sleeper.id);
      assert(sleeping.id === sleeper.id && sleeping.discarded, "Sleeping changed the native tab identity");
      const zoom = await chrome.tabs.getZoom(sleeper.id);
      assert(Number.isFinite(zoom) && zoom > 0, "Dormant API did not resume the actual native function");
      assert((await chrome.tabs.get(sleeper.id)).id === sleeper.id, "Waking replaced the native tab identity");
      const sleepAgain = async () => {
        const value = await chrome.tabs.discard(sleeper.id);
        assert(value.id === sleeper.id && value.discarded, "Native document did not return to sleep");
      };
      await sleepAgain();
      const script = await chrome.scripting.executeScript({ target: { tabId: sleeper.id }, func: () => location.href });
      assert(script[0].result === sleeper.url, "Scripting did not restore the intended dormant document");
      await sleepAgain();
      const css = "body { --zacro-native-wake: restored; }";
      await chrome.scripting.insertCSS({ target: { tabId: sleeper.id }, css });
      const style = await chrome.scripting.executeScript({ target: { tabId: sleeper.id },
        func: () => getComputedStyle(document.body).getPropertyValue("--zacro-native-wake").trim() });
      assert(style[0].result === "restored", "CSS injection ran before native document restoration");
      await sleepAgain();
      await chrome.scripting.removeCSS({ target: { tabId: sleeper.id }, css });
      assert(!(await chrome.tabs.get(sleeper.id)).discarded, "CSS removal did not prepare the dormant document");
      await sleepAgain();
      const target = { tabId: sleeper.id };
      await chrome.debugger.attach(target, "1.3");
      try {
        const result = await chrome.debugger.sendCommand(target, "Runtime.evaluate", { expression: "location.href", returnByValue: true });
        assert(result.result.value === sleeper.url, "Debugger attached before dormant navigation restored");
      } finally { await chrome.debugger.detach(target); }
    });
    await check("workerStorageAndNotifications", async () => {
      const start = events.length;
      await chrome.storage.sync.set({ nativeFixtureValue: { number: 42, text: "worker" } });
      assert((await chrome.storage.sync.get("nativeFixtureValue")).nativeFixtureValue.number === 42, "Native sync storage write missing");
      await chrome.storage.sync.remove("nativeFixtureValue");
      assert(!("nativeFixtureValue" in await chrome.storage.sync.get(null)), "Native sync removal missing");
      await wait(50);
      assert(events.slice(start).some(event => event.name === "storage.onChanged"), "Storage events did not reach worker");
    });
    await check("logicalClosedSessions", async () => {
      assert(other, "Window prerequisite failed");
      const url = new URL("native-closed-session", origin).href;
      const tab = await chrome.tabs.create({ windowId: sourceWindowID, url, active: false });
      await chrome.tabs.remove(tab.id);
      const closed = await chrome.sessions.getRecentlyClosed({ maxResults: 25 });
      const session = closed.find(value => value.tab?.url === url);
      assert(session?.tab?.sessionId && session.tab.id === undefined, "Closed session leaked a live/physical tab identity");
      await chrome.windows.update(other.id, { focused: true });
      assert((await chrome.windows.getCurrent()).id === other.id, "Session restore requires a different current window");
      const restored = await chrome.sessions.restore(session.tab.sessionId);
      if (restored.tab?.id !== undefined) created.push(restored.tab.id);
      assert(restored.tab?.id && restored.tab.url === url && restored.tab.windowId === sourceWindowID,
        `Session restored outside its original authoritative owner: ${JSON.stringify({ sourceWindowID, restored })}`);
      const queried = await chrome.tabs.get(restored.tab.id);
      assert(queried.url === url && queried.windowId === sourceWindowID &&
        (await chrome.tabs.query({ windowId: sourceWindowID })).some(value => value.id === queried.id),
        "Restored session response disagrees with the live tab catalog");
      assert(!(await chrome.sessions.getRecentlyClosed({ maxResults: 25 })).some(value => value.tab?.sessionId === session.tab.sessionId),
        "Restored session remained available as a duplicate closed entry");
    });
    await check("approvedNativeNavigation", async () => {
      const url = "data:text/html,%3Ctitle%3EZacro%20approved%3C/title%3E%3Cp%3Enative%3C/p%3E";
      const tab = await chrome.tabs.create({ windowId: sourceWindowID, url, active: true });
      created.push(tab.id); await loaded(tab.id);
      assert((await chrome.tabs.get(tab.id)).url === url, "Chrome-approved data navigation was discarded by the host");
      const before = (await chrome.tabs.query({})).length;
      let rejected = false;
      try { await chrome.tabs.create({ url: "javascript:document.title='invalid'" }); } catch { rejected = true; }
      assert(rejected && (await chrome.tabs.query({})).length === before, "Forbidden JavaScript URL mutated the model");
    });
    await check("largeApprovedNativeNavigation", async () => {
      assert(first, "Tab prerequisite failed");
      const url = "data:text/html,%3Ctitle%3ELarge%20native%20document%3C/title%3E" + "x".repeat(600 * 1024);
      const tab = await chrome.tabs.create({ windowId: sourceWindowID, url, active: true });
      created.push(tab.id); await loaded(tab.id);
      assert((await chrome.tabs.get(tab.id)).url === url, "Large approved URL was truncated in the host model");
      await chrome.tabs.update(first.id, { active: true });
      await chrome.tabs.discard(tab.id);
      assert((await chrome.tabs.get(tab.id)).discarded, "Large approved document was not discarded");
      const target = { tabId: tab.id };
      await chrome.debugger.attach(target, "1.3");
      try {
        const actual = await chrome.debugger.sendCommand(target, "Runtime.evaluate", {
          expression: "location.href", returnByValue: true
        });
        assert(actual.result.value === url, "Large approved history did not restore the complete URL");
        assert(!(await chrome.tabs.get(tab.id)).discarded, "Debugger did not wake the dormant native document");
      } finally { await chrome.debugger.detach(target); }
    });
    await check("nativeDebuggerTargets", async () => {
      assert(first, "Tab prerequisite failed");
      const targets = await chrome.debugger.getTargets();
      assert(targets.some(target => target.tabId === first.id), "Logical native tab target missing");
      assert(!targets.some(target => target.type === "page" && /^chrome:\/\/extensions/.test(target.url || "")), "Hidden manager leaked through debugger");
      const target = { tabId: first.id };
      await chrome.debugger.attach(target, "1.3");
      try {
        const result = await chrome.debugger.sendCommand(target, "Runtime.evaluate", { expression: "location.href", returnByValue: true });
        assert(result.result.value === (await chrome.tabs.get(first.id)).url, "Debugger attached to the wrong document");
      } finally { await chrome.debugger.detach(target); }
    });
    await check("nativeBookmarkHierarchy", async () => {
      const folder = await chrome.bookmarks.create({ title: "Zacro native acceptance" });
      try {
        const item = await chrome.bookmarks.create({ parentId: folder.id, title: "Native child", url: new URL("native-bookmark", origin).href });
        assert((await chrome.bookmarks.getChildren(folder.id)).some(node => node.id === item.id), "Native bookmark tree lost child");
        await chrome.bookmarks.update(item.id, { title: "Updated native child" });
        assert((await chrome.bookmarks.get(item.id))[0].title === "Updated native child", "Native bookmark update missing");
      } finally { await chrome.bookmarks.removeTree(folder.id); }
    });
    await check("realOffscreenDocument", async () => {
      await chrome.offscreen.createDocument({ url: "offscreen.html", reasons: ["DOM_PARSER"], justification: "Disposable native browser acceptance" });
      const contexts = await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] });
      assert(contexts.length === 1 && contexts[0].documentUrl === chrome.runtime.getURL("offscreen.html"), "Offscreen context missing");
      await chrome.offscreen.closeDocument();
      assert((await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] })).length === 0, "Offscreen document leaked");
    });
    await check("workerOpenerRejectedBeforeMutation", async () => {
      const before = (await chrome.windows.getAll()).map(window => window.id).sort().join(",");
      let rejected = false;
      try { await chrome.windows.create({ url: baseURL, setSelfAsOpener: true }); } catch { rejected = true; }
      assert(rejected && before === (await chrome.windows.getAll()).map(window => window.id).sort().join(","), "Invalid worker opener created a window");
    });
    await check("logicalEvents", async () => {
      assert(events.some(event => event.name === "tabs.onCreated" && event.args[0].id === first?.id), "Tab creation event missing");
      assert(events.some(event => event.name === "tabs.onDetached" && event.args[0] === first?.id), "Tab detach event missing");
      assert(events.some(event => event.name === "tabs.onAttached" && event.args[0] === first?.id), "Tab attach event missing");
      assert(events.some(event => event.name === "windows.onCreated" && event.args[0].id === other?.id), "Window creation event missing");
    });
    return { passed: Object.values(checks).every(Boolean), checks, errors, createdTabIDs: created, createdWindowIDs: windows, events: events.slice() };
  },
  async actionResult() { return (await chrome.storage.local.get("lastNativeAction")).lastNativeAction ?? null; },
  async removeCreated({ createdTabIDs = [], createdWindowIDs = [] }) {
    for (const id of createdTabIDs) { try { await chrome.tabs.remove(id); } catch {} }
    for (const id of createdWindowIDs) { try { await chrome.windows.remove(id); } catch {} }
  }
};
