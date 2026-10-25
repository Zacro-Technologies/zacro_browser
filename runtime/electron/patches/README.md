# Zacro native capability patch set, version 1

Pinned bases and patch digests/application order are in `series.json`. Apply to
the Electron/Chromium checkout after the normal Electron upstream patches and
before GN generation/build. `target: chromium` means Chromium's `src` root;
`target: electron` means `src/electron`. Neither patch changes app JavaScript.

These are source changes, not a verified runtime artifact. Patch application and
syntax checks do not establish native compilation or acceptance. Build and run
`spec/zacro-native-capabilities.spec.ts` with the custom Electron binary, then run
the Zacro packaged acceptance suite on every target in `../build.json`.

## Main-process contract

All methods below are on `session.extensions`, unavailable to extension pages,
workers and ordinary web pages without an explicit application bridge. The
application authenticates extension identity, owning profile and user consent
before invoking them. The native methods additionally validate exact native
session/extension/tab identity and reject invalid input.

- `getZacroCapabilities()` synchronously returns
  `{version:1,activeTab:true,reviewedPermissions:true,userScripts:true,fontSettings:true}`.
- `grantZacroActiveTab(extensionId, webContentsId): Promise<void>` requires an
  enabled extension with granted `activeTab`, an HTTP(S) WebContents belonging to
  this exact persistent session, and a live document. It uses Chromium's native
  tab-specific permission granter and resolves after CORS/network update and
  renderer dispatch. Cancellation rejects. Cross-origin navigation, tab close,
  extension unload revoke rights. Chromium's normal same-origin navigation
  retention remains intact; no permanent host grants are inserted.
- `setZacroReviewedPermissions(extensionId, {permissions, origins}): Promise<void>`
  takes the complete reviewed native permission set, including original required
  APIs/hosts. Arrays contain strings; bounds are 256 APIs and 1024 origins.
  Required manifest/scriptable permissions are preserved internally. The set
  must contain required permissions and remain within required/optional native
  declarations. Native parsing rejects unknown/internal API permissions and
  invalid origins. Exact rights replace active/granted/runtime stores without
  replacing the extension or its caller. Resolution follows removal/addition
  networking and renderer dispatch, then the profile preference write callback.
  Concurrent updates for one extension reject. Unload/replacement cancels.
  A rights reduction also clears temporary activeTab grants; addition-only
  changes retain them. A forced network barrier covers even API-only revocation.
- `loadExtension(path, {allowFileAccess?, zacroReviewedPermissions?, zacroUserScriptsEnabled?})`
  accepts the same complete reviewed set. Managed loads apply it before native
  registration can start workers or scripts and reject an already-loaded ID.
  `zacroUserScriptsEnabled` is applied before registration, requires actual
  granted `userScripts` when true, and defaults false on managed loads. A load
  with neither custom option retains upstream native persisted state.
- `setZacroUserScriptsEnabled(extensionId, enabled): void` changes the genuine
  UserScriptManager toggle, rejects enabling without granted `userScripts`, and
  disables the dynamic source when false. Revoking that permission also disables
  the toggle. The SCRIPTS StateStore is created before UserScriptManager.
  Registered scripts survive normal process restart. The application must pass
  its persisted reviewed consent at each managed load. This method does not
  reverse effects of scripts that already ran.
- `setZacroFontPreferences(overrides): void` atomically validates and replaces
  the profile override map, updates existing contents, and applies to new
  contents through native Blink WebPreferences. `{}` restores native defaults.
  Shape: `{fonts?:[{script,genericFamily,fontId}], defaultFontSize?, defaultFixedFontSize?, minimumFontSize?}`.
  Script is a canonical ICU four-letter code. Families are `standard`, `serif`,
  `sansserif`, `fixed`, `cursive`, `fantasy`, `math`. fontId is at most 256 UTF-8
  bytes, no NUL; empty string means unset/fallback. Font sizes are integers 1–512;
  minimum is 0–512. Duplicate script/family keys and unknown keys reject before
  mutation. Explicit CSS families remain unaffected by generic-family changes.
- `getZacroFontPreferences()` synchronously returns native default script maps
  merged with profile overrides, plus all three native sizes. It uses the same
  map application helper as the render path. Missing script/family entries mean
  unset (`fontId: ''`), without synthesizing common-script fallbacks. Per-window
  Electron webPreferences are separate from these profile defaults.
- `getZacroFontList(): Promise<Array<{fontId,displayName}>>` uses Chromium's
  asynchronous operating-system font enumeration.

Original optional declarations remain metadata; they are never moved into
required permissions. Native `permissions.request` is disabled at browser
function registration, so retaining these declarations cannot bypass the
application's reviewed request path. Native APIs are not exposed to USER_SCRIPT
worlds, and no manifest-wide activeTab host grant or CSS font shim is used.

## Acceptance evidence required

The Electron spec exercises the invoked vs same-origin negative tab,
cross-profile/private rejection, navigation/close/unload and in-flight grant
cancellation; living-caller permission changes and broad-optional/narrow-required
revocation; pre-load stale rights; user-script world isolation, disabling, and
actual process restart with stale consent disabled; font metrics, explicit CSS,
profile isolation, new contents, getter values and default restoration.

Additional packaged Windows/x64/arm64 runs, artifact hashes/signing and real
application identity/consent integration remain mandatory release gates.
