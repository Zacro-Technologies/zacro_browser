# Native extension capability completion

**Spec:** [Remaining extensions/sync design](../specs/2026-10-25-remaining-extensions-sync-design.md).
**Execution:** `superpowers:subagent-driven-development`, one fresh implementer
and reviewer per bounded task. The primary agent independently handles the
separate sync-control plan. No simultaneous editing of shared extension files.
**Goal:** Implement the user's remaining capabilities on the existing Electron
45 engine, using its actual native behavior where verified.
**Global constraints:** Preserve sandboxing, authenticated contexts, profiles,
private exclusion, permission review, immutable original package provenance and
generation revocation. No fake success or broader permissions as a workaround.
Read official pinned Electron sources where capability documentation differs.
Do not change other agents' files or run foreground native tests concurrently.

## Task 1: Native DevTools extensions

**Files:** `src/main/extensions/catalog.cjs`; `src/main/extensions/adapt.cjs`
only if necessary; new `test/e2e/extension-devtools.test.cjs`; existing catalog
tests when their asserted boundary changes. A focused new documentation file
`docs/EXTENSION-DEVTOOLS.md` records actual supported behavior and evidence.

**Interfaces:** Reviewed `devtools_page` is preserved in the derived manifest
and passed to the existing profile session extension loader. Electron's native
`chrome.devtools` remains native. The existing bridge may bootstrap ordinary
extension pages but must not grant page/main-world scripts extension identity.
Avoid changes to shared `api.cjs`, `host.cjs`, `bootstrap.js` unless a concrete
integration failure requires them; report that need first.

1. Add catalog/runtime tests that fail before enabling the feature: a sandboxed
   managed extension with a devtools page creates a genuine panel for its own
   profile's inspected HTTP page. Evaluate a marker in inspectedWindow and read
   the resulting native panel DOM to establish real integration.
2. Test isolation: a second profile/private session does not load the extension;
   disable/remove tears down its native context and obsolete bridge access.
   Invalid/foreign/path-traversing devtools resources fail installation/load.
3. Run the focused tests; record expected RED failures. Remove the overly broad
   catalog rejection only after resource validation and real runtime behavior
   are established. Preserve unrelated unsupported fields.
4. Run the focused native test plus catalog/manager tests and format/check.
   Expected: all pass without relaxed assertions or skipping platform behavior.
5. Self-review and commit only task-owned files. Report test evidence and exact
   changed files. The controller performs a fresh task review.

## Task 2: Native declarative network rules, offscreen contexts and alarms

**Files:** `src/main/extensions/catalog.cjs`, `manager.cjs`, `bridge.cjs`,
`adapt.cjs`; new focused lifecycle module(s) in that directory; new
`test/e2e/extension-native-services.test.cjs`, focused unit tests, and
`docs/EXTENSION-NATIVE-SERVICES.md`. Coordinate catalog/bridge edits after Task 1.
Root owns action API/bootstrap/host changes; request integration there instead
of concurrently editing them.

**Interfaces:** Preserve native Chromium DNR/offscreen/alarms where verified.
Introduce explicit initialization awaited by manager activation/restore before
advertising enabled. A trusted host-owned extension page can call native APIs;
never use ordinary web pages or main-world bridges. Native DNR must initialize
manifest-enabled static rulesets through updateEnabledRulesets, preserve users'
enabled/disabled choices and dynamic rules across restore/update, and remove
effective rules on disable/removal. Native session rules stay session-local.
Offscreen contexts must expose only native runtime, not fabricated storage/tabs
facades. Alarms must fire/wake real native backgrounds and have truthful restart
semantics. All contexts remain profile-scoped and sandboxed.

1. Write failing native tests through actual managed extension installation:
   static/dynamic DNR really block/redirect/modify an HTTP request, allowed
   requests succeed, another profile unaffected; native session/dynamic/static
   changes preserve documented lifetime through stop/restart/disable/update.
2. Add offscreen DOM/runtime messaging create/has/close and denial of privileged
   adapter calls, including disable and private/profile isolation. Test genuine
   alarm delivery to suspended worker and alarm enumeration/clear/restart.
3. Inspect pinned Electron runtime behavior; add the smallest durable lifecycle
   initialization necessary. Do not claim success on absent native setters;
   report concrete blockers. No catalog enable until the fixture passes.
4. Run focused manager/catalog tests and native fixtures. Record RED/GREEN, exact
   method boundaries, self-review and commit only owned files. Root coordinates
   foreground tests and reviews the complete task diff.

## Task 3: Action popup, pixel icons and document menu callbacks

