# Native rewrite verification

This is a working acceptance record, not a release certification. The Electron implementation remains the behavior reference. Native implementation and successful compilation do not establish runtime parity.

## 2026-11-01: integrated build 6

The release-configuration Swift product compiled successfully. Visual checks used the packaged app with a fresh, empty, disposable `--engine-acceptance --native-ui-review` profile and an HTTP fixture bound to `127.0.0.1`. Normal browser profiles, credentials, and Keychain entries were not used. UI actions were performed through Computer Use.

Observed successes:

- Peek displayed its real Chromium page above the source page. A fixed green banner on the source remained visibly rendered beneath the tint outside the Peek card.
- Escape closed Peek and returned to the source with the typed draft unchanged. The previous integrated build also preserved a typed Peek draft when expanding it into a tab.
- A target-blank link opened an adopted tab. Returning to the original tab preserved its draft and page content.
- Importing a collection created a separate imported profile with three Spaces, Favorites, a folder, pinned tabs, and ordinary tabs.
- Split view displayed two live pages and a combined sidebar tab. Its group survived switching to an unrelated tab and selecting a split member again.
- An invalid hexadecimal color disabled the theme editor's Save button; Cancel returned to the saved theme.
- Site controls, native menus, the import panel, and Space selection remained responsive.

Observed failures and limits:

- After hiding and reselecting a retained page, its native accessibility tree could become empty although the page still rendered. Initial pages and the source immediately after Peek dismissal exposed their full tree. Layout notifications alone did not fix it.
- The command palette could remain hidden or lose keyboard focus after native window transitions. Raising the parent exposed a still-existing nested Split selector. AppKit panel visibility, stale dismissal notifications, and parent focus restoration are being corrected.
- Pointer dragging through Computer Use returned `windowNotFoundAtPosition` for the sidebar and narrow split divider. Pointer-based reorder, cross-Space hold, and divider motion are therefore not verified by this session. The gesture state-machine tests do not substitute for physical trackpad acceptance.
- Quit after the multi-profile/Split session exited with code 2 and Chromium's teardown watchdog message. Earlier shorter sessions exited normally. This is a release blocker; a passing pre-quit report cannot hide it.
- These runs used the stock CEF framework. Native protocol additions for encrypted history, safe discard, extension storage/action observation, and logical extension tab/window routing still require the custom Chromium framework and acceptance against that exact packaged binary.

## 2026-11-01: integrated build 7

The release-configuration product compiled successfully. The packaged engine acceptance passed all 14 reported checks: native readiness, native SVG favicon decoding, profile resource fetch and byte bounds, isolated JavaScript worlds, DevTools results/rejection, live document adoption and form retention, popup callback/opener retention, native close preparation cancellation/retry, and extension registry enumeration. Four documents retained distinct/shared/private profile behavior and the harness exited cleanly. Its report explicitly records `extensionCompatibilityVerified: false`; the stock framework does not implement the custom native protocol.

The isolated Core and Services regression run passed 134 tests with no failures or skips, including a real bundled Codex protocol handshake and the packaged PDF helper. A subsequent focused query run passed all nine cases, adding strict `splitViewId` filtering to the overall 135-test catalog. No paid inference or production credentials were used.

Computer Use acceptance in fresh profiles verified:

- Command-T and the New Tab button reopened the command palette with keyboard focus. A nested Split selector accepted Return and created the group.
- Native Back/Forward returned to the correct local fixture and preserved its form draft.
- A split group survived selecting an unrelated tab and returning. Accessibility adjustment visibly changed both live page widths to a 60/40 split.
- The source document remained visibly rendered beneath Peek's tint, including content outside the card. Clicking outside the card closed Peek.
- Invalid theme hexadecimal input disabled Save. Normal and maximum-intensity screenshots showed both the editor and window color responding; Cancel restored the saved theme. These screenshots do not establish desktop-transparency parity.
- `--force-renderer-accessibility` retained the native document accessibility tree after hide/show. The next build moves this into engine startup; the custom Chromium scoped accessibility lease still requires its own runtime check.

Shutdown is **still a release blocker**. A multi-profile/Split/Peek run without an actual target-blank popup exited 0. Repeating the actual target-blank popup, importing and switching to a second profile, then creating Split reproduced exit 2 and Chromium's teardown watchdog. A native sample captured the main thread inside `cef_shutdown`, including process wait/sleep frames. Initial cold-profile page presentation also briefly produced a blank native window; a later parent observation showed the loaded document. The next build adds timing traces to separate loading from presentation.

Evidence retained locally: `/tmp/zacro-native-integrated-release-7.log`, `/tmp/zacro-native-acceptance-7/engine.json`, `/tmp/zacro-core-services-134-tests.log`, `/tmp/zacro-extension-split-query-tests.log`, `/tmp/zacro-native-release7-popup-quit-sample.txt`, and the screenshots/logs in `/tmp/zacro-native-review-assets`.

## 2026-11-01: integrated build 8 and subsequent checks

Build 8 compiled in release configuration. Computer Use verified the native sidebar separator at 224px → 240px with Increment, 241px with Option-Right, 209px with Shift-Left, and 224px after double-click reset. The split separator moved from 50% to 52% with Right, then 62% with Shift-Right. Home respected the actual 160px minimum (13% in that window); double-click restored 50/50. The live page's typed draft remained visible throughout.

Pointer input remains unaccepted: a divider drag timed out in Computer Use, and horizontal scrolling over the tab list returned `windowNotFoundAtPosition` before dispatch. These tool failures do not establish a browser gesture defect or prove trackpad correctness.

Cold-profile tracing identified the blank-page delay precisely: native browser creation finished at 21:20:18.568, but its first real load did not start until 21:20:34.728. The unknown custom capability method on a never-navigated stock-CEF document waited for a renderer and timed out. The next source batch probes the already-initialized engine broker once, without navigating the fresh tab before history restoration.

After the Mac restarted, temporary app bundles and `/tmp` logs were lost. The observations above were recorded before restart; they are not reconstructed test output. No build-8 shutdown result was obtained. New verification artifacts are retained in the ignored `macos/.build/verification` directory.

The subsequent full Core/Services run passed 141 cases before restart, and the repeatable real-server sync check passed all 11 cases. The standalone favicon probe was rerun after restart and passed saved-icon retention beyond the memory cache, offline restart, private isolation, destination pruning, owner-only file permissions, late-response cancellation after clear, bounded raster size, and logo-color extraction. Its repeatable source is `macos/scripts/check-favicons.swift`; the real-server probe is `macos/scripts/check-sync-integration.py`.

## 2026-11-01: integrated build 9

The integrated release build passed after correcting two Swift type/access errors. The replacement executable was packaged in an isolated, ad-hoc-signed test app and passed deep, strict signature verification. All three fresh-profile acceptance runs passed 17 checks and exited 0, including a live target-blank popup retained through termination. New checks bound the fresh-document capability probe to three seconds and first navigation to five seconds. The original full SwiftUI popup/import/profile-switch/Split shutdown sequence has not been rerun, so the historical watchdog failure is not considered resolved by this narrower harness.

The historical shutdown sample was symbolized using the exact framework symbols: Chromium was waiting for its network process to exit in `BrowserProcessIOThread::ProcessHostCleanUp`. Native C-client handler ownership was corrected and its lifetime tests passed. That repair is included in build 9, but the evidence does not establish that it was the sole cause of the original watchdog failure.

