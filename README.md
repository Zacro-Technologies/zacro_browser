# Zacro Browser

**The next chapter of Arc-inspired browsing. Built on Chromium.**

Zacro Browser is an open-source browser by Zacro Technologies, built with Electron and Chromium to bring the experience we love about Arc into a new home. A sidebar that keeps everything in reach. Spaces that separate your worlds. A command bar that lets you move at the speed you think.

Our ambition is to become the new home for Arc users: familiar in the ways that matter, shaped by the people who use it, and built to keep evolving.

Zacro is an independent project, not an official continuation of Arc or an affiliation with The Browser Company.

## Project status

**Desktop development preview · 0.9.** This repository contains a runnable Chromium browser built with Electron, with Windows 11 x64 and native macOS integration for Apple silicon and Intel. It includes real page rendering, sandboxed tabs, Spaces, separate profiles, Peek, split view, local session recovery, library panels, compatible unpacked extensions, and six optional AI connections: ChatGPT subscription, Claude subscription, OpenAI API, Claude API, OpenRouter, and OpenAI-compatible servers. Version 0.9 corrects the tab lifecycle and interaction details: balanced Favorite tiles, navigated-pin markers, a 12-hour Today archive default with profile controls, continuously blended Space colors, an unblurred command palette and coordinated Peek motion. The [Arc behavior study](docs/ARC-BEHAVIOR-STUDY.md) records the reference evidence and design decisions. See the [validation record](docs/VALIDATION.md) and [Mac support boundary](docs/MACOS.md) for exact test evidence and remaining release checks.

This is **not yet a complete implementation of the vision or a commercial release**. Zacro account sync, full Chrome extension compatibility and `chrome.storage.sync`, consequential browser agents, signed automatic updates, and operational/security release gates remain open. AI connection code and controlled-transport tests are implemented; live subscription sign-in, API model access, billing/limits and inference acceptance remain pending with user-authorized accounts. The [implementation roadmap](docs/ROADMAP.md) separates working features from required release work; [AI documentation](docs/AI.md) describes the connection and data boundaries.

Navigation and the address field live in the sidebar. Profile-wide icon Favorites sit above the Space name, followed by folders, saved Space pins and ordinary tabs. Drag between those regions to organize the same live page. Library, Space icons and one creation menu share the footer; page actions live in compact menus. The default sidebar is 224px wide, with 32px Comfortable tab rows and footer; existing custom widths are preserved. See the historical [0.4 design study](docs/DESIGN-REVIEW-0.4.md) and current [interaction notes](docs/DESIGN.md).

The command workflow opens a palette in an empty Space instead of creating a blank tab. New Tab and **Ctrl/Command + T** open that palette; submitting an address or search creates the page. Tab on a result opens relevant actions and destination choices; Escape steps back. Search folders, reset or replace pins, and use a configured site keyword followed by Tab to search that site. Site-search shortcuts are editable. The shortcut editor, Space keys and recent-tab switching remain available.

Choose from 38 searchable Space icons, two colors, gradient balance, grain from 0–200 and window tint opacity from 0–100 with a live preview. Native acrylic on Windows 11 22H2+ and behind-window vibrancy on macOS show blurred desktop content through the chrome; text and webpages stay opaque. The operating system controls blur strength, with opaque accessibility and platform fallbacks. Sideways gestures reveal the next Space's actual favorites, folders and tabs while both theme colors, grain and tint follow the swipe. Reversing or canceling unwinds the same transition. Right-click a footer Space icon, or use Shift+F10, for its actions. The sidebar and browser panels share a 220ms ease at Balanced speed, with no spring overshoot. Library first offers named destinations, then opens a flat, searchable panel using the window material. Its edge and the sidebar edge resize by dragging or keyboard, preserving the live page at its original rendering scale. Windows as small as **560 × 420** logical pixels are supported; panels temporarily make room by hiding the sidebar while retaining its saved preference.

