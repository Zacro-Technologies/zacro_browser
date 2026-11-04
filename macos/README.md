# Zacro Native for macOS

Zacro's native macOS edition pairs a custom Swift interface with Chromium. Organize browsing in Spaces, keep Favorites and pinned tabs close, compare pages in saved split views, and open links in Peek without losing your place.

The native interface includes the command palette, website search, offline tab icons, theme controls, Library, downloads, permissions, AI and sync settings, and Chrome extension management, actions and side panels. Google is the default search engine; the default page spacing is 4px. The Electron browser remains the behavior and design reference while native acceptance is completed.

## Build and run

Requires Xcode, Swift 6, and macOS 14 or later. The current tested target is Apple silicon.

```sh
bash macos/scripts/build-app.sh --runtime-build /path/to/Release_GN_arm64/zacro-runtime-build.json
open "macos/dist/Zacro Native.app"
```

Build the pinned custom Chromium framework first using the [engine instructions](Engine/README.md). Packaging verifies its matching receipt, native adapters and resources. Development bundles are ad hoc signed, not notarized. Normal browsing uses Chromium's sandbox and macOS Keychain.

Native state is stored separately in `~/Library/Application Support/Zacro Native`. Import Electron collection JSON explicitly through Library → Settings. The importer does not modify the original profile or copy cookies, passwords, extension storage, or authentication tokens.

## Validation

The latest completed Core/Services run passed 321 tests. Build 61's native extension suite passed all 306 checks with normal application exit. Focused interface, navigation, restoration, window-transfer and accessibility checks also passed; the verification record gives exact builds and coverage. The updated custom framework 66 has passed provenance validation.

Build 70 passed 10 media checks, 28 extension-host checks and 71 independent engine/window/accessibility checks, all with normal exits. The pane-edge and motion changes passed 155 focused checks in 68 and actual visual review. Full 70 attempts stopped at foreground readiness; full-application acceptance remains open. The delivered `dist` apps remain build 40.

Desktop review confirmed the corrected pane contour, live tinted content beneath Peek, expansion retaining its draft, content-only mode, Unsplit, Favorite/pin/folder creation and saved themes. Physical drag/trackpad, VoiceOver, production Keychain and distribution checks remain separate gates. Universal Chrome extension compatibility is not established; some APIs have [external requirements](../docs/native-parity/compatibility-boundaries.md).

Run the isolated checks after packaging:

```sh
swift test --package-path macos
python3 -B macos/scripts/check-app.py --foreground
ZACRO_TURNSERVER=/path/to/turnserver python3 -B macos/scripts/check-app.py --integration --require-extensions --foreground
```

Full and focused media acceptance require a locally built coturn `turnserver` on the host, selected with `ZACRO_TURNSERVER`. This is a disposable loopback test dependency; the browser app does not depend on coturn. To run media alone, use `--integration --suite media --foreground` with the same environment variable.

Application checks use fresh disposable profiles and local fixtures, require a valid passing report and clean exit, and do not validate real-profile Keychain behavior. See the [verification record](../docs/native-parity/verification.md), [interface ledger](../docs/native-parity/interface.md) and [rewrite contract](../docs/SWIFT-REWRITE.md) for exact evidence and remaining acceptance work.
