# Native Chromium acceptance fixture

This disposable MV3 extension exercises actual Chrome APIs. The packaged app
runner installs it only in its isolated acceptance profile:

```sh
python3 macos/scripts/check-app.py --integration --require-extensions
```

`network.js` checks DNR dynamic-rule atomic rollback, session redirects and
request/response headers; storage namespace and trusted-context boundaries;
content-script sender metadata; frame/document-targeted messages, ports and
scripts; webRequest tab/document identity; denied host permissions; and stale
document rejection. Its `finally` block removes its listeners, uniquely allocated
rules, tabs and storage keys, and verifies removal. It uses only the runner's
loopback HTTP endpoints.

To validate these fixture assumptions independently against an installed Chrome
executable, use the opt-in baseline runner:

```sh
node macos/scripts/check-extension-network.cjs \
  --chrome '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
```

This uses the existing pinned Playwright dependency, a fresh headless profile,
and the same loopback server and extension files. It never opens a personal
profile. Results contain `browserBaselineOnly: true` and
`zacroRuntimeVerified: false`; a baseline pass does not establish Zacro parity.
Chrome must support `Extensions.loadUnpacked` with
`--enable-unsafe-extension-debugging`.

The contracts were checked against Chromium's pinned
`extensions/common/api/declarative_net_request.webidl`, `scripting.webidl`,
`storage.json`, `runtime.json`, `web_request.json`, and
`chrome/common/extensions/api/tabs.json`. In particular, DNR excludes other
extensions' subresource initiators, while an extension's own worker requests are
eligible under `RulesetManager::ShouldEvaluateRulesetForRequest`.
