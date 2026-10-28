# Validation record

Validated locally on Windows 11 x64 (OS build 26200), Node.js 24.19.0, Electron 45.0.0 and Chromium 156.0.8078.48. This record describes engineering verification of the development build, not commercial certification or a security audit.

## 0.9 tab behavior, sharp overlays and Peek motion

The final runtime is **`8069153`**. The changes distinguish profile-wide Favorites, per-Space pins and Today tabs; balance Favorite rows; preserve pin destinations and icons; use a 12-hour archive default with profile overrides; blend Space appearance continuously; and coordinate native Peek motion without scaling the document.

Final cross-platform [CI at `dc0f445`](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40713486954) completed successfully on October 29, 2026 (JST), with the same runtime:

| Platform | Unit/security | Native desktop | Packaged app | Additional |
| --- | --- | --- | --- | --- |
| Windows x64 | 202 passed | 101 passed; 6 Mac-only skips | 1 passed | 40-cycle lifecycle check and validation upload passed |
| macOS, Apple silicon | 202 passed | 86 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP and both uploads passed |
| macOS, Intel | 202 passed | 86 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP and both uploads passed |

All three jobs and the overall run completed successfully, including formatting, syntax and all five artifact uploads. The Mac packages are ad hoc signed development builds, not notarized releases. Decoded logs and artifact provenance are retained under `test-results/ci-40713486954/`. The subsequent publication commits change documentation and its generator only; the tested application runtime is unchanged.

Local verification on October 28–29, 2026 (JST):

| Check | Confirmed result | Evidence |
| --- | --- | --- |
| Final unit/security suite | 202 passed | `test-results/0.9-release-units.log` |
| Final formatting and syntax | Both passed | `test-results/0.9-release-format-check.log`, `test-results/0.9-release-syntax.log` |
| Earlier full desktop run | 98 passed, one stale layout assertion failed, six Mac-only skips | `test-results/0.9-verify-final.log` |
| Corrected compact Favorite check | Passed; targets remain compact and eight rows fit | `test-results/0.9-compact-favorite-regression.log` |
| Final backdrop/resize and Peek regressions | Five passed | `test-results/0.9-backdrop-resize-final.log` |
| Material lease synchronization regression | Three consecutive runs passed | `test-results/0.9-material-lease-ci-regression.log` |
| Native resize and Peek readiness regressions | Two passed | `test-results/0.9-native-readiness.log` |
| Adjacent native readiness checks | Six passed | `test-results/0.9-all-native-readiness.log` |
| Ordinary and closing-Peek login popup checks | Four passed | `test-results/0.9-peek-popup-clock.log` |
| Settings target measurement | One passed | `test-results/0.9-panel-target-readiness.log` |
| Current Peek and Favorite geometry | Two passed | `test-results/0.9-current-geometry-readiness.log` |
| Local 40-cycle lifecycle soak | Passed; two WebContents at every sample | `test-results/0.9-soak.log` |

The earlier full run's sole failure expected the former 40px Favorite height; its corrected acceptance range retains the meaningful compact-target and visible-row checks. The first unit run also exposed a stale WebContents mock missing `isDevToolsOpened`; the corrected fixture additionally verifies that open DevTools protects a page. The final unit suite passes independently. Repeated targeted runs are not additional distinct cases.

- **Archive and pins:** clean loaded Today pages can expire, while selected/split/Peek-source pages, media/capture, downloads, authentication relationships, detected edits and beforeunload vetoes stay protected. An intervening selection cancels automatic closing. Startup inactivity, recovery, profile inheritance, changed defaults and imported Never/custom intervals are covered. Favorite row geometry is checked for one through twelve tiles, wider rails and profile isolation. Same-document navigation keeps the saved favicon/title, shows the slash and retains the saved pin when closed.
- **Peek:** native bounds change during the entrance while document identity, size and zoom stay constant. Promotion, replacement, reduced motion and a vetoed close retain page state. GET and POST popups arriving during the visual close retain the actual opener and callback; a popup cannot allocate an orphan once native closing has begun. The Intel sampling fixture now observes the native view from its first bounds update, before navigation commits.
- **Backdrops:** the palette has a shadow with no page filter, tint or radius change. Native PNG bytes and decoded backing dimensions match the source, including a 3840×2160 image represented at 2× scale. Pixel and byte bounds, an exact odd-pixel rounding boundary, privacy, dismissal and stale-copy rejection pass. Geometry changes clear the static image while retaining query, focus and page state; reopening captures current pixels. Hidden Chromium views did not reliably repaint at resized viewport dimensions, so live overlay recomposition remains an engine limitation. No off-window rendering workaround ships.
- **Lifecycle observations:** the local soak recorded a 483ms cycle median and 499ms p95; sampled process memory changed from 401,128 to 734,808 KiB. These fixture observations establish bounded lifecycle behavior, not general browsing performance or a long-term memory guarantee.

Historical CI at [`4fd9822`](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40699437474) passed Windows and Apple silicon but failed one Intel Peek sampling assertion because URL commit could follow the completed animation. The later [`ed36ad7` run](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40702549878) exposed a material fixture issuing manual leases before the renderer's real transition settled. The corrected fixture waits for publication and completed motion; stale-token protection is still checked immediately. Neither historical failed run is represented as fully green.

Subsequent Mac runs exposed fixture assumptions about screen size and page readiness. Cocoa can constrain a requested window after the initial native call returns, so resize checks now wait for stable agreement between the accepted native size and the renderer. Peek's entrance can finish before its document commits; the interaction check waits for that document before clicking. These corrections retain geometry, document identity, orphan prevention and unsaved-work assertions; they do not change the application runtime.