The welcome tour explains the keyboard workflow, including **Command/Ctrl+S** to toggle the sidebar. Every shortcut it displays can be edited directly on that slide. Focus the sidebar with **Command/Ctrl+Alt+S**, use arrows to navigate tabs and folders, and open row actions with Shift+F10. **F10** opens the browser menu on Windows; macOS has native menu routes. The toolbar no longer includes the sidebar-toggle button or the top-left application mark. Favorites retain accessible state labels without visual status dots.

Favorites share one live document across Spaces in a profile; saved Space pins remain in their own Space. Closing either keeps the saved destination. Favorites activate their existing page. A navigated pin shows `/` beside its saved name; click its favicon or use Reset Tab to return home. Command/Ctrl-W closes the page, retains the pin at its saved address and clears the marker. Replace Pin saves the current page. Idle Favorites sleep when safe. Today tabs sit below the divider and archive after 12 hours of inactivity by default; timing can inherit the default or differ by profile. Existing choices are preserved, and active pages, media and unsaved work stay protected. Shift-click a link to Peek; ordinary off-host links from pins can also open Peek. AI actions prepare a question and show the pages selected for sharing before sending. Website login popups retain their session and callback document, then return to their opener; a Peek opener becomes a tab without reloading. Persistent website login cookies stay within their profile across normal restarts. **Direct Google account sign-in is currently reported blocked by Google.** This is separate from the missing FedCM account chooser required by some third-party flows. Full Google support requires further browser-engine work and real-provider acceptance; the 0.9 changes do not solve that restriction. See [website sign-in](docs/WEB-SIGN-IN.md) for supported mechanics, remaining engine work and the default-browser option.

The isolated [native browser experiment](experiments/google-browser-compat/README.md) now includes a pinned full Chromium source build with Zacro's own product identity, Windows/macOS build tooling, local browser tests and separate human acceptance records. The Windows attempt passed toolchain setup, source synchronization and branding/configuration, then failed its build step; **no verified native browser package is available**. Brave reached Google's password step in a user-reported reference check, which does not establish compatibility for Zacro. See [native build status and instructions](experiments/google-browser-compat/build/NATIVE-BUILD.md).

## Screenshots

The current **0.9** gallery shows the packaged Windows browser, captured intact with Computer in an isolated local demo, and native Mac captures from CI. See the [Arc behavior study](docs/ARC-BEHAVIOR-STUDY.md), [capture provenance](docs/screenshots/README.md) and [feature guide (PDF)](docs/Zacro-0.9-Design-and-Feature-Guide.pdf).

![Zacro 0.9 with six balanced Favorites, a navigated pin marker and Today tabs](docs/screenshots/0.9/workspace.jpg)

| Command palette | Space customization |
| --- | --- |
| ![The command palette casts a shadow over a sharp unchanged page](docs/screenshots/0.9/palette.jpg) | ![Circular color swatches and wider theme controls](docs/screenshots/0.9/space-theme.jpg) |

| Library | Peek |
| --- | --- |
| ![Library shares the window material without a vertical divider](docs/screenshots/0.9/library.jpg) | ![Peek retains the live page at its original rendering scale](docs/screenshots/0.9/peek.jpg) |

| Dark appearance | Compact window |
| --- | --- |
| ![Readable selections and a sharp palette backdrop in dark appearance](docs/screenshots/0.9/dark.jpg) | ![A compact window with adaptive navigation and Library](docs/screenshots/0.9/compact.jpg) |

Still images show layout; the [validation record](docs/VALIDATION.md) separately covers motion, native input and remaining acceptance limits.

<details>
<summary>0.9 · Native macOS</summary>

Unedited Apple silicon desktop captures from [the passing packaged-app run](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40706282417), including native traffic lights, menu bar and Dock. The optional Home page was explicitly opened for these acceptance fixtures; the default workflow uses the command palette.

| Light | Dark |
| --- | --- |
| ![Zacro 0.9 on macOS in light appearance](docs/screenshots/0.9/mac-arm64-light.png) | ![Zacro 0.9 on macOS in dark appearance](docs/screenshots/0.9/mac-arm64-dark.png) |

</details>

<details>
<summary>Historical 0.8 · Windows and native macOS</summary>

