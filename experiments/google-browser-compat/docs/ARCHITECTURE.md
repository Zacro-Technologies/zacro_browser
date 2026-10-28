# Architecture decision: preserve the full browser layer

Status: **prototype direction selected; source-built Zacro fork and live Google acceptance remain separate gates**. Research date: October 29, 2026 (JST). See [sources and revisions](SOURCES.md).

## Problem and evidence boundaries

The user reports that direct Google account sign-in in Zacro fails with “This browser or app may not be secure.” The existing application is an Electron browser. Its local popup, persistent-cookie and profile-isolation tests demonstrate mechanics, not Google acceptance. A request header, preload or launch option must not be declared the cause of Google's decision without a controlled, supported comparison.

Google's current [account help](https://support.google.com/accounts/answer/7675428?co=GENIE.Platform%3DDesktop&hl=en) identifies embedded browsers and software automation among possible rejection conditions. Its [browser guidance](https://developers.googleblog.com/en/guidance-to-developers-affected-by-our-effort-to-block-less-secure-browsers-and-applications/) discusses blocking embedded frameworks and requires browser security features and truthful identity. These support investigating a full browser implementation; they do not prove that a newly branded Chromium fork will be accepted.

The experiment separates:

1. **Observed facts:** executable identity, source revision, native UI, configuration, local mechanics results and human-recorded account results.
2. **Source-based conclusions:** documented browser policies, upstream platform requirements and implemented browser subsystems.
3. **Hypotheses:** which particular signal caused a Google rejection, whether a new product identity will be accepted, and whether one change explains a difference between engines.

## Alternatives

| Requirement                          | A. Repair current Electron runtime                                                               | B. Thin full Chromium fork                                                                           | C. Brave Core derivative                                                                                          |
| ------------------------------------ | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Windows x64 and macOS arm64          | Existing implementation and build lanes                                                          | Native Chromium targets exist for both                                                               | Native desktop targets exist for both                                                                             |
| Google compatibility evidence        | Current user-observed failure; a supported repair has not been established                       | Removes the embedder architecture, but acceptance remains untested for the future product            | Official Brave can be a manual reference; a derivative must be evaluated independently                            |
| Shared versus platform-specific work | Shared JS shell, with Electron/native differences already handled by Zacro                       | Shared browser models, Views and WebUI; OS implementations stay behind Chromium/platform interfaces  | Same Chromium foundation plus Brave-specific patches and services                                                 |
| Existing UI and logic                | Highest direct reuse                                                                             | Reuse visual assets and pure policies; replace Electron IPC, view ownership and persistence adapters | Similar porting work, plus integration with Brave's UI and patch structure                                        |
| Profiles and private browsing        | Zacro owns session/partition lifecycle                                                           | Preserve Chromium Profile/OffTheRecord browser contexts and native profile selection                 | Preserve upstream profile implementation and inspect derivative changes                                           |
| Tabs, popups and recovery            | App-owned tab/view, opener and recovery logic                                                    | Retain browser tab/navigation/session services and native popup ownership                            | Retain Chromium services with Brave's modifications                                                               |
| Downloads and permissions            | Zacro-owned UX and allowlist                                                                     | Preserve browser-owned download and permission interfaces                                            | Preserve upstream implementations and branded service policies                                                    |
| Passkeys and authentication          | Existing missing integrations need work; adding them alone would not establish Google acceptance | Keep authenticator delegates, account selection and OS backends                                      | Keep corresponding upstream interfaces; validate build/signing-dependent capabilities                             |
| OS credential/cookie storage         | Existing Electron paths                                                                          | Preserve OSCrypt and native service integration; measure actual install mode                         | Inherits Chromium mechanisms, with Brave-specific identities/configuration                                        |
| Accessibility, IME and windows       | Existing app behavior and regression burden                                                      | Use mature browser chrome and platform integrations before replacing surfaces                        | Similar base with additional derivative behavior                                                                  |
| Packaging, signing and updates       | Existing development packaging; no compatibility guarantee                                       | Zacro must operate its own installers, signing, updater and rollback policy                          | Existing build/updater code helps, but Zacro still needs its own product/service identities and release operation |
| Licensing and branding               | Existing dependency obligations                                                                  | Chromium/third-party notices; own branding, no implied Google endorsement                            | Additional MPL-2.0 covered-source obligations and independent branding                                            |
| Ongoing maintenance                  | Lowest porting cost, unresolved supported sign-in path                                           | Maintain a deliberately small patch set and a prompt security-update process                         | Chromium plus Brave update cadence and additional patch/service coupling                                          |

**Decision:** pursue B as the target architecture. Use an intact full Chromium browser and a small optional workspace component as the bounded execution spike, and official Brave as a reference. This keeps the initial question focused on browser capability and human account acceptance before a wholesale UI migration. B is an engineering recommendation, not a finding of Google compatibility.

The spike exposed a [Chromium 159 Windows startup failure](../evidence/mechanics-chromium-win32-x64-engine-only.json) before its first fixture document, not a Google rejection. The next candidate now has a [Chromium 156 source pin and minimal native branding pipeline](../build/NATIVE-BUILD.md), aligning its engine version with the Brave reference. Its source patch is verified; compilation, native execution and Google acceptance remain untested. The saved Brave password-step observation does not transfer to that candidate.

A remains appropriate only for a demonstrated defect with a supported remedy. Correcting truthful identity or a popup bug is useful on its own, but cannot be marketed as solving embedded-browser rejection. The experiment must not search for a combination of spoofed headers, disabled security, imported cookies or undocumented token exchanges that happens to evade a check.

