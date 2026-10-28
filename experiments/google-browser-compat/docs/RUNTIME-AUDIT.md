# Existing runtime and workspace-component audit

Reviewed on **2026-10-29 (Asia/Tokyo)** against Zacro repository baseline **`109b2a366ad59c3c5efd325d605c74c3a6a0d981`**, before the engine experiment. This is a source audit and isolated version inspection, not a live Google sign-in result. No credentials, authentication cookies, account traffic or real profiles were inspected.

## Runtime and supported targets

An isolated `ELECTRON_RUN_AS_NODE=1` invocation of the installed development Electron executable reported:

| Component     | Observed version           |
| ------------- | -------------------------- |
| Electron      | 45.0.0                     |
| Chromium      | 156.0.8078.48              |
| V8            | 15.6.75.19-electron.0      |
| Embedded Node | 24.22.0                    |
| Application   | 0.9.0, from `package.json` |

This command did not create a browser window or open a browser profile. `package.json` pins Electron 45.0.0, electron-builder 26.18.0 and Codex 0.164.0. The supported native CI targets are Windows x64, macOS arm64 and **macOS x64**. The new architecture must account for Intel Mac support explicitly. A Linux AppImage target is also present in packaging configuration, but the existing workflow does not establish Linux acceptance.

Pinned upstream source revisions resolved with `git ls-remote`:

| Upstream | Tag                                                                         | Commit                                     |
| -------- | --------------------------------------------------------------------------- | ------------------------------------------ |
| Electron | `v45.0.0` (annotated tag object `98113abddebb16f430b09fd5fe89dea2e37ca32f`) | `54f961b44b83e4ece81065ab60a182fd0c38c01e` |
| Chromium | `156.0.8078.48`                                                             | `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c` |

These identify the existing Electron runtime, not a recommendation to pin a new full-browser fork to that Chromium revision indefinitely.

## Observations from the application

Line numbers below refer to the audited baseline. The existing engine is preserved by the experiment.

| Area                          | Observed implementation                                                                                                                                                                                                                                                                         | Implication and limit                                                                                                                                                                                                                                                                        |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Browser identification        | `src/main/main.cjs:509–522` removes Electron, Zacro and zacro-browser tokens from each session user-agent.                                                                                                                                                                                      | This is incompatible with using truthful identity as the experiment's acceptance criterion. Restoring truthful identification is a justified correction, but there is no evidence that it alone fixes or explains Google's rejection. Do not test Google using an identity-spoofing variant. |
| Request handling              | `main.cjs:612–630` reads top-level Content-Type and calls the response callback without modified headers. No request/header rewriting, webdriver concealment, token-to-cookie exchange or cookie-import path was found in production source.                                                    | The observer is distinct from modifying authentication traffic. Its presence does not explain the rejection.                                                                                                                                                                                 |
| Guest security                | `main.cjs:664–678` forces sandbox, context isolation and web security; Node in pages, workers and subframes and insecure mixed content are disabled. `main.cjs:3249` rejects certificate errors. `security.cjs:6` restricts navigation to HTTP/S without embedded credentials.                  | Preserve these boundaries in local regression tests. Do not relax them to seek a passing login.                                                                                                                                                                                              |
| Guest preload                 | `src/main/guest-preload.cjs` exposes no bridge to web pages. It reports trusted editing occurrence without field values and handles modified clicks and ordinary cross-host links from saved pins for Peek.                                                                                     | These are developer-controlled page interactions. They might affect specific navigation workflows, but no observed failure ties them to direct Google rejection. The full-browser candidate does not inject this preload.                                                                    |
| Page-context execution        | `main.cjs:1114` checks edited forms/media in isolated world 1002 before sleeping; `main.cjs:2072` performs explicitly requested, filtered AI extraction in isolated world 1001.                                                                                                                 | The existing application can inspect page DOM. No such page inspection is implemented by the bounded workspace component or used during live account acceptance.                                                                                                                             |
| Popups                        | `main.cjs:715–762` adopts Electron's actual popup WebContents, preserves opener/POST/referrer state, forces the originating profile session and promotes Peek without reloading its document. It limits popup bursts to four per second.                                                        | These mechanics are valuable regression cases. Successful local popup callbacks are not evidence of Google website compatibility.                                                                                                                                                            |
| Authentication lifetime       | `main.cjs:1045–1079` protects active pages and live popup/openers from sleeping. `main.cjs:339–361` implements an expiring HTTP/proxy-auth callback.                                                                                                                                            | HTTP/proxy authentication is separate from Google's HTML account flow. Popup relationships are in-memory browser mechanics, not persistent website credentials.                                                                                                                              |
| Profiles and private sessions | `main.cjs:513` uses `persist:zacro-<id>` for regular profiles and memory partitions for private profiles. `store.cjs:471–507` excludes private records and writes state atomically with recovery copies. `main.cjs:2995–3015` ends private sessions after an accepted last-window close on Mac. | Do not migrate these partitions or real cookies into the candidate. Use separate test data and native browser profiles. User-saved downloads deliberately survive private cleanup.                                                                                                           |
| Permissions                   | `main.cjs:523–611` has a limited origin/profile permission allowlist and native prompt, denies unsupported kinds including storage access, and denies device pairing.                                                                                                                           | Individual embedded flows could depend on missing permissions. This is an investigation lead, not proof of the direct-account error's cause. Blanket grants would be inappropriate.                                                                                                          |
| Connection UI                 | `src/renderer/app.js:1313,1340` selects the lock icon solely from the URL's `https:` prefix. There is no Chromium certificate/security-state or Page Info surface.                                                                                                                              | The candidate retains the full browser's visible omnibox and native connection-security UI. The scheme-only lock is not reused as a security assertion.                                                                                                                                      |
| Launch behavior               | Production source does not append automation, remote-debugging or security-disabling switches. Normal development startup is `electron .`.                                                                                                                                                      | Automation added by tests is a separate condition; never attach it during live account acceptance.                                                                                                                                                                                           |

