# Zacro implementation and commercial release gates

This repository started with a vision and no implementation. The desktop implementation uses Electron 45's Chromium/Blink/V8 runtime. Windows 11 x64 has local and CI acceptance evidence. macOS 13+ is the target for native window/menu/lifecycle integration and separate Apple silicon and Intel builds; native macOS 15 CI has passed on both architectures, including packaged browsing and development DMG/ZIP generation. Physical Mac and signed/notarized release acceptance remain open. Linux remains a packaging target requiring implementation review and platform validation. The work below distinguishes runnable code from release acceptance. An unchecked gate is not a shipped capability. See [the Mac guide](MACOS.md).

## 1. A reliable local browser

Build a privileged host, a restricted application UI, and isolated remote page renderers. Persist tabs, Spaces, profiles, folders, bookmarks and settings with bounded schemas, atomic writes and backup recovery. Separate profile cookies/cache in Chromium session partitions. Private profiles use memory partitions and never enter browser-state exports or history.

Acceptance: real navigation, redirects, popup handling, keyboard actions, session restart, two-profile cookie isolation, malformed state recovery, page crashes, cancelled navigation and invalid TLS; regression tests run in CI. No disabling the OS sandbox or certificate checks to get a test passing.

Website identity acceptance also requires a native FedCM account chooser and permission model, which the current Electron runtime does not provide. Resolve that engine capability and validate real Google account and third-party Google sign-in flows before claiming Google support. Popup callbacks, persistent cookies and profile isolation have local regression coverage; they do not establish provider acceptance. See [website sign-in](WEB-SIGN-IN.md).

## 2. The complete browsing interface

Implement vertical tabs, favorites, folders, drag and keyboard organization, Space themes, navigation/command bar, split pages and Peek with promotion and focus return. Deliver downloads with pause/cancel/reveal and reversible renaming, history, bookmark imports, archive recovery, printing, find, zoom, developer tools and readable errors. No inert feature buttons.

Acceptance: exercise every exposed control, keyboard-only flows, narrow/large windows, light/dark/high-contrast themes, reduced motion, native dialogs, long titles and empty/error states. Run actual Chromium integration tests and inspect rendered UI, rather than testing only reducer behavior.

## 3. Optional AI with explicit data boundaries

Version 0.5 implements six explicitly selected connections: ChatGPT subscription through the bundled official Codex app-server, Claude subscription through the installed official native Claude Code CLI, OpenAI API, Claude API, OpenRouter, and OpenAI-compatible APIs. Subscription sign-ins use separate Zacro configurations without importing personal developer credentials. API keys/configuration belong to one browser profile, provider and exact endpoint. Ordinary browsing remains independent of AI, and inference requires an explicit question. Subscription access and API billing stay separate; failures never trigger an automatic provider, model or credential fallback.

Questions, follow-ups, explicit page/PDF context, metadata-based download naming and current-answer source opening are implemented. Hosted research is enabled for ChatGPT subscription, OpenAI API, Claude API and OpenRouter. Claude subscription and compatible connections disclose that they do not provide web research. Only structured provider evidence establishes research sources; model-written URLs alone do not. PDF extraction runs in a bounded local worker with paragraph and physical-page citations. Private profiles are excluded, context remains profile-scoped, and provider changes are blocked during requests.

Version 0.6 adds editable starter questions, explicit document chips, comparison selection, draft retention, question editing/retry and answer copying with sources. Document URLs scope follow-up history; navigation requires renewed review, and cancelled or reset requests cannot restore late answers. These workflow improvements do not replace live-provider acceptance or the separate consequential-agent execution work below.

Acceptance: controlled app-server/CLI/API protocol tests, profile and endpoint isolation, encrypted/session storage, keychain failure, cancellation races, body/output bounds, malformed responses, citations and context disclosures. Connection checks inspect metadata without inference. Complete live ChatGPT/Claude sign-in, installed CLI discovery, selected model access, API billing and limits, real answers/research, citations and cancellation on each supported OS before claiming provider acceptance. Local commands, filesystem/browser tools, plugins, MCP servers and skills remain unavailable to browsing questions. Scoped consequential browser agents still require a separate verified permission and execution system.

Durable API keys require OS encryption, with session-only memory storage available only by explicit choice. Official API endpoints are fixed; custom endpoints require HTTPS except loopback HTTP, and redirects are rejected. Subscription storage follows the official runtimes and its disclosed limits. Zacro must not extract or resell subscription tokens. Commercial or hosted distribution needs a provider-specific authentication, licensing and terms review before release, including OpenAI's supported Sign in with ChatGPT requirements and Anthropic's official CLI integration rules. See [AI connections, storage and acceptance](AI.md) for the current contract and official references.

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
