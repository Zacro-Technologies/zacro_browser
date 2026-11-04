/* Real chrome.identity API against disposable loopback pages. No OAuth client,
 * account, token, injected API implementation, or external server is used.
 * Checked against pinned identity.json + identity_launch_web_auth_flow_function.
 */
(() => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const runs = new Map();
  const origin = value => {
    const url = new URL(value);
    assert(url.protocol === "http:" && url.hostname === "127.0.0.1" && !url.username && !url.password,
      "Identity acceptance requires loopback");
    return url;
  };
  const input = ({ baseURL, token = "zacro-auth-" + crypto.randomUUID(), holdMilliseconds }, mode) => {
    assert(/^[A-Za-z0-9_-]{1,96}$/.test(token), "Invalid identity fixture token");
    const base = origin(baseURL);
    const callback = new URL(chrome.identity.getRedirectURL("zacro-native/" + token));
    callback.searchParams.set("state", token); callback.hash = "fixture=complete";
    const url = new URL(mode === "redirect" ? "/native-auth/redirect" : mode === "pending" ? "/native-auth/pending" : "/native-auth/document", base);
    url.searchParams.set("callback", callback.href); url.searchParams.set("token", token);
    if (mode !== "redirect") url.searchParams.set("mode", mode);
    if (holdMilliseconds !== undefined) {
      assert((mode === "hold" || mode === "pending") && Number.isInteger(holdMilliseconds) && holdMilliseconds >= 20000 && holdMilliseconds <= 90000,
        "Invalid bounded identity fixture hold duration");
      url.searchParams.set("hold_ms", String(holdMilliseconds));
    }
    return { token, baseURL: base.href, callback: callback.href, url: url.href };
  };
  const failure = async operation => {
    try { await operation(); } catch (error) { return String(error?.message || error); }
    throw new Error("An invalid or noninteractive authorization unexpectedly succeeded");
  };
  const bounded = async (promise, milliseconds = 15000) => {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Native identity callback timed out")), milliseconds);
      })]);
    } finally { clearTimeout(timer); }
  };

  globalThis.zacroIdentityAcceptance = {
    async run({ baseURL }) {
      origin(baseURL);
      const checks = {}, errors = {};
      const check = async (name, body) => {
        try { await body(); checks[name] = true; }
        catch (error) { checks[name] = false; errors[name] = String(error?.message || error); }
      };
      await check("identityRedirectIsExtensionScoped", async () => {
        assert(await chrome.permissions.contains({ permissions: ["identity"] }), "Fixture identity permission is missing");
        assert(chrome.identity.getRedirectURL("zacro-native") === `https://${chrome.runtime.id}.chromiumapp.org/zacro-native`,
          "The identity callback is not scoped to the actual installed extension");
      });
      await check("identitySilentImmediateCallback", async () => {
        const request = input({ baseURL }, "redirect");
        const result = await bounded(chrome.identity.launchWebAuthFlow({ url: request.url, interactive: false,
          timeoutMsForNonInteractive: 5000 }));
        assert(result === request.callback, "Immediate identity callback changed its path, state, or fragment");
      });
      await check("identitySilentLoadedPageRequiresInteraction", async () => {
        const request = input({ baseURL }, "load");
        const error = await bounded(failure(() => chrome.identity.launchWebAuthFlow({ url: request.url,
          interactive: false, timeoutMsForNonInteractive: 5000 })));
        assert(/interaction/i.test(error), "Loaded silent authorization returned the wrong failure: " + error);
      });
      await check("identitySilentDelayedCallback", async () => {
        const request = input({ baseURL }, "async");
        const result = await bounded(chrome.identity.launchWebAuthFlow({ url: request.url, interactive: false,
          abortOnLoadForNonInteractive: false, timeoutMsForNonInteractive: 5000 }));
        assert(result === request.callback, "Asynchronous identity callback was lost or changed");
      });
      await check("identitySilentTimeoutClosesFlow", async () => {
        const request = input({ baseURL }, "timeout");
        const error = await bounded(failure(() => chrome.identity.launchWebAuthFlow({ url: request.url,
          interactive: false, abortOnLoadForNonInteractive: false, timeoutMsForNonInteractive: 150 })));
        assert(/interaction|timed out/i.test(error), "Silent timeout returned the wrong failure: " + error);
      });
      await check("identityRejectsNonWebAuthorizationURL", async () => {
        const error = await bounded(failure(() => chrome.identity.launchWebAuthFlow({ url: "data:text/html,fixture", interactive: false })));
        assert(/http|scheme|invalid/i.test(error), "Invalid scheme returned the wrong failure: " + error);
      });
      return { checks, errors, passed: Object.keys(checks).length === 6 && Object.values(checks).every(Boolean),
        credentialFlowVerified: false, desktopInputVerified: false };
    },

    // Root acceptance observes the genuine native NSWindow while this flow is
    // pending, then releases the loopback page or closes that native window.
    startInteractive(options) {
      const request = input(options, "hold");
      assert(!runs.has(request.token), "Fixture token is already active");
      assert(runs.size < 16, "Finish existing identity fixture flows first");
      const run = { ...request, state: "pending", startedAt: Date.now() };
      runs.set(request.token, run);
      chrome.identity.launchWebAuthFlow({ url: request.url, interactive: true }).then(
        value => { run.state = "resolved"; run.result = value; run.exactCallback = value === request.callback; },
        error => { run.state = "rejected"; run.error = String(error?.message || error); }
      );
      return { token: run.token, title: "Zacro auth fixture " + run.token, callback: run.callback };
    },
    startPending(options) {
      const request = input(options, "pending");
      assert(!runs.has(request.token), "Fixture token is already active");
      assert(runs.size < 16, "Finish existing identity fixture flows first");
      const run = { ...request, state: "pending", startedAt: Date.now() };
      runs.set(request.token, run);
      chrome.identity.launchWebAuthFlow({ url: request.url, interactive: true }).then(
        value => { run.state = "resolved"; run.result = value; run.exactCallback = value === request.callback; },
        error => { run.state = "rejected"; run.error = String(error?.message || error); }
      );
      return { token: run.token, title: "Zacro auth fixture " + run.token, callback: run.callback };
    },
    async pendingServerState(token) {
      const run = runs.get(token); assert(run, "Unknown identity fixture token");
      const url = new URL("/native-auth/pending-status", run.baseURL); url.searchParams.set("token", token);
      const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(5000) });
      if (response.status === 404) return { entered: false, released: false, completed: false, expired: false };
      assert(response.ok, "Pending auth server status failed");
      return response.json();
    },
    async releasePending(token) {
      const run = runs.get(token); assert(run, "Unknown identity fixture token");
      const url = new URL("/native-auth/pending-release", run.baseURL); url.searchParams.set("token", token);
      const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(5000) });
      assert(response.ok, "Pending auth request never reached the owned server");
      return true;
    },
    async status(token) {
      const run = runs.get(token); assert(run, "Unknown identity fixture token");
      const tabs = await chrome.tabs.query({});
      const windows = await chrome.windows.getAll({ populate: true });
      const matches = tab => {
        try { const url = new URL(tab.url); return url.origin === new URL(run.baseURL).origin && ["/native-auth/document", "/native-auth/pending"].includes(url.pathname) && url.searchParams.get("token") === token; }
        catch { return false; }
      };
      return { ...run, logicalAuthTabIDs: tabs.filter(matches).map(tab => tab.id),
        logicalAuthWindowIDs: windows.filter(window => window.tabs?.some(matches)).map(window => window.id),
        credentialFlowVerified: false, desktopInputVerified: false };
    },
    async release(token) {
      const run = runs.get(token); assert(run, "Unknown identity fixture token");
      const url = new URL("/native-auth/release", run.baseURL); url.searchParams.set("token", token);
      const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(5000) });
      assert(response.ok, "The held authorization page was not ready to release");
      return true;
    },
    finish(token) {
      const run = runs.get(token); assert(run && run.state !== "pending", "The native authorization flow has not closed");
      runs.delete(token); return { state: run.state, exactCallback: run.exactCallback === true, error: run.error || "" };
    }
  };
})();