The custom Chromium adapter compiled as an actual GN object against the pinned generated headers. This is a compilation result, not a linked framework or extension runtime acceptance. The packaged stock-framework tests still explicitly report `extensionCompatibilityVerified: false`.

Evidence: `macos/.build/verification/integrated-release-9-retry.log`, `acceptance-9/engine.json`, `acceptance-9-repeat2/engine.json`, `acceptance-9-repeat3/engine.json`, `cef-lifetime.log`, `release7-shutdown-symbolized.txt`, and `native-objects/object-check.json` beneath the same verification directory.

## 2026-11-01: integrated build 10

The release-configuration build passed (62.46 seconds on the successful retry). Its isolated packaged app passed strict signature verification and the engine harness exited 0. The harness now probes capabilities at cold engine startup, before public-page navigation, as well as checking the fresh-document load path. The native logical-tab catalog and single-use materialization ticket APIs compile together with the Swift coordinator. These APIs still require custom-framework runtime acceptance; stock-framework success does not exercise dormant tab reservation.

The coordinator coalesces dormant restores, awaits completion before extension document actions, and applies the latest committed URL when multiple navigation requests arrive during restoration. Its close barrier waits for in-flight discard/restore operations before capturing session history. Evidence: `macos/.build/verification/integrated-release-10-retry.log` and `macos/.build/verification/acceptance-10/engine.json`.

## 2026-11-02: integrated build 11

The multiwindow application compiled in release configuration (66.87 seconds on the successful retry). Its signed internal test bundle passed engine acceptance and exited 0. New runtime checks verified that moving a document between two native shell contexts retains its native browser ID and form value; a close veto affects only its own window; closing a window preserves other windows' documents and the hidden extension manager; and reopening the same model window assigns a fresh Chrome-facing window ID. These checks exercise the engine. The full application coordinator integration harness is being added separately.

All 89 Core tests passed, including ten repository/window migration, ownership, selection, and rollback cases. A subsequent targeted regression verified that completed downloads remain completed after restart, bringing the Core catalog to 90 tests. Services and per-window UI presentation work after this build is not covered by these results.

Evidence: `macos/.build/verification/integrated-release-11-retry.log`, `acceptance-11/engine.json`, `core-window-tests-fourth.log`, and `core-download-restart.log` beneath the same verification directory.

## 2026-11-02: integrated build 12 and full application owners

The integrated release build passed on its first attempt in 92.27 seconds, including window-scoped tab groups and service presentation. The Core/Services suite passed 162 tests (98 Core and 64 Services), with no failures or skips, including the real unauthenticated Codex handshake and bounded PDF subprocess cases.

The signed packaged app then ran `check-app.py --integration` through the actual `ApplicationCoordinator` and two SwiftUI shells in a fresh, disposable profile. All 21 reported checks passed, and the process exited 0. Checks included palette document retention; visible source content beneath Peek; promotion retaining Peek's renderer and form; split ratio persistence and selection; real target-blank popup adoption; second-profile isolation; moving an entire persistent split to another window while keeping its native document and unsaved form; independent palettes/sidebar widths; persisted window ownership; shared service actor identity; per-window profile status; and closing a service presentation without stopping its sibling/backend. The actual popup remained alive through final application shutdown.

This test creates the second profile through the application model. It does not replace the outstanding desktop-input/import-dialog reproduction or visual inspection. Its report explicitly records `desktopInputVerified: false`, `nativeExtensionProtocol: false`, and `extensionCompatibilityVerified: false` for the stock framework. The real MV3 fixture is wired behind `--integration --require-extensions` for the custom framework.

Evidence: `macos/.build/verification/integrated-release-12.log`, `core-services-post11.log`, and `application-12/application.json` with `application-12/application.log` beneath the same verification directory.

## 2026-11-02: integrated build 13

The release build passed in 78.21 seconds after correcting a shadowed error variable in the Archive panel. Strict signature verification passed for the internal test bundle. Its actual application integration run passed all 26 checks and exited 0. New checks imported an Electron-format profile, pinned page and bookmark through the production importer while a real popup and split remained open; read approved page context from its actual owning window after focus moved to another same-profile window; and closed/reopened a saved window with the exact same tab IDs and split, a fresh native window ID, and a clean subsequent close.

The full Core/Services suite passed 179 tests (115 Core and 64 Services), with zero failures or skips. These include trusted native URL provenance, saved windows, durable closed-tab/session restoration, bookmark migration acknowledgement/recovery, download identity after restart, and explicit AI profile scoping. The build integrates Chromium history clearing, native bookmark observation/migration, profile-wide download snapshots/controls, sessions routing, and native URL revalidation. Those new Chromium protocols still require the custom framework; the stock runtime report continues to mark native extension and desktop input verification false.

Evidence: `macos/.build/verification/integrated-release-13-retry.log`, `core-services-post12-full.log`, `bookmark-coordinator-typecheck.log`, and `application-13/application.json` with `application-13/application.log`. The HTTP download fixture independently passed Range/invalid-range checks. The custom framework completed another 5,763 actions without a compiler failure in its most recent segment, with 51,712 remaining when paused for this integrated build.

## 2026-11-02: integrated build 14

The release build passed in 103.98 seconds. Its isolated test bundle passed deep, strict signature verification, and all 30 application-owner checks passed with exit 0. New checks exercise hiding and reselecting the same Peek document, retaining its form draft, muting Peek independently of its source, preserving mute and the renderer through promotion, and persisting a popup's opener relationship. These checks use the real application owners and Chromium documents; they do not synthesize desktop input.

The full Core/Services run passed 190 cases (126 Core and 64 Services), with zero failures or skips, including the bundled Codex handshake and PDF helper. Two new parked-Peek session cases also passed with the five-case session suite: restoring a preview transfers its source and persistent split atomically, preserves preview selection and restart metadata, rejects live/cross-profile destinations, and rolls back failed writes.

The custom-only extension fixture now covers Peek tab identity, selection, scripting, zoom, capture, promotion and closure; blank-page action popups; retained global side panels; worker downloads controlled and renamed through the Swift Library; bookmark import deletion/replay; and Chromium-visible history clearing. These fixtures compiled but have **not** executed against the custom framework yet. The stock report explicitly retains `nativeExtensionProtocol: false`, `extensionCompatibilityVerified: false`, and `desktopInputVerified: false`.

Evidence: `macos/.build/verification/integrated-release-14.log`, `application-14/application.json`, `application-14/application.log`, `core-services-post14-full.log`, and `sessions-peek-post13.log`. The custom framework's latest segment completed 5,254 compilation actions without errors, with 46,862 remaining when paused for this build.

## 2026-11-02: integrated builds 15–16

Build 15 compiled, but its new actual-PDF acceptance exposed a protocol defect: CEF's string callback parser did not preserve flattened DevTools child-session replies. The PDF viewer initialized in a child target, then its response timed out. The Swift bridge now consumes the bounded raw protocol envelope, validates the expected session for each pending request, and fails detached sessions promptly. Nine focused envelope/routing tests passed, including native callback routing and reference ownership. Build 15's failed acceptance is not counted as a passing run.

Build 16 compiled in release configuration in 105.33 seconds. Its isolated, ad-hoc-signed app passed deep, strict signature verification. All 36 application-owner checks passed and the process exited 0, including real PDF viewer `documentLoaded` completion, safe PDF closure, window-specific approved AI context while another profile has focus, rejection of invented window authority, native extension management without replacing the live page, and one reusable ordinary Web Store tab. The separate engine harness passed all 26 checks and exited 0, including remapping a retained popup's opener when its source document is adopted.

