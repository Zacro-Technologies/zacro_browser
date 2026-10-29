# Independent sync controls and device details

> Execute inline with `superpowers:executing-plans`.

**Spec:** [Remaining work design](../specs/2026-10-25-remaining-extensions-sync-design.md),
section Independent synchronization, plus the original approved design.
This plan handles the sync-control slice; the other items remain open in the
addendum and require their own evidence-based implementation plan.

**Goal:** Fulfill the approved independent switches without discarding opted-in
settings or projecting a paused cloud library into local installations.

**Architecture:** Persist `librarySync` per SyncClient link; default old links to
true at read sites. Retain remote metadata for safe settings generation checks,
gate library producers/projection, invalidate old identity on preference changes.

**Global constraints:** Work in existing `extensions-and-sync`; preserve unrelated
work, private isolation, guard/cancellation, credential protection and per-device
installation approval. No network deployment or personal-profile testing.

## Task 1: Independent client controls

**Files:** `src/main/sync/client.cjs`, `test/sync-client.test.cjs`.

**Interfaces:** `linkProfile` accepts `librarySync=true`; status exposes it;
`setLibrarySync(profileId, enabled, {libraryChoice,localLibrary})` changes only
library behavior. `extensionIntents` returns none while paused. Existing
`setSettingsSync` retains library choice.

1. Add real-service tests: library-off settings-on converges settings while
   producing no library events/uploads; settings enable/disable leaves library
   off; restart retains controls; remote removal prevents stale settings writes.
   Add re-enable tests with pending/rejected settings, remote choice, merge local,
   and a held in-flight library pull/push rejected by the new link identity.
2. Run `node --test test/sync-client.test.cjs` (Expected: new cases fail for missing
   library switch). Save the result.
3. Implement independent control transactions. On disable retain settings and
   settings outbox/rejections, remove only library operations. On enable fetch a
   fresh snapshot under intent/link guards, merge remote metadata/settings through
   normal conflict handling, retain eligible settings operations and area access
   controls, then project the chosen cloud/merged library. Changes must not be
   committed after a newer toggle/unlink/account change.
4. Run focused client tests and all Node tests (Expected: all pass).
5. Commit the client and regression tests.

## Task 2: Desktop controls and device dates

**Files:** `src/main/sync/controller.cjs`, `src/renderer/sync.js`,
`test/e2e/extensions-sync.test.cjs`, `docs/SYNC.md`, `docs/EXTENSIONS.md`.

**Interfaces:** `sync:library` forwards enabled, libraryChoice and local portable
library; `sync:link` forwards librarySync. UI shows independent library/settings
state; library re-enable reviews remote/merge choice. Device date input is the
service's millisecond createdAt/lastSeenAt.

1. Add a native UI regression for settings-only linking and library pause/resume
   while preserving local extension operation/settings; assert both controls and
   the two date labels in the real account device list.
2. Run the focused case (Expected: fail before new controls exist).
3. Add controller/UI controls, truthful settings-only explanation, locale dates
   and unknown fallback. Update trial instructions with the independent behavior.
4. Run focused Electron cases and formatting/check (Expected: all pass).
5. Commit the UI/docs and evidence.

## Task 3: Review and acceptance

Run `npm run verify` after integration (Expected: all checks pass). Request a
fresh review of this plan's complete diff, prioritizing opt-out races, retained
settings, stale generations, old-state migration and profile boundaries. Fix
material findings with failing-then-passing regression evidence. Record current
results without claiming the other remaining-API/deployment tasks are complete.

## Review Focus

- Opt-out before a pending request or host projection finishes.
- Settings queued for a local extension whose library operation was cancelled.
- Tombstone/reinstall while library projection is paused.
- Re-enable preserving unsynced/rejected values and trusted-only access.
- Concurrent settings/library toggles and restart of a pre-switch legacy link.
