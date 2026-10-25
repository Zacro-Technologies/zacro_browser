# Task 2 implementer report

Status: DONE_WITH_CONCERNS. The implemented managed native capabilities and focused acceptance pass. Broader platform/action/quota/audio coverage and crash exactly-once behavior are not claimed.

## Implementation

- `native-services.cjs` owns a per-session/per-extension trusted native page, initialization barrier, serialized atomic native getter snapshots, ruleset reconciliation, native static/dynamic/session restoration, future native alarm restoration, and authenticated native clock forwarding. The manager awaits initialization before committing enabled/install/restore completion; native APIs missing in the pinned runtime fail initialization rather than silently succeeding.
- Static defaults explicitly run `updateEnabledRulesets`; saved choices override defaults for known IDs, new IDs use new defaults, removed IDs disappear. Disabled per-static-rule IDs are also snapshotted/restored. Dynamic rules are restored with actual native setters; session rules are cleared each load and never persisted.
- Transform v4 removes vendor `_metadata` in the derived copy and excludes exactly that top-level native-generated directory from its digest. Every native load purges it before loading, so immutable hashed JSON is reindexed. Original bytes and every other derived resource retain integrity checks. Transform v1–3 retain their previous hash policy; old native-service installations need reinstall to acquire the lifecycle page/wrappers.
- `native-services-preload.cjs` registers a real native `alarms.onAlarm` listener using a private callback closure. It exposes no global sender. Main-process IPC verifies the exact owned WebContents, exact main frame, extension page URL, live generation/permission, and bounded known Alarm fields. It forwards the real event through the existing bridge queue to wake native backgrounds and checkpoints after firing. Another WebContents at the identical extension URL cannot impersonate it.
- The root agent owns bootstrap integration: native DNR/alarms reads await ready; persistent setters await native completion and a host checkpoint before Promise/callback success; native session setters await ready but remain volatile. `alarms.onAlarm` uses one facade delivery path, preventing native/facade duplicates. That root-owned file is intentionally excluded from this task's commit.
- Offscreen create/has/close, DOM, and runtime messages remain genuine Chromium APIs. Bootstrap/frame preload suppress facade creation only as a heuristic; independent authoritative native `runtime.getContexts` checks reject `OFFSCREEN_DOCUMENT` before direct or relayed host dispatch. MV2 is excluded from that query because neither offscreen nor getContexts is exposed there; the decision uses the actual loaded native manifest. Offscreen disable/remove cleanup remains native. Private profiles reject installation.
- Removal deletes snapshots synchronously after durable removal, before cancellable queued teardown, so reinstall cannot inherit removed rules/alarms. Snapshots are scoped under the manager's hashed profile directory.

## TDD evidence

RED, before production changes:

`node --test test/e2e/extension-native-services.test.cjs`

Failed as expected: `Managed native services did not enable: incompatible` (1 failed). The actual managed installation, not a raw package load, was blocked by the old catalog.

Next native RED after enabling native initialization but before bootstrap persistence/gating:

- Real native static block/dynamic block/session block/redirect/response-header changes all worked.
- `reenabledStatic:["static"]` instead of `[]` and `reenabledDynamicBlocked:false` demonstrated missing durability.
- Offscreen reported `storage:"object", tabs:"object", bridge:"object"`, demonstrating facade expansion beyond the native runtime-only API.
- Native DNR generated metadata caused `Managed extension integrity check failed` at re-enable. This drove the v4 cache exclusion **and mandatory purge**; cached data never becomes trusted code/rule source.

Pure reconciliation RED initially reported missing `native-services.cjs`; subsequent tests explicitly proved disabled/removed/new-ID behavior. Additional behavior RED/GREEN:

- `node --test test/extensions-native-services.test.cjs`: MV2 offscreen initially returned `compatible:true`; after policy guard all 3 tests pass.
- `node --test --test-name-pattern='removal deletes native snapshots' test/extensions-manager.test.cjs`: RED `true !== false` / `a successor installation must not inherit removed rules`; GREEN 1/1 after synchronous deletion before asynchronous teardown.

The native-only alarm baseline did not initially start the MV2 lazy background. This is **not proof that an already registered native alarm listener fails after suspension**. The final fixture first sends a native runtime message to establish background instance 1, verifies its actual absence after 35 seconds, then requires the real native-clock event to wake instance 2. This catches an always-alive background, a missing initial startup, and duplicate event delivery. Source review separately confirms native scheduling and the absence of a JavaScript clock substitute.

## GREEN verification

`node --test test/e2e/extension-native-services.test.cjs`

