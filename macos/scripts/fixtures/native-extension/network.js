/* Disposable real-Chromium acceptance. No API substitutes or external hosts.
 * Contract checked against the pinned Chromium 156 schemas:
 * extensions/common/api/{declarative_net_request,scripting}.webidl,
 * extensions/common/api/{storage,runtime,web_request}.json and tabs.json.
 */
(() => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const regex = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  async function until(body, description, timeout = 10000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      const result = await body();
      if (result) return result;
      await sleep(30);
    }
    throw new Error(description);
  }
  async function rejected(body) {
    try { await body(); return false; } catch { return true; }
  }

  globalThis.zacroNetworkAcceptance = {
    async run({ baseURL, sourceWindowID }) {
      const base = new URL(baseURL);
      assert(base.protocol === "http:" && base.hostname === "127.0.0.1", "Network acceptance requires loopback");
      const token = "zacro-network-" + crypto.randomUUID();
      const key = token + ":storage";
      const address = kind => {
        const value = new URL("/native-network/echo", base);
        value.searchParams.set("case", kind); value.searchParams.set("token", token);
        return value.href;
      };
      const checks = {}, errors = {}, created = [], ports = [], listeners = [];
      const dynamicIDs = [], sessionIDs = [], observed = [], storageEvents = [];
      const check = async (name, body) => {
        try { await body(); checks[name] = true; }
        catch (error) { checks[name] = false; errors[name] = String(error?.message || error); }
      };
      const listen = (event, callback, ...args) => {
        event.addListener(callback, ...args); listeners.push([event, callback]);
      };
      let tab, frames, main, child;
      const loaded = async id => until(async () => {
        const current = await chrome.tabs.get(id);
        return current.status === "complete" ? current : null;
      }, `Network fixture tab ${id} did not load`, 15000);
      const fetchJSON = async url => {
        const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(10000) });
        assert(response.ok, `Loopback response failed: ${response.status}`);
        return { body: await response.json(), url: response.url, headers: Object.fromEntries(response.headers) };
      };

      try {
        await check("nativeNetworkSetup", async () => {
          assert(await chrome.permissions.contains({ permissions: ["declarativeNetRequestWithHostAccess", "webRequest", "scripting", "storage"] }),
            "Fixture permissions are incomplete");
          const occupied = new Set([
            ...await chrome.declarativeNetRequest.getDynamicRules(),
            ...await chrome.declarativeNetRequest.getSessionRules()
          ].map(rule => rule.id));
          let first = 1500000000 + Math.floor(Math.random() * 10000000);
          while ([0, 1, 2, 3].some(offset => occupied.has(first + offset))) first += 4;
          dynamicIDs.push(first, first + 3); sessionIDs.push(first + 1, first + 2);
          for (const name of ["onBeforeRequest", "onCompleted", "onErrorOccurred"]) {
            listen(chrome.webRequest[name], details => {
              if (details.url.includes(token)) {
                observed.push({ event: name, ...details });
                if (observed.length > 100) observed.shift();
              }
            }, { urls: ["http://127.0.0.1/native-network/*"] });
          }
          listen(chrome.storage.onChanged, (changes, area) => {
            if (Object.hasOwn(changes, key)) storageEvents.push({ area, change: changes[key] });
          });
          // Respond only to this run's content scripts. The sender fields come
          // from Chromium; the payload is never treated as authoritative.
          listen(chrome.runtime.onMessage, (message, sender, respond) => {
            if (message?.token !== token || message.operation !== "sender") return;
            respond({ extensionID: sender.id, tabID: sender.tab?.id, windowID: sender.tab?.windowId,
              frameID: sender.frameId, documentID: sender.documentId, url: sender.url, origin: sender.origin });
          });
          const documentURL = new URL("/native-network/document", base);
          documentURL.searchParams.set("token", token);
          tab = await chrome.tabs.create({ windowId: sourceWindowID, url: documentURL.href, active: true });
          created.push(tab.id); await loaded(tab.id);
        });

        await check("dynamicRuleBlocksAndInvalidBatchRollsBack", async () => {
          assert(dynamicIDs.length, "Network setup failed");
          const blocked = address("blocked");
          assert((await fetchJSON(blocked)).body.path.includes("case=blocked"), "Control request failed before rule installation");
          const rule = { id: dynamicIDs[0], priority: 1, action: { type: "block" },
            condition: { regexFilter: "^" + regex(blocked) + "$", resourceTypes: ["xmlhttprequest"] } };
          await chrome.declarativeNetRequest.updateDynamicRules({ addRules: [rule] });
          assert(await rejected(() => fetchJSON(blocked)), "Dynamic block rule did not block the real request");
          assert(await rejected(() => chrome.declarativeNetRequest.updateDynamicRules({
            removeRuleIds: [rule.id], addRules: [{ ...rule, id: dynamicIDs[1], condition: { regexFilter: "[" } }]
          })), "Malformed rule update was accepted");
          const persisted = await chrome.declarativeNetRequest.getDynamicRules();
          assert(persisted.some(value => value.id === rule.id) && !persisted.some(value => value.id === dynamicIDs[1]),
            "Rejected dynamic update partially changed the rule set");
          assert(await rejected(() => fetchJSON(blocked)), "Rejected batch removed the existing blocking rule");
          await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [rule.id] });
          assert((await fetchJSON(blocked)).body.path.includes("case=blocked"), "Removing a dynamic rule did not restore the request");
        });

        await check("sessionRedirectAndHeaderRulesAffectNetwork", async () => {
          assert(sessionIDs.length, "Network setup failed");
          const redirect = address("redirect"), destination = address("target"), headers = address("headers");
          await chrome.declarativeNetRequest.updateSessionRules({ addRules: [
            { id: sessionIDs[0], priority: 1, action: { type: "redirect", redirect: { url: destination } },
              condition: { regexFilter: "^" + regex(redirect) + "$", resourceTypes: ["xmlhttprequest"] } },
            { id: sessionIDs[1], priority: 1, action: { type: "modifyHeaders",
              requestHeaders: [{ header: "x-zacro-native-fixture", operation: "set", value: token }],
              responseHeaders: [{ header: "x-zacro-native-response", operation: "set", value: token }] },
              condition: { regexFilter: "^" + regex(headers) + "$", resourceTypes: ["xmlhttprequest"] } }
          ] });
          const redirected = await fetchJSON(redirect), modified = await fetchJSON(headers);
          assert(redirected.url === destination && redirected.body.path.includes("case=target"), "Session redirect missed the actual request");
          assert(modified.body.headers["x-zacro-native-fixture"] === token && modified.headers["x-zacro-native-response"] === token,
            "Native request/response header modifications were not applied");
          assert(!(await chrome.declarativeNetRequest.getDynamicRules()).some(rule => sessionIDs.includes(rule.id)),
            "Session rules leaked into the dynamic rule namespace");
          await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: sessionIDs });
          const restored = await fetchJSON(headers);
          assert(!restored.body.headers["x-zacro-native-fixture"] && !restored.headers["x-zacro-native-response"],
            "Removed session rules still modify network traffic");
        });

        await check("storageAreasAndContentScriptPrivilegeBoundary", async () => {
          assert(tab, "Network setup failed");
          await chrome.storage.local.set({ [key]: { area: "local", value: 1 } });
          await chrome.storage.session.set({ [key]: { area: "session", value: 2 } });
          assert((await chrome.storage.local.get(key))[key].area === "local" &&
            (await chrome.storage.session.get(key))[key].area === "session", "Local and session storage are not isolated");
          frames = await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true },
            args: [token, key], func: async (token, key) => {
              const onMessage = (message, _sender, respond) => {
                if (message?.token !== token || message.operation !== "ping") return;
                respond({ url: location.href, nonce: message.nonce });
              };
              const onConnect = port => {
                if (port.name !== token) return;
                port.onMessage.addListener(message => port.postMessage({ nonce: message.nonce, url: location.href }));
              };
              chrome.runtime.onMessage.addListener(onMessage);
              chrome.runtime.onConnect.addListener(onConnect);
              let denied = false;
              try { await chrome.storage.session.get(key); } catch { denied = true; }
              const sender = await chrome.runtime.sendMessage({ token, operation: "sender" });
              return { url: location.href, local: (await chrome.storage.local.get(key))[key], sessionDenied: denied, sender };
            }
          });
          main = frames.find(frame => frame.frameId === 0);
          child = frames.find(frame => frame.frameId !== 0 && new URL(frame.result.url).pathname === "/native-network/frame");
          assert(main && child && frames.length === 2, "Expected one main frame and one real child document");
          for (const frame of frames) {
            assert(frame.result.local.area === "local" && frame.result.sessionDenied,
              "Content script lost local storage or gained trusted-only session storage");
          }
          await chrome.storage.local.set({ [key]: { area: "local", value: 3 } });
          await until(() => storageEvents.some(value => value.area === "local" && value.change.oldValue?.value === 1 && value.change.newValue?.value === 3)
            && storageEvents.some(value => value.area === "session" && value.change.newValue?.value === 2),
            "Storage change events lost their namespace or previous value");
        });

        await check("contentSenderAndDocumentTargetedMessages", async () => {
          assert(main && child, "Content-script setup failed");
          for (const frame of frames) {
            const sender = frame.result.sender;
            assert(sender.extensionID === chrome.runtime.id && sender.tabID === tab.id && sender.windowID === sourceWindowID &&
              sender.frameID === frame.frameId && sender.documentID === frame.documentId && sender.url === frame.result.url && sender.origin === base.origin,
              "Content-script sender was not bound to the real logical tab/document");
            const response = await chrome.tabs.sendMessage(tab.id, { token, operation: "ping", nonce: frame.documentId }, { documentId: frame.documentId });
            assert(response.url === frame.result.url && response.nonce === frame.documentId, "Document-targeted message reached the wrong frame");
          }
          const selected = await chrome.scripting.executeScript({ target: { tabId: tab.id, documentIds: [child.documentId] }, func: () => location.href });
          assert(selected.length === 1 && selected[0].documentId === child.documentId && selected[0].result === child.result.url,
            "Document-targeted scripting ignored the requested child");
          const port = chrome.tabs.connect(tab.id, { name: token, documentId: child.documentId });
          ports.push(port);
          const response = await new Promise((resolve, reject) => {
            const timeout = setTimeout(() => { port.disconnect(); reject(new Error("Document port did not reply")); }, 10000);
            port.onMessage.addListener(message => { clearTimeout(timeout); resolve(message); });
            port.onDisconnect.addListener(() => {
              const message = chrome.runtime.lastError?.message;
              clearTimeout(timeout); reject(new Error(message || "Document port disconnected before replying"));
            });
            port.postMessage({ nonce: child.documentId });
          });
          assert(response.url === child.result.url && response.nonce === child.documentId, "Port connected to the wrong document");
          port.disconnect();
        });

        await check("webRequestUsesLogicalTabAndNativeDocument", async () => {
          assert(main, "Content-script setup failed");
          const url = address("page-request");
          const result = await chrome.scripting.executeScript({ target: { tabId: tab.id, documentIds: [main.documentId] },
            args: [url], func: async url => (await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(10000) })).json() });
          assert(result[0].result.path.includes("case=page-request"), "Page request did not reach the loopback server");
          const completed = await until(() => observed.find(value => value.event === "onCompleted" && value.url === url), "webRequest completion event missing");
          const before = observed.find(value => value.event === "onBeforeRequest" && value.requestId === completed.requestId);
          assert(before && before.tabId === tab.id && completed.tabId === tab.id && completed.frameId === 0 &&
            completed.documentId === main.documentId && completed.type === "xmlhttprequest", "webRequest exposed a physical/wrong tab or document");
        });

        await check("hostPermissionBoundaryAndStaleDocumentRejection", async () => {
          assert(main, "Content-script setup failed");
          const denied = new URL("/native-network/denied", base); denied.hostname = "localhost";
          assert(!await chrome.permissions.contains({ origins: ["http://localhost/*"] }), "Negative host already has permission");
          const foreign = await chrome.tabs.create({ windowId: sourceWindowID, url: denied.href, active: false });
          created.push(foreign.id);
          assert(await rejected(() => chrome.scripting.executeScript({ target: { tabId: foreign.id }, func: () => document.title })),
            "Script injection bypassed the extension host permission boundary");
          const next = new URL("/native-network/document", base); next.searchParams.set("replacement", token);
          await chrome.tabs.update(tab.id, { url: next.href });
          await loaded(tab.id);
          // tabs.update resolves when navigation starts. Wait for the actual
          // replacement document instead of mistaking the old complete status
          // for completion of the new load.
          await until(async () => {
            try {
              const current = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => location.href });
              return current[0].documentId !== main.documentId && current[0].result === next.href;
            } catch { return false; }
          }, "Navigation did not create its replacement document", 15000);
          assert(await rejected(() => chrome.tabs.sendMessage(tab.id, { token, operation: "ping" }, { documentId: main.documentId })),
            "Message to an obsolete document silently reached its replacement");
          assert(await rejected(() => chrome.scripting.executeScript({ target: { tabId: tab.id, documentIds: [main.documentId] }, func: () => location.href })),
            "Script targeting an obsolete document ran in its replacement");
        });
      } finally {
        // Every cleanup is attempted even if another fails; never remove a rule,
        // tab or key that existed before this run. Content listeners die with
        // the fixture documents, worker listeners are explicitly removed.
        for (const port of ports) { try { port.disconnect(); } catch {} }
        for (const [event, listener] of listeners) event.removeListener(listener);
        const cleanup = await Promise.allSettled([
          chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: dynamicIDs }),
          chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: sessionIDs }),
          chrome.storage.local.remove(key), chrome.storage.session.remove(key),
          ...created.map(id => chrome.tabs.remove(id))
        ]);
        checks.networkFixtureCleanup = cleanup.every(value => value.status === "fulfilled");
        if (!checks.networkFixtureCleanup) errors.networkFixtureCleanup = cleanup.filter(value => value.status === "rejected").map(value => String(value.reason)).join("; ");
        await check("networkFixtureResourcesRemoved", async () => {
          assert(!(await chrome.declarativeNetRequest.getDynamicRules()).some(rule => dynamicIDs.includes(rule.id)), "Fixture dynamic rules remain");
          assert(!(await chrome.declarativeNetRequest.getSessionRules()).some(rule => sessionIDs.includes(rule.id)), "Fixture session rules remain");
          assert(!(key in await chrome.storage.local.get(key)) && !(key in await chrome.storage.session.get(key)), "Fixture storage remains");
          assert(listeners.every(([event, listener]) => !event.hasListener(listener)), "Fixture listeners remain");
          assert(!(await chrome.tabs.query({})).some(value => created.includes(value.id)), "Fixture tabs remain");
        });
      }
      return { passed: Object.values(checks).every(Boolean), checks, errors };
    }
  };
})();
