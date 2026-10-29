# Extension identity

Zacro implements `identity.getRedirectURL`, `identity.launchWebAuthFlow` and
`identity.getProfileUserInfo` through its authenticated compatibility adapter.
This is web authorization support, not a Google account/token service.

## Supported web authorization

`getRedirectURL(path?)` synchronously returns
`https://<native-extension-id>.chromiumapp.org/<path>`. Paths cannot change the
origin, contain controls/backslashes or traverse directories. The helper derives
its ID from the native runtime, never from extension-supplied identity fields.

`launchWebAuthFlow(details)` requires a current trusted extension context and the
reviewed `identity` permission. The initial provider URL and subsequent navigation
must use HTTPS without embedded credentials. The owned BrowserWindow uses the
extension's profile session, normal certificate validation, sandboxing and context
isolation, with Node disabled and no window preload. Profile session preloads do
not expose compatibility APIs on HTTPS pages. All new windows are denied.

The exact same-extension HTTPS `chromiumapp.org` host completes a flow before
navigation and returns the full URL including query and fragment. Other extension
callbacks, lookalike callback hosts, credentials, insecure navigation and oversized
URLs fail closed. Subframes cannot finish a flow or transmit callback URLs.
Results/errors are not logged by the controller; errors omit provider URLs/tokens.

The window starts hidden. Interactive flows show after the first completed page
load; immediate redirects complete without showing it. Noninteractive flows abort
after load unless `abortOnLoadForNonInteractive: false` is explicitly set, enabling
JavaScript redirects until `timeoutMsForNonInteractive` (1–600000 ms, default
60000 ms). Interactive flows have a five minute limit. At most two flows per
profile/extension and eight globally may exist simultaneously.

Completion, timeout, user closure, caller document/worker revocation, extension
reload/disable/remove, permission loss, profile removal and application shutdown
settle or invalidate the call and destroy the owned window. Existing profile
cookies remain available to subsequent authorized flows. A provider must accept
the extension's exact redirect origin; the extension remains responsible for its
OAuth state/PKCE validation and provider-specific exchange.

Promise and callback forms use the existing facade's transient
`chrome.runtime.lastError` behavior. The synchronous redirect helper performs no
network or account operation. `getProfileUserInfo` returns `{email: '', id: ''}`
because Zacro has no Chrome Google primary account; a Zacro sync account is never
substituted.

## OPEN: Google account and token services

The unadapted pinned runtime probe reports Electron **45.0.0**, Chromium
**156.0.8078.48**, and no `chrome.identity` namespace. No real account is used in
this probe. `getAuthToken`, `getAccounts`, `removeCachedAuthToken` and
`clearAllCachedAuthTokens` explicitly reject; there is no fabricated token,
no-op token cache or inferred sign-in state. Manifests declaring `oauth2` retain
an explicit required `identity.getAuthToken` compatibility blocker.

Chrome's provider flow requires a stable extension ID, a Google OAuth client
registered for that extension, its scopes/consent configuration, and the browser's
genuine identity/token implementation. Chromium's own documentation explicitly
states that default `chrome.identity.getAuthToken` fails outside Google Chrome
because it uses restricted APIs. Adding API keys or compiling a custom Electron
runtime alone does not establish authorized access to those services. A custom
provider-approved public OAuth implementation, valid client registrations,
provider policy compliance and native/account isolation acceptance remain OPEN.
Do not replace Chrome identity with a Zacro sync account or claim that enabling
web authorization has completed Google token support.

Primary references checked on 2026-10-26:

- [Chrome identity contract](https://developer.chrome.com/docs/extensions/reference/api/identity)
- [Chrome extension OAuth registration](https://developer.chrome.com/docs/extensions/how-to/integrate/oauth)
- [Chromium derivative identity restrictions](https://www.chromium.org/developers/how-tos/api-keys/#polyfilling-chromeidentity-api-in-your-chromium-derivative)
- [Electron extension support](https://www.electronjs.org/docs/latest/api/extensions)
- [Electron navigation interception](https://www.electronjs.org/docs/latest/api/web-contents#navigation-events)

## Acceptance

`node --test test/extensions-identity.test.cjs test/extensions-identity-api.test.cjs`
checks the controller, API guard and executable facade. The real desktop fixture
is `node --test --test-concurrency=1 test/e2e/extension-identity.test.cjs`.
It uses a disposable user-data directory and only a local synthetic HTTPS
provider. Its exact fixture certificate/host is trusted only in the disposable
extension profile session, never through a production TLS bypass. It probes the
unadapted runtime, profile cookies, HTTP/JavaScript callbacks, window isolation,
popup denial, timeouts, caller closure and extension disable.
