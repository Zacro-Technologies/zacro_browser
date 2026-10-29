# Zacro on macOS

The Mac implementation targets **macOS 13 or later**, on **Apple silicon (`arm64`) and Intel (`x64`)**. Version **0.9**, at runtime `8069153e0b5fc43fb5a0bcfdf4f96b1ab32e452b`, combines native window translucency, resizable browser rails, a compact Library chooser and distinct Favorites, Pinned Tabs and Today tabs with continuous Space colors, sharp command-palette backgrounds and animated Peek previews.

Both Mac architectures passed **202 unit/security checks, 86 native desktop cases and one packaged-application check**, with one Windows-only skip each, in [final CI run 40713486954 at `dc0f445`](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40713486954). Development DMG/ZIP creation and all validation/package uploads passed. The runtime is unchanged by that revision's test-readiness fixes. [VALIDATION.md](VALIDATION.md) records the exact evidence.

These are native CI and development-package results. macOS 13 is the declared minimum, not a completed physical-device result. Physical Mac review, live Google/AI account acceptance and signed/notarized distribution remain open; Google sign-in is currently blocked as detailed below.

## Everyday use

![Packaged Zacro 0.9 in dark appearance on macOS, with native traffic lights, aligned navigation, menu bar and Dock icon](screenshots/0.9/mac-arm64-dark.png)

This unedited 1024×768 native desktop capture shows the **0.9** Apple silicon development package at runtime `8069153`, using a disposable profile in [CI run 40706282417](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40706282417). Both this image and its [light appearance counterpart](screenshots/0.9/mac-arm64-light.png) were visually reviewed for traffic-light/navigation alignment, compact chrome, page gutters and dark selection contrast. The optional Home page was opened explicitly during packaged acceptance; an empty Space normally opens the command palette. The source validation ZIP's SHA-256 was verified before extraction. [Capture provenance](screenshots/README.md) and the [0.9 manifest](screenshots/0.9/manifest.json) record artifact `12823049726`, image hashes and dimensions. Still images do not establish physical trackpad feel, desktop blur or live sign-in acceptance.

The red, yellow and green window controls are native macOS controls. Their reserved area remains clear when the sidebar is hidden. Full screen uses the operating system's transition and screen arrangement; returning to a window restores the controls' layout. The interface follows system light/dark appearance, reduced motion, reduced transparency and increased contrast, uses the system font, and dims chrome when inactive.