The later [`d409ee5` run](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40708506726) passed Windows and Apple silicon but failed two Intel cases: a compositor screenshot capture and a POST-popup interaction that could arrive after the real 168ms closing interval. The capture fixture lacked native visibility/paint preconditions; the original compositor state was not logged, so its precise cause is unconfirmed. Captures now require a visible, focused window and presented frames, with richer diagnostics. The popup race holds only the main animation clock during the closing-state interaction, then restores it in `finally`; native timers, Chromium, POST data, opener callbacks and document-identity checks remain live. Separate motion tests retain the real clock. This failed run is not presented as fully green.

In [`64cd45d` CI](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40711047275), those two Intel cases passed. Windows and Apple silicon completed successfully, but Intel's Settings test dereferenced a null button rectangle during an asynchronous header refresh. Its corrected measurement polls for a real, nonempty click target and retains the original coordinate click, palette dismissal and panel-state assertions.

The final unsigned Windows installer and executable built successfully. Packaged acceptance passed (one test), covering hardened fuses, browsing, PDF parsing and the isolated bundled Codex runtime: `test-results/0.9-release-build.log` and `test-results/0.9-release-package.log`. Packaged main, renderer, styles, theme, store and archive sources match the checkout (`test-results/0.9-release-package-source.log`).

Computer pointer review confirmed Library menu selection and opening Bookmarks. Native keyboard review hit the helper error `failed to activate captured window`; it is not counted as passed. One incorrect foreground capture was discarded. The final fresh-session gallery contains eight inspected whole-window captures of the exact runtime above, prepared with the instrumented local review harness. All eight PDF pages were rendered and visually reviewed; image hashes, page/image counts and extracted text passed. PDF SHA-256: `d10557460fa3267853423bbde09ab921e052cc6c53d3950476fdd059815ce548`. See [capture provenance](screenshots/README.md).

Two native Mac desktop captures from the `0810fd1` Apple silicon packaged-app run were also visually reviewed. The source ZIP matched GitHub's SHA-256 before extraction; all ten gallery images match their recorded hashes and dimensions. The Mac images show native traffic lights, aligned navigation, page gutters and dark selection, using the explicitly opened optional Home-page fixture. They do not establish physical trackpad behavior, desktop blur or live Google sign-in.

### Focused Space color and material checks

These focused checks supplement the full validation above. They do not count repeat executions as additional distinct tests.

| Check | Confirmed result | Evidence |
| --- | --- | --- |
| Theme interpolation, contrast and native material policy | Nine passed | `test-results/0.9-space-theme-unit.log` |
| Initial Space-swipe and native-material run | Nine passed, one failed | `test-results/space-theme-motion-validation.log` |
| Corrected menu fixture plus color/material regressions | Three passed | `test-results/space-theme-motion-targeted.log` |

The initial failure was a test timing race: after deleting two Spaces through host commands, the fixture opened the remaining Space's menu before the renderer received the updated list. Waiting for the single rendered Space icon corrected the fixture. The three-case rerun includes that case and repeats the color-transition and native-material cases; it is not three additional desktop tests or a claim that the initial run passed.

- **Presented appearance:** quarter- and half-width drags produce the expected perceptual color blend; reversal retraces it. Title updates preserve the in-progress theme. Cancellation and commitment settle monotonically with the tab rows, and reduced motion settles immediately. Saved colors, gradient balance, grain and opacity remain unchanged by gestures.
- **Native material continuity:** the tint follows swipe progress from 100 to 0 when the compositor supports transparency, and stays opaque under the tested fallback statuses. The native material lease survives activation until the transition finishes; stale completion cannot clear a newer lease, and leaving its Space pair releases it. Zero tint does not change whole-window opacity from 1 or replace the website's WebContents. Existing draft, rendering-scale and canceled-preview checks also pass.
- **Expanded controls:** opacity accepts 0–100 and grain accepts 0–200. Existing grain values through 100 retain their previous strength; the new maximum doubles it. Unit checks cover interpolation endpoints, reverse symmetry, invalid values and readable foreground/accent tones on opaque tint surfaces with the strongest single grain layer. Arbitrary desktop content visible through low-opacity chrome is outside that contrast guarantee.

These checks use controlled gestures and local documents in the actual Windows Electron runtime. They do not establish physical Mac trackpad feel, VoiceOver acceptance, macOS vibrancy quality or visual acceptance of desktop blur. Live Google sign-in remains blocked as described in [website sign-in](WEB-SIGN-IN.md); Google/AI account acceptance and signed distribution remain open. Prior screenshots and CI runs retain their recorded revisions and do not certify the 0.9 changes.

## 0.8 native glass, resizable chrome, Arc pins and command workflows

Final [CI run 40692880415](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40692880415) passed at runtime commit **`1a64f6d82ba1e43468a14d95b676fbdf87205796`**:

| Platform | Unit/security | Native desktop | Packaged app | Additional |
| --- | --- | --- | --- | --- |
| Windows x64 | 188 passed | 87 passed; 6 Mac-only skips | 1 passed | 40-cycle lifecycle check and validation upload passed |
| macOS, Apple silicon | 188 passed | 72 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP and both uploads passed |
| macOS, Intel | 188 passed | 72 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP and both uploads passed |

All three jobs and the overall run completed successfully, including formatting and syntax. All five validation/development artifacts were published. Decoded job logs are retained locally under `test-results/ci-40692880415/`. The Mac packages are ad hoc signed development builds; this result does not establish notarized distribution or physical-device acceptance. The subsequent documentation-only commit does not change this tested runtime.

Local automated verification on October 28, 2026 (JST) passed **188 unit/security tests** and established passing results for **87 distinct Windows desktop cases**, with **six Mac-only cases skipped**. The desktop total combines the initial full run with corrected regression runs; it is not a claim that the initial full run passed.

