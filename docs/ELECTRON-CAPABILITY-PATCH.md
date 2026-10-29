# Native Electron capability decision

The user chose to retain Electron and requested all previously missing
extension/sync features. This document isolates the remaining engine decision
from ordinary compatibility-adapter implementation. On 2026-10-26 the user
explicitly approved Choice A: include the custom Electron build and proceed
with all items. Build and acceptance have not yet been completed.

## Evidence on the pinned runtime

- Electron 45.0.0's public extension API loads/unloads extensions but exposes no
  native per-tab permission grant. The checked-in native activeTab probe proves
  that an adapter gesture alone does not let native scripting access the tab.
- Chromium 156 implements the required grant in
  `extensions/browser/permissions/active_tab_permission_granter.cc`, through
  `ActiveTabPermissionGranter::GrantIfRequested`. It updates native tab-specific
  permissions, networking and renderers and revokes on navigation/destruction.
- `UserScriptManager::SetUserScriptPrefEnabled` controls a separate per-extension
  user toggle. Electron exposes no public setter; its dynamic user script state
  store is also absent. Modifying live Preferences JSON would not be a valid API.
- Reviewed optional permission changes currently rebuild/reload the native
  extension. Its old caller can be destroyed before the request completes. A
  native permission-update hook is needed for Chrome-like caller continuity.
- Complete per-script font preference mutation also needs a genuine rendering
  preference path; CSS overrides are not equivalent to native font settings.

The source links and reproducible tests are recorded in the capability review.
Public API reference: https://www.electronjs.org/docs/latest/api/extensions-api
Pinned source: https://github.com/electron/electron/tree/v45.0.0

## Choice A: Maintain a small Electron patch set

Keep Electron as the product foundation, but build a pinned runtime with
host-only native methods for directed active-tab grants, reviewed permission
updates, user-script enablement/persistence and font preferences. Expose no such
method to ordinary pages or extension JavaScript. The existing authenticated
main-process adapter invokes them only after its identity/permission/gesture
checks. Keep per-profile native sessions and private exclusion.

The patch source, upstream version, build configuration, artifact digests and
runtime feature negotiation belong in the repository. A standard Electron
binary must fail closed for unavailable hooks. Each runtime upgrade requires
rebasing and running grant/revocation, context isolation and native API tests on
Windows and both supported Mac architectures, followed by signing/notarization.
Building and distributing this runtime adds substantial build storage/CI and
ongoing maintenance. Build capacity and exact compilation duration are not yet
established. A patch file alone is not a finished or verified feature.

## Choice B: Retain the unmodified Electron distribution

Complete the supported native facilities and application-level adapters, but
keep the engine-bound capabilities explicitly unavailable. This is simpler to
maintain and cannot satisfy every remaining feature in the user's request.

## Acceptance of a custom runtime

- Native scripting/network access reaches only the invoked tab, including a
  separate same-origin negative tab; cross-origin navigation/disable revokes it.
- Optional access succeeds in the original living caller only after the real
  native permission update, and revocation still respects unsaved pages.
- User scripts persist and execute in distinct isolated worlds with documented
  matching/run timing and no privileged extension credentials/Node access.
- Font preferences affect native generic font selection, preserve explicit CSS
  families and work per profile and script; no silent success through CSS hacks.
- Windows/arm64/x64 runtime build and packaged acceptance pass at exact digests.

Public service deployment still separately requires a hosting account/domain,
and signed distribution requires the owner's signing credentials.