These **0.8** captures show the packaged Windows application in an isolated local demo. Application states were prepared by the review harness and captured intact through Computer; they are not proof of native-input acceptance. See [capture provenance](docs/screenshots/README.md), [design decisions](docs/DESIGN-REVIEW-0.8.md) and the [eight-page feature guide (PDF)](docs/Zacro-0.8-Design-and-Feature-Guide.pdf).

![Zacro 0.8 with profile Favorites, saved Space pins and a compact sidebar beside a real page](docs/screenshots/0.8/workspace.jpg)

| Library destinations | Integrated Library |
| --- | --- |
| ![Named Library options appear before a panel opens](docs/screenshots/0.8/library-menu.jpg) | ![A flat searchable Library shares the browser window material](docs/screenshots/0.8/library.jpg) |
| Choose a destination with keys or a pointer. | Resize the panel and sidebar from their edges. |

| Command workflow | Dark selection |
| --- | --- |
| ![Command palette with text filters and page-only blur](docs/screenshots/0.8/palette.jpg) | ![Clear selected command and active tab in dark appearance](docs/screenshots/0.8/dark.jpg) |
| Result actions, folder search and keyword-Tab Site Search. | Defined selection and keyboard focus. |

| Space customization | Peek |
| --- | --- |
| ![Searchable Space icons and native window material controls](docs/screenshots/0.8/space-theme.jpg) | ![Peek opens a real page while retaining the original document](docs/screenshots/0.8/peek.jpg) |
| 38 icons, two colors, grain and window tint. | Shift-click a link, then dismiss or promote it. |

![Compact Zacro with adaptive navigation and a usable Library panel](docs/screenshots/0.8/compact.jpg)

Still images document layout. The [validation record](docs/VALIDATION.md) distinguishes automated tests, native capture, physical-device input and live-provider acceptance.

<details>
<summary>Native macOS 0.8 · light and dark</summary>

| Light | Dark |
| --- | --- |
| ![Zacro 0.8 on macOS with native controls and compact navigation](docs/screenshots/0.8/macos-light.png) | ![Zacro 0.8 in dark appearance with a clearly selected tab](docs/screenshots/0.8/macos-dark.png) |

Original Apple silicon desktop captures from packaged `33aa133` in [CI run 40690651723](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40690651723). The optional New Tab Page was opened explicitly; empty Spaces normally open the command palette. Exact artifact provenance and remaining physical-device acceptance are documented separately.

</details>

</details>

<details>
<summary>Historical 0.7 · Windows and native macOS</summary>

These **0.7** Windows captures show the packaged development application in an isolated local demo workspace. They were captured through native Computer interactions without retouching. See [capture provenance](docs/screenshots/README.md), the [0.7 design decisions](docs/DESIGN-REVIEW-0.7.md), and the [design and feature guide (PDF)](docs/Zacro-0.7-Design-and-Feature-Guide.pdf).

![Zacro 0.7 with quiet sidebar navigation, favorites and tabs beside a live page](docs/screenshots/0.7/workspace.jpg)

| Browser settings | Compact window |
| --- | --- |
| ![Settings belongs to the Space-colored browser chrome beside the live page](docs/screenshots/0.7/settings.jpg) | ![Compact Zacro window with a browser panel and adaptive navigation](docs/screenshots/0.7/compact.jpg) |
| Shared panel and sidebar motion; Library keeps the real page visible. | Layout adapts down to 560 × 420 logical pixels. |

| Editable onboarding | Space actions |
| --- | --- |
| ![Welcome tour with directly editable keyboard shortcuts](docs/screenshots/0.7/onboarding.jpg) | ![Context menu for a footer Space, including customization and organization](docs/screenshots/0.7/spaces.jpg) |
| Change each displayed shortcut on its slide. | Right-click or press Shift+F10 on a Space. |

![Command palette with scoped results over the content-only blurred backdrop](docs/screenshots/0.7/palette.jpg)

Still images document layout; native interaction tests and hands-on review cover motion separately. Physical Mac trackpad and live identity-provider acceptance remain open.

