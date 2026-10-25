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

## Subsequent capability slices

The required builder check is probing DNR/offscreen/alarms and other APIs. Add
their exact implementation tasks after verified native behavior establishes
the appropriate mechanism. These items are OPEN, not omitted from the user's
request: action popups/ImageData, callbacks, alarms/fontSettings, DNR, offscreen,
sidePanel, userScripts, activeTab, nativeMessaging, identity, deployment and
release validation. They must not be marked complete by this DevTools task.

## Review Focus

- Genuine DevTools context and inspected document behavior, not manifest loading.
- No cross-profile or private extension installation.
- Resource escape and generation revocation.
- Packaged original signature/provenance remains untouched.
