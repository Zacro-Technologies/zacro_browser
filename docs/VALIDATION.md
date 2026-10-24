# Validation record

Validated locally on Windows 11 x64 (OS build 26200), Node.js 24.19.0, Electron 45.0.0 and Chromium 156.0.8078.48. This record describes engineering verification of the development build, not commercial certification or a security audit.

Final 0.2.0 local run on **October 24, 2026: 74 unit/security tests, 30 desktop integration tests, 1 packaged-application test, and 1 lifecycle soak test passed** (106 total). The soak completed 120 cycles. Formatting, syntax, and Git whitespace checks passed. The installer was rebuilt from the final verified source, then its packaged application passed automated and native Computer acceptance checks.

## Automated checks

`npm run verify` runs formatting, syntax, unit/security tests and real Electron integration tests. Unit tests exercise navigation validation, graph integrity across randomized tab/Space operations, atomic session recovery, private-data exclusion, import privilege boundaries, filenames and rename races, provider protocols, encrypted credentials, cancellation, citation parsing and actual PDF parsing.

Desktop tests use separate temporary profiles and local HTTP fixture servers. They exercise actual Chromium navigation, back/forward, zoom, the command bar, themes, cookie and localStorage isolation, private-session restart, Peek preserving scroll/JavaScript state, promotion, native split views, downloads and rename/undo, and organization through UI controls. Security integration tests cover popup POST/session/sandbox behavior, privileged IPC sender rejection, unpacked-extension profile isolation and enable/disable/remove, unsaved-form decisions, hostile-page text extraction, PDF page citations, and HTTP authentication. They mock provider inference and native permission decisions, not Chromium page rendering or cookie storage.

Unsaved Peek regression tests cover cancellation and completion when creating a tab, changing Space, and replacing a preview. Navigation tests verify that choosing Stay preserves both the live document and its saved address when navigating to another page or returning to New Tab.

The 0.2 regressions additionally cover persistent user tab names, exact window restoration, IME composition, dialog focus isolation/return, F6, native Find focus, stable split-pane positions, panel search selection, native-view attachment, and real raster favicon decoding. Modal capture tests deliberately defer native capture until after the page is hidden, verify the real JPEG backdrop and immediate command focus, and exercise timeout, dismissal, destruction and private-profile cases. Permission tests hold a real Notification request open while the active tab or profile changes, then verify that a delayed Allow-and-remember response is rejected. Empty Current page AI requests cannot silently become hosted research.

Sampled light/dark text contrast meets the tested 4.5:1 threshold. Windows forced-colors and reduced-motion behavior are checked through Chromium media emulation in the real Electron shell, including a preference change while transitions are active. This is not an actual Windows contrast-theme or screen-reader certification.

`npm run test:package`, after `npm run pack` or `npm run dist`, verifies the built Windows executable's security fuses, launches that executable, navigates a real page, inspects its light/dark home screens, and closes it. It also loads the exact packaged PDF module and dependencies from `app.asar` in the same Electron runtime to verify the PDF worker and font resources. Main-process inspection remains disabled in the distributed binary.

`npm run test:soak` completed 120 repeated real tab/Peek/split lifecycles. Only the shell and retained original page remained after each cycle; the original draft and reading position survived, with no renderer errors. Observed process-memory totals rose from about 394 MiB initially to 796 MiB at the end, with the GPU process the largest contributor. Packaging ran concurrently during this final test. These short local observations establish lifecycle behavior, not a leak-free or long-running performance claim. Detailed samples are generated in `test-results/soak.json`.

`npm audit` reported zero known dependency vulnerabilities at validation time; this is not proof that vulnerabilities do not exist.

## Native Computer acceptance

The Computer plugin exercised the real Windows application in disposable profiles using a loopback journal fixture. The source-build pass covered page browsing and scrolling, a draft retained through tab/Space changes, link-context-menu Peek, a second draft retained through promotion, split-pane focus and a live counter, favorites, Space creation and color changes, history filtering, light/dark settings, F6, command-palette dismissal, and maximize/restore. Light/dark, command bar, settings and narrow-window screenshots were also inspected.

The final packaged executable was launched separately with `npm run test:interactive -- --packaged`. Computer verified real page rendering, the command palette's visual backdrop, dismissal, and the finished home screen. Windows' accessibility tree exposed the current page again after dismissal and excluded it while the dialog or New Tab was active. This confirms the tested native-view isolation, not full assistive-technology acceptance. Both interactive runs exited normally and their disposable profiles were removed.

The manual pass used UIA clicks/edits and F6/Escape. The Computer tool's Control-key delivery was inconsistent on this host; Control shortcuts were verified separately through Electron's actual keyboard-input integration tests. No AI credentials, paid inference, real messages or purchases were used in these tests.

## Distribution

`dist/win-unpacked/Zacro.exe` is the directly runnable build. `dist/Zacro-0.2.0-x64-Setup.exe` is a per-user Windows NSIS installer. Both are **unsigned development artifacts**; Windows Authenticode inspection returned `NotSigned` for both. The installer was generated; installation/uninstallation on a clean disposable Windows machine has not been certified. Generated binaries and validation screenshots are ignored by Git.

## Required further acceptance

- Live, explicitly funded OpenAI/Anthropic model and hosted-search tests; the automated suite makes no paid provider calls.
- Independent security review and prompt-injection/evidence-quality evaluation.
- Real-world long-running browsing, media/DRM, OAuth, accessibility/assistive technology and performance testing.
- Broader extension compatibility, full account/extension sync and service operation.
- Signed installer acceptance, automatic-update infrastructure, signature/rollback testing and release incident processes.
- macOS and Linux validation; only Windows was run here.

Local file navigation, native Arc database migration, a password manager, full Chrome extension APIs and Web Store installation, device pairing choosers, and managed default-browser registration are not implemented. Loaded pages are deliberately excluded from automatic archiving to protect live form state. See the [roadmap](ROADMAP.md) for remaining commercial release requirements and [AI documentation](AI.md) for supported context and provider boundaries.
