# Extensions and sync validation

This is the development record for `extensions-and-sync`, based on the
[approved design](superpowers/specs/2026-10-25-extensions-and-sync-design.md).
Production implementation is committed through `cae78db`. After the Mac was
unlocked, the final full verification passed all 240 Node and 96 native checks.
Final packaged acceptance remains
incomplete because the rebuilt development app still waits for an OS Keychain
confirmation. The record below separates passing checks from open gates.

## Environment and baseline

Local checks began on 2026-10-25 (Asia/Hong_Kong) on Apple silicon, macOS
27.0.1, Node.js 24.22.1, and the pinned Electron 45.0.0 runtime.
The feature baseline is `978bfa0`; implementation plans are recorded at `b30853b`.

- Baseline formatting, syntax and 99 unit/security tests passed.
- `npm run test:mac` passed all 32 checks.
- The general desktop suite initially passed 47 of 52 checks. The five
  failures were in `polish.test.cjs`, which sent Windows Control shortcuts or
  selected Windows-only shortcut labels on macOS. Commit `cbd7a79` corrects
  platform input/labels and adds keyboard context-menu activation. After native
  app activation, the unchanged behavior assertions passed all 20 polish tests.
  The full feature run later hit an actual locked-desktop condition; see the final gate record below.
- Windows and Intel macOS feature-branch validation has not run locally.
  Earlier release CI results do not establish acceptance of this branch.

## Public provider probe

A manually invoked provider probe on 2026-10-25 downloaded Dark Reader
(`eimadpbcbfnmbkopoojfekhnkhdbieeh`, version 4.9.133, Manifest V3).
The official publisher's [download link](https://darkreader.org/) identifies
the store entry. The provider probe did not execute or install the package.

- Endpoint: `https://clients2.google.com/service/update2/crx`, with
  `response=redirect`, `prodversion=156.0.0.0`, `acceptformat=crx3`, and the
  requested extension ID.
- Observed route: `clients2.google.com` returned HTTP 302 to
  `clients2.googleusercontent.com`, which returned HTTP 200 over HTTPS.
- Original CRX: 851,022 bytes, SHA-256
  `ee38f20d1d50789f4b482c9a1a5dadab599b8682fd2a7dfb7de21fae8561b918`.
- CRX3 signed extension ID and developer-key-derived ID matched the request.
  RSA developer proof and the production ECDSA publisher proof verified over
  the signed data and archive. Publisher-key SHA-256:
  `61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf`.

The initial probe established the distribution response and signatures only.
The production downloader subsequently verified, extracted and adapted that
package. Its required alarms/fontSettings APIs remain unsupported, so it was
not activated. Archive safety and lifecycle behavior have separate malicious
fixture suites; successful extraction alone does not establish those properties.
Downloaded third-party binaries remain in ignored validation scratch storage.
Normal unit tests must not depend on this external service.

## Implemented checkpoints

- Extension acquisition/lifecycle checkpoint `2e2abfd`: 43 focused checks passed,
  including signed IDs/publisher rejection, hostile archives, update permissions,
  rollback, interrupted operations, stale cancellation and scheduler stop/restart.
- Browser API checkpoint `12fdd3d`: 204 Node checks passed in the shared checkout;
  68 focused API/package/manager checks passed. The native context/API/capability
  batch passed 18 checks, including intentionally negative engine probes, followed
  by a final 4-test native API/grant rerun. Review found background wake, relative URL, narrower host-grant and menu-state
  defects. Commits `0c29500` and `ab06271` fix these and subsequent live-event/Unicode
  regressions with failing-before/passing-after tests. Final scoped review approved both fixes with no remaining material findings.
- The real Node/SQLite service and desktop client cover account/device lifecycle,
  encrypted persistence, restore/deletion ledger, ownership, stale generations,
  offline merges, quota rejection, token replay and settings download consent.
  The latest parent-only store/security/sync/host-projection group passed 70 checks.
- Full-main Electron controls passed action/options views, genuine tab CRUD and
  getCurrent, native keyboard dispatch, composed context-menu click delivery,
  storage events, badges, profile cleanup and the visible store-install form.