**Execution:** Root inline with TDD, independent of Task 2 files.
**Files:** `api.cjs`, `bootstrap.js`, `host.cjs`, a pure icon encoder if needed;
`test/extensions-api.test.cjs`, `test/e2e/extension-api.test.cjs` and owned
new native test file. Do not change Task 2 initialization concurrently.

**Interfaces:** action.openPopup accepts optional windowId, selects the existing
profile's active tab, and opens its declared sandboxed popup without granting a
user gesture/activeTab. Missing/disabled/foreign-window/hidden-profile cases
reject. Only one action popup per profile/window is retained. setIcon accepts
ImageData or size dictionaries; facade serializes bounded RGBA bytes, host
validates and encodes real PNG pixels. Paths continue to work. Menu onclick
functions remain in their owning document; facade routes onClicked events by
menu ID and removes/replaces callbacks after successful remove/update; MV3
workers must use onClicked as Chrome documents.

1. Add RED tests for openPopup, invalid windows/state/no gesture, pixel icons
   including malformed dimensions/bytes, and native callback/PROMISE behavior.
2. Implement under existing generation/permission guard. Image encoding is
   bounded, rejects malformed input, preserves alpha/colors and is never HTML.
   Verify actual shell icon pixels and isolated popup page. Inline callbacks
   work in a native MV2/document context and are not sent over IPC as functions.
3. Run focused unit/native tests, self-review and commit task-owned changes;
   request a fresh review after integration.

## Subsequent capability slices

The required builder check is probing DNR/offscreen/alarms and other APIs. Add
their exact implementation tasks after verified native behavior establishes
the appropriate mechanism. These items are OPEN, not omitted from the user's
request: action popups/ImageData, callbacks, alarms/fontSettings, DNR, offscreen,
sidePanel, userScripts, activeTab, nativeMessaging, identity, deployment and
release validation. They must not be marked complete by this DevTools task.

## Task 4: Native messaging host broker

**Files:** New `src/main/extensions/native-messaging.cjs`, focused
`test/extensions-native-messaging.test.cjs`, native fixture/e2e, and
`docs/EXTENSION-NATIVE-MESSAGING.md`. API/bootstrap/host/catalog integration is
coordinated with root after Task 3 completes; do not edit those concurrently.

**Interfaces:** A broker class accepts `resolveHost`, `approveHost`, `emit`, and
native process spawning dependencies for deterministic tests. Production host
resolution uses OS registration for the named host (macOS/Linux known Chrome
native-messaging locations; Windows documented HKCU/HKLM native-messaging
registry keys). Strict hostname grammar, manifest type=stdio, exact name and
allowed_origins must include the verified chrome-extension://ID/; reject URLs,
relative executables on Unix, shell commands, wildcard origins and malformed
or oversized manifests. Never search arbitrary executable paths or use a shell.

`connect(context, name, clientPortId)`, `post(context, clientPortId, value)`,
`disconnect(context, clientPortId)`, `send(context,name,value)`; context includes
profile/extension/generation and guard. Ports are scoped to that authenticated
context. Require nativeMessaging permission and a local review of the exact
registered host/executable; remember approval only for its unchanged manifest
and executable identity. Revoke processes/queues on context death, extension
disable/removal/profile shutdown. Native JSON length framing uses the machine's
byte order, validates UTF-8/JSON and size limits, handles fragmentation and
multiple messages, rejects truncated frames and bounds queue/process resources.
Do not print host payloads/stderr or include them in errors.

1. Add failing real-child-process tests using a synthetic temporary native host,
   including fragmented response, multiple responses, denial by origin, malformed
   lengths/JSON/UTF-8, process exit, cancellation, profile/generation mismatch and
   withheld local approval. No real personal installed host is launched.
2. Implement broker/resolver with explicit limits and teardown. Cross-OS lookup
   tests inject registry/path discovery; real execution is tested on local OS.
3. Coordinate real native Port facade (onMessage/onDisconnect/lastError,
   synchronous connectNative return) and sendNativeMessage Promise/callback
   through authenticated IPC. Native nativeMessaging is blocked by Electron,
   so these methods must call the broker, not pretend native support.
4. Native acceptance: a disposable reviewed extension talks to the synthetic
   registered host and loses connection on disable. Unit + native checks pass;
   document exact host discovery, review and bounds, self-review, commit owned
   files and provide RED/GREEN report for fresh review.

## Review Focus

- Genuine DevTools context and inspected document behavior, not manifest loading.
- No cross-profile or private extension installation.
- Resource escape and generation revocation.
- Packaged original signature/provenance remains untouched.
