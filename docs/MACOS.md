# Zacro on macOS

The Mac implementation targets **macOS 13 or later**, on **Apple silicon (`arm64`) and Intel (`x64`)**. The 0.8 development branch adds native window translucency, resizable browser rails, a compact Library chooser, searchable Space icons and distinct Pinned Tabs and Favorites. These changes require fresh Mac acceptance; the historical test results and screenshots below apply only to their stated revisions.

Version 0.7 added smaller windows, matching sidebar/panel motion, incoming Space previews and an editable keyboard tour to the native window controls, menus, Dock reopening and architecture-matched packaging. Both Mac architectures passed **176 unit checks, 62 native desktop cases and packaged-application acceptance**, plus development DMG/ZIP builds, at the website-sign-in follow-up `9bf9af7` in [CI run 40680503131](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40680503131). The overall run failed when GitHub timed out finalizing Intel's validation artifact, so its later development-package upload was skipped. Physical-device and signed distribution checks remain open.

For historical context, both Mac jobs in [final 0.6 CI run 40222980054](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40222980054) passed **173 unit/security checks, 52 desktop checks, packaged-application acceptance and development DMG/ZIP generation** at commit `9bfcd1c104c5d9a7f9725fce93e32ac5fcd3ce17`. macOS 13 is the declared minimum, not a completed physical-device result. Physical Mac review, live AI account acceptance and signed/notarized release acceptance remain open.

## Everyday use

![Packaged Zacro 0.7 in dark appearance on macOS, with native traffic lights, menu bar and revised Dock icon](screenshots/0.7/macos-dark.png)