- Stable native tab identities survive New Tab; restored background pages make
  no network request until opened. Existing unsaved-navigation cancellation passes.
- A real legacy migration/backup reproduction resurrected a removed extension.
  Durable imported-ID receipts fixed it; the focused two-launch test now passes,
  without deleting the user's original browser recovery files.

## Two complete desktop installations

`test/e2e/extensions-sync.test.cjs` runs two isolated product instances against
one actual HTTP/SQLite service using native OS credential protection. All five
background variants passed: MV3 classic/module workers, persistent MV2
scripts/HTML pages, and a lazy MV2 event page. The lazy case first observes zero
native background contexts, then uses a real service setting change to wake it. Each uses genuine background, options, popup and content
script APIs, including accepted remote change notifications.

The flows cover per-device installation approval and refusal; settings staying
local until separate consent; independent offline writes; browser/server restart;
extension disable/enable/remove convergence; and device revocation. The module
variant additionally reproduces merged server-quota rejection, retains the
unsynced local values, exports them and discards them explicitly.

Only these deterministic fixtures' verified package acquisition boundary is
substituted with a developer-signed synthetic CRX. The normal production
publisher verifier rejects that synthetic publisher. There is no substitute
service, storage implementation, or extension API. Live publisher/package
acceptance below is separate, and no production test IPC was introduced.

## Native execution evidence

These rows summarize demonstrated execution contexts. The API method boundary
is listed separately in [Extensions](EXTENSIONS.md); a row does not imply every
Chrome API works in that context.

| Context | Demonstrated behavior | Principal fixture |
| --- | --- | --- |
| MV3 classic and module workers | Authenticated adapter calls, native messaging, sync events, genuine stop then native wake with command/settings delivery | `extension-api.test.cjs`, `extension-context.test.cjs` |
| MV2 persistent scripts and full HTML background | Original entry paths, native-runtime facade, storage/API calls and genuine two-product sync | `extension-context.test.cjs`, `extensions-sync.test.cjs` |
| MV2 lazy event page | Native context count reaches zero, then host command or real remote settings change wakes it; idle-retirement notification arrives once | `extension-capabilities.test.cjs`, `extensions-sync.test.cjs` |
| Own extension pages, options and action popup | Real sync API, tab identity/relative URLs, action/options UI and events | `extension-api.test.cjs`, `extensions-sync.test.cjs` |
| Isolated content contexts | Static, registered dynamic and programmatic bootstrap; permitted sync calls, immediate first listener and trusted-only exclusion | `extension-context.test.cjs`, `extension-api.test.cjs`, `extension-events.test.cjs` |
| Untrusted or obsolete senders | Ordinary page/main world excluded; forged identity, old document challenge, disable/profile/generation and delayed access changes rejected | `extension-context.test.cjs`, `extension-api.test.cjs` |

All files are under `test/e2e/`. Genuine native permission tests verify a narrowed
optional host after grant, restart and removal, including denial on a separate
loaded host and preservation of an unsaved page. The final rollback regression additionally proves that revoked optional
scripting/network access stays denied after both enabled rollback and disabled
rollback followed by enable.

## Representative public packages

All originals below were fetched over the production HTTPS path and verified
with the production publisher key. Version/hash details identify observations,
not a promise about later store versions. Packages remain in ignored scratch;
third-party source is not redistributed in this repository.

| Sample | Version | Current result |
| --- | --- | --- |
| JSON Formatter, `bcjindcccaagfpapjjmafapmmgkkhgoa` | 0.10.2 | Production acquisition, native JSON formatting, options and packaged icon passed in the actual browser. It uses native local preferences; those stay local. |
| Dark Reader, `eimadpbcbfnmbkopoojfekhnkhdbieeh` | 4.9.133 | Verified/extracted/adapted; required alarms/fontSettings prevent activation. |
| React Developer Tools, `fmkadmapgofadopljbjfkapdkoienihi` | 8.0.0 | Verified/extracted; devtools_page prevents activation. |
| uBlock Origin Lite, `ddkjiahejlhfcafbddmgiahcphecmpfh` | 2026.1021.1354 | Verified/extracted; DNR, offscreen, userScripts, alarms and native activeTab are unsupported. |
| Bitwarden, `nngceckbapebfimnlniiiahkandclblb` | 2026.10.0 | Verified/extracted; required offscreen/sidePanel and other engine capabilities are unsupported. |

