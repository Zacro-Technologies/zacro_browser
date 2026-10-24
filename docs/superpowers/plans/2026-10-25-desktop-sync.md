# Desktop extension synchronization implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Connect the real extension API and browser interface to the authenticated sync service and validate two independent clients.
**Architecture:** Main-process credential vault and transactional client state isolate each service/account/profile. A persistent outbox reconciles remote library intent and settings while local permission decisions control installation.
**Tech Stack:** Electron 45, Node.js 24, native SQLite where available in the pinned runtime, CommonJS/plain renderer JavaScript, node:test and Playwright.
**Spec:** `docs/superpowers/specs/2026-10-25-extensions-and-sync-design.md`

## Global Constraints

- Preserve `extensions-and-sync`, the sandbox, shell-only IPC and current browser/AI behavior.
- Never export or snapshot tokens, passwords, recovery codes except the explicit one-time recovery display, or local extension paths.
- Settings synchronization requires separate informed opt-in; local and sync storage are distinct.
- Resolve every async result against its originating service/account/profile/lifecycle generation.
- Use actual service and extension API calls for final two-client acceptance; no mock may substitute for convergence.
- Keep unsupported native APIs and unverified platform/provider acceptance visible.

## Review Focus

- Account/profile/service changes during an in-flight operation must not publish stale data.
- Worker/content-script changes and remote changes must emit correct API events without feedback loops.
- Offline queue survival, rejected mutations and atomic cursor acknowledgements must survive crashes.
- Sync intent cannot auto-approve permissions or reinstall a deleted generation.
- Packages must include new adapters without bundling the service or weakening Electron fuses.

### Task 1: Vault, local sync storage and client

**Files:** create `src/main/sync/{vault,client,storage}.cjs`, `src/core/sync/model.cjs`; tests `test/sync-client.test.cjs`, `test/sync-storage.test.cjs`.
**Interfaces:** `SyncClient({directory,protect,unprotect,onLibraryChange,onStorageChange})`; `configure({endpoint})`, `register`, `login`, `logout`, `status`, `devices`, `revokeDevice`, `datasets`, `linkProfile({profileId,datasetId,settingsSync,settingsChoice})`, `unlinkProfile`, `syncNow`, `queueExtension`, `callStorage(context,method,args)`, `close`. `status()` contains safe UI state only. The protected credential backend is passed by the host using Electron safeStorage and fails closed if unavailable. HTTP follows the service plan and its recorded refinements.

- [x] Write failing tests for secret exclusion, real account linkage, offline setting writes, atomic outbox persistence and namespace separation.
- [x] Implement the vault and distinct local sync storage with complete storage API serialization/quotas/events; connect the real HTTP protocol with cancellation, paging and jittered backoff.
- [x] Test deletion, reinstall generations, quota conflicts, account switches and service URL changes using two actual clients and the service.
- [x] Run `node --test test/sync-client.test.cjs test/sync-storage.test.cjs` and `npm test`; expected: all pass with no secret leakage.
- [x] Commit.

### Task 2: Browser integration and UI

**Files:** modify `src/main/main.cjs`, `src/core/store.cjs`, `src/renderer/app.js`, `styles.css`, `package.json`, `.github/workflows/ci.yml`; tests `test/e2e/extensions-sync.test.cjs` and extension fixtures.
**Interfaces:** connect the extension manager/API/bridge and SyncClient through explicit profile callbacks; expose only narrow validated shell `extension:*` and `sync:*` actions. Snapshot includes nonsecret extension/sync status. Async operations cannot use a changed active profile implicitly.

- [x] Write failing Electron flows for store installation review, action/options UI, registration/devices, dataset linking, sync consent, pending remote permissions and errors.
- [x] Integrate lifecycle cleanup, account/profile actions, compact UI, cancellation and readable status; remove the native webRequest listener conflict without weakening page/PDF behavior.
- [x] Run the two-browser fixture against the actual service, including writes from frame/worker/content contexts and remote change events.
- [ ] Run `npm run verify`, `npm run test:soak`, then `npm run pack:mac` and `npm run test:package`. Expected: baseline and new assertions pass; isolate any platform failures with evidence instead of weakening tests.
- [x] Update CI to include new suites for Windows and both Mac architectures. Remote CI and public provider checks are reported only if actually run.
- [ ] Commit.

### Task 3: Acceptance record and whole-branch review

**Files:** update README, roadmap, security and validation documentation; create extension compatibility and sync operator/user documentation.

- [ ] Record exact implemented APIs, tested extension versions, successful commands and any blocked/unverified contexts/providers/platforms. Do not label unsupported APIs complete.
- [ ] Obtain an independent whole-branch review of security, protocol, lifecycle and integration changes. Resolve material findings with reproducing tests.
- [ ] Run the appropriate final suites after fixes, inspect the diff and status, and commit reviewed work on the existing branch without merging/publishing.