This unedited native desktop capture shows the **0.7** Apple silicon development package at `77669476468d53bb66f98d37faddae7c10bb99d8`, using a disposable profile in [CI run 40579207712](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40579207712). Both light and dark captures were visually reviewed, including the native traffic lights, application menu and Dock icon. The optional New Tab Page was opened explicitly during acceptance; an empty Space normally opens the command palette. These captures supplement native tests and do not establish physical-device acceptance. The [README gallery](../README.md#screenshots) and [capture provenance](screenshots/README.md) identify both images and their source artifact.

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
| Back / forward | ⌘[ / ⌘] |
| Settings / History / Downloads | ⌘, / ⌘Y / ⌘J |
| Toggle sidebar / full screen | ⌘S / ⌃⌘F |
| Focus sidebar / page or browser controls | ⌥⌘S / F6 |
| Copy page address | ⇧⌘C |
| Save page / keyboard shortcuts | ⇧⌘S / ⌥⌘K |
| Find / print / reload | ⌘F / ⌘P / ⌘R |
| Reload without cache | ⇧⌘R |
| Quit | ⌘Q |

⌘T opens the command palette without creating a tab. An empty Space opens it automatically; submitting an address or search creates the page, and cancelling keeps the Space empty. Choose New Tab Page explicitly to open the home page. The sidebar stays interactive beside the palette. ⌘L edits the current destination. The palette filters All, Tabs, Spaces, Bookmarks, History and Actions; `/` or `>` searches actions, `@` searches tabs, and `#` searches Spaces. Space customization, sleeping unused favorites, and prepared AI questions are available as actions.

⌃Tab returns to the most recent tab in the current profile. Keep Control held and press Tab again to move farther back; Shift reverses the direction. The Option-Command-Up/Down commands follow sidebar order instead: pins, folders, then ordinary tabs. Open Keyboard Shortcuts to search, record, disable and reset bindings. Defaults and aliases come from the shared catalog, and overrides are stored separately for macOS. These conventions follow Arc's [command and recent-tab workflow](https://start.arc.net/master-multitasking), [pinning](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), and [Space navigation](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas).

The welcome tour introduces commands, the sidebar, Spaces, favorites and preferences. Every shortcut displayed in the tour can be changed there, with the same conflict checks as Keyboard Shortcuts. Reopen the tour through browser commands. There is no permanent sidebar-toggle icon: ⌘S and the command menu provide that action. ⌥⌘S reveals and focuses the sidebar, arrows move through its tabs and folders, and Enter activates the focused destination. F6 returns to page/browser controls. The sidebar shortcut preserves an active webpage field's focus when invoked from that page.

⌘Tab remains the system application switcher, and ⌘H hides the application. Horizontal scrolling over the sidebar switches Spaces within the current profile; ordinary webpage scrolling remains with the page. Favorites, folders and tabs follow the finger as one page, while the neighboring Space's contents enter beside them. The footer stays fixed and no extra Space-name badge appears. Sufficient distance or a qualifying projected flick settles into the neighbor at release, while a reversal or short movement can settle back. One gesture's momentum tail cannot advance repeatedly, and endpoints resist without wrapping. Each Space retains its tab-list position. Forms, text fields, dragging and pinch/zoom keep their input. Portable wheel events do not always expose contact phases, so release detection also uses a short pause/deceleration heuristic. Physical-trackpad acceptance remains open.

Right-click a footer Space icon to switch, customize, rename, move the current tab there, create or delete a Space, with unavailable actions omitted or disabled. Shift+F10 opens the same menu from keyboard focus.

At Balanced motion, keyboard Space changes use a 220ms transition. Sidebar and browser panels share a 220ms monotonic ease-out without spring or overshoot. Shell width and native page bounds follow the same samples, preserving the live page and focus; interrupted motion reverses from its displayed position. Quick/Relaxed/Gentle settings adjust both rails. Reduced motion settles both immediately, including when the system preference changes during a transition.

Library first opens a small menu beside its footer button: Bookmarks, History, Downloads and Archived tabs, followed by Settings, Extensions and Ask Zacro. The panel's title opens the same chooser. Arrow keys, Home/End and typing a destination's initial move through the choices; Enter selects and Escape returns to the opener. Search filters compact rows grouped by date. From a search field, Down enters the page list and Up from the first row returns to search. Download rows keep Show in Finder visible, with Rename, Suggest name and Undo rename in their action menu.

The Library panel shares the Space's window tint and grain without another background layer. Its menu stays within browser chrome, so the native webpage retains its live document and pixel scale. Closing releases panel interaction immediately and slides the chrome away. Opening a panel from its keyboard shortcut remains direct.

The browser window can shrink to 560×420. Drag the sidebar's right edge or Library panel's left edge to resize it; double-click an edge to restore its default width. The edges are keyboard-focusable and support arrow keys. A wide sidebar adapts to the available room while retaining its saved size. At narrow widths an open panel temporarily retracts the sidebar to retain a page at least 240px wide; closing the panel or expanding the window restores it. The command palette can use the full window width when the page is narrow, while blur stays inside the page's unchanged rounded frame. Settings, shortcut lists, theme controls and palette results scroll within short windows.

Customize Space offers searchable icons, two colors, gradient balance, grain and **Window tint opacity**, with a live preview before Save. Below 100%, macOS uses behind-window vibrancy to reveal system-blurred content behind the browser chrome. Text and webpage surfaces stay fully opaque. The operating system controls blur strength; there is no separate blur-radius slider. Setting the tint to 100%, enabling Reduce Transparency or high contrast, or losing native material support restores opaque chrome while preserving the saved Space preference. Cancel restores the saved appearance. On Windows, the equivalent acrylic material requires Windows 11 22H2 or later; older Windows versions and other unsupported platforms use opaque chrome. Physical Mac review of this new material remains open.

**Settings → Layout & motion** adds tab spacing, a shared 4–20px page inset, corner radius, motion speed and idle-favorite timing. With the sidebar shown, Mac page top/side/bottom gutters use the selected inset; hidden-sidebar navigation or Find retains its 40px top reservation. Traffic-light clearance remains separate from page framing.

Pinned Tabs are named rows saved within one Space, above Today. Favorites are icon tiles shared by Spaces using the same profile; they stay separate from other profiles and private sessions. Drag a tab above Today to pin it or into the icon row to make it a Favorite. ⌘D pins or unpins; ⌥⌘D keeps the separate bookmark action. A pin's label resumes its current page, while its favicon resets to the saved destination. A Favorite tile also returns to its saved destination. The context menu offers **Replace pin with current page** when browsing away from that destination. Ordinary links to another host open in Peek, while forms, redirects and site-owned popup flows keep their normal behavior. Shift-click previews a link explicitly.

⌘W on a Pinned Tab or Favorite closes its live page but keeps its name, position and saved destination, subject to any unsaved-work decision. Reopening starts a fresh page at that destination. Loaded, Sleeping or Closed remains in its tooltip and accessible name; the icon has no status dot beneath it. Idle sleep defaults to 20 minutes and can be disabled. Active/split/Peek-source pages, media/captures, downloads, authentication and detected edits are retained; beforeunload can silently veto sleeping. Unknown editing state is treated conservatively, but sleeping does not preserve arbitrary JavaScript state. Unpinning an open page moves it into Today; unpinning an already closed item removes the saved shortcut.

Ask Zacro and the command palette can prepare a summary, explanation, comparison or research question. They send nothing until submission. Context chips identify the selected page URLs, independent of the newly active tab; navigation or closure requires review before another send. Edit, Retry and Copy operate on the displayed conversation, with partial answers marked incomplete and drafts retained within the current profile. Enter sends and ⇧Enter inserts a line; IME composition does not submit. See [AI workflows](AI.md) for connection, storage and provider limits. Live ChatGPT/Claude sign-in, API model access and paid usage remain separate acceptance checks.

Zacro currently uses one browser window. ⌘N opens that window if closed or brings it forward; it does not create an independent second browsing window. Closing the window keeps the application available in the Dock. Reopening restores tabs and the active Space from the session; pages reload after an approved window close. Beforeunload decisions still protect pages that report unsaved work. Quit exits the application, and cancelling a close warning cancels the pending quit.

Successfully closing the last window ends private sessions: private profile metadata, cookies and session data are cleared before reopening. Cancelling the close keeps the private session intact. Regular profile sessions remain available, and user-saved downloads remain on disk.

The application bundle declares HTTP/HTTPS handling so macOS can offer Zacro for web links. Links received before startup or while no window is open are validated and opened after the window is ready. An installed build exposes an explicit **Default browser** action in Settings that requests the operating system's choice; Zacro does not take over automatically. Local-file browsing and arbitrary protocol handlers remain unsupported.

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

The GitHub Actions workflow has separate `macos-15` Apple silicon and `macos-15-intel` jobs. **0.7 native Mac verification is pending.** The results below apply only to historical 0.6 and must not be read as approval of the new layout, motion or onboarding.

At the final **0.6** runtime `9bfcd1c104c5d9a7f9725fce93e32ac5fcd3ce17`, [run 40222980054](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40222980054) passed **173 unit/security tests, 52 desktop integration tests and one packaged-application test per architecture**, plus formatting, syntax and native development DMG/ZIP generation. Both jobs completed successfully with zero failures on macOS 15.7.9 build 24G830. The Windows-only DPAPI restart check skips on Mac. These architecture-labeled artifacts are development outputs, not a signed/notarized public release.

That 0.6 runtime includes the earlier release gesture and sidebar spring, custom framing, retained/sleeping favorites, palette filters, reviewed AI-context workflows and composer-sizing fix. Its Apple silicon light/dark images have been retrieved and visually reviewed. The 0.7 interface replaces the spring and changes the sidebar/panel presentation, so those images remain historical alongside the 0.5 screenshots. [VALIDATION.md](VALIDATION.md) records exact revisions.

The Darwin-only suite covers native traffic-light position and layout, menu conventions, Cmd-based shortcuts, Ctrl-Tab, native full screen, guest-page editing, window close/Dock reopen, validated web links, pre-ready link delivery, cancellation of Quit with unsaved work, and private-session cleanup after the last window closes. It is skipped on non-Mac hosts. The Mac command also includes shared browser, renderer contract, motion, Space-scroll, favorite lifecycle, personalization, local-provider AI workflow, security and startup native-paint tests. The counts above apply to the stated revision. The packaged suite checks actual browsing, security fuses, PDF parsing and an isolated signed-out Codex handshake; it does not make authenticated model requests.

Before release, test on physical Apple silicon and Intel Macs with a keyboard and trackpad, multiple displays, full screen, Spaces/Mission Control, Finder file dialogs, camera/microphone/location consent, printing, VoiceOver, keyboard-only navigation, reduced motion/transparency and display scaling. Include slow drags, reversals, release/momentum tails, rapid sidebar toggles, custom insets and favorite sleep vetoes. Complete ChatGPT/Claude authentication and provider-specific API inference with user-authorized accounts to validate access, sources, billing/limits and cancellation; controlled fixtures do not establish those results. Record OS versions, architecture, exact commit and observed limitations in [the validation record](VALIDATION.md).

References: [Apple Mac design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [Electron window controls](https://www.electronjs.org/docs/latest/api/browser-window), [Electron app lifecycle](https://www.electronjs.org/docs/latest/api/app), [Electron's macOS minimum version](https://www.electronjs.org/blog/electron-44-0), [GitHub's native Mac runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), and [Electron macOS signing guidance](https://www.electronjs.org/docs/latest/tutorial/code-signing#macos).
