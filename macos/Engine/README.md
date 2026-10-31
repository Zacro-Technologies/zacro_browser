# Chromium engine dependency

CefSwift is vendored from https://github.com/Rajaniraiyn/CefSwift at
`b18cceef8afaf6686147e19a9239f31c2dd81541` under its BSD 3-Clause license.
Its pinned CEF archive is declared in `CefSwift/CEF_VERSION.json`; native
binaries and build caches are not tracked.

Zacro changes in `CefChromeBrowser.swift` add profile-specific Chrome request
contexts and independently retained Chrome browser child windows. CEF allows only one
Chrome BrowserView per window, so each page retains its own CEF window under
the native shell. Pages are never converted to Alloy. Coordinates are converted
from the parent content view to screen coordinates. Fullscreen transitions,
native dialogs and layering above page windows require explicit acceptance.

Build from the repository root using `macos/scripts/build-app.sh`. The CEF plugin verifies the archive
against its pinned digest, bundles the framework and five helpers, and signs
inside-out. Ad hoc builds are development artifacts, not notarized releases.

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
