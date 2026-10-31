# Zacro Native for macOS

This directory contains the Swift rewrite on `swift-rewrite`. It is **in progress, not a feature-complete replacement** for the Electron browser. Chromium and Chrome extension compatibility are requirements, not optional follow-ups. See the [migration and acceptance contract](../docs/SWIFT-REWRITE.md).

## Build

Requires Xcode, Swift 6, and macOS 14 or later. The current tested target is Apple silicon.

```sh
swift build --package-path macos
swift test --package-path macos
bash macos/scripts/build-app.sh
```

The bundle is `macos/dist/Zacro Native.app`. The build plugin downloads the pinned CEF archive and verifies its digest. Binaries/build products are ignored by Git. Development bundles are ad hoc signed, not notarized. Normal browsing uses the Chromium sandbox and macOS Keychain; no mock-keychain fallback is permitted for real profiles.

Native state is stored separately in `~/Library/Application Support/Zacro Native`. Import Electron collection JSON explicitly through Library → Settings. The importer does not modify the original profile or copy cookies, passwords, extension storage, or authentication tokens.

## Implementation

- `ZacroCore`: validated state, atomic persistence, profile privacy boundaries, saved tabs, Spaces, folders, splits, Peek, navigation stacks, Library records, settings, and explicit legacy import.
- `ZacroApp`: SwiftUI/AppKit interface, native palette and Peek overlay panels, gestures, theme controls, haptics, site controls, menu/shortcut handling, and browser lifecycle coordination.
- `ZacroChromium`: Chrome-runtime-only CEF integration. Each page retains an independent native Chromium child window because CEF permits only one Chrome-style browser view per window. No Alloy or WebKit fallback.
- `Engine/CefSwift`: pinned third-party source with documented Zacro patches and original licenses. Website content has no privileged application bridge.

## Validation and remaining work

Core persistence tests and upstream profile/handler tests pass. Native source builds and the ad hoc app signature verify. The disposable packaged engine test passes four independent Chrome documents, shared same-profile storage, separate/private profile isolation, and retained hidden-page state. Broader packaged runtime acceptance is still incomplete: ordinary persistent profiles encounter a macOS Keychain authorization prompt. UI lifecycle, fullscreen, physical trackpad behavior, extension installation/actions/service workers, and retained page state require packaged acceptance.

The custom installed/pinned extension interface is not implemented: the current CEF API does not expose the needed extension enumeration to this host. The current native controls open Chromium's real extension manager, store, and native extension menu. This is not evidence that every Chrome extension works.

The native AI providers, account sync, full download controls, sleep policy, advanced permissions persistence, and complete extension lifecycle/settings migration have not yet been ported. The existing Electron implementation remains the feature reference. Do not remove it or mark the rewrite complete while these requirements remain open.

## Disposable engine acceptance

`--engine-acceptance` is a test-only entry point requiring a fresh empty direct child of the system temporary directory named `zacro-native-acceptance-*` and a credential-free loopback HTTP fixture. Only that entry point selects mock cookie encryption; the Chromium sandbox stays enabled. It tests independently retained Chrome documents and persistent/private context isolation without authorizing access to the user's Keychain. It does **not** validate production cookie encryption or extension compatibility.

After a force-terminated development run, pass `-ApplePersistenceIgnoreState YES` to prevent AppKit’s unrelated window-restoration dialog from blocking the test event loop.

Set `ZACRO_NATIVE_DATA`, `ZACRO_NATIVE_SMOKE_URL`, and `ZACRO_ACCEPTANCE_OUTPUT` for the packaged executable. A JSON `passed: false` or missing report is a failure, regardless of the process exit code.

The same isolated mode accepts `--native-ui-review` to exercise the full Swift interface against the local fixture. Native input review confirmed command-palette opening, new-tab submission, retained tab results, and theme editor presentation/dismissal. It does not waive the remaining parity or production Keychain requirements.
