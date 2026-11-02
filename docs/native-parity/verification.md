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

## Required release evidence

- Successful custom Chromium build and package provenance; native protocol capability checks.
- Passing native runtime and extension integration checks, including permission filtering, profile isolation, native tab identity, cancellation, uninstall/reinstall, and shutdown.
- Repeatable UI acceptance for focus, retained accessibility, all drag paths, trackpad contact versus momentum, material changes, Peek/Split persistence, and restoration after relaunch.
- Provider and sync acceptance using explicitly configured services, with failures and interruption recovery exercised.
- Final packaged app validation, signing/distribution status, screenshots from the actual build, and an accurate version/readme.

Do not infer universal Chrome-extension compatibility from Chromium embedding or from successful extension installation alone. APIs that require unimplemented native window ownership must report their limitation, not expose hidden implementation windows or fabricate success.