| Check | Confirmed local result | Evidence |
| --- | --- | --- |
| Unit/security | 188 passed, zero failures | `test-results/0.8-unit.log` |
| Initial full desktop run | 82 passed, four failed, six Mac-only skips | `test-results/0.8-e2e.log` |
| Corrected desktop regressions | 34 passed, including all four previously failing cases and all seven command workflow cases | `test-results/0.8-regression.log` |
| Library/material follow-up | Two passed | `test-results/0.8-library-material.log` |
| Formatting and syntax | Both passed | `test-results/0.8-format-check.log`, `test-results/0.8-syntax.log` |
| Windows development build | Unsigned `Zacro-0.8.0-x64-Setup.exe` and block map produced | `test-results/0.8-build.log` |
| Packaged application | One passed | `test-results/0.8-package.log` |
| Resource lifecycle soak | One passed, 40 cycles | `test-results/0.8-soak.log` |

The initial desktop failures covered a retained-favicon fixture expecting the navigated URL instead of the Favorite's saved destination, keyboard events whose target was not an element, dark Space-title contrast, and Windows forced-color selection. The fixture, event handling and style corrections passed in the subsequent 34-case regression run. The new AI-shortcut rebinding case increases the distinct Windows desktop total from 86 to 87; repeat executions of existing tests are not counted again. The two Library/material follow-up cases also repeat cases already included in that total.

- **Native materials and resizing:** Windows native glass preserves opaque live web pages and restores the saved Space material after a canceled preview. Sidebar and Library edge dragging retains document identity and native page resolution; chosen widths survive restart. Keyboard sizing, reset, cancellation and compact-window constraints pass. Library opens a destination chooser and preserves its opener, keyboard navigation and download actions.
- **Pins and Favorites:** durable Space pins, pinned folders and profile-wide Favorites have distinct ordering and drag targets. Tests cover saved URL/title behavior, reset and replacement, closing and reopening without deleting a pin, safe navigation with unsaved work, and retained favicon isolation. Trusted Shift-click cases cover ordinary main-document links and links with a new-window target while retaining the original document and tab count. Iframe modifier-click interception is not implemented; embedded-frame links retain native behavior. Existing automatic-sleep protections remain covered by the plain Electron lifecycle suite.
- **Command workflows:** all seven native cases pass, including tabless opening, reversible result-action and destination steps, folder search/reveal, profile isolation, custom keyword-Tab Site Search with encoded queries and restart persistence, Arc-style Space/tab navigation, editable shortcuts and Save Page. Regression assertions verify that an explicit Tabs scope prevents a site keyword from taking over Tab, command contexts expose accessible names and status, and rebinding AI disables its former palette key. The rebinding test opens AI with an empty query and sends no provider request. Shortcut geometry was also checked at the native minimum content size accepted on this host, 561×421.
- **Package and soak:** the built Windows executable passed security-fuse checks, real page navigation, packaged PDF worker parsing and the bundled Codex runtime's isolated signed-out handshake. The 40-cycle local soak retained two WebContents at every sample, with a 361 ms cycle median and 612 ms p95. Sampled process memory increased from 359,464 to 668,772 KiB. These bounded fixture observations do not establish general browsing performance or long-term memory behavior.

The final Space-form refinements at `33aa133` and `26bd670` reduce the preview and icon grid and use the available window height. Six personalization/compact-layout cases passed after each change, including short-window layouts. The Windows package was rebuilt after the changes.

Intel CI at `33aa133` exposed an AI Settings validation race. A background refresh preserved a typed localhost endpoint but restored an outdated required API-key constraint, preventing Save. A deterministic reproduction confirmed that the same endpoint changed from valid to invalid after a Space update. Runtime fix `1a64f6d` recomputes validation after restoring the draft. The existing workflow test now forces local, remote and local endpoint redraws, verifying that local keys remain optional and remote keys remain required. All three AI workflow cases and all three AI connection cases passed locally. The final unsigned Windows installer was rebuilt and packaged acceptance passed (`test-results/0.8-final-build.log`, `test-results/0.8-final-package.log`); formatting and syntax passed as well. Packaged renderer, styles and main-process sources match the checkout.

Computer initially failed to activate both translucent and opaque review windows. Native input recovered in a fresh packaged `33aa133` session. Pointer review verified Library menu selection and edge dragging from 224 to 278px for the sidebar and 336 to 442px for Library. Native keyboard Tab after entering `w` opened the Wikipedia search context without navigating or sending a query. The documentation gallery uses intact Computer captures of instrumented review states; [capture provenance](screenshots/README.md) distinguishes those from native-input checks. Desktop blur behind a translucent window has API coverage but is not claimed visually accepted by these opaque captures.

All ten documentation images passed hash and dimension checks against their manifest. The eight-page PDF was rendered and visually reviewed; every page contains one intact capture and extractable text. Its SHA-256 is `43a12242d595fbb32b9f502b09efc78c4edd14283137c24f4deadf212a44b005`.

Physical Mac trackpad/VoiceOver, live Google/AI account acceptance and signed distribution remain open. Historical 0.7 evidence below applies only to its recorded revisions. See [website sign-in](WEB-SIGN-IN.md) for the current direct Google account rejection and separate FedCM limitation.


## 0.7 compact windows, browser panels and keyboard onboarding

### Website sign-in follow-up

The subsequent website-sign-in fix promotes a Peek popup's opener into a tab before the popup is activated. It retains the original Chromium document and avoids a duplicate page request during promotion. Three new native regressions cover a blank popup redirected across origins, a named-target form POST, and callback/focus return to the secondary split pane. Chromium's implicit `noopener` for `_blank` form targets is preserved.

Local Windows verification passed **176 unit/security tests and all 22 browser/security desktop cases**, plus syntax and formatting. The rebuilt unsigned Windows installer and packaged-application acceptance also passed. The enhanced restart case verifies server-set HttpOnly persistent login cookies and local storage in two separate profiles, expiry of session-only cookies, and private storage remaining in memory. Computer review in an isolated development profile verified link-menu Peek, automatic promotion, popup creation, callback delivery and return to the original page. The local `/popup-check` fixture displayed its passed result; no provider account or credential was used. This does not establish Google/FedCM acceptance; see [website sign-in](WEB-SIGN-IN.md).

