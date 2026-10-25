# Zacro Browser

**The next chapter of Arc-inspired browsing. Built on Chromium.**

Zacro Browser is an open-source browser by Zacro Technologies, built from scratch on Chromium to bring the experience we love about Arc into a new home. A sidebar that keeps everything in reach. Spaces that separate your worlds. A command bar that lets you move at the speed you think.

Our ambition is to become the new home for Arc users: familiar in the ways that matter, shaped by the people who use it, and built to keep evolving.

Zacro is an independent project, not an official continuation of Arc or an affiliation with The Browser Company.

## Project status

**Desktop development build · 0.5.** This repository contains a runnable Chromium browser built with Electron, with Windows 11 x64 and native macOS integration for Apple silicon and Intel. It includes real page rendering, sandboxed tabs, Spaces, separate profiles, Peek, split view, local session recovery, library panels, compatible unpacked extensions, and six optional AI connections: ChatGPT subscription, Claude subscription, OpenAI API, Claude API, OpenRouter, and OpenAI-compatible servers. The previous 0.4 revision passed Windows and native macOS 15 CI on both Mac architectures, including packaged-application acceptance and development DMG/ZIP builds. The current command, shortcut, gesture and provider changes are undergoing validation; those earlier results do not certify this revision. Physical Mac review and signed/notarized release acceptance remain open. See [macOS setup and validation](docs/MACOS.md) for the exact support boundary.

This is **not yet a complete implementation of the vision or a commercial release**. Zacro account sync, full Chrome extension compatibility and `chrome.storage.sync`, consequential browser agents, signed automatic updates, and operational/security release gates remain open. AI connection code and controlled-transport tests are implemented; live subscription sign-in, API model access, billing/limits and inference acceptance remain pending with user-authorized accounts. The [implementation roadmap](docs/ROADMAP.md) separates working features from required release work; [AI documentation](docs/AI.md) describes the connection and data boundaries.

See the [validation record](docs/VALIDATION.md) for tests performed, package checks, and remaining acceptance work.