The complete Core/Services suite passed 198 cases (127 Core and 71 Services), including the bundled Codex handshake and PDF helper. Ten focused Chromium shortcut-matching regressions also passed. The network extension fixture passed nine baseline checks in an isolated installed Google Chrome process; the media fixture passed four baseline checks there. Those baseline results validate the fixtures, not Zacro's custom runtime.

The source now includes native extension shortcut dispatch and capture suspension, content-only extension options windows, actual action-popup anchors, blank-page side-panel presentation, H.264/AAC fixture assets, and expanded extension/network/media acceptance. These custom-runtime branches remain unverified until the custom Chromium framework links and is packaged. The stock reports explicitly retain `nativeExtensionProtocol: false`, `extensionCompatibilityVerified: false`, and `desktopInputVerified: false`. Desktop Computer tools are currently unavailable in this session; visual and physical-input acceptance remains outstanding.

Evidence: `macos/.build/verification/integrated-release-16.log`, `application-16/application.json`, `application-16/application.log`, `engine-16/engine.json`, `core-services-window-authority.log`, and `cef-envelope-tests.log` beneath the same verification directory. Earlier failed PDF runs remain in `application-15*`.

## 2026-11-02: integrated build 17

The release build passed in 108.21 seconds without warnings. The isolated app passed deep, strict signature verification, all 42 application checks and clean shutdown. New checks cover saved camera permission only for a visible owned page, screen capture delegation to Chromium's native chooser, denial for a hidden page, and AI reset/answer ordering that preserves a newly started request while cancelling the intended older request. The complete Core/Services suite passed 200 tests (127 Core and 73 Services), with no failures or skips.

This build restores the permission prompt's explicit remember choice; separates device and desktop capture permission masks; fixes profile-clear locking, all-window Peek cleanup and profile-wide AI reset; retains global side panels in an empty logical window; and includes the audited sidebar/loading/press/Find-focus refinements. The custom extension fixtures now test last-tab panel parking and actual profile data clearing across windows. These custom branches have not run yet. The stock report still records native extension and desktop input verification as false.

The CEF permission mapping/callback tests passed 15 cases, including native chooser deferral without invoking an allow/cancel callback. Native messaging discovery adds Chrome/Chromium registration fallbacks while retaining Chromium's original manifest and origin checks: four isolated fixtures passed, including twelve cases against the actual generated resolver body; the native implementation and test objects compiled. Native GTests are not yet linked/executed.

The normal build script now requires a custom-runtime receipt. Nine packaging-validator regressions passed, covering stale inputs/arguments/binaries/resources/revisions/links. Eight build-driver provenance tests passed. The Swift package plugin compiled with local-framework support. These checks protect build provenance; they do not replace actual custom-framework acceptance or signing/notarization.

Evidence: `macos/.build/verification/integrated-release-17.log`, `application-17/application.json`, `application-17/application.log`, `core-services-post17-full.log`, `runtime-receipt-validation-17.log`, `plugin-custom-framework-17.log`, `native-messaging-fixtures.log`, and `native-messaging-objects/object-check.json`.

## 2026-11-02: integrated build 18

The first release build compiled in 123.38 seconds without warnings. Its new error-state acceptance exposed a real focus regression: showing an underlying split window could select it while Peek was opening, redirecting subsequent address navigation away from the preview. The coordinator now rejects underlying-document focus while Peek is presented. The successful retry compiled in 94.25 seconds, passed deep/strict signature verification, all **61 application checks**, and clean shutdown. The separate stock-engine acceptance passed and exited cleanly. The complete Core/Services suite passed **203 cases** (130 Core and 73 Services), with no failures or skips and the real bundled Codex handshake/PDF helper.

New application checks cover the Find layout reservation and repeat focus request, retained native drag-source attachment across category/Space presentation removal, exactly-once drag cleanup and UTF-8 pasteboard identity, normal and Peek failure cards, address editing, and recovery without replacing either Chromium document. The Peek check requires an actually visible retained panel as well as the rendered source. No physical drag event is synthesized by these checks.

The build also applies dormant-start/session-restoration settings independently to each saved window, preserves intentional empty selection, resets the palette on profile changes, and adds the original loading strip and page/Peek error presentation. A focused CEF callback regression passed, confirming subframe failures cannot replace main-document error state and transferred frame references are released. Native restoration now waits for a correlated main-frame navigation commit and propagates failure rather than allowing extension document actions to target the temporary blank page. Custom-only fixtures expand coverage for listener-independent side panels, dormant document APIs, native identity windows, and isolated native-messaging framing/origin/process cleanup. Those custom branches still await the linked Chromium framework.

The application harness renders its own NSView trees into `view-renders`. The palette, page-error and Peek-error artifacts were visually inspected for layout, typography, glyphs and readable controls. These are **not desktop screenshots**: native web-document windows and behind-window material composition are excluded, and the metadata explicitly records desktop input and material-compositing verification as false. They do not replace Computer acceptance or README screenshots of the completed browser.

Evidence: `macos/.build/verification/integrated-release-18.log`, `integrated-release-18-retry.log`, `application-18-retry/application.json`, `application-18-retry/view-renders`, `engine-18/engine.json`, `core-services-post18-full.log`, and `cef-load-error-tests-18-retry.log`. The initial failing run remains in `application-18`. Stock reports continue to mark native extension compatibility and desktop input as unverified.

## 2026-11-02: integrated build 19

The release product compiled in **126.29 seconds**, without warnings. The internal bundle passed deep/strict signature verification, all **74 application checks**, all **26 stock-engine checks**, and clean shutdown. The complete **212 Core/Services tests** passed (135 Core and 77 Services), with no failures or skips and the bundled Codex handshake/PDF helper.

The application checks now include thirteen deterministic Space presentation and scroll-lifetime cases: bounded hosting across 1,000 Spaces, continuous long travel, exact snapping, one-viewport distant-dot transitions, interruption, Reduce Motion, profile changes, scroll restoration and deleted-Space cleanup. Explicit focus uses a cancellable selection intent, with a narrow closing-palette grace period; later input or another window cannot revive an abandoned request. Four Core regressions exercise that intent. The actual custom-runtime split activation check remains pending because stock CEF does not honor the new hosted-window ShowInactive marker.

The build retains pinned extension layout during asynchronous metadata refresh, provides real native Menu images from the source glyph paths, preserves saved subscription storage before every provider operation, and uses bounded digest metadata for exceptional navigation history. Failed pages can retain their native extension side panel while a separate error panel covers only the document rectangle. Custom-only checks assert exact error bounds, retained panel drafts and recovery. They have not yet run. Exact extension-popup/owner notifications and scoped shortcut routing compile, and the native popup-anchor object check passed; physical popup keyboard input is unverified.

Evidence: `macos/.build/verification/integrated-release-19.log`, `application-19/application.json`, `engine-19/engine.json`, `core-services-post19-full.log`, `document-focus-intent-19.log`, and `popup-owner-objects-19/object-check.json`. Own-view render artifacts retain the same explicit limitations as build18. Custom-framework acceptance, desktop input, material composition and final distribution remain release gates.

## 2026-11-02: integrated build 20