## Development, packaging and test boundaries

`package.json` enables OS cookie encryption and embedded ASAR integrity, disables RunAsNode, NODE_OPTIONS and main-process CLI inspection fuses, and loads application code from ASAR. `scripts/prepare-runtime.cjs` and `validate-package-target.cjs` check native Electron/Codex architectures. Development Electron retains its usual inspection facilities.

`scripts/build-mac.cjs` deliberately emits ad-hoc development packages without Hardened Runtime. Publisher release tooling separately requires Developer ID, Hardened Runtime, notarization and verification. Windows release tooling checks trusted Authenticode signatures. These are distribution controls, not Google compatibility evidence. The repository does not provide a complete production updater or rollback service.

Most native tests use Playwright. `test/package/packaged.test.cjs:129` and `scripts/review-captures.cjs:127` explicitly enable local CDP. They cannot be reused for the live Google acceptance run. `test/e2e/startup.test.cjs:44` launches a local fixture without debugger or automation switches, but it is still only a rendering/mechanics test.

`scripts/interactive-qa.cjs` opens a debugger-free disposable test profile and deletes it after exit. It is unsuitable for restart-persistence acceptance. The engine experiment must provide a separate manual launcher whose dedicated test profile survives normal exit, with no account automation or authentication logging.

Relevant existing local-mechanics regressions:

- `test/e2e/browser.test.cjs:287`: persistent HttpOnly login cookies, session-cookie expiration, regular-profile isolation and private cleanup.
- `test/e2e/security.test.cjs:128,184,242,399`: popup sandbox settings, POST preservation, cross-origin callbacks, Peek promotion and split-view opener behavior.
- `test/e2e/mac.test.cjs:537`: private-session cleanup when the last Mac window closes.
- `test/package/packaged.test.cjs:64`: actual executable fuse checks.

Existing successful fixture results do not change the live Google acceptance matrix. No successful Google account sign-in was observed during this audit.

## Browser-owned authentication interfaces

