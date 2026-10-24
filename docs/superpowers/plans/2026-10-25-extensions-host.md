# Electron extension host implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Supply verified Web Store packages and a tested, profile-scoped extension API bridge on Electron.
**Architecture:** Original compatibility code runs in managed extension copies, with authenticated native IPC from extension frames/workers and native messaging from isolated content scripts. Host capabilities remain separated from the shell bridge.
**Tech Stack:** Electron 45, Node.js 24, CommonJS, native test runner and Playwright.
**Spec:** `docs/superpowers/specs/2026-10-25-extensions-and-sync-design.md`

## Global Constraints

- Use the existing `extensions-and-sync` checkout as explicitly requested; do not switch worktrees or branches.
- Preserve MIT licensing, sandbox/context isolation, native permissions and existing browser features.
- Never expose the shell bridge to web pages or extensions. Derive identity from the native sender and session.
- Verify original CRX3 developer identity and production store publisher proof before adapting a managed copy.
- Native engine incompatibilities remain explicit; no local-storage replacement advertised as sync.
- Implementation and validation are already authorized; proceed through the plans without another routine approval request.

## Review Focus

- Forged extension identity and messages after disable/profile switch must be rejected (Task 1).
- Static, dynamic and programmatic content scripts must get equal capabilities without exposing them to page worlds (Tasks 1/3).
- Stale async installs/updates must not resurrect removed extensions or overwrite active versions (Task 2).
- Untrusted archive paths, signatures, publisher proofs and expanded permissions must fail before activation (Task 2).
- Native APIs must not bypass adapter permission checks or hide existing browser callbacks (Task 3).

### Task 1: Context bridge and feasibility

**Files:** create `src/main/extensions/bridge.cjs`, `frame-preload.cjs`, `worker-preload.cjs`, `bootstrap.js`, `adapt.cjs`; create `test/e2e/extension-context.test.cjs` and fixture helpers in `test/fixtures/extensions/`.
**Interfaces:** `ExtensionBridge({resolveExtension, dispatch})` registers frame/service-worker preloads with `attachSession(session, profileId)` and revokes with `close()`. `resolveExtension(profileId, extensionId)` returns enabled manifest/grants metadata; `dispatch(context, method, args)` implements an allowed extension call. Context is derived by the bridge and includes `profileId`, `extensionId`, native sender and context kind. `adaptExtension(source,destination,{publicKey?})` creates a deterministic derived copy and returns `{manifest, transformVersion}`.

- [ ] Write real Electron tests for extension frame, MV2 background, classic/module worker and isolated content-script round trips; assert native identity and absence of page-world access. Run first and record the expected missing-feature failure.
- [ ] Implement the authenticated transport and deterministic bootstrap/adaptation only; preserve native runtime messaging and original entry paths. Include invalid sender and unload rejection tests.
- [ ] Run `node --test --test-concurrency=1 test/e2e/extension-context.test.cjs`. Expected: all required contexts pass on the pinned runtime; otherwise investigate before claiming feasibility.
- [ ] Commit the verified bridge and record platform limitations. This proves transport, not complete settings synchronization.

### Task 2: Verified extension acquisition and lifecycle

**Files:** create `src/main/extensions/packages.cjs`, `catalog.cjs`, `manager.cjs`; create `test/extensions-packages.test.cjs`, `test/extensions-manager.test.cjs`, fixtures.
**Interfaces:** `parseStoreId(input)` validates IDs/canonical URLs; `verifyCrx(buffer,{expectedId,requirePublisher=true})` returns `{id, publicKey, zip, sha256}`; `extractArchive(zip,destination)` enforces spec limits. `fetchStorePackage(id,{signal,chromiumVersion})` returns verified package metadata. `inspectManifest(manifest)` returns permission and unsupported-capability information. Manager operations are bound to an explicit profile and lifecycle generation, never the mutable active profile after await.

- [ ] Write failing signature/ID/publisher, traversal, case collision, bomb, stale install/update and permission escalation tests using hand-built fixtures.
- [ ] Implement bounded HTTPS acquisition, original/derived package staging, source provenance and update comparison. Pin any parser dependency and its license.
- [ ] Implement manager install/restore/enable/disable/remove/update/approve/rollback with cancellation and persisted six-hour scheduling/backoff; await host permission callbacks before enabling a new package.
- [ ] Run `node --test test/extensions-packages.test.cjs test/extensions-manager.test.cjs`. Expected: positive fixtures accepted, malicious fixtures and stale operations rejected without altering active files.
- [ ] Commit and hand stable interfaces to desktop integration.

### Task 3: Browser API adapter

**Files:** create `src/main/extensions/api.cjs`, `permissions.cjs`; extend bridge/bootstrap; create `test/extensions-api.test.cjs` and real Electron API fixtures.
**Interfaces:** `ExtensionAPI({tabs,windows,menus,dialogs,storage,emit})` dispatches methods for the authenticated context. Browser callbacks accept profile identity explicitly. Storage exposes `call(context,method,args)` and emits `{profileId,extensionId,changes,areaName:'sync'}`. Native extension IDs and browser tab IDs remain stable for the lifetime documented by their APIs.

- [ ] Write failing behavioral tests for action/options, tabs/events, single-window support, context menus, commands and permission lifecycle.
- [ ] Implement adapters with grants and activeTab restrictions; unknown methods reject. Integrate native scripting injection so dynamic content receives the bootstrap. Preserve native runtime API and local storage behavior.
- [ ] Test effective native permission changes, disabled-extension requests and pending-reload handling without losing page drafts.
- [ ] Run focused unit and Electron tests; expected: matrix entries correspond to demonstrated behavior, unsupported capabilities reject visibly.
- [ ] Commit; continue into desktop integration plan.