The first release build completed in **125.42 seconds**. Its signed internal bundle passed **87 application checks** and exited 0. A single implicit-capture warning in the theme editor's weak window-reporting callback was corrected with an explicit weak capture binding; the warning-free rebuild completed in **97.88 seconds**. That final executable passed deep/strict signature verification and **26 stock-engine checks**, with clean shutdown. The complete **213 Core/Services tests** passed (136 Core and 77 Services), without failures or skips.

Actual loopback `Notification.requestPermission()` requests now verify window-owned asynchronous sheets, continued use of another browser window, navigation cancellation without persisting a choice, background queuing without activation, presentation when the owner gains focus, and cancellation when its source tab closes. Eight focused CEF callback/lifetime tests also passed, covering retained decisions, exact native dismissal, late-response rejection and native chooser deferral. A repository regression verifies that cold startup chooses the most recently saved window when every window was closed.

Application checks verify that action preparation materializes the selected Peek, rejects a changed profile before creating an empty tab, and cannot activate an inactive window. The actual `chrome.action.openPopup` path now prepares an authorized owner and resumes Chromium's original implementation without granting activeTab. Native dispatcher, ActionAPI, ExtensionsToolbarDesktop and popup-anchor object checks passed. A real-worker fixture is authored for logical popup identity, native owner, floating placement above browser controls, no unintended scripting grant and cleanup; this custom-runtime branch is still unexecuted.

The theme editor's actual owned view was rendered and inspected for layout and readable controls. Capture of its exact popover window, dismissal, unchanged saved theme and retained page draft passed. The image does not include desktop material composition. A discrepancy in native color-swatch presentation remains under review. Editor-to-editor navigation now waits for sheet dismissal and validates its owner/profile/Space; HTML bookmark import retains its originating profile; palette dismissal uses guarded shell responder restoration.

Evidence: `macos/.build/verification/integrated-release-20.log`, `integrated-release-20-retry.log`, `application-20-engine-assisted/application.json`, `application-20-engine-assisted.log`, `application-20-engine-assisted/view-renders/theme-editor-0.png`, `engine-20/engine.json`, `core-services-post20-full.log`, `permission-callbacks-20.log`, `startup-window-20.log`, `action-open-popup-objects-20/object-check.json`, and `popup-owner-objects-20/object-check.json`. Stock extension compatibility, desktop input and material composition remain explicitly unverified.

## 2026-11-02: integrated build 21

The final release build passed in **105.10 seconds**, without warnings. The internal app passed deep/strict signature verification and all **113 application checks**, with clean shutdown. The complete **218 Core/Services tests** passed (141 Core and 77 Services), including the bundled Codex handshake and PDF helper, without failures or skips.

New application coverage exercises actual asynchronous AppKit sheets, duplicate-sheet rejection, task cancellation, physical owner closure, and cancellation of a child editor's sheet when its logical browser owner closes. The first run reached 101 passing checks before an incorrect test lookup for the Window menu. After correcting the fixture, the next run exposed a real product hang: AppKit can refuse `performClose` while a sheet disables the titlebar's close button. Programmatic browser close now uses the existing Chromium window transaction, retaining page beforeunload checks. The successful run verifies that closing a browser cancels its sheet and completes normally.

Application-level commands and external links now wait for window-close decisions and profile maintenance. Dock actions remain available after the last browser window closes; a command reopens the most recent saved window, external links use one live owner, and New Window creates exactly one window. Native menu commands preserve the focused Chromium document, and Minimize targets its owning shell. The application checks exercise all these paths. A Core regression also preserves recovery warnings in newly created window facades.

Five native color-well checks and four dialog-owner lifetime checks pass. The actual theme-editor view renders clearer separate swatches; integrated capture revealed AppKit expanding a nominal 27-point well to 33 points, so exact sizing remains a follow-up. These own-view images still exclude desktop composition and input. The custom Chromium build guard passed nineteen driver/provenance cases; a monitored ten-job trial hit native memory-pressure warning and was stopped, then compilation resumed safely at eight jobs. No custom-runtime extension or desktop-input acceptance is claimed.

Evidence: `macos/.build/verification/integrated-release-21-retry2.log`, `application-21-retry2/application.json`, `application-21-retry2/application.log`, `application-21-retry2/view-renders`, and `core-services-post21-full.log`. The initial fixture failure and interrupted close-hang run remain under `application-21` and `application-21-retry` respectively. Custom framework, physical interaction, material composition, signing/notarization and final distribution remain release gates.

## 2026-11-02: integrated build 22

The final release retry compiled in **94.14 seconds**, without warnings. The internal bundle passed deep/strict signature verification and all **133 application checks**, with clean shutdown. The complete **236 Core/Services tests** passed (155 Core and 81 Services), without failures or skips. The unchanged engine implementation separately passed **31 stock-engine checks** and clean shutdown before the final UI-only retry.

The first presented theme-editor check exposed actual native color-well frames of 33×31 points with lazy AppKit bezel alignment insets, despite 27-point SwiftUI proposals. A permanent zero-inset override preserves genuine AppKit color-panel activation while fixing the layout. The final presented controls measure 27×27 after drawing, with matching fitting sizes and zero insets; owned-view pixel inspection confirms the 27-point swatches. Palette dismissal also checks whether focus may be restored before making the parent key, so it cannot take focus from a newly opened editor.

New lifecycle checks verify real private cookies survive an unrelated window closing, while explicit private retirement clears them. A still-retired public profile ID cannot reopen native documents; unopened profiles replay their durable deletion receipts, and replay rejects already-opened profiles. The native journal has 21 passing standalone filesystem checks. Core recovery tests ensure an uncommitted privacy backup cannot authorize profile retirement, while startup cleanup keeps its receipt until native and application artifacts are durably removed.

Evidence: `macos/.build/verification/integrated-release-22-assisted-retry2.log`, `application-22-assisted-retry2/application.json`, `application-22-assisted-retry2/application.log`, `application-22-assisted-retry2/view-renders`, `acceptance-22-assisted/engine.json`, `core-services-post22-full.log`, and `profile-retirement-journal-check.log`. Earlier failing hosted-control measurements remain under `application-22` and `application-22-assisted-retry`. The custom Chromium framework is still compiling; its extension fixtures, physical interaction, final material composition and distribution signing/notarization remain release gates.

## 2026-11-02: integrated build 23

The release build completed in **126.88 seconds**, without warnings. Its internal bundle passed deep/strict signature verification, **149 application checks**, **31 stock-engine checks**, and clean shutdown. The complete **244 Core/Services tests** passed (155 Core and 89 Services), with zero failures, skips or compiler warnings, including the bundled Codex handshake and PDF helper.

Sixteen added application checks cover standalone split Favorites, destination reflow and delayed Space navigation bound to the originating drag, profile, window and destination. These exercise actual native helpers and Core state; physical drag/trackpad acceptance remains outstanding. Sync now retains consent-required cloud intents for explicit review, validates the captured profile before mutation, and cancels stale reviews independently of its serialized profile queue. Eight additional Services regressions cover that durable intent authority.

Native management operations now carry an individual owner/cancellation lease into Chromium's original install, enable and uninstall paths. The foreign Swift-window dialog parent is handled explicitly, and cancellation reaches shared-module and CRX commit checks. Twelve changed production Chromium objects compiled successfully, alongside the focused adapter/lifetime fixtures. A custom-only application fixture is authored to check real uninstall-dialog ownership, pre-consent installation preservation and cancellation. These paths have **not executed in the custom browser runtime** because its framework is still linking/building; object compilation does not establish extension compatibility.

