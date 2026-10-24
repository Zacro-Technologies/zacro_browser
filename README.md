# Zacro Browser

**The next chapter of Arc-inspired browsing. Built on Chromium.**

Zacro Browser is an open-source browser by Zacro Technologies, built from scratch on Chromium to bring the experience we love about Arc into a new home. A sidebar that keeps everything in reach. Spaces that separate your worlds. A command bar that lets you move at the speed you think.

Our ambition is to become the new home for Arc users: familiar in the ways that matter, shaped by the people who use it, and built to keep evolving.

Zacro is an independent project, not an official continuation of Arc or an affiliation with The Browser Company.

## Project status

**Early planning.** This repository currently contains the project README and license. There is no runnable browser, installer, or release yet. The capabilities below describe the product we intend to build.

## The experience

- **Sidebar-first browsing.** Vertical tabs, pinned favorites, and folders give your browsing a place to live.
- **Spaces.** Separate work, personal projects, and everything in between, with distinct tab collections and themes.
- **Profiles.** Keep accounts, cookies, and browsing data separate when you need a different identity.
- **Command bar.** Open tabs, search, navigate, and trigger browser actions from the keyboard.
- **Split view.** Work with pages side by side inside one window.
- **Peek.** Keep the Arc-inspired preview experience: open a link in an overlay, explore it without leaving the current page, then dismiss it or promote it to a full tab.
- **Tab cleanup.** Automatically archive unpinned tabs, with controls for timing and recovery.
- **Personalization.** Make the browser feel like yours through themes and thoughtful interface details.
- **Zacro account sync.** Opt in to bring your extensions and supported extension settings across compatible devices, with separate sync data for each linked browser profile.
- **AI where you browse.** Find useful sources, ask questions about pages, rename downloads, and delegate browser tasks through an optional AI provider connection.

## Peek is a core feature

Peek should feel like a natural part of browsing, not an afterthought. The planned experience includes:

- Open links in a focused overlay while preserving the underlying page and its position.
- Dismiss the preview with Escape or a close control and return to where you were.
- Promote a preview to a regular tab when it deserves a permanent place.
- Keep previews in the originating profile so account and browsing contexts stay consistent.
- Support keyboard navigation and accessible focus handling, including returning focus when the preview closes.

Exact link triggers and shortcuts will be refined during prototyping.

## Your extensions, across devices

An optional **Zacro account** will connect compatible Zacro installations through a Zacro-operated sync service. Browsing locally will remain available without an account.

The planned rollout has two parts:

1. **Extension library sync.** Sync extension identifiers, supported installation sources, and intended enabled or disabled states between explicitly linked profiles. Each device will install compatible extensions from their supported sources, preserve local security restrictions, and request any required permissions. Uninstall changes must also propagate so removed extensions do not reappear.
2. **Extension settings sync.** Integrate Zacro sync with the extension `chrome.storage.sync` API so extensions using that API can carry their preferences across devices. Local-only storage, cookies, and sign-in sessions are outside this scope; some extensions will still require separate sign-in or their own sync service.

This requires browser integration and our own authentication and sync backend. Google's Chrome Sync service is restricted for third-party browsers, so a Zacro account will not depend on it. See Chromium's [private API availability notice](https://blog.chromium.org/2021/01/limiting-private-api-availability-in.html) and the [extension storage documentation](https://developer.chrome.com/docs/extensions/reference/api/storage).

The design must cover encrypted transport and storage, device revocation, cloud-data deletion, offline changes, conflict resolution, and profile isolation before release. End-to-end encryption and account recovery need an explicit design before we make privacy guarantees. Initial scope is compatible desktop installations; mobile extension support is not assumed.

## AI that fits the workflow

AI is a planned, optional layer across the command bar, Peek, downloads, and Spaces. Users should be able to choose their provider and continue browsing normally without connecting one. All features in this section are proposals, not implemented capabilities.

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

The integration approach, interface stack, initial operating system, and build tooling are still to be selected. Chromium compatibility is a foundation, not a promise that every Chrome feature or Google service will be available.

## Principles

**Make room for the web.** Browser controls should be easy to reach and leave the page room to breathe.

**Make organization effortless.** Useful defaults should reduce tab clutter without making your work hard to find.

**Respect the user.** Keep data collection transparent, permissions understandable, and data portable. Local browsing should not require a Zacro account.

**Build in the open.** Keep development, product decisions, and contribution paths accessible to the community.

## Roadmap

### 1. Establish the foundation

- [ ] Select the Chromium integration approach and first supported operating system.
- [ ] Document a reproducible development build.
- [ ] Launch a browser window with navigation and basic tab management.
- [ ] Establish the upstream update and security maintenance process.

### 2. Build the core experience

- [ ] Add the vertical sidebar, pinned tabs, and folders.
- [ ] Implement Spaces and profile separation.
- [ ] Add the command bar and keyboard shortcuts.
- [ ] Implement Peek overlays, dismissal, and promotion to a full tab.
- [ ] Persist and restore browsing sessions.

### 3. Make it a daily browser

- [ ] Add split view and configurable tab archiving.
- [ ] Build downloads, history, bookmarks, and settings interfaces.
- [ ] Validate extension support.
- [ ] Design Zacro accounts, device management, and profile-scoped sync.
- [ ] Sync extension installation and removal across compatible desktop devices.
- [ ] Integrate supported extension settings through `chrome.storage.sync`.
- [ ] Validate sync permissions, offline conflicts, device revocation, and cloud-data deletion.
- [ ] Add import and export tools, including a migration path for Arc users where supported.
- [ ] Test accessibility, performance, stability, and recovery.

### 4. Add optional AI assistance

- [ ] Validate supported OpenAI/Codex and Claude authentication, entitlement, and billing paths.
- [ ] Build provider selection, context controls, cancellation, and usage-limit handling.
- [ ] Implement Command + Enter web-grounded answers and contextual follow-up chat.
- [ ] Add Open sources via a second Command + Enter, using the current answer's sources without duplicate tabs.
- [ ] Add cited page/PDF Q&A and content-aware download naming with undo.
- [ ] Add selected-tab comparisons and Ask Peek.
- [ ] Prototype browser agents with scoped permissions, visible actions, and confirmation controls.
- [ ] Evaluate source quality, citation accuracy, prompt-injection resistance, latency, and cost.

### 5. Ship a public preview

- [ ] Package signed builds for supported platforms.
- [ ] Implement and validate browser updates.
- [ ] Publish release notes, known limitations, and contribution guidance.

Roadmap items are goals, not release commitments. Platform availability and release dates will be announced when there are builds to test.

## Contributing

We're starting with the foundations. Ideas, workflow feedback, Chromium experience, and interface design contributions are welcome.

Open an issue to describe a proposal or a browsing workflow you want Zacro to support. For substantial implementation work, discuss the approach in an issue first so it fits the emerging architecture. Build instructions and contributor documentation will follow with the initial implementation.

## License

Original code in this repository is licensed under the [MIT License](LICENSE). Chromium and any third-party components retain their respective licenses and attribution requirements.
