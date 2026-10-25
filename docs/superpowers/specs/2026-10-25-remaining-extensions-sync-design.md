# Remaining extensions and sync work

This addendum records the user's request to implement the remaining items on
`extensions-and-sync`, retaining Electron. The user explicitly excludes the
previous non-goals: E2EE, email verification, history/bookmark/tab sync.
The approved [original design](2026-10-25-extensions-and-sync-design.md) remains
binding. No broader permissions, plaintext credential fallback or simulated
successful APIs may be introduced to make an extension appear compatible.

## Approach

Continue the existing authenticated, profile-scoped compatibility adapter and
use native Electron extension facilities where they actually work. A Chromium
migration conflicts with the user's selected approach. A private Electron fork
is not assumed: any capability requiring an engine change must first have a
reproducible runtime probe and a concrete implementation decision.

The following implementation choices are the builder's decisions within the
approved approach; they are not represented as additional user preferences.

## Independent synchronization

Every linked profile has `librarySync` and `settingsSync`. Existing links without
`librarySync` retain their previous enabled behavior. The link review defaults
library on and settings off, with the existing explicit settings consent.
Either can be enabled alone; disabling both keeps the account/link available.

Library off stops outgoing installation/state/removal operations and incoming
installation prompts or state changes. Pending library operations are discarded
locally on opt-out, without changing cloud intent. Local installed extensions
are retained. Settings continue for extensions already represented in the cloud
dataset; adding a new extension to the cloud library requires library consent.
Cloud identity/generation/tombstone metadata is still read to prevent writing
settings into deleted installations. This metadata must never project into
the local installation library while library sync is off.

Switching a category invalidates outstanding work for the old link identity.
Re-enabling library asks whether to use the cloud library or merge local portable
extensions, then obtains a fresh snapshot. It preserves opted-in settings,
including queued and rejected local writes, rather than silently dropping them.
Settings opt-in retains its separate local/remote choice and privacy consent.
Toggles cannot restore one another, revive rejected operations of a disabled
category or affect another profile/account. After restart the choices persist.

The device list displays registration and most recent service activity times in
the user's locale, with an explicit unknown value for absent/invalid timestamps.

## Remaining extension capabilities

The remaining work covers `action.openPopup`, ImageData icons, inline context
menu callbacks, permission-request completion across native reload, alarms,
font settings, DevTools integration, offscreen documents, side panels,
declarative network rules, user scripts, temporary active-tab access,
external native messaging, and identity/web authentication. Each capability
must have a real native acceptance fixture before being advertised as supported.

Use the current guard (profile, extension identity, generation, document,
permission and enabled state) for every operation and event. Views and workers
remain sandboxed and never receive Node. Resource views may load only the
requesting extension's reviewed resources. Offscreen and side-panel lifetimes
end on disable/remove/profile shutdown. Network rules may affect only the
extension profile and approved requests. Temporary access must be limited to
the invoked tab and revoked on cross-origin navigation/closure/disable; adding
an origin to the permanent manifest is not an implementation of activeTab.
User-script worlds must not gain extension credentials or Node privileges.
Native host launch requires an OS-registered host explicitly allowing this
extension, bounded framing, process teardown and user-visible approval.
Identity flows must validate the extension-specific redirect and clean up
cancelled windows; provider account/token services require real provider support.

Implementation plans for these APIs must be based on the pinned runtime and
official API documentation. A fail-closed capability remains a documented open
item until real behavior and security properties pass; removing a catalog block
or returning a placeholder is not completion.

## Service deployment and release validation

The user has no domain or hosting server. Prepare reproducible HTTPS deployment,
durable storage, backup/restore, monitoring and operator setup. Do not purchase
resources or pretend a public endpoint exists. Account creation/hosting choices
and signing credentials are external prerequisites to live operation.
Run available CI for Windows and Intel Mac, add and verify container acceptance,
and retain the signed/notarized release gate until credentials and actual
distribution verification are available. Local test success is not that gate.

## Evidence and completion

Use real service/client tests for consent, race cancellation and restart; real
Electron fixtures for native APIs and representative verified packages; build
and package checks after production changes. Keep historical baseline evidence
distinct from the new revision. Report external prerequisites and remaining
engine constraints explicitly instead of marking the entire request complete.