Evidence: `macos/.build/verification/integrated-release-23.log`, `application-23/application.json`, `application-23/application.log`, `acceptance-23/engine.json`, `core-services-post23-full.log`, `management-23-final-objects/object-check.json`, and `native-management-prompt-objects/object-check.json`. The stock report continues to mark native extension compatibility and desktop input as unverified. Final custom-runtime acceptance, desktop interaction, material composition and distribution signing/notarization remain required.

## 2026-11-02: first complete custom framework and integrated build 24

The complete custom Chromium/CEF framework linked successfully: **2,878 actions in 13m17s**, no failed actions. Receipt validation passed for the pinned revisions, 45 native inputs, 240 resources, four symlinks, arm64 binary, sandbox support and ICU. The Swift release build passed in **134.10 seconds**; the final rebuild including the CEF preference ownership correction passed in **125.41 seconds**, both without warnings. Normal packaging with this receipt completed, including deep/strict ad hoc signature verification, at `macos/.build/verification/custom-24/Zacro Native.app`.

The first actual custom-engine launch aborted before acceptance. Chromium's non-official build had enabled its field-trial testing configuration, which selected experimental Aperitif helpers that upstream CEF does not package. The subsequent GPU launch failure also exposed an upstream cache-cleanup callback destroying open files on a thread that prohibits blocking. No helper aliases, sandbox bypass or disabled DCHECKs were used. A diagnostic launch of the unchanged binary with `--disable-field-trial-config` resolved startup. Production release configuration and asynchronous abandoned-cache cleanup are being corrected for the next build.

That diagnostic passed **26 engine checks**, including native protocol/registry availability, navigation commit barriers and encrypted restoration of a form larger than 512KiB. The suite then failed its oversized-history capture assertion; it is not an engine acceptance pass. The application diagnostic passed **164 checks** and exited cleanly, but failed `privatePDFViewerLoadsActualDocument`. Public PDF loading passed. The private viewer reported that its target tab was absent from its profile, confirming the missing component-only private host route. The real third-party extension suite occurs later and has not yet executed.

The passing application checks include all **19** new palette/shortcut/site-controls cases and **12** deterministic model/service AI cases, as well as exact-window sync dialogs, stale-form rejection and the actual per-context download preference bridge. AI request fixtures use an in-memory transport, with no account, credential lookup or provider network request. Proposed page sharing now requires explicit confirmation; cancellation preserves existing approvals and conversation. The follow-up close/reopen service-lifetime fix and three additional regressions are authored but are not included in build24.

Evidence: `custom-framework-23.log`, `custom-framework-23-validation.log`, `integrated-release-24.log`, `integrated-release-24-final.log`, `custom-package-24.log`, `custom-engine-24/engine.log`, `custom-engine-24-fieldtrial-diagnostic/engine.json`, and `custom-application-24-fieldtrial-diagnostic/application.json` under `macos/.build/verification`. Diagnostic reports keep extension compatibility and desktop input unverified. The first receipt is historical once the next native fixes change its inputs; normal packaging must use a newly validated receipt.

## 2026-11-02: integrated build 25, stock-engine regression check

The final Swift release build passed in **112.98 seconds**, without warnings. Its internal stock-CEF bundle passed deep/strict ad hoc signature verification, all **193 application checks**, and clean shutdown. The report correctly records native extension protocol, full extension compatibility and desktop input as unverified. The last unchanged Core/Services run remains 244 passing tests.

All **15** deterministic AI model/service cases passed, including a delayed shutdown followed by reopening: replacement requests wait for the previous model's cleanup, and repeated cleanup from the old model cannot cancel or erase the new conversation. The 19 palette/shortcut/site-controls checks also passed. The stock private-PDF document handshake passes, but it cannot establish the new custom component-only private API route.

The private PDF observer and native policy, renderer history-state acknowledgement, field-trial release configuration and abandoned GPU-cache cleanup require a newly built custom framework and actual integration acceptance. A later private-observer retirement guard is not part of this executable and requires the next Swift build.

Evidence: `macos/.build/verification/integrated-release-25-final.log`, `application-25-stock/application.json`, `application-25-stock/application.log`, and `application-25-stock-driver.log`. No desktop screenshot, physical-input acceptance or release certification is inferred from this run.

## 2026-11-02: integrated build 26, close ownership and search parity

The Swift release build passed in **127.56 seconds**, without warnings. The signed internal stock-CEF app passed all **243 application checks**, **31 engine checks**, and clean shutdown. The application report still explicitly marks native extension protocol, extension compatibility and desktop input as unverified. No new Core/Services implementation changed; its last full run remains 244 passing tests.

The application run includes all 50 new Electron-reference Unicode search checks. Before integration, actual standalone Swift execution caught Greek final sigma differing from JavaScript despite source-level review; root-locale contextual lowercasing fixed it, and all 50 then passed both standalone and in the packaged app. Existing private-PDF stock behavior, model/service AI lifetimes, owned dialogs and multi-window closure continue to pass.

The new coordinator serializes actual native capture operations, invalidates stale publication, and requires fresh snapshots before close/discard. Actual save failure offers Keep Open or explicit URL-only fallback, with exact page/browser/profile/window/history consent and durable deletion of older encrypted form state. Window close attempts and their preparation tasks now have independent identities; the authored custom-runtime test covers an older tab prompt superseded by window close. These history-specific cases are not exercised by stock CEF and remain pending. A subsequent outer `CefRuntime` quit-preparation generation fix is not included in this executable and needs the next build.

The new framework build passed its five changed implementation-object checks. Its first eight-job full rebuild stopped safely after 42 actions due to memory pressure/new swap growth, without compiler errors. Compilation is resuming with six jobs; no receipt or final package is accepted from a stopped build.

Evidence: `macos/.build/verification/integrated-release-26.log`, `application-26-stock/application.json`, `engine-26-stock/engine.json`, their driver logs, `command-search-26.log`, `command-search-26-retry.log`, and `custom-framework-25.log`. Desktop composition/input, full custom-runtime acceptance and distribution remain separate release gates.

## 2026-11-02: custom runtime 25 with Swift 26, diagnostic acceptance

The incremental custom framework completed **436 actions in 11m58.61s** at six jobs, with normal memory pressure and no further swap growth. Its validated receipt covers 51 native inputs, 240 framework files and four symlinks. The binary SHA-256 is `e7abd3311214f24e0bfbb00b64c76ec9accb281936b3f22c15426c0b91cb53a6`. A separately assembled, deep/strict-verified diagnostic app paired that framework with the unchanged Swift26 executable; it is not the final release package.

Both engine runs passed all **43 checks** and exited cleanly, without the earlier field-trial launch override. Real encrypted form restoration above 512 KiB and explicit rejection of oversized state passed. The first application run stalled in accessibility serialization of the fixture's visible 8.4-million-character textarea. An owned renderer sample identified Blink inline-text serialization. The fixture now hides that textarea while retaining exactly the same form bytes and capture assertions; this does not establish acceptable performance for a visible document of that size.

The retry passed **232 checks**, including concurrent native capture, Keep Open, oversized live draft preservation, stale-consent rejection, superseding tab/window close, durable URL-only fallback and reopening without stale form state. It then failed while loading the public extension used to verify private-PDF isolation: the fixture had not enabled native Developer Mode, so Chromium correctly left its unpacked extension disabled. The fixture now explicitly enables that setting and verifies the installed extension is enabled. The private-component observer passed, but private PDF API operations and the full extension suite still require a new executable and successful run.

