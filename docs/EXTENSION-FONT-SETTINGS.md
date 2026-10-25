# Extension font preferences

The `fontSettings` permission is available only when the actual profile session
negotiates Zacro native ABI v1 and the native getter, replacement setter and OS
font enumeration hooks are present. Stock Electron remains incompatible with a
required `fontSettings` permission. Saved preferences do not enable the feature.

The adapter implements `getFont`, `setFont`, `clearFont`, `getFontList`, and the
get/set/clear methods for default font size, default fixed font size and minimum
font size. Promise and callback forms share the authenticated bridge; callback
failures use `runtime.lastError`. It delivers `onFontChanged`,
`onDefaultFontSizeChanged`, `onDefaultFixedFontSizeChanged` and
`onMinimumFontSizeChanged` to enabled authorized receivers with their own
`levelOfControl`. A newer installation without its own override can control an
older owner's setting; an older installation cannot steal a newer owner's
selection by writing afterward.

The contract follows the official [Chrome fontSettings reference](https://developer.chrome.com/docs/extensions/reference/api/fontSettings).
The public generic-family and script enums match that reference; absent script
means `Zyyy`, and an empty font ID requests the native global-script fallback.
Defaults and the font list come from the native engine and operating system.
Native maps for newer ICU scripts are ignored by the public enum projection.
The renderer receives real font preferences for existing and new contents;
no page CSS is injected. An explicit CSS family/size continues to govern its
own element, subject to Chromium's ordinary minimum-size behavior.

Preferences are stored only in each managed profile's `font-settings.json`.
Each extension retains its own overrides. The greatest numeric `installedAt`
wins, with extension ID as a deterministic tie break. Clearing removes only
that caller's value. Disable and permission revocation remove an owner's
current effect; an explicit enable or permission regrant can reactivate retained
values. Uninstall discards that owner's stored values, including an immediate
reinstall of the same ID. Private profiles are rejected.

Calls wait for managed activation readiness and recheck the current profile,
permission, extension generation and document context across native waits.
The native setter runs before a successful atomic local commit. A failed or
cancelled operation restores still-eligible previously committed owners;
rollback failures are reported instead of claiming success. Lifecycle
reconciliation is awaited during native activation, restore and deactivation.
Queued bridge events recheck receiver permissions and generation at delivery.

Input/state limits are explicit: 128 stored owners per profile, 512 settings per
owner, a 4 MiB state file, font IDs at most 256 UTF-8 bytes with no control
characters, integer default sizes 1–512 and minimum sizes 0–512. Native default
names are preserved up to 4096 UTF-8 bytes; the native font list is bounded to
32768 entries and 4 MiB. These bounds reject excess data rather than truncating
an accepted override.

## Verification

Focused tests:

```sh
node --test test/extensions-font-settings.test.cjs test/extensions-font-settings-bootstrap.test.cjs test/extensions-host.test.cjs
node --test --test-concurrency=1 test/e2e/extension-font-settings.test.cjs
```

Demand positive native rendering acceptance on the selected Electron binary:

```sh
ZACRO_REQUIRE_CUSTOM_ELECTRON=1 node --test --test-concurrency=1 test/e2e/extension-font-settings.test.cjs
```

An optional `ZACRO_CUSTOM_ELECTRON=/absolute/path/to/electron` selects a source
build directly; otherwise Playwright uses the installed Electron runtime. The
required run fails if the launched engine lacks genuine font hooks. The fixture
uses actual managed extension calls, OS font enumeration, canvas text metrics,
existing/new page sizes, explicit CSS, another profile, events, clear and disable
restoration. Passing the stock denial branch proves only fail-closed behavior.
Positive custom rendering acceptance remains unrun until the approved native
runtime is built; unit mocks are not evidence of browser font rendering.
