# Native extension capability adapter

The adapter negotiates ABI v1 from the actual profile's `session.extensions`.
Electron's version string, saved extension state and environment flags cannot
enable a capability. Stock Electron, unknown ABI versions, throwing capability
queries and missing core hooks fail closed. The native patch contract is in
[runtime/electron/patches](../runtime/electron/patches/README.md).

The adapter and focused acceptance fixture are implemented. The custom native
build and successful custom-runtime acceptance are still outstanding; the
checked-in patch and JavaScript tests alone do not establish native support.

## Reviewed permission lifecycle

A native managed copy retains the original required and optional manifest
permissions. The original package and source hash remain separate from the
derived adapter copy. `loadExtension` receives the exact complete reviewed set
through `zacroReviewedPermissions` before native registration. The initial
`zacroUserScriptsEnabled` value is also applied before registration.

On ABI v1, optional permission requests and removals call the native exact-set
setter. They await native network/renderer dispatch and persistence before
updating adapter metadata, durable grants and events. The extension generation,
worker and original document remain alive. Approval authorizes only the requested
delta; it is applied to the latest grants inside the native mutation queue.
Concurrent ordinary changes do not cancel each other or replay stale full sets.
Required permissions and undeclared
or unsupported optional rights cannot be removed/granted. Stock Electron keeps
its existing reduced-manifest/reload behavior.

If the original requesting document expires, or a profile/lifecycle change
invalidates an in-flight native operation, the adapter unloads that generation
and persists a disabled state when it still owns the record. A later callback
cannot replace a newer disable/removal/reinstall. A profile change during an
in-flight activeTab grant similarly disables only the original generation,
because ABI v1 has no separate granular revoke method. This exceptional recovery
does not reload browser page documents or discard their unsaved data. Ordinary
profile switches with no pending grant do not trigger it.

Saved copies created with a tracked original tree digest can be rederived when
changing runtime mode. Existing grants are revalidated against current runtime
support. A downgrade with granted native-only rights is disabled. Historical
copies without an original digest, and legacy path-only installations, require
reinstallation before entering native mode. Migration never fabricates trust
for an unverified original or broadens grants.

## Temporary tab access

Only genuine host action, declared command or context-menu invocation enters
the activeTab grant path. Programmatic `action.openPopup` and extension-supplied
messages do not issue gestures. The adapter waits for the native grant and
revalidates the original profile, generation, document/navigation and permission
revision before exposing temporary tab metadata. Native tab-specific rights
stay scoped to the actual WebContents in the exact profile session. Permission
reductions clear adapter temporary visibility as well as native grants.

## Local user script consent

Manage extensions offers **Allow user scripts on this device** only when the
actual runtime advertises user scripts and the extension holds that permission.
This trusted local control is separate from manifest permission approval.
Extensions cannot invoke it through their API bridge. Its boolean is stored per
managed profile/extension, defaults to false, and is applied on every managed
load before background initialization. It is not library/settings sync consent.

Execution, matching, timing, persistence and script-world isolation use native
Chromium user script facilities. The adapter does not evaluate script source or
give user script worlds Node or extension adapter credentials. Turning the
toggle off prevents future runs; it cannot reverse a script's prior page changes.
Manifest V2 user scripts remain unsupported.

## Focused verification

```sh
node --test test/extensions-engine-capabilities.test.cjs test/extensions-manager.test.cjs test/extensions-api.test.cjs test/extensions-host.test.cjs
node --test test/e2e/extension-custom-runtime.test.cjs
ZACRO_REQUIRE_CUSTOM_ELECTRON=1 ZACRO_CUSTOM_ELECTRON=/absolute/path/to/custom/Electron node --test test/e2e/extension-custom-runtime.test.cjs
```

The default native fixture runs stock Electron and asserts explicit denial,
including that the incompatible extension was never natively loaded. Required
custom mode fails if the executable is missing or does not negotiate ABI v1; it
never turns absent native support into a successful skip.

On a custom runtime the fixture checks actual native scripting access to only
the invoked tab, a same-origin negative tab, navigation/disable revocation,
optional permission completion in the original living page, native network
access/removal, preservation of unsaved page data, and separate user script
worlds, local consent, restart persistence and disabled future execution.
These positive assertions remain unrun until a built custom binary is available.