<details>
<summary>Native macOS 0.7 · light and dark</summary>

| Light | Dark |
| --- | --- |
| ![Zacro 0.7 on macOS with native traffic lights, compact controls and the revised Dock icon](docs/screenshots/0.7/macos-light.png) | ![Zacro 0.7 in dark appearance on macOS](docs/screenshots/0.7/macos-dark.png) |

Unedited desktop captures from the Apple silicon package at `7766947`, from successful [Windows and native Mac CI](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40579207712). The optional New Tab Page was opened explicitly during package acceptance; empty Spaces normally open the command palette. Both Mac architectures passed 176 unit checks, 59 native cases and package acceptance at this revision.

</details>

</details>

<details>
<summary>Historical 0.6 · Windows and native macOS</summary>

The Windows images below show the packaged **0.6** development application, captured through native Computer interactions on October 26, 2026 (Japan time). They use an isolated demo workspace and local pages, with no retouching or simulated AI answers, and predate the 0.7 interface changes.

See [capture provenance](docs/screenshots/README.md) and the [0.6 design and feature guide (PDF)](docs/Zacro-0.6-Design-and-Feature-Guide.pdf).

![Zacro 0.6 workspace with customized Space chrome, favorites and a live page](docs/screenshots/0.6/workspace.jpg)

| Filtered commands | Space appearance |
| --- | --- |
| ![Zacro 0.6 command palette with category filters and browser actions](docs/screenshots/0.6/palette.jpg) | ![Zacro 0.6 Space customization with icon, colors, gradient, grain and glass controls](docs/screenshots/0.6/space-theme.jpg) |
| Find tabs, Spaces, bookmarks, history or actions. | Preview a Space's appearance before saving. |

| Reviewed AI context | Layout and motion |
| --- | --- |
| ![Zacro 0.6 Ask Zacro panel with a prepared question and explicit page context](docs/screenshots/0.6/ai-workflow.jpg) | ![Zacro 0.6 layout controls for tab spacing, page inset, corners, motion and favorite sleep](docs/screenshots/0.6/customization.jpg) |
| Prepare and review a question before sending; this capture does not establish live provider acceptance. | Choose the page frame and interaction preferences. Still captures do not demonstrate motion. |

<details>
<summary>Native macOS 0.6 · light and dark</summary>

| Light | Dark |
| --- | --- |
| ![Packaged Zacro 0.6 on macOS in light appearance with native traffic lights, menu bar and Dock](docs/screenshots/0.6/macos-light.png) | ![Packaged Zacro 0.6 on macOS in dark appearance with native traffic lights, menu bar and Dock](docs/screenshots/0.6/macos-dark.png) |

Unedited desktop captures from the packaged Apple silicon build on macOS 15.7.9, at revision `9bfcd1c`. These show the optional New Tab Page opened explicitly during package acceptance; empty Spaces normally open the command palette. The [capture record](docs/screenshots/README.md) identifies their exact revision and CI provenance. Physical-device acceptance remains separate.

</details>

</details>

<details>
<summary>Historical 0.5 · Windows and native macOS</summary>

The Windows images below document the packaged **0.5** interface, captured through native Computer interactions on October 25, 2026; they predate the 0.6 changes described above. These unretouched images use an isolated demo workspace and local pages. See [capture provenance](docs/screenshots/README.md) and the historical [0.5 design and feature guide (PDF)](docs/Zacro-0.5-Design-and-Feature-Guide.pdf).

![Zacro 0.5 with compact sidebar navigation, icon favorites, folders and single-line tabs beside a live journal page](docs/screenshots/0.5/workspace.jpg)

A 224px sidebar keeps navigation, Spaces and tabs within reach. Drag tabs into favorites to pin them, or back into the tab list to unpin them.

| Command palette | Shortcuts |
| --- | --- |
| ![Zacro 0.5 command palette with browser actions and the sidebar still available](docs/screenshots/0.5/palette.jpg) | ![Searchable Zacro 0.5 shortcut editor with bindings and reset controls](docs/screenshots/0.5/shortcuts.jpg) |
| New Tab opens a destination; the address field edits the current page. Type `/` for actions. | Familiar Arc defaults, with searchable bindings you can change, disable or reset. |

