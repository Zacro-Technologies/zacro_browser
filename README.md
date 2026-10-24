# Zacro Browser

**The next chapter of Arc-inspired browsing. Built on Chromium.**

Zacro Browser is an open-source browser by Zacro Technologies, built from scratch on Chromium to bring the experience we love about Arc into a new home. A sidebar that keeps everything in reach. Spaces that separate your worlds. A command bar that lets you move at the speed you think.

Our ambition is to become the new home for Arc users: familiar in the ways that matter, shaped by the people who use it, and built to keep evolving.

Zacro is an independent project, not an official continuation of Arc or an affiliation with The Browser Company.

## Project status

**Desktop development build.** This repository contains a runnable Chromium browser built with Electron, targeting Windows 11 x64 first. It includes real page rendering, sandboxed tabs, Spaces, separate profiles, Peek, split view, local session recovery, library panels, compatible unpacked extensions, and optional AI through your Codex subscription.

This is **not yet a complete implementation of the vision or a commercial release**. Zacro account sync, full Chrome extension compatibility and `chrome.storage.sync`, consequential browser agents, signed automatic updates, and operational/security release gates remain open. Subscription sign-in is implemented; live account and inference acceptance still requires a user to finish ChatGPT sign-in. The [implementation roadmap](docs/ROADMAP.md) separates working features from required release work; [AI documentation](docs/AI.md) describes the connection and data boundaries.

See the [validation record](docs/VALIDATION.md) for tests performed, package checks, and remaining acceptance work.

The 0.3 redesign puts the page first: compact chrome, icon favorites, single-line tabs, a minimal new-tab page, and a sidebar you can hide. Library and Settings reveal secondary controls when needed. Short 100–160ms feedback makes changes clear; dismissal and page resizing happen immediately. See the [design study](docs/DESIGN-REVIEW-0.3.md), [release notes](docs/RELEASE-NOTES-0.3.md), and [interaction notes](docs/DESIGN.md).

## Screenshots

Captured from the packaged **Zacro 0.3 Windows development build**, using an isolated demo workspace and local journal pages.

![Zacro 0.3 with a compact Design studio sidebar, four icon favorites, folders, and single-line tabs beside a live web page](docs/screenshots/workspace.jpg)

A 44px toolbar, compact sidebar, and thin page frame leave room for the web.

| New tab · dark | Settings · light |
| --- | --- |
| ![Minimal dark new-tab page with search, saved destinations, and recent pages](docs/screenshots/home-dark.jpg) | ![Compact light Settings with inline controls and expandable groups](docs/screenshots/appearance-light.jpg) |
| Search, saved pages, and recents. | Everyday preferences first; details on demand. |

| Peek | Split view |
| --- | --- |
| ![Live link preview with promote and close controls](docs/screenshots/peek.jpg) | ![Two native web pages arranged side by side](docs/screenshots/split-view.jpg) |
| Follow a link without losing your place. | Compare pages with stable panes. |

| Command palette | Library |
| --- | --- |
| ![Compact command palette with tab results over the current page](docs/screenshots/command-palette.jpg) | ![Bookmarks panel with search and quick Library section switching](docs/screenshots/bookmarks.jpg) |
| Find a tab or enter an address. | Bookmarks, history, downloads, and archived tabs. |

<details>
<summary>Focus mode and optional AI</summary>

![The same page with the sidebar hidden and more width available for reading](docs/screenshots/focus-mode.jpg)

**Ctrl/Command + Shift + B** hides or shows the sidebar without reloading pages.

![Compact Ask Zacro panel with ChatGPT sign-in for a Codex subscription](docs/screenshots/optional-ai.jpg)

AI is optional. Choose **Sign in with ChatGPT** to use your account's Codex allowance. Zacro has no API-key or separate API-billing fallback. Page sharing requires an explicit choice. This capture shows the unconnected interface. See [AI workflows and limits](docs/AI.md).

</details>

## Run and build

Install Node.js 24 or later, then run:

```powershell
npm ci
npm start
```

Dependency installation downloads the pinned Electron and official Codex runtimes. Local browsing does not require an account. `npm run dev` launches the same development application. Do not use `--no-sandbox` or disable web security.

```powershell
npm run check      # JavaScript syntax validation
npm test           # State, import, security and provider protocol tests
npm run test:e2e   # Real Chromium desktop integration tests
npm run test:interactive # Disposable browser + local site for hands-on review
npm run test:interactive -- --showcase # Populated design-review workspace
npm run test:soak  # Repeated native tab/Peek/split lifecycle checks
npm run pack       # Runnable application folder under dist/
npm run test:package # Verify the packaged executable, security fuses and PDF worker
npm run dist       # Unsigned Windows NSIS test installer
```