Original SHA-256 digests:

- JSON Formatter (20,840 bytes): `5e0ebde71ee60f997a9f5fc0850e6ae4a9f67006dbf662f00507f99e957c2b21`.
- React Developer Tools (670,658 bytes): `d92e1122a16362cc5510927068a5b1a8d50b43e1f3be25c3117f7c005807b302`.
- uBlock Origin Lite (9,172,092 bytes): `0887559eb9e6864e91b52e4a0c660995ade47c084dcc7150ed9ae743c9475a76`.
- Bitwarden (24,875,732 bytes): `f2feb7fc46d2550bef9b69af1cc358aea26b90a947645f9de16ec14d9296ef69`.

Run `npm run test:provider` for the separate, explicit online JSON Formatter
acceptance. It uses normal product installation and the real production verifier,
with a disposable profile and a local JSON page. It approves only the pinned
manifest version. A changed version requires fresh review. No personal browsing
profile or real external account is used.

## Final local gate record

- Final formatting and JavaScript syntax checks passed. `npm test`: **240/240**
  passed after the lifecycle fixes and final active-profile deletion amendment.
- First `npm run verify`: formatting/syntax and **212/212** then-current Node
  checks passed; native **61/85** passed. All five complete two-desktop variants
  and extension/API/context/capability tests passed. The 24 failures comprise
  compact-layout (1), Mac keyboard (2), polish startup focus (20), and startup
  paint (1). Native diagnostics showed invisible-to-the-desktop page visibility
  and no focused window. Computer-use tooling then positively confirmed that
  the Mac was locked. The user subsequently unlocked it; see the later full-run
  results below. The original failed run is retained as historical evidence.
- The first unlocked `npm run verify` passed formatting/syntax and **240/240**
  Node checks, with **94/96** native checks passing. The old focus/paint failures
  passed. Two stale test expectations failed: Settings still expected four
  disclosures after Account & sync added a fifth, and one notification test
  still counted only worker filtering after live-frame delivery was added.
  The tests now assert all five named sections and keyboard operation, and the
  exact permission-check context/timing for the live frame and queued worker.
  The focused rerun passed **2/2**. Independent review found no actionable
  findings and confirmed the behavior/security assertions remain intact.
- The final unlocked `npm run verify` exited **0** after those test corrections:
  formatting/syntax passed, **240/240** Node checks passed, and **96/96** native
  checks passed, with no failures, cancellations or skipped tests. The native
  suite completed in 235.36 seconds. It includes all five complete two-browser
  variants, the corrected assertions, native focus and startup painting. No
  production source changed after the reviewed `cae78db` implementation, so
  the existing final-source build and soak results still apply. Reviewed test
  corrections and bounded package-process cleanup are committed at `fbb705a`.
- Following the final bridge fix, focused native **8/8** passed: genuine stopped
  classic/module worker wake, MV2 lazy wake, MV2 idle-retirement race, immediate
  and gated first-listener notifications in both extension pages and isolated
  content scripts, and trusted-only suppression for content scripts.
- `npm run test:soak`: **1/1**, 40 cycles, passed. Only the shell and retained
  page remained after each cycle; the original draft and reading position
  survived. The post-review rerun passed again: median cycle 277ms, p95 285ms on this host. These timings are
  observations, not a cross-machine performance guarantee.
- `npm run pack:mac` passed again for the final arm64 source. Exact source bytes
  for seven affected modules match the ASAR; all six configured security fuses
  pass inspection. This is an ad-hoc development build, not a Developer ID
  signed/notarized release.