The 0.4 interface revision brings navigation and the address field into the sidebar. Icon favorites sit above the Space name, followed by folders, a quiet New Tab row and single-line tabs. Library, Space indicators and one creation menu share the footer; page actions live in compact menus. The default sidebar is 224px wide, with 32px tab rows and footer; existing custom widths are preserved. Short feedback, immediate dismissal and immediate native-page resizing keep the interface responsive. See the [0.4 design study](docs/DESIGN-REVIEW-0.4.md), [validation record](docs/VALIDATION.md#04-interface-revision), and [interaction notes](docs/DESIGN.md).

The 0.5 workflow opens a command palette in an empty Space instead of creating a blank tab. New Tab and **Ctrl/Command + T** open that palette; submitting an address or search creates the page. This revision adds the shortcut editor, Arc-style pinning and Space keys, recent-tab switching, proportional trackpad feedback, and explicit subscription/API provider selection. Usage and validation limits are described below.

## Screenshots

**Historical 0.4 captures:** these screenshots and the linked PDF show the previous packaged interface, before the current blank-Space, shortcut and gesture changes. Fresh captures are pending. They were taken through native Computer interactions and window capture, using an isolated demo workspace and local journal pages. See [capture provenance](docs/screenshots/README.md).

![Zacro 0.4 with navigation and address in the compact Design studio sidebar, four icon favorites, folders and single-line tabs beside a live web page](docs/screenshots/workspace.jpg)

Navigation and the address field share the sidebar. A thin page frame leaves room for the web, with Windows window controls above it. [Download the historical 0.4 feature guide (PDF)](docs/Zacro-0.4-Design-and-Feature-Guide.pdf); its shortcut and new-tab descriptions predate the current workflow.

| New tab · dark                                                                                                 | Settings · light                                                                                            |
| -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| ![Minimal dark new-tab page with search, saved destinations, and recent pages](docs/screenshots/home-dark.jpg) | ![Compact light Settings with inline controls and expandable groups](docs/screenshots/appearance-light.jpg) |
| Search, saved pages, and recents.                                                                              | Everyday preferences first; details on demand.                                                              |

| Peek                                                                            | Split view                                                                     |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| ![Live link preview with promote and close controls](docs/screenshots/peek.jpg) | ![Two native web pages arranged side by side](docs/screenshots/split-view.jpg) |
| Follow a link without losing your place.                                        | Compare pages with stable panes.                                               |

| Command palette                                                                                         | Library                                                                                            |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| ![Compact command palette with tab results over the current page](docs/screenshots/command-palette.jpg) | ![Bookmarks panel with search and quick Library section switching](docs/screenshots/bookmarks.jpg) |
| Find a tab or enter an address.                                                                         | Bookmarks, history, downloads, and archived tabs.                                                  |

<details>
<summary>Focus mode and optional AI</summary>

![The same page with the sidebar hidden and more width available for reading](docs/screenshots/focus-mode.jpg)

**Ctrl/Command + S** now hides or shows the sidebar without reloading pages. When hidden, a compact navigation row keeps the address and sidebar toggle available. The older capture predates this shortcut change.

![Unconnected Ask Zacro panel with a Connect Codex button leading to subscription settings](docs/screenshots/optional-ai.jpg)

AI is optional. This historical capture shows the earlier **Connect Codex** panel. Version 0.5 offers separate ChatGPT/Claude subscription connections and four API connections in Settings. Subscription usage and API billing remain distinct, with no automatic provider or billing fallback. Page sharing requires an explicit choice. See [AI workflows and limits](docs/AI.md).

</details>

<details>
<summary>Native macOS · light and dark</summary>

These 0.4 captures come from the packaged Apple silicon build on macOS 15.7.9 in [CI](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40099796398). Native traffic lights, the Zacro menu bar and Dock icon are visible; the recent page is the local acceptance fixture. Both Mac architectures passed native integration and packaged-application checks. Physical-device review remains open.

![Zacro on macOS in light appearance with native window controls, application menu and Dock icon](docs/screenshots/macos-light.png)

![Zacro on macOS in dark appearance with native window controls and a compact sidebar](docs/screenshots/macos-dark.png)

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

Tests create temporary profiles and local fixture servers; they do not use your normal browsing data or make paid AI calls. `npm run dist:release` requires organization code-signing credentials, and macOS releases additionally require notarization. Development artifacts do not satisfy the [commercial release gates](docs/ROADMAP.md#5-commercial-distribution). Linux remains an unvalidated packaging target.

On **macOS 13 or later**, install native Node.js 24 for your Mac's architecture and run `npm ci` followed by `npm start`. `npm run pack:mac` creates a local `.app`; `npm run dist:mac` creates separate development DMG and ZIP files for the current architecture. Use `npm run test:mac` for the Mac acceptance suite. Build Apple silicon (`arm64`) and Intel (`x64`) packages on matching hosts; cross-architecture packaging is rejected to keep Electron and the bundled Codex runtime aligned.

Mac touches include native traffic lights, a full application menu with Services and Hide, **⌘,** Settings, **⌘[ / ⌘]** history, **⌃Tab** recent-tab switching, Finder reveal, and native full screen. **⌘Tab** and **⌘H** retain their macOS meanings. Closing the browser window keeps the app available in the Dock; reopening restores the browsing session, while **⌘Q** quits. See the [Mac guide](docs/MACOS.md) for shortcuts, packaging, and release verification.

Browser data lives in Electron's per-user Zacro application-data directory. For an isolated development profile, set `ZACRO_USER_DATA` to a separate absolute directory. Export/import in Settings supports Zacro JSON and standard browser bookmark HTML. Arc migration currently uses supported bookmark exports; native Arc sidebar databases are not imported.

Use **Ctrl/Command + T** to open the command palette and **Ctrl/Command + L** to edit the current address. Opening or cancelling the palette does not add a tab. Empty Spaces open it automatically; **New Tab Page** remains available as an explicit action for the home page with search, saved destinations and recents. Type `/` to find browser actions. **F6** moves between the page and browser controls.

| Action | macOS | Windows / Linux |
| --- | --- | --- |
| Command palette / edit current address | ⌘T / ⌘L | Ctrl+T / Ctrl+L |
| Toggle sidebar / save page | ⌘S / ⇧⌘S | Ctrl+S / Ctrl+Shift+S |
| Pin or unpin / bookmark | ⌘D / ⌥⌘D | Ctrl+D / Ctrl+Alt+D |
| Recent tabs / reverse recent tabs | ⌃Tab / ⌃⇧Tab | Ctrl+Tab / Ctrl+Shift+Tab |
| Previous / next tab in sidebar order | ⌥⌘↑ / ⌥⌘↓ | Ctrl+Alt+↑ / Ctrl+Alt+↓ |
| Previous / next Space | ⌥⌘← / ⌥⌘→ | Ctrl+Alt+← / Ctrl+Alt+→ |
| Space by position | ⌃1–9 | Alt+1–9 |
| Tab by position / last tab | ⌘1–8 / ⌘9 | Ctrl+1–8 / Ctrl+9 |
| Split view | ⌃⇧= | Alt+Shift+= |
| Keyboard shortcuts | ⌥⌘K | Ctrl+Alt+K |

**Ctrl + Tab** returns to the most recent tab in the current profile; keep Control held and press Tab again to move farther back. Sidebar-order commands follow pinned tabs, folders, then ordinary tabs. Open **Keyboard shortcuts** to search, record, disable or reset a binding. Conflicting assignments and protected system/editing combinations are rejected; custom bindings are saved separately for each platform. The command palette also accepts **Ctrl/Command + K** by default. These defaults follow Arc's [command and recent-tab workflow](https://start.arc.net/master-multitasking), [pinning](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), and [Space navigation](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas).

**Scroll sideways over the sidebar** to switch Spaces within the current profile; **Shift + mouse wheel** works too. The tab list follows the movement, a short deliberate flick or longer drag commits a switch, and continued momentum cannot skip through several Spaces. Reversing before the switch unwinds the preview; the endpoints resist without wrapping. The sidebar remains usable beside the command palette. Other dialogs, text fields, dragging and pinch/zoom keep their own input. Webpage scrolling stays with the page, and each Space remembers its tab-list position.

The sidebar footer opens Library or creates a tab, folder or Space. Right-click a tab to pin it, rename it, move it to a folder/Space, or split it beside another page. **Alt + click** or a link's context menu opens Peek; **Escape** dismisses it. For optional AI, see [AI workflows and connection limits](docs/AI.md).

## The experience

- **Sidebar-first browsing.** Navigation, the address field, icon favorites, folders and vertical tabs live together in a compact sidebar. Secondary actions appear in menus and on hover or keyboard focus.
- **Spaces.** Separate work, personal projects, and everything in between, with distinct tab collections and themes.
- **Profiles.** Keep accounts, cookies, and browsing data separate when you need a different identity.
- **Command bar.** Open tabs, search, navigate, and trigger browser actions from the keyboard.
- **Split view.** Work with pages side by side inside one window.
- **Peek.** Keep the Arc-inspired preview experience: open a link in an overlay, explore it without leaving the current page, then dismiss it or promote it to a full tab.
- **Tab cleanup.** Automatically archive unpinned tabs, with controls for timing and recovery.
- **Personalization.** Make the browser feel like yours through themes and thoughtful interface details.
- **Zacro account sync (planned).** Bring extensions and supported extension settings across compatible devices, with separate sync data for each linked browser profile. Account sync is not implemented in the development build.
- **AI where you browse.** Choose your ChatGPT or Claude subscription, OpenAI or Claude API, OpenRouter, or an OpenAI-compatible server. Ask about selected pages/PDFs and suggest download names; supported providers also offer hosted web research. Browser-task delegation remains planned work.

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

AI is an optional layer across the command bar and browsing workflow. Settings offers **ChatGPT subscription**, **Claude subscription**, **OpenAI API**, **Claude API**, **OpenRouter**, and **OpenAI-compatible API** connections. All support questions, follow-ups, explicitly selected page/PDF extracts, and metadata-based download name suggestions, subject to the selected account/model/server's capabilities. Browsing works normally without a connection. See [current AI workflows and limits](docs/AI.md) for the provider matrix and pending live acceptance.

### Ask first, then open sources

Type a question into the command palette and use **Option + Command + G** on macOS or **Ctrl + Alt + G** on Windows/Linux. **Ctrl/Command + Enter** is also a default alias. ChatGPT subscription, OpenAI API, Claude API and OpenRouter can use hosted search and return source links. Claude subscription and compatible servers answer without web research and show that limitation. Asking does not open source tabs; ordinary Enter retains normal navigation and search behavior.

When an answer finishes with supporting sources, click **Open sources** or press the AI shortcut again with the answer panel active. Zacro opens a small, configurable set of those pages in the current Space and reuses matching tabs. Only structured provider search results or citation annotations establish research sources; model-written links alone are not treated as verified evidence.

Enter in the follow-up composer submits another question with bounded conversation context. Hosted-search providers can research again when needed. Open sources always targets the current completed answer. Page questions share only the selected extracts and disable outside research; private profiles are excluded.

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

### Choose a connection

**ChatGPT subscription** uses the bundled official Codex app-server and your own sign-in. It has a separate Zacro configuration and credential-store entry; it never imports credentials from the Codex desktop app or a developer's terminal setup. OS keychain failures are reported, with an explicit session-only sign-in option. Your account's Codex allowance and model access apply.

**Claude subscription** uses an installed official native Claude Code CLI and your own sign-in in a separate Zacro configuration. Zacro does not extract or replay OAuth tokens. The CLI manages credential storage, including its documented local-file behavior on Windows/Linux and macOS Keychain fallback. It runs with browser, shell, file and other client tools disabled; web research is not enabled for this connection.

**OpenAI API**, **Claude API**, **OpenRouter**, and **OpenAI-compatible API** use keys and billing from the provider you explicitly select. API requests and hosted search may incur charges. Keys are scoped to a browser profile, provider and exact endpoint, stored through OS encryption or kept in memory only when you explicitly choose session-only storage. Changing an endpoint does not forward its old key. Compatible servers require an HTTPS base URL, except HTTP on localhost/loopback.

There is no automatic switch between providers, subscriptions, models or API keys after failure. **Test saved connection** checks account/model metadata without inference; it does not guarantee model or search access. Subscription sign-ins are app-level connections, while API configuration and credentials belong to their browser profile. Zacro account sync is separate and remains planned.

Research does not attach open pages, history, cookies or downloads. Page questions share only explicitly chosen text. Neither subscription runtime nor an API answer can perform browser actions or execute local tools. See [credential storage](docs/AI.md#sign-in-and-credential-storage), [runtime restrictions](docs/AI.md#runtime-and-network-restrictions), and [remaining acceptance](docs/AI.md#validation-and-remaining-acceptance). Live sign-in/inference and provider-specific commercial distribution requirements must be reviewed before release.

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

- [x] Implement isolated ChatGPT subscription sign-in and the official Claude Code subscription connection.
- [x] Add explicit OpenAI API, Claude API, OpenRouter and OpenAI-compatible connections, with no automatic provider or billing fallback.
- [x] Add profile/endpoint-bound API key encryption and explicit session-only storage, with connection checks that make no inference request.
- [ ] Complete live sign-in, model access, provider billing/limits, research and inference acceptance with user-authorized accounts.
- [x] Build model selection, context controls, cancellation, and usage-limit handling.
- [x] Implement hosted research for supported providers, explicit no-research notices for other connections, and contextual follow-up chat.
- [x] Add Open sources through the AI shortcut or button, reusing matching tabs in the current Space.
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
