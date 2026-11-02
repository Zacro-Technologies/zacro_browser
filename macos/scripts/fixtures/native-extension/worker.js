/* Real MV3 APIs only. Loaded solely into a fresh disposable acceptance profile. */
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
chrome.action.onClicked.addListener(async tab => {
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
      group = await chrome.tabs.group({ tabIds: [first.id, second.id] });
      await chrome.tabGroups.update(group, { title: "Zacro α group", color: "purple", collapsed: true });
      const matching = await chrome.tabGroups.query({ windowId: other.id, title: "Zacro ? group", color: "purple", collapsed: true });
      assert(matching.length === 1 && matching[0].id === group && matching[0].shared === false, "Group identity/filter mismatch");
      assert((await chrome.tabs.get(first.id)).groupId === group, "Tab group decoration missing");
      const moved = await chrome.tabGroups.move(group, { windowId: sourceWindowID, index: -1 });
      assert(moved.id === group && moved.windowId === sourceWindowID, "Group transfer changed identity");
      assert((await chrome.tabs.get(second.id)).windowId === sourceWindowID, "Group member did not transfer");
      await chrome.tabs.ungroup([first.id, second.id]);
      assert((await chrome.tabs.get(first.id)).groupId === -1, "Ungroup left stale metadata");
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
    await check("workerStorageAndNotifications", async () => {
      const start = events.length;
      await chrome.storage.sync.set({ nativeFixtureValue: { number: 42, text: "worker" } });
      assert((await chrome.storage.sync.get("nativeFixtureValue")).nativeFixtureValue.number === 42, "Native sync storage write missing");
      await chrome.storage.sync.remove("nativeFixtureValue");
      assert(!("nativeFixtureValue" in await chrome.storage.sync.get(null)), "Native sync removal missing");
      await wait(50);
      assert(events.slice(start).some(event => event.name === "storage.onChanged"), "Storage events did not reach worker");
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
