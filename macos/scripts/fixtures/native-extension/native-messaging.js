/* Genuine nativeMessaging calls to our isolated, allowlisted test executable.
 * No installed user hosts, shell commands, or credentials are ever accessed.
 */
(() => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const bound = async promise => {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Native messaging fixture timed out")), 8000);
      })]);
    } finally { clearTimeout(timer); }
  };
  const rejected = async (operation, expression) => {
    let error = "";
    try { await bound(operation()); } catch (value) { error = String(value?.message || value); }
    assert(expression.test(error), "Unexpected native messaging result: " + error);
  };
  const exchange = (name, payloads, expected, failure) => new Promise((resolve, reject) => {
    const port = chrome.runtime.connectNative(name);
    const received = [];
    let settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      port.onMessage.removeListener(message); port.onDisconnect.removeListener(disconnected);
      port.disconnect();
      if (error) reject(error); else resolve(result);
    };
    const message = value => {
      if (failure) { finish(new Error("Malformed native framing unexpectedly produced a message")); return; }
      received.push(value);
      if (received.length === expected) finish(null, received);
    };
    const disconnected = () => {
      const error = chrome.runtime.lastError?.message || "Native port disconnected";
      if (failure?.test(error)) finish(null, error);
      else finish(new Error(error));
    };
    const timer = setTimeout(() => finish(new Error("Native port fixture timed out")), 8000);
    port.onMessage.addListener(message); port.onDisconnect.addListener(disconnected);
    for (const payload of payloads) port.postMessage(payload);
  });

  globalThis.zacroNativeMessagingAcceptance = {
    async run({ hosts }) {
      const kinds = ["echo", "fragments", "batch", "oversized", "truncated", "invalidjson", "hold", "denied", "missing"];
      for (const kind of kinds) {
        assert(typeof hosts?.[kind] === "string" && new RegExp(`^com\\.zacro\\.native_fixture_[a-f0-9]{32}\\.${kind}$`).test(hosts[kind]),
          "Only this disposable fixture's host identities may be used");
      }
      const checks = {}, errors = {};
      const check = async (name, body) => {
        try { await body(); checks[name] = true; }
        catch (error) { checks[name] = false; errors[name] = String(error?.message || error); }
      };
      const expectedOrigin = `chrome-extension://${chrome.runtime.id}/`;
      const payload = { unicode: "雪 🦊", nested: { value: 7 }, escaped: "line\nzero\u0000end" };
      const verify = result => {
        assert(result.origin === expectedOrigin, "Native host received another extension's origin");
        assert(JSON.stringify(result.payload) === JSON.stringify(payload), "Native framing changed the JSON payload");
      };
      await check("nativeMessageOneShotAndOrigin", async () => {
        assert(await chrome.permissions.contains({ permissions: ["nativeMessaging"] }), "Fixture nativeMessaging permission is missing");
        verify(await bound(chrome.runtime.sendNativeMessage(hosts.echo, payload)));
      });
      await check("nativePortFragmentedFrames", async () => {
        const replies = await exchange(hosts.fragments, [payload, payload], 2);
        replies.forEach(verify);
      });
      await check("nativePortOrderedMultipleFrames", async () => {
        const replies = await exchange(hosts.batch, [payload], 2);
        replies.forEach(verify);
        assert(replies[0].sequence === 1 && replies[1].sequence === 2, "Native frame order changed");
      });
      await check("nativeOversizedFrameDisconnects", async () => {
        await exchange(hosts.oversized, [payload], 0, /communicat|input|output|error/i);
      });
      await check("nativeTruncatedFrameDisconnects", async () => {
        await exchange(hosts.truncated, [payload], 0, /exited|closed|communicat/i);
      });
      await check("nativeInvalidJSONIsNotDelivered", async () => {
        // Chromium's port forwards framed text to its JSON deserializer. The
        // fixture then exits; no malformed value may reach onMessage, and EOF
        // is a valid terminal error rather than a guaranteed parse-error string.
        await exchange(hosts.invalidjson, [payload], 0, /communicat|invalid|error|exited/i);
      });
      await check("nativePortExplicitDisconnect", async () => {
        const replies = await exchange(hosts.hold, [payload], 1);
        verify(replies[0]);
        // The parent harness also verifies hold.pid no longer identifies a
        // running host. JS alone cannot prove OS process cleanup.
      });
      await check("nativeHostOriginRestriction", async () => {
        await rejected(() => chrome.runtime.sendNativeMessage(hosts.denied, payload), /forbidden|not allowed|access.*denied/i);
      });
      await check("nativeHostMissingAndInvalidName", async () => {
        await rejected(() => chrome.runtime.sendNativeMessage(hosts.missing, payload), /not found|not registered|not exist/i);
        await rejected(() => chrome.runtime.sendNativeMessage("../invalid", payload), /invalid.*name/i);
      });
      return { checks, errors, passed: Object.values(checks).every(Boolean), processCleanupVerified: false,
        actualUserHostsAccessed: false };
    }
  };
})();