Zacro's menu bar exposes browser actions without adding another menu row inside the window. The application menu contains Settings, Services, Hide and Quit. Window actions use native Minimize, Zoom and Bring All to Front. Edit actions target the focused page or browser field, including Undo, Redo, Select All, and Paste and Match Style. Downloads offer **Show in Finder**. These choices follow [Apple's Mac design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) and [Electron's native menu behavior](https://www.electronjs.org/docs/latest/api/menu-item).

Page context menus include spelling suggestions and macOS Look Up for selected text. Native pages use macOS scroll bounce. The Dock menu offers the browser window, command palette and a new private Space without requiring an existing window.

| Action                               | Mac shortcut |
| ------------------------------------ | ------------ |
| Command palette / edit current address | ⌘T or ⌘K / ⌘L |
| Reopen closed tab | ⇧⌘T |
| Close tab / close window | ⌘W / ⇧⌘W |
| Open or bring forward browser window | ⌘N |
| New private Space | ⇧⌘N |
| Recent tabs / reverse recent tabs | ⌃Tab / ⌃⇧Tab |
| Previous / next tab in sidebar order | ⌥⌘↑ / ⌥⌘↓ |
| Previous / next Space | ⌥⌘← / ⌥⌘→ |
| Space by position | ⌃1–9 |
| Tab by position / last tab | ⌘1–8 / ⌘9 |
| Pin or unpin / bookmark | ⌘D / ⌥⌘D |
| Split view | ⌃⇧= |
| Back / forward | ⌘← / ⌘→ (also ⌘[ / ⌘]) |
| Settings / History / Downloads | ⌘, / ⌘Y / ⌘J |
| Toggle sidebar / full screen | ⌘S / ⌃⌘F |
| Focus sidebar / page or browser controls | ⌥⌘S / F6 |
| Copy page address / paste and search | ⇧⌘C / ⌃⌘V |
| Save page / keyboard shortcuts | ⇧⌘S / ⌥⌘K |
| Find / print / reload | ⌘F / ⌘P / ⌘R |
| Reload without cache | ⇧⌘R |
| Quit | ⌘Q |

⌘T opens the command palette without creating a tab. An empty Space opens it automatically; submitting an address or search creates the page, and cancelling keeps the Space empty. Choose New Tab Page explicitly to open the home page. The sidebar stays interactive beside the palette. ⌘L edits the current destination. The palette filters All, Tabs, Spaces, Bookmarks, History and Actions; `/` or `>` searches actions, `@` searches tabs, and `#` searches Spaces. Space customization, sleeping unused favorites, and prepared AI questions are available as actions.

⌃Tab returns to the most recent tab in the current profile. Keep Control held and press Tab again to move farther back; Shift reverses the direction. The Option-Command-Up/Down commands follow sidebar order instead: Favorites, pins and folders, then Today tabs. Open Keyboard Shortcuts to search, record, disable and reset bindings. Defaults and aliases come from the shared catalog, and overrides are stored separately for macOS. These conventions follow Arc's [command and recent-tab workflow](https://start.arc.net/master-multitasking), [pinning](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), and [Space navigation](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas).

The welcome tour introduces commands, the sidebar, Spaces, favorites and preferences. Every shortcut displayed in the tour can be changed there, with the same conflict checks as Keyboard Shortcuts. Reopen the tour through browser commands. ⌘S hides the sidebar and address strip for a content-only view; ⌘L still opens the address command palette. The pane button beside the window controls toggles the sidebar; a small floating pane button restores it in content-only view. ⌥⌘S reveals and focuses the sidebar, arrows move through its tabs and folders, and Enter activates the focused destination. F6 returns to page/browser controls. The sidebar shortcut preserves an active webpage field's focus when invoked from that page.

⌘Tab remains the system application switcher, and ⌘H hides the application. Horizontal scrolling over the sidebar switches Spaces within the current profile; ordinary webpage scrolling remains with the page. Favorites, folders and tabs follow the finger as one page, while the neighboring Space's contents enter beside them. Window colors and tint blend with the same gesture progress, including reversal and cancellation, without changing either Space's saved theme. The footer stays fixed and no extra Space-name badge appears. A quick swipe moves one Space; a longer, sustained swipe can cross several Spaces and snaps to the page reached when released. Momentum is ignored, and endpoints resist without wrapping. Each Space retains its tab-list position. Forms, text fields, dragging and pinch/zoom keep their input. Native contact phases keep a held swipe continuous; platforms without contact signals use a bounded quiet-period heuristic. Physical-trackpad acceptance remains open.

Right-click a footer Space icon to switch, customize, rename, move the current tab there, create or delete a Space, with unavailable actions omitted or disabled. Shift+F10 opens the same menu from keyboard focus.

At Balanced motion, keyboard Space changes use a 220ms transition. Sidebar and browser panels share a 220ms monotonic ease-out without spring or overshoot. Shell width and native page bounds follow the same samples, preserving the live page and focus; interrupted motion reverses from its displayed position. Quick/Relaxed/Gentle settings adjust both rails. Reduced motion settles both immediately, including when the system preference changes during a transition.

Peek enters in 180ms and exits in 120ms at Balanced motion. Its live webpage translates with the surrounding preview chrome at a fixed document size and zoom; it is not scaled or replaced by a screenshot. Promoting Peek keeps the same document, history and form state. A cancelled unsaved-work close restores the preview, and reduced motion settles immediately.

Library first opens a small menu beside its footer button: Bookmarks, History, Downloads and Archived tabs, followed by Settings, Extensions and Ask Zacro. The panel's title opens the same chooser. Arrow keys, Home/End and typing a destination's initial move through the choices; Enter selects and Escape returns to the opener. Search filters compact rows grouped by date. From a search field, Down enters the page list and Up from the first row returns to search. Download rows keep Show in Finder visible, with Rename, Suggest name and Undo rename in their action menu.

The Library panel shares the Space's window tint and grain without another background layer. Its menu stays within browser chrome, so the native webpage retains its live document and pixel scale. Closing releases panel interaction immediately and slides the chrome away. Opening a panel from its keyboard shortcut remains direct.

The browser window can shrink to 560×420. Drag the sidebar's right edge or Library panel's left edge to resize it; double-click an edge to restore its default width. The edges are keyboard-focusable and support arrow keys. A wide sidebar adapts to the available room while retaining its saved size. At narrow widths an open panel temporarily retracts the sidebar to retain a page at least 240px wide; closing the panel or expanding the window restores it. The command palette can use the full window width when the page is narrow. Its floating card has a shadow; the page behind it has no blur, tint or filter, and keeps its rounded frame. Settings, shortcut lists, theme controls and palette results scroll within short windows.

The palette's static page backdrop preserves native-resolution PNG pixels, including HiDPI captures, within explicit pixel and byte limits. Resizing or otherwise changing page geometry while the palette is open clears that backdrop, preserving the query, focus and underlying document; dismissing and reopening captures the current page. It does not stretch an old image or display a blurred fallback. [Validation](VALIDATION.md) records the capture limits and this overlay-resize limitation.

Customize Space offers searchable icons, two colors, gradient balance, color intensity, grain and **Window tint opacity**. The preview uses the same appearance layers as the window, and folders follow the Space accent. Opacity spans 0–100; on macOS it directly controls background transparency, including the empty content pane, while text and webpages remain opaque. There is no fixed native blur layer masking low opacity settings. Reduce Transparency and high contrast restore opaque chrome while preserving the saved preference. Cancel restores the saved appearance. Windows uses acrylic on Windows 11 22H2 or later; unsupported systems use opaque chrome.

**Settings → Layout & motion** adds tab spacing, a shared 4–20px page inset, corner radius, motion speed and idle-favorite timing. Mac page top/side/bottom gutters use the selected inset, including in content-only view. Find reserves space while open. Traffic-light clearance remains separate from page framing.

Pinned Tabs are named rows saved within one Space, above Today. Favorites are icon tiles shared by Spaces using the same profile; they stay separate from other profiles and private sessions. Favorite rows balance their tile sizes as their count and sidebar width change. Drag a tab above Today to pin it or into the icon row to make it a Favorite. ⌘D pins or unpins; ⌥⌘D keeps the separate bookmark action. A pin's label resumes its current page, while its favicon resets to the saved destination. A Favorite tile activates its current live page; use an explicit Reset action in its menu or the command palette to return home. A closed pin or Favorite opens its saved destination.

Saved titles and icons remain stable while browsing. A slash marks a pin or Favorite that has navigated away from its saved URL, including a changed page fragment; resetting or closing clears it. The context menu offers **Replace pin with current page** to change the saved destination. Ordinary links from pins and Favorites to another host open in Peek, while forms, redirects and site-owned popup flows keep their normal behavior. Shift-click previews a link explicitly. The [Arc behavior study](ARC-BEHAVIOR-STUDY.md) records the source behavior and implementation boundaries.

⌘W on a Pinned Tab or Favorite closes its live page but keeps its name, position and saved destination, subject to any unsaved-work decision. Reopening starts a fresh page at that destination. Loaded, Sleeping or Closed remains in its tooltip and accessible name; the icon has no status dot beneath it. Idle sleep defaults to 20 minutes and can be disabled. Active/split/Peek-source pages, media/captures, downloads, authentication and detected edits are retained; beforeunload can silently veto sleeping. Unknown editing state is treated conservatively, but sleeping does not preserve arbitrary JavaScript state. Unpinning an open page moves it into Today; unpinning an already closed item removes the saved shortcut.

Today tabs automatically archive after **12 hours of inactivity** by default. Profiles can inherit the browser default or choose their own interval, including Never. Recent activity restarts the interval. Clean background pages can expire even while loaded, while selected/split/Peek-source pages, media/capture, downloads, authentication relationships, detected edits and unsaved-work vetoes remain protected. Archived tabs can be restored from Library. Pins and Favorites never auto-archive.

Ask Zacro and the command palette can prepare a summary, explanation, comparison or research question. They send nothing until submission. Context chips identify the selected page URLs, independent of the newly active tab; navigation or closure requires review before another send. Edit, Retry and Copy operate on the displayed conversation, with partial answers marked incomplete and drafts retained within the current profile. Enter sends and ⇧Enter inserts a line; IME composition does not submit. See [AI workflows](AI.md) for connection, storage and provider limits. Live ChatGPT/Claude sign-in, API model access and paid usage remain separate acceptance checks.

Zacro currently uses one browser window. ⌘N opens that window if closed or brings it forward; it does not create an independent second browsing window. Closing the window keeps the application available in the Dock. Reopening restores tabs and the active Space from the session; pages reload after an approved window close. Beforeunload decisions still protect pages that report unsaved work. Quit exits the application, and cancelling a close warning cancels the pending quit.

Successfully closing the last window ends private sessions: private profile metadata, cookies and session data are cleared before reopening. Cancelling the close keeps the private session intact. Regular profile sessions remain available, and user-saved downloads remain on disk.

The application bundle declares HTTP/HTTPS handling so macOS can offer Zacro for web links. Links received before startup or while no window is open are validated and opened after the window is ready. An installed build exposes an explicit **Default browser** action in Settings that requests the operating system's choice; Zacro does not take over automatically. Local-file browsing and arbitrary protocol handlers remain unsupported.

Website redirect and popup mechanics are tested, including POST login callbacks, but **Google currently rejects direct sign-in in this embedded browser**. The runtime also lacks a native FedCM account chooser, and macOS platform passkeys are not configured. **Open in default browser** is available; authentication there remains in that browser's session. See [website sign-in](WEB-SIGN-IN.md) for the engine limitations and live acceptance required before claiming Google support.

## Develop and package

Use native Node.js 24 or later on the Mac where the build will run. Install dependencies separately for each architecture:

```sh
npm ci
npm start
npm test
npm run test:mac
npm run pack:mac
npm run test:package
npm run dist:mac
```

The runnable bundle is `dist/mac-arm64/Zacro.app` on Apple silicon and `dist/mac/Zacro.app` on Intel. Development archives are named `Zacro-<version>-mac-<arch>-development.dmg` and `.zip`. The DMG includes an Applications shortcut. The icon contains native `.icns` sizes for Finder and Dock rendering.

Both Electron and Codex are native executables. The build validates their binary architecture and rejects cross-platform, cross-architecture and universal targets rather than shipping a mismatched runtime. Build the two distributions on corresponding hosts; a universal bundle would require a separate native-dependency merge strategy. Browsing remains available without AI authentication. Optional Codex sign-in uses Zacro's isolated OS keyring credentials and never imports a developer's Codex credentials.

Development bundles are ad-hoc signed and omit Hardened Runtime. They are for local validation, not a trusted public release. Publisher release commands require a Developer ID identity and notarization configuration. No Apple credentials are included in this repository or requested by ordinary browsing/build-preview workflows.

## Sign and verify a release

`npm run dist:release` on a native Mac runs source checks, unit tests, the Mac suite, release packaging and packaged acceptance. Configure the signing identity using `CSC_LINK` with `CSC_KEY_PASSWORD`, or an installed Developer ID selected through `CSC_NAME`. Supply one complete notarization mechanism: Apple ID/app-specific password/team ID; App Store Connect API key/key ID/issuer; or an existing `APPLE_KEYCHAIN_PROFILE`. See the release script for exact environment names. Store these through the release operator's secret-management system, not source files.

The release build uses Hardened Runtime and narrowly scoped entitlements, signs the embedded Codex executable, notarizes the application and DMG, and validates signatures and stapled tickets. `codesign`, `spctl`, and `stapler` checks must succeed. The ZIP contains the notarized application. The pipeline does not publish artifacts or configure automatic updates by itself.

Passing a build is only one release gate. A Mac release still needs clean-machine installation and removal, publisher and ticket verification, real site/media/OAuth acceptance, assistive-technology review, and the broader [commercial release requirements](ROADMAP.md).

## Native verification

The GitHub Actions workflow has separate `macos-15` Apple silicon and `macos-15-intel` jobs. At the **0.9 runtime `8069153`**, both passed in [final run 40713486954 at test revision `dc0f445`](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40713486954):

| Check | Apple silicon | Intel |
| --- | --- | --- |
| Unit/security | 202 passed | 202 passed |
| Native desktop | 86 passed; 1 Windows-only skip | 86 passed; 1 Windows-only skip |
| Packaged application | 1 passed | 1 passed |
| Development DMG and ZIP | Passed | Passed |
| Validation and package uploads | Both passed | Both passed |

Formatting and syntax checks also passed. The Windows-only DPAPI restart check skips on Mac. The overall cross-platform run and all five artifact uploads completed successfully. These architecture-labeled packages are ad hoc signed development outputs, not signed/notarized public releases. The Apple silicon light/dark packaged desktop images above were retrieved, digest-verified and visually reviewed. [VALIDATION.md](VALIDATION.md) records the exact runtime, fixture-readiness corrections, subsequent test-only runs and remaining acceptance work.

The Darwin-only suite covers native traffic-light position and layout, menu conventions, Cmd-based shortcuts, Ctrl-Tab, native full screen, guest-page editing, window close/Dock reopen, validated web links, pre-ready link delivery, cancellation of Quit with unsaved work, and private-session cleanup after the last window closes. It is skipped on non-Mac hosts. The Mac command also includes shared browser, renderer contract, motion, Space-scroll, pin/Favorite lifecycle, archive protection, rail resizing, personalization, lossless HiDPI backdrop, local-provider AI workflow, security and startup native-paint tests. The counts above apply to the stated revision. The packaged suite checks actual browsing, security fuses, PDF parsing and an isolated signed-out Codex handshake; it does not make authenticated model requests.

Earlier evidence remains historical: [0.7 run 40680503131](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40680503131) passed both architectures' 176 unit checks, 62 native cases, packaged acceptance and development builds at `9bf9af7`, but the overall run failed when Intel's validation upload timed out and its package upload was skipped. [0.6 run 40222980054](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40222980054) passed 173 unit/security checks, 52 desktop cases, packaged acceptance and development builds per architecture at `9bfcd1c`. Those revisions and older screenshots do not establish acceptance of 0.9.

Before release, test on physical Apple silicon and Intel Macs with a keyboard and trackpad, multiple displays, full screen, Spaces/Mission Control, Finder file dialogs, camera/microphone/location consent, printing, VoiceOver, keyboard-only navigation, reduced motion/transparency and display scaling. Include slow drags, reversals, release/momentum tails, rapid sidebar toggles, custom insets and favorite sleep vetoes. Complete ChatGPT/Claude authentication and provider-specific API inference with user-authorized accounts to validate access, sources, billing/limits and cancellation; controlled fixtures do not establish those results. Record OS versions, architecture, exact commit and observed limitations in [the validation record](VALIDATION.md).

References: [Apple Mac design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [Electron window controls](https://www.electronjs.org/docs/latest/api/browser-window), [Electron app lifecycle](https://www.electronjs.org/docs/latest/api/app), [Electron's macOS minimum version](https://www.electronjs.org/blog/electron-44-0), [GitHub's native Mac runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), and [Electron macOS signing guidance](https://www.electronjs.org/docs/latest/tutorial/code-signing#macos).