| AI connections | An empty Space |
| --- | --- |
| ![Zacro 0.5 Settings with the OpenAI API connection form](docs/screenshots/0.5/ai-connections.jpg) | ![Zacro 0.5 opening the command palette in a Space without creating a blank tab](docs/screenshots/0.5/blank-space.jpg) |
| Six explicit providers. Subscription usage and API billing stay separate; this capture does not demonstrate live sign-in or answers. | Start with the palette. A tab is created only when you submit a destination. |

<details>
<summary>Native macOS 0.5 · light and dark</summary>

| Light | Dark |
| --- | --- |
| ![Packaged Zacro 0.5 on macOS in light appearance with native traffic lights, menu bar and Dock](docs/screenshots/0.5/macos-light.png) | ![Packaged Zacro 0.5 on macOS in dark appearance with native traffic lights, menu bar and Dock](docs/screenshots/0.5/macos-dark.png) |

Unedited desktop captures from the packaged Apple silicon build on macOS 15.7.9. These show the optional New Tab Page opened explicitly during package acceptance; empty Spaces normally open the command palette. See [capture provenance](docs/screenshots/README.md).

</details>

</details>

<details>
<summary>Historical 0.4 · Windows and native macOS</summary>

These earlier captures predate the 0.5 command palette, shortcut editor and provider selection. The Windows images were captured through Computer from a packaged development build on October 24, 2026. [Download the historical 0.4 feature guide (PDF)](docs/Zacro-0.4-Design-and-Feature-Guide.pdf); its shortcuts and new-tab descriptions describe that revision.

![Zacro 0.4 with navigation and address in the compact Design studio sidebar, four icon favorites, folders and single-line tabs beside a live web page](docs/screenshots/workspace.jpg)

Navigation and the address field share the sidebar. A thin page frame leaves room for the web, with Windows window controls above it.

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

![The same page with the sidebar hidden and more width available for reading](docs/screenshots/focus-mode.jpg)

**Ctrl/Command + S** hides or shows the sidebar without reloading pages. When hidden, a compact navigation row keeps the address available. The older capture predates the shortcut change and removal of the sidebar-toggle button.

![Unconnected Ask Zacro panel with a Connect Codex button leading to subscription settings](docs/screenshots/optional-ai.jpg)

AI is optional. This historical capture shows the earlier **Connect Codex** panel. Version 0.5 offers separate ChatGPT/Claude subscription connections and four API connections in Settings. Subscription usage and API billing remain distinct, with no automatic provider or billing fallback. Page sharing requires an explicit choice. See [AI workflows and limits](docs/AI.md).