- The earlier `fc4a901` package passed **1/1** actual executable acceptance:
  security fuses, normal browsing, AI runtime startup, packaged PDF worker,
  adapter dependencies/bootstrap, SQLite persistence and OS credential
  protection; plaintext sync HTTP rejected; service/test-only provider absent.
  **The final rebuilt executable has not passed this gate.** Its rerun stalled
  before the first local page loaded. Narrow macOS `securityd` diagnostics
  explicitly show a pending “Zacro Safe Storage” access confirmation for the
  rebuilt app. Its ad-hoc CDHash differs from the existing Keychain ACL's
  requirement. After the user unlocked the Mac, an explicit interactive rerun
  still timed out at the same first-navigation assertion after 305 seconds;
  **0/1** passed. The user subsequently reported that no confirmation dialog
  was visible. An OS log saying it requested a prompt is not evidence that the
  user can see or answer that prompt.
  A fresh retry after that report also failed **0/1** at the unchanged
  305-second navigation deadline. The exact new process again generated the
  OS confirmation request; its user ID matched the console login, and normal
  app activation/tab selection did not unblock navigation. The disposable
  process was closed by test cleanup. Why no confirmation appeared remains
  unresolved; no packaged success is claimed.
  This run did not establish packaged browsing or the later executable checks.
  No Keychain item, credential or OS protection was changed. A disposable
  browser profile does not isolate the app-scoped Keychain encryption key.
  Test cleanup now waits for its own disposable process to exit before deleting
  the temporary profile; the blocked run ended without leaving that process.
- The final full-product native file passed **9/9**, including all five
  two-Electron variants, against the actual service and OS-protected credentials.
  The review-fix native group passed **6/6**; the final active-profile deletion
  amendment passed **3/3** (one overlaps that group), including interrupted
  deletion and retry. These are programmatic native/product checks, not a
  substitute for physical keyboard/focus/paint acceptance.
- `npm audit --omit=dev`: zero reported production dependency vulnerabilities.
  This is not an independent security assessment.

Whole-branch review identified eight material lifecycle defects. Fixes in
`21d632a` and `cae78db` cover rollback authority, consent/refresh races, repeated
tab IDs, stale missing-dataset responses, restored commands, dataset deletion
across backup restoration, local-profile deletion through asynchronous teardown,
and warnings for scripts remaining after uninstall. Each has a reproduced
failure and passing regression. The independent scoped rereview approved all eight fixes at `cae78db`, with no
remaining code findings. This approval does not certify the open platform gates. Windows and Intel macOS CI are configured but have not run for this
branch. Docker CLI is unavailable locally, so the service container build is
unverified. No public service, production deployment or release publication
was performed.

Implementation choices and their costs are recorded in [the decision record](EXTENSIONS-SYNC-DECISIONS.md).

## Resume packaged acceptance

The user reports no visible confirmation dialog. Treat the gap between the
OS confirmation request and a visible dialog as unresolved, not simply an
unanswered approval request.
The current app has an intact ad-hoc signature (`codesign --verify --deep
--strict` passes), but its CDHash differs from the stored Keychain requirement.
[Electron's code-signing documentation](https://www.electronjs.org/docs/latest/tutorial/code-signing#macos-apis-that-require-code-signing)
describes inconsistent Keychain behavior with ad-hoc signatures and recommends
consistent signing for both safeStorage and cookie encryption. This supports
the signature diagnosis; it does not establish why this particular dialog is
absent or prove that a newly signed release fixes it. The repository already
has a separate Developer ID/notarized release path; it has not been executed.

For the final packaged executable, keep the Mac unlocked and run
`ZACRO_INTERACTIVE_KEYCHAIN=1 npm run test:package`. This explicit local mode
allows five extra minutes for the user to review and handle the genuine macOS
“Zacro Safe Storage” confirmation. It does not approve the dialog or skip any
assertion. The ordinary `npm run test:package` keeps its original deadlines.
Rebuilding an ad-hoc app can change its signature again;
never delete the Keychain entry or disable encryption/fuses just to bypass this
gate. The final local artifact is `dist/mac-arm64/Zacro.app`.
