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

## Required release evidence

- Successful custom Chromium build and package provenance; native protocol capability checks.
- Passing native runtime and extension integration checks, including permission filtering, profile isolation, native tab identity, cancellation, uninstall/reinstall, and shutdown.
- Repeatable UI acceptance for focus, retained accessibility, all drag paths, trackpad contact versus momentum, material changes, Peek/Split persistence, and restoration after relaunch.
- Provider and sync acceptance using explicitly configured services, with failures and interruption recovery exercised.
- Final packaged app validation, signing/distribution status, screenshots from the actual build, and an accurate version/readme.

Do not infer universal Chrome-extension compatibility from Chromium embedding or from successful extension installation alone. APIs that require unimplemented native window ownership must report their limitation, not expose hidden implementation windows or fabricate success.