The following 0.4 captures come from the packaged Apple silicon build on macOS 15.7.9 in [CI](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40099796398), at commit `f3101841f04cda2e9441734c0b711f6e63c697e2`. Native traffic lights, the Zacro menu bar and Dock icon are visible; the recent page is the local acceptance fixture. Both Mac architectures passed native integration and packaged-application checks at that revision. Physical-device review remains open.

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
npm run test:interactive -- --showcase --compact # Minimum-size workspace
npm run test:interactive -- --onboarding # First-run tour with editable shortcuts
npm run test:soak  # Repeated native tab/Peek/split lifecycle checks
npm run pack       # Runnable application folder under dist/
npm run test:package # Verify the packaged executable, security fuses and PDF worker
npm run dist       # Unsigned Windows NSIS test installer
```

Tests create temporary profiles and local fixture servers; they do not use your normal browsing data or make paid AI calls. `npm run dist:release` requires organization code-signing credentials, and macOS releases additionally require notarization. Development artifacts do not satisfy the [commercial release gates](docs/ROADMAP.md#5-commercial-distribution). Linux remains an unvalidated packaging target.

On **macOS 13 or later**, install native Node.js 24 for your Mac's architecture and run `npm ci` followed by `npm start`. `npm run pack:mac` creates a local `.app`; `npm run dist:mac` creates separate development DMG and ZIP files for the current architecture. Use `npm run test:mac` for the Mac acceptance suite. Build Apple silicon (`arm64`) and Intel (`x64`) packages on matching hosts; cross-architecture packaging is rejected to keep Electron and the bundled Codex runtime aligned.

Mac touches include native traffic lights, a full application menu with Services and Hide, **⌘,** Settings, **⌘[ / ⌘]** history, **⌃Tab** recent-tab switching, Finder reveal, and native full screen. **⌘Tab** and **⌘H** retain their macOS meanings. Closing the browser window keeps the app available in the Dock; reopening restores the browsing session, while **⌘Q** quits. See the [Mac guide](docs/MACOS.md) for shortcuts, packaging, and release verification.

Browser data lives in Electron's per-user Zacro application-data directory. For an isolated development profile, set `ZACRO_USER_DATA` to a separate absolute directory. Export/import in Settings supports Zacro JSON and standard browser bookmark HTML. Arc migration currently uses supported bookmark exports; native Arc sidebar databases are not imported.

Use **Ctrl/Command + T** to open the command palette and **Ctrl/Command + L** to edit the current address. Opening or cancelling the palette does not add a tab. Empty Spaces open it automatically; **New Tab Page** remains available as an explicit action for the home page with search, saved destinations and recents. Filter results by Tabs, Spaces, Bookmarks, History or Actions. Type `/` or `>` for actions, `@` for tabs, or `#` for Spaces. Actions include Space customization, sleeping unused favorites and preparing AI questions. **F6** moves between the page and browser controls.

| Action | macOS | Windows / Linux |
| --- | --- | --- |
| Command palette / edit current address | ⌘T / ⌘L | Ctrl+T / Ctrl+L |
| Toggle sidebar / save page | ⌘S / ⇧⌘S | Ctrl+S / Ctrl+Shift+S |
| Focus sidebar | ⌥⌘S | Ctrl+Alt+S |
| Context menu for focused tab or Space | ⇧F10 | Shift+F10 |
| Browser menu | Native menu bar | F10 |
| Pin or unpin / bookmark | ⌘D / ⌥⌘D | Ctrl+D / Ctrl+Alt+D |
| Recent tabs / reverse recent tabs | ⌃Tab / ⌃⇧Tab | Ctrl+Tab / Ctrl+Shift+Tab |
| Previous / next tab in sidebar order | ⌥⌘↑ / ⌥⌘↓ | Ctrl+Alt+↑ / Ctrl+Alt+↓ |
| Previous / next Space | ⌥⌘← / ⌥⌘→ | Ctrl+Alt+← / Ctrl+Alt+→ |
| Space by position | ⌃1–9 | Alt+1–9 |
| Tab by position / last tab | ⌘1–8 / ⌘9 | Ctrl+1–8 / Ctrl+9 |
| Split view | ⌃⇧= | Alt+Shift+= |
| Keyboard shortcuts | ⌥⌘K | Ctrl+Alt+K |

**Ctrl + Tab** returns to the most recent tab in the current profile; keep Control held and press Tab again to move farther back. Sidebar-order commands follow pinned tabs, folders, then ordinary tabs. Open **Keyboard shortcuts** to search, record, disable or reset a binding. Conflicting assignments and protected system/editing combinations are rejected; custom bindings are saved separately for each platform. The command palette also accepts **Ctrl/Command + K** by default. These defaults follow Arc's [command and recent-tab workflow](https://start.arc.net/master-multitasking), [pinning](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), and [Space navigation](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas).

**Scroll sideways over the sidebar** to switch Spaces within the current profile; **Shift + mouse wheel** works too. The tab list follows the movement. At release, distance and recent speed decide whether it settles into the neighboring Space or returns; crossing a small fixed threshold no longer switches immediately. Reversing unwinds the preview, and the endpoints resist without wrapping. One gesture's momentum cannot advance through several Spaces. The sidebar remains usable beside the command palette. Other dialogs, text fields, dragging and pinch/zoom keep their own input. Webpage scrolling stays with the page, and each Space remembers its tab-list position. Portable wheel events require release/momentum heuristics; physical Mac trackpad acceptance remains open.