Evidence: `macos/.build/verification/custom-runtime25-swift26/assembly.json`, `engine/engine.json`, `engine-retry-hidden-form/engine.json`, `application/renderer-44407-sample.txt`, and `application-retry-hidden-form/application.json` within that diagnostic directory. The subsequent exact-production-method termination fixture passes **14 checks**, and the Electron-reference native command fixture passes **50**, under `termination-lifecycle` and `command-search-27-driver.log`. Those narrow results do not replace the next integrated application build.

## 2026-11-02: integrated builds 27–28, Peek initialization regression

Build27 compiled without warnings in **140.79 seconds**, packaged normally with the validated custom25 receipt and passed deep/strict signing validation. All **43 engine checks** passed with clean shutdown. Its application run passed 199 checks, then the first normal document failed preparation: the new Peek bridge awaited renderer-side Runtime/Page setup while its URL-less WebContents had no started document. The run failed and exited cleanly; it is not application acceptance.

Build28's final warning-free retry completed in **122.34 seconds** and packaged normally. An explicit new-page blank bootstrap released renderer setup, allowing 252 application checks to pass. Reopening a saved split window then failed: the bootstrap had consumed Chromium's fresh initial navigation controller, so legacy saved history correctly rejected restoration. This diagnostic was useful but is not an accepted fix. The subsequent source removes the temporary blank navigation entirely, retains native ownership registration before restore, and awaits Peek setup only after the real initial/restored document commits. One metadata reconciliation after the restore guard releases preserves redirected addresses and final titles that completed during adapter setup. Build29 must verify this ordering.

The new History implementation follows actual successful main-frame commits, updates each exact visit's title without changing its timestamp, excludes same-document/failed destinations and transient Peek, and records promotion atomically. Eight additional Core/Services regressions and a real renderer history fixture are authored but were not reached by build28's application failure. A preserved unreadable credential index now prevents unverified durable-key cleanup from being acknowledged; ephemeral connections need no protected-store access. No real credentials or account requests were used.

Evidence: `integrated-release-27.log`, `custom-package-27.log`, `engine-27/engine.json`, `application-27/application.json`, `integrated-release-28-retry.log`, `custom-package-28.log`, and `application-28/application.json` under `macos/.build/verification`. The initial build28 compiler error from a nested actor-isolated helper was corrected before packaging. These failed application checkpoints do not discharge the remaining extension, desktop-input or release gates.

## 2026-11-02: integrated build 29, real history and trusted Peek

The Swift release build completed in **130.74 seconds**, without warnings. Normal custom-runtime packaging and deep/strict ad hoc signature verification passed. All **43 engine checks** and all **252 Core/Services tests** (161 Core, 91 Services) passed, with no failures, skips or compiler warnings. The Services run includes the bundled Codex handshake and PDF helper; no real account or credential was accessed.

The first application run, concurrent with the unit-test compilation, failed a recovered Peek visibility assertion after 268 passing checks. A retry of the same immutable app passed that assertion and reached the extension-worker fixture. Source review found a real presentation-cache weakness: an error-to-live transition could leave a newly attached page hidden when the final animation frame had not changed. The next build repairs actual native visibility rather than inferring it solely from cached geometry. The failed first run remains part of the evidence.

The retry passed all ten actual History checks, ten trusted Peek-link checks, and fifteen custom navigation-close checks. These include no bootstrap Back entry, successful-commit-only visits, exact title updates, transient-Peek exclusion, atomic promotion, isolated main-frame link handling, real Shift/Alt input, inactive split selection, reload rearming, bounded navigation history and preserved oversized drafts on Keep Open.

The application run still **failed**: after unpacked Developer Mode and installation checks passed, its first MV3 worker evaluation hit Chromium's `WorkerGlobalScope` invalid-URL CHECK. A DevTools target existed before the worker had finished startup. The next native batch binds inspection to the exact RUNNING service-worker version, instance token and unique execution context. An intentional rejected-Promise regression must return a normal JavaScript error and leave that same worker usable. Private PDF API operations and the full extension suite remain unverified until this passes in a newly built framework.

Evidence: `integrated-release-29.log`, `custom-package-29.log`, `engine-29/engine.json`, `core-services-post29-full.log`, `application-29/application.json`, and `application-29-retry/application.json` / `application.log` under `macos/.build/verification`. Owned-view renders of the sidebar, theme editor and palette were inspected for layout; they do not capture the composited Chromium content or establish desktop-input acceptance.

## 2026-11-02: integrated build 30, stricter startup and discard checks

The final Swift release retry compiled without warnings in **126.88 seconds**. Normal packaging passed with the newly validated custom30 framework (58 native inputs; binary SHA-256 `2d0a72e5485c3cf86d3e6bfc26fb225dda7dcb98c5c2ff0fe0e687e199b92678`). The first compiler attempt caught a missing actor annotation on a nested dialog request and an ambiguous continuation type; both were corrected before packaging.

Both packaged runs exited cleanly but **failed acceptance**. The engine passed 28 checks, then the first new private-discard case was rejected by Chromium's unchanged document-in-use guard. The next Swift change makes hosted BrowserView hiding symmetric with showing and adds native/renderer visibility diagnostics; the cause and fix still need runtime confirmation. The application passed 280 checks, including saved history restoration and prior error recovery, then timed out at the new first-parser-inline Peek fixture. Its isolated world was first created during later arming, proving that the initial bootstrap had not executed. The next bridge revision submits Page enablement and document-start registration before navigation without waiting for an absent renderer. The strict competing site handler remains in the test.

These earlier failures prevented the new worker regression, real extension suite, Peek replacement and navigation-veto fixtures from running. Focused application suites are being added to diagnose those groups independently; only the default full suite can establish full application acceptance. No pass is inferred for the unexecuted paths.

Evidence: `integrated-release-30.log`, `integrated-release-30-retry.log`, `custom-package-30.log`, `engine-30/engine.json` / `engine.log`, and `application-30/application.json` / `application.log` under `macos/.build/verification`.

## 2026-11-02: integrated build 31, focused runtime diagnosis

The Swift release build completed without warnings in **140.30 seconds** and packaged normally with the validated custom30 framework. All **51 engine checks passed**, with clean shutdown. The eight added private-discard checks confirm actual renderer hiding, preservation of current and older form history, rejection of oversized state without losing the live draft, retry after shrinking the form, and continued denial of encrypted private-state export.

The focused extension run confirmed all three worker-startup regressions: a top-level marker was ready, an intentionally rejected Promise returned an ordinary JavaScript error, and the same worker remained usable. It then failed the private-window isolation assertion and exited with signal 5 during shutdown. Source review found that the intended private-only fixture still retained its initial public blank tab, making public window visibility legitimate; this does not establish that private tab data was exposed. Build32 removes only that disposable blank and reports each isolation probe separately. A separate shutdown correction prevents profile-download cleanup from creating a new native transport after native host closure has begun.

The focused Peek run confirmed document-start installation during parser loading, before a body existed, and interception ahead of the first inline site handler. It then timed out waiting for the owned preview. A scoped tab index had been applied inside a canonical repository transaction, modifying the wrong window's tab. Build32 resolves the source by exact tab and owner IDs inside the transaction and checks that other windows remain unchanged.

