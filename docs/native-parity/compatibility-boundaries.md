# Native messaging and Google identity audit

Reviewed 2026-11-02 against the Electron source and Chromium commit `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`. These are specific compatibility requirements and external dependencies, not a claim that all Chrome extensions work. No installed host executable was launched and no browser credentials were read or copied for this audit.

## Native messaging host discovery

The Electron broker searches the user's Google Chrome `NativeMessagingHosts` directory and `/Library/Google/Chrome/NativeMessagingHosts` on macOS (`src/main/extensions/native-messaging.cjs`, `hostRegistrationPaths`). It resolves and validates the manifest and host identity before the original approval/launch flow.

The pinned native implementation searches only `chrome::DIR_USER_NATIVE_MESSAGING`, followed by `chrome::DIR_NATIVE_MESSAGING` (`chrome/browser/extensions/api/messaging/launch_context_posix.cc`, `FindManifest`). The user path is under Chromium's configured user-data directory. An unbranded macOS build uses `/Library/Application Support/Chromium/NativeMessagingHosts` for the system path (`chrome/common/chrome_paths.cc`). A vendor that registered its host only for Google Chrome is therefore not discovered by the current native default.

`apply_native_messaging_adapter.py` now adds deterministic fallbacks for the existing Google Chrome and Chromium registration directories while preserving user-level policy controls, extension `nativeMessaging` permission, manifest `allowed_origins`, valid host-name syntax, absolute executable paths, and Chromium's process/protocol implementation. Priority is the configured user directory, standard Chromium user directory, standard Chrome user directory, configured system directory, then Chrome's system directory. All user paths are skipped when policy disables user hosts. The first existing registration remains authoritative: an invalid higher-priority manifest fails validation rather than silently selecting a different host. No manifest or credential copying is needed.

Four pinned-source fixture tests passed, including twelve filesystem cases executing the actual generated resolver body in an isolated temporary tree (`macos/.build/verification/native-messaging-fixtures.log`). The real production object and five native GTest cases compiled with the pinned GN commands (`native-messaging-objects/object-check.json`). Those GTest cases have not been linked/executed; neither the source fixtures nor object checks launch a host.

The separate disposable native-messaging fixture passes ten checks in Chrome 156: one-shot JSON/origin, fragmented and ordered multi-frame ports, oversized/truncated input, malformed JSON not delivered, explicit disconnect, denied origin, missing/invalid host, and OS process cleanup. Only the project-owned C executable is launched; its manifests live under the temporary `--user-data-dir`, never an installed browser's Library directory. It has a twenty-second failure-cleanup alarm. The final baseline observed an exited zombie before Chromium's asynchronous reap completed; a PID existence test alone must not be interpreted as a live host. Evidence: `native-messaging-chrome-baseline/result.json`.

The custom packaged Zacro build35 also passes all nine messaging API cases in `extensions-35/application.json`, including actual native-host responses, fragmented/ordered ports and permission/protocol failures. That broader extension run later fails an unrelated popup assertion, so it is not a full extension-suite pass. Its messaging results do not establish compatibility with installed vendor hosts or their browser-signature policies.

Discovery alone does not prove compatibility with a password manager. A vendor host can independently restrict accepted browser signatures or bundle identifiers; those products need vendor-specific acceptance with their own supported browser policy.

## Google identity token acquisition

The Electron implementation explicitly rejects `getAuthToken`, `removeCachedAuthToken`, `clearAllCachedAuthTokens`, and `getAccounts`; it implements `launchWebAuthFlow` (`src/main/extensions/identity.cjs`). Matching that baseline is insufficient for the requested broader compatibility.

