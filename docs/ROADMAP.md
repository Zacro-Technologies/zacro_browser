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

Electron supports only a subset of Chrome extension APIs. Unpacked extension management is useful for compatible extensions but does not meet the full README extension goal. `chrome.storage.sync` is not provided by this runtime. Do not quietly replace it with local storage or claim Web Store compatibility.

Required engine work: choose a maintained Chromium integration/fork or implement and audit missing extension APIs; build a compatibility suite using representative password managers, content blockers, developer tools and productivity extensions. Define supported installation/update sources and require user review of added permissions.

Required service work: authenticate Zacro accounts independently of AI; explicitly link per-profile datasets; authenticate every device and operation; use encrypted transport and encrypted storage; model install, enable, disable and uninstall tombstones; support offline operations, deterministic conflict handling, quotas and replay protection; revoke devices and delete cloud data. Do not sync cookies, login sessions, OS paths or AI credentials. Make an explicit encryption/recovery design before publishing privacy promises. A locally tested service is not an operated Zacro service.

Acceptance: two-device convergence after concurrent install/uninstall; a revoked device cannot read or write; profile links cannot cross accounts; cloud deletion removes replicas/backups under a documented retention policy; storage.sync quotas/change events/extension namespaces behave correctly; independent security review and operational restore exercises.

## 5. Commercial distribution

- [ ] Complete the extension/sync and README-required AI gaps above, or obtain an explicit product scope change.
- [ ] Complete Windows and macOS accessibility and assistive-technology review, performance/memory soak tests and real-site compatibility matrix (including media, OAuth and PDF).
- [ ] Pass independent browser-host security assessment, permission review, extension review and update threat modelling.
- [ ] Operate the account/sync services with monitoring, backup restore tests, privacy documentation and a support process.
- [ ] Provision organization code-signing credentials; sign installers and executables, notarize and staple macOS application/DMG releases, and pass clean-machine Gatekeeper acceptance on Apple silicon and Intel.
- [ ] Deploy authenticated, signed update metadata and test staged updates, failed downloads, signature rejection, rollback and emergency Chromium releases.
- [ ] Publish tested platform support, exact limitations, third-party notices, release notes and incident-reporting routes.

`npm run dist` creates a local unsigned Windows test installer. `npm run dist:mac` creates an explicitly named development DMG/ZIP with ad-hoc signing; that is not a trusted publisher release. `npm run dist:release` refuses to proceed without signing credentials and, on macOS, notarization configuration. It verifies produced artifacts, but passing that command alone does not satisfy this checklist. Do not call a build commercial-ready while any release gate above remains open.
