# Representative extension provider acceptance

This opt-in online check complements the separate JSON Formatter provider test.
It launches the real app with disposable `ZACRO_USER_DATA`; normal unit/E2E tests
remain offline. It never logs into accounts or reads personal browser profiles.

```sh
node --test test/provider/representative-extensions.test.cjs
ZACRO_CUSTOM_ELECTRON=/absolute/path/to/Electron \
  ZACRO_REQUIRE_CUSTOM_ELECTRON=1 \
  node --test test/provider/representative-extensions.test.cjs
```

`ZACRO_CUSTOM_ELECTRON` selects a binary, but only the real profile session's
negotiated native ABI determines support. `ZACRO_REQUIRE_CUSTOM_ELECTRON=1` fails
if reviewed permissions, activeTab, userScripts or fontSettings are absent.
A stock denial does not satisfy demanded custom-runtime acceptance.

## Package and dependency pins

| Original provider package | Version        | ID                               | Original CRX SHA-256                                             |
| ------------------------- | -------------- | -------------------------------- | ---------------------------------------------------------------- |
| Dark Reader               | 4.9.133        | eimadpbcbfnmbkopoojfekhnkhdbieeh | ee38f20d1d50789f4b482c9a1a5dadab599b8682fd2a7dfb7de21fae8561b918 |
| React Developer Tools     | 8.0.0          | fmkadmapgofadopljbjfkapdkoienihi | d92e1122a16362cc5510927068a5b1a8d50b43e1f3be25c3117f7c005807b302 |
| uBlock Origin Lite        | 2026.1021.1354 | ddkjiahejlhfcafbddmgiahcphecmpfh | 0887559eb9e6864e91b52e4a0c660995ade47c084dcc7150ed9ae743c9475a76 |
| Bitwarden                 | 2026.10.0      | nngceckbapebfimnlniiiahkandclblb | f2feb7fc46d2550bef9b69af1cc358aea26b90a947645f9de16ec14d9296ef69 |

The test entrypoint adds a pre-install pin guard around the unchanged production
HTTPS downloader. That downloader verifies CRX developer identity and the Web Store
publisher proof. The guard checks the original bytes and extracted manifest
version before returning the download to managed installation. Version or hash
drift requires explicit review and fails closed. Managed `original.crx` is checked
again after installation. Task-owned investigation caches are never a fallback.

The React page acquires the official `react@18.3.1` and `react-dom@18.3.1` npm
archives afresh from `registry.npmjs.org`, with 30-second download bounds, pinned
byte sizes and SHA-512 integrity. Only integrity-verified development UMD members
are served by the disposable loopback server. No React hook is invented and no
production dependency is added. Pins match the task ledger's
`react-fixture-pack.json`.

## Core behaviors and limits

- Dark Reader: stock must show required `fontSettings` incompatibility without
  native activation. A complete negotiated custom runtime must inject original
  Dark Reader styles and change computed page appearance; disable and reload
  must restore the baseline appearance.
- React Developer Tools: genuine React state updates must work; the original
  extension must create its native Components, Profiler and Suspense panels and
  display the real `RepresentativeCounter` component tree. Optional
  `clipboardWrite` remains visibly unsupported. This is partial compatibility,
  not a claim that every developer tool works.
- uBOL: stock must show required `activeTab` and `userScripts` incompatibility
  without native activation. Custom positive acceptance uses the original,
  enabled `easylist` rule 19 (`/xpopup/xpopup.js`). Native blocking must prevent
  a loopback server hit; disabling the extension must allow the request again.
  No public ad endpoint, hostname map, replacement ruleset or rule mutation is
  used. Separate user-script opt-in behavior is covered by native contract tests,
  not claimed by this rule-blocking check.
- Bitwarden: both runtime kinds must show required unsupported clipboard,
  idle, notifications, webNavigation, webRequestAuthProvider, file-origin and
  sandbox requirements, and no native activation. No password-manager behavior,
  vault access or login is claimed.

Actual run evidence, failures and unrun custom gates are recorded below and
in the [combined validation record](EXTENSIONS-SYNC-VALIDATION.md).
The custom positive branches remain unvalidated until run on the compiled real
native binary; the presence of their assertions is not compatibility evidence.

## Measured stock run, 2026-10-26

On macOS arm64, Electron 45.0.0 / Chromium 156.0.8078.48 negotiated ABI version 0. The focused provider command passed 4/4 after real HTTPS acquisition:

| Provider              | Observed stock result                                                           | Custom positive gate               |
| --------------------- | ------------------------------------------------------------------------------- | ---------------------------------- |
| Dark Reader           | Visible required fontSettings denial; no native activation                      | Unrun                              |
| React Developer Tools | Real panels and component tree passed; optional clipboardWrite boundary visible | Unrun on custom binary             |
| uBOL                  | Visible required activeTab/userScripts denial; no native activation             | Local original-rule blocking unrun |
| Bitwarden             | Visible unsupported requirements; no native activation                          | Remains unsupported by design      |

The real uBOL package exposed a root-relative worker adaptation rejection. The
focused fix retains its original `/js/background.js` manifest spelling and
normalizes one slash only for safe derived file access and bootstrap import
calculation. Managed native classic and module worker regressions both passed,
including genuine relative imports, strict mode, native worker identity and
unchanged source/managed-original bytes. Ambiguous/foreign paths and package
symlinks remain rejected. The demanded custom run on stock correctly failed at
the native ABI gate; that expected failure is not positive custom evidence.
## PR preparation recheck, 2026-10-29

The initial online run after main 0.9 integration passed JSON Formatter 0.10.2.
React Developer Tools and Bitwarden matched their approved acquisition pins,
but their old fixtures attempted Library input behind the new first-run dialog.
Commit `c4c005c` opts out of unrelated onboarding and explicitly dismisses the
actual initial palette. It preserves all provider pins and behavior assertions.
The focused recheck passes **3/3**: React Developer Tools 8.0.0 renders its real
panels/component tree; JSON Formatter 0.10.2 formats the loopback JSON and opens
its real options; Bitwarden 2026.10.0 shows required-API incompatibility and is
not activated. The Bitwarden result is a denial check, not vault/login support.
See the [combined validation record](EXTENSIONS-SYNC-VALIDATION.md).

Dark Reader and uBOL failed the immutable original-archive check before activation.
Observed SHA-256 values were respectively
`864a7301c6841b34066c3537c12eab1c17a2f4cc8f27c5f05ece2b11b2615586` and
`6763ff30cb7b89bf3b411908c03674b5d4e98c12a38fbae776fd057d1a8d1837`.
These are observed changes, not newly approved pins or evidence of a changed
version number. No new package review or native positive acceptance is claimed.
The existing fixed hashes remain in place; a future provider run must review
those original packages before accepting replacements. Historical denial results
above do not certify the newly supplied archives.