Pinned `IdentityGetAuthTokenFunction` reads the installed extension's OAuth client and scopes, then uses a browser-account refresh token through `IdentityManager` and `OAuthConsumerId::kExtensionsIdentityAPI` before minting an extension token. The underlying browser-account request uses the configured Chrome OAuth client. Supplying only an extension's manifest client ID does not remove that dependency. Chromium documents that this stock path depends on restricted Google APIs and fails outside Chrome. [Chromium API-key documentation](https://www.chromium.org/developers/how-tos/api-keys/#polyfilling-chromeidentity-api-in-your-chromium-derivative).

The often-linked [2021 prototype](https://chromium-review.googlesource.com/c/chromium/src/+/2704571) is not a production substitute. Its last patch uses a reverse-client-ID custom URI redirect, implicit token response, scheme-only callback matching, and simplified account/scope caching. It never shipped. Google subsequently disallowed custom URI redirects for new Chrome-extension OAuth clients, while describing existing configurations separately. [Chrome Extensions DevRel explanation](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/eY4qv8fI1sQ), [Google's custom-URI policy](https://developers.googleblog.com/improving-user-safety-in-oauth-flows-through-new-oauth-custom-uri-scheme-restrictions/).

A feasible public integration is the real `launchWebAuthFlow` path with the extension vendor's compatible registered OAuth client and redirect. Preserve Chromium's extension/profile ownership, interactive versus noninteractive behavior, exact callback handling, and cancellation. A browser-provided token fallback would additionally need explicit state binding, truthful granted scopes and account selection, token expiry/cache/revocation, and installation/profile isolation. It must use a client configuration that Google actually permits; it cannot turn an arbitrary Chrome-extension OAuth client into a web client or borrow Chrome's credentials. Vendor client/redirect changes, or an authorized Google integration, remain external requirements for extensions whose only supported flow is restricted `getAuthToken`.

Pinned `WebAuthFlow::DisplayAuthPageInPopupWindow` creates a native `TYPE_POPUP`, transfers its private WebContents into it, marks it omitted from session restore, and calls `Show()`. That path bypasses the Swift `windows.create` host dispatcher. Zacro now adopts these Chrome-created windows through CEF's default client while keeping them out of the logical tab catalog.

`identity.js` and `native_auth_fixture.py` provide a synthetic loopback flow without a production account or token. Six silent API cases and two headless native-page lifecycle cases pass in Chrome 156 (`identity-chrome-baseline/result.json`): extension-scoped callbacks, immediate/delayed redirects, interaction-required rejection, timeout, invalid authorization scheme, interactive completion cleanup, and native-page close rejection. That baseline explicitly keeps `credentialFlowVerified`, `desktopInputVerified`, and `zacroRuntimeVerified` false.

The packaged custom Zacro build35 passes those six silent API cases, actual native authorization completion/cancellation, and ten auxiliary-window checks in `extensions-35/application.json`. They verify distinct native profiles, exclusion from the logical tab catalog, a trusted beforeunload veto retaining the exact window/document/draft, accepted close waiting for document and native-window destruction, and preservation/completion of another profile's flow. This establishes those disposable flows only. Authentication creation racing process/profile retirement still needs the pending native admission barrier and runtime acceptance; no real-account or general Google-token compatibility is inferred.

Both baseline suites are reproducible with an explicit Chrome executable:

```sh
node macos/scripts/check-extension-network.cjs --chrome /absolute/path/to/chrome --suite identity
node macos/scripts/check-extension-network.cjs --chrome /absolute/path/to/chrome --suite native-messaging
```

CEF's configured `root_cache_path` is authoritative for `chrome::DIR_USER_DATA` (`cef/libcef/common/resource_util.cc`). In the native acceptance app that is `<temporary acceptance data>/Chromium`; register synthetic hosts in its `NativeMessagingHosts` child after engine startup. The ordinary per-profile child cache directory is not the host registration root.

## Current evidence boundary

The native-host registration fix and synthetic native messaging/authorization paths now have packaged runtime evidence. Remaining admission/shutdown work and vendor-specific host behavior still require acceptance. The Google token dependency remains an external compatibility boundary, supported by both the pinned implementation and current official guidance. None of these findings establish universal Chrome-extension compatibility or replace a passing complete custom-runtime extension suite.
