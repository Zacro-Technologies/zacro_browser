# Zacro Native for macOS

This directory contains the Swift rewrite on `swift-rewrite`. It is **in progress, not a feature-complete replacement** for the Electron browser. Chromium and Chrome extension compatibility are requirements, not optional follow-ups. See the [migration and acceptance contract](../docs/SWIFT-REWRITE.md).

## Build

Requires Xcode, Swift 6, and macOS 14 or later. The current tested target is Apple silicon.

```sh
swift build --package-path macos
swift test --package-path macos
bash macos/scripts/build-app.sh --runtime-build /path/to/Release_GN_arm64/zacro-runtime-build.json
```

The bundle is `macos/dist/Zacro Native.app`. Packaging requires a completed custom Chromium framework and its matching build receipt; it verifies the pinned revisions, native adapters, framework and resources. See the [engine build instructions](Engine/README.md). `--stock-runtime` creates a diagnostic app without the native extension integration. Binaries/build products are ignored by Git. Development bundles are ad hoc signed, not notarized. Normal browsing uses the Chromium sandbox and macOS Keychain; no mock-keychain fallback is permitted for real profiles.

Native state is stored separately in `~/Library/Application Support/Zacro Native`. Import Electron collection JSON explicitly through Library → Settings. The importer does not modify the original profile or copy cookies, passwords, extension storage, or authentication tokens.

## Implementation

- `ZacroCore`: validated state, atomic persistence, profile privacy boundaries, saved tabs, Spaces, folders, splits, Peek, navigation stacks, Library records, settings, and explicit legacy import.
- `ZacroApp`: SwiftUI/AppKit interface, native palette and Peek overlay panels, gestures, theme controls, haptics, site controls, menu/shortcut handling, and browser lifecycle coordination.
- `ZacroChromium`: Chrome-runtime-only CEF integration. Each page retains an independent native Chromium child window because CEF permits only one Chrome-style browser view per window. No Alloy or WebKit fallback.
- `ZacroServices`: AI connections, selected page/PDF context, account sync, durable extension-sync review and navigation-history storage. The app coordinates native downloads, permissions and extension management with the engine.
- `Engine/CefSwift`: pinned third-party source with documented Zacro patches and original licenses. Website content has no privileged application bridge.

## Validation and remaining work

Completed suites include 263 Core/Services tests, 51 custom-engine checks, 28 Peek checks, 33 navigation checks, 11 real tab-capture checks, 11 scoped renderer accessibility checks, seven sidebar accessibility checks, nine window-transfer checks, and sixteen download-retirement checks. The latest packaged popup ownership checks pass, but an open popup exposed a shutdown lifetime defect. Side panels now open in the correct logical window; retention when the page fails still needs correction. Full custom application/extension acceptance and new live tab-recovery cases remain incomplete. The earlier stock-engine checkpoint passed all 243 application checks, but does not validate native extension support. See the verification record for exact builds, partial runs and failures.

The native Extensions Library, pinned actions, settings synchronization, browser API adapters and Chromium consent integration are implemented in source. The complete custom framework has built and passed receipt validation; its packaged real-extension fixtures must still pass before the integration can be accepted. Google token APIs and third-party native hosts also have [external compatibility requirements](../docs/native-parity/compatibility-boundaries.md); universal extension compatibility is not established.

Desktop pointer/trackpad, VoiceOver, visual animation and performance review, production Keychain behavior, signed distribution and notarization remain required. The Electron implementation remains the feature reference. See the [current verification record](../docs/native-parity/verification.md) and [parity contract](../docs/SWIFT-REWRITE.md).

## Disposable engine acceptance

`--engine-acceptance` is a test-only entry point requiring a fresh empty direct child of the system temporary directory named `zacro-native-acceptance-*` and a credential-free loopback HTTP fixture. Only that entry point selects mock cookie encryption; the Chromium sandbox stays enabled. It tests independently retained Chrome documents and persistent/private context isolation without authorizing access to the user's Keychain. It does **not** validate production cookie encryption or extension compatibility.

After a force-terminated development run, pass `-ApplePersistenceIgnoreState YES` to prevent AppKit’s unrelated window-restoration dialog from blocking the test event loop.

Set `ZACRO_NATIVE_DATA`, `ZACRO_NATIVE_SMOKE_URL`, and `ZACRO_ACCEPTANCE_OUTPUT` for the packaged executable. A JSON `passed: false` or missing report is a failure, regardless of the process exit code.

The same isolated mode accepts `--native-ui-review` to exercise the full Swift interface against the local fixture. Native input review confirmed command-palette opening, new-tab submission, retained tab results, and theme editor presentation/dismissal. It does not waive the remaining parity or production Keychain requirements.

After bundling, run the engine check and full custom-runtime application check:

```sh
python3 -B macos/scripts/check-app.py
python3 -B macos/scripts/check-app.py --integration --require-extensions
```

Both require a successful native report and a clean process exit, so a shutdown crash fails validation. Reports are saved under `macos/dist/acceptance`. AppKit view renders verify their captured native views only; they do not capture composed Chromium windows or establish physical-input acceptance.
