# Zacro Browser

**The next chapter of Arc-inspired browsing. Built on Chromium.**

Zacro Browser is an open-source browser by Zacro Technologies, built from scratch on Chromium to bring the experience we love about Arc into a new home. A sidebar that keeps everything in reach. Spaces that separate your worlds. A command bar that lets you move at the speed you think.

Our ambition is to become the new home for Arc users: familiar in the ways that matter, shaped by the people who use it, and built to keep evolving.

Zacro is an independent project, not an official continuation of Arc or an affiliation with The Browser Company.

## Project status

**Desktop development build.** This repository now contains a runnable Chromium browser built with Electron, targeting Windows 11 x64 first. It includes real page rendering, sandboxed tabs, Spaces, separate profiles, Peek, split view, local session recovery, library panels, compatible unpacked extensions, and optional API-based AI assistance.

This is **not yet a complete implementation of the vision or a commercial release**. Zacro account sync, full Chrome extension compatibility and `chrome.storage.sync`, subscription AI sign-in, consequential browser agents, signed automatic updates, and operational/security release gates remain open. The [implementation roadmap](docs/ROADMAP.md) separates working features from required release work; [AI documentation](docs/AI.md) describes the implemented provider and data boundaries.

See the [validation record](docs/VALIDATION.md) for tests performed, package checks, and remaining acceptance work.

The 0.2 interface adds Space-tinted chrome, rounded native pages, a practical home screen, real raster site icons, and coordinated tab, panel, and dialog motion. Keyboard focus, IME composition, reduced motion, and split-pane targeting are covered by regression checks. See the [release notes](docs/RELEASE-NOTES-0.2.md) and [design and interaction notes](docs/DESIGN.md).

## Screenshots

Captured from the packaged **Zacro 0.2 Windows development build**. The example web pages and browsing data were prepared locally for this tour.

