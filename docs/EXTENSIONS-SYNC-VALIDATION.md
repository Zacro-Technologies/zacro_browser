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
  selected Windows-only shortcut labels on macOS. A test-input correction is
  being validated separately; browser behavior assertions are retained.
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

This probe establishes a live distribution response and signature evidence
for this one package. It does not establish production downloader behavior,
archive safety, runtime compatibility, updates, or cross-device sync.
Downloaded third-party binaries remain in ignored validation scratch storage.
Normal unit tests must not depend on this external service.

## Acceptance still required

Track context transport, package/lifecycle, API, real service, two-client,
platform and packaged acceptance against section 8 of the approved design.
Only successful, reproducible checks belong in the completed record.