The focused navigation run passed fifteen close checks and six new veto/dialog checks before failing its dialog-reset fixture with “No dialog is showing.” Actual checks established that Stay preserves address, history and form draft, another window remains usable, state capture still succeeds, and prompt input is returned exactly. The reset fixture had not enabled its own root DevTools Page session; build32 corrects that setup. Partial checks printed before a helper throws are retained in the logs and are not counted as a passing suite. None of the three focused application suites passed in build31.

Evidence: `integrated-release-31.log`, `custom-package-31.log`, `engine-31/engine.json`, `extensions-31/application.json`, `peek-31/application.log`, and `navigation-31/application.log` under `macos/.build/verification`. These results do not replace full application, desktop-input or distribution acceptance.

## 2026-11-02: integrated build 32, Peek passes and extension cases execute

The release retry compiled without warnings in **127.39 seconds** and packaged normally with custom30. The initial compiler attempt required an explicit main-actor annotation on a nested navigation-ownership predicate; the packaged executable includes that correction. All four focused runs exited cleanly, including the extension failure path that previously crashed during shutdown.

The **Peek suite passed all 28 checks**: six pre-navigation bootstrap/cancellation checks, fourteen trusted-link checks, six replacement checks, and two setup checks. These exercise actual isolated renderer worlds, parser-inline capture priority, exact window ownership, retained source drafts, beforeunload veto, concurrent replacement intent, and self-replacement after old-browser teardown. They do not establish desktop composition or hardware-input equivalence.

The extension suite passed **32 checks** and failed four. Private-only PDF isolation now passes all three ordinary-extension probes (tab lookup, window lookup, query), while the bundled component loads the real PDF, controls native zoom, creates links/windows in the same private profile, and retires its transport only after the last owner closes. All three worker startup/error regressions pass. Twelve real MV3 aggregate cases passed, including logical tabs/events/window transfer, retained scripting, approved navigation, zoom, bookmarks, debugger targets, offscreen documents and storage/notifications. The failures concern dormant document APIs, large approved navigation, closed-session restoration and tab-group expectations. These are being corrected; the full extension fixture has not passed.

Navigation passed all fifteen close checks and nine veto/dialog checks, then its new Peek-promotion fixture timed out after the first ownership assertion. The separate capture suite confirmed that host permission does not grant tab capture, then failed because the native action model was unavailable. No positive capture-stream claim is made. These failures remain release blockers rather than being skipped from full acceptance.

Evidence: `integrated-release-32-retry.log`, `custom-package-32.log`, and the `extensions-32`, `peek-32`, `navigation-32`, `capture-32` report/log directories under `macos/.build/verification`.

## 2026-11-02: integrated build 33, real capture and extension progress

Swift compiled without warnings in **129.58 seconds**. The custom Chromium framework rebuilt in **69.31 seconds / 32 steps**, after its exact toolbar implementation object passed. Its validated receipt covers 61 native inputs. Normal packaging and deep/strict ad hoc signature verification passed. The hidden toolbar owner restores Chromium's actual extension action model without displaying Chrome's toolbar or replacing native permission grants.

The packaged engine again passed **all 51 checks** with clean shutdown. The focused sidebar suite passed **all seven checks**, including five actual owned accessibility-tree checks for favorite action names across Sleeping, Loaded, Closed and rename transitions. These read only the disposable application's own shell tree; no desktop input or VoiceOver acceptance is claimed.

The first capture run failed because `requestVideoFrameCallback` depends on presentation scheduling in an offscreen document. The unchanged packaged executable, rerun with a fixture that reads genuine timestamped `MediaStreamTrackProcessor` frames, passed **all 11 checks** and exited cleanly. Actual decoded colors, distinct frames, native active/stopped events and permission denial cover default, legacy, explicit background, split, Peek and second-window targets. This changes the fixture's decoder, not capture permissions or the browser's video source.

The extension run passed **52 checks**, including all seventeen core API cases, nine network cases and six silent identity cases. Scoped Peek-adapter removal now permits safe discard while real site pagehide/beforeunload handlers still prevent it; session restore and group behavior also pass. The run failed to identify its first interactive authorization window, then crashed during shutdown with a BrowserManager/MemorySaver observer stack. CEF's missing default-client registration leaves Chrome-created windows unmanaged; source work is addressing that ownership seam. No full extension pass or safe authorization shutdown is claimed.

The navigation run again passed fifteen close and nine veto checks, then the promotion fixture identified a more precise failure: the visible Peek did not acquire native document focus. Its focus correction remains unverified. Full application acceptance has not yet run successfully.

Evidence: `integrated-release-33.log`, `custom-framework-33.log`, `custom-package-33.log`, `engine-33`, `sidebar-33`, `capture-33`, `capture-33-track-processor`, `extensions-33`, and `navigation-33` under `macos/.build/verification`.

## 2026-11-02: integrated build 34, authorization and Peek focus

Swift compiled without warnings in **147.87 seconds**. Normal packaging reused the validated custom33 framework and passed deep/strict ad hoc signature verification.

The extension suite passed **78 checks** before a fixture-origin assertion failed, and exited cleanly. Real interactive authorization callbacks and user cancellation now resolve and close their actual Chrome-owned windows. Minimal default CEF clients retain those windows outside the tab catalog and drain both the browser document and its native window before releasing the profile. Nine native-messaging cases, command shortcuts, options-window reuse, native action dispatch, icon decoding and history clearing also passed. The later programmatic-popup fixture loaded `localhost` successfully but incorrectly called a helper restricted to `127.0.0.1`; the next build checks its exact intended URL and title. No full extension pass is inferred.

The focused **navigation suite passed all 33 checks**, with clean shutdown. Removing the assignment of Chromium's root widget as AppKit first responder preserves the actual renderer responder. The visible Peek now acquires native focus and trusted sticky activation; navigation cancellation, promotion, retained draft, native identity and subsequent encrypted capture all pass.

A separate fresh-process **accessibility diagnostic passed all 11 checks**, with clean shutdown and the global renderer-accessibility switch omitted only for that launch. A never-shown control has no tree before any accessibility access and remains tree-free while the positive document uses the production show/hide path. The positive tree retains actual text, form value and native document identity after hiding and showing. This supports the scoped implementation; production-switch removal still requires the next packaged run. It does not establish VoiceOver or desktop-input acceptance.

Evidence: `integrated-release-34.log`, `custom-package-34.log`, `extensions-34/application.json`, `navigation-34/application.json`, and `accessibility-34/accessibility.json` under `macos/.build/verification`. Full custom application, broader extension compatibility, desktop composition/input and distribution acceptance remain incomplete.

## 2026-11-02: integrated build 35, scoped accessibility and auxiliary veto

The warning-free Swift release build completed in **159.12 seconds** and packaged normally with the unchanged custom33 framework. **All 51 engine checks** and **all 11 separate scoped accessibility checks** passed with clean shutdown after removal of the production global renderer-accessibility switch. The exact-production-method shutdown driver passed **35 lifecycle checks**, including late native creation, Stay, replacement Quit and reuse of one asynchronous cleanup task. Four CEF auxiliary-client tests passed without warnings.

The extension run passed **89 checks** before its programmatic popup ownership/stacking assertion failed; it exited cleanly. All ten new actual auxiliary-window cases passed: distinct native profiles, exclusion from the logical tab catalog, trusted activation, an owned beforeunload sheet, Stay retaining the exact document/draft/worker flow, Leave waiting for both document and NSWindow closure, and preservation/completion of another profile's authorization flow. The `localhost` fixture now loads and its popup sees the correct logical document without acquiring an activeTab grant. The subsequent popup key-window/level assertion still requires diagnosis; later extension services remain unexecuted in this run.