![Zacro's dark home screen with a Design studio Space, pinned favorites, folders, search, and recent pages](docs/screenshots/home-dark.jpg)

The home screen brings search, favorites, and recent pages together inside a Space-tinted frame.

| Light theme and personalization | Spaces, favorites, and folders |
| --- | --- |
| ![Light appearance with the Settings panel open](docs/screenshots/appearance-light.jpg) | ![A live journal page beside a sidebar containing favorites and an Inspiration folder](docs/screenshots/workspace.jpg) |
| Switch between light, dark, and system appearance, and customize each Space. | Keep frequent destinations pinned and group project tabs into folders. |

| Peek | Split view |
| --- | --- |
| ![A link opened in Peek with controls to close it or promote it to a tab](docs/screenshots/peek.jpg) | ![Two live journal pages arranged side by side in native split view](docs/screenshots/split-view.jpg) |
| Follow a link in a focused preview, then dismiss it or promote the live page to a tab. | Keep two pages in view while navigation controls follow the focused pane. |

| Command palette | Bookmarks and library panels |
| --- | --- |
| ![The command palette finding an open Design references tab over a blurred page backdrop](docs/screenshots/command-palette.jpg) | ![The searchable Bookmarks panel open beside the home screen](docs/screenshots/bookmarks.jpg) |
| Search tabs, enter an address, or start a web search with **Ctrl/Command + L**. | Revisit saved pages and reach history, downloads, and archived tabs from the sidebar. |

<details>
<summary>Optional AI workspace</summary>

![Ask Zacro before a provider has been connected, showing its connection prompt and context controls](docs/screenshots/optional-ai.jpg)

Ask Zacro supports optional OpenAI and Claude API-key connections. This screenshot shows the unconnected interface; no generated answer is simulated. Page sharing requires an explicit choice, and API usage is billed by the selected provider. See [AI workflows and limits](docs/AI.md).

</details>

## Run and build

Install Node.js 24 or later, then run:

```powershell
npm ci
npm start
```

Dependency installation downloads the pinned Electron runtime from its official release source. Local browsing does not require an account or API key. `npm run dev` launches the same development application. Do not use `--no-sandbox` or disable web security.

```powershell
npm run check      # JavaScript syntax validation
npm test           # State, import, security and provider protocol tests
npm run test:e2e   # Real Chromium desktop integration tests
npm run test:interactive # Disposable browser + local site for hands-on review
npm run test:soak  # Repeated native tab/Peek/split lifecycle checks
npm run pack       # Runnable application folder under dist/
npm run test:package # Verify the packaged executable, security fuses and PDF worker
npm run dist       # Unsigned Windows NSIS test installer
```

Tests create temporary profiles and local fixture servers; they do not use your normal browsing data or make paid AI calls. `npm run dist:release` requires organization code-signing credentials. An unsigned test installer does not satisfy the [commercial release gates](docs/ROADMAP.md#5-commercial-distribution). macOS and Linux build targets are configured but have not been validated on those platforms.

Browser data lives in Electron's per-user Zacro application-data directory. For an isolated development profile, set `ZACRO_USER_DATA` to a separate absolute directory. Export/import in Settings supports Zacro JSON and standard browser bookmark HTML. Arc migration currently uses supported bookmark exports; native Arc sidebar databases are not imported.

Use **Ctrl/Command + L** for the command bar, **Ctrl/Command + T** for a new tab, **F6** to move between page and browser controls, **Alt + click** or a link's context menu for Peek, and **Escape** to dismiss it. Right-click a tab to pin it, rename it, move it to a folder/Space, or split it beside another page. AI is optional: connect an API key in Settings, then use **Ctrl/Command + Enter** to ask a research question; use it again in the answer panel to open the current answer's sources.

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
- **AI where you browse.** Find useful sources, ask questions about selected pages and PDFs, and suggest download names through an optional API provider connection. Browser-task delegation remains planned work.

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

AI is an optional layer across the command bar and browsing workflow. The development build implements API-key connections, web-grounded answers, follow-ups, selected-page questions, source opening, and metadata-based download name suggestions. The broader vision below includes work still to be implemented; see [current AI workflows and limits](docs/AI.md) for exact availability. Browsing works normally without an AI connection.

### Ask first, open sources with Command + Enter

Type a question or research goal into the command bar and press **Command + Enter** on macOS, or **Ctrl + Enter** on Windows and Linux. Zacro will search the web, inspect candidate pages, and show an AI answer with source links in a conversation panel. This first action does not open source tabs. Ordinary Enter in the command bar will retain normal navigation and search behavior.

Once the answer is ready, show **Open sources · ⌘↵** (or **Ctrl + Enter** on Windows and Linux). Pressing the shortcut again while the answer panel is active, or clicking Open sources, opens a small, configurable set of supporting pages in the current Space. No page-selection explanations are shown.

Users can ask follow-up questions in the same conversation. Enter in the follow-up composer submits the question, preserving the conversation context and searching again when needed. After each answer, Open sources targets that answer's supporting pages, reuses already-open source tabs, and keeps the conversation available for further questions. Opening sources is available only when the answer is complete and has supporting pages.

Source ranking should consider relevance, primary evidence, authorship, freshness when it matters, and independent corroboration. Trustworthiness is an assessment, not a guarantee; the answer should acknowledge weak or conflicting evidence. If no strong matches are found, say so and offer ordinary search results.

### Initial AI features

- **Content-aware download names.** Suggest descriptive filenames using the source page and supported file contents, such as `invoice_2026-10_acme.pdf`. Preserve the extension, avoid collisions, and provide one-step undo. File-content uploads require an explicit user setting or action.
- **Page and PDF Q&A.** Ask questions about the current page, selected text, or a supported PDF. Cite passages and jump to the evidence; distinguish page content from outside research and say when the answer is absent.
- **Ask selected tabs.** Compare or synthesize a user-selected group of tabs, with citations back to each source and clear identification of pages that could not be read.
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

### Bring your AI connection

The goal is to support **Codex/OpenAI and Claude**, including existing subscriptions wherever the provider supports this integration, plus separately billed API-key connections. A Zacro sync account is separate from an AI provider connection; it does not include model usage.

Provider documentation reviewed on October 23, 2026:

- **OpenAI:** [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source) documents eligible ChatGPT plan usage for open-source, locally hosted apps, including a [Codex app-server integration](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server). This is the proposed subscription path, subject to account eligibility, supported capabilities, and usage limits. Paid or remotely hosted offerings require a separate provider path.
- **Claude:** The [Agent SDK subscription guidance](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) describes subscription-backed third-party usage, while the [account authentication guidance](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account) directs developers building products for others to API authentication and makes third-party subscription access discretionary. Zacro must verify a supported integration before promising Claude subscription access; API authentication is the fallback.

Connections should use each provider's supported authentication flow, protect credentials in the operating system's credential store, and show the active provider and available usage information. Never silently switch to a paid API connection when a subscription limit is reached. Search, file processing, and other services may have separate costs or limits.

Users should see which tabs, selections, or files are shared with a provider. Page content is untrusted input, not permission to execute instructions. Agent access must remain within the selected profile and granted scope; private browsing and sensitive fields are excluded by default. AI credentials must not be included in ordinary Zacro sync data.

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

- [x] Implement OpenAI and Claude API-key authentication with OS-encrypted credentials.
- [ ] Implement supported subscription authentication and validate entitlement, billing and live provider behavior.
- [x] Build provider selection, context controls, cancellation, and usage-limit handling.
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