Tests create temporary profiles and local fixture servers; they do not use your normal browsing data or make paid AI calls. `npm run dist:release` requires organization code-signing credentials. An unsigned test installer does not satisfy the [commercial release gates](docs/ROADMAP.md#5-commercial-distribution). macOS and Linux build targets are configured but have not been validated on those platforms.

Browser data lives in Electron's per-user Zacro application-data directory. For an isolated development profile, set `ZACRO_USER_DATA` to a separate absolute directory. Export/import in Settings supports Zacro JSON and standard browser bookmark HTML. Arc migration currently uses supported bookmark exports; native Arc sidebar databases are not imported.

Use **Ctrl/Command + L** for the command bar, **Ctrl/Command + T** for a new tab, **F6** to move between page and browser controls, **Ctrl/Command + Shift + B** to toggle the sidebar, **Alt + click** or a link's context menu for Peek, and **Escape** to dismiss it. Right-click a tab to pin it, rename it, move it to a folder/Space, or split it beside another page. For optional AI, sign in with ChatGPT in Settings or Ask Zacro, then use **Ctrl/Command + Enter** to ask a research question; use it again in the answer panel to open the current answer's sources.

## The experience

- **Sidebar-first browsing.** Vertical tabs, pinned favorites, and folders give your browsing a place to live.
- **Spaces.** Separate work, personal projects, and everything in between, with distinct tab collections and themes.
- **Profiles.** Keep accounts, cookies, and browsing data separate when you need a different identity.
- **Command bar.** Open tabs, search, navigate, and trigger browser actions from the keyboard.
- **Split view.** Work with pages side by side inside one window.
- **Peek.** Keep the Arc-inspired preview experience: open a link in an overlay, explore it without leaving the current page, then dismiss it or promote it to a full tab.
- **Tab cleanup.** Automatically archive unpinned tabs, with controls for timing and recovery.
- **Personalization.** Make the browser feel like yours through themes and thoughtful interface details.
- **Zacro account sync (planned).** Bring extensions and supported extension settings across compatible devices, with separate sync data for each linked browser profile. Account sync is not implemented in the development build.
- **AI where you browse.** Use your Codex subscription to research questions, ask about selected pages and PDFs, and suggest download names. Browser-task delegation remains planned work.

## Peek is a core feature

Peek is part of the implemented browsing experience:

- Open links in a focused overlay while preserving the underlying page and its position.
- Dismiss the preview with Escape or a close control and return to where you were.
- Promote a preview to a regular tab when it deserves a permanent place.
- Keep previews in the originating profile so account and browsing contexts stay consistent.
- Support keyboard navigation and accessible focus handling, including returning focus when the preview closes.

Use **Alt + click** or a link's context menu to open Peek. Promotion preserves the live page's draft, scroll position, and navigation history while adding its current destination to browser History.

## Your extensions, across devices

An optional **Zacro account** will connect compatible Zacro installations through a Zacro-operated sync service. Browsing locally will remain available without an account.

The planned rollout has two parts:

1. **Extension library sync.** Sync extension identifiers, supported installation sources, and intended enabled or disabled states between explicitly linked profiles. Each device will install compatible extensions from their supported sources, preserve local security restrictions, and request any required permissions. Uninstall changes must also propagate so removed extensions do not reappear.
2. **Extension settings sync.** Integrate Zacro sync with the extension `chrome.storage.sync` API so extensions using that API can carry their preferences across devices. Local-only storage, cookies, and sign-in sessions are outside this scope; some extensions will still require separate sign-in or their own sync service.

This requires browser integration and our own authentication and sync backend. Google's Chrome Sync service is restricted for third-party browsers, so a Zacro account will not depend on it. See Chromium's [private API availability notice](https://blog.chromium.org/2021/01/limiting-private-api-availability-in.html) and the [extension storage documentation](https://developer.chrome.com/docs/extensions/reference/api/storage).

The design must cover encrypted transport and storage, device revocation, cloud-data deletion, offline changes, conflict resolution, and profile isolation before release. End-to-end encryption and account recovery need an explicit design before we make privacy guarantees. Initial scope is compatible desktop installations; mobile extension support is not assumed.

## AI that fits the workflow

AI is an optional layer across the command bar and browsing workflow. The development build implements ChatGPT sign-in through a Zacro-managed Codex runtime, web research, follow-ups, selected-page questions, source opening, and metadata-based download name suggestions. Browsing works normally without an AI connection. See [current AI workflows and limits](docs/AI.md) for exact availability and live-verification requirements.

### Ask first, open sources with Command + Enter

Type a question or research goal into the command bar and press **Command + Enter** on macOS, or **Ctrl + Enter** on Windows and Linux. Zacro will search the web, inspect candidate pages, and show an AI answer with source links in a conversation panel. This first action does not open source tabs. Ordinary Enter in the command bar will retain normal navigation and search behavior.

Once the answer is ready, show **Open sources · ⌘↵** (or **Ctrl + Enter** on Windows and Linux). Pressing the shortcut again while the answer panel is active, or clicking Open sources, opens a small, configurable set of supporting pages in the current Space. No page-selection explanations are shown.

Users can ask follow-up questions in the same conversation. Enter in the follow-up composer submits the question, preserving the conversation context and searching again when needed. After each answer, Open sources targets that answer's supporting pages, reuses already-open source tabs, and keeps the conversation available for further questions. Opening sources is available only when the answer is complete and has supporting pages.

Source ranking should consider relevance, primary evidence, authorship, freshness when it matters, and independent corroboration. Trustworthiness is an assessment, not a guarantee; the answer should acknowledge weak or conflicting evidence. If no strong matches are found, say so and offer ordinary search results.

### Further AI work

- **Content-aware download names.** Suggest descriptive filenames using the source page and supported file contents, such as `invoice_2026-10_acme.pdf`. Preserve the extension, avoid collisions, and provide one-step undo. File-content uploads require an explicit user setting or action.
- **More precise page context.** Current-page, selected-tab and supported-PDF questions are implemented with evidence links. Selected-text questions and richer evidence highlighting remain planned work.
- **Browser agent.** Research, navigate, extract information, and prepare forms within explicitly granted tabs and sites. Show progress, allow interruption, and request confirmation before sending messages, purchasing, deleting, or submitting consequential changes unless the user has already explicitly authorized that exact action.

### Further ideas to explore

- **Ask Peek.** Preview a link, see a short summary, and ask a follow-up without leaving the original page.
- **Semantic find.** Find a concept such as "the cancellation fee" even when the page uses different wording, and highlight the supporting passage.
- **Compare tabs.** Turn selected product pages, documentation, or articles into a cited comparison table, marking missing information and disagreements.
- **Find that page again.** Search opted-in browsing history by meaning: "the article with the database benchmark I read last week." Keep the index local where feasible, exclude private browsing, and respect history deletion.
- **Resume a Space.** Generate an on-demand recap of saved research, decisions, and unresolved questions, with links to the relevant tabs.
- **Tidy tabs.** Suggest short titles, groups, and duplicates to close. Preview changes and support undo.
- **Selection actions.** Explain, translate, or extract dates and tables from selected content into a copyable format.
- **Reusable browser tasks.** Save an explicitly configured workflow, such as collecting weekly reports, with site permissions, a visible run history, and controls for any recurring runs.

### Use your Codex subscription

Choose **Sign in with ChatGPT** in Settings or Ask Zacro and finish the official sign-in in your system browser. Zacro manages its own bundled Codex app-server and separate credential-store entry. It does not reuse credentials from the Codex desktop app or an existing command-line setup. The model list comes from the signed-in Codex connection; account access and limits still apply.

Questions use your account's Codex allowance. There is no API-key field, Claude connection, or automatic switch to separate API billing. No inference request is made merely by connecting. A Zacro sync account is separate from this AI connection.

Only explicitly chosen page/PDF text is shared for page questions; private profiles are excluded. Research enables hosted web search without access to open pages. Local command execution, filesystem access, installed skills, plugins, and MCP integrations are unavailable to the assistant. See [AI security and privacy](docs/AI.md#credentials-and-privacy) for the enforced boundaries and current verification limits.

This local open-source build uses the authentication flow documented for [Codex app-server](https://learn.chatgpt.com/docs/app-server#authentication-endpoints). Commercial or hosted distribution requires a separate supported Sign in with ChatGPT integration review before release.

## Built on Chromium

Chromium is the foundation. We are building a new browser interface and product experience on top of its web platform, rather than creating a new rendering engine.

The technical goals are to:

- Use Chromium's Blink rendering engine and V8 JavaScript engine.
- Preserve Chromium's process isolation and sandbox protections.
- Support Chromium-compatible extensions.
- Keep pace with upstream security and compatibility updates.
- Build the sidebar, Spaces, tab management, and command bar as a cohesive browser experience.

The initial integration uses Electron 45, a sandboxed HTML/CSS/JavaScript interface, isolated native WebContentsViews, Node.js 24 development tooling, and electron-builder packaging. Windows is the first validation target. Chromium compatibility is a foundation, not a promise that every Chrome feature or Google service is available. In particular, Electron's extension API subset cannot satisfy the full extension-sync vision without additional engine work.

## Principles

**Make room for the web.** Browser controls should be easy to reach and leave the page room to breathe.

**Make organization effortless.** Useful defaults should reduce tab clutter without making your work hard to find.

**Respect the user.** Keep data collection transparent, permissions understandable, and data portable. Local browsing should not require a Zacro account.

**Build in the open.** Keep development, product decisions, and contribution paths accessible to the community.

## Roadmap

### 1. Establish the foundation

- [x] Select the Chromium integration approach and first supported operating system.
- [x] Document a reproducible development build.
- [x] Launch a browser window with navigation and basic tab management.
- [ ] Establish the upstream update and security maintenance process.

### 2. Build the core experience

- [x] Add the vertical sidebar, pinned tabs, and folders.
- [x] Implement Spaces and profile separation.
- [x] Add the command bar and keyboard shortcuts.
- [x] Implement Peek overlays, dismissal, and promotion to a full tab.
- [x] Persist and restore browsing sessions.

### 3. Make it a daily browser

- [x] Add split view and configurable tab archiving (live pages are protected from automatic archiving).
- [x] Build downloads, history, bookmarks, and settings interfaces.
- [x] Manage compatible unpacked extensions with profile isolation and enable/disable/remove controls.
- [ ] Validate broader extension compatibility, action/options UI and required Chrome APIs.
- [ ] Design Zacro accounts, device management, and profile-scoped sync.
- [ ] Sync extension installation and removal across compatible desktop devices.
- [ ] Integrate supported extension settings through `chrome.storage.sync`.
- [ ] Validate sync permissions, offline conflicts, device revocation, and cloud-data deletion.
- [x] Import/export Zacro data and standard bookmark HTML, including supported bookmark exports from other browsers.
- [ ] Add and validate native Arc sidebar migration.
- [x] Add local keyboard, contrast, reduced-motion, lifecycle and recovery regressions.
- [ ] Complete assistive-technology review, sustained performance testing and real-site compatibility acceptance.

### 4. Add optional AI assistance

- [x] Implement managed ChatGPT subscription sign-in with isolated Codex credentials and no API-key fallback.
- [ ] Complete live sign-in, account-access, usage-limit and inference acceptance with a user-authorized account.
- [x] Build model selection, context controls, cancellation, and usage-limit handling.
- [x] Implement Command + Enter web-grounded answers and contextual follow-up chat.
- [x] Add Open sources via a second Command + Enter, reusing matching tabs in the current Space.
- [x] Add cited page/PDF Q&A, selected-tab questions and metadata-based download naming with undo.
- [ ] Add selected-text Q&A, file-content naming and direct Ask Peek.
- [ ] Prototype browser agents with scoped permissions, visible actions, and confirmation controls.
- [ ] Evaluate source quality, citation accuracy, prompt-injection resistance, latency, and cost.

### 5. Ship a public preview

- [ ] Package signed builds for supported platforms.
- [ ] Implement and validate browser updates.
- [x] Document development release notes, known limitations, and contribution guidance.
- [ ] Publish an accepted, signed public preview with its support and incident-reporting processes.

Roadmap items are goals, not release commitments. Platform availability and release dates will be announced when there are builds to test.

## Contributing

Ideas, workflow feedback, Chromium experience, security review, and interface design contributions are welcome. Read the [implementation contract](docs/IMPLEMENTATION-CONTRACT.md), [release roadmap](docs/ROADMAP.md), and [security boundaries](docs/SECURITY.md) before changing privileged browser behavior.

Open an issue to describe a proposal or a browsing workflow you want Zacro to support. For substantial implementation work, discuss the approach in an issue first so it fits the architecture. Run `npm run verify` for local validation; CI also packages the Windows application. Keep credentials, browser profiles, and generated installers out of source control.

## License

Original code in this repository is licensed under the [MIT License](LICENSE). Chromium and any third-party components retain their respective licenses and attribution requirements.
