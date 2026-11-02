# Chromium engine dependency

CefSwift is vendored from https://github.com/Rajaniraiyn/CefSwift at
`b18cceef8afaf6686147e19a9239f31c2dd81541` under its MIT license. CEF is
licensed separately under BSD 3-Clause.
Its pinned CEF archive is declared in `CefSwift/CEF_VERSION.json`; native
binaries and build caches are not tracked.

Zacro changes in `CefChromeBrowser.swift` add profile-specific Chrome request
contexts and independently retained Chrome browser child windows. CEF allows only one
Chrome BrowserView per window, so each page retains its own CEF window under
the native shell. Pages are never converted to Alloy. Coordinates are converted
from the parent content view to screen coordinates. Fullscreen transitions,
native dialogs and layering above page windows require explicit acceptance.

After preparing the pinned Chromium/CEF source with the official `automate-git.py`,
build the custom framework from the repository root:

```sh
python3 -B macos/Engine/CefSwift/NativeRuntime/build_runtime.py --download-dir /path/to/zacro-chromium --jobs 4
macos/scripts/build-app.sh --runtime-build /path/to/zacro-chromium/chromium/src/out/Release_GN_arm64/zacro-runtime-build.json
```

The driver verifies source revisions, applies the native integration and writes a
receipt only after a successful build. Packaging verifies that receipt against the
current adapters and framework, bundles the required helpers, and signs inside-out. Use
`--skip-generation` only to resume an already generated pinned build. See the
[runtime verification record](../../docs/native-parity/engine-extensions.md).
Ad hoc bundles are development artifacts, not notarized releases.

Zacro explicitly enables the Chromium sandbox and real Keychain cookie
protection. No privileged page-to-Swift bridge handlers are registered.
The upstream extension APIs and actual sandbox/packaged behavior still require
native acceptance. Chrome runtime selection alone does not prove that every
Chrome extension can run; Google services, OS-specific APIs, policies and
extension-specific assumptions can remain incompatible.

Persistent Chrome profiles must be direct children of Chromium's root cache
directory. The upstream wrapper's extra `Profiles/` directory caused CEF to
fall back to an ephemeral profile; Zacro removes that level and fails closed
on profile-directory/context creation errors. This change is covered by the
profile path unit tests; cross-profile cookies and restart persistence still
require native acceptance.

`--engine-acceptance` permits a mock cookie key only with a newly created,
empty `zacro-native-acceptance-*` directory directly inside the system temporary
directory. It is an explicit isolated test mode, not a recovery fallback.
Normal launches always use Keychain and never retry with mock encryption.
The acceptance results do not validate production credential access.