C is technically viable. [Brave Core](https://github.com/brave/brave-core/blob/52db4b25c0aa3038e9a1c6021428b136cc3cb5fc/README.md) supplies Chromium patches and a cross-platform build system, not a small replacement runtime. Its maintained implementations are useful references, but additional privacy policies, services, branding and patch integration increase the surface of a narrowly scoped sign-in prototype. A public Brave result would not automatically transfer to a Zacro-branded derivative.

CEF continues to be an embedded Chromium framework. WebView2 exposes a Windows host-controlled browser component; WKWebView is an Apple-platform embedding API. Neither component alone supplies a coherent cross-platform full-browser product or evidence of Google acceptance. A WebView2/WKWebView split would also require two implementations and two independent behavior/compatibility evaluations. See [Google's embedded-browser guidance](https://developers.googleblog.com/en/guidance-to-developers-affected-by-our-effort-to-block-less-secure-browsers-and-applications/) and [WebView2's host APIs](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/overview-features-apis).

## Browser-owned security boundary

The first source-built candidate should retain Chromium's native address bar, connection-security UI, certificate errors, native tabs, profile selection, private windows, downloads, permissions and authentication dialogs. Retain `//chrome/browser`; do not start from `content_shell` or another content embedder and reimplement these services around it.

The later Zacro workspace can be a trusted WebUI/native Views surface. Its JS/TS should use narrow generated Mojo methods implemented by browser-owned C++ controllers. Page renderers remain untrusted. No general `executeJavaScript`, raw request-rewriting, arbitrary cookie access or filesystem method should be exposed to workspace UI. Browser-owned security prompts must retain their actual origin and cannot be covered or simulated by decorative chrome. Chromium's [WebUI design](https://github.com/chromium/chromium/blob/0c75ec0efee23f664c9a3380217ae4650bed97e6/docs/webui/webui_explainer.md) and [Mojo security guidance](https://github.com/chromium/chromium/blob/0c75ec0efee23f664c9a3380217ae4650bed97e6/docs/security/mojo.md) describe these privilege boundaries.

Use explicit application interfaces:

| Interface                         | Browser authority retained behind it                                                           |
| --------------------------------- | ---------------------------------------------------------------------------------------------- |
| Workspace model                   | Space metadata, saved destinations, ordering and theme preferences; no credential data         |
| Tab/navigation adapter            | Native tab identifiers, navigation controller, opener relationships and beforeunload decisions |
| Profile adapter                   | Native regular/off-the-record context identity, lifecycle and isolation                        |
| Permission/authentication adapter | Browser-owned origin checks, permissions and authenticator UI; no credential interception      |
| Persistence/recovery adapter      | Browser session service plus versioned Zacro metadata with atomic writes and validation        |
| Platform integration              | Native windows, accessibility/IME, credential service and distribution integration             |

The optional Manifest V3 component is an intermediate adapter experiment. It must leave the native browser's identity and security UI intact and use no page-content injection, request interception, cookie API or debugger capability. It cannot by itself prove the eventual WebUI/C++ implementation. Its configuration requires its own acceptance row because extensions can affect browser behavior.

For the upstream reference and snapshot, retain the browser's own generated user agent and client hints. A Chromium compatibility token in an unmodified upstream binary is not a reason to inject a replacement header or claim that the binary is Google Chrome. A future Zacro build must introduce a truthful product identity through its source-level branding, user-agent and client-hint generation, and record the resulting identity for a new acceptance run. Google's published identity guidance is a requirement to investigate, not permission to impersonate an accepted product.

## Separate identity concepts

| Concept                                  | What it does                                                               | Why it does not complete this task                                                        |
| ---------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Direct Google website session            | A human signs in to Google's own web pages in the selected browser profile | This is the required outcome and needs manual acceptance on each platform                 |
| Zacro Google OAuth client                | Authorizes Zacro to request particular Google API scopes                   | An API access/refresh token is not a Gmail/Drive website cookie                           |
| External browser callback                | Returns an authorization result to an application                          | The external browser's authenticated website session remains external                     |
| Third-party Google button                | A website integrates Google OAuth/OpenID Connect                           | Its callback mechanics and site/provider policy require separate testing                  |
| FedCM                                    | Browser-owned federated identity mediation and account selection           | A missing chooser is a separate capability; adding it does not prove direct website login |
| Chrome/Chromium browser sign-in and Sync | Browser-account and synchronization services                               | Distinct from a web profile's Google website session                                      |
| Google API keys                          | Enable eligible configured Google APIs and quotas                          | Do not grant website cookies, browser certification or restricted browser-sign-in access  |

Google's [OAuth policy](https://developers.google.com/identity/protocols/oauth2/policies#use-secure-browsers) and [Chromium API-key guidance](https://www.chromium.org/developers/how-tos/api-keys/) are particularly relevant. Chromium warns that configuring browser OAuth client IDs can trigger restricted browser-account sign-in after a Google website login. The prototype should not add Google browser client secrets or Sync configuration merely to pursue website sessions.

## Acceptance before migration

Maintain separate results for Windows x64 and macOS arm64, and within each platform for Chromium without the component, Chromium with the component and the Brave reference. Record exact engine/component revisions and a human's result, not credentials or authentication traffic. Chromium 159 snapshot versus Brave/Electron Chromium 156 remains an explicit version confound; the native Zacro candidate's separate Chromium 156 pin aligns versions for its future comparison.

Retain a distinct future Intel Mac gate because the existing product supports that architecture. All source-fork claims, native distribution capabilities and live acceptance remain unproven until their corresponding build and execution evidence exists. [Migration](MIGRATION.md) defines the progression; [distribution](DISTRIBUTION.md) defines platform and update requirements.