2/2 passed, approximately 45.4 seconds, final fixture and root bootstrap integration:

1. Managed update via existing synthetic verified-download boundary: version 2 enabled; old disabled static ID retained; new default enabled (`choices:["new"]`); old URL allowed/new URL blocked; dynamic URL still blocked; offscreen permission absent and native document closed. Identical-URL unowned WebContents IPC forgery denied.
2. Real native static/dynamic/session blocking, redirect to `/landed`, native response header `x-native:native`, unaffected second profile, native rule cleanup on disable, durable static choice/dynamic rules on re-enable, session clearing, corrupted cache discarded, bad offscreen URL rejected, duplicate create rejected, offscreen DOM/runtime message reaches real worker, Node/process/storage/tabs/host bridge absent, direct native runtime Port attempt authoritatively denied, native close/disable cleanup, private install denied, and ordinary no-permission page retains the facade before its first script. The background truly suspends; alarm event wakes instance 2 and appears exactly once; native callback and Promise alarm create/get/clear work. A second Electron process restores dynamic blocking, disabled static choice and future alarm, clears session rules and offscreen state, and removal restores allowed traffic.

`node --test test/extensions-manager.test.cjs test/extensions-native-services.test.cjs test/extensions-packages.test.cjs`

56/56 passed before the extra removal-race test; the new test separately passes 1/1 (57 focused cases total).

`node --test --test-concurrency=1 test/e2e/extension-context.test.cjs test/e2e/extension-devtools.test.cjs test/e2e/extension-events.test.cjs`

Initial regression batch: 16/18 passed. Two queued Port tests timed out because their minimal resolver metadata omits a manifest, while the new query dereferenced it. Fixed by consulting the actual loaded native manifest. The batch's six native MV2/MV3 context round trips, all DevTools cases, all four live-event cases and adaptation cases passed.

`node --test --test-name-pattern='queued native Port' test/e2e/extension-context.test.cjs`

Final targeted regression: 2/2 passed (~1.75s), both old native document identities rejected after same-URL reload, zero dispatches.

`npm test`

- First full run: 254/255; sole failure was the root-owned obsolete ImageData rejection expectation during action implementation; root corrected it.
- Latest full run during parallel native-messaging implementation: 271/272. Sole failure: `test/extensions-native-messaging.test.cjs:66` / `local approval is mandatory and identity changes invalidate remembered approval` / `Native messaging connection failed` at line 68. Reported to root; root will run the final combined suite after that owner's integration stabilizes. No failure from the Task 2 manager/catalog tests.
- `git diff --check` and focused Prettier checks pass.

## Files changed

Production: `src/main/extensions/{native-services.cjs,native-services-preload.cjs,manager.cjs,adapt.cjs,bridge.cjs,catalog.cjs,frame-preload.cjs}`.

Tests: `test/e2e/extension-native-services.test.cjs`, `test/fixtures/extensions/native-services-host.cjs`, `test/extensions-native-services.test.cjs`, updated transform-version/removal-race coverage in `test/extensions-manager.test.cjs`, updated supported-permission count in `test/extensions-packages.test.cjs`, and removed the newly supported DNR context from the DevTools test's unrelated unsupported list.

Documentation: `docs/EXTENSION-NATIVE-SERVICES.md`, this report.

## Self-review and concerns

- Found and fixed the untrusted native cache loading risk by purging before every load, the cancelled removal/reinstall snapshot race, the MV2 getContexts incompatibility, and the metadata-only resolver regression. Callback/Promise boundaries and one-path alarm delivery were checked in actual native contexts.
- Native receiver has no publicly borrowable capability; the forged same-origin/same-URL IPC test proves URL alone is insufficient.
- This validates Electron 45 / Chromium 156 on the native macOS host. Windows/Intel Mac, every DNR action/regex/priority/quota, audio-inactivity offscreen shutdown, cancellation at every native pending-call boundary, and crash timing have not all been exercised by this focused fixture. Matching, quotas, native offscreen lifetime, and permission-specific redirect/header restrictions remain native.
- Future one-shot alarms restore natively; elapsed one-shots are deliberately not replayed from snapshots. Recurring alarms restore with at most one immediate due event. Exactly-once alarm delivery across a process crash is not promised. The API and documentation expose this truthful lifetime boundary.
- The lifecycle module is 270 lines and remains focused on initialization, persistence and native clock event delivery. No JS request engine, fake offscreen window, or JS clock was added.
- Root bootstrap changes are required and tested together but committed separately by its owner. Root coordinates full-suite/platform acceptance and fresh review.
