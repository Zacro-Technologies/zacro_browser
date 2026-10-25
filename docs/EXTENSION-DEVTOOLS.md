# Native DevTools extensions

Zacro preserves a managed extension's validated `devtools_page` in its derived
manifest and loads it through the owning profile's Electron session. The
`chrome.devtools` implementation remains Electron/Chromium's native API. The
compatibility bootstrap supplies the usual extension-page bridge; inspected
websites do not gain extension identity or a bridge.

A DevTools entry must be a nonempty relative package path with no empty, `.` or
`..` segments, URL scheme, backslash, percent escape, query, fragment, ASCII whitespace
or control characters. It must resolve to a regular file inside the package.
Missing files, directories, foreign URLs and resource escapes are rejected
before a derived extension is written. Managed acquisition rejects symbolic
links and preserves the original package, manifest and verification provenance.

Extensions load only in their installing profile. Private profiles cannot
install extensions. Open DevTools using the browser's existing developer-tools
command and select the extension's panel in the native DevTools tab strip or
its overflow menu.

When a DevTools extension unloads (including disable, remove, update or a
permission-driven reload), Zacro closes open DevTools in that exact native
profile session. This is necessary because Electron 45 removes the extension
from its registry while existing native DevTools frames otherwise retain
`inspectedWindow.eval` access. The inspected pages and their unsaved input stay
open. Other profiles' DevTools stay open. Re-enable the extension and reopen
DevTools to obtain fresh native contexts; old bridge contexts remain revoked.

## Verified behavior and limits

`node --test test/e2e/extension-devtools.test.cjs` exercises the real managed
loader and sandboxed native renderer on Electron 45.0.0. It selects the panel
registered by `chrome.devtools.panels.create`, evaluates a marker in an HTTP
page with `inspectedWindow.eval`, and reads the result from the native panel's
DOM. It also verifies bridge round trips, original/derived manifest handling,
resource rejection during installation, session/private isolation, native and
bridge revocation, and preservation of another profile's open DevTools and
unsaved page input. The fixture selects the registered panel through DevTools'
frontend tab controller, equivalent to selecting its tab; it does not simulate
a panel with an ordinary extension window. Calling `panel.show()` alone did
not select the panel in the tested Electron runtime.

This evidence covers native panel creation and inspected-window evaluation;
it does not establish complete Chrome DevTools API compatibility or packaged
release/platform coverage. Existing rejections of `chrome_url_overrides`,
`sandbox` and `declarative_net_request` remain unchanged by this slice. Other
capability work and deployment/release validation remain separate open tasks.
