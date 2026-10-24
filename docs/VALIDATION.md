# Validation record

Validated locally on Windows 11 x64 (OS build 26200), Node.js 24.19.0, Electron 45.0.0 and Chromium 156.0.8078.48. This record describes engineering verification of the development build, not commercial certification or a security audit.

The initial 0.3 validation passed **90 unit/security tests, 38 desktop integration tests, one packaged-application test and one lifecycle soak test: 130 tests total**, plus formatting and syntax checks, on October 24, 2026. The desktop total includes the plain-window native-paint regression. That soak completed 40 cycles.

The subsequent sidebar Space-scroll change passed `npm run verify`: **90 unit/security tests and 41 desktop integration tests**, plus formatting and syntax. Three new regressions cover native horizontal wheel input, directional/reduced motion, page identity and draft retention, per-Space tab-list scroll, intent thresholds, momentum, direction changes, wheel delta modes, Shift-wheel, profile boundaries, and interrupted gestures. A native Computer pass on the development application confirmed forward/back switching, the final-Space edge stop, and unchanged Space selection when scrolling over a webpage. The packaged and soak results below refer to the initial 0.3 build.

The macOS integration passed local Windows verification: **98 unit/security tests, 42 desktop tests, and one rebuilt-package test**, plus formatting and syntax. Six Darwin-only native integration tests explicitly skipped on Windows; the simulated Mac renderer check is not native macOS acceptance. CI now defines separate Apple silicon and Intel jobs for source/unit checks, Mac behavior, development DMG/ZIP generation and packaged acceptance. Native runner results remain pending; no signed/notarized Mac artifact or physical Mac review has been completed. See [macOS validation and release steps](MACOS.md).

The 0.3 checks cover compact tab density, native page bounds with the sidebar hidden, page-field focus and draft preservation, Library navigation and return focus, home-shortcut deduplication, Settings disclosure state, short motion and immediate dismissal, and the subscription connection UI/protocol. Account-change, cancellation and filename-stream regressions protect the AI lifecycle.

The previous 0.2.0 baseline passed 74 unit/security tests, 30 desktop integration tests, one packaged-application test and a 120-cycle lifecycle soak. That earlier run is historical context, not a substitute for 0.3 verification.

## Automated checks

`npm run verify` runs formatting, syntax, unit/security tests and real Electron integration tests. Unit tests exercise navigation validation, graph integrity across randomized tab/Space operations, atomic session recovery, private-data exclusion, import privilege boundaries, filenames and rename races, Codex app-server protocol restrictions, credential isolation, cancellation, citation parsing and actual PDF parsing.

Desktop tests use separate temporary profiles and local HTTP fixture servers. They exercise actual Chromium navigation, back/forward, zoom, the command bar, themes, cookie and localStorage isolation, private-session restart, Peek preserving scroll/JavaScript state, promotion, native split views, downloads and rename/undo, and organization through UI controls. Security integration tests cover popup POST/session/sandbox behavior, privileged IPC sender rejection, unpacked-extension profile isolation and enable/disable/remove, unsaved-form decisions, hostile-page text extraction, PDF page citations, and HTTP authentication. They mock provider inference and native permission decisions, not Chromium page rendering or cookie storage.

Unsaved Peek regression tests cover cancellation and completion when creating a tab, changing Space, and replacing a preview. Navigation tests verify that choosing Stay preserves both the live document and its saved address when navigating to another page or returning to New Tab.

The 0.2 regressions additionally cover persistent user tab names, exact window restoration, IME composition, dialog focus isolation/return, F6, native Find focus, stable split-pane positions, panel search selection, native-view attachment, and real raster favicon decoding. Modal capture tests deliberately defer native capture until after the page is hidden, verify the real JPEG backdrop and immediate command focus, and exercise timeout, dismissal, destruction and private-profile cases. Permission tests hold a real Notification request open while the active tab or profile changes, then verify that a delayed Allow-and-remember response is rejected. Empty Current page AI requests cannot silently become hosted research.

Sampled light/dark text contrast meets the tested 4.5:1 threshold. Windows forced-colors and reduced-motion behavior are checked through Chromium media emulation in the real Electron shell, including a preference change while transitions are active. This is not an actual Windows contrast-theme or screen-reader certification.

The native-paint regression launches a plain visible foreground window and checks page animation frames before capture. Nine checks cover shell rendering, initial navigation, new/restored tabs, Peek creation/dismissal, overlay dismissal and resizing. Its visible, unoccluded window is a test precondition; the check verifies frame progress and rendered page pixels across native-view transitions.

`npm run test:package`, after `npm run pack` or `npm run dist`, verifies the built Windows executable's security fuses, launches that executable, navigates a real page, inspects its light/dark home screens, and closes it. It also loads the exact packaged PDF module and dependencies from `app.asar` in the same Electron runtime to verify the PDF worker and font resources. The 0.3 packaged check additionally starts the bundled Codex runtime with an isolated, signed-out profile and verifies its account handshake. This does not test sign-in or inference. Main-process inspection remains disabled in the distributed binary.