**Favorites and Space pins remain when closed.** Closing a pinned page releases its live page, after any unsaved-work decision, while retaining its name, saved address and position. Click it to open again. **Unpin tab** returns an open pin to the ordinary tab list; unpinning a closed pin removes it. Loaded, Sleeping or Closed states remain in tooltips and accessible labels, without status dots. Idle sleep defaults to 20 minutes and can be changed or disabled in **Settings → Layout & motion**. Active/split pages, media, captures, pending authentication and live popup openers, downloads and detected edits are protected; a page's beforeunload veto keeps it awake without an automatic discard prompt. Sleeping reloads the page when reopened, so it is not a promise to preserve arbitrary in-memory application state.

**Customize the frame and Space.** Edit a Space to choose from 38 searchable icons, primary/secondary colors, gradient balance, grain and window tint opacity. Native blur strength follows the operating system. Changes preview before Save. Layout & motion offers Compact/Comfortable tab spacing, 4–20px page insets, square through rounded corners, and motion speed. The same frame settings drive shell and native pages; title controls, hidden-sidebar navigation and Find retain their required top space. System reduced-motion and reduced-transparency preferences take precedence.

The sidebar footer opens the Library destination chooser or creates a tab, folder or Space. Right-click a tab to pin it, rename it, move it to a folder/Space, or split it beside another page. **Shift + click**, **Alt + click** or a link's context menu opens Peek; **Escape** dismisses it. For optional AI, see [AI workflows and connection limits](docs/AI.md).

## The experience

- **Sidebar-first browsing.** Navigation, the address field, icon favorites, folders and vertical tabs live together in a compact sidebar. Secondary actions appear in menus and on hover or keyboard focus.
- **Spaces.** Separate work, personal projects, and everything in between, with distinct tab collections, icons and customizable color/glass themes.
- **Profiles.** Keep accounts, cookies, and browsing data separate when you need a different identity.
- **Command bar.** Filter tabs, Spaces, bookmarks, history and actions, navigate, and prepare contextual AI questions from the keyboard.
- **Split view.** Work with pages side by side inside one window.
- **Peek.** Keep the Arc-inspired preview experience: open a link in an overlay, explore it without leaving the current page, then dismiss it or promote it to a full tab.
- **Tab cleanup.** Automatically archive eligible unpinned tabs, retain closed favorites, and sleep safe idle favorites with timing controls and clear status.
- **Personalization.** Make the browser feel like yours through themes and thoughtful interface details.
- **Zacro account sync (planned).** Bring extensions and supported extension settings across compatible devices, with separate sync data for each linked browser profile. Account sync is not implemented in the development build.
- **AI where you browse.** Choose your ChatGPT or Claude subscription, OpenAI or Claude API, OpenRouter, or an OpenAI-compatible server. Prepare summaries, explanations and comparisons, review selected page/PDF context, then send. Edit or retry questions, retain unfinished drafts and copy answers with source links. A selected page that navigates must be reviewed again before sharing. Supported providers also offer hosted web research; browser-task delegation remains planned work.

## Peek is a core feature

Peek is part of the implemented browsing experience:

- Open links in a focused overlay while preserving the underlying page and its position.
- Dismiss the preview with Escape or a close control and return to where you were.
- Promote a preview to a regular tab when it deserves a permanent place.
- Keep previews in the originating profile so account and browsing contexts stay consistent.
- Support keyboard navigation and accessible focus handling, including returning focus when the preview closes.

Use **Shift + click**, **Alt + click** or a link's context menu to open Peek. Its short lift, shadow and scrim animate together without scaling the webpage; reduced motion removes the travel. Promotion preserves the live page's draft, scroll position, and navigation history while adding its current destination to browser History.

Modifier-click Peek currently applies to links in the main page. Links inside embedded frames retain their native behavior; use their context menu's Peek action.

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
- [x] Add prepared summary/explanation/comparison questions, explicit document context, draft retention and edit/retry/copy controls.
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