At runtime commit **`9bf9af76115afffe63d2c75b97868bf5eab6c506`**, [CI run 40680503131](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40680503131) passed all test and build steps:

| Platform | Unit/security | Native desktop | Packaged app | Additional |
| --- | --- | --- | --- | --- |
| Windows x64 | 176 passed | 77 passed; 6 Mac-only skips | 1 passed | Lifecycle check and upload passed |
| macOS, Apple silicon | 176 passed | 62 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP and uploads passed |
| macOS, Intel | 176 passed | 62 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP built; upload failed |

**The overall CI result is failed, not green.** Intel's validation archive transferred successfully but GitHub returned `Failed to FinalizeArtifact: Unable to make request: ETIMEDOUT`; its subsequent development-package upload was skipped. The validation artifact later appeared in GitHub's listing, but no Intel development package was published. No tests failed. A failed-job retry was attempted through the connected GitHub integration, which returned HTTP 403 because it lacks Actions write permission. A maintainer with that permission must retry the failed job to complete Intel artifact publication. The earlier green interface runs below remain historical evidence.

### Original interface acceptance

On October 28, 2026 (JST), final [CI run 40581387047](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40581387047) passed at runtime commit **`7f8aba038f805a948e06ed6d90fcc846ae977196`**:

| Platform | Unit/security | Native desktop | Packaged app | Additional |
| --- | --- | --- | --- | --- |
| Windows x64 | 176 passed | 74 passed; 6 Mac-only skips | 1 passed | 40-cycle lifecycle check passed |
| macOS 15, Apple silicon | 176 passed | 59 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP built |
| macOS 15, Intel | 176 passed | 59 passed; 1 Windows-only skip | 1 passed | Development DMG/ZIP built |

All three jobs completed successfully, including validation artifact uploads. The earlier [CI run 40579207712](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40579207712) at `77669476468d53bb66f98d37faddae7c10bb99d8` passed the same suites and supplied the Mac documentation captures. The final runtime also includes clearer shortcut-recorder feedback and the compact manual-review launcher.

- **Compact layout:** minimum 560×420 geometry, all six browser panel sections, adaptive sidebar hiding, retained width preference, scrollable short dialogs, theme controls and command results. Native page bounds match the shell at fractional Windows scaling.
- **Live Library and motion:** opening Library performs zero `capturePage` calls and retains the real page, document identity and device-pixel ratio. Sidebar and panel width changes share a monotonic 220 ms ease, with reversal and reduced-motion handling. Interrupting chrome motion with a dialog captures the settled native bounds. Opening a panel or focusing the sidebar cancels a pending Space swipe.
- **Keyboard:** first-run/replay tour, editable bindings on every slide, conflict rejection, persistence after restart, focus restoration, roving sidebar arrows, folder expansion/collapse, keyboard context menus and Windows F10. Native Mac menu and shortcut checks pass on both architectures.
- **Spaces:** neighboring favorites, folders and tabs appear during dragging; previews are inert and have no duplicate IDs or actions. Cancellation, reversal, endpoints, release settling, native page retention, profile boundaries and right-click/keyboard menu targeting pass.
- **Website login mechanics:** cross-origin popup callback and opener restoration pass in a local Chromium fixture. A separate plain Electron fixture proves favorite protection without debugger capture, background callbacks without focus theft, and sleep eligibility after popup closure. These are not live Google acceptance results; see [website sign-in](WEB-SIGN-IN.md).
- **Local package and soak:** the unsigned 0.7 Windows installer built, package acceptance passed, and the 40-cycle soak kept two WebContents at every sample. Observed cycle median was 345 ms and p95 364 ms; sampled memory grew from 499,268 to 722,496 KiB. These bounded fixture measurements are not general latency or long-term memory guarantees.

The revised icon contains nine Windows sizes from 16 to 256 pixels, plus the existing seven macOS sizes. Mac validation archives were SHA-256 verified before extraction; packaged light/dark captures were visually inspected. Mac artifacts are ad hoc signed development builds; notarization was explicitly skipped. Physical Mac trackpad review, assistive-technology acceptance, live identity-provider/AI accounts, signed distribution and the other commercial release gates remain separate.

**Computer review:** the packaged Windows application was exercised with disposable profiles at normal and minimum size. Checks covered onboarding F8 recording/reset, direct Library/Settings navigation, panel scrolling and close/restoration, right-click Space targeting, horizontal Space switching, F10 menu navigation and compact command results. This host's injected Control combinations arrived as Windows/Meta combinations, so those manual modifier results are not counted as successful Control/Command verification; native event tests cover the intended bindings. That review prompted clearer recorder notices for Windows-key/AltGr input and removal of Electron's IPC envelope from displayed errors. The updated onboarding native test and rebuilt Windows package passed locally at `7f8aba0`.

Six original Windows screenshots and two native Mac captures were visually reviewed. The six-page PDF was rendered with Poppler; every page was inspected for clipping and overlap, with page count, embedded images and extracted text checked. [Capture provenance](screenshots/README.md) distinguishes the normal-size `7766947` captures from the minimum-size `7f8aba0` captures. The PDF SHA-256 is `9B71D3B0A21BBEE583E74471712782AD9D40AD9EB6B8C5BC577ECE53044E0A55`.

## 0.6 Space materials, motion, favorites and AI workflows

Version 0.6 adds Space icons and live material previews; adjustable colors, gradient, grain, opacity and blur; matching page gutters and configurable corners; page-only palette blur; release-based Space gestures; reversible sidebar motion; retained closed favorites and protected idle sleeping; filtered command results; and AI questions with explicit, reviewed document context. Evidence below is recorded on October 26, 2026 (JST), with runtime verification and capture revisions identified separately.