The final 0.3 `npm run test:soak` run completed 40 repeated real tab/Peek/split lifecycles. Only the shell and retained original page remained after each cycle; the original draft and reading position survived, with no renderer errors. Observed process-memory totals rose from 468,888 KiB to 696,228 KiB (about 458 to 680 MiB). The complete test-cycle duration had a 334ms median and a 365ms 95th percentile; these are lifecycle-test timings, not general browser interaction latency. Packaging did not run concurrently. These short local observations establish lifecycle behavior, not a leak-free or long-running performance claim. Detailed samples are generated in `test-results/soak.json`.

`npm audit` reported zero known vulnerabilities across production and development dependencies at validation time; this is not proof that vulnerabilities do not exist.

The real bundled Codex runtime passed an isolated signed-out account handshake and an authentication-start/cancel smoke check. The latter validated the official authorization URL without opening a browser, using credentials, completing sign-in or submitting a model request. Protocol tests use controlled transport responses. Live subscription entitlement and inference remain unverified until the user completes authentication.

## Native Computer acceptance

The final 0.3 packaged application was exercised through actual Computer input and native window capture in a disposable showcase profile. The pass covered sidebar hide/show, light/dark appearance through the native combobox, New tab, a link's context-menu Peek and Escape dismissal, split selection and closing, command-palette search and dismissal, Library bookmarks, and Ask Zacro's Connect Codex route to Settings. Settings displayed ChatGPT sign-in with no API-key fields. All nine README screenshots were refreshed from this final build and visually reviewed; the Computer pointer highlight remains visible in the original captures. No browser-protocol input driver was used for this final manual pass.

The refreshed nine-page PDF guide uses the same final screenshots. Every page was rendered with Poppler and visually inspected, with document text, image presence and page count also checked. Screenshots demonstrate still interface states; motion was exercised through the application and integration checks.

The 0.2 baseline Computer review exercised the real Windows application in disposable profiles using a loopback journal fixture. Its source-build pass covered page browsing and scrolling, a draft retained through tab/Space changes, link-context-menu Peek, a second draft retained through promotion, split-pane focus and a live counter, favorites, Space creation and color changes, history filtering, light/dark settings, F6, command-palette dismissal, and maximize/restore. Light/dark, command bar, settings and narrow-window screenshots were also inspected.

That baseline's packaged executable was launched separately with `npm run test:interactive -- --packaged`. Computer verified real page rendering, the command palette's visual backdrop, dismissal, and the home screen. Windows' accessibility tree exposed the current page again after dismissal and excluded it while the dialog or New Tab was active. This confirms the tested native-view isolation, not full assistive-technology acceptance. Both interactive runs exited normally and their disposable profiles were removed.

The baseline pass used UIA clicks/edits and F6/Escape. Control-key delivery was inconsistent on this host, so Control shortcuts were verified separately through Electron's actual keyboard-input integration tests. Neither manual pass used AI credentials, authenticated inference, real messages or purchases. The final pass did not complete ChatGPT sign-in.

## Distribution

`dist/win-unpacked/Zacro.exe` is the directly runnable build. `dist/Zacro-0.3.0-x64-Setup.exe` is a per-user Windows NSIS installer. Both are **unsigned development artifacts**; Windows Authenticode inspection returned `NotSigned` for both. The installer was generated and packaged acceptance passed; installation/uninstallation on a clean disposable Windows machine has not been certified. Generated binaries are ignored by Git; the curated README screenshots are tracked under `docs/screenshots/`.

## Required further acceptance

- Live ChatGPT sign-in and Codex subscription acceptance, including account/model access, hosted-search evidence, cancellation and limits. This requires the user to complete authentication; automated tests make no live inference calls and do not use personal credentials.
- Independent security review and prompt-injection/evidence-quality evaluation.
- Real-world long-running browsing, media/DRM, OAuth, accessibility/assistive technology and performance testing.
- Broader extension compatibility, full account/extension sync and service operation.
- Signed installer acceptance, automatic-update infrastructure, signature/rollback testing and release incident processes.
- Successful native macOS CI on Apple silicon and Intel plus physical-device acceptance and signed/notarized installation checks. Linux validation remains open. Only Windows was run in this local development session.

Local file navigation, native Arc database migration, a password manager, full Chrome extension APIs and Web Store installation, device pairing choosers, and managed default-browser registration are not implemented. Loaded pages are deliberately excluded from automatic archiving to protect live form state. See the [roadmap](ROADMAP.md) for remaining commercial release requirements and [AI documentation](AI.md) for supported context and provider boundaries.
