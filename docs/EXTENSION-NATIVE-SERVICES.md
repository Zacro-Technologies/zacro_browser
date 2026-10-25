# Native extension services

Zacro pins Electron 45 / Chromium 156. Declarative network matching, offscreen
documents, and alarm scheduling use Chromium's native extension APIs. They are
profile scoped; private profiles cannot install extensions. Electron does not
promise these APIs in its public compatibility list, so the managed native
fixture is a runtime upgrade gate.

## Load and persistence

The manager awaits a sandboxed host-owned extension page before committing an
enabled installation or completing profile restore. This page has no Node or
renderer shell capability. Its dedicated sandboxed preload keeps an alarm
callback in a private native-listener closure, exposing no sender function on
the extension Window. The page calls native setters and getters; it contains no
request matcher or JavaScript alarm timer.

Static rulesets need explicit `updateEnabledRulesets` on Electron's unpacked
loader. First load uses manifest defaults. Later loads retain the extension's
enabled/disabled choices; new ruleset IDs use their new manifest defaults and
removed IDs are discarded. Per-static-rule disabled IDs are retained too.
Native dynamic rules are durably snapshotted after successful native mutation;
native session rules are explicitly cleared on every load and never persisted.
Unload immediately removes effective native rules. Removal deletes the snapshot.

Snapshots live under the managed profile's `native-services/<extension-id>.json`.
Native setters complete only after a serialized atomic snapshot succeeds.
Reads await initialization. Native validation, host permission checks, quotas,
priority, callback errors, and actual network effects remain Chromium's work.
The snapshot transports no extension-supplied rules directly to the filesystem:
the host reads rules back from its registered native extension page.

Transform version 4 removes vendor `_metadata` from the derived package and
excludes exactly that top-level generated directory from its integrity digest.
The manager deletes that cache before every load, forcing native rules to be
reindexed from the integrity-checked rules JSON. All original package bytes and
all other derived resources remain hashed. Versions 1–3 retain their existing
integrity policy; previously unsupported native-service packages need reinstall
to receive the version 4 lifecycle page and wrappers.

## Offscreen contexts

`chrome.offscreen.createDocument`, `hasDocument`, `closeDocument`, DOM APIs, and
runtime messaging stay native. Bootstrap and frame preload suppress facades in
the native runtime-only surface. API absence is only a suppression heuristic:
the host independently asks native `runtime.getContexts` for
`OFFSCREEN_DOCUMENT` by native document identity before accepting any relayed
call, and rejects such contexts. There is no hidden BrowserWindow substitute for
an offscreen document. Native unload closes the document and restoration never
resurrects it.

## Alarm lifetime

Alarm creation, enumeration, cancellation and timing use native `chrome.alarms`.
The native-only baseline did not initially start an unstarted MV2 lazy page for
the tested alarm. That baseline does not establish the native router's behavior
after a page has registered its listeners and suspended. For deterministic
managed delivery, Zacro's owned lifecycle page receives the real native event
and forwards its Alarm through the existing authenticated
bridge event queue, which wakes the real native background and waits for its
listener subscription. Extension-facing `onAlarm` uses that one delivery route.
The main process verifies the exact owned WebContents and main-frame identity;
matching an extension URL alone cannot impersonate the native receiver.
Snapshots retain alarms whose native `persistAcrossSessions` is not false.
On re-enable/profile restart, future one-shots are recreated natively and
recurring alarms resume with at most one immediate due event. Elapsed one-shots
are not replayed from a snapshot, avoiding duplicate historical delivery after
an interrupted shutdown. This deliberately does not guarantee exactly-once
delivery across process crashes. Clearing an alarm durably removes it; disabling
the extension stops its native execution until enabled again. Removal deletes
its saved alarms.

## Verification

`node --test test/e2e/extension-native-services.test.cjs` installs through the real
manager and launches Electron twice using a fresh isolated user-data directory.
It checks actual static/dynamic/session request blocking, redirect and response
header changes, an unaffected profile, disable/re-enable cleanup, discarded
unverified native cache, offscreen runtime/DOM and host denial, genuine lazy
background suspension and alarm wake, and restart persistence. Unit tests cover
ruleset reconciliation and resource validation. These results do not establish
Windows, Intel Mac, every DNR action/quota, audio inactivity, or crash timing.
