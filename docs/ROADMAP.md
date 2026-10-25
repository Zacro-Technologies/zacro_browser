# Zacro implementation and commercial release gates

This repository started with a vision and no implementation. The desktop implementation uses Electron 45's Chromium/Blink/V8 runtime. Windows 11 x64 has local and CI acceptance evidence. macOS 13+ is the target for native window/menu/lifecycle integration and separate Apple silicon and Intel builds; native macOS 15 CI has passed on both architectures, including packaged browsing and development DMG/ZIP generation. Physical Mac and signed/notarized release acceptance remain open. Linux remains a packaging target requiring implementation review and platform validation. The work below distinguishes runnable code from release acceptance. An unchecked gate is not a shipped capability. See [the Mac guide](MACOS.md).

## 1. A reliable local browser

Build a privileged host, a restricted application UI, and isolated remote page renderers. Persist tabs, Spaces, profiles, folders, bookmarks and settings with bounded schemas, atomic writes and backup recovery. Separate profile cookies/cache in Chromium session partitions. Private profiles use memory partitions and never enter browser-state exports or history.

Acceptance: real navigation, redirects, popup handling, keyboard actions, session restart, two-profile cookie isolation, malformed state recovery, page crashes, cancelled navigation and invalid TLS; regression tests run in CI. No disabling the OS sandbox or certificate checks to get a test passing.

## 2. The complete browsing interface

Implement vertical tabs, favorites, folders, drag and keyboard organization, Space themes, navigation/command bar, split pages and Peek with promotion and focus return. Deliver downloads with pause/cancel/reveal and reversible renaming, history, bookmark imports, archive recovery, printing, find, zoom, developer tools and readable errors. No inert feature buttons.

Acceptance: exercise every exposed control, keyboard-only flows, narrow/large windows, light/dark/high-contrast themes, reduced motion, native dialogs, long titles and empty/error states. Run actual Chromium integration tests and inspect rendered UI, rather than testing only reducer behavior.

## 3. Optional AI with explicit data boundaries

Use the signed-in user's Codex subscription through a supported ChatGPT authentication flow, with cancellation, separate research and page-context modes, citations, follow-up conversation and current-answer source opening without duplicate tabs. Keep the connection isolated from an existing developer Codex setup. Inference requires an explicit question; ordinary browsing remains independent of AI. Do not add an API-key or separate API-billing fallback.

Acceptance: app-server protocol tests, profile/private-tab guards, cancellation races, usage limits, malformed responses, source URL validation, credential isolation and context disclosures. Direct PDF text extraction runs in a bounded local worker with physical-page citations. Live subscription acceptance requires the tester to finish ChatGPT sign-in and confirm account access, real answers, citations, cancellation, and limit handling. Local commands, filesystem tools, plugins, MCP servers, and skills must remain unavailable to browsing questions. Scoped consequential browser agents still require a separate verified permission and execution system.

The local open-source build uses Codex app-server authentication. OpenAI distinguishes that integration from commercial or hosted services, which require the supported Sign in with ChatGPT path. Any change to that distribution model must pass the authentication/distribution review before release. See the [official app-server authentication guidance](https://learn.chatgpt.com/docs/app-server#authentication-endpoints).

## 4. Extension compatibility and Zacro sync

The chosen implementation retains Electron 45. A managed extension host verifies Chrome Web Store CRX3 packages, preserves originals, builds separate compatibility copies and supplies action/options, tab/window, menu/command, optional-permission and distinct `chrome.storage.sync` integration. Profile isolation, local permission review, update rollback and native unload remain mandatory. Unsupported native APIs are rejected or explicitly reported; full Chrome compatibility is not promised. See [extension support](EXTENSIONS.md) and [the acceptance record](EXTENSIONS-SYNC-VALIDATION.md).

The separate Node.js 24/SQLite service implements username/password/recovery-code accounts, authenticated devices, explicitly linked datasets, encrypted transport and storage, library tombstones/generations, persistent offline changes, deterministic conflicts, quotas, replay protection, revocation and cloud deletion. The desktop stores tokens with OS credential protection and requires separate settings consent. Server-side encryption is not end-to-end encryption. Cookies, site sessions, local paths and AI credentials are outside the sync protocol.

Actual two-desktop tests exercise extension APIs, local permission approval, opt-in, offline restart, quota rejection and revocation. A live public JSON Formatter package passed production acquisition and native functionality. Other representative packages expose unsupported engine requirements. Native background suspend/wake and lifecycle regressions pass, and independent whole-branch review has no remaining code findings. Final packaged and cross-platform acceptance remain open on this branch; see the validation record for current results. Do not treat an earlier platform run as feature-branch acceptance.

Release gates: validate Windows and both Mac architectures; expand the real extension compatibility matrix; perform independent security assessment and operational restore exercises; deploy and monitor the service with external key custody and enforced backup expiry. The operator guide documents the current security ledger required for deletion-safe restoration and a maximum seven-day backup lifetime. A locally tested service is not an operated Zacro service. See [user setup](SYNC.md) and [service operations](../services/sync/README.md).

## 5. Commercial distribution

- [ ] Complete the extension/sync and README-required AI gaps above, or obtain an explicit product scope change.
- [ ] Complete Windows and macOS accessibility and assistive-technology review, performance/memory soak tests and real-site compatibility matrix (including media, OAuth and PDF).
- [ ] Pass independent browser-host security assessment, permission review, extension review and update threat modelling.
- [ ] Operate the account/sync services with monitoring, backup restore tests, privacy documentation and a support process.
- [ ] Provision organization code-signing credentials; sign installers and executables, notarize and staple macOS application/DMG releases, and pass clean-machine Gatekeeper acceptance on Apple silicon and Intel.
- [ ] Deploy authenticated, signed update metadata and test staged updates, failed downloads, signature rejection, rollback and emergency Chromium releases.
- [ ] Publish tested platform support, exact limitations, third-party notices, release notes and incident-reporting routes.

`npm run dist` creates a local unsigned Windows test installer. `npm run dist:mac` creates an explicitly named development DMG/ZIP with ad-hoc signing; that is not a trusted publisher release. `npm run dist:release` refuses to proceed without signing credentials and, on macOS, notarization configuration. It verifies produced artifacts, but passing that command alone does not satisfy this checklist. Do not call a build commercial-ready while any release gate above remains open.
