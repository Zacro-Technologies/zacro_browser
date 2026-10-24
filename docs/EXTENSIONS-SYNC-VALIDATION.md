# Extensions and sync validation

This is the development record for `extensions-and-sync`, based on the
[approved design](superpowers/specs/2026-10-25-extensions-and-sync-design.md).
It records observed results; it is not a claim that the feature is complete.

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

## Final gate record (in progress)

- Final formatting and JavaScript syntax checks passed. `npm test`: **215/215**
  passed after the live-event, Unicode grant and pending-update intent fixes.
- First `npm run verify`: formatting/syntax and **212/212** then-current Node
  checks passed; native **61/85** passed. All five complete two-desktop variants
  and extension/API/context/capability tests passed. The 24 failures comprise
  compact-layout (1), Mac keyboard (2), polish startup focus (20), and startup
  paint (1). Native diagnostics showed invisible-to-the-desktop page visibility
  and no focused window. Computer-use tooling then positively confirmed that
  the Mac was locked. The user has been asked to unlock it; these failures are
  not suppressed or reported as passed.
- Following the final bridge fix, focused native **8/8** passed: genuine stopped
  classic/module worker wake, MV2 lazy wake, MV2 idle-retirement race, immediate
  and gated first-listener notifications in both extension pages and isolated
  content scripts, and trusted-only suppression for content scripts.
- `npm run test:soak`: **1/1**, 40 cycles, passed. Only the shell and retained
  page remained after each cycle; the original draft and reading position
  survived. Median cycle 285ms, p95 578ms on this host. These timings are
  observations, not a cross-machine performance guarantee.
- `npm run pack:mac` passed for arm64. This is a local ad-hoc development build,
  not a Developer ID signed/notarized release. `npm run test:package`: **1/1**
  passed against its actual executable: security fuses, normal browsing, AI
  runtime startup, packaged PDF worker, packaged adapter dependencies/bootstrap,
  SQLite persistence and OS credential protection. Packaged clients rejected
  plaintext HTTP even with the development environment flag. The service and
  test-only package provider were absent from the ASAR.
- `npm audit --omit=dev`: zero reported production dependency vulnerabilities.
  This is not an independent security assessment.

Whole-branch review and unlocked-desktop reruns remain open. Windows and Intel macOS CI are configured but have not run for this
branch. Docker CLI is unavailable locally, so the service container build is
unverified. No public service, production deployment or release publication
was performed.