- **Source and unit checks:** formatting, syntax and **173 unit/security tests** pass locally. New coverage includes theme contrast across saturated colors and material combinations, Space gesture release/reversal, layout gutters, retained pins, document-scoped AI history and seven deterministic pin lifecycle races. Pending sleep rechecks document/activity identity and the current timeout, so changing to Never or revisiting/navigating a page cancels stale eligibility. Explicit Close takes precedence over an in-flight sleep.
- **Native lifecycle design:** idle-pin acceptance uses an ordinary Electron process without a debugging connection. A DevTools protocol attachment makes Chromium report a page as being captured; testing only through Playwright would incorrectly exercise the capture protection instead of actual sleep. The plain fixture verifies unloading, wake, beforeunload decisions and exclusions for active/split pages, media, downloads and edited forms, including shadow inputs.
- **Additional review fixes:** keyboard traversal reaches theme disclosures; valid imported layout values display correctly; expanded theme forms preserve their footer at short heights; an outside click over an open panel dismisses the palette; Space/profile switches discard unfinished theme previews; and Windows forced-color tokens take precedence over custom colors.
- **Favorite icons:** the plain native lifecycle suite passes all five cases, including real PNG retrieval, retention after Close/sleep, exact tab/profile/URL isolation and removal when browsing data is cleared. Retention is memory-only, capped at 128 tabs / a 4 MiB string budget; it adds no retrieval or persistence path.
- **AI acceptance scope:** document-context, draft, cancellation, retry and provider tests use controlled responses or real loopback HTTP with fake keys. Windows credential restart acceptance uses actual OS encryption. No live subscription sign-in, paid inference, account entitlement or provider billing/limit acceptance is claimed.

The final runtime passed [CI run 40222980054](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40222980054) at commit **`9bfcd1c104c5d9a7f9725fce93e32ac5fcd3ce17`**:

| Platform | Confirmed checks | Job status |
| --- | --- | --- |
| Windows x64 | 173 unit/security, 67 desktop, one 40-cycle soak, one packaged-application test; six Mac-only skips | Passed |
| macOS 15.7.9 Apple silicon | 173 unit/security, 52 desktop, one packaged-application test; one Windows-only skip; development DMG/ZIP generation | Passed |
| macOS 15.7.9 Intel | 173 unit/security, 52 desktop, one packaged-application test; one Windows-only skip; development DMG/ZIP generation | Passed |

All three jobs completed successfully with zero failures, including formatting and syntax. Both Mac runners report macOS 15.7.9 build 24G830. Package acceptance covers the hardened executable, real navigation, PDF extraction and the isolated signed-out Codex runtime. Development packages do not establish signed release or clean-machine installer acceptance.

The final composer patch, **`9bfcd1c104c5d9a7f9725fce93e32ac5fcd3ce17`**, makes the question field grow with its contents between 53px and 160px. Its targeted local workflow assertions pass for a visible prepared question, shrinking short text and bounded long text. The final Windows `npm run dist` produced the unsigned development installer, and the rebuilt package passed **one packaged-application acceptance test**. Installer generation does not establish installation/uninstallation or signed distribution acceptance.

Native Computer review produced five unretouched, visually reviewed Windows captures. Workspace, scoped commands, Space materials and layout preferences show the packaged `1f130cb` baseline; the AI workflow capture shows the final `9bfcd1c` package with its prepared question fully visible and selected page context. It remains disconnected and shows no provider answer. The [five-page 0.6 feature guide](Zacro-0.6-Design-and-Feature-Guide.pdf) uses one intact capture per page. All five pages were rendered with Poppler and visually inspected; page count, image presence and embedded text were checked.

The final Windows CI run's fresh **40-cycle** soak retained **two WebContents at every sample**, with **366ms median and 420ms p95** per lifecycle cycle. These are bounded fixture observations, not general browsing-speed or long-running memory guarantees.

Final `9bfcd1c` Apple silicon light/dark screenshots were retrieved from the same run's artifact `12610675900` and visually reviewed. The unedited desktop images include the native traffic lights, application menu and Dock icon, with the optional New Tab Page explicitly opened for acceptance. They are tracked under `docs/screenshots/0.6/`; physical-Mac and assistive-technology acceptance remain separate.

The [capture record](screenshots/README.md) identifies image revisions and dates. The 0.5/0.4 evidence below is historical. Physical Mac trackpad feel, live provider-account acceptance, assistive technology and signed commercial distribution remain separate acceptance gates.

## 0.5 commands, gestures and AI connections

Evidence recorded October 25, 2026 covers the tabless command workflow, editable Arc-style shortcuts, recent-tab navigation, proportional Space gestures and six explicit AI connections. Local Windows checks and final cross-platform CI are complete; physical-device, live-account and release acceptance remain separate gates.