All **91 Services tests and 161 existing Core tests** passed without skips or warnings. Seven of the eleven new retirement recovery tests failed because the ordinary single-window reducer deliberately omits the canonical window sessions required by recovery. The next correction uses a canonical durable transaction with explicit requesting-window validation. Its first targeted rerun passed the ownership checks but found two fixture expectations using unnormalized optional Peek history; those fixtures now provide complete saved navigation before asserting exact metadata equality. The final rerun and actual recovery cases remain pending.

The Home layout now follows the Electron source's fixed-width wrapping tiles, search outline/focus halo and toolbar hover/press behavior. It compiled but its new owned-view renders have not yet run. Independent adapter checks passed 42 pinned source/ownership tests; the initial generic unittest invocation lacked the required pinned-source setup and was replaced with each test's documented `--chromium-root` entry point. The Peek DOM bridge also passed 38 reference decisions and six adapter lifecycle checks.

Evidence: `integrated-release-35.log`, `custom-package-35.log`, `engine-35`, `accessibility-35`, `extensions-35`, `core-services-35.log`, `core-retirement-36.log`, `runtime-termination-35.json`, `auxiliary-browser-35-tests.log`, `native-adapter-35-tests-corrected.log`, and `peek-link-35.log` under `macos/.build/verification`. No full application, universal extension, physical-input or release claim is made.

## 2026-11-02: integrated build 36, recovery transactions and focused extension services

The warning-free Swift release build completed in **161.13 seconds** and packaged normally with the unchanged custom33 framework. All **263 Core/Services tests** passed (172 Core, 91 Services), with no skips or compiler warnings. Eleven recovery regressions now verify canonical window ownership, exact retained Peek/split metadata, rejection of foreign or replaced owners, and rollback after an actual persistence failure. The bundled Codex handshake and PDF helper ran without real accounts or credentials.

The navigation run again passed its previous **33 checks**, then failed the first new recovery fixture's trusted activation assertion. A subsequent fixture correction waits for the exact native view and renderer viewport to settle and confirms hit testing before issuing one genuine primary click. That correction is not part of build36 and has no runtime pass yet.

The focused extension-services run passed **13 checks**, including a deleted bookmark remaining deleted, worker downloads appearing in the Swift Library, pause/resume, expected file bytes, rename/undo and removal. It then failed to load a side panel. Pinned Chromium source inspection identified its normal-browser-type guard rejecting CEF's hosted popup browser; no working side-panel claim is made. The focused action run passed **26 checks** and failed its popup ownership assertion. Its diagnostics show the real popup attached to Chromium's page window without entering Zacro's prepared-anchor path; the logical document and permission checks themselves passed.

The full application run passed **238 checks** before a `CancellationError` transferring the split into a second window. All four runs exited cleanly but failed acceptance. Eight owned Home view renders were produced; light, dark, compact and private layouts were inspected. These are SwiftUI/AppKit view captures, not screenshots of desktop composition or evidence of physical input.

Evidence: `integrated-release-36.log`, `custom-package-36.log`, `core-services-36.log`, `navigation-36`, `extension-services-36`, `extension-actions-36`, and `application-36` under `macos/.build/verification`. Full application, broader extension compatibility and the remaining release gates are still open.

## 2026-11-02: integrated build 37, popup anchoring and download retirement

The Swift release retry passed without warnings in **136.31 seconds** after adding a missing Services import to the new acceptance helper. Seven native presentation tests passed, including fifteen compiled guard assertions. All five changed production objects compiled. The guarded-six-job complete Chromium build passed in **2m48.33s / 99 steps**, with no swap growth or resource-guard stop. Independent receipt validation and normal packaging passed; the receipt covers 62 native inputs, 240 files and four symlinks. Framework SHA-256: `0be30949a46c21e9b24b365734ae5b7b13c5874674f60cb0bf08bc9ea34cf363`.

The focused **window-transfer suite passed all nine checks** and exited cleanly. It verifies rejection of a retained closed coordinator, a persistent split moving as a unit, both live native identities and unsaved drafts surviving, one authoritative owner despite a focus change, and rejection when the destination closes during authorization. The earlier full fixture was corrected to select the exact newly created window; production transfer validation was preserved.

The focused **download-retirement suite passed all sixteen checks** and exited cleanly. Real MV3 transfers cover running and paused cancellation, a late item cancelled by the retired context, durable deletion receipts, another profile's paused/resumable item, and the complete application Delete Profile action. A deliberately retained worker witnesses the first profile's fence; the second profile closes its inspector before ordinary deletion. This does not establish private last-owner behavior or physical database erasure before native shutdown/replay.

The action suite passed **46 checks**, including programmatic popup ownership above the palette, release of that ownership and a real popup on a blank tab. Its first side-panel response arrived before the document's message listener was ready; the external fixture now waits for its actual instance, draft and window ID. The action run then **crashed during shutdown**: its still-open popup host outlived the physical Browser. A native lifetime fix is staged, not included in this build.

With the readiness correction, the same packaged app's focused services run passed **14 checks**, including the real side panel's logical window, then failed `failedDocumentKeepsNativeSidePanelVisible`. Failed-run shutdown remained alive; an owned-process sample was saved before its exact disposable process group was stopped with SIGTERM. This is not clean-shutdown acceptance. Chromium's error-page reload timer explains the repeated loads in that log; diagnostics are being added to distinguish the failed layout predicate and any owned navigation-save sheet.

The navigation run passed seventeen checks, then timed out waiting for its beforeunload sheet. A contemporaneous actual screen capture shows a macOS crash-report dialog over the browser. Clean focus/input conditions must be restored before attributing this regression or accepting the new recovery cases. Screen Recording permission is available, and two real OS captures were inspected, but these interrupted captures do not establish visual or hardware-input parity. Full build37 application acceptance has not passed.

Evidence: `integrated-release-37-retry.log`, `native-presentation-37-objects`, `native-framework-37*`, `custom-package-37.log`, `extension-actions-37`, `windows-37`, `navigation-37`, `download-retirement-37`, and `extension-services-37-ready` under `macos/.build/verification`. Actual capture paths are `/var/folders/9s/lwj2ss7d679bl8hv9dx2qf6h0000gn/T/codex-shot-2026-11-02_12-30-02.png` (popup) and `codex-shot-2026-11-02_12-31-18.png` in the same temporary directory (browser covered by the crash report).

## Required release evidence

- Successful custom Chromium build and package provenance; native protocol capability checks.
- Passing native runtime and extension integration checks, including permission filtering, profile isolation, native tab identity, cancellation, uninstall/reinstall, and shutdown.
- Repeatable UI acceptance for focus, retained accessibility, all drag paths, trackpad contact versus momentum, material changes, Peek/Split persistence, and restoration after relaunch.
- Provider and sync acceptance using explicitly configured services, with failures and interruption recovery exercised.
- Final packaged app validation, signing/distribution status, screenshots from the actual build, and an accurate version/readme.

Do not infer universal Chrome-extension compatibility from Chromium embedding or from successful extension installation alone. APIs that require unimplemented native window ownership must report their limitation, not expose hidden implementation windows or fabricate success.