The pinned [Electron browser client](https://github.com/electron/electron/blob/54f961b44b83e4ece81065ab60a182fd0c38c01e/shell/browser/electron_browser_client.h) exposes WebAuthn delegates but has no IdentityRequest-dialog override. Chromium's [default identity dialog controller](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/content/public/browser/webid/identity_request_dialog_controller.cc) dismisses account selection when interception is not enabled. This supports the existing FedCM capability-gap conclusion. FedCM remains a separate follow-up from direct Google website sign-in.

No `app.configureWebAuthn`, `select-webauthn-account` or authenticator-selection handling exists in Zacro. Its Mac entitlements lack WebAuthn keychain groups and associated domains. Electron's [pinned app API](https://github.com/electron/electron/blob/54f961b44b83e4ece81065ab60a182fd0c38c01e/docs/api/app.md#appconfigurewebauthnoptions-macos) says Mac platform authenticators remain unavailable until configured. Touch ID requires a keychain group and an account chooser. The `platformPasskeys` path additionally requires signed provisioning and cooperating relying-party associated-domain/AASA configuration; simply adding an entitlement does not enable arbitrary Google-domain passkeys through that API. [Account-selection events](https://github.com/electron/electron/blob/54f961b44b83e4ece81065ab60a182fd0c38c01e/docs/api/session.md#event-select-webauthn-account) also matter for applicable roaming authenticators. These observations do not establish the cause of Google's direct-login rejection.

## Bounded workspace component

`../extension/` contains an independent Manifest V3 side panel. It reuses a small subset of Zacro's vector icon vocabulary and visual ideas, with no dependency on Electron, its preload bridge, session files or AI services. It deliberately leaves the native browser tab strip, address bar, Page Info, permission prompts, authentication interfaces, downloads and recovery in place.

The component has exactly four permissions: `sidePanel`, `tabs`, `tabGroups`, and `storage`. It has no content scripts, host permissions, scripting, cookie access, request interception, debugger, native messaging, external messaging or web-accessible resources. CSP restricts scripts and styles to local files and denies connections and objects. No external favicon is fetched. It does not make Google-specific decisions or alter browser identification.

The `tabs` permission exposes page title and address metadata. The component reads that metadata to organize the owning window, so it is not a zero-observation baseline. It never stores or logs URLs, titles, query strings, fragments or group IDs. Its search presentation uses titles and hostnames; it does not expose URL query/fragment values. The only extension storage record is `zacroWorkspacePreferences: { appearance }` in `chrome.storage.local`. Native browser profiles isolate that storage. Engine-only and workspace-enabled acceptance must use separate dedicated profiles.

Workspaces map directly to native tab groups; pins use native tab pinning. Activation and grouping preserve tab identity instead of copying or reopening a page. All mutations validate the current tab/group belongs to the bound regular window. `chrome.windows.getCurrent({populate:false})` establishes the panel's owning window without requesting an additional permission. Private access is disabled by `incognito: not_allowed`; native private windows remain available without the component. A tab moved between windows concurrently with an API call is still subject to the browser's asynchronous API semantics; there is no claim of a cross-process transaction.

The manifest's public development key fixes extension ID **`fimeokmnmdjlnadhinihgiaimdfinehg`** across checkout paths and platforms. No corresponding private signing key is retained or shipped. This is a development identifier, not a Chrome Web Store publication credential. The panel entry is `chrome-extension://fimeokmnmdjlnadhinihgiaimdfinehg/panel.html`; the browser action opens it through the native Side Panel API.

Keyboard operation uses standard buttons/selects/dialogs, visible focus and native dialog focus trapping. Down from search enters the visible tab list; Up/Down and Home/End navigate tab buttons; Tab reaches pin/workspace actions; Enter activates; `/` returns to search. Focus is restored by stable tab/action keys after metadata redraws. Appearance follows the system or an explicit light/dark preference, with reduced-motion and forced-colors handling. This is a small engine-integration lab, not a wholesale Arc UI migration.

Run its local unit checks with:

```sh
node --test experiments/google-browser-compat/tests/workspace.test.cjs
```

The seven tests cover capability limits and stable identity, HTTP/S-only creation, private/foreign-window rejection, native identity through pin/group operations, validated group mapping, preference-only persistence across separate mock profile stores, and revalidation after stale snapshots. These tests use browser-API mocks; they do not establish native profile isolation, platform UI acceptance or Google compatibility. Native fixture execution and live account checks must be recorded separately.

API documentation rechecked on the audit date: [Side Panel](https://developer.chrome.com/docs/extensions/reference/api/sidePanel), [Tabs](https://developer.chrome.com/docs/extensions/reference/api/tabs), [Tab Groups](https://developer.chrome.com/docs/extensions/reference/api/tabGroups), [Incognito manifest behavior](https://developer.chrome.com/docs/extensions/reference/manifest/incognito).

## Reuse and remaining uncertainties

Pure tab-ordering, archive policy, shortcut parsing, theme math and validation concepts can inform a future native/WebUI implementation. Existing Node filesystem persistence, Electron WebContents ownership, permission callbacks, preload IPC, overlay captures and AI child-process ownership are not drop-in browser-layer modules. They need explicit native interfaces and new security review.

`docs/IMPLEMENTATION-CONTRACT.md` contains stale examples: a 24-hour archive default, pinned close described as removal, and JPEG backdrops. Do not use it as the migration schema authority. Current `store.cjs`, `archive.cjs`, renderer bridge and regression tests are the reliable baseline until that contract is reconciled.

Restoring honest identity, replacing the scheme-only lock with verified browser security UI, and supplying missing native authentication interfaces are independently justified changes. None proves Google will accept a candidate. A successful baseline on one OS, a Chromium version number, an OAuth callback, a signed package, or a locally passing fixture cannot establish reliable direct website sign-in on the other OS.