- **Source and unit checks:** formatting and JavaScript syntax checks pass, along with **154 unit/security tests**. Coverage includes visible sidebar ordering, shortcut conflicts and aliases, exact modifiers, gesture intent and momentum, provider isolation, credential storage, cancellation and response bounds. Credential regressions verify that status never probes the OS store, asynchronous decryption handles Electron's result object, rotation preserves bindings, and timeouts or late responses cannot restore replaced/deleted keys.
- **Desktop integration:** **54 Windows desktop checks pass** across the full 51-check run, three additional AI cases and targeted regression reruns. Six Darwin-only checks skip on Windows. Tests exercise actual Chromium pages, command creation/current-address intent, empty Spaces, persistent shortcut edits, recent-tab switching, drag pinning, native page geometry and preserved page state. Gesture checks cover finger-proportional feedback, reversal, endpoint resistance, momentum suppression and the usable sidebar beside the command palette. The page-scroll check observes trusted native pointer/wheel delivery before asserting real scrolling.
- **AI transport evidence:** the added API workflows use a real loopback HTTP fixture with a fake key. A Windows test uses actual Electron asynchronous encryption, inspects ciphertext, restarts the complete application and verifies that the restored key reaches the metadata endpoint without entering exports or public state. These checks verify the application-to-provider path and settings behavior without a live provider account, paid inference or completed subscription sign-in. Controlled runtime transports cover the Claude connection; the bundled Codex runtime is checked while signed out. These checks do not establish live model, search, billing or account acceptance; see [AI verification limits](AI.md#validation-and-remaining-acceptance).
- **Lifecycle soak:** **40 tab/Peek/split cycles pass**, retaining the original page's draft and reading position and releasing closed native pages. The local observation in `test-results/soak.json` reports **359ms median and 376ms p95 per cycle**. These are deterministic fixture lifecycle timings, not general browsing-speed or long-running memory guarantees.
- **Packaged Windows application:** the 0.5 folder build passes acceptance for Electron security fuses, real navigation, local PDF extraction and the isolated signed-out Codex handshake. `npm run dist` also produced the unsigned `Zacro-0.5.0-x64-Setup.exe`. This verifies the packaged executable and installer generation; it does not certify installer deployment or a signed release.
- **Packaged Computer review and documentation:** the Windows package was reviewed using the Computer plugin for populated and empty Spaces, horizontal switching in both directions beside the palette, command action search, the shortcut editor, and subscription/API settings. Review exposed a clipped shortcut footer; the corrected editor was recaptured and checked at normal and minimum window sizes by native tests. Five unretouched JPEGs and a five-page 0.5 PDF are refreshed; every PDF page was rendered with Poppler and visually inspected. The Computer helper's modifier/paste input remains unreliable on this host; native integration tests cover shortcuts and real mouse drag pin/reorder/unpin operations. No real authentication or paid inference was performed.
- **Cross-platform CI:** [run 40190619770](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40190619770) passed at commit `4913177dfe5998608bdc2f1ab1d5f02115986167`. Windows passed **154 unit/security tests, 54 desktop tests, one 40-cycle lifecycle soak and one packaged-application test**. Each macOS 15.7.9 job, Apple silicon and Intel, passed **154 unit/security tests, 39 desktop tests and one packaged-application test**, plus formatting, syntax and development DMG/ZIP generation. Six Mac-only checks skip on Windows; the Windows DPAPI restart check skips on Mac. Two unedited native 0.5 Mac desktop captures were downloaded from this run and visually reviewed.
- **Still pending:** physical-Mac trackpad and device review, assistive-technology, real-account and signed/notarized release acceptance. The completed 0.4 checks and captures below are historical evidence.

The cross-platform checks exposed synchronous credential-store access during startup and an outdated asynchronous decryption result contract. The corrected vault never initializes OS storage during status reads, uses bounded asynchronous operations for explicit credential actions, and preserves encrypted files on failures. The final native packages start and pass acceptance on both Mac architectures. Package checks now report bounded stages and stop only their owned processes on failure, so a blocked OS prompt cannot hide the failing stage indefinitely.

## 0.4 interface revision

That revision moved navigation and the address field into the sidebar and followed the hierarchy recorded in the [0.4 design study](DESIGN-REVIEW-0.4.md): favorites, Space identity, folders/tabs, and a compact Library/Space/creation footer. It replaced permanent action strips with menus while retaining keyboard access and visible focus. The default sidebar is 224px wide; saved custom widths are preserved. Tab rows and the footer are 32px high.

The layout contract places the native page at an 8px top inset on macOS with the sidebar visible, or 36px on Windows to preserve window controls. Full screen uses the 8px inset. Page content begins at 40px when the sidebar is hidden or Find is open, keeping those controls outside the website. Tests compare exact native Chromium bounds with the shell in normal, hidden-sidebar, Find, panel, split-view and Peek states, including a saved 380px sidebar at the minimum window size.

- **Local verification:** 99 unit/security tests and all 46 Windows desktop checks pass across the full and targeted regression runs, plus formatting and syntax. Six Darwin-only tests skip on Windows. New regressions cover exact native geometry, live menu state and retained keyboard focus, anchored menu placement, backdrop capture and private-page capture exclusion. Sampled text contrast remains at least 4.5:1 across both gradient endpoints.
- **Packaged application:** the 0.4 Windows folder build passes packaged acceptance, including security fuses, real navigation, PDF parsing and the isolated signed-out Codex runtime. The lifecycle soak passes 40 tab/Peek/split cycles with the original page's draft and position retained. This is a short local lifecycle check, not a long-running performance guarantee.
- **Native Computer review:** the packaged Windows build was exercised with populated and empty Spaces, light/dark appearance, pinned favorites, command search and dismissal, Library, Settings, the unconnected AI panel, sidebar hide/show, native link-menu Peek, split view and horizontal Space switching in both directions. Minimum-window layout is covered by native integration tests. The Computer tool's modifier chords reported Meta rather than Control on this host; Control shortcuts are covered by native integration tests, not claimed as manually verified here.
- **Documentation captures:** all nine Windows JPEGs are refreshed from the packaged 0.4 application without retouching. The nine-page feature PDF was rendered with Poppler and every page visually inspected. Both Mac PNGs are refreshed from the packaged Apple silicon application in native CI and visually reviewed, including traffic lights, menu bar and Dock.
- **Cross-platform CI:** [run 40099796398](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40099796398) passed at commit `f3101841f04cda2e9441734c0b711f6e63c697e2`. Windows passed **99 unit/security tests, 46 desktop tests, one lifecycle soak and one packaged-application test**. Each macOS 15.7.9 job, Apple silicon and Intel, passed **99 unit/security tests, 32 desktop tests and one packaged-application test**, plus formatting, syntax and development DMG/ZIP generation. Six Mac-only tests skip on Windows. Physical Mac review and signed/notarized public release acceptance remain open.

The ordinary-window paint check initially encountered an idle Windows desktop/compositor condition: the shell was visible while the page reported hidden. Real Computer keyboard input restored page rendering, and the unchanged nine-record paint check then passed repeatedly, including CI. Failure-only desktop idle and native-view diagnostics now distinguish this condition from layout failures; no production throttling or security setting was disabled. Mac CI also prompted fixture readiness fixes for asynchronous menu/Peek replacement and cold HTTP transport startup, retaining the exact geometry and network rejection assertions.

## Previous validated builds

The initial 0.3 validation passed **90 unit/security tests, 38 desktop integration tests, one packaged-application test and one lifecycle soak test: 130 tests total**, plus formatting and syntax checks, on October 24, 2026. The desktop total includes the plain-window native-paint regression. That soak completed 40 cycles.

The subsequent sidebar Space-scroll change passed `npm run verify`: **90 unit/security tests and 41 desktop integration tests**, plus formatting and syntax. Three new regressions cover native horizontal wheel input, directional/reduced motion, page identity and draft retention, per-Space tab-list scroll, intent thresholds, momentum, direction changes, wheel delta modes, Shift-wheel, profile boundaries, and interrupted gestures. A native Computer pass on the development application confirmed forward/back switching, the final-Space edge stop, and unchanged Space selection when scrolling over a webpage. The packaged and soak results below refer to the initial 0.3 build.

The macOS integration passed [cross-platform CI run 40094147848](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40094147848) at commit `99eba6d9289d0c2a56038336c2215f419cdb62f1`. Windows passed **98 unit/security tests, 43 desktop tests, one packaged-application test and one lifecycle soak test**, plus formatting and syntax. Each native macOS **15.7.9 (24G830)** job, Apple silicon and Intel, passed **98 unit/security tests, 29 desktop tests and one packaged-application test**, plus formatting, syntax and development DMG/ZIP generation. The architecture-specific development artifacts are retained for seven days; they are not public release artifacts.

Six Darwin-only integration tests explicitly skip on Windows; the simulated Mac renderer check is separate from the native Mac results above. These CI results do not establish physical-device acceptance across the macOS 13+ target range. No signed/notarized Mac release or physical Mac review has been completed. See [macOS validation and release steps](MACOS.md).

The 0.3 checks cover compact tab density, native page bounds with the sidebar hidden, page-field focus and draft preservation, Library navigation and return focus, home-shortcut deduplication, Settings disclosure state, short motion and immediate dismissal, and the subscription connection UI/protocol. Account-change, cancellation and filename-stream regressions protect the AI lifecycle.

The previous 0.2.0 baseline passed 74 unit/security tests, 30 desktop integration tests, one packaged-application test and a 120-cycle lifecycle soak. That earlier run is historical context, not a substitute for 0.3 verification.

## Automated checks

`npm run verify` runs formatting, syntax, unit/security tests and real Electron integration tests. Unit tests exercise navigation validation, graph integrity across randomized tab/Space operations, atomic session recovery, private-data exclusion, import privilege boundaries, filenames and rename races, Codex app-server protocol restrictions, credential isolation, cancellation, citation parsing and actual PDF parsing.

Desktop tests use separate temporary profiles and local HTTP fixture servers. They exercise actual Chromium navigation, back/forward, zoom, the command bar, themes, cookie and localStorage isolation, private-session restart, Peek preserving scroll/JavaScript state, promotion, native split views, downloads and rename/undo, and organization through UI controls. Security integration tests cover popup POST/session/sandbox behavior, privileged IPC sender rejection, unpacked-extension profile isolation and enable/disable/remove, unsaved-form decisions, hostile-page text extraction, PDF page citations, and HTTP authentication. They mock provider inference and native permission decisions, not Chromium page rendering or cookie storage.

Unsaved Peek regression tests cover cancellation and completion when creating a tab, changing Space, and replacing a preview. Navigation tests verify that choosing Stay preserves both the live document and its saved address when navigating to another page or returning to New Tab.

The 0.2 regressions additionally cover persistent user tab names, exact window restoration, IME composition, dialog focus isolation/return, F6, native Find focus, stable split-pane positions, panel search selection, native-view attachment, and real raster favicon decoding. Modal capture tests deliberately defer native capture until after the page is hidden, verify the real JPEG backdrop and immediate command focus, and exercise timeout, dismissal, destruction and private-profile cases. Permission tests hold a real Notification request open while the active tab or profile changes, then verify that a delayed Allow-and-remember response is rejected. Empty Current page AI requests cannot silently become hosted research.

Sampled light/dark text contrast meets the tested 4.5:1 threshold. Windows forced-colors and reduced-motion behavior are checked through Chromium media emulation in the real Electron shell, including a preference change while transitions are active. This is not an actual Windows contrast-theme or screen-reader certification.

The native-paint regression launches a plain visible foreground window and checks page animation frames before capture. Nine checks cover shell rendering, initial navigation, new/restored tabs, Peek creation/dismissal, overlay dismissal and resizing. Its visible, unoccluded window is a test precondition; the check verifies frame progress and rendered page pixels across native-view transitions.

`npm run test:package`, after `npm run pack` or `npm run dist` on Windows, or `npm run pack:mac` or `npm run dist:mac` on macOS, verifies the built application's security fuses, launches its native executable, navigates a real page, inspects its light/dark home screens, and closes it. It also loads the exact packaged PDF module and dependencies from `app.asar` in the same Electron runtime to verify the PDF worker and font resources. The 0.3 packaged check additionally starts the bundled Codex runtime with an isolated, signed-out profile and verifies its account handshake. This does not test sign-in or inference. Main-process inspection remains disabled in the distributed binary.

The initial 0.3 `npm run test:soak` run completed 40 repeated real tab/Peek/split lifecycles. Only the shell and retained original page remained after each cycle; the original draft and reading position survived, with no renderer errors. Observed process-memory totals rose from 468,888 KiB to 696,228 KiB (about 458 to 680 MiB). The complete test-cycle duration had a 334ms median and a 365ms 95th percentile; these are lifecycle-test timings, not general browser interaction latency. Packaging did not run concurrently. These short local observations establish lifecycle behavior, not a leak-free or long-running performance claim. Detailed samples are generated in `test-results/soak.json`.

`npm audit` reported zero known vulnerabilities across production and development dependencies at validation time; this is not proof that vulnerabilities do not exist.

The real bundled Codex runtime passed an isolated signed-out account handshake and an authentication-start/cancel smoke check. The latter validated the official authorization URL without opening a browser, using credentials, completing sign-in or submitting a model request. Protocol tests use controlled transport responses. Live subscription entitlement and inference remain unverified until the user completes authentication.

## Historical native Computer acceptance

The packaged Apple silicon app was initially captured through macOS's native screen capture in disposable GitHub CI on commit `62c34cdc103b8f58d047c01ce987d60bbfdd6a85`. The actual website pixels, light/dark appearance, native traffic lights, Zacro menu-bar name and Dock icon were visually reviewed. Subsequent 0.4 captures at `f3101841f04cda2e9441734c0b711f6e63c697e2` and 0.5 captures at `4913177dfe5998608bdc2f1ab1d5f02115986167` were separately reviewed and retain their historical provenance. The 0.6 review status is recorded at the top of this document. These captures supplement automated tests; they are not a physical-device or assistive-technology review.

The final 0.3 packaged application was exercised through actual Computer input and native window capture in a disposable showcase profile. The pass covered sidebar hide/show, light/dark appearance through the native combobox, New tab, a link's context-menu Peek and Escape dismissal, split selection and closing, command-palette search and dismissal, Library bookmarks, and Ask Zacro's Connect Codex route to Settings. Settings displayed ChatGPT sign-in with no API-key fields. All nine README screenshots were refreshed for that build and visually reviewed; the Computer pointer highlight remains visible in the original captures. No browser-protocol input driver was used for that manual pass.

The 0.3 nine-page PDF guide used the same screenshots. Every page was rendered with Poppler and visually inspected, with document text, image presence and page count also checked. Screenshots demonstrate still interface states; motion was exercised through the application and integration checks. The 0.4 guide was independently regenerated and reviewed as recorded above.

The 0.2 baseline Computer review exercised the real Windows application in disposable profiles using a loopback journal fixture. Its source-build pass covered page browsing and scrolling, a draft retained through tab/Space changes, link-context-menu Peek, a second draft retained through promotion, split-pane focus and a live counter, favorites, Space creation and color changes, history filtering, light/dark settings, F6, command-palette dismissal, and maximize/restore. Light/dark, command bar, settings and narrow-window screenshots were also inspected.

That baseline's packaged executable was launched separately with `npm run test:interactive -- --packaged`. Computer verified real page rendering, the command palette's visual backdrop, dismissal, and the home screen. Windows' accessibility tree exposed the current page again after dismissal and excluded it while the dialog or New Tab was active. This confirms the tested native-view isolation, not full assistive-technology acceptance. Both interactive runs exited normally and their disposable profiles were removed.

The baseline pass used UIA clicks/edits and F6/Escape. Control-key delivery was inconsistent on this host, so Control shortcuts were verified separately through Electron's actual keyboard-input integration tests. Neither manual pass used AI credentials, authenticated inference, real messages or purchases. The final pass did not complete ChatGPT sign-in.

## Distribution

`dist/win-unpacked/Zacro.exe` is the directly runnable Windows build. The CI workflow runs `npm run pack` and packaged acceptance on that application folder; it does **not** generate or upload a Windows NSIS installer. `npm run dist` is the separate local command that creates `Zacro-<version>-x64-Setup.exe`. The Mac CI jobs run `npm run dist:mac` and upload architecture-specific development DMG/ZIP files. These are **development artifacts**: Windows release signing and Mac Developer ID signing/notarization have not been completed. Windows Authenticode inspection of the earlier 0.3 executable and installer returned `NotSigned`; packaged-application acceptance is recorded above. Installation/uninstallation on a clean disposable Windows machine has not been certified. Generated binaries are ignored by Git; the curated README screenshots are tracked under `docs/screenshots/`.

## Required further acceptance

- Live ChatGPT sign-in and Codex subscription acceptance, including account/model access, hosted-search evidence, cancellation and limits. This requires the user to complete authentication; automated tests make no live inference calls and do not use personal credentials.
- Independent security review and prompt-injection/evidence-quality evaluation.
- Real-world long-running browsing, media/DRM, OAuth, accessibility/assistive technology and performance testing.
- Broader extension compatibility, full account/extension sync and service operation.
- Signed installer acceptance, automatic-update infrastructure, signature/rollback testing and release incident processes.
- Physical-device macOS acceptance and signed/notarized installation checks on Apple silicon and Intel. Native macOS 15 CI has passed on both architectures; Linux validation remains open. Only Windows was exercised locally in this development session.

Local file navigation, native Arc database migration, a password manager, full Chrome extension APIs and Web Store installation, device pairing choosers, and default-browser registration on Windows/Linux are not implemented. Packaged macOS builds offer an explicit default-browser action in Settings. In 0.9, clean background pages may archive after the profile interval. Active/split/Peek-source pages, media, downloads, authentication relationships, detected edits and beforeunload vetoes prevent automatic unloading; arbitrary website memory cannot be inferred perfectly. See the [roadmap](ROADMAP.md) for remaining commercial release requirements and [AI documentation](AI.md) for supported context and provider boundaries.
